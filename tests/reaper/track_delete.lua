-- Run inside REAPER (ReaScript). A bandmate deletes a whole track; here the track's delete lands before its items'
-- own deletes (a receive pass runs out of time between them). The items went with the track, so the next look must
-- not take them for our deletes and put them back (the Mac put back 226 of them after the laptop's restore, 0.34.4).
-- Two scratch tabs, a scratch shared folder; both tabs saved there and closed at the end.
local D = reaper.GetResourcePath() .. "/StudioSync/tests"
reaper.RecursiveCreateDirectory(D, 0)
local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/"
package.path = lib .. "?.lua;" .. package.path
for _, m in ipairs({ "band", "sync", "mirror", "recall", "json" }) do package.loaded[m] = nil end
local band, sync, mirror = require("band"), require("sync"), require("mirror")
local root = D .. "/troot_" .. os.time()
local song, room = "TrackDelLab", "main"
local A, B = { user = "Laptop", root = root }, { user = "Mac", root = root }
local events = sync.room_dir(A, song, room) .. "/events"
reaper.RecursiveCreateDirectory(events, 0)
local yes, no = function() return true end, function() return false end
local out, fails = {}, 0
local function say(s) out[#out + 1] = s end
local function check(ok, what) if not ok then fails = fails + 1 end; say((ok and "PASS " or "FAIL ") .. what) end
local front = reaper.EnumProjects(-1)
reaper.Main_OnCommand(40859, 0); local pa = reaper.EnumProjects(-1)
reaper.Main_OnCommand(40859, 0); local pb = reaper.EnumProjects(-1)
local function recv(p, cfg) reaper.SelectProjectInstance(p); local n = 0; for _ = 1, 3 do n = n + sync.receive(p, cfg, song, room, yes) end; return n end
local ok, err = pcall(function()
  reaper.InsertTrackInProject(pa, 0, 0); reaper.InsertTrackInProject(pa, 1, 0)
  local burst = reaper.GetTrack(pa, 1)
  reaper.GetSetMediaTrackInfo_String(reaper.GetTrack(pa, 0), "P_NAME", "Keys", true)
  reaper.GetSetMediaTrackInfo_String(burst, "P_NAME", "G burst", true)
  for k = 0, 4 do reaper.CreateNewMIDIItemInProj(burst, k * 2, k * 2 + 1, false) end
  mirror.watch(pa, A, song, room, { can = yes, mode = "claims" })
  recv(pb, B)
  check(reaper.CountTracks(pb) == 2 and reaper.CountMediaItems(pb) == 5, "B has the track and its 5 items")
  -- A deletes the whole track: one delete for the track, one per item
  reaper.DeleteTrack(burst)
  mirror.watch(pa, A, song, room, { can = yes, mode = "claims" })
  -- B gets only the track's delete this pass: the items' deletes are held back
  local held = {}
  for _, f in ipairs(band.files(events, ".json")) do
    local ev = band.read_json(events .. "/" .. f)
    if ev and ev.obj == "item" and ev.gone then os.rename(events .. "/" .. f, events .. "/" .. f .. ".held"); held[#held + 1] = f end
  end
  check(#held == 5, "A sent a delete per item (" .. #held .. ")")
  recv(pb, B)
  check(reaper.CountTracks(pb) == 1 and reaper.CountMediaItems(pb) == 0, "the track's delete took its items with it on B")
  -- B's next look, as someone who may not delete A's things: nothing put back, and nothing said about it
  local function put_backs() return (band.json_decode(reaper.GetExtState(band.SECTION, "put back")) or {}).n or 0 end
  local before = put_backs()
  mirror.watch(pb, B, song, room, { can = no, mode = "claims" })
  check(reaper.CountMediaItems(pb) == 0 and reaper.CountTracks(pb) == 1, "nothing put back on B (" .. reaper.CountMediaItems(pb) .. " item(s))")
  check(put_backs() == before, "no \"isn't yours to delete\" for the band's own delete (" .. (put_backs() - before) .. ")")
  for _, f in ipairs(held) do os.rename(events .. "/" .. f .. ".held", events .. "/" .. f) end
  recv(pb, B)
  mirror.watch(pb, B, song, room, { can = no, mode = "claims" })
  check(reaper.CountMediaItems(pb) == 0, "the items' own deletes land later without bringing anything back")
  check(mirror.root(pa) == mirror.root(pb), "both hold the same project (" .. mirror.root(pa) .. " / " .. mirror.root(pb) .. ")")
  local mine = 0
  for _, f in ipairs(band.files(events, ".json")) do if f:sub(1, 4) == "Mac-" then mine = mine + 1 end end
  check(mine == 0, "B sent nothing (" .. mine .. ")")
end)
if not ok then say("ERROR " .. tostring(err)); fails = fails + 1 end
for k, p in ipairs({ pa, pb }) do
  if reaper.ValidatePtr2(0, p, "ReaProject*") then
    reaper.SelectProjectInstance(p)
    reaper.Main_SaveProjectEx(p, D .. "/track_delete_" .. k .. ".rpp", 8)
    reaper.Main_OnCommand(40860, 0)
  end
end
if front and reaper.ValidatePtr2(0, front, "ReaProject*") then reaper.SelectProjectInstance(front) end
return (fails == 0 and "ALL PASS" or (fails .. " FAILED")) .. "\n" .. table.concat(out, "\n")
