# Mirror sync (0.30 line)

The event sync (0.1–0.21, branch `legacy/event-sync`, tag `event-sync-final`) sent a fixed list of change kinds:
take shape, what plays, track name/mute/solo/fader, note edits, tempo. Anything else (copies, hand-drawn items,
lanes and lane play modes, unnamed tracks, envelopes, fades) never travelled, and receivers' projects were built
differently on purpose ("(band)" tracks, muted MIDI shadow items). Mirror sync makes every machine in a room hold
the same project.

## Objects

- **Track**: identified by `P_EXT:band_oid` (`T-<user>-<time>-<n>`), never by name. Unnamed and renamed tracks are fine.
- **Item**: `P_EXT:band_oid` (`I-…`). A copy (Ctrl+drag, paste, split) carries its source's oid in its chunk, so
  any item whose oid is already used by another item gets a fresh oid on first look ("new object").
- Every object has `rev` (integer) and `by`. A change is sent as `{type="obj", obj="item"|"track"|"fx",
  oid, rev, base, chunk|props, track=<track oid>}`; deletion as `{type="obj", obj=…, oid, rev, gone=true}`.
- Receivers apply the newest `rev` per oid (ties: later time, then user id), so every machine converges.

## What travels (normalized)

- **Item**: `GetItemStateChunk` minus local lines: `SEL`, `IGUID`, take `GUID`, `POOLEDEVTS` (copies are
  unpooled), MIDI editor view state (`CFGEDITVIEW`, `CFGEDIT`, `EVTFILTER`, `KEYSNAP`, `TRACKSEL`), the active-take
  marker (wet/dry is per machine). Media paths are rewritten to `{room}/media/<file>`; recordings are copied there
  once (FLAC), receivers resolve the token to their shared folder.
- **Track**: name, folder depth, order (oid of the track above), mute/solo/phase, colour/icon, lanes
  (`I_FREEMODE`, `I_NUMFIXEDLANES`, `C_LANEPLAYS:n`, lane names, `C_LANESCOLLAPSED`), envelopes (later), and
  fader/pan unless the person has **Local mixing** on. Never: record arm, input, monitoring, height, selection.
- **FX chain**: the `<FXCHAIN>` block minus `FXID`/`FLOATPOS`/`WNDRECT`/`SHOW`, sent only when its hash changes
  (replacing a chain re-instantiates plug-ins), never while playing.

## Authority (unchanged rules, new granularity)

Driver, claims and the room mode (Driver only / Claims / Open) decide per object. A change you may not make is put
back by re-applying the newest known revision of that object (this covers copies, hand-drawn items and anything
else, not only known takes). Receivers check the same rule (deferral as before).

## Applying

- Never on a track that is recording; never mid-drag (mouse down in arrange); item changes apply during playback,
  FX chains only when stopped.
- Applies are stamped so the next watch pass doesn't echo them back as local changes (snapshot = the applied hash).

## MIDI (wet/dry per person)

The MIDI item is the truth and travels as MIDI. Its owner also renders a print (the wet sound) as a second take
whenever the notes or the instrument change. Each person picks how MIDI plays on their machine:
**Notes** (dry, own instruments), **Sound** (wet, the owner's print) or **Auto** (notes when the instrument is
installed here, else the print). The active take is local and never mirrored, so nobody's choice changes anyone
else's. Audio uses the same mechanism: a print take only when someone lacks a plug-in on that track.

## History

Every revision is History: "undo this change" re-applies the object's previous revision; "restore selection's
state" re-applies the selected tracks' (and their items') revisions as of that moment; "restore project state"
does it for every object. Each restore is itself a set of new revisions, so it can be undone the same way.
The project as it was before BandSync (the first publish/open) is kept as recall point zero.

## Offline and solo editing

Live sync is always on for BandSync projects. Work done while disconnected keeps each object's `base` (the rev it
started from). On reconnect, per object: only you changed it → yours goes out; only they did → theirs comes in;
both → theirs wins in the room, yours is kept as a recall point ("your offline version") with a one-click
"bring mine in". Solo work is a side room (rooms already do this).

## Staying identical

Each machine publishes a root hash over its normalized objects in its status file; a mismatch drills down to the
differing objects and repairs them from the newest revision (research memo pending: integrity scheme).
