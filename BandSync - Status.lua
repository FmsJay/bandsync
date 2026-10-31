-- @description BandSync: sync status window (who's online, and who has which takes, both ways)
-- Every Live sync writes a receipt of the takes (and revisions) its project holds; this window compares
-- them with the room's takes. Green = in sync, yellow = catching up, grey = offline. Esc closes.
local dir = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
package.path = dir .. "/lib/?.lua;" .. package.path
local band = require("band")

local cfg = band.settings()
if not cfg then return end
local proj = reaper.EnumProjects(-1)
local b = band.binding(proj)
if not b then return band.msg("Publish (host) or open (guest) a session in this project first.") end

local status = require("status")
local ago, COLORS = status.ago, status.COLORS

local view = {}
local function gather() view = status.gather(cfg, b, proj) end

local function text(x, y, s, c)
  gfx.set(c[1], c[2], c[3], 1)
  gfx.x, gfx.y = x, y
  gfx.drawstr(s)
end

local function draw()
  gfx.set(0.12, 0.12, 0.13, 1)
  gfx.rect(0, 0, gfx.w, gfx.h, 1)
  local white, dim = { 0.92, 0.92, 0.92 }, { 0.6, 0.6, 0.6 }
  gfx.setfont(1, "Arial", 18)
  text(14, 12, string.format("%s  ·  room %s  ·  driver %s  ·  print %s", b.song, b.room, tostring(view.driver), view.print), white)
  gfx.setfont(1, "Arial", 15)
  local running = (view.my_age or math.huge) < 30
  local me_state = not running and "offline" or (view.my_missing == 0 and "synced" or "syncing")
  text(14, 40, string.format("You (%s): %d/%d takes here, %s.   Live sync %s.", cfg.user, view.total - view.my_missing,
    view.total, view.my_missing == 0 and "nothing waiting" or (view.my_missing .. " still arriving"),
    running and "running" or "NOT running (start BandSync - Live sync)"), COLORS[me_state])
  local cols = { 14, 170, 290, 400, 500, 620 }
  local y = 72
  if view.newer then
    text(14, 62, string.format("BandSync %s is in use here; you have %s. Run 'BandSync - Update'.", view.newer, band.VERSION), COLORS["syncing"])
    y = 92
  end
  for i, h in ipairs({ "Bandmate", "State", "Last seen", "Has", "Missing yours", "Version" }) do text(cols[i], y, h, dim) end
  y = y + 24
  if #view.rows == 0 then text(14, y, "Nobody else has synced in this room yet.", dim) end
  for _, r in ipairs(view.rows) do
    local c = COLORS[r.state]
    text(cols[1], y, r.name, white)
    text(cols[2], y, r.state, c)
    text(cols[3], y, ago(r.age), c)
    text(cols[4], y, r.has .. "/" .. view.total, c)
    text(cols[5], y, r.mine == 0 and "none" or tostring(r.mine), r.mine == 0 and COLORS["synced"] or COLORS["syncing"])
    text(cols[6], y, r.version, r.version == band.VERSION and dim or COLORS["syncing"])
    y = y + 22
  end
  gfx.update()
end

local mx, my = reaper.GetMousePosition() -- open by the mouse (down-left of it), not over REAPER's menu bar
gfx.init("BandSync status", 720, 300, 0, math.max(0, mx - 360), my + 40)
local last = 0
local function loop()
  local ch = gfx.getchar()
  if ch < 0 or ch == 27 then return gfx.quit() end
  if reaper.time_precise() - last > 2 then
    last = reaper.time_precise()
    local ok, err = pcall(gather)
    if not ok then view.rows, view.total, view.my_missing = {}, 0, 0; band.log("status: " .. tostring(err)) end
  end
  if view.rows then draw() end
  reaper.defer(loop)
end
loop()
