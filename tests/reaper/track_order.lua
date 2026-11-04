-- Run inside REAPER (ReaScript). Track order (0.56): the newest list anyone published is the studio's, and every computer comes onto it
-- when its tab is in front, sending nothing. And a big restore goes in slices with one undo point (a 415-change one held REAPER 6.9 s).
-- Two scratch tabs, a scratch shared folder; both tabs saved there and closed at the end.
local D = reaper.GetResourcePath() .. "/StudioSync/tests"
reaper.RecursiveCreateDirectory(D, 0)
local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/"
package.path = lib .. "?.lua;" .. package.path
for _, m in ipairs({ "band", "sync", "mirror", "recall", "json" }) do package.loaded[m] = nil end
local band, sync, mirror, recall = require("band"), require("sync"), require("mirror"), require("recall")
local root = D .. "/oroot_" .. os.time()
local song, room = "OrderLab", "main"
local A, B = { user = "Laptop", root = root }, { user = "Mac", root = root }
local room_dir = sync.room_dir(A, song, room)
local events = room_dir .. "/events"
reaper.RecursiveCreateDirectory(events, 0)
local yes = function() return true end
local out, fails = {}, 0
local function say(s) out[#out + 1] = s end
local function check(ok, what) if not ok then fails = fails + 1 end; say((ok and "PASS " or "FAIL ") .. what) end
local function hold(s) local t = reaper.time_precise(); while reaper.time_precise() - t < s do end end
local function sent(who) local n = 0; for _, f in ipairs(band.files(events, ".json")) do if f:sub(1, #who + 1) == who .. "-" then n = n + 1 end end; return n end
local front = reaper.EnumProjects(-1)
reaper.Main_OnCommand(40859, 0); local pa = reaper.EnumProjects(-1)
reaper.Main_OnCommand(40859, 0); local pb = reaper.EnumProjects(-1)
local function watch(p, cfg)
  reaper.SelectProjectInstance(p)
  repeat mirror.watch(p, cfg, song, room, { can = yes, mode = "claims" }) until not mirror.more
end
local function recv(p, cfg) reaper.SelectProjectInstance(p); for _ = 1, 6 do sync.receive(p, cfg, song, room, yes) end end
local function names(p)
  local t = {}
  for i = 0, reaper.CountTracks(p) - 1 do t[#t + 1] = select(2, reaper.GetTrackName(reaper.GetTrack(p, i))) end
  return table.concat(t, " ")
end
local function add(p, at, name)
  reaper.InsertTrackInProject(p, at, 0)
  local tr = reaper.GetTrack(p, at)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", name, true)
  return tr
end
local function move_to(p, name, before)
  reaper.SelectProjectInstance(p)
  for i = 0, reaper.CountTracks(p) - 1 do
    local tr = reaper.GetTrack(p, i)
    if select(2, reaper.GetTrackName(tr)) == name then reaper.SetOnlyTrackSelected(tr); break end
  end
  reaper.ReorderSelectedTracks(before, 0)
  reaper.Main_OnCommand(40297, 0) -- (none selected: the way a person's next move starts)
end
local real_defer, real_log = reaper.defer, band.log
local ok, err = pcall(function()
  reaper.SelectProjectInstance(pa)
  for i, n in ipairs({ "W", "X", "Y", "Z" }) do add(pa, i - 1, n) end
  watch(pa, A)
  recv(pb, B); watch(pb, B)
  check(names(pb) == "W X Y Z", "the tracks arrive in order (" .. names(pb) .. ")")
  local base = sent("Laptop") + sent("Mac")
  -- nobody's said yet: whoever looks first has the list
  reaper.SelectProjectInstance(pa)
  check(mirror.keep_order(pa, A, song, room) == 0 and mirror.read_order(room_dir) ~= nil, "the first to look publishes where everyone starts")
  -- B moves one, with A's tab behind: the old way that never landed
  hold(1.1)
  watch(pb, B) -- (seen as it is before the move)
  move_to(pb, "Z", 1)
  watch(pb, B)
  check(names(pb) == "W Z X Y", "B moved it (" .. names(pb) .. ")")
  check(mirror.read_order(room_dir).by == "Mac", "and published the list")
  reaper.SelectProjectInstance(pb)
  sync.receive(pa, A, song, room, yes)
  check(names(pa) == "W X Y Z", "A's tab behind stays put")
  reaper.SelectProjectInstance(pa)
  for _ = 1, 4 do sync.receive(pa, A, song, room, yes) end
  mirror.keep_order(pa, A, song, room)
  check(names(pa) == "W Z X Y", "with its tab in front it comes onto the list (" .. names(pa) .. ")")
  check(mirror.keep_order(pa, A, song, room) == 0, "and once there, nothing moves")
  local n = sent("Laptop")
  watch(pa, A)
  check(sent("Laptop") == n, "coming onto it sends nothing (" .. (sent("Laptop") - n) .. ")")
  -- a track that's newer than the list goes under the one it sat under
  reaper.SelectProjectInstance(pa)
  add(pa, 2, "New")
  watch(pa, A)
  check(names(pa) == "W Z New X Y", "A adds one under Z (" .. names(pa) .. ")")
  recv(pb, B)
  mirror.keep_order(pb, B, song, room)
  check(names(pb) == "W Z New X Y", "it lands under Z on B, though it's not on the list (" .. names(pb) .. ")")
  watch(pb, B)
  -- orders that have already drifted come back on their own
  hold(1.1)
  reaper.SelectProjectInstance(pb)
  mirror.order_seen[tostring(pb)] = nil -- (as if this is how the project opened, so it isn't a move)
  move_to(pb, "Y", 0)
  mirror.keep_order(pb, B, song, room)
  check(names(pb) == "W Z New X Y", "a computer that's out of step comes back (" .. names(pb) .. ")")
  watch(pb, B)
  -- going back puts the order as it was then, for everyone
  hold(1.1)
  local es = recall.entries(A, song, room)
  local upto = #es
  watch(pa, A)
  move_to(pa, "W", 3)
  watch(pa, A)
  check(names(pa):find("^Z New W") ~= nil, "A moves W down (" .. names(pa) .. ")")
  hold(1.1)
  es = recall.entries(A, song, room)
  reaper.SelectProjectInstance(pa)
  mirror.revert(pa, A, song, room, mirror.plan_restore(es, upto), { can = yes, mode = "claims" })
  check(mirror.read_order(room_dir).by == "Laptop", "going back publishes the order it brought back")
  mirror.keep_order(pa, A, song, room)
  say("after going back: " .. names(pa))
  -- a big restore: in slices, one undo point, everything back
  reaper.SelectProjectInstance(pa)
  local tr = reaper.GetTrack(pa, 0)
  for i = 1, 140 do
    local it = reaper.AddMediaItemToTrack(tr)
    reaper.SetMediaItemInfo_Value(it, "D_POSITION", i * 2)
    reaper.SetMediaItemInfo_Value(it, "D_LENGTH", 1)
  end
  watch(pa, A)
  hold(1.1)
  es = recall.entries(A, song, room)
  local before_move = #es
  for i = reaper.CountTrackMediaItems(tr) - 1, 0, -1 do -- (from the end: a moved item goes to the end of the track's list)
    local it = reaper.GetTrackMediaItem(tr, i)
    reaper.SetMediaItemInfo_Value(it, "D_POSITION", reaper.GetMediaItemInfo_Value(it, "D_POSITION") + 500)
  end
  watch(pa, A)
  hold(1.1)
  es = recall.entries(A, song, room)
  local plan = mirror.plan_restore(es, before_move)
  local count = 0
  for _ in pairs(plan) do count = count + 1 end
  check(count > mirror.REVERT_AT_ONCE, "the restore is a big one (" .. count .. ")")
  local logged
  band.log = function(t) logged = t end
  reaper.defer = function() end -- (stepped by hand below)
  mirror.revert_slice = nil
  local at_start = mirror.revert(pa, A, song, room, plan, { can = yes, mode = "claims" })
  check(at_start:find("keeps working", 1, true) ~= nil, "it says so and returns (" .. at_start .. ")")
  local worst, steps = 0, 0
  while not logged and steps < 400 do
    local t = reaper.time_precise()
    mirror.revert_slice()
    worst, steps = math.max(worst, reaper.time_precise() - t), steps + 1
  end
  band.log, reaper.defer = real_log, real_defer
  say(string.format("%d slices, the longest %.3f s: %s", steps, worst, tostring(logged)))
  check(logged ~= nil and steps > 1, "it took more than one pass")
  check(worst < 0.5, string.format("and no pass held REAPER long (%.3f s)", worst))
  local far = 0
  for i = 0, reaper.CountTrackMediaItems(tr) - 1 do
    if reaper.GetMediaItemInfo_Value(reaper.GetTrackMediaItem(tr, i), "D_POSITION") >= 500 then far = far + 1 end
  end
  check(far == 0, "everything came back (" .. far .. " still moved)")
  check(reaper.CountTrackMediaItems(tr) == 140, "and nothing went missing (" .. reaper.CountTrackMediaItems(tr) .. " of 140)")
  check(reaper.Undo_CanUndo2(pa) == "StudioSync: go back", "one undo point for the lot (" .. tostring(reaper.Undo_CanUndo2(pa)) .. ")")
  local n2 = sent("Laptop")
  watch(pa, A)
  check(sent("Laptop") == n2, "and the next look finds nothing new to send (" .. (sent("Laptop") - n2) .. ")")
end)
band.log, reaper.defer = real_log, real_defer
if not ok then say("ERROR " .. tostring(err)); fails = fails + 1 end
for k, p in ipairs({ pa, pb }) do
  if reaper.ValidatePtr2(0, p, "ReaProject*") then
    reaper.SelectProjectInstance(p)
    reaper.Main_SaveProjectEx(p, D .. "/track_order_" .. k .. ".rpp", 8)
    reaper.Main_OnCommand(40860, 0)
  end
end
if front and reaper.ValidatePtr2(0, front, "ReaProject*") then reaper.SelectProjectInstance(front) end
return (fails == 0 and "ALL PASS" or (fails .. " FAILED")) .. "\n" .. table.concat(out, "\n")
