-- band.is_conflict_copy: sync tools' duplicate files are never read as ours (lupa or any Lua 5.4, from the repo root)
reaper = setmetatable({}, { __index = function() return function() end end }) -- band.lua only needs reaper at call time
package.path = "lib/?.lua;" .. package.path
local band = require("band")
assert(band.is_conflict_copy("James-20261028-070536Z-00009-8160.sync-conflict-20261028-071122-ABCDEF.json"), "Syncthing conflict copy")
assert(band.is_conflict_copy("James-20261028-070536Z-00009-8160 (1).json"), "Drive duplicate")
assert(not band.is_conflict_copy("James-20261028-070536Z-00009-8160.json"), "a real event")
assert(not band.is_conflict_copy("Gtr (band).fxchain"), "a name with brackets isn't a duplicate")
print("ok")
