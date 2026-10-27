-- @description BandSync: change shared folder, your name, and where takes land in this project
local dir = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
package.path = dir .. "/lib/?.lua;" .. package.path
local band = require("band")

local cfg = band.settings(true)
if not cfg then return end
local proj = reaper.EnumProjects(-1)
local b = band.binding(proj)
if not b then return band.msg("Saved. Shared folder: " .. cfg.root .. "\nYour name: " .. cfg.user) end

local MODES = { mirror = true, lanes = true, takes = true, person = true, inbox = true }
local current = b.take_mode or "mirror"
local ok, mode = reaper.GetUserInputs("BandSync: " .. b.song, 1,
  "Takes land as (mirror/lanes/takes/person/inbox),extrawidth=120", current)
mode = ok and mode:lower():gsub("%s", "")
if mode and MODES[mode] then
  band.bind(proj, { take_mode = mode })
  reaper.MarkProjectDirty(proj)
  band.msg("Saved. Shared folder: " .. cfg.root .. "\nYour name: " .. cfg.user .. "\n\nTakes now land as '" .. mode ..
    "'. Restart 'BandSync - Live sync' if it is running.")
end
