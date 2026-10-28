-- @description BandSync: start Live sync with REAPER (run from Scripts/__startup.lua; the panel's toggle adds it)
-- Watches the project in front. A BandSync session whose Live sync was running when REAPER closed (and that
-- nobody stopped) gets Live sync started again, so a restart doesn't silently drop you out of the band.
local dir = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
package.path = dir .. "/lib/?.lua;" .. package.path
local band = require("band")

local tried = {} -- project key -> when we last started it (don't hammer a Live sync that refuses to run)
local cmd, at = nil, 0
local function loop()
  reaper.defer(loop)
  if reaper.time_precise() - at < 2 then return end -- every 2 s is plenty
  at = reaper.time_precise()
  local proj, fn = reaper.EnumProjects(-1)
  local key = tostring(proj)
  if fn and fn ~= "" and reaper.GetExtState(band.SECTION, "autosync " .. fn:lower()) == "1" and band.binding(proj) then
    local beat = tonumber(reaper.GetExtState(band.SECTION, "live " .. key))
    local alive = beat and reaper.time_precise() - beat < 5
    if not alive and reaper.time_precise() - (tried[key] or -1e9) > 30 and reaper.Audio_IsRunning() == 1 then
      tried[key] = reaper.time_precise()
      cmd = cmd or reaper.AddRemoveReaScript(true, 0, dir .. "/BandSync - Live sync.lua", true)
      if cmd > 0 then
        band.log("starting Live sync again for " .. fn)
        reaper.Main_OnCommand(cmd, 0)
      end
    end
  end
end
reaper.defer(loop)
