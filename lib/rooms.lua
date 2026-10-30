-- Rooms: a song's main room, and side rooms people make to try their own edits (or work on something else) and
-- have everyone come and see. Each room is its own project tab, so going between them is a tab switch: nothing
-- reloads. A side room starts as a copy of the room it came from, as it was then:
--   rooms/<room>/room.json   { parent = "main", by, time, base = <its first recall point: the parent as it was> }
-- Its own recordings live in its own takes/ (the parent's takes are already in every copy). What's good goes
-- back to the parent two ways: "Send selected" copies chosen takes over (the default), and "Bring into" compares
-- three versions (the base, the parent now, the side room now) and brings every side-room change that doesn't
-- clash, listing the clashes to pick (lib/rooms.lua plan / merge).
local band = require("band")
local sync = require("sync")
local rooms = {}

function rooms.meta(cfg, song, room) return band.read_json(sync.room_dir(cfg, song, room) .. "/room.json") end

local function file_of(proj)
  for i = 0, math.huge do
    local p, f = reaper.EnumProjects(i)
    if not p then return nil end
    if p == proj then return f end
  end
end

-- This machine's tab of song/room (never a Solo edit copy), or nil.
function rooms.tab(song, room)
  for i = 0, math.huge do
    local p = reaper.EnumProjects(i)
    if not p then return nil end
    local b = band.binding(p)
    if b and b.song == song and b.room == room and b.role ~= "solo" then return p end
  end
end

-- The song's rooms, main first, then rooms the host gathers (older BandSync), then side rooms oldest first:
-- { name, parent, by, time }
function rooms.list(cfg, song)
  local out = {}
  for _, name in ipairs(band.subdirs(band.song_dir(cfg, song) .. "/rooms")) do
    local m = rooms.meta(cfg, song, name) or {}
    out[#out + 1] = { name = name, parent = m.parent, by = m.by, time = m.time or "" }
  end
  table.sort(out, function(a, z)
    if (a.name == "main") ~= (z.name == "main") then return a.name == "main" end
    if (a.parent == nil) ~= (z.parent == nil) then return a.parent == nil end
    return (a.time .. a.name) < (z.time .. z.name)
  end)
  return out
end

-- Who's in a room: { {user, here, me} }. Bandmates from their status receipts (under 45 s old; `here` = it's the
-- tab in front of them), you from your own tabs.
function rooms.people(cfg, song, room)
  local out = {}
  local dir = sync.room_dir(cfg, song, room) .. "/status"
  for _, f in ipairs(band.files(dir, ".json")) do
    local st = band.read_json(dir .. "/" .. f)
    if type(st) == "table" and type(st.user) == "string" and st.user ~= cfg.user and type(st.time) == "string"
        and band.age(st.time) < 45 then
      out[#out + 1] = { user = st.user, here = st.front ~= false } -- (receipts before 0.16 don't say)
    end
  end
  table.sort(out, function(a, z) return a.user < z.user end)
  local p = rooms.tab(song, room)
  if p then table.insert(out, 1, { user = cfg.user, here = p == reaper.EnumProjects(-1), me = true }) end
  return out
end

-- Live plug-ins carry this machine's identity: a second connected SonoBus (or ReaNINJAM) in another tab would
-- join the band twice. A new room's tab starts with them offline; Same room there turns SonoBus on.
local function live_offline(proj)
  for t = -1, reaper.CountTracks(proj) - 1 do
    local tr = t < 0 and reaper.GetMasterTrack(proj) or reaper.GetTrack(proj, t)
    for i = 0, reaper.TrackFX_GetCount(tr) - 1 do
      local _, name = reaper.TrackFX_GetFXName(tr, i, "")
      if name:find("SonoBus", 1, true) or name:find("ReaNINJAM", 1, true) then reaper.TrackFX_SetOffline(tr, i, true) end
    end
  end
end

-- Go to a room: its tab if open here; else the tab it had here before (its file, reopened); else a new tab made
-- from this machine's tab of the room it came from, saved next to it (same media paths, nothing copied).
-- `from` is the tab asking (any room of the song). Returns the tab, or nil + why. Doesn't start Live sync there.
function rooms.open(from, cfg, b, name)
  local p = rooms.tab(b.song, name)
  if p then reaper.SelectProjectInstance(p); return p end
  local m = rooms.meta(cfg, b.song, name)
  local src = m and m.parent and rooms.tab(b.song, m.parent) or from
  local src_file = file_of(src) or ""
  if src_file == "" then return nil, "Save this project first." end
  local path = src_file:gsub("\\", "/"):match("^(.*)/") .. "/" .. b.song .. " - " .. name:gsub("[^%w%-_ ]", "") .. " (room).rpp"
  local fresh = not reaper.file_exists(path)
  if fresh then reaper.Main_SaveProjectEx(src, path, 0) end -- a copy; the open project keeps its own file
  reaper.Main_OnCommand(40859, 0) -- File: New project tab
  reaper.Main_openProject("noprompt:" .. path)
  p = reaper.EnumProjects(-1)
  if file_of(p) ~= path and (file_of(p) or ""):gsub("\\", "/") ~= path then return nil, "REAPER didn't open " .. path end
  if fresh then
    local nb = {}
    for k, v in pairs(band.binding(src) or b) do nb[k] = v end
    -- a host gathers the rooms of older BandSync into its project: a side room's tab never does
    nb.room, nb.role = name, nb.role == "host" and "guest" or nb.role
    band.bind(p, nb)
    for _, k in ipairs({ "alone_last", "side", "hold" }) do reaper.SetProjExtState(p, band.SECTION, k, "") end
    live_offline(p)
    reaper.Main_SaveProject(p, false)
  end
  return p
end

-- Why a room name can't be used, or nil. Pure. (Windows can't make folders called CON, NUL, COM1... at all.)
function rooms.bad_name(name)
  if not name:match("^[%w][%w %-_]*$") or #name > 30 then return "Room names: up to 30 letters, numbers, spaces, - or _." end
  local l = name:lower():gsub("%s+$", "")
  if l == "con" or l == "prn" or l == "aux" or l == "nul" or l:match("^com%d$") or l:match("^lpt%d$") then
    return "'" .. name .. "' is a name Windows keeps for itself: pick another."
  end
end

-- Make a side room from the room in tab `proj` (binding b), as it is now, and go there. You drive it.
function rooms.create(proj, cfg, b, name)
  name = (name or ""):match("^%s*(.-)%s*$")
  local err = rooms.bad_name(name)
  if err then return nil, err end
  for _, r in ipairs(rooms.list(cfg, b.song)) do
    if r.name:lower() == name:lower() then return nil, "There's already a room called '" .. r.name .. "'." end
  end
  local dir = sync.room_dir(cfg, b.song, name)
  for _, sub in ipairs({ "takes", "events", "recall", "_trash" }) do reaper.RecursiveCreateDirectory(dir .. "/" .. sub, 0) end
  local base = require("recall").save(proj, cfg, b.song, name, "made from " .. b.room, true)
  sync.set_driver(cfg, b.song, name, cfg.user)
  band.write_json(dir .. "/room.json", { parent = b.room, by = cfg.user, time = os.date("!%Y-%m-%dT%H:%M:%SZ"), base = base })
  return rooms.open(proj, cfg, b, name)
end

-- ---- come see ---------------------------------------------------------------------------------------------
-- One file per person (<song>/invites/<user>.json), replaced by their next invite.
function rooms.invite(cfg, song, room)
  local dir = band.song_dir(cfg, song) .. "/invites"
  reaper.RecursiveCreateDirectory(dir, 0)
  band.write_json(dir .. "/" .. (cfg.user:gsub("[^%w%-_]", "_")) .. ".json",
    { from = cfg.user, room = room, time = os.date("!%Y-%m-%dT%H:%M:%SZ") })
end

-- Bandmates' invites from the last 15 minutes: { {from, room, time} }
function rooms.invites(cfg, song)
  local dir, out = band.song_dir(cfg, song) .. "/invites", {}
  for _, f in ipairs(band.files(dir, ".json")) do
    local v = band.read_json(dir .. "/" .. f)
    if type(v) == "table" and type(v.from) == "string" and v.from ~= cfg.user and type(v.room) == "string"
        and type(v.time) == "string" and band.age(v.time) < 900 then out[#out + 1] = v end
  end
  return out
end

-- ---- send selected: copy takes recorded in one room into another ------------------------------------------
-- `list` = { {id, shape = {track, pos, len, lane, qn} or nil} }. Copies each take's current print (and its dry
-- twin and MIDI) with its manifest, placed where `shape` says (else where it was recorded). Everyone in `to`
-- gets them like any new take; the original stays in `from`. Returns how many were copied.
function rooms.copy_takes(cfg, song, from, to, list)
  local fdir, tdir = band.takes_dir(cfg, song, from), band.takes_dir(cfg, song, to)
  local froom, troom = sync.room_dir(cfg, song, from), sync.room_dir(cfg, song, to)
  reaper.RecursiveCreateDirectory(tdir, 0)
  local n = 0
  for _, t in ipairs(list) do
    local m = band.read_json(fdir .. "/" .. t.id .. ".json")
    if m and m.full and not reaper.file_exists(tdir .. "/" .. t.id .. ".json") then
      for _, k in ipairs({ "full", "preview", "dry", "midi" }) do
        if m[k] and reaper.file_exists(fdir .. "/" .. m[k]) then band.copy_atomic(fdir .. "/" .. m[k], tdir .. "/" .. m[k]) end
      end
      if m.fxchain and reaper.file_exists(froom .. "/" .. m.fxchain) and not reaper.file_exists(troom .. "/" .. m.fxchain) then
        reaper.RecursiveCreateDirectory((troom .. "/" .. m.fxchain):match("^(.*)/"), 0)
        band.copy_atomic(froom .. "/" .. m.fxchain, troom .. "/" .. m.fxchain)
      end
      local s = t.shape
      if s then m.track, m.pos, m.len, m.lane, m.qn = s.track or m.track, s.pos or m.pos, s.len or m.len, s.lane, s.qn or m.qn end
      m.room, m.from_room = to, from
      band.write_json(tdir .. "/" .. t.id .. ".json", m) -- the manifest last: its files are there when it lands
      n = n + 1
    end
  end
  return n
end

-- Where a take sits in tab `proj` now, for its copy's manifest (the length without the reverb tail its print has).
function rooms.shape(proj, id, it)
  local pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
  return { track = sync.track_name(it), pos = pos, qn = sync.qn(proj, pos), lane = sync.lane_of(it),
    len = reaper.GetMediaItemInfo_Value(it, "D_LENGTH") - (tonumber(sync.ext(proj, sync.TAILS, id)) or 0) }
end

-- The selected items' takes recorded in side room `from` and not yet in `to`, ready for copy_takes:
-- list, plus how many selected takes were already there or not sent yet.
function rooms.selected_takes(proj, cfg, song, from, to)
  local list, had, unsent = {}, 0, 0
  for i = 0, reaper.CountSelectedMediaItems(proj) - 1 do
    local it = reaper.GetSelectedMediaItem(proj, i)
    for k = 0, reaper.CountTakes(it) - 1 do
      local id = band.take_id(reaper.GetTake(it, k))
      if not id then
        unsent = unsent + 1
      elseif reaper.file_exists(band.takes_dir(cfg, song, to) .. "/" .. id .. ".json") then
        had = had + 1
      elseif reaper.file_exists(band.takes_dir(cfg, song, from) .. "/" .. id .. ".json") then
        list[#list + 1] = { id = id, shape = rooms.shape(proj, id, it) }
      else
        had = had + 1 -- the parent's own take (it came with the copy)
      end
    end
  end
  return list, had, unsent
end

-- ---- bring into: a three-way merge ------------------------------------------------------------------------
-- Changes are compared in recall-point form (lib/recall.lua capture: takes {track, pos, len, lane, mute, offs,
-- active, notes}, plays, tracks, timeline). For each take, track and "what plays": changed only in the side
-- room -> it's brought; only in the parent -> it stays; in both differently -> a clash to pick.

-- (numbers read back from JSON are 0 where REAPER says 0.0: compare them as numbers)
local function n(v) return v == nil and "-" or string.format("%.4f", tonumber(v) or 0) end
local function shape_sig(t)
  if not t then return "gone" end
  return table.concat({ tostring(t.track), n(t.pos), n(t.len), n(t.lane), n(t.mute or 0), n(t.offs or 0), tostring(t.active and true or false) }, "|")
end
local function list_sig(l) local c = {}; for i, v in ipairs(l or {}) do c[i] = tostring(v):lower() end; table.sort(c); return table.concat(c, ",") end
local function props_sig(p) return p and (n(p.mute or 0) .. "|" .. n(p.solo or 0)) or "" end
local function tl_sig(st) return st.timeline and band.json_encode({ st.timeline.tempo or {}, st.timeline.markers or {} }) or "" end
local function lower_keys(t) local o = {}; for k, v in pairs(t or {}) do o[k:lower()] = { id = k, v = v } end; return o end

-- Pure. Returns { items = { {kind, key, track, side, main, clash, label} }, new = { ids recorded in the side room
-- only }, timeline = nil | "side" | "main" | "both" }. kind: "take" (side/main = a shape, or false = deleted),
-- "plays" (lists), "track" (props), "notes" (MIDI hashes). Items are only the side room's changes.
-- What changed in a take's shape, in words (moved, trimmed, muted...). Pure.
local function shape_words(b, s)
  local w = {}
  local function differ(x, y) return x ~= nil and y ~= nil and math.abs((tonumber(x) or 0) - (tonumber(y) or 0)) > 1e-4 end
  if b.track ~= s.track then w[#w + 1] = "moved to " .. tostring(s.track)
  elseif differ(b.pos, s.pos) then w[#w + 1] = "moved" end
  if differ(b.len, s.len) or differ(b.offs, s.offs) then w[#w + 1] = "trimmed" end
  if ((tonumber(b.mute) or 0) > 0) ~= ((tonumber(s.mute) or 0) > 0) then w[#w + 1] = (tonumber(s.mute) or 0) > 0 and "muted" or "unmuted" end
  if tostring(b.lane) ~= tostring(s.lane) and differ(b.lane or 0, s.lane or 0) then w[#w + 1] = "lane changed" end
  if (b.active and true or false) ~= (s.active and true or false) then w[#w + 1] = s.active and "now plays" or "no longer plays" end
  return #w > 0 and table.concat(w, ", ") or "changed"
end

-- `notes`: compare MIDI notes too. Only when all three were captured on this machine: a drum map translates notes on
-- each machine, so another machine's base can't tell an edit from a translation (and old bases used REAPER's hash).
function rooms.plan(base, main, side, notes)
  local out = { items = {}, new = {} }
  local B, M, S = lower_keys(base.takes), lower_keys(main.takes), lower_keys(side.takes)
  local function add(kind, key, track, s, m, clash, label)
    out.items[#out.items + 1] = { kind = kind, key = key, track = track, side = s, main = m, clash = clash, label = label }
  end
  for k, s in pairs(S) do
    if not B[k] and not M[k] then out.new[#out.new + 1] = s.id end
  end
  table.sort(out.new)
  local keys = {}
  for k in pairs(B) do keys[k] = true end
  for k in pairs(S) do if M[k] then keys[k] = true end end -- in the parent before this tab was made (a later joiner's copy)
  for k in pairs(keys) do
    local b, m, s = B[k] and B[k].v, M[k] and M[k].v, S[k] and S[k].v
    local id = (B[k] or M[k] or S[k]).id
    local bs, ms, ss = shape_sig(b), shape_sig(m), shape_sig(s)
    if not b then bs = ms end -- not in the base: the parent's version is where the side room started from
    if ss ~= bs and ss ~= ms then
      local track = (s or m or b).track
      local clash = ms ~= bs or not b -- (not in the base: which of the two is newer can't be told, so you pick)
      local label = not s and "deleted" or not m and "brought back (deleted in the parent)" or not b and "changed" or shape_words(b, s)
      add("take", id, track, s or false, m or false, clash, label)
    end
    local bn, mn, sn = b and b.notes, m and m.notes, s and s.notes
    if not b then bn = mn end
    local comparable = notes and type(sn) == "string" and sn:sub(1, 3) == "n2:" and type(mn) == "string" and mn:sub(1, 3) == "n2:"
      and type(bn) == "string" and bn:sub(1, 3) == "n2:"
    if comparable and s and m and sn ~= bn and sn ~= mn then add("notes", id, s.track, sn, mn, mn ~= bn or not b, "notes edited") end
  end
  local names = {}
  for _, st in ipairs({ base, main, side }) do for n in pairs(st.plays or {}) do names[n] = true end end
  for n in pairs(names) do
    local bs, ms, ss = list_sig((base.plays or {})[n]), list_sig((main.plays or {})[n]), list_sig((side.plays or {})[n])
    -- (a track only the side room has comes with its new takes)
    local known = (base.plays or {})[n] or (main.plays or {})[n]
    if known and (side.plays or {})[n] and ss ~= bs and ss ~= ms then add("plays", n, n, side.plays[n], (main.plays or {})[n], ms ~= bs, "what plays") end
  end
  names = {}
  for n in pairs(side.tracks or {}) do names[n] = true end
  for n in pairs(names) do
    local bs, ms, ss = props_sig((base.tracks or {})[n]), props_sig((main.tracks or {})[n]), props_sig(side.tracks[n])
    if ((base.tracks or {})[n] or (main.tracks or {})[n]) and ss ~= bs and ss ~= ms then add("track", n, n, side.tracks[n], (main.tracks or {})[n], ms ~= bs, "mute/solo") end
  end
  table.sort(out.items, function(a, z) return (tostring(a.track) .. a.kind .. a.key) < (tostring(z.track) .. z.kind .. z.key) end)
  local tb, tm, ts = tl_sig(base), tl_sig(main), tl_sig(side)
  out.timeline = (ts ~= tb and tm ~= tb and ts ~= tm) and "both" or (ts ~= tb and ts ~= tm) and "side" or (tm ~= tb and tm ~= ts) and "main" or nil
  return out
end

-- Changes on what someone else has claimed in the parent can't come over (the parent's Live sync would put them back:
-- 2026-10-29, a delete on a track the laptop had claimed came straight back): marked `blocked` = whose claim it is,
-- so the preview says so and merged() leaves them. `can`, `owner`: sync.authority's for the parent room. Pure.
function rooms.mark_blocked(plan, can, owner, me)
  for _, it in ipairs(plan.items) do
    local sh = type(it.side) == "table" and it.side or type(it.main) == "table" and it.main or nil
    local pos = sh and sh.pos
    if it.track and not can(me, it.track, pos) then it.blocked = owner(it.track, pos) or "someone" end
  end
end

-- Pure. The parent's state after taking `items` (each with .use = "side" or "main"; clashes default to main,
-- the rest to side) and only those whose track is in `tracks` (nil = all): what recall.restore_state makes the
-- parent's tab match. With `timeline`, the side room's tempo and markers too.
function rooms.merged(main, side, items, tracks, timeline)
  local st = { takes = {}, plays = {}, tracks = {}, musical = main.musical }
  for k, v in pairs(main.takes or {}) do st.takes[k] = v end
  for k, v in pairs(main.plays or {}) do st.plays[k] = v end
  for k, v in pairs(main.tracks or {}) do st.tracks[k] = v end
  local idx = {}
  for k in pairs(st.takes) do idx[k:lower()] = k end
  for _, it in ipairs(items) do
    local use = it.use or (it.clash and "main" or "side")
    if use == "side" and not it.blocked and (not tracks or tracks[it.track or ""]) then
      if it.kind == "take" then
        local key = idx[it.key:lower()] or it.key
        st.takes[key] = it.side or nil
      elseif it.kind == "plays" then st.plays[it.key] = it.side
      elseif it.kind == "track" then st.tracks[it.key] = it.side end
    end
  end
  st.timeline = timeline and side.timeline or nil
  return st
end

-- A take's notes in tab proj: the take itself when it's MIDI (yours), else its "(MIDI)" copy (a bandmate's).
local function midi_take(proj, id)
  local hit = band.take_index(proj)[id:lower()]
  if hit and reaper.TakeIsMIDI(hit[2]) then return hit[2] end
  return select(2, band.find_midi(proj, id))
end

-- Bring side room `room` (tab sproj) into its parent (tab mproj): what plan() listed, as chosen, plus the side
-- room's own recordings on the chosen tracks (copied, landing by beat). The parent's tab changes; its Live sync
-- sends that to everyone there, so only its driver (or someone alone there) should do this. Returns a summary.
function rooms.merge(cfg, song, room, sproj, mproj, plan, side, tracks, timeline)
  local recall = require("recall")
  local m = rooms.meta(cfg, song, room) or {}
  local parent = m.parent or "main"
  recall.save(mproj, cfg, song, parent, "before bringing in " .. room, true)
  local st = rooms.merged(recall.capture(mproj), side, plan.items, tracks, timeline and plan.timeline)
  local can_move = not plan.timeline or timeline -- positions in another tempo map would land wrong: new takes only
  local said = can_move and recall.restore_state(mproj, cfg, song, parent, st, "bring in " .. room, true) or "takes left as they were"
  local notes = 0
  if can_move then
    for _, it in ipairs(plan.items) do
      if it.kind == "notes" and (it.use or (it.clash and "main" or "side")) == "side" and (not tracks or tracks[it.track or ""]) then
        local stk, mtk = midi_take(sproj, it.key), midi_take(mproj, it.key)
        if stk and mtk then
          local ok, buf = reaper.MIDI_GetAllEvts(stk, "")
          if ok then reaper.MIDI_SetAllEvts(mtk, buf); reaper.MIDI_Sort(mtk); notes = notes + 1 end
        end
      end
    end
  end
  local list, idx = {}, band.take_index(sproj)
  for _, id in ipairs(plan.new) do
    local hit = idx[id:lower()]
    if hit and (not tracks or tracks[sync.track_name(hit[1])]) then list[#list + 1] = { id = id, shape = rooms.shape(sproj, id, hit[1]) } end
  end
  local n = rooms.copy_takes(cfg, song, room, parent, list)
  return string.format("%s; %d new take(s) copied in%s", said, n, notes > 0 and string.format("; notes of %d MIDI take(s)", notes) or "")
end

return rooms
