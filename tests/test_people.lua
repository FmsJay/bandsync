-- people.assign is pure (lupa or Lua 5.4, from the repo root)
package.path = "lib/?.lua;" .. package.path
reaper = reaper or {}
package.loaded.band = package.loaded.band or {}
local people = require("people")
local P = people.PALETTE
local c = people.assign({}, { "Mac", "James", "Laptop" })
assert(c.James == P[1] and c.Laptop == P[2] and c.Mac == P[3], "defaults in name order, so every machine agrees")
c = people.assign({ Laptop = P[1] }, { "Mac", "James", "Laptop" })
assert(c.Laptop == P[1] and c.James == P[2] and c.Mac == P[3], "a picked colour is nobody else's default")
c = people.assign({ Mac = 0x123456 }, { "James", "James" })
assert(c.Mac == 0x123456 and c.James == P[1], "any colour can be picked; a name listed twice gets one")
local many = {}
for i = 1, #P + 2 do many[#many + 1] = "P" .. string.format("%02d", i) end
c = people.assign({}, many)
assert(c.P01 == P[1] and c[many[#P + 1]] ~= nil, "more people than colours: everyone still gets one")
print("ok")

-- what's new fades
assert(people.fade(0) == 1 and people.fade(299) == 1, "full at first")
assert(people.fade(1950) > 0.4 and people.fade(1950) < 0.6, "half way")
assert(people.fade(3600) == 0 and people.fade(90000) == 0, "gone after the hour")
