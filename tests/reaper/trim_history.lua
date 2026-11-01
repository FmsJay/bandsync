-- Run inside REAPER (ReaScript). History trim: after trimming every change nothing needs (a cutoff in the future),
-- a machine opening the song fresh still ends up with exactly the project, a major saved version's changes are all
-- still there, and the trimmed files are in the archive, not lost. Scratch tabs and folders only.
local D = reaper.GetResourcePath() .. "/BandSync/tests"
reaper.RecursiveCreateDirectory(D, 0)
local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/"
package.path = lib .. "?.lua;" .. package.path
for _, m in ipairs({ "band", "sync", "mirror", "recall", "trim", "json" }) do package.loaded[m] = nil end
local band, sync, mirror, recall, trim = require("band"), require("sync"), require("mirror"), require("recall"), require("trim")
local base = D .. "/troot_trim_" .. os.time() .. "/BandSync"
local song, room = "TrimLab", "main"
local A, B = { user = "James", root = base }, { user = "Mac", root = base }
local events = sync.room_dir(A, song, room) .. "/events"
reaper.RecursiveCreateDirectory(events, 0)
local yes = function() return true end
local out, fails = {}, 0
local function say(s) out[#out + 1] = s end
local function check(ok, what) if not ok then fails = fails + 1 end; say((ok and "PASS " or "FAIL ") .. what) end
local front = reaper.EnumProjects(-1)
reaper.Main_OnCommand(40859, 0); local pa = reaper.EnumProjects(-1)
local function send() repeat mirror.watch(pa, A, song, room, { can = yes, mode = "claims" }) until not mirror.more end
local pb
local ok, err = pcall(function()
  reaper.InsertTrackInProject(pa, 0, 0)
  local tr = reaper.GetTrack(pa, 0)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "Keys", true)
  local items = {}
  for k = 0, 4 do items[#items + 1] = reaper.CreateNewMIDIItemInProj(tr, k * 2, k * 2 + 1, false) end
  send()
  for step = 1, 3 do -- three rounds of moves: each item has a history of revisions
    for _, it in ipairs(items) do reaper.SetMediaItemInfo_Value(it, "D_POSITION", reaper.GetMediaItemInfo_Value(it, "D_POSITION") + 0.1) end
    send()
    if step == 2 then -- a major point, saved by hand, mid-history (a second apart either side: times are to the second)
      local t = reaper.time_precise(); while reaper.time_precise() - t < 1.2 do end
      recall.save(pa, A, song, room, "chorus idea")
      t = reaper.time_precise(); while reaper.time_precise() - t < 1.2 do end
    end
  end
  local before = #band.files(events, ".json")
  local root_a = mirror.root(pa)
  local n = trim.run(A, song, room, -1) -- (a cutoff tomorrow: everything not needed goes)
  local after = #band.files(events, ".json")
  say(string.format("events %d -> %d (%d trimmed)", before, after, n))
  check(n > 0 and after == before - n, "trimmed files left the events folder")
  local archive = base:match("^(.*)/[^/]+$") .. "/BandSync history archive/" .. song .. "/" .. room
  check(#band.files(archive, ".json") == n, "and every one is in the archive")
  local lists = band.files(sync.room_dir(A, song, room) .. "/trimmed", ".json")
  local listed = #lists == 1 and band.read_json(sync.room_dir(A, song, room) .. "/trimmed/" .. lists[1]) or {}
  check(#listed == n, "and listed for the band in trimmed/, so the Drive copy doesn't bring them back (" .. #listed .. ")")
  -- the newest change of each item, and the saved version's moment, are still there
  local pt = recall.list(A, song, room)[1]
  local kept_at = {}
  for _, f in ipairs(band.files(events, ".json")) do
    local ev = band.read_json(events .. "/" .. f)
    if ev and ev.type == "obj" and ev.time <= pt.time and (not kept_at[ev.oid] or ev.rev > kept_at[ev.oid]) then kept_at[ev.oid] = ev.rev end
  end
  local n_items = 0
  for _, it in ipairs(items) do if kept_at[mirror.item_oid(it)] then n_items = n_items + 1 end end
  check(n_items == #items, "the saved version still has each item's change at its moment (" .. n_items .. "/" .. #items .. ")")
  check(after == 1 + 2 * #items, "kept: the track, each item's newest, and each item's change at the saved version (" .. after .. ")")
  -- a machine opening the song fresh catches up from what's left: the same project
  reaper.Main_OnCommand(40859, 0); pb = reaper.EnumProjects(-1)
  reaper.SelectProjectInstance(pb)
  for _ = 1, 4 do sync.receive(pb, B, song, room, yes) end
  check(mirror.root(pb) == root_a, "a fresh machine ends up with the same project (" .. mirror.root(pb) .. " / " .. root_a .. ")")
  check(reaper.CountMediaItems(pb) == #items, "every item is there")
end)
if not ok then say("ERROR " .. tostring(err)); fails = fails + 1 end
for k, p in ipairs({ pa, pb }) do
  if p and reaper.ValidatePtr2(0, p, "ReaProject*") then
    reaper.SelectProjectInstance(p)
    reaper.Main_SaveProjectEx(p, D .. "/trim_history_" .. k .. ".rpp", 8)
    reaper.Main_OnCommand(40860, 0)
  end
end
if front and reaper.ValidatePtr2(0, front, "ReaProject*") then reaper.SelectProjectInstance(front) end
return (fails == 0 and "ALL PASS" or (fails .. " FAILED")) .. "\n" .. table.concat(out, "\n")
