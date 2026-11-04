-- Run inside REAPER (ReaScript). A side room starts as a copy: what hasn't changed in it keeps the print it came with, on any computer.
-- (Whoever opened the room used to render the Drums again: laptop, 0.42.5.) What's changed in the room does get a new print.
-- Scratch shared folder and tabs, saved there and closed at the end.
local D = reaper.GetResourcePath() .. "/StudioSync/tests"
reaper.RecursiveCreateDirectory(D, 0)
package.path = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/?.lua;" .. package.path
for _, m in ipairs({ "band", "sync", "mirror", "recall", "prints" }) do package.loaded[m] = nil end
local band, sync, mirror, prints = require("band"), require("sync"), require("mirror"), require("prints")
prints.SETTLE = 0
local root = D .. "/rproot_" .. os.time()
local song = "RoomPrints"
local A, B = { user = "James", root = root }, { user = "Laptop", root = root }
local yes = function() return true end
local out, fails = {}, 0
local function check(ok, what) if not ok then fails = fails + 1 end; out[#out + 1] = (ok and "PASS " or "FAIL ") .. what end
local function wait(s) local t = reaper.time_precise(); while reaper.time_precise() - t < s do end end
local function count(room, kind)
  local dir, n = sync.room_dir(A, song, room) .. "/events", 0
  for _, f in ipairs(band.files(dir, ".json")) do
    local ev = band.read_json(dir .. "/" .. f)
    if ev and (not kind or ev.obj == kind) then n = n + 1 end
  end
  return n
end
local function printed(p, it)
  for k = 0, reaper.CountTakes(it) - 1 do
    local tk = reaper.GetTake(it, k)
    if tk and select(2, reaper.GetSetMediaItemTakeInfo_String(tk, "P_NAME", "", false)):find("^wet") then return true end
  end
  return false
end
local front = reaper.EnumProjects(-1)
reaper.Main_OnCommand(40859, 0); local pa = reaper.EnumProjects(-1)
local ps
local function look(p, cfg, room, n, secs)
  reaper.SelectProjectInstance(p)
  local t = reaper.time_precise()
  for _ = 1, n do
    mirror.watch(p, cfg, song, room, { can = yes, mode = "claims", here = { James = true, Laptop = true } })
    if secs then wait(secs) end
    if t + 60 < reaper.time_precise() then break end
  end
end
local ok, err = pcall(function()
  reaper.InsertTrackInProject(pa, 0, 0)
  local tr = reaper.GetTrack(pa, 0)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "Drums", true)
  reaper.TrackFX_AddByName(tr, "ReaSynth", false, -1)
  local it = reaper.CreateNewMIDIItemInProj(tr, 0, 2, false)
  reaper.MIDI_InsertNote(reaper.GetActiveTake(it), false, false, 0, 960, 0, 60, 100, false)
  reaper.MIDI_Sort(reaper.GetActiveTake(it))
  look(pa, A, "main", 8, 0.3)
  wait(1)
  look(pa, A, "main", 8, 0.5)
  local takes = reaper.CountTakes(it)
  out[#out + 1] = "main has " .. takes .. " take(s), " .. count("main") .. " events"
  check(takes >= 2, "the main room's part has its print")
  -- the room, opened by someone else on another computer: a copy with the same marks
  reaper.Main_SaveProjectEx(pa, D .. "/rp_main.rpp", 8)
  reaper.Main_OnCommand(40859, 0)
  reaper.Main_openProject("noprompt:" .. D .. "/rp_main.rpp")
  ps = reaper.EnumProjects(-1)
  reaper.Main_SaveProjectEx(ps, D .. "/rp_side.rpp", 8)
  reaper.RecursiveCreateDirectory(sync.room_dir(A, song, "side") .. "/events", 0)
  band.write_json(sync.room_dir(A, song, "side") .. "/room.json", { parent = "main", by = "James" })
  look(ps, B, "side", 10, 0.5)
  check(count("side") == 0, "nothing's changed in the room, so nothing's printed or sent (" .. count("side") .. " events)")
  local sit = reaper.GetTrackMediaItem(reaper.GetTrack(ps, 0), 0)
  check(reaper.CountTakes(sit) == takes, "the copy keeps the print it came with (" .. reaper.CountTakes(sit) .. " takes)")
  -- a change in the room is that room's, and gets its print
  local tk = reaper.GetTake(sit, 0)
  for k = 0, reaper.CountTakes(sit) - 1 do if reaper.TakeIsMIDI(reaper.GetTake(sit, k)) then tk = reaper.GetTake(sit, k) end end
  reaper.MIDI_InsertNote(tk, false, false, 960, 1920, 0, 64, 100, false)
  reaper.MIDI_Sort(tk)
  look(ps, B, "side", 4, 0.5)
  check(count("side", "item") >= 1, "a change in the room goes out in the room (" .. count("side", "item") .. ")")
end)
if not ok then out[#out + 1] = "ERROR " .. tostring(err); fails = fails + 1 end
for k, p in ipairs({ ps or false, pa }) do
  if p and reaper.ValidatePtr2(0, p, "ReaProject*") then
    reaper.SelectProjectInstance(p)
    reaper.Main_SaveProjectEx(p, D .. "/rp_" .. k .. ".rpp", 8)
    reaper.Main_OnCommand(40860, 0)
  end
end
if front and reaper.ValidatePtr2(0, front, "ReaProject*") then reaper.SelectProjectInstance(front) end
return (fails == 0 and "ALL PASS" or (fails .. " FAILED")) .. "\n" .. table.concat(out, "\n")
