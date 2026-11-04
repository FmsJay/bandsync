-- Run inside REAPER (ReaScript), silently: nothing plays. The producer's seat as far as one computer can show it: the effects load and sit either side of SonoBus's place,
-- what's quiet here isn't sent, the talkback track isn't mirrored, and stopping leaves nothing behind. (The sound itself: rendered through Opus by hand, 0.57.)
-- A scratch tab and shared folder, saved there and closed at the end.
local D = reaper.GetResourcePath() .. "/StudioSync/tests"
reaper.RecursiveCreateDirectory(D, 0)
package.path = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/?.lua;" .. package.path
for _, m in ipairs({ "band", "sync", "mirror", "hear", "live", "stamp", "producer" }) do package.loaded[m] = nil end
local band, sync, mirror, hear, live, stamp, producer = require("band"), require("sync"), require("mirror"), require("hear"), require("live"), require("stamp"), require("producer")
local root = D .. "/stroot_" .. os.time()
local song, room = "StampLab", "main"
local A = { user = "James", root = root }
reaper.RecursiveCreateDirectory(sync.room_dir(A, song, room) .. "/events", 0)
local yes = function() return true end
local out, fails = {}, 0
local function check(ok, what) if not ok then fails = fails + 1 end; out[#out + 1] = (ok and "PASS " or "FAIL ") .. what end
local front = reaper.EnumProjects(-1)
reaper.Main_OnCommand(40859, 0); local p = reaper.EnumProjects(-1)
local function watch() repeat mirror.watch(p, A, song, room, { can = yes, mode = "claims" }) until not mirror.more end
local function sent()
  local n = 0
  for _ in ipairs(band.files(sync.room_dir(A, song, room) .. "/events", ".json")) do n = n + 1 end
  return n
end
local function names(tr)
  local t = {}
  for i = 0, reaper.TrackFX_GetCount(tr) - 1 do t[#t + 1] = select(2, reaper.TrackFX_GetFXName(tr, i, "")) end
  return table.concat(t, " | ")
end
local key = "produce " .. tostring(p)
local ok, err = pcall(function()
  reaper.InsertTrackInProject(p, 0, 0)
  local keys = reaper.GetTrack(p, 0)
  reaper.GetSetMediaTrackInfo_String(keys, "P_NAME", "Keys", true)
  watch()
  -- the effects compile and sit the right way round, with something standing in for SonoBus between them
  local rt = live.rt_track(p, true)
  check(rt ~= nil and mirror.local_track(rt), "the Real time track is this computer's own")
  reaper.TrackFX_AddByName(rt, "ReaEQ", false, -1)
  check(stamp.send(p, true, 12) == true, "the sender goes on")
  check(stamp.read(p, true, 4) == true, "the reader goes on")
  local list = names(rt)
  check(list:find("^JS: StudioSync stamp send") and list:find("ReaEQ") and list:find("StudioSync stamp read$"), "sender first, reader last: " .. list)
  local si, ri = 0, reaper.TrackFX_GetCount(rt) - 1
  check(reaper.TrackFX_GetParam(rt, si, 0) == 1 and math.abs(reaper.TrackFX_GetParam(rt, si, 1) - 12) < 0.01, "the sender is on, taking off the delay")
  check(reaper.TrackFX_GetParam(rt, ri, 0) == 1 and reaper.TrackFX_GetParam(rt, ri, 1) == 4, "the reader reads the pair it was told")
  check(stamp.read(p, true, 6) == true and names(rt) == list, "asking again adds nothing")
  check(reaper.TrackFX_GetParam(rt, reaper.TrackFX_GetCount(rt) - 1, 1) == 6, "and moves it to the new pair")
  local st = stamp.status()
  check(type(st.count) == "number" and st.active == false, "the reader's there to be asked, and hears nothing yet")
  stamp.send(p, false); stamp.read(p, false)
  check(reaper.TrackFX_GetParam(rt, si, 0) == 0, "off is off")
  -- the live mix knows whose right channel is stamps
  local m, i = hear.mix(p, true)
  check(m ~= nil, "the live mix loads")
  hear.set_stamped(p, 5)
  check(reaper.TrackFX_GetParam(m, i, 9) == 5, "it takes the pairs with stamps (" .. tostring(reaper.TrackFX_GetParam(m, i, 9)) .. ")")
  hear.set_stamped(p, 0)
  -- what's being sung over goes quiet here, and that isn't a mute to send
  local n0 = sent()
  producer.quiet_tracks(p, { "Keys" })
  check(reaper.GetMediaTrackInfo_Value(keys, "B_MUTE") == 1, "their track goes quiet here")
  watch()
  check(sent() == n0, "and nothing's sent (" .. (sent() - n0) .. ")")
  producer.quiet_tracks(p, {})
  check(reaper.GetMediaTrackInfo_Value(keys, "B_MUTE") == 0, "it comes back")
  watch()
  check(sent() == n0, "and that isn't sent either")
  reaper.SetMediaTrackInfo_Value(keys, "B_MUTE", 1)
  producer.quiet_tracks(p, { "Keys" })
  producer.quiet_tracks(p, {})
  check(reaper.GetMediaTrackInfo_Value(keys, "B_MUTE") == 1, "a track that was muted already stays muted")
  reaper.SetMediaTrackInfo_Value(keys, "B_MUTE", 0)
  watch()
  -- talkback: its own track, feeding SonoBus only while you talk, and nobody else's business
  local n1 = sent()
  producer.talk(p, false)
  check(not producer.talking(p), "not talking to begin with")
  producer.talk(p, true)
  check(producer.talking(p), "talking")
  local talk
  for t = 0, reaper.CountTracks(p) - 1 do
    local tr = reaper.GetTrack(p, t)
    if select(2, reaper.GetTrackName(tr)) == "StudioSync talkback" then talk = tr end
  end
  check(talk ~= nil and mirror.local_track(talk), "on a track of this computer's")
  check(talk and reaper.GetMediaTrackInfo_Value(talk, "B_MAINSEND") == 0, "you don't hear yourself")
  check(talk and reaper.GetMediaTrackInfo_Value(talk, "I_RECMODE") == 2, "and pressing record makes no file of it")
  check(live.rt_sends(p) >= 1, "it feeds SonoBus")
  watch()
  check(sent() == n1, "none of it's sent (" .. (sent() - n1) .. ")")
  -- producer.tick: nobody's asked, nothing starts
  producer.tick(p, A, { project = p, song = song, room = room }, { { user = "Maya" } })
  check(reaper.GetExtState(band.SECTION, "produced by " .. tostring(p)) == "", "nobody's producing me")
  -- someone asks through their status: the sender comes on (with SonoBus absent here, only as far as this computer can)
  reaper.SetExtState(band.SECTION, key, "Maya", false)
  check(producer.who(p) == "Maya" and producer.behind(p, "Maya") == 1.5 and producer.behind(p, "Sam") == nil, "only the one you're producing sets the lag")
  producer.set_lag(p, 0.1)
  check(producer.lag(p) == producer.MIN_LAG, "not less than it can do")
  producer.set_lag(p, 3)
  check(producer.behind(p, "Maya") == 3, "the lag's yours to set")
  reaper.SetProjExtState(p, band.SECTION, "produce lag", "")
  producer.stop(p, A, { project = p, song = song, room = room })
  check(producer.who(p) == nil, "stopping stops it")
  local left = false
  for t = 0, reaper.CountTracks(p) - 1 do left = left or select(2, reaper.GetTrackName(reaper.GetTrack(p, t))) == "StudioSync talkback" end
  check(not left, "the talkback track goes with it")
end)
reaper.DeleteExtState(band.SECTION, key, false)
if not ok then out[#out + 1] = "ERROR " .. tostring(err); fails = fails + 1 end
reaper.SelectProjectInstance(p)
reaper.Main_SaveProjectEx(p, D .. "/stamp_chain.rpp", 8)
reaper.Main_OnCommand(40860, 0)
if front and reaper.ValidatePtr2(0, front, "ReaProject*") then reaper.SelectProjectInstance(front) end
return (fails == 0 and "ALL PASS" or (fails .. " FAILED")) .. "\n" .. table.concat(out, "\n")
