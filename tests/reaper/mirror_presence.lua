-- Run inside REAPER (ReaScript). Presence between two scratch tabs, "James" (A) and "Bee" (B): an edit hold, a ping
-- and following a view, through the status files as Live sync writes them. Scratch folder and tabs only.
local D = reaper.GetResourcePath() .. "/BandSync/tests"
reaper.RecursiveCreateDirectory(D, 0)
local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/"
package.path = lib .. "?.lua;" .. package.path
for _, m in ipairs({ "band", "sync", "mirror", "recall", "json", "presence" }) do package.loaded[m] = nil end
local band, sync, mirror, presence = require("band"), require("sync"), require("mirror"), require("presence")
local stamp = os.time()
local root = D .. "/zroot_" .. stamp
local song, room = "PresenceLab", "main"
local A, B = { user = "James", root = root }, { user = "Bee", root = root }
reaper.RecursiveCreateDirectory(sync.room_dir(A, song, room) .. "/events", 0)
local yes = function() return true end
local out, fails = {}, 0
local function check(ok, what) if not ok then fails = fails + 1 end; out[#out + 1] = (ok and "PASS " or "FAIL ") .. what end
local function held_by(cfg) return function(oid) return presence.holder(presence.peers(cfg, song, room), oid) end end
local function pass(p, cfg) reaper.SelectProjectInstance(p); return mirror.watch(p, cfg, song, room, { can = yes, mode = "claims", held = held_by(cfg) }) end
local function recv(p, cfg) reaper.SelectProjectInstance(p); local n = 0; for _ = 1, 3 do n = n + sync.receive(p, cfg, song, room, yes) end; return n end
local function status(p, cfg) -- as Live sync writes it
  sync.write_status(p, cfg, song, room, { editing = presence.editing(p), view = presence.view(p), ping = presence.my_ping(p) })
end
local function fresh_peers() package.loaded.presence = nil; presence = require("presence") end -- (its peer list is cached a second)
local front = reaper.EnumProjects(-1)
local pa, pb
local ok, err = pcall(function()
  reaper.Main_OnCommand(40859, 0); pa = reaper.EnumProjects(-1)
  reaper.Main_OnCommand(40859, 0); pb = reaper.EnumProjects(-1)
  reaper.SelectProjectInstance(pa)
  reaper.InsertTrackInProject(pa, 0, 0)
  local tr = reaper.GetTrack(pa, 0)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "Keys", true)
  local it = reaper.CreateNewMIDIItemInProj(tr, 0, 2, false)
  pass(pa, A); recv(pb, B)
  status(pb, B)
  local bit = mirror.find(pb, "item", mirror.item_oid(it))
  check(bit ~= nil, "B has the item")

  -- 1. A moves the item: A holds it; B's move a moment later is put back with A's name
  reaper.SelectProjectInstance(pa)
  reaper.SetMediaItemInfo_Value(it, "D_POSITION", 4)
  check(pass(pa, A) == 1, "A's move goes out")
  status(pa, A)
  check(table.concat(presence.editing(pa), ","):find(mirror.item_oid(it), 1, true) ~= nil, "A is editing the item")
  recv(pb, B)
  fresh_peers()
  reaper.SelectProjectInstance(pb)
  reaper.SetMediaItemInfo_Value(bit, "D_POSITION", 8)
  local sent = pass(pb, B)
  check(sent == 0 and math.abs(reaper.GetMediaItemInfo_Value(bit, "D_POSITION") - 4) < 1e-6, "B's move is put back while A holds it (sent " .. sent .. ")")
  check(tostring(band.activity()[1]):find("James is editing that item on Keys right now", 1, true) ~= nil, "it says who: " .. tostring(band.activity()[1]))
  -- once A's hold has passed (its status no longer lists the item), B's move goes out
  package.loaded.presence.HOLD = 0
  status(pa, A)
  fresh_peers()
  reaper.SetMediaItemInfo_Value(bit, "D_POSITION", 8)
  check(pass(pb, B) == 1, "after the hold, B's move goes out")

  -- 2. A pings 6 s: a marker with A's name shows on B (not as one of the song's markers); it goes when the ping is old
  presence.ping_here(pa, 6)
  status(pa, A)
  fresh_peers()
  presence.pings(pb, presence.peers(B, song, room))
  local found
  for i = 0, reaper.CountProjectMarkers(pb) - 1 do
    local _, rgn, pos, _, name = reaper.EnumProjectMarkers3(pb, i)
    if not rgn and name == "[ping] James" and math.abs(pos - 6) < 1e-6 then found = true end
  end
  check(found, "B shows A's ping at 6 s")
  local caught = false
  for _, m in ipairs(band.capture_markers(pb)) do if m.name:find("ping", 1, true) then caught = true end end
  check(not caught, "a ping isn't one of the song's markers")
  reaper.DeleteExtState(band.SECTION, "ping " .. tostring(pa), false)
  status(pa, A)
  fresh_peers()
  presence.pings(pb, presence.peers(B, song, room))
  check(reaper.CountProjectMarkers(pb) == 0, "the ping's marker goes with it")

  -- 3. following A: B's view goes where A's is
  reaper.SelectProjectInstance(pa)
  reaper.GetSet_ArrangeView2(pa, true, 0, 0, 20, 40)
  status(pa, A)
  fresh_peers()
  reaper.SelectProjectInstance(pb)
  reaper.GetSet_ArrangeView2(pb, true, 0, 0, 0, 10)
  presence.follow(pb, presence.peers(B, song, room), "James")
  local a, z = reaper.GetSet_ArrangeView2(pb, false, 0, 0, 0, 0)
  check(math.abs(a - 20) < 0.6 and math.abs(z - 40) < 0.6, string.format("B's view follows A's (%.1f-%.1f)", a, z))
end)
if not ok then fails = fails + 1; out[#out + 1] = "ERROR " .. tostring(err) end
for _, p in pairs({ pa, pb }) do
  if reaper.ValidatePtr2(0, p, "ReaProject*") then
    reaper.SelectProjectInstance(p)
    reaper.Main_SaveProjectEx(p, D .. "/presence_" .. stamp .. "_end.rpp", 8)
    reaper.Main_OnCommand(40860, 0)
  end
end
if front and reaper.ValidatePtr2(0, front, "ReaProject*") then reaper.SelectProjectInstance(front) end
return (fails == 0 and "ALL PASS" or fails .. " FAILED") .. "\n" .. table.concat(out, "\n")
