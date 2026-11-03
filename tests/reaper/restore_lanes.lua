-- Run inside REAPER (ReaScript). Round 2's Restore findings (0.42.7): a whole-song Back and forward keeps a track's lane names on
-- both machines, tempo goes back from before the first tempo change, a claim survives the Back, collapsing lanes is nobody
-- else's business, and a pass on a lane nobody hears isn't printed until it plays.
-- Two scratch tabs, a scratch shared folder; both saved there and closed at the end.
local D = reaper.GetResourcePath() .. "/BandSync/tests"
local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/"
package.path = lib .. "?.lua;" .. package.path
for _, m in ipairs({ "band", "sync", "mirror", "recall", "prints", "plugins", "json" }) do package.loaded[m] = nil end
require("prints").SETTLE = 0
local band, sync, mirror, recall, prints = require("band"), require("sync"), require("mirror"), require("recall"), require("prints")
local root = D .. "/nroot_" .. os.time()
local song, room = "LaneLab", "main"
local A, B = { user = "Laptop", root = root }, { user = "James", root = root }
local events = sync.room_dir(A, song, room) .. "/events"
reaper.RecursiveCreateDirectory(events, 0)
local out, fails = {}, 0
local function say(s) out[#out + 1] = s end
local function check(ok, what) if not ok then fails = fails + 1 end; say((ok and "PASS " or "FAIL ") .. what) end
local yes = function() return true end
local front = reaper.EnumProjects(-1)
local was_bg = reaper.GetExtState(band.SECTION, "bg render")
reaper.SetExtState(band.SECTION, "bg render", "off", false)
reaper.Main_OnCommand(40859, 0); local pa = reaper.EnumProjects(-1)
reaper.Main_OnCommand(40859, 0); local pb = reaper.EnumProjects(-1)
local function sent(who)
  local n = 0
  for _, f in ipairs(band.files(events, ".json")) do if f:sub(1, #who + 1) == who .. "-" then n = n + 1 end end
  return n
end
local function watch(p, cfg) reaper.SelectProjectInstance(p); return (mirror.watch(p, cfg, song, room, { can = yes, mode = "claims", here = { Laptop = true, James = true } })) end
local function recv(p, cfg) reaper.SelectProjectInstance(p); for _ = 1, 3 do sync.receive(p, cfg, song, room, yes) end end
local function hold(s) local w = reaper.time_precise(); while reaper.time_precise() - w < s do end end
local function find(p, name)
  for i = 0, reaper.CountTracks(p) - 1 do
    local t = reaper.GetTrack(p, i)
    if select(2, reaper.GetTrackName(t)) == name then return t end
  end
end
local function lane_names(t)
  local n = {}
  for l = 0, reaper.GetMediaTrackInfo_Value(t, "I_NUMFIXEDLANES") - 1 do n[#n + 1] = select(2, reaper.GetSetMediaTrackInfo_String(t, "P_LANENAME:" .. l, "", false)) end
  return table.concat(n, ",")
end
local ok, err = pcall(function()
  reaper.SelectProjectInstance(pa)
  reaper.InsertTrackInProject(pa, 0, 0)
  local base = reaper.GetTrack(pa, 0)
  reaper.GetSetMediaTrackInfo_String(base, "P_NAME", "Older", true)
  watch(pa, A); hold(1.1)
  reaper.InsertTrackInProject(pa, 1, 0)
  local tr = reaper.GetTrack(pa, 1)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "Laned", true)
  reaper.SetMediaTrackInfo_Value(tr, "I_FREEMODE", 2)
  reaper.SetMediaTrackInfo_Value(tr, "I_NUMFIXEDLANES", 3)
  for l, name in ipairs({ "C1", "Take 1", "Take 2" }) do
    local it = reaper.AddMediaItemToTrack(tr)
    reaper.SetMediaItemInfo_Value(it, "D_POSITION", 0)
    reaper.SetMediaItemInfo_Value(it, "D_LENGTH", 2)
    reaper.SetMediaItemInfo_Value(it, "I_FIXEDLANE", l - 1)
    reaper.GetSetMediaItemInfo_String(it, "P_NOTES", "pass " .. l, true)
  end
  for l, name in ipairs({ "C1", "Take 1", "Take 2" }) do -- (a lane takes its name once it holds an item)
    reaper.GetSetMediaTrackInfo_String(tr, "P_LANENAME:" .. (l - 1), name, true)
    reaper.SetMediaTrackInfo_Value(tr, "C_LANEPLAYS:" .. (l - 1), l == 1 and 1 or 0)
  end
  watch(pa, A); watch(pa, A)
  recv(pb, B)
  local on_b = find(pb, "Laned")
  check(on_b and lane_names(on_b) == "C1,Take 1,Take 2", "the bandmate has the lanes, named: " .. (on_b and lane_names(on_b) or "no track"))

  -- collapsing lanes is a view: nothing goes out, and it's left alone
  local n = sent("James")
  reaper.SelectProjectInstance(pb)
  reaper.SetMediaTrackInfo_Value(on_b, "C_LANESCOLLAPSED", 1)
  watch(pb, B); watch(pb, B)
  check(sent("James") == n, "collapsing lanes sends nothing")
  check(reaper.GetMediaTrackInfo_Value(on_b, "C_LANESCOLLAPSED") == 1, "and stays collapsed here")
  reaper.SetMediaTrackInfo_Value(on_b, "C_LANESCOLLAPSED", 0)

  -- a claim waits out the Back
  check(sync.GONE_WAIT >= 300, "a claim on a missing track waits minutes, not seconds")

  -- the whole song back to before the track, and forward again
  hold(1.1)
  reaper.SelectProjectInstance(pa)
  local es, oid = recall.entries(A, song, room), mirror.track_oid(tr)
  local upto = 0
  for i, e in ipairs(es) do if e.kind == "obj" and e.oid == oid then upto = i - 1; break end end
  check(upto > 0, "there's a version from before it")
  mirror.revert(pa, A, song, room, mirror.plan_restore(es, upto), { can = yes, mode = "claims" })
  recv(pb, B)
  check(find(pa, "Laned") == nil and find(pb, "Laned") == nil, "going back takes it on both")
  hold(1.1)
  reaper.SelectProjectInstance(pa)
  es = recall.entries(A, song, room)
  local before
  for i, e in ipairs(es) do if e.kind == "obj" and e.gone then before = i - 1; break end end
  mirror.revert(pa, A, song, room, mirror.plan_restore(es, before), { can = yes, mode = "claims" })
  for _ = 1, 3 do watch(pa, A) end
  recv(pb, B)
  for _ = 1, 3 do watch(pb, B); recv(pa, A); recv(pb, B) end
  local ta, tb = find(pa, "Laned"), find(pb, "Laned")
  check(ta and lane_names(ta) == "C1,Take 1,Take 2", "forward: the lanes keep their names here: " .. (ta and lane_names(ta) or "no track"))
  check(tb and lane_names(tb) == "C1,Take 1,Take 2", "and on the bandmate's: " .. (tb and lane_names(tb) or "no track"))
  check(ta and reaper.CountTrackMediaItems(ta) == 3, "with its passes")
  check(ta and reaper.GetMediaTrackInfo_Value(ta, "C_LANEPLAYS:0") > 0 and reaper.GetMediaTrackInfo_Value(ta, "C_LANEPLAYS:1") == 0, "and the same lane plays")

  -- tempo from before its first change: the session's first map, not its newest
  reaper.SelectProjectInstance(pa)
  local first = band.capture_tempo(pa)
  reaper.SetCurrentBPM(pa, 77, false)
  local now = band.capture_tempo(pa)
  check(sync.restore_timeline(pa, A, song, room, {}, 0, { tempo = now, first_timeline = { tempo = first } }), "Back from before any tempo change restores the first map")
  check(math.abs(reaper.TimeMap2_GetDividedBpmAtTime(pa, 0) - 77) > 1, "the tempo's back")
  -- a side room's history starts where it was made: the song's first map isn't what it had (Mac, 0.45.0)
  do
    local side = sync.room_dir(A, song, "Side")
    reaper.RecursiveCreateDirectory(side .. "/events", 0)
    reaper.SetCurrentBPM(pa, 77, false)
    local made = band.capture_tempo(pa)
    band.write_json(side .. "/room.json", { parent = "main", by = "Laptop" })
    check(not sync.restore_timeline(pa, A, song, "Side", {}, 0, { first_timeline = { tempo = first } }), "a side room with no record of its tempo leaves it alone")
    check(math.abs(reaper.TimeMap2_GetDividedBpmAtTime(pa, 0) - 77) < 0.01, "at what it has")
    reaper.SetCurrentBPM(pa, 88, false)
    band.write_json(side .. "/room.json", { parent = "main", by = "Laptop", tempo = made, markers = {} })
    check(sync.restore_timeline(pa, A, song, "Side", {}, 0, { first_timeline = { tempo = first } }), "with a record, it goes back to what the room started with")
    check(math.abs(reaper.TimeMap2_GetDividedBpmAtTime(pa, 0) - 77) < 0.01, "not the song's first: " .. reaper.TimeMap2_GetDividedBpmAtTime(pa, 0))
    check(sync.restore_timeline(pa, A, song, "New", {}, 0, { first_timeline = { tempo = first } }, "main"), "a new room from a moment in main goes by main's history")
    check(math.abs(reaper.TimeMap2_GetDividedBpmAtTime(pa, 0) - 77) > 1, "before main's first change: the song's first map")
  end

  -- fewer lanes than its items sit on: the count holds, and nothing reads as lane 255
  reaper.SelectProjectInstance(pa)
  local st = { name = "Laned", lanes = 1, freemode = 2, plays = "1", lanenames = "C1" }
  mirror.set_track_state(pa, ta, st, false)
  check(reaper.GetMediaTrackInfo_Value(ta, "I_NUMFIXEDLANES") == 3, "a track keeps the lanes its items sit on (" .. reaper.GetMediaTrackInfo_Value(ta, "I_NUMFIXEDLANES") .. ")")
  local worst = 0
  for i = 0, reaper.CountTrackMediaItems(ta) - 1 do worst = math.max(worst, reaper.GetMediaItemInfo_Value(reaper.GetTrackMediaItem(ta, i), "I_FIXEDLANE")) end
  check(worst <= 2, "and they stay on them (" .. worst .. ")")
  mirror.set_track_state(pa, ta, band.json_decode(band.json_encode(mirror.track_state(pa, ta, false))), false)
  for i = 0, 2 do reaper.GetSetMediaTrackInfo_String(ta, "P_LANENAME:" .. i, ({ "C1", "Take 1", "Take 2" })[i + 1], true); reaper.SetMediaTrackInfo_Value(ta, "C_LANEPLAYS:" .. i, i == 0 and 1 or 0) end
  for _ = 1, 3 do watch(pa, A); recv(pb, B); watch(pb, B); recv(pa, A) end

  -- a new lane changes the track, not every item on it
  local items_sent = function()
    local n = 0
    for _, f in ipairs(band.files(events, ".json")) do
      local e = band.read_json(events .. "/" .. f)
      if e and e.obj == "item" then n = n + 1 end
    end
    return n
  end
  local before_lane = items_sent()
  reaper.SelectProjectInstance(pa)
  reaper.SetMediaTrackInfo_Value(ta, "I_NUMFIXEDLANES", 4)
  reaper.GetSetMediaTrackInfo_String(ta, "P_LANENAME:3", "Take 3", true)
  for _ = 1, 3 do watch(pa, A); recv(pb, B); watch(pb, B); recv(pa, A) end
  check(items_sent() == before_lane, "adding a lane sends no item (" .. (items_sent() - before_lane) .. ")")
  check(mirror.clean_lane(255, 4) == 0 and mirror.clean_lane(9, 4) == 3 and mirror.clean_lane(2, 4) == 2, "a lane number that makes no sense isn't sent")

  -- a comp on a track in lanes: a take from an old version with three prints, and the part it was played over
  reaper.SelectProjectInstance(pa)
  reaper.InsertTrackInProject(pa, 2, 0)
  local cp = reaper.GetTrack(pa, 2)
  reaper.GetSetMediaTrackInfo_String(cp, "P_NAME", "Comped", true)
  reaper.SetMediaTrackInfo_Value(cp, "I_FREEMODE", 2)
  reaper.SetMediaTrackInfo_Value(cp, "I_NUMFIXEDLANES", 2)
  local function part(at, name, wet_too)
    local x = reaper.AddMediaItemToTrack(cp)
    reaper.SetMediaItemInfo_Value(x, "D_POSITION", at); reaper.SetMediaItemInfo_Value(x, "D_LENGTH", 2)
    for k = 1, wet_too do
      reaper.GetSetMediaItemTakeInfo_String(reaper.AddTakeToMediaItem(x), "P_NAME", name .. " dry " .. k, true)
      local w = reaper.AddTakeToMediaItem(x)
      reaper.GetSetMediaItemTakeInfo_String(w, "P_NAME", name .. " wet " .. k, true)
      reaper.GetSetMediaItemTakeInfo_String(w, "P_EXT:" .. prints.KEY, "key" .. k, true)
    end
    return x
  end
  local under, spare = part(50, "under", 1), part(70, "elsewhere", 1)
  local over = part(50, "over", 3)
  reaper.SetMediaItemInfo_Value(part(100, "pass", 1), "I_FIXEDLANE", 1) -- (a lane exists once it holds an item)
  reaper.SetMediaTrackInfo_Value(cp, "C_LANEPLAYS:0", 1)
  reaper.SetMediaTrackInfo_Value(cp, "C_LANEPLAYS:1", 0)
  prints.takes_to_lanes(pa, function() return true end)
  local count, wet_left, names = reaper.CountTrackMediaItems(cp), 0, {}
  for i = 0, count - 1 do
    local x = reaper.GetTrackMediaItem(cp, i)
    for k = 0, reaper.CountTakes(x) - 1 do names[#names + 1] = select(2, reaper.GetSetMediaItemTakeInfo_String(reaper.GetTake(x, k), "P_NAME", "", false)) end
  end
  table.sort(names)
  local joined = table.concat(names, ",")
  check(count == 6 and not joined:find("over wet", 1, true), "three real passes make three parts, none of them a print: " .. joined)
  check(reaper.GetMediaItemInfo_Value(over, "I_FIXEDLANE") == 0, "the part played stays on the playing lane")
  check(reaper.GetMediaItemInfo_Value(under, "I_FIXEDLANE") ~= 0, "the part it was played over moves out of the way")
  check(reaper.GetMediaItemInfo_Value(spare, "I_FIXEDLANE") == 0, "one elsewhere on the lane stays")
  check(select(2, prints.takes(spare)) ~= nil, "and keeps its print")
  reaper.DeleteTrack(cp)

  -- tracks whose saved places point at each other: each goes out once
  do
    reaper.SelectProjectInstance(pa)
    local function new_track(name)
      reaper.InsertTrackInProject(pa, reaper.CountTracks(pa), 0)
      local x = reaper.GetTrack(pa, reaper.CountTracks(pa) - 1)
      reaper.GetSetMediaTrackInfo_String(x, "P_NAME", name, true)
      return x
    end
    local r1, r2 = new_track("Ring 1"), new_track("Ring 2")
    hold(1.1)
    for _ = 1, 3 do watch(pa, A) end
    local o1, o2 = mirror.track_oid(r1), mirror.track_oid(r2)
    local function newest(oid)
      local best
      for _, e in ipairs(recall.entries(A, song, room)) do if e.oid == oid and e.obj == "track" then best = e end end
      return best
    end
    local e1, e2 = band.json_decode(band.json_encode(newest(o1))), band.json_decode(band.json_encode(newest(o2)))
    e1.state.after, e2.state.after = o2, o1
    e1.state.name, e2.state.name = "Ring A", "Ring B"
    e1.id, e2.id = "ring-1", "ring-2"
    mirror.revert(pa, A, song, room, { [o1] = e1, [o2] = e2 }, { can = yes, mode = "claims" })
    local n1, n2 = 0, 0
    for _, e in ipairs(recall.entries(A, song, room)) do
      if e.restored == "ring-1" then n1 = n1 + 1 elseif e.restored == "ring-2" then n2 = n2 + 1 end
    end
    check(n1 == 1 and n2 == 1, string.format("a ring of tracks goes out once each (%d, %d)", n1, n2))
    reaper.DeleteTrack(r1); reaper.DeleteTrack(r2)
    for _ = 1, 3 do watch(pa, A) end
  end

  -- behind the band: takes wait to become lanes until it has caught up (an old file reopened sent its old comps)
  do
    reaper.SelectProjectInstance(pb)
    reaper.InsertTrackInProject(pb, reaper.CountTracks(pb), 0)
    local late = reaper.GetTrack(pb, reaper.CountTracks(pb) - 1)
    reaper.GetSetMediaTrackInfo_String(late, "P_NAME", "Late", true)
    local two = reaper.AddMediaItemToTrack(late)
    reaper.SetMediaItemInfo_Value(two, "D_LENGTH", 2)
    reaper.GetSetMediaItemTakeInfo_String(reaper.AddTakeToMediaItem(two), "P_NAME", "pass 1", true)
    reaper.GetSetMediaItemTakeInfo_String(reaper.AddTakeToMediaItem(two), "P_NAME", "pass 2", true)
    reaper.SelectProjectInstance(pa)
    reaper.SetMediaTrackInfo_Value(reaper.GetTrack(pa, 0), "B_MUTE", 1)
    watch(pa, A); watch(pa, A)
    check(sync.pending_events(pb, B, song, room) > 0, "the bandmate is behind")
    watch(pb, B)
    check(reaper.CountTakes(two) == 2, "and its takes wait")
    recv(pb, B)
    check(sync.pending_events(pb, B, song, room) == 0, "caught up")
    for _ = 1, 6 do watch(pb, B); hold(0.1) end
    check(reaper.CountTrackMediaItems(late) >= 2 and reaper.GetMediaTrackInfo_Value(late, "I_NUMFIXEDLANES") > 1, "then they become lanes (" .. reaper.CountTrackMediaItems(late) .. " items)")
    reaper.SelectProjectInstance(pb)
    reaper.DeleteTrack(late)
    for _ = 1, 2 do watch(pb, B) end
    reaper.SelectProjectInstance(pa)
    reaper.SetMediaTrackInfo_Value(reaper.GetTrack(pa, 0), "B_MUTE", 0)
    for _ = 1, 3 do watch(pa, A); recv(pb, B); recv(pa, A) end
  end

  -- a track added at the end: only it goes out, though others sit in a different place here than the band's
  do
    for _ = 1, 3 do recv(pb, B); recv(pa, A) end
    reaper.SelectProjectInstance(pb)
    local x = reaper.GetTrack(pb, reaper.CountTracks(pb) - 1)
    reaper.SetOnlyTrackSelected(x)
    check(reaper.ReorderSelectedTracks(0, 0), "the bandmate's list is in another order")
    mirror.order_band[tostring(pb)] = true -- (as if it landed that way)
    for _ = 1, 3 do watch(pb, B) end
    local before = sent("James")
    reaper.InsertTrackInProject(pb, reaper.CountTracks(pb), 0)
    local added = reaper.GetTrack(pb, reaper.CountTracks(pb) - 1)
    reaper.GetSetMediaTrackInfo_String(added, "P_NAME", "Added", true)
    watch(pb, B); watch(pb, B)
    check(sent("James") - before == 1, "adding a track sends that track, not the others (" .. (sent("James") - before) .. ")")
    local list = {}
    for i = 0, reaper.CountTracks(pb) - 1 do list[#list + 1] = select(2, reaper.GetTrackName(reaper.GetTrack(pb, i))) end
    check(reaper.GetTrack(pb, 0) == x, "and nothing was moved back: " .. table.concat(list, ", ") .. " (moved: " .. select(2, reaper.GetTrackName(x)) .. ")")
    -- a track Back restored carries no hash: its place differing here isn't a change either
    local xo, newest_x = mirror.track_oid(x), nil
    for _, e in ipairs(recall.entries(A, song, room)) do if e.oid == xo and e.obj == "track" and not e.gone then newest_x = e end end
    reaper.SelectProjectInstance(pa)
    mirror.revert(pa, A, song, room, { [xo] = newest_x }, { can = yes, mode = "claims" })
    recv(pb, B)
    reaper.SelectProjectInstance(pb)
    reaper.SetOnlyTrackSelected(x)
    reaper.ReorderSelectedTracks(0, 0)
    mirror.order_band[tostring(pb)] = true
    local before_alias = sent("James")
    for _ = 1, 3 do watch(pb, B) end
    check(sent("James") == before_alias, "a restored track in another place here sends nothing (" .. (sent("James") - before_alias) .. ")")
    reaper.SelectProjectInstance(pb)
    reaper.DeleteTrack(added)
    reaper.SetOnlyTrackSelected(x)
    reaper.ReorderSelectedTracks(reaper.CountTracks(pb), 0)
    for _ = 1, 3 do watch(pb, B); recv(pa, A); recv(pb, B) end
  end

  -- forward takes back what going back revived: a bandmate's delete between the two isn't undone for good
  do
    reaper.SelectProjectInstance(pb)
    reaper.InsertTrackInProject(pb, reaper.CountTracks(pb), 0)
    local th = reaper.GetTrack(pb, reaper.CountTracks(pb) - 1)
    reaper.GetSetMediaTrackInfo_String(th, "P_NAME", "Theirs", true)
    local gone_it = reaper.AddMediaItemToTrack(th)
    reaper.SetMediaItemInfo_Value(gone_it, "D_LENGTH", 2)
    for _ = 1, 3 do watch(pb, B) end
    recv(pa, A)
    local tho, ioid = mirror.track_oid(th), mirror.item_oid(gone_it)
    hold(1.1)
    reaper.SelectProjectInstance(pb)
    reaper.DeleteTrackMediaItem(th, gone_it)
    for _ = 1, 3 do watch(pb, B) end
    recv(pa, A)
    check(mirror.find(pa, "item", ioid) == nil, "the bandmate deleted it, and it's gone here")
    hold(1.1)
    local only = function(oid) return oid == ioid end
    reaper.SelectProjectInstance(pa)
    local es1 = recall.entries(A, song, room)
    local gone_at
    for i, e in ipairs(es1) do if e.oid == ioid and e.gone then gone_at = i end end
    mirror.revert(pa, A, song, room, mirror.plan_restore(es1, gone_at - 1, only), { can = yes, mode = "claims" })
    check(mirror.find(pa, "item", ioid) ~= nil, "going back revives it")
    recv(pb, B)
    check(mirror.find(pb, "item", ioid) ~= nil, "for the bandmate too")
    hold(1.1)
    reaper.SelectProjectInstance(pa)
    mirror.revert(pa, A, song, room, mirror.plan_restore(es1, #es1, only), { can = yes, mode = "claims" })
    check(mirror.find(pa, "item", ioid) == nil, "forward takes it away again")
    recv(pb, B)
    check(mirror.find(pb, "item", ioid) == nil, "for the bandmate too")
    reaper.SelectProjectInstance(pb)
    reaper.DeleteTrack(mirror.find(pb, "track", tho))
    for _ = 1, 3 do watch(pb, B); recv(pa, A) end
  end

  -- a pass that feeds a comp: deleting it takes the comp piece too, as two rows. Undoing the pass, REAPER rebuilds the piece as a new
  -- item; the leftover comp row then has nothing to add, where it played a second copy on top (Mac 0.42.27)
  do
    reaper.SelectProjectInstance(pa)
    reaper.InsertTrackInProject(pa, reaper.CountTracks(pa), 0)
    local lab = reaper.GetTrack(pa, reaper.CountTracks(pa) - 1)
    reaper.GetSetMediaTrackInfo_String(lab, "P_NAME", "Comp Lab", true)
    local whole = reaper.CreateNewMIDIItemInProj(lab, 30, 50, false)
    reaper.GetSetMediaItemTakeInfo_String(reaper.GetActiveTake(whole), "P_NAME", "pass 1", true)
    for k = 2, 3 do reaper.GetSetMediaItemTakeInfo_String(reaper.AddTakeToMediaItem(whole), "P_NAME", "pass " .. k, true) end
    local mid = reaper.SplitMediaItem(whole, 36)
    local tail = reaper.SplitMediaItem(mid, 44)
    reaper.SetActiveTake(reaper.GetTake(whole, 0)); reaper.SetActiveTake(reaper.GetTake(mid, 1)); reaper.SetActiveTake(reaper.GetTake(tail, 2))
    reaper.SetOnlyTrackSelected(lab)
    reaper.Main_OnCommand(42636, 0) -- (takes to lanes, with comp areas: the same link a comp made by hand has)
    for _ = 1, 4 do watch(pa, A); hold(0.2) end
    recv(pb, B)
    local on_lane = function(p, lane, at)
      local t, n = find(p, "Comp Lab"), 0
      for i = 0, reaper.CountTrackMediaItems(t) - 1 do
        local x = reaper.GetTrackMediaItem(t, i)
        if reaper.GetMediaItemInfo_Value(x, "I_FIXEDLANE") == lane and reaper.GetMediaItemInfo_Value(x, "D_POSITION") == at then n = n + 1 end
      end
      return n
    end
    local sorted = function()
      local es = recall.entries(A, song, room)
      table.sort(es, function(a, x) return (a.time .. a.id) < (x.time .. x.id) end)
      return es
    end
    check(on_lane(pa, 0, 36) == 1 and on_lane(pa, 2, 36) == 1, "a comp: the piece on C1, its pass on lane 2")
    hold(1.2)
    reaper.SelectProjectInstance(pa)
    reaper.SelectAllMediaItems(pa, false)
    for i = 0, reaper.CountTrackMediaItems(lab) - 1 do
      local x = reaper.GetTrackMediaItem(lab, i)
      if reaper.GetMediaItemInfo_Value(x, "I_FIXEDLANE") == 2 and reaper.GetMediaItemInfo_Value(x, "D_POSITION") == 36 then reaper.SetMediaItemSelected(x, true) end
    end
    reaper.Main_OnCommand(40006, 0)
    for _ = 1, 3 do watch(pa, A); hold(0.2) end
    recv(pb, B)
    check(on_lane(pa, 0, 36) == 0 and on_lane(pa, 2, 36) == 0, "deleting the pass takes its comp piece")
    local es = sorted()
    local pass_row, comp_row
    for i = #es, 1, -1 do
      if es[i].gone and es[i].obj == "item" and not pass_row or (es[i].gone and es[i].obj == "item" and not comp_row) then
        local l = mirror.entry_lane(es, i)
        if l == 0 and not comp_row then comp_row = i elseif l == 2 and not pass_row then pass_row = i end
      end
    end
    check(pass_row and comp_row, "as two rows")
    hold(1.2)
    reaper.SelectProjectInstance(pa)
    mirror.revert(pa, A, song, room, mirror.plan_undo_moment(es, pass_row), { can = yes, mode = "claims" })
    for _ = 1, 4 do watch(pa, A); hold(0.6) end
    recv(pb, B)
    check(on_lane(pa, 2, 36) == 1 and on_lane(pa, 0, 36) == 1, "undoing the pass brings back both")
    hold(1.2)
    reaper.SelectProjectInstance(pa)
    local said = mirror.revert(pa, A, song, room, mirror.plan_undo_moment(sorted(), comp_row), { can = yes, mode = "claims" })
    for _ = 1, 4 do watch(pa, A); hold(0.3) end
    recv(pb, B)
    check(on_lane(pa, 0, 36) == 1 and on_lane(pb, 0, 36) == 1, "undoing the leftover comp row adds no second copy: " .. tostring(said))
    reaper.SelectProjectInstance(pa)
    reaper.DeleteTrack(lab)
    for _ = 1, 3 do watch(pa, A); recv(pb, B); recv(pa, A) end
  end

  -- only what plays is printed
  reaper.SelectProjectInstance(pa)
  reaper.TrackFX_AddByName(ta, "ReaSynth", false, -1)
  local midi = {}
  for l = 0, 1 do
    local it = reaper.CreateNewMIDIItemInProj(ta, 4, 5, false)
    reaper.SetMediaItemInfo_Value(it, "I_FIXEDLANE", l)
    reaper.MIDI_InsertNote(reaper.GetActiveTake(it), false, false, 0, 400, 0, 60, 100, false)
    midi[l] = it
  end
  local function has_print(it) return select(2, prints.takes(it)) ~= nil end
  local media = sync.room_dir(A, song, room) .. "/media"
  check(prints.refresh(pa, midi[1], media, "x", "", A) == false and not has_print(midi[1]), "a pass on a lane nobody hears isn't printed")
  reaper.SetMediaTrackInfo_Value(ta, "C_LANEPLAYS:1", 1)
  local did = prints.refresh(pa, midi[1], media, "x", "", A)
  check(did ~= false and has_print(midi[1]), "and is once it plays")
end)
if not ok then fails = fails + 1; say("ERROR " .. tostring(err)) end
reaper.SetExtState(band.SECTION, "bg render", was_bg, false)
for _, p in ipairs({ pb, pa }) do
  reaper.SelectProjectInstance(p)
  reaper.Main_SaveProjectEx(p, root .. "/" .. tostring(p):gsub("%W", "") .. ".rpp", 8)
  reaper.Main_OnCommand(40860, 0)
end
reaper.SelectProjectInstance(front)
say(fails == 0 and "ALL PASS" or (fails .. " FAILED"))
return table.concat(out, "\n")
