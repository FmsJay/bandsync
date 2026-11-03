-- lib/removal.lua's pure half
package.path = "lib/?.lua;" .. package.path
reaper = reaper or { GetResourcePath = function() return "res" end }
local removal = require("removal")
assert(not removal.due({ at = 1000 }, 1000 + removal.GRACE - 1), "a minute to change your mind")
assert(removal.due({ at = 1000 }, 1000 + removal.GRACE), "then it happens")
local dev = { Sam = "A", Kim = "NEW" }
local of = function(u) return dev[u] end
local out = removal.out({ { user = "Sam", device = "A", at = 0 }, { user = "Kim", device = "OLD", at = 0 }, { user = "Pat", device = "P", at = 0 }, { user = "Lee", device = "L", at = 9e9 } }, of, 1000)
assert(out.Sam, "taken out: not listed")
assert(not out.Kim, "a new computer of theirs, let in since, isn't the one the mark names")
assert(out.Pat, "a computer that never said which it was goes by the mark")
assert(not out.Lee, "still in their minute: still listed")
print("ok")
