<#
  One-way backup of BandSync data into a cloud-drive folder (default: Google Drive), meant to run nightly.
  Copies new and changed files only and never deletes from the backup, so a mistake that syncs to every
  machine (a deleted take, an overwritten project) can still be recovered from here.
  Never point Syncthing and the cloud drive at the same folder: two sync engines fight over it.

  Usage: pwsh -File backup_to_drive.ps1 [-Source <folders>] [-Dest <backup folder>]
#>
param(
  [string[]]$Source = @('J:\Portable Workstation\BandSync', 'J:\Portable Workstation\DAW\REAPER\BandSync'),
  [string]$Dest = 'G:\My Drive\BandSync backup'
)

$drive = Split-Path -Qualifier $Dest
if (-not (Test-Path "$drive\")) { Write-Error "Backup drive $drive isn't mounted (is Google Drive running?)"; exit 1 }
New-Item -ItemType Directory -Force $Dest | Out-Null
$log = Join-Path $Dest 'backup.log'
$failed = 0
foreach ($s in $Source) {
  if (-not (Test-Path $s)) { Add-Content $log "$(Get-Date -Format s) skipped missing $s"; continue }
  $target = Join-Path $Dest (($s -replace '[:\\/]+', '_').Trim('_'))
  # /E: subfolders; no /MIR or /PURGE, so nothing is ever deleted from the backup.
  # Skip Syncthing's own bookkeeping and in-progress temp files.
  robocopy $s $target /E /R:2 /W:5 /NP /NDL /XD .stversions .stfolder /XF '.syncthing.*' '~syncthing~*' /LOG+:$log | Out-Null
  if ($LASTEXITCODE -ge 8) { $failed++ } # robocopy: 0-7 = success (with or without copies), 8+ = failure
}
Add-Content $log "$(Get-Date -Format s) backup finished: $failed failure(s)"
exit [int]($failed -gt 0)
