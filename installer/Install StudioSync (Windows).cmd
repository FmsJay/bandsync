@echo off
rem StudioSync setup for Windows: double-click this file. It runs install_windows.ps1 from this folder, or downloads
rem the one that belongs to this StudioSync version if this file was downloaded on its own.
set TAG=main
set HERE=%~dp0
if exist "%HERE%install_windows.ps1" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%install_windows.ps1" -Tag %TAG%
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -Command "$f = Join-Path $env:TEMP 'studiosync_install.ps1'; Invoke-WebRequest -UseBasicParsing 'https://github.com/FmsJay/studiosync/raw/%TAG%/installer/install_windows.ps1' -OutFile $f; & $f -Tag '%TAG%'"
)
echo.
pause
