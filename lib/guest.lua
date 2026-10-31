-- A guest: someone who joins with only SonoBus (a singer at home, no REAPER, no copy of the song). They hear your mix
-- through SonoBus (every band track feeds it while a guest is on: lib/live.lua rt_sends), and what they sing comes
-- back on SonoBus's shared pair, late by the whole round trip: out to them, their interface, back to you. BandSync
-- measures that once (they clap along to 8 clicks it plays them), then lines their takes up by it, and "their time"
-- (lib/hear.lua) delays your own backing by the same amount so you hear them in time while they sing.
-- The idea of measuring the real SonoBus delay is from ReaConnect (AtmanActive, unlicensed: re-implemented, no code).
local band = require("band")
local live = require("live")
local guest = {}

guest.CLICKS, guest.BPM = 8, 90

function guest.on(proj) return select(2, reaper.GetProjExtState(proj, band.SECTION, "guest")) == "1" end
-- Guest on: SonoBus gets the whole mix, and the Real time track records what comes back on SonoBus's shared pair
-- (its output, channels 1-2: bandmates have pairs of their own, a guest doesn't) whenever you record.
function guest.set(proj, on)
  reaper.SetProjExtState(proj, band.SECTION, "guest", on and "1" or "")
  local rt = live.rt_track(proj, false)
  if rt then
    reaper.SetMediaTrackInfo_Value(rt, "I_RECMODE", 1) -- (record: output, stereo)
    reaper.SetMediaTrackInfo_Value(rt, "I_RECMON", 0)
    reaper.SetMediaTrackInfo_Value(rt, "I_RECARM", on and 1 or 0)
  end
  pcall(live.rt_sends, proj)
end

-- The measured round trip (ms), or nil.
function guest.delay(proj) return tonumber(select(2, reaper.GetProjExtState(proj, band.SECTION, "guest delay"))) end

-- Where each clap landed against its click: the first rise past half the loudest sample within each click's window
-- (from the click to the next one). `samples` is mono, `sr` its rate, `t0` the time of the first sample, `beats` the
-- clicks' times. Returns the median lateness in seconds and how many claps were found, or nil. Pure.
function guest.lateness(samples, sr, t0, beats)
  local peak = 0
  for k = 1, #samples do local a = math.abs(samples[k]); if a > peak then peak = a end end
  if peak < 0.01 then return nil, 0 end -- (silence: nobody clapped, or nothing came back)
  local lates = {}
  for b = 1, #beats do
    local from, to = beats[b], beats[b + 1] or (beats[b] + (beats[b] - (beats[b - 1] or beats[b] - 1)))
    local k0, k1 = math.max(1, math.floor((from - t0) * sr) + 1), math.min(#samples, math.floor((to - t0) * sr))
    for k = k0, k1 do
      if math.abs(samples[k]) >= peak * 0.5 then lates[#lates + 1] = (k - 1) / sr + t0 - from; break end
    end
  end
  if #lates < 3 then return nil, #lates end -- (a few claps at least, so one stray noise can't decide it)
  table.sort(lates)
  return lates[(#lates + 1) // 2], #lates
end

-- The clicks as a 48 kHz mono WAV: a bar of count-in (higher) then guest.CLICKS beats, each a short decaying 1 kHz
-- (count-in 1.5 kHz) burst. Pure: returns the file's bytes.
function guest.click_wav()
  local sr, beat = 48000, 60 / guest.BPM
  local n = math.floor((4 + guest.CLICKS + 1) * beat * sr)
  local s = {}
  for k = 1, n do s[k] = 0 end
  for c = 0, 3 + guest.CLICKS do
    local f, k0 = c < 4 and 1500 or 1000, math.floor(c * beat * sr)
    for j = 0, math.floor(0.015 * sr) - 1 do
      s[k0 + j + 1] = math.sin(2 * math.pi * f * j / sr) * math.exp(-j / (0.004 * sr)) * 0.8
    end
  end
  local data = {}
  for k = 1, n do data[k] = string.pack("<i2", math.floor(s[k] * 32767 + 0.5)) end
  local body = table.concat(data)
  return "RIFF" .. string.pack("<I4", 36 + #body) .. "WAVEfmt " .. string.pack("<I4I2I2I4I4I2I2", 16, 1, 1, sr, sr * 2, 2, 16) ..
    "data" .. string.pack("<I4", #body) .. body
end

-- The clicks to clap along to on a track of this machine's own ("click": it feeds SonoBus, lib/live.lua), from `at`.
-- Returns the clapped beats' times (after the count-in) and the track.
function guest.click_track(proj, at)
  local path = reaper.GetResourcePath() .. "/BandSync/measure-clicks-" .. guest.BPM .. ".wav"
  if not reaper.file_exists(path) then
    reaper.RecursiveCreateDirectory(reaper.GetResourcePath() .. "/BandSync", 0)
    local f = assert(io.open(path, "wb"))
    f:write(guest.click_wav())
    f:close()
  end
  local tr = require("mirror").add_local_track(proj, "BandSync click (measuring)", "click")
  local it = reaper.AddMediaItemToTrack(tr)
  reaper.SetMediaItemTake_Source(reaper.AddTakeToMediaItem(it), reaper.PCM_Source_CreateFromFile(path))
  reaper.SetMediaItemInfo_Value(it, "D_POSITION", at)
  reaper.SetMediaItemInfo_Value(it, "D_LENGTH", (4 + guest.CLICKS + 1) * 60 / guest.BPM)
  local beats = {}
  for k = 4, 3 + guest.CLICKS do beats[#beats + 1] = at + k * 60 / guest.BPM end -- (the first bar is the count-in: listen, don't clap)
  return beats, tr
end

-- What came back while measuring: the Real time track's newest recorded item between `from` and `to`, read as mono.
function guest.read_back(proj, from, to)
  local rt = live.rt_track(proj, false)
  if not rt then return nil end
  local it
  for k = 0, reaper.CountTrackMediaItems(rt) - 1 do
    local x = reaper.GetTrackMediaItem(rt, k)
    local p = reaper.GetMediaItemInfo_Value(x, "D_POSITION")
    if p <= from + 0.5 and p + reaper.GetMediaItemInfo_Value(x, "D_LENGTH") >= to - 0.5 then it = x end
  end
  local tk = it and reaper.GetActiveTake(it)
  if not tk then return nil end
  local sr = 8000 -- (enough to find a clap to the ms: 0.125 ms per sample)
  local acc = reaper.CreateTakeAudioAccessor(tk)
  local pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
  local n = math.floor((to - from) * sr)
  local buf = reaper.new_array(n * 2)
  reaper.GetAudioAccessorSamples(acc, sr, 2, from - pos, n, buf)
  reaper.DestroyAudioAccessor(acc)
  local t, out = buf.table(), {}
  for k = 1, n do out[k] = ((t[2 * k - 1] or 0) + (t[2 * k] or 0)) / 2 end
  return out, sr, it
end

-- Line a guest's takes up: the Real time track's items (what came back from them) move to a band track of the
-- guest's name, earlier by the measured round trip, so they sit where they were sung. They're sent to the band then.
function guest.line_up(proj, name)
  local ms = guest.delay(proj)
  local rt = live.rt_track(proj, false)
  if not ms or not rt then return 0 end
  local label = "Guest: " .. (name ~= "" and name or "singer")
  local tr
  for t = 0, reaper.CountTracks(proj) - 1 do
    local x = reaper.GetTrack(proj, t)
    if select(2, reaper.GetTrackName(x)) == label then tr = x end
  end
  reaper.Undo_BeginBlock2(proj)
  if not tr then
    reaper.InsertTrackInProject(proj, reaper.CountTracks(proj) - 1, 0) -- (above the Real time track)
    tr = reaper.GetTrack(proj, reaper.CountTracks(proj) - 2)
    reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", label, true)
  end
  local moved = 0
  for k = reaper.CountTrackMediaItems(rt) - 1, 0, -1 do
    local it = reaper.GetTrackMediaItem(rt, k)
    reaper.MoveMediaItemToTrack(it, tr)
    reaper.SetMediaItemInfo_Value(it, "D_POSITION", math.max(0, reaper.GetMediaItemInfo_Value(it, "D_POSITION") - ms / 1000))
    moved = moved + 1
  end
  reaper.Undo_EndBlock2(proj, "BandSync: line up the guest's takes", -1)
  return moved, label
end

return guest
