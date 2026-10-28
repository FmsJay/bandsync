-- recall.replay / groups / describe are pure: run them on a hand-made history (lupa or any Lua 5.4)
package.loaded.band = { files = function() return {} end }
package.loaded.sync = { base_name = function(n) return n end }
package.path = "lib/?.lua;" .. package.path
local recall = require("recall")
local E = {
  { kind = "take", time = "2026-10-27T01:00:00Z", id = "A-20261027-010000Z-1", take = "A-20261027-010000Z-1", user = "A", track = "Gtr", pos = 1, len = 4 },
  { kind = "take", time = "2026-10-27T01:01:00Z", id = "B-20261027-010100Z-1", take = "B-20261027-010100Z-1", user = "B", track = "Bass", pos = 0, len = 8 },
  { kind = "edit", time = "2026-10-27T01:02:00Z", id = "A-e1", user = "A", take = "A-20261027-010000Z-1", track = "Gtr", pos = 2, len = 3, offs = 0.5, mute = 0 },
  { kind = "driver", time = "2026-10-27T01:03:00Z", id = "B-e0", user = "B", from = "A", driver = "B" },
  { kind = "delete", time = "2026-10-27T01:04:00Z", id = "B-e1", user = "B", take = "A-20261027-010000Z-1", track = "Gtr", pos = 2 },
  { kind = "plays", time = "2026-10-27T01:05:00Z", id = "B-e2", user = "B", track = "Bass", takes = { "b-20261027-010100z-1" } },
  { kind = "undelete", time = "2026-10-27T01:06:00Z", id = "B-e3", user = "B", take = "A-20261027-010000Z-1", track = "Gtr" },
}
local st = recall.replay(E, 3)
assert(st.takes["A-20261027-010000Z-1"].pos == 2 and st.takes["A-20261027-010000Z-1"].offs == 0.5, "edit applied")
assert(st.takes["B-20261027-010100Z-1"].pos == 0, "second take placed")
st = recall.replay(E, 5)
assert(st.takes["A-20261027-010000Z-1"] == nil, "deleted")
st = recall.replay(E, 7)
assert(st.takes["A-20261027-010000Z-1"].pos == 2, "undelete keeps last shape")
assert(st.takes["B-20261027-010100Z-1"].active, "plays marks active")
assert(recall.replay(E, 1).takes["B-20261027-010100Z-1"] == nil, "later takes absent")
local g = recall.groups(E, "A")
assert(#g == 4, "groups: A(take), B(take), A(edit), B(driver..undelete) got " .. #g)
assert(g[4].driver == "B" and g[4].first == 4 and g[4].last == 7, "driver change starts B's run")
assert(recall.describe(E[5]) == "deleted A's take on Gtr", recall.describe(E[5]))
assert(recall.describe(E[1]):match("^recorded a take on Gtr at 1.00 s"), recall.describe(E[1]))
-- the timeline (tempo map/markers) is part of where things are: a restore before a tempo change brings its map back
local TL = {
  E[1],
  { kind = "timeline", time = "2026-10-27T01:02:00Z", id = "A-t1", user = "A", tempo = { { time = 0, bpm = 96, num = 4, denom = 4 }, { time = 90, bpm = 88, num = 4, denom = 4 } }, markers = {} },
  { kind = "edit", time = "2026-10-27T01:03:00Z", id = "A-e9", user = "A", take = "A-20261027-010000Z-1", track = "Gtr", pos = 5, len = 4 },
}
assert(recall.replay(TL, 1).timeline == nil, "no timeline change yet: the published one applies")
assert(recall.replay(TL, 3).timeline.tempo[2].bpm == 88, "after the change: its map")
assert(recall.describe(TL[2]):match("^changed the tempo map %(96 bpm 4/4 at 0.00 s, 88 bpm 4/4 at 90.00 s%)"), recall.describe(TL[2]))
print("ok")
