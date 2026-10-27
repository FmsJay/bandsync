-- @description BandSync: measure how early/late your recordings land, using a loopback cable
-- Plays three clicks out of output 1, records them back in through a cable, and measures where they
-- landed. 0 ms means your takes line up with everyone else's. Runs in its own temporary project tab.
local dir = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
package.path = dir .. "/lib/?.lua;" .. package.path
local band = require("band")

local SR, CLICKS, LEN = 48000, { 1.0, 1.5, 2.0 }, 3.0

if reaper.GetPlayState() ~= 0 then return band.msg("Stop playback first.") end
local ok, ch = reaper.GetUserInputs("BandSync: latency calibration", 1, "Loopback input channel (1, 2, ...),extrawidth=40", "1")
ch = ok and tonumber(ch)
if not ch then return end
if reaper.MB("Connect a cable from your interface's OUTPUT 1 to INPUT " .. ch .. ".\nTurn speakers/headphones down: three clicks will play.\n\nReady?",
    "BandSync", 1) ~= 1 then return end

-- a 3 s mono WAV with one full-scale sample at each click time
local work = reaper.GetResourcePath() .. "/BandSync/calibration"
reaper.RecursiveCreateDirectory(work, 0)
for _, f in ipairs(band.files(work)) do -- previous runs' recordings
  if f ~= "click.wav" and not f:match("%.rpp") then os.remove(work .. "/" .. f) end
end
local parts, last = {}, 0
for _, t in ipairs(CLICKS) do
  local s = math.floor(t * SR)
  parts[#parts + 1] = string.rep("\0\0", s - last) .. string.pack("<i2", 32000)
  last = s + 1
end
parts[#parts + 1] = string.rep("\0\0", math.floor(LEN * SR) - last)
local data = table.concat(parts)
local wav = work .. "/click.wav"
local f = assert(io.open(wav, "wb"))
f:write(string.pack("<c4I4c4c4I4I2I2I4I4I2I2c4I4", "RIFF", 36 + #data, "WAVE", "fmt ", 16, 1, 1, SR, SR * 2, 2, 16, "data", #data), data)
f:close()

-- temporary project tab: click track out to the master, record track on the loopback input, no monitoring
reaper.Main_OnCommand(40859, 0) -- File: New project tab
local proj = reaper.EnumProjects(-1)
reaper.Main_SaveProjectEx(proj, work .. "/calibration.rpp", 8) -- a saved tab closes later without a prompt
local click_tr = band.new_track(proj, "click")
band.add_item(click_tr, wav, 0)
local rec_tr = band.new_track(proj, "loopback")
reaper.SetMediaTrackInfo_Value(rec_tr, "I_RECINPUT", ch - 1) -- mono input, 0-based
reaper.SetMediaTrackInfo_Value(rec_tr, "I_RECMODE", 0)        -- record the input
reaper.SetMediaTrackInfo_Value(rec_tr, "I_RECMON", 0)         -- no monitoring: avoids a feedback loop
reaper.SetMediaTrackInfo_Value(rec_tr, "I_RECARM", 1)
reaper.SetEditCurPos2(proj, 0, false, false)
-- the metronome and record pre-roll would play into the measurement windows: off for the run, then restored
local restore = {}
for _, id in ipairs({ 40364, 41819 }) do -- Options: Toggle metronome; Pre-roll: toggle pre-roll on record
  if reaper.GetToggleCommandState(id) == 1 then reaper.Main_OnCommand(id, 0); restore[#restore + 1] = id end
end
local function put_back()
  for _, id in ipairs(restore) do reaper.Main_OnCommand(id, 0) end
  restore = {}
end
reaper.atexit(put_back) -- also restores if the analysis throws
reaper.Main_OnCommand(1013, 0) -- Transport: Record

local function finish()
  local item = reaper.GetTrackMediaItem(rec_tr, 0)
  local report
  if not item then
    report = "Nothing was recorded. Check that REAPER's audio device is open and input " .. ch .. " exists."
  else
    local acc = reaper.CreateTakeAudioAccessor(reaper.GetActiveTake(item))
    local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local n = math.floor(LEN * SR)
    local buf = reaper.new_array(n)
    reaper.GetAudioAccessorSamples(acc, SR, 1, 0, n, buf)
    reaper.DestroyAudioAccessor(acc)
    local offsets, weakest = {}, 1
    for _, t in ipairs(CLICKS) do -- loudest sample from 50 ms before to 200 ms after each click
      local best, at = 0, nil
      for i = math.max(1, math.floor((t - pos - 0.05) * SR)), math.min(n, math.floor((t - pos + 0.2) * SR)) do
        local v = math.abs(buf[i])
        if v > best then best, at = v, i end
      end
      weakest = math.min(weakest, best)
      if at then offsets[#offsets + 1] = (pos + (at - 1) / SR - t) * 1000 end
    end
    if weakest < 0.02 or #offsets < #CLICKS then
      report = string.format("No clear clicks came back (loudest %.3f). Check the cable goes from output 1 to input %d, and the input gain.", weakest, ch)
    else
      local lo, hi, sum = math.huge, -math.huge, 0
      for _, o in ipairs(offsets) do lo, hi, sum = math.min(lo, o), math.max(hi, o), sum + o end
      local ms = sum / #offsets
      reaper.SetExtState(band.SECTION, "rec_offset_ms", string.format("%.3f", ms), true)
      local _, rate = reaper.GetAudioDeviceInfo("SRATE")
      local samples = math.floor(math.abs(ms) / 1000 * (tonumber(rate) or SR) + 0.5)
      -- verified on a ToneX (ASIO, 44.1 kHz): 203 samples LATE fixed by Input manual offset +203
      report = string.format(
        "Recordings land %.2f ms %s (%d samples at %s Hz; spread %.2f ms across the 3 clicks).\n\n%s",
        math.abs(ms), ms >= 0 and "LATE" or "EARLY", samples, rate or "?", hi - lo,
        math.abs(ms) < 1 and "That's within 1 ms: your takes line up. Nothing to do."
        or string.format("Fix: Preferences > Audio > Recording, %s %d samples %s the INPUT manual offset, then run this again.\n" ..
          "Re-run after changing your audio device, sample rate or buffer size.",
          ms >= 0 and "add" or "subtract", samples, ms >= 0 and "to" or "from"))
    end
  end
  put_back()
  reaper.Main_SaveProject(proj, false)
  reaper.Main_OnCommand(40860, 0) -- File: Close current project tab
  band.msg(report)
end

local function wait()
  if reaper.GetPlayPosition2Ex(proj) < LEN - 0.2 and reaper.GetPlayStateEx(proj) & 4 == 4 then return reaper.defer(wait) end
  reaper.Main_OnCommand(40667, 0) -- Transport: Stop (save all recorded media), so no keep/delete prompt
  finish()
end
reaper.defer(wait)
