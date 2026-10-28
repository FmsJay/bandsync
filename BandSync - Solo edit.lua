-- @description BandSync: check out a song to edit it alone (one person at a time, through the cloud folder)
-- Takes the song's lock, copies its current version to this machine and opens it. While you have it, your
-- bandmates see that you're editing (and since when); nobody else can check it out. Run "BandSync - Check
-- in" to publish your changes and hand it back. Tracks whose plugins you don't have play their wet prints.
local dir = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
package.path = dir .. "/lib/?.lua;" .. package.path
local band = require("band")
local solo = require("solo")
if reaper.set_action_options then reaper.set_action_options(2) end -- re-running starts a new instance (which just says "already open")

local cfg = band.settings()
if not cfg then return end
local cur = reaper.EnumProjects(-1)
local b = band.binding(cur)
local song = b and b.song
if not song then
  local names = {}
  for _, d in ipairs(band.subdirs(solo.root(cfg))) do
    if reaper.file_exists(solo.root(cfg) .. "/" .. d .. "/solo/project/" .. d .. ".rpp") then names[#names + 1] = d end
  end
  if #names == 0 then return band.msg("No song has a solo version yet. Open a BandSync song (or publish one), then run this to start.") end
  song = band.pick(names)
  if not song then return end
end
local alive = tonumber(reaper.GetExtState(band.SECTION, "solo alive " .. song))
if alive and reaper.time_precise() - alive < 5 then return band.msg("You already have '" .. song .. "' checked out. Run 'BandSync - Check in' when you're done.") end

local ok, l = solo.take(cfg, song, false)
if not ok then
  if l.stale then
    if reaper.MB(string.format("%s had '%s' checked out on %s, but their REAPER hasn't checked in for %d minutes (it may have crashed).\n\n" ..
        "Take it over? Anything they didn't check in stays on their machine only.", l.user, song, l.machine or "?", math.floor(l.age / 60)), "BandSync", 4) ~= 6 then return end
    solo.take(cfg, song, true)
  else
    if reaper.MB(string.format("%s is editing '%s' right now (since %s, last seen %d s ago).\n\nOpen the latest checked-in version to look at it? " ..
        "(Your changes there won't be published.)", l.user, song, (l.since or ""):sub(12, 16) .. " UTC", math.floor(l.age)), "BandSync", 4) == 6 then
      local path = solo.pull(cfg, song)
      if path then reaper.Main_OnCommand(40859, 0); reaper.Main_openProject(path) end
    end
    return
  end
end

-- The cloud folder may take a moment to show someone else's lock: confirm we still hold it before opening.
local started = reaper.time_precise()
local function confirmed()
  if reaper.time_precise() - started < 8 then return reaper.defer(confirmed) end
  local l2 = solo.lock(cfg, song)
  if not (l2 and l2.mine) then
    return band.msg((l2 and l2.user or "Someone") .. " checked out '" .. song .. "' at the same moment and got it first. Try again when they're done.")
  end
  local path = solo.pull(cfg, song)
  if not path then -- first solo version: start from the project in front
    if not b then solo.release(cfg, song); return band.msg("Open the song's project first: its current state becomes the first solo version.") end
    path = solo.local_dir(cfg, song) .. "/" .. song .. ".rpp"
    reaper.RecursiveCreateDirectory(solo.local_dir(cfg, song), 0)
    -- a copy in a tab of its own: the live session stays open and keeps syncing (until 0.9.10 this tab itself
    -- became the solo copy, which closed the live session out from under its Live sync)
    reaper.Main_SaveProjectEx(cur, path, 0) -- 0: save a copy; this tab keeps its own file
    band.write_atomic(path, solo.strip_live_fx(band.read(path)))
    reaper.Main_OnCommand(40859, 0) -- new tab
    reaper.Main_openProject("noprompt:" .. path)
    local copy = reaper.EnumProjects(-1)
    band.bind(copy, { role = "solo", song = song, room = "main" })
    local msg = solo.push(copy, cfg, song, "first solo version")
    band.log(msg or "first solo version failed")
  else
    reaper.Main_OnCommand(40859, 0) -- new tab
    reaper.Main_openProject(path)
  end
  local proj = reaper.EnumProjects(-1)
  band.bind(proj, { role = "solo", song = song, room = "main" })
  local n = solo.use_prints_where_needed(proj)
  band.log(string.format("checked out '%s'%s", song, n > 0 and (": " .. n .. " track(s) play wet prints (plugins missing here)") or ""))

  local _, _, section, cmd = reaper.get_action_context()
  if cmd > 0 then reaper.SetToggleCommandState(section, cmd, 1); reaper.RefreshToolbar2(section, cmd) end
  reaper.atexit(function() if cmd > 0 then reaper.SetToggleCommandState(section, cmd, 0); reaper.RefreshToolbar2(section, cmd) end end)
  local last = 0
  local function keep()
    reaper.SetExtState(band.SECTION, "solo alive " .. song, tostring(reaper.time_precise()), false)
    if reaper.GetExtState(band.SECTION, "solo done " .. song) ~= "" then -- checked in for good
      reaper.DeleteExtState(band.SECTION, "solo done " .. song, false)
      reaper.DeleteExtState(band.SECTION, "solo alive " .. song, false)
      return
    end
    if not reaper.ValidatePtr2(0, proj, "ReaProject*") then proj = solo.find_tab(song) or proj end -- reopened (restore)
    if not reaper.ValidatePtr2(0, proj, "ReaProject*") then -- tab closed without checking in: the lock goes stale
      reaper.DeleteExtState(band.SECTION, "solo alive " .. song, false)
      return band.log("'" .. song .. "' was closed without checking in; it stays checked out to you until it goes stale (5 min)")
    end
    if reaper.time_precise() - last > 30 then
      last = reaper.time_precise()
      if not solo.beat(cfg, song) then
        reaper.DeleteExtState(band.SECTION, "solo alive " .. song, false)
        return band.msg("Someone took over '" .. song .. "' (your lock had gone stale). Your changes here are no longer published.")
      end
    end
    reaper.defer(keep)
  end
  keep()
end
reaper.defer(confirmed)
