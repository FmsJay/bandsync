-- BandSync shared library: settings, song folders, session.json, stems and take placement.
-- Pure REAPER API, no extensions required (js_ReaScriptAPI only improves the folder picker).
local json = require("json")
local band = { VERSION = "0.2.0", FORMAT = 1, SECTION = "BandSync", TAKES = "BandSync.takes" }

-- 1 if version a is newer than b, -1 if older, 0 if equal ("0.10.0" > "0.9.1").
function band.compare_versions(a, b)
  local pa, pb = {}, {}
  for n in tostring(a):gmatch("%d+") do pa[#pa + 1] = tonumber(n) end
  for n in tostring(b):gmatch("%d+") do pb[#pb + 1] = tonumber(n) end
  for i = 1, math.max(#pa, #pb) do
    local x, y = pa[i] or 0, pb[i] or 0
    if x ~= y then return x > y and 1 or -1 end
  end
  return 0
end

-- Warn once per run when a bandmate's file was made with a newer BandSync than this one.
local warned = {}
function band.check_version(theirs, what)
  if theirs and band.compare_versions(theirs, band.VERSION) > 0 and not warned[theirs] then
    warned[theirs] = true
    band.msg(string.format("%s was made with BandSync %s; you have %s.\n\nRun 'BandSync - Update' so everyone stays compatible.",
      what, theirs, band.VERSION))
  end
end

-- ---- small helpers --------------------------------------------------------------------------

function band.clean(s) return (s:gsub("[^%w%-_ ]", ""):match("^%s*(.-)%s*$")) end
local function norm(p) return (p:gsub("\\", "/"):gsub("/+$", "")) end
band.norm = norm

function band.msg(text) reaper.MB(text, "BandSync", 0) end
function band.log(text) reaper.ShowConsoleMsg("[bandsync] " .. text .. "\n") end

function band.read(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("a"); f:close()
  return s
end

function band.size(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local n = f:seek("end"); f:close()
  return n
end

-- Write under a temp name, then rename, so a syncing peer never picks up a half-written file.
-- The ".syncthing.*.tmp" name is one Syncthing always ignores; cloud drives may upload it briefly.
function band.write_atomic(path, data)
  local dir, name = path:match("^(.*)/([^/]+)$")
  local tmp = dir .. "/.syncthing." .. name .. ".tmp"
  local f = assert(io.open(tmp, "wb"))
  f:write(data); f:close()
  os.remove(path)
  assert(os.rename(tmp, path))
end

function band.copy_atomic(src, dst) band.write_atomic(dst, assert(band.read(src), "cannot read " .. src)) end

function band.read_json(path)
  local s = band.read(path)
  if not s then return nil end
  local ok, v = pcall(json.decode, s)
  return ok and type(v) == "table" and v or nil
end

function band.write_json(path, t) band.write_atomic(path, json.encode(t, true)) end

local function enum(fn, dir)
  local out, i = {}, 0
  fn(dir, -1) -- invalidate REAPER's directory cache so newly synced files show up
  while true do
    local name = fn(dir, i)
    if not name then break end
    out[#out + 1] = name; i = i + 1
  end
  table.sort(out)
  return out
end

function band.files(dir, ext)
  local out = {}
  for _, f in ipairs(enum(reaper.EnumerateFiles, dir)) do
    if not ext or f:lower():sub(-#ext) == ext then out[#out + 1] = f end
  end
  return out
end

function band.subdirs(dir) return enum(reaper.EnumerateSubdirectories, dir) end

-- Pop a menu at the mouse; returns the chosen string or nil.
function band.pick(items)
  if #items == 0 then return nil end
  local x, y = reaper.GetMousePosition()
  gfx.init("", 0, 0, 0, x, y)
  gfx.x, gfx.y = 0, 0
  local i = gfx.showmenu(table.concat(items, "|"))
  gfx.quit()
  return items[i]
end

-- ---- settings and project binding -----------------------------------------------------------

function band.settings(force)
  local root = reaper.GetExtState(band.SECTION, "sync_root")
  local user = reaper.GetExtState(band.SECTION, "user")
  if force or root == "" or user == "" then
    if root == "" and reaper.JS_Dialog_BrowseForFolder then
      local ok, picked = reaper.JS_Dialog_BrowseForFolder("BandSync: pick the shared (Syncthing) folder", "")
      if ok == 1 then root = picked end
    end
    local ok, csv = reaper.GetUserInputs("BandSync settings", 2,
      "Shared folder (Syncthing),Your name,separator=|,extrawidth=250", root .. "|" .. user)
    if not ok then return nil end
    root, user = csv:match("^(.-)|(.*)$")
    root = root:gsub("^~", os.getenv("HOME") or os.getenv("USERPROFILE") or "~")
    root, user = norm(root), band.clean(user)
    if root == "" or user == "" then return nil end
    local probe = root .. "/.bandsync-write-test" -- the folder must exist and be writable
    local f = io.open(probe, "w")
    if not f then
      band.msg("Can't write to " .. root .. ". Check the folder exists (is Syncthing set up?).")
      return nil
    end
    f:close(); os.remove(probe)
    reaper.SetExtState(band.SECTION, "sync_root", root, true)
    reaper.SetExtState(band.SECTION, "user", user, true)
  end
  return { root = root, user = user }
end

-- A project is bound to one song: role (host/guest), song, room, version, take_mode.
function band.binding(proj)
  local b = {}
  for _, k in ipairs({ "role", "song", "room", "version", "take_mode", "stem_mode" }) do
    local _, v = reaper.GetProjExtState(proj, band.SECTION, k)
    b[k] = v ~= "" and v or nil
  end
  return b.song and b or nil
end

function band.bind(proj, b)
  for k, v in pairs(b) do reaper.SetProjExtState(proj, band.SECTION, k, tostring(v)) end
end

function band.song_dir(cfg, song) return cfg.root .. "/" .. song end
function band.session_path(cfg, song) return band.song_dir(cfg, song) .. "/session.json" end
function band.takes_dir(cfg, song, room) return band.song_dir(cfg, song) .. "/rooms/" .. room .. "/takes" end

function band.songs(cfg)
  local out = {}
  for _, d in ipairs(band.subdirs(cfg.root)) do
    if reaper.file_exists(band.session_path(cfg, d)) then out[#out + 1] = d end
  end
  return out
end

-- ---- timeline: sample rate, tempo map, markers ----------------------------------------------

function band.srate(proj)
  if reaper.GetSetProjectInfo(proj, "PROJECT_SRATE_USE", 0, false) == 1 then
    return reaper.GetSetProjectInfo(proj, "PROJECT_SRATE", 0, false)
  end
  local _, sr = reaper.GetAudioDeviceInfo("SRATE")
  return tonumber(sr) or 48000
end

function band.capture_tempo(proj)
  local out = {}
  for i = 0, reaper.CountTempoTimeSigMarkers(proj) - 1 do
    local _, t, _, _, bpm, num, den, lin = reaper.GetTempoTimeSigMarker(proj, i)
    out[#out + 1] = { time = t, bpm = bpm, num = num, denom = den, linear = lin }
  end
  if #out == 0 or out[1].time > 0 then -- make the project's base tempo explicit at time 0
    local num, den, bpm = reaper.TimeMap_GetTimeSigAtTime(proj, 0)
    table.insert(out, 1, { time = 0, bpm = bpm, num = num, denom = den, linear = false })
  end
  return out
end

function band.apply_tempo(proj, map)
  for i = reaper.CountTempoTimeSigMarkers(proj) - 1, 0, -1 do reaper.DeleteTempoTimeSigMarker(proj, i) end
  for _, m in ipairs(map) do
    reaper.SetTempoTimeSigMarker(proj, -1, m.time, -1, -1, m.bpm, m.num, m.denom, m.linear)
  end
  reaper.UpdateTimeline()
end

function band.capture_markers(proj)
  local out, i = {}, 0
  while true do
    local n, rgn, pos, rend, name, _, color = reaper.EnumProjectMarkers3(proj, i)
    if n == 0 then break end
    out[#out + 1] = { region = rgn, pos = pos, ["end"] = rend, name = name, color = color }
    i = i + 1
  end
  return out
end

function band.apply_markers(proj, list)
  while reaper.DeleteProjectMarkerByIndex(proj, 0) do end
  for _, m in ipairs(list) do reaper.AddProjectMarker2(proj, m.region, m.pos, m["end"], m.name, -1, m.color) end
end

-- ---- rendering ------------------------------------------------------------------------------

local RENDER_N = { "RENDER_SETTINGS", "RENDER_BOUNDSFLAG", "RENDER_STARTPOS", "RENDER_ENDPOS", "RENDER_SRATE",
  "RENDER_CHANNELS", "RENDER_TAILFLAG", "RENDER_ADDTOPROJ" }
local RENDER_S = { "RENDER_FILE", "RENDER_PATTERN", "RENDER_FORMAT", "RENDER_FORMAT2" }
-- Sink configs read back from REAPER 7.83 and patched: FLAC 24-bit level 5 ("calf", int bits, int level);
-- Opus 64 kbps per channel ("SggO", float kbps/ch, then REAPER's defaults).
band.FLAC, band.OPUS = "Y2FsZhgAAAAFAAAA", "U2dnTwAAgEIACgAAAAAAAAA="

-- Render the active project with temporary settings, then put the user's render settings back.
function band.render(n, s)
  local saved_n, saved_s = {}, {}
  for _, k in ipairs(RENDER_N) do saved_n[k] = reaper.GetSetProjectInfo(0, k, 0, false) end
  for _, k in ipairs(RENDER_S) do saved_s[k] = select(2, reaper.GetSetProjectInfo_String(0, k, "", false)) end
  for k, v in pairs(n) do reaper.GetSetProjectInfo(0, k, v, true) end
  for k, v in pairs(s) do reaper.GetSetProjectInfo_String(0, k, v, true) end
  reaper.Main_OnCommand(42230, 0) -- File: Render project, most recent settings, auto-close dialog
  for k, v in pairs(saved_n) do reaper.GetSetProjectInfo(0, k, v, true) end
  for k, v in pairs(saved_s) do reaper.GetSetProjectInfo_String(0, k, v, true) end
end

-- ---- items, tracks, P_EXT tags --------------------------------------------------------------

function band.track_ext(tr, key) return select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:" .. key, "", false)) end
function band.item_ext(it, key) return select(2, reaper.GetSetMediaItemInfo_String(it, "P_EXT:" .. key, "", false)) end
function band.set_item_ext(it, key, v) reaper.GetSetMediaItemInfo_String(it, "P_EXT:" .. key, v, true) end

function band.add_item(track, path, pos, len)
  local src = reaper.PCM_Source_CreateFromFile(path)
  if not src then return nil end
  local item = reaper.AddMediaItemToTrack(track)
  local take = reaper.AddTakeToMediaItem(item)
  reaper.SetMediaItemTake_Source(take, src)
  reaper.SetMediaItemInfo_Value(item, "D_POSITION", pos)
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH", len or (reaper.GetMediaSourceLength(src)))
  reaper.UpdateItemInProject(item)
  return item, take
end

-- Point an item at a better file (preview -> full). Length and position are left alone.
function band.swap_source(item, path)
  local take = reaper.GetActiveTake(item)
  local src = take and reaper.PCM_Source_CreateFromFile(path)
  if not src then return false end
  local old = reaper.GetMediaItemTake_Source(take)
  reaper.SetMediaItemTake_Source(take, src)
  reaper.PCM_Source_Destroy(old) -- the API leaves the old source to the caller
  reaper.UpdateItemInProject(item)
  return true
end

function band.find_track(proj, name, skip_stems)
  local lname = name:lower()
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    local _, n = reaper.GetTrackName(tr)
    if n:lower() == lname and not (skip_stems and band.track_ext(tr, "band_stem") ~= "") then return tr end
  end
end

-- Append a track to the end of proj, which may be a background tab (the inbox runs on one).
-- Before 7.18 tracks can only be added to the active tab: return nil and the caller retries later.
function band.new_track(proj, name)
  local n = reaper.CountTracks(proj)
  if reaper.InsertTrackInProject then
    reaper.InsertTrackInProject(proj, n, 1)
  elseif proj == reaper.EnumProjects(-1) then
    reaper.InsertTrackAtIndex(n, true)
  else
    return nil
  end
  local tr = reaper.GetTrack(proj, n)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", name, true)
  return tr
end

-- Copy a synced file into proj's recording folder and return the copy's path, so the project never
-- depends on the shared folder: it may mount after REAPER loads, and a sync client can't update files
-- REAPER holds open. "stems/v5/01.flac" becomes "<record path>/bandsync/v5_01.flac". An unsaved
-- project has no folder of its own, so it keeps the original path.
function band.localize(proj, path)
  if reaper.GetProjectName(proj) == "" then return path end
  local dir = norm(reaper.GetProjectPathEx(proj)) .. "/bandsync"
  local parent, name = path:match("([^/]+)/([^/]+)$")
  local dst = dir .. "/" .. parent .. "_" .. name
  if not reaper.file_exists(dst) then
    reaper.RecursiveCreateDirectory(dir, 0)
    band.copy_atomic(path, dst)
  end
  return dst
end

-- ---- stems ----------------------------------------------------------------------------------

local function best(dir, st)
  local full, prev = dir .. "/" .. st.file, st.preview and (dir .. "/" .. st.preview)
  if reaper.file_exists(full) then return full, "full" end
  if prev and reaper.file_exists(prev) then return prev, "preview" end
end

-- Make the active project's stem tracks match session s. With upgrade_only, just swap preview
-- stems for full-quality files that have since arrived. Returns the number of tracks changed.
function band.sync_stems(proj, cfg, song, s, upgrade_only)
  local dir = band.song_dir(cfg, song)
  local existing = {}
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    local key = band.track_ext(tr, "band_stem")
    if key ~= "" then existing[key] = tr end
  end
  local changed = 0
  for idx, st in ipairs(s.stems or {}) do
    local path, quality = best(dir, st)
    local tr = existing[st.name]
    local item = tr and reaper.GetTrackMediaItem(tr, 0)
    if path and upgrade_only then
      if item and quality == "full" and band.item_ext(item, "band_quality") == "preview" then
        band.swap_source(item, band.localize(proj, path))
        band.set_item_ext(item, "band_quality", quality)
        changed = changed + 1
      end
    elseif path then
      if not tr then
        reaper.InsertTrackAtIndex(idx - 1, true)
        tr = reaper.GetTrack(proj, idx - 1)
        reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "[stem] " .. st.name, true)
        reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_stem", st.name, true)
      end
      for i = reaper.CountTrackMediaItems(tr) - 1, 0, -1 do
        reaper.DeleteTrackMediaItem(tr, reaper.GetTrackMediaItem(tr, i))
      end
      item = band.add_item(tr, band.localize(proj, path), 0)
      if item then band.set_item_ext(item, "band_quality", quality) end
      changed = changed + 1
    end
  end
  return changed
end

-- ---- takes ----------------------------------------------------------------------------------

function band.take_state(proj, id) return select(2, reaper.GetProjExtState(proj, band.TAKES, id)) end
function band.set_take_state(proj, id, v) reaper.SetProjExtState(proj, band.TAKES, id, v) end

function band.find_take_item(proj, id)
  for i = 0, reaper.CountMediaItems(proj) - 1 do
    local it = reaper.GetMediaItem(proj, i)
    if band.item_ext(it, "band_take") == id then return it end
  end
end

-- Where a take lands. mode: "lanes" (new fixed lane on the matching track), "person"
-- ("Takes - <user>" track) or "inbox" (one muted "BandSync inbox" track).
local function target(proj, t, mode)
  if mode == "person" then
    local name = "Takes - " .. t.user
    return band.find_track(proj, name) or band.new_track(proj, name)
  elseif mode == "inbox" then
    local tr = band.find_track(proj, "BandSync inbox")
    if not tr then
      tr = band.new_track(proj, "BandSync inbox")
      if tr then reaper.SetMediaTrackInfo_Value(tr, "B_MUTE", 1) end
    end
    return tr
  end
  local tr = band.find_track(proj, t.track, true)
  if not tr then return band.new_track(proj, t.track) end
  if reaper.CountTrackMediaItems(tr) == 0 then return tr end -- first take on an empty part just plays
  if reaper.GetMediaTrackInfo_Value(tr, "I_FREEMODE") ~= 2 then
    reaper.SetMediaTrackInfo_Value(tr, "I_FREEMODE", 2)
    reaper.UpdateTimeline()
  end
  local lane = math.floor(reaper.GetMediaTrackInfo_Value(tr, "I_NUMFIXEDLANES"))
  reaper.SetMediaTrackInfo_Value(tr, "I_NUMFIXEDLANES", lane + 1)
  return tr, lane
end

-- Insert take t (a take manifest) from path, or upgrade its source if already placed.
function band.place_take(proj, t, path, mode)
  path = band.localize(proj, path)
  local item = band.find_take_item(proj, t.id)
  if item then return band.swap_source(item, path) end
  local label = string.format("%s · %s · %s", t.room, t.user, (t.sent or ""):sub(12, 16))
  local tr, lane = target(proj, t, mode)
  if not tr then return false end
  item = band.add_item(tr, path, t.pos, t.len)
  if not item then return false end
  band.set_item_ext(item, "band_take", t.id)
  reaper.GetSetMediaItemTakeInfo_String(reaper.GetActiveTake(item), "P_NAME", label .. " · " .. t.track, true)
  if lane then -- name the lane only once an item lives in it, or the name doesn't stick
    reaper.SetMediaItemInfo_Value(item, "I_FIXEDLANE", lane)
    reaper.GetSetMediaTrackInfo_String(tr, "P_LANENAME:" .. lane, label, true)
    reaper.SetMediaTrackInfo_Value(tr, "C_LANEPLAYS:" .. lane, 0) -- never change what is already playing
  end
  if mode == "inbox" then reaper.GetSetMediaItemInfo_String(item, "P_NOTES", label .. " → " .. t.track, true) end
  return true
end

return band
