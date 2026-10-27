-- @description BandSync: take control of the session (your deletes, moves and lane choices go to everyone)
-- The driver is the one person whose edits to the shared takes propagate; everyone else's stay local.
-- The host drives until someone runs this. Live sync must be running for your changes to go out.
local dir = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
package.path = dir .. "/lib/?.lua;" .. package.path
local band = require("band")
local sync = require("sync")

local cfg = band.settings()
if not cfg then return end
local proj = reaper.EnumProjects(-1)
local b = band.binding(proj)
if not b then return band.msg("Publish (host) or open (guest) a session in this project first.") end
local s = band.read_json(band.session_path(cfg, b.song))
local now = sync.driver(cfg, b.song, b.room, s)
if now == cfg.user then return band.msg("You're already driving '" .. b.song .. "' (room " .. b.room .. ").") end
if reaper.MB((now or "Nobody") .. " is driving '" .. b.song .. "' (room " .. b.room .. ").\n\nTake control? Tell them first: " ..
    "from now on only your deletes, moves and lane choices reach everyone.", "BandSync", 4) ~= 6 then return end
sync.watch(proj, cfg, b.song, b.room, function() return false end) -- start from what's here now: old local edits aren't replayed
-- every handover leaves a recall point, so the band can always go back to how it was before
require("recall").save(proj, cfg, b.song, b.room, "before " .. cfg.user .. " took over from " .. tostring(now))
sync.set_driver(cfg, b.song, b.room, cfg.user)
band.msg("You're driving '" .. b.song .. "' now.")
