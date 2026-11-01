# Bands and per-song sync (per-song sync built in 0.34.7, bands in 0.35.0)

James, 2026-10-31: "having separate 'sessions' or 'bands' within bandsync instead of sharing every project with
everyone", and "only get a song at a time based on what's being worked on ... otherwise that'll be a lot to sync
especially on a first run". Both change the shared folder's layout, so they're designed together.

## Today

One Syncthing folder (id `bandsync`) holds everything: every song, `_band/names.json`, `plugins/`, `drummaps/`,
`sonobus.json`. Every machine that's let in gets all of it. The Google Drive copy is one `BandSync` folder in My Drive.

## Bands

A band is its own shared folder, nothing more. Everything band-wide moves with it.

- **Syncthing:** one folder per band, id `bandsync-<band>`, at `<BandSync folder>/<Band name>`. Letting someone in
  shares only that band's folder with them, so another band never sees it. The existing `bandsync` folder becomes
  the first band, with its id kept, so nobody re-syncs anything.
- **Per band:** songs, `_band/names.json`, `plugins/` (what everyone in *this* band has), drum maps, the SonoBus
  group, the Drive copy.
- **Per machine (unchanged):** your name, audio settings, latency, MIDI plays as.
- **Google Drive:** one Drive folder per band, `BandSync - <Band>`, shared with that band only (Drive shares whole
  folders, so bands can't nest inside one shared folder). The existing `BandSync` folder stays as the first band's.
- **Panel:** the start screen and Setup show the band you're in, with a switch when you're in more than one. Each song
  tab remembers its band, so two bands' songs can be open at once.
- **Invite a bandmate** invites to the current band: the line carries the band's folder id as well as your
  Syncthing ID, and the installer joins that band.
- **New band:** Setup > Bands > "Start a band" makes the folder (and its Drive folder), and you invite people to it.

## Per-song sync

Syncthing's ignore file (`.stignore`, kept on each machine, never shared) decides what a machine downloads. BandSync
writes it:

- **Always:** `_band/`, `plugins/`, `drummaps/`, and from every song only what the song list needs:
  `session.json`, `folder.json`, each room's `summary/` (tracks, plug-ins, size: the chooser's preview) and
  `status/` (who's in it). A few KB a song.
- **Per song, once you open it:** the rest of that song (events, takes, media). Opening a song adds it; the chooser
  shows how much will download, and the tab opens straight away with grey "arriving" stand-ins as it does now.
- **Keep or free up:** songs you've opened stay. Setup > Songs lists them with their size and a "Free up space"
  button (stops syncing that song here and removes its files from this computer only).
- **The machine that stays on** (the host) can choose "keep every song", so new members always have a source.

Limits to know:
- A song arrives from a bandmate who has it and is online, and from the Drive copy (every machine keeps its own part
  of every song it has in full there, so a song opens even when nobody who has it is online).
- Syncthing rescans after an ignore change; the first pull of a big song takes as long as its audio does.

## Order of work

1. Per-song sync on the current single band (smaller, and helps first installs most).
2. Bands: folder per band, band switch, invite carries the band, Drive per band.
3. Installer: joins the invited band; asks for a band name when you're the first.

## Open questions for James

- Answered (James, 2026-10-31): the first band is **Chilio**; a new member gets only the song list.
