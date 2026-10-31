-- Mirror sync: every machine in a room holds the same project (see docs/mirror-design.md).
-- This file's top half is pure (chunk normalizing, hashing, ordering, merging) so it runs under any Lua.
local mirror = {}

-- Lines in an item chunk that are this machine's business only: selection, REAPER's own ids (regenerated on
-- apply), MIDI pooling (a copy is its own item), MIDI editor view state, and which take is active (wet/dry is
-- each person's choice).
local LOCAL = { "SEL", "IGUID", "IID", "GUID", "POOLEDEVTS", "CFGEDITVIEW", "CFGEDIT", "EVTFILTER", "KEYSNAP", "TRACKSEL" }
local LOCAL_SET = {}
for _, k in ipairs(LOCAL) do LOCAL_SET[k] = true end
-- P_EXT keys that travel: our object id, and mirrored markers (band_m_*). Everything else is this machine's.
local function ext_travels(key) return key == "band_oid" or key:sub(1, 7) == "band_m_" end

-- Normalized item chunk: what the band shares about this item, byte-identical on every machine that holds it.
function mirror.normalize_item(chunk)
  local out, in_ext = {}, false
  for line in chunk:gmatch("[^\r\n]+") do
    local s = line:match("^%s*(.-)%s*$")
    local key = s:match("^(%S+)")
    if in_ext then
      if s == ">" then in_ext = false; out[#out + 1] = s
      elseif key and ext_travels(key) then out[#out + 1] = s end
    elseif s == "<EXT" or s == "<EXTI" then -- (REAPER writes an item's P_EXT as <EXTI, a track's or take's as <EXT)
      in_ext = true; out[#out + 1] = s
    elseif key == "TAKE" then
      out[#out + 1] = "TAKE" -- ("TAKE SEL" marks the active take: local)
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
local FX_LOCAL = { FXID = true, FLOATPOS = true, FLOAT = true, WNDRECT = true, SHOW = true, LASTSEL = true, DOCKED = true }
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
      elseif not e.restored and not undone[e.id] then return i end
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

-- Track settings that travel, as one line (order matters only for hashing). Faders and pan always travel, but with
-- Local mixing on they aren't a change here. Never: record arm, input, monitoring, height, selection.
function mirror.track_hash(t, local_mix) return mirror.hash(mirror.track_line(t, local_mix) .. "|" .. (t.after or "")) end
function mirror.track_line(t, local_mix)
  -- (colour isn't part of it: it travels with a real change, but auto-colouring (SWS) recolours new tracks on every
  -- machine, and counting that as a change made machines recolour each other)
  local f = { t.name or "", t.parent or "", t.depth or 0, t.mute or 0, t.solo or 0, t.phase or 0, t.icon or "",
    t.freemode or 0, t.lanes or 0, t.plays or "", t.lanenames or "", t.collapsed or 0, local_mix and "" or (t.vol or ""), local_mix and "" or (t.pan or "") }
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
local function remember(proj, oid, rev, h, evid, order)
  setext(proj, oid, string.format("%d|%s|%s|%s", rev or 0, h or "", evid or "", order or ""))
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
  for _, kp in ipairs({ { "freemode", "I_FREEMODE" }, { "lanes", "I_NUMFIXEDLANES" }, { "mute", "B_MUTE" }, { "solo", "I_SOLO" },
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
  if not local_mix then
    if t.vol and t.vol ~= "" then reaper.SetMediaTrackInfo_Value(tr, "D_VOL", tonumber(t.vol)) end
    if t.pan and t.pan ~= "" then reaper.SetMediaTrackInfo_Value(tr, "D_PAN", tonumber(t.pan)) end
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
  local keeper, matched = {}, {}
  for k, x in ipairs(list) do
    if x.oid ~= "" and not matched[x.oid] then
      local known = x.guid == select(2, reaper.GetProjExtState(proj, mirror.GSEC, x.oid))
      if not keeper[x.oid] or known then keeper[x.oid], matched[x.oid] = k, known end -- (the first that REAPER knows wins)
    end
  end
  for k, x in ipairs(list) do
    if x.oid == "" or keeper[x.oid] ~= k then x.oid = mirror.new_oid(kind, user); set_oid(x.ptr, x.oid) end
    if select(2, reaper.GetProjExtState(proj, mirror.GSEC, x.oid)) ~= x.guid then reaper.SetProjExtState(proj, mirror.GSEC, x.oid, x.guid) end
  end
end

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
    end
  end
  local il = {}
  for i = 0, reaper.CountMediaItems(proj) - 1 do
    local it = reaper.GetMediaItem(proj, i)
    local toid = tracks[reaper.GetMediaItem_Track(it)]
    if toid then
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
function mirror.find(proj, kind, oid)
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

-- Apply one revision (an "obj" event) here. Returns true when done, false to try again later (its track or its
-- media hasn't arrived yet), and the hash now held.
function mirror.apply(proj, ev, media_dir, local_mix)
  local kind, oid = ev.obj, ev.oid
  if ev.gone then
    local p = mirror.find(proj, kind == "fx" and "track" or kind, kind == "fx" and ev.track or oid)
    if p and kind == "item" then reaper.DeleteTrackMediaItem(reaper.GetMediaItem_Track(p), p)
    elseif p and kind == "track" then reaper.DeleteTrack(p) end
    return true, ""
  end
  if kind == "track" then
    local tr = mirror.find(proj, "track", oid)
    if not tr then
      local idx = 0 -- under the track it sat under there (or first)
      local above = ev.state.after ~= "" and mirror.find(proj, "track", ev.state.after)
      if above then idx = math.floor(reaper.GetMediaTrackInfo_Value(above, "IP_TRACKNUMBER")) end
      reaper.InsertTrackInProject(proj, idx, 0) -- (InsertTrackAtIndex only knows the tab in front; REAPER 7.18+)
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
    local _, chunk = reaper.GetTrackStateChunk(tr, "", false)
    local sync = require("sync")
    local block = (ev.state or ""):gsub("\n$", "")
    local new = sync.chunk_set_block(chunk, "FXCHAIN", block ~= "" and block or nil)
    if new and new ~= chunk then reaper.SetTrackStateChunk(tr, new, false) end
    -- the band's chain replaced this machine's translations too: put them back (they're never part of the hash)
    if select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_local_fx", "", false)) ~= "" then
      reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_local_fx", "", true)
      local cfg = require("band").settings()
      if cfg then pcall(require("page_plugins").apply_here, proj, cfg) end
    end
    local _, after = reaper.GetTrackStateChunk(tr, "", false)
    local skip = {}
    for g in select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_local_fx", "", false)):gmatch("({[^}]+})for=") do skip[g] = true end
    return true, mirror.hash(mirror.fxchain(after, skip) or "")
  elseif kind == "item" then
    local tr = mirror.find(proj, "track", ev.track)
    if not tr then return false end
    for _, path in ipairs(mirror.media_needed(ev.state, media_dir)) do
      if not reaper.file_exists(path) then return false end -- still on its way
    end
    local it = mirror.find(proj, "item", oid)
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
    require("sync").put_back(string.format("%s also changed %s while you were apart: theirs is in. Yours is in History " ..
      "(Undo specific change on theirs brings yours back)", tostring(ev.user), (ev.name or "") ~= "" and ("something on " .. ev.name) or "the same thing"))
  end
  local ok, h = mirror.apply(proj, ev, media_dir, local_mix)
  if ok then remember(proj, ev.oid, ev.rev, h, ev.id, order) end
  if ok and ev.hash and h ~= ev.hash and not ev.gone then -- applied, but it isn't what they have: the projects differ
    local band = require("band")
    local n = (tonumber(reaper.GetExtState(band.SECTION, "mirror drift " .. tostring(proj))) or 0) + 1
    reaper.SetExtState(band.SECTION, "mirror drift " .. tostring(proj), tostring(n), false)
    band.log(string.format("%s's change to %s came out different here than on their machine (the panel's Health shows it)", tostring(ev.user),
      (ev.name or "") ~= "" and ("something on " .. ev.name) or "an unnamed track"))
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
  local idx = reaper.CountTracks(proj)
  reaper.InsertTrackInProject(proj, idx, 0)
  local tr = reaper.GetTrack(proj, idx)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", label, true)
  reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_local", "yours", true)
  return tr
end

-- One pass: what changed here goes out if this person may change it, else the band's version is put back.
-- opts: local_mix, can (sync.authority's), mode (room mode). Returns sent, put back.
function mirror.watch(proj, cfg, song, room, opts)
  local band, sync = require("band"), require("sync")
  if reaper.JS_Mouse_GetState and reaper.JS_Mouse_GetState(1) & 1 == 1 then return 0, 0 end -- mid-drag: wait for the drop
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
    return opts.mode ~= "driver" and mirror.creator(t) == mirror.user_tag(me)
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
      else -- it can't land here (its track is gone): the band's state wins, and that has no such item
        if o.kind == "item" and o.ptr and reaper.ValidatePtr2(proj, o.ptr, "MediaItem*") then reaper.DeleteTrackMediaItem(reaper.GetMediaItem_Track(o.ptr), o.ptr) end
        remember(proj, o.oid, rev or 0, "", evid, (ev.time or "") .. (ev.user or ""))
      end
    elseif not rev then
      -- never the band's: something new this person may not add. Kept here, on a track of their own (never deleted)
      if o.kind == "item" and o.ptr then reaper.MoveMediaItemToTrack(o.ptr, keep_track(proj, why.name or ""))
      elseif o.kind == "track" and o.ptr then reaper.GetSetMediaTrackInfo_String(o.ptr, "P_EXT:band_local", "yours", true) end
    else
      -- known, but its last change can't be read here (still arriving, or from another room): left as it is
      return say_once("noev" .. o.oid, "couldn't put back a change on " .. ((why.name or "") ~= "" and why.name or "an unnamed track") ..
        " (the band's version hasn't arrived here yet): it stays as it is for now")
    end
    back = back + 1
    sync.put_back(why.text)
  end
  local seen = {}
  for _, o in ipairs(objs) do
    seen[o.oid] = true
    local ok, err = pcall(function()
      local rev, h, evid = mirror.known(proj, o.oid)
      if h == o.hash then return end
      if o.kind == "fx" then -- only while stopped, once it has settled: not a whole chain (or a put-back) per knob turn
        if not rev and o.state == "" then return end -- (an empty chain nobody has sent: nothing to share)
        local key = tostring(proj) .. o.oid -- (per tab: a side room's copy shares the oid)
        local f = mirror.fx_seen[key]
        if playing then return end
        if not f or f.hash ~= o.hash then mirror.fx_seen[key] = { hash = o.hash, since = reaper.time_precise() }; return end
        if reaper.time_precise() - f.since < 3 then return end
      end
      local name = perm_name(o, by_oid)
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
          name = name, pos = o.pos, hash = o.hash } -- (hash: what it is here; every receiver checks it came out the same)
        local id = sync.post(cfg, song, room, ev)
        remember(proj, o.oid, ev.rev, o.hash, id, (ev.time or "") .. me)
        sent = sent + 1
      else
        put_back(o, rev, evid, { name = ok_before and name or (last.name or ""), text = string.format("%s on %s isn't yours to change right now: put back (claim it, or take control)",
          o.kind == "item" and "that item" or o.kind == "fx" and "the plug-ins" or "that track", (ok_before and name or last.name or "") ~= "" and (ok_before and name or last.name) or "an unnamed track") })
      end
    end)
    if not ok then say_once("err" .. o.oid, "mirror sync skipped " .. o.oid .. ": " .. tostring(err)) end
  end
  -- MIDI prints: an item whose newest change is this person's gets a fresh print once its notes, length or the
  -- band's plug-in chain on its track changed (it goes out on the next pass). Only theirs, so two machines never take
  -- turns re-printing one item. Rendering needs this tab in front and the transport stopped; two per pass at most.
  if reaper.EnumProjects(-1) == proj and not playing then
    local prints, made = require("prints"), 0
    for _, o in ipairs(objs) do
      if made < 2 and o.kind == "item" and reaper.ValidatePtr2(proj, o.ptr, "MediaItem*") then
        local _, _, kev = mirror.known(proj, o.oid)
        local fx = by_oid["F" .. o.track:sub(2)]
        if kev and kev:upper():sub(1, #mine_prefix) == mine_prefix and fx then
          local ok, did = pcall(prints.refresh, proj, o.ptr, media, fx.hash)
          if ok and did then made = made + 1 end
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
      if o.kind == "fx" then -- (its track went: the track's own deletion covers it)
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
  return sent, back
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
    if oid ~= "" then set[oid], set["F" .. oid:sub(2)], any = true, true, true end
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
    elseif not (opts.can(cfg.user, name, p.t and p.t.pos or nil) or (opts.mode ~= "driver" and mirror.creator(p.t and p.t.obj == "track" and p.oid or (p.t and p.t.track) or p.oid) == mirror.user_tag(cfg.user))) then
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
      local kind = p.oid:sub(1, 1) == "T" and "track" or p.oid:sub(1, 1) == "F" and "fx" or "item"
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
