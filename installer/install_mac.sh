#!/bin/bash
# StudioSync setup for macOS: installs and sets up everything StudioSync needs, skipping whatever is already there.
# Run it with "Install BandSync (Mac).command" (right-click > Open the first time), or in Terminal:
#   curl -fsSL "https://raw.githubusercontent.com/FmsJay/bandsync/main/installer/install_mac.sh?$(date +%s)" | bash
# (the ?<time>: GitHub's cache handed out the previous installer for minutes after a release, 2026-10-31)
# REAPER, ReaPack, ReaImGui, Syncthing (the shared folder), StudioSync's scripts (through ReaPack), SonoBus
# (hearing each other) and Google Drive for desktop (the band's copy). Every app comes from its official source.
# Uses only tools a stock Mac has (curl, hdiutil, ditto, installer): nothing here triggers the Xcode tools prompt.
# Answers can be given up front as environment variables: BS_USER, BS_HOSTING (yes: the first one set up), BS_HOST_ID (a set-up bandmate's Syncthing ID), BS_ROOT,
# BS_LIVE / BS_SOLO (no: leave out SonoBus / Google Drive; both go in unless said), BS_SCRIPTS (reapack/folder/verify), BS_TAG,
# BS_BAND_ID / BS_BAND_NAME (the band an invitation is for: its Syncthing folder id and name; the first band is "bandsync").
# A bandmate's panel (Invite a collaborator) hands out the curl line above with BS_HOST_ID already in it.
# First run on a Mac 2026-10-28 (fixes in c2639a5); reviewed again for 0.34 (2026-10-31).
set -u
REPO="FmsJay/bandsync"
TAG="${BS_TAG:-main}"
REAIMGUI="0.10.0.5"   # shortcut: pinned, like the Windows installer
REAPACK="v1.2.6"
# arm64 or x86_64, which is also how the extensions name their builds. (Not uname -m: a Terminal running under
# Rosetta says x86_64 on an Apple Silicon Mac, and those builds don't load in REAPER there.)
ARCH="x86_64"; [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ] && ARCH="arm64"
RES="$HOME/Library/Application Support/REAPER"
WORK="$(mktemp -d /tmp/bandsync_setup.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT # (also when it stops early)

say()  { printf '\033[36m%s\033[0m\n' "$*"; }
ok()   { printf '\033[32m  OK  %s\033[0m\n' "$*"; }
warn() { printf '\033[33m  !!  %s\033[0m\n' "$*"; }
ask()  { local a; read -e -r -p "$1${2:+ [$2]} " a </dev/tty; echo "${a:-${2:-}}"; } # (-e: arrow keys edit, not type escape codes)
plain() { printf '%s' "$1" | iconv -f UTF-8 -t ASCII//TRANSLIT 2>/dev/null | LC_ALL=C tr -cd 'A-Za-z0-9 _-'; } # "CHILIØ" -> "CHILIO"
yes()  { case "$1" in [yY]*) return 0;; *) return 1;; esac; }

say "StudioSync setup"
echo "This installs what StudioSync needs and sets it up. It asks a few questions first (unless they were given up"
echo "front); macOS asks for your password to install some apps, and to allow a few things (all explained as they"
echo "come). Nothing already installed is changed."
echo

# ---------- 0. questions ----------
# (names are plain letters, digits, spaces, - and _: the default is shown already cleaned, and a typed name that
# changes when cleaned is said, not changed silently)
USERNAME_BS="$(plain "${BS_USER:-}")"
while [ -z "$USERNAME_BS" ]; do
  typed="$(ask "Your name, as the studio will see it (you can change it later)" "$(plain "$(id -F 2>/dev/null | cut -d' ' -f1)")")"
  USERNAME_BS="$(plain "$typed")"
  [ -n "$USERNAME_BS" ] && [ "$USERNAME_BS" != "$typed" ] && say "Using the name '$USERNAME_BS' (plain letters only)."
done
# Pairing: with whoever in the band is already set up (any of them: every machine passes the folder on). "Host" is
# a song's, not a machine's: anyone can host a song (James, 2026-10-31: "are you the band's host" read as a role).
if [ -n "${BS_HOSTING:-}" ]; then HOSTING="$BS_HOSTING" # (the old way of saying "I'm the first")
elif [ -n "${BS_HOST_ID:-}" ]; then HOSTING=n # (an invitation: someone is set up, and that's their ID)
elif yes "$(ask "Is someone in the studio already set up with StudioSync? (y/n)" y)"; then HOSTING=n
else HOSTING=y; fi
HOST_ID="$(echo "${BS_HOST_ID:-}" | tr '[:lower:]' '[:upper:]')"
ID_RE='^[A-Z0-9]{7}(-[A-Z0-9]{7}){7}$'
if ! yes "$HOSTING"; then
  echo "$HOST_ID" | grep -Eq "$ID_RE" || {
    say "Their Syncthing device ID is 8 groups of 7 letters and digits, like ABCDEFG-HIJKLMN-...-1234567 (63 characters)."
    say "Easiest: they press 'Invite a collaborator' in their StudioSync panel and send you the line it copies (it has the ID"
    say "in it). Or they find it in Syncthing: Actions > Show ID. Copy all of it and paste it here."
  }
  until echo "$HOST_ID" | grep -Eq "$ID_RE"; do
    HOST_ID="$(ask "Paste their Syncthing device ID (in their Syncthing: Actions > Show ID)" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"
    echo "$HOST_ID" | grep -Eq "$ID_RE" || warn "That doesn't look like a device ID (8 groups of 7 letters/digits, joined by dashes)."
  done
else
  say "You're the first: at the end you get your Syncthing ID to send to each collaborator who installs."
fi
# the band (docs/bands-design.md): each its own shared folder. An invitation names it; the first one set up names it.
FOLDER_ID="$(printf '%s' "${BS_BAND_ID:-}" | LC_ALL=C tr -cd 'a-z0-9-')"
if ! yes "$HOSTING" && [ -z "$FOLDER_ID" ]; then # (someone's device ID typed in by hand, no invitation)
  FOLDER_ID="$(ask "The studio's ID (it's in their invitation, after BS_BAND_ID=; press Return if they don't have one)" bandsync | LC_ALL=C tr -cd 'a-z0-9-')"
  [ -n "$FOLDER_ID" ] || FOLDER_ID=bandsync
fi
BAND_NAME="$(plain "${BS_BAND_NAME:-}")"
if yes "$HOSTING" && [ -z "$BAND_NAME" ]; then
  while [ -z "$BAND_NAME" ]; do BAND_NAME="$(plain "$(ask "Name your studio" "My studio")")"; done
fi
[ -n "$BAND_NAME" ] || BAND_NAME="the studio"
DEF_ROOT="$HOME/BandSync"
if [ "$FOLDER_ID" != bandsync ]; then DEF_ROOT="$HOME/StudioSync $BAND_NAME"; fi
while :; do
  ROOT="${BS_ROOT:-$(ask "Where should $BAND_NAME's shared folder be" "$DEF_ROOT")}"
  ROOT="$(printf '%s' "$ROOT" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/\\\(.\)/\1/g')" # (dragged in from Finder: "\ " and a trailing space)
  ROOT="${ROOT/#\~/$HOME}"
  ROOT="${ROOT%/}"
  case "$ROOT" in /*) break;; esac
  warn "That isn't a full folder path (it should start with / or ~). Try again, or drag the folder in from Finder."
  BS_ROOT=""
done
# The first one set up: an ID of the group's own. They all used to get "bandsync", so someone in two such groups had the two
# folders treated as one and their files mixed. Run again on the same folder, it keeps the ID it has; a folder from before
# groups had IDs, with no band.json yet, is "bandsync" (lib/band.lua band.info).
if [ -z "$FOLDER_ID" ]; then
  if [ -f "$ROOT/_band/band.json" ]; then FOLDER_ID="$(sed -n 's/.*"id"[^"]*"\([^"]*\)".*/\1/p' "$ROOT/_band/band.json" | head -1)"
  elif [ -n "$(ls -A "$ROOT" 2>/dev/null)" ]; then FOLDER_ID=bandsync; fi
  if [ -z "$FOLDER_ID" ]; then
    SLUG="$(printf '%s' "$BAND_NAME" | tr '[:upper:]' '[:lower:]' | LC_ALL=C sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
    FOLDER_ID="bandsync-${SLUG:-group}-$(printf '%04x' $((RANDOM * 2)))"
  fi
fi
DRIVE_NAME="BandSync"; [ "$FOLDER_ID" != bandsync ] && DRIVE_NAME="StudioSync - $BAND_NAME"
# SonoBus (hearing each other) and Google Drive (the group's copy) are part of StudioSync, not asked. Tailscale isn't any more (James, 2026-11-03):
# only the Play tab's NINJAM wants it, or someone whose router stops SonoBus (Settings > Advanced says how).
# (James, 2026-10-31: "it feels like a core feature"); BS_LIVE=no / BS_SOLO=no still leave them out.
LIVE="${BS_LIVE:-y}"
SOLO="${BS_SOLO:-y}"
if [ -z "${BS_PLUGINS:-}" ]; then
  say "The plug-in pack (free, about 350 MB): Surge XT, Dexed, Airwindows, Dragonfly Reverb, Chow Tape, BYOD"
  say "guitar/bass amps and tuner, ZL Equalizer and Compressor, ChowMatrix delay, and the Saike, Chokehold and chmaha"
  say "JSFX with drum kits and keys, so everyone has the same sounds. (Adding the JSFX also updates your other ReaPack packages.)"
fi
PLUGINS="${BS_PLUGINS:-$(ask "Install the plug-in pack? (y/n)" y)}"
EXTRAS="${BS_EXTRAS:-n}"
if yes "$PLUGINS" && [ -z "${BS_EXTRAS:-}" ]; then
  say "The larger extras (about 880 MB): Neural Amp Modeler and AIDA-X amp capture players, Odin 2 synth, and the"
  say "Salamander Grand piano for sforzando."
  EXTRAS="$(ask "Install the extras too? (y/n)" n)"
fi
echo

# ---------- 1. apps ----------
# Mount a disk image, then install the .app or .pkg inside it. Disk images with a license show it first: that's yours to agree to.
from_dmg() { # url name app-name
  local dmg="$WORK/$2.dmg" mnt="$WORK/mnt_$2"
  curl -fsSL "$1" -o "$dmg" || { warn "$2: download failed"; return 1; }
  mkdir -p "$mnt"
  # (a disk image with a licence shows it here, and waits for you to agree: it used to go to /dev/null and look hung)
  PAGER=cat hdiutil attach -noverify -nobrowse -mountpoint "$mnt" "$dmg" </dev/tty | grep -v '^/dev/' || true
  [ -d "$mnt" ] && [ -n "$(ls -A "$mnt" 2>/dev/null)" ] || { warn "$2: couldn't open the disk image"; return 1; }
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
gh_asset_tag() { # repo tag regex -> download URL of that release's asset matching it
  curl -fsSL "https://api.github.com/repos/$1/releases/tags/$2" | grep -o '"browser_download_url": *"[^"]*"' | sed 's/.*"\(http[^"]*\)"/\1/' | grep -E "$3" | head -1
}
# A plug-in's disk image: its .pkg if it has one, else its plug-in bundles copied into your own Plug-Ins folders
# (no password needed). `pattern`: a glob that's there once it's installed, in /Library or ~/Library.
plugin_found() { find /Library/Audio/Plug-Ins "$HOME/Library/Audio/Plug-Ins" -maxdepth 2 -name "$1" 2>/dev/null | grep -q .; }
plugin_dmg() { # url name pattern
  [ -n "$1" ] || { warn "$2: no download found, skipped"; return 1; }
  if plugin_found "$3"; then ok "$2 is already installed"; return 0; fi
  local dmg="$WORK/$2.dmg" mnt="$WORK/mnt_plugin"
  say "Installing $2 ..."
  curl -fsSL "$1" -o "$dmg" || { warn "$2: download failed"; return 1; }
  mkdir -p "$mnt"
  PAGER=cat hdiutil attach -noverify -nobrowse -mountpoint "$mnt" "$dmg" </dev/tty | grep -v '^/dev/' || true
  [ -d "$mnt" ] && [ -n "$(ls -A "$mnt" 2>/dev/null)" ] || { warn "$2: couldn't open the disk image"; return 1; }
  local pkg; pkg="$(find "$mnt" -maxdepth 2 -name '*.pkg' | head -1)"
  if [ -n "$pkg" ]; then password_note; sudo installer -pkg "$pkg" -target / >/dev/null
  else
    local d="$HOME/Library/Audio/Plug-Ins"
    mkdir -p "$d/VST3" "$d/Components" "$d/CLAP"
    find "$mnt" -maxdepth 3 -name '*.vst3' -prune | while read -r b; do ditto "$b" "$d/VST3/$(basename "$b")"; done
    find "$mnt" -maxdepth 3 -name '*.component' -prune | while read -r b; do ditto "$b" "$d/Components/$(basename "$b")"; done
    find "$mnt" -maxdepth 3 -name '*.clap' -prune | while read -r b; do ditto "$b" "$d/CLAP/$(basename "$b")"; done
  fi
  hdiutil detach "$mnt" -quiet
  plugin_found "$3" && ok "$2 installed" || warn "$2 didn't install: install it by hand"
}
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
fi
if yes "$SOLO"; then
  if have "Google Drive"; then ok "Google Drive is already installed"
  else say "Installing Google Drive for desktop (asks for your password) ..."; from_dmg https://dl.google.com/drive-file-stream/GoogleDrive.dmg GoogleDrive "Google Drive"; fi
fi
# Google Drive: signed in, and the band's BandSync folder in My Drive (the first one makes it; everyone else adds
# the shared one as a shortcut: Drive has no way to do that for you, so its page opens and this waits). Return skips.
if yes "$SOLO" && have "Google Drive"; then
  # (one My Drive per Google account signed in; with several, the one that has BandSync is the band's, as BandSync
  # itself looks: lib/drive.lua. Mac 0.34.4: a personal and a band account, and head -1 watched the wrong one.)
  drives() { ls -d "$HOME"/Library/CloudStorage/GoogleDrive-*/"My Drive" 2>/dev/null; }
  mydrive() {
    [ -n "${PICKED:-}" ] && [ -d "$PICKED" ] && { echo "$PICKED"; return; }
    local d; while IFS= read -r d; do [ -d "$d/$DRIVE_NAME" ] && { echo "$d"; return; }; done < <(drives)
    drives | head -1
  }
  account() { echo "$1" | sed -n 's#.*/GoogleDrive-\([^/]*\)/My Drive$#\1#p'; } # the account's e-mail, from its folder
  if [ -z "$(mydrive)" ]; then
    open -a "Google Drive"
    say "Sign in to Google Drive in its window, with the Google account the studio's Drive folder is shared with (yours,"
    say "or the studio's own account if you have one). Allow its extension if macOS asks."
    say "Waiting for it; press Return to skip and do it later."
    while [ -z "$(mydrive)" ]; do read -t 3 -r </dev/tty && break; done
  fi
  MD="$(mydrive)"
  if [ -n "$MD" ] && [ ! -d "$MD/$DRIVE_NAME" ] && [ "$(drives | wc -l)" -gt 1 ]; then
    say "Google Drive has several accounts signed in here. Which one is the studio's (it gets the studio's folder)?"
    i=0; while IFS= read -r d; do i=$((i + 1)); echo "    $i) $(account "$d")"; done < <(drives)
    n="$(ask "Number" 1)"
    PICKED="$(drives | sed -n "${n}p")"; [ -n "$PICKED" ] && MD="$PICKED"
  fi
  if [ -n "$MD" ] && [ -d "$MD/$DRIVE_NAME" ]; then ok "Google Drive: the studio's '$DRIVE_NAME' folder is there ($(account "$MD"))"; DRIVE_OK=1
  elif [ -n "$MD" ] && yes "$HOSTING"; then
    mkdir -p "$MD/$DRIVE_NAME" && ok "Google Drive: made '$DRIVE_NAME' in your My Drive (share it at the end)"; DRIVE_OK=1
  elif [ -n "$MD" ]; then
    say "Add the studio's Drive folder: in the page that opens, right-click '$DRIVE_NAME' > Organize > Add shortcut > My Drive."
    say "(If it isn't there yet, whoever set up first shares it with you.) Waiting; press Return to skip."
    open "https://drive.google.com/drive/shared-with-me?authuser=$(account "$MD")" # (in that account, not whichever the browser has)
    while [ ! -d "$MD/$DRIVE_NAME" ]; do read -t 3 -r </dev/tty && break; done
    [ -d "$MD/$DRIVE_NAME" ] && { ok "Google Drive: the studio's '$DRIVE_NAME' folder is there"; DRIVE_OK=1; }
  fi
fi
# the band plug-in pack (optional): free, open-source plug-ins every bandmate can have, each from its official release
# (never bundled here); what everyone has shows in REAPER's FX browser folder "BandSync (everyone has)"
if yes "$PLUGINS"; then
  plugin_dmg "$(gh_asset_tag surge-synthesizer/releases-xt "$(curl -fsSL https://api.github.com/repos/surge-synthesizer/releases-xt/releases/latest | grep -o '"tag_name": *"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/')" 'macOS-[0-9.]+\.dmg$')" "Surge XT" "Surge XT*"
  plugin_dmg "$(gh_asset asb2m10/dexed 'macOS\.dmg$')" "Dexed" "Dexed*"
  plugin_dmg "$(gh_asset_tag baconpaul/airwin2rack DAWPlugin 'macOS.*\.dmg$')" "Airwindows Consolidated" "Airwindows*"
  plugin_dmg "$(gh_asset michaelwillis/dragonfly-reverb 'macos-universal\.dmg$')" "Dragonfly Reverb" "Dragonfly*"
  plugin_dmg "$(gh_asset jatinchowdhury18/AnalogTapeModel 'Mac.*\.dmg$')" "Chow Tape Model" "CHOW*"
  plugin_dmg "$(gh_asset Chowdhury-DSP/BYOD 'Mac-.*\.dmg$')" "BYOD" "BYOD*"
  arch="$( [ "$ARCH" = arm64 ] && echo arm64 || echo x86-64 )"
  plugin_dmg "$(gh_asset ZL-Audio/ZLEqualizer "macOS-$arch\.dmg$")" "ZL Equalizer 2" "ZL Equalizer*"
  plugin_dmg "$(gh_asset ZL-Audio/ZLCompressor "macOS-$arch\.dmg$")" "ZL Compressor" "ZL Compressor*"
  plugin_dmg "$(gh_asset Chowdhury-DSP/ChowMatrix 'Mac-.*\.dmg$')" "ChowMatrix" "ChowMatrix*"
  if yes "$EXTRAS"; then
    # NAM: v0.7.14 and later have no release files; 0.7.13 is the newest that does
    plugin_dmg "$(gh_asset_tag sdatkinson/NeuralAmpModelerPlugin v0.7.13 'mac\.dmg$')" "Neural Amp Modeler" "NeuralAmpModeler*"
    plugin_dmg "$(gh_asset AidaDSP/AIDA-X 'macos-universal.*\.dmg$')" "AIDA-X" "AIDA-X*"
    odin="$(gh_asset_tag TheWaveWarden/odin2 NightlyDevel 'MacInstaller\.pkg$')"
    if plugin_found "Odin2*"; then ok "Odin 2 is already installed"
    elif [ -n "$odin" ] && curl -fsSL "$odin" -o "$WORK/odin2.pkg"; then password_note; sudo installer -pkg "$WORK/odin2.pkg" -target / >/dev/null && ok "Odin 2 installed"
    else warn "Odin 2 didn't download: install it by hand"; fi
    piano="$HOME/Documents/BandSync Instruments/Salamander Grand Piano"
    if [ -d "$piano" ]; then ok "Salamander Grand piano is already there"
    else
      say "Downloading the Salamander Grand piano (about 715 MB) ..."
      mkdir -p "$(dirname "$piano")"
      if curl -fsSL "https://github.com/sfzinstruments/SalamanderGrandPiano/archive/refs/heads/master.zip" -o "$WORK/salamander.zip" &&
         ditto -x -k "$WORK/salamander.zip" "$(dirname "$piano")" && mv "$(dirname "$piano")/SalamanderGrandPiano-master" "$piano"; then
        ok "Salamander Grand piano in $piano: play it with sforzando (free, plogue.com/products/sforzando.html)"
      else warn "the piano didn't download"; fi
    fi
  fi
fi
have REAPER || { warn "REAPER isn't installed: get it from reaper.fm and run this again."; exit 1; }

# ---------- 2. REAPER extensions: ReaPack and ReaImGui ----------
PLUG="$RES/UserPlugins"
need=""
[ -f "$PLUG/reaper_reapack-$ARCH.dylib" ] || need="$need reaper_reapack-$ARCH.dylib=https://github.com/cfillion/reapack/releases/download/$REAPACK/reaper_reapack-$ARCH.dylib"
[ -f "$PLUG/reaper_imgui-$ARCH.dylib" ] || need="$need reaper_imgui-$ARCH.dylib=https://github.com/cfillion/reaimgui/releases/download/v$REAIMGUI/reaper_imgui-$ARCH.dylib"
# js_ReaScriptAPI (drawing on the tracks, window placement, ReaNINJAM's mode) and SWS (links, a few actions), from the
# files ReaPack's ReaTeam Extensions index points at (both MIT); skipped when any copy of them is there already
JSF="reaper_js_ReaScriptAPI64.dylib"; [ "$ARCH" = arm64 ] && JSF="reaper_js_ReaScriptAPI64ARM.dylib"
ls "$PLUG"/reaper_js_ReaScriptAPI* >/dev/null 2>&1 || need="$need $JSF=https://github.com/juliansader/ReaExtensions/raw/master/js_ReaScriptAPI/v1.310/$JSF"
ls "$PLUG"/reaper_sws* >/dev/null 2>&1 || need="$need reaper_sws-$ARCH.dylib=https://github.com/reaper-oss/sws/releases/download/v2.14.0.7/reaper_sws-$ARCH.dylib"
if [ -n "$need" ]; then
  if pgrep -x REAPER >/dev/null; then
    say "REAPER has to restart to load its new extensions: quit REAPER now (Cmd+Q; save if it asks). It's reopened"
    say "afterwards, with your project."
    REOPEN=true
    waited=0
    while pgrep -x REAPER >/dev/null; do
      sleep 1; waited=$((waited + 1))
      [ $((waited % 30)) -eq 0 ] && say "Still waiting for REAPER to close (answer its save question if it asked one) ..."
    done
  fi
  mkdir -p "$PLUG"
  for n in $need; do curl -fsSL "${n#*=}" -o "$PLUG/${n%%=*}" && ok "${n%%=*} installed" || warn "${n%%=*} didn't download"; done
else ok "ReaPack, ReaImGui, js_ReaScriptAPI and SWS are already installed"; fi
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
if yes "$HOSTING" && [ ! -f "$ROOT/_band/band.json" ]; then # (who this folder is: lib/band.lua band.info; names are plain)
  mkdir -p "$ROOT/_band"
  printf '{ "name": "%s", "id": "%s", "drive": "%s", "owner": "%s" }\n' "$BAND_NAME" "$FOLDER_ID" "$DRIVE_NAME" "$USERNAME_BS" > "$ROOT/_band/band.json"
fi
# per-song sync (lib/songsync.lua writes the same block): a new bandmate gets every song's listing, and a song in
# full once they open it, so the first sync isn't the whole library. The first one set up keeps everything.
if ! yes "$HOSTING" && ! grep -q '^// BandSync end$' "$ROOT/.stignore" 2>/dev/null; then
  printf '%s\n' '// BandSync: what this computer downloads (written by BandSync, up to the line below)' '!/_*' '!/plugins' '!/drummaps' '!/*/session.json' '!/*/folder.json' '!/*/live.json' '!/*/invites' '!/*/rooms/*/room.json' '!/*/rooms/*/summary' '!/*/rooms/*/status' '(?d)/*/*' '// BandSync end' >> "$ROOT/.stignore" && ok "this computer gets each song in full once it's opened (the rest: their listing)"
fi
LABEL="BandSync"; [ "$FOLDER_ID" != bandsync ] && LABEL="StudioSync $BAND_NAME"
if stcli config folders list | grep -qx "$FOLDER_ID"; then ok "$BAND_NAME's shared folder is already set up"
else
  stcli config folders list | grep -q . || stcli config defaults folder path set "$(dirname "$ROOT")" >/dev/null # (fresh setup: new folders land beside it)
  stcli config folders add --id "$FOLDER_ID" --label "$LABEL" --path "$ROOT" >/dev/null && ok "$BAND_NAME's shared folder -> $ROOT"
fi
stcli config folders "$FOLDER_ID" order set smallestFirst >/dev/null
stcli config folders "$FOLDER_ID" fswatcher-delays set 1 >/dev/null  # the default 10 s delay added 10 s to every take
stcli config devices "$MY_ID" name set "$USERNAME_BS" >/dev/null
if ! yes "$HOSTING"; then
  stcli config devices list | grep -qx "$HOST_ID" || stcli config devices add --device-id "$HOST_ID" --name "Collaborator" --introducer --auto-accept-folders >/dev/null
  stcli config folders "$FOLDER_ID" devices list | grep -qx "$HOST_ID" || stcli config folders "$FOLDER_ID" devices add --device-id "$HOST_ID" >/dev/null
  CONNECTED=""
  stcli show connections 2>/dev/null | tr -d '\n ' | grep -q "\"$HOST_ID\":{[^}]*\"connected\":true" && CONNECTED=1
  if [ -n "$CONNECTED" ]; then ok "paired with your collaborator, and connected"
  else ok "paired with your collaborator (they still have to let you in: see the end)"; fi
fi

# ---------- 4. BandSync scripts, inside REAPER ----------
ZREF="heads/main"; [ "$TAG" != main ] && ZREF="tags/$TAG"
curl -fsSL "https://codeload.github.com/$REPO/zip/refs/$ZREF" -o "$WORK/bandsync.zip" && ditto -x -k "$WORK/bandsync.zip" "$WORK/src"
HELPER="$(find "$WORK/src" -path '*/installer/bandsync_setup.lua' | head -1)"
HDIR="$(dirname "$HELPER")"
request() { # mode -> runs the helper in REAPER, leaves its JSON result in $HDIR/bandsync_setup_result.json
  local panel=false; [ "$1" = verify ] && panel=true
  local jsfx=false; yes "$PLUGINS" && jsfx=true
  local root_json; root_json="$(printf '%s' "$ROOT" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')" # (a " or \ in the path broke the JSON)
  printf '{"sync_root":"%s","user":"%s","mode":"%s","repo_url":"https://github.com/%s/raw/main/index.xml","open_panel":%s,"jsfx":%s}' \
    "$root_json" "$USERNAME_BS" "$1" "$REPO" "$panel" "$jsfx" > "$HDIR/bandsync_setup.json"
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
    rm -f "$REQ" # not picked up (an older StudioSync, or a window holding REAPER): asked the other way below
  fi
  if [ -z "$HANDED" ]; then
    if pgrep -x REAPER >/dev/null; then
      say "REAPER is about to run StudioSync's setup step. First close any ReaPack window in REAPER (like its"
      say "'Transaction report'): one left open makes REAPER quit. Then press Return."
      read -r </dev/tty
    fi
    open -a REAPER "$HELPER" # ONE request: the helper waits inside REAPER for ReaPack itself
  fi
  GONE=""
  for i in $(seq 1 360); do
    [ -f "$HDIR/bandsync_setup_result.json" ] && break
    if [ $i -gt 15 ] && ! pgrep -x REAPER >/dev/null; then GONE=1; break; fi
    [ $i -eq 30 ] && say "Waiting for StudioSync to arrive through ReaPack. ReaPack opens its own windows on a first run (Manage repositories, Transaction report): press OK on them."
    sleep 1
  done
  [ -f "$HDIR/bandsync_setup_result.json" ]
}
say "Setting up StudioSync inside REAPER (REAPER opens; on a first start it scans your plug-ins, which can take a while) ..."
say "macOS may ask to let REAPER use the microphone: click Allow, or your takes record silence."
if request "${BS_SCRIPTS:-reapack}"; then
  if grep -q '"ok": *false' "$HDIR/bandsync_setup_result.json"; then warn "REAPER setup step had problems:"; cat "$HDIR/bandsync_setup_result.json"
  else ok "REAPER: name, shared folder and BandSync repository set"; fi
elif [ -n "$GONE" ]; then warn "REAPER closed unexpectedly during setup. Open REAPER (and your project: File > Recent projects), then run this again."; exit 1
else warn "REAPER didn't run the setup step. Open REAPER, then run this again."; exit 1; fi
count="$(grep -o '"registered_actions": *[0-9]*' "$HDIR/bandsync_setup_result.json" | grep -o '[0-9]*$')"
bver="$(grep -o '"version": *"[^"]*"' "$HDIR/bandsync_setup_result.json" | sed 's/.*"\([^"]*\)"$/\1/')"
[ "${count:-0}" -ge 5 ] && ok "StudioSync ${bver:-} installed: $count actions (the StudioSync panel opens in REAPER)" || warn "StudioSync's scripts haven't arrived yet: in REAPER, Extensions > ReaPack > Synchronize packages"

# ---------- 5. what's left for a human ----------
echo
say "Done. What's left (these need you):"
if yes "$HOSTING"; then
  echo "  - To bring in a collaborator: StudioSync panel > Invite a collaborator, and send them what it copies (their installer is"
  echo "    then already paired with you). When they've run it, the panel shows 'Let them in': press it."
  echo "    (Your Syncthing device ID, if they ask for it:  $MY_ID)"
else
  if [ -z "${CONNECTED:-}" ]; then
    echo "  - Tell the collaborator whose ID you used: their StudioSync panel shows 'Let $USERNAME_BS in' (or they add your"
    echo "    Syncthing ID by hand: $MY_ID). The shared folder then arrives by itself."
  fi
fi
if yes "$SOLO" && yes "$HOSTING" && [ -n "${DRIVE_OK:-}" ]; then
  echo "  - Google Drive: share the '$DRIVE_NAME' folder in your My Drive with each collaborator (Editor), at drive.google.com."
elif yes "$SOLO" && [ -z "${DRIVE_OK:-}" ]; then
  echo "  - Google Drive (skipped above): sign in, then at drive.google.com: Shared with me > right-click '$DRIVE_NAME' >"
  echo "    Organize > Add shortcut > My Drive."
fi
if yes "$HOSTING"; then
  echo "  - In REAPER, open your song's project: the StudioSync panel offers 'Share this project with the studio'."
else
  echo "  - In REAPER, the StudioSync panel offers 'Join the studio's project' once your collaborator has let you in: the studio's"
  echo "    songs arrive by themselves, and the panel lists them."
fi
