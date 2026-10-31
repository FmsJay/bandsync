-- @description BandSync: take control of the session (your deletes, moves and lane choices go to everyone)
-- The driver is the one person whose edits to the shared takes propagate (for whatever nobody has claimed).
-- Before switching, everyone online must hold every take and have applied every change, so the handover
-- starts from one agreed state; you can wait for that (up to 2 minutes) or switch anyway.
-- Live sync must be running for your changes to go out.
local dir = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
package.path = dir .. "/lib/?.lua;" .. package.path
local band = require("band")
local sync = require("sync")
local status = require("status")

local cfg = band.settings()
if not cfg then return end
local proj = reaper.EnumProjects(-1)
local b = band.binding(proj)
if not b then return band.msg("Publish (host) or open (guest) a session in this project first.") end
local s = band.read_json(band.session_path(cfg, b.song))
local now = sync.driver(cfg, b.song, b.room, s)
if now == cfg.user then return band.msg("You're already driving '" .. b.song .. "' (room " .. b.room .. ").") end
local away = now and now ~= cfg.user
for _, o in ipairs(sync.present(cfg, b.song, b.room)) do if o == now then away = false end end
if reaper.MB((now or "Nobody") .. " is driving '" .. b.song .. "' (room " .. b.room .. ")" ..
    (away and ", but isn't here.\n\nTake control so the session can carry on? " or ".\n\nTake control? Tell them first: ") ..
    "from now on your deletes, moves and lane choices reach everyone (except on tracks or regions someone owns)." ..
    (away and " They can take it back when they return." or ""), "BandSync", 4) ~= 6 then return end

local function handover()
  -- every handover leaves a recall point, so the band can always go back to how it was before
  require("recall").save(proj, cfg, b.song, b.room, "before " .. cfg.user .. " took over from " .. tostring(now))
  sync.set_driver(cfg, b.song, b.room, cfg.user)
  sync.post(cfg, b.song, b.room, { type = "driver", from = now, driver = cfg.user }) -- for the history
  band.log("you're driving '" .. b.song .. "' now") -- not a dialog: one would pause Live sync until it's closed
end

local function describe(c)
  local text = "- " .. table.concat(c.problems, "\n- ")
  if #c.offline > 0 then text = text .. "\n\nOffline (they catch up when they're back): " .. table.concat(c.offline, ", ") end
  return text
end

local c = status.handover_check(cfg, b, proj)
if #c.problems == 0 then return handover() end
local r = reaper.MB("Not everyone is in sync yet:\n" .. describe(c) ..
  "\n\nYes: wait until they are (up to 2 minutes), then take control.\nNo: take control now anyway.", "BandSync", 3)
if r == 7 then return handover() end
if r ~= 6 then return end

band.log("waiting for everyone to sync before taking control of '" .. b.song .. "'")
local started, last = reaper.time_precise(), 0
local function wait()
  if reaper.time_precise() - last < 2 then return reaper.defer(wait) end
  last = reaper.time_precise()
  c = status.handover_check(cfg, b, proj)
  if #c.problems == 0 then return handover() end
  if last - started < 120 then return reaper.defer(wait) end
  if reaper.MB("Still not in sync after 2 minutes:\n" .. describe(c) .. "\n\nTake control anyway?", "BandSync", 4) == 6 then handover() end
end
reaper.defer(wait)
