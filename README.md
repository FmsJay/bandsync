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

**Easiest: let an AI do it.** In Claude Code, on the computer being set up, point it at
`installer/SKILL.md` ("set up BandSync using installer/SKILL.md"). It installs and configures everything below,
explains each prompt before it appears, and asks before every download.

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

## Session workflow

**BandSync - Panel** puts all of it in one dockable window, in four tabs: **Session** (Live sync on/off, Hold
sync, bandmates and what they have, who's driving, who owns what, drum maps), **Solo edit**, **Live**, and
**History & restore**. The table below uses the separate actions, which still work without the panel.

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
  drives); *Claim region at cursor* does the same for every take that starts in that region. A track claim
  beats a region claim, which beats the driver. *Release mine* hands them back.
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

The **Live** tab uses REAPER's own ReaNINJAM and a NINJAM server the host runs (see
`tools/ninjam-server/README.md`), reached over Tailscale. Three modes:

- **Play along (synced)**, the default: your audio is stamped with its song position; listeners start playback
  a bar or two after you and hear you in time with the song. What you play also lands on their timeline as a
  placeholder on a "<name> (live)" track, replaced automatically when your real take arrives.
- **Listen live**: plain live audio, as fast as the network allows.
- **Jam**: classic NINJAM, everyone one interval late.

The host enters `<Tailscale IP>:2049` and clicks *Save for the band*; everyone else clicks **Connect**, which adds
ReaNINJAM to their master track with everything filled in (one more Connect click in its window).

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

- Wet prints include the item's own track (FX, volume, pan), not parent folders, sends or reverb tails past
  the item's end.
- Deleting one take out of a multi-take item happens when that project's tab is in front (REAPER/SWS only
  allow it there); whole items are deleted any time.
- REAPER's lanes play one lane or all of them, so "which lane plays" mirrors as exactly that.
- Refreshing replaces a bandmate's markers and tempo map with the host's. A take recorded before the host
  changed the tempo stays at its original time, not on the bar.
- MIDI copies assume everyone has the same tempo map (they do, from the publish). Looped MIDI items print
  fine but their copy isn't looped.
- Live: ReaNINJAM reads its settings when it first opens in a REAPER session; after changing mode or server,
  restart REAPER. Synced mode needs the listener to play from a point behind the sender.
- Solo edit restores bring back arrangement and settings; media is only ever added to the shared folder, never
  deleted, so old versions always find their files.
- History restores (live mode) put back arrangement and what plays; note edits and reprints stay current.
