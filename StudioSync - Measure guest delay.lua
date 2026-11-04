-- @description StudioSync: measure a guest's delay (they clap along to 8 clicks over SonoBus)
-- For a guest who joins with only SonoBus (lib/guest.lua). StudioSync plays them a bar of count-in and 8 clicks, records
-- what comes back, and finds where their claps land: that's the whole round trip, which then lines up their takes
-- and "their time". Only the Real time track records meanwhile (nothing else is armed, and the band doesn't follow
-- this record press); the clicks and the recording are taken away after.
local dir = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
package.path = dir .. "/lib/?.lua;" .. package.path
local band, live, guest = require("band"), require("live"), require("guest")
local proj = reaper.EnumProjects(-1)
local rt = live.rt_track(proj, false)
local sm, si = live.fx(proj, false, live.SONOBUS)
if not rt or not sm or reaper.TrackFX_GetOffline(sm, si) then
  return band.msg("Turn on Real time mode first (Home), and have your guest join the studio's SonoBus group.")
end
if reaper.GetPlayStateEx(proj) ~= 0 then return band.msg("Stop playback first, then measure.") end
if reaper.MB("Tell your guest: they'll hear a bar of count-in (higher clicks), then 8 clicks. Clap along with the 8, " ..
  "on the beat, as if playing.\n\nReady?", "StudioSync: measure the guest's delay", 1) ~= 1 then return end

-- (put back exactly as it was afterwards: arms, the Real time follow, the edit cursor)
local arms, side, cursor = {}, select(2, reaper.GetProjExtState(proj, band.SECTION, "side")), reaper.GetCursorPositionEx(proj)
local was_guest = guest.on(proj)
for t = 0, reaper.CountTracks(proj) - 1 do
  local tr = reaper.GetTrack(proj, t)
  arms[tr] = reaper.GetMediaTrackInfo_Value(tr, "I_RECARM")
  if tr ~= rt then reaper.SetMediaTrackInfo_Value(tr, "I_RECARM", 0) end
end
reaper.SetProjExtState(proj, band.SECTION, "side", "") -- (this record press is ours alone)
guest.set(proj, true) -- (SonoBus gets the clicks; the Real time track records what comes back)
local at = reaper.GetProjectLength(proj) + 2 -- (past the end: nothing of the song plays under the clicks)
local beats, click = guest.click_track(proj, at)
live.rt_sends(proj)
local stop_at = beats[#beats] + 60 / guest.BPM * 1.5
reaper.SetEditCurPos2(proj, at - 0.5, false, false)
reaper.Main_OnCommand(1013, 0) -- record

local function finish(note)
  reaper.OnStopButtonEx(proj)
  local samples, sr, item = guest.read_back(proj, beats[1] - 0.2, stop_at)
  local late, found
  if samples then late, found = guest.lateness(samples, sr, beats[1] - 0.2, beats) end
  if item then reaper.DeleteTrackMediaItem(rt, item) end
  reaper.DeleteTrack(click)
  for tr, a in pairs(arms) do if reaper.ValidatePtr2(proj, tr, "MediaTrack*") then reaper.SetMediaTrackInfo_Value(tr, "I_RECARM", a) end end
  reaper.SetProjExtState(proj, band.SECTION, "side", side)
  guest.set(proj, was_guest)
  reaper.SetEditCurPos2(proj, cursor, false, false)
  if note then return band.msg(note) end
  if not late then
    return band.msg(string.format("Couldn't measure it: %s.\n\nCheck your guest hears the clicks and claps loud enough " ..
      "near their mic, then try again.", (found or 0) == 0 and "nothing came back from SonoBus" or ("only " .. found .. " claps were heard")))
  end
  reaper.SetProjExtState(proj, band.SECTION, "guest delay", string.format("%.0f", late * 1000))
  band.log(string.format("guest delay: their claps land %.0f ms late (%d of %d heard). Their takes are lined up by that, " ..
    "and Their time uses it. It drifts as SonoBus adjusts: measure again right before you record.", late * 1000, found, #beats))
  if select(2, reaper.GetProjExtState(proj, band.SECTION, "hear their time")) == "1" then require("hear").set_delay(proj, late * 1000) end
end

local started = reaper.time_precise()
local function wait()
  if reaper.GetPlayStateEx(proj) & 4 == 0 and reaper.time_precise() - started > 2 then return finish("Recording stopped before the clicks ended: measure again.") end
  if reaper.GetPlayPositionEx(proj) >= stop_at then return finish() end
  reaper.defer(wait)
end
reaper.defer(wait)
