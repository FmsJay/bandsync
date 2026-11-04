-- Run inside REAPER (ReaScript). StudioSync's live mix (lib/hear.lua) without SonoBus: tracks stand in for what SonoBus
-- would bring in, sent onto the Real time track's pairs as SonoBus would, and the master is rendered and listened to:
-- each person at their level or off, "their time" delaying the backing and nothing else. Also a guest's feed (every
-- band track to SonoBus) and the band's colours held when the Real time track goes in. Scratch tab and folder only.
local D = reaper.GetResourcePath() .. "/StudioSync/tests"
reaper.RecursiveCreateDirectory(D, 0)
local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/"
package.path = lib .. "?.lua;" .. package.path
for _, m in ipairs({ "band", "mirror", "live", "hear", "guest" }) do package.loaded[m] = nil end
local band, mirror, live, hear, guest = require("band"), require("mirror"), require("live"), require("hear"), require("guest")
local stamp = os.time()
local out, fails = {}, 0
local function check(ok, what) if not ok then fails = fails + 1 end; out[#out + 1] = (ok and "PASS " or "FAIL ") .. what end
local front = reaper.EnumProjects(-1)
local p
local wav = D .. "/hear_click.wav"
local f = assert(io.open(wav, "wb")); f:write(guest.click_wav()); f:close() -- (its first click is at 0)

local function item(tr, at)
  local it = reaper.AddMediaItemToTrack(tr)
  reaper.SetMediaItemTake_Source(reaper.AddTakeToMediaItem(it), reaper.PCM_Source_CreateFromFile(wav))
  reaper.SetMediaItemInfo_Value(it, "D_POSITION", at)
  reaper.SetMediaItemInfo_Value(it, "D_LENGTH", 0.3) -- (one click)
end
local function track(name)
  local n = reaper.CountTracks(p)
  reaper.InsertTrackInProject(p, n, 0)
  local tr = reaper.GetTrack(p, n)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", name, true)
  return tr
end
-- render the master 0-7 s and find the first click in each window
local n_render = 0
local function render()
  n_render = n_render + 1
  local name = "hear_" .. stamp .. "_" .. n_render
  band.render({ RENDER_SETTINGS = 0, RENDER_BOUNDSFLAG = 0, RENDER_STARTPOS = 0, RENDER_ENDPOS = 7, RENDER_SRATE = 48000,
    RENDER_CHANNELS = 2, RENDER_TAILFLAG = 0, RENDER_TAILMS = 0, RENDER_ADDTOPROJ = 0 },
    { RENDER_FILE = D, RENDER_PATTERN = name, RENDER_FORMAT = band.FLAC, RENDER_FORMAT2 = "" })
  local tr = track("probe")
  local it = reaper.AddMediaItemToTrack(tr)
  local tk = reaper.AddTakeToMediaItem(it)
  reaper.SetMediaItemTake_Source(tk, reaper.PCM_Source_CreateFromFile(D .. "/" .. name .. ".flac"))
  reaper.SetMediaItemInfo_Value(it, "D_LENGTH", 7)
  local acc = reaper.CreateTakeAudioAccessor(tk)
  local sr, n = 48000, 7 * 48000
  local buf = reaper.new_array(n * 2)
  reaper.GetAudioAccessorSamples(acc, sr, 2, 0, n, buf)
  reaper.DestroyAudioAccessor(acc)
  reaper.DeleteTrack(tr)
  local t = buf.table()
  local function onset(from, to)
    for k = math.floor(from * sr), math.floor(to * sr) - 1 do
      if math.abs(t[2 * k + 1] or 0) > 0.1 then return k / sr end
    end
  end
  return { backing = onset(0.5, 2.5), peer = onset(2.5, 4.5), other = onset(4.5, 6.5) }
end
local function near(a, b) return a and math.abs(a - b) < 0.003 end
local function fmt(r) return string.format("backing %s, peer %s, other %s", tostring(r.backing), tostring(r.peer), tostring(r.other)) end

local ok, err = pcall(function()
  reaper.Main_OnCommand(40859, 0); p = reaper.EnumProjects(-1)
  local backing = track("Backing")
  reaper.SetMediaTrackInfo_Value(backing, "I_CUSTOMCOLOR", 0x1000000 | 0x3366CC)
  item(backing, 1.0)
  -- the Real time track goes in with the band's colours held
  local rt = mirror.add_local_track(p, live.RT_NAME, "realtime")
  reaper.SetMediaTrackInfo_Value(backing, "I_CUSTOMCOLOR", 0x1000000 | 0xFF0000) -- (as an auto-colour rule would)
  mirror.hold_colours()
  check(reaper.GetMediaTrackInfo_Value(backing, "I_CUSTOMCOLOR") == 0x1000000 | 0x3366CC, "the band's colour held when the Real time track went in")
  -- SonoBus's outputs stand-ins: "Peer" on their own pair (channels 5-6), someone without one on 1-2
  local function feeder(name, at, dst)
    local tr = track(name)
    reaper.SetMediaTrackInfo_Value(tr, "B_MAINSEND", 0)
    item(tr, at)
    local s = reaper.CreateTrackSend(tr, rt)
    reaper.SetTrackSendInfo_Value(tr, 0, s, "I_DSTCHAN", dst)
    return tr
  end
  hear.route(p, rt)
  feeder("Peer (stand-in)", 3.0, 4)
  feeder("Other (stand-in)", 5.0, 0)
  hear.set_pairs(p, { Peer = 4 })
  local m, i = hear.mix(p, false)
  check(m and i == reaper.TrackFX_GetCount(m) - 1, "the live mix is last on the master")
  check(reaper.GetMediaTrackInfo_Value(m, "I_NCHAN") >= 18 and reaper.GetMediaTrackInfo_Value(rt, "I_NCHAN") >= 16
    and reaper.GetMediaTrackInfo_Value(rt, "C_MAINSEND_OFFS") == 2, "the master has room for SonoBus's pairs, which arrive on 3-18")

  local r = render()
  check(near(r.backing, 1.0) and near(r.peer, 3.0) and near(r.other, 5.0), "everyone heard, on time: " .. fmt(r))
  hear.set_on(p, "Peer", false)
  r = render()
  check(near(r.backing, 1.0) and r.peer == nil and near(r.other, 5.0), "Peer muted, nobody else: " .. fmt(r))
  check(not hear.is_on(p, "Peer") and hear.is_on(p, "Somebody"), "is_on reads it back")
  hear.set_on(p, "Peer", true)
  hear.set_on(p, nil, false)
  r = render()
  check(near(r.peer, 3.0) and r.other == nil, "everyone else off, Peer on: " .. fmt(r))
  hear.set_on(p, nil, true)
  hear.set_delay(p, 250)
  r = render()
  check(near(r.backing, 1.25) and near(r.peer, 3.0) and near(r.other, 5.0), "their time: only the backing comes 250 ms later: " .. fmt(r))
  check(math.abs(hear.delay(p) - 250) < 0.5, "delay reads back")
  hear.set_delay(p, 0)

  -- a guest: every band track (top level) feeds SonoBus, the stand-ins too (they're band tracks here); the click track as well
  reaper.SetProjExtState(p, band.SECTION, "guest", "1")
  local n = live.rt_sends(p)
  check(n == 3, "with a guest, every band track feeds the Real time track (" .. n .. ")")
  reaper.SetProjExtState(p, band.SECTION, "guest", "")
  n = live.rt_sends(p)
  check(n == 0, "without one, only what's armed (" .. n .. ")")
  -- (the master's chain travels to the band, but never the live mix)
  local _, mch = reaper.GetTrackStateChunk(m, "", false)
  check(not (mirror.fxchain(mch, mirror.live_fx(m)) or ""):find("StudioSync live mix", 1, true), "the live mix never goes to the band")
end)
if not ok then fails = fails + 1; out[#out + 1] = "ERROR " .. tostring(err) end
if p and reaper.ValidatePtr2(0, p, "ReaProject*") then
  reaper.SelectProjectInstance(p)
  reaper.Main_SaveProjectEx(p, D .. "/hear_" .. stamp .. "_end.rpp", 8)
  reaper.Main_OnCommand(40860, 0)
end
if front and reaper.ValidatePtr2(0, front, "ReaProject*") then reaper.SelectProjectInstance(front) end
return (fails == 0 and "ALL PASS" or fails .. " FAILED") .. "\n" .. table.concat(out, "\n")
