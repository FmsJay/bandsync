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

-- Make this project match recall point `file`. Only the driver should call this (Live sync posts only
-- what this person may change). Returns a short summary.
function recall.restore(proj, cfg, song, room, file)
  local st = band.read_json(recall.dir(cfg, song, room) .. "/" .. file)
  if not st then return nil, "can't read " .. file end
  recall.save(proj, cfg, song, room, "before restoring " .. (st.label or file))
  local want = {}
  for id, t in pairs(st.takes or {}) do want[id:lower()] = { id = id, t = t } end
  local idx = band.take_index(proj)
  local moved, removed, revived = 0, 0, 0
  reaper.Undo_BeginBlock2(proj)
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
      reaper.SetMediaItemInfo_Value(it, "D_LENGTH", t.len)
      reaper.SetMediaItemInfo_Value(it, "B_MUTE", t.mute or 0)
      reaper.SetMediaItemTakeInfo_Value(tk, "D_STARTOFFS", band.base_offs(tk) + (t.offs or 0))
      if t.lane then reaper.SetMediaItemInfo_Value(it, "I_FIXEDLANE", t.lane) end
      if t.active then reaper.SetActiveTake(tk) end
      reaper.UpdateItemInProject(it)
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
