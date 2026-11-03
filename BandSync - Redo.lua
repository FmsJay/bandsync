-- @description BandSync: redo the change you undid last, for everyone (bind it to Ctrl+Shift+Z; Cmd+Shift+Z on a Mac)
-- In a BandSync session: REAPER's own Redo if what's next on its list is your own edit, else your own last undone change.
-- In any other project: REAPER's normal Redo.
local dir = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
package.path = dir .. "/lib/?.lua;" .. package.path
local band = require("band")
local proj = reaper.EnumProjects(-1)
local b = band.binding(proj)
local cfg = b and band.settings()
local undo = require("undo")
if not (b and cfg) or undo.native(reaper.Undo_CanRedo2(proj)) then return reaper.Main_OnCommand(40030, 0) end -- Edit: Redo
local res, why = undo.step(proj, cfg, b, true)
if res then band.log(res) elseif why then band.msg(why) end
