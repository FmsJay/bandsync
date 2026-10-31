-- @description BandSync: change the shared folder and your name
-- (A new name moves who drives and your claims over everywhere, and your tracks stay yours: see band.rename.)
local dir = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
package.path = dir .. "/lib/?.lua;" .. package.path
local band = require("band")

local cfg = band.settings(true)
if cfg then band.msg("Saved. Shared folder: " .. cfg.root .. "\nYour name: " .. cfg.user) end
