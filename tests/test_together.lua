-- lib/together.lua's plan() is pure: run with lupa or any Lua 5.4 from the repo root
package.path = "lib/?.lua;" .. package.path
local together = require("together")
local function near(a, b) return math.abs(a - b) < 1e-9 end

local ev = { at = 1000, pos = 30, countin = 2.5, lag = 5, lead = "James" }
local f, from = together.plan(ev, "James", 990)
assert(near(f, 1000) and near(from, 27.5), "on time: fire at the moment, from one count-in before")
f, from = together.plan(ev, "Laptop", 990)
assert(near(f, 1005) and near(from, 27.5), "a listener in Play along starts lag seconds behind the lead")
f, from = together.plan({ at = 1000, pos = 30, countin = 2.5 }, "Laptop", 990)
assert(near(f, 1000), "no lead/lag: everyone at once")
f, from = together.plan(ev, "James", 1003.25)
assert(near(f, 1003.25) and near(from, 30.75), "late: start now, as far into the song as time has gone")
f, from = together.plan({ at = 1000, pos = 1, countin = 2.5 }, "James", 990)
assert(near(f, 1001.5) and near(from, 0), "count-in can't start before 0: start at 0, 1.5 s later, so bar 1 still lands at at+2.5")
print("ok")
