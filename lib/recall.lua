-- Recall points: snapshots of the shared arrangement (which takes exist, where they sit, which take or lane
-- plays, track mute/solo/colour/icon), saved at every handover and whenever someone asks. Restoring one
-- makes the driver's project match it; Live sync then posts the differences as usual, so everyone follows.
-- Takes deleted since come back out of _trash. Restoring saves a "before restore" point first, so going
-- back and forth between options is always possible.
local band = require("band")
local sync = require("sync")
local recall = {}

function recall.dir(cfg, song, room) return sync.room_dir(cfg, song, room) .. "/recall" end

local function capture(proj)
  local st = { takes = {}, plays = {}, tracks = {} }
  for i = 0, reaper.CountMediaItems(proj) - 1 do
    local it = reaper.GetMediaItem(proj, i)
    local active = reaper.GetActiveTake(it)
    for k = 0, reaper.CountTakes(it) - 1 do
      local tk = reaper.GetTake(it, k)
      local id = band.take_id(tk)
      if id then
        st.takes[id] = { track = sync.track_name(it), pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION"),
          len = reaper.GetMediaItemInfo_Value(it, "D_LENGTH"), lane = sync.lane_of(it), mute = reaper.GetMediaItemInfo_Value(it, "B_MUTE"),
          offs = reaper.GetMediaItemTakeInfo_Value(tk, "D_STARTOFFS") - band.base_offs(tk), active = tk == active }
      end
    end
  end
  for t = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, t)
    local any, ids = sync.audible(tr)
    if any and band.track_ext(tr, "band_stem") == "" and sync.speaks_for_name(proj, tr) then
      local name = sync.base_name(select(2, reaper.GetTrackName(tr)))
      local list = {}
      for id in ids:gmatch("[^,]+") do list[#list + 1] = id end
      st.plays[name] = list
      st.tracks[name] = { mute = reaper.GetMediaTrackInfo_Value(tr, "B_MUTE"), solo = reaper.GetMediaTrackInfo_Value(tr, "I_SOLO"),
        color = reaper.GetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR"),
        icon = select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_ICON", "", false)) }
    end
  end
  return st
end

function recall.save(proj, cfg, song, room, label)
  local st = capture(proj)
  st.label, st.by, st.time = label, cfg.user, os.date("!%Y-%m-%dT%H:%M:%SZ")
  st.timeline = { tempo = band.capture_tempo(proj), markers = band.capture_markers(proj) } -- positions are in its seconds
  local dir = recall.dir(cfg, song, room)
  reaper.RecursiveCreateDirectory(dir, 0)
  local file = string.format("%s-%s-%s.json", os.date("!%Y%m%d-%H%M%SZ"), (cfg.user:gsub("[^%w%-_]", "_")),
    (label:gsub("[^%w%-_ ]", ""):gsub(" ", "_"):sub(1, 40)))
  band.write_json(dir .. "/" .. file, st)
  return file
end

-- Newest first: { file, label, by, time, takes = count }
function recall.list(cfg, song, room)
  local dir, out = recall.dir(cfg, song, room), {}
  local files = band.files(dir, ".json")
  for i = #files, 1, -1 do
    local st = band.read_json(dir .. "/" .. files[i])
    if st then
      local n = 0
      for _ in pairs(st.takes or {}) do n = n + 1 end
      out[#out + 1] = { file = files[i], label = st.label or files[i], by = st.by, time = st.time, takes = n }
    end
  end
  return out
end

-- ---- history: every take and change, in order -----------------------------------------------------
-- Entries are { time, id, user, kind = "take" | event type, ... }: a take's arrival (from its manifest's
-- first placement) or an event as posted. Sorted by time, then id.

function recall.entries(cfg, song, room)
  local out = {}
  local rdir = sync.room_dir(cfg, song, room)
  for _, d in ipairs({ band.takes_dir(cfg, song, room), rdir .. "/_trash" }) do -- deleted takes still have a past
    for _, f in ipairs(band.files(d, ".json")) do
      local m = band.read_json(d .. "/" .. f)
      if m and m.id and m.user then
        local o = m.origin or { pos = m.pos, len = m.len, track = sync.base_name(m.track), lane = m.lane, sent = m.sent }
        out[#out + 1] = { kind = "take", time = o.sent or m.sent or "", id = m.id, take = m.id, user = m.user,
          track = o.track, pos = o.pos, len = o.len, lane = o.lane, midi = m.midi and true or nil }
      end
    end
  end
  for _, f in ipairs(band.files(rdir .. "/events", ".json")) do
    local ev = band.read_json(rdir .. "/events/" .. f)
    if ev and ev.id and ev.time then ev.kind = ev.type; out[#out + 1] = ev end
  end
  table.sort(out, function(a, x) return (a.time .. a.id) < (x.time .. x.id) end)
  return out
end

-- The arrangement after entries[1..upto], in recall-point form ({ takes, plays, tracks }). Pure: no REAPER calls.
function recall.replay(entries, upto)
  local st = { takes = {}, plays = {}, tracks = {} }
  local gone = {} -- deleted takes keep their last shape, for an undelete
  for i = 1, math.min(upto or #entries, #entries) do
    local e = entries[i]
    local id = e.take and e.take:lower()
    if e.kind == "take" then
      st.takes[id] = { id = e.take, track = e.track, pos = e.pos, len = e.len, lane = e.lane, mute = 0, offs = 0 }
    elseif e.kind == "delete" and st.takes[id] then
      gone[id], st.takes[id] = st.takes[id], nil
    elseif e.kind == "undelete" and gone[id] then
      st.takes[id], gone[id] = gone[id], nil
    elseif e.kind == "edit" and st.takes[id] then
      local t = st.takes[id]
      t.track, t.pos, t.len, t.lane = e.track or t.track, e.pos or t.pos, e.len or t.len, e.lane
      t.mute, t.offs = e.mute or t.mute, e.offs or t.offs
    elseif e.kind == "plays" then
      st.plays[e.track] = e.takes or {}
    elseif e.kind == "track" then
      if e.was and st.tracks[e.was] then st.tracks[e.was] = nil end
      st.tracks[e.track] = { mute = e.mute, solo = e.solo, color = e.color, icon = e.icon }
    elseif e.kind == "timeline" or (e.kind == "shift" and e.tempo) then -- an insert/remove carries the map it left
      st.timeline = { tempo = e.tempo, markers = e.markers }
    end
  end
  -- which takes play: the newest "plays" per track picks the active take of each item
  local active = {}
  for _, list in pairs(st.plays) do for _, id in ipairs(list) do active[id:lower()] = true end end
  local out = { takes = {}, plays = st.plays, tracks = st.tracks, timeline = st.timeline }
  for lid, t in pairs(st.takes) do
    out.takes[t.id] = { track = t.track, pos = t.pos, len = t.len, lane = t.lane, mute = t.mute, offs = t.offs, active = active[lid] or nil }
  end
  return out
end

-- One line per entry, for the history list.
function recall.describe(e)
  local whose = e.take and ((e.take:match("^(.-)%-%d+%-%d+Z") or e.take) .. "'s take") or ""
  local on = e.track and (" on " .. e.track) or "" -- events from before 0.5 don't name the track
  if e.kind == "take" then
    return string.format("recorded %s%s at %.2f s%s", e.midi and "a MIDI take" or "a take", on, e.pos or 0, e.lane and (" (lane " .. (e.lane + 1) .. ")") or "")
  elseif e.kind == "edit" then
    return string.format("moved/trimmed %s%s to %.2f s%s", whose, on, e.pos or 0, (e.mute or 0) > 0 and ", muted" or "")
  elseif e.kind == "delete" then return "deleted " .. whose .. on
  elseif e.kind == "undelete" then return "brought back " .. whose .. on
  elseif e.kind == "midi" then return "edited the notes of " .. whose .. on
  elseif e.kind == "plays" then return string.format("%s: now playing %d take(s)", tostring(e.track), #(e.takes or {}))
  elseif e.kind == "track" then
    if e.changed then -- 0.7.6+: only what changed
      local parts = {}
      for _, f in ipairs(e.changed) do
        parts[#parts + 1] = f == "mute" and ((e.mute or 0) > 0 and "muted" or "unmuted") or f == "solo" and ((e.solo or 0) > 0 and "soloed" or "unsoloed")
          or f == "color" and "colour changed" or f == "icon" and "icon changed" or f == "name" and "renamed"
          or f == "vol" and tonumber(e.vol) and string.format("volume %.1f dB", 20 * math.log(math.max(tonumber(e.vol), 1e-9), 10))
          or f == "pan" and e.pan and (tonumber(e.pan) == 0 and "pan centre" or string.format("pan %d%% %s", math.floor(math.abs(tonumber(e.pan)) * 100 + 0.5), tonumber(e.pan) < 0 and "left" or "right"))
          or f
      end
      return string.format("%s%s: %s", e.was and (e.was .. " renamed to ") or "", tostring(e.track), table.concat(parts, ", "))
    end
    return string.format("%s%s: %s%s", e.was and (e.was .. " renamed to ") or "", tostring(e.track),
      (e.mute or 0) > 0 and "muted" or "unmuted", (e.solo or 0) > 0 and ", soloed" or "")
  elseif e.kind == "driver" then return "took control from " .. tostring(e.from)
  elseif e.kind == "start" then return string.format("%s together from %.2f s", e.rec and "recorded" or "played", e.pos or 0)
  elseif e.kind == "stop" then return "stopped together"
  elseif e.kind == "note" then return "note" .. (e.take and (" on " .. whose) or string.format(" at %.2f s", e.pos or 0)) .. ": " .. tostring(e.text)
  elseif e.kind == "like" then return "liked " .. whose .. on
  elseif e.kind == "shift" then
    return string.format("%s %.2f s at %.2f s (every track)", (e.len or 0) > 0 and "inserted" or "removed", math.abs(e.len or 0), e.at or 0)
  elseif e.kind == "solo" then return "Solo edit version" .. (e.note and (": " .. e.note) or "") .. string.format(" (%d change(s))", #(e.changes or {}))
  elseif e.kind == "timeline" then
    local t, changes = e.tempo or {}, {}
    for i, m in ipairs(t) do
      changes[#changes + 1] = string.format("%g bpm%s at %.2f s", m.bpm, (m.num or 0) > 0 and string.format(" %d/%d", m.num, m.denom) or "", m.time)
    end
    return string.format("changed the tempo map (%s), %d marker(s)/region(s)", table.concat(changes, ", "), #(e.markers or {}))
  end
  return tostring(e.kind)
end

-- Consecutive entries by one person, while one driver drives and without a long pause, form a group:
-- { user, driver, first, last (entry indexes), from, to (times) }.
-- A pause of more than 3 minutes also starts a new group, so a long session doesn't become one restore point.
local function secs(iso)
  local y, mo, d, h, mi, s = (iso or ""):match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  return y and os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = s }) or 0
end
function recall.groups(entries, host)
  local groups, driver = {}, host
  for i, e in ipairs(entries) do
    if e.kind == "driver" then driver = e.driver or e.user end
    local g = groups[#groups]
    if not g or g.user ~= e.user or g.driver ~= driver or secs(e.time) - secs(g.to) > 180 then
      g = { user = e.user, driver = driver, first = i, from = e.time }
      groups[#groups + 1] = g
    end
    g.last, g.to = i, e.time
  end
  return groups
end

-- Make this project match recall point `file`. Only the driver should call this (Live sync posts only
-- what this person may change). Returns a short summary.
function recall.restore(proj, cfg, song, room, file)
  local st = band.read_json(recall.dir(cfg, song, room) .. "/" .. file)
  if not st then return nil, "can't read " .. file end
  return recall.restore_state(proj, cfg, song, room, st, st.label or file)
end

-- Make this project match state st (a recall point, or recall.replay's result).
function recall.restore_state(proj, cfg, song, room, st, label)
  st.label = label
  local file = label
  recall.save(proj, cfg, song, room, "before restoring " .. (st.label or file))
  local want = {}
  for id, t in pairs(st.takes or {}) do want[id:lower()] = { id = id, t = t } end
  local idx = band.take_index(proj)
  local moved, removed, revived = 0, 0, 0
  reaper.Undo_BeginBlock2(proj)
  if st.timeline and st.timeline.tempo and band.json_encode({ st.timeline.tempo, st.timeline.markers or {} }) ~= sync.timeline_sig(proj) then
    band.apply_tempo(proj, st.timeline.tempo)
    band.apply_markers(proj, st.timeline.markers or {})
    sync.post(cfg, song, room, { type = "timeline", tempo = st.timeline.tempo, markers = st.timeline.markers or {} })
    sync.setext(proj, band.SECTION, "timeline", sync.timeline_sig(proj))
  end
  for lid, hit in pairs(idx) do -- here now, not in the recall point: delete (it goes to _trash, recoverable)
    if not want[lid] and sync.delete_take(proj, hit[1], hit[2], band.take_id(hit[2]) or lid) then
      removed = removed + 1
      local mit = band.find_midi(proj, lid) -- a revived take's MIDI copy comes back with its import
      if mit then reaper.DeleteTrackMediaItem(reaper.GetMediaItem_Track(mit), mit) end
    end
  end
  idx = band.take_index(proj)
  local takes_dir, trash = band.takes_dir(cfg, song, room), sync.room_dir(cfg, song, room) .. "/_trash"
  for lid, w in pairs(want) do
    local hit, t = idx[lid], w.t
    if not hit then -- deleted since: bring its files back and let everyone (us included) import it again
      local found = false
      for _, f in ipairs(band.files(trash)) do
        local lf = f:lower()
        if lf:sub(1, #lid + 1) == lid .. "." or lf:sub(1, #lid + 1) == lid .. "-" then
          os.rename(trash .. "/" .. f, takes_dir .. "/" .. f)
          found = true
        end
      end
      if found then
        local chunk = sync.ext(proj, sync.ITEMS, w.id)
        if chunk ~= "" then -- ours: rebuild the real item (source, take FX) on our real track, not its print
          local tr = band.find_track(proj, t.track, true) or band.new_track(proj, t.track)
          local it = tr and reaper.AddMediaItemToTrack(tr)
          if it and reaper.SetItemStateChunk(it, chunk, false) then
            band.set_take_state(proj, w.id, "full")
            local tk = band.take_index(proj)[lid]
            if tk then hit = tk end
          end
        else -- someone else's: import it again, then put it where the recall point had it
          band.set_take_state(proj, w.id, "")
          sync.setext(proj, sync.PENDING, w.id, band.json_encode(t))
        end
        sync.post(cfg, song, room, { type = "undelete", take = w.id, track = t.track, pos = t.pos })
        sync.post(cfg, song, room, { type = "edit", take = w.id, track = t.track, pos = t.pos, len = t.len, lane = t.lane,
          mute = t.mute, offs = t.offs }) -- applied by each receiver once the take has arrived
        revived = revived + 1
      end
    end
    if hit then
      local it, tk = hit[1], hit[2]
      reaper.SetMediaItemInfo_Value(it, "C_LOCK", 0)
      if t.track and sync.track_name(it):lower() ~= t.track:lower() then
        local dest = band.dest_track(proj, t.track, band.take_ext(tk, "band_wet") == "1")
        if dest then reaper.MoveMediaItemToTrack(it, dest) end
      end
      reaper.SetMediaItemInfo_Value(it, "D_POSITION", t.pos)
      reaper.SetMediaItemInfo_Value(it, "D_LENGTH", t.len + (tonumber(sync.ext(proj, sync.TAILS, w.id)) or 0))
      reaper.SetMediaItemInfo_Value(it, "B_MUTE", t.mute or 0)
      reaper.SetMediaItemTakeInfo_Value(tk, "D_STARTOFFS", band.base_offs(tk) + (t.offs or 0))
      if t.lane then reaper.SetMediaItemInfo_Value(it, "I_FIXEDLANE", t.lane) end
      if t.active then reaper.SetActiveTake(tk) end
      reaper.UpdateItemInProject(it)
      local mit = band.find_midi(proj, w.id) -- its "(MIDI)" copy sits under it
      if mit then
        reaper.SetMediaItemInfo_Value(mit, "D_POSITION", t.pos)
        reaper.SetMediaItemInfo_Value(mit, "D_LENGTH", t.len)
        reaper.UpdateItemInProject(mit)
      end
      moved = moved + 1
    end
  end
  for name, list in pairs(st.plays or {}) do sync.set_plays(proj, name, list) end
  for name, p in pairs(st.tracks or {}) do
    local tr = band.find_track(proj, name, true) or band.find_track(proj, name .. " (band)", true)
    if tr then
      reaper.SetMediaTrackInfo_Value(tr, "B_MUTE", p.mute or 0)
      reaper.SetMediaTrackInfo_Value(tr, "I_SOLO", p.solo or 0)
      reaper.SetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR", p.color or 0)
      reaper.GetSetMediaTrackInfo_String(tr, "P_ICON", p.icon or "", true)
    end
  end
  reaper.Undo_EndBlock2(proj, "BandSync: restore " .. (st.label or file), -1)
  reaper.UpdateArrange()
  return string.format("restored '%s': %d take(s) set, %d removed, %d brought back", st.label or file, moved, removed, revived)
end

return recall
