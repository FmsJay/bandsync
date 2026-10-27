-- @description BandSync: join a published song, or refresh this project from the latest publish
-- Builds a local project with the host's sample rate, tempo map, markers and stems, so you record
-- on the same timeline with no latency. Re-run any time to pick up a new publish.
local dir = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
package.path = dir .. "/lib/?.lua;" .. package.path
local band = require("band")

local cfg = band.settings()
if not cfg then return end
local b = band.binding(0)
if b and b.role == "host" then
  return band.msg("This is the host project for '" .. b.song .. "'. Open the session in a new project tab instead.")
end

local song = b and b.song
if not song then
  local songs = band.songs(cfg)
  if #songs == 0 then return band.msg("No published songs found in " .. cfg.root) end
  song = band.pick(songs)
  if not song then return end -- menu dismissed
end
local s = band.read_json(band.session_path(cfg, song))
if not s then return band.msg("Couldn't read session.json for '" .. song .. "' (still syncing?).") end
band.check_version(s.bandsync, "'" .. song .. "'")

if not b then
  local ok, room = reaper.GetUserInputs("Join " .. song, 1, "Room (main, or a new side room),extrawidth=100", "main")
  if not ok then return end
  room = band.clean(room)
  if room == "" then room = "main" end
  if reaper.CountTracks(0) > 0 then reaper.Main_OnCommand(40859, 0) end -- File: New project tab
  b = { role = "guest", song = song, room = room }
end

local proj, projfile = reaper.EnumProjects(-1)
-- First open: save into a local (not synced) folder first, so stems are copied next to the project
-- and recordings stay off the shared folder until sent.
local first_open = projfile == ""
if first_open then
  local local_dir = reaper.GetResourcePath() .. "/BandSync/" .. song
  reaper.RecursiveCreateDirectory(local_dir, 0)
  reaper.Main_SaveProjectEx(proj, local_dir .. "/" .. song .. " - " .. cfg.user .. ".rpp", 8) -- &8: becomes this project's file
end

reaper.Undo_BeginBlock2(proj)
reaper.PreventUIRefresh(1)
reaper.GetSetProjectInfo(proj, "PROJECT_SRATE", s.srate, true)
reaper.GetSetProjectInfo(proj, "PROJECT_SRATE_USE", 1, true)
-- record 24-bit FLAC: Send renders 24-bit, but can't restore detail a 16-bit recording never captured
if first_open then reaper.GetSetProjectInfo_String(proj, "RECORD_FORMAT", band.FLAC, true) end
band.apply_tempo(proj, s.tempo)
band.apply_markers(proj, s.markers)
local n = band.sync_stems(proj, cfg, song, s)
if s.share then -- the host shares its real takes and lanes, so stems are only a mixed reference
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    if band.track_ext(tr, "band_stem") ~= "" then reaper.SetMediaTrackInfo_Value(tr, "B_MUTE", 1) end
  end
end
b.version = s.version
band.bind(proj, b)
reaper.RecursiveCreateDirectory(band.takes_dir(cfg, song, b.room), 0)
reaper.PreventUIRefresh(-1)
reaper.TrackList_AdjustWindows(false)
reaper.UpdateArrange()
reaper.Undo_EndBlock2(proj, "BandSync: open " .. song .. " v" .. s.version, -1)

if first_open then reaper.Main_SaveProject(proj, false) end

band.msg(string.format("'%s' v%d by %s, room '%s': %d stem track(s) updated.\n\n" ..
  "Name your recording track like the host's to land in its lanes:\n%s\n\n" ..
  "Run 'BandSync - Live sync' and record: each take goes out by itself when you stop.", song, s.version, s.host, b.room, n, table.concat(s.tracks or {}, ", ")))
