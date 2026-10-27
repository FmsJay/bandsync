# BandSync

Remote band collaboration for REAPER, phase 1. One person hosts a song; everyone else records
locally against the host's tempo map and stems, with no latency, and their takes land in the
host's project automatically, in lanes on the matching track.

Five ReaScripts, plain Lua, no extensions required. They need REAPER 7.0 or newer; 7.83 is tested.
They talk only through a shared folder (Syncthing or a cloud drive).

## How it works

```
<shared folder>/
  <Song>/
    session.json             tempo map, markers, sample rate, stems list, host, version
    stems/vN/NN.flac + .opus one folder per publish (open files are never overwritten); .opus syncs first
    rooms/<room>/takes/      <id>.json manifest + <id>.opus preview + <id>.flac full take
```

- **Publish** (host) writes `session.json` and renders stems. Whoever publishes is the host.
- **Open** (guest) builds a local project with the same sample rate, tempo map, markers and
  stems, saved to a local folder (`<REAPER resource path>/BandSync/<Song>/`). Running it again
  refreshes the project from the latest publish.
- **Send** renders each take dry (no track FX) to a 24-bit FLAC and a ~128 kbps Opus preview,
  stamped with its timeline position, and writes them to the room's `takes/` folder.
- **Inbox** (background) places takes at their stamped position, so network delay never affects
  alignment. It uses the preview first and swaps in the FLAC when it arrives. It never edits the
  project while it is recording.

Rooms: everyone joins `main` by default. Type a new room name when opening to try ideas on the
same timeline without cluttering main. The host receives every room; each room's lanes are named
`room · person · time`. Promote a take by clicking its lane's play button.

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
     and load every `BandSync - *.lua` straight from `<shared folder>/_tools/bandsync`. Edits there reach
     everyone instantly, but new scripts must be loaded once by hand. The trade-off: anyone who can write to the
     shared folder can change everyone's scripts. Only share it with your band.
3. Run **BandSync - Settings**: choose the shared folder and enter your name.
4. **Calibrate recording latency** (important): connect a
   cable from your interface's output 1 to an input, and run it. It plays three clicks, records them
   back in a temporary project, and tells you how many ms early or late your recordings land. Under
   1 ms is fine. Otherwise adjust the latency compensation offset in *Preferences > Audio > Recording*
   and run it again. Without this, every take you send can land a few ms off.

## Session workflow

| Host | Guest |
|---|---|
| **BandSync - Publish session**: song name and stems mode (`none` / `mix` / `grouped` / `tracks`). Save. | |
| **BandSync - Take inbox**: leave running. | **BandSync - Open session**: pick the song and a room. |
| | Record on a track named like the host's (e.g. `Bass`) to land in that track's lanes; any other name becomes a new track on the host. |
| Takes appear as lanes. Preview first, then full quality. To send a part of your own to guests, select it first: in a host project, every item counts as unsent. | **BandSync - Send takes**: everything not sent yet, or just the selection. It asks when a selection would leave other new takes behind. |
| Changed the tempo or arrangement? Publish again. | Run **Open session** again to refresh. **Take inbox** on a guest receives bandmates' takes from the same room on `Takes - <name>` tracks and upgrades preview stems to FLAC. |

Stems modes: `none` sends only the timeline (for when you're streaming audio instead, e.g. with
SonoBus), `mix` sends one master bounce (use your own metronome for the click), `grouped` sends one
stem per top-level track or folder, `tracks` sends every non-folder track.

**BandSync - Settings** also sets where takes land in the current project: `lanes` (host default),
`person` (a `Takes - <name>` track; guest default) or `inbox` (one muted `BandSync inbox` track
to review first).

## Limits (phase 1)

- Refreshing replaces the guest's markers and tempo map with the host's.
- A take recorded before the host changed the tempo stays at its original time, not on the bar.
  Send warns about this.
- `tracks` mode skips folder tracks' own FX.
- Live listening is not part of this phase. Use SonoBus on the performer's master bus to stream
  their monitor mix.
