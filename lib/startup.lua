-- REAPER's start without its boxes. Reloading a band song stops at "Replace missing file..." and "Project Load Warning" for
-- anything a bandmate's machine has and this one lacks, on every start, before any script runs, so a machine nobody is at stays
-- out of the band. No preference covers the plug-ins, and scripts are paused while a box is up. So as REAPER quits, a song's tabs
-- are noted and REAPER told to open none; at its next start they're opened from here, and a small hidden helper answers those
-- two boxes for band songs only (never for a project of your own), leaving the files offline and changing nothing.
-- shortcut: Windows only: on a Mac a helper clicking another app's box needs an Accessibility permission, which BandSync won't ask for.
local band = require("band")
local startup = {}

local DIR = reaper.GetResourcePath() .. "/BandSync"
local FILE = DIR .. "/reopen.json"
local BAND_TAB, DONE, SAID = DIR .. "/reopen-band-tab", DIR .. "/reopen-done", DIR .. "/reopen-said.txt"
local function usable() return reaper.GetOS():find("^Win") and reaper.SNM_GetIntConfigVar ~= nil and reaper.BR_Win32_WritePrivateProfileString ~= nil end
-- In the file, not only in memory: REAPER has written its settings by the time a script's atexit runs, so a change there alone is lost.
local function set_open_mode(value)
  reaper.SNM_SetIntConfigVar("loadlastproj", value)
  reaper.BR_Win32_WritePrivateProfileString("REAPER", "loadlastproj", tostring(value), reaper.get_ini_file())
end

-- Tabs as of the last look: at quit they may be closing already.
local known = {}
-- The plan is kept on disk all the time, not only at quit: after a crash REAPER reopened the tabs itself, with its boxes up until
-- someone answered and the song catching up a little at a time behind them (PC, 2026-11-03: nearly 2 minutes against 20 s).
local kept, kept_was
function startup.note()
  local tabs, front = {}, reaper.EnumProjects(-1)
  for i = 0, 512 do
    local p, fn = reaper.EnumProjects(i)
    if not p then break end
    if fn ~= "" then tabs[#tabs + 1] = { path = fn, band = band.binding(p) ~= nil or nil, front = p == front or nil } end
  end
  known = tabs
  if not usable() then return end
  local sig = band.json_encode(tabs)
  if sig == kept then return end
  kept = sig
  if startup.plan(tabs) then
    kept_was = kept_was or reaper.SNM_GetIntConfigVar("loadlastproj", 1)
    band.write_json(FILE, { tabs = tabs, loadlastproj = kept_was })
    set_open_mode(startup.no_open(kept_was))
  elseif kept_was then -- (no band song open any more: as you had it)
    set_open_mode(kept_was)
    kept_was = nil
    os.remove(FILE)
  end
end

-- What to do at the next start, or nil: only a session with a band song in it is opened from here. Pure.
function startup.plan(tabs)
  for _, t in ipairs(tabs) do if t.band then return tabs end end
  return nil
end

-- REAPER's "Open project(s) on startup", in the low bits: 0 last active project, 1 last project tabs, 2 new project, 3 new
-- project without the default template, 4 prompt. Pure.
function startup.no_open(value) return value - value % 8 + 2 end

function startup.same_path(p) return (p:gsub("\\", "/"):lower()) end

function startup.on_quit()
  -- (once: Autostart reloaded on an update has asked twice, and the second time read "new project" as the person's own choice)
  if band.read_json(FILE) or not usable() or not startup.plan(known) then return end
  local was = reaper.SNM_GetIntConfigVar("loadlastproj", 1)
  band.write_json(FILE, { tabs = known, loadlastproj = was })
  set_open_mode(startup.no_open(was))
end

local HELPER = [==[
param([string]$BandTab, [string]$Done, [string]$Said)
Add-Type -Name W -Namespace BandSync -MemberDefinition @"
public delegate bool EnumProc(System.IntPtr h, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool EnumChildWindows(System.IntPtr p, EnumProc f, System.IntPtr l);
[DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(System.IntPtr h, out int p);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool PostMessage(System.IntPtr h, int m, System.IntPtr w, System.IntPtr l);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern System.IntPtr SendMessage(System.IntPtr h, int m, System.IntPtr w, System.Text.StringBuilder l);
"@
function T($h) { $b = New-Object System.Text.StringBuilder 4000; [void][BandSync.W]::SendMessage($h, 0x000D, [IntPtr]4000, $b); "$b" }
$until = (Get-Date).AddSeconds(180)
while ((Get-Date) -lt $until -and -not (Test-Path -LiteralPath $Done)) {
  if (Test-Path -LiteralPath $BandTab) {
    $ids = @(Get-Process reaper -ErrorAction SilentlyContinue | ForEach-Object Id)
    $top = [BandSync.W+EnumProc]{ param($h, $l)
      $p = 0; [void][BandSync.W]::GetWindowThreadProcessId($h, [ref]$p)
      if ($ids -contains $p -and [BandSync.W]::IsWindowVisible($h)) {
        $t = T $h
        if ($t -eq 'Replace missing file...' -or $t -eq 'Project Load Warning') {
          $want = if ($t -eq 'Project Load Warning') { 'OK' } else { 'Ignore all missing files' }
          $kid = [BandSync.W+EnumProc]{ param($k, $m)
            $x = T $k
            if ($t -eq 'Project Load Warning' -and $x.Length -gt 40) { Add-Content -LiteralPath $Said -Value $x -Encoding UTF8 }
            if ($x -eq $want) { [void][BandSync.W]::PostMessage($k, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero) }
            $true
          }
          [void][BandSync.W]::EnumChildWindows($h, $kid, [IntPtr]::Zero)
        }
      }
      $true
    }
    [void][BandSync.W]::EnumWindows($top, [IntPtr]::Zero)
  }
  Start-Sleep -Milliseconds 400
}
]==]

local function start_helper()
  local tmp = (os.getenv("TEMP") or os.getenv("TMP") or DIR):gsub("\\", "/")
  local ps, cmd, vbs = tmp .. "/bandsync-answer-boxes.ps1", tmp .. "/bandsync-answer-boxes.cmd", tmp .. "/bandsync-hidden.vbs"
  band.write_atomic(ps, HELPER)
  band.write_atomic(cmd, string.format('@powershell -NoProfile -ExecutionPolicy Bypass -File "%s" "%s" "%s" "%s"\r\n', ps, BAND_TAB, DONE, SAID))
  if not reaper.file_exists(vbs) then band.write_atomic(vbs, 'CreateObject("WScript.Shell").Run """" & WScript.Arguments(0) & """", 0, False\r\n') end
  reaper.ExecProcess(string.format('wscript.exe //B //Nologo "%s" "%s"', vbs, cmd), -1)
end

-- What the load warning said, in a line for the Activity list: which plug-ins and how many files are missing here. Pure.
function startup.summary(text)
  local fx, seen = {}, {}
  for name in (text or ""):gmatch("Track %d+: ([^\r\n]+)") do
    if not seen[name] then seen[name] = true; fx[#fx + 1] = name end
  end
  local files = tonumber((text or ""):match("There were (%d+) files"))
  local bits = {}
  if #fx > 0 then bits[#bits + 1] = #fx .. " plug-in(s) this computer lacks (" .. table.concat(fx, ", ") .. "), so those parts play their prints" end
  if files then bits[#bits + 1] = files .. " file(s) missing, left offline" end
  return #bits > 0 and ("opening the studio's projects: " .. table.concat(bits, "; ")) or nil
end

-- Opening a group project while REAPER runs (Open project, a side room's square): its boxes are answered as at REAPER's start.
function startup.open_quietly(open)
  if not usable() then return open() end
  os.remove(DONE); os.remove(SAID)
  band.write_atomic(BAND_TAB, "1")
  start_helper()
  local ok, a, b = pcall(open)
  os.remove(BAND_TAB)
  band.write_atomic(DONE, "1")
  local line = startup.summary(band.read(SAID))
  if line then band.log(line) end
  if not ok then error(a) end
  return a, b
end

function startup.on_start()
  local plan = usable() and band.read_json(FILE)
  if not plan then return end
  os.remove(FILE)
  if plan.loadlastproj then set_open_mode(plan.loadlastproj) end
  os.remove(DONE); os.remove(BAND_TAB); os.remove(SAID)
  start_helper()
  local first, front = reaper.EnumProjects(0) and select(2, reaper.EnumProjects(0)) == "" and reaper.CountTracks(reaper.EnumProjects(0)) == 0, nil
  local open = {} -- (REAPER's own reopening if the setting didn't take, or a song opened by double-clicking it: never a second tab)
  for i = 0, 512 do
    local p, fn = reaper.EnumProjects(i)
    if not p then break end
    open[startup.same_path(fn)] = true
  end
  for _, t in ipairs(plan.tabs or {}) do
    if reaper.file_exists(t.path) and not open[startup.same_path(t.path)] then
      if t.band then band.write_atomic(BAND_TAB, "1") else os.remove(BAND_TAB) end
      if not first then reaper.Main_OnCommand(40859, 0) end -- New project tab
      first = false
      reaper.Main_openProject(t.path)
      -- (each one ready now: clicking a tab later finds it caught up, not loading while you wait)
      local here = reaper.EnumProjects(-1)
      local tb = t.band and band.binding(here)
      if tb then pcall(function() require("sync").preload(here, band.for_tab(band.settings(), tb), tb.song, tb.room) end) end
    end
    if t.front then front = startup.same_path(t.path) end
  end
  os.remove(BAND_TAB)
  band.write_atomic(DONE, "1")
  for i = 0, 512 do -- (back on the tab that was in front)
    local p, fn = reaper.EnumProjects(i)
    if not p then break end
    if front and startup.same_path(fn) == front then reaper.SelectProjectInstance(p); break end
  end
  local line = startup.summary(band.read(SAID))
  if line then band.log(line) end
end

return startup
