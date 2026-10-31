# When two people change the same thing

This is how BandSync decides today, how other collaborative tools decide, and the choices left open. Nothing here
is settled for good: it's written down so the band can decide later with the facts in one place (James, 2026-10-31).

## What BandSync does now

Most edits never clash. Each track, item, plug-in chain, envelope and send is its own object, so two people changing
different things both land. A clash is two changes to **the same object** that neither saw before making theirs:
both were apart (offline, or Syncthing hadn't caught up), or both changed it within the same second or two.

1. **Rules come first.** In *Only the driver* and *Driver + claims*, a change you may not make is put back on your
   machine at once, with the reason, so most would-be clashes never reach the band. In *Anyone*, everything
   unclaimed is open, the tempo map and markers too.
2. **More edits wins.** Every object carries a version number that goes up by one with each change to it. Of two
   clashing versions, the one with the higher number wins: whoever changed that object more times since the two
   split. A tie goes to the later clock time, then to the name that sorts last, so every machine picks the same
   one without asking anyone (`mirror.newer` in `lib/mirror.lua`).
3. **Nothing is lost.** The losing version stays in History. Its owner is told ("X also changed ... while you were
   apart: theirs is in"), and **Undo** on the winning change on the Restore page brings theirs back. When both
   worked alone, a saved version of the loser's whole project is kept first.

Known weak spots:
- "More edits" is a proxy for "more work", not a measure of it: ten nudges outvote one long careful edit.
- The tie-break uses each computer's clock; a clock that's minutes off can win ties it shouldn't.
- The loser hears about it after the fact. There is no "both versions, pick one" step.

## How other tools decide

| Tool | How a clash is avoided or settled |
|---|---|
| **Pro Tools cloud collaboration** (Avid) | Per-track **ownership**: one person owns a track at a time and asks the owner to hand it over. You can still edit a track you don't own, but the owner's version is the one that goes to the project; yours shows as a conflict (yellow upload/download arrows) until you take theirs or get ownership. Changes are shared per track, when you choose. |
| **Figma** (design, not audio: the best documented live model) | A central server orders every change. Two changes clash only if they set the same property of the same object; then the **last one the server received wins**. No locks. |
| **Ohm Studio** (live collaborative DAW, now discontinued) | Everyone edits live in one shared project; each change is logged with who made it. Tracks can be kept **private** until you're ready to reveal them. |
| **BandLab, Soundtrap** | Live co-editing in the browser. Neither publishes how two edits to the same clip are settled; general write-ups describe edit locking or last-writer-wins as the usual answers. |
| **Splice Studio** (retired), Dropbox-style sharing | Whole-project versions: whoever saves later makes a new version, and the older ones stay in the history to go back to. |
| **git and code tools** | Merge what doesn't overlap; where it does, stop and ask a person to choose. |

## The choices, if the band wants to change it

- **Keep "more edits wins"** (now): automatic, the same on every machine, no waiting on anyone.
- **Last change wins** (Figma): simple to explain, but "last" depends on clocks when there is no central server, and
  a quick tweak can replace an hour's work.
- **Owner wins** (Pro Tools): the driver or the claimant's version always wins on what they own; BandSync's claims
  are halfway there already.
- **Ask** (git): show both versions and let the person whose change lost pick. Safest, but it interrupts playing.

Sources: [Sound On Sound, Cloud Collaboration in Pro Tools 12.5](https://www.soundonsound.com/techniques/part-2-cloud-collaboration-pro-tools-125),
[AudioTechnology, Pro Tools Cloud review](https://www.audiotechnology.com/reviews/pro-tools-cloud-nine-or-nein),
[Evan Wallace, Multiplayer editing in Figma](https://madebyevan.com/figma/multiplayer-editing-in-figma/),
[Figma, Making multiplayer more reliable](https://www.figma.com/blog/making-multiplayer-more-reliable/),
[MusicRadar, Ohm Studio review](https://www.musicradar.com/reviews/tech/ohm-force-ohm-studio-590570),
[Synthtopia, Ohm Studio](https://www.synthtopia.com/content/2011/03/24/ohm-studio-demo-2-people-making-music-together-in-real-time/),
[Soundbridge, real-time collaborative DAWs](https://www.soundbridge.io/real-time-collaborative-daw-your-2026-production-guide).
