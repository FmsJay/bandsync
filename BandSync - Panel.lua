-- @description BandSync: control panel (sync, bandmates, who drives, who owns what, recall points)
-- One dockable window for everything BandSync does in the project in front: start/stop Live sync, hold
-- it while you try things, see who has what, take control, claim tracks and regions, and save/restore
-- recall points. Needs ReaImGui (ReaPack: "ReaImGui: ReaScript binding for Dear ImGui").
local dir = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
package.path = dir .. "/lib/?.lua;" .. package.path
local band = require("band")
local sync = require("sync")
local recall = require("recall")
local status = require("status")

if not reaper.APIExists("ImGui_GetBuiltinPath") then
  return band.msg("The panel needs ReaImGui. Install it with ReaPack (Extensions > ReaPack > Browse packages: ReaImGui), then run this again.")
end
package.path = reaper.ImGui_GetBuiltinPath() .. "/?.lua;" .. package.path
local ImGui = require "imgui" "0.10"

local cfg = band.settings()
if not cfg then return end

local _, _, section, cmd = reaper.get_action_context()
if cmd > 0 then reaper.SetToggleCommandState(section, cmd, 1); reaper.RefreshToolbar2(section, cmd) end
reaper.atexit(function() if cmd > 0 then reaper.SetToggleCommandState(section, cmd, 0); reaper.RefreshToolbar2(section, cmd) end end)

local ctx = ImGui.CreateContext("BandSync")
local GREEN, YELLOW, GREY, RED = 0x59CC73FF, 0xF2BF40FF, 0x8C8C8CFF, 0xE0605AFF
local function rgba(c) return math.floor(c[1] * 255) << 24 | math.floor(c[2] * 255) << 16 | math.floor(c[3] * 255) << 8 | 0xFF end

-- Actions run as REAPER actions (so they see their own action context), registered on first use.
local ids = {}
local function action(name)
  ids[name] = ids[name] or reaper.AddRemoveReaScript(true, 0, dir .. "/BandSync - " .. name .. ".lua", true)
  if ids[name] > 0 then reaper.Main_OnCommand(ids[name], 0) end
end

local proj, b, view, can, who, points, last, err = nil, nil, nil, nil, nil, {}, 0, nil
local label = ""
local function refresh()
  proj = reaper.EnumProjects(-1)
  b = band.binding(proj)
  if not b then return end
  view = status.gather(cfg, b, proj)
  can, who = sync.authority(cfg, b.song, b.room, view.session)
  points = recall.list(cfg, b.song, b.room)
end

-- What a track is called for ownership: a "(MIDI)" copy track and a "(band)" mirror belong to their part.
local function part_name(tr)
  local m = band.track_ext(tr, "band_midi_track")
  return m ~= "" and m or sync.base_name(select(2, reaper.GetTrackName(tr)))
end
local function claim(tracks, regions)
  local c = sync.my_claims(cfg, b.song, b.room)
  c.tracks, c.regions = c.tracks or {}, c.regions or {}
  local function add(list, name)
    for _, n in ipairs(list) do if n:lower() == name:lower() then return end end
    list[#list + 1] = name
  end
  for _, n in ipairs(tracks) do add(c.tracks, n) end
  for _, n in ipairs(regions) do add(c.regions, n) end
  sync.set_claims(cfg, b.song, b.room, c)
end

local function section_sync()
  ImGui.SeparatorText(ctx, "Sync")
  local key = tostring(proj)
  local beat = tonumber(reaper.GetExtState(band.SECTION, "live " .. key))
  local running = beat and reaper.time_precise() - beat < 5
  ImGui.TextColored(ctx, running and GREEN or RED, running and "Live sync is running" or "Live sync is not running")
  ImGui.SameLine(ctx)
  if ImGui.SmallButton(ctx, running and "Stop" or "Start") then
    if running then reaper.SetExtState(band.SECTION, "stop " .. key, "1", false) -- Live sync sees it on its next tick
    else reaper.DeleteExtState(band.SECTION, "stop " .. key, false); action("Live sync") end
  end
  local hold = select(2, reaper.GetProjExtState(proj, band.SECTION, "hold")) ~= ""
  local changed, v = ImGui.Checkbox(ctx, "Hold sync (try things; your changes go out once, when you release)", hold)
  if changed then reaper.SetProjExtState(proj, band.SECTION, "hold", v and "1" or "") end
  ImGui.Text(ctx, string.format("Here: %d/%d takes%s", view.total - view.my_missing, view.total,
    view.my_missing > 0 and (", " .. view.my_missing .. " still arriving") or ""))
  if view.newer then
    ImGui.TextColored(ctx, YELLOW, "BandSync " .. view.newer .. " is in use here; you have " .. band.VERSION .. ".")
    ImGui.SameLine(ctx)
    if ImGui.SmallButton(ctx, "Update") then action("Update") end
  end
end

local function section_band()
  ImGui.SeparatorText(ctx, "Bandmates")
  if #view.rows == 0 then return ImGui.TextDisabled(ctx, "Nobody else has synced in this room yet.") end
  if ImGui.BeginTable(ctx, "mates", 5, ImGui.TableFlags_RowBg | ImGui.TableFlags_SizingStretchProp) then
    for _, h in ipairs({ "Who", "State", "Seen", "Has", "Version" }) do ImGui.TableSetupColumn(ctx, h) end
    ImGui.TableHeadersRow(ctx)
    for _, r in ipairs(view.rows) do
      local c = rgba(status.COLORS[r.state])
      ImGui.TableNextRow(ctx)
      ImGui.TableNextColumn(ctx); ImGui.Text(ctx, r.name .. (r.name == view.driver and "  (driving)" or ""))
      ImGui.TableNextColumn(ctx); ImGui.TextColored(ctx, c, r.state)
      ImGui.TableNextColumn(ctx); ImGui.TextColored(ctx, c, status.ago(r.age))
      ImGui.TableNextColumn(ctx); ImGui.TextColored(ctx, c, r.has .. "/" .. view.total)
      ImGui.TableNextColumn(ctx); ImGui.TextColored(ctx, r.version == band.VERSION and GREY or YELLOW, r.version)
    end
    ImGui.EndTable(ctx)
  end
end

local function section_control()
  ImGui.SeparatorText(ctx, "Who changes what")
  local driving = view.driver == cfg.user
  ImGui.Text(ctx, driving and "You're driving: what nobody has claimed follows you." or (tostring(view.driver) .. " is driving."))
  if not driving then
    ImGui.SameLine(ctx)
    if ImGui.SmallButton(ctx, "Take control") then action("Take control") end
  end
  local owned = {}
  for name, c in pairs(who.tracks) do owned[#owned + 1] = string.format("track %s: %s", c.name or name, c.user) end
  for name, c in pairs(who.regions) do owned[#owned + 1] = string.format("region %s: %s", c.name or name, c.user) end
  table.sort(owned)
  if #owned == 0 then ImGui.TextDisabled(ctx, "Nothing claimed: everything follows the driver.") end
  for _, o in ipairs(owned) do ImGui.BulletText(ctx, o) end
  if ImGui.Button(ctx, "Claim selected tracks") then
    local list = {}
    for i = 0, reaper.CountSelectedTracks(proj) - 1 do list[#list + 1] = part_name(reaper.GetSelectedTrack(proj, i)) end
    if #list == 0 then band.msg("Select the tracks you want to own first.") else claim(list, {}) end
  end
  ImGui.SetItemTooltip(ctx, "Only you can move, trim, delete or re-pick takes on them; everyone follows you there.")
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Claim region at cursor") then
    local _, ri = reaper.GetLastMarkerAndCurRegion(proj, reaper.GetCursorPositionEx(proj))
    local _, isrgn, _, _, name = reaper.EnumProjectMarkers3(proj, ri)
    if ri < 0 or not isrgn or name == "" then band.msg("Put the edit cursor inside a named region first.") else claim({}, { name }) end
  end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Release mine") then sync.set_claims(cfg, b.song, b.room, { tracks = {}, regions = {} }) end
end

local function section_recall()
  ImGui.SeparatorText(ctx, "Recall points")
  ImGui.SetNextItemWidth(ctx, -90)
  local _, v = ImGui.InputTextWithHint(ctx, "##label", "name this version (e.g. 'chorus with double guitars')", label, ImGui.InputTextFlags_None)
  label = v
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Save point") then
    recall.save(proj, cfg, b.song, b.room, label ~= "" and label or "saved by " .. cfg.user)
    label = ""
    last = 0
  end
  local driving = view.driver == cfg.user
  if ImGui.BeginChild(ctx, "points", 0, 160, ImGui.ChildFlags_Borders) then
    if #points == 0 then ImGui.TextDisabled(ctx, "None yet. Every handover saves one by itself.") end
    for i, p in ipairs(points) do
      ImGui.PushID(ctx, i)
      ImGui.BeginDisabled(ctx, not driving)
      if ImGui.SmallButton(ctx, "Restore") and reaper.MB("Make the session match '" .. p.label .. "'?\n\n" ..
          "Where things are now is saved as a recall point first, so you can come back.", "BandSync", 4) == 6 then
        band.log(recall.restore(proj, cfg, b.song, b.room, p.file) or "restore failed")
        last = 0
      end
      ImGui.EndDisabled(ctx)
      if not driving then ImGui.SetItemTooltip(ctx, "Only the driver restores (take control first).") end
      ImGui.SameLine(ctx)
      ImGui.Text(ctx, string.format("%s  ·  %s  ·  %s  ·  %d takes", p.label, tostring(p.by), (p.time or ""):sub(1, 16):gsub("T", " "), p.takes))
      ImGui.PopID(ctx)
    end
    ImGui.EndChild(ctx)
  end
end

local function section_actions()
  ImGui.SeparatorText(ctx, "More")
  for i, name in ipairs({ "Send takes", "Print my MIDI", "Settings", "Calibrate latency", "Update" }) do
    if i > 1 then ImGui.SameLine(ctx) end
    if ImGui.Button(ctx, name) then action(name) end
  end
end

local function frame()
  if reaper.time_precise() - last > 1.5 or reaper.EnumProjects(-1) ~= proj then
    last = reaper.time_precise()
    local ok, e = pcall(refresh)
    err = not ok and tostring(e) or nil
  end
  if err then return ImGui.TextColored(ctx, RED, "Error: " .. err) end
  if not b then return ImGui.TextWrapped(ctx, "This project isn't a BandSync session. Publish it (host) or open one (guest) first.") end
  ImGui.Text(ctx, string.format("%s  ·  room %s  ·  %s  ·  you are %s", b.song, b.room, b.role, cfg.user))
  section_sync()
  section_band()
  section_control()
  section_recall()
  section_actions()
end

local function loop()
  ImGui.SetNextWindowSize(ctx, 560, 640, ImGui.Cond_FirstUseEver)
  local visible, open = ImGui.Begin(ctx, "BandSync", true)
  if visible then
    local ok, e = pcall(frame) -- an error in our logic must still reach End
    if not ok then err = tostring(e) end
    ImGui.End(ctx)
  end
  if open then reaper.defer(loop) end
end
reaper.defer(loop)
