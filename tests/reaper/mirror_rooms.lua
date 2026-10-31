-- Run inside REAPER (ReaScript). Side room under mirror sync: main tab A, side tab S (a copy of A), scratch shared folder, then closed.
local D = reaper.GetResourcePath() .. "/BandSync/tests" -- scratch: never the shared folder
reaper.RecursiveCreateDirectory(D, 0)
package.path = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/?.lua;" .. package.path
for _, m in ipairs({ "band", "sync", "mirror", "recall", "prints" }) do package.loaded[m] = nil end
local sync, mirror = require("sync"), require("mirror")
local root = D .. "/rroot_" .. os.time()
local song = "RoomLab"
local A = { user = "James", root = root }
local yes = function() return true end
local out, fails = {}, 0
local function check(ok, what) if not ok then fails = fails + 1 end; out[#out + 1] = (ok and "PASS " or "FAIL ") .. what end
local function wait(s) local t = reaper.time_precise(); while reaper.time_precise() - t < s do end end
local front = reaper.EnumProjects(-1)
reaper.Main_OnCommand(40859, 0); local pa = reaper.EnumProjects(-1)
local ps
local ok, err = pcall(function()
  reaper.InsertTrackInProject(pa, 0, 0)
  local tr = reaper.GetTrack(pa, 0)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "Gtr", true)
  local x = reaper.CreateNewMIDIItemInProj(tr, 0, 1, false)
  local y = reaper.CreateNewMIDIItemInProj(tr, 4, 5, false)
  mirror.watch(pa, A, song, "main", { can = yes, mode = "claims" })
  local xo, yo = mirror.item_oid(x), mirror.item_oid(y)
  -- the side room: a copy of the main tab, made now
  reaper.Main_SaveProjectEx(pa, D .. "/m_rooms_main.rpp", 8)
  wait(1.1)
  local since = os.date("!%Y-%m-%dT%H:%M:%SZ")
  wait(1.1)
  reaper.Main_OnCommand(40859, 0); ps = reaper.EnumProjects(-1)
  reaper.Main_openProject("noprompt:" .. D .. "/m_rooms_main.rpp")
  ps = reaper.EnumProjects(-1)
  reaper.Main_SaveProjectEx(ps, D .. "/m_rooms_side.rpp", 8)
  do
    local objs = mirror.scan(ps, "x", sync.room_dir(A, song, "side") .. "/media")
    for _, o in ipairs(objs) do
      local _, h = mirror.known(ps, o.oid)
      if h ~= o.hash then out[#out + 1] = "  side sees a change on " .. o.kind .. " " .. o.oid:sub(-10) .. " known " .. tostring(h) .. " now " .. o.hash end
    end
  end
  check(mirror.watch(ps, A, song, "side", { can = yes, mode = "claims" }) == 0, "the side copy starts in step (nothing to send)")
  local sx = mirror.find(ps, "item", xo)
  reaper.SetMediaItemInfo_Value(sx, "D_POSITION", 8)
  local z = reaper.CreateNewMIDIItemInProj(reaper.GetTrack(ps, 0), 12, 13, false)
  mirror.watch(ps, A, song, "side", { can = yes, mode = "claims" })
  local zo = mirror.item_oid(z)
  reaper.SetMediaItemInfo_Value(y, "D_POSITION", 6) -- main changes something else meanwhile
  mirror.watch(pa, A, song, "main", { can = yes, mode = "claims" })
  local bring, clash = mirror.plan_bring(mirror.room_newest(sync.room_dir(A, song, "side"), since), mirror.room_newest(sync.room_dir(A, song, "main"), since))
  check(#bring == 2 and #clash == 0, string.format("plan: %d to bring, %d clash(es)", #bring, #clash))
  mirror.post_into(A, song, "side", "main", bring, pa)
  local mx, mz = mirror.find(pa, "item", xo), mirror.find(pa, "item", zo)
  check(mx and reaper.GetMediaItemInfo_Value(mx, "D_POSITION") == 8, "main got the side room's move")
  check(mz and reaper.GetMediaItemInfo_Value(mz, "D_POSITION") == 12, "main got the side room's new item")
  check(reaper.GetMediaItemInfo_Value(y, "D_POSITION") == 6, "main's own change stayed")
  check(mirror.watch(pa, A, song, "main", { can = yes, mode = "claims" }) == 0, "nothing echoes in main afterwards")
  -- both change the same item: a clash, main keeps its own
  reaper.SetMediaItemInfo_Value(mirror.find(ps, "item", yo), "D_POSITION", 9)
  mirror.watch(ps, A, song, "side", { can = yes, mode = "claims" })
  bring, clash = mirror.plan_bring(mirror.room_newest(sync.room_dir(A, song, "side"), since), mirror.room_newest(sync.room_dir(A, song, "main"), since))
  local yclash = false
  for _, e in ipairs(clash) do if e.oid == yo then yclash = true end end
  check(yclash, "both moved the same item: listed as a clash")
end)
if not ok then fails = fails + 1; out[#out + 1] = "ERROR " .. tostring(err) end
for _, p in ipairs({ ps, pa }) do
  if p and reaper.ValidatePtr2(0, p, "ReaProject*") then reaper.SelectProjectInstance(p); reaper.Main_SaveProject(p, false); reaper.Main_OnCommand(40860, 0) end
end
if front and reaper.ValidatePtr2(0, front, "ReaProject*") then reaper.SelectProjectInstance(front) end
return (fails == 0 and "ALL PASS" or fails .. " FAILED") .. "\n" .. table.concat(out, "\n")
