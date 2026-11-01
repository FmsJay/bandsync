-- Run inside REAPER (ReaScript). Drive as the source for songs (0.36): each person's recordings go up to the band's
-- Google Drive copy (whose a recording is: the first change that used it), a machine with only a song's listing
-- gets the whole room from Drive, changes the history trim took stay gone, and every song here in full keeps its
-- Drive copy, not only the open one. Plain folders stand in for the shared folder and Drive; all scratch.
local D = reaper.GetResourcePath() .. "/BandSync/tests"
local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/"
package.path = lib .. "?.lua;" .. package.path
for _, m in ipairs({ "band", "drive", "json" }) do package.loaded[m] = nil end
local band, drive = require("band"), require("drive")
local base = D .. "/droot_" .. os.time()
local PC, Mac, drv = { user = "James", root = base .. "/pc" }, { user = "Mac", root = base .. "/mac" }, base .. "/drive"
local out, fails = {}, 0
local function say(s) out[#out + 1] = s end
local function check(ok, what) if not ok then fails = fails + 1 end; say((ok and "PASS " or "FAIL ") .. what) end
local function put(path, text) reaper.RecursiveCreateDirectory(path:match("^(.*)/"), 0); local f = io.open(path, "wb"); f:write(text); f:close() end
local function item_ev(id, user, time, files)
  local chunk = "<ITEM\nPOSITION 0\n"
  for _, f in ipairs(files) do chunk = chunk .. '<SOURCE FLAC\nFILE "{media:main}/' .. f .. '"\n>\n' end
  return { type = "obj", obj = "item", oid = "I-" .. id, rev = 1, id = id, user = user, time = time, state = chunk .. ">\n" }
end
local has = reaper.file_exists
local function wj(path, t) reaper.RecursiveCreateDirectory(path:match("^(.*)/"), 0); band.write_json(path, t) end
local ok, err = pcall(function()
  local song = "DriveLab"
  local here, there = PC.root .. "/" .. song .. "/rooms/main", drv .. "/" .. song .. "/rooms/main"
  local E1, E2, E3 = "James-20261101-010000Z-00001-1111", "Laptop-20261101-020000Z-00001-2222", "James-20261101-030000Z-00002-3333"
  wj(here .. "/events/" .. E1 .. ".json", item_ev(E1, "James", "2026-11-01T01:00:00Z", { "rec1.flac" }))
  wj(here .. "/events/" .. E2 .. ".json", item_ev(E2, "Laptop", "2026-11-01T02:00:00Z", { "rec1.flac", "rec2.flac" }))
  wj(here .. "/events/" .. E3 .. ".json", item_ev(E3, "James", "2026-11-01T03:00:00Z", {}))
  put(here .. "/media/rec1.flac", "james's recording"); put(here .. "/media/rec2.flac", "the laptop's recording")
  wj(PC.root .. "/" .. song .. "/session.json", { song = song, version = 1 })
  -- James's machine: his recording and his changes go up; the laptop's are the laptop's to send
  drive.mirror(here, there, 5, "James")
  check(has(there .. "/media/rec1.flac"), "James's recording went up to Drive (the first change that used it was his)")
  check(not has(there .. "/media/rec2.flac"), "the laptop's recording didn't go up from James's machine")
  check(has(there .. "/events/" .. E1 .. ".json") and not has(there .. "/events/" .. E2 .. ".json"), "only James's changes went up")
  drive.mirror(here, there, 5, "Laptop") -- (the laptop's own pass, as it holds the same files)
  check(has(there .. "/media/rec2.flac") and has(there .. "/events/" .. E2 .. ".json"), "the laptop's pass sent its recording and change")
  check(not has(there .. "/media/rec1.flac.tmp"), "nothing half-written left")
  -- a Mac with only the song's listing (nobody else online): opening it brings the room from Drive
  local mhere = Mac.root .. "/" .. song .. "/rooms/main"
  wj(Mac.root .. "/" .. song .. "/session.json", { song = song, version = 1 })
  drive.mirror(mhere, there, 5, "Mac")
  check(#band.files(mhere .. "/events", ".json") == 3 and has(mhere .. "/media/rec1.flac") and has(mhere .. "/media/rec2.flac"),
    "a listing-only machine got the whole room from Drive (" .. #band.files(mhere .. "/events", ".json") .. " changes)")
  check(band.read(mhere .. "/media/rec2.flac") == "the laptop's recording", "the recordings arrive intact")
  -- James's machine trims E1 and E2: they stay gone, and Drive loses each once its maker sees the list
  wj(here .. "/trimmed/James-20261101-040000.json", { E1, E2 })
  os.remove(here .. "/events/" .. E1 .. ".json"); os.remove(here .. "/events/" .. E2 .. ".json")
  drive.mirror(here, there, 5, "James")
  check(not has(here .. "/events/" .. E1 .. ".json") and not has(here .. "/events/" .. E2 .. ".json"), "trimmed changes aren't brought back from Drive")
  check(not has(there .. "/events/" .. E1 .. ".json"), "James's trimmed change left Drive")
  check(has(there .. "/events/" .. E2 .. ".json"), "the laptop's is the laptop's to take off Drive")
  check(has(there .. "/trimmed/James-20261101-040000.json"), "the list went up to Drive")
  drive.mirror(here, there, 5, "Laptop")
  check(not has(there .. "/events/" .. E2 .. ".json"), "and the laptop's pass takes its own off")
  -- another machine that still has them (it was away when the band's copies went) doesn't send them back up
  drive.mirror(mhere, there, 5, "Mac")
  check(not has(there .. "/events/" .. E1 .. ".json") and not has(there .. "/events/" .. E2 .. ".json"), "nor does the Mac's pass")
  check(has(mhere .. "/trimmed/James-20261101-040000.json"), "and the Mac got the list (from Drive) too")
  -- every song here in full keeps its Drive copy, one a pass, not only the open one
  local E4 = "James-20261101-050000Z-00001-4444"
  wj(PC.root .. "/Second/rooms/main/events/" .. E4 .. ".json", item_ev(E4, "James", "2026-11-01T05:00:00Z", {}))
  wj(PC.root .. "/Third/rooms/demo/events/" .. E4 .. ".json", item_ev(E4, "James", "2026-11-01T05:00:00Z", {}))
  local songs = { song, "Second", "Third" }
  local _, _, s1 = drive.upkeep(PC, drv, songs, song, 2)
  local _, _, s2 = drive.upkeep(PC, drv, songs, song, 2)
  check(s1 ~= song and s2 ~= song and s1 ~= s2, "the upkeep takes the other songs in turn, never the open one (" .. tostring(s1) .. ", " .. tostring(s2) .. ")")
  check(has(drv .. "/Second/rooms/main/events/" .. E4 .. ".json") and has(drv .. "/Third/rooms/demo/events/" .. E4 .. ".json"), "both reached Drive, each room")
end)
if not ok then say("ERROR " .. tostring(err)); fails = fails + 1 end
return (fails == 0 and "ALL PASS" or (fails .. " FAILED")) .. "\n" .. table.concat(out, "\n")
