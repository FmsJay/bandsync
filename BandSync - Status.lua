-- @description BandSync: sync status window (who's online, and who has which takes, both ways)
-- Every Live sync writes a receipt of the takes (and revisions) its project holds; this window compares
-- them with the room's takes. Green = in sync, yellow = catching up, grey = offline. Esc closes.
local dir = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
package.path = dir .. "/lib/?.lua;" .. package.path
local band = require("band")
local sync = require("sync")

local cfg = band.settings()
if not cfg then return end
local proj = reaper.EnumProjects(-1)
local b = band.binding(proj)
if not b then return band.msg("Publish (host) or open (guest) a session in this project first.") end

local function age(iso) -- seconds since an ISO UTC timestamp
  local y, m, d, H, M, S = (iso or ""):match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then return math.huge end
  return os.time(os.date("!*t")) - os.time({ year = y, month = m, day = d, hour = H, min = M, sec = S })
end
local function ago(sec)
  if sec == math.huge then return "never" elseif sec < 60 then return math.floor(sec) .. " s ago" end
  return math.floor(sec / 60) .. " min ago"
end

local view = {}
local function gather()
  local s = band.read_json(band.session_path(cfg, b.song)) or {}
  local takes, total, mine = {}, 0, 0
  for _, f in ipairs(band.files(band.takes_dir(cfg, b.song, b.room), ".json")) do
    local t = band.read_json(band.takes_dir(cfg, b.song, b.room) .. "/" .. f)
    if t and t.id then
      takes[t.id:lower()] = { rev = t.rev or 1, user = t.user }
      total = total + 1
      if t.user == cfg.user then mine = mine + 1 end
    end
  end
  local function count(have, filter)
    local missing = 0
    for id, t in pairs(takes) do
      if (not filter or t.user == filter) and (have[id] or 0) < t.rev then missing = missing + 1 end
    end
    return missing
  end
  local me = sync.holdings(proj)
  local rows, seen = {}, {}
  for _, f in ipairs(band.files(sync.room_dir(cfg, b.song, b.room) .. "/status", ".json")) do
    local st = band.read_json(sync.room_dir(cfg, b.song, b.room) .. "/status/" .. f)
    if st and st.user then
      seen[st.user] = true
      if st.user == cfg.user then view.my_age = age(st.time) else
        local a, missing = age(st.time), count(st.takes or {})
        rows[#rows + 1] = { name = st.user, age = a, version = st.version or "?", missing = missing,
          has = total - missing, mine = count(st.takes or {}, cfg.user),
          state = a > 60 and "offline" or (missing == 0 and "in sync" or "catching up") }
      end
    end
  end
  for _, t in pairs(takes) do -- people who sent takes but never ran a Live sync that wrote a receipt
    if t.user ~= cfg.user and not seen[t.user] then
      seen[t.user] = true
      rows[#rows + 1] = { name = t.user, age = math.huge, version = "?", missing = total, has = 0, mine = mine, state = "no receipt" }
    end
  end
  table.sort(rows, function(x, y) return x.name < y.name end)
  view.rows, view.total, view.mine = rows, total, mine
  view.my_missing = count(me)
  view.driver = sync.driver(cfg, b.song, b.room, s)
  view.print = s.print or "wet"
end

local COLORS = { ["in sync"] = { 0.35, 0.8, 0.45 }, ["catching up"] = { 0.95, 0.75, 0.25 },
  offline = { 0.55, 0.55, 0.55 }, ["no receipt"] = { 0.55, 0.55, 0.55 } }
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
  local me_state = not running and "offline" or (view.my_missing == 0 and "in sync" or "catching up")
  text(14, 40, string.format("You (%s): %d/%d takes here, %s.   Live sync %s.", cfg.user, view.total - view.my_missing,
    view.total, view.my_missing == 0 and "nothing waiting" or (view.my_missing .. " still arriving"),
    running and "running" or "NOT running (start BandSync - Live sync)"), COLORS[me_state])
  local cols = { 14, 170, 290, 400, 500, 620 }
  local y = 72
  for i, h in ipairs({ "Bandmate", "State", "Last seen", "Has", "Missing yours", "Version" }) do text(cols[i], y, h, dim) end
  y = y + 24
  if #view.rows == 0 then text(14, y, "Nobody else has synced in this room yet.", dim) end
  for _, r in ipairs(view.rows) do
    local c = COLORS[r.state]
    text(cols[1], y, r.name, white)
    text(cols[2], y, r.state, c)
    text(cols[3], y, ago(r.age), c)
    text(cols[4], y, r.has .. "/" .. view.total, c)
    text(cols[5], y, r.mine == 0 and "none" or tostring(r.mine), r.mine == 0 and COLORS["in sync"] or COLORS["catching up"])
    text(cols[6], y, r.version, r.version == band.VERSION and dim or COLORS["catching up"])
    y = y + 22
  end
  gfx.update()
end

gfx.init("BandSync status", 720, 300, 0)
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
