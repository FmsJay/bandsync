-- The background programs StudioSync leans on, started when a session needs them (never at login):
--   Syncthing   moves the shared folder; Live sync makes sure it runs on every machine
--   ninjamsrv   the NINJAM server for Live; the host's Connect (panel: Live) starts it
-- Paths can be set in ExtState (section StudioSync: syncthing_path, ninjam_dir); otherwise the usual install
-- locations are tried.
local band = require("band")
local services = {}

local WIN = reaper.GetOS():match("^Win") ~= nil

local function q(s) return '"' .. s .. '"' end

-- Slow checks (tasklist ~150 ms, a curl call up to 3 s) run in the background: REAPER waiting on them froze
-- its UI for 0.3-0.4 s at every panel refresh (2026-10-28, laptop). Each call starts a fresh run at most every
-- `every` seconds, its output going to a file, and returns what the previous run wrote (nil before the first).
-- (macOS: the per-user TMPDIR, not the shared /tmp: the Syncthing check's script carries its API key)
local TMP = (WIN and (os.getenv("TEMP") or os.getenv("TMP")) or os.getenv("TMPDIR") or "/tmp"):gsub("\\", "/"):gsub("/+$", "")
local started, last = {}, {}
local function background(name, cmd, every)
  local file = TMP .. "/bandsync-" .. name .. ".txt"
  if not started[name] or reaper.time_precise() - started[name] > every then
    started[name] = reaper.time_precise()
    -- shortcut: written in place (these outputs are a few hundred bytes); a half-written read just looks like "no answer" once
    if WIN then -- through a hidden-window runner: `cmd /c` without waiting flashes a console window (seen 0.9.7)
      local bat, vbs = TMP .. "/bandsync-" .. name .. ".cmd", TMP .. "/bandsync-hidden.vbs"
      pcall(band.write_atomic, bat, string.format('@%s > "%s" 2>nul\r\n', cmd, file)) -- (its last run may still hold it, from another script: the same words are there already)
      if not reaper.file_exists(vbs) then band.write_atomic(vbs, 'CreateObject("WScript.Shell").Run """" & WScript.Arguments(0) & """", 0, False\r\n') end
      reaper.ExecProcess(string.format('wscript.exe //B //Nologo "%s" "%s"', vbs, bat), -1)
    else -- through a script file too: macOS's ExecProcess doesn't honour \" inside a quoted argument, so any command
      -- with quotes in it (the curl's -H "X-API-Key: ...") silently never ran (Mac, 2026-10-28). Grouped, so the
      -- whole command's output lands in the file, not only the part after a ||.
      local sh = TMP .. "/bandsync-" .. name .. ".sh"
      band.write_atomic(sh, "{ " .. cmd .. "; } > '" .. file .. "' 2>/dev/null\n")
      reaper.ExecProcess("/bin/sh '" .. sh .. "'", -1)
    end
  end
  local out = band.read(file)
  if out and out:match("%S") then last[name] = out end -- a run that has just started truncates the file: keep the last answer
  return last[name]
end

-- Whether a process named `exe` (e.g. "syncthing") is running. Answers from the last background check
-- (at most ~15 s old); the very first time, it waits for one.
-- `fresh`: ask now and wait (the background answer can be up to 15 s old: before starting something, that's too old)
function services.running(exe, fresh)
  local out = not fresh and background("ps-" .. exe, WIN and ('tasklist /FI "IMAGENAME eq ' .. exe .. '.exe" /NH') or ("/usr/bin/pgrep -x " .. exe .. " || echo none"), 15)
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
  local sh = TMP .. "/bandsync-launch.sh" -- a script file, not sh -c "...": see background()
  band.write_atomic(sh, cmd .. "\n")
  return reaper.ExecProcess("/bin/sh '" .. sh .. "'", -1) ~= nil
end

local function first_existing(list)
  for _, p in ipairs(list) do if p and p ~= "" and reaper.file_exists(p) then return p end end
end

function services.syncthing_path()
  local set = reaper.GetExtState(band.SECTION, "syncthing_path")
  local lad = (os.getenv("LOCALAPPDATA") or ""):gsub("\\", "/")
  return first_existing({ set,
    lad .. "/Microsoft/WinGet/Links/syncthing.exe", "C:/Program Files/Syncthing/syncthing.exe", lad .. "/Programs/Syncthing/syncthing.exe",
    "/Applications/Syncthing.app/Contents/Resources/syncthing/syncthing", -- (the Mac app before a Homebrew copy: the installer's)
    "/opt/homebrew/bin/syncthing", "/usr/local/bin/syncthing", "/usr/bin/syncthing" })
end

-- Make sure Syncthing runs. Returns "running", "started", or nil + why.
function services.ensure_syncthing()
  if services.running("syncthing", true) then return "running" end
  local path = services.syncthing_path()
  if not path then return nil, "Syncthing isn't running and wasn't found (set its path: ExtState BandSync/syncthing_path)" end
  -- on a Mac with Syncthing.app: the app starts it (its own copy, started beside the app, found the database and
  -- ports taken when the app opened later, or at login)
  if path:find("/Syncthing.app/", 1, true) then
    os.execute("/usr/bin/open -gja Syncthing")
    return "started"
  end
  if not launch(path, { "serve", "--no-browser" }) then return nil, "couldn't start " .. path end
  return "started"
end

-- The band folder's Syncthing settings for live use: changes are picked up within a second and, while files keep
-- changing (a live MIDI stream writes one a second), offered to the others at least every 2 s; left at 0 (the
-- default), Syncthing held them back about 7 s at a time (2026-10-28, laptop -> PC). Checked once per Live sync
-- start; only what differs is set. Returns what it set ({} when nothing), or nil + why.
services.WATCH = { ["fswatcher-enabled"] = "true", ["fswatcher-delays"] = "1", ["fswatcher-timeouts"] = "2" }
function services.tune_band_folder(folder)
  folder = folder or "bandsync" -- (each band's own Syncthing folder: band.info)
  local st = services.syncthing_path()
  if not st then return nil, "Syncthing wasn't found" end
  local set = {}
  for key, want in pairs(services.WATCH) do
    local got = (reaper.ExecProcess(q(st) .. " cli config folders " .. folder .. " " .. key .. " get", 8000) or ""):match("^0\n(.-)%s*$")
    if not got then return nil, "Syncthing didn't answer (is it running, with a folder called " .. folder .. "?)" end
    if tonumber(got) and tonumber(want) and tonumber(got) == tonumber(want) or got == want then -- (2 and 2.0 alike)
    else
      local r = reaper.ExecProcess(q(st) .. " cli config folders " .. folder .. " " .. key .. " set " .. want, 8000) or ""
      if not r:match("^0\n") then return nil, "couldn't set " .. key .. ": " .. r:gsub("^%d+\n", "") end
      set[#set + 1] = key .. " " .. got .. " -> " .. want
    end
  end
  table.sort(set)
  return set
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
-- Syncthing's API, from its own config: the start of a curl command for `path`, or nil + why.
local function st_api(path, method)
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
  return string.format('curl -s -m 3 %s%s-H "X-API-Key: %s" "%s://%s%s"', tls and "-k " or "", method and ("-X " .. method .. " ") or "",
    key, tls and "https" or "http", addr, path)
end
-- Syncthing's REST answer, now: for what someone just asked for, not for every frame. -> the text, or nil.
local function run_now(cmd, secs)
  if not WIN then
    local sh = TMP .. "/bandsync-ask.sh"
    band.write_atomic(sh, cmd .. "\n")
    cmd = "/bin/sh '" .. sh .. "'"
  end
  local r = reaper.ExecProcess(cmd, (secs + 1) * 1000) or ""
  if not r:match("^0\n") then return nil end
  local out = r:gsub("^0\n", "")
  return out ~= "" and out or nil
end
function services.ask(path, secs)
  local cmd = st_api(path)
  if not cmd then return nil end
  return run_now((cmd:gsub("%-m 3 ", "-m " .. (secs or 3) .. " ", 1)), secs or 3)
end
-- Have Syncthing scan a folder now (it reads a changed .stignore then: lib/songsync.lua). In the background.
function services.rescan(folder)
  local cmd = st_api("/rest/db/scan?folder=" .. folder, "POST")
  if cmd then background("syncthing-rescan", cmd, 0) end
end
function services.syncthing_peers_now()
  local cmd, why = st_api("/rest/system/connections")
  if not cmd then return nil, why end
  local out = background("syncthing-connections", cmd, 20) or ""
  local data = band.json_decode(out)
  if type(data) ~= "table" or type(data.connections) ~= "table" then return nil, "Syncthing didn't answer" end
  local n, on = 0, 0
  for _, c in pairs(data.connections) do n = n + 1; if c.connected then on = on + 1 end end
  return on, n
end

-- Machines asking Syncthing to connect that it doesn't know yet (a bandmate's installer pairs with the host):
-- { { id, name, address } }. Answers from a background check at most 20 s old ({} before the first).
function services.pending_devices()
  local st = services.syncthing_path()
  local data = st and band.json_decode(background("st-pending", q(st) .. " cli show pending devices", 20) or "")
  local list = {}
  for id, d in pairs(type(data) == "table" and data or {}) do
    if type(d) == "table" and services.is_device_id(id) then list[#list + 1] = { id = id, name = tostring(d.name or ""), address = tostring(d.address or "") } end
  end
  table.sort(list, function(a, z) return a.id < z.id end)
  return list
end

-- Syncthing forgets a machine that asked: it's only listed again if it asks again. In the background.
function services.dismiss_pending(id)
  if not services.is_device_id(id) then return end
  local cmd = st_api("/rest/cluster/pending/devices?device=" .. id, "DELETE")
  if cmd then background("st-dismiss", cmd, 0) end
end

-- This machine's Syncthing device ID, or nil (Syncthing not running, or no answer yet: a background check).
function services.my_device_id()
  local st = services.syncthing_path()
  local data = st and band.json_decode(background("st-system", q(st) .. " cli show system", 300) or "")
  local id = type(data) == "table" and data.myID
  return services.is_device_id(id) and id or nil
end

-- What a set-up bandmate sends someone new: one line to paste on a Mac and one on Windows, each running the
-- installer with this machine's ID already in it, so nobody types an ID (Mac, 2026-10-31: "2MOGZMD" + Return was
-- the first try). The ?<time> keeps GitHub's cache from handing out an installer from before the last release.
-- With the band (band.info): its folder id and name ride along, so the installer joins that band.
function services.invite_text(id, info)
  info = info or { id = "bandsync", name = "the studio" }
  local base = "https://raw.githubusercontent.com/FmsJay/studiosync/main/installer/"
  local q1 = function(s) return "'" .. tostring(s):gsub("'", "") .. "'" end -- (band names are plain: band.clean)
  return "Join " .. info.name .. " on StudioSync.\n\n" ..
    "Already have StudioSync? In its panel, open your studios, press Paste join code, and paste this message:\n" ..
    services.join_code(id, info) .. "\n\n" ..
    "New to it? Paste ONE of these:\n\n" ..
    "Mac (in Terminal):\n" ..
    'curl -fsSL "' .. base .. 'install_mac.sh?$(date +%s)" | BS_HOST_ID=' .. id .. " BS_BAND_ID=" .. info.id ..
    " BS_BAND_NAME=" .. q1(info.name) .. " bash\n\n" ..
    "Windows (in PowerShell):\n" ..
    '$f="$env:TEMP\\studiosync_install.ps1"; iwr -UseBasicParsing "' .. base .. 'install_windows.ps1?$(Get-Random)" -OutFile $f; ' ..
    "powershell -NoProfile -ExecutionPolicy Bypass -File $f -HostId " .. id .. " -BandId " .. info.id .. " -BandName " .. q1(info.name) .. "\n\n" ..
    "When it's done, tell me: I let you in from my StudioSync panel."
end

-- The line that gets someone with StudioSync into a studio, in an invitation.
function services.join_code(id, info) return "studiosync-join:" .. id .. ":" .. info.id .. ":" .. tostring(info.name):gsub("[\r\n]", "") end
-- What was pasted: the code, on its own or in the whole message, or an invitation from before there were codes (the installer's own lines). -> { id, band, name }, or nil. Pure.
function services.parse_join(text)
  text = tostring(text or "")
  local id, folder, name = text:match("studiosync%-join:([%u%d%-]+):([%w%-]+):([^\r\n]*)")
  if not id then id, folder, name = text:match("%-HostId%s+([%u%d%-]+)%s+%-BandId%s+([%w%-]+)%s+%-BandName%s+'([^'\r\n]*)'") end
  if not id then id, folder, name = text:match("BS_HOST_ID=([%u%d%-]+)%s+BS_BAND_ID=([%w%-]+)%s+BS_BAND_NAME='([^'\r\n]*)'") end
  if not id or not services.is_device_id(id) then return nil end
  return { id = id, band = folder:lower(), name = (name:gsub("[^%w%-_ ]", ""):match("^%s*(.-)%s*$")) }
end
-- Into a studio from a code, with StudioSync already here: what an invitation's installer does (the folder, the pairing), and nothing else to install. Whoever invited
-- you then sees Let them in. -> its folder, or nil + why.
function services.join_band(cfg, code)
  local st = services.syncthing_path()
  if not st then return nil, "Syncthing wasn't found" end
  if code.id == services.my_device_id() then return nil, "That's your own join code: send it to whoever you're inviting." end
  for _, x in ipairs(band.bands()) do
    if x.id == code.band and not require("groups").is_old(x.root) then band.use_band(x.root); return x.root, "already" end
  end
  local name = code.name ~= "" and code.name or code.band
  local here = ((cfg.base or cfg).root or ""):gsub("[/\\]+$", "")
  local parent = here:match("^(.*)[/\\][^/\\]+$") or here
  local root, n = parent .. "/StudioSync " .. name, 1
  while band.subdirs(root)[1] and band.info(root).id ~= code.band do n = n + 1; root = parent .. "/StudioSync " .. name .. " " .. n end -- (strangers' studios can share a name)
  reaper.RecursiveCreateDirectory(root, 0)
  reaper.SetExtState(band.SECTION, "joining " .. root, band.json_encode({ name = name, id = code.band }), true) -- (who this folder is, until its own _band/band.json arrives)
  if not reaper.file_exists(root .. "/.stignore") then -- (each project in full once it's opened; the rest as a listing)
    band.write_atomic(root .. "/.stignore", table.concat(require("songsync").block({}), "\n") .. "\n")
  end
  local r = reaper.ExecProcess(q(st) .. " cli config folders add --id " .. code.band .. " --label " .. q("StudioSync " .. name) .. " --path " .. q(root), 15000) or ""
  if not r:match("^0\n") and not (reaper.ExecProcess(q(st) .. " cli config folders " .. code.band .. " label get", 8000) or ""):match("^0\n") then
    return nil, "Syncthing didn't add the studio's folder: " .. r:gsub("^%d+\n", "")
  end
  reaper.ExecProcess(q(st) .. " cli config folders " .. code.band .. " order set smallestFirst", 8000)
  services.tune_band_folder(code.band)
  if not (reaper.ExecProcess(q(st) .. " cli config devices " .. code.id .. " name get", 8000) or ""):match("^0\n") then
    r = reaper.ExecProcess(q(st) .. " cli config devices add --device-id " .. code.id .. " --name " .. q("Collaborator") .. " --introducer --auto-accept-folders", 15000) or ""
    if not r:match("^0\n") then return nil, "Syncthing didn't pair with them: " .. r:gsub("^%d+\n", "") end
  end
  reaper.ExecProcess(q(st) .. " cli config folders " .. code.band .. " devices add --device-id " .. code.id, 15000)
  require("groups").forget_old(root) -- (back in one you'd left)
  band.use_band(root)
  return root
end

-- A bandmate already known here offering a band's folder: someone in one of your bands joining another of them (an
-- invitation's installer shares that band's folder with you). { { folder, id, name } }, from a background check at
-- most 20 s old. (A new machine is a pending device instead: pending_devices.)
function services.pending_folders()
  local st = services.syncthing_path()
  local data = st and band.json_decode(background("st-pending-folders", q(st) .. " cli show pending folders", 20) or "")
  local list = {}
  for folder, f in pairs(type(data) == "table" and data or {}) do
    for id in pairs(type(f) == "table" and type(f.offeredBy) == "table" and f.offeredBy or {}) do
      if services.is_device_id(id) then list[#list + 1] = { folder = folder, id = id } end
    end
  end
  table.sort(list, function(a, z) return a.folder .. a.id < z.folder .. z.id end)
  return list
end
-- A device's name in Syncthing (what its owner called their computer), or its ID's first 7 characters.
function services.device_name(id)
  local st = services.syncthing_path()
  local r = st and reaper.ExecProcess(q(st) .. " cli config devices " .. id .. " name get", 8000) or ""
  return r:match("^0\n(.-)%s*$") or id:sub(1, 7)
end
-- Share a band's folder with a machine Syncthing already knows. Returns true, or nil + why.
function services.share_folder(folder, id)
  local st = services.syncthing_path()
  if not st then return nil, "Syncthing wasn't found" end
  if not services.is_device_id(id) then return nil, "not a device ID: " .. tostring(id) end
  local r = reaper.ExecProcess(q(st) .. " cli config folders " .. folder .. " devices add --device-id " .. id, 15000) or ""
  if not r:match("^0\n") then return nil, "Syncthing didn't share it: " .. r:gsub("^%d+\n", "") end
  return true
end

-- A Syncthing device ID: 8 groups of 7 letters/digits.
local ID_PATTERN = "^" .. ("[%u%d]"):rep(7) .. ("%-" .. ("[%u%d]"):rep(7)):rep(7) .. "$"
function services.is_device_id(id)
  return type(id) == "string" and id:match(ID_PATTERN) ~= nil
end

-- Whether an address ("100.97.1.2:22000", "[fd7a:115c:a1e0::1]:22000") is on Tailscale (100.64.0.0/10, or its
-- fd7a:115c:a1e0::/48): with the band on one Tailscale account, only the band's own machines are there.
function services.on_tailnet(address)
  local a, b = (address or ""):match("^%[?(%d+)%.(%d+)%.%d+%.%d+")
  if a then return tonumber(a) == 100 and tonumber(b) >= 64 and tonumber(b) <= 127 end
  return (address or ""):lower():match("^%[?fd7a:115c:a1e0:") ~= nil
end

-- A band's Syncthing folder id from its name: "bandsync-" and the name in lower case, letters, digits and dashes. Pure.
function services.band_id(name)
  local slug = (name or ""):lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  return "studiosync-" .. (slug ~= "" and slug or "band")
end

-- Start a band (docs/bands-design.md): its own shared folder beside this band's (<parent>/StudioSync <Name>), with
-- _band/band.json saying who it is, and its own Syncthing folder (shared with nobody yet: Invite a bandmate). This
-- computer then works in it. Returns its folder, or nil + why.
function services.new_band(cfg, name)
  name = band.clean(name or "")
  if name == "" then return nil, "Give the studio a name." end
  local st = services.syncthing_path()
  if not st then return nil, "Syncthing wasn't found" end
  -- (the end is random: two strangers' groups can have one name, and someone could be in both)
  local id = services.band_id(name) .. string.format("-%04x", (os.time() * 7 + math.floor(reaper.time_precise() * 1000)) % 65536)
  for _, x in ipairs(band.bands()) do
    if x.id == id or x.name:lower() == name:lower() then return nil, "You're already in a studio called " .. x.name .. "." end
  end
  local here = ((cfg.base or cfg).root or ""):gsub("[/\\]+$", "")
  local root = (here:match("^(.*)[/\\][^/\\]+$") or here) .. "/StudioSync " .. name
  if band.subdirs(root)[1] then return nil, root .. " is already there: pick another name, or remove that folder." end
  reaper.RecursiveCreateDirectory(root .. "/_band", 0)
  band.write_json(root .. "/_band/band.json", { name = name, id = id, drive = "StudioSync - " .. name, owner = (cfg.base or cfg).user })
  local r = reaper.ExecProcess(q(st) .. " cli config folders add --id " .. id .. " --label " .. q("StudioSync " .. name) .. " --path " .. q(root), 15000) or ""
  if not r:match("^0\n") then return nil, "Syncthing didn't add the studio's folder: " .. r:gsub("^%d+\n", "") end
  reaper.ExecProcess(q(st) .. " cli config folders " .. id .. " order set smallestFirst", 8000)
  services.tune_band_folder(id)
  band.use_band(root)
  return root
end

-- How long since anyone else in a folder was online: days, from Syncthing's own stats (read in the background, at most every 5 minutes).
-- nil when it can't tell, or there's nobody yet, or they've never connected (someone waiting to be let in).
function services.quiet_days(stats, peers, now)
  local newest
  for _, id in ipairs(peers) do
    local d = type(stats) == "table" and stats[id]
    local y, mo, da, h, mi = tostring(type(d) == "table" and d.lastSeen or ""):match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+)")
    if y and tonumber(y) > 2000 then
      local t = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(da), hour = tonumber(h), min = tonumber(mi) })
      if not newest or t > newest then newest = t end
    end
  end
  return newest and math.floor((now - newest) / 86400) or nil
end
function services.days_quiet(id)
  local st = services.syncthing_path()
  local cmd = st_api("/rest/stats/device")
  if not (st and cmd) then return nil end
  local stats = band.json_decode(background("st-stats", cmd, 300) or "")
  local me, peers = services.my_device_id(), {}
  for d in (background("st-peers-" .. id, q(st) .. " cli config folders " .. id .. " devices list", 300) or ""):gmatch("[^\r\n]+") do
    if d ~= me then peers[#peers + 1] = d end
  end
  return services.quiet_days(stats, peers, os.time())
end
function services.set_folder_label(id, label)
  local st = services.syncthing_path()
  if st then reaper.ExecProcess(q(st) .. " cli config folders " .. id .. " label set " .. q(label), 8000) end
end
-- This computer stops syncing a group's folder, and forgets the computers only that folder had. Its files stay. -> true when it's gone.
function services.forget_folder(id)
  local st = services.syncthing_path()
  if not st then return false end
  local function lines(cmd)
    local r = reaper.ExecProcess(q(st) .. " cli config " .. cmd, 8000) or ""
    local out = {}
    if r:match("^0\n") then for l in r:gsub("^0\n", ""):gmatch("[^\r\n]+") do out[#out + 1] = l end end
    return out, r:match("^0\n") ~= nil
  end
  local listed, ok = lines("folders list")
  if not ok then return false end
  local there = false
  for _, f in ipairs(listed) do there = there or f == id end
  if not there then return true end
  local peers = lines("folders " .. id .. " devices list")
  if not (reaper.ExecProcess(q(st) .. " cli config folders " .. id .. " delete", 15000) or ""):match("^0\n") then return false end
  local me = services.my_device_id()
  for _, d in ipairs(peers) do
    local used = d == me or not me -- (who "me" is unknown: nobody is forgotten)
    for _, f in ipairs(listed) do
      if f ~= id and not used then
        for _, x in ipairs((lines("folders " .. f .. " devices list"))) do used = used or x == d end
      end
    end
    if not used then reaper.ExecProcess(q(st) .. " cli config devices " .. d .. " delete", 15000) end
  end
  return true
end

-- Add a machine to Syncthing and share a band's folder (`folder`: its Syncthing id, "bandsync" for the first band)
-- with it, and only that one. Returns true, or nil + why.
-- Stop sharing a band's folder with a machine, and forget the machine if no other folder has it. Nothing is deleted on either side.
-- Returns true (also when it wasn't shared), or nil + why.
function services.unshare(folder, id)
  local st = services.syncthing_path()
  if not st then return nil, "Syncthing wasn't found" end
  if not services.is_device_id(id) then return nil, "not a device ID: " .. tostring(id) end
  local function has(f) return (reaper.ExecProcess(q(st) .. " cli config folders " .. f .. " devices list", 8000) or ""):find(id, 1, true) ~= nil end
  if has(folder) then
    local r = reaper.ExecProcess(q(st) .. " cli config folders " .. folder .. " devices " .. id .. " delete", 15000) or ""
    if not r:match("^0\n") then return nil, "Syncthing didn't stop sharing: " .. r:gsub("^%d+\n", "") end
  end
  local listed = reaper.ExecProcess(q(st) .. " cli config folders list", 8000) or ""
  if not listed:match("^0\n") then return true end -- (the folder's done; a machine left known does no harm)
  for f in listed:gsub("^0\n", ""):gmatch("[^\r\n]+") do if has(f) then return true end end
  reaper.ExecProcess(q(st) .. " cli config devices " .. id .. " delete", 15000)
  return true
end
function services.add_device(id, name, folder)
  local st = services.syncthing_path()
  if not st then return nil, "Syncthing wasn't found" end
  if not services.is_device_id(id) then return nil, "not a device ID: " .. tostring(id) end
  name = (name or ""):gsub("[^%w%-_ ]", "")
  local r1 = reaper.ExecProcess(q(st) .. " cli config devices add --device-id " .. id .. (name ~= "" and (" --name " .. q(name)) or ""), 15000) or ""
  local r2 = folder and reaper.ExecProcess(q(st) .. " cli config folders " .. folder .. " devices add --device-id " .. id, 15000) or "0\n"
  if not r1:match("^0\n") then return nil, "Syncthing didn't add it: " .. r1:gsub("^%d+\n", "") end
  if not r2:match("^0\n") then return nil, "added, but the studio folder wasn't shared with it: " .. r2:gsub("^%d+\n", "") end
  return true
end
-- Who's asking to join, among the studios `me` may let people into. A computer not known here yet can't say which studio it wants: Syncthing shows that
-- only once it's known, as a folder it offers. So letting one in adds just the computer, and the studio comes after. (It went into whichever studio the
-- tab in front was in, invited or not, and a person with no tab or a tab in a studio they don't run never saw the request: 0.52.4.)
local asker_names = {}
function services.join_asks(me)
  local groups = require("groups")
  local ask, mine, any = {}, {}, false
  for _, x in ipairs(band.bands()) do
    if not groups.is_old(x.root) and groups.may_manage(x.root, me) then mine[x.id], any = x, true end
  end
  if any then for _, d in ipairs(services.pending_devices()) do ask[#ask + 1] = d end end
  for _, f in ipairs(services.pending_folders()) do
    local x = mine[f.folder]
    if x then
      asker_names[f.id] = asker_names[f.id] or services.device_name(f.id)
      ask[#ask + 1] = { id = f.id, name = asker_names[f.id], folder = f.folder, band = x.name, root = x.root }
    end
  end
  return ask
end

local function tailscale_exe()
  return first_existing({ "C:/Program Files/Tailscale/tailscale.exe", "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
    "/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale", "/usr/bin/tailscale" })
end
function services.tailscale_installed() return tailscale_exe() ~= nil end
-- Running and signed in? Asked at most every 20 s: it's for a Health row. Pure part: services.tailscale_running_in.
function services.tailscale_running_in(json) return json:find('"BackendState":%s*"Running"') ~= nil end
local ts_at, ts_up = -math.huge, false
function services.tailscale_up()
  local exe = tailscale_exe()
  if not exe then return false end
  if reaper.time_precise() - ts_at > 20 then
    ts_at = reaper.time_precise()
    ts_up = services.tailscale_running_in(reaper.ExecProcess(q(exe) .. " status --json --peers=false", 5000) or "")
  end
  return ts_up
end
-- From `tailscale status --json --peers=false`: this machine's name, if the tailnet's names work ("pc.tail1234.ts.net", no last dot).
function services.tailscale_name_in(json)
  if not json:find('"MagicDNSEnabled":%s*true') then return nil end
  return json:match('"Self":%s*{.-"DNSName":%s*"([^"]-)%.?"')
end
-- How others reach this machine over Tailscale: its name (a 100.x address changes: the PC's did), or that address if the
-- tailnet has names turned off; nil when Tailscale isn't installed or signed in.
function services.tailscale_address()
  local exe = tailscale_exe()
  if not exe then return nil end
  local name = services.tailscale_name_in(reaper.ExecProcess(q(exe) .. " status --json --peers=false", 5000) or "")
  if name and name ~= "" then return name end
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
  if not exe then return nil, "set the NINJAM server folder (the one with ninjamsrv and bandsync.cfg) on the panel's Live page" end
  if not reaper.file_exists(dir .. "/bandsync.cfg") then return nil, "no bandsync.cfg in " .. dir end
  if not launch(exe, { "bandsync.cfg" }, dir) then return nil, "couldn't start " .. exe end
  return "started"
end

return services
