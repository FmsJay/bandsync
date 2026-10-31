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
local at, seen_disk = 0, nil
local function loop()
  if reaper.time_precise() - at < 2 then return reaper.defer(loop) end -- every 2 s is plenty
  at = reaper.time_precise()
  -- an update: the new code takes over in place (once the version on disk has held for two looks), as Live sync does;
  -- before 0.21.3 a running Autostart kept its old rules until REAPER restarted
  local disk = (band.read(dir .. "/lib/band.lua") or ""):match('VERSION = "([^"]+)"')
  if disk and disk ~= band.VERSION and disk == seen_disk then
    for _, f in ipairs(band.files(dir .. "/lib", ".lua")) do package.loaded[f:sub(1, -5)] = nil end
    return dofile(dir .. "/BandSync - Autostart.lua")
  end
  seen_disk = disk
  reaper.defer(loop)
  -- a BandSync session that opens (or is open when REAPER starts) opens the panel, once per opening: closing the panel
  -- keeps it closed until another BandSync session opens. (Marks aren't persisted, and survive an Autostart reload.)
  local opened = false
  for i = 0, 512 do
    local proj, fn = reaper.EnumProjects(i)
    if not proj then break end
    local mark = "panel for " .. tostring(proj) .. " " .. fn:lower()
    if fn ~= "" and reaper.GetExtState(band.SECTION, mark) == "" and band.binding(proj) then
      reaper.SetExtState(band.SECTION, mark, "1", false)
      opened = true
    end
  end
  local beat = tonumber(reaper.GetExtState(band.SECTION, "panel alive"))
  if opened and not (beat and reaper.time_precise() - beat < 10) then
    local id = reaper.AddRemoveReaScript(true, 0, dir .. "/BandSync - Panel.lua", true)
    if id > 0 and reaper.GetToggleCommandState(id) ~= 1 then reaper.Main_OnCommand(id, 0) end
  end
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
      -- (30 s, not 5: a dialog left open a few seconds pauses every script, and isn't a Live sync that stopped)
      local alive = beat and reaper.time_precise() - beat < 30
      -- Only the tab in front is (re)started: starting a background tab meant flipping it to the front, and with more
      -- BandSync tabs open than Live sync has slots (17) the flipping never stopped and REAPER couldn't be clicked
      -- (PC, 2026-10-30, 38 tabs). A background tab starts when you switch to it. Three tries, then it says so once.
      local n = tried[key] or { at = -1e9, n = 0 }
      tried[key] = n
      if alive then n.n = 0
      elseif proj == front and n.n < 3 and reaper.time_precise() - n.at > 30 then
        n.at, n.n = reaper.time_precise(), n.n + 1
        band.log("starting Live sync again for " .. fn)
        if not band.start_live(dir) then band.log("Live sync has no free slot for " .. fn .. ": close some BandSync tabs (17 at most run at once)") end
        if n.n == 3 then band.log("Live sync didn't stay running for " .. fn .. " after 3 tries: press Start in the BandSync panel") end
      end
    end
  end
end
reaper.defer(loop)
