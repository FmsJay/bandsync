# BandSync setup for Windows: installs and sets up everything BandSync needs, skipping whatever is already there.
# Run it with "Install BandSync (Windows).cmd" (double-click). Windows PowerShell 5.1 compatible.
#   REAPER, ReaPack, ReaImGui, Syncthing (the shared folder), BandSync's scripts (through ReaPack), and optionally
#   SonoBus + Tailscale (Live) and Google Drive for desktop (Solo edit).
# Each app comes from its official source (winget, or the extension's own release); each installer may show a
# Windows permission prompt. Sign-ins (Tailscale, Google Drive) stay the musician's own clicks.
# Every question can be answered up front (for an AI installer or a test run); anything not given is asked.
param(
  [string]$Tag = "main",          # which BandSync version's helper files to use (the .cmd passes its own)
  [string]$User = "", [string]$HostId = "", [string]$Root = "",
  [ValidateSet("", "yes", "no")][string]$Hosting = "", [ValidateSet("", "yes", "no")][string]$Live = "", [ValidateSet("", "yes", "no")][string]$Solo = "",
  [ValidateSet("reapack", "folder", "verify")][string]$Scripts = "reapack", # folder: band-internal copy in <root>/_tools/bandsync
  [string]$SyncthingHome = "",    # testing: drive a separate Syncthing instance (--home)
  [switch]$NoApps                 # testing: skip installing apps, only configure
)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue" # Invoke-WebRequest is 10x slower with the progress bar
$Repo = "FmsJay/bandsync"
$ReaImGuiVer = "0.10.0.5" # shortcut: pinned; ReaPack keeps it updated only if later reinstalled through ReaPack
$ReaPackVer = "v1.2.6"

# Programs started from some sandboxed apps (seen: the Claude desktop app) get a private copy of AppData, so what
# they set up (Syncthing's identity, REAPER's settings) is invisible to the same programs started normally. Seen
# 2026-10-27: Syncthing started from REAPER made a second identity that knew no other machine. The process isn't
# "packaged" (GetCurrentPackageFullName says so), so test what matters: does a write to AppData land in an app's
# sandbox? Then reopen through Explorer, which starts things outside it, with the same answers.
$probe = "bandsync_probe_" + [guid]::NewGuid().ToString("N")
Set-Content (Join-Path $env:LOCALAPPDATA $probe) "x"
$boxed = Get-ChildItem "$env:LOCALAPPDATA\Packages\*\LocalCache\Local\$probe" -ErrorAction SilentlyContinue
Remove-Item (Join-Path $env:LOCALAPPDATA $probe) -ErrorAction SilentlyContinue
if ($boxed) {
  $argv = @("-Tag", $Tag, "-Scripts", $Scripts)
  foreach ($k in "User", "HostId", "Root", "Hosting", "Live", "Solo", "SyncthingHome") { $v = Get-Variable $k -ValueOnly; if ($v) { $argv += @("-$k", $v) } }
  if ($NoApps) { $argv += "-NoApps" }
  $quoted = ($argv | ForEach-Object { if ($_ -match '^-') { $_ } else { '"' + $_ + '"' } }) -join " "
  $cmd = Join-Path $env:TEMP "bandsync_install_outside.cmd"
  Set-Content $cmd "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" $quoted`r`npause" -Encoding ascii
  Start-Process explorer.exe -ArgumentList "`"$cmd`""
  Write-Host "This window runs inside another app's sandbox; BandSync setup continues in a new window. If none appears, double-click 'Install BandSync (Windows).cmd' yourself." -ForegroundColor Yellow
  exit 0
}

function Say($t) { Write-Host $t -ForegroundColor Cyan }
function Ok($t) { Write-Host "  OK  $t" -ForegroundColor Green }
function Warn($t) { Write-Host "  !!  $t" -ForegroundColor Yellow }
function Ask($q, $def) { $a = Read-Host "$q$(if ($def) { " [$def]" })"; if ($a) { $a.Trim() } else { $def } }
function YesNo($q, $def) { $a = Ask "$q (y/n)" $def; return $a -match '^[yY]' }

Say "BandSync setup"
Write-Host "This installs what BandSync needs and sets it up. It asks a few questions first (unless given up front); Windows may ask"
Write-Host "permission for each app it installs. Nothing already installed is changed."
Write-Host ""

# ---------- 0. questions ----------
$user = $User -replace '[^\w\- ]', ''
while (-not $user) { $user = (Ask "Your name, as the band will see it" $env:USERNAME) -replace '[^\w\- ]', '' }
$isHost = if ($Hosting) { $Hosting -eq "yes" } else { YesNo "Are you the band's host (the first one to set up, with the machine that stays on)?" "n" }
$hostId = $HostId.ToUpper()
$idPattern = '^[A-Z0-9]{7}(-[A-Z0-9]{7}){7}$'
if (-not $isHost) {
  while ($hostId -notmatch $idPattern) {
    $hostId = (Ask "The host's Syncthing device ID (they find it in Syncthing: Actions > Show ID)" "").ToUpper()
    if ($hostId -notmatch $idPattern) { Warn "That doesn't look like a device ID (8 groups of 7 letters/digits, joined by dashes)." }
  }
}
$root = if ($Root) { $Root } else { Ask "Where should the shared BandSync folder be" (Join-Path $env:USERPROFILE "BandSync") }
$wantLive = if ($Live) { $Live -eq "yes" } else { YesNo "Will you use Live (hearing each other while playing)? Installs SonoBus and Tailscale" "y" }
$wantSolo = if ($Solo) { $Solo -eq "yes" } else { YesNo "Will you use Solo edit (editing a song while the others are offline)? Installs Google Drive" "y" }
Write-Host ""

# ---------- 1. apps ----------
$winget = Get-Command winget -ErrorAction SilentlyContinue
function Install-App($id, $name) {
  $ErrorActionPreference = "Continue" # winget writes to stderr (see ST below)
  if ($NoApps) { return }
  if (-not $winget) { Warn "$name : winget isn't available (install 'App Installer' from the Microsoft Store), install $name by hand"; return }
  & winget list --id $id --exact --accept-source-agreements *> $null
  if ($LASTEXITCODE -eq 0) { Ok "$name is already installed"; return }
  Say "Installing $name ..."
  & winget install --id $id --exact --silent --accept-package-agreements --accept-source-agreements
  if ($LASTEXITCODE -eq 0) { Ok "$name installed" } else { Warn "$name didn't install (winget exit $LASTEXITCODE): install it by hand" }
}

function Find-Reaper {
  $p = Get-Process reaper -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($p -and $p.Path) { return $p.Path }
  foreach ($c in @("$env:ProgramFiles\REAPER (x64)\reaper.exe", "$env:ProgramFiles\REAPER\reaper.exe")) { if (Test-Path $c) { return $c } }
  return $null
}
if (-not (Find-Reaper)) { Install-App "Cockos.REAPER" "REAPER" } else { Ok "REAPER is already installed" }
Install-App "Syncthing.Syncthing" "Syncthing"
if ($wantLive) { Install-App "Sonosaurus.SonoBus" "SonoBus"; Install-App "Tailscale.Tailscale" "Tailscale" }
if ($wantSolo) { Install-App "Google.GoogleDrive" "Google Drive for desktop" }

$reaper = Find-Reaper
if (-not $reaper) { Warn "REAPER wasn't found after installing: install it from reaper.fm and run this again."; exit 1 }
$exeDir = Split-Path $reaper
$res = if (Test-Path (Join-Path $exeDir "reaper.ini")) { $exeDir } else { Join-Path $env:APPDATA "REAPER" } # portable installs keep everything beside reaper.exe
Ok "REAPER: $reaper (settings in $res)"

# ---------- 2. REAPER extensions: ReaPack and ReaImGui ----------
$plugins = Join-Path $res "UserPlugins"
$need = @()
if (-not (Test-Path (Join-Path $plugins "reaper_reapack-x64.dll"))) { $need += @{ file = "reaper_reapack-x64.dll"; url = "https://github.com/cfillion/reapack/releases/download/$ReaPackVer/reaper_reapack-x64.dll" } }
if (-not (Test-Path (Join-Path $plugins "reaper_imgui-x64.dll"))) { $need += @{ file = "reaper_imgui-x64.dll"; url = "https://github.com/cfillion/reaimgui/releases/download/v$ReaImGuiVer/reaper_imgui-x64.dll" } }
if ($need.Count -gt 0) {
  if (Get-Process reaper -ErrorAction SilentlyContinue) {
    Say "REAPER has to restart to load its new extensions. Press Enter and REAPER is asked to close (it asks to save"
    Say "anything unsaved first; it reopens your project afterwards), or close it yourself."
    Read-Host | Out-Null
    Get-Process reaper -ErrorAction SilentlyContinue | ForEach-Object { [void]$_.CloseMainWindow() } # like clicking X: REAPER asks to save
    $script:Reopen = $true
    $waited = 0
    while (Get-Process reaper -ErrorAction SilentlyContinue) {
      Start-Sleep 1; $waited++
      if ($waited % 30 -eq 0) { Say "Still waiting for REAPER to close (answer its save question if it asked one) ..." }
    }
  }
  New-Item -ItemType Directory -Force $plugins | Out-Null
  foreach ($n in $need) { Invoke-WebRequest -UseBasicParsing $n.url -OutFile (Join-Path $plugins $n.file); Ok "$($n.file) installed" }
} else { Ok "ReaPack and ReaImGui are already installed" }
$api = Join-Path $res "Scripts\ReaTeam Extensions\API"
if (-not (Test-Path (Join-Path $api "imgui.lua"))) { # ReaImGui's version shim, which scripts load with require "imgui"
  New-Item -ItemType Directory -Force $api | Out-Null
  Invoke-WebRequest -UseBasicParsing "https://codeberg.org/cfillion/reaimgui/raw/v$ReaImGuiVer/shims/imgui.lua" -OutFile (Join-Path $api "imgui.lua")
  Ok "ReaImGui shim installed"
}

# ---------- 3. Syncthing: the shared folder ----------
$st = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Links\syncthing.exe"
if (-not (Test-Path $st)) { $c = Get-Command syncthing -ErrorAction SilentlyContinue; if ($c) { $st = $c.Source } }
if (-not (Test-Path $st)) { Warn "Syncthing wasn't found: install it from syncthing.net and run this again."; exit 1 }
$homeArg = @(); if ($SyncthingHome) { $homeArg = @("--home", $SyncthingHome) }
# Windows PowerShell 5.1 turns a native program's stderr into errors, and with "Stop" above an error ends the whole
# installer (seen: Syncthing's "not up yet" while waiting for it killed the run). These calls expect stderr.
function ST { $ErrorActionPreference = "Continue"; & $st @args @homeArg 2>&1 }
function STcli { $ErrorActionPreference = "Continue"; & $st cli @homeArg @args 2>&1 }

$cfgDir = if ($SyncthingHome) { $SyncthingHome } else { Join-Path $env:LOCALAPPDATA "Syncthing" }
if (-not (Test-Path (Join-Path $cfgDir "config.xml"))) { ST generate | Out-Null; Ok "Syncthing set up for the first time" }
$running = if ($SyncthingHome) { $false } else { [bool](Get-Process syncthing -ErrorAction SilentlyContinue) }
if (-not $running) {
  $sargs = @("serve", "--no-browser") + $homeArg
  Start-Process $st -ArgumentList $sargs -WindowStyle Hidden
  Ok "Syncthing started (BandSync's Live sync starts it from now on)"
}
$up = $false
for ($i = 0; $i -lt 30 -and -not $up; $i++) { $null = STcli show system; $up = $LASTEXITCODE -eq 0; if (-not $up) { Start-Sleep 1 } }
if (-not $up) { Warn "Syncthing didn't answer; finish its setup by hand (see installer/SKILL.md)"; exit 1 }
$myId = (ST device-id | Select-Object -Last 1).ToString().Trim()

$root = $root.TrimEnd('\', '/')
New-Item -ItemType Directory -Force $root | Out-Null
if (-not ((STcli config folders list) -match '^bandsync$')) { STcli config defaults folder path set (Split-Path $root) | Out-Null } # fresh setup only
$folders = STcli config folders list
if ($folders -notcontains "bandsync") {
  STcli config folders add --id bandsync --label BandSync --path $root | Out-Null
  Ok "shared folder 'bandsync' -> $root"
} else { Ok "shared folder 'bandsync' already set up" }
STcli config folders bandsync order set smallestFirst | Out-Null
STcli config folders bandsync fswatcher-delays set 1 | Out-Null  # the default 10 s delay added 10 s to every take
STcli config devices $myId name set $user | Out-Null
if (-not $isHost) {
  $devices = STcli config devices list
  if ($devices -notcontains $hostId) {
    STcli config devices add --device-id $hostId --name "Band host" --introducer --auto-accept-folders | Out-Null
  }
  $shared = STcli config folders bandsync devices list
  if ($shared -notcontains $hostId) { STcli config folders bandsync devices add --device-id $hostId | Out-Null }
  Ok "paired with the host"
}

# ---------- 4. BandSync scripts, inside REAPER ----------
$work = Join-Path $env:TEMP "bandsync_setup"
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $work | Out-Null
if ($Tag -eq "main") { # the newest released version (what ReaPack serves), not whatever is on main right now
  try {
    $idx = (Invoke-WebRequest -UseBasicParsing "https://github.com/$Repo/raw/main/index.xml").Content
    $vers = [regex]::Matches($idx, 'version name="([0-9.]+)"') | ForEach-Object { $_.Groups[1].Value }
    if ($vers) { $Tag = "v" + ($vers | Sort-Object { [version]$_ } | Select-Object -Last 1) }
  } catch { }
}
$zipRef = if ($Tag -eq "main") { "heads/main" } else { "tags/$Tag" }
Invoke-WebRequest -UseBasicParsing "https://codeload.github.com/$Repo/zip/refs/$zipRef" -OutFile (Join-Path $work "bandsync.zip")
Expand-Archive (Join-Path $work "bandsync.zip") $work
$src = Get-ChildItem $work -Directory | Select-Object -First 1
$helper = Join-Path $src.FullName "installer\bandsync_setup.lua"
$utf8 = New-Object System.Text.UTF8Encoding($false) # no BOM: the Lua JSON reader wants plain UTF-8
function Request($mode) {
  $req = @{ sync_root = ($root -replace '\\', '/'); user = $user; mode = $mode; repo_url = "https://github.com/$Repo/raw/main/index.xml"; open_panel = ($mode -eq "verify") } | ConvertTo-Json
  [IO.File]::WriteAllText((Join-Path (Split-Path $helper) "bandsync_setup.json"), $req, $utf8)
  $result = Join-Path (Split-Path $helper) "bandsync_setup_result.json"
  Remove-Item $result -ErrorAction SilentlyContinue
  if ($script:Reopen -and -not (Get-Process reaper -ErrorAction SilentlyContinue)) {
    # we closed REAPER: start it the way you do, so it reopens your projects as it always does (started WITH the
    # helper it came back with an empty project), then hand it the helper once it's up
    Start-Process $reaper
    for ($i = 0; $i -lt 60 -and -not (Get-Process reaper -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 }); $i++) { Start-Sleep 1 }
    Start-Sleep 5
  }
  Start-Process $reaper -ArgumentList @("-nonewinst", "`"$helper`"")
  for ($i = 0; $i -lt 180 -and -not (Test-Path $result); $i++) { Start-Sleep 1 }
  if (-not (Test-Path $result)) { return $null }
  Start-Sleep -Milliseconds 300
  return Get-Content $result -Raw | ConvertFrom-Json
}
Say "Setting up BandSync inside REAPER (REAPER opens; on a first start it scans your plug-ins, which can take a while) ..."
$r = Request $Scripts
if (-not $r) { Warn "REAPER didn't run the setup step. Open REAPER, then run this again." ; exit 1 }
foreach ($s in $r.steps) { if ($s.ok) { Ok "$($s.name): $($s.detail)" } else { Warn "$($s.name): $($s.detail)" } }
$count = 0
for ($i = 0; $i -lt 12 -and $count -lt 5; $i++) { # ReaPack downloads in the background
  Start-Sleep 10
  $v = Request "verify"
  if ($v) { $count = [int]$v.registered_actions }
}
if ($count -ge 5) { Ok "BandSync installed: $count actions (the BandSync panel opens in REAPER)" } else { Warn "BandSync's scripts haven't arrived yet: in REAPER, Extensions > ReaPack > Synchronize packages" }

# ---------- 5. what's left for a human (only what isn't done yet) ----------
$left = @()
$peers = @()
try {
  $x = [xml](Get-Content (Join-Path $cfgDir "config.xml"))
  $c = Invoke-RestMethod -TimeoutSec 5 -Uri ("http://" + $x.configuration.gui.address + "/rest/system/connections") -Headers @{ "X-API-Key" = $x.configuration.gui.apikey }
  $peers = @($c.connections.PSObject.Properties | Where-Object { $_.Value.connected } | ForEach-Object { $_.Name })
} catch { }
if ($isHost) {
  $left += "Your Syncthing device ID, for bandmates' installers:  $myId"
  $left += "When a bandmate sends you their ID: Syncthing (http://127.0.0.1:8384) > Add Remote Device, paste it, and on its Sharing tab tick 'BandSync'."
} elseif ($peers -notcontains $hostId) {
  $left += "Send the host your Syncthing device ID:  $myId  (they add it in Syncthing; the shared folder then arrives by itself)"
}
if ($wantLive) {
  $ts = "$env:ProgramFiles\Tailscale\tailscale.exe"
  # sign in as a tagged band machine: a tagged machine's key never expires, so nobody has to sign in again before a
  # session (untagged ones sign out every 180 days). Needs the host's one-time tagOwners line (below).
  $st = $null
  $tagged = $false
  if (Test-Path $ts) {
    try { $ErrorActionPreference = "Continue"; $st = & $ts status --json 2>$null | ConvertFrom-Json } catch { } finally { $ErrorActionPreference = "Stop" }
    # tagged, or its key expiry was turned off by hand (then it has no KeyExpiry)
    $tagged = $st -and (@($st.Self.Tags) -contains "tag:bandsync" -or ($st.BackendState -eq "Running" -and -not $st.Self.KeyExpiry))
    if ($tagged) { Ok "Tailscale signed in, and stays signed in" }
    else {
      $extra = @()
      $go = $true
      if ($st -and $st.BackendState -eq "Running") {
        $go = YesNo "Tailscale is signed in, but signs out by itself every few months. Make this PC stay signed in? You sign in once more" "y"
        $extra = @("--force-reauth", "--reset")
      }
      if ($go) {
        Say "Signing in to Tailscale: a browser page opens; sign in with the band's account there."
        $out = Join-Path $env:TEMP "bandsync_ts_up.txt"
        Set-Content $out ""
        $p = Start-Process -FilePath $ts -ArgumentList (@("up", "--advertise-tags=tag:bandsync", "--timeout=300s") + $extra) -RedirectStandardError $out -NoNewWindow -PassThru
        $null = $p.Handle # (so ExitCode is readable afterwards)
        $url = $null
        for ($i = 0; $i -lt 30 -and -not $url -and -not $p.HasExited; $i++) {
          Start-Sleep 1
          $m = Select-String -Path $out -Pattern 'https://login\.tailscale\.com/\S+' | Select-Object -First 1
          if ($m) { $url = $m.Matches[0].Value }
        }
        if ($url) { Start-Process $url }
        $p.WaitForExit()
        if ($p.ExitCode -eq 0) { Ok "Tailscale signed in as a band machine (it stays signed in)"; $tagged = $true }
        elseif ((Get-Content $out -Raw) -match 'tag') { Warn "Tailscale didn't accept the band tag yet: the host has to allow it once (see below). Until then, sign in from the Tailscale icon; this PC then signs out by itself every few months." }
        else { Warn "Tailscale sign-in didn't finish: sign in from its icon in the taskbar." }
      }
    }
  }
  if (-not $tagged -or $isHost) {
    $left += "Tailscale, once for the whole band (if not done yet): at login.tailscale.com/admin/acls add this line inside the policy's { }:"
    $left += "    `"tagOwners`": { `"tag:bandsync`": [`"autogroup:member`"] },"
    $left += "  Then band machines sign in as 'tag:bandsync', and tagged machines never have to sign in again."
  }
}
if ($wantSolo -and -not (Test-Path "G:\My Drive\BandSync")) {
  $left += "Google Drive: sign in when it opens."
  if ($isHost) { $left += "Google Drive: make a 'BandSync' folder in My Drive and share it with each bandmate (Editor)." }
  else { $left += "Google Drive: at drive.google.com, Shared with me > right-click BandSync > Organize > Add shortcut > My Drive (or set the folder in the panel's Solo edit tab if your Drive isn't G:)." }
}
$ext = Join-Path $res "reaper-extstate.ini"
$offset = ""
if (Test-Path $ext) { $m = Select-String -Path $ext -Pattern '^rec_offset_ms=(.*)$' | Select-Object -First 1; if ($m) { $offset = $m.Matches[0].Groups[1].Value } }
if (-not $offset -or [math]::Abs([double]$offset) -ge 1) {
  $left += "Recording latency: connect a cable from your interface's output 1 to an input, then in the BandSync panel: More > Calibrate latency."
}
$left += "In the panel, open the band's session (or publish yours, as host); its Set up list shows anything still missing."
Write-Host ""
Say "Done. What's left (these need you):"
foreach ($l in $left) { Write-Host "  - $l" }
