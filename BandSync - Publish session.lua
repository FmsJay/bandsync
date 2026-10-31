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
if not b.song then
  local todo = {}
  for _, r in ipairs(require("prep").scan(proj, cfg, nil)) do
    if r.key == "format" and r.todo ~= nil then
      -- only a setting, nothing recorded changes: done here, without a question
      reaper.GetSetProjectInfo_String(proj, "RECORD_FORMAT", band.FLAC, true)
      reaper.GetSetProjectInfo(proj, "PROJECT_SRATE", band.srate(proj), true)
      reaper.GetSetProjectInfo(proj, "PROJECT_SRATE_USE", 1, true)
    elseif r.todo ~= nil and r.on and r.key ~= "autostart" then todo[#todo + 1] = "  - " .. r.title end
  end
  if #todo > 0 then
    if reaper.MB("This project needs preparing for BandSync first:\n\n" .. table.concat(todo, "\n") ..
        "\n\nOK opens the checklist (you choose what changes). Publish again when it's done.", "BandSync", 1) == 1 then
      local id = reaper.AddRemoveReaScript(true, 0, dir .. "/BandSync - Prepare session.lua", true)
      if id > 0 then reaper.Main_OnCommand(id, 0) end
    end
    return
  end
end

local projname = reaper.GetProjectName(proj)
local suggested = b.song or band.clean(projname:gsub("%.[Rr][Pp][Pp]$", ""))
local old_for = function(song) return band.read_json(band.session_path(cfg, song)) end
local ok, name = reaper.GetUserInputs("BandSync: publish", 1, "Song name,extrawidth=150", suggested)
if not ok then return end
local song = band.clean(name)
if song == "" then return band.msg("Give the song a name.") end
local old = old_for(song)
if old and old.host ~= cfg.user and b.song ~= song then
  return band.msg("There's already a band song called '" .. song .. "' (hosted by " .. tostring(old.host) .. ").\n\n" ..
    "Pick another name, or join theirs with 'BandSync - Open session'.")
end
if old and b.song ~= song and reaper.MB("You already published a song called '" .. song .. "' from another project.\n\n" ..
    "Publish this project under that name instead (the band then follows this one)?", "BandSync", 4) ~= 6 then
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
reaper.RecursiveCreateDirectory(band.song_dir(cfg, song) .. "/rooms/main/media", 0)
local version = (old and old.version or 0) + 1
band.write_json(band.session_path(cfg, song), {
  format = band.FORMAT, bandsync = band.VERSION, song = song, host = cfg.user, version = version, sync = "mirror",
  published = os.date("!%Y-%m-%dT%H:%M:%SZ"), srate = band.srate(proj),
  tempo = band.capture_tempo(proj), markers = band.capture_markers(proj),
})
band.bind(proj, { role = "host", song = song, room = "main", version = version })
reaper.SetProjExtState(proj, band.SECTION, "timeline", band.json_encode({ band.capture_tempo(proj), band.capture_markers(proj) }))
reaper.Main_SaveProject(proj, false)
local beat = tonumber(reaper.GetExtState(band.SECTION, "live " .. tostring(proj)))
if not (beat and reaper.time_precise() - beat < 5) then band.start_live(dir) end
return band.log(string.format("published '%s': Live sync is sending the project to the band (bandmates join with 'BandSync - Open session')", song))
