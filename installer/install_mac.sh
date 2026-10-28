#!/bin/bash
# BandSync setup for macOS: installs and sets up everything BandSync needs, skipping whatever is already there.
# Run it with "Install BandSync (Mac).command" (right-click > Open the first time), or in Terminal:
#   curl -fsSL https://github.com/FmsJay/bandsync/raw/main/installer/install_mac.sh | bash
# REAPER, ReaPack, ReaImGui, Syncthing (the shared folder), BandSync's scripts (through ReaPack), and optionally
# SonoBus + Tailscale (Live) and Google Drive for desktop (Solo edit). Every app comes from its official source.
# Uses only tools a stock Mac has (curl, hdiutil, ditto, installer): nothing here triggers the Xcode tools prompt.
# Answers can be given up front as environment variables: BS_USER, BS_HOSTING (yes/no), BS_HOST_ID, BS_ROOT,
# BS_LIVE (yes/no), BS_SOLO (yes/no), BS_SCRIPTS (reapack/folder/verify), BS_TAG.
# Not yet run on a Mac: the Windows twin (install_windows.ps1) is the tested one.
set -u
REPO="FmsJay/bandsync"
TAG="${BS_TAG:-main}"
REAIMGUI="0.10.0.5"   # shortcut: pinned, like the Windows installer
REAPACK="v1.2.6"
ARCH="$(uname -m)"    # arm64 or x86_64, which is also how the extensions name their builds
RES="$HOME/Library/Application Support/REAPER"
WORK="$(mktemp -d /tmp/bandsync_setup.XXXXXX)"

say()  { printf '\033[36m%s\033[0m\n' "$*"; }
ok()   { printf '\033[32m  OK  %s\033[0m\n' "$*"; }
warn() { printf '\033[33m  !!  %s\033[0m\n' "$*"; }
ask()  { local a; read -r -p "$1${2:+ [$2]} " a </dev/tty; echo "${a:-${2:-}}"; }
yes()  { case "$1" in [yY]*) return 0;; *) return 1;; esac; }

say "BandSync setup"
echo "This installs what BandSync needs and sets it up. It asks a few questions first (unless they were given up"
echo "front); macOS asks for your password to install some apps, and to allow a few things (all explained as they"
echo "come). Nothing already installed is changed."
echo

# ---------- 0. questions ----------
USERNAME_BS="$(echo "${BS_USER:-}" | tr -cd '[:alnum:] _-')"
while [ -z "$USERNAME_BS" ]; do USERNAME_BS="$(ask "Your name, as the band will see it" "$(id -F 2>/dev/null | cut -d' ' -f1)" | tr -cd '[:alnum:] _-')"; done
HOSTING="${BS_HOSTING:-$(ask "Are you the band's host (the first one to set up, with the machine that stays on)? (y/n)" n)}"
HOST_ID="$(echo "${BS_HOST_ID:-}" | tr '[:lower:]' '[:upper:]')"
ID_RE='^[A-Z0-9]{7}(-[A-Z0-9]{7}){7}$'
if ! yes "$HOSTING"; then
  until echo "$HOST_ID" | grep -Eq "$ID_RE"; do
    HOST_ID="$(ask "The host's Syncthing device ID (they find it in Syncthing: Actions > Show ID)" | tr '[:lower:]' '[:upper:]')"
    echo "$HOST_ID" | grep -Eq "$ID_RE" || warn "That doesn't look like a device ID (8 groups of 7 letters/digits, joined by dashes)."
  done
fi
ROOT="${BS_ROOT:-$(ask "Where should the shared BandSync folder be" "$HOME/BandSync")}"
ROOT="${ROOT%/}"
LIVE="${BS_LIVE:-$(ask "Will you use Live (hearing each other while playing)? Installs SonoBus and Tailscale (y/n)" y)}"
SOLO="${BS_SOLO:-$(ask "Will you use Solo edit (editing a song while the others are offline)? Installs Google Drive (y/n)" y)}"
echo

# ---------- 1. apps ----------
# Mount a disk image, then install the .app or .pkg inside it. Disk images with a license show it first: that's yours to agree to.
from_dmg() { # url name app-name
  local dmg="$WORK/$2.dmg" mnt="$WORK/mnt_$2"
  curl -fsSL "$1" -o "$dmg" || { warn "$2: download failed"; return 1; }
  mkdir -p "$mnt"
  hdiutil attach -nobrowse -mountpoint "$mnt" "$dmg" >/dev/null </dev/tty || { warn "$2: couldn't open the disk image"; return 1; }
  local pkg app
  pkg="$(find "$mnt" -maxdepth 1 -name '*.pkg' | head -1)"
  app="$(find "$mnt" -maxdepth 1 -name "${3:-*}.app" | head -1)"
  local rc=1 # neither a .pkg nor an .app in the image: not installed
  if [ -n "$pkg" ]; then password_note; sudo installer -pkg "$pkg" -target / >/dev/null; rc=$?
  elif [ -n "$app" ]; then ditto "$app" "/Applications/$(basename "$app")"; rc=$?
  fi
  hdiutil detach "$mnt" -quiet
  [ $rc -eq 0 ] && ok "$2 installed" || warn "$2 didn't install: install it by hand"
}
gh_asset() { # repo regex -> download URL of the latest release asset matching it
  curl -fsSL "https://api.github.com/repos/$1/releases/latest" | grep -o '"browser_download_url": *"[^"]*"' | sed 's/.*"\(http[^"]*\)"/\1/' | grep -E "$2" | head -1
}
have() { [ -d "/Applications/$1.app" ]; }
told_pw=""
password_note() { # before the first sudo: a bare "Password:" looks like something's wrong
  [ -n "$told_pw" ] && return
  told_pw=1
  say "Installing apps needs your Mac password (the one you log in with). Type it at 'Password:' below: nothing shows"
  say "while you type, that's normal. It's asked once and used only to install."
}

if have REAPER; then ok "REAPER is already installed"
else
  say "Installing REAPER (a 60-day evaluation; see reaper.fm for the license) ..."
  dmg="$(curl -fsSL https://www.reaper.fm/download.php | grep -o 'files/[0-9.x]*/reaper[0-9]*_universal\.dmg' | head -1)"
  from_dmg "https://www.reaper.fm/$dmg" REAPER REAPER
fi
if have Syncthing; then ok "Syncthing is already installed"
else say "Installing Syncthing ..."; from_dmg "$(gh_asset syncthing/syncthing-macos '\.dmg$')" Syncthing Syncthing; fi
if yes "$LIVE"; then
  if have SonoBus; then ok "SonoBus is already installed"
  else say "Installing SonoBus (may ask for your password) ..."; from_dmg "$(gh_asset sonosaurus/sonobus 'mac\.dmg$')" SonoBus SonoBus; fi
  if have Tailscale; then ok "Tailscale is already installed"
  else
    say "Installing Tailscale (asks for your password) ..."
    password_note
    curl -fsSL https://pkgs.tailscale.com/stable/Tailscale-latest-macos.pkg -o "$WORK/Tailscale.pkg" && sudo installer -pkg "$WORK/Tailscale.pkg" -target / >/dev/null && ok "Tailscale installed" || warn "Tailscale didn't install: get it from tailscale.com/download"
  fi
fi
if yes "$SOLO"; then
  if have "Google Drive"; then ok "Google Drive is already installed"
  else say "Installing Google Drive for desktop (asks for your password) ..."; from_dmg https://dl.google.com/drive-file-stream/GoogleDrive.dmg GoogleDrive "Google Drive"; fi
fi
# Tailscale sign-in as a tagged band machine: a tagged machine's key never expires, so nobody has to sign in again
# before a session (untagged ones sign out every 180 days). Needs the host's one-time tagOwners line (see the end).
TS="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
TS_TAGGED=""
if yes "$LIVE" && [ -x "$TS" ]; then
  open -a Tailscale; sleep 3
  tsst="$("$TS" status --json 2>/dev/null | tr -d '\n ')"
  TS_RUNNING=""; echo "$tsst" | grep -q '"BackendState":"Running"' && TS_RUNNING=1
  if echo "$tsst" | grep -q '"Tags":\["tag:bandsync"' || { [ -n "$TS_RUNNING" ] && ! echo "$tsst" | grep -q '"KeyExpiry"'; }; then
    ok "Tailscale signed in, and stays signed in"; TS_TAGGED=1 # tagged, or its key expiry was turned off by hand
  elif [ -n "$TS_RUNNING" ]; then
    # already signed in: left exactly as it is. Re-signing in with the tag logged a Mac OUT when the tag wasn't allowed
    # yet, and the refused tag stuck in its settings so signing in again kept failing (2026-10-28)
    ok "Tailscale is signed in (it signs out by itself every few months: see the end to keep it signed in)"
  else
    say "Signing in to Tailscale: a browser page opens; sign in with the band's account there. (macOS may first ask"
    say "to allow Tailscale's VPN configuration: click Allow.)"
    out="$WORK/ts_up.txt"; : > "$out"
    "$TS" up --advertise-tags=tag:bandsync --timeout=300s >"$out" 2>&1 &
    pid=$!; url=""
    for i in $(seq 1 30); do url="$(grep -o 'https://login.tailscale.com/[^ ]*' "$out" | head -1)"; [ -n "$url" ] && break; kill -0 $pid 2>/dev/null || break; sleep 1; done
    [ -n "$url" ] && open "$url"
    if wait $pid; then ok "Tailscale signed in as a band machine (it stays signed in)"; TS_TAGGED=1
    else
      # the refused tag stays in Tailscale's settings and every later sign-in fails on it: clear it, then sign in plainly
      "$TS" up --reset --advertise-tags= --timeout=120s >"$out" 2>&1 &
      pid=$!; url=""
      for i in $(seq 1 30); do url="$(grep -o 'https://login.tailscale.com/[^ ]*' "$out" | head -1)"; [ -n "$url" ] && break; kill -0 $pid 2>/dev/null || break; sleep 1; done
      [ -n "$url" ] && open "$url"
      if wait $pid; then ok "Tailscale signed in (without the band tag: it signs out by itself every few months; see the end)"
      else warn "Tailscale sign-in didn't finish: open Tailscale (in Applications, or its menu-bar icon) and sign in."; fi
    fi
  fi
fi
have REAPER || { warn "REAPER isn't installed: get it from reaper.fm and run this again."; exit 1; }

# ---------- 2. REAPER extensions: ReaPack and ReaImGui ----------
PLUG="$RES/UserPlugins"
need=""
[ -f "$PLUG/reaper_reapack-$ARCH.dylib" ] || need="$need reaper_reapack-$ARCH.dylib=https://github.com/cfillion/reapack/releases/download/$REAPACK/reaper_reapack-$ARCH.dylib"
[ -f "$PLUG/reaper_imgui-$ARCH.dylib" ] || need="$need reaper_imgui-$ARCH.dylib=https://github.com/cfillion/reaimgui/releases/download/v$REAIMGUI/reaper_imgui-$ARCH.dylib"
if [ -n "$need" ]; then
  if pgrep -x REAPER >/dev/null; then
    say "REAPER has to restart to load its new extensions. Press Return and REAPER is asked to quit (it asks to save"
    say "anything unsaved first; it reopens your project afterwards), or quit it yourself."
    read -r </dev/tty
    osascript -e 'tell application "REAPER" to quit' >/dev/null 2>&1
    REOPEN=true
    waited=0
    while pgrep -x REAPER >/dev/null; do
      sleep 1; waited=$((waited + 1))
      [ $((waited % 30)) -eq 0 ] && say "Still waiting for REAPER to close (answer its save question if it asked one) ..."
    done
  fi
  mkdir -p "$PLUG"
  for n in $need; do curl -fsSL "${n#*=}" -o "$PLUG/${n%%=*}" && ok "${n%%=*} installed" || warn "${n%%=*} didn't download"; done
else ok "ReaPack and ReaImGui are already installed"; fi
API="$RES/Scripts/ReaTeam Extensions/API"
if [ ! -f "$API/imgui.lua" ]; then
  mkdir -p "$API" && curl -fsSL "https://codeberg.org/cfillion/reaimgui/raw/v$REAIMGUI/shims/imgui.lua" -o "$API/imgui.lua" && ok "ReaImGui shim installed"
fi

# ---------- 3. Syncthing: the shared folder ----------
ST="/Applications/Syncthing.app/Contents/Resources/syncthing/syncthing"
STHOME="$HOME/Library/Application Support/Syncthing"
[ -x "$ST" ] || { warn "Syncthing wasn't found: install it from syncthing.net and run this again."; exit 1; }
stcli() { "$ST" cli --home "$STHOME" "$@" 2>&1; }
if ! pgrep -x syncthing >/dev/null; then
  say "Starting Syncthing. macOS asks to let it find devices on your local network: click Allow."
  open -a Syncthing
fi
up=""; for i in $(seq 1 60); do stcli show system >/dev/null && { up=1; break; }; sleep 1; done
[ -n "$up" ] || { warn "Syncthing didn't answer; finish its setup by hand (see installer/SKILL.md)"; exit 1; }
MY_ID="$("$ST" device-id --home "$STHOME" 2>/dev/null | tail -1 | tr -d '[:space:]')"
mkdir -p "$ROOT"
if stcli config folders list | grep -qx bandsync; then ok "shared folder 'bandsync' already set up"
else
  stcli config defaults folder path set "$(dirname "$ROOT")" >/dev/null # new folders land beside it
  stcli config folders add --id bandsync --label BandSync --path "$ROOT" >/dev/null && ok "shared folder 'bandsync' -> $ROOT"
fi
stcli config folders bandsync order set smallestFirst >/dev/null
stcli config folders bandsync fswatcher-delays set 1 >/dev/null  # the default 10 s delay added 10 s to every take
stcli config devices "$MY_ID" name set "$USERNAME_BS" >/dev/null
if ! yes "$HOSTING"; then
  stcli config devices list | grep -qx "$HOST_ID" || stcli config devices add --device-id "$HOST_ID" --name "Band host" --introducer --auto-accept-folders >/dev/null
  stcli config folders bandsync devices list | grep -qx "$HOST_ID" || stcli config folders bandsync devices add --device-id "$HOST_ID" >/dev/null
  CONNECTED=""
  stcli show connections 2>/dev/null | tr -d '\n ' | grep -q "\"$HOST_ID\":{[^}]*\"connected\":true" && CONNECTED=1
  if [ -n "$CONNECTED" ]; then ok "paired with the host, and connected"
  else ok "paired with the host (they still have to add you: see the end)"; fi
fi

# ---------- 4. BandSync scripts, inside REAPER ----------
ZREF="heads/main"; [ "$TAG" != main ] && ZREF="tags/$TAG"
curl -fsSL "https://codeload.github.com/$REPO/zip/refs/$ZREF" -o "$WORK/bandsync.zip" && ditto -x -k "$WORK/bandsync.zip" "$WORK/src"
HELPER="$(find "$WORK/src" -path '*/installer/bandsync_setup.lua' | head -1)"
HDIR="$(dirname "$HELPER")"
request() { # mode -> runs the helper in REAPER, leaves its JSON result in $HDIR/bandsync_setup_result.json
  local panel=false; [ "$1" = verify ] && panel=true
  printf '{"sync_root":"%s","user":"%s","mode":"%s","repo_url":"https://github.com/%s/raw/main/index.xml","open_panel":%s}' \
    "$ROOT" "$USERNAME_BS" "$1" "$REPO" "$panel" > "$HDIR/bandsync_setup.json"
  rm -f "$HDIR/bandsync_setup_result.json"
  if [ -n "${REOPEN:-}" ] && ! pgrep -x REAPER >/dev/null; then
    # we quit REAPER: start it the way you do, so it reopens your project tabs as it always does (started WITH the
    # helper it came back with one tab, 2026-10-28), then hand it the helper once it's up
    open -a REAPER
    for i in $(seq 1 60); do pgrep -x REAPER >/dev/null && break; sleep 1; done
    sleep 8
  fi
  # Any Apple Event ("open -a") reaching REAPER while ReaPack's report window is open crashes it on macOS
  # (2026-10-28). A REAPER running BandSync's background loop (Autostart, from __startup.lua) gets a request FILE
  # instead; only a REAPER that isn't running is started with the helper.
  local REQ="$RES/BandSync/install-request" HANDED=""
  if pgrep -x REAPER >/dev/null && grep -q "BandSync autostart" "$RES/Scripts/__startup.lua" 2>/dev/null; then
    mkdir -p "$RES/BandSync"; printf '%s' "$HELPER" > "$REQ"
    for i in $(seq 1 20); do [ -f "$REQ" ] || { HANDED=1; break; }; sleep 1; done
    rm -f "$REQ" # not picked up (an older BandSync, or a window holding REAPER): asked the other way below
  fi
  if [ -z "$HANDED" ]; then
    if pgrep -x REAPER >/dev/null; then
      say "REAPER is about to run BandSync's setup step. First close any ReaPack window in REAPER (like its"
      say "'Transaction report'): one left open makes REAPER quit. Then press Return."
      read -r </dev/tty
    fi
    open -a REAPER "$HELPER" # ONE request: the helper waits inside REAPER for ReaPack itself
  fi
  GONE=""
  for i in $(seq 1 360); do
    [ -f "$HDIR/bandsync_setup_result.json" ] && break
    if [ $i -gt 15 ] && ! pgrep -x REAPER >/dev/null; then GONE=1; break; fi
    [ $i -eq 30 ] && say "Waiting for BandSync to arrive through ReaPack. If REAPER shows ReaPack's report window, close it."
    sleep 1
  done
  [ -f "$HDIR/bandsync_setup_result.json" ]
}
say "Setting up BandSync inside REAPER (REAPER opens; on a first start it scans your plug-ins, which can take a while) ..."
say "macOS may ask to let REAPER use the microphone: click Allow, or your takes record silence."
if request "${BS_SCRIPTS:-reapack}"; then
  if grep -q '"ok": *false' "$HDIR/bandsync_setup_result.json"; then warn "REAPER setup step had problems:"; cat "$HDIR/bandsync_setup_result.json"
  else ok "REAPER: name, shared folder and BandSync repository set"; fi
elif [ -n "$GONE" ]; then warn "REAPER closed unexpectedly during setup. Open REAPER (and your project: File > Recent projects), then run this again."; exit 1
else warn "REAPER didn't run the setup step. Open REAPER, then run this again."; exit 1; fi
count="$(grep -o '"registered_actions": *[0-9]*' "$HDIR/bandsync_setup_result.json" | grep -o '[0-9]*$')"
[ "${count:-0}" -ge 5 ] && ok "BandSync installed: $count actions (the BandSync panel opens in REAPER)" || warn "BandSync's scripts haven't arrived yet: in REAPER, Extensions > ReaPack > Synchronize packages"

# ---------- 5. what's left for a human ----------
echo
say "Done. What's left (these need you):"
if yes "$HOSTING"; then
  echo "  - Your Syncthing device ID, for bandmates' installers:  $MY_ID"
  echo "  - When a bandmate sends you their ID: Syncthing (menu bar icon > Open) > Add Remote Device, paste it,"
  echo "    and on its Sharing tab tick 'BandSync'."
else
  if [ -z "${CONNECTED:-}" ]; then
    echo "  - Send the host your Syncthing device ID:  $MY_ID"
    echo "    (They add it in Syncthing; the shared folder then arrives by itself.)"
  fi
fi
if yes "$LIVE" && [ -z "$TS_TAGGED" ]; then
  echo "  - Tailscale: if it isn't signed in, open it (Applications > Tailscale, or its menu-bar icon) and sign in with the"
  echo "    band's account. To keep this Mac signed in for good: login.tailscale.com/admin/machines > this Mac > ... >"
  echo "    Disable key expiry (one click; otherwise it signs out every few months, maybe right before a session)."
fi
if yes "$LIVE" && yes "$HOSTING"; then # the host's job, once: then bandmates' installers sign their machines in for good
  echo "  - Tailscale, once for the whole band (if not done yet): at login.tailscale.com/admin/acls add this line inside the"
  echo '    policy'"'"'s { }:   "tagOwners": { "tag:bandsync": ["autogroup:member"] },'
  echo "    Then each bandmate's installer signs their machine in as a band machine that never has to sign in again."
fi
if yes "$SOLO"; then
  echo "  - Google Drive: open it and sign in; allow its extension when macOS asks."
  if yes "$HOSTING"; then echo "    Make a 'BandSync' folder in My Drive and share it with each bandmate (Editor)."
  else echo "    At drive.google.com: Shared with me > right-click BandSync > Organize > Add shortcut > My Drive."; fi
fi
echo "  - Recording latency: connect a cable from your interface's output 1 to an input, then in the BandSync"
echo "    panel: More > Calibrate latency."
echo "  - In the panel, open the band's session (or publish yours, as host); its Set up list shows anything still missing."
rm -rf "$WORK"
