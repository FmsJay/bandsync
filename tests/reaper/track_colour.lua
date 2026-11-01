-- Run inside REAPER (ReaScript). Track colours travel (0.36): a colour change alone goes to the band, unless SWS
-- auto-colouring colours tracks on that machine (then its colours are its own: not sent, and not set on others when
-- it sends another change). A record from before 0.36, when colour never counted, is re-anchored, not sent.
-- Two scratch tabs, a scratch shared folder; both tabs saved there and closed at the end.
local D = reaper.GetResourcePath() .. "/BandSync/tests"
reaper.RecursiveCreateDirectory(D, 0)
local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/"
package.path = lib .. "?.lua;" .. package.path
for _, m in ipairs({ "band", "sync", "mirror", "recall", "json" }) do package.loaded[m] = nil end
local band, sync, mirror = require("band"), require("sync"), require("mirror")
local root = D .. "/croot_" .. os.time()
local song, room = "ColourLab", "main"
local A, B = { user = "Laptop", root = root }, { user = "Mac", root = root }
local events = sync.room_dir(A, song, room) .. "/events"
reaper.RecursiveCreateDirectory(events, 0)
local yes = function() return true end
local out, fails = {}, 0
local function say(s) out[#out + 1] = s end
local function check(ok, what) if not ok then fails = fails + 1 end; say((ok and "PASS " or "FAIL ") .. what) end
local real_own = mirror.own_colours
local function sws(on) mirror.own_colours = function() return on end end -- (this machine's SWS auto-colouring, as each side sees it)
local front = reaper.EnumProjects(-1)
reaper.Main_OnCommand(40859, 0); local pa = reaper.EnumProjects(-1)
reaper.Main_OnCommand(40859, 0); local pb = reaper.EnumProjects(-1)
for _, p in ipairs({ pa, pb }) do reaper.DeleteExtState(band.SECTION, "mirror drift " .. tostring(p), false) end -- (a closed tab's address comes back)
local function sent(who) local n = 0; for _, f in ipairs(band.files(events, ".json")) do if f:sub(1, #who + 1) == who .. "-" then n = n + 1 end end; return n end
local function watch(p, cfg, own) sws(own); reaper.SelectProjectInstance(p); return mirror.watch(p, cfg, song, room, { can = yes, mode = "claims" }) end
local function recv(p, cfg, own) sws(own); reaper.SelectProjectInstance(p); for _ = 1, 3 do sync.receive(p, cfg, song, room, yes) end; reaper.DeleteExtState(band.SECTION, "colour hold", false) end
local RED, BLUE, GREEN = 0x1000000 | reaper.ColorToNative(200, 30, 30), 0x1000000 | reaper.ColorToNative(30, 30, 200), 0x1000000 | reaper.ColorToNative(30, 200, 30)
local function colour(p) return reaper.GetMediaTrackInfo_Value(reaper.GetTrack(p, 0), "I_CUSTOMCOLOR") end
local ok, err = pcall(function()
  reaper.InsertTrackInProject(pa, 0, 0)
  local ta = reaper.GetTrack(pa, 0)
  reaper.GetSetMediaTrackInfo_String(ta, "P_NAME", "Keys", true)
  reaper.SetMediaTrackInfo_Value(ta, "I_CUSTOMCOLOR", RED)
  watch(pa, A, false)
  recv(pb, B, false)
  check(reaper.CountTracks(pb) == 1 and colour(pb) == RED, "a new track arrives in its colour")
  -- a colour change alone is a change now
  local n = sent("Laptop")
  reaper.SetMediaTrackInfo_Value(ta, "I_CUSTOMCOLOR", BLUE)
  watch(pa, A, false)
  check(sent("Laptop") == n + 1, "recolouring a track sends it (" .. (sent("Laptop") - n) .. ")")
  recv(pb, B, false)
  check(colour(pb) == BLUE, "and the bandmate's track takes the colour")
  watch(pb, B, false); watch(pa, A, false)
  check(sent("Mac") == 0, "receiving it isn't a change of B's (" .. sent("Mac") .. ")")
  -- B has SWS auto-colouring on: its rule recolours the track, which is B's own business
  reaper.SetMediaTrackInfo_Value(reaper.GetTrack(pb, 0), "I_CUSTOMCOLOR", GREEN)
  watch(pb, B, true)
  check(sent("Mac") == 0, "an auto-coloured machine's recolour isn't sent (" .. sent("Mac") .. ")")
  -- ...and a real change of B's (a rename) doesn't carry B's colour to A
  reaper.GetSetMediaTrackInfo_String(reaper.GetTrack(pb, 0), "P_NAME", "Keys 2", true)
  watch(pb, B, true)
  check(sent("Mac") == 1, "B's rename goes out (" .. sent("Mac") .. ")")
  recv(pa, A, false)
  check(select(2, reaper.GetTrackName(ta)) == "Keys 2" and colour(pa) == BLUE, "A takes the name but keeps the band's colour")
  watch(pa, A, false)
  local n2 = sent("Laptop")
  check(n2 == n + 1, "and A sends nothing back (" .. (n2 - n - 1) .. ")")
  -- B switches SWS auto-colouring off: its colours count again, but switching isn't a change by itself
  watch(pb, B, false)
  check(sent("Mac") == 1, "switching auto-colouring off sends nothing (" .. (sent("Mac") - 1) .. ")")
  -- a record from before 0.36 (colour never counted): re-anchored on the next look, not sent
  local oid = mirror.track_oid(ta)
  local rev, _, evid, kord = mirror.known(pa, oid)
  mirror.remember(pa, oid, rev, mirror.track_hash(mirror.track_state(pa, ta), false, false), evid, kord)
  reaper.SetProjExtState(pa, mirror.CSEC, "colours", "") -- (and no colour scheme noted yet, as before 0.36)
  watch(pa, A, false)
  check(sent("Laptop") == n2, "a pre-0.36 record isn't sent as a change (" .. (sent("Laptop") - n2) .. ")")
  watch(pa, A, false)
  check(sent("Laptop") == n2, "and stays quiet on the next look")
  check(select(2, mirror.known(pa, oid)) == mirror.track_hash(mirror.track_state(pa, ta), false), "its record now counts the colour")
  local drift = (tonumber(reaper.GetExtState(band.SECTION, "mirror drift " .. tostring(pa))) or 0) + (tonumber(reaper.GetExtState(band.SECTION, "mirror drift " .. tostring(pb))) or 0)
  check(drift == 0, "no \"came out different\" between an auto-coloured machine and one that isn't (" .. drift .. ")")
end)
mirror.own_colours = real_own
if not ok then say("ERROR " .. tostring(err)); fails = fails + 1 end
for k, p in ipairs({ pa, pb }) do
  if reaper.ValidatePtr2(0, p, "ReaProject*") then
    reaper.SelectProjectInstance(p)
    reaper.Main_SaveProjectEx(p, D .. "/track_colour_" .. k .. ".rpp", 8)
    reaper.Main_OnCommand(40860, 0)
  end
end
if front and reaper.ValidatePtr2(0, front, "ReaProject*") then reaper.SelectProjectInstance(front) end
return (fails == 0 and "ALL PASS" or (fails .. " FAILED")) .. "\n" .. table.concat(out, "\n")
