# BandSync

Record and arrange together in REAPER from different cities, as if you were all working in one project.
Everyone in a room holds the same project: every track, item, lane, MIDI part and plug-in chain, kept
identical by mirror sync. One person drives (their changes go to everyone); bandmates claim the tracks or
song sections they work on, and Restore can take back any change, any track, or the whole song.

Plain-Lua ReaScripts (the control panel needs ReaImGui; SWS helps). REAPER 7.18 or newer; 7.83 is tested.
Machines talk only through a shared folder (Syncthing recommended), with an optional Google Drive copy.

## How it works

```
<shared folder>/
  <Song>/
    session.json               tempo map, markers, sample rate, host
    rooms/<room>/
      events/   <person>-<time>.json    every change: a track, an item or a plug-in chain, as REAPER describes it
      media/    recordings and MIDI prints the items use (copied in once)
      claims/   <person>.json           the tracks and regions each person owns
      recall/   recall points (every handover, or saved by hand)
      status/   <person>.json           who's here, what they're doing (the panel's Who's here)
      chat/     messages, to-dos, links for the room (the song's and the band's sit beside it)
      driver.json, mode.json            who drives; Driver only / Claims / Open
```

- **Publish** (host) makes the song a band session. The project must be prepared first (a checklist); an
  untitled project is saved under the song's name, and a copy as it was before BandSync is kept (Restore offers
  it back). A song name another bandmate already uses is refused.
- **Open session** (bandmate) opens the song straight into its main room, in a new tab; Live sync fills it.
- **Live sync** (everyone, always, whenever a BandSync project is open) does the rest. See `docs/mirror-design.md`.
  - Every track and item has a permanent id (never its name), so unnamed and renamed tracks are fine.
  - What you change goes out a moment after you change it (after the drop, when dragging): items (position,
    fades, mute, lane, MIDI notes, copies, new items), tracks (name, lanes and which lanes play, folders,
    mute/solo, fader and pan) and plug-in chains (only while stopped: replacing a chain reloads the plug-ins).
  - What the band changes comes in, the newest version of each object winning on every machine alike.
  - A change you may not make (the driver's, or someone's claim) is put back, Ctrl+drag copies included, with the
    reason in the panel's banner (or a tooltip by the mouse when the panel is closed).
  - Never touches a track while you record on it.
- **MIDI** travels as notes. Whoever changes a MIDI part also renders a print (its sound, through their
  instrument), kept as the item's second take. Each person picks how MIDI plays on their machine (Setup >
  Options): **Auto** (your instruments when the track's plug-ins all load, else the print), **Notes** or
  **Sound**. That choice never changes what anyone else hears.
- **Local mixing** (Home): your faders and pan stay yours. Switching it off asks whether to take the band's
  mix or send yours.
- Songs published with BandSync before 0.30 are left alone: publish them again to sync them.

## Setup (each person, once)

**Easiest: the installer.** Download the `installer` folder (or just the one file) and double-click
**Install BandSync (Windows).cmd**, or on a Mac **Install BandSync (Mac).command** (right-click > Open the first
time). It asks your name, whether you're the host (if not, the host's Syncthing device ID), and whether you'll use
Live and the Google Drive copy, then installs whatever is missing from official sources: REAPER, ReaPack, ReaImGui, Syncthing,
and optionally SonoBus + Tailscale and Google Drive for desktop. It sets up the shared folder and pairs it with the
host, installs BandSync through ReaPack and opens the panel. What's left needs you, and it lists it at the end:
signing in to Tailscale and Google Drive, the host adding your device, and the latency cable. (Windows: tested.
macOS: written the same way, not yet run on a Mac.)

**Or let an AI do it.** In Claude Code, on the computer being set up, point it at
`installer/SKILL.md` ("set up BandSync using installer/SKILL.md"). It installs and configures everything below,
explains each prompt before it appears, and asks before every download.

**In the project:** the panel's first screen offers *Publish this project* (host) or *Open a band session*, and the
Setup page's **Health** list shows what's in place for this project and machine (shared folder syncing,
Live sync, SonoBus, the Live server, latency). **Set up everything I can** does every fix that needs no
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
5. **Install ReaImGui** (*Extensions > ReaPack > Browse packages*): the panel, and with it the Live and
   Restore pages, needs it.
6. Optional extras:
   - **Live** needs **Tailscale**. Bandmates don't join the host's tailnet: the host shares the server machine with
     each of them (admin console > the machine's **...** > *Share*), and they accept the link with their own account.
   - **The Google Drive copy** (optional, recommended) needs **Google Drive for desktop**, each person signed in
     with their **own** Google account (two computers on one account lose files: "Lost and Found"). The host makes a
     `BandSync` folder in My Drive and shares it with everyone as Editor; each bandmate adds it to their own Drive
     with *Shared with me > right-click > Organize > Add shortcut > My Drive*, keeping the name `BandSync`, or it
     never reaches their computer. BandSync finds it in any My Drive on the machine (any drive letter, the Windows
     user folder, every macOS account) and never makes one itself; Settings says when the shortcut is
     missing. Anything else goes in the `drive_root` setting (ExtState), and Settings
     *Keep the band's copy on Google Drive* turns it off on one machine.

## Session workflow

**BandSync - Panel** puts everything in one window. It opens by itself whenever a BandSync project opens.

- **Top bar**: `Project: <song>`, the room, **Sync on** (green: Live sync is running; red **Sync off**: press Start),
  who drives, **Undo** / **Redo** (your own changes, for everyone; each asks first, and says if a bandmate changed the
  same thing since), **Dock** and, floating, **Full screen** and **Window** (half the screen, the next screen, back).
  Under the bar, what BandSync just did shows for a few seconds.
- **Pages**: **Home** (Who's here with *Take control*, Real time mode, who changes what, Local mixing, claims),
  **Rooms**, **Play** (play/record together, follow each other, how you hear each other), **Chat**, **Restore**,
  **Plugins** and **Setup** (Health, Console, Options, Updates). A red or yellow dot on Setup means Health has
  something (red: the band can't sync until it's fixed).
- **Docking**: click *Dock* for Bottom / Left / Right (REAPER's docker on that side; if there isn't one, BandSync
  says how to set it once). Right-click *Dock* to arm drag-to-dock (it turns green); otherwise dragging the
  window only docks while you hold Shift, so moving it never docks it by accident. Docked short and wide, each
  page lays out in columns.
- **The pill**: closing the panel leaves a small button over REAPER (Live, who drives, new chat). Click it to
  bring the panel back where it was; right-click to close BandSync's panel or remove the button (Setup > Options
  brings it back).
- The floating window resizes from every edge and corner. Every control explains itself on hover.

**BandSync - Radial menu** pops a ring of everyday moves around the mouse. Give it a key or mouse button in the
Actions list. The slices are Undo, Redo, Restore project…, Restore selection…, Undo one change… (each of these three
opens Restore set to that kind of going back), Take control (greyed while you drive), Real time mode on/off, and
Chat. Point at a slice to read what it does underneath, and click it to do it. Esc, a click anywhere else, or the key
again closes the menu. The panel carries the move out, so each choice asks first just as its button there does, and
the panel opens if it was closed.

Who may change what:

- **Driver**: their changes reach everyone, except on what someone has claimed. *Take control* (next to Who's
  here) makes you the driver; it checks everyone has caught up first, and every handover saves a recall point.
- **Editing modes** (Home; the driver picks): **Driver only**, **Claims** (default: the driver, and everyone on
  what they've claimed, plus the new tracks they make themselves) or **Open** (anyone changes anything unclaimed;
  the newest change wins; the tempo map stays the driver's).
- **Claims**: *Claim selected tracks*, *Claim region at cursor* or *Claim time selection* (shown to everyone as a
  `[claimed: you]` region). A track claim beats a time claim, which beats a region claim, which beats the driver.
- **What you see is what the band has**: anything you change that isn't yours to change is put back at once,
  with the reason. Recording on a track you may change always goes out. **Hold my changes** keeps your changes
  here until you switch it off; then they go out together.

Restore (its own page):

- Every change in the room, newest first, grouped by who made it; filters by person, kind (items, tracks,
  plug-ins, deletes, things brought back, tempo, handovers...), track or words.
- Pick what the buttons do: **Restore project state** (the whole song back to that moment; driver only),
  **Restore selection's state** (only the tracks selected in REAPER, their items and plug-ins) or **Undo specific
  change** (only that one change). Every restore goes to the band as new changes, so it can be undone the same
  way.
- **Recall points** (every handover, or *Save point*), and *Open it as it was before BandSync* (the copy Publish
  kept).

Chat (its own page): **This room**, **This song** or **Band**, each with **Messages**, **To-do** (anyone ticks
them off) and **Links** (lyrics, charts, documents). Each message is its own small file, so nothing ever clashes.

Plugins (its own page): every plug-in the project uses, on which tracks, and who in the band doesn't have it. Set a
**translation** for one (something the band has that's close enough); *Apply translations here* adds it right after
the original on a machine that's missing it. Translations are that machine's own: they never go to the band, and
the original stays for everyone who has it.

Recording and MIDI: record as usual. A new recording goes out a moment after you stop (the file is copied into
the room's media folder once). MIDI travels as notes with a print beside it (see How it works).

- **BandSync - Prepare session** (Setup > Updates, or the first screen): for a busy project, a checklist of what it
  needs for BandSync (takes into fixed lanes, 24-bit FLAC at one sample rate, unnamed or duplicate track names,
  files from outside the project, ripple editing off...), applied after a backup copy as one undo. Publish asks for
  it first.
- **Drum maps** (Setup > Options): rewrite a drum track's MIDI into another drum VST's notes (named drum sounds,
  General MIDI plus articulations). Maps are JSON files in `<shared folder>/drummaps`.

### Working alone, and the Google Drive copy

- **Alone = full control.** While nobody else is in the room, everything you change goes out (the band gets it when
  they're back), whatever the claims.
- **Both changed something while apart**: the newer change wins on every machine alike. If yours was replaced, BandSync
  says so: yours is still on the Restore page (*Undo specific change* on theirs brings it back).
- **The Google Drive copy** (Setup > Options): Syncthing only moves files while two machines are on at the same time.
  Live sync also keeps a copy of the room on Google Drive (store and forward), so what someone does alone reaches the
  others even if you're never online together.

### Real time mode

Home's **Real time mode** switch: you hear each other as you play (SonoBus, peer to peer), and play, stop and record
follow whoever presses them. SonoBus sits on its own **BandSync Real time** track, fed only by your **armed** tracks:
everyone already plays the song from their own copy, so only what you're playing live goes out (no doubled backing).
*Configure SonoBus* opens its own window (volume and mute per bandmate, buffer), which you don't need to play
together.

### Rooms: side rooms, and bringing work back

- **Create side room**: a copy of the room you're in, as it is now, in a new tab, to try things without changing the
  room. Squares show each room and who's in it; **Go there** to join one; **Come see** asks everyone over.
- **Send selected to main**: the selected items (and any track of theirs main hasn't got) go to main as they are
  here.
- **Bring into main**: everything this room changed since it was made goes to main, except what main has also
  changed since (listed as clashes; main keeps its own). Only main's driver brings a room in. Brought changes are
  ordinary changes in main, so Restore there can undo them.

### Plug-ins everyone has

Each machine sends the band the names of the plug-ins it has (`<shared folder>/plugins/<you>.json`) when Live sync
starts. What every bandmate has goes in a folder of REAPER's FX browser, **BandSync (everyone has)** (VST3 first when
a plug-in comes in several formats, since Windows and Mac both have VST3). Use those and the song sounds the same on
every machine. The **Plugins** page updates it on demand. REAPER's own effects (ReaPlugs and the
JSFX) are on every machine; JSFX from ReaPack work on Windows and Mac alike, once everyone installs the same package.

**The band plug-in pack** (the installers ask; free, each from its official release, nothing bundled, about 150 MB
on Windows and 350 MB on a Mac): Surge XT (synth + effects, GPL-3), Dexed (FM synth, GPL-3), Airwindows Consolidated
(MIT), Dragonfly Reverb (GPL-3), Chow Tape Model (GPL-3), BYOD (guitar and bass amps, tuner; GPL-3), ZL Equalizer 2
and ZL Compressor (AGPL-3), ChowMatrix (delay, BSD-3), and through ReaPack the JSFX of Saike and Chokehold (MIT) and
chmaha's *DSP to JSFX* (the effects and instruments REAPER 7.83 bundled and 7.84 removed: drum kits, piano and
e-piano, organ, channel strip...; GPL-3 with MIT/AGPL parts).

**Extras** (a second question, about 820 MB on Windows, 880 MB on a Mac, most of it the piano): Neural Amp Modeler
0.7.13 and AIDA-X (amp capture players), Odin 2 (synth), and the Salamander Grand piano (SFZ) with sforzando to play
it. Worth adding by hand (free, but they need an account or can't be passed on): Vital, Valhalla Supermassive,
Spitfire LABS, MeldaProduction MFreeFXBundle.

### Live: hear each other while it happens

The **Play** page has three ways to hear each other:

- **Play along (synced)**, the default: your audio is stamped with its song position; listeners start playback
  a bar or two after you and hear you in time with the song, at any distance. What you play also lands on their
  timeline as a placeholder on a "<name> (live)" track, replaced automatically when your real take arrives.
  Uses REAPER's own ReaNINJAM and a NINJAM server the host runs (`tools/ninjam-server/README.md`), over Tailscale.
- **Listen live** (Home's **Real time mode**): hear each other as it happens, through **SonoBus** (free, GPLv3,
  sonobus.net): peer to peer, far lower delay than NINJAM, nobody runs a server. It sits on the **BandSync Real time**
  track, fed only by your armed tracks, already in the band's group under your BandSync name (BandSync writes the group
  into SonoBus's saved state; `lib/sonobus.lua`). The band's group and password are in `<shared folder>/sonobus.json`;
  SonoBus's public server only introduces peers, and the audio goes directly between you, unencrypted.
- **Jam**: classic NINJAM, everyone one interval late.

The host enters `<Tailscale IP>:2049` and clicks *Save for the band*; everyone else clicks **Connect**, which adds
ReaNINJAM to their master track with everything filled in (one more Connect click in its window).
The host also sets the server folder (the one with `ninjamsrv` and `bandsync.cfg`) once; the host's Connect starts
the server if it isn't running.

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

Closing REAPER without saving (or a crash) is safe. Next to each BandSync project sits
`<project>.bandsync-ids.json`, this machine's record of which track and item is which. When you reopen an older
save, BandSync recognises its tracks and items, brings back what changed since as the band has it, and sends
nothing new. Leave the file where it is. Without it, a reopened older save would show up for everyone with its
tracks twice.

## Limits

- Plug-in chains change only while the transport is stopped (replacing a chain reloads its plug-ins), and a
  plug-in a bandmate doesn't have stays in their copy as offline, its settings kept (see Plugins: translations).
- Prints render through the item's track (not parent folders or sends) and only on a machine where all of that
  track's plug-ins load; rendering shows REAPER's render window for a moment (REAPER has no background render).
- Track colours travel with a real change but aren't a change on their own (auto-colouring would make machines
  recolour each other). Envelopes (automation) don't travel yet.
- An item's lane travels; a lane's name and which lanes play travel with its track.
- Both changing one object while apart: the newer change wins everywhere; the other is on the Restore page.
- Bringing a side room in: an object both rooms changed since the room was made stays as main has it.
- The FX browser folder is written to `reaper-fxfolders.ini` while REAPER runs; REAPER may only show a changed
  folder after a restart.
- Time-selection claims are kept in seconds: inserting time before them doesn't move them (re-claim after).
- The shared folder trusts its members: an event says who made it, and nothing checks that beyond the folder's
  own sharing. Share it only with your band. The events folder grows with the session (never pruned yet).
- Live (Play along): ReaNINJAM reads its settings when it first opens in a REAPER session; after changing mode or
  server, restart REAPER. Play along needs the sender's channel in Session mode (the panel says when it isn't).
  Its placeholders appear when the listener disconnects (ReaNINJAM writes its clip log only then).
- Real time mode: REAPER only sees a newly installed SonoBus after a restart. Setting SonoBus up relies on its saved
  state's layout (checked against SonoBus 1.7.2); if a later SonoBus changes it, BandSync says so and you join with
  SonoBus's own Connect button. What you hear from others is a little late (the network): line-up against the grid
  is being worked on.
