-- Run outside REAPER: lua tests/test_age.lua (from the repo root)
package.path = "lib/?.lua;" .. package.path
reaper = {} -- band.lua only touches reaper.* inside functions
local band = require("band")
-- a "now" carrying isdst = true, as os.date("!*t") does in a DST zone: must not shift the result
local now = { year = 2026, month = 10, day = 27, hour = 2, min = 43, sec = 42, isdst = true }
assert(band.age("2026-10-27T02:43:22Z", now) == 20, "20 s, not 3620 s")
now.isdst = false
assert(band.age("2026-10-27T02:38:59Z", now) == 283)
assert(band.age("garbage", now) == math.huge)
assert(band.age(os.date("!%Y-%m-%dT%H:%M:%SZ")) <= 1, "a timestamp from right now is about 0 s old")
print("ok")
