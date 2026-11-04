-- Run inside REAPER (ReaScript). When two change one thing at once, the owner's stands, and Use mine takes yours back where it's yours to take; and the project's colours
-- travel. Two scratch tabs, a scratch shared folder; both saved there and closed at the end.
local D = reaper.GetResourcePath() .. "/StudioSync/tests"
local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/"
package.path = lib .. "?.lua;" .. package.path
for _, m in ipairs({ "band", "sync", "mirror", "prints", "colours" }) do package.loaded[m] = nil end
require("prints").SETTLE = 0
local band, sync, mirror, colours = require("band"), require("sync"), require("mirror"), require("colours")
local root = D .. "/oroot_" .. os.time()
local song, room = "OwnerLab", "main"
local A, B = { user = "Laptop", root = root }, { user = "James", root = root }
reaper.RecursiveCreateDirectory(sync.room_dir(A, song, room) .. "/events", 0)
local events = sync.room_dir(A, song, room) .. "/events"
local out, fails = {}, 0
local function check(ok, what) if not ok then fails = fails + 1 end; out[#out + 1] = (ok and "PASS " or "FAIL ") .. what end
local yes = function() return true end
local front = reaper.EnumProjects(-1)
local was_bg, was_put = reaper.GetExtState(band.SECTION, "bg render"), reaper.GetExtState(band.SECTION, "put back")
reaper.SetExtState(band.SECTION, "bg render", "off", false)
reaper.Main_OnCommand(40859, 0); local pa = reaper.EnumProjects(-1)
reaper.Main_OnCommand(40859, 0); local pb = reaper.EnumProjects(-1)
local was_driver, was_claimed = sync.driver_name, sync.is_claimed
sync.driver_name = "Laptop"
local function watch(p, cfg, can) reaper.SelectProjectInstance(p); return (mirror.watch(p, cfg, song, room, { can = can or yes, mode = "claims" })) end
local function recv(p, cfg) reaper.SelectProjectInstance(p); for _ = 1, 3 do sync.receive(p, cfg, song, room, yes) end end
local function vol(p, name)
  for i = 0, reaper.CountTracks(p) - 1 do
    local tr = reaper.GetTrack(p, i)
    if select(2, reaper.GetTrackName(tr)) == name then return reaper.GetMediaTrackInfo_Value(tr, "D_VOL"), tr end
  end
end
local ok, err = pcall(function()
  reaper.SelectProjectInstance(pa)
  reaper.InsertTrackInProject(pa, 0, 0); reaper.InsertTrackInProject(pa, 1, 0); reaper.InsertTrackInProject(pa, 2, 0)
  reaper.GetSetMediaTrackInfo_String(reaper.GetTrack(pa, 0), "P_NAME", "Drums", true)
  reaper.GetSetMediaTrackInfo_String(reaper.GetTrack(pa, 1), "P_NAME", "Bass DI", true)
  reaper.GetSetMediaTrackInfo_String(reaper.GetTrack(pa, 2), "P_NAME", "Vocal", true)
  watch(pa, A); watch(pa, A)
  recv(pb, B)
  check(reaper.CountTracks(pb) == 3, "the other tab has the tracks")

  -- ---- the rule, by revision number
  check(mirror.next_rev(5, false) == 6 and mirror.next_rev(5, true) == 5 + 1 + mirror.OWNER_STEP, "an owner's change steps past whatever the others could reach")
  check(mirror.newer({ rev = mirror.next_rev(5, true) }, { rev = 5 + 50 }), "so it beats fifty quick edits made meanwhile")
  check(mirror.newer({ rev = mirror.next_rev(mirror.next_rev(5, true), false) }, { rev = mirror.next_rev(5, true) }), "and someone who has seen it can still follow it")

  -- ---- a real clash: the driver (Laptop) owns unclaimed tracks, James changes Drums more times while apart
  local _, ta = vol(pa, "Drums")
  local _, tb = vol(pb, "Drums")
  reaper.SelectProjectInstance(pb)
  sync.driver_name = "Laptop"
  for k = 1, 3 do -- (James, unaware: three edits, three revisions)
    reaper.SetMediaTrackInfo_Value(tb, "D_VOL", 0.2 + k * 0.01)
    watch(pb, B)
  end
  local mine_vol = reaper.GetMediaTrackInfo_Value(tb, "D_VOL")
  local _, _, mine_ev = mirror.known(pb, mirror.track_oid(tb))
  reaper.SelectProjectInstance(pa)
  reaper.SetMediaTrackInfo_Value(ta, "D_VOL", 0.9)
  watch(pa, A) -- (the driver: one edit, before seeing James's)
  local _, _, theirs_ev = mirror.known(pa, mirror.track_oid(ta))
  reaper.DeleteExtState(band.SECTION, "put back", false)
  recv(pb, B)
  recv(pa, A)
  check(math.abs(reaper.GetMediaTrackInfo_Value(tb, "D_VOL") - 0.9) < 1e-6, "the owner's one edit beats three from someone else, there")
  check(math.abs(reaper.GetMediaTrackInfo_Value(ta, "D_VOL") - 0.9) < 1e-6, "and stays here")
  local pb_note = band.json_decode(reaper.GetExtState(band.SECTION, "put back")) or {}
  check(type(pb_note.mine) == "table" and pb_note.mine[1] and pb_note.mine[1].oid == mirror.track_oid(tb) and pb_note.mine[1].ev == mine_ev, "the loser's note carries what Use mine needs")
  check(tostring(pb_note.text):find("theirs is in", 1, true) ~= nil, "and says what happened: " .. tostring(pb_note.text))

  -- ---- Use mine: where it's yours to take, it goes back, for everyone
  local msg = mirror.use_mine(pb, B, song, room, pb_note.mine, { can = yes, mode = "open" })
  check(math.abs(reaper.GetMediaTrackInfo_Value(tb, "D_VOL") - mine_vol) < 1e-6, "Use mine: yours is back here (" .. tostring(msg) .. ")")
  recv(pa, A)
  check(math.abs(reaper.GetMediaTrackInfo_Value(ta, "D_VOL") - mine_vol) < 1e-6, "and for the other person")
  -- ---- and where it isn't, it stays
  local before = reaper.GetMediaTrackInfo_Value(tb, "D_VOL")
  msg = mirror.use_mine(pb, B, song, room, { { oid = mirror.track_oid(tb), ev = theirs_ev } }, { can = function() return false end, mode = "claims" })
  check(reaper.GetMediaTrackInfo_Value(tb, "D_VOL") == before and tostring(msg):find("not yours", 1, true) ~= nil, "not yours to change: nothing moves, and it says so (" .. tostring(msg) .. ")")
  check(mirror.use_mine(pb, B, song, room, {}, { can = yes }) == nil, "nothing to take back")

  -- ---- two owners can't both step past each other for good: same rule, same winner on both machines
  local a1, a2 = { rev = 1006, time = "2026-11-04T10:00:00ZA" }, { rev = 1006, time = "2026-11-04T10:00:00ZB" }
  check(mirror.newer(a2, a1) and not mirror.newer(a1, a2), "two owners at once: one winner, the same everywhere")

  -- ---- colours: applied here, they travel; someone else's stays
  reaper.SelectProjectInstance(pa)
  sync.driver_name = "Laptop"
  local list = colours.read(pa, A)
  check(#list == 3 and list[1].name == "Drums", "the plan reads the project's tracks")
  local plan = colours.plan(list, "gradient", { stops = { 0x102030, 0xF0E0D0 } })
  local done, left = colours.apply(pa, A, list, plan, function(n) return n ~= "Bass DI" end)
  check(done == 2 and left == 1, "only what's yours gets coloured")
  watch(pa, A); watch(pa, A)
  recv(pb, B)
  local function colour(p, name) local _, tr = vol(p, name); return band.track_colour(tr) end
  local r, g, bl = reaper.ColorFromNative(math.floor(colour(pb, "Vocal")) & 0xFFFFFF)
  check((r << 16 | g << 8 | bl) == plan[3], "the colour reaches the other tab")
  check(colour(pa, "Bass DI") == 0 or colour(pa, "Bass DI") == colour(pb, "Bass DI"), "the one left alone is unchanged")
  -- ---- regions
  reaper.SelectProjectInstance(pa)
  reaper.AddProjectMarker2(pa, true, 0, 4, "Verse 1", -1, 0)
  reaper.AddProjectMarker2(pa, true, 4, 8, "Chorus 1", -1, 0)
  reaper.AddProjectMarker2(pa, true, 8, 12, "Verse 2", -1, 0)
  check(colours.apply_marks(pa, "sections", { 0, 0xFFFFFF }) == 3, "regions are coloured")
  local _, _, _, _, _, _, c1 = reaper.EnumProjectMarkers3(pa, 0)
  local _, _, _, _, _, _, c2 = reaper.EnumProjectMarkers3(pa, 1)
  local _, _, _, _, _, _, c3 = reaper.EnumProjectMarkers3(pa, 2)
  check(c1 == c3 and c1 ~= c2 and c1 ~= 0, "both verses match, the chorus doesn't")
end)
if not ok then fails = fails + 1; out[#out + 1] = "FAIL error: " .. tostring(err) end
sync.driver_name, sync.is_claimed = was_driver, was_claimed
for _, p in ipairs({ pb, pa }) do
  reaper.SelectProjectInstance(p)
  reaper.Main_SaveProjectEx(p, root .. "/" .. tostring(p):gsub("%W", "") .. ".rpp", 8)
  reaper.Main_OnCommand(40860, 0)
end
if reaper.ValidatePtr(front, "ReaProject*") then reaper.SelectProjectInstance(front) end
reaper.SetExtState(band.SECTION, "bg render", was_bg, false)
if was_put ~= "" then reaper.SetExtState(band.SECTION, "put back", was_put, false) else reaper.DeleteExtState(band.SECTION, "put back", false) end
out[#out + 1] = string.format("owner_wins: fails %d of %d", fails, #out)
return table.concat(out, "\n")
