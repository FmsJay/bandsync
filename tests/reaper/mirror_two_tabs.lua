-- Run inside REAPER (ReaScript). Mirror sync between two scratch tabs on this machine: "James" (A, allowed everything) and "Bee" (B). The shared
-- folder is a scratch folder, so nothing reaches the band. Both tabs are saved to the scratch folder and closed at
-- the end (James's projects are never touched).
local D = reaper.GetResourcePath() .. "/BandSync/tests" -- scratch: never the shared folder
reaper.RecursiveCreateDirectory(D, 0)
local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/"
package.path = lib .. "?.lua;" .. package.path
for _, m in ipairs({ "band", "sync", "mirror", "recall", "json" }) do package.loaded[m] = nil end
local band, sync, mirror, recall = require("band"), require("sync"), require("mirror"), require("recall")
local root = D .. "/mroot_" .. os.time()
local song, room = "MirrorLab", "main"
local A, B = { user = "James", root = root }, { user = "Bee", root = root }
reaper.RecursiveCreateDirectory(sync.room_dir(A, song, room) .. "/events", 0)
local yes = function() return true end
local out, fails = {}, 0
local function say(s) out[#out + 1] = s end
local function check(ok, what) if not ok then fails = fails + 1 end; say((ok and "PASS " or "FAIL ") .. what) end
local front = reaper.EnumProjects(-1)
reaper.Main_OnCommand(40859, 0); local pa = reaper.EnumProjects(-1)
reaper.Main_OnCommand(40859, 0); local pb = reaper.EnumProjects(-1)
local media = sync.room_dir(A, song, room) .. "/media"
local function pass_a(can) return mirror.watch(pa, A, song, room, { can = can or yes, mode = "claims" }) end
local function pass_b(can) return mirror.watch(pb, B, song, room, { can = can or yes, mode = "claims" }) end
local function recv(p, cfg) local n = 0; for _ = 1, 3 do n = n + sync.receive(p, cfg, song, room, yes) end; return n end
local function same(what)
  local oa = select(2, mirror.scan(pa, "x", media)); local ob = select(2, mirror.scan(pb, "x", media))
  local diff = {}
  for oid, o in pairs(oa) do if not ob[oid] then diff[#diff + 1] = "missing on B: " .. oid elseif ob[oid].hash ~= o.hash then
    diff[#diff + 1] = "differs: " .. oid .. (o.kind == "track" and ("\n   A " .. mirror.track_line(o.state) .. "|" .. o.state.after ..
      "\n   B " .. mirror.track_line(ob[oid].state) .. "|" .. ob[oid].state.after) or "") end end
  for oid in pairs(ob) do if not oa[oid] then diff[#diff + 1] = "extra on B: " .. oid end end
  check(#diff == 0, what .. (#diff > 0 and (" -> " .. table.concat(diff, "; ")) or ""))
end
local ok, err = pcall(function()
  -- 1. A builds: a named track with fixed lanes and a MIDI item in lane 1, plus an unnamed track with an item
  reaper.InsertTrackInProject(pa, 0, 0); reaper.InsertTrackInProject(pa, 1, 0)
  local bass, blank = reaper.GetTrack(pa, 0), reaper.GetTrack(pa, 1)
  reaper.GetSetMediaTrackInfo_String(bass, "P_NAME", "Bass", true)
  local it = reaper.CreateNewMIDIItemInProj(bass, 0, 2, false)
  local tk = reaper.GetActiveTake(it)
  reaper.MIDI_InsertNote(tk, false, false, 0, 480, 0, 40, 100, true); reaper.MIDI_Sort(tk)
  reaper.SetMediaTrackInfo_Value(bass, "I_FREEMODE", 2)
  reaper.SetMediaTrackInfo_Value(bass, "I_NUMFIXEDLANES", 2)
  local it2 = reaper.CreateNewMIDIItemInProj(bass, 0, 2, false)
  reaper.SetMediaItemInfo_Value(it2, "I_FIXEDLANE", 1)
  reaper.SetMediaTrackInfo_Value(bass, "C_LANEPLAYS:1", 1)
  reaper.CreateNewMIDIItemInProj(blank, 4, 6, false)
  local sent = pass_a()
  say("A sent " .. sent .. " object(s)")
  say("B applied " .. recv(pb, B) .. " event(s)")
  check(reaper.CountTracks(pb) == 2, "B has both tracks (" .. reaper.CountTracks(pb) .. ")")
  check(select(2, reaper.GetSetMediaTrackInfo_String(reaper.GetTrack(pb, 0), "P_NAME", "", false)) == "Bass", "B's first track is Bass")
  check(reaper.GetMediaTrackInfo_Value(reaper.GetTrack(pb, 0), "I_NUMFIXEDLANES") == 2, "B's Bass has 2 lanes")
  check(reaper.GetMediaTrackInfo_Value(reaper.GetTrack(pb, 0), "C_LANEPLAYS:1") ~= 0, "lane 2 plays on B")
  local bit = reaper.GetTrackMediaItem(reaper.GetTrack(pb, 0), 0)
  local _, bn = reaper.MIDI_CountEvts(reaper.GetActiveTake(bit))
  check(bn == 1, "B's MIDI item has the note")
  same("after first send")
  do -- what would B think changed?
    local i, keys = 0, {}
    while true do
      local ok2, k, v = reaper.EnumProjExtState(pb, mirror.SEC, i)
      if not ok2 then break end
      i = i + 1
      if i <= 3 then keys[#keys + 1] = k .. " = " .. v end
    end
    say("  B holds " .. i .. " record(s): " .. table.concat(keys, " ; "))
    local objs = mirror.scan(pb, "Bee", media)
    for _, o in ipairs(objs) do
      local _, h = mirror.known(pb, o.oid)
      if h ~= o.hash then say("  B sees a change on " .. o.oid .. " (" .. o.kind .. "): known " .. tostring(h) .. " now " .. o.hash ..
        (o.kind == "item" and ("\n" .. o.state) or "")) end
    end
  end
  check(pass_b() == 0, "B sends nothing back (no echo)")
  -- 2. A copies an item (as Ctrl+drag does: same chunk, same oid), renames the unnamed track, mutes, lane play changes
  local _, ch = reaper.GetItemStateChunk(it, "", false)
  local cp = reaper.AddMediaItemToTrack(bass)
  reaper.SetItemStateChunk(cp, ch, false)
  reaper.SetMediaItemInfo_Value(cp, "D_POSITION", 8)
  reaper.GetSetMediaTrackInfo_String(blank, "P_NAME", "Keys", true)
  reaper.SetMediaItemInfo_Value(it, "B_MUTE", 1)
  reaper.SetMediaTrackInfo_Value(bass, "C_LANEPLAYS:0", 1)
  say("A sent " .. pass_a() .. " change(s)")
  recv(pb, B)
  same("after copy, rename, mute, lane play")
  check(reaper.CountTrackMediaItems(reaper.GetTrack(pb, 0)) == 3, "the copy arrived as its own item")
  check(pass_b() == 0, "still no echo")
  -- 3. B may not change anything: its move is put back
  local bi = reaper.GetTrackMediaItem(reaper.GetTrack(pb, 1), 0)
  local was = reaper.GetMediaItemInfo_Value(bi, "D_POSITION")
  reaper.SetMediaItemInfo_Value(bi, "D_POSITION", was + 3)
  local s2, back = pass_b(function() return false end)
  check(s2 == 0 and back == 1, "B's move wasn't sent, it was put back (sent " .. s2 .. ", put back " .. back .. ")")
  check(math.abs(reaper.GetMediaItemInfo_Value(reaper.GetTrackMediaItem(reaper.GetTrack(pb, 1), 0), "D_POSITION") - was) < 1e-6, "B's item is where the band has it")
  -- and a copy B isn't allowed to make goes away
  local _, bch = reaper.GetItemStateChunk(reaper.GetTrackMediaItem(reaper.GetTrack(pb, 1), 0), "", false)
  local bcp = reaper.AddMediaItemToTrack(reaper.GetTrack(pb, 1)); reaper.SetItemStateChunk(bcp, bch, false)
  pass_b(function() return false end)
  check(reaper.CountTrackMediaItems(reaper.GetTrack(pb, 1)) == 1, "B's unallowed copy was removed")
  same("after B's put-backs")
  -- 4. History: undo A's mute (one change), from the shared History; B follows
  local entries = recall.entries(A, song, room)
  local idx
  for i, e in ipairs(entries) do if e.kind == "obj" and e.obj == "item" and e.oid == mirror.item_oid(it) and (e.rev or 0) > 1 then idx = i end end
  check(idx ~= nil, "History has the mute change")
  if idx then
    say(mirror.revert(pa, A, song, room, mirror.plan_undo(entries, idx), { can = yes, mode = "claims" }))
    check(reaper.GetMediaItemInfo_Value(it, "B_MUTE") == 0, "A's item unmuted by Undo this")
    recv(pb, B)
    same("after Undo this")
  end
  -- 5. A deletes the Keys track: it goes on B too
  reaper.DeleteTrack(blank)
  pass_a(); recv(pb, B)
  check(reaper.CountTracks(pb) == 1, "Keys deleted on B too")
  same("after track delete")
  -- 6. both move the same item while apart (both allowed): one version wins on both machines
  local xa = reaper.GetTrackMediaItem(reaper.GetTrack(pa, 0), 0)
  local oid = mirror.item_oid(xa)
  local xb = mirror.find(pb, "item", oid)
  reaper.SetMediaItemInfo_Value(xa, "D_POSITION", 20)
  reaper.SetMediaItemInfo_Value(xb, "D_POSITION", 30)
  pass_a(); pass_b()
  recv(pb, B); recv(pa, A)
  local pa_pos = reaper.GetMediaItemInfo_Value(mirror.find(pa, "item", oid), "D_POSITION")
  local pb_pos = reaper.GetMediaItemInfo_Value(mirror.find(pb, "item", oid), "D_POSITION")
  check(pa_pos == pb_pos, string.format("both changed it: they agree (A %.0f, B %.0f)", pa_pos, pb_pos))
  same("after both changed one item")
end)
if not ok then say("ERROR " .. tostring(err)) ; fails = fails + 1 end
-- tidy: both scratch tabs saved into the scratch folder (so closing never asks) and closed
for k, p in ipairs({ pa, pb }) do
  if reaper.ValidatePtr2(0, p, "ReaProject*") then
    reaper.SelectProjectInstance(p)
    reaper.Main_SaveProjectEx(p, D .. "/m_two_tabs_" .. k .. ".rpp", 8)
    reaper.Main_OnCommand(40860, 0)
  end
end
if front and reaper.ValidatePtr2(0, front, "ReaProject*") then reaper.SelectProjectInstance(front) end
return (fails == 0 and "ALL PASS" or (fails .. " FAILED")) .. "\n" .. table.concat(out, "\n")
