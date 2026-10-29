-- @description BandSync: start Live sync with REAPER (run from Scripts/__startup.lua; the panel's toggle adds it)
-- Watches the open projects. A BandSync session whose Live sync was running when REAPER closed (and that nobody
-- stopped) gets Live sync started again, so a restart doesn't silently drop you out of the band, in front or not.
-- It also runs the installer's setup step when the installer leaves a request (<resource>/BandSync/install-request):
-- on macOS any Apple Event reaching REAPER while ReaPack's report window is open crashes it (2026-10-28), so an
-- installer talking to a running REAPER leaves a file here instead of "open -a REAPER".
local dir = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
package.path = dir .. "/lib/?.lua;" .. package.path
local band = require("band")

local REQUEST = reaper.GetResourcePath() .. "/BandSync/install-request"
local tried = {} -- project key -> when we last started it (don't hammer a Live sync that refuses to run)
local at = 0
local function loop()
  reaper.defer(loop)
  if reaper.time_precise() - at < 2 then return end -- every 2 s is plenty
  at = reaper.time_precise()
  local helper = band.read(REQUEST)
  if helper then
    os.remove(REQUEST)
    helper = helper:match("^%s*(.-)%s*$")
    if reaper.file_exists(helper) then
      local ok, err = pcall(dofile, helper)
      if not ok then band.log("the installer's setup step failed: " .. tostring(err)) end
    end
  end
  if reaper.Audio_IsRunning() ~= 1 then return end
  local front = reaper.EnumProjects(-1)
  for i = 0, 512 do
    local proj, fn = reaper.EnumProjects(i)
    if not proj then break end
    local key = tostring(proj)
    if fn ~= "" and reaper.GetExtState(band.SECTION, "autosync " .. fn:lower()) == "1" and band.binding(proj) then
      local beat = tonumber(reaper.GetExtState(band.SECTION, "live " .. key))
      local alive = beat and reaper.time_precise() - beat < 5
      if not alive and reaper.time_precise() - (tried[key] or -1e9) > 30 then
        tried[key] = reaper.time_precise()
        band.log("starting Live sync again for " .. fn)
        reaper.SelectProjectInstance(proj) -- Live sync takes the project in front: this one, for a moment
        band.start_live(dir) -- (each tab at once needs an action of its own)
        if front and reaper.ValidatePtr2(0, front, "ReaProject*") then reaper.SelectProjectInstance(front) end
      end
    end
  end
end
reaper.defer(loop)
