-- BandSync sync engine: printing and sending takes, reprinting them when their sound changes, and keeping
-- everyone's project in step with the session driver's changes (deletes, moves/trims/lane moves, which
-- take or lane plays). Changes travel as small event files; each person writes only files named after
-- themselves, so a sync client never sees two people writing the same file.
local band = require("band")
local sync = {
  SNAP = "BandSync.snap",       -- id -> "<original-case id>|pos|len|offs|lane" as last seen/applied
  PLAYS = "BandSync.plays",     -- track name -> ids audible on it, as last seen/applied
  APPLIED = "BandSync.applied", -- event id -> "1"
  SENTKEYS = "BandSync.sent",   -- source file|offset|length -> id: never send the same audio twice
  REV = "BandSync.rev",         -- id -> revision this project holds
  MIN_LEN = 0.5,                -- shorter items are recording slivers, not takes
}

local function ext(proj, sec, key) return select(2, reaper.GetProjExtState(proj, sec, key)) end
local function setext(proj, sec, key, v) reaper.SetProjExtState(proj, sec, key, v) end
sync.ext, sync.setext = ext, setext

function sync.room_dir(cfg, song, room) return band.song_dir(cfg, song) .. "/rooms/" .. room end

-- The driver is whoever holds control of a room: the host, until someone runs "Take control".
function sync.driver(cfg, song, room, s)
  local d = band.read_json(sync.room_dir(cfg, song, room) .. "/driver.json")
  return d and d.driver or (s and s.host)
end
function sync.set_driver(cfg, song, room, user)
  reaper.RecursiveCreateDirectory(sync.room_dir(cfg, song, room), 0)
  band.write_json(sync.room_dir(cfg, song, room) .. "/driver.json", { driver = user, since = os.date("!%Y-%m-%dT%H:%M:%SZ") })
end

-- ---- where a take sits ---------------------------------------------------------------------------

-- REAPER's lane play state isn't per lane (verified 7.83): setting a lane to 1 plays it exclusively and
-- silences the others, setting any lane to 2 makes every lane play. A track plays one lane, or all.
local function set_lanes_playing(tr, lanes)
  local n = reaper.GetMediaTrackInfo_Value(tr, "I_NUMFIXEDLANES")
  if #lanes == 0 then
    for l = 0, n - 1 do reaper.SetMediaTrackInfo_Value(tr, "C_LANEPLAYS:" .. l, 0) end
  elseif #lanes == 1 then
    reaper.SetMediaTrackInfo_Value(tr, "C_LANEPLAYS:" .. lanes[1], 1)
  else
    reaper.SetMediaTrackInfo_Value(tr, "C_LANEPLAYS:" .. lanes[1], 2)
  end
end
local function lanes_playing(tr)
  local on = {}
  for l = 0, reaper.GetMediaTrackInfo_Value(tr, "I_NUMFIXEDLANES") - 1 do
    if reaper.GetMediaTrackInfo_Value(tr, "C_LANEPLAYS:" .. l) ~= 0 then on[#on + 1] = l end
  end
  return on
end

local function lane_of(it)
  local tr = reaper.GetMediaItem_Track(it)
  if reaper.GetMediaTrackInfo_Value(tr, "I_FREEMODE") ~= 2 or reaper.GetMediaTrackInfo_Value(tr, "I_NUMFIXEDLANES") < 2 then return nil end
  return math.floor(reaper.GetMediaItemInfo_Value(it, "I_FIXEDLANE"))
end
local function shape(it, tk)
  return string.format("%.6f|%.6f|%.6f|%s", reaper.GetMediaItemInfo_Value(it, "D_POSITION"), reaper.GetMediaItemInfo_Value(it, "D_LENGTH"),
    reaper.GetMediaItemTakeInfo_Value(tk, "D_STARTOFFS"), tostring(lane_of(it)))
end
function sync.remember(proj, id, it, tk) setext(proj, sync.SNAP, id, id .. "|" .. shape(it, tk)) end

-- Everything that changes how a print sounds: FX (names, bypass, every parameter), volumes, pan, fades.
-- Track-level parts only matter for wet prints.
local function fxhash(it, tk, wet)
  local tr = reaper.GetMediaItem_Track(it)
  local parts = { reaper.GetMediaItemInfo_Value(it, "D_VOL"), reaper.GetMediaItemTakeInfo_Value(tk, "D_VOL"),
    reaper.GetMediaItemInfo_Value(it, "D_FADEINLEN"), reaper.GetMediaItemInfo_Value(it, "D_FADEOUTLEN") }
  local function fx(count, name, en, np, pv, obj)
    for f = 0, count(obj) - 1 do
      parts[#parts + 1] = select(2, name(obj, f)) .. (en(obj, f) and "+" or "-")
      for p = 0, np(obj, f) - 1 do parts[#parts + 1] = string.format("%.4f", pv(obj, f, p)) end
    end
  end
  fx(reaper.TakeFX_GetCount, reaper.TakeFX_GetFXName, reaper.TakeFX_GetEnabled, reaper.TakeFX_GetNumParams, reaper.TakeFX_GetParamNormalized, tk)
  if wet then
    parts[#parts + 1] = reaper.GetMediaTrackInfo_Value(tr, "D_VOL") .. "/" .. reaper.GetMediaTrackInfo_Value(tr, "D_PAN") ..
      "/" .. reaper.GetMediaTrackInfo_Value(tr, "I_FXEN")
    fx(reaper.TrackFX_GetCount, reaper.TrackFX_GetFXName, reaper.TrackFX_GetEnabled, reaper.TrackFX_GetNumParams, reaper.TrackFX_GetParamNormalized, tr)
  end
  local s, h = table.concat(parts, ";"), 5381
  for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
  return string.format("%08x", h)
end

-- ---- our own takes ------------------------------------------------------------------------------

local function content_key(it, tk) -- position included: a pasted copy is the same audio, somewhere else
  local fn = reaper.GetMediaSourceFileName(reaper.GetMediaItemTake_Source(tk))
  return string.format("%s|%.4f|%.4f|%.4f", fn:match("[^/\\]+$") or fn, reaper.GetMediaItemTakeInfo_Value(tk, "D_STARTOFFS"),
    reaper.GetMediaItemInfo_Value(it, "D_LENGTH"), reaper.GetMediaItemInfo_Value(it, "D_POSITION"))
end

-- Copy/paste, duplicate and split copy an item's P_EXT, so two takes end up carrying one BandSync id.
-- The one still where the snapshot last saw it keeps the id (else the first); the others are new
-- material: their tags are cleared, so Live sync prints and sends them as takes of their own.
-- (After a split, the left half usually keeps the id and goes out as a trim; the right half is new.)
function sync.split_copies(proj)
  local by_id, n = {}, 0
  for i = 0, reaper.CountMediaItems(proj) - 1 do
    local it = reaper.GetMediaItem(proj, i)
    for k = 0, reaper.CountTakes(it) - 1 do
      local tk = reaper.GetTake(it, k)
      local id = band.take_id(tk)
      if id then
        local l = id:lower()
        by_id[l] = by_id[l] or {}
        table.insert(by_id[l], { it, tk, id })
      end
    end
  end
  for _, list in pairs(by_id) do
    if #list > 1 then
      local keep = 1
      for j, u in ipairs(list) do
        if ext(proj, sync.SNAP, u[3]) == u[3] .. "|" .. shape(u[1], u[2]) then keep = j end
      end
      for j, u in ipairs(list) do
        if j ~= keep then
          for _, key in ipairs({ "band_sent", "band_take", "band_fxhash", "band_base_offs", "band_base" }) do band.set_take_ext(u[2], key, "") end
          band.set_item_ext(u[1], "band_take", "")
          band.set_item_ext(u[1], "band_group", "")
          n = n + 1
        end
      end
    end
  end
  return n
end

-- Everything already in a guest's project when sync first runs is baseline (earlier experiments): never
-- auto-sent. A host shares everything instead (Publish marks the project "shared"). Returns count marked.
function sync.mark_baseline(proj)
  if ext(proj, band.SECTION, "baseline") ~= "" then return 0 end
  local n = 0
  for i = 0, reaper.CountMediaItems(proj) - 1 do
    local it = reaper.GetMediaItem(proj, i)
    for k = 0, reaper.CountTakes(it) - 1 do
      local tk = reaper.GetTake(it, k)
      if not band.take_id(tk) then band.set_take_ext(tk, "band_base", "1"); n = n + 1 end
    end
  end
  setext(proj, band.SECTION, "baseline", os.date("!%Y-%m-%dT%H:%M:%SZ"))
  return n
end

-- {item, take} pairs this project recorded itself: not stems, not received, not dry twins.
-- opts.all: every take of each item (else the active one); opts.unsent: skip sent, baseline and
-- already-sent audio; opts.selected: selected items only; opts.min_len: skip shorter items.
function sync.own_takes(proj, opts)
  local out = {}
  local n = opts.selected and reaper.CountSelectedMediaItems(proj) or reaper.CountMediaItems(proj)
  for i = 0, n - 1 do
    local it = opts.selected and reaper.GetSelectedMediaItem(proj, i) or reaper.GetMediaItem(proj, i)
    if band.track_ext(reaper.GetMediaItem_Track(it), "band_stem") == "" and band.item_ext(it, "band_take") == "" then
      local legacy = band.item_ext(it, "band_sent") -- 0.2 marked the item: carry it to the take that was active
      if legacy ~= "" then
        local a = reaper.GetActiveTake(it)
        if a and band.take_ext(a, "band_sent") == "" then band.set_take_ext(a, "band_sent", legacy) end
        band.set_item_ext(it, "band_sent", "")
      end
      local function add(tk)
        if not tk or band.take_ext(tk, "band_take") ~= "" or band.take_ext(tk, "band_dry") ~= "" then return end
        if reaper.GetMediaItemInfo_Value(it, "D_LENGTH") < (opts.min_len or 0) then return end
        if opts.unsent then
          if band.take_ext(tk, "band_sent") ~= "" or band.take_ext(tk, "band_base") ~= "" then return end
          -- the same audio at the same place went out before, unless that take has since been deleted
          -- (delete a paste, paste it back: it must go out again)
          local before = ext(proj, sync.SENTKEYS, content_key(it, tk))
          if before ~= "" and band.take_state(proj, before) ~= "deleted" then return end
        end
        out[#out + 1] = { it, tk }
      end
      if opts.all then
        for k = 0, reaper.CountTakes(it) - 1 do add(reaper.GetTake(it, k)) end
      else
        add(reaper.GetActiveTake(it))
      end
    end
  end
  return out
end

local function dirs(proj, cfg, b)
  local out = (select(2, reaper.EnumProjects(-1)):match("^(.*)[/\\]") or reaper.GetResourcePath()):gsub("\\", "/") .. "/band-out"
  local takes = band.takes_dir(cfg, b.song, b.room)
  reaper.RecursiveCreateDirectory(out, 0)
  reaper.RecursiveCreateDirectory(takes, 0)
  return out, takes
end

-- Render one take as the song prints it and post it as revision `rev` of `id`.
--   wet: through its track's FX, volume and pan, at the item's exact extent
--   dry: take FX, fades and item volume only        both: wet, plus the dry print as a twin
-- Render source 32 ("selected media items") runs the item through its TRACK (FX, volume, pan; verified
-- 7.83), so a dry print bypasses the track's FX and neutralises its volume/pan for the render.
-- Works on the active tab only (REAPER renders the active project).
local function print_take(proj, cfg, b, it, take, id, rev, mode, out, takes)
  local tr = reaper.GetMediaItem_Track(it)
  local suffix = rev > 1 and ("-r" .. rev) or ""
  local nch = reaper.GetMediaSourceNumChannels(reaper.GetMediaItemTake_Source(take))
  local function render(name, wet)
    os.remove(out .. "/" .. name .. ".flac") -- leftovers would make REAPER stop on a modal "files exist" warning
    os.remove(out .. "/" .. name .. ".opus")
    local keys = { "B_MUTE", "I_FXEN", "D_VOL", "D_PAN" }
    local saved, imute, lane = {}, reaper.GetMediaItemInfo_Value(it, "B_MUTE"), lane_of(it)
    for _, k in ipairs(keys) do saved[k] = reaper.GetMediaTrackInfo_Value(tr, k) end
    local playing = lane and lanes_playing(tr)
    -- an alternate in a silent lane, or a muted item/track, must still print
    reaper.SetMediaTrackInfo_Value(tr, "B_MUTE", 0)
    reaper.SetMediaItemInfo_Value(it, "B_MUTE", 0)
    if lane then reaper.SetMediaTrackInfo_Value(tr, "C_LANEPLAYS:" .. lane, 1) end
    if not wet then
      reaper.SetMediaTrackInfo_Value(tr, "I_FXEN", 0)
      reaper.SetMediaTrackInfo_Value(tr, "D_VOL", 1)
      reaper.SetMediaTrackInfo_Value(tr, "D_PAN", 0)
    end
    band.render({ RENDER_SETTINGS = 32, RENDER_BOUNDSFLAG = 4, RENDER_SRATE = 0, RENDER_CHANNELS = wet and 2 or math.min(nch, 2),
      RENDER_TAILFLAG = 0, RENDER_ADDTOPROJ = 0 }, -- &32: selected media items, through their track
      { RENDER_FILE = out, RENDER_PATTERN = name, RENDER_FORMAT = band.FLAC, RENDER_FORMAT2 = band.OPUS })
    for _, k in ipairs(keys) do reaper.SetMediaTrackInfo_Value(tr, k, saved[k]) end
    reaper.SetMediaItemInfo_Value(it, "B_MUTE", imute)
    if lane then set_lanes_playing(tr, playing) end
    return out .. "/" .. name
  end
  local playing = reaper.GetActiveTake(it)
  reaper.SetActiveTake(take) -- renders render the item's active take
  reaper.SelectAllMediaItems(proj, false)
  reaper.SetMediaItemSelected(it, true)
  local main = render(id .. suffix, mode ~= "dry")
  local dry = mode == "both" and render(id .. "-dry" .. suffix, false)
  reaper.SetActiveTake(playing)
  if not reaper.file_exists(main .. ".flac") then band.log("render failed for take " .. id); return nil end

  local lane = lane_of(it)
  local m = {
    format = band.FORMAT, bandsync = band.VERSION, id = id, rev = rev, user = cfg.user, room = b.room,
    track = select(2, reaper.GetTrackName(tr)), pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION"),
    len = reaper.GetMediaItemInfo_Value(it, "D_LENGTH"), session_version = tonumber(b.version),
    sent = os.date("!%Y-%m-%dT%H:%M:%SZ"), full = id .. suffix .. ".flac", print = mode, wet = mode ~= "dry",
    group = select(2, reaper.GetSetMediaItemInfo_String(it, "GUID", "", false)), -- passes of one item stay one item
    lane = lane, lane_name = lane and select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_LANENAME:" .. lane, "", false)) or nil,
  }
  if (band.size(main .. ".opus") or math.huge) < band.size(main .. ".flac") then -- a preview only helps if smaller
    band.copy_atomic(main .. ".opus", takes .. "/" .. id .. suffix .. ".opus")
    m.preview = id .. suffix .. ".opus"
  end
  if dry and reaper.file_exists(dry .. ".flac") then
    band.copy_atomic(dry .. ".flac", takes .. "/" .. id .. "-dry" .. suffix .. ".flac")
    m.dry = id .. "-dry" .. suffix .. ".flac"
  end
  if rev > 1 then -- receivers keep local copies, so the previous revision's shared files can go
    local old = rev > 2 and ("-r" .. (rev - 1)) or ""
    for _, f in ipairs({ id .. old .. ".flac", id .. old .. ".opus", id .. "-dry" .. old .. ".flac" }) do os.remove(takes .. "/" .. f) end
  end
  band.write_json(takes .. "/" .. id .. ".json", m) -- one manifest per take, rewritten for each revision
  band.copy_atomic(main .. ".flac", takes .. "/" .. m.full)
  band.set_take_ext(take, "band_sent", id)
  band.set_take_ext(take, "band_fxhash", fxhash(it, take, mode ~= "dry"))
  band.mark_base(take)
  band.set_take_state(proj, id, "full") -- this project already has it: its own sync must not re-import it
  setext(proj, sync.REV, id, tostring(rev))
  setext(proj, sync.SENTKEYS, content_key(it, take), id)
  sync.remember(proj, id, it, take)
  return m
end

local function finish(proj, sel)
  reaper.SelectAllMediaItems(proj, false)
  for _, it in ipairs(sel) do if reaper.ValidatePtr2(proj, it, "MediaItem*") then reaper.SetMediaItemSelected(it, true) end end
  reaper.UpdateArrange()
  if select(2, reaper.EnumProjects(-1)) ~= "" then reaper.Main_SaveProject(proj, false) end -- sent marks survive a crash
end
local function selection(proj)
  local sel = {}
  for i = 0, reaper.CountSelectedMediaItems(proj) - 1 do sel[#sel + 1] = reaper.GetSelectedMediaItem(proj, i) end
  return sel
end

-- Print and post {item, take} pairs as new takes. Returns how many went out.
function sync.send(proj, cfg, b, units, mode)
  local out, takes = dirs(proj, cfg, b)
  local sel, stamp, seq, sent = selection(proj), os.date("!%Y%m%d-%H%M%SZ"), 0, 0
  for _, u in ipairs(units) do
    local id
    repeat -- per-second ids must not collide when two sends land in one second
      seq = seq + 1
      id = string.format("%s-%s-%d", (cfg.user:gsub(" ", "_")), stamp, seq)
    until not reaper.file_exists(takes .. "/" .. id .. ".json")
    if print_take(proj, cfg, b, u[1], u[2], id, 1, mode or "wet", out, takes) then sent = sent + 1 end
  end
  if sent > 0 then finish(proj, sel) end
  return sent
end

-- Reprint our sent takes whose sound changed (FX added/changed/bypassed, volume, pan, fades) as their
-- next revision; everyone's copy updates in place. Returns how many were reprinted.
function sync.reprint(proj, cfg, b, mode)
  local todo = {}
  for i = 0, reaper.CountMediaItems(proj) - 1 do
    local it = reaper.GetMediaItem(proj, i)
    for k = 0, reaper.CountTakes(it) - 1 do
      local tk = reaper.GetTake(it, k)
      local id = band.take_ext(tk, "band_sent")
      if id ~= "" and band.take_ext(tk, "band_fxhash") ~= fxhash(it, tk, mode ~= "dry") then todo[#todo + 1] = { it, tk, id } end
    end
  end
  if #todo == 0 then return 0 end
  local out, takes = dirs(proj, cfg, b)
  local sel, n = selection(proj), 0
  for _, u in ipairs(todo) do
    local rev = (tonumber(ext(proj, sync.REV, u[3])) or 1) + 1
    if print_take(proj, cfg, b, u[1], u[2], u[3], rev, mode, out, takes) then n = n + 1 end
  end
  finish(proj, sel)
  return n
end

-- ---- events -------------------------------------------------------------------------------------

local ev_seq = 0
function sync.post(cfg, song, room, ev)
  ev_seq = ev_seq + 1
  ev.format, ev.user, ev.time = band.FORMAT, cfg.user, os.date("!%Y-%m-%dT%H:%M:%SZ")
  ev.id = string.format("%s-%s-%d-%04d", (cfg.user:gsub(" ", "_")), os.date("!%Y%m%d-%H%M%SZ"), ev_seq, math.random(0, 9999))
  local dir = sync.room_dir(cfg, song, room) .. "/events"
  reaper.RecursiveCreateDirectory(dir, 0)
  band.write_json(dir .. "/" .. ev.id .. ".json", ev)
  return ev.id
end

-- Move a deleted take's files to the room's _trash, so nobody imports it later and nothing is lost.
function sync.trash(cfg, song, room, id)
  local from, to = band.takes_dir(cfg, song, room), sync.room_dir(cfg, song, room) .. "/_trash"
  reaper.RecursiveCreateDirectory(to, 0)
  for _, f in ipairs(band.files(from)) do
    if f:lower():sub(1, #id + 1) == (id .. "."):lower() or f:lower():sub(1, #id + 1) == (id .. "-"):lower() then
      os.rename(from .. "/" .. f, to .. "/" .. f)
    end
  end
end

-- Delete a take and its dry twin; the whole item when nothing else is in it. Deleting one take can
-- rebuild the item (SWS's NF_DeleteTakeFromItem left the old item pointer invalid), so after every
-- delete the item is found again by GUID and the next doomed take by its BandSync tags. Without SWS,
-- single takes go through an action on the active tab only: false means retry later.
local function delete_take(proj, it, tk, id)
  local lid = id:lower()
  local function doomed(t2) return (band.take_id(t2) or ""):lower() == lid or band.take_ext(t2, "band_dry"):lower() == lid end
  local others = 0
  for k = 0, reaper.CountTakes(it) - 1 do if not doomed(reaper.GetTake(it, k)) then others = others + 1 end end
  if others == 0 then
    reaper.DeleteTrackMediaItem(reaper.GetMediaItem_Track(it), it)
    return true
  end
  -- single takes can only be removed in the active tab: the action needs it, and SWS's NF_DeleteTakeFromItem
  -- rejects items of a background project with a modal "expected MediaItem*" error that pcall can't catch
  if reaper.EnumProjects(-1) ~= proj then return false end
  local guid = select(2, reaper.GetSetMediaItemInfo_String(it, "GUID", "", false))
  local playing = select(2, reaper.GetSetMediaItemTakeInfo_String(reaper.GetActiveTake(it), "GUID", "", false))
  local function find_item()
    for i = 0, reaper.CountMediaItems(proj) - 1 do
      local it2 = reaper.GetMediaItem(proj, i)
      if select(2, reaper.GetSetMediaItemInfo_String(it2, "GUID", "", false)) == guid then return it2 end
    end
  end
  local sel = selection(proj)
  for _ = 1, 8 do -- a take and its twin; bounded so a take that won't delete can't spin forever
    local item = find_item()
    if not item then break end
    local k
    for j = 0, reaper.CountTakes(item) - 1 do if doomed(reaper.GetTake(item, j)) then k = j; break end end
    if not k then break end
    if reaper.NF_DeleteTakeFromItem then
      reaper.NF_DeleteTakeFromItem(item, k)
    else
      reaper.SelectAllMediaItems(proj, false)
      reaper.SetMediaItemSelected(item, true)
      reaper.SetActiveTake(reaper.GetTake(item, k))
      reaper.Main_OnCommand(40129, 0) -- Take: Delete active take from items
    end
  end
  local item = find_item()
  if item then -- keep what was playing, if it survived
    for j = 0, reaper.CountTakes(item) - 1 do
      local t2 = reaper.GetTake(item, j)
      if select(2, reaper.GetSetMediaItemTakeInfo_String(t2, "GUID", "", false)) == playing then reaper.SetActiveTake(t2) end
    end
  end
  reaper.SelectAllMediaItems(proj, false)
  for _, s in ipairs(sel) do if reaper.ValidatePtr2(proj, s, "MediaItem*") then reaper.SetMediaItemSelected(s, true) end end
  return true
end

-- Which BandSync takes are audible on a track: the active take of each item in a playing lane.
-- Returns whether the track holds any BandSync takes, and their sorted ids.
function sync.audible(tr)
  local lanes = reaper.GetMediaTrackInfo_Value(tr, "I_FREEMODE") == 2
  local any, ids = false, {}
  for j = 0, reaper.CountTrackMediaItems(tr) - 1 do
    local it = reaper.GetTrackMediaItem(tr, j)
    local active = reaper.GetActiveTake(it)
    local lane_on = not lanes or reaper.GetMediaTrackInfo_Value(tr, "C_LANEPLAYS:" ..
      math.floor(reaper.GetMediaItemInfo_Value(it, "I_FIXEDLANE"))) ~= 0
    for k = 0, reaper.CountTakes(it) - 1 do
      local tk = reaper.GetTake(it, k)
      local id = band.take_id(tk)
      if id then
        any = true
        if tk == active and lane_on then ids[#ids + 1] = id:lower() end
      end
    end
  end
  table.sort(ids)
  return any, table.concat(ids, ",")
end

local function apply_plays(proj, trackname, list)
  local want, idx = {}, band.take_index(proj)
  for _, id in ipairs(list) do
    want[id:lower()] = true
    -- wait until every take it names is here (unless deleted), or the lanes it names don't exist yet
    if not idx[id:lower()] and band.take_state(proj, id) ~= "deleted" then return false end
  end
  for _, n in ipairs({ trackname, trackname .. " (band)" }) do -- wet prints may sit on a mirror track
    local tr = band.find_track(proj, n, true)
    if tr then
      local lanes = reaper.GetMediaTrackInfo_Value(tr, "I_FREEMODE") == 2
      local lane_band, lane_want = {}, {}
      for j = 0, reaper.CountTrackMediaItems(tr) - 1 do
        local it = reaper.GetTrackMediaItem(tr, j)
        local lane = math.floor(reaper.GetMediaItemInfo_Value(it, "I_FIXEDLANE"))
        for k = 0, reaper.CountTakes(it) - 1 do
          local tk = reaper.GetTake(it, k)
          local id = band.take_id(tk)
          if id then
            lane_band[lane] = true
            if want[id:lower()] then lane_want[lane] = true; reaper.SetActiveTake(tk) end
          end
        end
      end
      if lanes and next(lane_band) then -- the lanes holding the driver's choice play (one lane, or all)
        local on = {}
        for lane in pairs(lane_want) do on[#on + 1] = lane end
        table.sort(on)
        set_lanes_playing(tr, on)
      end
      setext(proj, sync.PLAYS, n, select(2, sync.audible(tr)))
    end
  end
  return true
end

-- Apply one of the driver's events. False means retry later (its take hasn't arrived, or a delete
-- needs this tab in front).
function sync.apply(proj, ev)
  if ev.type == "plays" then return apply_plays(proj, ev.track, ev.takes or {}) end
  local it, tk = band.find_take(proj, ev.take)
  if ev.type == "delete" then
    band.set_take_state(proj, ev.take, "deleted") -- also stops a late arrival from being imported
    if not it then return true end
    return delete_take(proj, it, tk, ev.take)
  elseif ev.type == "edit" then
    if not it then return band.take_state(proj, ev.take) == "deleted" end
    reaper.SetMediaItemInfo_Value(it, "D_POSITION", ev.pos)
    reaper.SetMediaItemInfo_Value(it, "D_LENGTH", ev.len)
    local offs = band.base_offs(tk) + (ev.offs or 0) -- offsets travel relative to where each print was placed
    for k = 0, reaper.CountTakes(it) - 1 do
      local t2 = reaper.GetTake(it, k)
      if t2 == tk or band.take_ext(t2, "band_dry"):lower() == ev.take:lower() then reaper.SetMediaItemTakeInfo_Value(t2, "D_STARTOFFS", offs) end
    end
    if ev.lane then
      local tr = reaper.GetMediaItem_Track(it)
      if reaper.GetMediaTrackInfo_Value(tr, "I_FREEMODE") ~= 2 then reaper.SetMediaTrackInfo_Value(tr, "I_FREEMODE", 2) end
      if reaper.GetMediaTrackInfo_Value(tr, "I_NUMFIXEDLANES") < ev.lane + 1 then reaper.SetMediaTrackInfo_Value(tr, "I_NUMFIXEDLANES", ev.lane + 1) end
      reaper.SetMediaItemInfo_Value(it, "I_FIXEDLANE", ev.lane)
    end
    reaper.UpdateItemInProject(it)
    sync.remember(proj, ev.take, it, tk) -- so this change isn't seen as a local edit
    return true
  end
  return true -- unknown types from newer versions are skipped
end

-- Compare the project with its snapshots. As driver (emit = true) the differences go out as events;
-- otherwise the snapshots are just brought up to date, so taking control later doesn't replay old edits.
function sync.watch(proj, cfg, song, room, emit)
  local idx = band.take_index(proj)
  local i = 0
  while true do
    local ok, key, state = reaper.EnumProjExtState(proj, band.TAKES, i)
    if not ok then break end
    i = i + 1
    if state ~= "deleted" then
      local snap = ext(proj, sync.SNAP, key)
      local id = snap:match("^([^|]+)") or key -- original case lives in the snapshot
      local hit = idx[id:lower()]
      if not hit then
        band.set_take_state(proj, id, "deleted")
        if emit then
          sync.post(cfg, song, room, { type = "delete", take = id })
          sync.trash(cfg, song, room, id)
        end
      elseif snap == "" then
        sync.remember(proj, id, hit[1], hit[2]) -- first look at a take placed before snapshots existed
      elseif snap ~= id .. "|" .. shape(hit[1], hit[2]) then
        if emit then
          sync.post(cfg, song, room, { type = "edit", take = id, pos = reaper.GetMediaItemInfo_Value(hit[1], "D_POSITION"),
            len = reaper.GetMediaItemInfo_Value(hit[1], "D_LENGTH"), lane = lane_of(hit[1]),
            offs = reaper.GetMediaItemTakeInfo_Value(hit[2], "D_STARTOFFS") - band.base_offs(hit[2]) })
        end
        sync.remember(proj, id, hit[1], hit[2])
      end
    end
  end
  for t = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, t)
    local any, ids = sync.audible(tr)
    if any then
      local name = select(2, reaper.GetTrackName(tr))
      if ids ~= ext(proj, sync.PLAYS, name) then
        if emit then
          local list = {}
          for id in ids:gmatch("[^,]+") do list[#list + 1] = id end
          sync.post(cfg, song, room, { type = "plays", track = (name:gsub(" %(band%)$", "")), takes = list })
        end
        setext(proj, sync.PLAYS, name, ids)
      end
    end
  end
end

-- Apply the room driver's events this project hasn't applied yet, oldest first.
function sync.receive(proj, cfg, song, room, driver, host)
  local dir = sync.room_dir(cfg, song, room) .. "/events"
  local pending = {}
  for _, f in ipairs(band.files(dir, ".json")) do
    if ext(proj, sync.APPLIED, f:sub(1, -6)) == "" then
      local ev = band.read_json(dir .. "/" .. f)
      if ev and ev.id then pending[#pending + 1] = ev end
    end
  end
  table.sort(pending, function(a, x) return (a.time .. a.id) < (x.time .. x.id) end)
  -- only the newest "plays" per track matters; an older one still waiting for its takes must never
  -- be applied after a newer one
  local newest = {}
  for _, ev in ipairs(pending) do if ev.type == "plays" then newest[ev.track or ""] = ev.id end end
  local applied = 0
  for _, ev in ipairs(pending) do
    if ev.type == "plays" and newest[ev.track or ""] ~= ev.id then
      setext(proj, sync.APPLIED, ev.id, "1") -- superseded
    elseif ev.user == cfg.user or not (ev.user == driver or ev.user == host) then
      setext(proj, sync.APPLIED, ev.id, "1") -- our own (already true here), or not from whoever's driving
    elseif sync.apply(proj, ev) then
      setext(proj, sync.APPLIED, ev.id, "1")
      applied = applied + 1
    end
  end
  return applied
end

-- ---- status receipts ----------------------------------------------------------------------------

-- What this project holds: { [lower id] = rev }. Written to rooms/<room>/status/<user>.json so everyone
-- can see who has what (the Status window).
function sync.holdings(proj)
  local have, i = {}, 0
  while true do
    local ok, key, state = reaper.EnumProjExtState(proj, band.TAKES, i)
    if not ok then break end
    i = i + 1
    if state == "full" or state == "preview" then
      local id = (ext(proj, sync.SNAP, key):match("^([^|]+)") or key):lower()
      have[id] = (tonumber(ext(proj, sync.REV, key)) or 1) + (state == "preview" and -0.5 or 0)
    end
  end
  return have
end

function sync.write_status(proj, cfg, song, room, info)
  local dir = sync.room_dir(cfg, song, room) .. "/status"
  reaper.RecursiveCreateDirectory(dir, 0)
  info.user, info.time, info.version, info.room = cfg.user, os.date("!%Y-%m-%dT%H:%M:%SZ"), band.VERSION, room
  info.takes = sync.holdings(proj)
  band.write_json(dir .. "/" .. (cfg.user:gsub("[^%w%-_ ]", "")) .. ".json", info)
end

return sync
