-- Run inside REAPER (ReaScript). Tracks in the colour of who's working on them (0.38, lib/people.lua): each mode, a
-- picked colour and the defaults, and the band's own colours kept aside (never sent, restored after). Scratch only.
local D = reaper.GetResourcePath() .. "/StudioSync/tests"
local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/"
package.path = lib .. "?.lua;" .. package.path
for _, m in ipairs({ "band", "mirror", "people", "json" }) do package.loaded[m] = nil end
local band, mirror, people = require("band"), require("mirror"), require("people")
local root = D .. "/proot_" .. os.time()
local cfg = { user = "James", root = root }
local out, fails = {}, 0
local function say(s) out[#out + 1] = s end
local function check(ok, what) if not ok then fails = fails + 1 end; say((ok and "PASS " or "FAIL ") .. what) end
local function native(rgb) return reaper.ColorToNative(rgb >> 16, (rgb >> 8) & 0xFF, rgb & 0xFF) | 0x1000000 end
local front = reaper.EnumProjects(-1)
local mode_was = reaper.GetExtState(band.SECTION, "track colours")
reaper.Main_OnCommand(40859, 0); local p = reaper.EnumProjects(-1)
local ok, err = pcall(function()
  reaper.RecursiveCreateDirectory(root .. "/plugins", 0)
  for _, u in ipairs({ "James", "Mac", "Laptop" }) do band.write_json(root .. "/plugins/" .. u .. ".json", { user = u, names = {}, time = "2026-11-01T00:00:00Z" }) end
  people.pick({ user = "Mac", root = root }, 0x123456)
  local col = people.colours(root)
  check(col.Mac == 0x123456 and col.James == people.PALETTE[1] and col.Laptop == people.PALETTE[2], "Mac's pick, defaults for the rest")
  local names = { "Keys", "Bass", "Gtr", "Vox" }
  local makers = { "MAC", "JAMES", "LAPTOP", "JAMES" }
  local BAND = { native(0x202020), native(0x404040), native(0x606060), native(0x808080) }
  for i, n in ipairs(names) do
    reaper.InsertTrackInProject(p, i - 1, 0)
    local tr = reaper.GetTrack(p, i - 1)
    reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", n, true)
    reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_oid", string.format("T-%s-20261101000000-%d", makers[i], i), true)
    reaper.SetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR", BAND[i])
  end
  local keys, bass, gtr, vox = reaper.GetTrack(p, 0), reaper.GetTrack(p, 1), reaper.GetTrack(p, 2), reaper.GetTrack(p, 3)
  local it = reaper.CreateNewMIDIItemInProj(keys, 0, 1, false)
  reaper.GetSetMediaItemInfo_String(it, "P_EXT:band_oid", "I-MAC-20261101000000-9", true)
  local function shown(tr) return reaper.GetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR") end
  local peers = { { user = "Mac", editing = { "I-MAC-20261101000000-9" } }, { user = "James", editing = { "T-JAMES-20261101000000-4" } } }
  local claims = { bass = { user = "Laptop" } }
  local before = {}
  for i = 0, 3 do before[i] = mirror.track_hash(mirror.track_state(p, reaper.GetTrack(p, i))) end
  -- band's colours: nothing changes
  reaper.SetExtState(band.SECTION, "track colours", "band", false)
  people.paint(p, cfg, peers, claims)
  check(shown(keys) == BAND[1] and shown(bass) == BAND[2], "Band's colours: tracks keep them")
  -- show who's working: someone editing (an item on the track), someone's claim; not my own edits
  reaper.SetExtState(band.SECTION, "track colours", "working", false)
  people.paint(p, cfg, peers, claims)
  check(shown(keys) == native(0x123456), "Mac editing an item on Keys: Keys in Mac's colour")
  check(shown(bass) == native(col.Laptop), "Bass is Laptop's claim: Laptop's colour")
  check(shown(gtr) == BAND[3] and shown(vox) == BAND[4], "nobody else on Gtr or Vox (my own edit doesn't count): the band's colours")
  local same = true
  for i = 0, 3 do same = same and mirror.track_hash(mirror.track_state(p, reaper.GetTrack(p, i))) == before[i] end
  check(same, "the band's colours are what mirror sees, so nothing would be sent")
  check(band.track_colour(keys) == BAND[1], "the band's colour waits aside")
  -- a bandmate recolours Keys meanwhile: it goes aside too, and shows once Mac is done
  mirror.set_track_state(p, keys, { name = "Keys", color = band.color_out(native(0x00FF00)) })
  check(shown(keys) == native(0x123456) and band.track_colour(keys) == native(0x00FF00), "the band's new colour waits while Mac's shows")
  -- whose track: the maker too
  reaper.SetExtState(band.SECTION, "track colours", "people", false)
  people.paint(p, cfg, peers, claims)
  check(shown(gtr) == native(col.Laptop) and shown(vox) == native(col.James), "Whose track: Gtr by Laptop, Vox by me (made them)")
  -- everyone done, nothing claimed, back to Show who's working: the band's colours, as they are now
  reaper.SetExtState(band.SECTION, "track colours", "working", false)
  people.paint(p, cfg, {}, {})
  check(shown(keys) == native(0x00FF00) and shown(bass) == BAND[2] and shown(gtr) == BAND[3] and shown(vox) == BAND[4], "done: every track back in the band's colour")
  check(band.track_ext(keys, "band_colour") == "", "and nothing left aside")
  -- my own pick, then back to the default
  people.pick(cfg, 0xABCDEF)
  check(people.mine(cfg) == 0xABCDEF, "picking a colour")
  people.pick(cfg, nil)
  check(people.mine(cfg) == people.PALETTE[1], "Default: back to the palette's")
end)
if not ok then say("ERROR " .. tostring(err)); fails = fails + 1 end
if mode_was ~= "" then reaper.SetExtState(band.SECTION, "track colours", mode_was, false) else reaper.DeleteExtState(band.SECTION, "track colours", false) end
if reaper.ValidatePtr2(0, p, "ReaProject*") then
  reaper.SelectProjectInstance(p)
  reaper.Main_SaveProjectEx(p, D .. "/track_people.rpp", 8)
  reaper.Main_OnCommand(40860, 0)
end
if front and reaper.ValidatePtr2(0, front, "ReaProject*") then reaper.SelectProjectInstance(front) end
return (fails == 0 and "ALL PASS" or (fails .. " FAILED")) .. "\n" .. table.concat(out, "\n")
