-- Run inside REAPER (ReaScript). A project saved before mirror sync gave its tracks ids, changed and sent since, then
-- reopened from that older save (closed without saving, or a crash): its tracks and items must get their ids back,
-- not come back twice, and what changed since must come back as the band has it. Scratch folder and scratch tabs only.
local D = reaper.GetResourcePath() .. "/BandSync/tests" -- scratch: never the shared folder
reaper.RecursiveCreateDirectory(D, 0)
local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/"
package.path = lib .. "?.lua;" .. package.path
for _, m in ipairs({ "band", "sync", "mirror", "recall", "json" }) do package.loaded[m] = nil end
local sync, mirror = require("sync"), require("mirror")
local stamp = os.time()
local root = D .. "/rroot_" .. stamp
local song, room = "ReopenLab", "main"
local A = { user = "James", root = root }
reaper.RecursiveCreateDirectory(sync.room_dir(A, song, room) .. "/events", 0)
local yes = function() return true end
local out, fails = {}, 0
local function check(ok, what) if not ok then fails = fails + 1 end; out[#out + 1] = (ok and "PASS " or "FAIL ") .. what end
local function pass(p) return mirror.watch(p, A, song, room, { can = yes, mode = "claims" }) end
local function recv(p) reaper.SelectProjectInstance(p); local n = 0; -- (in front, as when someone switches to it)
   for _ = 1, 3 do n = n + sync.receive(p, A, song, room, yes) end; return n end
local function names(p)
  local t = {}
  for i = 0, reaper.CountTracks(p) - 1 do t[#t + 1] = select(2, reaper.GetTrackName(reaper.GetTrack(p, i))) end
  return table.concat(t, ",")
end
local file = D .. "/reopen_" .. stamp .. ".rpp"
local front = reaper.EnumProjects(-1)
local p1, p2
local ok, err = pcall(function()
  reaper.Main_OnCommand(40859, 0); p1 = reaper.EnumProjects(-1)
  for i, n in ipairs({ "Drums", "Bass" }) do
    reaper.InsertTrackInProject(p1, i - 1, 0)
    local tr = reaper.GetTrack(p1, i - 1)
    reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", n, true)
    reaper.CreateNewMIDIItemInProj(tr, 0, 2, false)
  end
  reaper.Main_SaveProjectEx(p1, file, 8) -- saved before any ids: what Publish leaves behind
  local sent = pass(p1)
  check(sent >= 4, "first pass sends the tracks and items (" .. sent .. ")")
  local oids = {}
  for i = 0, 1 do oids[i] = select(2, reaper.GetSetMediaTrackInfo_String(reaper.GetTrack(p1, i), "P_EXT:band_oid", "", false)) end
  reaper.GetSetMediaTrackInfo_String(reaper.GetTrack(p1, 1), "P_NAME", "Bass 2", true) -- changed after the save
  pass(p1)
  check(reaper.file_exists((file:gsub("%.rpp$", "")) .. ".bandsync-ids.json"), "the ids file sits beside the project")
  -- the same file reopened in a tab of its own: the older save, with no ids in it
  reaper.Main_SaveProjectEx(p1, D .. "/reopen_" .. stamp .. "_away.rpp", 8) -- (p1 now saves elsewhere: closing it can't prompt)
  reaper.Main_OnCommand(40860, 0); p1 = nil
  reaper.Main_OnCommand(40859, 0); p2 = reaper.EnumProjects(-1)
  reaper.Main_openProject("noprompt:" .. file)
  p2 = reaper.EnumProjects(-1)
  check(names(p2) == "Drums,Bass", "the reopened file is the older save (" .. names(p2) .. ")")
  local sent2 = pass(p2)
  check(sent2 == 0, "nothing goes out as new (" .. sent2 .. " sent)")
  recv(p2); pass(p2)
  check(reaper.CountTracks(p2) == 2, "no tracks came back twice (" .. names(p2) .. ")")
  local same = true
  for i = 0, 1 do
    if select(2, reaper.GetSetMediaTrackInfo_String(reaper.GetTrack(p2, i), "P_EXT:band_oid", "", false)) ~= oids[i] then same = false end
  end
  check(same, "both tracks got their ids back")
  check(names(p2) == "Drums,Bass 2", "the rename made after the save is back (" .. names(p2) .. ")")
  local items = 0
  for i = 0, reaper.CountTracks(p2) - 1 do items = items + reaper.CountTrackMediaItems(reaper.GetTrack(p2, i)) end
  check(items == 2, "items: 2, no copies (" .. items .. ")")
  check(pass(p2) == 0, "a further pass sends nothing")
end)
if not ok then fails = fails + 1; out[#out + 1] = "ERROR " .. tostring(err) end
for _, p in pairs({ p1, p2 }) do -- (pairs: p1 is nil once it's closed, which would stop ipairs before p2)
  if reaper.ValidatePtr2(0, p, "ReaProject*") then
    reaper.SelectProjectInstance(p)
    reaper.Main_SaveProjectEx(p, D .. "/reopen_" .. stamp .. "_end.rpp", 8)
    reaper.Main_OnCommand(40860, 0)
  end
end
if front and reaper.ValidatePtr2(0, front, "ReaProject*") then reaper.SelectProjectInstance(front) end
return (fails == 0 and "ALL PASS" or fails .. " FAILED") .. "\n" .. table.concat(out, "\n")
