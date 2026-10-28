-- The background programs BandSync leans on, started when a session needs them (never at login):
--   Syncthing   moves the shared folder; Live sync makes sure it runs on every machine
--   ninjamsrv   the NINJAM server for Live; the host's Live tab starts it when connecting
-- Paths can be set in ExtState (section BandSync: syncthing_path, ninjam_dir); otherwise the usual install
-- locations are tried.
local band = require("band")
local services = {}

local WIN = reaper.GetOS():match("^Win") ~= nil

local function q(s) return '"' .. s .. '"' end

-- Slow checks (tasklist ~150 ms, a curl call up to 3 s) run in the background: REAPER waiting on them froze
-- its UI for 0.3-0.4 s at every panel refresh (2026-10-28, laptop). Each call starts a fresh run at most every
-- `every` seconds, its output going to a file, and returns what the previous run wrote (nil before the first).
local TMP = (WIN and (os.getenv("TEMP") or os.getenv("TMP")) or "/tmp"):gsub("\\", "/")
local started, last = {}, {}
local function background(name, cmd, every)
  local file = TMP .. "/bandsync-" .. name .. ".txt"
  if not started[name] or reaper.time_precise() - started[name] > every then
    started[name] = reaper.time_precise()
    -- shortcut: written in place (these outputs are a few hundred bytes); a half-written read just looks like "no answer" once
    if WIN then -- through a hidden-window runner: `cmd /c` without waiting flashes a console window (seen 0.9.7)
      local bat, vbs = TMP .. "/bandsync-" .. name .. ".cmd", TMP .. "/bandsync-hidden.vbs"
      band.write_atomic(bat, string.format('@%s > "%s" 2>nul\r\n', cmd, file))
      if not reaper.file_exists(vbs) then band.write_atomic(vbs, 'CreateObject("WScript.Shell").Run """" & WScript.Arguments(0) & """", 0, False\r\n') end
      reaper.ExecProcess(string.format('wscript.exe //B //Nologo "%s" "%s"', vbs, bat), -1)
    else
      reaper.ExecProcess("/bin/sh -c " .. q(cmd:gsub('"', '\\"') .. " > '" .. file .. "' 2>/dev/null"), -1)
    end
  end
  local out = band.read(file)
  if out and out:match("%S") then last[name] = out end -- a run that has just started truncates the file: keep the last answer
  return last[name]
end

-- Whether a process named `exe` (e.g. "syncthing") is running. Answers from the last background check
-- (at most ~15 s old); the very first time, it waits for one.
function services.running(exe)
  local out = background("ps-" .. exe, WIN and ('tasklist /FI "IMAGENAME eq ' .. exe .. '.exe" /NH') or ("/usr/bin/pgrep -x " .. exe .. " || echo none"), 15)
  if not out then -- nothing yet: ask once and wait
    out = reaper.ExecProcess(WIN and ('tasklist /FI "IMAGENAME eq ' .. exe .. '.exe" /NH') or ("/usr/bin/pgrep -x " .. exe), 5000) or ""
    if not WIN then return out:match("^0\n") ~= nil end
  end
  if WIN then return out:lower():find(exe:lower() .. ".exe", 1, true) ~= nil end
  return out:match("%d") ~= nil -- pgrep prints the pids
end

-- Start `path args...` in the background, hidden, in `cwd` (optional). Returns true if launched.
local function launch(path, args, cwd)
  if WIN then
    local function sq(s) return "'" .. s:gsub("'", "''") .. "'" end -- PowerShell single quotes: ' is written ''
    local list = {}
    for _, a in ipairs(args) do list[#list + 1] = sq(a) end
    local ps = string.format("Start-Process -FilePath %s%s%s -WindowStyle Hidden", sq(path),
      #list > 0 and (" -ArgumentList " .. table.concat(list, ",")) or "", cwd and (" -WorkingDirectory " .. sq(cwd)) or "")
    return reaper.ExecProcess('powershell -NoProfile -WindowStyle Hidden -Command ' .. q(ps), -1) ~= nil
  end
  local cmd = (cwd and ("cd " .. q(cwd) .. " && ") or "") .. "nohup " .. q(path) .. " " .. table.concat(args, " ") .. " >/dev/null 2>&1 &"
  return reaper.ExecProcess("/bin/sh -c " .. q(cmd:gsub('"', '\\"')), -1) ~= nil
end

local function first_existing(list)
  for _, p in ipairs(list) do if p and p ~= "" and reaper.file_exists(p) then return p end end
end

function services.syncthing_path()
  local set = reaper.GetExtState(band.SECTION, "syncthing_path")
  local lad = (os.getenv("LOCALAPPDATA") or ""):gsub("\\", "/")
  return first_existing({ set,
    lad .. "/Microsoft/WinGet/Links/syncthing.exe", "C:/Program Files/Syncthing/syncthing.exe", lad .. "/Programs/Syncthing/syncthing.exe",
    "/opt/homebrew/bin/syncthing", "/usr/local/bin/syncthing", "/usr/bin/syncthing",
    "/Applications/Syncthing.app/Contents/Resources/syncthing/syncthing" })
end

-- Make sure Syncthing runs. Returns "running", "started", or nil + why.
function services.ensure_syncthing()
  if services.running("syncthing") then return "running" end
  local path = services.syncthing_path()
  if not path then return nil, "Syncthing isn't running and wasn't found (set its path: ExtState BandSync/syncthing_path)" end
  if not launch(path, { "serve", "--no-browser" }) then return nil, "couldn't start " .. path end
  return "started"
end

-- How many of Syncthing's devices it's connected to right now: connected, total. nil + why if it can't tell.
-- Asks Syncthing's own API with the key from its config. "Running but connected to nobody" is what a second
-- identity looks like (2026-10-27: one started outside a sandboxed shell knew no other machine).
local peers_at, peers_on, peers_n, peers_why = -math.huge
function services.syncthing_peers()
  if reaper.time_precise() - peers_at < 5 then return peers_on, peers_n or peers_why end -- (the curl itself runs in the background)
  peers_at = reaper.time_precise()
  peers_on, peers_n = services.syncthing_peers_now()
  if not peers_on then peers_why, peers_n = peers_n, nil end
  return peers_on, peers_n or peers_why
end
function services.syncthing_peers_now()
  local home = WIN and ((os.getenv("LOCALAPPDATA") or "") .. "/Syncthing")
    or first_existing({ (os.getenv("HOME") or "") .. "/Library/Application Support/Syncthing/config.xml",
      (os.getenv("HOME") or "") .. "/.local/state/syncthing/config.xml", (os.getenv("HOME") or "") .. "/.config/syncthing/config.xml" })
  if home and not WIN then home = home:gsub("/config.xml$", "") end
  local f = home and io.open(home .. "/config.xml", "r")
  if not f then return nil, "no Syncthing config found" end
  local xml = f:read("a")
  f:close()
  local gui = xml:match("<gui(.-)</gui>") or ""
  local key, addr = gui:match("<apikey>(.-)</apikey>"), gui:match("<address>(.-)</address>")
  if not key or not addr then return nil, "Syncthing config has no API key" end
  local tls = gui:match('^[^>]*tls="true"') ~= nil
  local out = background("syncthing-connections", string.format('curl -s -m 3 %s-H "X-API-Key: %s" %s://%s/rest/system/connections',
    tls and "-k " or "", key, tls and "https" or "http", addr), 20) or ""
  local data = band.json_decode(out)
  if type(data) ~= "table" or type(data.connections) ~= "table" then return nil, "Syncthing didn't answer" end
  local n, on = 0, 0
  for _, c in pairs(data.connections) do n = n + 1; if c.connected then on = on + 1 end end
  return on, n
end

-- This machine's Tailscale address (100.x.y.z), or nil when Tailscale isn't installed or signed in.
function services.tailscale_ip()
  local exe = first_existing({ "C:/Program Files/Tailscale/tailscale.exe", "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
    "/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale", "/usr/bin/tailscale" })
  if not exe then return nil end
  local out = reaper.ExecProcess(q(exe) .. " ip -4", 5000) or "" -- "0\n100.97.210.49\n"
  return out:match("^0\n%s*(100%.%d+%.%d+%.%d+)")
end

-- The host's NINJAM server: <ninjam_dir>/ninjamsrv(.exe) with bandsync.cfg beside it.
function services.ninjam_dir()
  return reaper.GetExtState(band.SECTION, "ninjam_dir")
end
function services.ensure_ninjam()
  if services.running("ninjamsrv") then return "running" end
  local dir = services.ninjam_dir()
  local exe = dir ~= "" and first_existing({ dir .. "/ninjamsrv.exe", dir .. "/ninjamsrv" })
  if not exe then return nil, "set the NINJAM server folder (the one with ninjamsrv and bandsync.cfg) in the Live tab" end
  if not reaper.file_exists(dir .. "/bandsync.cfg") then return nil, "no bandsync.cfg in " .. dir end
  if not launch(exe, { "bandsync.cfg" }, dir) then return nil, "couldn't start " .. exe end
  return "started"
end

return services
