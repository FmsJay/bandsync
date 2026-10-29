-- rooms.plan / rooms.merged are pure (lupa or any Lua 5.4, from the repo root)
package.loaded.band = { json_encode = function(t) -- enough for comparing tempo maps
  local function enc(v) if type(v) ~= "table" then return tostring(v) end local o = {} for k, x in pairs(v) do o[#o + 1] = tostring(k) .. "=" .. enc(x) end table.sort(o) return "{" .. table.concat(o, ",") .. "}" end
  return enc(t) end }
package.loaded.sync = {}
package.path = "lib/?.lua;" .. package.path
local rooms = require("rooms")
local function take(track, pos, extra)
  local t = { track = track, pos = pos, len = 4, lane = 0, mute = 0, offs = 0, active = true }
  for k, v in pairs(extra or {}) do t[k] = v end
  return t
end
local tl = { tempo = { { time = 0, bpm = 120 } }, markers = {} }
local base = { takes = {
  ["A-20261029-100000Z-1"] = take("Gtr", 0),   -- moved only in the side room
  ["A-20261029-100000Z-2"] = take("Gtr", 8),   -- moved in both, differently: a clash
  ["B-20261029-100000Z-1"] = take("Bass", 0),  -- deleted in the side room
  ["B-20261029-100000Z-2"] = take("Bass", 8),  -- deleted in the side room, moved in main: a clash
  ["C-20261029-100000Z-1"] = take("Keys", 0, { notes = "h1" }), -- notes edited in the side room
  ["C-20261029-100000Z-2"] = take("Keys", 8),  -- deleted in main, untouched in the side room: stays deleted
  ["D-20261029-100000Z-1"] = take("Vox", 0),   -- moved in main only: stays as main has it
}, plays = { Gtr = { "A-20261029-100000Z-1" } }, tracks = { Gtr = { mute = 0, solo = 0 } }, timeline = tl }
local main = { takes = {
  ["A-20261029-100000Z-1"] = take("Gtr", 0),
  ["A-20261029-100000Z-2"] = take("Gtr", 9),
  ["B-20261029-100000Z-1"] = take("Bass", 0),
  ["B-20261029-100000Z-2"] = take("Bass", 9),
  ["C-20261029-100000Z-1"] = take("Keys", 0, { notes = "h1" }),
  ["D-20261029-100000Z-1"] = take("Vox", 2),
  ["E-20261029-110000Z-1"] = take("Drums", 0), -- recorded in main after the room was made
}, plays = { Gtr = { "A-20261029-100000Z-1" } }, tracks = { Gtr = { mute = 0, solo = 0 } }, timeline = tl }
local side = { takes = {
  ["A-20261029-100000Z-1"] = take("Gtr", 1),
  ["A-20261029-100000Z-2"] = take("Gtr", 10),
  ["C-20261029-100000Z-1"] = take("Keys", 0, { notes = "h2" }),
  ["C-20261029-100000Z-2"] = take("Keys", 8),
  ["D-20261029-100000Z-1"] = take("Vox", 0),
  ["S-20261029-120000Z-1"] = take("Gtr", 16), -- recorded in the side room
}, plays = { Gtr = { "A-20261029-100000Z-1", "S-20261029-120000Z-1" } }, tracks = { Gtr = { mute = 1, solo = 0 } }, timeline = tl }

local plan = rooms.plan(base, main, side)
local by = {}
for _, it in ipairs(plan.items) do by[it.kind .. ":" .. it.key] = it end
assert(#plan.new == 1 and plan.new[1] == "S-20261029-120000Z-1", "the side room's own recording is new")
assert(by["take:A-20261029-100000Z-1"] and not by["take:A-20261029-100000Z-1"].clash, "moved only here: brought")
assert(by["take:A-20261029-100000Z-2"].clash, "moved in both: a clash")
assert(by["take:B-20261029-100000Z-1"].side == false and not by["take:B-20261029-100000Z-1"].clash, "deleted only here: brought")
assert(by["take:B-20261029-100000Z-2"].clash and by["take:B-20261029-100000Z-2"].side == false, "deleted here, moved there: a clash")
assert(by["notes:C-20261029-100000Z-1"] and not by["notes:C-20261029-100000Z-1"].clash, "notes edited only here")
assert(not by["take:C-20261029-100000Z-2"], "deleted in main and untouched here: nothing to bring")
assert(not by["take:D-20261029-100000Z-1"], "moved only in main: nothing to bring")
assert(not by["take:E-20261029-110000Z-1"], "main's new take isn't the side room's business")
assert(by["plays:Gtr"] and by["track:Gtr"], "what plays and mute changed here")
assert(plan.timeline == nil, "same tempo map")

local st = rooms.merged(main, side, plan.items)
assert(st.takes["A-20261029-100000Z-1"].pos == 1, "brought")
assert(st.takes["A-20261029-100000Z-2"].pos == 9, "a clash keeps main's by default")
assert(st.takes["B-20261029-100000Z-1"] == nil, "a delete is brought")
assert(st.takes["B-20261029-100000Z-2"].pos == 9, "a clashing delete isn't, by default")
assert(st.takes["D-20261029-100000Z-1"].pos == 2 and st.takes["E-20261029-110000Z-1"], "main's own changes and takes stay")
by["take:A-20261029-100000Z-2"].use = "side"
st = rooms.merged(main, side, plan.items, { Bass = true })
assert(st.takes["A-20261029-100000Z-1"].pos == 0 and st.takes["B-20261029-100000Z-1"] == nil, "only the ticked tracks")
st = rooms.merged(main, side, plan.items)
assert(st.takes["A-20261029-100000Z-2"].pos == 10, "picking this room's version")
assert(st.tracks.Gtr.mute == 1 and #st.plays.Gtr == 2 and st.timeline == nil, "track and plays")

-- a tempo change in the side room is flagged, and only travels when asked
local side2 = { takes = side.takes, plays = side.plays, tracks = side.tracks, timeline = { tempo = { { time = 0, bpm = 100 } }, markers = {} } }
local plan2 = rooms.plan(base, main, side2)
assert(plan2.timeline == "side", "tempo changed here")
assert(rooms.merged(main, side2, plan2.items, nil, true).timeline.tempo[1].bpm == 100, "with the tempo")
local main2 = { takes = main.takes, plays = main.plays, tracks = main.tracks, timeline = side2.timeline }
assert(rooms.plan(base, main2, side).timeline == "main", "tempo changed there")

-- a later joiner's copy holds a main take that isn't in the base: a difference there is a clash, never a silent revert
local plan3 = rooms.plan(base, main, { takes = { ["E-20261029-110000Z-1"] = take("Drums", 4) }, plays = {}, tracks = {}, timeline = tl })
local e
for _, it in ipairs(plan3.items) do if it.key == "E-20261029-110000Z-1" then e = it end end
assert(e and e.clash, "not in the base: you pick")
-- REAPER says 0.0 where a saved point says 0: not a change
local live = { takes = { ["A-20261029-100000Z-1"] = take("Gtr", 0.0, { mute = 0.0, len = 4.0, lane = 0.0 }) }, plays = {}, tracks = { Gtr = { mute = 0.0, solo = 0.0 } }, timeline = tl }
local saved = { takes = { ["A-20261029-100000Z-1"] = take("Gtr", 0, { mute = 0, len = 4, lane = 0 }) }, plays = {}, tracks = { Gtr = { mute = 0, solo = 0 } }, timeline = tl }
assert(#rooms.plan(saved, live, saved).items == 0 and #rooms.plan(saved, saved, live).items == 0, "0.0 is 0")
local side3 = { takes = side.takes, plays = { Gtr = side.plays.Gtr, New = { "S-20261029-120000Z-1" } }, tracks = { Gtr = side.tracks.Gtr, New = { mute = 0, solo = 0 } }, timeline = tl }
for _, it in ipairs(rooms.plan(base, main, side3).items) do assert(it.key ~= "New", "a new track's state isn't a change") end
print("ok")
