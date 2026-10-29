-- @description BandSync: the classic control panel (tabs, plain widgets), the backup for the app look
-- Opens the BandSync panel in its classic layout. The panel's Settings page (or the classic panel's "Switch to the
-- new look") goes back; it's one panel with two looks, the same underneath.
local dir = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
package.path = dir .. "/lib/?.lua;" .. package.path
local band = require("band")
reaper.SetExtState(band.SECTION, "panel_ui", "classic", true)
local id = reaper.AddRemoveReaScript(true, 0, dir .. "/BandSync - Panel.lua", true)
if id > 0 and reaper.GetToggleCommandState(id) ~= 1 then reaper.Main_OnCommand(id, 0) end -- (open already: it switches by itself)
