-- The panel's Plugins page: every plug-in this project uses, who in the band doesn't have it, and the band's
-- translations (a plug-in someone has instead, close enough to hear the idea). A translation is added only on a
-- machine missing the original, right after it, and is that machine's own: mirror sync never sends it
-- (track P_EXT band_local_fx lists those FX ids).
local band = require("band")
local plugins = require("plugins")
local pp = {}

local function tdir(cfg) return cfg.root .. "/plugins/translations" end
local function tfile(cfg, key) return tdir(cfg) .. "/" .. require("mirror").hash(key) .. ".json" end

function pp.translations(cfg)
  local t = {}
  for _, f in ipairs(band.files(tdir(cfg), ".json")) do
    local v = band.read_json(tdir(cfg) .. "/" .. f)
    if type(v) == "table" and v.key and v.to then t[v.key] = v end
  end
  return t
end

-- { {key, name, tracks = {names}, fx = { {tr, idx} }} } for every plug-in on every track (and the master).
function pp.used(proj)
  local by, out = {}, {}
  local function scan(tr, tname)
    for i = 0, reaper.TrackFX_GetCount(tr) - 1 do
      local ok, name = reaper.TrackFX_GetNamedConfigParm(tr, i, "fx_name")
      if not ok or name == "" then _, name = reaper.TrackFX_GetFXName(tr, i, "") end
      local key = plugins.key(name)
      local guid = reaper.TrackFX_GetFXGUID(tr, i)
      local mine = band.track_ext(tr, "band_local_fx"):find(guid, 1, true)
      if not mine then
        local u = by[key]
        if not u then u = { key = key, name = name, tracks = {}, fx = {} }; by[key] = u; out[#out + 1] = u end
        if u.tracks[#u.tracks] ~= tname then u.tracks[#u.tracks + 1] = tname end
        u.fx[#u.fx + 1] = { tr = tr, idx = i, guid = guid }
      end
    end
  end
  scan(reaper.GetMasterTrack(proj), "Master")
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    local _, n = reaper.GetTrackName(tr)
    scan(tr, n)
  end
  table.sort(out, function(a, x) return a.key < x.key end)
  return out
end

-- Add the band's translation next to every plug-in this machine doesn't have. Returns how many were added.
function pp.apply_here(proj, cfg)
  local have = {}
  for _, p in ipairs(plugins.installed()) do have[plugins.key(p.name)] = true end
  local tr_map, n = pp.translations(cfg), 0
  for _, u in ipairs(pp.used(proj)) do
    local t = tr_map[u.key]
    if t and not have[u.key] then
      for k = #u.fx, 1, -1 do -- from the end, so indexes stay right as FX are added
        local f = u.fx[k]
        local list = band.track_ext(f.tr, "band_local_fx")
        if not list:find("for=" .. f.guid, 1, true) then
          local idx = reaper.TrackFX_AddByName(f.tr, t.to, false, -1000 - (f.idx + 1)) -- right after the original
          if idx >= 0 then
            local g = reaper.TrackFX_GetFXGUID(f.tr, idx)
            reaper.TrackFX_SetNamedConfigParm(f.tr, idx, "renamed_name", "[for " .. u.name:gsub("^%w+:%s*", "") .. "] " .. t.to:gsub("^%w+:%s*", ""))
            band.set_track_ext(f.tr, "band_local_fx", list .. g .. "for=" .. f.guid .. ";")
            n = n + 1
          end
        end
      end
    end
  end
  return n
end

local picking, filter, found, used_at, used, open_now, found_all = nil, "", nil, -math.huge, {}, false, 0

function pp.draw(ctx, ImGui, proj, cfg)
  if reaper.time_precise() - used_at > 3 then used_at, used = reaper.time_precise(), pp.used(proj) end
  local lists = {}
  for _, f in ipairs(band.files(cfg.root .. "/plugins", ".json")) do
    local l = band.read_json(cfg.root .. "/plugins/" .. f)
    if type(l) == "table" and type(l.names) == "table" and l.user then
      local set = {}
      for _, k in ipairs(l.names) do set[k] = true end
      lists[#lists + 1] = { user = l.user, set = set }
    end
  end
  local tmap = pp.translations(cfg)
  ImGui.TextDisabled(ctx, "Plug-ins in this project, who doesn't have them, and the band's translation for them.")
  if ImGui.Button(ctx, "Apply translations here") then
    band.log(pp.apply_here(proj, cfg) .. " translation(s) added on this machine (only here: they never go to the band)")
    used_at = -math.huge
  end
  ImGui.SetItemTooltip(ctx, "Adds the band's translation right after each plug-in this machine doesn't have, so you hear something close. " ..
    "Only on this machine; the original stays in the project for everyone who has it.")
  if ImGui.BeginTable(ctx, "plugs", 4, ImGui.TableFlags_RowBg | ImGui.TableFlags_SizingStretchProp | ImGui.TableFlags_ScrollY) then
    ImGui.TableSetupScrollFreeze(ctx, 0, 1)
    ImGui.TableSetupColumn(ctx, "Plug-in")
    ImGui.TableSetupColumn(ctx, "Tracks")
    ImGui.TableSetupColumn(ctx, "Missing for")
    ImGui.TableSetupColumn(ctx, "Translation")
    ImGui.TableHeadersRow(ctx)
    for _, u in ipairs(used) do
      ImGui.TableNextRow(ctx)
      ImGui.TableNextColumn(ctx); ImGui.Text(ctx, (u.name:gsub("^%w+:%s*", "")))
      ImGui.TableNextColumn(ctx); ImGui.TextDisabled(ctx, table.concat(u.tracks, ", "))
      ImGui.TableNextColumn(ctx)
      local miss = {}
      for _, l in ipairs(lists) do if not l.set[u.key] then miss[#miss + 1] = l.user end end
      if u.key:find("%.jsfx?$") or u.name:match("^JS:") then ImGui.TextDisabled(ctx, "everyone (JSFX)")
      elseif #miss == 0 then ImGui.TextDisabled(ctx, "nobody")
      else ImGui.TextColored(ctx, 0xF2BF40FF, table.concat(miss, ", ")) end
      ImGui.TableNextColumn(ctx)
      ImGui.PushID(ctx, u.key)
      local t = tmap[u.key]
      if t then ImGui.Text(ctx, (t.to:gsub("^%w+:%s*", ""))); ImGui.SameLine(ctx) end
      if ImGui.SmallButton(ctx, t and "Change" or "Set") then picking, filter, found, open_now = u, "", nil, true end
      if t then
        ImGui.SameLine(ctx)
        if ImGui.SmallButton(ctx, "x") and reaper.MB("Remove the band's translation for " .. (u.name:gsub("^%w+:%s*", "")) .. "?", "BandSync", 4) == 6 then
          os.remove(tfile(cfg, u.key))
          require("band").log("removed the translation for " .. (u.name:gsub("^%w+:%s*", "")))
        end
        ImGui.SetItemTooltip(ctx, "Remove this translation (set by " .. tostring(t.by) .. ")")
      end
      ImGui.PopID(ctx)
    end
    ImGui.EndTable(ctx)
  end
  if #used == 0 then ImGui.TextDisabled(ctx, "No plug-ins in this project yet.") end
  if open_now then ImGui.OpenPopup(ctx, "Pick a translation"); open_now = false end -- (outside the table's ID scope)
  if ImGui.BeginPopupModal(ctx, "Pick a translation", true, ImGui.WindowFlags_AlwaysAutoResize) then
    ImGui.Text(ctx, "Something close to " .. (picking.name:gsub("^%w+:%s*", "")) .. ", from your plug-ins:")
    ImGui.SetNextItemWidth(ctx, 360)
    local ch
    ch, filter = ImGui.InputTextWithHint(ctx, "##f", "type to search", filter)
    if ch or not found then
      found, found_all = {}, 0
      local f = filter:lower()
      for _, p in ipairs(plugins.installed()) do
        if f == "" or p.name:lower():find(f, 1, true) then
          found_all = found_all + 1
          if #found < 200 then found[#found + 1] = p.name end
        end
      end
    end
    if found_all > #found then ImGui.TextDisabled(ctx, string.format("showing %d of %d: type to narrow it down", #found, found_all)) end
    if ImGui.BeginListBox(ctx, "##list", 360, 220) then
      for _, name in ipairs(found) do
        if ImGui.Selectable(ctx, name, false) then
          reaper.RecursiveCreateDirectory(tdir(cfg), 0)
          band.write_json(tfile(cfg, picking.key), { key = picking.key, from = picking.name, to = name, by = cfg.user,
            time = os.date("!%Y-%m-%dT%H:%M:%SZ") })
          picking = nil
          ImGui.CloseCurrentPopup(ctx)
        end
      end
      ImGui.EndListBox(ctx)
    end
    ImGui.EndPopup(ctx)
  end
  if picking and not ImGui.IsPopupOpen(ctx, "Pick a translation") then picking = nil end
end

return pp
