-- @description BandSync: publish this project to the shared folder (you become the song's host)
-- Every song is a mirror session (docs/mirror-design.md): everyone in the room holds the same project, and Live sync
-- carries every track and item.
local dir = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
package.path = dir .. "/lib/?.lua;" .. package.path
local band = require("band")

local cfg = band.settings()
if not cfg then return end
local proj, projfile = reaper.EnumProjects(-1)
local b = band.binding(proj) or {}

-- a new song must be prepared first (takes into lanes, FLAC, unique track names...): much harder to tidy once the
-- band has it, so there is no "publish as it is"
if not b.song and reaper.GetExtState(band.SECTION, "prepared " .. tostring(proj)) == "" then
  -- nothing goes to the group that hasn't been through the checklist (James, 2026-11-03): its last button comes back here
  reaper.SetExtState(band.SECTION, "share after prepare", "1", false)
  local id = reaper.AddRemoveReaScript(true, 0, dir .. "/BandSync - Prepare session.lua", true)
  if id > 0 then reaper.Main_OnCommand(id, 0) end
  return
end
reaper.DeleteExtState(band.SECTION, "prepared " .. tostring(proj), false)
if not b.song then -- (only a setting, nothing recorded changes: done here, without a question)
  reaper.GetSetProjectInfo_String(proj, "RECORD_FORMAT", band.FLAC, true)
  reaper.GetSetProjectInfo(proj, "PROJECT_SRATE", band.srate(proj), true)
  reaper.GetSetProjectInfo(proj, "PROJECT_SRATE_USE", 1, true)
end

local projname = reaper.GetProjectName(proj)
local suggested = b.song or band.clean(projname:gsub("%.[Rr][Pp][Pp]$", ""))
local old_for = function(song) return band.read_json(band.session_path(cfg, song)) end
local ok, name = true, reaper.GetExtState(band.SECTION, "publish as") -- (Start a new group/session has asked already)
if name == "" then ok, name = reaper.GetUserInputs("StudioSync: share this project", 1, "Project name,extrawidth=150", suggested) end
if not ok then return end
local song = band.clean(name)
if song == "" then return band.msg("Give the project a name.") end
require("songsync").want(cfg, song) -- (yours: it syncs here in full, whatever this computer downloads of others)
local old = old_for(song)
if old and old.host ~= cfg.user and b.song ~= song then
  return band.msg("There's already a studio project called '" .. song .. "' (hosted by " .. tostring(old.host) .. ").\n\n" ..
    "Pick another name, or join theirs with 'BandSync - Open session'.")
end
if old and b.song ~= song and reaper.MB("You already published a project called '" .. song .. "' from another project.\n\n" ..
    "Publish this project under that name instead (everyone then follows this one)?", "StudioSync", 4) ~= 6 then
  return
end
-- an untitled project takes the song's name and is saved first; either way a copy as it was before BandSync is kept
local pdir
if projfile == "" then
  pdir = reaper.GetResourcePath() .. "/BandSync/" .. song
  reaper.RecursiveCreateDirectory(pdir, 0)
  reaper.Main_SaveProjectEx(proj, pdir .. "/" .. song .. ".rpp", 8) -- &8: becomes this project's file
else
  pdir = projfile:match("^(.*)[/\\]")
end
if not b.song then
  reaper.Main_SaveProjectEx(proj, pdir .. "/" .. song .. " (before BandSync).rpp", 0) -- a copy; History offers it back
  reaper.SetProjExtState(proj, band.SECTION, "before_bandsync", pdir .. "/" .. song .. " (before BandSync).rpp")
end
reaper.SetExtState(band.SECTION, "project file " .. song, (select(2, reaper.EnumProjects(-1)):gsub("\\", "/")), true)
reaper.RecursiveCreateDirectory(band.song_dir(cfg, song) .. "/rooms/main/media", 0)
local version = (old and old.version or 0) + 1
band.write_json(band.session_path(cfg, song), {
  format = band.FORMAT, bandsync = band.VERSION, song = song, host = cfg.user, version = version, sync = "mirror",
  published = os.date("!%Y-%m-%dT%H:%M:%SZ"), srate = band.srate(proj),
  tempo = band.capture_tempo(proj), markers = band.capture_markers(proj),
})
band.bind(proj, { role = "host", song = song, room = "main", version = version, root = cfg.root })
reaper.SetProjExtState(proj, band.SECTION, "timeline", band.json_encode({ band.capture_tempo(proj), band.capture_markers(proj) }))
reaper.Main_SaveProject(proj, false)
local beat = tonumber(reaper.GetExtState(band.SECTION, "live " .. tostring(proj)))
if not (beat and reaper.time_precise() - beat < 5) then band.start_live(dir) end
return band.log(string.format("published '%s': Live sync is sending the project to the studio (collaborators: it's on their Projects page)", song))
