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
assert(tok:find('FILE "{media}/bass1.flac"'), "tokenized: " .. tok:match('FILE "[^"]*"'))
local mac = mirror.resolve_media(tok, "/Volumes/X/BandSync/Lantern/rooms/main/media/")
assert(mac:find('FILE "/Volumes/X/BandSync/Lantern/rooms/main/media/bass1.flac"'), "resolved")
assert(mirror.media_needed(tok)[1] == "bass1.flac", "needed list")
assert(mirror.tokenize_media('FILE "C:/elsewhere/x.wav"', "J:/m"):find("C:/elsewhere"), "outside the room stays")

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

-- side room into its parent: only-side changes come in (tracks first), both-changed are clashes
local side = { ["I-1"] = { obj = "item", oid = "I-1" }, ["T-9"] = { obj = "track", oid = "T-9" }, ["I-2"] = { obj = "item", oid = "I-2" } }
local main = { ["I-2"] = { obj = "item", oid = "I-2" } }
local bring, clash = mirror.plan_bring(side, main)
assert(#bring == 2 and bring[1].obj == "track" and #clash == 1 and clash[1].oid == "I-2", "bring plan")

local a, b = mirror.new_oid("I", "Big Al", "20261030"), mirror.new_oid("I", "Big Al", "20261030")
assert(a ~= b and a:find("^I%-BIG_AL%-20261030%-"), "oids unique, upper case: " .. a)
print("ok")
