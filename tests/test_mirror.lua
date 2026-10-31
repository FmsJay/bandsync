-- mirror.lua's pure half: normalizing chunks, FX chains, hashing, ordering, merging, media tokens
package.path = "lib/?.lua;" .. package.path
local mirror = require("mirror")

local item = [[<ITEM
  POSITION 4
  SNAPOFFS 0
  LENGTH 2
  LOOP 1
  ALLTAKES 0
  FADEIN 1 0 0 1 0 0 0
  FADEOUT 1 0 0 1 0 0 0
  MUTE 0 0
  SEL 1
  IGUID {AAAA}
  IID 7
  <EXT
    band_oid I-James-1
    band_sent James-20261030-1
    band_m_print 1
  >
  NAME bass
  TAKE SEL
  NAME print
  <SOURCE WAVE
    FILE "J:\Portable Workstation\BandSync\Lantern\rooms\main\media\bass1.flac"
  >
  GUID {BBBB}
  <SOURCE MIDI
    HASDATA 1 960 QN
    POOLEDEVTS {CCCC}
    E 0 90 28 64
    CFGEDITVIEW 0 0 0 0
    GUID {DDDD}
  >
>]]
local n = mirror.normalize_item(item)
assert(not n:find("SEL 1") and not n:find("IGUID") and not n:find("IID") and not n:find("GUID"), "local ids and selection go")
assert(not n:find("POOLEDEVTS") and not n:find("CFGEDITVIEW"), "pooling and editor view go")
assert(n:find("band_oid I%-James%-1") and n:find("band_m_print 1") and not n:find("band_sent"), "only travelling EXT keys stay")
assert(n:find("\nTAKE\n") and not n:find("TAKE SEL"), "active take is local")
assert(n:find("E 0 90 28 64"), "notes stay")
-- the same item on another machine (other ids, other selection) normalizes to the same bytes
local other = item:gsub("SEL 1", "SEL 0"):gsub("{AAAA}", "{ZZZZ}"):gsub("IID 7", "IID 2"):gsub("band_sent James%-20261030%-1", "band_take x")
assert(mirror.normalize_item(other) == n, "same item elsewhere, same bytes")
assert(mirror.hash(n) == mirror.hash(mirror.normalize_item(other)) and #mirror.hash(n) == 8, "hash")
-- a pooled MIDI item (after a Ctrl+drag copy) reads the same as its plain copy on the other side
local pooled = "<ITEM\nPOSITION 0\nPOOLCOLOR 57375313 R\n<SOURCE MIDIPOOL\nHASDATA 1 960 QN\nPOOLEDEVTS {P1}\nE 0 90 3c 60\n>\n>\n"
local plain = "<ITEM\nPOSITION 0\nPOOLCOLOR 40598097 R\n<SOURCE MIDI\nHASDATA 1 960 QN\nE 0 90 3c 60\n>\n>\n"
assert(mirror.normalize_item(pooled) == mirror.normalize_item(plain), "MIDI pooling is local: " .. mirror.normalize_item(pooled))
assert(mirror.hash("a") ~= mirror.hash("b"), "hash tells apart")
-- an <EXT> with nothing that travels disappears
local bare = mirror.normalize_item("<ITEM\nPOSITION 1\n<EXT\nband_sent x\n>\n>")
assert(not bare:find("EXT"), "empty EXT dropped: " .. bare)
-- REAPER writes an item's own P_EXT as <EXTI (seen in REAPER 7.83)
local exti = mirror.normalize_item("<ITEM\nPOSITION 1\n<EXTI\nband_oid I-x\nband_sent y\n>\n>")
assert(exti:find("<EXTI\nband_oid I%-x\n>") and not exti:find("band_sent"), "EXTI filtered: " .. exti)
assert(not mirror.normalize_item("<ITEM\n<EXTI\nband_sent y\n>\n>"):find("EXTI"), "empty EXTI dropped")

-- FX chain: window state and ids go; a local translation (by FXID) can be left out
local tr = [[<TRACK {T1}
  NAME Bass
  <FXCHAIN
    WNDRECT 1 2 3 4
    SHOW 0
    LASTSEL 0
    DOCKED 0
    BYPASS 0 0 0
    <VST "VST: ReaEQ (Cockos)" reaeq.dll 0 "" 1919247729<...>
      ZXE=
    >
    FLOATPOS 0 0 0 0
    FXID {F1}
    WAK 0 0
    BYPASS 0 0 0
    <JS "my translation" ""
      1 2 3
    >
    FLOATPOS 0 0 0 0
    FXID {F2}
    WAK 0 0
  >
  <ITEM
    POSITION 1
  >
>]]
local fx = mirror.fxchain(tr)
assert(fx:find("^<FXCHAIN\n") and fx:find("ReaEQ") and fx:find("my translation"), "chain kept")
assert(not fx:find("WNDRECT") and not fx:find("FXID") and not fx:find("FLOATPOS") and not fx:find("SHOW"), "window state and ids go")
assert(not fx:find("POSITION 1"), "stops at the chain's end")
local fx2 = mirror.fxchain(tr, { ["{F2}"] = true })
assert(fx2:find("ReaEQ") and not fx2:find("my translation"), "local translation left out")
assert(fx2:sub(-2) == ">\n", "closing kept")
assert(mirror.fxchain("<TRACK\nNAME x\n>") == nil, "no chain")

-- ordering: rev, then time, then user
assert(mirror.newer({ rev = 3 }, { rev = 2 }) and not mirror.newer({ rev = 2 }, { rev = 3 }), "rev wins")
assert(mirror.newer({ rev = 2, time = "b" }, { rev = 2, time = "a" }), "then time")
assert(mirror.newer({ rev = 2, time = "a", user = "Z" }, { rev = 2, time = "a", user = "A" }), "then user")
assert(mirror.newer({ rev = 1 }, nil) and not mirror.newer(nil, { rev = 1 }), "nil")

-- three-way
assert(mirror.merge3("a", "a", "a") == "same")
assert(mirror.merge3("a", "a", "b") == "take")
assert(mirror.merge3("a", "b", "a") == "send")
assert(mirror.merge3("a", "b", "c") == "both")
assert(mirror.merge3("a", "b", "b") == "same")

-- media tokens: Windows path in, Mac path out
local tok = mirror.tokenize_media(item, "J:/Portable Workstation/BandSync/Lantern/rooms/main/media")
assert(tok:find('FILE "{media:main}/bass1.flac"'), "tokenized: " .. tok:match('FILE "[^"]*"'))
local mac = mirror.resolve_media(tok, "/Volumes/X/BandSync/Lantern/rooms/main/media/")
assert(mac:find('FILE "/Volumes/X/BandSync/Lantern/rooms/main/media/bass1.flac"'), "resolved")
assert(mirror.media_needed(tok, "/V/BandSync/Lantern/rooms/main/media")[1] == "/V/BandSync/Lantern/rooms/main/media/bass1.flac", "needed list")
assert(mirror.tokenize_media('FILE "C:/elsewhere/x.wav"', "J:/m/rooms/main/media"):find("C:/elsewhere"), "outside the song stays")
-- a side room's copy of main's item keeps pointing at main's media: the same token from either room (not a change)
local side_tok = mirror.tokenize_media(item, "J:/Portable Workstation/BandSync/Lantern/rooms/try this/media")
assert(side_tok == tok, "same token from a side room")
assert(mirror.resolve_media(side_tok, "J:/B/Lantern/rooms/try this/media"):find('FILE "J:/B/Lantern/rooms/main/media/bass1.flac"'), "resolves to main's media")
assert(mirror.resolve_media('FILE "{media}/old.flac"', "J:/B/S/rooms/main/media"):find('J:/B/S/rooms/main/media/old.flac'), "older token: this room")

-- History plans
local E = {
  { kind = "obj", obj = "track", oid = "T-A-1-1", rev = 1, id = "e1", state = "t1" },
  { kind = "obj", obj = "item", oid = "I-A-1-2", rev = 1, id = "e2", track = "T-A-1-1", state = "pos1" },
  { kind = "edit", id = "legacy" },
  { kind = "obj", obj = "item", oid = "I-A-1-2", rev = 2, id = "e3", track = "T-A-1-1", state = "pos2" },
  { kind = "obj", obj = "item", oid = "I-B-1-3", rev = 1, id = "e4", track = "T-A-1-1", state = "new" },
  { kind = "obj", obj = "item", oid = "I-A-1-2", rev = 3, id = "e5", gone = true },
}
local plan = mirror.plan_restore(E, 2)
assert(plan["I-A-1-2"].id == "e2" and plan["T-A-1-1"].id == "e1", "as after entry 2")
assert(plan["I-B-1-3"] == false, "made later: goes")
plan = mirror.plan_restore(E, 4, function(oid, last) return oid == "I-A-1-2" end)
assert(plan["I-A-1-2"].id == "e3" and plan["T-A-1-1"] == nil, "scope")
plan = mirror.plan_restore(E, 6)
assert(plan["I-A-1-2"] == false, "deleted by then")
assert(mirror.plan_undo(E, 4)["I-A-1-2"].id == "e2", "undo a move: the revision before")
assert(mirror.plan_undo(E, 5)["I-B-1-3"] == false, "undo an add: it goes")
assert(mirror.plan_undo(E, 6)["I-A-1-2"].id == "e3", "undo a delete: it comes back")
assert(mirror.plan_undo(E, 3) == nil, "not a mirror change")
assert(mirror.creator("I-BIG_AL-20261030-4") == "BIG_AL" and mirror.creator("T-A-1-1") == "A", "creator")
assert(mirror.user_tag("Big Al") == "BIG_AL", "user tag")

-- top bar Undo / Redo: your own changes only
local U = {
  { kind = "obj", user = "J", id = "c1" }, { kind = "obj", user = "B", id = "b1" }, { kind = "obj", user = "J", id = "c2" },
}
assert(mirror.last_mine(U, "J") == 3, "undo: my newest")
assert(mirror.last_undo(U, "J") == nil, "nothing to redo yet")
U[4] = { kind = "obj", user = "J", id = "u1", undoes = "c2", restored = "c1" }
assert(mirror.last_mine(U, "J") == 1, "undo again: the one before")
assert(mirror.last_undo(U, "J") == 4, "redo: my newest undo")
U[5] = { kind = "obj", user = "J", id = "r1", redoes = "u1", restored = "x" }
assert(mirror.last_mine(U, "J") == 3, "after redo, c2 counts again")
assert(mirror.last_undo(U, "J") == nil, "redone: nothing left to redo")
U[6] = { kind = "obj", user = "J", id = "c3" }
assert(mirror.last_undo(U, "J") == nil and mirror.last_mine(U, "J") == 6, "a new change ends redo")

-- side room into its parent: only-side changes come in (tracks first), both-changed are clashes
local side = { ["I-1"] = { obj = "item", oid = "I-1" }, ["T-9"] = { obj = "track", oid = "T-9" }, ["I-2"] = { obj = "item", oid = "I-2" } }
local main = { ["I-2"] = { obj = "item", oid = "I-2" } }
local bring, clash = mirror.plan_bring(side, main)
assert(#bring == 2 and bring[1].obj == "track" and #clash == 1 and clash[1].oid == "I-2", "bring plan")

-- envelopes and receives: cut out of a track chunk, spliced back, the same again; positions travel as oids
local trk = [[<TRACK
  NAME Keys
  MAINSEND 1 0
  AUXRECV 0 0 0.5 0 0 0 0 0 0 -1:U 0 -1 ''
  <AUXVOLENV
    EGUID {S1}
    ACT 1 -1
    VIS 1 1 1
    ARM 0
    PT 0 1 0
  >
  AUXRECV 2 0 1 0 0 0 0 0 0 -1:U 0 -1 ''
  <VOLENV2
    EGUID {E1}
    ACT 1 -1
    VIS 0 1 1
    LANEHEIGHT 40 0
    ARM 1
    PT 0 1 0
    PT 2 0.5 0
  >
  <FXCHAIN
    SHOW 0
  >
  <ITEM
    POSITION 0
  >
>
]]
local at = { [0] = "T-BASS-1", [1] = "T-KEYS-1" } -- position 2 is the Real time track: not mirrored
local function oid_at(i) return at[i] end
local env, recv = mirror.track_parts(trk, oid_at)
assert(env == "<VOLENV2\nACT 1 -1\nPT 0 1 0\nPT 2 0.5 0\n>\n", "envelope without its view lines: " .. env)
assert(recv == "AUXRECV T-BASS-1 0 0.5 0 0 0 0 0 0 -1:U 0 -1 ''\n<AUXVOLENV\nACT 1 -1\nPT 0 1 0\n>\n", "mirrored receive, by oid: " .. recv)
-- a bandmate's version: the envelope moved, the receive now comes from Bass at another position here
local their_env = "<VOLENV2\nACT 1 -1\nPT 0 1 0\nPT 4 0.25 0\n>\n"
local spliced = mirror.splice_parts(trk, "env", their_env, function() end, oid_at)
local e2 = mirror.track_parts(spliced, oid_at)
assert(e2 == their_env, "envelope spliced in: " .. e2)
assert(spliced:find("VIS 0 1 1", 1, true) and spliced:find("LANEHEIGHT 40 0", 1, true) and spliced:find("ARM 1", 1, true), "view lines kept")
assert(spliced:find("<FXCHAIN", 1, true) and spliced:find("<ITEM", 1, true) and select(2, spliced:gsub("AUXRECV", "")) == 2, "the rest untouched")
local pos = { ["T-BASS-1"] = 0, ["T-DRUMS-1"] = 1 }
local their_recv = "AUXRECV T-DRUMS-1 0 1 0 0 0 0 0 0 -1:U 0 -1 ''\n"
local r2 = mirror.splice_parts(trk, "recv", their_recv, function(o) return pos[o] end, oid_at)
assert(select(2, r2:gsub("\n%s*AUXRECV 1 0 1 0", "")) == 1, "the new receive, at its source's position here")
assert(select(2, r2:gsub("\n%s*AUXRECV 2 ", "")) == 1, "the receive from the Real time track stays")
assert(not r2:find("AUXRECV 0 ", 1, true) and not r2:find("<AUXVOLENV", 1, true), "the old receive and its envelope went")
assert(mirror.splice_parts(trk, "recv", "AUXRECV T-NOT-HERE 0 1 0 0 0 0 0 0 -1:U 0 -1 ''\n", function(o) return pos[o] end, oid_at) == nil,
  "a source that hasn't arrived: try later")
local fresh = mirror.splice_parts("<TRACK\n  NAME x\n  <FXCHAIN\n  >\n>\n", "env", their_env, function() end, oid_at)
assert(fresh:find("<VOLENV2\nVIS 1 1 1\n", 1, true) and fresh:find("VOLENV2") < fresh:find("FXCHAIN"), "a new envelope shows, before the plug-ins: " .. fresh)

-- the track's other settings: group/VCA flags, lock, input FX (without its window lines), note names
local trk2 = "<TRACK\n  NAME Gtr\n  LOCK 1\n  GROUP_FLAGS 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0\n  <FXCHAIN_REC\n    SHOW 0\n    LASTSEL 0\n" ..
  "    DOCKED 0\n    BYPASS 0 0 0\n    <JS amp\n      0.5\n    >\n    FLOATPOS 10 10 300 200\n    FXID {X}\n    WAK 0 0\n  >\n" ..
  "  <MIDINOTENAMES\n    -1 36 Kick\n  >\n  <FXCHAIN\n    SHOW 0\n  >\n>\n"
local _, _, misc = mirror.track_parts(trk2, oid_at)
assert(misc == "LOCK 1\nGROUP_FLAGS 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0\n<FXCHAIN_REC\nBYPASS 0 0 0\n<JS amp\n0.5\n>\nWAK 0 0\n>\n" ..
  '<MIDINOTENAMES\n-1 36 "Kick"\n>\n', "misc part: " .. misc)
-- note names: cleared ones ("") are the same as none; quoted or bare, the same name
local nn = mirror.note_names('<MIDINOTENAMES\n-1 36 Kick 0 36\n-1 38 "Snare rim" 0 38\n9 42 "" 0 42\n>\n')
assert(nn["-1 36"] == "Kick" and nn["-1 38"] == "Snare rim" and nn["9 42"] == nil, "note names parsed")
local unlocked = misc:gsub("LOCK 1\n", "")
local m2 = mirror.splice_parts(trk2, "misc", unlocked, function() end, oid_at)
assert(select(3, mirror.track_parts(m2, oid_at)) == unlocked and not m2:find("LOCK", 1, true), "misc spliced: unlocked")
assert(m2:find("<FXCHAIN\n", 1, true) and m2:find("NAME Gtr", 1, true), "the rest kept")
-- a take plug-in's window opened or moved is not a change to the item
local tfx = "<ITEM\nPOSITION 0\n<TAKEFX\nSHOW 0\nLASTSEL 0\nDOCKED 0\nBYPASS 0 0 0\n<JS eq\n1\n>\nFLOATPOS 0 0 0 0\nFXID {A}\nWAK 0 0\n>\n>\n"
local tfx2 = tfx:gsub("SHOW 0", "SHOW 1"):gsub("FLOATPOS 0 0 0 0", "FLOATPOS 50 60 400 300"):gsub("{A}", "{B}")
assert(mirror.normalize_item(tfx) == mirror.normalize_item(tfx2), "take FX windows are local: " .. mirror.normalize_item(tfx2))
assert(mirror.normalize_item(tfx):find("<JS eq\n1\n>", 1, true), "the take plug-in itself travels")
-- the master's live link (ReaNINJAM/SonoBus) is kept out of what travels, and kept when the band's chain lands
local mch = "<TRACK\n<FXCHAIN\nSHOW 0\nBYPASS 0 0 0\n<JS limiter\n1\n>\nFXID {LIM}\nWAK 0 0\nBYPASS 0 0 0\n<VST reaninjam\nAAA=\n>\nFXID {NJ}\nWAK 0 0\n>\n>\n"
local kept = mirror.fx_blocks(mch, { ["{NJ}"] = true })
assert(table.concat(kept, "|") == "BYPASS 0 0 0|<VST reaninjam|AAA=|>|FXID {NJ}|WAK 0 0", "live plug-in block: " .. table.concat(kept, "|"))
assert(not mirror.fxchain(mch, { ["{NJ}"] = true }):find("reaninjam", 1, true), "the live link never travels")
assert(#mirror.fx_blocks(mch, {}) == 0, "nothing kept when there is no live link")
-- the plug-ins a chain uses, for the song chooser's preview
local names = mirror.fx_names('<FXCHAIN\nBYPASS 0 0 0\n<VST "VST3: ReaEQ (Cockos)" reaeq.vst3 0 ""\nAAA=\n>\n' ..
  'BYPASS 0 0 0\n<JS utility/volume ""\n0\n>\nBYPASS 0 0 0\n<CLAP "CLAPi: Surge XT (Surge Synth Team)" org.surge\n>\n>\n')
assert(table.concat(names, "|") == "VST3: ReaEQ (Cockos)|JS: utility/volume|CLAPi: Surge XT (Surge Synth Team)", "plug-in names: " .. table.concat(names, "|"))
-- automation items travel as their own lines: never spliced into the chunk
local withai = "<VOLENV2\nACT 1 -1\nPT 0 1 0\n>\nBANDAI VOLENV2 1 2 0 1 0.5 0 1 0\nBANDAIPT VOLENV2 0 1 0.5 0 0\n"
local sai = mirror.splice_parts("<TRACK\n<FXCHAIN\n>\n>\n", "env", withai, function() end, oid_at)
assert(not sai:find("BANDAI", 1, true) and sai:find("PT 0 1 0", 1, true), "automation item lines stay out of the chunk")
assert(mirror.track_parts("<TRACK\n<VOLENV2\nACT 1 -1\nPOOLEDENVINST 1 1 2 0 1 0 0 0 1 0 0\nPT 0 1 0\n>\n>\n", oid_at) == "<VOLENV2\nACT 1 -1\nPT 0 1 0\n>\n",
  "an envelope's pool references are this machine's")

local a, b = mirror.new_oid("I", "Big Al", "20261030"), mirror.new_oid("I", "Big Al", "20261030")
assert(a ~= b and a:find("^I%-BIG_AL%-20261030%-"), "oids unique, upper case: " .. a)
print("ok")
