#!/bin/bash
# BandSync setup for macOS: double-click this file (the first time: right-click > Open, since it isn't from the App
# Store). It runs install_mac.sh from this folder, or downloads it if this file was downloaded on its own.
HERE="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$HERE/install_mac.sh" ]; then bash "$HERE/install_mac.sh"
else curl -fsSL https://github.com/FmsJay/bandsync/raw/main/installer/install_mac.sh | bash; fi
echo
read -r -p "Press Return to close this window. " _
