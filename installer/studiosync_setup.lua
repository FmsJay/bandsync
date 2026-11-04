-- @noindex
-- StudioSync installer step that runs INSIDE the live REAPER, with no dialogs, so an AI installer can drive it:
--   Windows: reaper.exe -nonewinst "<this file>"      macOS: open -a /Applications/REAPER.app "<this file>"
-- It reads studiosync_setup.json next to itself and writes studiosync_setup_result.json next to itself.
-- Request: { "sync_root": "...", "user": "...", "mode": "reapack" | "folder", "repo_url": "..." }
--   reapack: add the StudioSync repository and start a ReaPack sync (installs + registers actions)
--   folder:  register every "StudioSync - *.lua" in <sync_root>/_tools/studiosync (re-run after updates)
local here = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
-- chmaha's "DSP to JSFX": the effects and instruments REAPER 7.83 bundled and 7.84 removed (drum kits, MDA piano and
-- e-piano, organ, channel strip, tuner, limiter...), GPL-3.0 with MIT/AGPL parts; new in Oct 2026, still changing
local JSFX_REPOS = { { "Saike", "https://raw.githubusercontent.com/JoepVanlier/JSFX/master/index.xml" },
                     { "Chokehold", "https://github.com/chkhld/jsfx/raw/main/index.xml" },
                     { "DSP to JSFX (chmaha)", "https://github.com/chmaha/DSP-Ports-JSFX/raw/main/index.xml" } }
package.path = here .. "/../lib/?.lua;" .. package.path
local json = require("json")

local out = { ok = true, steps = {} }
local function step(name, ok, detail)
  out.steps[#out.steps + 1] = { name = name, ok = ok, detail = detail and tostring(detail) or "" }
  if not ok then out.ok = false end
end
local function finish()
  local f = io.open(here .. "/studiosync_setup_result.json", "w")
  if f then f:write(json.encode(out, true)); f:close() end
end

local f = io.open(here .. "/studiosync_setup.json", "r")
if not f then step("read request", false, here .. "/studiosync_setup.json missing"); return finish() end
local ok, req = pcall(json.decode, f:read("a"))
f:close()
if not ok or type(req) ~= "table" then step("read request", false, req); return finish() end

local ver = reaper.GetAppVersion()
local major, minor = ver:match("^(%d+)%.(%d+)")
step("REAPER 7.18 or newer", tonumber(major) > 7 or (tonumber(major) == 7 and tonumber(minor) >= 18), ver)

local root = (req.sync_root or ""):gsub("\\", "/"):gsub("/+$", "")
local probe = io.open(root .. "/.bandsync-write-test", "w")
if probe then probe:close(); os.remove(root .. "/.bandsync-write-test") end
step("shared folder writable", probe ~= nil, root)
local user = (req.user or ""):gsub("[^%w%-_ ]", "")
step("name", user ~= "", user)
if probe and user ~= "" then
  -- joining another band: the band this computer was in stays one of its bands (Setup > Options > Bands)
  local was, bands = reaper.GetExtState("BandSync", "sync_root"), reaper.GetExtState("BandSync", "bands")
  local list = {}
  for r in bands:gmatch("[^|]+") do list[#list + 1] = r end
  for _, r in ipairs({ was, root }) do
    local have = false
    for _, x in ipairs(list) do if x == r then have = true end end
    if r ~= "" and not have then list[#list + 1] = r end
  end
  reaper.SetExtState("BandSync", "bands", table.concat(list, "|"), true)
  reaper.SetExtState("BandSync", "sync_root", root, true)
  reaper.SetExtState("BandSync", "user", user, true)
end

-- The VERSION in a StudioSync lib/band.lua, or nil.
local function version_in(path)
  local vf = path and io.open(path, "r")
  local v = vf and vf:read("a"):match('VERSION%s*=%s*"([^"]+)"')
  if vf then vf:close() end
  return v
end
-- This installer's StudioSync (the copy it came in), and the one REAPER runs now (where its Live sync action points).
local WANT = version_in(here .. "/../lib/band.lua")
local function installed_version()
  local kb = io.open(reaper.GetResourcePath() .. "/reaper-kb.ini", "r")
  local text = kb and kb:read("a") or ""
  if kb then kb:close() end
  local live = text:match('"[^"]*StudioSync %- Live sync%.lua" "([^"]+)"')
  if not live then return nil end
  live = live:gsub("\\", "/")
  if not live:match("^/") and not live:match("^%a:") then live = reaper.GetResourcePath() .. "/Scripts/" .. live end
  return version_in(live:match("^(.*)/") .. "/lib/band.lua")
end

-- StudioSync already up to date through ReaPack (the repository set, this installer's version installed, and every
-- requested JSFX repository there)? Then ReaPack is left alone: starting a ReaPack sync while its Transaction report
-- window is open crashes REAPER on macOS (2026-10-28), and a re-run is exactly when that window may still be up.
-- (Until 0.34.4 any registered StudioSync counted: a Mac on 0.13.4 re-ran the installer, was told OK, and stayed on
-- 0.13.4 without the plug-in pack's JSFX.)
local function already_installed()
  if not reaper.APIExists("ReaPack_GetRepositoryInfo") then return false end
  local ok, url = reaper.ReaPack_GetRepositoryInfo("StudioSync")
  if not ok or url ~= req.repo_url then return false end
  if not WANT or installed_version() ~= WANT then return false end
  if req.jsfx then
    for _, r in ipairs(JSFX_REPOS) do if not reaper.ReaPack_GetRepositoryInfo(r[1]) then return false end end
  end
  return true
end

-- The plug-in pack's JSFX without StudioSync's own ReaPack sync to ride along with: a sync of their own, only when
-- one of them is missing (a re-run with all there leaves ReaPack alone, see above).
local function jsfx_only()
  if not (req.jsfx and reaper.APIExists("ReaPack_AddSetRepository")) then return end
  local added = false
  for _, r in ipairs(JSFX_REPOS) do
    local have = reaper.APIExists("ReaPack_GetRepositoryInfo") and reaper.ReaPack_GetRepositoryInfo(r[1])
    if not have then
      local ok_r, e = reaper.ReaPack_AddSetRepository(r[1], r[2], true, 1)
      step("add " .. r[1] .. " JSFX repository", ok_r, e ~= "" and e or r[2])
      added = added or ok_r
    end
  end
  if added then
    reaper.ReaPack_ProcessQueue(true)
    local sync = reaper.NamedCommandLookup("_REAPACK_SYNC")
    if sync ~= 0 then reaper.Main_OnCommand(sync, 0) end
  end
end
-- This version already runs here from somewhere other than ReaPack (the band folder's staged copy, a checkout): a
-- ReaPack copy beside it gave the laptop two of every action and two Live syncs to choose from (0.35.1).
local function runs_elsewhere()
  local ok = reaper.APIExists("ReaPack_GetRepositoryInfo") and reaper.ReaPack_GetRepositoryInfo("StudioSync")
  return not ok and WANT ~= nil and installed_version() == WANT
end

if req.mode == "reapack" then
  if not reaper.APIExists("ReaPack_AddSetRepository") then
    step("ReaPack installed", false, "install ReaPack (reapack.com) and restart REAPER first")
  elseif already_installed() then
    step("StudioSync " .. WANT .. " already installed through ReaPack", true, "left as it is")
    req.mode, req.open_panel = "verify", true -- nothing to wait for; land in the panel (it stayed shut, Mac 0.34.3)
  elseif runs_elsewhere() then
    step("StudioSync " .. WANT .. " already runs here (not through ReaPack)", true, "left as it is: no second copy")
    jsfx_only()
    req.mode, req.open_panel = "verify", true
  else
    local added, err = reaper.ReaPack_AddSetRepository("BandSync", req.repo_url or "", true, 1) -- 1: auto-install on sync
    step("add StudioSync repository", added, err ~= "" and err or req.repo_url)
    if req.jsfx then -- the plug-in pack's JSFX (both MIT): in this same ReaPack sync, never one of their own (see above)
      for _, r in ipairs(JSFX_REPOS) do
        local ok_r, e = reaper.ReaPack_AddSetRepository(r[1], r[2], true, 1)
        step("add " .. r[1] .. " JSFX repository", ok_r, e ~= "" and e or r[2])
      end
    end
    reaper.ReaPack_ProcessQueue(true)
    local sync = reaper.NamedCommandLookup("_REAPACK_SYNC")
    if added and sync ~= 0 then reaper.Main_OnCommand(sync, 0) end
    step("ReaPack sync started", sync ~= 0, "asynchronous: re-run with mode \"verify\" in a minute")
  end
elseif req.mode == "folder" then
  local dir, scripts, i = root .. "/_tools/studiosync", {}, 0
  reaper.EnumerateFiles(dir, -1)
  while true do
    local name = reaper.EnumerateFiles(dir, i)
    if not name then break end
    if name:match("^StudioSync %- .+%.lua$") then scripts[#scripts + 1] = dir .. "/" .. name end
    i = i + 1
  end
  for n, path in ipairs(scripts) do reaper.AddRemoveReaScript(true, 0, path, n == #scripts) end
  step("register actions from shared folder", #scripts > 0, #scripts .. " scripts in " .. dir)
  jsfx_only() -- (StudioSync came from the folder: no StudioSync ReaPack sync for the JSFX to ride along with)
end

-- What's registered now, autostart, the result file, and the panel. With ReaPack, run once its sync has brought the
-- scripts: this script waits for that INSIDE REAPER. The installer used to ask REAPER to run it again every 10 s,
-- and on macOS a request arriving while ReaPack's report window was open crashed REAPER (2026-10-28): now there's
-- one request per installer run.
local waiting = false
local function conclude()
  -- optional: the control panel needs ReaImGui (ReaTeam Extensions repository, which ReaPack has by default)
  out.reaimgui = reaper.APIExists("ImGui_GetBuiltinPath")

  -- verify: which StudioSync actions does REAPER have registered right now?
  local kb = io.open(reaper.GetResourcePath() .. "/reaper-kb.ini", "r")
  local count, text = 0, kb and kb:read("a") or ""
  if kb then kb:close() end
  for _ in text:gmatch('SCR %d+ %d+ %S+ "[^"]*StudioSync %- [^"]*"') do count = count + 1 end
  out.registered_actions = count
  out.version = installed_version()
  step("StudioSync actions registered", count >= 5, count)

  -- Live sync starts again with REAPER for a session where it was running (Scripts/__startup.lua runs StudioSync -
  -- Autostart, the panel's "Start Live sync with REAPER"). Without it, a REAPER restart (this installer does one)
  -- left Live sync off and changes silently stayed here (Mac, 2026-10-28). Same block as lib/tools.lua writes.
  local live = text:match('"[^"]*StudioSync %- Live sync%.lua" "([^"]+)"')
  if live and count >= 5 then
    live = live:gsub("\\", "/")
    if not live:match("^/") and not live:match("^%a:") then live = reaper.GetResourcePath() .. "/Scripts/" .. live end
    local sdir = live:match("^(.*)/")
    local startup = reaper.GetResourcePath() .. "/Scripts/__startup.lua"
    local sf = io.open(startup, "r")
    local cur = sf and sf:read("a") or ""
    if sf then sf:close() end
    if not cur:find(sdir .. "/StudioSync - Autostart.lua", 1, true) and reaper.file_exists(sdir .. "/StudioSync - Autostart.lua") then
      -- (a block from before the rename, or from another copy, makes way)
      local a = cur:find("-- BandSync autostart", 1, true)
      local z = a and cur:find("-- /BandSync autostart", a, true)
      if z then cur = cur:sub(1, a - 1) .. cur:sub(z + #"-- /BandSync autostart" + 1) end
      local wf = io.open(startup, "w")
      if wf then
        wf:write(cur .. (cur ~= "" and not cur:match("\n$") and "\n" or "") .. "-- BandSync autostart\ndofile([[" .. sdir ..
          "/StudioSync - Autostart.lua]])\n-- /BandSync autostart\n")
        wf:close()
        dofile(sdir .. "/StudioSync - Autostart.lua") -- and now, for this REAPER session (it just restarted without it)
      end
    end
    local again = io.open(startup, "r")
    local on = again and again:read("a"):find("-- BandSync autostart", 1, true) ~= nil
    if again then again:close() end
    step("Live sync starts with REAPER", on, startup)
  end
  finish()

  -- open_panel: land the musician in the panel, whose first screen offers to publish or open a session
  if (req.open_panel or waiting) and count >= 5 and out.reaimgui then
    local id = text:match('SCR %d+ %d+ (%S+) "[^"]*StudioSync %- Panel%.lua"')
    local cmd = id and reaper.NamedCommandLookup("_" .. id) or 0
    if cmd ~= 0 and reaper.GetToggleCommandState(cmd) ~= 1 then reaper.Main_OnCommand(cmd, 0) end
  end
end

local function registered()
  local kb = io.open(reaper.GetResourcePath() .. "/reaper-kb.ini", "r")
  local n, text = 0, kb and kb:read("a") or ""
  if kb then kb:close() end
  for _ in text:gmatch('SCR %d+ %d+ %S+ "[^"]*StudioSync %- [^"]*"') do n = n + 1 end
  return n
end
if req.mode == "reapack" and out.ok then
  waiting = true
  local started, last, same, at = reaper.time_precise(), -1, 0, 0
  local function wait()
    if reaper.time_precise() - at < 2 then return reaper.defer(wait) end
    at = reaper.time_precise()
    local n = registered()
    -- arrived (this installer's version, when an older one was there: its actions were registered all along), and
    -- nothing more for a moment
    if n >= 5 and n == last and (not WANT or installed_version() == WANT) then same = same + 1 else same = 0 end
    last = n
    if same >= 2 or reaper.time_precise() - started > 240 then return conclude() end
    reaper.defer(wait)
  end
  reaper.defer(wait)
else
  conclude()
end
