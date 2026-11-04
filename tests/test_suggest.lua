package.path = "lib/?.lua;" .. package.path
reaper = reaper or {}
local mirror = require("mirror")
local suggest = require("suggest")

-- what a suggestion says it does
assert(suggest.words({ changes = 2, adds = 30, removes = 1, names = { "Keys", "Guitar" } }) == "2 changes, 30 new, 1 removed on Keys, Guitar")
assert(suggest.words({ changes = 0, adds = 1, removes = 0, names = { "Keys" } }) == "1 new on Keys")
local now = os.time({ year = 2026, month = 11, day = 4, hour = 12, min = 0, sec = 0, isdst = false })
assert(suggest.age("2026-11-04T11:59:30Z", now) == "just now")
assert(suggest.age("2026-11-04T11:48:00Z", now) == "12 min ago")
assert(suggest.age("2026-11-04T09:00:00Z", now) == "3 h ago")
assert(suggest.age("2026-11-01T12:00:00Z", now) == "3 days ago")
assert(suggest.age("", now) == "")

-- what runs through a track: its folder's tracks, what it receives, and what runs through those
local f = mirror.feeders({
  { oid = "T-BUS", parent = "" },
  { oid = "T-DRUMS", parent = "T-BUS", recv = "AUXRECV T-KICK 0 1\nAUXRECV T-SNARE 0 1\n" },
  { oid = "T-KICK", parent = "" },
  { oid = "T-SNARE", parent = "" },
  { oid = "T-KEYS", parent = "T-BUS" },
})
table.sort(f["T-BUS"])
assert(table.concat(f["T-BUS"], " ") == "T-DRUMS T-KEYS T-KICK T-SNARE", table.concat(f["T-BUS"], " "))
assert(#f["T-DRUMS"] == 2 and f["T-KICK"] == nil, "a track with nothing through it isn't listed")
-- (a loop of sends can't hang it)
local loop = mirror.feeders({ { oid = "A", recv = "AUXRECV B 0\n" }, { oid = "B", recv = "AUXRECV A 0\n" } })
assert(#loop.A == 1 and loop.A[1] == "B")

-- a VCA holds its followers, as a bus does
local v = mirror.feeders({ { oid = "T-LEAD", lead = 2 }, { oid = "T-KEYS", follow = 2 }, { oid = "T-BASS", follow = 4 }, { oid = "T-GTR", lead = 0, follow = 0 } })
assert(#v["T-LEAD"] == 1 and v["T-LEAD"][1] == "T-KEYS" and v["T-BASS"] == nil, "a VCA leads only the tracks that follow its group")

-- whose parts, in words
assert(mirror.whose({ { "Mac", "Keys" }, { "Bee", "Bass" }, { "Mac", "Guitar" } }) == "Bee's Bass and Mac's Guitar, Keys")

-- a tempo change moves an item, stretches it and nothing else
local a = "<ITEM\nPOSITION 1\nLENGTH 2\nMUTE 0\n<SOURCE MIDI\nE 0 90 40 100\n>\n>\n"
local b = "<ITEM\nPOSITION 3.5\nLENGTH 4\nMUTE 0\n<SOURCE MIDI\nE 0 90 40 100\n>\n>\n"
local c = "<ITEM\nPOSITION 1\nLENGTH 2\nMUTE 1\n<SOURCE MIDI\nE 0 90 40 100\n>\n>\n"
local d = "<ITEM\nPOSITION 1\nLENGTH 2\nMUTE 0\n<SOURCE MIDI\nE 0 90 41 100\n>\n>\n"
assert(mirror.sans_tempo(a) == mirror.sans_tempo(b), "moved and stretched: the same part")
assert(mirror.sans_tempo(a) ~= mirror.sans_tempo(c), "muted: an edit")
assert(mirror.sans_tempo(a) ~= mirror.sans_tempo(d), "another note: an edit")
print("ok")
