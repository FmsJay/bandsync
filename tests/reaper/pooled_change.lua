-- Run inside REAPER (ReaScript). A band change landing on one of two pooled MIDI parts: "James" copies a part the way Ctrl+drag does, so here the two share a
-- pool; "Bee" gets them as separate parts and edits one. Coming back it rewrites that one here. REAPER's MIDI code has crashed on a freed list entry on a
-- later tab close after a rewrite like that (the kept copy in lib/mirror.lua); this checks the band's edit lands, the other part keeps its notes, and it's safe
-- to close. Scratch tabs and folder only.
local D = reaper.GetResourcePath() .. "/StudioSync/tests"
reaper.RecursiveCreateDirectory(D, 0)
local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/"
package.path = lib .. "?.lua;" .. package.path
for _, m in ipairs({ "band", "sync", "mirror", "recall", "json", "prints" }) do package.loaded[m] = nil end
require("prints").SETTLE = 0
local band, sync, mirror = require("band"), require("sync"), require("mirror")
local root = D .. "/pooled_" .. os.time()
local song, room = "PoolLab", "main"
local A, B = { user = "James", root = root }, { user = "Bee", root = root }
reaper.RecursiveCreateDirectory(sync.room_dir(A, song, room) .. "/events", 0)
local yes = function() return true end
local out, fails = {}, 0
local function check(ok, what) if not ok then fails = fails + 1 end; out[#out + 1] = (ok and "PASS " or "FAIL ") .. what end
local function pass(p, cfg) reaper.SelectProjectInstance(p); local n = 0; for _ = 1, 3 do n = n + mirror.watch(p, cfg, song, room, { can = yes, mode = "open" }) end; return n end
local function recv(p, cfg) reaper.SelectProjectInstance(p); local n = 0; for _ = 1, 3 do n = n + sync.receive(p, cfg, song, room, yes) end; return n end
local function hold(s) local w = reaper.time_precise(); while reaper.time_precise() - w < s do end end
local function notes(it)
  local tk = reaper.GetActiveTake(it)
  local _, n = reaper.MIDI_CountEvts(tk)
  return n
end
local function pool(it) return select(2, reaper.GetItemStateChunk(it, "", false)):match("POOLEDEVTS (%S+)") end
local front = reaper.EnumProjects(-1)
local pa, pb
local ok, err = pcall(function()
  reaper.Main_OnCommand(40859, 0); pa = reaper.EnumProjects(-1)
  reaper.Main_OnCommand(40859, 0); pb = reaper.EnumProjects(-1)
  reaper.SelectProjectInstance(pa)
  reaper.InsertTrackInProject(pa, 0, 0)
  local tr = reaper.GetTrack(pa, 0)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "Keys", true)
  local one = reaper.CreateNewMIDIItemInProj(tr, 0, 2, false)
  reaper.MIDI_InsertNote(reaper.GetActiveTake(one), false, false, 0, 480, 0, 60, 100, false)
  -- as Ctrl+drag: a new item id, the same pool
  local _, ch = reaper.GetItemStateChunk(one, "", false)
  local two = reaper.AddMediaItemToTrack(tr)
  reaper.SetItemStateChunk(two, (ch:gsub("\nIGUID [^\n]*", "")), false)
  reaper.SetMediaItemInfo_Value(two, "D_POSITION", 10)
  check(pool(one) and pool(one) == pool(two), "here the two parts share a MIDI pool")
  pass(pa, A); recv(pb, B)
  local btr = reaper.GetTrack(pb, 0)
  check(btr and reaper.CountTrackMediaItems(btr) == 2, "Bee has both")
  hold(1.1)
  local oid_one = mirror.item_oid(one)
  local on_b = mirror.find(pb, "item", oid_one)
  reaper.SelectProjectInstance(pb)
  reaper.MIDI_InsertNote(reaper.GetActiveTake(on_b), false, false, 480, 960, 0, 62, 100, false)
  reaper.UpdateItemInProject(on_b)
  pass(pb, B)
  recv(pa, A)
  local got = mirror.find(pa, "item", oid_one)
  check(got and notes(got) == 2, "Bee's edit lands on James's part (" .. tostring(got and notes(got)) .. " notes)")
  local other
  for i = 0, reaper.CountTrackMediaItems(tr) - 1 do
    local x = reaper.GetTrackMediaItem(tr, i)
    if x ~= got then other = x end
  end
  check(other and notes(other) == 1, "the other part keeps its own notes (" .. tostring(other and notes(other)) .. ")")
  check(other and pool(other) ~= pool(got), "and they don't share a pool any more")
  pass(pa, A); recv(pb, B)
  -- and looking at, moving and rewriting the leftover copy is all right
  reaper.SelectProjectInstance(pa)
  reaper.SetMediaItemInfo_Value(other, "D_POSITION", 12)
  pass(pa, A); recv(pb, B)
  check(math.abs(reaper.GetMediaItemInfo_Value(mirror.find(pb, "item", mirror.item_oid(other)), "D_POSITION") - 12) < 1e-6, "the other part still syncs")
end)
if not ok then fails = fails + 1; out[#out + 1] = "ERROR " .. tostring(err) end
for k, p in pairs({ pa, pb }) do
  if p and reaper.ValidatePtr2(0, p, "ReaProject*") then
    reaper.SelectProjectInstance(p)
    reaper.Main_SaveProjectEx(p, root .. "/end_" .. k .. ".rpp", 8)
    reaper.Main_OnCommand(40860, 0)
  end
end
if front and reaper.ValidatePtr2(0, front, "ReaProject*") then reaper.SelectProjectInstance(front) end
return (fails == 0 and "ALL PASS" or fails .. " FAILED") .. "\n" .. table.concat(out, "\n")
