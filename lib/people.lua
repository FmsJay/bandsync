-- Each person's colour, and tracks that show who's working on them (James, 2026-11-01).
-- Everyone has a colour: their own pick (Setup > Options), else a default from the palette nobody has picked, the
-- same on every machine. Drawings use it ("Mine"); tracks may too, as this machine chooses (ExtState "track colours"):
--   "band"     the band's colours only (the default)
--   "working"  the band's colours, but a track someone else is editing (its last 15 s, lib/presence.lua) or has
--              claimed shows their colour, and goes back once that ends
--   "people"   every track in the colour of whoever is editing it, claimed it, or made it
-- A person's colour on a track is only ever shown here: the band's colour waits in the track's P_EXT:band_colour
-- meanwhile, and mirror, restore points and the rest read and write that one (band.track_colour), so nothing sends,
-- saves or loses it.
--   _band/colours/<user>.json   { colour = 0xRRGGBB, time }: each person's own file (one writer each)
local band = require("band")
local people = {}

people.PALETTE = { 0xFF5A5A, 0x4CC2FF, 0x7BE07B, 0xFFC24C, 0xC88BFF, 0xFF8BD0, 0x5AE0D0, 0xFF9F5A }
people.MODES = { { "band", "Band's colours", "Tracks keep the colours the band gave them." },
  { "working", "Show who's working", "The band's colours, but a track someone else is editing or has claimed shows their colour until they're done." },
  { "people", "Whose track", "Every track in the colour of whoever is editing it, claimed it, or made it." } }

local function file(root, user) return root .. "/_band/colours/" .. (user:gsub("[^%w%-_ ]", "")) .. ".json" end

-- Everyone's colour: picked ones, then a default each for the rest of `known` (name order, so every machine agrees),
-- skipping colours already taken. Pure over `picked` ({ user = rgb }) and `known` (names).
function people.assign(picked, known)
  local out, taken, rest, seen = {}, {}, {}, {}
  for u, c in pairs(picked) do out[u], taken[c] = c, true end
  for _, u in ipairs(known) do if not out[u] and not seen[u] then seen[u] = true; rest[#rest + 1] = u end end
  table.sort(rest)
  local i = 0
  for _, u in ipairs(rest) do
    local c
    for _ = 1, #people.PALETTE do
      i = i % #people.PALETTE + 1
      if not taken[people.PALETTE[i]] then c = people.PALETTE[i]; break end
    end
    c = c or people.PALETTE[i] -- (more people than colours: they share)
    out[u], taken[c] = c, true
  end
  return out
end

local cache = {} -- root -> { at, picked, members }
-- Everyone's colour in this band (+ `extra` names: people in a room, who drew). 0xRRGGBB each.
function people.colours(root, extra)
  local c = cache[root]
  if not c or reaper.time_precise() - c.at > 10 then
    c = { at = reaper.time_precise(), picked = {}, members = {} }
    for _, f in ipairs(band.files(root .. "/_band/colours", ".json")) do
      local p = band.read_json(root .. "/_band/colours/" .. f)
      if type(p) == "table" and type(p.user) == "string" and math.tointeger(tonumber(p.colour)) then c.picked[p.user] = math.tointeger(tonumber(p.colour)) end
    end
    for _, f in ipairs(band.files(root .. "/plugins", ".json")) do -- (every machine publishes its plug-in list: the band's members)
      local p = band.read_json(root .. "/plugins/" .. f)
      if type(p) == "table" and type(p.user) == "string" then c.members[#c.members + 1] = p.user end
    end
    cache[root] = c
  end
  local known = {}
  for _, u in ipairs(c.members) do known[#known + 1] = u end
  for _, u in ipairs(extra or {}) do known[#known + 1] = u end
  return people.assign(c.picked, known)
end
function people.mine(cfg) return people.colours(cfg.root, { cfg.user })[cfg.user] end
-- Pick a colour (nil: back to the default).
function people.pick(cfg, rgb)
  if rgb then
    reaper.RecursiveCreateDirectory(cfg.root .. "/_band/colours", 0)
    band.write_json(file(cfg.root, cfg.user), { user = cfg.user, colour = rgb, time = os.date("!%Y-%m-%dT%H:%M:%SZ") })
  else
    os.remove(file(cfg.root, cfg.user))
  end
  cache[cfg.root] = nil
end
function people.mode() local m = reaper.GetExtState(band.SECTION, "track colours"); return m ~= "" and m or "band" end

-- Who a track shows, in this machine's mode: someone else editing it, else its claimant, else (Whose track) whoever
-- made it. `editing`: oid -> user (bandmates' edit holds); `claims`: lower track name -> { user } (sync.authority).
-- Pure apart from REAPER reads of the track.
function people.who(tr, mode, editing, claims, cfg)
  local me = cfg.user
  if mode == "band" then return nil end
  local mirror = require("mirror")
  local oid = mirror.track_oid(tr)
  local rest = oid:sub(2)
  for o, u in pairs(editing) do
    if u ~= me and (o == oid or (o:sub(1, 1) ~= "I" and o:sub(2) == rest)) then return u end -- (the track, its plug-ins, envelopes...)
  end
  for i = 0, reaper.CountTrackMediaItems(tr) - 1 do
    local u = editing[mirror.item_oid(reaper.GetTrackMediaItem(tr, i))]
    if u and u ~= me then return u end
  end
  local name = select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)):gsub(" %(band%)$", ""):lower()
  if claims[name] then return claims[name].user end
  if mode == "people" then
    local tag = mirror.creator(oid)
    if tag then
      for u in pairs(people.colours(cfg.root, { me })) do if mirror.user_tag(u) == tag then return u end end
      local now = band.names()[tag] -- (they renamed since)
      if now then return now end
    end
  end
  return nil
end

-- Show it: each mirrored track in its person's colour, or the band's. `peers`: bandmates' status files.
function people.paint(proj, cfg, peers, claims)
  local mode, editing, others = people.mode(), {}, {}
  for _, st in ipairs(peers or {}) do
    if type(st.user) == "string" then
      others[#others + 1] = st.user
      for _, o in ipairs(type(st.editing) == "table" and st.editing or {}) do editing[o] = st.user end
    end
  end
  local colours = mode ~= "band" and people.colours(cfg.root, others) or {}
  local mirror = require("mirror")
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    if not mirror.local_track(tr) then
      local u = people.who(tr, mode, editing, claims or {}, cfg)
      local rgb = u and (colours[u] or people.colours(cfg.root, { u })[u])
      band.show_colour(tr, rgb and (reaper.ColorToNative(rgb >> 16, (rgb >> 8) & 0xFF, rgb & 0xFF) | 0x1000000) or nil)
    end
  end
end

-- Setup > Options: your colour and how tracks look here. (In this file: the panel is near Lua's 200-locals limit.)
function people.options(ctx, ImGui, cfg)
  ImGui.SeparatorText(ctx, "Your colour")
  local mine = people.mine(cfg)
  local list = {}
  for _, c in ipairs(people.PALETTE) do list[#list + 1] = c end
  for _, c in ipairs({ 0xE0E0E0, 0x8A6BFF, 0x3DFF8A, 0xFFE05A }) do list[#list + 1] = c end
  for i, c in ipairs(list) do
    if i > 1 then ImGui.SameLine(ctx) end
    ImGui.PushID(ctx, i)
    local size = c == mine and 26 or 20 -- (yours: the bigger one)
    if ImGui.ColorButton(ctx, "##colour", (c << 8) | 0xFF, ImGui.ColorEditFlags_NoTooltip, size, size) then people.pick(cfg, c) end
    ImGui.PopID(ctx)
  end
  ImGui.SameLine(ctx)
  local rv, picked = ImGui.ColorEdit3(ctx, "##own", mine, ImGui.ColorEditFlags_NoInputs)
  if rv and picked ~= mine then people.pick(cfg, picked) end
  ImGui.SetItemTooltip(ctx, "Any colour of your own")
  ImGui.SameLine(ctx)
  if ImGui.SmallButton(ctx, "Default##colour") then people.pick(cfg, nil) end
  ImGui.TextDisabled(ctx, "Everyone sees you in it: your drawings, and tracks you're working on where they show that.")
  ImGui.SeparatorText(ctx, "Track colours here")
  for _, m in ipairs(people.MODES) do
    if m[1] ~= "band" then ImGui.SameLine(ctx) end
    if ImGui.RadioButton(ctx, m[2] .. "##trackcolours", people.mode() == m[1]) then reaper.SetExtState(band.SECTION, "track colours", m[1], true) end
    ImGui.SetItemTooltip(ctx, m[3] .. " Only on this computer: nobody else's colours change.")
  end
end

return people
