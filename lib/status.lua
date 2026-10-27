-- Who's online and who has which takes, from the receipts every Live sync writes (rooms/<room>/status).
-- Shared by the Status window and the control panel.
local band = require("band")
local sync = require("sync")
local status = {}

status.COLORS = { ["in sync"] = { 0.35, 0.8, 0.45 }, ["catching up"] = { 0.95, 0.75, 0.25 },
  offline = { 0.55, 0.55, 0.55 }, ["no receipt"] = { 0.55, 0.55, 0.55 } }

function status.ago(sec)
  if sec == math.huge then return "never" elseif sec < 60 then return math.floor(sec) .. " s ago" end
  return math.floor(sec / 60) .. " min ago"
end

-- { rows = { name, age, version, missing, has, mine, state }, total, mine, my_missing, my_age, newer, driver, print }
function status.gather(cfg, b, proj)
  local view = {}
  local s = band.read_json(band.session_path(cfg, b.song)) or {}
  local takes, total, mine, newest = {}, 0, 0, band.VERSION
  local function note_version(v) if v and band.compare_versions(v, newest) > 0 then newest = v end end
  for _, f in ipairs(band.files(band.takes_dir(cfg, b.song, b.room), ".json")) do
    local t = band.read_json(band.takes_dir(cfg, b.song, b.room) .. "/" .. f)
    if t and t.id then
      takes[t.id:lower()] = { rev = t.rev or 1, user = t.user }
      note_version(t.bandsync)
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
      if st.user ~= cfg.user then note_version(st.version) end
      if st.user == cfg.user then view.my_age = band.age(st.time) else
        local a, missing = band.age(st.time), count(st.takes or {})
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
  view.newer = band.compare_versions(newest, band.VERSION) > 0 and newest or nil
  view.my_missing = count(me)
  view.driver = sync.driver(cfg, b.song, b.room, s)
  view.print = s.print or "wet"
  view.session = s
  return view
end

return status
