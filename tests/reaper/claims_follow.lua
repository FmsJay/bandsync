-- Run inside REAPER (ReaScript). A claim follows its track when the track is renamed (keeping its date), and the
-- driver releasing someone's claims while they're away empties their claims file when they're back. Scratch only.
local D = reaper.GetResourcePath() .. "/BandSync/tests"
reaper.RecursiveCreateDirectory(D, 0)
local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/"
package.path = lib .. "?.lua;" .. package.path
for _, m in ipairs({ "band", "sync", "mirror", "json" }) do package.loaded[m] = nil end
local band, sync = require("band"), require("sync")
local stamp = os.time()
local root = D .. "/clroot_" .. stamp
local song, room = "ClaimLab", "main"
local cfg = { user = "James", root = root }
local out, fails = {}, 0
local function check(ok, what) if not ok then fails = fails + 1 end; out[#out + 1] = (ok and "PASS " or "FAIL ") .. what end
local front = reaper.EnumProjects(-1)
local p
local ok, err = pcall(function()
  reaper.Main_OnCommand(40859, 0); p = reaper.EnumProjects(-1)
  reaper.InsertTrackInProject(p, 0, 0)
  local tr = reaper.GetTrack(p, 0)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "Bass", true)
  reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_oid", "T-JAMES-1", true)
  sync.set_claims(cfg, song, room, { tracks = { "Bass" }, regions = {}, times = {} })
  local since = (sync.my_claims(cfg, song, room).since or {})["tracks:bass"]
  sync.follow_claims(p, cfg, song, room)
  check((sync.my_claims(cfg, song, room).oids or {}).bass == "T-JAMES-1", "the claim learns which track it is")
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "Bass Guitar", true)
  sync.follow_claims(p, cfg, song, room)
  local c = sync.my_claims(cfg, song, room)
  check(c.tracks[1] == "Bass Guitar", "renamed: the claim goes with it (" .. tostring(c.tracks[1]) .. ")")
  check((c.since or {})["tracks:bass guitar"] == since and (c.since or {})["tracks:bass"] == nil, "and keeps its date")
  local can = sync.authority(cfg, song, room, { host = "Laptop" })
  check(can("James", "Bass Guitar", 0) and not can("Laptop", "Bass Guitar", 0), "the band sees it as James's under its new name")
  -- the driver releases James's claims while he's away; when James's Live sync next looks, his file is emptied
  sync.release_claims({ user = "Laptop", root = root }, song, room, "James")
  can = sync.authority(cfg, song, room, { host = "Laptop" })
  check(not can("James", "Bass Guitar", 0), "released: it follows the driver")
  sync.follow_claims(p, cfg, song, room)
  check(#(sync.my_claims(cfg, song, room).tracks or {}) == 0, "James's own file is emptied when he's back")
end)
if not ok then fails = fails + 1; out[#out + 1] = "ERROR " .. tostring(err) end
if p and reaper.ValidatePtr2(0, p, "ReaProject*") then
  reaper.SelectProjectInstance(p)
  reaper.Main_SaveProjectEx(p, D .. "/claims_" .. stamp .. ".rpp", 8)
  reaper.Main_OnCommand(40860, 0)
end
if front and reaper.ValidatePtr2(0, front, "ReaProject*") then reaper.SelectProjectInstance(front) end
return (fails == 0 and "ALL PASS" or fails .. " FAILED") .. "\n" .. table.concat(out, "\n")
