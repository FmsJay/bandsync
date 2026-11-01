-- Run inside REAPER (ReaScript). A burst of changes with background prints (0.41): a part waits until it has held still;
-- a part being edited doesn't hold up the others; whichever changed longest ago goes first; several render at once; a
-- job for a version that's gone is ended; going back to a printed state doesn't wait; every part ends on the print of
-- its newest notes. One scratch tab, a scratch shared folder; saved there and closed at the end.
local D = reaper.GetResourcePath() .. "/BandSync/tests"
local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/"
package.path = lib .. "?.lua;" .. package.path
for _, m in ipairs({ "band", "sync", "mirror", "prints", "plugins", "json", "bgrender" }) do package.loaded[m] = nil end
local band, sync, mirror, prints, bg = require("band"), require("sync"), require("mirror"), require("prints"), require("bgrender")
local root = D .. "/broot_" .. os.time()
local song, room = "BurstLab", "main"
local A = { user = "Laptop", root = root }
local media = sync.room_dir(A, song, room) .. "/media"
reaper.RecursiveCreateDirectory(sync.room_dir(A, song, room) .. "/events", 0)
local out, fails = {}, 0
local function say(s) out[#out + 1] = s end
local function check(ok, what) if not ok then fails = fails + 1 end; say((ok and "PASS " or "FAIL ") .. what) end
local yes = function() return true end
local front = reaper.EnumProjects(-1)
local was_bg = reaper.GetExtState(band.SECTION, "bg render")
reaper.SetExtState(band.SECTION, "bg render", "on", false)
reaper.Main_OnCommand(40859, 0); local pa = reaper.EnumProjects(-1)
sync.driver_name = "Laptop"
local function watch() mirror.watch(pa, A, song, room, { can = yes, mode = "claims", here = { Laptop = true } }) end
local function hold(s) local w = reaper.time_precise(); while reaper.time_precise() - w < s do end end
local function pkey(it)
  local _, p = prints.takes(it)
  return p and select(2, reaper.GetSetMediaItemTakeInfo_String(p, "P_EXT:" .. prints.KEY, "", false)) or ""
end
local function pfile(it)
  local _, p = prints.takes(it)
  return p and reaper.GetMediaSourceFileName(reaper.GetMediaItemTake_Source(p), "") or ""
end
local function nudge(it, pitch)
  local tk = prints.takes(it)
  local _, _, m, a, b, c, _, v = reaper.MIDI_GetNote(tk, 0)
  reaper.MIDI_SetNote(tk, 0, false, m, a, b, c, pitch, v, false)
end
local ok, err = pcall(function()
  reaper.SelectProjectInstance(pa)
  reaper.InsertTrackInProject(pa, 0, 0)
  local tr = reaper.GetTrack(pa, 0)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "Keys", true)
  reaper.TrackFX_AddByName(tr, "ReaSynth", false, -1)
  local items = {}
  for i = 1, 7 do
    local it = reaper.CreateNewMIDIItemInProj(tr, (i - 1) * 3, (i - 1) * 3 + 2.5, false)
    local tk = reaper.GetActiveTake(it)
    for n = 0, 3 do reaper.MIDI_InsertNote(tk, false, false, n * 480, n * 480 + 400, 0, 50 + n, 100, true) end
    reaper.MIDI_Sort(tk)
    items[i] = it
  end
  watch(); hold(3.2)
  local function all_printed(limit, before)
    local t = reaper.time_precise()
    while reaper.time_precise() - t < limit do
      watch()
      local n = 0
      for i, it in ipairs(items) do if pkey(it) ~= "" and (not before or pkey(it) ~= before[i]) then n = n + 1 end end
      if n == #items and not bg.waiting() and not prints.waiting() then return true, reaper.time_precise() - t end
      hold(0.25)
    end
    return false, limit
  end

  prints.SETTLE = 1.5
  local d0, f0 = bg.counts()
  local done, secs = all_printed(90)
  local d1, f1 = bg.counts()
  check(done and d1 - d0 == 7 and f1 == f0, string.format("then all 7 print (%.1f s, %d done, %d failed)", secs, d1 - d0, f1 - f0))
  for _, it in ipairs(items) do
    if (band.size(pfile(it)) or 0) < 1500 then check(false, "a print came out silent: " .. pfile(it)) end
  end

  -- a part isn't rendered until it has held still
  nudge(items[4], 58)
  watch()
  check(not bg.waiting() and prints.waiting(), "a changed part waits first: nothing rendering yet")
  hold(0.8); watch()
  check(not bg.waiting(), "still waiting partway")
  hold(0.9); watch()
  check(bg.waiting(), "held still long enough: it renders")
  all_printed(30)

  -- several at once
  local before, peak = {}, 0
  for i, it in ipairs(items) do before[i] = pkey(it); nudge(it, 60) end
  prints.SETTLE = 0
  local t = reaper.time_precise()
  local TMP = bg.PROFILE:gsub("/profile$", "")
  while reaper.time_precise() - t < 60 do
    watch()
    local n, i = 0, 0
    while true do -- job folders with a job in them and no print yet: rendering now
      local d = reaper.EnumerateSubdirectories(TMP, i)
      if not d then break end
      for _, it in ipairs(items) do
        local oid = select(2, reaper.GetSetMediaItemInfo_String(it, "P_EXT:band_oid", "", false))
        if d:find(oid, 1, true) and reaper.file_exists(TMP .. "/" .. d .. "/job.rpp") then n = n + 1 end
      end
      i = i + 1
    end
    peak = math.max(peak, n)
    local left = 0
    for j, it in ipairs(items) do if pkey(it) == before[j] then left = left + 1 end end
    if left == 0 and not bg.waiting() then break end
    hold(0.2)
  end
  check(peak >= 2 and peak <= bg.MAX + 1, "several render at once, within the limit: " .. peak .. " of " .. bg.MAX .. " (plus one done, not yet picked up)")

  -- one part being edited doesn't hold up another, which goes first
  prints.SETTLE = 1.5
  local busy, other = items[1], items[7]
  local other_was = pkey(other)
  nudge(other, 64)
  local got, tn = false, reaper.time_precise()
  local pitch = 65
  while reaper.time_precise() - tn < 14 do
    nudge(busy, pitch); pitch = pitch + 1
    local w = reaper.time_precise()
    while reaper.time_precise() - w < 0.7 do watch(); hold(0.1) end
    if pkey(other) ~= other_was then got = reaper.time_precise() - tn; break end
  end
  check(got ~= false, "a part being nudged doesn't hold up another: it printed after " .. tostring(got and string.format("%.1f s", got)))
  all_printed(30)
  local _, _, cancelled0 = bg.counts()

  -- the oldest change goes first: two changed in turn, the older one's job starts first
  nudge(items[5], 70); hold(0.2); watch()
  nudge(items[2], 70); watch()
  hold(1.7); watch()
  local function job_for(it)
    local oid = select(2, reaper.GetSetMediaItemInfo_String(it, "P_EXT:band_oid", "", false))
    local i = 0
    while true do
      local d = reaper.EnumerateSubdirectories(TMP, i)
      if not d then return false end
      if d:find(oid, 1, true) and reaper.file_exists(TMP .. "/" .. d .. "/job.rpp") then return true end
      i = i + 1
    end
  end
  check(job_for(items[5]) and not job_for(items[2]), "the part that changed longest ago starts first, though it comes later in the song")
  all_printed(30)

  -- a job for a version that's gone is ended, not waited for
  prints.SETTLE = 0
  nudge(items[3], 72)
  watch()
  hold(2.5) -- (its REAPER has started and said its process id)
  nudge(items[3], 73)
  watch()
  local _, _, cancelled1 = bg.counts()
  check(cancelled1 > cancelled0, "a job for a version that's gone is ended")
  hold(0.6)
  local ok3 = all_printed(40)
  local final = pfile(items[3])
  check(ok3 and final ~= "" and reaper.file_exists(final), "and the newest version prints")
  -- going back to a printed state doesn't wait, whatever SETTLE says
  prints.SETTLE = 30
  local was_file = pfile(items[3])
  nudge(items[3], 72); watch(); nudge(items[3], 73)
  local t4 = reaper.time_precise()
  watch(); watch()
  check(pfile(items[3]) == was_file and reaper.time_precise() - t4 < 2, "going back to a printed state doesn't wait")
end)
if not ok then fails = fails + 1; say("ERROR " .. tostring(err)) end
prints.SETTLE = 0
reaper.SetExtState(band.SECTION, "bg render", was_bg, false)
reaper.SelectProjectInstance(pa)
reaper.Main_SaveProjectEx(pa, root .. "/burst.rpp", 8)
reaper.Main_OnCommand(40860, 0)
reaper.SelectProjectInstance(front)
say(fails == 0 and "ALL PASS" or (fails .. " FAILED"))
return table.concat(out, "\n")
