# StudioSync setup for Windows: installs and sets up everything StudioSync needs, skipping whatever is already there.
# Run it with "Install StudioSync (Windows).cmd" (double-click). Windows PowerShell 5.1 compatible.
#   REAPER, ReaPack, ReaImGui, Syncthing (the shared folder), StudioSync's scripts (through ReaPack), and optionally
#   SonoBus + Tailscale (hearing each other) and Google Drive for desktop (the group's copy): -Live no / -Solo no leave them out.
# A bandmate's panel (Invite a collaborator) hands out a one-line command that runs this with -HostId already in it.
# Each app comes from its official source (winget, or the extension's own release); each installer may show a
# Windows permission prompt. Sign-ins (Tailscale, Google Drive) stay the musician's own clicks.
# Every question can be answered up front (for an AI installer or a test run); anything not given is asked.
param(
  [string]$Tag = "main",          # which StudioSync version's helper files to use (the .cmd passes its own)
  [string]$User = "", [string]$HostId = "", [string]$Root = "",
  [string]$BandId = "", [string]$BandName = "", # the band an invitation is for: its Syncthing folder id and name
  [ValidateSet("", "yes", "no")][string]$Hosting = "", [ValidateSet("", "yes", "no")][string]$Live = "", [ValidateSet("", "yes", "no")][string]$Solo = "",
  [ValidateSet("", "yes", "no")][string]$Plugins = "", # the band plug-in pack (free, open source)
  [ValidateSet("", "yes", "no")][string]$Extras = "", # the larger extras: amp modelers, Odin 2, sforzando + Salamander piano
  [ValidateSet("reapack", "folder", "verify")][string]$Scripts = "reapack", # folder: band-internal copy in <root>/_tools/studiosync
  [string]$SyncthingHome = "",    # testing: drive a separate Syncthing instance (--home)
  [string]$ReaperExe = "",         # testing: this REAPER, as if the installer had just put it there
  [switch]$NoApps,                # testing: skip installing apps, only configure
  [switch]$NoReaper               # testing: stop before anything happens inside REAPER (the shared folder and pairing only)
)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue" # Invoke-WebRequest is 10x slower with the progress bar
$Repo = "FmsJay/studiosync"
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
  foreach ($k in "User", "HostId", "Root", "BandId", "BandName", "Hosting", "Live", "Solo", "Plugins", "Extras", "SyncthingHome", "ReaperExe") { $v = Get-Variable $k -ValueOnly; if ($v) { $argv += @("-$k", $v) } }
  if ($NoApps) { $argv += "-NoApps" }
  if ($NoReaper) { $argv += "-NoReaper" }
  $quoted = ($argv | ForEach-Object { if ($_ -match '^-') { $_ } else { '"' + $_ + '"' } }) -join " "
  $cmd = Join-Path $env:TEMP "bandsync_install_outside.cmd"
  Set-Content $cmd "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" $quoted`r`npause" -Encoding ascii
  Start-Process explorer.exe -ArgumentList "`"$cmd`""
  Write-Host "This window runs inside another app's sandbox; StudioSync setup continues in a new window. If none appears, double-click 'Install StudioSync (Windows).cmd' yourself." -ForegroundColor Yellow
  exit 0
}

function Say($t) { Write-Host $t -ForegroundColor Cyan }
function Ok($t) { Write-Host "  OK  $t" -ForegroundColor Green }
function Warn($t) { Write-Host "  !!  $t" -ForegroundColor Yellow }
function Ask($q, $def) { $a = Read-Host "$q$(if ($def) { " [$def]" })"; if ($a) { $a.Trim() } else { $def } }
function YesNo($q, $def) { $a = Ask "$q (y/n)" $def; return $a -match '^[yY]' }

Say "StudioSync setup"
Write-Host "This installs what StudioSync needs and sets it up. It asks a few questions first (unless given up front); Windows may ask"
Write-Host "permission for each app it installs. Nothing already installed is changed."
Write-Host ""

# ---------- 0. questions ----------
$user = $User -replace '[^\w\- ]', ''
while (-not $user) { $user = (Ask "Your name, as the studio will see it" $env:USERNAME) -replace '[^\w\- ]', '' }
# Pairing: with whoever in the band is already set up (any of them: every machine passes the folder on). "Host" is
# a song's, not a machine's: anyone can host a song (James, 2026-10-31: "are you the band's host" read as a role).
$isHost = if ($Hosting) { $Hosting -eq "yes" } elseif ($HostId) { $false } else { -not (YesNo "Is someone in the studio already set up with StudioSync?" "y") } # (-HostId: an invitation)
if ($isHost -and -not $Hosting) { Say "You're the first: at the end you get your Syncthing ID to send to each collaborator who installs." }
$hostId = $HostId.ToUpper()
$idPattern = '^[A-Z0-9]{7}(-[A-Z0-9]{7}){7}$'
if (-not $isHost) {
  if ($hostId -notmatch $idPattern) {
    Say "Their Syncthing device ID is 8 groups of 7 letters and digits, like ABCDEFG-HIJKLMN-...-1234567 (63 characters)."
    Say "Easiest: they press 'Invite a collaborator' in their StudioSync panel and send you the line it copies (it has the ID"
    Say "in it). Or they find it in Syncthing: Actions > Show ID. Copy all of it and paste it here."
  }
  while ($hostId -notmatch $idPattern) {
    $hostId = ((Ask "Paste their Syncthing device ID (in their Syncthing: Actions > Show ID)" "") -replace '\s', '').ToUpper()
    if ($hostId -notmatch $idPattern) { Warn "That doesn't look like a device ID (8 groups of 7 letters/digits, joined by dashes)." }
  }
}
# the band (docs/bands-design.md): each its own shared folder. An invitation names it; the first one set up names it.
$folderId = ($BandId.ToLower() -replace '[^a-z0-9-]', '')
if (-not $isHost -and -not $folderId) { # (someone's device ID typed in by hand, no invitation)
  $folderId = ((Ask "The studio's ID (it's in their invitation, after -BandId; press Enter if they don't have one)" "bandsync").ToLower() -replace '[^a-z0-9-]', '')
  if (-not $folderId) { $folderId = "bandsync" }
}
$bandName = $BandName -replace '[^\w\- ]', ''
if ($isHost -and -not $bandName) { while (-not $bandName) { $bandName = (Ask "Name your studio" "My studio") -replace '[^\w\- ]', '' } }
if (-not $bandName) { $bandName = "the studio" }
$defRoot = if ($folderId -eq "bandsync") { Join-Path $env:USERPROFILE "BandSync" } else { Join-Path $env:USERPROFILE "StudioSync $bandName" }
$root = if ($Root) { $Root } else { Ask "Where should $bandName's shared folder be" $defRoot }
# The first one set up: an ID of the group's own. They all used to get "bandsync", so someone in two such groups had the two
# folders treated as one and their files mixed. Run again on the same folder, it keeps the ID it has; a folder from before
# groups had IDs, with no band.json yet, is "bandsync" (lib/band.lua band.info).
if (-not $folderId) {
  $known = Join-Path $root "_band\band.json"
  if (Test-Path $known) { try { $folderId = (Get-Content $known -Raw | ConvertFrom-Json).id } catch { } }
  elseif (Get-ChildItem $root -Force -ErrorAction SilentlyContinue | Select-Object -First 1) { $folderId = "bandsync" }
  if (-not $folderId) {
    $slug = ($bandName.ToLower() -replace '[^a-z0-9]+', '-').Trim('-'); if (-not $slug) { $slug = "group" }
    $folderId = "studiosync-$slug-" + ('{0:x4}' -f (Get-Random -Maximum 65536))
  }
}
$driveName = if ($folderId -eq "bandsync") { "BandSync" } else { "StudioSync - $bandName" }
# SonoBus + Tailscale (hearing each other) and Google Drive (the group's copy) are part of StudioSync, not asked. Tailscale left in 0.50 and came back
# (James, 2026-11-04: "should not be optional"): the NINJAM route needs it, and it gets round a router that stops SonoBus.
# (James, 2026-10-31: "it feels like a core feature"); -Live no / -Solo no still leave them out.
$wantLive = $Live -ne "no"
$wantSolo = $Solo -ne "no"
$wantPlugins = if ($Plugins) { $Plugins -eq "yes" } else { YesNo "Install the plug-in pack (free, about 150 MB: Surge XT, Dexed, Airwindows, Dragonfly Reverb, Chow Tape, BYOD guitar/bass amps and tuner, ZL Equalizer and Compressor, ChowMatrix delay, and the Saike, Chokehold and chmaha JSFX with drum kits and keys), so everyone has the same sounds? (Adding the JSFX runs a ReaPack sync, which also updates your other ReaPack packages.)" "y" }
$wantExtras = if ($Extras) { $Extras -eq "yes" } else { $wantPlugins -and (YesNo "Also the larger extras (about 820 MB: Neural Amp Modeler and AIDA-X amp capture players, Odin 2 synth, sforzando with the Salamander Grand piano)?" "n") }
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

# (a test's -ReaperExe: only that REAPER counts. Any other is someone's real one, and this asked it to close: PC, 0.52.5)
function Get-Reaper { $all = Get-Process reaper -ErrorAction SilentlyContinue; if ($ReaperExe) { $all | Where-Object { $_.Path -eq $ReaperExe } } else { $all } }
function Find-Reaper {
  if ($ReaperExe) { return $ReaperExe }
  $p = Get-Reaper | Select-Object -First 1
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

# ---------- 1b. the band plug-in pack (optional) ----------
# Free, open-source plug-ins every bandmate can have, each from its official release (never bundled here): what
# everyone has shows in REAPER's FX browser folder "StudioSync (everyone has)". Installers that come as .exe open for
# you to click through; a .zip of VST3 bundles goes into REAPER's own plug-in folder (UserPlugins\FX, scanned by
# REAPER, no admin rights needed).
function Release-Asset($repo, $pattern, $tag) {
  $api = if ($tag) { "https://api.github.com/repos/$repo/releases/tags/$tag" } else { "https://api.github.com/repos/$repo/releases/latest" }
  try { (Invoke-RestMethod $api -UseBasicParsing).assets | Where-Object { $_.name -match $pattern } | Select-Object -First 1 } catch { $null }
}
# Every plug-in installer here that opens a wizard is an Inno Setup one (2026-11-01: Dexed, Airwindows, Chow Tape,
# BYOD, ChowMatrix, NAM, AIDA-X, Odin 2). Those run without their windows, all at the end in one go, so Windows asks
# for permission once instead of once each. Any other installer opens its own windows as before.
$script:Quiet = @()
function Is-Inno($exe) { try { (Get-Item -LiteralPath $exe).VersionInfo.Comments -match 'Inno Setup' } catch { $false } }
function Run-Installer($name, $exe, $have) {
  if (Is-Inno $exe) { $script:Quiet += @{ name = $name; exe = $exe; have = $have }; return $true }
  Say "  $name's own installer opens: click through it (the defaults are fine)."
  Start-Process $exe -Wait
  return $false
}
function Install-Quiet {
  if ($script:Quiet.Count -eq 0) { return }
  Say "Installing $($script:Quiet.Count) plug-in(s) without their setup windows: Windows asks for permission once."
  $run = ($script:Quiet | ForEach-Object { "Start-Process -Wait -FilePath '$($_.exe -replace "'", "''")' -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-'" }) -join "; "
  $asked = $true
  try { Start-Process powershell -Verb RunAs -Wait -WindowStyle Hidden -ArgumentList @("-NoProfile", "-Command", $run) } catch { $asked = $false }
  foreach ($q in $script:Quiet) {
    $there = @($q.have | Where-Object { Test-Path $_ }).Count -gt 0
    if (-not $there -and -not $asked) { # (permission declined: each one's own installer, as before)
      Say "  $($q.name)'s own installer opens: click through it (the defaults are fine)."
      Start-Process $q.exe -Wait
      $there = @($q.have | Where-Object { Test-Path $_ }).Count -gt 0
    }
    if ($there) { Ok "$($q.name) installed" } else { Warn "$($q.name) : not found where expected afterwards ($($q.have -join ' or ')); check it in REAPER's FX browser" }
  }
  $script:Quiet = @()
}
function Install-Plugin($name, $repo, $pattern, $tag, $have) {
  if ($NoApps) { return }
  # ($have: one place or several where it lands, wildcards allowed)
  $there = { @($have | Where-Object { Test-Path $_ }).Count -gt 0 }
  if (& $there) { Ok "$name is already installed"; return }
  $a = Release-Asset $repo $pattern $tag
  if (-not $a) { Warn "$name : no download found on github.com/$repo, skipped (install it by hand if you like)"; return }
  $file = Join-Path $env:TEMP $a.name
  Say "Downloading $name ($($a.name)) ..."
  try { Invoke-WebRequest $a.browser_download_url -OutFile $file -UseBasicParsing } catch { Warn "$name didn't download: $_"; return }
  if ($file -match '\.exe$') {
    if (Run-Installer $name $file $have) { return } # (later, with the others: Install-Quiet)
  } elseif ($file -match '\.msi$') {
    Say "  $name's installer runs (it may ask for permission)."
    Start-Process msiexec -ArgumentList "/i `"$file`" /passive" -Wait
  } else {
    $x = Join-Path $env:TEMP ("bandsync_" + [guid]::NewGuid().ToString("N"))
    Expand-Archive $file $x -Force
    $fx = Join-Path $res "UserPlugins\FX"
    New-Item -ItemType Directory -Force $fx | Out-Null
    # the bundles themselves, not the .vst3 file inside each bundle's Contents
    $vst3 = @(Get-ChildItem $x -Recurse -Filter *.vst3 | Where-Object { $_.FullName.Substring($x.Length) -notmatch '\.vst3\\.' })
    $vst3 | ForEach-Object { Copy-Item $_.FullName (Join-Path $fx $_.Name) -Recurse -Force }
    # a zip holding the plug-in's own installer instead (Neural Amp Modeler 0.7.13: "NeuralAmpModeler Installer.exe")
    $exe = Get-ChildItem $x -Recurse -Filter *.exe | Select-Object -First 1
    if ($vst3.Count -eq 0 -and $exe -and (Run-Installer $name $exe.FullName $have)) { return } # (its folder stays until then)
    Remove-Item $x -Recurse -Force -ErrorAction SilentlyContinue
  }
  if (& $there) { Ok "$name installed" } else { Warn "$name : not found where expected afterwards ($($have -join ' or ')); check it in REAPER's FX browser" }
}
if ($wantPlugins) {
  $vst3 = Join-Path $env:CommonProgramFiles "VST3"
  Install-App "SurgeSynth.SurgeXT" "Surge XT"
  Install-Plugin "Dexed" "asb2m10/dexed" '-win\.exe$' $null (Join-Path $vst3 "Dexed*")
  Install-Plugin "Airwindows Consolidated" "baconpaul/airwin2rack" '^(?!.*windows7).*Windows-64bit-setup\.exe$' "DAWPlugin" (Join-Path $vst3 "Airwindows*")
  Install-Plugin "Dragonfly Reverb" "michaelwillis/dragonfly-reverb" 'win64\.zip$' $null (Join-Path $res "UserPlugins\FX\Dragonfly*")
  Install-Plugin "Chow Tape Model" "jatinchowdhury18/AnalogTapeModel" 'Win-64bit.*\.exe$' $null (Join-Path $vst3 "CHOW*")
  Install-Plugin "BYOD (guitar and bass amps, tuner)" "Chowdhury-DSP/BYOD" 'Win-64bit.*\.exe$' $null (Join-Path $vst3 "BYOD*")
  Install-Plugin "ZL Equalizer 2" "ZL-Audio/ZLEqualizer" 'Windows-x86-64\.msi$' $null (Join-Path $vst3 "ZL Equalizer*")
  Install-Plugin "ZL Compressor" "ZL-Audio/ZLCompressor" 'Windows-x86-64\.msi$' $null (Join-Path $vst3 "ZL Compressor*")
  Install-Plugin "ChowMatrix (delay)" "Chowdhury-DSP/ChowMatrix" 'Win-.*\.exe$' $null (Join-Path $vst3 "ChowMatrix*")
  if ($wantExtras) {
    # NAM: v0.7.14 and later have no release files; 0.7.13 is the newest that does
    Install-Plugin "Neural Amp Modeler" "sdatkinson/NeuralAmpModelerPlugin" '-win\.zip$' "v0.7.13" @((Join-Path $res "UserPlugins\FX\NeuralAmpModeler*"), (Join-Path $env:CommonProgramFiles "VST3\NeuralAmpModeler*"))
    Install-Plugin "AIDA-X" "AidaDSP/AIDA-X" 'win64-installer\.exe$' $null (Join-Path $vst3 "AIDA-X*")
    Install-Plugin "Odin 2" "TheWaveWarden/odin2" 'WinInstaller\.exe$' "NightlyDevel" (Join-Path $vst3 "Odin2*")
    Install-App "plogue.sforzando" "sforzando (plays the piano below)"
    $piano = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "StudioSync Instruments\Salamander Grand Piano"
    if (Test-Path $piano) { Ok "Salamander Grand piano is already there" } elseif (-not $NoApps) {
      Say "Downloading the Salamander Grand piano (about 715 MB) ..."
      $zip = Join-Path $env:TEMP "salamander.zip"
      try {
        Invoke-WebRequest "https://github.com/sfzinstruments/SalamanderGrandPiano/archive/refs/heads/master.zip" -OutFile $zip -UseBasicParsing
        Expand-Archive $zip (Split-Path $piano) -Force
        Rename-Item (Join-Path (Split-Path $piano) "SalamanderGrandPiano-master") $piano -ErrorAction SilentlyContinue
        Remove-Item $zip -ErrorAction SilentlyContinue
        Ok "Salamander Grand piano in $piano (load its .sfz file in sforzando)"
      } catch { Warn "the piano didn't download: $_" }
    }
  }
  Install-Quiet
  Ok "plug-in pack done: restart REAPER so it finds them (a re-scan in Preferences shows them, but the studio's 'everyone has' list only takes them after a restart)"
}

# ---------- 2. REAPER extensions: ReaPack and ReaImGui ----------
$userPlugins = Join-Path $res "UserPlugins"
$need = @()
if (-not (Test-Path (Join-Path $userPlugins "reaper_reapack-x64.dll"))) { $need += @{ file = "reaper_reapack-x64.dll"; url = "https://github.com/cfillion/reapack/releases/download/$ReaPackVer/reaper_reapack-x64.dll" } }
if (-not (Test-Path (Join-Path $userPlugins "reaper_imgui-x64.dll"))) { $need += @{ file = "reaper_imgui-x64.dll"; url = "https://github.com/cfillion/reaimgui/releases/download/v$ReaImGuiVer/reaper_imgui-x64.dll" } }
# js_ReaScriptAPI (drawing on the tracks, window placement, ReaNINJAM's mode) and SWS (links, a few actions), from the
# files ReaPack's ReaTeam Extensions index points at (both MIT); skipped when any copy of them is there already
if (-not (Get-ChildItem $userPlugins -Filter "reaper_js_ReaScriptAPI*" -ErrorAction SilentlyContinue)) { $need += @{ file = "reaper_js_ReaScriptAPI64.dll"; url = "https://github.com/juliansader/ReaExtensions/raw/master/js_ReaScriptAPI/v1.310/reaper_js_ReaScriptAPI64.dll" } }
if (-not (Get-ChildItem $userPlugins -Filter "reaper_sws*" -ErrorAction SilentlyContinue)) { $need += @{ file = "reaper_sws-x64.dll"; url = "https://github.com/reaper-oss/sws/releases/download/v2.14.0.7/reaper_sws-x64.dll" } }
if ($need.Count -gt 0) {
  if (Get-Reaper) {
    Say "REAPER has to restart to load its new extensions. Press Enter and REAPER is asked to close (it asks to save"
    Say "anything unsaved first; it reopens your project afterwards), or close it yourself."
    Read-Host | Out-Null
    Get-Reaper | ForEach-Object { [void]$_.CloseMainWindow() } # like clicking X: REAPER asks to save
    $script:Reopen = $true
    $waited = 0
    while (Get-Reaper) {
      Start-Sleep 1; $waited++
      if ($waited % 30 -eq 0) { # (asking again: REAPER drops a close asked for while it's busy, say scanning plug-ins for the first time)
        Get-Reaper | ForEach-Object { [void]$_.CloseMainWindow() }
        Say "Still waiting for REAPER to close (it may be scanning plug-ins, or waiting on a question: answer it if it asked one) ..."
      }
    }
  }
  New-Item -ItemType Directory -Force $userPlugins | Out-Null
  foreach ($n in $need) { Invoke-WebRequest -UseBasicParsing $n.url -OutFile (Join-Path $userPlugins $n.file); Ok "$($n.file) installed" }
} else { Ok "ReaPack, ReaImGui, js_ReaScriptAPI and SWS are already installed" }
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
  $sargs = @("serve", "--no-browser"); if ($SyncthingHome) { $sargs += @("--home", "`"$SyncthingHome`"") } # (Start-Process doesn't quote a path with spaces)
  Start-Process $st -ArgumentList $sargs -WindowStyle Hidden
  Ok "Syncthing started (StudioSync's Live sync starts it from now on)"
}
$up = $false
for ($i = 0; $i -lt 60 -and -not $up; $i++) { $null = STcli show system; $up = $LASTEXITCODE -eq 0; if (-not $up) { Start-Sleep 1 } }
if (-not $up) { Warn "Syncthing didn't answer; finish its setup by hand (see installer/SKILL.md)"; exit 1 }
$myId = (ST device-id | Select-Object -Last 1).ToString().Trim()

$root = $root.TrimEnd('\', '/')
New-Item -ItemType Directory -Force $root | Out-Null
$bj = Join-Path $root "_band\band.json"
if ($isHost -and -not (Test-Path $bj)) { # (who this folder is: lib/band.lua band.info; names are plain)
  New-Item -ItemType Directory -Force (Join-Path $root "_band") | Out-Null
  [IO.File]::WriteAllText($bj, (@{ name = $bandName; id = $folderId; drive = $driveName; owner = $user } | ConvertTo-Json -Compress))
}
# per-song sync (lib/songsync.lua writes the same block): a new bandmate gets every song's listing, and a song in
# full once they open it, so the first sync isn't the whole library. The first one set up keeps everything.
$ign = Join-Path $root ".stignore"
if (-not $isHost -and -not ((Test-Path $ign) -and (Select-String -Path $ign -Pattern '^// BandSync end$' -Quiet))) {
  [IO.File]::AppendAllText($ign, ((@('// BandSync: what this computer downloads (written by BandSync, up to the line below)', '!/_*', '!/plugins', '!/drummaps', '!/*/session.json', '!/*/folder.json', '!/*/live.json', '!/*/invites', '!/*/rooms/*/room.json', '!/*/rooms/*/summary', '!/*/rooms/*/status', '(?d)/*/*', '// BandSync end') -join "`n") + "`n")) # (no BOM: PowerShell 5.1's -Encoding UTF8 writes one, and the block's first line then reads as something else)
  Ok "this computer gets each song in full once it's opened (the rest: their listing)"
}
$folders = @(STcli config folders list)
if (-not ($folders | Where-Object { $_ })) { STcli config defaults folder path set (Split-Path $root) | Out-Null } # fresh setup only
$label = if ($folderId -eq "bandsync") { "BandSync" } else { "StudioSync $bandName" }
if ($folders -notcontains $folderId) {
  STcli config folders add --id $folderId --label $label --path $root | Out-Null
  Ok "$bandName's shared folder -> $root"
} else { Ok "$bandName's shared folder is already set up" }
STcli config folders $folderId order set smallestFirst | Out-Null
STcli config folders $folderId fswatcher-delays set 1 | Out-Null  # the default 10 s delay added 10 s to every take
STcli config devices $myId name set $user | Out-Null
if (-not $isHost) {
  $devices = STcli config devices list
  if ($devices -notcontains $hostId) {
    STcli config devices add --device-id $hostId --name "Collaborator" --introducer --auto-accept-folders | Out-Null
  }
  $shared = STcli config folders $folderId devices list
  if ($shared -notcontains $hostId) { STcli config folders $folderId devices add --device-id $hostId | Out-Null }
  Ok "paired with your collaborator"
}

# ---------- 4. StudioSync scripts, inside REAPER ----------
$work = Join-Path $env:TEMP "studiosync_setup"
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
$helper = Join-Path $src.FullName "installer\studiosync_setup.lua"
$utf8 = New-Object System.Text.UTF8Encoding($false) # no BOM: the Lua JSON reader wants plain UTF-8
function Request($mode) {
  $req = @{ sync_root = ($root -replace '\\', '/'); user = $user; mode = $mode; repo_url = "https://github.com/$Repo/raw/main/index.xml"; open_panel = ($mode -eq "verify"); jsfx = [bool]$wantPlugins } | ConvertTo-Json
  [IO.File]::WriteAllText((Join-Path (Split-Path $helper) "studiosync_setup.json"), $req, $utf8)
  $result = Join-Path (Split-Path $helper) "studiosync_setup_result.json"
  Remove-Item $result -ErrorAction SilentlyContinue
  if ($script:Reopen -and -not (Get-Reaper)) {
    # we closed REAPER: start it the way you do, so it reopens your projects as it always does (started WITH the
    # helper it came back with an empty project), then hand it the helper once it's up
    Start-Process $reaper
    for ($i = 0; $i -lt 60 -and -not (Get-Reaper | Where-Object { $_.MainWindowHandle -ne 0 }); $i++) { Start-Sleep 1 }
    Start-Sleep 5
  }
  # ONE request: the helper waits inside REAPER for ReaPack itself (asking again while ReaPack's report window was up
  # crashed REAPER on macOS, 2026-10-28)
  $once = if ($ReaperExe) { @("-newinst", "-cfgfile", "`"$res\reaper.ini`"") } else { @("-nonewinst") }
  Start-Process $reaper -ArgumentList ($once + "`"$helper`"")
  $script:Gone = $false
  for ($i = 0; $i -lt 360 -and -not (Test-Path $result); $i++) {
    Start-Sleep 1
    if ($i -gt 15 -and -not (Get-Reaper)) { $script:Gone = $true; break }
    if ($i -eq 30) { Say "Waiting for StudioSync to arrive through ReaPack. ReaPack opens its own windows on a first run (Manage repositories, Transaction report): press OK on them." }
  }
  if (-not (Test-Path $result)) { return $null }
  Start-Sleep -Milliseconds 300
  return Get-Content $result -Raw | ConvertFrom-Json
}
if ($NoReaper) { Ok "stopping before REAPER, as asked. This computer's Syncthing ID: $myId"; exit 0 }
Say "Setting up StudioSync inside REAPER (REAPER opens; on a first start it scans your plug-ins, which can take a while) ..."
$r = Request $Scripts
if (-not $r) {
  if ($script:Gone) { Warn "REAPER closed unexpectedly during setup. Open REAPER (and your project: File > Recent projects), then run this again." }
  else { Warn "REAPER didn't run the setup step. Open REAPER, then run this again." }
  exit 1
}
foreach ($s in $r.steps) { if ($s.ok) { Ok "$($s.name): $($s.detail)" } else { Warn "$($s.name): $($s.detail)" } }
$count = [int]$r.registered_actions
if ($count -ge 5) { Ok "StudioSync $($r.version) installed: $count actions (the StudioSync panel opens in REAPER)" } else { Warn "StudioSync's scripts haven't arrived yet: in REAPER, Extensions > ReaPack > Synchronize packages" }

# ---------- 5. what's left for a human (only what isn't done yet) ----------
$left = @()
$peers = @()
try {
  $x = [xml](Get-Content (Join-Path $cfgDir "config.xml"))
  $c = Invoke-RestMethod -TimeoutSec 5 -Uri ("http://" + $x.configuration.gui.address + "/rest/system/connections") -Headers @{ "X-API-Key" = $x.configuration.gui.apikey }
  $peers = @($c.connections.PSObject.Properties | Where-Object { $_.Value.connected } | ForEach-Object { $_.Name })
} catch { }
# Waits for what needs a person (James, 2026-10-31: "the installer should wait for you to sign in"), instead of
# listing it at the end: true once $test passes, false if they pressed a key to skip.
function Wait-Until($test) {
  while (-not (& $test)) {
    for ($i = 0; $i -lt 30; $i++) {
      if ([Console]::KeyAvailable) { $null = [Console]::ReadKey($true); return [bool](& $test) }
      Start-Sleep -Milliseconds 100
    }
  }
  return $true
}
if ($isHost) {
  $left += "To bring in a collaborator: StudioSync panel > Invite a collaborator, and send them what it copies (their installer is then already paired with you). When they've run it, the panel shows 'Let them in': press it."
  $left += "(Your Syncthing device ID, if they ask for it:  $myId)"
} elseif ($peers -notcontains $hostId) {
  $left += "Tell the collaborator whose ID you used: their StudioSync panel shows 'Let $user in' (or they add your Syncthing ID by hand: $myId). The shared folder then arrives by itself."
}
if ($wantLive) {
  # Any computer may end up running the NINJAM server. Windows only asks about it the first time it runs, mid-session, on that computer's screen, and until it's
  # answered nobody can connect. Asked now instead, for Tailscale addresses only (the server's own rule, lib/ninjam/bandsync.cfg). James's call, 2026-11-05.
  $srvHome = if (Test-Path (Join-Path $res "BandSync")) { Join-Path $res "BandSync" } else { Join-Path $res "StudioSync" }
  $srv = Join-Path $srvHome "ninjam\ninjamsrv.exe"
  $rule = "New-NetFirewallRule -DisplayName 'StudioSync NINJAM server' -Direction Inbound -Action Allow -Program '$($srv -replace "'", "''")' -RemoteAddress 100.64.0.0/10 -Profile Any"
  Say "Letting StudioSync's NINJAM server accept connections over Tailscale: Windows asks for permission once."
  try {
    Start-Process powershell -Verb RunAs -Wait -WindowStyle Hidden -ArgumentList @("-NoProfile", "-Command", $rule)
    Ok "The NINJAM server can accept connections over Tailscale"
  } catch { Warn "Skipped: if this computer ever runs the NINJAM server, Windows asks then. Allow it." }
  $ts = "$env:ProgramFiles\Tailscale\tailscale.exe"
  # sign in as a tagged group machine: a tagged machine's key never expires, so nobody has to sign in again before a
  # session (untagged ones sign out every 180 days). Needs the host's one-time tagOwners line (below).
  $tsSt = $null
  $tagged = $false
  if (Test-Path $ts) {
    try { $ErrorActionPreference = "Continue"; $tsSt = & $ts status --json 2>$null | ConvertFrom-Json } catch { } finally { $ErrorActionPreference = "Stop" }
    # tagged, or its key expiry was turned off by hand (then it has no KeyExpiry)
    $tagged = $tsSt -and (@($tsSt.Self.Tags) -contains "tag:bandsync" -or ($tsSt.BackendState -eq "Running" -and -not $tsSt.Self.KeyExpiry))
    if ($tagged) { Ok "Tailscale signed in, and stays signed in" }
    elseif ($tsSt -and $tsSt.BackendState -eq "Running") {
      # already signed in: left exactly as it is. Re-signing in with the tag logged a Mac OUT when the tag wasn't
      # allowed yet, and the refused tag stuck in its settings so signing in again kept failing (2026-10-28)
      Ok "Tailscale is signed in (it signs out by itself every few months: see below to keep it signed in)"
    } else {
      function Ts-Up($argv) { # runs tailscale up, opens its sign-in page; returns the exit code
        $out = Join-Path $env:TEMP "bandsync_ts_up.txt"
        Set-Content $out ""
        $p = Start-Process -FilePath $ts -ArgumentList (@("up") + $argv) -RedirectStandardError $out -NoNewWindow -PassThru
        $null = $p.Handle # (so ExitCode is readable afterwards)
        $url = $null
        for ($i = 0; $i -lt 30 -and -not $url -and -not $p.HasExited; $i++) {
          Start-Sleep 1
          $m = Select-String -Path $out -Pattern 'https://login\.tailscale\.com/\S+' | Select-Object -First 1
          if ($m) { $url = $m.Matches[0].Value }
        }
        if ($url) { Start-Process $url }
        $p.WaitForExit()
        return $p.ExitCode
      }
      Say "Signing in to Tailscale: a browser page opens; sign in with the group's account there."
      if ((Ts-Up @("--advertise-tags=tag:bandsync", "--timeout=300s")) -eq 0) { Ok "Tailscale signed in as a group machine (it stays signed in)"; $tagged = $true }
      # the refused tag stays in Tailscale's settings and every later sign-in fails on it: clear it, then sign in plainly
      elseif ((Ts-Up @("--reset", "--advertise-tags=", "--timeout=120s")) -eq 0) { Ok "Tailscale signed in (without the group tag: it signs out by itself every few months; see below)" }
      else { Warn "Tailscale sign-in didn't finish: open Tailscale from the Start menu (or its taskbar icon) and sign in." }
    }
  }
  if (Test-Path $ts) {
    $tsNow = { try { $ErrorActionPreference = "Continue"; & $ts status --json 2>$null | ConvertFrom-Json } catch { $null } finally { $ErrorActionPreference = "Stop" } }
    if (-not $tagged -and -not ((& $tsNow).BackendState -eq "Running")) {
      Say "Sign in to Tailscale now (its taskbar icon > Log in). Waiting for it; press any key to skip and do it later."
      if (Wait-Until { (& $tsNow).BackendState -eq "Running" }) { Ok "Tailscale signed in" }
    }
    if (-not $tagged -and (& $tsNow).BackendState -eq "Running" -and (& $tsNow).Self.KeyExpiry) {
      Say "One click keeps this PC signed in to Tailscale for good. In the page that opens: this PC's ... menu >"
      Say "Disable key expiry. Waiting for it; press any key to skip (it then signs out by itself every few months)."
      Start-Process "https://login.tailscale.com/admin/machines"
      if (Wait-Until { -not (& $tsNow).Self.KeyExpiry }) { Ok "Tailscale stays signed in"; $tagged = $true }
    }
  }
  if (-not $tagged) {
    $left += "Tailscale (skipped above): sign in from its taskbar icon, then at login.tailscale.com/admin/machines > this PC > ... > Disable key expiry (otherwise it signs out every few months, maybe right before a session)."
  }
  if ($isHost) { # the host's job, once: then bandmates' installers sign their machines in for good
    $left += "Tailscale, once for the whole group (if not done yet): at login.tailscale.com/admin/acls add this line inside the policy's { }:"
    $left += "    `"tagOwners`": { `"tag:bandsync`": [`"autogroup:member`"] },"
    $left += "  Then each collaborator's installer signs their machine in as a group machine that never has to sign in again."
  }
}
# Google Drive: signed in, and the band's StudioSync folder in My Drive (the first one makes it; everyone else adds the
# shared one as a shortcut: Drive has no way to do that for you, so its page opens and this waits). A key skips.
if ($wantSolo) {
  # (one drive letter per Google account signed in: the one that has StudioSync is the band's, as StudioSync itself looks)
  $myDrive = {
    $all = @(foreach ($l in [char[]](67..90)) { $d = [string]$l + ":\My Drive"; if (Test-Path $d) { $d } })
    $band = @($all | Where-Object { Test-Path "$_\$driveName" })
    if ($band) { $band[0] } elseif ($all) { $all[0] } else { $null }
  }
  $driveOk = $false
  if (-not (& $myDrive)) {
    Say "Sign in to Google Drive (its window, or its taskbar icon), with the Google account the studio's Drive folder is shared with (yours, or the studio's own account if you have one). Waiting for it; press any key to skip."
    $null = Wait-Until { & $myDrive }
  }
  $md = & $myDrive
  if ($md -and (Test-Path "$md\$driveName")) { Ok "Google Drive: the studio's '$driveName' folder is there"; $driveOk = $true }
  elseif ($md -and $isHost) { New-Item -ItemType Directory "$md\$driveName" | Out-Null; Ok "Google Drive: made '$driveName' in your My Drive"; $driveOk = $true }
  elseif ($md) {
    Say "Add the studio's Drive folder: in the page that opens, right-click '$driveName' > Organize > Add shortcut > My Drive."
    Say "(If it isn't there yet, whoever set up first shares it with you.) Waiting; press any key to skip."
    Start-Process "https://drive.google.com/drive/shared-with-me"
    if (Wait-Until { Test-Path "$md\$driveName" }) { Ok "Google Drive: the studio's '$driveName' folder is there"; $driveOk = $true }
  }
  if ($isHost -and $driveOk) { $left += "Google Drive: share the '$driveName' folder in your My Drive with each collaborator (Editor), at drive.google.com." }
  elseif (-not $driveOk) { $left += "Google Drive (skipped above): sign in, then at drive.google.com: Shared with me > right-click '$driveName' > Organize > Add shortcut > My Drive." }
}
if ($isHost) { $left += "In REAPER, open your song's project: the StudioSync panel offers 'Share this project with the studio'." }
else { $left += "In REAPER, the StudioSync panel offers 'Join the studio's project' once your collaborator has let you in: the studio's projects arrive by themselves, and the panel lists them." }
Write-Host ""
Say "Done. What's left (these need you):"
foreach ($l in $left) { Write-Host "  - $l" }
