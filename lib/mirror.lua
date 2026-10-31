-- Mirror sync: every machine in a room holds the same project (see docs/mirror-design.md).
-- This file's top half is pure (chunk normalizing, hashing, ordering, merging) so it runs under any Lua.
local mirror = {}

-- Lines in an item chunk that are this machine's business only: selection, REAPER's own ids (regenerated on
-- apply), MIDI pooling (a copy is its own item), MIDI editor view state, which take is active (wet/dry is each
-- person's choice) and item grouping (group numbers are per project: another machine's group 3 is other items).
local LOCAL = { "SEL", "IGUID", "IID", "GUID", "POOLEDEVTS", "POOLCOLOR", "CFGEDITVIEW", "CFGEDIT", "EVTFILTER", "KEYSNAP", "TRACKSEL", "GROUP" }
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

-- A track's automation ("E-" + its oid) and its receives ("R-", each with its send envelopes) travel as objects of
-- their own, cut out of the track chunk and spliced back in. Writing a track chunk back keeps its plug-ins running
-- (measured, REAPER 7.83: no @init, even with a changed parameter). Which envelopes show, which is armed and how
-- tall its lane is stay each person's own. A receive names its source track by oid (REAPER's chunk says its
-- position); receives from a track that isn't mirrored (Real time, live views) stay as they are on each machine.
mirror.HV = 2 -- how object hashes are made: bump it whenever what goes into one changes (events carry it as hv)
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
function mirror.hash(s)
  local h = 2166136261
  for i = 1, #s do
    h = h ~ s:byte(i)
    h = (h * 16777619) & 0xFFFFFFFF
  end
  return string.format("%08x", h)
end

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
function mirror.plan_restore(entries, upto, in_scope)
  local at, last = {}, {}
  for i, e in ipairs(entries) do
    if e.kind == "obj" and e.oid then
      last[e.oid] = e
      if i <= upto then at[e.oid] = e end
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
  for j = i - 1, 1, -1 do
    local p = entries[j]
    if p.kind == "obj" and p.oid == e.oid then return { [e.oid] = (not p.gone) and p or false } end
  end
  return { [e.oid] = false }
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
      elseif not e.restored and not e.auto and not undone[e.id] then return i end -- (auto: a print BandSync refreshed)
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
      elseif not e.restored then return nil end -- a new change since: nothing to redo
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
function mirror.track_hash(t, local_mix) return mirror.hash(mirror.track_line(t, local_mix) .. "|" .. (t.after or "")) end
-- More of a track's settings, as { field, REAPER parameter }: the FX button, channels, the parent/master send and
-- its channels, timebase, playback offset, solo defeat, lane settings and pan law; MIX ones follow Local mixing.
mirror.TRACK_MORE = { { "fxen", "I_FXEN" }, { "nchan", "I_NCHAN" }, { "mainsend", "B_MAINSEND" }, { "msoffs", "C_MAINSEND_OFFS" },
  { "msnch", "C_MAINSEND_NCH" }, { "timebase", "C_BEATATTACHMODE" }, { "playoffs", "D_PLAY_OFFSET" }, { "playoffsflag", "I_PLAY_OFFSET_FLAG" },
  { "solodefeat", "B_SOLO_DEFEAT" }, { "lanesettings", "C_LANESETTINGS" }, { "panlaw", "D_PANLAW" }, { "panlawflags", "I_PANLAW_FLAGS" } }
mirror.TRACK_MIX = { { "width", "D_WIDTH" }, { "panmode", "I_PANMODE" }, { "dualpanl", "D_DUALPANL" }, { "dualpanr", "D_DUALPANR" } }

function mirror.track_line(t, local_mix)
  -- (colour isn't part of it: it travels with a real change, but auto-colouring (SWS) recolours new tracks on every
  -- machine, and counting that as a change made machines recolour each other)
  local f = { t.name or "", t.parent or "", t.depth or 0, t.mute or 0, "", t.phase or 0, t.icon or "", -- ("": solo is each person's own)
    t.freemode or 0, t.lanes or 0, t.plays or "", t.lanenames or "", t.collapsed or 0, local_mix and "" or (t.vol or ""), local_mix and "" or (t.pan or "") }
  for _, kp in ipairs(mirror.TRACK_MORE) do f[#f + 1] = t[kp[1]] or "" end
  for _, kp in ipairs(mirror.TRACK_MIX) do f[#f + 1] = local_mix and "" or (t[kp[1]] or "") end
  for i, v in ipairs(f) do f[i] = tostring(v):gsub("|", "/") end
  return table.concat(f, "|")
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
-- BandSync's own helper tracks (the SonoBus return, stems) never mirror
local function local_track(tr) -- (also live placeholders and live MIDI views: each machine draws its own)
  return select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_local", "", false)) ~= ""
    or select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_live_track", "", false)) ~= ""
end

-- A track's travelling settings (see track_line).
function mirror.track_state(proj, tr, local_mix)
  local parent = reaper.GetParentTrack(tr)
  local t = { name = select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)), parent = parent and trk_oid(parent) or "",
    depth = reaper.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH"), mute = reaper.GetMediaTrackInfo_Value(tr, "B_MUTE"),
    solo = reaper.GetMediaTrackInfo_Value(tr, "I_SOLO"), phase = reaper.GetMediaTrackInfo_Value(tr, "B_PHASE"),
    color = reaper.GetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR"), icon = select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_ICON", "", false)),
    freemode = reaper.GetMediaTrackInfo_Value(tr, "I_FREEMODE"), lanes = reaper.GetMediaTrackInfo_Value(tr, "I_NUMFIXEDLANES"),
    collapsed = reaper.GetMediaTrackInfo_Value(tr, "C_LANESCOLLAPSED") }
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
  for _, kp in ipairs({ { "freemode", "I_FREEMODE" }, { "lanes", "I_NUMFIXEDLANES" }, { "mute", "B_MUTE" },
      { "phase", "B_PHASE" }, { "color", "I_CUSTOMCOLOR" }, { "collapsed", "C_LANESCOLLAPSED" }, { "depth", "I_FOLDERDEPTH" } }) do
    if t[kp[1]] then reaper.SetMediaTrackInfo_Value(tr, kp[2], tonumber(t[kp[1]]) or 0) end
  end
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
  for _, kp in ipairs(mirror.TRACK_MORE) do
    if tonumber(t[kp[1]]) then reaper.SetMediaTrackInfo_Value(tr, kp[2], tonumber(t[kp[1]])) end -- (a sender without it: left)
  end
  if not local_mix then
    if t.vol and t.vol ~= "" then reaper.SetMediaTrackInfo_Value(tr, "D_VOL", tonumber(t.vol)) end
    if t.pan and t.pan ~= "" then reaper.SetMediaTrackInfo_Value(tr, "D_PAN", tonumber(t.pan)) end
    for _, kp in ipairs(mirror.TRACK_MIX) do
      if tonumber(t[kp[1]]) then reaper.SetMediaTrackInfo_Value(tr, kp[2], tonumber(t[kp[1]])) end
    end
  end
end

-- An item's travelling state: its normalized chunk, plus its lane (REAPER keeps an item's fixed lane out of the
-- item's chunk, so it gets a line of its own).
function mirror.item_state(it, media_dir)
  local _, chunk = reaper.GetItemStateChunk(it, "", false)
  local st = mirror.tokenize_media(mirror.normalize_item(chunk), media_dir)
  if reaper.GetMediaTrackInfo_Value(reaper.GetMediaItem_Track(it), "I_FREEMODE") == 2 then
    st = st .. "BANDLANE " .. math.floor(reaper.GetMediaItemInfo_Value(it, "I_FIXEDLANE")) .. "\n"
  end
  return st
end

-- Every mirrored object in the project, with its normalized state and hash. Objects with no oid, or a copy that
-- carries another object's oid, get a fresh oid here (they are new). `media_dir`: the room's media folder.
-- Copies (Ctrl+drag, paste, duplicate track) carry their source's oid. Whichever of them REAPER's own GUID shows to
-- be the one this machine already knew keeps the oid, wherever it sits (a copy placed before its source must not take
-- it: the source would then look new and be put back); the others become new objects. Returns the oid per entry.
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
    if x.oid == "" or keeper[x.oid] ~= k then x.oid = mirror.new_oid(kind, user); set_oid(x.ptr, x.oid) end
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
mirror.auto = {} -- proj .. oid -> its next send is a print BandSync refreshed (Undo skips those)

function mirror.scan(proj, user, media_dir, local_mix)
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
  for _, x in ipairs(tl) do
    local tr, oid = x.ptr, x.oid
    do
      local t = mirror.track_state(proj, tr, local_mix)
      local o = { kind = "track", oid = oid, ptr = tr, state = t, hash = mirror.track_hash(t, local_mix) }
      objs[#objs + 1], by_oid[oid], tracks[tr] = o, o, oid
      local _, chunk = reaper.GetTrackStateChunk(tr, "", false)
      local skip = {} -- this machine's plug-in translations (lib/page_plugins.lua): never sent
      for g in select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_local_fx", "", false)):gmatch("({[^}]+})for=") do skip[g] = true end
      local fx = mirror.fxchain(chunk, skip) or ""
      local fo = { kind = "fx", oid = "F" .. oid:sub(2), ptr = tr, track = oid, state = fx, hash = mirror.hash(fx) }
      objs[#objs + 1], by_oid[fo.oid] = fo, fo
      local env, recv, misc = mirror.track_parts(chunk, oid_at)
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
    local menv = mirror.track_parts(mch, oid_at) .. mirror.ai_lines(master)
    for _, p in ipairs({ { "F-MASTER", "fx", mfx }, { "E-MASTER", "env", menv } }) do
      local po = { kind = p[2], oid = p[1], ptr = master, track = mirror.MASTER, state = p[3], hash = mirror.hash(p[3]) }
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
    local o = { kind = "item", oid = x.oid, ptr = x.ptr, track = x.toid, state = norm, hash = mirror.hash(x.toid .. "\n" .. norm),
      pos = reaper.GetMediaItemInfo_Value(x.ptr, "D_POSITION") }
    objs[#objs + 1], by_oid[x.oid] = o, o
  end
  return objs, by_oid
end

-- Media an item uses from outside the room's media folder is copied in (once) so the band has it. Returns the
-- chunk with paths rewritten to the copies.
function mirror.share_media(chunk, media_dir)
  reaper.RecursiveCreateDirectory(media_dir, 0)
  local room = norm_path(media_dir):match("([^/]+)/media/?$") or "main"
  return (chunk:gsub('(FILE ")([^"]+)(")', function(a, path, z)
    if path:find("^{media") then return a .. path .. z end
    local name = path:gsub("\\", "/"):match("[^/]+$") or "media"
    local copy = mirror.hash(path:lower()) .. "-" .. name
    local dst = media_dir .. "/" .. copy
    if not reaper.file_exists(dst) and reaper.file_exists(path) then pcall(require("band").copy_atomic, path, dst) end
    -- (only once the copy is really there: pointing at a copy that was never made left everyone waiting for it)
    if reaper.file_exists(dst) then return a .. "{media:" .. room .. "}/" .. copy .. z end
    return a .. path .. z
  end))
end

-- Find a track or item by oid.
-- The master track travels as two parts only, F-MASTER (its plug-ins) and E-MASTER (its automation): its fader and
-- pan are each person's listening level. ReaNINJAM and SonoBus on it are this machine's live link, never sent.
mirror.MASTER = "T-MASTER"
function mirror.live_fx(tr)
  local set = {}
  for i = 0, reaper.TrackFX_GetCount(tr) - 1 do
    local _, name = reaper.TrackFX_GetFXName(tr, i, "")
    if name:find("ReaNINJAM", 1, true) or name:find("SonoBus", 1, true) then set[reaper.TrackFX_GetFXGUID(tr, i)] = true end
  end
  return set
end

function mirror.find(proj, kind, oid)
  if oid == mirror.MASTER then return reaper.GetMasterTrack(proj) end
  if kind == "item" then
    for i = 0, reaper.CountMediaItems(proj) - 1 do
      local it = reaper.GetMediaItem(proj, i)
      if itm_oid(it) == oid then return it end
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
  if lane then reaper.SetMediaItemInfo_Value(it, "I_FIXEDLANE", lane) end
  reaper.SetMediaItemInfo_Value(it, "I_CUSTOMCOLOR", reaper.ColorToNative(90, 90, 90) | 0x1000000)
  reaper.GetSetMediaItemInfo_String(it, "P_NOTES", "arriving: " .. ((state:match("\nNAME ([^\n]+)") or ""):gsub('^"(.*)"$', "%1")) ..
    " (" .. (track_name or "") .. "), still syncing", true)
  reaper.GetSetMediaItemInfo_String(it, "P_EXT:band_arriving", "1", true)
  reaper.GetSetMediaItemInfo_String(it, "P_EXT:band_oid", oid, true)
  reaper.UpdateItemInProject(it)
end

-- Apply one revision (an "obj" event) here. Returns true when done, false to try again later (its track or its
-- media hasn't arrived yet), and the hash now held.
function mirror.apply(proj, ev, media_dir, local_mix)
  local kind, oid = ev.obj, ev.oid
  if ev.gone then
    local p = mirror.find(proj, kind == "fx" and "track" or kind, kind == "fx" and ev.track or oid)
    if p and kind == "item" then reaper.DeleteTrackMediaItem(reaper.GetMediaItem_Track(p), p)
    elseif p and kind == "track" then -- (auto-colour rules recolour the rest when a track goes: theirs are the band's)
      local colours = {}
      for t = 0, reaper.CountTracks(proj) - 1 do local x = reaper.GetTrack(proj, t); colours[x] = reaper.GetMediaTrackInfo_Value(x, "I_CUSTOMCOLOR") end
      reaper.DeleteTrack(p)
      mirror.keep_colours = { proj = proj, colours = colours, till = reaper.time_precise() + 5 }
      mirror.hold_colours()
    end
    return true, ""
  end
  if kind == "track" then
    local tr = mirror.find(proj, "track", oid)
    if not tr then
      local idx = 0 -- under the track it sat under there (or first)
      local above = ev.state.after ~= "" and mirror.find(proj, "track", ev.state.after)
      if above then idx = math.floor(reaper.GetMediaTrackInfo_Value(above, "IP_TRACKNUMBER")) end
      local colours = {} -- (auto-colour rules recolour the other tracks when one goes in: theirs are the band's)
      for t = 0, reaper.CountTracks(proj) - 1 do local x = reaper.GetTrack(proj, t); colours[x] = reaper.GetMediaTrackInfo_Value(x, "I_CUSTOMCOLOR") end
      reaper.InsertTrackInProject(proj, idx, 0) -- (InsertTrackAtIndex only knows the tab in front; REAPER 7.18+)
      mirror.keep_colours = { proj = proj, colours = colours, till = reaper.time_precise() + 5 }
      mirror.hold_colours()
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
    return true, mirror.track_hash(t, local_mix)
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
    return true, mirror.hash(mirror.fxchain(after, skip) or "")
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
    local lane = tonumber(ev.state:match("BANDLANE (%d+)"))
    reaper.SetItemStateChunk(it, mirror.resolve_media((ev.state:gsub("BANDLANE %d+\n?", "")), media_dir), false)
    reaper.GetSetMediaItemInfo_String(it, "P_EXT:band_oid", oid, true)
    if lane then reaper.SetMediaItemInfo_Value(it, "I_FIXEDLANE", lane) end
    require("prints").choose(it) -- notes or the print, as this machine chose (never part of what travels)
    reaper.SetMediaItemSelected(it, sel)
    reaper.UpdateItemInProject(it)
    return true, mirror.hash(ev.track .. "\n" .. mirror.item_state(it, media_dir))
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
  local order = (ev.time or "") .. (ev.user or "")
  if not mirror.wins(proj, ev.oid, ev.rev or 0, order) then return true end
  -- both changed it while apart: theirs wins everywhere (the same on every machine); ours stays in History
  local krev, _, kev = mirror.known(proj, ev.oid)
  if me and krev and ev.base and ev.base < krev and kev:sub(1, #me + 1):upper() == (me:gsub(" ", "_") .. "-"):upper() then
    require("sync").put_back(string.format("%s also changed %s while you were apart: theirs is in. Yours is on the Restore page " ..
      "(Undo specific change on theirs brings yours back)", tostring(ev.user), (ev.name or "") ~= "" and ("something on " .. ev.name) or "the same thing"))
  end
  local ok, h = mirror.apply(proj, ev, media_dir, local_mix)
  if ok then remember(proj, ev.oid, ev.rev, h, ev.id, order) end
  -- applied, but it isn't what they have: the projects differ (only when made the same way: a change from an older
  -- BandSync hashed fewer of a track's settings, so it always reads as different; the laptop saw 4 on its first open)
  if ok and ev.hash and ev.hv == mirror.HV and h ~= ev.hash and not ev.gone then
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

local function event_file(room_dir, evid) return evid and evid ~= "" and require("band").read_json(room_dir .. "/events/" .. evid .. ".json") or nil end
mirror.event_file = event_file

-- The name permissions use for an object (claims are by track name): its track's name.
local function perm_name(o, by_oid)
  if o.kind == "track" then return o.state.name end
  local t = by_oid[o.track]
  return t and t.state.name or ""
end

mirror.said = mirror.said or {} -- (things said once per session, not every pass)
mirror.fx_seen = mirror.fx_seen or {} -- oid -> { hash, since }: a plug-in chain goes out once it has settled

-- Where a recording this person wasn't allowed to add goes (kept, never deleted): a track of their own, not sent.
local function keep_track(proj, name)
  local label = (name ~= "" and name or "Track") .. " (yours, not sent)"
  for t = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, t)
    if select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)) == label and local_track(tr) then return tr end
  end
  local colours = {} -- (auto-colouring recoloured Keys when this track went in, on the laptop: 2026-10-31)
  for t = 0, reaper.CountTracks(proj) - 1 do local x = reaper.GetTrack(proj, t); colours[x] = reaper.GetMediaTrackInfo_Value(x, "I_CUSTOMCOLOR") end
  local idx = reaper.CountTracks(proj)
  reaper.InsertTrackInProject(proj, idx, 0)
  local tr = reaper.GetTrack(proj, idx)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", label, true)
  reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_local", "yours", true)
  mirror.keep_colours = { proj = proj, colours = colours, till = reaper.time_precise() + 5 }
  mirror.hold_colours()
  return tr
end
-- The band's track colours as they were before a track of your own went in, put back for a few seconds (auto-colour
-- rules may run a moment later).
function mirror.hold_colours()
  local k = mirror.keep_colours
  if not k or reaper.time_precise() > k.till then mirror.keep_colours = nil; return end
  for x, c in pairs(k.colours) do
    if reaper.ValidatePtr2(k.proj, x, "MediaTrack*") and reaper.GetMediaTrackInfo_Value(x, "I_CUSTOMCOLOR") ~= c then
      reaper.SetMediaTrackInfo_Value(x, "I_CUSTOMCOLOR", c)
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
  local playing = reaper.GetPlayStateEx(proj) & 1 == 1
  local mine_prefix = (me:gsub(" ", "_") .. "-"):upper() -- (event ids start with their author's name)
  local function allowed(o, name, pos)
    if opts.can(me, name, pos) then return true end
    -- your own new tracks (and what's on them) are yours, except in Driver only
    local t = o.kind == "track" and o.oid or o.track
    return opts.mode ~= "driver" and mirror.is_creator(t, me)
  end
  local function say_once(key, text)
    if not mirror.said[key] then mirror.said[key] = true; band.log(text) end
  end
  local function put_back(o, rev, evid, why)
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
        why.text = "a new item on " .. where .. " isn't yours to add: it's kept here on '" .. where .. " (yours, not sent)', not sent to the band (claim the track, or take control)"
      elseif o.kind == "track" and o.ptr then
        reaper.GetSetMediaTrackInfo_String(o.ptr, "P_EXT:band_local", "yours", true)
        why.text = "a new track isn't yours to add: it stays here as yours, not sent to the band (take control to add tracks)"
      end
    else
      -- known, but its last change can't be read here (still arriving, or from another room): left as it is
      return say_once("noev" .. o.oid, "couldn't put back a change on " .. ((why.name or "") ~= "" and why.name or "an unnamed track") ..
        " (the band's version hasn't arrived here yet): it stays as it is for now")
    end
    back = back + 1
    if why.text then sync.put_back(why.text) end
  end
  local seen = {}
  for _, o in ipairs(objs) do
    seen[o.oid] = true
    local ok, err = pcall(function()
      local rev, h, evid = mirror.known(proj, o.oid)
      local rk = tostring(proj) .. o.oid
      if h == o.hash then mirror.reopened[rk] = nil; return end
      if mirror.reopened[rk] and rev then -- opened without its last save: the band's version, not this older one
        say_once("reopened" .. tostring(proj), "this project was opened without its last save: what changed since is back as the band has it")
        if h == "" then -- the band deleted it since: gone here too (2026-10-31: three deleted tracks came back on a reopen)
          mirror.reopened[rk] = nil
          if o.kind == "track" or o.kind == "item" then mirror.apply(proj, { obj = o.kind, oid = o.oid, gone = true }, media, opts.local_mix) end
          back = back + 1
          return
        end
        return put_back(o, rev, evid, { name = perm_name(o, by_oid) })
      end
      if not rev and o.state == "" and o.kind ~= "track" and o.kind ~= "item" then return end -- (an empty part nobody has sent)
      -- plug-ins and automation: only while stopped, once settled (not a whole chain per knob turn, or an envelope per
      -- point drawn)
      if o.kind == "fx" or o.kind == "env" then
        local key = tostring(proj) .. o.oid -- (per tab: a side room's copy shares the oid)
        local f = mirror.fx_seen[key]
        if playing then return end
        if not f or f.hash ~= o.hash then mirror.fx_seen[key] = { hash = o.hash, since = reaper.time_precise() }; return end
        if reaper.time_precise() - f.since < 3 then return end
      end
      local name = perm_name(o, by_oid)
      local holder = rev and opts.held and opts.held(o.oid)
      if holder then -- someone else is working on it right now (lib/presence.lua): theirs, for a few seconds
        return put_back(o, rev, evid, { name = name, text = string.format("%s is editing %s right now: put back (try again in a few seconds)",
          holder, o.kind == "track" and ("track " .. (name ~= "" and name or "(unnamed)")) or ((o.kind == "item" and "that item" or mirror.PART[o.kind]) .. " on " .. (name ~= "" and name or "an unnamed track"))) })
      end
      local last = rev and event_file(room_dir, evid) or nil
      -- allowed where it is now, and where it was (moving an item off a claimed track, or renaming a claimed track,
      -- mustn't slip past the claim)
      local ok_now = allowed(o, name, o.pos)
      local ok_before = not last or last.gone or allowed(o, last.name or "", last.pos)
      if ok_now and ok_before then
        local state = o.state
        if o.kind == "item" then
          local shared = mirror.share_media(state, media)
          if shared ~= state then -- it now plays the shared copy here too, so the next look sees the same thing
            reaper.SetItemStateChunk(o.ptr, mirror.resolve_media((shared:gsub("BANDLANE %d+\n?", "")), media), false)
            state = mirror.item_state(o.ptr, media)
            o.hash = mirror.hash(o.track .. "\n" .. state)
          end
        end
        local ev = { type = "obj", obj = o.kind, oid = o.oid, rev = (rev or 0) + 1, base = rev or 0, state = state, track = o.track,
          name = name, pos = o.pos, hash = o.hash, hv = mirror.HV } -- (hash: what it is here; every receiver checks it came out the same)
        if mirror.auto[tostring(proj) .. o.oid] then ev.auto, mirror.auto[tostring(proj) .. o.oid] = true, nil end
        if o.kind == "fx" then ev.files = require("fxfiles").share(state, media) end -- (samples, IRs, models it loads)
        local id = sync.post(cfg, song, room, ev)
        remember(proj, o.oid, ev.rev, o.hash, id, (ev.time or "") .. me)
        require("presence").touch(proj, o.oid)
        sent = sent + 1
      else
        local where = (ok_before and name or last.name or "") ~= "" and (ok_before and name or last.name) or "an unnamed track"
        put_back(o, rev, evid, { name = ok_before and name or (last.name or ""), text = string.format("%s isn't yours to change right now: put back (claim it, or take control)",
          o.kind == "track" and ("track " .. where) or ((o.kind == "item" and "that item" or mirror.PART[o.kind]) .. " on " .. where)) })
      end
    end)
    if not ok then say_once("err" .. o.oid, "mirror sync skipped " .. o.oid .. ": " .. tostring(err)) end
  end
  -- MIDI prints: an item whose newest change is this person's gets a fresh print once its notes, length or the
  -- band's plug-in chain on its track changed (it goes out on the next pass). Only theirs, so two machines never take
  -- turns re-printing one item. Rendering needs this tab in front and the transport stopped; two per pass at most.
  if reaper.EnumProjects(-1) == proj and not playing then
    local prints, made = require("prints"), 0
    prints.watch_ara(proj) -- (a Melodyne window closed: that take gets a new print below)
    for _, o in ipairs(objs) do
      if made < 2 and o.kind == "item" and reaper.ValidatePtr2(proj, o.ptr, "MediaItem*") then
        local _, _, kev = mirror.known(proj, o.oid)
        local fx = by_oid["F" .. o.track:sub(2)]
        if kev and kev:upper():sub(1, #mine_prefix) == mine_prefix and fx then
          local ok, did = pcall(prints.refresh, proj, o.ptr, media, fx.hash)
          if ok and did then made = made + 1; mirror.auto[tostring(proj) .. o.oid] = true end -- (its next send is BandSync's, not theirs)
        end
      end
    end
  end
  -- gone here: deleted (sent, if allowed) or put back
  local i, gone = 0, {}
  while true do
    local ok, oid = reaper.EnumProjExtState(proj, mirror.SEC, i)
    if not ok then break end
    i = i + 1
    local rev, h, evid = mirror.known(proj, oid)
    if not seen[oid] and h ~= "" then gone[#gone + 1] = { oid = oid, rev = rev, evid = evid } end
  end
  for _, g in ipairs(gone) do
    local ok, err = pcall(function()
      local last = event_file(room_dir, g.evid)
      if not last then -- nothing to go on (its last change isn't here): forgotten, not resurrected or repeated
        return remember(proj, g.oid, g.rev or 0, "", g.evid)
      end
      local o = { kind = last.obj or (g.oid:sub(1, 1) == "T" and "track" or "item"), oid = g.oid, track = last.track, state = last.state }
      local name = last.name or ""
      if mirror.PART[o.kind] then -- (its track went: the track's own deletion covers it)
        remember(proj, g.oid, (g.rev or 0) + 1, "", g.evid)
      elseif allowed(o, name, last.pos) then
        local ev = { type = "obj", obj = o.kind, oid = g.oid, rev = (g.rev or 0) + 1, base = g.rev or 0, gone = true, track = o.track, name = name, pos = last.pos }
        local id = sync.post(cfg, song, room, ev)
        remember(proj, g.oid, ev.rev, "", id, (ev.time or "") .. me) -- (with its order: a racing edit is settled alike everywhere)
        sent = sent + 1
      else
        put_back(o, g.rev, g.evid, { name = name, text = string.format("%s on %s isn't yours to delete: it's back",
          o.kind == "track" and "that track" or "that item", name ~= "" and name or "an unnamed track") })
      end
    end)
    if not ok then say_once("err" .. g.oid, "mirror sync skipped " .. g.oid .. ": " .. tostring(err)) end
  end
  mirror.save_ids(proj)
  mirror.summary(proj, cfg, room_dir, objs, media)
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
  require("sync").put_back("a change you made just as control changed hands wasn't yours to make: it's back as the band has it")
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
function mirror.revert(proj, cfg, song, room, plan, opts)
  local sync = require("sync")
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
  local done, refused = 0, 0
  reaper.Undo_BeginBlock2(proj)
  for _, p in ipairs(list) do
    local rev, h, evid = mirror.known(proj, p.oid)
    local name = p.t and p.t.name or ""
    if not p.t and (h or "") == "" then -- gone then, gone now
    elseif p.t and evid == p.t.id then -- already that revision
    elseif not (opts.can(cfg.user, name, p.t and p.t.pos or nil) or (opts.mode ~= "driver" and mirror.is_creator(p.t and p.t.obj == "track" and p.oid or (p.t and p.t.track) or p.oid, cfg.user))) then
      refused = refused + 1
    elseif p.t then
      local ok, nh = mirror.apply(proj, p.t, media, opts.local_mix)
      if ok then
        local ev = { type = "obj", obj = p.t.obj, oid = p.oid, rev = (rev or 0) + 1, state = p.t.state, track = p.t.track, name = name, pos = p.t.pos, restored = p.t.id,
          undoes = opts.undoes, redoes = opts.redoes }
        local id = sync.post(cfg, song, room, ev)
        remember(proj, p.oid, ev.rev, nh, id, (ev.time or "") .. cfg.user)
        done = done + 1
      end
    else
      local kind = mirror.KIND[p.oid:sub(1, 1)] or "item"
      mirror.apply(proj, { obj = kind, oid = p.oid, gone = true }, media, opts.local_mix)
      local gev = { type = "obj", obj = kind, oid = p.oid, rev = (rev or 0) + 1, base = rev or 0, gone = true, undoes = opts.undoes, redoes = opts.redoes }
      local id = sync.post(cfg, song, room, gev)
      remember(proj, p.oid, gev.rev, "", id, (gev.time or "") .. cfg.user)
      done = done + 1
    end
  end
  reaper.Undo_EndBlock2(proj, "BandSync: go back", -1)
  reaper.UpdateArrange()
  return string.format("%d change(s) brought back and sent to the band%s", done, refused > 0 and string.format(" (%d not yours to change, left as they are)", refused) or "")
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
    local h = v:match("^%d+|([^|]*)|")
    if h and h ~= "" then t[#t + 1] = oid:upper() .. "=" .. h end
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

-- The selected items here (and any track of theirs the other room hasn't got), as revisions to send to `to`.
function mirror.selected(proj, cfg, song, from, to)
  local sync = require("sync")
  local media = sync.room_dir(cfg, song, from) .. "/media"
  local there = mirror.room_newest(sync.room_dir(cfg, song, to))
  local list, tracks = {}, {}
  for i = 0, reaper.CountSelectedMediaItems(proj) - 1 do
    local it = reaper.GetSelectedMediaItem(proj, i)
    local tr = reaper.GetMediaItem_Track(it)
    local toid, ioid = trk_oid(tr), itm_oid(it)
    if toid ~= "" and ioid ~= "" then
      local name = select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false))
      if not tracks[toid] and not there[toid] then
        tracks[toid] = true
        list[#list + 1] = { obj = "track", oid = toid, state = mirror.track_state(proj, tr), name = name }
      end
      list[#list + 1] = { obj = "item", oid = ioid, track = toid, state = mirror.item_state(it, media), name = name,
        pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION") }
    end
  end
  return list
end

return mirror
