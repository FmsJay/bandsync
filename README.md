# StudioSync

(It began as BandSync, and the script files, folders, the ReaPack package and this repository still carry that name for now.)

Record and arrange together in REAPER from different cities, as if you were all working in one project.
Everyone in a room holds the same project: every track, item, lane, MIDI part, plug-in chain, automation
envelope and send, kept
identical by mirror sync. One person drives (their changes go to everyone); collaborators claim the tracks or
project sections they work on, and Restore can take back any change, any track, or the whole project.

Plain-Lua ReaScripts (the control panel needs ReaImGui; SWS helps). REAPER 7.18 or newer; 7.83 is tested.
Machines talk only through a shared folder (Syncthing recommended), with an optional Google Drive copy.

## Start a new group/session

For a band, or for one song with someone: it's the same thing, so name it what it is.

1. Run the installer: **Install BandSync (Windows).cmd**, or on a Mac **Install BandSync (Mac).command** (see
   [Setup](#setup-each-person-once) if macOS blocks it). Answer *n* to "Is someone in the group already set up?" and
   give it a name. Already have StudioSync? Press **Start a new group/session** on a project's first screen, or in
   Setup > Options. With a project open, it offers to share it and has the invitation ready.
2. In REAPER, open your project and press **Share this project with the group** in the StudioSync panel.
3. On the Home page, press **Invite a collaborator**. It copies a line for them to paste: send it to each person.
4. When they've run it, your panel shows **Let *them* in**: press it.
5. Finished? **Close** in Setup > Options stops it on every computer. Everyone keeps their copy, and its projects stay
   open as ordinary projects.

Syncing needs no account: only your two computers and the shared folder, and files move while both are online. Two
extras do: *Play along* and *Jam* use one Tailscale account for the group, and the optional Google Drive copy uses a
Google account. REAPER keeps its own licence (reaper.fm).

## Collaborators: start here

1. Ask whoever invited you for the line from their panel's **Invite a collaborator**, and paste it where it says.
   It runs the installer with everything filled in. (No line? Run the installer as above, answer *y*, and paste their
   **Syncthing device ID** (in Syncthing: Actions > Show ID) and the group's ID.)
2. Tell them you've installed: their StudioSync panel shows **Let *you* in**. Once they press it, the group's projects
   arrive in your shared folder by themselves.
3. In REAPER's StudioSync panel: **Join the group's project**. Its tracks arrive over the next moments.
4. Play and record as usual. What you change reaches everyone; anything that isn't yours to change is put back,
   with the reason.
5. To hear each other live: **Real time mode** on the Home page. Undo anything: the **Restore** page.
6. Once: **Calibrate latency** (Setup > Health says when it's still missing).

Everything below is the detail.

## How it works

```
<shared folder>/
  <Project>/
    session.json               tempo map, markers, sample rate, host
    rooms/<room>/
      events/   <person>-<time>.json    every change: a track, an item, a plug-in chain, a track's automation or its
                                        sends, as REAPER describes it
      media/    recordings and MIDI prints the items use (copied in once)
      claims/   <person>.json           the tracks and regions each person owns
      recall/   recall points (every handover, or saved by hand)
      status/   <person>.json           who's here, what they're doing (the panel's Who's here)
      chat/     messages, to-dos, links for the room (the project's and the group's sit beside it)
      driver.json, mode.json            who drives; Only the driver / Driver + claims / Anyone
```

- **Publish** (host) makes the project a group session. The project must be prepared first (a checklist); an
  untitled project is saved under the project's name, and a copy as it was before BandSync is kept (Restore offers
  it back). A project name another collaborator already uses is refused.
- **Open session** (collaborator) opens the project straight into its main room, in a new tab; Live sync fills it.
- **Live sync** (everyone, always, whenever a BandSync project is open) does the rest. See `docs/mirror-design.md`.
  - Every track and item has a permanent id (never its name), so unnamed and renamed tracks are fine.
  - What you change goes out a moment after you change it (after the drop, when dragging): items (position,
    fades, mute, lane, MIDI notes, copies, new items), tracks (name, lanes and which lanes play, folders,
    mute, fader, pan, width and pan mode, channel count, the FX button, the master/parent send, timebase,
    playback offset, group/VCA membership, lock, input FX and MIDI note names), sends between tracks (level, pan, mute, channels and their send envelopes),
    automation envelopes and their automation items (volume, pan, width, mute, trim; sent once you stop and leave
    them for 3 seconds), plug-in chains with their parameter automation (only while stopped: replacing a chain
    reloads the plug-ins), and the master track's plug-ins and automation (its fader and pan stay yours: that's
    your listening level; a ReaNINJAM or SonoBus on it stays yours too).
    Which envelopes you show, which is armed and how tall their lanes are stay yours. Plug-ins, automation and
    sends land when that project's tab is in front (REAPER misroutes sends written into a tab behind).
    Solo stays yours: soloing a part to hear it never solos it for the group. So does item grouping.
  - A collaborator's recording whose audio is still syncing shows as a grey item where it goes, until the file lands.
  - Files a plug-in loads by itself (sampler samples, impulse responses, amp models) are copied into the room.
    A collaborator gets each one at the same place when their machine has that folder; otherwise BandSync says which
    plug-in wants which file and where the copy is.
  - Melodyne (and other ARA plug-ins) on a take: whoever edits it gets a print (closing the Melodyne window makes
    a new one) that travels as audio. They keep the editable take; everyone else plays the print, since
    Melodyne's edits live outside the item. Freezing a track travels as its result; unfreezing brings it back.
  - The project's own settings travel with the tempo map and markers (the driver's): title, author, project notes,
    track group names, the timebase, the ruler lanes and which lane each marker or region sits in.
  - What the group changes comes in, the newest version of each object winning on every machine alike.
  - A change you may not make (the driver's, or someone's claim) is put back, Ctrl+drag copies included, with the
    reason in the panel's banner (or a tooltip by the mouse when the panel is closed). If it's someone's claim, what
    you did goes to them as a suggestion (see Claims).
  - Never touches a track while you record on it.
- **MIDI** travels as notes. Whoever changes a MIDI part also renders a print (its sound, through their
  instrument), kept as the item's second take: "dry" is the notes, "wet" the print. A MIDI track that plays an
  instrument on another track (a MIDI send to a sampler or drum-kit track) is printed through that track, with
  only that item feeding it. Each person picks how MIDI plays on their machine (Setup > Options): **Auto** (your
  instruments when every plug-in it plays through loads here, else the print), **Dry** or **Wet**. That choice
  never changes what anyone else hears. When an instrument on another track doesn't load here, Setup > Health
  names it and says you hear the group's print.
- **Audio through a plug-in someone lacks** (an amp sim on a guitar, say) gets a wet take the same way: whoever
  changes the item renders it through the track's plug-ins, and the same Auto / Dry / Wet choice picks which plays.
  Only tracks with a plug-in that isn't on everyone's list get one, and only items with a single take. While a
  track plays a wet take, its plug-ins are switched off on that computer only, so the ones that do load there
  don't apply twice (the group still has them on).
- **Your colour, and who's working where** (Setup > Options): everyone has a colour, their own pick or a default
  nobody else has, the same on every computer; drawings use it. Each computer chooses how tracks look: **Group's
  colours**; **Show who's working** (the group's colours, but a track a collaborator is editing or has claimed shows their
  colour until they're done); or **Whose track** (every track in the colour of whoever is editing it, claimed it, or
  made it). Only on that computer: the group's own colours are kept aside meanwhile, never sent or lost.
- **Prints render in the background**: a second, hidden REAPER renders each one from a copy of the project while you
  carry on (a few seconds each, one at a time), and it's added when it's done; on Windows it runs on a desktop of its
  own, so nothing shows or takes the keyboard. It runs with a settings folder of its own (in your temp folder): your plug-ins and effects, but none of REAPER's extensions, MIDI devices or control surfaces, and it never touches your reaper.ini or Recent projects. Where that doesn't work it renders in front as before; Setup > Options
  turns it off. BandSync adds a guard to the top of Scripts/__startup.lua so your own startup scripts don't run in it.
- **Who prints**: whoever changed a part, when they have every plug-in it plays through. Someone who doesn't is
  covered by a collaborator in the project who does (the first by name), and **Print selected tracks here** (Claims) puts you
  in charge of printing those tracks whenever you're in the project with their plug-ins.
- **Takes become lanes**: in a group project an item's takes (several in one item) are turned into fixed lanes by REAPER's
  own "explode takes to fixed lanes and add comp areas", so a comp you made by picking takes stays the comp (the
  project plays the same, sample for sample). A track that already has wet takes waits (it would split them).
- **Local mixing** (Home): your faders and pan stay yours. Switching it off asks whether to take the group's
  mix or send yours.
- Projects published with BandSync before 0.30 are left alone: publish them again to sync them.

## Setup (each person, once)

**Easiest: the installer.** Download the `installer` folder (or just the one file) and double-click
**Install BandSync (Windows).cmd**, or on a Mac **Install BandSync (Mac).command**. It asks your name, whether
someone in the group is already set up (if so, their Syncthing device ID: any set-up collaborator's will do; with the line
from their panel's **Invite a collaborator**, it's already filled in) and whether you want the plug-in pack, then
installs whatever is missing from official sources: REAPER, ReaPack, ReaImGui, js_ReaScriptAPI, SWS, Syncthing,
SonoBus, Tailscale and Google Drive for desktop. It sets up the shared folder and pairs it with your collaborator,
waits while you sign in to Tailscale (and switch off its key expiry) and Google Drive (and add the group's folder),
installs BandSync through ReaPack and opens the panel. At the end it lists only what's still left, such as your
collaborator pressing *Let you in*.

On a Mac, macOS blocks a downloaded script the first time. Either:
- in Terminal, paste `curl -fsSL "https://raw.githubusercontent.com/FmsJay/bandsync/main/installer/install_mac.sh?$(date +%s)" | bash`
  (nothing to unblock; a collaborator's **Invite a collaborator** gives you this line with their ID already in it), or
- double-click the .command, then System Settings > Privacy & Security > **Open Anyway** (macOS 15 and later no longer
  offer right-click > Open for this). A .command that came through a shared folder, Drive or email may also have lost
  its "can run" bit: run it as `bash "Install BandSync (Mac).command"` instead.
A newly installed REAPER opens with its evaluation reminder: wait for its countdown, then *Still evaluating* (REAPER's
own licence: reaper.fm). Tailscale asks macOS to approve its system extension (System Settings > General > Login Items & Extensions): the
installer waits while you do.

**Or let an AI do it.** In Claude Code, on the computer being set up, point it at
`installer/SKILL.md` ("set up BandSync using installer/SKILL.md"). It installs and configures everything below,
explains each prompt before it appears, and asks before every download.

**In the project:** the panel's first screen offers *Join the group's project* or *Share this project with the group*, and the
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
   - **From the shared folder** (group-internal): *Actions > Show action list > New action > Load ReaScript*,
     and load every `BandSync - *.lua` straight from `<shared folder>/_tools/bandsync`. **BandSync - Update**
     registers any new scripts that arrive later. The trade-off: anyone who can write to the shared folder can
     change everyone's scripts. Only share it with your group.
3. Run **BandSync - Settings**: choose the shared folder and enter your name.
4. **Calibrate recording latency** (important): connect a cable from your interface's output 1 to an
   input and run **BandSync - Calibrate latency**. It plays three clicks, records them back in a temporary
   project, and tells you how many samples early or late your recordings land. Under 1 ms is fine. If it says
   LATE N, add +N to *Preferences > Audio > Recording > Input manual offset* (EARLY: subtract) and run it again.
5. **Install ReaImGui** (*Extensions > ReaPack > Browse packages*): the panel, and with it the Live and
   Restore pages, needs it.
6. Optional extras:
   - **Tailscale** is only for *Play along* and *Jam* (they reach the NINJAM server on the host's machine).
     Syncthing, Real time mode (SonoBus) and everything else work without it. Simplest: everyone signs in to
     the group's one Tailscale account (what the installers do; the host adds the `tag:bandsync` line they print, so
     group machines stay signed in). Someone who keeps their own Tailscale account instead gets the server machine
     shared with them (admin console > the machine's **...** > *Share*) and accepts the link.
   - **The Google Drive copy** (optional, recommended) needs **Google Drive for desktop**, each person signed in
     with their **own** Google account (two computers on one account lose files: "Lost and Found"). The host makes a
     `BandSync` folder in My Drive and shares it with everyone as Editor; each collaborator adds it to their own Drive
     with *Shared with me > right-click > Organize > Add shortcut > My Drive*, keeping the name `BandSync`, or it
     never reaches their computer. BandSync finds it in any My Drive on the machine (any drive letter, the Windows
     user folder, every macOS account) and never makes one itself; Settings says when the shortcut is
     missing. Anything else goes in the `drive_root` setting (ExtState), and Settings
     *Keep the group's copy on Google Drive* turns it off on one machine.

## Session workflow

**BandSync - Panel** puts everything in one window. It opens by itself whenever a BandSync project opens.

- **Top bar**: `Project: <song>`, the room, **Sync on** (green: Live sync is running; red **Sync off**: press Start),
  who drives, **Undo** / **Redo** (your own changes, for everyone; each asks first, and says if a collaborator changed the
  same thing since), **Dock** and, floating, **Full screen** and **Window** (half the screen, the next screen, back).
  Under the bar, what BandSync just did shows for a few seconds.
- **Open collaborators' MIDI edits as they happen** (Setup > Options, off by default, this computer only): when someone's
  change to a MIDI part reaches you, it opens in the MIDI editor with the notes they changed selected. A MIDI editor
  you opened yourself is left alone. Which notes are selected and which lanes an editor shows never go to the group.
- **Background renders on a Mac** use a private copy of REAPER (about 170 MB in `~/Library/Caches/BandSync`, made once and
  again after REAPER updates) that macOS keeps in the background, with a small library that keeps its windows
  transparent. It never touches your REAPER. Setup > Options can switch background rendering off.
- **Wet takes in a burst**: a part is rendered once it has held still for 3 seconds, up to three at once, whichever
  changed longest ago first, so a part you're still editing doesn't hold up the others and doesn't render every step.
  A render of a version that's gone is ended. Going back to a version already printed needs no render and doesn't wait.
- **Minimize** (top bar, or closing the panel) shrinks it to a small square over REAPER: its edge is green while sync runs, red when it doesn't, and a count in the corner says what's waiting (hover for the words). Click it and the panel opens where it was, floating or docked. Drag it and it stays there, pinned to REAPER's window; right-click to lock it, close the panel or remove the square.
- **Themes**: Setup > Options > Look: Dark, Light, Midnight or Warm, per computer.
- **Nothing clips in a render**: prints and the final mix go through REAPER's render limiter at -0.3 dB. Only what goes over is touched, and timing stays as it was. It stops a clip, not a mix that's too hot: the final mix says so when the limiter was working.
- **Removing someone**: the driver or the song's host has **Remove** on their card in Who's here. You get a minute to change your mind (**Keep them**), then every computer in the group stops syncing with theirs, each on its own as it comes online. Their claims go free, and what they made stays in the songs and on Restore. They keep the copy they already have, and the group's Google Drive folder is yours to take them off. Invite them again to bring them back.
- **Pages**: **Home** (Who's here with *Take control*, Real time mode, who changes what, Local mixing, claims),
  **Rooms**, **Play** (play/record together, follow each other, how you hear each other), **Chat**, **Restore**,
  **Plugins** and **Setup** (Health, Console, Options, Updates). A red or yellow dot on Setup means Health has
  something (red: the group can't sync until it's fixed).
- **Docking**: click *Dock* for Bottom / Left / Right (REAPER's docker on that side; if there isn't one, BandSync
  says how to set it once). Right-click *Dock* to arm drag-to-dock (it turns green); otherwise dragging the
  window only docks while you hold Shift, so moving it never docks it by accident. Docked short and wide, each
  page lays out in columns.
- The floating window resizes from every edge and corner. Every control explains itself on hover.

**BandSync - Radial menu** pops a ring of everyday moves around the mouse. Give it a key or mouse button in the
Actions list. The slices are Undo, Redo, Restore project…, Restore selection…, Undo one change… (each of these three
opens Restore set to that kind of going back), Take control (greyed while you drive), Real time mode on/off, and
Chat. Point at a slice to read what it does underneath, and click it to do it. Esc, a click anywhere else, or the key
again closes the menu. The panel carries the move out, so each choice asks first just as its button there does, and
the panel opens if it was closed.

**BandSync - Undo** and **BandSync - Redo**: bind them to Ctrl+Z and Ctrl+Shift+Z (Actions list > Add shortcut). In a
BandSync session they step back through your own changes only, for everyone, and ask first only when a collaborator
changed the same thing since (REAPER's own undo would roll their changes back too). In any other project they're
REAPER's normal Undo and Redo.

**Your name**: Setup > Options > Change name. Who drives and your claims move over, and your tracks stay yours on
every machine (the group keeps a list of old names). Changes you made before keep the old name on the Restore page.

**Drawing on the tracks**: Chat > "Draw on the tracks" (or the BandSync - Draw action). Draw over the arrange view
for everyone in the room, with a toolbar: **Pen**, **Highlighter** (wide and see-through), **Line**, **Arrow**, **Box**
(drag from one end or corner to the other), **Text** (click where the words go) and **Eraser** (click one of your
drawings); a colour (or *Mine*, your own) and a size (S, M, L), which this computer remembers. **Undo** takes away
your last drawing, **Clear mine** all of yours; Done or Esc stops. Drawings sit on a bar and a track, so they stay
put however anyone scrolls or zooms. "Show drawings" / "Hide drawings" turns the overlay on and off here (clicks
always go to REAPER while you're not drawing). The eraser, Undo and Clear mine only touch your own drawings. The
toolbar sits at the foot of the arrange view; the mouse wheel still zooms and scrolls while drawing. BandSync's own
tracks (Real time) can't be drawn on: each computer has its own, so nothing there could reach the group.

**Working at the same time** (each machine's status file carries it, a few seconds behind):

- **Edit holds**: what a collaborator changed in the last 15 seconds is theirs for that long. If you change it too, yours
  is put back with "Bee is editing that item on Keys right now", instead of the two of you overwriting each other.
- **Follow**: the Follow button next to a collaborator in Who's here keeps your arrange view where theirs is.
- **Ping**: the radial menu's "Ping here" puts a marker with your name on everyone's timeline for 30 seconds.

**FX browser**: the plug-ins everyone in the group has show in a "BandSync" category (and the "BandSync (everyone
has)" folder) after REAPER's next start.

**Open session** shows, for the project you point at, how many tracks it has, how much audio, and which of its
plug-ins this machine doesn't have.

Who may change what:

- **Driver**: their changes reach everyone, except on what someone has claimed. *Take control* (next to Who's
  here) makes you the driver; it checks everyone has caught up first, and every handover saves a version.
- **Editing modes** (Home; the driver picks): **Only the driver**, **Driver + claims** (default: the driver, and
  everyone on what they've claimed; a track you make is claimed for you once it has a name, unless you drive, and
  a track you made stays yours to change until someone claims it, listed on the Claims card) or **Anyone** (anything unclaimed;
  the tempo map, markers and project settings too; a clash goes to whoever changed it more: docs/clashes.md).
- **Claims**: *Claim selected tracks*, *Claim region at cursor* or *Claim time selection* (shown to everyone as a
  `[claimed: you]` region). A track claim beats a time claim, which beats a region claim, which beats the driver.
- **Suggestions**: an edit that reaches someone's claim (a section copied or moved across the project, say) goes out for
  what's yours, and the claimed parts go back. What you did to them reaches their owner as one line at the top of the
  panel, *Accept* or *Decline*; you see *Waiting on ...*, and can *Withdraw*. Accepted, it lands as the owner's own change,
  so the claim never moves, and their undo key takes it back. Anything new stays on your own "(yours, not sent)" track until
  then. A part they've changed since is left as it is. Plug-in changes aren't suggested: a plug-in can change its own
  data, which would ask its owner about nothing.
- **Tempo**: the driver's, or anyone's in *Anyone*. The parts it moves aren't anyone's edit, whoever claimed them.
- **Buses, folders, VCA faders and the master**: a change to one still goes through under the usual rules, and says whose claimed parts it affects.
  One holding someone's claimed part can't be deleted: it comes back, and says why.
- **A copy of someone's claimed track** goes out as yours, as "Keys (James's copy)", and says whose it was. The original isn't touched.
- **What you see is what the group has**: anything you change that isn't yours to change is put back at once,
  with the reason. Recording on a track you may change always goes out. **Hold my changes** keeps your changes
  here until you switch it off; then they go out together.

Restore (its own page):

- Every change in the room, newest first, grouped by who made it; filters by person, kind (items, tracks,
  plug-ins, deletes, things brought back, tempo, handovers...), track or words.
- Click a change for what you can do with it: **Undo this change** (everything after it stays), **Restore selected
  tracks to here** (their items and plug-ins), **Restore whole project to here** (the driver), or **Open in side room**,
  to check it's the right moment first. Every restore goes to the group as new changes, so it can be undone the same way.
- **Saved versions** (every handover, or *Save this version*), and *Open it as it was before BandSync* (the copy Publish
  kept). **Render current mix** puts the whole project's mix, as your master has it, in the shared folder's `<Song>/mixes/` for everyone, and on Drive. **Back up** keeps the project as it stands: a saved version kept for good, and the project on Drive.
- **Old history is trimmed**: once a day, at the end of a session, the room's driver takes away changes older than
  30 days that nothing needs. Each thing's newest change stays, so does everything a major saved version (end of
  session, "yours before…", or one you saved by hand) needs to restore exactly; only the snapshots before a
  handover may lose their exact past. Trimmed files go to `BandSync history archive` beside the group folder on the
  driver's computer, not away for good.

Chat (its own page): **This room**, **This project** or **Group**, each with **Messages**, **To-do** (anyone ticks
them off) and **Links** (lyrics, charts, documents). Each message is its own small file, so nothing ever clashes.

Plugins (its own page): every plug-in the project uses, on which tracks, and who in the group doesn't have it. Set a
**translation** for one (something the group has that's close enough); *Apply translations here* adds it right after
the original on a machine that's missing it. Translations are that machine's own: they never go to the group, and
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

- **Alone = full control.** While nobody else is in the room, everything you change goes out (the group gets it when
  they're back), whatever the claims.
- **Both changed something while apart**: whoever changed it more times since you split wins (a tie: the later
  one), on every machine alike ([docs/clashes.md](docs/clashes.md) explains, and how other tools decide). If yours was replaced, BandSync
  says so: yours is still on the Restore page (*Undo* on theirs brings it back).
- **The Google Drive copy** (Setup > Options): Syncthing only moves files while two machines are on at the same time.
  Live sync also keeps a copy of the room on Google Drive (store and forward), so what someone does alone reaches the
  others even if you're never online together. Every project on your computer in full keeps its Drive copy (your
  changes and recordings; the others' come from their machines), one project at a time in the background. Opening a
  project that's only listed here brings it from Drive as well as from collaborators, so it opens even when nobody who has it
  is online. What the history trim took out stays out of the Drive copy too.

### Groups

Each group is its own shared folder: its own projects, collaborators' names, plug-in list, drum maps, SonoBus group and
Google Drive copy, and nobody in your other groups sees it. `_band/band.json` in the folder says which group it is
(name, Syncthing folder id, Drive folder name); a folder without one is the first group (Syncthing id `bandsync`,
Drive folder `BandSync`).

- **Who runs a group**: whoever started it is its **owner**, and can make people **admins** on their cards in Who's here. Admins let people in, rename it and remove members. Only the owner can remove an admin, make someone else the owner, or close it. This trusts the people in the group: the list is a shared file, not a lock.
- **Rename** and **Leave** (Setup > Options > Groups): a new name reaches everyone, and folder names stay as they are. Leaving stops this computer syncing it: you keep your copy, its projects stay open as ordinary projects, and someone can invite you again. The owner hands it over first, or closes it. Your only group can't be left, unless nobody in it has been online for a week: closed or removed while you were offline, nothing can reach you to say so, and the panel says so then.
- **Start a new group/session** (Setup > Options > Groups): makes its folder beside your first group's (`StudioSync <Name>`) and its
  own Syncthing folder, shared with nobody yet. Then *Invite a collaborator*: the invitation is for the group you're
  working in, and their installer joins that group (`BS_BAND_ID` / `BS_BAND_NAME` on a Mac, `-BandId` / `-BandName`
  on Windows). *Let them in* shares only that group's folder.
- **Switch** (Setup > Options > Groups, or the start screen when you're in more than one): new projects, *Join the group's
  project* and the project list are that group's. Project tabs keep their own group, so two groups' projects can be open at once.
- The first person to set up a group names it in the installer.

### Projects on this computer (per-project sync)

Every computer gets every project's listing (a few KB: what the project chooser shows), and a project in full only once it's
opened there, so a new collaborator's first sync isn't the whole library. Opening a project in the chooser brings the rest
of it (the chooser says "downloaded when you open it"). Setup > Options > **Projects on this computer** lists the projects
here in full, with **Stop downloading** for one you're done with (its files stay until you remove them; nothing
changes for the group), and **Keep every project on this computer** for the machine that stays on, so new collaborators
always have somewhere to get a project from. It works through Syncthing's ignore file in the shared folder
(`.stignore`, never synced: each computer its own); BandSync writes its own block there and leaves any other lines
alone. Computers that already had projects keep every project they had.

### Real time mode

Home's **Real time mode** switch: you hear each other as you play (SonoBus, peer to peer), and play, stop and record
follow whoever presses them. SonoBus sits on its own **BandSync Real time** track, fed only by your **armed** tracks:
everyone already plays the project from their own copy, so only what you're playing live goes out (no doubled backing).
*Configure SonoBus* opens its own window (volume and mute per collaborator, buffer), which you don't need to play
together.

With Real time mode on:
- **Who you hear**: each collaborator in Who's here gets a **hear** / **muted** button. BandSync gives everyone their
  own SonoBus output pair (written into SonoBus's per-person settings, which it keeps by name) and mixes them on your
  master with **BandSync live mix**, a small effect of your own that never goes to the group. Up to 7 collaborators get a
  pair; anyone else (a guest, an eighth collaborator) shares one.
- **My time / Their time**: in your time you hear them as it arrives, a little late. *Their time* holds your own
  backing back by that much, so what they play lines up with it: for listening along, not for playing. SonoBus's window
  shows each person's delay (the number after the down arrow); with a guest, use their measured delay.
- **Guest**: for someone who joins with only SonoBus (a singer at home, no REAPER, no copy of the project). They hear
  your whole mix, and what they sing is recorded on the Real time track whenever you record. **Measure their delay**
  plays them a bar of count-in and 8 clicks to clap along to, and times where the claps land (the whole round trip;
  the idea is from ReaConnect). Measure right before you record: the delay drifts as SonoBus adjusts its buffers
  (tested PC to laptop over Wi-Fi: 426 to 555 ms within two minutes), so a take can land that far off and need a nudge. **Line up their takes** then moves what you recorded onto a group track of theirs,
  earlier by that delay, and the group gets it like any take.
- SonoBus has to actually join the group's group: BandSync checks it did (SonoBus saves each join), tries twice more,
  then tells you to press Connect in its window. Turning Real time mode on also takes any other tab's SonoBus offline,
  so you're only in the group once.

### Rooms: side rooms, and bringing work back

- **Create side room**: a copy of the room you're in, as it is now, in a new tab, to try things without changing the
  room. Squares show each room and who's in it; click one to go there; **Come see** asks everyone over.
- **Send selected to main**: the selected items (and any track of theirs main hasn't got) go to main as they are
  here.
- **Bring into main**: everything this room changed since it was made goes to main, except what main has also
  changed since (listed as clashes; main keeps its own). Only main's driver brings a room in. Brought changes are
  ordinary changes in main, so Restore there can undo them.

### Plug-ins everyone has

Each machine sends the group the names of the plug-ins it has (`<shared folder>/plugins/<you>.json`) when Live sync
starts. What every collaborator has goes in a folder of REAPER's FX browser, **BandSync (everyone has)** (VST3 first when
a plug-in comes in several formats, since Windows and Mac both have VST3). Use those and the project sounds the same on
every machine. The **Plugins** page updates it on demand. REAPER's own effects (ReaPlugs and the
JSFX) are on every machine; JSFX from ReaPack work on Windows and Mac alike, once everyone installs the same package.

**The group plug-in pack** (the installers ask; free, each from its official release, nothing bundled, about 150 MB
on Windows and 350 MB on a Mac): Surge XT (synth + effects, GPL-3), Dexed (FM synth, GPL-3), Airwindows Consolidated
(MIT), Dragonfly Reverb (GPL-3), Chow Tape Model (GPL-3), BYOD (guitar and bass amps, tuner; GPL-3), ZL Equalizer 2
and ZL Compressor (AGPL-3), ChowMatrix (delay, BSD-3), and through ReaPack the JSFX of Saike and Chokehold (MIT) and
chmaha's *DSP to JSFX* (the effects and instruments REAPER 7.83 bundled and 7.84 removed: drum kits, piano and
e-piano, organ, channel strip...; GPL-3 with MIT/AGPL parts). On Windows the plug-ins with a setup program install
together at the end without their setup windows, and Windows asks for permission once (say no and each one's own
setup opens instead).

**Extras** (a second question, about 820 MB on Windows, 880 MB on a Mac, most of it the piano): Neural Amp Modeler
0.7.13 and AIDA-X (amp capture players), Odin 2 (synth), and the Salamander Grand piano (SFZ) with sforzando to play
it. Worth adding by hand (free, but they need an account or can't be passed on): Vital, Valhalla Supermassive,
Spitfire LABS, MeldaProduction MFreeFXBundle.

### Live: hear each other while it happens

The **Play** page has three ways to hear each other:

- **Play along (synced)**, the default: your audio is stamped with its project position; listeners start playback
  a bar or two after you and hear you in time with the project, at any distance. What you play also lands on their
  timeline as a placeholder on a "<name> (live)" track, replaced automatically when your real take arrives.
  Uses REAPER's own ReaNINJAM and a NINJAM server the host runs (`tools/ninjam-server/README.md`), over Tailscale.
- **Real time** (Home's **Real time mode**): hear each other as it happens, through **SonoBus** (free, GPLv3,
  sonobus.net): peer to peer, far lower delay than NINJAM, nobody runs a server. It sits on the **BandSync Real time**
  track, fed only by your armed tracks, already in the group's group under your BandSync name (BandSync writes the group
  into SonoBus's saved state; `lib/sonobus.lua`). The group's group and password are in `<shared folder>/sonobus.json`;
  SonoBus's public server only introduces peers, and the audio goes directly between you, unencrypted.
- **Jam**: classic NINJAM, everyone one interval late.

The host enters `<Tailscale IP>:2049` and clicks *Save for the group*; everyone else clicks **Connect**, which adds
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
save, BandSync recognises its tracks and items, brings back what changed since as the group has it, and sends
nothing new. Leave the file where it is. Without it, a reopened older save would show up for everyone with its
tracks twice.

## Limits

- Plug-in chains change only while the transport is stopped (replacing a chain reloads its plug-ins), and a
  plug-in a collaborator doesn't have stays in their copy as offline, its settings kept (see Plugins: translations).
- Prints render through the item's track (not parent folders or sends) and only on a machine where all of that
  track's plug-ins load; they leave out the item's own volume and fades (the item applies them to whichever take
  plays). The hidden REAPER that renders them puts its copy in REAPER's recent-projects list until you next quit.
- Track colours travel. SWS auto-colouring (Extensions > Auto Color/Icon/Layout) is switched off while a group project
  is in front, since its rules would recolour the group's tracks, and back on when another project is; a computer
  where it stays on (an older BandSync) keeps its colours to itself. Automation items arrive as items of their own (pooled ones aren't pooled on the other side).
- Sends to and from a track that only exists on your machine (Real time, live views) stay yours; hardware
  outputs, record arm, inputs and monitoring stay yours too.
- Not synced, on purpose: render, metronome and recording settings, and the master fader (each person's own).
  A Melodyne edit reaches the group as audio (the print), not as an edit they can change.
- An item's lane travels; a lane's name and which lanes play travel with its track.
- Both changing one object while apart: the newer change wins everywhere; the other is on the Restore page.
- Bringing a side room in: an object both rooms changed since the room was made stays as main has it.
- The FX browser folder is written to `reaper-fxfolders.ini` while REAPER runs; REAPER may only show a changed
  folder after a restart.
- Time-selection claims are kept in seconds: inserting time before them doesn't move them (re-claim after).
- The shared folder trusts its members: an event says who made it, and nothing checks that beyond the folder's
  own sharing. Share it only with your group. The events folder grows with the session (never pruned yet).
- Live (Play along): ReaNINJAM reads its settings when it first opens in a REAPER session; after changing mode or
  server, restart REAPER. Play along needs the sender's channel in Session mode (the panel says when it isn't).
  Its placeholders appear when the listener disconnects (ReaNINJAM writes its clip log only then).
- Real time mode: REAPER only sees a newly installed SonoBus after a restart. Setting SonoBus up relies on its saved
  state's layout (checked against SonoBus 1.7.2); if a later SonoBus changes it, BandSync says so and you join with
  SonoBus's own Connect button. What you hear from others is a little late (the network): *Their time* lines it up
  for listening, but its delay is one number for everyone (set by hand for collaborators; SonoBus doesn't let other
  programs read its measurements). Changing a person's output in SonoBus's own window while people come and go has
  crashed REAPER once (SonoBus 1.7.2): leave the outputs to BandSync.

## Licence

BandSync is free software under the GNU General Public License, version 3 or later (see `LICENSE`).
