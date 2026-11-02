-- Run inside REAPER (ReaScript). Round 2's Restore findings (0.42.7): a whole-song Back and forward keeps a track's lane names on
-- both machines, tempo goes back from before the first tempo change, a claim survives the Back, collapsing lanes is nobody
-- else's business, and a pass on a lane nobody hears isn't printed until it plays.
-- Two scratch tabs, a scratch shared folder; both saved there and closed at the end.
local D = reaper.GetResourcePath() .. "/BandSync/tests"
local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/"
package.path = lib .. "?.lua;" .. package.path
for _, m in ipairs({ "band", "sync", "mirror", "recall", "prints", "plugins", "json" }) do package.loaded[m] = nil end
require("prints").SETTLE = 0
local band, sync, mirror, recall, prints = require("band"), require("sync"), require("mirror"), require("recall"), require("prints")
local root = D .. "/nroot_" .. os.time()
local song, room = "LaneLab", "main"
local A, B = { user = "Laptop", root = root }, { user = "James", root = root }
local events = sync.room_dir(A, song, room) .. "/events"
reaper.RecursiveCreateDirectory(events, 0)
local out, fails = {}, 0
local function say(s) out[#out + 1] = s end
local function check(ok, what) if not ok then fails = fails + 1 end; say((ok and "PASS " or "FAIL ") .. what) end
local yes = function() return true end
local front = reaper.EnumProjects(-1)
local was_bg = reaper.GetExtState(band.SECTION, "bg render")
reaper.SetExtState(band.SECTION, "bg render", "off", false)
reaper.Main_OnCommand(40859, 0); local pa = reaper.EnumProjects(-1)
reaper.Main_OnCommand(40859, 0); local pb = reaper.EnumProjects(-1)
local function sent(who)
  local n = 0
  for _, f in ipairs(band.files(events, ".json")) do if f:sub(1, #who + 1) == who .. "-" then n = n + 1 end end
  return n
end
local function watch(p, cfg) reaper.SelectProjectInstance(p); return (mirror.watch(p, cfg, song, room, { can = yes, mode = "claims", here = { Laptop = true, James = true } })) end
local function recv(p, cfg) reaper.SelectProjectInstance(p); for _ = 1, 3 do sync.receive(p, cfg, song, room, yes) end end
local function hold(s) local w = reaper.time_precise(); while reaper.time_precise() - w < s do end end
local function find(p, name)
  for i = 0, reaper.CountTracks(p) - 1 do
    local t = reaper.GetTrack(p, i)
    if select(2, reaper.GetTrackName(t)) == name then return t end
  end
end
local function lane_names(t)
  local n = {}
  for l = 0, reaper.GetMediaTrackInfo_Value(t, "I_NUMFIXEDLANES") - 1 do n[#n + 1] = select(2, reaper.GetSetMediaTrackInfo_String(t, "P_LANENAME:" .. l, "", false)) end
  return table.concat(n, ",")
end
local ok, err = pcall(function()
  reaper.SelectProjectInstance(pa)
  reaper.InsertTrackInProject(pa, 0, 0)
  local base = reaper.GetTrack(pa, 0)
  reaper.GetSetMediaTrackInfo_String(base, "P_NAME", "Older", true)
  watch(pa, A); hold(1.1)
  reaper.InsertTrackInProject(pa, 1, 0)
  local tr = reaper.GetTrack(pa, 1)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "Laned", true)
  reaper.SetMediaTrackInfo_Value(tr, "I_FREEMODE", 2)
  reaper.SetMediaTrackInfo_Value(tr, "I_NUMFIXEDLANES", 3)
  for l, name in ipairs({ "C1", "Take 1", "Take 2" }) do
    local it = reaper.AddMediaItemToTrack(tr)
    reaper.SetMediaItemInfo_Value(it, "D_POSITION", 0)
    reaper.SetMediaItemInfo_Value(it, "D_LENGTH", 2)
    reaper.SetMediaItemInfo_Value(it, "I_FIXEDLANE", l - 1)
    reaper.GetSetMediaItemInfo_String(it, "P_NOTES", "pass " .. l, true)
  end
  for l, name in ipairs({ "C1", "Take 1", "Take 2" }) do -- (a lane takes its name once it holds an item)
    reaper.GetSetMediaTrackInfo_String(tr, "P_LANENAME:" .. (l - 1), name, true)
    reaper.SetMediaTrackInfo_Value(tr, "C_LANEPLAYS:" .. (l - 1), l == 1 and 1 or 0)
  end
  watch(pa, A); watch(pa, A)
  recv(pb, B)
  local on_b = find(pb, "Laned")
  check(on_b and lane_names(on_b) == "C1,Take 1,Take 2", "the bandmate has the lanes, named: " .. (on_b and lane_names(on_b) or "no track"))

  -- collapsing lanes is a view: nothing goes out, and it's left alone
  local n = sent("James")
  reaper.SelectProjectInstance(pb)
  reaper.SetMediaTrackInfo_Value(on_b, "C_LANESCOLLAPSED", 1)
  watch(pb, B); watch(pb, B)
  check(sent("James") == n, "collapsing lanes sends nothing")
  check(reaper.GetMediaTrackInfo_Value(on_b, "C_LANESCOLLAPSED") == 1, "and stays collapsed here")
  reaper.SetMediaTrackInfo_Value(on_b, "C_LANESCOLLAPSED", 0)

  -- a claim waits out the Back
  check(sync.GONE_WAIT >= 300, "a claim on a missing track waits minutes, not seconds")

  -- the whole song back to before the track, and forward again
  hold(1.1)
  reaper.SelectProjectInstance(pa)
  local es, oid = recall.entries(A, song, room), mirror.track_oid(tr)
  local upto = 0
  for i, e in ipairs(es) do if e.kind == "obj" and e.oid == oid then upto = i - 1; break end end
  check(upto > 0, "there's a version from before it")
  mirror.revert(pa, A, song, room, mirror.plan_restore(es, upto), { can = yes, mode = "claims" })
  recv(pb, B)
  check(find(pa, "Laned") == nil and find(pb, "Laned") == nil, "going back takes it on both")
  hold(1.1)
  reaper.SelectProjectInstance(pa)
  es = recall.entries(A, song, room)
  local before
  for i, e in ipairs(es) do if e.kind == "obj" and e.gone then before = i - 1; break end end
  mirror.revert(pa, A, song, room, mirror.plan_restore(es, before), { can = yes, mode = "claims" })
  for _ = 1, 3 do watch(pa, A) end
  recv(pb, B)
  for _ = 1, 3 do watch(pb, B); recv(pa, A); recv(pb, B) end
  local ta, tb = find(pa, "Laned"), find(pb, "Laned")
  check(ta and lane_names(ta) == "C1,Take 1,Take 2", "forward: the lanes keep their names here: " .. (ta and lane_names(ta) or "no track"))
  check(tb and lane_names(tb) == "C1,Take 1,Take 2", "and on the bandmate's: " .. (tb and lane_names(tb) or "no track"))
  check(ta and reaper.CountTrackMediaItems(ta) == 3, "with its passes")
  check(ta and reaper.GetMediaTrackInfo_Value(ta, "C_LANEPLAYS:0") > 0 and reaper.GetMediaTrackInfo_Value(ta, "C_LANEPLAYS:1") == 0, "and the same lane plays")

  -- tempo from before its first change: the session's first map, not its newest
  reaper.SelectProjectInstance(pa)
  local first = band.capture_tempo(pa)
  reaper.SetCurrentBPM(pa, 77, false)
  local now = band.capture_tempo(pa)
  check(sync.restore_timeline(pa, A, song, room, {}, 0, { tempo = now, first_timeline = { tempo = first } }), "Back from before any tempo change restores the first map")
  check(math.abs(reaper.TimeMap2_GetDividedBpmAtTime(pa, 0) - 77) > 1, "the tempo's back")

  -- only what plays is printed
  reaper.SelectProjectInstance(pa)
  reaper.TrackFX_AddByName(ta, "ReaSynth", false, -1)
  local midi = {}
  for l = 0, 1 do
    local it = reaper.CreateNewMIDIItemInProj(ta, 4, 5, false)
    reaper.SetMediaItemInfo_Value(it, "I_FIXEDLANE", l)
    reaper.MIDI_InsertNote(reaper.GetActiveTake(it), false, false, 0, 400, 0, 60, 100, false)
    midi[l] = it
  end
  local function has_print(it) return select(2, prints.takes(it)) ~= nil end
  local media = sync.room_dir(A, song, room) .. "/media"
  check(prints.refresh(pa, midi[1], media, "x", "", A) == false and not has_print(midi[1]), "a pass on a lane nobody hears isn't printed")
  reaper.SetMediaTrackInfo_Value(ta, "C_LANEPLAYS:1", 1)
  local did = prints.refresh(pa, midi[1], media, "x", "", A)
  check(did ~= false and has_print(midi[1]), "and is once it plays")
end)
if not ok then fails = fails + 1; say("ERROR " .. tostring(err)) end
reaper.SetExtState(band.SECTION, "bg render", was_bg, false)
for _, p in ipairs({ pb, pa }) do
  reaper.SelectProjectInstance(p)
  reaper.Main_SaveProjectEx(p, root .. "/" .. tostring(p):gsub("%W", "") .. ".rpp", 8)
  reaper.Main_OnCommand(40860, 0)
end
reaper.SelectProjectInstance(front)
say(fails == 0 and "ALL PASS" or (fails .. " FAILED"))
return table.concat(out, "\n")
