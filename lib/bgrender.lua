-- Prints rendered in the background (James, 2026-11-01: render wet takes so people can keep editing meanwhile).
-- REAPER renders only in the project in front, holding its window until done. A second REAPER, started hidden on a
-- saved copy with -renderproject, renders while this one carries on: the copy is saved set up exactly as the
-- render in front would be (band.render saves it instead of rendering when a job is open), then that's put back.
-- Measured on the PC (REAPER 7.84): a short MIDI print through a VST3 instrument took ~4 s, no window in front.
-- The copy keeps every track (routing still points at the right ones) with the plug-ins of the tracks the print
-- doesn't go through switched offline, so only what it needs loads.
-- Costs: the second REAPER writes reaper.ini when it quits (as it read it when it started) and puts the copy in the
-- recent-projects list; this REAPER writes its own over both when it quits. Where background renders don't work
-- (two failures, none done), prints render in front again for the rest of the session.
local band = require("band")
local bg = {}

local WIN = reaper.GetOS():find("^Win") ~= nil
local TMP = ((WIN and (os.getenv("TEMP") or os.getenv("TMP")) or os.getenv("TMPDIR") or "/tmp"):gsub("\\", "/"):gsub("/+$", "")) .. "/bandsync-render"
bg.WAIT = 180 -- seconds before a job that hasn't finished counts as failed
local jobs = {} -- name -> { dir, started, sizes, at }
local done, failed = 0, 0

-- Whether prints go to the background here (ExtState "bg render" = "off" turns it off for good).
-- On a Mac only when switched on: a second REAPER there takes the keyboard for ~0.7 s, shows a "Scanning VST
-- plugins" box and a second Dock icon, and `open -j -g` was worse (Mac, 0.39.0): there's no hidden desktop to put it on.
function bg.on()
  local set = reaper.GetExtState(band.SECTION, "bg render")
  if set == "off" or (not WIN and set ~= "on") then return false end
  if failed >= 2 and done == 0 then return false end
  return WIN or reaper.GetOS():find("^OSX") ~= nil or reaper.GetOS():find("^macOS") ~= nil
end
function bg.default_on() return WIN end

-- The copy, ready for the second REAPER: the plug-ins of every track not in `keep` (REAPER track GUIDs) and the
-- master's switched offline (BYPASS <bypass> <offline> ...). A stem of the selected track (RENDER_STEMS 2: a
-- routed MIDI print, sync.print_routed) finds "Nothing to render!" from the command line (PC, 0.37.0), so that one
-- renders the master mix instead: every other track muted, no folders (a parent's plug-ins and fader stay out, as
-- in a stem), the kept tracks sent to the master, the master's fader at 0 dB. BandSync's own project state goes
-- (<EXTSTATE>'s BANDSYNC blocks): the copy isn't the band's song, so opened from Recent projects it's just a project.
-- Pure.
function bg.prepare(text, keep)
  local mix = tonumber(text:match("\n%s*RENDER_STEMS (%d+)")) == 2
  local out, depth, inside, keeping, skip = {}, 0, nil, true, nil
  for raw in text:gmatch("[^\n]*\n?") do
    if raw == "" then break end
    local line = raw
    local s = line:match("^%s*(.-)%s*$")
    if not skip and depth == 2 and inside == "EXTSTATE" and s:match("^<BANDSYNC") then skip = depth end
    if depth == 1 and s:sub(1, 1) == "<" then
      local guid = s:match("^<TRACK%s+(%b{})")
      inside, keeping = s:match("^<(%S+)"), guid ~= nil and keep[guid:upper()] or false
    end
    if (inside == "TRACK" or inside == "MASTERFXLIST") and not keeping then
      line = line:gsub("^(%s*BYPASS %d+ )%d+", "%11")
    end
    if mix then
      if depth == 1 then
        line = line:gsub("^(%s*RENDER_STEMS )%d+", "%10"):gsub("^(%s*MASTER_VOLUME )%S+ %S+", "%11 0"):gsub("^(%s*MASTERMUTESOLO )%d+", "%10")
      elseif depth == 2 and inside == "TRACK" then
        line = line:gsub("^(%s*ISBUS )%S+ %S+", "%10 0")
        if keeping then line = line:gsub("^(%s*MAINSEND )%d+", "%11")
        else line = line:gsub("^(%s*MUTESOLO )%d+", "%11") end
      end
    end
    if s:sub(1, 1) == "<" then depth = depth + 1 elseif s == ">" then depth = depth - 1 end
    if depth == 1 and s == ">" then inside, keeping = nil, true end
    if skip then
      if depth == skip then skip = nil end -- (its closing line, left out too)
    else
      out[#out + 1] = line
    end
  end
  return table.concat(out)
end

-- Windows: the second REAPER starts on a Windows desktop of its own (CreateDesktop), so nothing it shows can be seen
-- or take the keyboard. Started plainly, its scan box, its window (maximised, as REAPER was last left) and the
-- render box covered the screen for ~1.5 s on every print and took the keys (laptop, 0.37.0): -noactivate and a
-- hidden .cmd don't stop that. The launcher stays until that REAPER quits (a desktop goes with its last handle),
-- writes its process id to pid.txt, and tidies empty job folders.
local LAUNCH = [==[
param($exe, $job, $res, $profile)
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class BandSyncDesk {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] public struct SI { public int cb; public string reserved; public string desktop; public string title;
    public int x, y, w, h, xc, yc, fill, flags; public short show, reserved2; public IntPtr reserved3, stdin, stdout, stderr; }
  [StructLayout(LayoutKind.Sequential)] public struct PI { public IntPtr process, thread; public int pid, tid; }
  [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern IntPtr CreateDesktop(string name, IntPtr device, IntPtr mode, int flags, uint access, IntPtr sa);
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern bool CreateProcess(string app, string cmd, IntPtr pa, IntPtr ta, bool inherit, int flags, IntPtr env, string dir, ref SI si, out PI pi);
}
"@
$dir = Split-Path $job
# the render profile's links (bg.profile): this REAPER's Effects and Data, and its plug-ins (UserPlugins\FX) only
foreach ($d in "Effects", "Data") {
  $l = Join-Path $profile $d
  if (-not (Test-Path $l) -and (Test-Path (Join-Path $res $d))) { New-Item -ItemType Junction -Path $l -Target (Join-Path $res $d) | Out-Null }
}
New-Item -ItemType Directory -Force (Join-Path $profile "UserPlugins") | Out-Null
$fx = Join-Path $profile "UserPlugins\FX"
if (-not (Test-Path $fx) -and (Test-Path (Join-Path $res "UserPlugins\FX"))) { New-Item -ItemType Junction -Path $fx -Target (Join-Path $res "UserPlugins\FX") | Out-Null }
# job folders done with: empty ones, and any an hour old (its item went before its print was picked up: laptop, 0.40.0)
Get-ChildItem (Split-Path $dir) -Directory -ErrorAction SilentlyContinue | Where-Object { $_.FullName -ne $dir -and $_.Name -ne "profile" -and -not $_.LinkType -and
  (-not (Get-ChildItem $_.FullName -Force) -or $_.LastWriteTime -lt (Get-Date).AddHours(-1)) } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
$desk = [BandSyncDesk]::CreateDesktop("BandSyncRender", [IntPtr]::Zero, [IntPtr]::Zero, 0, 0x10000000, [IntPtr]::Zero)
$si = New-Object BandSyncDesk+SI
$si.cb = [Runtime.InteropServices.Marshal]::SizeOf($si)
$si.desktop = "BandSyncRender"
$pi = New-Object BandSyncDesk+PI
$cmd = '"' + $exe + '" -newinst -nosplash -ignoreerrors -noactivate -cfgfile "' + (Join-Path $profile "reaper.ini") + '" -renderproject "' + $job + '"'
$env:BANDSYNC_RENDER = "1" # (inherited: Scripts/__startup.lua's guard skips the person's startup scripts in it)
# ([NullString]::Value, not $null: PowerShell passes $null to a string parameter as "", and CreateProcess refuses "")
if ($desk -ne [IntPtr]::Zero -and [BandSyncDesk]::CreateProcess([NullString]::Value, $cmd, [IntPtr]::Zero, [IntPtr]::Zero, $false, 0, [IntPtr]::Zero, [NullString]::Value, [ref]$si, [ref]$pi)) {
  Set-Content (Join-Path $dir "pid.txt") $pi.pid
  try { Wait-Process -Id $pi.pid -Timeout 600 -ErrorAction SilentlyContinue } catch {}
} else { Set-Content (Join-Path $dir "pid.txt") "failed" }
]==]

-- ---- the render profile (0.40) ------------------------------------------------------------------------------------
-- The second REAPER runs with a settings folder of its own (-cfgfile, James, 2026-11-01): links to this REAPER's
-- Effects and Data and to its plug-ins (UserPlugins/FX), but none of its extensions: started plainly, the second REAPER
-- loaded all of them, ReaLearn, ReaBlink (Ableton Link), MCU Live, Komplete Kontrol..., and opened the MIDI devices
-- (PC, 0.39.3). Copies of the plug-in lists (no scan: an empty folder rescanned everything and hung past 60 s) and the
-- licence, and a reaper.ini of its own, which it writes instead of this REAPER's (it rewrote it on quitting, and put
-- each job in Recent projects). The launcher makes the links; the files are refreshed here every time.
local PROFILE = TMP .. "/profile"
local COPY = { "^reaper%-vstplugins.*%.ini$", "^reaper%-vstshells.*%.ini$", "^reaper%-clap.*%.ini$", "^reaper%-auplugins.*%.ini$",
  "^reaper%-jsfx%.ini$", "^reaper%-reginfo2%.ini$" }
-- This REAPER's reaper.ini for the render profile: no MIDI devices in or out, no control surfaces (the web interface's
-- port too), no splash, no recent or last project, the audio device closed while it's in the background. Pure.
function bg.profile_ini(text)
  local out = {}
  for raw in (text or ""):gmatch("[^\r\n]+") do
    local line = raw
    local k = line:match("^([%w_]+)=")
    if k and (k:match("^midiins") or k:match("^midiouts")) and line:match("=%-?%d+$") then line = k .. "=0"
    elseif k == "csurf_cnt" then line = "csurf_cnt=0"
    elseif k and k:match("^csurf_%d+$") then line = nil
    elseif k == "splash" or k == "splash2" then line = k .. "=0"
    elseif k and (k:match("^recent%d+$") or k == "lastproject" or k == "lastprojuiref") then line = nil
    elseif k == "audiocloseinactive" then line = nil end
    if line then
      out[#out + 1] = line
      if line:upper() == "[REAPER]" then out[#out + 1] = "audiocloseinactive=1" end -- (the Mac writes [reaper]: Mac, 0.40.2)
    end
  end
  return table.concat(out, "\n") .. "\n"
end
local function profile()
  local res = reaper.GetResourcePath():gsub("\\", "/")
  reaper.RecursiveCreateDirectory(PROFILE, 0)
  for _, f in ipairs(band.files(res)) do
    for _, pat in ipairs(COPY) do
      if f:lower():match(pat) then band.copy_atomic(res .. "/" .. f, PROFILE .. "/" .. f); break end
    end
  end
  band.write_atomic(PROFILE .. "/reaper.ini", bg.profile_ini(band.read(reaper.get_ini_file())))
  return res
end
bg.PROFILE = PROFILE

local function launch(exe, job)
  local res = profile()
  if WIN then
    local cmd, vbs, ps = job:gsub("%.rpp$", ".cmd"), TMP .. "/hidden.vbs", TMP .. "/launch.ps1"
    if band.read(ps) ~= LAUNCH then band.write_atomic(ps, LAUNCH) end
    band.write_atomic(cmd, string.format('@powershell -NoProfile -ExecutionPolicy Bypass -File "%s" "%s" "%s" "%s" "%s"\r\n', ps, exe, job, res, PROFILE))
    if not reaper.file_exists(vbs) then band.write_atomic(vbs, 'CreateObject("WScript.Shell").Run """" & WScript.Arguments(0) & """", 0, False\r\n') end
    reaper.ExecProcess(string.format('wscript.exe //B //Nologo "%s" "%s"', vbs, cmd), -1)
  else -- a Mac (only when switched on: bg.on): tried on 0.39.1, renders in ~1 s but shows a window and takes the keys
    local sh = job:gsub("%.rpp$", ".sh")
    band.write_atomic(sh, string.format("find '%s' -mindepth 1 -maxdepth 1 -type d ! -name profile \\( -empty -o -mmin +60 \\) -exec rm -rf {} + 2>/dev/null\n" .. -- (job folders done with)
      "P='%s'; R='%s'\n" .. -- (the render profile's links, as on Windows)
      "for d in Effects Data; do [ -e \"$P/$d\" ] || [ ! -d \"$R/$d\" ] || ln -s \"$R/$d\" \"$P/$d\"; done\n" ..
      "mkdir -p \"$P/UserPlugins\"; [ -e \"$P/UserPlugins/FX\" ] || [ ! -d \"$R/UserPlugins/FX\" ] || ln -s \"$R/UserPlugins/FX\" \"$P/UserPlugins/FX\"\n" ..
      "BANDSYNC_RENDER=1 nohup '%s' -newinst -nosplash -ignoreerrors -noactivate -cfgfile \"$P/reaper.ini\" -renderproject '%s' >/dev/null 2>&1 &\n",
      TMP, PROFILE, res, exe, job))
    reaper.ExecProcess("/bin/sh '" .. sh .. "'", -1)
  end
end
-- (on a Mac GetExePath() is the folder holding REAPER.app, "/Applications": Mac, 0.39.0)
local function exe_path()
  local d = reaper.GetExePath():gsub("\\", "/")
  if WIN then return d .. "/reaper.exe" end
  for _, p in ipairs({ d .. "/Contents/MacOS/REAPER", d .. "/REAPER.app/Contents/MacOS/REAPER", d .. "/REAPER64.app/Contents/MacOS/REAPER", d .. "/REAPER" }) do
    if reaper.file_exists(p) then return p end
  end
  return d .. "/REAPER.app/Contents/MacOS/REAPER"
end

-- Render in the background, one print per item (`key`) at a time: `render(dir)` sets the project up and calls
-- band.render as it always does (which saves the copy into `dir` instead of rendering); `keep`: the tracks the
-- print goes through. Active tab only.
function bg.start(key, name, keep, render)
  local dir = TMP .. "/" .. name
  reaper.RecursiveCreateDirectory(dir, 0)
  for _, f in ipairs(band.files(dir)) do os.remove(dir .. "/" .. f) end
  local job = dir .. "/job.rpp"
  pcall(require("tools").render_guard) -- (the person's startup scripts don't run in it)
  band.render_job = { dir = dir, copy = job }
  local ok, err = pcall(render, dir)
  band.render_job = nil
  if not ok or not reaper.file_exists(job) then return false, err end
  local set = {}
  for _, g in ipairs(keep) do set[g:upper()] = true end
  band.write_atomic(job, bg.prepare(band.read(job), set))
  launch(exe_path(), job)
  jobs[key] = { name = name, dir = dir, started = reaper.time_precise(), sizes = {} }
  return true
end

-- A job's output files once it has finished, else nil. Finished: on Windows, they can be renamed (REAPER holds
-- them open while it writes; each is renamed and back); elsewhere, their sizes held still for 2 s.
local function finished(j)
  local files = {}
  for _, f in ipairs(band.files(j.dir)) do
    local ext = f:match("%.(%a+)$")
    if ext == "flac" or ext == "opus" then files[#files + 1] = f end
  end
  if #files < 2 then return nil end
  if WIN then
    for _, f in ipairs(files) do
      local a = j.dir .. "/" .. f
      if not os.rename(a, a .. ".x") then return nil end
      os.rename(a .. ".x", a)
    end
    return files
  end
  local now, same = reaper.time_precise(), j.at ~= nil and reaper.time_precise() - j.at >= 2
  for _, f in ipairs(files) do
    local n = band.size(j.dir .. "/" .. f)
    if not n or n == 0 or n ~= j.sizes[f] then same = false end
    j.sizes[f] = n
  end
  if same then return files end
  if not j.at or now - j.at >= 2 then j.at = now end
  return nil
end
local function drop(key)
  local j = jobs[key]
  for _, f in ipairs(band.files(j.dir)) do os.remove(j.dir .. "/" .. f) end
  jobs[key] = nil
end
local function launch_failed(j) return (band.read(j.dir .. "/pid.txt") or ""):match("^failed") ~= nil end
-- A job that's gone wrong: its REAPER (if it's still there, stuck on something nobody can see) is ended.
local function timed_out(key)
  failed = failed + 1
  local pid = tonumber((band.read(jobs[key].dir .. "/pid.txt") or ""):match("^%d+"))
  if pid and WIN then
    local kill = TMP .. "/kill.cmd"
    band.write_atomic(kill, "@taskkill /PID " .. pid .. " /T /F\r\n")
    reaper.ExecProcess(string.format('wscript.exe //B //Nologo "%s" "%s"', TMP .. "/hidden.vbs", kill), -1)
  end
  drop(key)
  band.log("a print didn't render in the background within " .. bg.WAIT .. " s: it renders here instead" ..
    ((failed >= 2 and done == 0) and " (and so will the rest this session)" or ""))
end

-- Whether a background render is still going (one at a time: each is a whole REAPER).
function bg.busy()
  for key, j in pairs(jobs) do
    if not finished(j) then
      if reaper.time_precise() - j.started <= bg.WAIT and not launch_failed(j) then return true end
      timed_out(key)
    end
  end
  return false
end

-- The item's print `name`, moved into `out` once rendered: its .flac path. Else nil and "running", "failed", or
-- nothing (no job for it, or the job was for what the item was before: that one's dropped).
function bg.claim(key, name, out)
  local j = jobs[key]
  if not j then return nil end
  local files = finished(j)
  if not files then
    if reaper.time_precise() - j.started <= bg.WAIT and not launch_failed(j) then return nil, "running" end
    timed_out(key)
    return nil, "failed"
  end
  if j.name ~= name then drop(key); return nil end
  reaper.RecursiveCreateDirectory(out, 0)
  local flac
  for _, f in ipairs(files) do
    -- (whatever the render called it: a stem render may add the track's name, a leftover a "-2")
    local ext = f:match("%.(%a+)$")
    local to = out .. "/" .. name .. "." .. ext
    os.remove(to)
    -- (one REAPER still holds can't be replaced: it's the same print, made from the same, so that one stands)
    if (os.rename(j.dir .. "/" .. f, to) or reaper.file_exists(to)) and ext == "flac" then flac = to end
  end
  drop(key)
  if flac then done = done + 1 end
  return flac, not flac and "failed" or nil
end

-- Whether any job is out (Live sync then looks every second, so a finished print goes in at once).
function bg.waiting() return next(jobs) ~= nil end

-- Prints done in the background this session, and jobs that failed (tests, Health).
function bg.counts() return done, failed end

return bg
