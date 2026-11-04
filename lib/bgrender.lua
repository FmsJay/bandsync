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
bg.MAX = 3 -- renders at once
bg.SPACING = 0.5 -- seconds between starting them
local last_start, cancelled, ini_slot = -math.huge, 0, 0
local jobs = {} -- name -> { dir, started, sizes, at }
local done, failed = 0, 0

-- The Mac's helpers (lib/mac, built by tools/mac/build.sh, shipped by ReaPack to Macs only): the folder, or nil.
-- A second REAPER on a Mac took the keyboard for ~0.7 s and showed its windows, and there's no hidden desktop to put it
-- on, so it runs from a private copy of REAPER.app that macOS treats as background-only (no focus, no Dock icon), with
-- a library that keeps its windows transparent (tools/mac/hide.m): nothing seen in 6 of 6 runs (Mac, 2026-11-01).
local LIB = (debug.getinfo(1, "S").source or ""):match("^@?(.*)[/\\][^/\\]+$") or "."
function bg.helpers()
  local d = LIB .. "/mac"
  if not WIN and reaper.file_exists(d .. "/bandsync-hide.dylib") and reaper.file_exists(d .. "/bandsync-launch") then return d end
end
-- Whether prints go to the background here (ExtState "bg render": "off" or "on" overrides this default).
function bg.default_on() return WIN or bg.helpers() ~= nil end
function bg.on()
  local set = reaper.GetExtState(band.SECTION, "bg render")
  if set == "off" or (not bg.default_on() and set ~= "on") then return false end
  if failed >= 2 and done == 0 then return false end
  return WIN or reaper.GetOS():find("^OSX") ~= nil or reaper.GetOS():find("^macOS") ~= nil
end

-- The copy, ready for the second REAPER: the plug-ins of every track not in `keep` (REAPER track GUIDs) and the
-- master's switched offline (BYPASS <bypass> <offline> ...). A stem of the selected track (RENDER_STEMS 2: a
-- routed MIDI print, sync.print_routed) finds "Nothing to render!" from the command line (PC, 0.37.0), so that one
-- renders the master mix instead: every other track muted, no folders (a parent's plug-ins and fader stay out, as
-- in a stem), the kept tracks sent to the master, the master's fader at 0 dB. StudioSync's own project state goes
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
param($exe, $job, $res, $profile, $ini)
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class StudioSyncDesk {
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
$desk = [StudioSyncDesk]::CreateDesktop("StudioSyncRender", [IntPtr]::Zero, [IntPtr]::Zero, 0, 0x10000000, [IntPtr]::Zero)
$si = New-Object StudioSyncDesk+SI
$si.cb = [Runtime.InteropServices.Marshal]::SizeOf($si)
$si.desktop = "StudioSyncRender"
$pi = New-Object StudioSyncDesk+PI
$cmd = '"' + $exe + '" -newinst -nosplash -ignoreerrors -noactivate -cfgfile "' + (Join-Path $profile $ini) + '" "' + $job + '"'
$env:BANDSYNC_RENDER = "1" # (inherited: Scripts/__startup.lua's guard skips the person's startup scripts in it)
# ([NullString]::Value, not $null: PowerShell passes $null to a string parameter as "", and CreateProcess refuses "")
if ($desk -ne [IntPtr]::Zero -and [StudioSyncDesk]::CreateProcess([NullString]::Value, $cmd, [IntPtr]::Zero, [IntPtr]::Zero, $false, 0, [IntPtr]::Zero, [NullString]::Value, [ref]$si, [ref]$pi)) {
  Set-Content (Join-Path $dir "pid.txt") $pi.pid
  try { Wait-Process -Id $pi.pid -Timeout 600 -ErrorAction SilentlyContinue } catch {}
  if (Test-Path $dir) { Set-Content (Join-Path $dir "done.txt") "1" }
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
    elseif k == "audiocloseinactive" or k == "renderclosewhendone" then line = nil end
    if line then
      out[#out + 1] = line
      -- (the Mac writes [reaper]: Mac, 0.40.2) (4: the render window closes whatever came out, a print that clips too,
      -- where nobody could click it: Mac, 0.42.2)
      if line:upper() == "[REAPER]" then out[#out + 1] = "audiocloseinactive=1"; out[#out + 1] = "renderclosewhendone=4" end
    end
  end
  return table.concat(out, "\n") .. "\n"
end
-- What the second REAPER does: its resource folder is the profile, so this is the __startup.lua it runs. -renderproject
-- renders the moment the project has loaded, and an instrument that loads its samples in the background isn't ready:
-- Superior Drummer's print came out almost silent, 17 KB against 541 KB in front, with no error (PC, 2026-11-01). So it
-- renders, and again, until two renders in a row come out about the same size, then keeps the last. A plug-in with nothing
-- to load costs one extra render. (Not the same bytes: some plug-ins never repeat exactly. Serum differed by 3%.)
bg.PASSES, bg.PASS_WAIT, bg.PASS_SAME = 10, 3, 0.10
local function pass_script()
  return string.format([==[
-- StudioSync's background render (written by lib/bgrender.lua; only the hidden REAPER runs this)
if not os.getenv("BANDSYNC_RENDER") then return end
local PASSES, WAIT, SAME = %d, %d, %.2f
local function flac_size(dir)
  for i = 0, 99 do
    local f = reaper.EnumerateFiles(dir, i)
    if not f then return 0 end
    if f:lower():match("%%.flac$") then
      local h = io.open(dir .. "/" .. f, "rb")
      if h then local n = h:seek("end"); h:close(); return n end
    end
  end
  return 0
end
local function clear(dir, into)
  local names = {}
  for i = 0, 99 do
    local f = reaper.EnumerateFiles(dir, i)
    if not f then break end
    names[#names + 1] = f
  end
  for _, f in ipairs(names) do
    if into then os.rename(dir .. "/" .. f, into .. "/" .. f) else os.remove(dir .. "/" .. f) end
  end
  os.remove(dir)
end
local started = reaper.time_precise()
local proj, dir, pass, last, at
local function step()
  if not dir then
    local p, path = reaper.EnumProjects(-1)
    if path and path:find("job.rpp", 1, true) then proj, dir = p, path:match("^(.*)[/\\]")
    elseif reaper.time_precise() - started > 60 then return reaper.Main_OnCommand(40004, 0) end
    return reaper.defer(step)
  end
  if at and reaper.time_precise() < at then return reaper.defer(step) end
  pass = (pass or 0) + 1
  local out = dir .. "/pass" .. pass
  reaper.RecursiveCreateDirectory(out, 0)
  reaper.GetSetProjectInfo_String(proj, "RENDER_FILE", out, true)
  reaper.Main_OnCommand(42230, 0) -- File: Render project, most recent settings, auto-close dialog
  local size = flac_size(out)
  local same = last and last.size > 0 and math.abs(size - last.size) <= SAME * math.max(size, last.size)
    or last and last.size == size
  if same or pass >= PASSES then
    if last then clear(last.dir) end
    clear(out, dir)
    local h = io.open(dir .. "/passes.txt", "w") -- (its print is ready, whether or not anything stops it quitting)
    if h then h:write(pass, "\n"); h:close() end
    reaper.Main_SaveProject(proj, false)
    return reaper.Main_OnCommand(40004, 0) -- File: Quit REAPER
  end
  if last then clear(last.dir) end
  last = { dir = out, size = size }
  at = reaper.time_precise() + (pass == 1 and 0 or WAIT)
  reaper.defer(step)
end
reaper.defer(step)
]==], bg.PASSES, bg.PASS_WAIT, bg.PASS_SAME)
end

-- A second REAPER rewrites its settings as it quits. One starting at that moment read half of them, lost its plug-in
-- folders, and began scanning the default one where nobody could see, holding its place until the time limit (PC, three
-- at once, 2026-11-01). So each job gets a reaper.ini of its own (a read-only one stops REAPER at a "Configuration Write
-- Error" box, waiting for an OK nobody can give), and the plug-in lists they share are read-only, rewritten only when
-- this REAPER's have changed.
local function read_only(on)
  if WIN then reaper.ExecProcess(string.format('cmd /c attrib %sR "%s\\reaper-*.ini"', on and "+" or "-", (PROFILE:gsub("/", "\\"))), 5000)
  else reaper.ExecProcess(string.format("/bin/sh -c \"chmod %s '%s'/reaper-*.ini\"", on and "a-w" or "u+w", PROFILE), 5000) end
end
local function profile()
  local res = reaper.GetResourcePath():gsub("\\", "/")
  reaper.RecursiveCreateDirectory(PROFILE, 0)
  local want = {} -- file name -> what it should hold
  for _, f in ipairs(band.files(res)) do
    for _, pat in ipairs(COPY) do
      if f:lower():match(pat) then want[f] = band.read(res .. "/" .. f); break end
    end
  end
  local stale = {}
  for f, text in pairs(want) do if text and band.read(PROFILE .. "/" .. f) ~= text then stale[#stale + 1] = f end end
  if #stale > 0 then
    read_only(false)
    for _, f in ipairs(stale) do band.write_atomic(PROFILE .. "/" .. f, want[f]) end
    read_only(true)
  end
  reaper.RecursiveCreateDirectory(PROFILE .. "/Scripts", 0)
  local script = pass_script()
  if band.read(PROFILE .. "/Scripts/__startup.lua") ~= script then band.write_atomic(PROFILE .. "/Scripts/__startup.lua", script) end
  return res
end
bg.PROFILE = PROFILE

-- What runs one job on a Mac. Pure (t: tmp, profile, res, exe, ini, job, helpers). Makes the private copy the first time
-- and again after REAPER or a helper changes (`built` says what it was made from), in a job's own script so this REAPER
-- never waits for it. pid.txt lets a job be ended; done.txt says its REAPER has quit, so its files are complete.
local MAC_JOB = [==[
find @TMP@ -mindepth 1 -maxdepth 1 -type d ! -name profile \( -empty -o -mmin +60 \) -exec rm -rf {} + 2>/dev/null
P=@PROFILE@; R=@RES@; X=@EXE@; J=@JOB@; H=@HELPERS@
D="${J%/*}"
for d in Effects Data; do [ -e "$P/$d" ] || [ ! -d "$R/$d" ] || ln -s "$R/$d" "$P/$d"; done
mkdir -p "$P/UserPlugins"; [ -e "$P/UserPlugins/FX" ] || [ ! -d "$R/UserPlugins/FX" ] || ln -s "$R/UserPlugins/FX" "$P/UserPlugins/FX"
export BANDSYNC_RENDER=1
[ -s "$P/reaper-jsfx.ini" ] || { echo failed > "$D/pid.txt"; exit 1; } # (the profile went just now: the next job makes it whole)
if [ -n "$H" ]; then
  C="$HOME/Library/Caches/StudioSync"; A="$C/REAPER-render.app"; S="${X%/Contents/MacOS/*}"; B="${X##*/}"
  W="$(stat -f '%m %z' "$X" "$H/bandsync-hide.dylib" "$H/bandsync-launch" | tr '\n' ' ')"
  mkdir -p "$C"
  find "$C/build.lock" -maxdepth 0 -mmin +5 -exec rmdir {} + 2>/dev/null
  # (the copy or a helper gone or emptied, as well as out of date: Mac, 0.42.2)
  [ -x "$A/Contents/MacOS/$B" ] && [ -s "$C/bandsync-hide.dylib" ] && [ -x "$C/bandsync-launch" ] || rm -f "$C/built"
  if [ "$(cat "$C/built" 2>/dev/null)" != "$W" ] && mkdir "$C/build.lock" 2>/dev/null; then
    rm -rf "$A" "$C/built"
    ditto "$S" "$A" && plutil -replace LSBackgroundOnly -bool YES "$A/Contents/Info.plist" && codesign --force --deep -s - "$A" &&
      cp "$H/bandsync-hide.dylib" "$H/bandsync-launch" "$C/" && xattr -c "$C/bandsync-hide.dylib" "$C/bandsync-launch" &&
      chmod +x "$C/bandsync-launch" && echo "$W" > "$C/built"
    rmdir "$C/build.lock"
  fi
  n=0
  while [ "$(cat "$C/built" 2>/dev/null)" != "$W" ] && [ -d "$C/build.lock" ] && [ "$n" -lt 240 ]; do sleep 0.5; n=$((n+1)); done
  if [ "$(cat "$C/built" 2>/dev/null)" != "$W" ]; then echo failed > "$D/pid.txt"; exit 1; fi
  nohup "$C/bandsync-launch" "$C/bandsync-hide.dylib" "$A/Contents/MacOS/$B" -newinst -nosplash -ignoreerrors -noactivate -cfgfile "$P/@INI@" "$J" >/dev/null 2>&1 &
else
  nohup "$X" -newinst -nosplash -ignoreerrors -noactivate -cfgfile "$P/@INI@" "$J" >/dev/null 2>&1 &
fi
p=$!
echo "$p" > "$D/pid.txt"
wait "$p"
echo "$?" > "$D/done.txt"
]==]
function bg.mac_script(t)
  local function q(s) return "'" .. tostring(s or ""):gsub("'", "'\\''") .. "'" end
  local vals = { TMP = q(t.tmp), PROFILE = q(t.profile), RES = q(t.res), EXE = q(t.exe), JOB = q(t.job), HELPERS = q(t.helpers), INI = t.ini }
  return (MAC_JOB:gsub("@(%u+)@", vals))
end

local function launch(exe, job)
  -- (each time: only what's changed or gone is rewritten. A profile a temp clean-up took came back with a job out as
  -- settings and no plug-in lists, and that REAPER scanned every plug-in until its time ran out: laptop, 0.42.2)
  local res = profile()
  ini_slot = ini_slot % 12 + 1 -- (a few, in turn: never one a REAPER that's just finished may still be writing)
  local ini = "job" .. ini_slot .. ".ini"
  reaper.RecursiveCreateDirectory(PROFILE, 0)
  band.write_atomic(PROFILE .. "/" .. ini, bg.profile_ini(band.read(reaper.get_ini_file())))
  if WIN then
    local cmd, vbs, ps = job:gsub("%.rpp$", ".cmd"), TMP .. "/hidden.vbs", TMP .. "/launch.ps1"
    if band.read(ps) ~= LAUNCH then band.write_atomic(ps, LAUNCH) end
    band.write_atomic(cmd, string.format('@powershell -NoProfile -ExecutionPolicy Bypass -File "%s" "%s" "%s" "%s" "%s" "%s"\r\n', ps, exe, job, res, PROFILE, ini))
    if not reaper.file_exists(vbs) then band.write_atomic(vbs, 'CreateObject("WScript.Shell").Run """" & WScript.Arguments(0) & """", 0, False\r\n') end
    reaper.ExecProcess(string.format('wscript.exe //B //Nologo "%s" "%s"', vbs, cmd), -1)
  else
    local sh = job:gsub("%.rpp$", ".sh")
    band.write_atomic(sh, bg.mac_script({ tmp = TMP, profile = PROFILE, res = res, exe = exe, ini = ini, job = job, helpers = bg.helpers() }))
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

-- Render in the background, up to bg.MAX at once and one per item (`key`): `render(dir)` sets the project up and calls
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
  jobs[key] = { name = name, dir = dir, started = reaper.time_precise() }
  last_start = reaper.time_precise()
  return true
end

-- A job's output files once it has finished, else nil. Finished: on Windows, they can be renamed (REAPER holds
-- them open while it writes; each is renamed and back); on a Mac, its script says its REAPER has quit.
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
  if reaper.file_exists(j.dir .. "/done.txt") or reaper.file_exists(j.dir .. "/passes.txt") then return files end
  return nil
end
local function drop(key)
  local j = jobs[key]
  for _, f in ipairs(band.files(j.dir)) do os.remove(j.dir .. "/" .. f) end
  jobs[key] = nil
end
local function launch_failed(j)
  if (band.read(j.dir .. "/pid.txt") or ""):match("^failed") then return true end
  -- (it quit with no print, or its folder's gone: known now, not at the time limit, with newer edits waiting: laptop, 0.42.2)
  if not reaper.file_exists(j.dir .. "/job.rpp") and not finished(j) then return true end
  return reaper.file_exists(j.dir .. "/done.txt") and not finished(j)
end
-- End a job's REAPER, if it's still there. -> whether that could be asked (once its process id is known).
local function end_job(j)
  local pid = tonumber((band.read(j.dir .. "/pid.txt") or ""):match("^%d+"))
  if not pid then return false end
  if not WIN then reaper.ExecProcess("/bin/kill -9 " .. pid, -1); return true end
  local kill = TMP .. "/kill" .. pid .. ".cmd" -- (one each, deleting itself: jobs can end together)
  band.write_atomic(kill, "@taskkill /PID " .. pid .. ' /T /F\r\n@del "%~f0"\r\n')
  reaper.ExecProcess(string.format('wscript.exe //B //Nologo "%s" "%s"', TMP .. "/hidden.vbs", kill), -1)
  return true
end
-- A job that's gone wrong: its REAPER (if it's still there, stuck on something nobody can see) is ended. One that never
-- started renders in front instead. One that ran and never finished doesn't: it's a plug-in asking something nobody can
-- see, and in front it held this REAPER on that same question, and on every render after it (UAD with no hardware: Mac,
-- 0.42.2). That part goes without a new print until it changes again. -> "failed" or "stuck".
bg.stuck = {} -- print name -> true (this session)
local function timed_out(key)
  local j = jobs[key]
  local never = launch_failed(j)
  end_job(j)
  drop(key)
  if never then
    failed = failed + 1
    band.log("a print stopped in the background before it finished: it renders here instead" .. ((failed >= 2 and done == 0) and " (and so will the rest this session)" or ""))
    return "failed"
  end
  bg.stuck[j.name] = true
  band.log("a wet take took over " .. bg.WAIT .. " s to render and was stopped: a plug-in may be waiting for an answer (a licence, missing hardware). Collaborators keep the last one until that part changes")
  return "stuck"
end

-- Whether another render has to wait: each is a whole REAPER, so bg.MAX at most, and starting one (saving the project's
-- copy) holds this REAPER up for a moment, so one at a time, spaced out.
function bg.busy()
  local running = 0
  for key, j in pairs(jobs) do
    if not finished(j) then
      if reaper.time_precise() - j.started <= bg.WAIT and not launch_failed(j) then running = running + 1
      else timed_out(key) end
    end
  end
  return running >= bg.MAX or reaper.time_precise() - last_start < bg.SPACING
end

-- The item's print `name`, moved into `out` once rendered: its .flac path. Else nil and "running", "failed", or
-- nothing (no job for it, or the job was for what the item was before: that one's dropped).
function bg.claim(key, name, out)
  local j = jobs[key]
  if not j then return nil end
  -- the item has changed since this job started: nobody wants its print, and it holds a place (a heavy instrument, for
  -- minutes). (Before its process id is known it runs on, and is dropped when it ends.)
  if j.name ~= name and end_job(j) then
    cancelled = cancelled + 1
    jobs[key] = nil -- (its folder goes with the others: it's empty of what we want, and its REAPER may still hold it)
    return nil
  end
  local files = finished(j)
  if not files then
    if reaper.time_precise() - j.started <= bg.WAIT and not launch_failed(j) then return nil, "running" end
    return nil, timed_out(key)
  end
  end_job(j) -- (its print is done: if a question stops it quitting, it mustn't stay on, unseen)
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
function bg.counts() return done, failed, cancelled end

return bg
