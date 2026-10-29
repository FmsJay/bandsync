-- @description BandSync: join a published song, or refresh this project from the latest publish
-- Builds a local project with the host's sample rate, tempo map, markers and stems, so you record
-- on the same timeline with no latency. Re-run any time to pick up a new publish.
local dir = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
package.path = dir .. "/lib/?.lua;" .. package.path
local band = require("band")

local cfg = band.settings()
if not cfg then return end
local b = band.binding(0)
if reaper.GetExtState(band.SECTION, "open_other") ~= "" then -- the panel's "Open another song": the chooser, then a new tab
  reaper.DeleteExtState(band.SECTION, "open_other", false)
  b = nil
end
if b and b.role == "host" then
  return band.msg("This is the host project for '" .. b.song .. "'. Open the session in a new project tab instead.")
end

local function open_song(song, room) -- room: for a new tab (nil when refreshing a bound one)
  local s = band.read_json(band.session_path(cfg, song))
  if not s then return band.msg("Couldn't read session.json for '" .. song .. "' (still syncing?).") end
  band.check_version(s.bandsync, "'" .. song .. "'")

  if not b then
    room = (room and room ~= "") and room or "main"
    local rooms = require("rooms")
    local m = rooms.meta(cfg, song, room)
    if m and m.parent then -- a side room is a copy of the room it came from: made from your tab of that room
      local from = rooms.tab(song, m.parent)
      if not from then return band.msg("'" .. room .. "' is a side room of '" .. m.parent .. "'. Open '" .. m.parent .. "' first, then go there from the panel's Rooms tab.") end
      local p, why = rooms.open(from, cfg, band.binding(from), room)
      if not p then return band.msg(why) end
      return band.msg("Opened the side room '" .. room .. "' in its own tab. Start Live sync there (panel: Start).")
    end
    for i = 0, math.huge do -- already open here? two tabs of one song share its file and its status (2026-10-28)
      local p = reaper.EnumProjects(i)
      if not p then break end
      local ob = band.binding(p)
      if ob and ob.song == song and ob.room == room and ob.role ~= "solo" then
        reaper.SelectProjectInstance(p)
        return band.msg("'" .. song .. "' (room " .. room .. ") is already open in another tab: switched to it.")
      end
    end
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
  -- the band's timeline, not a local edit: Live sync mustn't send it back (lib/sync.lua timeline_sig)
  reaper.SetProjExtState(proj, band.SECTION, "timeline", band.json_encode({ band.capture_tempo(proj), band.capture_markers(proj) }))
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
end

if b then return open_song(b.song) end
if #band.songs(cfg) == 0 then return band.msg("No published songs found in " .. cfg.root) end
require("chooser").open(cfg, { title = "Open a band song", action = "Open", rooms = "new" },
  function(song, room) if song then open_song(song, room) end end)
