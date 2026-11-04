-- Run inside REAPER (ReaScript). Colouring items (they go out like any change), and What's new (only here, fading, kept up to date).
-- A scratch tab and shared folder, saved there and closed at the end.
local D = reaper.GetResourcePath() .. "/StudioSync/tests"
reaper.RecursiveCreateDirectory(D, 0)
package.path = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/?.lua;" .. package.path
for _, m in ipairs({ "band", "sync", "mirror", "people", "colours" }) do package.loaded[m] = nil end
local band, sync, mirror, people, colours = require("band"), require("sync"), require("mirror"), require("people"), require("colours")
local root = D .. "/ciroot_" .. os.time()
local song, room = "ColourItems", "main"
local A = { user = "James", root = root }
reaper.RecursiveCreateDirectory(sync.room_dir(A, song, room) .. "/events", 0)
local yes = function() return true end
local out, fails = {}, 0
local function check(ok, what) if not ok then fails = fails + 1 end; out[#out + 1] = (ok and "PASS " or "FAIL ") .. what end
local front = reaper.EnumProjects(-1)
reaper.Main_OnCommand(40859, 0); local p = reaper.EnumProjects(-1)
local mode_was = reaper.GetExtState(band.SECTION, "track colours")
local function watch() repeat mirror.watch(p, A, song, room, { can = yes, mode = "claims" }) until not mirror.more end
local function sent()
  local dir, n = sync.room_dir(A, song, room) .. "/events", 0
  for _ in ipairs(band.files(dir, ".json")) do n = n + 1 end
  return n
end
local ok, err = pcall(function()
  reaper.InsertTrackInProject(p, 0, 0)
  local tr = reaper.GetTrack(p, 0)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "Keys", true)
  local items = {}
  for i = 1, 4 do
    local it = reaper.AddMediaItemToTrack(tr)
    reaper.SetMediaItemInfo_Value(it, "D_POSITION", (i - 1) * 10)
    reaper.SetMediaItemInfo_Value(it, "D_LENGTH", 5)
    items[i] = it
  end
  reaper.AddProjectMarker2(p, true, 0, 10, "Verse 1", 1, 0)
  reaper.AddProjectMarker2(p, true, 10, 20, "Chorus", 2, 0)
  reaper.AddProjectMarker2(p, true, 20, 30, "Verse 2", 3, 0)
  watch()
  local n0 = sent()
  local stops = { 0x000000, 0xFFFFFF }
  local n, left = colours.apply_items(p, A, "section", stops, function() return true end)
  check(n == 4 and left == 0, "all four coloured (" .. n .. ", " .. left .. ")")
  local function col(i) return reaper.GetMediaItemInfo_Value(items[i], "I_CUSTOMCOLOR") end
  check(col(1) == col(3) and col(1) ~= col(2) and col(1) ~= 0, "the verses match, the chorus doesn't")
  check(col(4) ~= col(1) and col(4) ~= 0, "outside any region has its own")
  watch()
  check(sent() - n0 == 4, "each goes out as a change (" .. (sent() - n0) .. ")")
  n, left = colours.apply_items(p, A, "clear", stops, function() return false end)
  check(n == 0 and left == 4 and col(1) ~= 0, "someone else's track is left as it is")
  n = colours.apply_items(p, A, "clear", stops, function() return true end)
  check(n == 4 and col(1) == 0, "as its track takes the colour off")
  watch()
  -- what's new: only here, and it fades
  reaper.SetExtState(band.SECTION, "track colours", "new", false)
  band.set_track_colour(tr, reaper.ColorToNative(10, 20, 30) | 0x1000000)
  watch()
  local before = sent()
  people.paint(p, A, {}, {})
  local shown = reaper.GetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR")
  check(shown ~= (reaper.ColorToNative(10, 20, 30) | 0x1000000), "a track just changed shows in its person's colour")
  check(band.track_colour(tr) == (reaper.ColorToNative(10, 20, 30) | 0x1000000), "the studio's colour is kept under it")
  watch()
  check(sent() == before, "and showing it sends nothing (" .. (sent() - before) .. ")")
  reaper.SetExtState(band.SECTION, "track colours", "band", false)
  people.paint(p, A, {}, {})
  check(reaper.GetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR") == (reaper.ColorToNative(10, 20, 30) | 0x1000000), "off again, the studio's colour is back")
end)
if mode_was ~= "" then reaper.SetExtState(band.SECTION, "track colours", mode_was, true) else reaper.DeleteExtState(band.SECTION, "track colours", true) end
if not ok then out[#out + 1] = "ERROR " .. tostring(err); fails = fails + 1 end
reaper.SelectProjectInstance(p)
reaper.Main_SaveProjectEx(p, D .. "/colour_items.rpp", 8)
reaper.Main_OnCommand(40860, 0)
if front and reaper.ValidatePtr2(0, front, "ReaProject*") then reaper.SelectProjectInstance(front) end
return (fails == 0 and "ALL PASS" or (fails .. " FAILED")) .. "\n" .. table.concat(out, "\n")
