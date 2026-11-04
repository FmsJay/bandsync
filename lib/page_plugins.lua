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
    local helpers = require("mirror").live_fx(tr) -- (SonoBus, the live mix, NINJAM: StudioSync's own, not the project's: Mac, 0.51.9)
    for i = 0, reaper.TrackFX_GetCount(tr) - 1 do
      local ok, name = reaper.TrackFX_GetNamedConfigParm(tr, i, "fx_name")
      if not ok or name == "" then _, name = reaper.TrackFX_GetFXName(tr, i, "") end
      local key = plugins.key(name)
      local guid = reaper.TrackFX_GetFXGUID(tr, i)
      local mine = helpers[guid] or band.track_ext(tr, "band_local_fx"):find(guid, 1, true)
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
  pp.apply_drums(proj)
  return n
end

-- ---- Drum maps: every drum plug-in has its own notes for kick, snare and hats. The part stays as written; on this computer a small effect ahead of
-- the instrument moves the notes to what the plug-in here wants. Which maps a track uses is kept on the track here (P_EXT), and the effect is one of this
-- computer's own (band_local_fx), so nothing goes to anyone. The maps themselves are files in <group>/drummaps, so one made once is there for everyone.
local DRUM_TAG = "for=drummap;"
local function map_names(cfg)
  local names = { "gm" }
  for _, f in ipairs(band.files(cfg.root .. "/drummaps", ".json")) do if f ~= "gm.json" then names[#names + 1] = f:sub(1, -6) end end
  return names
end
local function words(n) return n == "gm" and "General MIDI" or n end
local function drum_fx(tr)
  local list = band.track_ext(tr, "band_local_fx")
  for g in list:gmatch("({[^}]+})" .. DRUM_TAG) do
    for i = 0, reaper.TrackFX_GetCount(tr) - 1 do
      if reaper.TrackFX_GetFXGUID(tr, i) == g then return i, g end
    end
    return nil, g
  end
end
local function drop_drum_fx(tr)
  local i, g = drum_fx(tr)
  if i then reaper.TrackFX_Delete(tr, i) end
  if g then band.set_track_ext(tr, "band_local_fx", (band.track_ext(tr, "band_local_fx"):gsub(g:gsub("%p", "%%%0") .. DRUM_TAG, ""))) end
end
-- This track's maps made true: the right effect first in its chain, or none. -> notes moved, or nil.
function pp.apply_drum_track(tr, root)
  local dm = require("drummap")
  local from, to = band.track_ext(tr, "band_drum_from"), band.track_ext(tr, "band_drum_to")
  local t = from ~= "" and to ~= "" and from ~= to and dm.table(dm.load(root, from), dm.load(root, to))
  if not t then drop_drum_fx(tr); return nil end
  local text = dm.jsfx(from, to, t)
  local file = "StudioSync drum map " .. require("mirror").hash(text):sub(1, 12) .. ".jsfx"
  local dir = reaper.GetResourcePath() .. "/Effects/BandSync"
  if band.read(dir .. "/" .. file) ~= text then
    reaper.RecursiveCreateDirectory(dir, 0)
    local f = io.open(dir .. "/" .. file, "wb")
    if not f then return nil end
    f:write(text)
    f:close()
  end
  local i = drum_fx(tr)
  if i and select(2, reaper.TrackFX_GetNamedConfigParm(tr, i, "fx_ident")):find(file, 1, true) then return t end
  drop_drum_fx(tr)
  local idx = reaper.TrackFX_AddByName(tr, "JS:BandSync/" .. file, false, -1000)
  if idx < 0 then return nil end
  band.set_track_ext(tr, "band_local_fx", band.track_ext(tr, "band_local_fx") .. reaper.TrackFX_GetFXGUID(tr, idx) .. DRUM_TAG)
  return t
end
-- Every track with maps: after the group's chain replaced this computer's own effects (mirror), or after reopening.
function pp.apply_drums(proj)
  local b = band.binding(proj)
  local cfg = band.settings()
  if not cfg then return end
  cfg = band.for_tab(cfg, b)
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    if band.track_ext(tr, "band_drum_from") ~= "" then pp.apply_drum_track(tr, cfg.root) end
  end
end

local edit_map, edit_name, edit_why
function pp.drums(ctx, ImGui, proj, cfg)
  local theme = require("theme")
  local dm = require("drummap")
  ImGui.SeparatorText(ctx, "Drum maps (this computer only)")
  ImGui.TextDisabled(ctx, "Every drum plug-in has kick, snare and hats on its own notes. If a part was written for a different plug-in than yours, say which: the notes reach your plug-in on the right drums. Nobody else's project changes, and the part stays as written.")
  local tr = reaper.GetSelectedTrack(proj, 0)
  if not tr then
    ImGui.TextColored(ctx, theme.YELLOW, "Select a drum track.")
  else
    local n = reaper.CountSelectedTracks(proj)
    ImGui.Text(ctx, n == 1 and ("Track: " .. select(2, reaper.GetTrackName(tr))) or string.format("%d tracks", n))
    local names = map_names(cfg)
    local function pick(label, id, ext)
      ImGui.AlignTextToFramePadding(ctx)
      ImGui.Text(ctx, label)
      ImGui.SameLine(ctx, 110)
      ImGui.SetNextItemWidth(ctx, math.max(120, math.min(240, ImGui.GetContentRegionAvail(ctx))))
      local cur = band.track_ext(tr, ext)
      if ImGui.BeginCombo(ctx, id, cur == "" and "not set" or words(cur)) then
        if ImGui.Selectable(ctx, "not set", cur == "") then cur = false end
        for _, m in ipairs(names) do
          if ImGui.Selectable(ctx, words(m), cur == m) then cur = m end
        end
        ImGui.EndCombo(ctx)
        if cur ~= band.track_ext(tr, ext) then
          for i = 0, n - 1 do
            local t2 = reaper.GetSelectedTrack(proj, i)
            band.set_track_ext(t2, ext, cur or "")
            pp.apply_drum_track(t2, cfg.root)
          end
        end
      end
    end
    pick("Written for", "##drumfrom", "band_drum_from")
    pick("Played here on", "##drumto", "band_drum_to")
    local from, to = band.track_ext(tr, "band_drum_from"), band.track_ext(tr, "band_drum_to")
    if from ~= "" and to ~= "" then
      local t = from ~= to and dm.table(dm.load(cfg.root, from), dm.load(cfg.root, to))
      if t then
        local c = 0
        for _ in pairs(t) do c = c + 1 end
        ImGui.TextColored(ctx, theme.GREEN, string.format("On: %d note%s moved, here only.", c, c == 1 and "" or "s"))
      else ImGui.TextDisabled(ctx, "Those two use the same notes: nothing to move.") end
    end
  end
  if ImGui.SmallButton(ctx, "Make a map...") then
    edit_map, edit_name, edit_why = {}, "", nil
    for _, k in ipairs(dm.KIT) do edit_map[k[1]] = dm.GM[k[1]] end
    ImGui.OpenPopup(ctx, "Make a drum map")
  end
  ImGui.SetItemTooltip(ctx, "Name a drum plug-in and say which note plays what. Its manual lists them, or play it and watch. Everyone in the studio can use the map once it's made; only the choice above is yours.")
  ImGui.SetNextWindowSize(ctx, 380, 520, ImGui.Cond_Appearing)
  if ImGui.BeginPopupModal(ctx, "Make a drum map", true) then
    ImGui.SetNextItemWidth(ctx, -1)
    local _, v = ImGui.InputTextWithHint(ctx, "##mapname", "the plug-in's name", edit_name)
    edit_name = v
    if ImGui.BeginChild(ctx, "kit", 0, -ImGui.GetFrameHeightWithSpacing(ctx)) then
      for _, k in ipairs(dm.KIT) do
        ImGui.AlignTextToFramePadding(ctx)
        ImGui.Text(ctx, k[2])
        ImGui.SameLine(ctx, 150)
        ImGui.SetNextItemWidth(ctx, 110)
        local ch, nv = ImGui.InputInt(ctx, "##" .. k[1], edit_map[k[1]])
        if ch then edit_map[k[1]] = math.max(0, math.min(127, nv)) end
      end
      ImGui.EndChild(ctx)
    end
    if ImGui.Button(ctx, "Save") then
      local name = band.clean(edit_name)
      if name == "" or name:lower() == "gm" then edit_why = "Give it the plug-in's name."
      else
        reaper.RecursiveCreateDirectory(cfg.root .. "/drummaps", 0)
        band.write_json(cfg.root .. "/drummaps/" .. name .. ".json", { name = name, notes = edit_map, by = cfg.user })
        ImGui.CloseCurrentPopup(ctx)
      end
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Cancel") then ImGui.CloseCurrentPopup(ctx) end
    if edit_why then ImGui.SameLine(ctx); ImGui.TextColored(ctx, theme.YELLOW, edit_why) end
    ImGui.EndPopup(ctx)
  end
end

local picking, filter, found, used_at, used, open_now, found_all = nil, "", nil, -math.huge, {}, false, 0

-- REAPER's own Add FX window, on a helper track that stays on this computer (mirror.local_track). What's picked there is read off the
-- track, and the track goes. Closing the window without picking just takes the track away again.
local browsing -- { tr, proj, u, since }
local function browse(proj, u)
  local tr = require("mirror").add_local_track(proj, "StudioSync: pick a translation", "pick")
  reaper.SetOnlyTrackSelected(tr)
  reaper.Main_OnCommand(40914, 0) -- Track: Set first selected track as last touched track (else it opens a Browse FX with nothing to add to)
  reaper.Main_OnCommand(40291, 0) -- Track: View FX chain for current/last touched track (empty, it opens Add FX)
  browsing = { tr = tr, proj = proj, u = u, since = reaper.time_precise() }
end
local function browse_tick(cfg)
  if not browsing then return end
  local h = browsing
  if not reaper.ValidatePtr2(h.proj, h.tr, "MediaTrack*") then browsing = nil; return end
  if reaper.TrackFX_GetCount(h.tr) > 0 then
    local ok, name = reaper.TrackFX_GetNamedConfigParm(h.tr, 0, "fx_name")
    if not ok or name == "" then _, name = reaper.TrackFX_GetFXName(h.tr, 0, "") end
    local js = name:match("^JS:")
    if js then
      local got, ident = reaper.TrackFX_GetNamedConfigParm(h.tr, 0, "fx_ident")
      if got and ident ~= "" then name = "JS:" .. ident:gsub("^.*[/\\]Effects[/\\]", ""):gsub("\\", "/") end
    end
    reaper.RecursiveCreateDirectory(tdir(cfg), 0)
    band.write_json(tfile(cfg, h.u.key), { key = h.u.key, from = h.u.name, to = name, by = cfg.user, time = os.date("!%Y-%m-%dT%H:%M:%SZ") })
    band.log("translation for " .. (h.u.name:gsub("^%w+:%s*", "")) .. ": " .. (name:gsub("^%w+:%s*", "")))
    reaper.DeleteTrack(h.tr)
    browsing = nil
  elseif reaper.time_precise() - h.since > 1.5 and reaper.TrackFX_GetChainVisible(h.tr) == -1
      -- (the Add FX window doesn't count as the chain being open: the helper track went from under it, and its Add button greyed out)
      -- (on a Mac, Cancel only hides it: visible or not is what counts. Mac, 0.50.4)
      and (reaper.JS_Window_Find and not (function()
          local w = reaper.JS_Window_Find("Browse FX", true) or reaper.JS_Window_Find("Add FX to", false)
          return w and reaper.JS_Window_IsVisible(w)
        end)() or reaper.time_precise() - h.since > 300) then
    reaper.DeleteTrack(h.tr)
    browsing = nil
  end
end

function pp.draw(ctx, ImGui, proj, cfg)
  browse_tick(cfg)
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
  ImGui.TextDisabled(ctx, "Plug-ins in this project, who doesn't have them, and the studio's translation for them.")
  if ImGui.Button(ctx, "Apply translations here") then
    band.log(pp.apply_here(proj, cfg) .. " translation(s) added on this machine (only here: they never go to the others)")
    used_at = -math.huge
  end
  ImGui.SetItemTooltip(ctx, "Adds the studio's translation right after each plug-in this machine doesn't have, so you hear something close. " ..
    "Only on this machine; the original stays in the project for everyone who has it.")
  if ImGui.BeginTable(ctx, "plugs", 4, ImGui.TableFlags_RowBg | ImGui.TableFlags_SizingStretchProp | ImGui.TableFlags_ScrollY) then
    ImGui.TableSetupScrollFreeze(ctx, 0, 1)
    ImGui.TableSetupColumn(ctx, "Plug-in")
    ImGui.TableSetupColumn(ctx, "Tracks")
    ImGui.TableSetupColumn(ctx, "Missing for")
    ImGui.TableSetupColumn(ctx, "Translation", ImGui.TableColumnFlags_WidthFixed, 120) -- (long track lists squeezed out its button)
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
      else ImGui.TextColored(ctx, require("theme").YELLOW, table.concat(miss, ", ")) end
      ImGui.TableNextColumn(ctx)
      ImGui.PushID(ctx, u.key)
      local t = tmap[u.key]
      if t then ImGui.Text(ctx, (t.to:gsub("^%w+:%s*", ""))) end
      if ImGui.SmallButton(ctx, t and "Change" or "Set") then browse(proj, u) end
      ImGui.SetItemTooltip(ctx, "Opens REAPER's Add FX window: pick something close. Right-click for a plain list of your plug-ins instead.")
      if ImGui.IsItemClicked(ctx, 1) then picking, filter, found, open_now = u, "", nil, true end
      if t then
        ImGui.SameLine(ctx)
        if ImGui.SmallButton(ctx, "x") and reaper.MB("Remove the studio's translation for " .. (u.name:gsub("^%w+:%s*", "")) .. "?", "StudioSync", 4) == 6 then
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
  if browsing then ImGui.TextColored(ctx, require("theme").YELLOW, "Pick a plug-in in REAPER's window (close it to cancel).") end
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
