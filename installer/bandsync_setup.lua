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

-- verify: which BandSync actions does REAPER have registered right now?
local kb = io.open(reaper.GetResourcePath() .. "/reaper-kb.ini", "r")
local count, text = 0, kb and kb:read("a") or ""
if kb then kb:close() end
for _ in text:gmatch('SCR %d+ %d+ %S+ "[^"]*BandSync %- [^"]*"') do count = count + 1 end
out.registered_actions = count
step("BandSync actions registered", count >= 5, count)
finish()
