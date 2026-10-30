-- @description BandSync: (older) check in a Solo edit working copy made before Live sync took over working alone
local dir = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
package.path = dir .. "/lib/?.lua;" .. package.path
local band = require("band")
local solo = require("solo")

local cfg = band.settings()
if not cfg then return end
local proj = reaper.EnumProjects(-1)
local b = band.binding(proj)
if not b or b.role ~= "solo" then return band.msg("Bring the song you checked out (BandSync - Solo edit) to the front first.") end
local l = solo.lock(cfg, b.song)
if not (l and l.mine) then return band.msg("You don't have '" .. b.song .. "' checked out" .. (l and (": " .. l.user .. " does.") or ".")) end
local ok, note = reaper.GetUserInputs("BandSync: check in '" .. b.song .. "'", 1, "What did you change? (optional),extrawidth=220", "")
if not ok then return end
local keep = reaper.MB("Keep editing after checking in?\n\nYes: publish now and keep it checked out.\nNo: publish and hand it back.", "BandSync", 3)
if keep == 2 then return end
local msg, err = solo.push(proj, cfg, b.song, note)
if not msg then return band.msg(err) end
if keep == 7 then
  solo.release(cfg, b.song)
  reaper.SetExtState(band.SECTION, "solo done " .. b.song, "1", false) -- the Solo edit loop stops its heartbeat
  msg = msg .. ". It's free for the next person."
end
band.log(msg)
band.msg(msg)
