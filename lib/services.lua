-- The background programs BandSync leans on, started when a session needs them (never at login):
--   Syncthing   moves the shared folder; Live sync makes sure it runs on every machine
--   ninjamsrv   the NINJAM server for Live; the host's Live tab starts it when connecting
-- Paths can be set in ExtState (section BandSync: syncthing_path, ninjam_dir); otherwise the usual install
-- locations are tried.
local band = require("band")
local services = {}

local WIN = reaper.GetOS():match("^Win") ~= nil

local function q(s) return '"' .. s .. '"' end

-- Whether a process named `exe` (e.g. "syncthing") is running.
function services.running(exe)
  local out
  if WIN then
    out = reaper.ExecProcess('tasklist /FI "IMAGENAME eq ' .. exe .. '.exe" /NH', 5000) or ""
    return out:lower():find(exe:lower() .. ".exe", 1, true) ~= nil
  end
  out = reaper.ExecProcess("/usr/bin/pgrep -x " .. exe, 5000) or ""
  return out:match("^0\n") ~= nil
end

-- Start `path args...` in the background, hidden, in `cwd` (optional). Returns true if launched.
local function launch(path, args, cwd)
  if WIN then
    local list = {}
    for _, a in ipairs(args) do list[#list + 1] = "'" .. a .. "'" end
    local ps = string.format("Start-Process -FilePath '%s'%s%s -WindowStyle Hidden", path,
      #list > 0 and (" -ArgumentList " .. table.concat(list, ",")) or "", cwd and (" -WorkingDirectory '" .. cwd .. "'") or "")
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
  if reaper.time_precise() - peers_at < 30 then return peers_on, peers_n or peers_why end -- a curl call: not every check
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
  local out = reaper.ExecProcess(string.format('curl -s -m 3 %s-H "X-API-Key: %s" %s://%s/rest/system/connections',
    tls and "-k " or "", key, tls and "https" or "http", addr), 5000) or ""
  local data = band.json_decode(out:match("^%d+\n(.*)$") or "")
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
