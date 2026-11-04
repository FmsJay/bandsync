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
    FILE "J:\Portable Workstation\StudioSync\Lantern\rooms\main\media\bass1.flac"
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
-- a restless plug-in counts by its first line in a chain's hash; everything else as ever
do
  local function chain(blob, other)
    return '<FXCHAIN\nBYPASS 0 0 0\n<VST "VST3: Disperser (Kilohearts)" d.vst3 0 "" 1\n' .. blob .. '\nAAAA\n>\nFXID {1}\nBYPASS 0 0 0\n<VST "VST: ReaEQ (Cockos)" e.dll 0 "" 2\n' .. other .. '\nAAAA\n>\n>\n'
  end
  local blocks = mirror.plugin_blocks({ "<FXCHAIN", "BYPASS 0 0 0", '<JS a/b ""', "1 2", "<JS_SER", "abc", ">", ">", "<PARMENV 1", ">", ">" })
  assert(#blocks == 1 and blocks[1].key == "a/b" and blocks[1].first == 3 and blocks[1].last == 8, "a plug-in block, nested and all")
  assert(mirror.fx_differing(chain("x", "y"), chain("z", "y"))[1] == "VST3: Disperser (Kilohearts)", "which plug-in differs")
  assert(#mirror.fx_differing(chain("x", "y"), chain("x", "y")) == 0, "none")
  assert(mirror.restless_in(chain("x", "y")) == nil and mirror.fx_hash(chain("x", "y")) ~= mirror.fx_hash(chain("z", "y")), "before: its data counts")
  assert(mirror.restless_add({ "VST3: Disperser (Kilohearts)" }) and not mirror.restless_add({ "VST3: Disperser (Kilohearts)" }), "added once")
  assert(mirror.fx_hash(chain("x", "y")) == mirror.fx_hash(chain("z", "y")), "after: it doesn't")
  assert(mirror.fx_hash(chain("x", "y")) ~= mirror.fx_hash(chain("x", "w")), "another plug-in's still does")
  assert(mirror.restless_in(chain("x", "y"))[1] == "VST3: Disperser (Kilohearts)", "named on the chain")
  mirror.restless = {}
  -- the same bytes in different base64 pieces are the same chain; different bytes aren't
  local ab = '<VST "x" y 0 "" 1\nAAECAwQFBgc=\nCAkKCwwNDg8=\n>\n'
  local one = '<VST "x" y 0 "" 1\nAAECAwQFBgcICQoLDA0ODw==\n>\n'
  local other = '<VST "x" y 0 "" 1\nAAECAwQFBgcICQoLDA0OAA==\n>\n'
  assert(mirror.fx_same(ab, ab) and mirror.fx_same(ab, one), "re-encoded: the same")
  assert(not mirror.fx_same(ab, other), "different bytes: not the same")
end
-- which notes are selected and which lanes the MIDI editor shows are each person's: opening the editor isn't a change
local picked = "<ITEM\n<SOURCE MIDI\nHASDATA 1 960 QN\nCCINTERP 32\nVELLANE 64 100 0 0 1\ne 0 90 3c 60\nem 240 80 3c 00\nx 0 90 3e 60 0 0 0\n<x 0 0\n>\nE 0 90 40 60\n>\n>\n"
local clean = "<ITEM\n<SOURCE MIDI\nHASDATA 1 960 QN\nCCINTERP 32\nE 0 90 3c 60\nEm 240 80 3c 00\nX 0 90 3e 60 0 0 0\n<X 0 0\n>\nE 0 90 40 60\n>\n>\n"
assert(mirror.normalize_item(picked) == mirror.normalize_item(clean), "selection and view are local: " .. mirror.normalize_item(picked))
assert(mirror.normalize_item(mirror.normalize_item(picked)) == mirror.normalize_item(clean), "normalizing twice changes nothing")
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
local tok = mirror.tokenize_media(item, "J:/Portable Workstation/StudioSync/Lantern/rooms/main/media")
assert(tok:find('FILE "{media:main}/bass1.flac"'), "tokenized: " .. tok:match('FILE "[^"]*"'))
local mac = mirror.resolve_media(tok, "/Volumes/X/StudioSync/Lantern/rooms/main/media/")
assert(mac:find('FILE "/Volumes/X/StudioSync/Lantern/rooms/main/media/bass1.flac"'), "resolved")
assert(mirror.media_needed(tok, "/V/StudioSync/Lantern/rooms/main/media")[1] == "/V/StudioSync/Lantern/rooms/main/media/bass1.flac", "needed list")
assert(mirror.tokenize_media('FILE "C:/elsewhere/x.wav"', "J:/m/rooms/main/media"):find("C:/elsewhere"), "outside the song stays")
-- a side room's copy of main's item keeps pointing at main's media: the same token from either room (not a change)
local side_tok = mirror.tokenize_media(item, "J:/Portable Workstation/StudioSync/Lantern/rooms/try this/media")
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

-- a plug-in's program block (its state's last line) gets the program name once loaded: not a difference
local eq1 = '<FXCHAIN\nBYPASS 0 0 0\n<VST "VST: ReaEQ (Cockos)" reaeq.dll 0 ""\nZXFlcu5e7f4CAAAA\nAAAQAAAA\n>\nWAK 0 0\n>\n'
local eq2 = eq1:gsub("AAAQAAAA", "AFByb2dyYW0gMQAQAAAA")
assert(mirror.fx_hash(eq1) == mirror.fx_hash(eq2), "ReaEQ's 'Program 1' isn't a change")
assert(mirror.fx_hash(eq1) ~= mirror.fx_hash((eq1:gsub("ZXFlcu5e7f4CAAAA", "ZXFlcu5e7f4DAAAA"))), "a real state change still is")
-- the same as an item's take FX (block K: the projects differed for good); items without one hash as they always did
local item1 = "POSITION 13.8\nLENGTH 2\n<TAKEFX\nWNDRECT 0 0 0 0\n<VST \"VST: ReaEQ (Cockos)\" reaeq.dll 0 \"\"\nZXFlcu5e7f4CAAAA\nAAAQAAAA\n>\nWAK 0 0\n>\n<SOURCE MIDI\n>"
local item2 = item1:gsub("AAAQAAAA", "AFByb2dyYW0gMQAQAAAA")
assert(mirror.item_hash("T-1", item1) == mirror.item_hash("T-1", item2), "a take FX's 'Program 1' isn't a change")
assert(mirror.item_hash("T-1", item1) ~= mirror.item_hash("T-1", (item1:gsub("ZXFlcu5e7f4CAAAA", "ZXFlcu5e7f4DAAAA"))), "its real state is")
assert(mirror.item_hash("T-1", item1) ~= mirror.item_hash("T-2", item1), "the track still counts")
local plain = "POSITION 1\nLENGTH 2\n<SOURCE WAVE\nFILE \"a.flac\"\n>"
assert(mirror.item_hash("T-1", plain) == mirror.hash("T-1\n" .. plain), "no VST: the hash it always had (no resend after updating)")
-- a print StudioSync refreshed by itself isn't the person's change: Undo reaches past it to the copy they made
local P = { { kind = "obj", user = "J", id = "copy" }, { kind = "obj", user = "J", id = "reprint", auto = true } }
assert(mirror.last_mine(P, "J") == 1, "Undo skips an automatic print refresh")
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

-- a clash: Bee's offline edit (rev 2, from rev 1) lands after James's newer revision 3; the band kept James's
local C = {
  { kind = "obj", oid = "I-X-1", id = "c1", rev = 1, time = "2026-10-31T10:00:00Z", user = "James" },
  { kind = "obj", oid = "I-X-1", id = "c2", rev = 2, time = "2026-10-31T10:01:00Z", user = "James" },
  { kind = "obj", oid = "I-X-1", id = "c3", rev = 3, time = "2026-10-31T10:02:00Z", user = "James" },
  { kind = "obj", oid = "I-X-1", id = "c4", rev = 2, time = "2026-10-31T10:05:00Z", user = "Bee" }, -- (the loser)
}
assert(mirror.plan_restore(C, 4)["I-X-1"].id == "c3", "restore to now: the band's version, not the later loser")
assert(mirror.plan_restore(C, 2)["I-X-1"].id == "c2", "restore to a point before the clash")
assert(mirror.plan_undo(C, 3)["I-X-1"].id == "c2", "undo James's rev 3: back to rev 2 (his), not Bee's losing rev 2")

local a, b = mirror.new_oid("I", "Big Al", "20261030"), mirror.new_oid("I", "Big Al", "20261030")
assert(a ~= b and a:find("^I%-BIG_AL%-20261030%-"), "oids unique, upper case: " .. a)
-- one chain or item as a Mac and as Windows writes it (from the Mac's first join, 0.34.3): the same once portable
local win = '<VST "VSTi: ReaSynth (Cockos)" reasynth.dll 0 "" 1919251321<5653547265737972656173796E746800> ""\n' ..
  '<VST "VST3: Surge XT (Surge Synth Team)" "Surge XT.vst3" 0 "" 1<0> ""\nCOLOR 26973901 R\nTAKECOLOR 16777471 R\n'
local mac = '<VST "VSTi: ReaSynth (Cockos)" reasynth.vst.dylib 0 "" 1919251321<5653547265737972656173796E746800> ""\n' ..
  '<VST "VST3: Surge XT (Surge Synth Team)" "Surge XT.vst3" 0 "" 1<0> ""\nCOLOR 30250651 B\nTAKECOLOR 33488896 B\n'
assert(mirror.portable(mac) == win, "a Mac's plug-in files and colours read as Windows'")
assert(mirror.portable(win) == win, "Windows' text is left exactly as it was (no hash moves)")
assert(mirror.portable('<VST "VST: Dexed" Dexed.vst 0 ""\n') == '<VST "VST: Dexed" Dexed.dll 0 ""\n', "a macOS VST2 bundle")
assert(mirror.fx_hash(mac) == mirror.fx_hash(win) and mirror.item_hash("T", mac) == mirror.item_hash("T", win), "hashes agree")

-- one act, one row: a delete that reached a copy in a comp lane undoes both; another person's, or another second's, doesn't count
do
  local M = {
    { kind = "obj", obj = "item", oid = "I-1", id = "a1", user = "L", time = "T1", rev = 1, name = "Bass" },
    { kind = "obj", obj = "item", oid = "I-2", id = "a2", user = "L", time = "T1", rev = 1, name = "Bass" },
    { kind = "obj", obj = "item", oid = "I-1", id = "g1", user = "L", time = "T2", rev = 2, name = "Bass", gone = true },
    { kind = "obj", obj = "item", oid = "I-2", id = "g2", user = "L", time = "T2", rev = 2, name = "Bass", gone = true },
    { kind = "obj", obj = "item", oid = "I-3", id = "g3", user = "M", time = "T2", rev = 2, name = "Bass", gone = true },
    { kind = "obj", obj = "item", oid = "I-4", id = "g4", user = "L", time = "T3", rev = 2, name = "Bass", gone = true },
    { kind = "note", id = "n", user = "L", time = "T3" },
  }
  assert(#mirror.same_moment(M, 3) == 2 and #mirror.same_moment(M, 4) == 2, "the two deletes are one act, whichever row")
  assert(#mirror.same_moment(M, 5) == 1 and #mirror.same_moment(M, 6) == 1, "not another person's, nor another second's")
  assert(#mirror.same_moment(M, 7) == 1, "only changes count")
  assert(mirror.item_hash("T", "YPOS 0 0.1 2\nBANDLANE 1\n") == mirror.item_hash("T", "YPOS 0 0.2 2\nBANDLANE 1\n"), "on a lane YPOS doesn't count")
  assert(mirror.item_hash("T", "YPOS 0 0.1 2\n") ~= mirror.item_hash("T", "YPOS 0 0.2 2\n"), "free-positioned, it does")
  -- a glue: two parts gone and a new one made, in one second. Undone, the new one goes and both come back
  local G = {
    { kind = "obj", obj = "item", oid = "I-1", id = "a1", user = "L", time = "T1", rev = 1, name = "Bass" },
    { kind = "obj", obj = "item", oid = "I-2", id = "a2", user = "L", time = "T1", rev = 1, name = "Bass" },
    { kind = "obj", obj = "item", oid = "I-1", id = "g1", user = "L", time = "T2", rev = 2, name = "Bass", gone = true },
    { kind = "obj", obj = "item", oid = "I-2", id = "g2", user = "L", time = "T2", rev = 2, name = "Bass", gone = true },
    { kind = "obj", obj = "item", oid = "I-9", id = "n9", user = "L", time = "T2", rev = 1, name = "Bass" },
  }
  local glue = mirror.plan_undo_moment(G, 3)
  assert(glue["I-1"].id == "a1" and glue["I-2"].id == "a2" and glue["I-9"] == false, "undoing a glue from any of its rows")
  -- a print finishing after an undo leaves it redoable; a real change doesn't
  local R = {
    { kind = "obj", oid = "I-1", id = "c", user = "L", rev = 1 },
    { kind = "obj", oid = "I-1", id = "u", user = "L", rev = 2, undoes = "c", restored = "x" },
    { kind = "obj", oid = "I-2", id = "p", user = "L", rev = 2, auto = true },
  }
  assert(mirror.last_undo(R, "L") == 2, "a print after the undo: still redoable")
  R[4] = { kind = "obj", oid = "I-2", id = "n", user = "L", rev = 3 }
  assert(mirror.last_undo(R, "L") == nil, "a new change after it: nothing to redo")
  -- which tracks moved
  local function moved(old, new, sel)
    local s = {}
    for _, x in ipairs(sel or {}) do s[x] = true end
    local names = {}
    for x in pairs(mirror.moved_tracks(old, new, s)) do names[#names + 1] = x end
    table.sort(names)
    return table.concat(names, ",")
  end
  assert(moved({ "a", "b", "c" }, { "a", "b", "c", "n" }) == "", "one added at the end moves nobody")
  assert(moved({ "a", "b", "c" }, { "a", "n", "b", "c" }) == "", "one added in the middle moves nobody, whatever now sits above b")
  assert(moved({ "a", "b", "c" }, { "a", "c" }) == "", "one gone moves nobody")
  assert(moved({ "a", "b", "c", "d" }, { "b", "c", "d", "a" }) == "a", "dragged to the end: only it")
  assert(moved({ "a", "b", "c", "d" }, { "d", "a", "b", "c" }) == "d", "dragged to the top: only it")
  assert(moved({ "a", "b" }, { "b", "a" }, { "b" }) == "b", "two swapped: the selected one")
  assert(moved({ "a", "b" }, { "b", "a" }, { "a" }) == "a", "whichever that is")
  assert(moved({ "a", "b", "c" }, { "a", "b", "c" }, { "b" }) == "", "selected and not moved")
  -- by lane: a pass and its copies in the comp are separate acts; a glue on one lane is one
  local function on(lane) return "<ITEM\nBANDLANE " .. lane .. "\n" end
  local L = {
    { kind = "obj", obj = "item", oid = "I-P", id = "a", user = "M", time = "T1", rev = 1, name = "Lead", state = on(3) },
    { kind = "obj", obj = "item", oid = "I-C", id = "b", user = "M", time = "T1", rev = 1, name = "Lead", state = on(0) },
    { kind = "obj", obj = "item", oid = "I-D", id = "c", user = "M", time = "T1", rev = 1, name = "Lead", state = on(0) },
    { kind = "obj", obj = "item", oid = "I-P", id = "gp", user = "M", time = "T2", rev = 2, name = "Lead", gone = true },
    { kind = "obj", obj = "item", oid = "I-C", id = "gc", user = "M", time = "T2", rev = 2, name = "Lead", gone = true },
    { kind = "obj", obj = "item", oid = "I-D", id = "gd", user = "M", time = "T2", rev = 2, name = "Lead", gone = true },
    { kind = "obj", obj = "item", oid = "I-N", id = "n", user = "M", time = "T2", rev = 1, name = "Lead", state = on(0) },
  }
  assert(mirror.entry_lane(L, 1) == 3 and mirror.entry_lane(L, 4) == 3, "a delete sits on the lane its item had last")
  assert(#mirror.same_moment(L, 4) == 1, "the pass is its own row")
  assert(#mirror.same_moment(L, 5) == 3, "its two copies and what was made on that lane are one act")
  local copies = mirror.plan_undo_moment(L, 5)
  assert(copies["I-P"] == nil and copies["I-C"].id == "b" and copies["I-D"].id == "c" and copies["I-N"] == false, "and undoing them leaves the pass alone")
  assert(mirror.plan_undo_moment(L, 4)["I-P"].id == "a" and mirror.plan_undo_moment(L, 4)["I-C"] == nil, "undoing the pass leaves the comp alone")
  -- a row names the lane as it was then, whatever has been added since
  local function lanes(t, rev, n, names) return { kind = "obj", obj = "track", oid = "T-1", id = "t" .. rev, user = "M", time = t, rev = rev, state = { lanes = n, lanenames = names } } end
  local N = {
    lanes("T1", 1, 3, "Pass 1,Pass 2,Pass 3"),
    { kind = "obj", obj = "item", oid = "I-A", id = "a", user = "M", time = "T2", rev = 1, track = "T-1", state = on(1) },
    { kind = "obj", obj = "item", oid = "I-B", id = "b", user = "M", time = "T3", rev = 1, track = "T-1", state = on(1) },
    lanes("T3", 2, 3, "C1,Pass 1,Pass 2"), -- (its event just after its item's, the same second)
    lanes("T4", 3, 4, "C2,C1,Pass 1,Pass 2"),
    { kind = "obj", obj = "item", oid = "I-A", id = "ga", user = "M", time = "T5", rev = 2, track = "T-1", gone = true },
    { kind = "obj", obj = "item", oid = "I-C", id = "c", user = "M", time = "T6", rev = 1, track = "T-X", state = on(4) },
    { kind = "obj", obj = "item", oid = "I-D", id = "d", user = "M", time = "T7", rev = 1, track = "T-1", state = "<ITEM\n" },
  }
  assert(mirror.lane_words(N, 2) == " (lane Pass 2)", "by the names then: " .. mirror.lane_words(N, 2))
  assert(mirror.lane_words(N, 3) == " (lane Pass 1)", "with the track's event in the same second: " .. mirror.lane_words(N, 3))
  assert(mirror.lane_words(N, 6) == " (lane Pass 2)", "a delete, by when its item last had a lane: " .. mirror.lane_words(N, 6))
  assert(mirror.lane_words(N, 7) == " (lane 5)", "no track event to read: its number")
  assert(mirror.lane_words(N, 8) == "", "not on a lane: nothing")
  local S = { lanes("T1", 1, 1, ""), { kind = "obj", obj = "item", oid = "I-A", id = "a", user = "M", time = "T2", rev = 1, track = "T-1", state = on(0) } }
  assert(mirror.lane_words(S, 2) == "", "a track with one lane: nothing to say")
  assert(mirror.rounded("<ITEM\nPOSITION 108.46153846154\nLENGTH 9.23076923076923\n") == mirror.rounded("<ITEM\nPOSITION 108.46153846154\nLENGTH 9.23076923076927\n"), "a 14th digit is arithmetic")
  assert(mirror.rounded("<ITEM\nPOSITION 1\nLENGTH 9.25\n") ~= mirror.rounded("<ITEM\nPOSITION 1\nLENGTH 9.26\n"), "a real change isn't")
  local playing, holds = mirror.lane_cover({ { pos = 30, len = 60, plays = false }, { pos = 32, len = 8, plays = true }, { pos = 30, len = 60, plays = false } })
  assert(playing == 8 and holds == 60, "the first comp holds 8 s of 60: " .. playing .. " of " .. holds)
  local all, whole = mirror.lane_cover({ { pos = 0, len = 10, plays = true }, { pos = 5, len = 10, plays = true }, { pos = 20, len = 5, plays = true } })
  assert(all == 20 and whole == 20, "overlaps count once")
  local plan = mirror.plan_undo_moment(M, 4)
  assert(plan["I-1"].id == "a1" and plan["I-2"].id == "a2", "Undo on either row brings both back")
end
do -- a state read here has floats, one from a bandmate's event can have whole numbers: the same settings (0.45: a track that had only moved was put back and suggested at every restart)
  local real_own = mirror.own_colours
  mirror.own_colours = function() return false end
  local here = { name = "Keys", depth = 0.0, mute = 0.0, phase = 0.0, freemode = 0.0, lanes = 1.0, vol = "1.000000", color = 16576, after = "x" }
  local theirs = { name = "Keys", depth = 0, mute = 0, phase = 0, freemode = 0, lanes = 1, vol = "1.000000", color = 16576, after = "y" }
  assert(mirror.same_line(here, theirs, false), "0 and 0.0 are one number, and the place in the list isn't in it")
  theirs.mute = 1
  assert(not mirror.same_line(here, theirs, false), "a real difference still is one")
  theirs.mute, theirs.vol = 0, "0.500000"
  assert(not mirror.same_line(here, theirs, false), "a fader too")
  theirs.vol, theirs.name = "1.000000", "Keys 1.0"
  here.name = "Keys 1"
  assert(not mirror.same_line(here, { name = "Keys 2", depth = 0 }, false), "other names differ")
  mirror.own_colours = real_own
end
do -- a label a print adds, which REAPER takes off a comp piece on opening, isn't a change; anything else is
  assert(mirror.same_but_labels('POSITION 1\nNAME "dry - pass 2"\nNAME "wet - pass 2"', 'POSITION 1\nNAME "pass 2"\nNAME "pass 2"'), "only the labels")
  assert(not mirror.same_but_labels('POSITION 1\nNAME "dry - pass 2"', 'POSITION 2\nNAME "pass 2"'), "moved too")
  assert(not mirror.same_but_labels('NAME "dry - pass 2"', 'NAME "pass 3"'), "another name")
end
print("ok")
