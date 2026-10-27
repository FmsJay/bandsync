---
name: bandsync-setup
description: Set up BandSync (remote band recording in REAPER) on this computer from zero, or repair/update an existing setup. Installs and configures Syncthing, REAPER, ReaPack, ReaImGui and the BandSync scripts, pairs this machine with the band's host, joins the host's Tailscale share for Live and the band's Google Drive folder for Solo edit, and runs the latency check. Use when someone says "set up BandSync", "join my band's BandSync", "install BandSync", or "BandSync isn't working on this machine".
---

# BandSync setup

You are installing BandSync for a musician who is probably not technical. They are at the keyboard.
Your job is to get them from nothing to "my take landed in the host's project", explaining each
prompt before it appears. Everything here was learned from real first-time installs on Windows 11
and macOS 26 (2026-10-26); the times quoted are from those runs.

## Ground rules

- **Ask before every download, install, or settings change** that affects anything outside BandSync. Say what,
  from where, and why, in one line.
- **Never start a second REAPER.** If REAPER is running, drive the running one (below). A second
  instance can show a "reset configuration" prompt, and on exit it rewrites the shared `reaper.ini`
  and `reaper-kb.ini` from memory. Never use generic "open application" tools on REAPER. If a stray
  instance appears, end its process (Task Manager / `kill`); don't close it normally.
- **REAPER rewrites its ini files on exit.** Never hand-edit `reaper.ini`/`reaper-kb.ini` while it runs;
  change settings through REAPER or through the helper below.
- **Driving REAPER from outside:** run a Lua file in the live instance:
  - Windows: `& "<REAPER dir>\reaper.exe" -nonewinst "<file.lua>"` (PowerShell `Start-Process` works;
    Git Bash may refuse to exec reaper.exe)
  - macOS: `open -a /Applications/REAPER.app "<file.lua>"`

  Scripts run this way must not open dialogs (`GetUserInputs`, `MB`); those block REAPER until a human clicks.
  `gfx.showmenu` pickers only work when the user runs the action from REAPER's Action list. Have scripts
  write results to a file and read that.
- **macOS: don't trigger the Xcode Command Line Tools installer.** On a stock Mac, `python3`, `git`, `make` are
  stubs that pop a CLT dialog. Use `curl`, `grep`, `sed`, `plutil`, `defaults`, `hdiutil`, `ditto`,
  `codesign`, `spctl`, `osascript`, REAPER-hosted Lua, and Syncthing's bundled binary.

## 0. Interview (one message)

Ask: their name as the band should see it; whether they are the **host** (first person in the band,
runs the always-on machine) or **joining**; if joining, the host's **Syncthing device ID** (56
characters, from the host's Syncthing "Show ID"); whether they have a **loopback cable** (output → input)
for the latency check; whether they mind REAPER's **plug-in scan** (see step 2); whether they'll use **Live** (hearing
each other while playing: needs Tailscale, step 4) and **Solo edit** (editing a song while the others are offline:
needs Google Drive, step 5). Both are optional; recording and sending takes needs neither.

## 1. Syncthing (the shared folder)

| OS | Install | CLI |
|---|---|---|
| Windows | `winget install --id Syncthing.Syncthing --exact --silent` (official, MPL-2.0) | `syncthing` (on PATH via winget alias) |
| macOS | official **Syncthing for macOS** .dmg from syncthing.net (signed, notarized; no Homebrew needed) | `/Applications/Syncthing.app/Contents/Resources/syncthing/syncthing cli --home "$HOME/Library/Application Support/Syncthing"` |

Windows: `syncthing generate`, then start `syncthing serve --no-browser` detached. Ask about starting it at login;
it only syncs while running.

**Before pairing, configure defaults, or folders land in the wrong place:**
- `cli config defaults folder path set "<parent of the BandSync folder>"`. It was empty on Windows, which puts the folder in the home dir.
- Pre-create the folder so it gets the right name and case: folder ID **`bandsync`**, label `BandSync`, path
  `<parent>/BandSync`. Auto-accept otherwise creates a lowercase `~/bandsync` on macOS.
- On that folder: `order set smallestFirst` and `fswatcher-delays set 1`. The default 10 s watcher delay added
  10 s to every take.
- Set this device's name to the musician's name.

**Pairing.** Joining: add the host's device ID with `--introducer --auto-accept-folders`, then read this machine's ID
(`syncthing device-id`, or REST `GET /rest/system/status` → `myID`) and give it to the musician to send to
the host. The host adds it and shares `bandsync`. Because the host is an introducer, every other bandmate appears
automatically. Hosting: create the folder, then add each bandmate's ID and share `bandsync` with them.

**macOS prompt:** Syncthing asks for **Local Network** access. It must be **Allow**, or LAN sync silently fails.
The first full sync of the folder took 4–40 s in testing.

## 2. REAPER (7.18 or newer; tested 7.83)

- Windows: installer from reaper.fm (or `winget install Cockos.REAPER`).
- macOS: `reaper<ver>_universal.dmg` from reaper.fm (arm64 + x86_64, notarized). The dmg shows a **license
  agreement**: open it for the user to click Agree (don't pipe `yes`), then copy REAPER.app to /Applications.
  REAPER is a 60-day evaluation; mention the license.
- **First launch scans every plug-in on the machine**: ~16 min and 49 vendor activation popups on a
  plug-in-heavy Mac. Warn first. BandSync needs no plug-ins, so a musician who just wants to record can
  cancel the scan.
- **macOS Microphone prompt** for REAPER: must be **Allow**, or takes record silence. Check a test recording's
  level (AudioAccessor peak) rather than assuming.
- Recording prompt: REAPER on macOS asks "save recorded media?" after every take by default, and nothing
  appears on the timeline until it's answered. Tell them to click **Save All**, or offer to turn it off in
  Preferences > Recording.

## 3. Install the BandSync scripts

**Preferred: ReaPack** (pinned versions, updates via ReaPack, registers new actions automatically):
1. If `reaper.APIExists("ReaPack_AddSetRepository")` is false, install ReaPack from reapack.com
   (the `reaper_reapack-<arch>` file into REAPER's `UserPlugins` folder), then **restart REAPER**.
2. Run the helper (below) with `"mode": "reapack"` and `"repo_url": "https://github.com/FmsJay/bandsync/raw/main/index.xml"`.

**Band-internal alternative: shared folder** (`"mode": "folder"`). This registers the scripts straight from
`<shared folder>/_tools/bandsync`, so edits there reach everyone instantly. The trade-off: anyone who can write to the
folder changes the code everyone runs. Re-run after updates, because new scripts aren't registered by themselves.

### The helper: `installer/bandsync_setup.lua`

Write `bandsync_setup.json` next to it, run it in the live REAPER (see Ground rules), then read
`bandsync_setup_result.json` next to it:

```json
{ "sync_root": "<absolute path to the BandSync folder>", "user": "<name>", "mode": "reapack", "repo_url": "<index.xml URL>" }
```

It checks the REAPER version, checks the folder is writable, stores the name and folder (no typing paths, no `~`
mistakes), installs in the chosen mode, and counts registered BandSync actions. ReaPack's sync is
asynchronous: re-run with `"mode": "verify"` after a minute and expect `registered_actions` ≥ 12.

**Install ReaImGui too.** `"reaimgui": false` in the result means **BandSync - Panel** won't open, and the Live,
Solo edit (versions) and History & restore tabs only exist there. ReaPack's API can't install a package by itself, so
walk them through *Extensions > ReaPack > Browse packages*, search **ReaImGui**, right-click > Install, Apply, then
restart REAPER. Re-run the helper with `"mode": "verify"` and expect `"reaimgui": true`.

## 4. Tailscale (only for Live)

Live audio goes through a NINJAM server on the host's machine, reached over Tailscale so it never faces the internet.
Bandmates don't join the host's tailnet; the host **shares one machine** with them.

| OS | Install | CLI |
|---|---|---|
| Windows | `winget install --id Tailscale.Tailscale --exact` | `"C:\Program Files\Tailscale\tailscale.exe"` |
| macOS | standalone package from tailscale.com/download (or the Mac App Store) | `/Applications/Tailscale.app/Contents/MacOS/Tailscale` |

- **Sign-in is the musician's own click,** with their own account (Google, Apple, Microsoft...). Never create an
  account or sign in for them. macOS asks to **add VPN configurations** (and, for the standalone package, to allow a
  system extension): both must be allowed.
- **Host:** in the admin console (login.tailscale.com/admin/machines), the server machine's **...** menu > **Share**,
  then invite each bandmate by email or send them the link. The host's Tailscale IP (100.x.y.z) is on that page.
- **Bandmate:** open the share link while signed in and accept. Check: `tailscale status` lists the host's machine,
  and `tailscale ping <host IP>` answers. A share is one-way (they reach the host, not the reverse), which is all
  Live needs: everyone connects to the host's server.
- **Hosting Live** (only the host): the server (`tools/ninjam-server/README.md`) must be built and its folder set in
  *Panel > Live*. The server is built for Windows; building it on a Mac needs the Xcode Command Line Tools, so ask
  first (see Ground rules).

Then, in REAPER: **BandSync - Panel > Live**, pick a mode and click **Connect**; ReaNINJAM opens on the master track
with the server and name filled in, and needs one more **Connect** in its own window. macOS: the Microphone
permission from step 2 covers it. If ReaNINJAM can't be added, it is missing from this REAPER install (Windows:
re-run the REAPER installer with the ReaNINJAM component ticked).

## 5. Google Drive (only for Solo edit)

Solo edit keeps each song's one real project in a Google Drive folder, so whoever edits while the others are offline
always starts from the latest version.

- Install **Google Drive for desktop** (Windows: `winget install --id Google.GoogleDrive --exact`; macOS: the dmg
  from google.com/drive/download). Sign-in is the musician's click. macOS asks to allow its File Provider / system
  extension: allow it.
- **Host:** create a folder **BandSync** in *My Drive* and share it with each bandmate as **Editor**.
- **Bandmate:** at drive.google.com, *Shared with me* > right-click **BandSync** > *Organize* > **Add shortcut** >
  *My Drive*. Without the shortcut, Drive for desktop never puts the folder on this computer and Solo edit sees
  nothing. Keep the shortcut's name `BandSync`.
- The folder is then `G:/My Drive/BandSync` (Windows, Drive on G:) or
  `~/Library/CloudStorage/GoogleDrive-<email>/My Drive/BandSync` (macOS); BandSync finds both by itself. Anywhere
  else (another drive letter): *Panel > Solo edit*, type the path, **Use this folder**.
- Check: the folder is visible in Explorer/Finder, and *Panel > Solo edit* shows "Nobody: '<song>' is free to check
  out" for a published song.

## 6. Latency check

With a loopback cable (output 1 → an input), the musician runs **BandSync - Calibrate latency** from the
Action list. It reports "Recordings land N samples LATE/EARLY". For LATE N, add **+N** to
*Preferences > Audio > Recording > Input manual offset* (verified: a ToneX at 44.1 kHz needed +203 samples,
4.6 ms), then run it again until it reads under 1 ms. Re-run after changing interface, sample rate or buffer size.
No cable: skip it, and tell them their takes may land a few ms off until they do it.

**Feedback warning:** a record-armed track with monitoring on and laptop speakers will howl. Use headphones.

## 7. First session (proves it works)

The host runs **BandSync - Publish session** and **BandSync - Live sync**. The joiner runs **BandSync - Open session**
from the Action list (the song picker needs REAPER focused), starts **BandSync - Live sync**, and records 10–20 s on a
track named like one of the host's. The take goes out by itself when they stop, and the host's Live sync places it.
**BandSync - Panel** (or **BandSync - Status**) shows both sides in sync. In testing, takes landed 1–14 s after stopping over Syncthing, with
sample-exact alignment.

If they set up Live: with the host connected, they click **Connect** in *Panel > Live* and should hear the host. If
they set up Solo edit: **BandSync - Solo edit** on a song nobody has checked out, then **BandSync - Check in**; the
others' Solo edit tab shows the new version.

## Updating later

ReaPack installs: **BandSync - Update** (runs ReaPack's sync; new actions get registered). Folder installs: updates
arrive with the shared folder; **BandSync - Update** registers any new scripts that came with it. Every
published song and take records the BandSync version that made it, and opening a newer one tells the user to update.

## Report back

End with a short summary: what was installed (versions), the device ID exchange status, whether the Tailscale share and
the Drive shortcut are in place, the latency result,
and any step the user skipped, plus anything that surprised you, so the next install goes better.
