-- @description BandSync: undo your own last change, for everyone (bind it to Ctrl+Z)
-- In a BandSync session: steps back through your own changes only, and asks first when a bandmate changed the same
-- thing since (REAPER's own undo would roll back their changes too). In any other project: REAPER's normal Undo.
local dir = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
package.path = dir .. "/lib/?.lua;" .. package.path
local band = require("band")
local proj = reaper.EnumProjects(-1)
local b = band.binding(proj)
local cfg = b and band.settings()
if not (b and cfg) then return reaper.Main_OnCommand(40029, 0) end -- Edit: Undo
local res, why = require("undo").step(proj, cfg, b, false)
if res then band.log(res) elseif why then band.msg(why) end
