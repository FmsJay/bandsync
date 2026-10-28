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
  TRACKS = "BandSync.tracks",   -- track GUID -> "name|mute|solo|colour|icon" as last seen/applied
  ITEMS = "BandSync.items",     -- id -> item state chunk of our own sent takes (recall points rebuild them)
  PENDING = "BandSync.pending", -- id -> where a revived take must sit once it has been imported again
  PRINTER = "BandSync.printer", -- id -> who made the current print (someone may print a take with their own instrument)
  MIDIHASH = "BandSync.midi",   -- id -> hash of the MIDI copy's notes as last seen/applied
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

-- ---- who may change what ------------------------------------------------------------------------
-- People claim tracks and regions, each in their own file (rooms/<room>/claims/<user>.json: never two
-- writers on one file). A take may be changed by the owner of its track; else by the owner of the region
-- it starts in; else by the driver. The newest claim on a track or region wins.

local function base_name(track) return track and (track:gsub(" %(band%)$", "")) end
sync.base_name = base_name

function sync.claims_path(cfg, song, room, user)
  return sync.room_dir(cfg, song, room) .. "/claims/" .. (user:gsub("[^%w%-_ ]", "")) .. ".json"
end
function sync.my_claims(cfg, song, room)
  return band.read_json(sync.claims_path(cfg, song, room, cfg.user)) or { tracks = {}, regions = {} }
end
function sync.set_claims(cfg, song, room, claims)
  claims.user, claims.time = cfg.user, os.date("!%Y-%m-%dT%H:%M:%SZ")
  reaper.RecursiveCreateDirectory(sync.room_dir(cfg, song, room) .. "/claims", 0)
  band.write_json(sync.claims_path(cfg, song, room, cfg.user), claims)
end

-- Returns can(user, track, pos) -> bool, plus { driver, tracks, regions, owner(track, pos) } for display.
function sync.authority(cfg, song, room, s)
  local driver = sync.driver(cfg, song, room, s)
  local tracks, regions = {}, {} -- lower name -> { user, time }
  local dir = sync.room_dir(cfg, song, room) .. "/claims"
  for _, f in ipairs(band.files(dir, ".json")) do
    local c = band.read_json(dir .. "/" .. f)
    if c and c.user and c.time then
      for _, list in ipairs({ { c.tracks, tracks }, { c.regions, regions } }) do
        for _, name in ipairs(list[1] or {}) do
          local k = name:lower()
          if not list[2][k] or list[2][k].time < c.time then list[2][k] = { user = c.user, time = c.time, name = name } end
        end
      end
    end
  end
  local spans = {} -- the song's regions, from the publish
  for _, m in ipairs((s and s.markers) or {}) do
    if m.region then spans[#spans + 1] = { name = m.name:lower(), from = m.pos, to = m["end"] } end
  end
  local function owner(track, pos)
    local t = base_name(track)
    if t and tracks[t:lower()] then return tracks[t:lower()].user end
    if pos then
      for _, sp in ipairs(spans) do
        if pos >= sp.from and pos < sp.to and regions[sp.name] then return regions[sp.name].user end
      end
    end
    return driver
  end
  return function(user, track, pos) return owner(track, pos) == user end,
    { driver = driver, tracks = tracks, regions = regions, owner = owner, spans = spans }
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
local function track_name(it) return base_name(select(2, reaper.GetTrackName(reaper.GetMediaItem_Track(it)))) end
local function shape(it, tk)
  return string.format("%.6f|%.6f|%.6f|%s|%d|%s", reaper.GetMediaItemInfo_Value(it, "D_POSITION"), reaper.GetMediaItemInfo_Value(it, "D_LENGTH"),
    reaper.GetMediaItemTakeInfo_Value(tk, "D_STARTOFFS"), tostring(lane_of(it)), reaper.GetMediaItemInfo_Value(it, "B_MUTE"), track_name(it))
end
function sync.remember(proj, id, it, tk)
  setext(proj, sync.SNAP, id, id .. "|" .. shape(it, tk))
  -- our own takes also keep a copy of the whole item (source, take FX, fades), so a recall point can bring
  -- back the real item after a delete instead of its print
  if band.take_ext(tk, "band_sent") ~= "" then
    local ok, chunk = reaper.GetItemStateChunk(it, "", false)
    if ok then setext(proj, sync.ITEMS, id, chunk) end
  end
end

-- One BandSync track per name speaks for it: our real "Vox", not the "Vox (band)" mirror beside it.
local function speaks_for_name(proj, tr)
  if band.track_ext(tr, "band_mirror") == "" then return true end
  local name = select(2, reaper.GetTrackName(tr))
  return not band.find_track(proj, base_name(name), true) or base_name(name) == name
end
sync.speaks_for_name = speaks_for_name

function sync.midi_seen(proj, id, tk) setext(proj, sync.MIDIHASH, id, select(2, reaper.MIDI_GetHash(tk, false, ""))) end

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
  if reaper.TakeIsMIDI(tk) then parts[#parts + 1] = select(2, reaper.MIDI_GetHash(tk, false, "")) end -- edited notes sound different
  if wet then
    parts[#parts + 1] = reaper.GetMediaTrackInfo_Value(tr, "D_VOL") .. "/" .. reaper.GetMediaTrackInfo_Value(tr, "D_PAN") ..
      "/" .. reaper.GetMediaTrackInfo_Value(tr, "I_FXEN")
    fx(reaper.TrackFX_GetCount, reaper.TrackFX_GetFXName, reaper.TrackFX_GetEnabled, reaper.TrackFX_GetNumParams, reaper.TrackFX_GetParamNormalized, tr)
  end
  local s, h = table.concat(parts, ";"), 5381
  for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
  return string.format("%08x", h)
end

sync.fxhash = fxhash

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
    if band.track_ext(reaper.GetMediaItem_Track(it), "band_stem") == "" and band.item_ext(it, "band_take") == ""
        and band.item_ext(it, "band_live") == "" then -- live placeholders are someone else's audio, never ours to send
      local legacy = band.item_ext(it, "band_sent") -- 0.2 marked the item: carry it to the take that was active
      if legacy ~= "" then
        local a = reaper.GetActiveTake(it)
        if a and band.take_ext(a, "band_sent") == "" then band.set_take_ext(a, "band_sent", legacy) end
        band.set_item_ext(it, "band_sent", "")
      end
      local function add(tk)
        if not tk or band.take_ext(tk, "band_take") ~= "" or band.take_ext(tk, "band_dry") ~= "" or band.take_ext(tk, "band_midi") ~= "" then return end
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
-- `twin`: printing someone's MIDI copy with our own instrument; it's the original track's name.
local function selection(proj)
  local sel = {}
  for i = 0, reaper.CountSelectedMediaItems(proj) - 1 do sel[#sel + 1] = reaper.GetSelectedMediaItem(proj, i) end
  return sel
end

-- Render item `it` (its active take, which must be selected alone) to <out>/<name>.flac (+ .opus).
local function render_item(it, take, out, name, wet)
  local tr = reaper.GetMediaItem_Track(it)
  local nch = reaper.GetMediaSourceNumChannels(reaper.GetMediaItemTake_Source(take))
  do
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
end

-- Print one take through its track (wet) to <out>/<name>.flac, leaving selection and the playing take as they
-- were. Returns the .flac path, or nil. Active tab only. (Solo edit keeps wet prints beside dry recordings.)
function sync.print_item(proj, it, take, out, name)
  local sel, playing = selection(proj), reaper.GetActiveTake(it)
  reaper.SetActiveTake(take)
  reaper.SelectAllMediaItems(proj, false)
  reaper.SetMediaItemSelected(it, true)
  local path = render_item(it, take, out, name, true) .. ".flac"
  reaper.SetActiveTake(playing)
  reaper.SelectAllMediaItems(proj, false)
  for _, s in ipairs(sel) do if reaper.ValidatePtr2(proj, s, "MediaItem*") then reaper.SetMediaItemSelected(s, true) end end
  return reaper.file_exists(path) and path or nil
end

local function print_take(proj, cfg, b, it, take, id, rev, mode, out, takes, twin)
  local tr = reaper.GetMediaItem_Track(it)
  local suffix = rev > 1 and ("-r" .. rev) or ""
  local playing = reaper.GetActiveTake(it)
  reaper.SetActiveTake(take) -- renders render the item's active take
  reaper.SelectAllMediaItems(proj, false)
  reaper.SetMediaItemSelected(it, true)
  local main = render_item(it, take, out, id .. suffix, mode ~= "dry")
  local dry = mode == "both" and render_item(it, take, out, id .. "-dry" .. suffix, false)
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
    printed_by = cfg.user,
  }
  local old = rev > 1 and band.read_json(takes .. "/" .. id .. ".json")
  if twin and old then -- printed from a MIDI copy: still the original's take (whose, which track, lane, item)
    for _, k in ipairs({ "user", "room", "track", "group", "lane", "lane_name", "session_version" }) do m[k] = old[k] end
  elseif twin then
    m.track = twin
  end
  -- where it first landed: the history replays edits from here (later revisions rewrite pos/len)
  m.origin = old and old.origin or { pos = m.pos, len = m.len, track = base_name(m.track), lane = m.lane, sent = old and old.sent or m.sent }
  if reaper.TakeIsMIDI(take) then -- the notes travel with the print, so anyone may edit them or print them with their own instrument
    local ok, buf = reaper.MIDI_GetAllEvts(take, "")
    if ok then
      band.write_atomic(takes .. "/" .. id .. suffix .. ".midibuf", buf)
      m.midi, m.midi_offs = id .. suffix .. ".midibuf", reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
      local map = band.track_ext(tr, "band_drummap") -- the notes are in this drum map; receivers translate
      m.drummap = map ~= "" and map or nil
      m.no_instrument = reaper.TrackFX_GetInstrument(tr) < 0 or nil -- its print is silent: receivers say so
    end
  end
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
    for _, f in ipairs({ id .. old .. ".flac", id .. old .. ".opus", id .. "-dry" .. old .. ".flac", id .. old .. ".midibuf" }) do os.remove(takes .. "/" .. f) end
  end
  band.write_json(takes .. "/" .. id .. ".json", m) -- one manifest per take, rewritten for each revision
  band.copy_atomic(main .. ".flac", takes .. "/" .. m.full)
  setext(proj, sync.REV, id, tostring(rev))
  setext(proj, sync.PRINTER, id, cfg.user)
  band.set_take_ext(take, "band_fxhash", fxhash(it, take, mode ~= "dry"))
  if reaper.TakeIsMIDI(take) then sync.midi_seen(proj, id, take) end
  if twin then -- a MIDI copy printed with our instrument stays a copy; the print we hold becomes ours
    band.update_take(proj, m, takes .. "/" .. m.full, m.dry and (takes .. "/" .. m.dry))
    return m
  end
  band.set_take_ext(take, "band_sent", id)
  band.mark_base(take)
  band.set_take_state(proj, id, "full") -- this project already has it: its own sync must not re-import it
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
      local id, twin = band.take_ext(tk, "band_sent"), nil
      if id == "" then -- a MIDI copy we printed with our own instrument: we keep that print current
        id, twin = band.take_ext(tk, "band_midi"), band.track_ext(reaper.GetMediaItem_Track(it), "band_midi_track")
      end
      local printer = id ~= "" and ext(proj, sync.PRINTER, id) or ""
      -- once someone else has printed this take with their own instrument, their print stands: we don't
      -- overwrite it with ours (our note edits still reach them as MIDI)
      if id ~= "" and (printer == cfg.user or (printer == "" and not twin)) and band.take_ext(tk, "band_fxhash") ~= fxhash(it, tk, mode ~= "dry") then
        todo[#todo + 1] = { it, tk, id, twin }
      end
    end
  end
  if #todo == 0 then return 0 end
  local out, takes = dirs(proj, cfg, b)
  local sel, n = selection(proj), 0
  for _, u in ipairs(todo) do
    local rev = (tonumber(ext(proj, sync.REV, u[3])) or 1) + 1
    if print_take(proj, cfg, b, u[1], u[2], u[3], rev, mode, out, takes, u[4]) then n = n + 1 end
  end
  finish(proj, sel)
  return n
end

-- "Print my MIDI": render MIDI copies through this person's "(MIDI)" track and instrument, and post each
-- as the take's next revision; everyone hears the new print, and they keep it current from then on.
-- units: { item, take, id, original track name }.
function sync.print_midi(proj, cfg, b, units, mode)
  local out, takes = dirs(proj, cfg, b)
  local sel, n = selection(proj), 0
  for _, u in ipairs(units) do
    local rev = (tonumber(ext(proj, sync.REV, u[3])) or 1) + 1
    if print_take(proj, cfg, b, u[1], u[2], u[3], rev, mode, out, takes, u[4]) then n = n + 1 end
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

-- Make exactly `list` (ids) audible on a track. With `local_only`, the snapshot isn't updated, so Live sync
-- sees the change and posts it as this person's own (that's how a recall point restores lane choices).
local function apply_plays(proj, trackname, list, local_only)
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
      if not local_only then setext(proj, sync.PLAYS, n, select(2, sync.audible(tr))) end
    end
  end
  return true
end
sync.set_plays = function(proj, trackname, list) return apply_plays(proj, trackname, list, true) end
sync.delete_take = delete_take -- recall points delete locally; Live sync then posts it
sync.lane_of, sync.track_name = lane_of, track_name

-- Track properties that follow whoever owns the track: name, mute, solo, colour, icon (by file name: icons
-- live in REAPER's own folder, so the same built-in icon exists everywhere).
local function track_props(tr)
  local icon = select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_ICON", "", false))
  return string.format("%s|%d|%d|%d|%s", base_name(select(2, reaper.GetTrackName(tr))), reaper.GetMediaTrackInfo_Value(tr, "B_MUTE"),
    reaper.GetMediaTrackInfo_Value(tr, "I_SOLO"), reaper.GetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR"), icon:match("[^/\\]+$") or icon)
end
local function track_guid(tr) return select(2, reaper.GetSetMediaTrackInfo_String(tr, "GUID", "", false)) end
local function holds_takes(tr)
  for j = 0, reaper.CountTrackMediaItems(tr) - 1 do
    local it = reaper.GetTrackMediaItem(tr, j)
    for k = 0, reaper.CountTakes(it) - 1 do if band.take_id(reaper.GetTake(it, k)) then return true end end
  end
  return false
end

local function apply_track(proj, ev)
  local from = ev.was or ev.track
  for t = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, t)
    local name = select(2, reaper.GetTrackName(tr))
    if band.track_ext(tr, "band_stem") == "" and base_name(name):lower() == from:lower() then
      local suffix = name:match(" %(band%)$") or ""
      reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", ev.track .. suffix, true)
      reaper.SetMediaTrackInfo_Value(tr, "B_MUTE", ev.mute or 0)
      reaper.SetMediaTrackInfo_Value(tr, "I_SOLO", ev.solo or 0)
      reaper.SetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR", ev.color or 0)
      reaper.GetSetMediaTrackInfo_String(tr, "P_ICON", ev.icon or "", true)
      setext(proj, sync.TRACKS, track_guid(tr), track_props(tr)) -- so this isn't seen as a local change
    end
  end
  reaper.TrackList_AdjustWindows(false)
  return true
end

-- Apply one event from whoever may make it. False means retry later (its take hasn't arrived, or a
-- delete needs this tab in front).
-- `dir`: the room's folder (where "midi" events keep their note files); `root`: the shared folder (drum maps).
function sync.apply(proj, ev, dir, root)
  if ev.type == "plays" then return apply_plays(proj, ev.track, ev.takes or {}) end
  if ev.type == "track" then return apply_track(proj, ev) end
  local it, tk = band.find_take(proj, ev.take)
  local mit, mtk = band.find_midi(proj, ev.take)
  if it then reaper.SetMediaItemInfo_Value(it, "C_LOCK", 0) end -- view-only locks are for people, not for sync
  if mit then reaper.SetMediaItemInfo_Value(mit, "C_LOCK", 0) end
  if ev.type == "midi" then -- someone edited the notes: our MIDI copy follows, and so does the original's source
    local buf = dir and band.read(dir .. "/midi/" .. ev.file)
    if not buf then return false end -- not synced here yet
    for _, t2 in pairs({ mtk or false, tk and reaper.TakeIsMIDI(tk) and tk }) do
      if t2 then
        reaper.MIDI_SetAllEvts(t2, band.to_track_map(root, buf, ev.drummap, reaper.GetMediaItem_Track(reaper.GetMediaItemTake_Item(t2))))
        reaper.MIDI_Sort(t2)
        sync.midi_seen(proj, ev.take, t2) -- applied, not a local edit (Live sync reprints if the print is ours)
      end
    end
    return true
  end
  if ev.type == "delete" then
    band.set_take_state(proj, ev.take, "deleted") -- also stops a late arrival from being imported
    if mit then reaper.DeleteTrackMediaItem(reaper.GetMediaItem_Track(mit), mit) end
    if not it then return true end
    return delete_take(proj, it, tk, ev.take)
  elseif ev.type == "undelete" then -- a recall point brought it back: import it again
    if band.take_state(proj, ev.take) == "deleted" then band.set_take_state(proj, ev.take, "") end
    return true
  elseif ev.type == "edit" then
    if not it then return band.take_state(proj, ev.take) == "deleted" end
    if ev.track and track_name(it):lower() ~= ev.track:lower() then -- moved to another track
      local dest = band.dest_track(proj, ev.track, band.take_ext(tk, "band_wet") == "1")
      if not dest then return false end -- needs this tab in front on REAPER < 7.18
      reaper.MoveMediaItemToTrack(it, dest)
    end
    reaper.SetMediaItemInfo_Value(it, "D_POSITION", ev.pos)
    reaper.SetMediaItemInfo_Value(it, "D_LENGTH", ev.len)
    if ev.mute then reaper.SetMediaItemInfo_Value(it, "B_MUTE", ev.mute) end
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
    sync.remember(proj, band.take_id(tk) or ev.take, it, tk) -- so this change isn't seen as a local edit
    if mit then -- the MIDI copy keeps sitting under its print
      reaper.SetMediaItemInfo_Value(mit, "D_POSITION", ev.pos)
      reaper.SetMediaItemInfo_Value(mit, "D_LENGTH", ev.len)
      reaper.SetMediaItemTakeInfo_Value(mtk, "D_STARTOFFS", band.base_offs(mtk) + (ev.offs or 0))
      reaper.UpdateItemInProject(mit)
    end
    return true
  end
  return true -- unknown types from newer versions are skipped
end

-- Compare the project with its snapshots and post what changed, for whatever `can` says this person may
-- change (track owner, region owner or driver). Changes they may not make stay local (and are locked in
-- the first place, see apply_locks). Hold sync doesn't call this at all: the snapshots keep the last
-- synced state, so releasing the hold sends the net result once.
function sync.watch(proj, cfg, song, room, can)
  local me = cfg.user
  local idx = band.take_index(proj)
  local i = 0
  while true do
    local ok, key, state = reaper.EnumProjExtState(proj, band.TAKES, i)
    if not ok then break end
    i = i + 1
    if state ~= "deleted" then
      local snap = ext(proj, sync.SNAP, key)
      local sid = snap:match("^([^|]+)") or key
      local hit = idx[sid:lower()]
      if not hit then
        local f = {}
        for v in (snap .. "|"):gmatch("([^|]*)|") do f[#f + 1] = v end -- id|pos|len|offs|lane|mute|track
        local pos, track = tonumber(f[2]), f[7]
        band.set_take_state(proj, sid, "deleted")
        local mit = band.find_midi(proj, sid) -- its MIDI copy goes with it
        if mit then reaper.DeleteTrackMediaItem(reaper.GetMediaItem_Track(mit), mit) end
        if can(me, track, pos) then
          sync.post(cfg, song, room, { type = "delete", take = sid, track = track, pos = pos })
          sync.trash(cfg, song, room, sid)
        end
      else
        local id = band.take_id(hit[2]) or sid -- the take's own id keeps its case; state keys may be upper-cased
        if snap == "" then
          sync.remember(proj, id, hit[1], hit[2]) -- first look at a take placed before snapshots existed
        elseif snap ~= id .. "|" .. shape(hit[1], hit[2]) then
          local pos, track = reaper.GetMediaItemInfo_Value(hit[1], "D_POSITION"), track_name(hit[1])
          if can(me, track, pos) then
            sync.post(cfg, song, room, { type = "edit", take = id, pos = pos, track = track,
              len = reaper.GetMediaItemInfo_Value(hit[1], "D_LENGTH"), lane = lane_of(hit[1]),
              mute = reaper.GetMediaItemInfo_Value(hit[1], "B_MUTE"),
              offs = reaper.GetMediaItemTakeInfo_Value(hit[2], "D_STARTOFFS") - band.base_offs(hit[2]) })
          end
          sync.remember(proj, id, hit[1], hit[2])
        end
      end
    end
  end
  for t = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, t)
    if band.track_ext(tr, "band_stem") == "" and holds_takes(tr) and speaks_for_name(proj, tr) then
      local full = select(2, reaper.GetTrackName(tr))
      local name = base_name(full)
      local any, ids = sync.audible(tr)
      if any and ids ~= ext(proj, sync.PLAYS, full) then
        if can(me, name, nil) then
          local list = {}
          for id in ids:gmatch("[^,]+") do list[#list + 1] = id end
          sync.post(cfg, song, room, { type = "plays", track = name, takes = list })
        end
        setext(proj, sync.PLAYS, full, ids)
      end
      local guid, props = track_guid(tr), track_props(tr)
      local before = ext(proj, sync.TRACKS, guid)
      if before ~= props then
        local was = before:match("^([^|]*)")
        if before ~= "" and can(me, (was and was ~= "") and was or name, nil) then
          sync.post(cfg, song, room, { type = "track", track = name, was = (was ~= name) and was or nil,
            mute = reaper.GetMediaTrackInfo_Value(tr, "B_MUTE"), solo = reaper.GetMediaTrackInfo_Value(tr, "I_SOLO"),
            color = reaper.GetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR"), icon = props:match("([^|]*)$") })
        end
        setext(proj, sync.TRACKS, guid, props)
      end
    end
  end
  -- note edits: on a MIDI copy, or on our own MIDI take once someone else prints it (else our reprint carries them)
  for i = 0, reaper.CountMediaItems(proj) - 1 do
    local it = reaper.GetMediaItem(proj, i)
    local tk = reaper.GetActiveTake(it)
    local id, track = tk and band.take_ext(tk, "band_midi") or "", nil
    if id ~= "" then
      track = band.track_ext(reaper.GetMediaItem_Track(it), "band_midi_track")
    elseif tk and reaper.TakeIsMIDI(tk) and band.take_ext(tk, "band_sent") ~= "" then
      id = band.take_ext(tk, "band_sent")
      local printer = ext(proj, sync.PRINTER, id)
      if printer ~= "" and printer ~= me then track = track_name(it) end
    end
    local before = track and ext(proj, sync.MIDIHASH, id)
    if before and before ~= select(2, reaper.MIDI_GetHash(tk, false, "")) then
      local pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
      if before ~= "" and can(me, track, pos) then
        local ok, buf = reaper.MIDI_GetAllEvts(tk, "")
        local file = string.format("%s-%s-%s.midibuf", id, (me:gsub("[^%w%-_]", "_")), os.date("!%Y%m%d-%H%M%S"))
        if ok then
          reaper.RecursiveCreateDirectory(sync.room_dir(cfg, song, room) .. "/midi", 0)
          band.write_atomic(sync.room_dir(cfg, song, room) .. "/midi/" .. file, buf)
          local map = band.track_ext(reaper.GetMediaItem_Track(it), "band_drummap")
          sync.post(cfg, song, room, { type = "midi", take = id, track = track, pos = pos, file = file, drummap = map ~= "" and map or nil })
        end
      end
      sync.midi_seen(proj, id, tk)
    end
  end
end

-- View-only: lock (item lock) the BandSync takes this person may not change, so nothing silently diverges;
-- unlock them when they may (took control, claimed the track). Only locks BandSync set are ever removed.
function sync.apply_locks(proj, can, me)
  for i = 0, reaper.CountMediaItems(proj) - 1 do
    local it = reaper.GetMediaItem(proj, i)
    local tk = reaper.GetActiveTake(it)
    local name = tk and (band.take_id(tk) and track_name(it) or band.take_ext(tk, "band_midi") ~= "" and
      band.track_ext(reaper.GetMediaItem_Track(it), "band_midi_track")) -- MIDI copies belong to their print's track
    if name then
      local allowed = can(me, name, reaper.GetMediaItemInfo_Value(it, "D_POSITION"))
      local lock = math.floor(reaper.GetMediaItemInfo_Value(it, "C_LOCK"))
      local ours = band.item_ext(it, "band_locked") ~= ""
      if not allowed and lock & 1 == 0 then
        reaper.SetMediaItemInfo_Value(it, "C_LOCK", lock | 1)
        band.set_item_ext(it, "band_locked", "1")
      elseif allowed and ours then
        reaper.SetMediaItemInfo_Value(it, "C_LOCK", lock & ~1)
        band.set_item_ext(it, "band_locked", "")
      end
    end
  end
end

-- Apply events this project hasn't applied yet, oldest first, from whoever may make each one.
function sync.receive(proj, cfg, song, room, can)
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
  local applied, done, undo_open = 0, {}, false
  for _, ev in ipairs(pending) do
    if ev.type == "plays" and newest[ev.track or ""] ~= ev.id then
      setext(proj, sync.APPLIED, ev.id, "1") -- superseded
    elseif ev.user == cfg.user or not can(ev.user, ev.was or ev.track, ev.pos) then
      setext(proj, sync.APPLIED, ev.id, "1") -- our own (already true here), or not theirs to change
    else
      if not undo_open then reaper.Undo_BeginBlock2(proj); undo_open = true end -- one undo point per pass, only when needed
      if sync.apply(proj, ev, sync.room_dir(cfg, song, room), cfg.root) then
        setext(proj, sync.APPLIED, ev.id, "1")
        applied = applied + 1
        local what = ({ plays = "now playing on " .. tostring(ev.track), track = "changed track " .. tostring(ev.track),
          delete = "deleted " .. tostring(ev.take), undelete = "brought back " .. tostring(ev.take),
          midi = "edited the notes of " .. tostring(ev.take) })[ev.type]
        done[#done + 1] = ev.user .. ": " .. (what or ("moved/trimmed " .. tostring(ev.take)))
      end
    end
  end
  if undo_open then reaper.Undo_EndBlock2(proj, "BandSync: changes from the band", -1) end
  for _, d in ipairs(done) do band.log(d) end
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

-- How many of the room's events this project hasn't applied (or set aside) yet.
function sync.pending_events(proj, cfg, song, room)
  local n = 0
  for _, f in ipairs(band.files(sync.room_dir(cfg, song, room) .. "/events", ".json")) do
    if ext(proj, sync.APPLIED, f:sub(1, -6)) == "" then n = n + 1 end
  end
  return n
end

function sync.write_status(proj, cfg, song, room, info)
  local dir = sync.room_dir(cfg, song, room) .. "/status"
  reaper.RecursiveCreateDirectory(dir, 0)
  info.user, info.time, info.version, info.room = cfg.user, os.date("!%Y-%m-%dT%H:%M:%SZ"), band.VERSION, room
  info.takes = sync.holdings(proj)
  band.write_json(dir .. "/" .. (cfg.user:gsub("[^%w%-_ ]", "")) .. ".json", info)
end

return sync
