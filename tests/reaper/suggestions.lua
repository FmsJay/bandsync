-- Run inside REAPER (ReaScript). An edit across parts someone has claimed: what's yours goes out, what's theirs goes back and
-- reaches them as one suggestion, accepted or declined without the claim ever moving. Also: a tempo change is nobody's edit,
-- a bus keeps what it holds, a bus's change says whose parts it affects, and a copy of a claimed track goes out as yours.
-- Two scratch tabs and a scratch shared folder: "James" (drives) and "Mac" (claims Keys).
local D = reaper.GetResourcePath() .. "/BandSync/tests"
reaper.RecursiveCreateDirectory(D, 0)
local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/"
package.path = lib .. "?.lua;" .. package.path
for _, m in ipairs({ "band", "sync", "mirror", "recall", "json", "suggest" }) do package.loaded[m] = nil end
local band, sync, mirror, suggest = require("band"), require("sync"), require("mirror"), require("suggest")
local root = D .. "/sgroot_" .. os.time()
local song, room = "SuggestLab", "main"
local A, B = { user = "James", root = root }, { user = "Mac", root = root }
local room_dir = sync.room_dir(A, song, room)
reaper.RecursiveCreateDirectory(room_dir .. "/events", 0)
local session = { host = "James" }
local out, fails = {}, 0
local function say(s) out[#out + 1] = s end
local function check(ok, what)
  if not ok then fails = fails + 1 end
  -- (mirror.watch waits while a mouse button is down: someone using this computer during a run shows up as a failure)
  say((ok and "PASS " or "FAIL ") .. what .. ((not ok and reaper.JS_Mouse_GetState and reaper.JS_Mouse_GetState(1) & 1 == 1) and " (mouse held)" or ""))
end
local yes = function() return true end
local front = reaper.EnumProjects(-1)
reaper.Main_OnCommand(40859, 0); local pa = reaper.EnumProjects(-1)
reaper.Main_OnCommand(40859, 0); local pb = reaper.EnumProjects(-1)
local media = room_dir .. "/media"
local function can() return (sync.authority(A, song, room, session)) end
local function pass_a() reaper.SelectProjectInstance(pa); return mirror.watch(pa, A, song, room, { can = can(), mode = "claims" }) end
local function pass_b() reaper.SelectProjectInstance(pb); return mirror.watch(pb, B, song, room, { can = can(), mode = "claims" }) end
local function recv(p, cfg) reaper.SelectProjectInstance(p); local n = 0; for _ = 1, 3 do n = n + sync.receive(p, cfg, song, room, yes) end; return n end
local function sync_all() for _ = 1, 2 do pass_a(); recv(pb, B); pass_b(); recv(pa, A) end end
local function name_of(tr) return select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)) end
local function track_named(p, name)
  for t = 0, reaper.CountTracks(p) - 1 do if name_of(reaper.GetTrack(p, t)) == name then return reaper.GetTrack(p, t) end end
end
local function new_track(p, name, at)
  reaper.InsertTrackInProject(p, at or reaper.CountTracks(p), 0)
  local tr = reaper.GetTrack(p, at or reaper.CountTracks(p) - 1)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", name, true)
  return tr
end
local function positions(tr)
  local t = {}
  for i = 0, reaper.CountTrackMediaItems(tr) - 1 do t[#t + 1] = string.format("%.3f", reaper.GetMediaItemInfo_Value(reaper.GetTrackMediaItem(tr, i), "D_POSITION")) end
  table.sort(t)
  return table.concat(t, " ")
end
local function copy_item(it, pos) -- (as Ctrl+drag does: a new GUID, the same oid)
  local _, ch = reaper.GetItemStateChunk(it, "", false)
  local cp = reaper.AddMediaItemToTrack(reaper.GetMediaItem_Track(it))
  reaper.SetItemStateChunk(cp, (ch:gsub("\nIGUID [^\n]*", "")), false)
  reaper.SetMediaItemInfo_Value(cp, "D_POSITION", pos)
  return cp
end
local function same(what)
  local oa = select(2, mirror.scan(pa, "x", media)); local ob = select(2, mirror.scan(pb, "x", media))
  local diff = {}
  for oid, o in pairs(oa) do if not ob[oid] then diff[#diff + 1] = "missing on Mac: " .. oid elseif ob[oid].hash ~= o.hash then diff[#diff + 1] = "differs: " .. oid ..
    (o.kind == "track" and ("\n   James " .. mirror.track_line(o.state) .. "|" .. o.state.after .. "\n   Mac   " .. mirror.track_line(ob[oid].state) .. "|" .. ob[oid].state.after) or "") end end
  for oid in pairs(ob) do if not oa[oid] then diff[#diff + 1] = "extra on Mac: " .. oid end end
  check(#diff == 0, what .. (#diff > 0 and (" -> " .. table.concat(diff, "; ")) or ""))
end
local was_put = reaper.GetExtState(band.SECTION, "put back") -- (what this says goes on the real panel's bar otherwise)
local ok, err = pcall(function()
  reaper.SelectProjectInstance(pa)
  local keys, bass = new_track(pa, "Keys"), new_track(pa, "Bass")
  local k1 = reaper.CreateNewMIDIItemInProj(keys, 0, 2, false)
  local k2 = reaper.CreateNewMIDIItemInProj(keys, 4, 6, false)
  local b1 = reaper.CreateNewMIDIItemInProj(bass, 0, 2, false)
  sync_all()
  sync.set_claims(B, song, room, { tracks = { "Keys" }, regions = {}, times = {} })
  check(not can()("James", "Keys", 0) and can()("Mac", "Keys", 0), "Mac has claimed Keys, and James drives")
  local mkeys = track_named(pb, "Keys")
  check(mkeys ~= nil and reaper.CountTrackMediaItems(mkeys) == 2, "Mac has Keys")

  -- 1. James copies a section, moves a claimed part, deletes one, and adds to his own at the same time
  local k1_oid, k2_oid = mirror.item_oid(k1), mirror.item_oid(k2)
  copy_item(b1, 20); copy_item(k1, 20)
  reaper.SetMediaItemInfo_Value(k1, "D_POSITION", 1)
  reaper.DeleteTrackMediaItem(keys, k2)
  local sent = pass_a()
  check(sent >= 1, "James's part of it goes out (" .. sent .. ")")
  check(positions(keys) == "0.000 4.000", "Keys is back as the band has it, here (" .. positions(keys) .. ")")
  local kept = track_named(pa, "Keys (yours, not sent)")
  check(kept ~= nil and reaper.CountTrackMediaItems(kept) == 1, "the new part is kept on James's own track")
  local mine = select(1, suggest.rows(room_dir, "Mac"))
  local _, waiting = suggest.rows(room_dir, "James")
  check(#mine == 1, "one line for Mac (" .. #mine .. ")")
  check(#waiting == 1, "James sees it waiting")
  local h = mine[1]
  if h then
    check(h.changes == 1 and h.adds == 1 and h.removes == 1, "it says what it does: " .. suggest.words(h))
    check(suggest.words(h):find("Keys", 1, true) ~= nil and not suggest.words(h):find("Bass", 1, true), "only Mac's track is on it")
  end
  check(can()("Mac", "Keys", 0) and not can()("James", "Keys", 0), "the claim hasn't moved")
  recv(pb, B)
  check(reaper.CountTrackMediaItems(track_named(pb, "Bass")) == 2, "Mac has James's own new part")
  check(positions(mkeys) == "0.000 4.000", "Mac's Keys hasn't changed by itself (" .. positions(mkeys) .. ")")

  -- 2. Mac accepts: it lands as Mac's own change, and the band follows
  reaper.SelectProjectInstance(pb)
  local did, stale, refused = suggest.accept(pb, B, room_dir, h, function(name, pos) return can()("Mac", name, pos) end, false)
  check(did == 3 and stale == 0 and refused == 0, "accepted: all 3 land (" .. tostring(did) .. ", " .. tostring(stale) .. ", " .. tostring(refused) .. ")")
  suggest.answer(room_dir, h, "Mac", "accepted", { left = 0 })
  check(positions(mkeys) == "1.000 20.000", "Mac's Keys has it (" .. positions(mkeys) .. ")")
  check(pass_b() >= 3, "and it goes out from Mac")
  local mine_sent = 0
  for _, f in ipairs(band.files(room_dir .. "/events", ".json")) do
    local e = band.read_json(room_dir .. "/events/" .. f)
    if e and e.obj == "item" and e.oid == k1_oid and e.user == "Mac" then mine_sent = mine_sent + 1 end
  end
  check(mine_sent == 1, "the event is Mac's")
  recv(pa, A)
  check(positions(keys) == "1.000 20.000", "James has it (" .. positions(keys) .. ")")
  suggest.notices(pa, A, room_dir)
  check(track_named(pa, "Keys (yours, not sent)") == nil, "James's kept part is on Keys now, and its empty track is gone")
  -- (an empty one is cleared on a later look too: the answer can arrive before what it brings)
  check(reaper.CountMediaItems(pa) == reaper.CountMediaItems(pb), "same number of parts on both")
  check(#(select(1, suggest.rows(room_dir, "Mac"))) == 0 and #(select(2, suggest.rows(room_dir, "James"))) == 0, "nothing's waiting now")
  sync_all()
  same("after accepting")
  check(pass_a() == 0 and pass_b() == 0, "quiet afterwards")

  -- 3. Decline: nothing changes for Mac, and what's new stays with James
  local k3 = reaper.GetTrackMediaItem(keys, 0)
  copy_item(k3, 30)
  reaper.SetMediaItemInfo_Value(k3, "D_POSITION", 2)
  pass_a()
  mine = select(1, suggest.rows(room_dir, "Mac"))
  check(#mine == 1, "a new line for Mac")
  if mine[1] then
    suggest.answer(room_dir, mine[1], "Mac", "declined")
    suggest.notices(pa, A, room_dir)
    kept = track_named(pa, "Keys (yours, not sent)")
    check(kept ~= nil and reaper.CountTrackMediaItems(kept) == 1, "declined: James keeps his copy on his own track")
  end
  check(positions(mkeys) == "1.000 20.000", "Mac's Keys is as it was (" .. positions(mkeys) .. ")")
  sync_all()
  same("after declining")

  -- 4. A suggestion on something Mac has changed since: what Mac did stands
  local k4 = reaper.GetTrackMediaItem(keys, 0)
  reaper.SetMediaItemInfo_Value(k4, "D_POSITION", 3)
  pass_a()
  mine = select(1, suggest.rows(room_dir, "Mac"))
  local mk = reaper.GetTrackMediaItem(mkeys, 0)
  reaper.SetMediaItemInfo_Value(mk, "D_POSITION", 9)
  pass_b(); recv(pa, A)
  reaper.SelectProjectInstance(pb)
  local d2, s2 = suggest.accept(pb, B, room_dir, mine[1], function(name, pos) return can()("Mac", name, pos) end, false)
  suggest.answer(room_dir, mine[1], "Mac", "accepted", { left = s2 })
  check(d2 == 0 and s2 == 1, "changed since: left as it is (" .. tostring(d2) .. " landed, " .. tostring(s2) .. " left)")
  check(reaper.GetMediaItemInfo_Value(mk, "D_POSITION") == 9, "Mac's own move stands")
  sync_all()

  -- 5. Withdrawn: the line goes for both
  local k5 = reaper.GetTrackMediaItem(keys, 0)
  reaper.SetMediaItemInfo_Value(k5, "D_POSITION", reaper.GetMediaItemInfo_Value(k5, "D_POSITION") + 1)
  pass_a()
  local _, w5 = suggest.rows(room_dir, "James")
  check(#w5 == 1, "waiting again")
  if w5[1] then suggest.answer(room_dir, w5[1], "James", "withdrawn") end
  check(#(select(1, suggest.rows(room_dir, "Mac"))) == 0, "withdrawn: gone from Mac's list")

  -- 6. The same thing refused again and again is changing by itself: no more lines for it
  local before = #suggest.all(room_dir)
  suggest.GAP = 0
  local again = reaper.GetTrackMediaItem(keys, 0)
  for i = 1, 8 do
    reaper.SetMediaItemInfo_Value(again, "D_POSITION", 40 + i)
    pass_a()
  end
  suggest.GAP = 15
  check(#suggest.all(room_dir) - before <= suggest.REPEATS, "repeats stop (" .. (#suggest.all(room_dir) - before) .. " new)")
  for _, x in ipairs(suggest.all(room_dir)) do if not x.answer then suggest.answer(room_dir, x, "James", "withdrawn") end end
  sync_all()
  same("after the repeats")

  -- 7. Tempo: the driver's change moves everyone's parts, and that's nobody's edit
  sync.watch_timeline(pa, A, song, room, can()); sync.watch_timeline(pb, B, song, room, can())
  local waits = #suggest.all(room_dir)
  local item_on_keys = reaper.GetTrackMediaItem(keys, 0)
  local at_before = reaper.GetMediaItemInfo_Value(item_on_keys, "D_POSITION")
  reaper.SelectProjectInstance(pb)
  reaper.SetCurrentBPM(pb, 77, false)
  sync.watch_timeline(pb, B, song, room, can())
  check(math.abs(reaper.TimeMap2_GetDividedBpmAtTime(pb, 0) - 77) > 1, "someone who doesn't drive can't change the tempo: put back")
  reaper.SelectProjectInstance(pa)
  reaper.SetCurrentBPM(pa, 60, false)
  sync.watch_timeline(pa, A, song, room, can())
  local moved = reaper.GetMediaItemInfo_Value(item_on_keys, "D_POSITION")
  say(string.format("  a part on Keys: %.3f, %.3f after the tempo change", at_before, moved))
  pass_a()
  check(#suggest.all(room_dir) == waits, "James's tempo change suggests nothing to Mac")
  check(math.abs(reaper.GetMediaItemInfo_Value(reaper.GetTrackMediaItem(keys, 0), "D_POSITION") - moved) < 1e-6, "Mac's part isn't put back to its old time on James's machine")
  recv(pb, B)
  check(math.abs(reaper.TimeMap2_GetDividedBpmAtTime(pb, 0) - 60) < 0.01, "Mac has the tempo")
  sync_all()
  same("after the tempo change")
  check(math.abs(reaper.GetMediaItemInfo_Value(reaper.GetTrackMediaItem(keys, 0), "D_POSITION") - moved) < 1e-6, "and it stays where the tempo put it")
  -- in an Open room anyone's tempo change goes through
  sync.set_mode(A, song, room, "open", "James")
  reaper.SelectProjectInstance(pb)
  reaper.SetCurrentBPM(pb, 90, false)
  sync.watch_timeline(pb, B, song, room, can())
  recv(pa, A)
  check(math.abs(reaper.TimeMap2_GetDividedBpmAtTime(pa, 0) - 90) < 0.01, "Open: Mac's tempo change reaches James")
  sync.set_mode(A, song, room, "claims", "James")
  sync_all()

  -- 8. A bus: James's change on it says whose part it affects; deleting it is refused while it holds Mac's
  local bus = new_track(pa, "Keys Bus", 0)
  reaper.TrackFX_AddByName(bus, "ReaEQ", false, -1)
  reaper.SelectProjectInstance(pa)
  reaper.SetMediaTrackInfo_Value(bus, "I_FOLDERDEPTH", 1)
  reaper.SetMediaTrackInfo_Value(keys, "I_FOLDERDEPTH", -1)
  mirror.watch(pa, A, song, room, { can = yes, mode = "claims" }) -- (as the driver with nobody else here, so Keys moves into it)
  for _ = 1, 3 do mirror.watch(pa, A, song, room, { can = yes, mode = "claims" }) end
  recv(pb, B); sync_all()
  reaper.SetMediaTrackInfo_Value(bus, "D_VOL", 0.5)
  pass_a()
  local noted
  for _, f in ipairs(band.files(room_dir .. "/events", ".json")) do
    local e = band.read_json(room_dir .. "/events/" .. f)
    if e and type(e.note) == "string" and e.note:find("Keys Bus", 1, true) then noted = e.note end
  end
  check(noted ~= nil and noted:find("Mac's Keys", 1, true) ~= nil, "the bus says so: " .. tostring(noted))
  sync_all()
  local mbus = track_named(pb, "Keys Bus")
  check(mbus ~= nil and math.abs(reaper.GetMediaTrackInfo_Value(mbus, "D_VOL") - 0.5) < 1e-3, "the bus change went through")
  pass_a()
  for _, f in pairs(mirror.fx_seen) do f.since = f.since - 10 end -- (a chain goes out once it has settled)
  pass_a(); recv(pb, B)
  local chain_before = reaper.TrackFX_GetCount(bus)
  check(chain_before == 1, "the bus has its plug-in")
  reaper.SelectProjectInstance(pa)
  reaper.SetOnlyTrackSelected(bus); reaper.Main_OnCommand(40005, 0) -- Track: Remove tracks
  pass_a()
  bus = track_named(pa, "Keys Bus")
  check(bus ~= nil, "deleting the bus that holds Mac's Keys: it's back")
  if bus then
    check(reaper.TrackFX_GetCount(bus) == 1, "with its plug-in")
    keys = track_named(pa, "Keys")
    check(reaper.GetParentTrack(keys) == bus, "and Keys is in it")
    check(reaper.GetMediaTrackInfo_Value(bus, "I_FOLDERDEPTH") == 1 and reaper.GetMediaTrackInfo_Value(keys, "I_FOLDERDEPTH") == -1, "the folder is as it was")
  end
  recv(pb, B); sync_all()
  same("after the refused delete")
  check(track_named(pb, "Keys Bus") ~= nil, "Mac never lost it")
  -- nobody's claim in it: the delete goes
  local free = new_track(pa, "Free Bus")
  local free_kid = new_track(pa, "Free Kid")
  reaper.SelectProjectInstance(pa)
  reaper.SetMediaTrackInfo_Value(free, "I_FOLDERDEPTH", 1)
  reaper.SetMediaTrackInfo_Value(free_kid, "I_FOLDERDEPTH", -1)
  sync_all(); pass_a()
  reaper.SetOnlyTrackSelected(free); reaper.Main_OnCommand(40005, 0)
  pass_a(); recv(pb, B)
  check(track_named(pa, "Free Bus") == nil and track_named(pb, "Free Bus") == nil, "a bus that holds nobody's claim is deleted")
  sync_all()

  -- 9. A copy of Mac's track: James's own, named so, Mac's untouched
  reaper.SelectProjectInstance(pa)
  local tk = track_named(pa, "Keys")
  reaper.SetOnlyTrackSelected(tk)
  reaper.Main_OnCommand(40062, 0) -- Track: Duplicate tracks
  local items_on_keys = reaper.CountTrackMediaItems(tk)
  sync_all()
  for _, x in ipairs(select(1, suggest.rows(room_dir, "Mac"))) do
    say("  on Mac's list: " .. x.id .. " " .. suggest.words(x))
    for _, oid in ipairs(x.oids) do
      local c = band.read_json(room_dir .. "/suggestions/parts/" .. x.id .. "/" .. oid .. ".json")
      say("    " .. oid .. " " .. tostring(c and c.obj) .. " base " .. tostring(c and c.rev))
      local here = mirror.find(pa, "item", oid)
      say("    on James: " .. (here and name_of(reaper.GetMediaItem_Track(here)) or "none") .. "; on Mac: " .. (mirror.find(pb, "item", oid) and name_of(reaper.GetMediaItem_Track(mirror.find(pb, "item", oid))) or "none"))
      for _, f in ipairs(band.files(room_dir .. "/events", ".json")) do
        local e = band.read_json(room_dir .. "/events/" .. f)
        if e and e.oid == oid then say("    ev " .. f .. " rev " .. tostring(e.rev) .. " gone " .. tostring(e.gone) .. " pos " .. tostring(e.pos)) end
      end
      if c and c.obj == "track" then
        local last = mirror.event_file(room_dir, select(3, mirror.known(pa, oid)))
        say("    now  " .. mirror.track_line(c.state) .. "|" .. tostring(c.state.after)); say("    band " .. mirror.track_line(last.state) .. "|" .. tostring(last.state.after))
      end
    end
  end
  check(#(select(1, suggest.rows(room_dir, "Mac"))) == 0, "copying Keys asks Mac nothing")
  local dup = track_named(pa, "Keys (James's copy)")
  check(dup ~= nil, "the copy has a name of its own")
  if dup then
    check(reaper.CountTrackMediaItems(dup) == items_on_keys, "with Keys' parts on it")
    check(can()("James", "Keys (James's copy)", 0), "it's James's")
    check(can()("Mac", "Keys", 0) and not can()("James", "Keys", 0), "Keys is still Mac's")
    check(track_named(pb, "Keys (James's copy)") ~= nil, "Mac has the copy")
  end
  check(track_named(pa, "Keys (yours, not sent)") == nil or reaper.CountTrackMediaItems(track_named(pa, "Keys (yours, not sent)")) == 1, "nothing of the copy went aside")
  local credited
  for _, f in ipairs(band.files(room_dir .. "/events", ".json")) do
    local e = band.read_json(room_dir .. "/events/" .. f)
    if e and type(e.note) == "string" and e.note:find("copied", 1, true) then credited = e.note end
  end
  check(credited ~= nil and credited:find("Mac's Keys", 1, true) ~= nil, "it says whose it was: " .. tostring(credited))
  same("after the copy")
end)
if not ok then say("ERROR " .. tostring(err)); fails = fails + 1 end
reaper.SetExtState(band.SECTION, "put back", was_put, false)
for k, p in ipairs({ pa, pb }) do
  if reaper.ValidatePtr2(0, p, "ReaProject*") then
    reaper.SelectProjectInstance(p)
    reaper.Main_SaveProjectEx(p, D .. "/suggest_" .. k .. ".rpp", 8)
    reaper.Main_OnCommand(40860, 0)
  end
end
if front and reaper.ValidatePtr2(0, front, "ReaProject*") then reaper.SelectProjectInstance(front) end
return (fails == 0 and "ALL PASS" or (fails .. " FAILED")) .. "\n" .. table.concat(out, "\n")
