-- @noindex
-- BandSync installer step that runs INSIDE the live REAPER, with no dialogs, so an AI installer can drive it:
--   Windows: reaper.exe -nonewinst "<this file>"      macOS: open -a /Applications/REAPER.app "<this file>"
-- It reads bandsync_setup.json next to itself and writes bandsync_setup_result.json next to itself.
-- Request: { "sync_root": "...", "user": "...", "mode": "reapack" | "folder", "repo_url": "..." }
--   reapack: add the BandSync repository and start a ReaPack sync (installs + registers actions)
--   folder:  register every "BandSync - *.lua" in <sync_root>/_tools/bandsync (re-run after updates)
local here = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
package.path = here .. "/../lib/?.lua;" .. package.path
local json = require("json")

local out = { ok = true, steps = {} }
local function step(name, ok, detail)
  out.steps[#out.steps + 1] = { name = name, ok = ok, detail = detail and tostring(detail) or "" }
  if not ok then out.ok = false end
end
local function finish()
  local f = io.open(here .. "/bandsync_setup_result.json", "w")
  if f then f:write(json.encode(out, true)); f:close() end
end

local f = io.open(here .. "/bandsync_setup.json", "r")
if not f then step("read request", false, here .. "/bandsync_setup.json missing"); return finish() end
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
  reaper.SetExtState("BandSync", "sync_root", root, true)
  reaper.SetExtState("BandSync", "user", user, true)
end

if req.mode == "reapack" then
  if not reaper.APIExists("ReaPack_AddSetRepository") then
    step("ReaPack installed", false, "install ReaPack (reapack.com) and restart REAPER first")
  else
    local added, err = reaper.ReaPack_AddSetRepository("BandSync", req.repo_url or "", true, 1) -- 1: auto-install on sync
    step("add BandSync repository", added, err ~= "" and err or req.repo_url)
    reaper.ReaPack_ProcessQueue(true)
    local sync = reaper.NamedCommandLookup("_REAPACK_SYNC")
    if added and sync ~= 0 then reaper.Main_OnCommand(sync, 0) end
    step("ReaPack sync started", sync ~= 0, "asynchronous: re-run with mode \"verify\" in a minute")
  end
elseif req.mode == "folder" then
  local dir, scripts, i = root .. "/_tools/bandsync", {}, 0
  reaper.EnumerateFiles(dir, -1)
  while true do
    local name = reaper.EnumerateFiles(dir, i)
    if not name then break end
    if name:match("^BandSync %- .+%.lua$") then scripts[#scripts + 1] = dir .. "/" .. name end
    i = i + 1
  end
  for n, path in ipairs(scripts) do reaper.AddRemoveReaScript(true, 0, path, n == #scripts) end
  step("register actions from shared folder", #scripts > 0, #scripts .. " scripts in " .. dir)
end

-- What's registered now, autostart, the result file, and the panel. With ReaPack, run once its sync has brought the
-- scripts: this script waits for that INSIDE REAPER. The installer used to ask REAPER to run it again every 10 s,
-- and on macOS a request arriving while ReaPack's report window was open crashed REAPER (2026-10-28): now there's
-- one request per installer run.
local waiting = false
local function conclude()
  -- optional: the control panel needs ReaImGui (ReaTeam Extensions repository, which ReaPack has by default)
  out.reaimgui = reaper.APIExists("ImGui_GetBuiltinPath")

  -- verify: which BandSync actions does REAPER have registered right now?
  local kb = io.open(reaper.GetResourcePath() .. "/reaper-kb.ini", "r")
  local count, text = 0, kb and kb:read("a") or ""
  if kb then kb:close() end
  for _ in text:gmatch('SCR %d+ %d+ %S+ "[^"]*BandSync %- [^"]*"') do count = count + 1 end
  out.registered_actions = count
  step("BandSync actions registered", count >= 5, count)

  -- Live sync starts again with REAPER for a session where it was running (Scripts/__startup.lua runs BandSync -
  -- Autostart, the panel's "Start Live sync with REAPER"). Without it, a REAPER restart (this installer does one)
  -- left Live sync off and changes silently stayed here (Mac, 2026-10-28). Same block as lib/tools.lua writes.
  local live = text:match('"[^"]*BandSync %- Live sync%.lua" "([^"]+)"')
  if live and count >= 5 then
    live = live:gsub("\\", "/")
    if not live:match("^/") and not live:match("^%a:") then live = reaper.GetResourcePath() .. "/Scripts/" .. live end
    local sdir = live:match("^(.*)/")
    local startup = reaper.GetResourcePath() .. "/Scripts/__startup.lua"
    local sf = io.open(startup, "r")
    local cur = sf and sf:read("a") or ""
    if sf then sf:close() end
    if not cur:find("-- BandSync autostart", 1, true) and reaper.file_exists(sdir .. "/BandSync - Autostart.lua") then
      local wf = io.open(startup, "w")
      if wf then
        wf:write(cur .. (cur ~= "" and not cur:match("\n$") and "\n" or "") .. "-- BandSync autostart\ndofile([[" .. sdir ..
          "/BandSync - Autostart.lua]])\n-- /BandSync autostart\n")
        wf:close()
        dofile(sdir .. "/BandSync - Autostart.lua") -- and now, for this REAPER session (it just restarted without it)
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
    local id = text:match('SCR %d+ %d+ (%S+) "[^"]*BandSync %- Panel%.lua"')
    local cmd = id and reaper.NamedCommandLookup("_" .. id) or 0
    if cmd ~= 0 and reaper.GetToggleCommandState(cmd) ~= 1 then reaper.Main_OnCommand(cmd, 0) end
  end
end

local function registered()
  local kb = io.open(reaper.GetResourcePath() .. "/reaper-kb.ini", "r")
  local n, text = 0, kb and kb:read("a") or ""
  if kb then kb:close() end
  for _ in text:gmatch('SCR %d+ %d+ %S+ "[^"]*BandSync %- [^"]*"') do n = n + 1 end
  return n
end
if req.mode == "reapack" and out.ok then
  waiting = true
  local started, last, same, at = reaper.time_precise(), -1, 0, 0
  local function wait()
    if reaper.time_precise() - at < 2 then return reaper.defer(wait) end
    at = reaper.time_precise()
    local n = registered()
    if n >= 5 and n == last then same = same + 1 else same = 0 end -- arrived, and nothing more for a moment
    last = n
    if same >= 2 or reaper.time_precise() - started > 240 then return conclude() end
    reaper.defer(wait)
  end
  reaper.defer(wait)
else
  conclude()
end
