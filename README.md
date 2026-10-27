# BandSync

Record together in REAPER from different cities, as if you were working in one project. One person
hosts a song; everyone records locally against the same tempo map with no latency, and every take,
alternate and lane shows up in everyone's project, in the same places. Edits made by whoever is
driving the session (deletes, moves, trims, which take or lane plays) follow everywhere.

Plain-Lua ReaScripts, no extensions required (SWS helps; see Limits). REAPER 7.18 or newer; 7.83 is
tested. Machines talk only through a shared folder (Syncthing recommended, or a cloud drive).

## How it works

```
<shared folder>/
  <Song>/
    session.json               tempo map, markers, sample rate, stems, host, print mode, version
    stems/vN/NN.flac + .opus   one folder per publish (open files are never overwritten)
    rooms/<room>/
      takes/    <id>.json + .flac (+ .opus preview, + -dry.flac twin)   every take, as printed
      events/   <person>-<time>.json    the driver's deletes, edits and lane/take choices
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
  - **Mirrors the driver**: their deletes, moves, trims, lane moves and which take or lane plays.
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

| Host | Bandmate |
|---|---|
| **BandSync - Publish session**: song name, stems (`none` / `mix` / `grouped` / `tracks`), print (`wet` / `dry` / `both`). Save. | |
| **BandSync - Live sync**: leave it running. | **BandSync - Open session**: pick the song and a room, then **BandSync - Live sync**. |
| You're the driver: delete, move, trim, switch lanes or takes, and everyone follows. | Record on a track named like the host's to land in the same place (any other name makes a new track). Your takes go out by themselves when you stop. |
| Changed the tempo or arrangement? Publish again. | Run **Open session** again to refresh. |

- **BandSync - Status**: a window showing who's online, their BandSync version, how many of the room's takes
  they have, and which of *yours* they're still missing. Green = in sync, yellow = catching up, grey = offline.
- **BandSync - Take control**: become the driver (tell the others first). Only the driver's edits propagate;
  everyone else's stay in their own project.
- **BandSync - Send takes / Send all takes**: send by hand (resend a selected item's active take, or every
  unsent pass). Live sync normally makes these unnecessary.
- **BandSync - Settings** also sets how takes land in this project: `mirror` (default: as the sender has them),
  `lanes`, `takes`, `person` (a `Takes - <name>` track) or `inbox` (one muted track to review first).

Stems modes: `none` sends only the timeline, `mix` one master bounce, `grouped` one stem per top-level track
or folder, `tracks` every non-folder track.

## Limits

- Wet prints include the item's own track (FX, volume, pan), not parent folders, sends or reverb tails past
  the item's end.
- Deleting one take out of a multi-take item happens when that project's tab is in front (REAPER/SWS only
  allow it there); whole items are deleted any time.
- REAPER's lanes play one lane or all of them, so "which lane plays" mirrors as exactly that.
- Refreshing replaces a bandmate's markers and tempo map with the host's. A take recorded before the host
  changed the tempo stays at its original time, not on the bar.
- Live listening while someone records isn't part of this yet: use SonoBus on the performer's master bus.
