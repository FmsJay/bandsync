-- Colouring a whole project at once (James, 2026-11-04): a gradient, by folder, by instrument, by who made it and a few more for tracks; regions by section or along the song.
-- It's the studio's colour, so it goes to everyone like any colour change. Who's working (lib/people.lua) still shows on top where a computer has that on.
local band = require("band")
local colours = {}

-- Colours are 0xRRGGBB here; REAPER's native form only at the edges (native below).
colours.PALETTES = {
  { "Sunset", { 0x2F7BFF, 0x8A5BE8, 0xFF8A3D } }, -- (the logo's: blue to orange through violet, as straight across goes grey)
  { "Ocean", { 0x0B3C5D, 0x1F8FB3, 0x6FE3D6 } },
  { "Forest", { 0x1E4D2B, 0x5E9E4A, 0xD9D26A } },
  { "Ember", { 0x5A1A2B, 0xD1493F, 0xFFC15A } },
  { "Neon", { 0xFF3DA5, 0x7A5CFF, 0x2DE2E6 } },
  { "Pastel", { 0xF7B2C4, 0xB8C7F9, 0xB4EBD4 } },
  { "Greys", { 0x3A4150, 0x7E8798, 0xD5DAE3 } },
}
colours.SCHEMES = {
  { "gradient", "Gradient", "Top track to bottom track, smoothly through the palette." },
  { "folders", "By folder", "Each folder its own colour, the tracks inside it shades of that." },
  { "instrument", "By instrument", "From the track's name: drums, bass, guitars, keys, synths, vocals, strings and horns, buses." },
  { "person", "By who made it", "Each track in the colour of the person who made it, kept even when nobody's working." },
  { "stripes", "Stripes", "Two colours taking turns, folder by folder: easy to follow across a long list." },
  { "rainbow", "Rainbow", "The whole colour wheel, top to bottom." },
  { "newest", "Newest work", "The longest untouched cool, the latest changed warm: where the project's been moving lately." },
  { "confetti", "Confetti", "A bright colour of its own for each name, the same every time." },
}

function colours.mix(a, b, t)
  local function ch(s) return math.floor(((a >> s) & 255) + (((b >> s) & 255) - ((a >> s) & 255)) * t + 0.5) end
  return (ch(16) << 16) | (ch(8) << 8) | ch(0)
end
-- A place (0 to 1) along a list of colours.
function colours.ramp(stops, t)
  if #stops == 1 then return stops[1] end
  t = math.max(0, math.min(1, t)) * (#stops - 1)
  local i = math.min(#stops - 2, math.floor(t))
  return colours.mix(stops[i + 1], stops[i + 2], t - i)
end
function colours.hsv(h, s, v)
  local i, f = math.floor(h * 6) % 6, h * 6 - math.floor(h * 6)
  local p, q, u = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
  local r, g, b = ({ v, q, p, p, u, v })[i + 1], ({ u, v, v, q, p, p })[i + 1], ({ p, p, u, v, v, q })[i + 1]
  return (math.floor(r * 255 + 0.5) << 16) | (math.floor(g * 255 + 0.5) << 8) | math.floor(b * 255 + 0.5)
end

-- What a name says it is. First match wins, so "bass drum" is drums and "vocal bus" is a bus.
local KINDS = {
  { 0x8A93A6, { "bus", "master", "reverb", "verb", "delay", "aux", "return", "%f[%a]fx%f[%A]" } },
  { 0xE5584F, { "drum", "kick", "snare", "%f[%a]hat", "tom%f[%A]", "perc", "shaker", "cymbal", "overhead", "%f[%a]oh%f[%A]", "tamb", "clap" } },
  { 0xF2A33A, { "bass", "%f[%a]sub%f[%A]" } },
  { 0x57B85A, { "guitar", "gtr", "acoustic", "riff" } },
  { 0x4C9BE8, { "piano", "keys", "%f[%a]key", "organ", "rhodes", "wurli" } },
  { 0x9A6BE8, { "synth", "%f[%a]pad", "arp", "pluck" } },
  { 0xF06BAF, { "vox", "vocal", "voc%f[%A]", "sing", "harmony", "bgv", "choir", "%f[%a]lead" } },
  { 0x36C4B4, { "string", "violin", "viola", "cello", "brass", "horn", "trumpet", "sax", "flute" } },
}
colours.OTHER = 0xA9B0BD
function colours.kind_of(name)
  local n = (name or ""):lower()
  for _, k in ipairs(KINDS) do
    for _, w in ipairs(k[2]) do if n:find(w) then return k[1] end end
  end
  return colours.OTHER
end

local function hash01(s)
  local h = 2166136261
  for i = 1, #s do h = ((h ~ s:byte(i)) * 16777619) & 0xFFFFFFFF end
  return h / 0xFFFFFFFF
end

-- The colour of each track. tracks: { { name, family (its top-level folder's number), maker (a colour, or nil), newest ("" if unknown) } }.
-- opt: { stops }. Pure.
function colours.plan(tracks, scheme, opt)
  local stops, n, out = opt.stops, #tracks, {}
  local families, members = 0, {}
  for _, t in ipairs(tracks) do
    families = math.max(families, t.family or 0)
    members[t.family or 0] = (members[t.family or 0] or 0) + 1
  end
  local rank = {}
  if scheme == "newest" then
    local order = {}
    for i, t in ipairs(tracks) do order[i] = i end
    table.sort(order, function(a, z)
      if (tracks[a].newest or "") ~= (tracks[z].newest or "") then return (tracks[a].newest or "") < (tracks[z].newest or "") end
      return a < z
    end)
    for r, i in ipairs(order) do rank[i] = r end
  end
  local seen = {}
  for i, t in ipairs(tracks) do
    local f, at = t.family or 0, i == 1 and 0 or (i - 1) / math.max(1, n - 1)
    seen[f] = (seen[f] or 0) + 1
    if scheme == "gradient" then out[i] = colours.ramp(stops, at)
    elseif scheme == "folders" then
      local base = colours.ramp(stops, families > 1 and (f - 1) / (families - 1) or 0)
      out[i] = colours.mix(base, 0xFFFFFF, (members[f] or 1) > 1 and 0.45 * (seen[f] - 1) / (members[f] - 1) or 0)
    elseif scheme == "instrument" then out[i] = colours.kind_of(t.name)
    elseif scheme == "person" then out[i] = t.maker or colours.OTHER
    elseif scheme == "stripes" then out[i] = f % 2 == 1 and stops[1] or stops[#stops]
    elseif scheme == "rainbow" then out[i] = colours.hsv(at * 0.85, 0.72, 0.95)
    elseif scheme == "newest" then out[i] = colours.ramp(stops, n > 1 and (rank[i] - 1) / (n - 1) or 1)
    elseif scheme == "confetti" then out[i] = colours.hsv(hash01((t.name or "") .. "!"), 0.65 + hash01(t.name or "") * 0.2, 0.95)
    else out[i] = colours.OTHER end
  end
  return out
end

-- The common sections keep a colour of their own in every song, whatever the palette: you learn them.
local SECTIONS = { intro = 0x7E8798, verse = 0x4C9BE8, pre = 0x36C4B4, prechorus = 0x36C4B4, chorus = 0xF2A33A, hook = 0xF2A33A, bridge = 0x9A6BE8, solo = 0xF06BAF,
  ["break"] = 0x57B85A, breakdown = 0x57B85A, drop = 0xE5584F, outro = 0x7E8798, ending = 0x7E8798, tag = 0xC9A15A, interlude = 0x57B85A }
function colours.section_key(name)
  return (name or ""):lower():gsub("[^%a]", " "):gsub("^%s*pre%s+chorus", "prechorus"):match("%a+") or ""
end
-- The colour of each region or marker. marks: { { name, region } }. mode: "sections" (the same section, the same colour) or "song" (along the song). Pure.
function colours.plan_marks(marks, mode, stops)
  local out, regions, at, other, n = {}, 0, 0, {}, 0
  for _, m in ipairs(marks) do if m.region then regions = regions + 1 end end
  for i, m in ipairs(marks) do
    if mode == "song" then
      out[i] = colours.ramp(stops, regions > 1 and at / (regions - 1) or 0)
      if m.region then at = at + 1 end
    else
      local key = colours.section_key(m.name)
      if SECTIONS[key] then out[i] = SECTIONS[key]
      elseif key == "" then out[i] = colours.OTHER
      else
        if not other[key] then n = n + 1; other[key] = colours.ramp(stops, (n * 0.381966) % 1) end -- (spread out however many there turn out to be)
        out[i] = other[key]
      end
    end
  end
  return out
end

local function native(rgb) return reaper.ColorToNative(rgb >> 16, (rgb >> 8) & 255, rgb & 255) | 0x1000000 end

-- What the plan needs to know of this project's tracks: the same order as CountTracks, the helpers left out.
function colours.read(proj, cfg)
  local mirror, people = require("mirror"), require("people")
  local by_tag = {}
  for u, c in pairs(people.colours(cfg.root, { cfg.user })) do by_tag[mirror.user_tag(u)] = c end
  local list, depth, family = {}, 0, 0
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    if depth == 0 then family = family + 1 end
    if not mirror.local_track(tr) then
      local oid = mirror.track_oid(tr)
      local newest = ""
      local function look(o)
        local _, _, ev = mirror.known(proj, o)
        local stamp = (ev or ""):match("%d%d%d%d%d%d%d%d%-%d%d%d%d%d%dZ")
        if stamp and stamp > newest then newest = stamp end
      end
      look(oid)
      for k = 0, reaper.CountTrackMediaItems(tr) - 1 do look(mirror.item_oid(reaper.GetTrackMediaItem(tr, k))) end
      list[#list + 1] = { ptr = tr, name = (select(2, reaper.GetTrackName(tr)):gsub(" %(band%)$", "")), family = family, maker = by_tag[mirror.creator(oid)], newest = newest }
    end
    depth = depth + math.floor(reaper.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH"))
    if depth < 0 then depth = 0 end
  end
  return list
end

-- Colours what this person may change. -> how many coloured, how many left because they're someone else's.
function colours.apply(proj, cfg, list, plan, may, only_selected)
  local done, left = 0, 0
  reaper.Undo_BeginBlock2(proj) -- (not named after StudioSync: Ctrl+Z is REAPER's own undo, and takes all of it back)
  for i, t in ipairs(list) do
    if not only_selected or reaper.IsTrackSelected(t.ptr) then
      if may(t.name) then band.set_track_colour(t.ptr, native(plan[i])); done = done + 1 else left = left + 1 end
    end
  end
  reaper.Undo_EndBlock2(proj, "Colour tracks", 1)
  reaper.TrackList_AdjustWindows(false)
  return done, left
end

function colours.apply_marks(proj, mode, stops)
  local marks, idx = {}, {}
  for i = 0, reaper.CountProjectMarkers(proj) - 1 do
    local _, region, pos, rend, name, num = reaper.EnumProjectMarkers3(proj, i)
    if not band.is_local_mark(name) then
      marks[#marks + 1] = { region = region, name = name }
      idx[#idx + 1] = { i = i, region = region, pos = pos, rend = rend, name = name, num = num }
    end
  end
  local plan = colours.plan_marks(marks, mode, stops)
  reaper.Undo_BeginBlock2(proj)
  for k, m in ipairs(idx) do reaper.SetProjectMarkerByIndex2(proj, m.i, m.region, m.pos, m.rend, m.num, m.name, native(plan[k]), 0) end
  reaper.Undo_EndBlock2(proj, "Colour regions", 8)
  reaper.UpdateTimeline()
  return #idx
end

-- The Settings card. (In this file: the panel is near Lua's 200-locals limit.) may(name): this person may change that track. timeline_ok: the driver, or anyone in Anyone.
local cache = { at = -math.huge }
function colours.draw(ctx, ImGui, proj, cfg, may, timeline_ok)
  ImGui.SeparatorText(ctx, "Colour the project")
  local function saved(key, default) local v = reaper.GetExtState(band.SECTION, key); return v ~= "" and v or default end
  local scheme, palette = saved("colour scheme", "gradient"), saved("colour palette", "Sunset")
  local a, z = tonumber(saved("colour from", "2F7BFF"), 16) or 0x2F7BFF, tonumber(saved("colour to", "FF8A3D"), 16) or 0xFF8A3D
  local label, tip = scheme, ""
  for _, s in ipairs(colours.SCHEMES) do if s[1] == scheme then label, tip = s[2], s[3] end end
  ImGui.SetNextItemWidth(ctx, 170)
  if ImGui.BeginCombo(ctx, "##colourscheme", label) then
    for _, s in ipairs(colours.SCHEMES) do
      if ImGui.Selectable(ctx, s[2], s[1] == scheme) then reaper.SetExtState(band.SECTION, "colour scheme", s[1], true); scheme = s[1]; cache.at = -math.huge end
      ImGui.SetItemTooltip(ctx, s[3])
    end
    ImGui.EndCombo(ctx)
  end
  ImGui.SetItemTooltip(ctx, tip)
  local uses = scheme == "gradient" or scheme == "folders" or scheme == "stripes" or scheme == "newest"
  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, 120)
  if ImGui.BeginCombo(ctx, "##colourpalette", palette) then
    for _, p in ipairs(colours.PALETTES) do
      if ImGui.Selectable(ctx, p[1], p[1] == palette) then reaper.SetExtState(band.SECTION, "colour palette", p[1], true); palette = p[1]; cache.at = -math.huge end
    end
    if ImGui.Selectable(ctx, "Your own", palette == "Your own") then reaper.SetExtState(band.SECTION, "colour palette", "Your own", true); palette = "Your own"; cache.at = -math.huge end
    ImGui.EndCombo(ctx)
  end
  ImGui.SetItemTooltip(ctx, uses and "The colours it runs through. Regions use it too." or "For regions along the song. This way of colouring tracks has its own colours.")
  local stops = { a, z }
  for _, p in ipairs(colours.PALETTES) do if p[1] == palette then stops = p[2] end end
  if palette == "Your own" then
    ImGui.SameLine(ctx)
    local ch1, v1 = ImGui.ColorEdit3(ctx, "##colourfrom", a, ImGui.ColorEditFlags_NoInputs)
    ImGui.SameLine(ctx)
    local ch2, v2 = ImGui.ColorEdit3(ctx, "##colourto", z, ImGui.ColorEditFlags_NoInputs)
    if ch1 then reaper.SetExtState(band.SECTION, "colour from", string.format("%06X", v1), true); cache.at = -math.huge end
    if ch2 then reaper.SetExtState(band.SECTION, "colour to", string.format("%06X", v2), true); cache.at = -math.huge end
  end
  if reaper.time_precise() - cache.at > 2 or cache.proj ~= proj then
    cache.at, cache.proj = reaper.time_precise(), proj
    cache.list = colours.read(proj, cfg)
    cache.plan = colours.plan(cache.list, scheme, { stops = stops })
  end
  local w = ImGui.GetContentRegionAvail(ctx)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local dl, n = ImGui.GetWindowDrawList(ctx), #cache.list
  for i, rgb in ipairs(cache.plan) do
    local x0 = x + (i - 1) * w / n
    ImGui.DrawList_AddRectFilled(dl, x0, y, x0 + w / n - 1, y + 16, (rgb << 8) | 0xFF, 2)
  end
  ImGui.InvisibleButton(ctx, "##colourpreview", math.max(1, w), 16)
  if ImGui.IsItemHovered(ctx) and n > 0 then
    local i = math.max(1, math.min(n, math.floor((select(1, ImGui.GetMousePos(ctx)) - x) / w * n) + 1))
    ImGui.SetTooltip(ctx, cache.list[i].name)
  end
  if ImGui.Button(ctx, "Colour all tracks") then colours.run(proj, cfg, may, false) end
  ImGui.SetItemTooltip(ctx, "Every track you may change. Someone else's stays as it is.")
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Selected only") then colours.run(proj, cfg, may, true) end
  ImGui.SetItemTooltip(ctx, "Only the tracks selected in REAPER.")
  ImGui.BeginDisabled(ctx, not timeline_ok)
  if ImGui.Button(ctx, "Regions by section") then band.log(string.format("coloured %d regions and markers: the same section, the same colour", colours.apply_marks(proj, "sections", stops))) end
  ImGui.EndDisabled(ctx)
  ImGui.SetItemTooltip(ctx, timeline_ok and "Every verse one colour, every chorus another. It goes to everyone." or "The timeline is the driver's: they do this.")
  ImGui.SameLine(ctx)
  ImGui.BeginDisabled(ctx, not timeline_ok)
  if ImGui.Button(ctx, "Regions along the song") then band.log(string.format("coloured %d regions and markers along the song", colours.apply_marks(proj, "song", stops))) end
  ImGui.EndDisabled(ctx)
  ImGui.SetItemTooltip(ctx, timeline_ok and "Start to end, through the palette." or "The timeline is the driver's: they do this.")
  ImGui.TextDisabled(ctx, "Goes to everyone, and Ctrl+Z takes it back. Who's working still shows on top.")
end
function colours.run(proj, cfg, may, only_selected)
  local done, left = colours.apply(proj, cfg, cache.list, cache.plan, may, only_selected)
  band.log(string.format("coloured %d track%s%s", done, done == 1 and "" or "s", left > 0 and string.format(": %d someone else's left as they are", left) or ""))
end

return colours
