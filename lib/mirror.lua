-- Mirror sync: every machine in a room holds the same project (see docs/mirror-design.md).
-- This file's top half is pure (chunk normalizing, hashing, ordering, merging) so it runs under any Lua.
local mirror = {}

-- Lines in an item chunk that are this machine's business only: selection, REAPER's own ids (regenerated on
-- apply), MIDI pooling (a copy is its own item), MIDI editor view state, which take is active (wet/dry is each
-- person's choice) and item grouping (group numbers are per project: another machine's group 3 is other items).
-- Which notes are selected is each person's too: a selected event is written "e"/"x"/"<x", and goes out as "E"/"X"/"<X"
-- (opening the MIDI editor sent its VELLANE line, and a moved note went out selected: laptop, 2026-11-01).
local LOCAL = { "SEL", "IGUID", "IID", "GUID", "POOLEDEVTS", "POOLCOLOR", "CFGEDITVIEW", "CFGEDIT", "EVTFILTER", "KEYSNAP", "TRACKSEL", "GROUP", "VELLANE" }
local LOCAL_SET = {}
for _, k in ipairs(LOCAL) do LOCAL_SET[k] = true end
-- P_EXT keys that travel: our object id, and mirrored markers (band_m_*). Everything else is this machine's.
local function ext_travels(key) return key == "band_oid" or key:sub(1, 7) == "band_m_" end

-- A plug-in chain's lines that are this machine's own: FX ids, window positions, which window is open or docked.
local FX_LOCAL = { FXID = true, FLOATPOS = true, FLOAT = true, WNDRECT = true, SHOW = true, LASTSEL = true, DOCKED = true }

-- Normalized item chunk: what the band shares about this item, byte-identical on every machine that holds it.
function mirror.normalize_item(chunk)
  local out, in_ext, takefx = {}, false, 0 -- (takefx: depth inside a take's <TAKEFX chain, 0 outside it)
  for line in chunk:gmatch("[^\r\n]+") do
    local s = line:match("^%s*(.-)%s*$")
    local key = s:match("^(%S+)")
    local fx_top = takefx == 1
    if takefx > 0 then
      if s:sub(1, 1) == "<" then takefx = takefx + 1 elseif s == ">" then takefx = takefx - 1 end
    elseif s == "<TAKEFX" then takefx = 1 end
    if fx_top and key and FX_LOCAL[key] then -- (a take plug-in's window opened or moved isn't a change)
    elseif in_ext then
      if s == ">" then in_ext = false; out[#out + 1] = s
      elseif key and ext_travels(key) then out[#out + 1] = s end
    elseif s == "<EXT" or s == "<EXTI" then -- (REAPER writes an item's P_EXT as <EXTI, a track's or take's as <EXT)
      in_ext = true; out[#out + 1] = s
    elseif key == "TAKE" then
      out[#out + 1] = "TAKE" -- ("TAKE SEL" marks the active take: local)
    elseif s == "<SOURCE MIDIPOOL" then
      out[#out + 1] = "<SOURCE MIDI" -- (a pooled copy arrives as an item of its own: REAPER writes it as plain MIDI there)
    elseif s:match("^[ex]m? ") or s:match("^<x ") then
      out[#out + 1] = s:gsub("^(<?)(.)", function(lt, c) return lt .. c:upper() end, 1)
    elseif not (key and LOCAL_SET[key]) then
      out[#out + 1] = s
    end
  end
  -- an <EXT> block left empty by the filter is dropped
  return (table.concat(out, "\n"):gsub("<EXTI?\n>\n?", "")) .. "\n"
end

-- The <FXCHAIN> block of a track chunk, normalized: no FX ids, window positions or open/closed state.
-- `skip` (optional set of FXIDs) leaves out this machine's own additions (plug-in translations). A plug-in runs
-- from its BYPASS line to the line before the next BYPASS (FXID and WAK follow its block).
function mirror.fxchain(track_chunk, skip)
  local raw, depth, on = {}, 0, false
  for line in track_chunk:gmatch("[^\r\n]+") do
    local s = line:match("^%s*(.-)%s*$")
    if not on and s == "<FXCHAIN" then on = true end
    if on then
      local top = depth == 1 -- a line directly inside <FXCHAIN>
      if s:sub(1, 1) == "<" then depth = depth + 1 elseif s == ">" then depth = depth - 1 end
      raw[#raw + 1] = { s = s, top = top }
      if depth == 0 then break end
    end
  end
  if not on then return nil end
  local out, group, drop = {}, nil, false
  local function flush()
    if group and not drop then for _, g in ipairs(group) do out[#out + 1] = g end end
    group, drop = nil, false
  end
  for i, r in ipairs(raw) do
    local key = r.s:match("^(%S+)")
    if r.top and key == "BYPASS" then flush(); group = {} end
    if i == #raw then flush() end -- the closing ">"
    if r.top and key == "FXID" and skip and skip[r.s:match("^FXID (%S+)")] then drop = true end
    if not (r.top and FX_LOCAL[key]) then
      if group then group[#group + 1] = r.s else out[#out + 1] = r.s end
    end
  end
  return table.concat(out, "\n") .. "\n"
end

-- What a chunk says differently on each platform, said one way for hashing (Mac, 0.34.3: every chain with a Cockos
-- plug-in and every coloured item read "project differs" against Windows, for good). Windows' text is left as it
-- is, so nothing a Windows machine already sent hashes differently:
--   the plug-in's file: reasynth.vst.dylib (macOS), reasynth.vst.so (Linux), Foo.vst (a macOS VST2 bundle) -> .dll
--   "COLOR n B" / "TAKECOLOR n B": the colour in macOS byte order -> Windows' "n R" (REAPER converts either on load)
-- shortcut: a third-party VST2 named differently per platform (Foo_x64.dll vs Foo.vst) still reads as different.
local function portable(s)
  s = s:gsub('(<VST "[^"\n]*" "?[^"\n]-)%.vst%.dylib("? )', "%1.dll%2"):gsub('(<VST "[^"\n]*" "?[^"\n]-)%.vst%.so("? )', "%1.dll%2")
    :gsub('(<VST "[^"\n]*" "?[^"\n]-)%.vst("? )', "%1.dll%2")
  return (s:gsub("(COLOR )(%d+) B", function(p, n)
    n = math.tointeger(tonumber(n)) or 0
    local c = n & 0xFFFFFF
    return p .. ((n & ~0xFFFFFF) | ((c & 0xFF) << 16) | (c & 0xFF00) | ((c >> 16) & 0xFF)) .. " R"
  end))
end
mirror.portable = portable

-- Restless plug-ins: some write different saved data every time REAPER reads it (Kilohearts Disperser, Mac, 0.42.0). Their
-- track never held still, so its chain never went out and its parts never got a print, and nothing said so. One that
-- keeps changing while its knobs don't and nothing else in the project does (mirror.watch) goes on this list, which
-- every machine learns from the band's events. Its saved data then stays out of the hash, and its knobs say when it
-- really changed. (Not everything's data: loading a patch in a sampler changes only that, and must still count.)
mirror.restless = {} -- plug-in name -> true
mirror.RESTLESS_FLIPS, mirror.RESTLESS_SECS = 4, 12 -- changes in a row, and for how long, before a plug-in counts
local RESTLESS_KEY = "restless plugins"
local function restless_key(line) return line:match('^<%S+%s+"([^"]*)"') or line:match("^<%S+%s+(%S+)") end
local function fx_block_start(l) return l:sub(1, 1) == "<" and l ~= "<FXCHAIN" and not l:match("^<PARMENV") and not l:match("^<PROGRAMENV") end
-- A chain's plug-in blocks. Pure. -> list of { key, first, last, text } (line numbers in `lines`).
function mirror.plugin_blocks(lines)
  local out, i = {}, 1
  while i <= #lines do
    if fx_block_start(lines[i]) then
      local depth, j = 1, i
      while depth > 0 and j < #lines do
        j = j + 1
        if lines[j]:sub(1, 1) == "<" then depth = depth + 1 elseif lines[j] == ">" then depth = depth - 1 end
      end
      local b = out[#out]
      if lines[i]:match("^<JS_SER") and b then -- (a JSFX's saved data: a block of its own, right after the plug-in's)
        b.last, b.text = j, table.concat(lines, "\n", b.first, j)
      else
        out[#out + 1] = { key = restless_key(lines[i]), first = i, last = j, text = table.concat(lines, "\n", i, j) }
      end
      i = j
    end
    i = i + 1
  end
  return out
end
local function chain_lines(chain)
  local lines = {}
  for l in (chain or ""):gmatch("[^\n]+") do lines[#lines + 1] = l end
  return lines
end
-- The restless plug-ins in a chain (a list), and which plug-ins differ between two reads of one. Pure.
function mirror.restless_in(chain)
  if not next(mirror.restless) then return nil end
  local names, seen = {}, {}
  for _, b in ipairs(mirror.plugin_blocks(chain_lines(chain))) do
    if b.key and mirror.restless[b.key] and not seen[b.key] then seen[b.key] = true; names[#names + 1] = b.key end
  end
  return #names > 0 and names or nil
end
function mirror.fx_differing(a, b)
  local x, y, names = mirror.plugin_blocks(chain_lines(a)), mirror.plugin_blocks(chain_lines(b)), {}
  if #x ~= #y then return names end
  for i, p in ipairs(x) do
    if p.key and p.key == y[i].key and p.text ~= y[i].text then names[#names + 1] = p.key end
  end
  return names
end
-- Do two chains say the same thing? Each plug-in's saved data is lines of base64, and REAPER re-encodes it on a machine
-- without the plug-in: the same bytes in different pieces (a Mac's GGD chain read differently on the PC and the laptop,
-- so the fingerprints stayed apart for good: 0.42.2). Pure.
function mirror.fx_same(a, b)
  if a == b then return true end
  local fxfiles = require("fxfiles")
  local function bytes(chain)
    local out = {}
    for _, l in ipairs(chain_lines(chain)) do
      out[#out + 1] = (l:match("^[A-Za-z0-9+/]+=*$") and #l >= 8) and fxfiles.unbase64(l) or ("\0" .. l .. "\0")
    end
    return table.concat(out)
  end
  return bytes(a) == bytes(b)
end
function mirror.restless_load()
  if mirror.restless_loaded or not (reaper and reaper.GetExtState) then return end
  mirror.restless_loaded = true
  for n in reaper.GetExtState("BandSync", RESTLESS_KEY):gmatch("[^\n]+") do mirror.restless[n] = true end
end
-- Add names (from this machine's own finding, or a bandmate's event). -> whether any is new.
function mirror.restless_add(names)
  local new = false
  for _, n in ipairs(type(names) == "table" and names or {}) do
    if type(n) == "string" and not mirror.restless[n] then mirror.restless[n], new = true, true end
  end
  if new and reaper and reaper.SetExtState then
    local all = {}
    for n in pairs(mirror.restless) do all[#all + 1] = n end
    table.sort(all)
    reaper.SetExtState("BandSync", RESTLESS_KEY, table.concat(all, "\n"), true)
  end
  return new
end
local function restless_sig()
  local all = {}
  for n in pairs(mirror.restless) do all[#all + 1] = n end
  table.sort(all)
  return table.concat(all, "\0")
end
-- All the knobs of a track's plug-ins, as a string: what says a restless plug-in really changed. This machine's only,
-- as a machine without the plug-in has none, so it never goes into a hash.
function mirror.fx_params(tr)
  local out = {}
  for i = 0, reaper.TrackFX_GetCount(tr) - 1 do
    for p = 0, math.min(reaper.TrackFX_GetNumParams(tr, i), 3000) - 1 do
      out[#out + 1] = string.format("%.4f", (reaper.TrackFX_GetParamNormalized(tr, i, p)))
    end
    out[#out + 1] = "|"
  end
  return table.concat(out, ",")
end

-- A plug-in chain's hash: its normalized text without each VST's last state line. That line is REAPER's program block
-- for the instance, and a plug-in loaded from a chunk writes its program name there ("Program 1"), so the same chain
-- read differently on every machine that received it (laptop, 2026-10-31). It still travels; only the hash skips it.
-- A restless plug-in counts by its first line only.
function mirror.fx_hash(chain)
  local lines = {}
  for l in portable(chain):gmatch("[^\n]+") do lines[#lines + 1] = l end
  if next(mirror.restless) then
    local blocks = mirror.plugin_blocks(lines)
    for b = #blocks, 1, -1 do
      if blocks[b].key and mirror.restless[blocks[b].key] then
        for k = blocks[b].last - 1, blocks[b].first + 1, -1 do table.remove(lines, k) end
      end
    end
  end
  local i = 1
  while i <= #lines do
    if lines[i]:match("^<VST") then
      local j = i + 1
      while j <= #lines and lines[j] ~= ">" and lines[j]:sub(1, 1) ~= "<" do j = j + 1 end
      if lines[j] == ">" and j - i - 1 >= 2 and lines[j - 1]:match("^[A-Za-z0-9+/]+=*$") then table.remove(lines, j - 1) end
    end
    i = i + 1
  end
  return mirror.hash(table.concat(lines, "\n") .. "\n")
end
-- An item's hash: the same, with take plug-ins' program lines left out as above (laptop, block K: an item with ReaEQ
-- as a take FX read "Program 1" on the machine that applied it, and the two projects differed for good). Only items
-- with a VST take FX hash differently from before, so an update doesn't make everyone send every item again.
function mirror.item_hash(track, state)
  state = portable(state)
  -- (on a lane its YPOS is only its share of the track's height, so adding a lane changed every item, and each machine sent
  -- them all: 500 events a minute on Bass Guitar, laptop and PC, 0.42.7. BANDLANE is what counts)
  if state:find("BANDLANE", 1, true) then state = state:gsub("YPOS [^\n]*\n", "") end
  if not state:find("<VST", 1, true) then return mirror.hash(track .. "\n" .. state) end
  local lines = {}
  for l in (state .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = l end
  lines[#lines] = nil -- (the one the extra "\n" made)
  local i = 1
  while i <= #lines do
    if lines[i]:match("^%s*<VST") then
      local j = i + 1
      while j <= #lines and not lines[j]:match("^%s*>$") and not lines[j]:match("^%s*<") do j = j + 1 end
      if j <= #lines and lines[j]:match("^%s*>$") and j - i - 1 >= 2 and lines[j - 1]:match("^%s*[A-Za-z0-9+/]+=*$") then table.remove(lines, j - 1) end
    end
    i = i + 1
  end
  return mirror.hash(track .. "\n" .. table.concat(lines, "\n"))
end

-- A track's automation ("E-" + its oid) and its receives ("R-", each with its send envelopes) travel as objects of
-- their own, cut out of the track chunk and spliced back in. Writing a track chunk back keeps its plug-ins running
-- (measured, REAPER 7.83: no @init, even with a changed parameter). Which envelopes show, which is armed and how
-- tall its lane is stay each person's own. A receive names its source track by oid (REAPER's chunk says its
-- position); receives from a track that isn't mirrored (Real time, live views) stay as they are on each machine.
mirror.HV = 6 -- how object hashes are made: bump it whenever what goes into one changes (events carry it as hv)
mirror.KIND = { T = "track", F = "fx", E = "env", R = "recv", M = "misc", I = "item" } -- (an oid's first letter)
mirror.PART = { fx = "the plug-ins", env = "the automation", recv = "the sends", misc = "the groups, lock, input FX or note names" }
mirror.PARTS = { "F", "E", "R", "M" } -- (what a track oid T-x carries: F-x, E-x, R-x, M-x)
local ENV_LOCAL = { EGUID = true, ARM = true, VIS = true, LANEHEIGHT = true, POOLEDENVINST = true }
local function is_env(u) return u.block and u.tag:find("ENV") and u.tag:sub(1, 3) ~= "AUX" end
local function is_aux(u) return u.block and u.tag:sub(1, 3) == "AUX" and u.tag:find("ENV") end
local MISC = { GROUP_FLAGS = true, GROUP_FLAGS_HIGH = true, LOCK = true, FXCHAIN_REC = true, MIDINOTENAMES = true }
local function is_misc(u) return MISC[u.tag] ~= nil end

-- A track chunk's first line, its top-level parts in order ({ tag, lines, block }) and its closing line.
local function track_units(chunk)
  local head, units, tail, depth, cur = nil, {}, ">", 0, nil
  for line in (chunk:gsub("\r", "") .. "\n"):gmatch("(.-)\n") do
    local s = line:match("^%s*(.-)%s*$")
    if s == "" then -- (nothing)
    elseif depth == 0 then head, depth = line, 1
    elseif depth == 1 then
      if s == ">" then tail, depth = line, 0
      elseif s:sub(1, 1) == "<" then cur = { tag = s:match("^<(%S+)"), lines = { line }, block = true }; units[#units + 1] = cur; depth = 2
      else units[#units + 1] = { tag = s:match("^(%S+)"), lines = { line } } end
    else
      cur.lines[#cur.lines + 1] = line
      if s:sub(1, 1) == "<" then depth = depth + 1 elseif s == ">" then depth = depth - 1 end
    end
  end
  return head, units, tail
end

-- An envelope block as it travels: trimmed, without its view lines.
local function env_norm(lines, drop)
  local out, depth = {}, 0
  for _, l in ipairs(lines) do
    local s = l:match("^%s*(.-)%s*$")
    if not (depth == 1 and (drop or ENV_LOCAL)[s:match("^(%S+)")]) then out[#out + 1] = s end
    if s:sub(1, 1) == "<" then depth = depth + 1 elseif s == ">" then depth = depth - 1 end
  end
  return table.concat(out, "\n") .. "\n"
end

-- A track's MIDI note names, { "chan pitch" = name }, from its chunk or a travelling state. A cleared name stays in
-- REAPER's block as "" (the same as none).
function mirror.note_names(text)
  local out, on = {}, false
  for line in text:gmatch("[^\r\n]+") do
    local s = line:match("^%s*(.-)%s*$")
    if s == "<MIDINOTENAMES" then on = true
    elseif on and s == ">" then on = false
    elseif on then
      local chan, pitch, rest = s:match("^(%-?%d+)%s+(%d+)%s+(.*)$")
      local name = rest and (rest:match('^"(.-)"') or rest:match("^'(.-)'") or rest:match("^`(.-)`") or rest:match("^(%S+)"))
      if name and name ~= "" then out[chan .. " " .. pitch] = name end
    end
  end
  return out
end

-- A track chunk's envelopes, receives and other settings (groups, lock, input FX, note names) as they travel.
-- `oid_at(index)`: the oid of the track at that 0-based position, nil when it isn't mirrored (its receive is left out).
function mirror.track_parts(chunk, oid_at)
  local _, units = track_units(chunk)
  local env, recv, misc, cur = {}, {}, {}, nil
  for _, u in ipairs(units) do
    if u.tag == "MIDINOTENAMES" then -- (named notes only, in a fixed order: set through REAPER's API on the other side)
      local names, keys = mirror.note_names(table.concat(u.lines, "\n")), {}
      for k in pairs(names) do keys[#keys + 1] = k end
      table.sort(keys)
      if #keys > 0 then
        local b = { "<MIDINOTENAMES" }
        for _, k in ipairs(keys) do local q = names[k]:find('"') and "`" or '"'; b[#b + 1] = k .. " " .. q .. names[k] .. q end
        misc[#misc + 1] = table.concat(b, "\n") .. "\n>\n"
      end
    elseif is_misc(u) then misc[#misc + 1] = u.block and env_norm(u.lines, FX_LOCAL) or (u.lines[1]:match("^%s*(.-)%s*$") .. "\n") end
    if u.tag == "AUXRECV" then
      local idx, rest = u.lines[1]:match("^%s*AUXRECV%s+(%d+)(.-)%s*$")
      local src = idx and oid_at(tonumber(idx))
      cur = src and { "AUXRECV " .. src .. rest .. "\n" } or nil
      if cur then recv[#recv + 1] = cur end
    elseif is_aux(u) then
      if cur then cur[#cur + 1] = env_norm(u.lines) end
    else
      cur = nil
      if is_env(u) then env[#env + 1] = env_norm(u.lines) end
    end
  end
  for i, r in ipairs(recv) do recv[i] = table.concat(r) end
  return table.concat(env), table.concat(recv), table.concat(misc)
end

-- The track chunk with its envelopes (what = "env") or its mirrored receives ("recv") replaced by `state` (as
-- track_parts gives it). `index_of(oid)`: that track's 0-based position here, nil when it isn't here yet (then nil
-- is returned: try again later). Envelopes keep this machine's view lines; a new one shows in its lane.
function mirror.splice_parts(chunk, what, state, index_of, oid_at)
  local head, units, tail = track_units(chunk)
  local new, view = {}, {}
  for _, u in ipairs(units) do
    if is_env(u) then
      local keep = {}
      for k = 2, #u.lines do
        local key = u.lines[k]:match("^%s*(%S+)")
        if ENV_LOCAL[key] and key ~= "EGUID" and key ~= "POOLEDENVINST" then keep[#keep + 1] = u.lines[k] end
      end
      view[u.tag] = keep
    end
  end
  local cur
  for line in state:gmatch("[^\n]+") do -- the incoming parts, back into chunk lines
    local src, rest = line:match("^AUXRECV (%S+)(.*)$")
    if src then
      local idx = index_of(src)
      if not idx then return nil end
      cur = { tag = "AUXRECV", lines = { "AUXRECV " .. idx .. rest } }
      new[#new + 1] = cur
    elseif line:match("^BANDAI") then -- (automation items: rebuilt through the API, mirror.set_ai)
    elseif not (cur and cur.open) and line:sub(1, 1) ~= "<" then -- (a lone line: GROUP_FLAGS, LOCK)
      cur = { tag = line:match("^(%S+)"), lines = { line } }
      new[#new + 1] = cur
    elseif line:sub(1, 1) == "<" and not (cur and cur.open) then
      cur = { tag = line:match("^<(%S+)"), lines = { line }, block = true, open = 1 }
      new[#new + 1] = cur
      if what == "env" then for _, v in ipairs(view[cur.tag] or { "VIS 1 1 1" }) do cur.lines[#cur.lines + 1] = v end end
    else
      cur.lines[#cur.lines + 1] = line
      if line:sub(1, 1) == "<" then cur.open = cur.open + 1 elseif line == ">" then cur.open = cur.open - 1 end
      if cur.open == 0 then cur.open = nil end
    end
  end
  -- note names aren't read from a chunk written back (measured 7.83): mirror.apply sets them through REAPER's API
  for i = #new, 1, -1 do if new[i].tag == "MIDINOTENAMES" then table.remove(new, i) end end
  local out, at, after_recv = { head }, nil, false
  for _, u in ipairs(units) do
    local drop
    if what == "env" then drop = is_env(u)
    elseif what == "misc" then drop = is_misc(u) and u.tag ~= "MIDINOTENAMES"
    elseif u.tag == "AUXRECV" then
      local idx = u.lines[1]:match("^%s*AUXRECV%s+(%d+)")
      drop = idx and oid_at(tonumber(idx)) ~= nil
      after_recv = drop
    else drop = is_aux(u) and after_recv end
    if not is_aux(u) and u.tag ~= "AUXRECV" then after_recv = false end
    -- the new parts go where the old ones were, else before the plug-ins and items
    if not at and (drop or u.tag == "FXCHAIN" or u.tag == "ITEM" or (what == "recv" and is_env(u))) then
      at = true
      for _, n in ipairs(new) do for _, l in ipairs(n.lines) do out[#out + 1] = l end end
    end
    if not drop then for _, l in ipairs(u.lines) do out[#out + 1] = l end end
  end
  if not at then for _, n in ipairs(new) do for _, l in ipairs(n.lines) do out[#out + 1] = l end end end
  out[#out + 1] = tail
  return table.concat(out, "\n") .. "\n"
end

-- The plug-ins in a track chunk's <FXCHAIN> whose FXID is in `keep`, as raw lines (each from its BYPASS line to the
-- line before the next plug-in's): what stays on this machine when the band's chain lands (the master's live link).
function mirror.fx_blocks(track_chunk, keep)
  local out, group, depth, on, hit = {}, nil, 0, false, false
  local function flush() if group and hit then for _, l in ipairs(group) do out[#out + 1] = l end end; group, hit = nil, false end
  for line in track_chunk:gmatch("[^\r\n]+") do
    local s = line:match("^%s*(.-)%s*$")
    if not on and s == "<FXCHAIN" then on, depth = true, 1
    elseif on then
      local top = depth == 1
      if s:sub(1, 1) == "<" then depth = depth + 1 elseif s == ">" then depth = depth - 1 end
      if depth == 0 then flush(); break end
      if top and s:match("^BYPASS ") then flush(); group = {} end
      if group then group[#group + 1] = s end
      if top and keep[s:match("^FXID (%S+)") or ""] then hit = true end
    end
  end
  return out
end

-- The plug-ins a chain uses, as REAPER names them ("VST3: ReaEQ (Cockos)", "JS: utility/volume"). Pure.
function mirror.fx_names(chain)
  local out = {}
  for line in chain:gmatch("[^\r\n]+") do
    local s = line:match("^%s*(.-)%s*$")
    local name = s:match('^<%u+%d? "([^"]+)"') or (s:match("^<JS (%S+)") and ("JS: " .. s:match("^<JS (%S+)")))
    if name then out[#out + 1] = name end
  end
  return out
end

-- 32-bit FNV-1a: cheap, stable on every Lua; enough to tell versions apart (not a security hash).
-- Results for text seen before (a whole look reads every track and item; most haven't changed since the last one,
-- and working them out again in Lua was most of a look's time: 0.5 s at 60 tracks and 2,000 items, measured
-- 2026-10-31). Keyed by the exact text, so any change misses and is worked out afresh. Emptied when its keys reach
-- 64 MB (a track's text holds all its items, so a busy session makes big ones), or 50,000 of them.
local memo, memo_n, memo_bytes = {}, 0, 0
function mirror.memo(key, make)
  local v = memo[key]
  if v == nil then
    if memo_n > 50000 or memo_bytes > 64 * 1048576 then memo, memo_n, memo_bytes = {}, 0, 0 end
    v = make()
    memo[key], memo_n, memo_bytes = v, memo_n + 1, memo_bytes + #key
  end
  return v
end
local function fnv(s)
  local h = 2166136261
  for i = 1, #s do
    h = h ~ s:byte(i)
    h = (h * 16777619) & 0xFFFFFFFF
  end
  return string.format("%08x", h)
end
function mirror.hash(s)
  if #s < 256 then return fnv(s) end
  return mirror.memo("h\0" .. s, function() return fnv(s) end)
end

-- The next revision number. An owner's change (they've claimed it, or they drive and it's unclaimed) steps far past anything made meanwhile, so it stands however many
-- times someone else changed it while apart, and every computer agrees without being told who owned what. Whoever has seen it follows it with a higher number still.
mirror.OWNER_STEP = 1000
function mirror.next_rev(rev, owned) return (rev or 0) + 1 + (owned and mirror.OWNER_STEP or 0) end
-- Which of two revisions of one object wins: higher rev, then later time, then the larger user name (so every
-- machine picks the same one).
function mirror.newer(a, b)
  if not b then return true end
  if not a then return false end
  if (a.rev or 0) ~= (b.rev or 0) then return (a.rev or 0) > (b.rev or 0) end
  if (a.time or "") ~= (b.time or "") then return (a.time or "") > (b.time or "") end
  return (a.user or "") > (b.user or "")
end

-- Three-way decision for one object after working offline: base = the hash it had when last in sync, mine = here
-- now, theirs = the room's newest. Returns "same", "send" (only mine changed), "take" (only theirs) or "both".
function mirror.merge3(base, mine, theirs)
  if mine == theirs then return "same" end
  if mine == base then return "take" end
  if theirs == base then return "send" end
  return "both"
end

-- Going back (History). `entries` are History's (recall.entries: mirror events have kind "obj"). A plan maps
-- oid -> the revision to bring back, or false (the object didn't exist then: it goes). Pure.
-- Restore project / selection state: every object in scope as it was right after entries[upto].
-- (which revision an object had: the one that won, as sync settles it (rev first, then time and name), not the latest
-- by time; a clash's loser is later by time and was never the band's: review, 2026-10-31)
local function won(a, x)
  return not x or mirror.newer({ rev = a.rev or 0, time = (a.time or "") .. (a.user or "") }, { rev = x.rev or 0, time = (x.time or "") .. (x.user or "") })
end
mirror.won = won
function mirror.plan_restore(entries, upto, in_scope)
  local at, last = {}, {}
  for i, e in ipairs(entries) do
    if e.kind == "obj" and e.oid then
      if won(e, last[e.oid]) then last[e.oid] = e end
      if i <= upto and won(e, at[e.oid]) then at[e.oid] = e end
    end
  end
  local plan = {}
  for oid, l in pairs(last) do
    if not in_scope or in_scope(oid, l, at[oid]) then
      local t = at[oid]
      plan[oid] = (t and not t.gone) and t or false
    end
  end
  return plan
end
-- Undo one change: that object back to the revision before entries[i] (none before: it was new, so it goes).
function mirror.plan_undo(entries, i)
  local e = entries[i]
  if not (e and e.kind == "obj" and e.oid) then return nil end
  local best -- (the revision it had before: the winner among the older ones, not just the one before it by time)
  for j = 1, #entries do
    local p = entries[j]
    if j ~= i and p.kind == "obj" and p.oid == e.oid and (p.time or "") <= (e.time or "") and won(e, p) and won(p, best) then best = p end -- (made before it)
  end
  if best then return { [e.oid] = (not best.gone) and best or false } end
  return { [e.oid] = false }
end

-- Which tracks moved between two looks at the list (arrays of oids), as a set: those that don't fit the order the rest kept,
-- longest run first. Tracks added or gone aren't moves, nor is what they shift. `selected` (a set) is what a person drags, so a
-- swap of two neighbours blames the selected one; it counts if the track above it changed. Pure.
function mirror.moved_tracks(old, new, selected)
  local in_old, in_new, moved = {}, {}, {}
  for _, x in ipairs(old) do in_old[x] = true end
  for _, x in ipairs(new) do in_new[x] = true end
  local a, b = {}, {}
  for _, x in ipairs(old) do if in_new[x] and not selected[x] then a[#a + 1] = x end end
  for _, x in ipairs(new) do if in_old[x] and not selected[x] then b[#b + 1] = x end end
  -- (longest common run, table by table: lists are short, and it's only worked out when the order has changed)
  local len = {}
  for i = #a + 1, 1, -1 do
    len[i] = {}
    for j = #b + 1, 1, -1 do
      if i > #a or j > #b then len[i][j] = 0
      elseif a[i] == b[j] then len[i][j] = len[i + 1][j + 1] + 1
      else len[i][j] = math.max(len[i + 1][j], len[i][j + 1]) end
    end
  end
  local kept, i, j = {}, 1, 1
  while i <= #a and j <= #b do
    if a[i] == b[j] then kept[a[i]] = true; i, j = i + 1, j + 1
    elseif len[i + 1][j] >= len[i][j + 1] then i = i + 1
    else j = j + 1 end
  end
  for _, x in ipairs(a) do if not kept[x] then moved[x] = true end end
  local above = {}
  for k, x in ipairs(old) do above[x] = old[k - 1] or "" end
  for k, x in ipairs(new) do
    if selected[x] and in_old[x] and above[x] ~= (new[k - 1] or "") then moved[x] = true end
  end
  return moved
end

-- The order the studio's tracks should be in: the newest list anyone published, then whatever's newer than that list under the
-- track it sat under (`after`: oid -> oid above), or at the end. Ties by oid, so every computer comes to the same list. Pure.
function mirror.wanted_order(list, here, after)
  local has, out, put = {}, {}, {}
  for _, x in ipairs(here) do has[x] = true end
  for _, x in ipairs(list or {}) do if has[x] and not put[x] then put[x] = true; out[#out + 1] = x end end
  local new = {}
  for _, x in ipairs(here) do if not put[x] then new[#new + 1] = x end end
  table.sort(new)
  repeat
    local landed = false
    for k = #new, 1, -1 do -- (from the end, so of two under one track the lower oid ends up first)
      local x, above = new[k], after[new[k]] or ""
      local at = above == "" and 0 or nil
      if not at then for i, y in ipairs(out) do if y == above then at = i end end end
      if at then table.insert(out, at + 1, x); put[x] = true; table.remove(new, k); landed = true end
    end
  until not landed
  for _, x in ipairs(new) do out[#out + 1] = x end -- (what it sat under is gone)
  return out
end

-- An item's state with its place and length to 8 decimals: beyond that it's arithmetic, not an edit. Pure.
function mirror.rounded(state)
  local function round(k, v) return k .. string.format("%.8f", tonumber(v) or 0) end
  return (state:gsub("(%f[%w]POSITION )([%d%.]+)", round, 1):gsub("(%f[%w]LENGTH )([%d%.]+)", round, 1))
end

-- How much of a track's parts the lanes that play cover, in seconds, against all it holds: { pos, len, plays } per item. Pure.
function mirror.lane_cover(items)
  local function span(only)
    local list = {}
    for _, x in ipairs(items) do if not only or x.plays then list[#list + 1] = x end end
    table.sort(list, function(a, z) return a.pos < z.pos end)
    local total, reach = 0, -math.huge
    for _, x in ipairs(list) do
      local from = math.max(x.pos, reach)
      if x.pos + x.len > from then total = total + x.pos + x.len - from; reach = x.pos + x.len end
    end
    return total
  end
  return span(true), span(false)
end

-- Which lane entries[i]'s item sat on, or nil (not on a lane). A delete holds no state, so it's the one its item had last.
-- Kept on the entry: lists call this for every row they draw. Pure.
function mirror.entry_lane(entries, i)
  local e = entries[i]
  if e.lane_seen == nil then
    local from = e
    for j = i - 1, 1, -1 do
      if type(from.state) == "string" then break end
      if not e.gone then break end
      if entries[j].oid == e.oid then from = entries[j] end
    end
    e.lane_seen = type(from.state) == "string" and tonumber(from.state:match("BANDLANE (%d+)")) or false
    e.lane_time = from.time
  end
  return e.lane_seen or nil
end

-- One act that made several changes on one lane: a glue that took three items and made one, a delete of parts picked together.
-- History's indexes of entries[i] and the others on that lane from the same person in the same second. Pure.
-- (A glue's deletes undone without its new item left all three playing: laptop, 0.42.8. But not across lanes: deleting a pass
-- also deletes its copies in the comp, and undoing them together put old copies over newer comp pieces: Mac, 0.42.10. So those
-- are rows of their own, each naming its lane: mirror.lane_words.)
-- shortcut: same second only, so an act that straddles one shows as two rows; a per-act id on events would settle it.
function mirror.same_moment(entries, i)
  local e, out = entries[i], { i }
  if not (e and e.kind == "obj" and e.oid) then return out end
  for _, step in ipairs({ -1, 1 }) do
    local j = i + step
    while entries[j] and entries[j].time == e.time do
      local p = entries[j]
      if p.kind == "obj" and p.oid ~= e.oid and p.user == e.user and p.obj == e.obj and p.name == e.name
        and (not p.restored) == (not e.restored) and mirror.entry_lane(entries, j) == mirror.entry_lane(entries, i) then out[#out + 1] = j end
      j = j + step
    end
  end
  return out
end
-- " (lane Take 2)" for a row about an item on a lane, else "": the lane's name when the change was made, from its track's newest
-- event by then, as lanes added or removed since shift the numbers. Pure.
function mirror.lane_words(entries, i)
  local e, lane = entries[i], mirror.entry_lane(entries, i)
  if not lane or not e.track then return "" end
  if e.lane_words_seen == nil then
    local start = i
    while entries[start + 1] and entries[start + 1].time == e.time do start = start + 1 end -- (a track's event can follow its items' in the same second)
    local name, plain = "", false
    for j = start, 1, -1 do
      local p = entries[j]
      if p.obj == "track" and p.oid == e.track and type(p.state) == "table" and (p.time or "") <= (e.lane_time or "") then
        plain = (tonumber(p.state.lanes) or 0) < 2
        local n = 0
        for v in ((p.state.lanenames or "") .. ","):gmatch("([^,]*),") do
          if n == lane then name = v end
          n = n + 1
        end
        break
      end
    end
    e.lane_words_seen = plain and "" or string.format(" (lane %s)", name ~= "" and name or tostring(lane + 1))
  end
  return e.lane_words_seen
end
function mirror.plan_undo_moment(entries, i)
  local plan
  for _, j in ipairs(mirror.same_moment(entries, i)) do
    for oid, v in pairs(mirror.plan_undo(entries, j) or {}) do plan = plan or {}; plan[oid] = v end
  end
  return plan
end

-- The top bar's Undo / Redo (your own changes only, for everyone). Pure, over History's entries:
-- last_mine: your newest change not undone yet (undo events carry `undoes`, redo events `redoes`).
function mirror.last_mine(entries, user)
  local undone = {}
  for i = #entries, 1, -1 do
    local e = entries[i]
    if e.kind == "obj" and e.user == user then
      if e.undoes and not undone[e.id] then undone[e.undoes] = true
      elseif e.redoes then undone[e.redoes] = true -- (a redo undoes an undo: the change it undid counts again)
      elseif not e.restored and not e.auto and not undone[e.id] then return i end -- (auto: a print StudioSync refreshed)
    end
  end
end
-- Who else changed entries[i]'s object after it (undoing it takes their later change back too). Pure.
function mirror.later_by_others(entries, i)
  local e, who, seen = entries[i], {}, {}
  for j = i + 1, #entries do
    local x = entries[j]
    if x.kind == "obj" and x.oid == e.oid and x.user ~= e.user and not seen[x.user] then seen[x.user] = true; who[#who + 1] = x.user end
  end
  return who
end
-- last_undo: your newest undo that hasn't been redone.
function mirror.last_undo(entries, user)
  local redone = {}
  for i = #entries, 1, -1 do
    local e = entries[i]
    if e.kind == "obj" and e.user == user then
      if e.redoes then redone[e.redoes] = true
      elseif e.undoes and not redone[e.id] then return i
      elseif not e.restored and not e.auto then return nil end -- a new change since: nothing to redo (a print StudioSync refreshed isn't one)
    end
  end
end

-- Media paths in chunks: anything in one of the song's rooms' media folders travels as {media:<room>}/<file>, so
-- every machine resolves it to its own shared folder (J:/... here, /Volumes/... on a Mac), and a side room's copy of
-- main's items still points at main's media (it isn't a change). `media_dir`: this room's, <song>/rooms/<room>/media.
local function norm_path(p) return (p:gsub("\\", "/")) end
local function rooms_dir(media_dir) return (norm_path(media_dir):gsub("/$", ""):gsub("/[^/]+/media$", "")) end
function mirror.tokenize_media(chunk, media_dir)
  local base = rooms_dir(media_dir):lower() .. "/"
  return (chunk:gsub('(FILE ")([^"]+)(")', function(a, path, z)
    local p = norm_path(path)
    if p:lower():sub(1, #base) == base then
      local room, rel = p:sub(#base + 1):match("^([^/]+)/media/(.+)$")
      if room then return a .. "{media:" .. room .. "}/" .. rel .. z end
    end
    return a .. path .. z
  end))
end
local function media_path(media_dir, room, rel)
  return room and (rooms_dir(media_dir) .. "/" .. room .. "/media/" .. rel) or (norm_path(media_dir):gsub("/$", "") .. "/" .. rel)
end
function mirror.resolve_media(chunk, media_dir)
  chunk = chunk:gsub('FILE "{media:([^}]+)}/([^"]+)"', function(room, rel) return 'FILE "' .. media_path(media_dir, room, rel) .. '"' end)
  return (chunk:gsub('FILE "{media}/([^"]+)"', function(rel) return 'FILE "' .. media_path(media_dir, nil, rel) .. '"' end))
end
-- The media files (full paths here) a tokenized chunk needs.
function mirror.media_needed(chunk, media_dir)
  local t = {}
  for room, rel in chunk:gmatch('FILE "{media:([^}]+)}/([^"]+)"') do t[#t + 1] = media_path(media_dir, room, rel) end
  for rel in chunk:gmatch('FILE "{media}/([^"]+)"') do t[#t + 1] = media_path(media_dir, nil, rel) end
  return t
end

-- A fresh object id: kind letter, user, time, counter (unique without coordination: the counter carries 4 random
-- digits, since two machines under one name can start the same second). Upper case throughout: REAPER hands
-- project ExtState keys back upper-cased (EnumProjExtState), and every object is looked up by them.
local seq = 0
function mirror.user_tag(user) return ((user or "x"):gsub("[^%w]", "_")):upper() end
function mirror.new_oid(kind, user, now)
  seq = seq + 1
  return string.format("%s-%s-%s-%d%04d", kind:upper(), mirror.user_tag(user), now or os.date("!%Y%m%d%H%M%S"), seq, math.random(0, 9999))
end
-- Who made an object (its oid's second field).
function mirror.creator(oid) return (oid or ""):match("^%a%-(.-)%-%d+%-%d+$") end
-- Did `user` make the object with this oid? Under an old name too (band.names: they renamed since).
function mirror.is_creator(oid, user)
  local c = mirror.creator(oid)
  if not c then return false end
  if c == mirror.user_tag(user) then return true end
  local now = require("band").names()[c]
  return now ~= nil and mirror.user_tag(now) == mirror.user_tag(user)
end

-- Track settings that travel, as one line (order matters only for hashing). Faders and pan always travel, but with
-- Local mixing on they aren't a change here. Never: record arm, input, monitoring, height, selection.
-- `colour` (tests and re-anchoring): whether the colour counts; by default it does unless SWS colours tracks here.
function mirror.track_hash(t, local_mix, colour) return mirror.hash(mirror.track_line(t, local_mix, colour) .. "|" .. (t.after or "")) end
-- Does SWS auto-colouring colour tracks on this machine? Then its track colours are its own: not a change, and not
-- sent (its rules would recolour whatever the band set, and sending them made machines recolour each other).
local auto_colour = { at = -math.huge }
function mirror.own_colours()
  if not reaper.NamedCommandLookup then return false end
  if reaper.time_precise() - auto_colour.at > 1 then
    local id = reaper.NamedCommandLookup("_SWSAUTOCOLOR_ENABLE")
    auto_colour.at, auto_colour.on = reaper.time_precise(), id > 0 and reaper.GetToggleCommandState(id) == 1
  end
  return auto_colour.on
end
-- More of a track's settings, as { field, REAPER parameter }: the FX button, channels, the parent/master send and
-- its channels, timebase, playback offset, solo defeat, lane settings and pan law; MIX ones follow Local mixing.
mirror.TRACK_MORE = { { "fxen", "I_FXEN" }, { "nchan", "I_NCHAN" }, { "mainsend", "B_MAINSEND" }, { "msoffs", "C_MAINSEND_OFFS" },
  { "msnch", "C_MAINSEND_NCH" }, { "timebase", "C_BEATATTACHMODE" }, { "playoffs", "D_PLAY_OFFSET" }, { "playoffsflag", "I_PLAY_OFFSET_FLAG" },
  { "solodefeat", "B_SOLO_DEFEAT" }, { "lanesettings", "C_LANESETTINGS" }, { "panlaw", "D_PANLAW" }, { "panlawflags", "I_PANLAW_FLAGS" } }
mirror.TRACK_MIX = { { "width", "D_WIDTH" }, { "panmode", "I_PANMODE" }, { "dualpanl", "D_DUALPANL" }, { "dualpanr", "D_DUALPANR" } }

function mirror.track_line(t, local_mix, colour)
  local f = { t.name or "", t.parent or "", t.depth or 0, t.mute or 0, "", t.phase or 0, t.icon or "", -- ("": solo is each person's own)
    t.freemode or 0, t.lanes or 0, t.plays or "", t.lanenames or "", 0, local_mix and "" or (t.vol or ""), local_mix and "" or (t.pan or "") }
  for _, kp in ipairs(mirror.TRACK_MORE) do f[#f + 1] = t[kp[1]] or "" end
  for _, kp in ipairs(mirror.TRACK_MIX) do f[#f + 1] = local_mix and "" or (t[kp[1]] or "") end
  if colour == nil then colour = not mirror.own_colours() end
  if colour then f[#f + 1] = t.color or 0 end -- (left off, not blank, when it doesn't count: the line from before 0.36)
  for i, v in ipairs(f) do f[i] = tostring(v):gsub("|", "/") end
  return table.concat(f, "|")
end

-- The same settings? As track_line, but 0 and 0.0 are one number: a state read here has floats, and one from a bandmate's event can have
-- whole numbers. Read as different, a track that had only moved in the list was put back and suggested to its owner at every restart.
-- (The hash stays on track_line: changing what it reads would make every track look changed.) Pure.
function mirror.same_line(x, y, local_mix)
  local function plain(t) return (mirror.track_line(t, local_mix):gsub("(%d)%.0%f[|\0]", "%1")) end
  return plain(x) == plain(y)
end

-- What runs through each track: its folder's tracks, what it receives, the tracks a VCA fader on it leads, and what runs through
-- those. Tracks with nothing running through them aren't listed. Pure. tracks: { { oid, parent, recv, lead, follow } } (recv: its R- part;
-- lead, follow: the VCA groups it leads and follows, as bits). A VCA moves no follower's own fader, only how it sounds: a bus, as far
-- as anyone's claim goes.
function mirror.feeders(tracks)
  local direct = {}
  local function add(to, from) direct[to] = direct[to] or {}; direct[to][#direct[to] + 1] = from end
  for _, t in ipairs(tracks) do
    if (t.parent or "") ~= "" then add(t.parent, t.oid) end
    for src in (t.recv or ""):gmatch("AUXRECV (%S+)") do add(t.oid, src) end
    if (t.lead or 0) ~= 0 then
      for _, x in ipairs(tracks) do if x ~= t and (t.lead & (x.follow or 0)) ~= 0 then add(t.oid, x.oid) end end
    end
  end
  local all = {}
  for oid in pairs(direct) do
    local seen, list = { [oid] = true }, {}
    local function walk(x)
      for _, f in ipairs(direct[x] or {}) do
        if not seen[f] then seen[f] = true; list[#list + 1] = f; walk(f) end
      end
    end
    walk(oid)
    all[oid] = list
  end
  return all
end

-- "Mac's Keys, Guitar and Bee's Bass" from { { owner, name } }, in a fixed order. Pure.
function mirror.whose(list)
  local by, owners = {}, {}
  for _, x in ipairs(list) do
    if not by[x[1]] then by[x[1]] = {}; owners[#owners + 1] = x[1] end
    by[x[1]][#by[x[1]] + 1] = x[2]
  end
  table.sort(owners)
  local out = {}
  for _, o in ipairs(owners) do table.sort(by[o]); out[#out + 1] = o .. "'s " .. table.concat(by[o], ", ") end
  return table.concat(out, " and ")
end

-- An item without what a tempo change moves: where it sits, how long, and how fast. Pure.
local TEMPO_MOVES = { POSITION = true, LENGTH = true, PLAYRATE = true, SOFFS = true, SNAPOFFS = true, FADEIN = true, FADEOUT = true }
function mirror.sans_tempo(state)
  local out = {}
  for line in (state or ""):gmatch("[^\n]+") do
    if not TEMPO_MOVES[line:match("^%s*(%S+)") or ""] then out[#out + 1] = line end
  end
  return table.concat(out, "\n")
end

-- ---- REAPER side ------------------------------------------------------------------------------------------
-- Everything below talks to REAPER. Kept per project: SEC "<oid>" = "rev|hash|event id" (the newest revision
-- this machine holds, and the event it came in, which is what a put-back re-applies).
mirror.SEC = "BandSync.mirror"
local function ext(proj, key) return select(2, reaper.GetProjExtState(proj, mirror.SEC, key)) end
local function setext(proj, key, v) reaper.SetProjExtState(proj, mirror.SEC, key, v) end
-- rev|hash|event id|order ("order" = time .. user of that revision: equal revs are settled by it, the same way
-- on every machine)
function mirror.known(proj, oid)
  local rev, h, ev, order = ext(proj, oid):match("^(%d+)|([^|]*)|([^|]*)|?(.*)$")
  return tonumber(rev), h, ev, order
end
-- This machine's ids also live in a file beside the project (<project>.bandsync-ids.json): REAPER's GUID -> oid, and
-- what was last known of each oid. The project only keeps them once it's saved, so one reopened without its last
-- save (closed unsaved, a crash) saw its tracks and items as new and sent them again as copies (2026-10-30: Mirror
-- Test came back with every track twice). Untitled projects have no file.
local idc = {}
local function ids(proj)
  local fn
  for i = 0, math.huge do
    local p, f = reaper.EnumProjects(i)
    if not p or p == proj then fn = p and f or ""; break end
  end
  if fn == "" then return nil end
  local c = idc[proj]
  if not c or c.fn ~= fn then
    local path = (fn:gsub("\\", "/"):gsub("%.[Rr][Pp][Pp]$", "")) .. ".bandsync-ids.json"
    local d = require("band").read_json(path) or {}
    c = { fn = fn, path = path, guid = d.guid or {}, rec = d.rec or {} }
    idc[proj] = c
  end
  return c
end
function mirror.save_ids(proj)
  local c = idc[proj]
  if c and c.dirty then c.dirty = false; require("band").write_json(c.path, { guid = c.guid, rec = c.rec }) end
end

local function remember(proj, oid, rev, h, evid, order)
  local v = string.format("%d|%s|%s|%s", rev or 0, h or "", evid or "", order or "")
  setext(proj, oid, v)
  local c = ids(proj)
  if c and c.rec[oid] ~= v then c.rec[oid], c.dirty = v, true end
end
mirror.remember = remember

local function trk_oid(tr) return select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_oid", "", false)):upper() end
local function itm_oid(it) return select(2, reaper.GetSetMediaItemInfo_String(it, "P_EXT:band_oid", "", false)):upper() end
mirror.track_oid, mirror.item_oid = trk_oid, itm_oid
-- StudioSync's own helper tracks (the SonoBus return, stems) never mirror
local function local_track(tr) -- (also live placeholders and live MIDI views: each machine draws its own)
  return select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_local", "", false)) ~= ""
    or select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_live_track", "", false)) ~= ""
end
mirror.local_track = local_track

-- A track's travelling settings (see track_line).
function mirror.track_state(proj, tr, local_mix)
  local parent = reaper.GetParentTrack(tr)
  local t = { name = select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)), parent = parent and trk_oid(parent) or "",
    depth = reaper.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH"), mute = reaper.GetMediaTrackInfo_Value(tr, "B_MUTE"),
    solo = reaper.GetMediaTrackInfo_Value(tr, "I_SOLO"), phase = reaper.GetMediaTrackInfo_Value(tr, "B_PHASE"),
    color = require("band").color_out(require("band").track_colour(tr)), icon = select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_ICON", "", false)),
    autocolour = mirror.own_colours() or nil, freemode = reaper.GetMediaTrackInfo_Value(tr, "I_FREEMODE"), lanes = reaper.GetMediaTrackInfo_Value(tr, "I_NUMFIXEDLANES") } -- (not lanes collapsed: a view, each person's own. It was put back as a bandmate's edit: Mac, 0.42.5)
  local held_mute = select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_quiet", "", false)) -- (quiet only here, for now: lib/producer.lua)
  if held_mute ~= "" then t.mute = tonumber(held_mute) or 0 end
  local plays, names = {}, {}
  for l = 0, t.lanes - 1 do
    plays[#plays + 1] = math.floor(reaper.GetMediaTrackInfo_Value(tr, "C_LANEPLAYS:" .. l))
    names[#names + 1] = (select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_LANENAME:" .. l, "", false)):gsub(",", ";"))
  end
  t.plays, t.lanenames = table.concat(plays, ","), table.concat(names, ",")
  t.vol = string.format("%.6f", reaper.GetMediaTrackInfo_Value(tr, "D_VOL"))
  t.pan = string.format("%.4f", reaper.GetMediaTrackInfo_Value(tr, "D_PAN"))
  for _, list in ipairs({ mirror.TRACK_MORE, mirror.TRACK_MIX }) do
    for _, kp in ipairs(list) do t[kp[1]] = string.format("%.6g", reaper.GetMediaTrackInfo_Value(tr, kp[2])) end
  end
  local held = select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_fxen", "", false)) -- (lib/prints.lua hold_fx)
  if held ~= "" then t.fxen = string.format("%.6g", tonumber(held) or 1) end
  -- (the track above, so new tracks land in the same order)
  t.after = ""
  for i = math.floor(reaper.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER")) - 2, 0, -1 do -- (the nearest mirrored one above)
    local above = reaper.GetTrack(proj, i)
    if not local_track(above) then t.after = trk_oid(above); break end
  end
  return t
end

function mirror.set_track_state(proj, tr, t, local_mix)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", t.name or "", true)
  -- never fewer lanes than its items sit on: REAPER then says those items are on lane 255, and it went out as an edit, and every
  -- machine grew to 256 lanes (a Back to before the lanes, with items not yet gone: laptop and PC, 0.42.7)
  local in_use = 0
  if reaper.GetMediaTrackInfo_Value(tr, "I_FREEMODE") == 2 then
    for i = 0, reaper.CountTrackMediaItems(tr) - 1 do
      local lane = reaper.GetMediaItemInfo_Value(reaper.GetTrackMediaItem(tr, i), "I_FIXEDLANE")
      if lane < mirror.BAD_LANE then in_use = math.max(in_use, lane + 1) end
    end
  end
  for _, kp in ipairs({ { "freemode", "I_FREEMODE" }, { "lanes", "I_NUMFIXEDLANES" }, { "mute", "B_MUTE" },
      { "phase", "B_PHASE" }, { "depth", "I_FOLDERDEPTH" } }) do
    local v = t[kp[1]] and (tonumber(t[kp[1]]) or 0)
    if v and kp[1] == "lanes" then v = math.max(v, in_use) end
    if v and kp[1] == "freemode" and in_use > 1 then v = 2 end
    if v then reaper.SetMediaTrackInfo_Value(tr, kp[2], v) end
  end
  if t.color and not t.autocolour then require("band").set_track_colour(tr, require("band").color_in(t.color)) end
  reaper.GetSetMediaTrackInfo_String(tr, "P_ICON", t.icon or "", true)
  local l = 0
  for v in ((t.plays or "") .. ","):gmatch("([^,]*),") do
    if v ~= "" then reaper.SetMediaTrackInfo_Value(tr, "C_LANEPLAYS:" .. l, tonumber(v) or 0) end
    l = l + 1
  end
  l = 0
  for v in ((t.lanenames or "") .. ","):gmatch("([^,]*),") do
    if l < (tonumber(t.lanes) or 0) then reaper.GetSetMediaTrackInfo_String(tr, "P_LANENAME:" .. l, v, true) end
    l = l + 1
  end
  local held = select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_fxen", "", false)) ~= ""
  for _, kp in ipairs(mirror.TRACK_MORE) do
    if held and kp[1] == "fxen" and tonumber(t.fxen) then -- (held off here while a wet take plays: the band's goes in its place)
      reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_fxen", tostring(math.floor(tonumber(t.fxen))), true)
    elseif tonumber(t[kp[1]]) then reaper.SetMediaTrackInfo_Value(tr, kp[2], tonumber(t[kp[1]])) end -- (a sender without it: left)
  end
  if not local_mix then
    if t.vol and t.vol ~= "" then reaper.SetMediaTrackInfo_Value(tr, "D_VOL", tonumber(t.vol)) end
    if t.pan and t.pan ~= "" then reaper.SetMediaTrackInfo_Value(tr, "D_PAN", tonumber(t.pan)) end
    for _, kp in ipairs(mirror.TRACK_MIX) do
      if tonumber(t[kp[1]]) then reaper.SetMediaTrackInfo_Value(tr, kp[2], tonumber(t[kp[1]])) end
    end
  end
end

-- A lane number that makes sense: REAPER reads 255 for an item on a lane the track has lost. Pure.
mirror.BAD_LANE = 200
function mirror.clean_lane(lane, lanes)
  lane, lanes = math.floor(tonumber(lane) or 0), math.floor(tonumber(lanes) or 1)
  if lane >= mirror.BAD_LANE then return 0 end
  return lanes > 0 and math.min(lane, lanes - 1) or lane
end

-- An item's travelling state: its normalized chunk, plus its lane (REAPER keeps an item's fixed lane out of the
-- item's chunk, so it gets a line of its own).
function mirror.item_state(it, media_dir)
  local _, chunk = reaper.GetItemStateChunk(it, "", false)
  local st = mirror.memo("i\0" .. media_dir .. "\0" .. chunk, function() return mirror.tokenize_media(mirror.normalize_item(chunk), media_dir) end)
  local tr = reaper.GetMediaItem_Track(it)
  if reaper.GetMediaTrackInfo_Value(tr, "I_FREEMODE") == 2 then
    st = st .. "BANDLANE " .. mirror.clean_lane(reaper.GetMediaItemInfo_Value(it, "I_FIXEDLANE"), reaper.GetMediaTrackInfo_Value(tr, "I_NUMFIXEDLANES")) .. "\n"
  end
  return st
end

-- Every mirrored object in the project, with its normalized state and hash. Objects with no oid, or a copy that
-- carries another object's oid, get a fresh oid here (they are new). `media_dir`: the room's media folder.
-- Copies (Ctrl+drag, paste, duplicate track) carry their source's oid. Whichever of them REAPER's own GUID shows to
-- be the one this machine already knew keeps the oid, wherever it sits (a copy placed before its source must not take
-- it: the source would then look new and be put back); the others become new objects. Returns the oid per entry.
mirror.CSEC = "BandSync.colours" -- "colours" = "own" (SWS auto-colours tracks here) or "band": as of the last look
mirror.GSEC = "BandSync.mirrorg" -- oid -> REAPER GUID of the object holding it here (this machine's own)
local function settle_ids(proj, list, kind, user, set_oid)
  local keeper, matched, c, held = {}, {}, ids(proj), {}
  -- no oid, but this machine gave its GUID one before (the project wasn't saved since): it gets that oid back
  for _, x in ipairs(list) do if x.oid ~= "" then held[x.oid] = true end end
  for _, x in ipairs(list) do
    local was = x.oid == "" and c and c.guid[x.guid]
    if was and not held[was] then
      x.oid, x.restored, held[was] = was, true, true
      set_oid(x.ptr, was)
      for _, p in ipairs(kind == "T" and { "T", table.unpack(mirror.PARTS) } or { "I" }) do -- what this machine knew of it (and its parts)
        local oid = p .. was:sub(2)
        if c.rec[oid] and ext(proj, oid) == "" then setext(proj, oid, c.rec[oid]) end
      end
    end
  end
  for k, x in ipairs(list) do
    if x.oid ~= "" and not matched[x.oid] then
      local known = x.guid == select(2, reaper.GetProjExtState(proj, mirror.GSEC, x.oid))
      if not keeper[x.oid] or known then keeper[x.oid], matched[x.oid] = k, known end -- (the first that REAPER knows wins)
    end
  end
  for k, x in ipairs(list) do
    if x.oid == "" or keeper[x.oid] ~= k then
      -- (a track's copy says what it's a copy of, on the track: whichever script looks first gives it its oid. mirror.watch)
      if kind == "T" and x.oid ~= "" then reaper.GetSetMediaTrackInfo_String(x.ptr, "P_EXT:band_copy_of", x.oid, true) end
      x.oid = mirror.new_oid(kind, user); set_oid(x.ptr, x.oid)
    end
    if select(2, reaper.GetProjExtState(proj, mirror.GSEC, x.oid)) ~= x.guid then reaper.SetProjExtState(proj, mirror.GSEC, x.oid, x.guid) end
    if c and c.guid[x.guid] ~= x.oid then c.guid[x.guid], c.dirty = x.oid, true end
    if x.restored then
      mirror.reopened[tostring(proj) .. x.oid] = true
      if kind == "T" then for _, p in ipairs(mirror.PARTS) do mirror.reopened[tostring(proj) .. p .. x.oid:sub(2)] = true end end
    end
  end
end
-- oids given back after an unsaved reopen whose state here is older than the band's: put back, never sent, until they
-- match what this machine last knew (proj .. oid -> true)
mirror.reopened = {}
mirror.auto = {} -- proj .. oid -> its next send is a print StudioSync refreshed (Undo skips those)
mirror.unsent = {} -- proj .. oid -> changed here, not sent yet (settling, playing, Hold my changes): mirror.receive waits
mirror.anchor_seen = {} -- proj .. oid .. known hash -> its event was checked against what's here (see watch)
mirror.orphaned = {} -- proj -> { track oid = true }: changes skipped while that track was gone (sync.receive looks again)

function mirror.scan(proj, user, media_dir, local_mix)
  mirror.restless_load()
  local objs, by_oid, tracks = {}, {}, {}
  local tl = {}
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    if not local_track(tr) then
      tl[#tl + 1] = { ptr = tr, oid = trk_oid(tr), guid = select(2, reaper.GetSetMediaTrackInfo_String(tr, "GUID", "", false)) }
    end
  end
  settle_ids(proj, tl, "T", user, function(tr, oid) reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_oid", oid, true) end)
  local at = {} -- 0-based position -> oid, for receives
  for _, x in ipairs(tl) do at[math.floor(reaper.GetMediaTrackInfo_Value(x.ptr, "IP_TRACKNUMBER")) - 1] = x.oid end
  local function oid_at(i) return at[i] end
  local sig = {} -- (where each mirrored track sits: what the receives' track numbers mean, part of the memo's key)
  for i = 0, reaper.CountTracks(proj) - 1 do sig[#sig + 1] = at[i] or "-" end
  local at_sig = table.concat(sig, ",")
  for _, x in ipairs(tl) do
    local tr, oid = x.ptr, x.oid
    do
      local t = mirror.track_state(proj, tr, local_mix)
      local o = { kind = "track", oid = oid, ptr = tr, state = t, hash = mirror.track_hash(t, local_mix) }
      objs[#objs + 1], by_oid[oid], tracks[tr] = o, o, oid
      local _, chunk = reaper.GetTrackStateChunk(tr, "", false)
      local lfx = select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_local_fx", "", false))
      local parts = mirror.memo("t\0" .. at_sig .. "\0" .. restless_sig() .. "\0" .. lfx .. "\0" .. chunk, function()
        local skip = {} -- this machine's plug-in translations (lib/page_plugins.lua): never sent
        for g in lfx:gmatch("({[^}]+})for=") do skip[g] = true end
        local fx = mirror.fxchain(chunk, skip) or ""
        local env, recv, misc = mirror.track_parts(chunk, oid_at)
        return { fx = fx, fxh = mirror.fx_hash(fx), env = env, recv = recv, misc = misc }
      end)
      local fx = parts.fx
      local fo = { kind = "fx", oid = "F" .. oid:sub(2), ptr = tr, track = oid, state = fx, hash = parts.fxh }
      objs[#objs + 1], by_oid[fo.oid] = fo, fo
      local env, recv, misc = parts.env, parts.recv, parts.misc
      env = env .. mirror.ai_lines(tr)
      for _, p in ipairs({ { "E", "env", env }, { "R", "recv", recv }, { "M", "misc", misc } }) do
        local po = { kind = p[2], oid = p[1] .. oid:sub(2), ptr = tr, track = oid, state = p[3], hash = mirror.hash(p[3]) }
        objs[#objs + 1], by_oid[po.oid] = po, po
      end
    end
  end
  do -- the master (see mirror.MASTER)
    local master = reaper.GetMasterTrack(proj)
    local _, mch = reaper.GetTrackStateChunk(master, "", false)
    local mfx = mirror.fxchain(mch, mirror.live_fx(master)) or ""
    if mfx:match("^<FXCHAIN[^\n]*\n>%s*$") then mfx = "" end -- (only this computer's live mix on it: Real time mode read as "changed the plug-ins on the master")
    local menv = mirror.track_parts(mch, oid_at) .. mirror.ai_lines(master)
    for _, p in ipairs({ { "F-MASTER", "fx", mfx }, { "E-MASTER", "env", menv } }) do
      local po = { kind = p[2], oid = p[1], ptr = master, track = mirror.MASTER, state = p[3], hash = p[2] == "fx" and mirror.fx_hash(p[3]) or mirror.hash(p[3]) }
      objs[#objs + 1], by_oid[po.oid] = po, po
    end
    by_oid[mirror.MASTER] = { kind = "master", state = { name = "Master" } } -- (who may change it: as a track called Master)
  end
  local il = {}
  for i = 0, reaper.CountMediaItems(proj) - 1 do
    local it = reaper.GetMediaItem(proj, i)
    local toid = tracks[reaper.GetMediaItem_Track(it)]
    if toid and select(2, reaper.GetSetMediaItemInfo_String(it, "P_EXT:band_arriving", "", false)) == "" then -- (a stand-in: never sent)
      il[#il + 1] = { ptr = it, toid = toid, oid = itm_oid(it), guid = select(2, reaper.GetSetMediaItemInfo_String(it, "GUID", "", false)) }
    end
  end
  settle_ids(proj, il, "I", user, function(it, oid) reaper.GetSetMediaItemInfo_String(it, "P_EXT:band_oid", oid, true) end)
  for _, x in ipairs(il) do
    local norm = mirror.item_state(x.ptr, media_dir)
    local o = { kind = "item", oid = x.oid, ptr = x.ptr, track = x.toid, state = norm, hash = mirror.item_hash(x.toid, norm),
      pos = reaper.GetMediaItemInfo_Value(x.ptr, "D_POSITION") }
    objs[#objs + 1], by_oid[x.oid] = o, o
  end
  return objs, by_oid
end

-- Media an item uses from outside the room's media folder is copied in (once) so the band has it. Returns the
-- chunk with paths rewritten to the copies.
function mirror.share_media(chunk, media_dir, it)
  reaper.RecursiveCreateDirectory(media_dir, 0)
  local room = norm_path(media_dir):match("([^/]+)/media/?$") or "main"
  -- (any quote: a name with a " in it is written between ' or `, and REAPER then turns a ` inside it into ', so the
  -- path no longer names the file and the item's own source has to say. Missed, the item went out with a Mac path nobody
  -- else has, and REAPER stopped on "Replace missing file" reopening the song: Mac and laptop, 0.42.2)
  local function actual(path)
    if reaper.file_exists(path) or not it then return path end
    for k = 0, reaper.CountTakes(it) - 1 do
      local tk = reaper.GetTake(it, k)
      local src = tk and reaper.GetMediaItemTake_Source(tk)
      local f = src and reaper.GetMediaSourceFileName(src, "") or ""
      if f:gsub("`", "'") == path then return f end
    end
    return path
  end
  return (chunk:gsub('FILE (["\'`])(.-)%1', function(q, written)
    local a, z = "FILE " .. q, q
    if written:find("^{media") then return a .. written .. z end
    local path = actual(written)
    local name = path:gsub("\\", "/"):match("[^/]+$") or "media"
    -- (plain characters only: an accented name can reach a Mac decomposed and come back as other bytes than Windows
    -- wrote, and the item then reads as different on each machine)
    local copy = mirror.hash(path:lower()) .. "-" .. name:gsub("[^%w%-_.]", "_")
    local dst = media_dir .. "/" .. copy
    if not reaper.file_exists(dst) and reaper.file_exists(path) then
      local ok, err = pcall(require("band").copy_atomic, path, dst)
      if not ok then mirror.copy_failed = tostring(err) end -- (watch holds the item back and says so: mirror.local_files)
    end
    -- (only once the copy is really there: pointing at a copy that was never made left everyone waiting for it)
    if reaper.file_exists(dst) then return 'FILE "{media:' .. room .. "}/" .. copy .. '"' end
    return a .. written .. z
  end))
end

-- Find a track or item by oid.
-- The master track travels as two parts only, F-MASTER (its plug-ins) and E-MASTER (its automation): its fader and
-- pan are each person's listening level. ReaNINJAM and SonoBus on it are this machine's live link, never sent, and so
-- is StudioSync's live mix (lib/hear.lua: who you hear, and in whose time).
mirror.MASTER = "T-MASTER"
function mirror.live_fx(tr)
  local set = {}
  for i = 0, reaper.TrackFX_GetCount(tr) - 1 do
    local _, name = reaper.TrackFX_GetFXName(tr, i, "")
    if name:find("ReaNINJAM", 1, true) or name:find("SonoBus", 1, true) or name:find("StudioSync live mix", 1, true) or name:find("BandSync live mix", 1, true) then
      set[reaper.TrackFX_GetFXGUID(tr, i)] = true
    end
  end
  return set
end

-- While a receive pass runs (mirror.index_for), items are found through an index made once for the pass: looking
-- through every item for every change made catching up on a long song take minutes (review, 2026-10-31).
local index
function mirror.index_for(proj) index = proj and { proj = proj } or nil end
function mirror.find(proj, kind, oid)
  if oid == mirror.MASTER then return reaper.GetMasterTrack(proj) end
  if kind == "item" then
    if index and index.proj == proj then
      if not index.map then
        index.map = {}
        for i = 0, reaper.CountMediaItems(proj) - 1 do
          local it = reaper.GetMediaItem(proj, i)
          index.map[itm_oid(it)] = it
        end
      end
      local it = index.map[oid]
      if it and reaper.ValidatePtr2(proj, it, "MediaItem*") and itm_oid(it) == oid then return it end
    end
    for i = 0, reaper.CountMediaItems(proj) - 1 do
      local it = reaper.GetMediaItem(proj, i)
      if itm_oid(it) == oid then
        if index and index.map and index.proj == proj then index.map[oid] = it end
        return it
      end
    end
  else
    for i = 0, reaper.CountTracks(proj) - 1 do
      local tr = reaper.GetTrack(proj, i)
      if trk_oid(tr) == oid then return tr end
    end
  end
end

-- A track's automation items (on its own envelopes, not plug-in or send ones), as lines: "BANDAI <envelope> position
-- length offset rate baseline amplitude loop mute" and each point "BANDAIPT <envelope> <item> time value shape tension".
-- Their pools live outside the track, so each arrives as an item of its own (unpooled, like a MIDI copy).
local AI_KEYS = { "D_POSITION", "D_LENGTH", "D_STARTOFFS", "D_PLAYRATE", "D_BASELINE", "D_AMPLITUDE", "D_LOOPSRC", "D_MUTE" }
local function env_tag(env)
  local _, ch = reaper.GetEnvelopeStateChunk(env, "", false)
  local tag = ch:match("^%s*<(%S+)")
  return tag and tag ~= "PARMENV" and tag:sub(1, 3) ~= "AUX" and tag or nil
end
function mirror.ai_lines(tr)
  local out = {}
  for e = 0, reaper.CountTrackEnvelopes(tr) - 1 do
    local env = reaper.GetTrackEnvelope(tr, e)
    local n = reaper.CountAutomationItems(env)
    local tag = n > 0 and env_tag(env)
    for a = 0, tag and n - 1 or -1 do
      local v = {}
      for _, k in ipairs(AI_KEYS) do v[#v + 1] = string.format("%.10g", reaper.GetSetAutomationItemInfo(env, a, k, 0, false)) end
      out[#out + 1] = "BANDAI " .. tag .. " " .. table.concat(v, " ")
      for p = 0, reaper.CountEnvelopePointsEx(env, a) - 1 do
        local _, t, val, shape, ten = reaper.GetEnvelopePointEx(env, a, p)
        out[#out + 1] = string.format("BANDAIPT %s %d %.10g %.10g %d %.6g", tag, a, t, val, shape, ten)
      end
    end
  end
  return #out > 0 and (table.concat(out, "\n") .. "\n") or ""
end

-- Rebuild the automation items a travelling envelope part lists (the chunk splice left the track with none). Each
-- gets a pool of its own: one past the highest in the project.
function mirror.set_ai(proj, tr, state)
  if not state:find("BANDAI ", 1, true) then return end
  local pool = 0
  for t = -1, reaper.CountTracks(proj) - 1 do
    local track = t < 0 and reaper.GetMasterTrack(proj) or reaper.GetTrack(proj, t)
    for e = 0, reaper.CountTrackEnvelopes(track) - 1 do
      local env = reaper.GetTrackEnvelope(track, e)
      for a = 0, reaper.CountAutomationItems(env) - 1 do pool = math.max(pool, reaper.GetSetAutomationItemInfo(env, a, "D_POOL_ID", 0, false) + 1) end
    end
  end
  local made, count = {}, {}
  for line in state:gmatch("[^\n]+") do
    local tag, rest = line:match("^BANDAI (%S+) (.*)$")
    if tag then
      local v = {}
      for x in rest:gmatch("%S+") do v[#v + 1] = tonumber(x) end
      local env = reaper.GetTrackEnvelopeByChunkName(tr, "<" .. tag)
      local k = count[tag] or 0
      count[tag] = k + 1
      if env and v[2] then
        local a = reaper.InsertAutomationItem(env, pool, v[1], v[2])
        pool = pool + 1
        for i = 3, #AI_KEYS do if v[i] then reaper.GetSetAutomationItemInfo(env, a, AI_KEYS[i], v[i], true) end end
        made[tag .. " " .. k] = { env, a }
      end
    else
      local ptag, k, t, val, shape, ten = line:match("^BANDAIPT (%S+) (%d+) (%S+) (%S+) (%S+) (%S+)$")
      local m = ptag and made[ptag .. " " .. k]
      if m then reaper.InsertEnvelopePointEx(m[1], m[2], tonumber(t), tonumber(val), tonumber(shape), tonumber(ten), false, true) end
    end
  end
  for _, m in pairs(made) do reaper.Envelope_SortPointsEx(m[1], m[2]) end
end

-- A stand-in for a bandmate's item whose audio is still arriving: an empty grey item at its place and length (and
-- lane), named for what it is, holding the item's oid so the real one replaces it. Never sent (mirror.scan skips it).
function mirror.placeholder(tr, oid, state, track_name)
  local it = reaper.AddMediaItemToTrack(tr)
  reaper.SetMediaItemInfo_Value(it, "D_POSITION", tonumber(state:match("\nPOSITION ([%d%.%-e]+)")) or 0)
  reaper.SetMediaItemInfo_Value(it, "D_LENGTH", tonumber(state:match("\nLENGTH ([%d%.%-e]+)")) or 1)
  local lane = tonumber(state:match("BANDLANE (%d+)"))
  if lane then reaper.SetMediaItemInfo_Value(it, "I_FIXEDLANE", lane < mirror.BAD_LANE and lane or 0) end
  reaper.SetMediaItemInfo_Value(it, "I_CUSTOMCOLOR", reaper.ColorToNative(90, 90, 90) | 0x1000000)
  reaper.GetSetMediaItemInfo_String(it, "P_NOTES", "arriving: " .. ((state:match("\nNAME ([^\n]+)") or ""):gsub('^"(.*)"$', "%1")) ..
    " (" .. (track_name or "") .. "), still syncing", true)
  reaper.GetSetMediaItemInfo_String(it, "P_EXT:band_arriving", "1", true)
  reaper.GetSetMediaItemInfo_String(it, "P_EXT:band_oid", oid, true)
  reaper.UpdateItemInProject(it)
end

-- Apply one revision (an "obj" event) here. Returns true when done, false to try again later (its track or its
-- media hasn't arrived yet), and the hash now held.
-- (through JSON, as an event's was: REAPER's 0.0 reads back as 0)
local function band_json(t) local band = require("band"); return band.json_decode(band.json_encode(t)) end
function mirror.apply(proj, ev, media_dir, local_mix)
  if ev.obj == "track" then mirror.order_band[tostring(proj)] = true end
  local kind, oid = ev.obj, ev.oid
  if ev.gone then
    local p = mirror.find(proj, kind == "fx" and "track" or kind, kind == "fx" and ev.track or oid)
    if p and kind == "item" then reaper.DeleteTrackMediaItem(reaper.GetMediaItem_Track(p), p)
    elseif p and kind == "track" then -- (auto-colour rules recolour the rest when a track goes: theirs are the band's)
      local colours = mirror.track_colours(proj)
      reaper.DeleteTrack(p)
      mirror.hold_colours(proj, colours)
    end
    return true, ""
  end
  if kind == "track" then
    local tr = mirror.find(proj, "track", oid)
    if not tr then
      local idx = 0 -- under the track it sat under there (or first)
      local above = ev.state.after ~= "" and mirror.find(proj, "track", ev.state.after)
      if above then idx = math.floor(reaper.GetMediaTrackInfo_Value(above, "IP_TRACKNUMBER")) end
      local colours = mirror.track_colours(proj) -- (auto-colour rules recolour the other tracks when one goes in: theirs are the band's)
      reaper.InsertTrackInProject(proj, idx, 0) -- (InsertTrackAtIndex only knows the tab in front; REAPER 7.18+)
      mirror.hold_colours(proj, colours)
      tr = reaper.GetTrack(proj, idx)
      reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_oid", oid, true)
    end
    mirror.set_track_state(proj, tr, ev.state, local_mix)
    -- moved in the band's project: here too (REAPER reorders only in the tab in front; a tab behind keeps its order)
    if mirror.track_state(proj, tr, local_mix).after ~= ev.state.after and reaper.EnumProjects(-1) == proj then
      local above = ev.state.after ~= "" and mirror.find(proj, "track", ev.state.after)
      if above or ev.state.after == "" then
        local sel = {}
        for i = 0, reaper.CountSelectedTracks(proj) - 1 do sel[#sel + 1] = reaper.GetSelectedTrack(proj, i) end
        reaper.SetOnlyTrackSelected(tr)
        reaper.ReorderSelectedTracks(above and math.floor(reaper.GetMediaTrackInfo_Value(above, "IP_TRACKNUMBER")) or 0, 0)
        reaper.SetOnlyTrackSelected(tr); reaper.SetTrackSelected(tr, false)
        for _, x in ipairs(sel) do if reaper.ValidatePtr2(proj, x, "MediaTrack*") then reaper.SetTrackSelected(x, true) end end
      end
    end
    local t = mirror.track_state(proj, tr, local_mix)
    -- (landed, only its place in this machine's list can differ: the band's hash stands, so fingerprints agree, and it isn't
    -- "came out different". Track order can differ: PC Fight, laptop, 0.42.3)
    local h = mirror.track_hash(t, local_mix)
    if ev.hash and h ~= ev.hash and type(ev.state) == "table" and mirror.same_line(t, ev.state, local_mix) then h = ev.hash end
    return true, h
  elseif kind == "fx" then
    local tr = mirror.find(proj, "track", ev.track)
    if not tr then return false end
    if reaper.GetPlayStateEx(proj) ~= 0 then return false end -- replacing a chain reloads plug-ins: only while stopped
    if reaper.EnumProjects(-1) ~= proj then return false end -- (see below: a track chunk waits for its tab to be in front)
    require("fxfiles").fetch(ev.files, media_dir, (ev.name or "") ~= "" and ev.name or "a track") -- (before the plug-ins load)
    local _, chunk = reaper.GetTrackStateChunk(tr, "", false)
    local sync = require("sync")
    local block = (ev.state or ""):gsub("\n$", "")
    if ev.track == mirror.MASTER then -- (this machine's ReaNINJAM / SonoBus stay on its master, at the end of the chain)
      local live = mirror.fx_blocks(chunk, mirror.live_fx(tr))
      -- (without its id: REAPER gives the incoming plug-ins, which travel without ids, the ids of the old chain by
      -- position, so the live link's own id would land on the band's first plug-in too; it's found by name anyway)
      for i = #live, 1, -1 do if live[i]:match("^FXID ") then table.remove(live, i) end end
      if #live > 0 then
        block = block ~= "" and block:gsub("\n>$", "\n" .. table.concat(live, "\n") .. "\n>") or ("<FXCHAIN\n" .. table.concat(live, "\n") .. "\n>")
      end
    end
    local new = sync.chunk_set_block(chunk, "FXCHAIN", block ~= "" and block or nil)
    if new and new ~= chunk then reaper.SetTrackStateChunk(tr, new, false) end
    -- the band's chain replaced this machine's translations too: put them back (they're never part of the hash)
    if select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_local_fx", "", false)) ~= "" then
      reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_local_fx", "", true)
      local cfg = require("band").settings()
      if cfg then pcall(require("page_plugins").apply_here, proj, cfg) end
    end
    local _, after = reaper.GetTrackStateChunk(tr, "", false)
    local skip = ev.track == mirror.MASTER and mirror.live_fx(tr) or {}
    for g in select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_local_fx", "", false)):gmatch("({[^}]+})for=") do skip[g] = true end
    mirror.fx_knobs[tostring(proj) .. ev.oid] = nil -- (its knobs are the band's now: the next look notes them)
    local here = mirror.fxchain(after, skip) or ""
    local h = mirror.fx_hash(here)
    local key = tostring(proj) .. ev.oid
    -- the band's hash stands, whatever a plug-in that loads here makes of its own saved data: read back, it differs from
    -- what was sent (Superior Drummer on the laptop), so fingerprints never agreed and whoever claimed the track re-rendered
    -- every part. What it reads as here, and for a while as it finishes loading, isn't a change.
    mirror.fx_readback[key], mirror.fx_loading[key], mirror.fx_load_knobs[key] = h, reaper.time_precise() + mirror.FX_LOAD_SECS, mirror.fx_params(tr)
    mirror.fx_quiet[key] = mirror.fx_load_knobs[key]
    if ev.hash then h = ev.hash end
    -- (a part that arrived before its plug-ins chose its take with nothing missing, and stayed on silent notes: laptop, 0.42.4)
    local prints = require("prints")
    for i = 0, reaper.CountTrackMediaItems(tr) - 1 do pcall(prints.choose, reaper.GetTrackMediaItem(tr, i)) end
    return true, h
  elseif kind == "env" or kind == "recv" or kind == "misc" then
    local tr = mirror.find(proj, "track", ev.track)
    if not tr then return false end
    if reaper.GetPlayStateEx(proj) & 4 == 4 then return false end -- (a track chunk isn't rewritten mid-recording)
    -- a track chunk written in a tab that isn't in front breaks that project's sends (REAPER reads the receives'
    -- track positions against the tab in front; measured 7.83: "source sends 0"): it waits until this tab is in front
    if reaper.EnumProjects(-1) ~= proj then return false end
    local at, pos = {}, {}
    for i = 0, reaper.CountTracks(proj) - 1 do
      local t = reaper.GetTrack(proj, i)
      local o = not local_track(t) and trk_oid(t) or ""
      if o ~= "" then at[i], pos[o] = o, i end
    end
    local function oid_at(i) return at[i] end
    local _, chunk = reaper.GetTrackStateChunk(tr, "", false)
    local new = mirror.splice_parts(chunk, kind, ev.state or "", function(o) return pos[o] end, oid_at)
    if not new then return false end -- a receive's source track hasn't arrived yet
    if new ~= chunk then reaper.SetTrackStateChunk(tr, new, false) end
    if kind == "misc" then -- note names: through the API (see splice_parts)
      local have, want = mirror.note_names(chunk), mirror.note_names(ev.state or "")
      for k in pairs(have) do if not want[k] then local c, n = k:match("^(%S+) (%S+)$"); reaper.SetTrackMIDINoteNameEx(proj, tr, tonumber(n), tonumber(c), "") end end
      for k, name in pairs(want) do
        if have[k] ~= name then local c, n = k:match("^(%S+) (%S+)$"); reaper.SetTrackMIDINoteNameEx(proj, tr, tonumber(n), tonumber(c), name) end
      end
    end
    local _, after = reaper.GetTrackStateChunk(tr, "", false)
    local env, recv, misc = mirror.track_parts(after, oid_at)
    if kind == "env" then mirror.set_ai(proj, tr, ev.state or ""); env = env .. mirror.ai_lines(tr) end
    return true, mirror.hash(kind == "env" and env or kind == "recv" and recv or misc)
  elseif kind == "item" then
    local tr = mirror.find(proj, "track", ev.track)
    if not tr then return false end
    for _, path in ipairs(mirror.media_needed(ev.state, media_dir)) do
      if not reaper.file_exists(path) then -- still on its way: a grey stand-in shows where it goes until it lands
        if not mirror.find(proj, "item", oid) then mirror.placeholder(tr, oid, ev.state, ev.name) end
        return false
      end
    end
    local it = mirror.find(proj, "item", oid)
    -- (an item with Melodyne / ARA on a take isn't rebuilt in place from a chunk without take ids: REAPER kept one
    -- take of two (measured 7.83). A fresh item takes it whole.)
    if it and require("prints").ara_take(it) then reaper.DeleteTrackMediaItem(reaper.GetMediaItem_Track(it), it); it = nil end
    if not it then it = reaper.AddMediaItemToTrack(tr)
    elseif reaper.GetMediaItem_Track(it) ~= tr then reaper.MoveMediaItemToTrack(it, tr) end
    local sel = reaper.IsMediaItemSelected(it)
    -- (which take plays is each person's own and isn't in what travels: setting the chunk put it back to the first,
    -- so an audio comp lost its pick on every update from the band: review, 2026-10-31)
    local active = reaper.CountTakes(it) > 1 and reaper.GetMediaItemInfo_Value(it, "I_CURTAKE")
    local lane = tonumber(ev.state:match("BANDLANE (%d+)"))
    reaper.SetItemStateChunk(it, mirror.resolve_media((ev.state:gsub("BANDLANE %d+\n?", "")), media_dir), false)
    reaper.GetSetMediaItemInfo_String(it, "P_EXT:band_oid", oid, true)
    if active and active < reaper.CountTakes(it) then reaper.SetMediaItemInfo_Value(it, "I_CURTAKE", active) end
    if lane then reaper.SetMediaItemInfo_Value(it, "I_FIXEDLANE", lane < mirror.BAD_LANE and lane or 0) end -- (events from 0.42.7 hold 255)
    require("prints").choose(it) -- notes or the print, as this machine chose (never part of what travels)
    reaper.SetMediaItemSelected(it, sel)
    reaper.UpdateItemInProject(it)
    return true, mirror.item_hash(ev.track, mirror.item_state(it, media_dir))
  end
  return true, ""
end

-- Does revision (rev, order) beat what this machine holds for oid?
function mirror.wins(proj, oid, rev, order)
  local krev, _, _, korder = mirror.known(proj, oid)
  return mirror.newer({ rev = rev, time = order }, krev and { rev = krev, time = korder } or nil)
end

-- An incoming "obj" event (from sync.apply). Returns true when handled (applied or older than what we hold).
function mirror.receive(proj, ev, media_dir, local_mix, me)
  if ev.obj == "fx" and ev.restless then mirror.restless_load(); mirror.restless_add(ev.restless) end
  local order = (ev.time or "") .. (ev.user or "")
  if not mirror.wins(proj, ev.oid, ev.rev or 0, order) then return true end
  -- a change of ours to it hasn't gone out yet (Hold my changes is on, plug-ins and automation waiting to settle or
  -- for playback to stop, a long edit): theirs waits until ours has gone, then the two are settled like any clash.
  -- Applied at once, ours was lost with no trace, not even on the Restore page (review, 2026-10-31).
  -- (watch marks those: comparing hashes here also caught what applying the band's last change had changed as a
  -- side effect, like a frozen track's items, and held it back for good)
  if mirror.unsent[tostring(proj) .. ev.oid] then return false end
  -- (on a track the band has deleted since: nothing to apply it to, ever. Waiting for it kept "still to come" above
  -- 0 for good: review, 2026-10-31)
  if ev.obj ~= "track" and ev.track and ev.track ~= mirror.MASTER then
    local trev, th = mirror.known(proj, ev.track)
    if trev and th == "" and not mirror.find(proj, "track", ev.track) then
      -- (unless the track comes back later in the same download: its return may still be on its way, so the room is
      -- looked over once its changes have all landed; sync.receive. Laptop, 0.34.8: a fresh song lost Keys' items)
      local o = mirror.orphaned[tostring(proj)] or {}
      o[ev.track] = true
      mirror.orphaned[tostring(proj)] = o
      return true
    end
  end
  -- both changed it while apart: theirs wins everywhere (the same on every machine); ours stays in History
  local krev, _, kev = mirror.known(proj, ev.oid)
  if me and krev and ev.base and ev.base < krev and kev:sub(1, #me + 1):upper() == (me:gsub(" ", "_") .. "-"):upper() then
    -- (within seconds of each other it was a race, not time apart: "while you were apart" read wrong, laptop round 2)
    local function secs(y, mo, d, h, mi, s) return y and os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = s }) end
    local mine = secs(kev:match("%-(%d%d%d%d)(%d%d)(%d%d)%-(%d%d)(%d%d)(%d%d)Z"))
    local theirs = secs((ev.time or ""):match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)"))
    local race = mine and theirs and math.abs(mine - theirs) <= 10
    require("sync").put_back(string.format("%s also changed %s %s: theirs is in.", tostring(ev.user), (ev.name or "") ~= "" and ("something on " .. ev.name) or "the same thing",
      race and "at the same moment as you" or "while you were apart"), { oid = ev.oid, ev = kev, name = ev.name })
  end
  local midiview = ev.obj == "item" and not ev.gone and require("midiview")
  if midiview and not (midiview.on() and midiview.recent(ev.time)) then midiview = nil end
  local notes_before = midiview and midiview.notes(mirror.find(proj, "item", ev.oid))
  local ok, h = mirror.apply(proj, ev, media_dir, local_mix)
  if ok then remember(proj, ev.oid, ev.rev, h, ev.id, order) end
  if ok and ev.obj == "item" then require("sync").landed_media = true end -- (Live sync builds its peaks, if nothing else will)
  if ok and midiview then midiview.show(proj, mirror.find(proj, "item", ev.oid), notes_before) end
  -- applied, but it isn't what they have: the projects differ (only when made the same way: a change from an older
  -- StudioSync hashed fewer of a track's settings, so it always reads as different; the laptop saw 4 on its first open)
  -- (nor when the colour counts on one machine and not the other: SWS auto-colouring)
  local same_way = ev.obj ~= "track" or type(ev.state) ~= "table" or (ev.state.autocolour == true) == (mirror.own_colours() == true)
  if ok and ev.hash and ev.hv == mirror.HV and same_way and h ~= ev.hash and not ev.gone then
    local band = require("band")
    local n = (tonumber(reaper.GetExtState(band.SECTION, "mirror drift " .. tostring(proj))) or 0) + 1
    reaper.SetExtState(band.SECTION, "mirror drift " .. tostring(proj), tostring(n), false)
    reaper.SetExtState(band.SECTION, "mirror drift last", ev.oid .. " here " .. tostring(h) .. " theirs " .. ev.hash, false) -- (for a bug report)
    local where = (ev.name or "") ~= "" and ev.name or "an unnamed track"
    band.log(string.format("%s's change to %s came out different here than on their machine (the panel's Health shows it)", tostring(ev.user),
      mirror.PART[ev.obj] and (mirror.PART[ev.obj] .. " on " .. where) or ev.obj == "track" and ("track " .. where) or ("an item on " .. where)))
  end
  if ok and ev.obj == "item" and ev.track then
    local tr = mirror.find(proj, "track", ev.track)
    local krev, _, kev, kord = mirror.known(proj, ev.track)
    if tr and krev then
      -- an item landing in a lane resets which lanes play: the track's own settings go back on top
      local tev = kev ~= "" and require("band").read_json(media_dir:gsub("/media$", "") .. "/events/" .. kev .. ".json")
      if type(tev) == "table" and type(tev.state) == "table" then mirror.set_track_state(proj, tr, tev.state, local_mix) end
      local t = mirror.track_state(proj, tr, local_mix)
      remember(proj, ev.track, krev, mirror.track_hash(t, local_mix), kev, kord)
    end
  end
  return ok
end

-- (a side room starts as a copy: what hasn't changed in it last changed in the room it came from. Looked for only here, a chain
-- that merely reads differently on this machine went out as a change, and opening a room printed 16 parts again: Mac, 0.42.27)
local room_parent = {}
local function event_file(room_dir, evid)
  if not evid or evid == "" then return nil end
  local band = require("band")
  local ev = band.read_json(room_dir .. "/events/" .. evid .. ".json")
  if ev then return ev end
  room_parent[room_dir] = room_parent[room_dir] or (band.read_json(room_dir .. "/room.json") or {}).parent -- (it may not have synced here yet: not noted as none)
  return room_parent[room_dir] and event_file((room_dir:gsub("[^/]+$", room_parent[room_dir])), evid) or nil
end
mirror.event_file = event_file

-- The name permissions use for an object (claims are by track name): its track's name.
local function perm_name(o, by_oid)
  if o.kind == "track" then return o.state.name end
  local t = by_oid[o.track]
  return t and t.state.name or ""
end

mirror.said = mirror.said or {} -- (things said once per session, not every pass)
mirror.fx_seen = mirror.fx_seen or {} -- oid -> { hash, since }: a plug-in chain goes out once it has settled
mirror.fx_knobs = mirror.fx_knobs or {} -- oid -> its knobs when it last went out or landed (chains with a restless plug-in)
mirror.fx_alias = mirror.fx_alias or {} -- chain hash and event id -> the event's hash, if the two are the same bytes (else false)
mirror.track_alias = mirror.track_alias or {} -- track hash and event id -> the event's hash, if only the place differs (else false)
mirror.FX_LOAD_SECS = 60 -- how long after landing or opening a chain's data may change by itself, with its knobs still
mirror.fx_readback = mirror.fx_readback or {} -- chain -> what its hash reads as here, now the band's has landed
mirror.fx_loading = mirror.fx_loading or {} -- chain -> until when it may be still loading
mirror.fx_load_knobs = mirror.fx_load_knobs or {} -- chain -> its knobs at the start of that
-- When each track last had a plug-in window open, looked at once a second: a change inside a plug-in's own window often moves no knob.
mirror.fx_open_at = {}
mirror.cc_seen = {}
mirror.fx_quiet = mirror.fx_quiet or {}
function mirror.note_open_fx(proj)
  local now = reaper.time_precise()
  for t = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, t)
    local open = reaper.TrackFX_GetChainVisible(tr) ~= -1
    for i = 0, reaper.TrackFX_GetCount(tr) - 1 do open = open or reaper.TrackFX_GetOpen(tr, i) end
    if open then mirror.fx_open_at[tostring(tr)] = now end
  end
end
function mirror.fx_was_open(tr)
  local open = reaper.TrackFX_GetChainVisible(tr) ~= -1
  for i = 0, reaper.TrackFX_GetCount(tr) - 1 do open = open or reaper.TrackFX_GetOpen(tr, i) end
  return open or reaper.time_precise() - (mirror.fx_open_at[tostring(tr)] or -math.huge) < 60
end
mirror.first_look = mirror.first_look or {} -- project -> until when its chains may be still loading after it opened
mirror.order_seen = mirror.order_seen or {} -- project -> its tracks' order at the last look
mirror.order_band = mirror.order_band or {} -- project -> a band's track landed since the last look
mirror.holds = mirror.holds or {} -- project -> track oid -> { what runs through it }, as of the last look
mirror.bus_said = mirror.bus_said or {} -- track oid -> when "that changes how X sounds" was last said
mirror.tempo_until = mirror.tempo_until or {} -- project -> until when items may be moving for a tempo change
mirror.TEMPO_SECS = 15
function mirror.tempo_changed(proj) mirror.tempo_until[tostring(proj)] = reaper.time_precise() + mirror.TEMPO_SECS end

-- Where a recording this person wasn't allowed to add goes (kept, never deleted): a track of their own, not sent.
local function keep_track(proj, name)
  local label = (name ~= "" and name or "Track") .. " (yours, not sent)"
  for t = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, t)
    if select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)) == label and local_track(tr) then return tr end
  end
  return mirror.add_local_track(proj, label, "yours") -- (auto-colouring recoloured Keys when this track went in, on the laptop: 2026-10-31)
end
-- A track of this machine's own (never mirrored) at the end, with the band's colours held.
function mirror.add_local_track(proj, name, tag)
  local colours = mirror.track_colours(proj)
  local idx = reaper.CountTracks(proj)
  reaper.InsertTrackInProject(proj, idx, 0)
  local tr = reaper.GetTrack(proj, idx)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", name, true)
  reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_local", tag, true)
  mirror.hold_colours(proj, colours)
  return tr
end
-- The band's track colours (by REAPER GUID), as they are before a track goes in or out: auto-colour rules recolour
-- the rest then, and again a moment later, so mirror.hold_colours puts them back for 5 s. The hold is kept in
-- ExtState: the panel adds tracks too (Real time mode's), and only Live sync's look runs often enough to hold them.
function mirror.track_colours(proj)
  local c = {}
  for t = 0, reaper.CountTracks(proj) - 1 do local x = reaper.GetTrack(proj, t); c[reaper.GetTrackGUID(x)] = reaper.GetMediaTrackInfo_Value(x, "I_CUSTOMCOLOR") end
  return c
end
function mirror.hold_colours(proj, colours)
  local band = require("band")
  if proj then
    reaper.SetExtState(band.SECTION, "colour hold", band.json_encode({ proj = tostring(proj), till = reaper.time_precise() + 5, colours = colours }), false)
  end
  local k = band.json_decode(reaper.GetExtState(band.SECTION, "colour hold"))
  if not k then return end
  if reaper.time_precise() > (tonumber(k.till) or 0) then return reaper.DeleteExtState(band.SECTION, "colour hold", false) end
  for i = 0, 512 do
    local p = reaper.EnumProjects(i)
    if not p then break end
    if tostring(p) == k.proj then
      for t = 0, reaper.CountTracks(p) - 1 do
        local x = reaper.GetTrack(p, t)
        local c = k.colours[reaper.GetTrackGUID(x)]
        if c and reaper.GetMediaTrackInfo_Value(x, "I_CUSTOMCOLOR") ~= c then reaper.SetMediaTrackInfo_Value(x, "I_CUSTOMCOLOR", c) end
      end
    end
  end
end

-- One pass: what changed here goes out if this person may change it, else the band's version is put back.
-- opts: local_mix, can (sync.authority's), mode (room mode). Returns sent, put back.
function mirror.watch(proj, cfg, song, room, opts)
  local band, sync = require("band"), require("sync")
  if reaper.JS_Mouse_GetState and reaper.JS_Mouse_GetState(1) & 1 == 1 then return 0, 0 end -- mid-drag: wait for the drop
  mirror.hold_colours()
  local room_dir = sync.room_dir(cfg, song, room)
  local media = room_dir .. "/media"
  local objs, by_oid = mirror.scan(proj, cfg.user, media, opts.local_mix)
  local me, sent, back = cfg.user, 0, 0
  mirror.unsettled = false
  local suggest = require("suggest")
  -- { owner, name } for the tracks in `oids` (by name, as of `names`) that someone else has claimed, out of this person's reach
  local function others_claims(oids, names)
    local list = {}
    for _, oid in ipairs(oids) do
      local name = names(oid)
      if name and name ~= "" and sync.is_claimed and sync.is_claimed(name) and not opts.can(me, name) then
        list[#list + 1] = { sync.owner_of(name), name }
      end
    end
    return list
  end
  -- A folder or bus holding a bandmate's claimed part isn't deleted (James, 2026-11-02): their part would lose its routing
  -- with no say of theirs. Before anything else is looked at: its folder's tracks read as changed now, and would go out.
  local kept_back, holds = {}, mirror.holds[tostring(proj)] or {}
  for oid, held in pairs(holds) do
    local rev, h = mirror.known(proj, oid)
    if not by_oid[oid] and rev and h ~= "" and not opts.hold then
      local theirs = others_claims(held.oids, function(x) return held.names[x] end)
      if #theirs > 0 then
        if reaper.EnumProjects(-1) ~= proj or reaper.GetPlayStateEx(proj) ~= 0 then return 0, 0 end -- (a chain only comes back in front, stopped)
        -- (REAPER's Remove tracks takes a folder's tracks with it, so they come back too, parts and all. One still here only
        -- needs its folder setting back)
        local function bring(x)
          local _, _, evid, order = mirror.known(proj, x)
          local ev = event_file(room_dir, evid)
          if ev and not ev.gone then
            local ok, hash = mirror.apply(proj, ev, media, opts.local_mix)
            if ok then remember(proj, x, ev.rev, hash, ev.id, order) end
          end
        end
        local tracks = { oid, table.unpack(held.oids) }
        for _, x in ipairs(tracks) do
          local was_gone = not by_oid[x]
          bring(x)
          if was_gone then
            kept_back[x] = true
            for _, p in ipairs(mirror.PARTS) do bring(p .. x:sub(2)) end
          end
        end
        sync.put_back(string.format("%s holds %s: it's back, as deleting it would take them out of it. Ask them to move out of it first",
          held.name ~= "" and held.name or "That track", mirror.whose(theirs)))
        back = back + 1
      end
    end
  end
  if next(kept_back) then objs, by_oid = mirror.scan(proj, me, media, opts.local_mix) end
  -- A copy of a part someone else has claimed goes out as yours, under a name of its own, and says whose it was: claims go by
  -- name, so as a second "Keys" it would be theirs, and refused.
  local credit = {}
  for _, o in ipairs(objs) do
    local from = o.kind == "track" and select(2, reaper.GetSetMediaTrackInfo_String(o.ptr, "P_EXT:band_copy_of", "", false)) or ""
    if from ~= "" and not opts.hold then
      reaper.GetSetMediaTrackInfo_String(o.ptr, "P_EXT:band_copy_of", "", true)
      local name = o.state.name
      if opts.mode ~= "driver" and sync.is_claimed and sync.is_claimed(name) and not opts.can(me, name) then
        local who, label, n = sync.owner_of(name), name .. " (" .. me .. "'s copy)", 1
        local function taken(x)
          for _, t in ipairs(objs) do if t.kind == "track" and t ~= o and t.state.name == x then return true end end
        end
        while taken(label) do n = n + 1; label = string.format("%s (%s's copy %d)", name, me, n) end
        reaper.GetSetMediaTrackInfo_String(o.ptr, "P_NAME", label, true)
        o.state.name = label
        o.hash = mirror.track_hash(o.state, opts.local_mix)
        credit[o.oid] = string.format("%s copied %s's %s as '%s'. The original isn't touched", me, who, name, label)
        band.log(credit[o.oid])
      end
    end
  end
  -- Says so when what changes on a bus, a folder or the master changes how a bandmate's claimed part sounds. Nothing's
  -- refused for that: the part itself isn't touched. Once a minute per track at most, or a fader dragged about says it each time.
  local function bus_note(o, name, last)
    local at = o.kind == "track" and o.oid or o.track
    local what = o.kind == "fx" and "the plug-ins on" or o.kind == "env" and "the automation on"
    if o.kind == "track" and last and type(last.state) == "table" then
      for _, f in ipairs({ "vol", "pan", "mute", "fxen", "phase", "width" }) do
        if tostring(o.state[f]) ~= tostring(last.state[f]) then what = "the fader, pan or mute of" end
      end
    end
    if not what or reaper.time_precise() - (mirror.bus_said[at] or -60) < 60 then return nil end
    local oids
    if at == mirror.MASTER then
      oids = {}
      for _, t in ipairs(objs) do if t.kind == "track" then oids[#oids + 1] = t.oid end end
    else oids = (holds[at] or {}).oids or {} end
    local theirs = others_claims(oids, function(x) return by_oid[x] and by_oid[x].state.name end)
    if #theirs == 0 then return nil end
    mirror.bus_said[at] = reaper.time_precise()
    return string.format("%s changed %s %s: that changes how %s sound", me, what, at == mirror.MASTER and "the master" or name, mirror.whose(theirs))
  end
  -- Did this person move a track? A track's place is the track above it, so anything that lands above it reads as a change
  -- of it. Sent, that came back round: a bandmate's track put back moved this one, it went out, and they moved in turn,
  -- every 2 s for good (laptop, undoing bandmates' new tracks, 0.42.3). So a track that differs only by its place is a
  -- change only on the look where the list has changed and nothing from the band landed since the last look.
  local order_key, order = tostring(proj), {}
  do -- (a file opened again in the same tab keeps the tab's address, and Live sync runs on through it: its tracks are all new. Then it's a first look.
    -- Deleting the first track reads the same: a first look does no harm)
    local had = mirror.cc_seen[order_key]
    if had and not reaper.ValidatePtr2(proj, had, "MediaTrack*") then mirror.order_seen[order_key] = nil; sync.timeline_looked[proj] = nil end
    mirror.cc_seen[order_key] = reaper.GetTrack(proj, 0)
  end
  for _, o in ipairs(objs) do if o.kind == "track" then order[#order + 1] = o.oid end end
  order = table.concat(order, ",")
  local moved_here = mirror.order_seen[order_key] ~= nil and mirror.order_seen[order_key] ~= order and not mirror.order_band[order_key]
  -- (by track, not "the list changed": a track added at the end sent or put back every track whose place differs here: Mac, 0.42.9)
  local moved_set = {}
  if moved_here then
    local function split(text) local t = {}; for x in text:gmatch("[^,]+") do t[#t + 1] = x end; return t end
    local selected = {}
    for _, o in ipairs(objs) do if o.kind == "track" and o.ptr and reaper.IsTrackSelected(o.ptr) then selected[o.oid] = true end end
    moved_set = mirror.moved_tracks(split(mirror.order_seen[order_key]), split(order), selected)
  end
  -- the first look at a project: which take plays is looked at again. (A part that arrived while the plug-in looked
  -- loaded stayed on silent notes, with its print sitting right there: laptop, 0.42.3)
  local first_here = mirror.order_seen[order_key] == nil
  if first_here then
    mirror.first_look[order_key] = reaper.time_precise() + mirror.FX_LOAD_SECS
    local prints = require("prints")
    for _, o in ipairs(objs) do
      if o.kind == "item" and o.ptr then pcall(prints.choose, o.ptr)
      elseif o.kind == "fx" and o.ptr then mirror.fx_load_knobs[order_key .. o.oid] = mirror.fx_params(o.ptr) end
    end
  end
  mirror.order_seen[order_key], mirror.order_band[order_key] = order, nil
  local playing = reaper.GetPlayStateEx(proj) & 1 == 1
  local mine_prefix = (me:gsub(" ", "_") .. "-"):upper() -- (event ids start with their author's name)
  local function allowed(o, name, pos)
    if opts.can(me, name, pos) then return true end
    return sync.maker_may(o.kind == "track" and o.oid or o.track, me, name, pos, opts.mode)
  end
  local function say_once(key, text)
    if not mirror.said[key] then mirror.said[key] = true; band.log(text) end
  end
  if next(moved_set) then -- (a move that isn't yours to make goes back, below)
    local yours = true
    for oid in pairs(moved_set) do
      local o = by_oid[oid]
      if o and not allowed(o, perm_name(o, by_oid), nil) then yours = false end
    end
    if yours then mirror.publish_order(proj, room_dir, me) end
  end
  local function put_back(o, rev, evid, why)
    mirror.unsent[tostring(proj) .. o.oid] = nil -- (the band's version is back: nothing of ours waits)
    local ev = event_file(room_dir, evid)
    if ev and not ev.gone then
      if o.kind == "fx" and playing then return end -- (reloading plug-ins mid-song: after the stop)
      local ok, h = mirror.apply(proj, ev, media, opts.local_mix)
      if ok then remember(proj, o.oid, ev.rev, h, ev.id, (ev.time or "") .. (ev.user or ""))
      elseif mirror.PART[o.kind] then return -- (waits for this tab to come to the front)
      else -- it can't land here (its track is gone): the band's state wins, and that has no such item
        if o.kind == "item" and o.ptr and reaper.ValidatePtr2(proj, o.ptr, "MediaItem*") then reaper.DeleteTrackMediaItem(reaper.GetMediaItem_Track(o.ptr), o.ptr) end
        remember(proj, o.oid, rev or 0, "", evid, (ev.time or "") .. (ev.user or ""))
      end
    elseif not rev then
      -- never the band's: something new this person may not add. Kept here, on a track of their own (never deleted)
      local where = (why.name or "") ~= "" and why.name or "an unnamed track"
      if o.kind == "item" and o.ptr then
        reaper.MoveMediaItemToTrack(o.ptr, keep_track(proj, why.name or ""))
        -- (out of the pool it shares with the part it was copied from, which is then put back from its event: REAPER's MIDI code crashed on a
        -- later tab close with a freed entry in its list, about 1 run in 5 after this step, and never without it: PC, 2026-11-03)
        do
          local got, ch = reaper.GetItemStateChunk(o.ptr, "", false)
          local unpooled, n = ch:gsub("\n%s*POOLEDEVTS[^\n]*", "")
          if got and n > 0 then reaper.SetItemStateChunk(o.ptr, unpooled, false) end
        end
        why.text = "a new item on " .. where .. " isn't yours to add: it's kept here on '" .. where .. " (yours, not sent)', " ..
          (why.to and ("and suggested to " .. why.to) or "not sent to the others (claim the track, or take control)")
      elseif o.kind == "track" and o.ptr then
        reaper.GetSetMediaTrackInfo_String(o.ptr, "P_EXT:band_local", "yours", true)
        why.text = "a new track isn't yours to add: it stays here as yours, not sent to the others (take control to add tracks)"
      elseif o.kind == "misc" then
        -- a group or lock put on someone's track: nothing here is worth keeping, and left on, your VCA went on moving their track on
        -- this computer alone (what you hear and render differs from everyone else). If they accept, it lands as theirs.
        if not mirror.apply(proj, { obj = "misc", oid = o.oid, track = o.track, state = "" }, media, opts.local_mix) then return end -- (waits for this tab to come to the front)
      elseif why.text then -- (a part that never went out: said once. Every pass, it pushed all else out of the log: laptop, 0.42.4)
        say_once("never" .. o.oid, why.text .. " (it stays on this computer)")
        return
      end
    else
      -- known, but its last change can't be read here (still arriving, or from another room): left as it is
      return say_once("noev" .. o.oid, "couldn't put back a change on " .. ((why.name or "") ~= "" and why.name or "an unnamed track") ..
        " (the studio's version hasn't arrived here yet): it stays as it is for now")
    end
    back = back + 1
    if why.text then sync.put_back(why.text) end
  end
  -- A track made here is claimed by whoever made it, once it has a name (James, 2026-11-01: an unseen "the maker may
  -- change it" let the PC change Bass I; a claim shows on the Claims card and can be released). Not by the driver
  -- (everything nobody claimed is theirs already) nor in Driver only. Only tracks first sent from 0.40.3 on.
  local function claim_new(o, rev, name)
    local k = "P_EXT:band_claim_new"
    if not rev then reaper.GetSetMediaTrackInfo_String(o.ptr, k, "1", true) end
    if name == "" or select(2, reaper.GetSetMediaTrackInfo_String(o.ptr, k, "", false)) ~= "1" then return end
    reaper.GetSetMediaTrackInfo_String(o.ptr, k, "", true)
    if opts.mode == "driver" or me == sync.driver_name or (sync.is_claimed and sync.is_claimed(name)) then return end
    if sync.claim_tracks(cfg, song, room, { name }) then band.log("you made track " .. name .. ": it's claimed for you (Claims card: release it to share it)") end
  end
  -- What was refused goes to whoever claimed it, as a suggestion, if it's a claim that refused it. -> true when it went.
  local function propose(o, rev, who, claim_name, pos, name, gone)
    if o.kind == "fx" or not who or who == me or opts.mode == "driver" or not (sync.is_claimed and sync.is_claimed(claim_name, pos)) then return false end
    local c = { obj = o.kind, oid = o.oid, rev = rev or 0, track = o.track, name = name, pos = pos, gone = gone or nil }
    if o.kind == "track" and o.ptr and not gone then -- (a normal group's fader moves the owner's track too: that's why this is a suggestion, and there's a better way)
      for _, g in ipairs({ "VOLUME_LEAD", "VOLUME_FOLLOW" }) do c.grouped = c.grouped or reaper.GetSetTrackGroupMembership(o.ptr, g, 0, 0) ~= 0 end
    end
    if not gone then
      c.state = o.state
      if o.kind == "item" then
        mirror.copy_failed = nil
        c.state = mirror.share_media(o.state, media, o.ptr)
        if mirror.copy_failed then return false end
      end
    end
    return suggest.add(room_dir, me, who, c)
  end
  local seen = {}
  -- a burst (hundreds of items moved at once) goes out a quarter second a pass, the rest on the next passes, which
  -- Live sync runs straight after: writing all 320 at once held REAPER up for 4.7 s (laptop, 0.34.5). What waits is
  -- marked unsent, so the band's changes to it wait too. `mirror.more`: there's more to send.
  local t_send = reaper.time_precise()
  mirror.more = false
  -- (whether track colours count here, per project: see below. "band2": 0.38 looks once more, as 0.36/0.37 kept each
  -- machine's own colour where it should have taken the band's: Bass I differed PC/laptop for good, 2026-11-01)
  local scheme = mirror.own_colours() and "own" or "band2"
  -- (or SWS's rules may just have recoloured it: it's only switched off once a band song is in front, so a project opened or
  -- brought forward with it on came in recoloured, and that went out as this person's change: laptop's Bass tracks, every reopen, 0.57.7)
  local sws_ran = reaper.time_precise() - (tonumber(reaper.GetExtState(require("band").SECTION, "sws colours ran")) or -math.huge) < 5
  local rescheme = first_here or sws_ran or select(2, reaper.GetProjExtState(proj, mirror.CSEC, "colours")) ~= scheme
  for _, o in ipairs(objs) do
    seen[o.oid] = true
    local ok, err = pcall(function()
      local rev, h, evid, kord = mirror.known(proj, o.oid)
      local rk = tostring(proj) .. o.oid
      -- the colour has just started or stopped counting here (before 0.36 it never did; SWS auto-colouring switched on
      -- or off): a track that differs from the band's version only in colour isn't a change of ours. With the colour
      -- counting, the band's last change to the track says what it is, so every machine ends up with the same (0.36
      -- and 0.37 kept each machine's own: Bass I differed PC/laptop for good). One sent from a machine whose SWS chose
      -- its colours says nothing: ours stays.
      if rescheme and o.kind == "track" and rev and h ~= "" then
        local ev = event_file(room_dir, evid)
        local function sans_colour(t) -- (through JSON both, as the event's was: REAPER's 0.0 reads back as 0)
          return mirror.track_line(band.json_decode(band.json_encode(t)), opts.local_mix, false)
        end
        if ev and type(ev.state) == "table" and sans_colour(ev.state) == sans_colour(o.state) then
          if scheme ~= "own" and tonumber(ev.state.color) and not ev.state.autocolour and o.ptr
              and band.color_in(ev.state.color) ~= band.track_colour(o.ptr) then
            band.set_track_colour(o.ptr, band.color_in(ev.state.color))
            o.state = mirror.track_state(proj, o.ptr, opts.local_mix)
            o.hash = mirror.track_hash(o.state, opts.local_mix)
          end
          -- (somewhere else in the list too: that's for the look below, now the colour's out of it)
          if (ev.state.after or "") == (o.state.after or "") then remember(proj, o.oid, rev, o.hash, evid, kord); return end
        end
      end
      -- only its place differs from the band's, and not by this person's doing: not a change, and the band's hash is
      -- what's recorded, so everyone's fingerprint agrees whatever order their list has ended up in (once per state and event)
      if o.kind == "track" and rev and h ~= "" and not moved_set[o.oid] and not mirror.reopened[rk] then
        local key = o.hash .. "\0" .. tostring(evid)
        local a = mirror.track_alias[key]
        if a == nil then
          local ev = event_file(room_dir, evid)
          -- (a track Back restored has no hash on its event: it went out on every machine whose list differs: PC, 0.42.11)
          a = ev and type(ev.state) == "table"
            and mirror.same_line(ev.state, o.state, opts.local_mix) and (ev.hash or h) or false
          mirror.track_alias[key] = a
        end
        if a then
          o.hash = a
          if h ~= a then remember(proj, o.oid, rev, a, evid, kord); h = a end
        end
      end
      -- a chain whose hash differs from its event's only as this machine re-encoded it: the band's hash stands (once per
      -- chain text and event), so everyone's fingerprint agrees and nothing re-prints
      if o.kind == "fx" and rev and evid and evid ~= "" then
        local key = o.hash .. "\0" .. evid
        local a = mirror.fx_alias[key]
        if a == nil then
          local ev = event_file(room_dir, evid)
          a = ev and ev.hash and ev.hash ~= o.hash and type(ev.state) == "string" and mirror.fx_same(o.state, ev.state) and ev.hash or false
          mirror.fx_alias[key] = a
        end
        if a then
          o.hash = a
          if h ~= a then remember(proj, o.oid, rev, a, evid, kord); h = a end
        end
      end
      -- this chain reads differently here from what the band has, as a plug-in saves its data its own way, or is still
      -- loading (knobs still, and only just landed or opened): not a change of ours
      if o.kind == "fx" and rev and h ~= "" and h ~= o.hash then
        if mirror.fx_readback[rk] == o.hash then o.hash = h
        elseif reaper.time_precise() < math.max(mirror.fx_loading[rk] or 0, mirror.first_look[tostring(proj)] or 0) then
          -- (knobs as they were when it opened or landed, and the band's plug-ins: one added, removed or moved changes those,
          -- as freezing and unfreezing a track do)
          local ev = event_file(room_dir, evid)
          local function names(chain)
            local t = {}
            for _, x in ipairs(mirror.plugin_blocks(chain_lines(chain))) do t[#t + 1] = tostring(x.key) end
            return table.concat(t, "\0")
          end
          if ev and type(ev.state) == "string" and names(ev.state) == names(o.state) and mirror.fx_load_knobs[rk] == mirror.fx_params(o.ptr) then
            mirror.fx_readback[rk] = o.hash; o.hash = h
          end
        end
      end
      -- its data changed, but no window of it has been open, no knob moved and the plug-ins are the same: nobody did that. Superior Drummer writes
      -- different data after every playthrough, which claimed the Drums, went to everyone and re-printed every item, each pass (PC, 0.57.5)
      -- (its knobs as of the end of its loading, or of the last change that went out or landed)
      if o.kind == "fx" and o.ptr and (mirror.fx_quiet[rk] == nil or reaper.time_precise() < math.max(mirror.fx_loading[rk] or 0, mirror.first_look[tostring(proj)] or 0)) then
        mirror.fx_quiet[rk] = mirror.fx_params(o.ptr)
      end
      if o.kind == "fx" and rev and h ~= "" and h ~= o.hash and o.ptr and not mirror.fx_was_open(o.ptr) and mirror.fx_quiet[rk] == mirror.fx_params(o.ptr) then
        local ev = event_file(room_dir, evid)
        local function names(chain)
          local t = {}
          for _, x in ipairs(mirror.plugin_blocks(chain_lines(chain))) do t[#t + 1] = tostring(x.key) end
          return table.concat(t, "\0")
        end
        if ev and type(ev.state) == "string" and names(ev.state) == names(o.state) then mirror.fx_readback[rk] = o.hash; o.hash = h end
      end
      -- a chain with a restless plug-in: the hash can't see its knobs move, so they're looked at here
      local knobs_moved, knobs
      if o.kind == "fx" and h == o.hash and mirror.restless_in(o.state) then
        knobs = mirror.fx_params(o.ptr)
        if mirror.fx_knobs[rk] == nil then mirror.fx_knobs[rk] = knobs end
        knobs_moved = mirror.fx_knobs[rk] ~= knobs
      end
      if h == o.hash and not knobs_moved then mirror.reopened[rk], mirror.unsent[rk] = nil, nil; return end
      if sent > 0 and reaper.time_precise() - t_send > 0.25 then mirror.unsent[rk], mirror.more = true, true; return end
      -- recorded under a hash this machine no longer makes (before 0.34.4 a Mac hashed plug-in files and colours its
      -- own way): what's here IS the band's version, so it's re-anchored, not sent as a change of ours. Once per record.
      if rev and h ~= "" and not knobs_moved and not mirror.anchor_seen[rk .. "\0" .. h] then
        mirror.anchor_seen[rk .. "\0" .. h] = true
        local ev = event_file(room_dir, evid)
        -- (or its item, read the way this machine reads one now: 0.40.3 left selected notes and VELLANE out)
        -- (or its chain: a plug-in on it was found restless since)
        if ev and (ev.hash == o.hash or o.kind == "item" and type(ev.state) == "string"
            and mirror.item_hash(o.track, mirror.normalize_item(ev.state)) == o.hash
            or o.kind == "fx" and type(ev.state) == "string" and mirror.fx_hash(ev.state) == o.hash
            -- (or the same but for its 14th digit, a tempo map put back: the Mac sent its Keys part as its own change, 0.42.8)
            or o.kind == "item" and type(ev.state) == "string" and mirror.rounded(mirror.normalize_item(ev.state)) == mirror.rounded(o.state)) then
          remember(proj, o.oid, rev, o.hash, evid, kord); return
        end
      end
      if mirror.reopened[rk] and rev then -- opened without its last save: the band's version, not this older one
        say_once("reopened" .. tostring(proj), "this project was opened without its last save: what changed since is back as the studio has it")
        if h == "" then -- the band deleted it since: gone here too (2026-10-31: three deleted tracks came back on a reopen)
          mirror.reopened[rk] = nil
          if o.kind == "track" or o.kind == "item" then mirror.apply(proj, { obj = o.kind, oid = o.oid, gone = true }, media, opts.local_mix) end
          back = back + 1
          return
        end
        return put_back(o, rev, evid, { name = perm_name(o, by_oid) })
      end
      -- (an empty part nobody has sent. Nor one gone from the band and just back with its track: its plug-ins were still on
      -- their way, and "none" went out as this machine's change, taking the Neve from everyone: Mac, 0.42.6)
      -- (nothing of ours waits then: a burst had marked it, and the band's chain never landed, as it waited for ours: PC, 0.42.9)
      if o.state == "" and o.kind ~= "track" and o.kind ~= "item" then
        if not rev then mirror.unsent[rk] = nil; return end
        if h == "" then local ev = event_file(room_dir, evid); if ev and ev.gone then mirror.unsent[rk] = nil; return end end
      end
      -- plug-ins and automation: only while stopped, once settled (not a whole chain per knob turn, or an envelope per
      -- point drawn)
      if o.kind == "fx" or o.kind == "env" then
        local key = tostring(proj) .. o.oid -- (per tab: a side room's copy shares the oid)
        local f = mirror.fx_seen[key]
        mirror.unsent[rk] = true -- (until it goes: the band's change to it waits)
        if playing then return end
        mirror.unsettled = true -- (Live sync looks again soon)
        if not f or f.hash ~= o.hash or f.knobs ~= knobs then
          local now, cc = reaper.time_precise(), reaper.GetProjectStateChangeCount(proj)
          local n = { hash = o.hash, knobs = knobs, since = now, text = o.state, cc = cc, flips = 0, began = now }
          if o.kind == "fx" then
            n.params = mirror.fx_params(o.ptr)
            -- it changed again with its knobs still and nothing else happening: restless, if it goes on
            if f and f.text and f.hash ~= o.hash and f.cc == cc and f.params == n.params then n.flips, n.began = (f.flips or 0) + 1, f.began or now end
            if n.flips >= mirror.RESTLESS_FLIPS and now - n.began >= mirror.RESTLESS_SECS then
              local names = mirror.fx_differing(f.text, o.state)
              if mirror.restless_add(names) then
                band.log(table.concat(names, ", ") .. " keeps changing its saved data by itself: StudioSync goes by its knobs from now on")
                o.hash = mirror.fx_hash(o.state)
                knobs = mirror.fx_params(o.ptr)
                mirror.fx_knobs[rk] = knobs
                n = { hash = o.hash, knobs = nil, since = now }
              end
            end
          end
          mirror.fx_seen[key] = n
          return
        end
        if reaper.time_precise() - f.since < 3 then return end
      end
      if opts.hold then mirror.unsent[rk] = true; return end -- (Hold my changes: it stays here until switched off)
      local name = perm_name(o, by_oid)
      local holder = rev and opts.held and opts.held(o.oid)
      if holder then -- someone else is working on it right now (lib/presence.lua): theirs, for a few seconds
        return put_back(o, rev, evid, { name = name, text = string.format("%s is editing %s right now: put back (try again in a few seconds)",
          holder, o.kind == "track" and ("track " .. (name ~= "" and name or "(unnamed)")) or ((o.kind == "item" and "that item" or mirror.PART[o.kind]) .. " on " .. (name ~= "" and name or "an unnamed track"))) })
      end
      local last = rev and event_file(room_dir, evid) or nil
      if o.kind == "item" and last and type(last.state) == "string" and type(o.state) == "string" and mirror.same_but_labels(o.state, last.state) then
        return remember(proj, o.oid, rev, last.hash or o.hash, evid, kord) -- (the event's hash: fingerprints stay the same as everyone's)
      end
      -- allowed where it is now, and where it was (moving an item off a claimed track, or renaming a claimed track,
      -- mustn't slip past the claim)
      -- (a wet take StudioSync just made: whoever is to print it may send it, whatever the claims: prints.printer)
      local auto = o.kind == "item" and mirror.auto[tostring(proj) .. o.oid]
      local ok_now = auto or allowed(o, name, o.pos) or (o.kind == "track" and last ~= nil and allowed(o, last.name or "", last.pos))
      local ok_before = auto or not last or last.gone or allowed(o, last.name or "", last.pos)
      if ok_now and ok_before then
        local state = o.state
        if o.kind == "item" then
          mirror.copy_failed = nil
          local shared = mirror.share_media(state, media, o.ptr)
          if mirror.copy_failed then -- (its audio didn't reach the band's folder: sent, it'd point at a file only we have)
            return say_once("copy" .. o.oid, string.format("couldn't copy the audio of an item on %s into the studio's folder (%s): it goes out once it can",
              name ~= "" and name or "an unnamed track", mirror.copy_failed))
          end
          if shared ~= state then -- it now plays the shared copy here too, so the next look sees the same thing
            reaper.SetItemStateChunk(o.ptr, mirror.resolve_media((shared:gsub("BANDLANE %d+\n?", "")), media), false)
            state = mirror.item_state(o.ptr, media)
            o.hash = mirror.item_hash(o.track, state)
          end
        end
        local owned = (sync.is_claimed and sync.is_claimed(name, o.pos) and opts.can(me, name, o.pos)) or (opts.mode ~= "open" and me == sync.driver_name)
        local ev = { type = "obj", obj = o.kind, oid = o.oid, rev = mirror.next_rev(rev, owned), base = rev or 0, state = state, track = o.track,
          name = name, pos = o.pos, hash = o.hash, hv = mirror.HV } -- (hash: what it is here; every receiver checks it came out the same)
        if o.kind == "track" and o.ptr and (tonumber(o.state.lanes) or 0) > 1 then
          -- (the first comp area: REAPER's new lane holds only that piece, and the rest of the part goes silent, with no word: Mac, 0.42.10)
          local items = {}
          for j = 0, reaper.CountTrackMediaItems(o.ptr) - 1 do
            local x = reaper.GetTrackMediaItem(o.ptr, j)
            items[#items + 1] = { pos = reaper.GetMediaItemInfo_Value(x, "D_POSITION"), len = reaper.GetMediaItemInfo_Value(x, "D_LENGTH"),
              plays = reaper.GetMediaTrackInfo_Value(o.ptr, "C_LANEPLAYS:" .. math.floor(reaper.GetMediaItemInfo_Value(x, "I_FIXEDLANE"))) > 0 }
          end
          local playing, holds = mirror.lane_cover(items)
          if holds > 0 and playing < holds / 2 then
            say_once("cover " .. o.oid .. tostring(o.state.plays), string.format("%s: the lane that plays holds %.0f s of the %.0f s on this track. The rest is silent until it's comped in, or another lane plays",
              name ~= "" and name or "a track", playing, holds))
          end
        end
        if mirror.auto[tostring(proj) .. o.oid] then ev.auto, mirror.auto[tostring(proj) .. o.oid] = true, nil end
        ev.note = credit[o.oid] or bus_note(o, name, last) -- (said on every machine as it lands: sync.receive)
        if ev.note and not credit[o.oid] then band.log(ev.note) end
        if o.kind == "fx" then
          ev.files = require("fxfiles").share(state, media) -- (samples, IRs, models it loads)
          ev.restless = mirror.restless_in(state)
          if ev.restless then mirror.fx_knobs[rk] = knobs or mirror.fx_params(o.ptr) end
        end
        local id = sync.post(cfg, song, room, ev)
        if o.kind == "fx" and o.ptr then mirror.fx_quiet[rk] = mirror.fx_params(o.ptr) end -- (what it's changed from, next time)
        remember(proj, o.oid, ev.rev, o.hash, id, (ev.time or "") .. me)
        if name ~= "" and not ev.auto and select(2, reaper.GetProjExtState(proj, band.SECTION, "last_track")) ~= name then
          reaper.SetProjExtState(proj, band.SECTION, "last_track", name) -- (what they're working in: Who's here)
        end
        mirror.unsent[tostring(proj) .. o.oid] = nil -- (gone out: the band's next change to it may land)
        require("presence").touch(proj, o.oid)
        sent = sent + 1
        if o.kind == "track" and o.ptr then claim_new(o, rev, name) end
      else
        -- only its place in the list differs: a track above it went (a bandmate's, say, joining late, or one that's coming
        -- back), and nobody changed this one, so it isn't news ("Track Mac Audio ... put back": laptop, 0.42.2)
        if o.kind == "track" and last and type(last.state) == "table" and mirror.same_line(o.state, last.state, opts.local_mix) then
          return put_back(o, rev, evid, { name = name })
        end
        -- the tempo changed and REAPER moved this with it: nobody's edit. It's where it should be, and whoever may change it sends
        -- it. (Put back, a bandmate's part sat at its old time, out of step with the new tempo, until theirs arrived.)
        if last and reaper.time_precise() < (mirror.tempo_until[tostring(proj)] or 0) and (o.kind == "env"
            or o.kind == "item" and type(last.state) == "string" and mirror.sans_tempo(o.state) == mirror.sans_tempo(last.state)) then
          mirror.unsent[rk] = nil
          return remember(proj, o.oid, rev, o.hash, evid, kord)
        end
        -- only how its folder closes differs, in the same folder: a track added or copied after it did that, and nobody changed
        -- this one. Nothing to ask its owner about (a copy of Keys asked Mac about Keys)
        if o.kind == "track" and last and type(last.state) == "table" then
          local x, y = band_json(o.state), band_json(last.state)
          x.depth, y.depth = 0, 0
          if mirror.same_line(x, y, opts.local_mix) then return put_back(o, rev, evid, { name = name }) end
        end
        local where = (ok_before and name or last.name or "") ~= "" and (ok_before and name or last.name) or "an unnamed track"
        -- whose it is, and what would let you: "or take control" told the driver to take control (laptop, round 2)
        local owner_of = sync.owner_of
        local pos = o.pos -- (a plug-in chain has none, and one that's never gone out has no last change: laptop, 0.42.3)
        if not ok_before and last then pos = last.pos end
        local who = owner_of and owner_of(ok_before and name or (last.name or ""), pos)
        -- (someone's claim: what was done to it goes to them to accept. lib/suggest.lua)
        local to = propose(o, rev, who, ok_before and name or (last and last.name or ""), pos, name)
        local how = to and ("it's claimed by " .. who .. ": put back, and suggested to them")
          or (who and who ~= me and who ~= sync.driver_name) and ("it's claimed by " .. who .. ": put back (ask them to release it)")
          or sync.room_mode == "admins" and "admins only here: put back (an admin can give it to you)"
          or (who and who ~= me) and (who .. " drives: put back (claim it, or take control)")
          or "it isn't yours to change right now: put back (claim it, or take control)"
        put_back(o, rev, evid, { name = ok_before and name or (last.name or ""), to = to and who or nil, text = string.format("%s: %s",
          o.kind == "track" and ("Track " .. where) or ((o.kind == "item" and "That item" or mirror.PART[o.kind]:gsub("^%l", string.upper)) .. " on " .. where), how) })
      end
    end)
    if not ok then say_once("err" .. o.oid, "mirror sync skipped " .. o.oid .. ": " .. tostring(err)) end
  end
  -- MIDI prints: an item whose newest change is this person's gets a fresh print once its notes, length or the
  -- band's plug-in chain on its track changed (it goes out on the next pass). Only theirs, so two machines never take
  -- turns re-printing one item. Rendering needs this tab in front and the transport stopped; two per pass at most.
  if reaper.EnumProjects(-1) == proj and not playing and not mirror.more and not opts.hold then -- (prints wait until a burst has gone, and Hold is off)
    local prints, made = require("prints"), 0
    prints.watch_ara(proj) -- (a Melodyne window closed: that take gets a new print below)
    -- takes become lanes, by whoever owns them (their newest change, or not sent yet). Once caught up: an old file reopened
    -- split its old comps and sent them before the band's newer versions had landed (laptop, 0.42.9)
    if require("sync").pending_events(proj, cfg, song, room) == 0 then
      prints.takes_to_lanes(proj, function(it)
        local _, _, k = mirror.known(proj, itm_oid(it))
        return not k or k == "" or k:upper():sub(1, #mine_prefix) == mine_prefix
      end)
    end
    local here = { [me] = true } -- (bandmates in the song now: who may print in place of whoever changed an item)
    for u in pairs(opts.here or {}) do here[u] = true end
    local keys_of = {} -- track -> the plug-in keys its prints go through
    for _, o in ipairs(objs) do
      if made < 2 and o.kind == "item" and reaper.ValidatePtr2(proj, o.ptr, "MediaItem*") then
        local _, _, kev = mirror.known(proj, o.oid)
        local fx = by_oid["F" .. o.track:sub(2)]
        -- who refreshes a print (prints.printer): the track's printer if they're here and can, else whoever changed
        -- it last if they can, else the first one here who can. Whoever changed it last but may not change it now
        -- (someone claimed the track since) is stood in for by the one who may (laptop, 2026-10-31: its re-print of a
        -- claimed track's item was put back three times).
        local name = perm_name(o, by_oid)
        local may = false
        -- (a side room starts as a copy: what hasn't changed in it keeps the print it came with. Another machine's reading of the
        -- same chain differs, so whoever opened the room rendered the Drums again: laptop, 0.42.5)
        local same_as_parent = false
        if room ~= "main" and fx then
          local _, _, fev = mirror.known(proj, fx.oid)
          same_as_parent = not reaper.file_exists(room_dir .. "/events/" .. tostring(kev) .. ".json") and not reaper.file_exists(room_dir .. "/events/" .. tostring(fev) .. ".json")
        end
        if fx and kev and not same_as_parent then
          local tr = reaper.GetMediaItem_Track(o.ptr)
          local author = kev:upper():sub(1, #mine_prefix) == mine_prefix and me or (event_file(room_dir, kev) or {}).user
          if type(author) ~= "string" then author = nil end
          if author and author ~= me and not opts.can(author, name, o.pos) and allowed(o, name, o.pos) then author = me end
          keys_of[tr] = keys_of[tr] or prints.track_keys(tr)
          local function can(u) if u == me then return prints.track_plays(tr) end return prints.has(cfg, u, keys_of[tr]) end
          may = prints.printer(name, author, here, opts.printers or {}, can) == me
        end
        if may then
          local dest = prints.route(reaper.GetMediaItem_Track(o.ptr)) -- (an instrument on another track: its chain is part of the print)
          local dfx = dest and by_oid["F" .. mirror.track_oid(dest):sub(2)]
          -- (a restless plug-in's knobs aren't in its chain's hash, but they change the sound: Disperser's Amount moved
          -- and went out, and the print stayed as it was: Mac, 0.42.1)
          local function sounds(f)
            if not f then return nil end
            if f.print_key == nil then f.print_key = mirror.restless_in(f.state) and (f.hash .. mirror.hash(mirror.fx_params(f.ptr))) or f.hash end
            return f.print_key
          end
          local ok, did = pcall(prints.refresh, proj, o.ptr, media, sounds(fx), sounds(dfx), cfg)
          if ok and did then made = made + 1; mirror.auto[tostring(proj) .. o.oid] = true end -- (its next send is StudioSync's, not theirs)
        end
      end
    end
    -- (a print just went on: out on the very next pass. It waited for the 10-second look: 9 s on a print that was
    -- already there, 18 s on a rendered one: PC, 0.41.1)
    if made > 0 then mirror.more = true end
  end
  local undeleted = {}
  -- gone here: deleted (sent, if allowed) or put back
  local i, gone = 0, {}
  while true do
    local ok, oid = reaper.EnumProjExtState(proj, mirror.SEC, i)
    if not ok then break end
    i = i + 1
    local rev, h, evid = mirror.known(proj, oid)
    if not seen[oid] and h ~= "" then
      if opts.hold then mirror.unsent[tostring(proj) .. oid] = true -- (held: the delete goes out when Hold is switched off)
      elseif oid:sub(1, 1) == "I" and mirror.find(proj, "item", oid) then
        -- still here, on a track of this machine's own (Real time, "yours, not sent"): not deleted. Sent as gone, it
        -- went for everyone (review, 2026-10-31); the band keeps it where it was
        say_once("local" .. oid, "an item of the studio's is on a track of your own: it isn't sent from there, and the others keep it where it was (move it back to a studio track to change it)")
      else gone[#gone + 1] = { oid = oid, rev = rev, evid = evid } end
    end
  end
  -- tracks first: a bandmate's track deleted here came back without its items, which had nowhere to land yet, and that
  -- machine stayed different until the owner next changed them (laptop, 0.42.2)
  local function gone_rank(g) return g.oid:sub(1, 1) == "T" and 1 or 2 end
  table.sort(gone, function(a, b)
    if gone_rank(a) ~= gone_rank(b) then return gone_rank(a) < gone_rank(b) end
    return a.oid < b.oid
  end)
  for _, g in ipairs(gone) do
    if sent > 0 and reaper.time_precise() - t_send > 0.25 then mirror.more = true; break end -- (the rest next pass, as above)
    local ok, err = pcall(function()
      local last = event_file(room_dir, g.evid)
      if not last then -- nothing to go on (its last change isn't here): forgotten, not resurrected or repeated
        return remember(proj, g.oid, g.rev or 0, "", g.evid)
      end
      local o = { kind = last.obj or (g.oid:sub(1, 1) == "T" and "track" or "item"), oid = g.oid, track = last.track, state = last.state }
      local name = last.name or ""
      local _, th, tev = mirror.known(proj, o.track or "")
      if kept_back[o.track or ""] then -- (on a folder or bus that was refused above: it comes back with it)
        put_back(o, g.rev, g.evid, { name = name })
      elseif mirror.PART[o.kind] then -- (its track went: the track's own deletion covers it)
        remember(proj, g.oid, (g.rev or 0) + 1, "", g.evid)
      elseif o.kind == "item" and th == "" and (tev or ""):upper():sub(1, #mine_prefix) ~= mine_prefix
          and not mirror.find(proj, "track", o.track) then
        -- the band deleted its track, and the item went with it here before the item's own delete arrived: theirs,
        -- not ours (the Mac put back 226 of a deleted track's items one by one: laptop's restore, 0.34.4). Same rev,
        -- so the item's delete still lands when it comes.
        remember(proj, g.oid, g.rev or 0, "", g.evid)
      elseif allowed(o, name, last.pos) then
        local ev = { type = "obj", obj = o.kind, oid = g.oid, rev = (g.rev or 0) + 1, base = g.rev or 0, gone = true, track = o.track, name = name, pos = last.pos }
        local id = sync.post(cfg, song, room, ev)
        remember(proj, g.oid, ev.rev, "", id, (ev.time or "") .. me) -- (with its order: a racing edit is settled alike everywhere)
        mirror.unsent[tostring(proj) .. g.oid] = nil
        sent = sent + 1
        if o.kind == "track" and holds[g.oid] then -- (nobody else's: it goes, and is said)
          local names = {}
          for _, x in ipairs(holds[g.oid].oids) do if holds[g.oid].names[x] then names[#names + 1] = holds[g.oid].names[x] end end
          band.log(string.format("you deleted %s, which held %s: they aren't in it any more", name ~= "" and name or "a track", table.concat(names, ", ")))
        end
      else
        local who = sync.owner_of and sync.owner_of(name, last.pos)
        local to = propose(o, g.rev, who, name, last.pos, name, true)
        if o.kind == "item" and not to then -- (one line for all of a track's: a deleted track's items each said so)
          undeleted[name] = (undeleted[name] or 0) + 1
          put_back(o, g.rev, g.evid, { name = name })
        else
          put_back(o, g.rev, g.evid, { name = name, text = string.format("%s on %s isn't yours to delete: it's back%s",
            o.kind == "track" and "that track" or "that item", name ~= "" and name or "an unnamed track", to and (", and suggested to " .. who) or "") })
        end
      end
    end)
    if not ok then say_once("err" .. g.oid, "mirror sync skipped " .. g.oid .. ": " .. tostring(err)) end
  end
  for name, n in pairs(undeleted) do
    sync.put_back(string.format("%s on %s %s yours to delete: %s back", n == 1 and "that item" or (n .. " items"), name ~= "" and name or "an unnamed track", n == 1 and "isn't" or "aren't", n == 1 and "it's" or "they're"))
  end
  mirror.save_ids(proj)
  if rescheme and not mirror.more then reaper.SetProjExtState(proj, mirror.CSEC, "colours", scheme) end
  mirror.summary(proj, cfg, room_dir, objs, media)
  suggest.flush()
  do -- (what each track holds, for the next look: a deleted track's can't be read any more)
    local list, names = {}, {}
    for _, o in ipairs(objs) do
      if o.kind == "track" then
        names[o.oid] = o.state.name
        -- shortcut: VCA groups 1 to 32 only (the rest are a second pair of calls): a VCA in 33 to 64 isn't seen as holding anything.
        list[#list + 1] = { oid = o.oid, parent = o.state.parent, recv = by_oid["R" .. o.oid:sub(2)] and by_oid["R" .. o.oid:sub(2)].state,
          lead = reaper.GetSetTrackGroupMembership(o.ptr, "VOLUME_VCA_LEAD", 0, 0), follow = reaper.GetSetTrackGroupMembership(o.ptr, "VOLUME_VCA_FOLLOW", 0, 0) }
      end
    end
    local now = {}
    for oid, oids in pairs(mirror.feeders(list)) do
      local held = {}
      for _, x in ipairs(oids) do held[x] = names[x] end
      now[oid] = { oids = oids, names = held, name = names[oid] or "" }
    end
    mirror.holds[tostring(proj)] = now
  end
  return sent, back
end

-- What the song chooser shows before someone joins (lib/chooser.lua): the room's tracks, plug-ins and how much audio
-- it holds. rooms/<room>/summary/<user>.json (each machine its own file), rewritten only when it changed; the media
-- folder is measured once a minute at most.
local summary_seen, media_mb = {}, {}
function mirror.summary(proj, cfg, room_dir, objs, media)
  local band = require("band")
  local key = tostring(proj) .. room_dir
  local m = media_mb[key]
  if not m or reaper.time_precise() - m.at > 60 then
    local bytes = 0
    for _, f in ipairs(band.files(media)) do bytes = bytes + (band.size(media .. "/" .. f) or 0) end
    m = { at = reaper.time_precise(), mb = math.floor(bytes / 1048576 + 0.5) }
    media_mb[key] = m
  end
  local names, seen, tracks = {}, {}, 0
  for _, o in ipairs(objs) do
    if o.kind == "track" then tracks = tracks + 1 end
    if o.kind == "fx" then
      for _, n in ipairs(mirror.fx_names(o.state)) do if not seen[n] then seen[n] = true; names[#names + 1] = n end end
    end
  end
  table.sort(names)
  local s = { tracks = tracks, plugins = names, media_mb = m.mb }
  local text = band.json_encode(s)
  if summary_seen[key] == text then return end
  summary_seen[key] = text
  s.time = os.date("!%Y-%m-%dT%H:%M:%SZ")
  reaper.RecursiveCreateDirectory(room_dir .. "/summary", 0)
  band.write_json(room_dir .. "/summary/" .. (cfg.user:gsub("[^%w%-_ ]", "")) .. ".json", s)
end

-- Our own change that the band's rules refuse (judged when it was made): this object goes back to the newest
-- revision before it, as the band has it.
function mirror.repair(proj, ev, room_dir, local_mix)
  local band = require("band")
  local best
  for _, f in ipairs(band.files(room_dir .. "/events", ".json")) do
    local e = f ~= ev.id .. ".json" and f:find(".json", 1, true) and band.read_json(room_dir .. "/events/" .. f)
    if type(e) == "table" and e.type == "obj" and e.oid == ev.oid and (e.rev or 0) < (ev.rev or 0) and
        mirror.newer({ rev = e.rev, time = (e.time or "") .. (e.user or "") }, best and { rev = best.rev, time = (best.time or "") .. (best.user or "") }) then
      best = e
    end
  end
  if best and not best.gone then
    local ok, h = mirror.apply(proj, best, room_dir .. "/media", local_mix)
    if ok then remember(proj, ev.oid, ev.rev, h, best.id, (ev.time or "") .. (ev.user or "")) end
  end
  require("sync").put_back("a change you made just as control changed hands wasn't yours to make: it's back as the studio has it")
end

-- History's "selected tracks" scope: the tracks selected in REAPER, their plug-ins and everything on them (then or
-- now). nil when nothing is selected.
function mirror.selection_scope(proj)
  local set, any = {}, false
  for i = 0, reaper.CountSelectedTracks(proj) - 1 do
    local oid = trk_oid(reaper.GetSelectedTrack(proj, i))
    if oid ~= "" then for _, p in ipairs({ "T", table.unpack(mirror.PARTS) }) do set[p .. oid:sub(2)] = true end; any = true end
  end
  if not any then return nil end
  return function(oid, last, at) return set[oid] or (last and set[last.track or ""]) or (at and set[at.track or ""]) or false end
end

-- Carry out a History plan (plan_restore / plan_undo) here and send it to the band as new revisions, so a restore
-- is itself a change that can be undone. Objects this person may not change are left (counted). Returns a summary.
-- Whether two states of an item differ only in what a print adds to a take's name. REAPER gives a comp piece its source pass's take name
-- as a project opens, so one whose piece is printed and whose pass isn't went from "dry - x" to "x" and out as a change, from just opening
-- (Mac, 0.45.0). Pure.
function mirror.same_but_labels(x, y)
  local function plain(s) return (s:gsub('NAME "dry %- ', 'NAME "'):gsub('NAME "wet %- ', 'NAME "')) end
  return plain(x) == plain(y)
end

-- A deleted item being brought back whose very place on its lane is taken by the same thing under another id. Undoing a pass makes
-- REAPER rebuild its comp piece as a new item, so the comp lane's own row, undone after, played a second copy on top (Mac 0.42.27, PC 0.45).
function mirror.sits_there(proj, ev)
  if ev.obj ~= "item" or type(ev.state) ~= "string" or mirror.find(proj, "item", ev.oid) then return false end
  local lane, pos, len = tonumber(ev.state:match("BANDLANE (%d+)")), tonumber(ev.state:match("POSITION ([%d%.%-e]+)")), tonumber(ev.state:match("LENGTH ([%d%.%-e]+)"))
  local tr = ev.track and mirror.find(proj, "track", ev.track)
  if not (tr and lane and pos and len) then return false end
  -- (by name without what a print adds: the same pass reads "x", "dry - x" or "wet - x" by whether it's been printed yet: Mac, 0.45.0)
  local function plain(n) return (n:gsub("^dry %- ", ""):gsub("^wet %- ", "")) end
  local name = ev.state:match('NAME "([^"\n]*)"') or ev.state:match("NAME ([^\n]*)")
  for i = 0, reaper.CountTrackMediaItems(tr) - 1 do
    local it = reaper.GetTrackMediaItem(tr, i)
    if reaper.GetMediaItemInfo_Value(it, "I_FIXEDLANE") == lane and math.abs(reaper.GetMediaItemInfo_Value(it, "D_POSITION") - pos) < 1e-6
      and math.abs(reaper.GetMediaItemInfo_Value(it, "D_LENGTH") - len) < 1e-6 then
      if not name then return true end
      for k = 0, reaper.CountTakes(it) - 1 do
        local take = reaper.GetTake(it, k)
        if take and plain(select(2, reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false))) == plain(name) then return true end
      end
    end
  end
  return false
end

mirror.REVERT_AT_ONCE, mirror.REVERT_SLICE = 120, 0.1 -- (changes; seconds per pass)
function mirror.revert(proj, cfg, song, room, plan, opts)
  local sync = require("sync")
  local function band_log(text) require("band").log(text) end
  local room_dir = sync.room_dir(cfg, song, room)
  local media = room_dir .. "/media"
  local order = { track = 1, fx = 2, item = 3 }
  local list = {}
  for oid, t in pairs(plan) do list[#list + 1] = { oid = oid, t = t } end
  -- tracks before what sits on them when bringing back; the other way round when removing
  table.sort(list, function(a, x)
    local ka, kx = order[a.t and a.t.obj or (a.oid:sub(1, 1) == "T" and "track" or "item")] or 3, order[x.t and x.t.obj or (x.oid:sub(1, 1) == "T" and "track" or "item")] or 3
    if (a.t and 1 or 0) ~= (x.t and 1 or 0) then return a.t ~= false end
    if a.t then return ka < kx else return ka > kx end
  end)
  -- and a track only after the one it sits under, when that comes back too: put back first, Keys found no K4 Inner
  -- yet and went to the top, out of its folder (laptop, block K)
  local back, placed, sorted = {}, {}, {}
  for _, p in ipairs(list) do if p.t and p.t.obj == "track" then back[p.oid] = p end end
  local function place(p)
    if placed[p] then return end
    placed[p] = true -- (before going up: tracks from different times can sit under each other in a ring, and each of 7 went out 73 times,
    -- 7.5 s with REAPER stopped: laptop, 0.42.8)
    local after = type(p.t.state) == "table" and p.t.state.after or ""
    if back[after] then place(back[after]) end
    sorted[#sorted + 1] = p
  end
  for _, p in ipairs(list) do
    if p.t and p.t.obj == "track" then place(p) elseif not placed[p] then placed[p] = true; sorted[#sorted + 1] = p end
  end
  list = sorted
  local done, refused, kept, kept_names, there = 0, 0, 0, {}, 0
  local function one(p)
    local rev, h, evid = mirror.known(proj, p.oid)
    local name = p.t and p.t.name or ""
    if p.t and p.t.obj ~= "track" and p.t.track then -- (a part or item: on the track as it's called now, not was; laptop 0.34.4)
      local tr = mirror.find(proj, "track", p.t.track)
      if tr then name = select(2, reaper.GetTrackName(tr)) end
    end
    local last = evid and evid ~= "" and event_file(room_dir, evid) or nil
    if not p.t and last and name == "" then name = last.name or "" end
    -- Going back never removes what a bandmate has made since: the driver going back a version took the Mac's new track and
    -- its 4 items for everyone, and forward couldn't return them, as the Mac's claim on it still stood (laptop, 0.42.5). And
    -- what you removed yourself you may bring back, whoever's claim stands now.
    -- (by who made it, not who touched it last: having restored the Mac's track earlier made it "yours" to remove. Only undoing
    -- that very change of yours may take it away again.)
    -- (nor what your own going back revived after a bandmate deleted it: forward left a glue's pieces under the glued part: laptop, 0.42.10)
    -- (opts.exact: a room made to look at that moment, where nothing is anybody's to keep)
    local theirs_new = not opts.exact and not p.t and not mirror.is_creator(p.oid, cfg.user) and not (opts.undoes and last and last.user == cfg.user)
      and not (last and last.user == cfg.user and last.revived)
    local mine_gone = p.t and last and last.gone and last.user == cfg.user
    if not p.t and (h or "") == "" then -- gone then, gone now
    elseif p.t and evid == p.t.id then -- already that revision
    elseif p.t and not opts.exact and mirror.sits_there(proj, p.t) then there = there + 1
    elseif theirs_new then
      kept = kept + 1
      kept_names[name ~= "" and name or "an unnamed track"] = true
    elseif mine_gone then
      local ok, nh = mirror.apply(proj, p.t, media, opts.local_mix)
      if ok then
        local ev = { type = "obj", obj = p.t.obj, oid = p.oid, rev = (rev or 0) + 1, state = p.t.state, track = p.t.track, name = name, pos = p.t.pos, restored = p.t.id,
          undoes = opts.undoes, redoes = opts.redoes }
        local id = sync.post(cfg, song, room, ev)
        remember(proj, p.oid, ev.rev, nh, id, (ev.time or "") .. cfg.user)
        done = done + 1
        p.landed = true
      end
    elseif not (opts.can(cfg.user, name, p.t and p.t.pos or nil) or sync.maker_may(p.t and p.t.obj == "track" and p.oid or (p.t and p.t.track) or p.oid, cfg.user, name, p.t and p.t.pos or nil, opts.mode)) then
      refused = refused + 1
    elseif p.t then
      local ok, nh = mirror.apply(proj, p.t, media, opts.local_mix)
      if ok then
        local ev = { type = "obj", obj = p.t.obj, oid = p.oid, rev = (rev or 0) + 1, state = p.t.state, track = p.t.track, name = name, pos = p.t.pos, restored = p.t.id,
          undoes = opts.undoes, redoes = opts.redoes, revived = (last and last.gone and last.user ~= cfg.user) or nil }
        local id = sync.post(cfg, song, room, ev)
        remember(proj, p.oid, ev.rev, nh, id, (ev.time or "") .. cfg.user)
        done = done + 1
        p.landed = true
      end
    else
      local kind = mirror.KIND[p.oid:sub(1, 1)] or "item"
      mirror.apply(proj, { obj = kind, oid = p.oid, gone = true }, media, opts.local_mix)
      local gev = { type = "obj", obj = kind, oid = p.oid, rev = (rev or 0) + 1, base = rev or 0, gone = true, undoes = opts.undoes, redoes = opts.redoes,
        name = last and last.name, track = last and last.track, pos = last and last.pos } -- (named: read later, it said "an unnamed track")
      local id = sync.post(cfg, song, room, gev)
      remember(proj, p.oid, gev.rev, "", id, (gev.time or "") .. cfg.user)
      done = done + 1
    end
  end
  local function finish()
    reaper.Undo_EndBlock2(proj, "StudioSync: go back", -1)
    reaper.UpdateArrange()
    -- a lane takes its name only now its items are in, and they came after the track: forward lost "Take 1", and sent that (Mac, 0.42.5)
    local tracks_landed = false
    for _, p in ipairs(list) do
      local tr = p.landed and p.t.obj == "track" and type(p.t.state) == "table" and mirror.find(proj, "track", p.oid)
      if tr then
        tracks_landed = true
        mirror.set_track_state(proj, tr, p.t.state, opts.local_mix)
        local rev, _, evid, ord = mirror.known(proj, p.oid)
        remember(proj, p.oid, rev, mirror.track_hash(mirror.track_state(proj, tr, opts.local_mix), opts.local_mix), evid, ord)
      end
    end
    if tracks_landed then mirror.publish_order(proj, room_dir, cfg.user) end -- (the order it had then is the order now)
    local names = {}
    for n in pairs(kept_names) do names[#names + 1] = n end
    table.sort(names)
    if done == 0 and there > 0 and refused == 0 and kept == 0 then return "it's already back: REAPER rebuilt it from its pass, so nothing changed" end
    return string.format("%d change(s) brought back and sent to the others%s%s", done, refused > 0 and string.format(" (%d not yours to change, left as they are)", refused) or "",
      kept > 0 and string.format(" (kept what collaborators added since: %s)", table.concat(names, ", ")) or "")
  end
  if #list <= mirror.REVERT_AT_ONCE or opts.at_once then
    reaper.Undo_BeginBlock2(proj)
    for _, p in ipairs(list) do one(p) end
    return finish()
  end
  -- A big one, a slice per pass: 415 changes held REAPER still for 6.9 s (Mac, 0.42). Each object lands and is remembered whole, so Live sync can
  -- look in between. No undo blocks in the middle: the one at the end is the single undo point for all of it.
  local i = 1
  local function slice()
    if not reaper.ValidatePtr(proj, "ReaProject*") then return band_log("Stopped bringing back changes: the project closed.") end
    local t0 = reaper.time_precise()
    while i <= #list and reaper.time_precise() - t0 < mirror.REVERT_SLICE do one(list[i]); i = i + 1 end
    if i <= #list then return reaper.defer(slice) end
    reaper.Undo_BeginBlock2(proj)
    band_log(finish())
  end
  mirror.revert_slice = slice -- (tests step it by hand)
  slice()
  return string.format("bringing back %d changes: REAPER keeps working while it does", #list)
end

-- Track order. A move used to travel only as that track's "sits under", landing only if its tab was in front, with each track
-- that came in later going wherever its neighbour then was: orders drifted apart, and nothing brought them back (0.56).
-- Each person's newest deliberate order: <room>/order/<user>.json, { list, time, by }; the newest of them is the studio's.
local function mirrored_order(proj)
  local list = {}
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    if not local_track(tr) then
      local oid = trk_oid(tr)
      if oid ~= "" then list[#list + 1] = oid end
    end
  end
  return list
end
function mirror.read_order(room_dir)
  local band, best = require("band"), nil
  for _, f in ipairs(band.files(room_dir .. "/order", ".json")) do
    local j = band.read_json(room_dir .. "/order/" .. f)
    if type(j) == "table" and type(j.list) == "table" and type(j.time) == "string" and type(j.by) == "string"
      and (not best or j.time .. j.by > best.time .. best.by) then best = j end
  end
  return best
end
function mirror.publish_order(proj, room_dir, me)
  local band = require("band")
  reaper.RecursiveCreateDirectory(room_dir .. "/order", 0)
  band.write_json(room_dir .. "/order/" .. me:gsub("[^%w%-_ ]", "_") .. ".json", { list = mirrored_order(proj), time = os.date("!%Y-%m-%dT%H:%M:%SZ"), by = me })
end
-- This tab's tracks onto the studio's list, moving as few as it takes. Only with the tab in front (REAPER reorders nowhere else), stopped,
-- and caught up. -> how many moved.
function mirror.keep_order(proj, cfg, song, room)
  local sync = require("sync")
  if reaper.EnumProjects(-1) ~= proj or reaper.GetPlayStateEx(proj) ~= 0 then return 0 end
  if sync.pending_events(proj, cfg, song, room) > 0 then return 0 end
  local room_dir = sync.room_dir(cfg, song, room)
  local best, here = mirror.read_order(room_dir), mirrored_order(proj)
  if not best then -- (nobody's said yet: whoever's here first, and what they have then, is where everyone starts)
    if #here > 0 then mirror.publish_order(proj, room_dir, cfg.user) end
    return 0
  end
  local after = {}
  local listed = {}
  for _, x in ipairs(best.list) do listed[x] = true end
  for _, x in ipairs(here) do
    if not listed[x] then -- (only what's newer than the list: reading each record on every look isn't free)
      local _, _, evid = mirror.known(proj, x)
      local ev = evid and evid ~= "" and event_file(room_dir, evid)
      after[x] = ev and type(ev.state) == "table" and ev.state.after or ""
    end
  end
  local want = mirror.wanted_order(best.list, here, after)
  if table.concat(want, ",") == table.concat(here, ",") then return 0 end
  local moved, n = mirror.moved_tracks(here, want, {}), 0
  local sel = {}
  for i = 0, reaper.CountSelectedTracks(proj) - 1 do sel[#sel + 1] = reaper.GetSelectedTrack(proj, i) end
  reaper.PreventUIRefresh(1)
  for k, x in ipairs(want) do
    local tr = moved[x] and mirror.find(proj, "track", x)
    if tr then
      local above = k > 1 and mirror.find(proj, "track", want[k - 1])
      reaper.SetOnlyTrackSelected(tr)
      reaper.ReorderSelectedTracks(above and math.floor(reaper.GetMediaTrackInfo_Value(above, "IP_TRACKNUMBER")) or 0, 0)
      n = n + 1
    end
  end
  for i = reaper.CountSelectedTracks(proj) - 1, 0, -1 do reaper.SetTrackSelected(reaper.GetSelectedTrack(proj, i), false) end
  for _, x in ipairs(sel) do if reaper.ValidatePtr2(proj, x, "MediaTrack*") then reaper.SetTrackSelected(x, true) end end
  reaper.PreventUIRefresh(-1)
  mirror.order_seen[tostring(proj)] = table.concat(mirrored_order(proj), ",") -- (not a move of this person's: the next look mustn't send it)
  reaper.TrackList_AdjustWindows(false)
  return n
end

-- Use mine: what lost a clash comes back at once, for everyone. mine: { { oid, ev (the event id of your version) } }. -> what happened in words, or nil with nothing to do.
function mirror.use_mine(proj, cfg, song, room, mine, opts)
  local dir, plan = require("sync").room_dir(cfg, song, room), {}
  for _, m in ipairs(mine or {}) do
    local ev = type(m.ev) == "string" and event_file(dir, m.ev)
    if ev and m.oid then plan[m.oid] = (not ev.gone) and ev or false end
  end
  if not next(plan) then return nil end
  return mirror.revert(proj, cfg, song, room, plan, opts)
end

-- Local mixing on: each track's record here is redone without its fader and pan.
function mirror.begin_local_mix(proj)
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    local oid = trk_oid(tr)
    local rev, h, evid, order = mirror.known(proj, oid)
    if rev and h ~= "" then remember(proj, oid, rev, mirror.track_hash(mirror.track_state(proj, tr), true), evid, order) end
  end
end

-- Local mixing off again: either adopt the band's faders and pan (each track as its newest revision has them), or
-- send yours (each track's next look counts as a change; it goes out if you may change that track).
function mirror.end_local_mix(proj, cfg, song, room, adopt)
  local band, sync = require("band"), require("sync")
  local rdir = sync.room_dir(cfg, song, room)
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    local oid = trk_oid(tr)
    local rev, h, evid, order = mirror.known(proj, oid)
    if rev then
      if adopt then
        local ev = evid ~= "" and band.read_json(rdir .. "/events/" .. evid .. ".json")
        if type(ev) == "table" and type(ev.state) == "table" then
          if ev.state.vol and ev.state.vol ~= "" then reaper.SetMediaTrackInfo_Value(tr, "D_VOL", tonumber(ev.state.vol)) end
          if ev.state.pan and ev.state.pan ~= "" then reaper.SetMediaTrackInfo_Value(tr, "D_PAN", tonumber(ev.state.pan)) end
          for _, kp in ipairs(mirror.TRACK_MIX) do
            if tonumber(ev.state[kp[1]]) then reaper.SetMediaTrackInfo_Value(tr, kp[2], tonumber(ev.state[kp[1]])) end
          end
        end
        local t = mirror.track_state(proj, tr, false)
        remember(proj, oid, rev, mirror.track_hash(t, false), evid, order)
      else
        remember(proj, oid, rev, "-", evid, order) -- (no hash matches "-": the next look sends it)
      end
    end
  end
end

-- One code for this whole project as mirrored (every object's version here): two machines with the same code hold
-- the same project. Published in the status file; Who's here compares it.
function mirror.root(proj)
  local t, i = {}, 0
  while true do
    local ok, oid, v = reaper.EnumProjExtState(proj, mirror.SEC, i)
    if not ok then break end
    i = i + 1
    -- the band's newest change of each thing, not its hash: a plug-in saves its data its own way on each machine, and a
    -- machine without it re-encodes it, so hashes differ for good with nothing different to hear (Surge, UADx, Superior Drummer:
    -- Mac, 0.42.6). What came out differently on landing is what "mirror drift" reports.
    local h, ev = v:match("^%d+|([^|]*)|([^|]*)")
    if h and h ~= "" then t[#t + 1] = oid:upper() .. "=" .. tostring(ev) end
  end
  table.sort(t)
  return mirror.hash(table.concat(t, "\n"))
end


-- ---- side rooms ------------------------------------------------------------------------------------------
-- A side room starts as a copy of its parent tab (ids and all), so both share every object's history up to then.

-- The newest revision of each object among a room's events, optionally only those after `since` (ISO time).
function mirror.room_newest(room_dir, since)
  local band = require("band")
  local out = {}
  for _, f in ipairs(band.files(room_dir .. "/events", ".json")) do
    local ev = band.read_json(room_dir .. "/events/" .. f)
    if type(ev) == "table" and ev.type == "obj" and ev.oid and (not since or (ev.time or "") > since) then
      local cur = out[ev.oid]
      if not cur or mirror.newer({ rev = ev.rev, time = (ev.time or "") .. (ev.user or "") }, { rev = cur.rev, time = (cur.time or "") .. (cur.user or "") }) then
        out[ev.oid] = ev
      end
    end
  end
  return out
end

-- Bring this project in line with the band's newest version of every object whose last change it doesn't hold: a
-- change that was skipped or never landed here (an unreadable file, a failed apply) left two projects different for
-- good, since nothing applied it again (review, 2026-10-31). Always towards the room's own events, never towards a
-- particular machine, so two machines can't pull each other back and forth. Objects whose newest change this machine
-- already holds are left as they are (what came out different there isn't fixed by applying it again). Returns how
-- many were brought in line.
function mirror.heal(proj, room_dir, local_mix)
  local n = 0
  for oid, ev in pairs(mirror.room_newest(room_dir)) do
    local _, kh, kev = mirror.known(proj, oid)
    if kev ~= ev.id then
      local order = (ev.time or "") .. (ev.user or "")
      if ev.gone then
        if kh and kh ~= "" then
          mirror.apply(proj, { obj = ev.obj, oid = oid, gone = true, track = ev.track }, room_dir .. "/media", local_mix)
          remember(proj, oid, ev.rev, "", ev.id, order)
          n = n + 1
        end
      else
        local ok, applied, h = pcall(mirror.apply, proj, ev, room_dir .. "/media", local_mix)
        if ok and applied then -- (a part waiting for its tab to be in front, or a track not here yet: next time)
          remember(proj, oid, ev.rev, h or "", ev.id, order)
          n = n + 1
        end
      end
    end
  end
  return n
end

-- What bringing a side room into its parent does, from both rooms' changes since the room was made: what only the
-- side room changed comes in; what both changed is a clash, and the parent's stays. Pure.
function mirror.plan_bring(side, main)
  local bring, clash = {}, {}
  for oid, ev in pairs(side) do
    if main[oid] then clash[#clash + 1] = ev else bring[#bring + 1] = ev end
  end
  local o = { track = 1, fx = 2, item = 3 } -- a new track before what sits on it
  table.sort(bring, function(a, x) return (o[a.obj] or 3) < (o[x.obj] or 3) end)
  return bring, clash
end

-- Send revisions into room `to` (as its newest revisions there). `here`:
-- that room's tab on this machine, if open (your own changes never come back to you through Live sync).
function mirror.post_into(cfg, song, from, to, list, here)
  local band, sync = require("band"), require("sync")
  local fdir, tdir = sync.room_dir(cfg, song, from), sync.room_dir(cfg, song, to)
  local newest = mirror.room_newest(tdir)
  reaper.RecursiveCreateDirectory(tdir .. "/media", 0)
  local n = 0
  for _, ev in ipairs(list) do
    -- (its media stays where it is: tokens name their room's folder, which every machine has)
    local cur = newest[ev.oid]
    local new = { type = "obj", obj = ev.obj, oid = ev.oid, rev = (cur and cur.rev or 0) + 1, base = cur and cur.rev or 0,
      state = ev.state, track = ev.track, name = ev.name, pos = ev.pos, gone = ev.gone, from_room = from }
    sync.post(cfg, song, to, new)
    if here and reaper.ValidatePtr2(0, here, "ReaProject*") then mirror.receive(here, new, tdir .. "/media", false) end
    n = n + 1
  end
  return n
end

-- Of these revisions, those this person may make in `to` by that room's claims and driver; and how many they may not.
-- ("Send selected" took a bandmate's claimed item into main with nothing to stop it: laptop, 0.42.2)
function mirror.allowed_into(cfg, song, to, list, session)
  local sync = require("sync")
  local can, who = sync.authority(cfg, song, to, session)
  local keep, refused = {}, 0
  for _, ev in ipairs(list) do
    local t = ev.obj == "track" and ev.oid or ev.track
    if can(cfg.user, ev.name or "", ev.pos) or sync.maker_may(t, cfg.user, ev.name or "", ev.pos, who.mode) then keep[#keep + 1] = ev
    else refused = refused + 1 end
  end
  return keep, refused
end

-- The selected items here (and any track of theirs the other room hasn't got), as revisions to send to `to`.
function mirror.selected(proj, cfg, song, from, to)
  local sync = require("sync")
  local media = sync.room_dir(cfg, song, from) .. "/media"
  local there = mirror.room_newest(sync.room_dir(cfg, song, to))
  local list, tracks = {}, {}
  local _, by_oid = mirror.scan(proj, cfg.user, media, false)
  for i = 0, reaper.CountSelectedMediaItems(proj) - 1 do
    local it = reaper.GetSelectedMediaItem(proj, i)
    local tr = reaper.GetMediaItem_Track(it)
    local toid, ioid = trk_oid(tr), itm_oid(it)
    if toid ~= "" and ioid ~= "" then
      local name = select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false))
      if not tracks[toid] and not there[toid] then
        tracks[toid] = true
        list[#list + 1] = { obj = "track", oid = toid, state = mirror.track_state(proj, tr), name = name }
        -- (with its plug-ins, automation, sends and the rest: a new idea arrived in main without its Neve: Mac, 0.42.4)
        for _, p in ipairs(mirror.PARTS) do
          local o = by_oid[p .. toid:sub(2)]
          if o and o.state ~= "" then list[#list + 1] = { obj = o.kind, oid = o.oid, track = toid, state = o.state, name = name } end
        end
      end
      list[#list + 1] = { obj = "item", oid = ioid, track = toid, state = mirror.item_state(it, media), name = name,
        pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION") }
    end
  end
  return list
end

return mirror
