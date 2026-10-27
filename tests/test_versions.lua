-- Run outside REAPER: lua tests/test_versions.lua (from the repo root)
package.path = "lib/?.lua;" .. package.path
reaper = {} -- band.lua only touches reaper.* inside functions
local band = require("band")
local cv = band.compare_versions
assert(cv("0.10.0", "0.9.1") == 1, "numeric, not string, comparison")
assert(cv("0.2", "0.2.0") == 0, "missing segments are zero")
assert(cv("0.2.0", "0.3.0") == -1)
assert(cv(band.VERSION, band.VERSION) == 0)
print("ok")
