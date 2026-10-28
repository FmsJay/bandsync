# BandSync

Record together in REAPER from different cities, as if you were working in one project. One person
hosts a song; everyone records locally against the same tempo map with no latency, and every take,
alternate and lane shows up in everyone's project, in the same places. Edits made by whoever is
driving the session (deletes, moves, trims, which take or lane plays) follow everywhere; bandmates can own
their own tracks or song sections, and every handover leaves a recall point you can go back to.

Plain-Lua ReaScripts, no extensions required (SWS helps; see Limits; the control panel needs ReaImGui). REAPER 7.18 or newer; 7.83 is
tested. Machines talk only through a shared folder (Syncthing recommended, or a cloud drive).

## How it works

```
<shared folder>/
  <Song>/
    session.json               tempo map, markers, sample rate, stems, host, print mode, version
    stems/vN/NN.flac + .opus   one folder per publish (open files are never overwritten)
    rooms/<room>/
      takes/    <id>.json + .flac (+ .opus preview, + -dry.flac twin, + .midibuf notes)   every take, as printed
      events/   <person>-<time>.json    deletes, edits, lane/take choices, note edits, track mute/colour
      midi/     note edits that travel with "midi" events
      claims/   <person>.json           the tracks and regions each person owns
      recall/   <time>-<person>-<label>.json   recall points (every handover, or saved by hand)
      status/   <person>.json           what each person's project holds (the Status window)
      _trash/   deleted takes, kept, never destroyed
      driver.json                       who's driving (the host until someone takes control)
```

- **Publish** (host) writes `session.json`: tempo map, markers, stems, and the song's **print mode**.
  The host's existing takes, lanes and alternates are shared too.
- **Open** (bandmate) builds a local project with the same timeline. Stems are copied locally, so the
  project never depends on the shared folder being mounted.
- **Live sync** (everyone, in the background) does the rest:
  - **Starts Syncthing** if the shared folder is a Syncthing folder and Syncthing isn't running (nothing starts
    at login: BandSync starts what a session needs when the session starts).
  - **Sends** every new recording a moment after you stop, every pass of it, active or not, printed at the
    item's exact position and length. Slivers under 0.5 s are skipped, and the same audio is never sent
    twice.
  - **Receives** everyone's takes and rebuilds them exactly: same track, same lane, passes of one item as
    takes of one item. Preview first, then full quality.
  - **Reprints** your takes when their sound changes (an FX added or tweaked, volume, pan, fades), and
    everyone's copy updates in place.
  - **Mirrors whoever may change each take**: deletes, moves, trims, mutes, lane moves, which take or lane
    plays, and track name/mute/solo/colour/icon. What you may not change is locked (view-only) so it can't
    silently drift from the band's version.
  - **MIDI**: a MIDI take's notes travel with its print and land as an editable MIDI copy on a muted
    "<track> (MIDI)" track. Edit those notes and everyone follows (the player's own Live sync reprints it).
  - Never touches the project while you're recording.

Print modes (the host picks per song): **wet** (default) prints each item through its track's FX,
volume and pan; **dry** prints the item alone (take FX, fades, item volume); **both** sends wet with a dry
twin take to switch to. Wet prints land on a BandSync **mirror track** with no FX of yours ("Vox", or
"Vox (band)" next to your own Vox), so nothing is processed twice. Dry prints land on your real track.
When the host shares its takes, the stems arrive muted as a mixed reference.

Rooms: everyone joins `main` by default; type a new room name when opening to try ideas on the same
timeline without cluttering main.

## Setup (each person, once)

**Easiest: the installer.** Download the `installer` folder (or just the one file) and double-click
**Install BandSync (Windows).cmd**, or on a Mac **Install BandSync (Mac).command** (right-click > Open the first
time). It asks your name, whether you're the host (if not, the host's Syncthing device ID), and whether you'll use
Live and Solo edit, then installs whatever is missing from official sources: REAPER, ReaPack, ReaImGui, Syncthing,
and optionally SonoBus + Tailscale and Google Drive for desktop. It sets up the shared folder and pairs it with the
host, installs BandSync through ReaPack and opens the panel. What's left needs you, and it lists it at the end:
signing in to Tailscale and Google Drive, the host adding your device, and the latency cable. (Windows: tested.
macOS: written the same way, not yet run on a Mac.)

**Or let an AI do it.** In Claude Code, on the computer being set up, point it at
`installer/SKILL.md` ("set up BandSync using installer/SKILL.md"). It installs and configures everything below,
explains each prompt before it appears, and asks before every download.

**In the project:** the panel's first screen offers *Publish this project* (host) or *Open a band session*, and the
Session tab's **Set up** list shows what's in place for this project and machine (shared folder syncing, Live sync,
SonoBus, the Live server, the Solo edit folder, latency). **Set up everything I can** does every fix that needs no
human: starts Syncthing and Live sync, adds SonoBus (off), and on the host fills in its Tailscale address as the
Live server and starts the NINJAM server.

By hand:

1. Share one folder between everyone:
   - **Syncthing** (recommended): free, peer-to-peer, a normal local folder. Folder ID `bandsync`, *Pull order*
     *Smallest first*, *Watch for changes* delay 1 s. Files only move while two people are online at the same
     time, so it helps if the host's machine stays on.
   - **Google Drive / Dropbox**: always on, but a virtual drive can mount after REAPER starts.
2. Install the scripts, either way:
   - **ReaPack** (recommended): *Extensions > ReaPack > Import repositories*, paste
     `https://github.com/FmsJay/bandsync/raw/main/index.xml`, then install **BandSync**. Updates come with
     ReaPack's sync, or run **BandSync - Update**.
   - **From the shared folder** (band-internal): *Actions > Show action list > New action > Load ReaScript*,
     and load every `BandSync - *.lua` straight from `<shared folder>/_tools/bandsync`. **BandSync - Update**
     registers any new scripts that arrive later. The trade-off: anyone who can write to the shared folder can
     change everyone's scripts. Only share it with your band.
3. Run **BandSync - Settings**: choose the shared folder and enter your name.
4. **Calibrate recording latency** (important): connect a cable from your interface's output 1 to an
   input and run **BandSync - Calibrate latency**. It plays three clicks, records them back in a temporary
   project, and tells you how many samples early or late your recordings land. Under 1 ms is fine. If it says
   LATE N, add +N to *Preferences > Audio > Recording > Input manual offset* (EARLY: subtract) and run it again.
5. **Install ReaImGui** (*Extensions > ReaPack > Browse packages*): the panel, and with it the Live, Solo edit and
   History tabs, needs it.
6. Optional extras:
   - **Live** needs **Tailscale**. Bandmates don't join the host's tailnet: the host shares the server machine with
     each of them (admin console > the machine's **...** > *Share*), and they accept the link with their own account.
   - **Solo edit** needs **Google Drive for desktop**. The host shares a `BandSync` folder in My Drive (Editor); each
     bandmate adds it to their own Drive with *Shared with me > right-click > Organize > Add shortcut > My Drive*,
     or it never reaches their computer. `G:/My Drive/BandSync` (Windows) and
     `~/Library/CloudStorage/GoogleDrive-<email>/My Drive/BandSync` (macOS) are found by themselves; anything
     else goes in the panel's Solo edit tab.

## Session workflow

**BandSync - Panel** puts all of it in one dockable window, in five tabs: **Session** (Live sync on/off, Hold
sync, bandmates and what they have, who's driving, who owns what, drum maps), **Together**, **Solo edit**,
**Live**, and **History & restore**. The table below uses the separate actions, which still work without the panel.

| Host | Bandmate |
|---|---|
| **BandSync - Publish session**: song name, stems (`none` / `mix` / `grouped` / `tracks`), print (`both` by default, or `wet` / `dry`). Save. | |
| **BandSync - Live sync**: leave it running. | **BandSync - Open session**: pick the song and a room, then **BandSync - Live sync**. |
| You're the driver: delete, move, trim, switch lanes or takes, and everyone follows. | Record on a track named like the host's to land in the same place (any other name makes a new track). Your takes go out by themselves when you stop. |
| Changed the tempo or arrangement? Publish again. | Run **Open session** again to refresh. |

- **BandSync - Status**: a window showing who's online, their BandSync version, how many of the room's takes
  they have, and which of *yours* they're still missing. Green = in sync, yellow = catching up, grey = offline.
- **BandSync - Take control**: become the driver (tell the others first). The driver's edits propagate for
  everything nobody has claimed; everyone else's stay in their own project. Before switching it checks that
  everyone online holds every take and has applied every change (and nobody is holding sync), and offers to
  wait up to 2 minutes for that. Every handover saves a recall point.
- **Ownership** (panel): *Claim selected tracks* makes them yours (only your edits there propagate, whoever
  drives); *Claim region at cursor* does the same for every take that starts in that region; *Claim time
  selection* does it for any stretch you highlight, shown to everyone as a region named `[claimed: you]` (it
  isn't one of the song's markers and never syncs as one). A track claim beats a time claim, which beats a
  region claim, which beats the driver. Each claim has its own x to release it; *Release mine* hands back all.
- **History & restore** (panel tab): every take and every change in the room, newest first, grouped by who made
  them (and who was driving), each group expandable to its individual changes. The driver can restore the
  session to right after any group: later takes are put away, deleted ones come back out of `_trash`, positions
  and what plays go back. Named **recall points** (saved at every handover and with *Save point*) live there
  too. Every restore first saves where things are, so you can flip between versions.
- **Hold sync** (panel checkbox): work without sending anything; on release your net changes go out once.
- **BandSync - Print my MIDI**: put your own instrument on a "<track> (MIDI)" track (a better drum VST,
  say), select its MIDI items and run this. Your render replaces the print everyone hears, and from then on
  your Live sync keeps it current (your FX changes, anyone's note edits).
- **Drum maps** (panel): every drum VST uses its own notes. Set the drum map of your drum track (or its
  "(MIDI)" copy); MIDI drum takes then travel in their player's map and land in yours, and note edits go back
  the same way. Translation goes through named drum sounds (General MIDI plus articulations such as rimshot,
  half-open hat and chokes, which fall back to the nearest GM sound where a kit lacks them). Maps are JSON files
  in `<shared folder>/drummaps` (`{"name": "...", "notes": {"kick": 36, "snare": 38, ...}}`); `gm` is built in.
- **Together** (panel tab):
  - *Side by side*: tick it and use REAPER's own transport. Whoever presses play, stop or record (or jumps
    somewhere while playing), everyone else with it on follows, a set number of bars behind: 1-2 bars with Play
    along, so you hear the one recording in time with the song; 0 with Listen live. The one who records records;
    the others listen. Edits land every half second. It feels like sitting next to each other, with the Play
    along delay.
  - *Who's ready*: whose Live sync is running, what they have armed, and who is side by side.
  - *Play / Record / Stop together*: every machine running Live sync starts from the edit cursor at the same
    moment (5 s after the click, with a count-in, optionally with a click), from the edit cursor or a region,
    with a countdown in the panel. Someone who gets the event late starts where the song has
    got to by then. In Play along, set the listeners' lag to one NINJAM interval.
  - *Notes and likes*: on the selected take (a take marker everyone sees) or at the cursor; click a note to
    jump there. They're in History too.
  - *Live ideas*: what Play along dropped on your timeline. Keep the selected ones, or dismiss someone's.
  - *Take back my last take*: removes your newest take from everyone (it waits in the room's `_trash`).
  - *Print selected MIDI as audio*: renders a synth or drum part through its instrument onto `<track> audio`,
    which goes out as an ordinary audio take.
  - *Copy mix from Solo edit*: your faders, pans and mutes become those of the latest Solo edit version.
  - *Insert / Remove bars* (driver): moves every take, tempo marker and marker after the cursor, on every
    machine. Takes that play across the edit point are split there by whoever recorded them, on their own
    machine (it asks first), so both parts stay theirs. "(MIDI)" copies aren't split.
  - *Dry mode*: plays a bandmate's dry recording through *their* plug-in chain (it travels with each print).
    Plug-ins you have load; the rest stay in the chain as missing, with their settings kept. The panel shows
    how many of them you have before you tick it. Untick to go back to the print.
- **Shared mix**: volume and pan travel like mute and solo (the driver's, or a track owner's). Prints are made
  at unity, so nobody's fader is baked in twice.
- **Locked edits snap back**: moving or trimming a take that isn't yours to change puts it back, with a note
  in the console. Your own takes you may always move, trim, mute or delete, unless someone has claimed that
  track or region.
- **Start Live sync with REAPER** (panel checkbox): Live sync comes back by itself for any session where it
  was running when REAPER closed, until you stop it.
- **Empty old trash** (panel, More): removes trashed takes and revisions older than 30 days.
- **BandSync - Send takes / Send all takes**: send by hand (resend a selected item's active take, or every
  unsent pass). Live sync normally makes these unnecessary.
- **BandSync - Settings** also sets how takes land in this project: `mirror` (default: as the sender has them),
  `lanes`, `takes`, `person` (a `Takes - <name>` track) or `inbox` (one muted track to review first).

### Solo edit: one person at a time, through Google Drive

For working on a song while the others are offline, without different versions piling up on different
machines. The song's real REAPER project lives in a cloud folder (the panel's Solo edit tab; Google Drive
`G:/My Drive/BandSync` by default).

- **BandSync - Solo edit** checks the song out: it takes the song's lock, copies the current version to this
  machine (`Documents/BandSync/<song>`; REAPER never edits files on the cloud drive) and opens it. Everyone's
  panel shows who has it, since when and when they were last seen. Nobody else can check it out meanwhile; they
  can open the latest version to look. A lock whose owner disappeared (no heartbeat for 5 minutes) can be taken over.
- **BandSync - Check in** publishes your changes with an optional note, keeps the previous version, and hands the
  song back (or keeps it checked out). New media is copied into the project folder, so the folder is always the
  whole project.
- **Versions** (Solo edit tab): every check-in, newest first, expandable to what changed on each track (items
  added, removed, moved; FX changed; tracks added, removed, renamed). Restore any of them while you have the song
  checked out; what you had is checked in first.
- **Wet and dry are both kept.** At check-in every item on a track with FX gets a wet print as an extra take next
  to its dry recording. Whoever lacks one of the track's plugins hears the prints (that track's FX are bypassed
  while they edit); the dry recording stays underneath, edits move both, and the published version is always
  dry + FX for whoever has the plugins. The same goes for live sessions: they now print `both` by default.

### Live: hear each other while it happens

The **Live** tab has three modes:

- **Play along (synced)**, the default: your audio is stamped with its song position; listeners start playback
  a bar or two after you and hear you in time with the song, at any distance. What you play also lands on their
  timeline as a placeholder on a "<name> (live)" track, replaced automatically when your real take arrives.
  Uses REAPER's own ReaNINJAM and a NINJAM server the host runs (`tools/ninjam-server/README.md`), over Tailscale.
- **Listen live**: hear each other as it happens, through **SonoBus** (free, GPLv3, sonobus.net): peer to peer,
  far lower delay than NINJAM, and nobody runs a server, so it works the same on Windows and Mac. Playing *together*
  in time this way needs low delay (wired internet, roughly the same region). **Connect** turns on SonoBus on your
  master track (it sends your mix and plays the band into it), already in the band's group under your BandSync name:
  one click, nothing to type or paste, even the first time (BandSync writes the group into SonoBus's saved state;
  `lib/sonobus.lua`). **Leave** turns it off (it stays on the master track, sending nothing). The band has one group
  and password, kept in `<shared folder>/sonobus.json`; *Copy join link* is there for joining from SonoBus's own
  app. SonoBus's public connection server only introduces peers; the audio goes directly between you, unencrypted.
- **Jam**: classic NINJAM, everyone one interval late.

The host enters `<Tailscale IP>:2049` and clicks *Save for the band*; everyone else clicks **Connect**, which adds
ReaNINJAM to their master track with everything filled in (one more Connect click in its window).
The host also sets the server folder (the one with `ninjamsrv` and `bandsync.cfg`) once; the host's Connect starts
the server if it isn't running.

Stems modes: `none` sends only the timeline, `mix` one master bounce, `grouped` one stem per top-level track
or folder, `tracks` every non-folder track.

## Backups

Syncthing is a mirror, not a backup: a delete or an overwrite on one machine reaches every machine. Two
layers fix that, best set up on the host's always-on machine:

- **Syncthing versioning** on the `bandsync` folder (*Edit folder > File Versioning > Staggered*, 30 days):
  keeps old copies of files that another machine changed or deleted, in the folder's hidden `.stversions`.
- **A nightly one-way copy to a cloud drive:** `tools/backup_to_drive.ps1` copies the shared folder and your
  local BandSync projects into `G:\My Drive\BandSync backup` (paths are parameters). It adds and updates files
  and never deletes from the backup. Schedule it with Task Scheduler (daily, "run as soon as possible after a
  missed start", as your user so the cloud drive is mounted). Never sync the same folder with both Syncthing
  and the cloud drive.

## Limits

- Wet prints include the item's own track FX and 2 s of reverb/delay tail past the item's end; not parent
  folders or sends. Volume and pan travel as the shared mix instead.
- Dry mode replaces whatever plug-ins you had put on that band track; unticking leaves it empty.
- Time-selection claims are kept in seconds: Insert/Remove bars doesn't move them (re-claim after one).
- Pitch, playrate or FX you put on someone else's take stay on your machine (your monitoring), and aren't sent.
- The shared folder trusts its members: an event says who made it, and nothing checks that beyond the folder's
  own sharing. Share it only with your band. The events folder grows with the session (never pruned yet).
- Deleting one take out of a multi-take item happens when that project's tab is in front (REAPER/SWS only
  allow it there); whole items are deleted any time.
- REAPER's lanes play one lane or all of them, so "which lane plays" mirrors as exactly that.
- Refreshing replaces a bandmate's markers and tempo map with the host's. A take recorded before the host
  changed the tempo stays at its original time, not on the bar.
- MIDI copies assume everyone has the same tempo map (they do, from the publish). Looped MIDI items print
  fine but their copy isn't looped.
- Live: ReaNINJAM reads its settings when it first opens in a REAPER session; after changing mode or server,
  restart REAPER, or switch the channel's mode in ReaNINJAM's own window. Play along (and Side by side with it)
  needs the sender's channel in Session mode: in Normal mode the others hear you on NINJAM's interval grid
  instead of in time with the song (measured 0.94 s off). The panel says when it isn't. Synced mode needs the listener to play from a point behind the sender.
- Live placeholders appear when the listener disconnects (or after a long session): ReaNINJAM buffers its clip
  log and only writes it to disk then. Hearing the audio live isn't affected.
- Listen live: REAPER only sees a newly installed SonoBus after a restart. Setting SonoBus up relies on its saved
  state's layout (checked against SonoBus 1.7.2); if a later SonoBus changes it, BandSync says so and you join with
  SonoBus's own Connect button. If your name is already in the group (say, a second project of yours is
  connected), SonoBus adds a number to it.
- Solo edit restores bring back arrangement and settings; media is only ever added to the shared folder, never
  deleted, so old versions always find their files.
- History restores (live mode) put back arrangement and what plays; note edits and reprints stay current.
