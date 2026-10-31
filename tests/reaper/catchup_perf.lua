-- Run inside REAPER (ReaScript). Catching up on a long history: "James" (A) makes 20 tracks of 25 items and moves
-- every item three times (four revisions each); "Bee" (B) then joins from nothing. Times each receive pass, and checks
-- B ends with what A has, having applied only the newest revision of each. Scratch tabs and folder only.
local D = reaper.GetResourcePath() .. "/BandSync/tests"
reaper.RecursiveCreateDirectory(D, 0)
local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/"
package.path = lib .. "?.lua;" .. package.path
for _, m in ipairs({ "band", "sync", "mirror", "recall", "json" }) do package.loaded[m] = nil end
local sync, mirror = require("sync"), require("mirror")
local stamp = os.time()
local root = D .. "/croot_" .. stamp
local song, room = "CatchupLab", "main"
local A, B = { user = "James", root = root }, { user = "Bee", root = root }
reaper.RecursiveCreateDirectory(sync.room_dir(A, song, room) .. "/events", 0)
local yes = function() return true end
local out, fails = {}, 0
local function check(ok, what) if not ok then fails = fails + 1 end; out[#out + 1] = (ok and "PASS " or "FAIL ") .. what end
local front = reaper.EnumProjects(-1)
local pa, pb
local ok, err = pcall(function()
  reaper.Main_OnCommand(40859, 0); pa = reaper.EnumProjects(-1)
  reaper.PreventUIRefresh(1)
  for t = 0, 19 do
    reaper.InsertTrackInProject(pa, t, 0)
    local tr = reaper.GetTrack(pa, t)
    reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "T" .. t, true)
    for k = 0, 24 do reaper.CreateNewMIDIItemInProj(tr, k * 3, k * 3 + 2) end
  end
  reaper.PreventUIRefresh(-1)
  local t0 = reaper.time_precise()
  local sent = mirror.watch(pa, A, song, room, { can = yes, mode = "open" })
  for rev = 2, 4 do -- every item moved, and sent again
    for i = 0, reaper.CountMediaItems(pa) - 1 do
      local it = reaper.GetMediaItem(pa, i)
      reaper.SetMediaItemInfo_Value(it, "D_POSITION", reaper.GetMediaItemInfo_Value(it, "D_POSITION") + 0.25)
    end
    sent = sent + mirror.watch(pa, A, song, room, { can = yes, mode = "open" })
  end
  out[#out + 1] = string.format("A sent %d events in %.1f s", sent, reaper.time_precise() - t0)
  reaper.Main_OnCommand(40859, 0); pb = reaper.EnumProjects(-1)
  local passes, worst, total, applied = 0, 0, 0, 0
  repeat
    local s = reaper.time_precise()
    local n = sync.receive(pb, B, song, room, yes)
    local dt = reaper.time_precise() - s
    passes, total, applied = passes + 1, total + dt, applied + n
    if dt > worst then worst = dt end
  until sync.pending_events(pb, B, song, room) == 0 or passes > 400
  out[#out + 1] = string.format("B caught up in %d passes, %.1f s in all, longest pass %.2f s, %d applied", passes, total, worst, applied)
  check(sync.pending_events(pb, B, song, room) == 0, "B has nothing left to apply")
  check(applied <= 20 + 500 + 40, "only the newest revision of each was applied (" .. applied .. ")")
  check(worst < 2, string.format("no pass held REAPER up for long (%.2f s)", worst))
  check(reaper.CountMediaItems(pb) == reaper.CountMediaItems(pa) and reaper.CountTracks(pb) == 20, "B has every track and item")
  local same = true
  for i = 0, reaper.CountMediaItems(pa) - 1 do
    local it = reaper.GetMediaItem(pa, i)
    local bi = mirror.find(pb, "item", mirror.item_oid(it))
    if not bi or math.abs(reaper.GetMediaItemInfo_Value(bi, "D_POSITION") - reaper.GetMediaItemInfo_Value(it, "D_POSITION")) > 1e-6 then same = false end
  end
  check(same, "every item where A's newest revision put it")
end)
if not ok then fails = fails + 1; out[#out + 1] = "ERROR " .. tostring(err) end
for k, p in pairs({ pa, pb }) do
  if reaper.ValidatePtr2(0, p, "ReaProject*") then
    reaper.SelectProjectInstance(p)
    reaper.Main_SaveProjectEx(p, D .. "/catchup_" .. stamp .. "_" .. k .. ".rpp", 8)
    reaper.Main_OnCommand(40860, 0)
  end
end
if front and reaper.ValidatePtr2(0, front, "ReaProject*") then reaper.SelectProjectInstance(front) end
return (fails == 0 and "ALL PASS" or fails .. " FAILED") .. "\n" .. table.concat(out, "\n")
