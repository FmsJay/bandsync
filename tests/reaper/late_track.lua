-- Run inside REAPER (ReaScript). A song opened fresh, its history arriving in batches: a track was deleted and then
-- brought back. One batch has the old "track deleted" and the item's newest change; the track's return comes
-- later. The item must still land once its track is back (laptop, 0.34.8: SongSync Test opened without Keys' items).
-- Two scratch tabs, a scratch shared folder; both tabs saved there and closed at the end.
local D = reaper.GetResourcePath() .. "/BandSync/tests"
reaper.RecursiveCreateDirectory(D, 0)
local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/"
package.path = lib .. "?.lua;" .. package.path
for _, m in ipairs({ "band", "sync", "mirror", "recall", "json" }) do package.loaded[m] = nil end
local band, sync, mirror = require("band"), require("sync"), require("mirror")
local root = D .. "/lroot_" .. os.time()
local song, room = "LateTrackLab", "main"
local A, B = { user = "Laptop", root = root }, { user = "Mac", root = root }
local events = sync.room_dir(A, song, room) .. "/events"
reaper.RecursiveCreateDirectory(events, 0)
local yes = function() return true end
local out, fails = {}, 0
local function say(s) out[#out + 1] = s end
local function check(ok, what) if not ok then fails = fails + 1 end; say((ok and "PASS " or "FAIL ") .. what) end
local front = reaper.EnumProjects(-1)
reaper.Main_OnCommand(40859, 0); local pa = reaper.EnumProjects(-1)
local function watch_a() return mirror.watch(pa, A, song, room, { can = yes, mode = "claims" }) end
local ok, err = pcall(function()
  reaper.InsertTrackInProject(pa, 0, 0)
  local keys = reaper.GetTrack(pa, 0)
  reaper.GetSetMediaTrackInfo_String(keys, "P_NAME", "Keys", true)
  reaper.CreateNewMIDIItemInProj(keys, 0, 2, false)
  watch_a()
  local toid = mirror.track_oid(keys)
  local ioid = mirror.item_oid(reaper.GetTrackMediaItem(keys, 0))
  -- deleted, then brought back with the same ids, as Restore does: the track's return and the item's are new changes
  reaper.DeleteTrack(keys)
  watch_a()
  reaper.InsertTrackInProject(pa, 0, 0)
  keys = reaper.GetTrack(pa, 0)
  reaper.GetSetMediaTrackInfo_String(keys, "P_NAME", "Keys", true)
  reaper.GetSetMediaTrackInfo_String(keys, "P_EXT:band_oid", toid, true)
  local it = reaper.CreateNewMIDIItemInProj(keys, 0, 2, false)
  reaper.GetSetMediaItemInfo_String(it, "P_EXT:band_oid", ioid, true)
  check(reaper.CountTracks(pa) == 1 and reaper.CountMediaItems(pa) == 1, "A has Keys and its item back")
  watch_a()
  -- the track's return is held back; everything else arrives first
  local held
  local newest = {}
  for _, f in ipairs(band.files(events, ".json")) do
    local ev = band.read_json(events .. "/" .. f)
    if ev and ev.oid == toid and not ev.gone and (not newest.rev or ev.rev > newest.rev) then newest = { rev = ev.rev, f = f } end
  end
  held = newest.f
  check(held ~= nil, "found the track's return (" .. tostring(held) .. ")")
  os.rename(events .. "/" .. held, events .. "/" .. held .. ".held")
  -- B opens the song fresh
  reaper.Main_OnCommand(40859, 0); local pb = reaper.EnumProjects(-1)
  local function recv() reaper.SelectProjectInstance(pb); for _ = 1, 3 do sync.receive(pb, B, song, room, yes) end end
  recv()
  check(reaper.CountTracks(pb) == 0, "B: no Keys yet (its newest change here is the delete)")
  os.rename(events .. "/" .. held .. ".held", events .. "/" .. held)
  recv()
  check(reaper.CountTracks(pb) == 1, "B: Keys came back when its return arrived")
  check(reaper.CountMediaItems(pb) == 1, "B: and its item with it (" .. reaper.CountMediaItems(pb) .. ")")
  check(mirror.root(pa) == mirror.root(pb), "both hold the same project (" .. mirror.root(pa) .. " / " .. mirror.root(pb) .. ")")
  for k, p in ipairs({ pa, pb }) do
    if reaper.ValidatePtr2(0, p, "ReaProject*") then
      reaper.SelectProjectInstance(p)
      reaper.Main_SaveProjectEx(p, D .. "/late_track_" .. k .. ".rpp", 8)
      reaper.Main_OnCommand(40860, 0)
    end
  end
end)
if not ok then
  say("ERROR " .. tostring(err)); fails = fails + 1
  for _, p in ipairs({ pa }) do if reaper.ValidatePtr2(0, p, "ReaProject*") then reaper.SelectProjectInstance(p); reaper.Main_SaveProjectEx(p, D .. "/late_track_err.rpp", 8); reaper.Main_OnCommand(40860, 0) end end
end
if front and reaper.ValidatePtr2(0, front, "ReaProject*") then reaper.SelectProjectInstance(front) end
return (fails == 0 and "ALL PASS" or (fails .. " FAILED")) .. "\n" .. table.concat(out, "\n")
