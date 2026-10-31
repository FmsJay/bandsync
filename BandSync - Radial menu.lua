-- @description BandSync: radial menu at the mouse (undo, restore, take control, Real time mode, chat)
-- A ring of BandSync's everyday moves that pops up where the mouse is: bind it to a key or a mouse button
-- (Actions list > "BandSync - Radial menu" > Add shortcut). Point at a slice to read what it does, click it to do it;
-- Esc, a click anywhere else, or the shortcut again closes it. The panel does the work (it opens if it was closed),
-- so every choice asks first exactly as its button there does.
local dir = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
package.path = dir .. "/lib/?.lua;" .. package.path
local band = require("band")

if not reaper.APIExists("ImGui_GetBuiltinPath") then
  return band.msg("The radial menu needs ReaImGui. Install it with ReaPack (Extensions > ReaPack > Browse packages: ReaImGui), then run this again.")
end
package.path = reaper.ImGui_GetBuiltinPath() .. "/?.lua;" .. package.path
local ImGui = require "imgui" "0.10"

local cfg = band.settings()
if not cfg then return end
local proj = reaper.EnumProjects(-1)
local b = band.binding(proj)
if not b then return band.msg("This project isn't a BandSync session yet: publish (host) or open (guest) one first.") end
if reaper.set_action_options then reaper.set_action_options(1) end -- the shortcut again closes it

local live = require("live")
local driving = require("sync").driver(cfg, b.song, b.room, band.read_json(band.session_path(cfg, b.song))) == cfg.user
local sm, si = live.fx(proj, false, live.SONOBUS)
local rt = sm and not reaper.TrackFX_GetOffline(sm, si) and select(2, reaper.GetProjExtState(proj, band.SECTION, "side")) == "0"
-- where a ping goes: the timeline under the mouse as the menu opens (SWS), else the edit cursor
local ping_pos = reaper.BR_PositionAtMouseCursor and reaper.BR_PositionAtMouseCursor(true) or -1
if ping_pos < 0 then ping_pos = reaper.GetCursorPositionEx(proj) end

-- The panel carries the request out ("panel do"); opened first when it isn't running (running it again would close it).
local function ask(what)
  reaper.SetExtState(band.SECTION, "panel do", what, false)
  reaper.DeleteExtState(band.SECTION, "panel minimized", true) -- (the pill doesn't run the panel's pages)
  local beat = tonumber(reaper.GetExtState(band.SECTION, "panel alive"))
  if not (beat and reaper.time_precise() - beat < 10) then
    local id = reaper.AddRemoveReaScript(true, 0, dir .. "/BandSync - Panel.lua", true)
    if id > 0 then reaper.Main_OnCommand(id, 0) end
  end
end

-- label (lines), what it does (shown while pointed at), and the move; no move = shown greyed
local SLICES = {
  { "Undo", "Undo your own last change, for everyone. It asks first, and says if a bandmate changed the same thing since.",
    function() ask("undo") end },
  { "Redo", "Bring back the change you undid last, for everyone. It asks first.", function() ask("redo") end },
  { "Restore\nproject…", "Opens Restore set to restore the whole project: each button there puts the whole song back to " ..
    "that moment, for everyone (the driver does this).", function() ask("history project") end },
  { "Restore\nselection…", "Opens Restore set to restore the selection: each button there puts only the tracks selected " ..
    "in REAPER back to that moment.", function() ask("history selection") end },
  { "Undo one\nchange…", "Opens Restore set to undo one change: each button there undoes just that change, and everything " ..
    "after it stays.", function() ask("history change") end },
  driving and { "You\ndrive", "You're driving: your deletes, moves and lane choices already go to everyone." } or
    { "Take\ncontrol", "Take control: from now on your deletes, moves and lane choices go to everyone. It asks first.",
      function() dofile(dir .. "/BandSync - Take control.lua") end },
  { "Real time\n" .. (rt and "on" or "off"), rt and "Turn Real time mode off: SonoBus leaves the band's group and you stop " ..
    "following play and stop. Edits keep syncing." or "Turn Real time mode on: SonoBus joins the band's group so you hear " ..
    "each other right away, and play, stop and record follow whoever presses them.", function() ask("realtime") end },
  { "Chat", "Open the Chat page: messages, to-dos and links for the band, this song or this room.",
    function() ask("chat") end },
  { "Ping\nhere", string.format("Put a marker at %.2f s on everyone's timeline for %d seconds, with your name: \"look here\".",
    ping_pos, require("presence").PING_SHOWN), function() require("presence").ping_here(proj, ping_pos) end },
}

local R, r, PAD, DESC_H = 165, 70, 12, 76 -- ring outside and inside radius; the description box goes under the ring
local W, H = 2 * (R + PAD), 2 * (R + PAD) + DESC_H
local ACCENT, SLICE, OFF, TEXT, MUTED = 0x4C8DF6FF, 0x2A2D32F2, 0x1F2124E6, 0xE6E8EBFF, 0x8D939BFF
local STEP = 2 * math.pi / #SLICES
local A0 = -math.pi / 2 - STEP / 2 -- slice 1 sits at the top

local ctx = ImGui.CreateContext("BandSync radial")
local mx, my = ImGui.PointConvertNative(ctx, reaper.GetMousePosition())
local FLAGS = ImGui.WindowFlags_NoDecoration | ImGui.WindowFlags_NoBackground | ImGui.WindowFlags_NoDocking |
  ImGui.WindowFlags_NoSavedSettings | ImGui.WindowFlags_NoMove | ImGui.WindowFlags_TopMost
local frame, run = 0, nil

local function centered(dl, x, y, text, col) -- each line centred on x, the block centred on y
  local lines = {}
  for l in (text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = l end
  local lh = select(2, ImGui.CalcTextSize(ctx, "Ag"))
  y = y - #lines * lh / 2
  for i, l in ipairs(lines) do ImGui.DrawList_AddText(dl, x - ImGui.CalcTextSize(ctx, l) / 2, y + (i - 1) * lh, col, l) end
end

-- Which slice the point (dx, dy) from the centre is on, or nil (the hole in the middle, or well outside the ring).
local function slice_at(dx, dy)
  local d = math.sqrt(dx * dx + dy * dy)
  if d < r or d > R + PAD then return nil end
  return math.floor(((math.atan(dy, dx) - A0) % (2 * math.pi)) / STEP) + 1
end

local function loop()
  frame = frame + 1
  ImGui.SetNextWindowPos(ctx, mx, my, ImGui.Cond_Appearing, 0.5, (R + PAD) / H) -- the ring's centre on the mouse
  ImGui.SetNextWindowSize(ctx, W, H, ImGui.Cond_Always)
  if frame == 1 then ImGui.SetNextWindowFocus(ctx) end
  local visible, open = ImGui.Begin(ctx, "BandSync radial", true, FLAGS)
  if visible then
    local dl = ImGui.GetWindowDrawList(ctx)
    local wx, wy = ImGui.GetWindowPos(ctx)
    local cx, cy = wx + W / 2, wy + R + PAD
    local px, py = ImGui.GetMousePos(ctx)
    local hot = slice_at(px - cx, py - cy)
    for i, s in ipairs(SLICES) do
      local a1, a2 = A0 + (i - 1) * STEP + 0.015, A0 + i * STEP - 0.015
      ImGui.DrawList_PathLineTo(dl, cx, cy)
      ImGui.DrawList_PathArcTo(dl, cx, cy, R, a1, a2, 0)
      ImGui.DrawList_PathFillConvex(dl, not s[3] and OFF or i == hot and ACCENT or SLICE)
      local mid, m = (a1 + a2) / 2, (R + r) / 2
      centered(dl, cx + math.cos(mid) * m, cy + math.sin(mid) * m, s[1], s[3] and TEXT or MUTED)
    end
    ImGui.DrawList_AddCircleFilled(dl, cx, cy, r - 4, 0x1B1D20F5) -- the hole: says whose session this is
    centered(dl, cx, cy, "BandSync\n" .. b.song .. "\nEsc closes", MUTED)
    local s = SLICES[hot]
    local tip = s and s[2] or "Point at a slice to see what it does; click it to do it."
    ImGui.DrawList_AddRectFilled(dl, wx + 4, wy + 2 * (R + PAD) + 4, wx + W - 4, wy + H - 4, 0x1B1D20F5, 8)
    ImGui.SetCursorScreenPos(ctx, wx + 14, wy + 2 * (R + PAD) + 12)
    ImGui.PushTextWrapPos(ctx, W - 14)
    ImGui.TextColored(ctx, s and not s[3] and MUTED or TEXT, tip)
    ImGui.PopTextWrapPos(ctx)
    if s and s[3] then ImGui.SetMouseCursor(ctx, ImGui.MouseCursor_Hand) end
    if ImGui.IsMouseClicked(ctx, ImGui.MouseButton_Left) then
      if s and s[3] then run = s[3] end
      open = false -- (a click on a greyed slice, the hole or anywhere else just closes it)
    end
    -- away: Esc, or REAPER (or anything else) took the focus
    if ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) or (frame > 3 and not ImGui.IsWindowFocused(ctx)) then open = false end
    ImGui.End(ctx)
  end
  if open then return reaper.defer(loop) end
  if run then run() end
end
reaper.defer(loop)
