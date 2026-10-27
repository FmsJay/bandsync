-- @description BandSync: update to the latest version (through ReaPack)
-- BandSync installed through ReaPack updates with ReaPack's sync, which also registers new actions.
local dir = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
package.path = dir .. "/lib/?.lua;" .. package.path
local band = require("band")

local sync = reaper.NamedCommandLookup("_REAPACK_SYNC")
if not reaper.APIExists("ReaPack_GetOwner") or sync == 0 then
  return band.msg("BandSync " .. band.VERSION .. " isn't managed by ReaPack here.\n\n" ..
    "Install ReaPack (reapack.com), then add the BandSync repository so updates arrive automatically.")
end
local _, me = reaper.get_action_context()
local entry = reaper.ReaPack_GetOwner(me)
if not entry then
  return band.msg("BandSync " .. band.VERSION .. " was loaded from a folder, not installed through ReaPack, " ..
    "so updates arrive with that folder (for example through Syncthing). Nothing to do here.")
end
reaper.ReaPack_FreeEntry(entry)
reaper.Main_OnCommand(sync, 0) -- ReaPack: Synchronize packages
