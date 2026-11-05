-- @description StudioSync: control panel (sync, bandmates, who drives, who owns what, recall points)
-- One dockable window for everything StudioSync does in the project in front: start/stop Live sync, hold
-- it while you try things, see who has what, take control, claim tracks and regions, and save/restore
-- recall points. Needs ReaImGui (ReaPack: "ReaImGui: ReaScript binding for Dear ImGui").
local dir = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
package.path = dir .. "/lib/?.lua;" .. package.path
local band = require("band")
local sync = require("sync")
local recall = require("recall")
local status = require("status")
local tools = require("tools")
local together = require("together")

if not reaper.APIExists("ImGui_GetBuiltinPath") then
  return band.msg("The panel needs ReaImGui. Install it with ReaPack (Extensions > ReaPack > Browse packages: ReaImGui), then run this again.")
end
package.path = reaper.ImGui_GetBuiltinPath() .. "/?.lua;" .. package.path
local ImGui = require "imgui" "0.10"

local cfg = band.settings()
if not cfg then return end

if reaper.set_action_options then reaper.set_action_options(1) end -- running it again closes it (no task dialog)
local section, cmd = select(3, reaper.get_action_context())
if cmd > 0 then reaper.SetToggleCommandState(section, cmd, 1); reaper.RefreshToolbar2(section, cmd) end
reaper.DeleteExtState(band.SECTION, "panel_open", true) -- (0.21.5 kept this; Autostart now opens the panel with any StudioSync session)
local restarting = false -- an update landed: a new panel took over, and its toolbar state is on
reaper.atexit(function() if cmd > 0 and not restarting then reaper.SetToggleCommandState(section, cmd, 0); reaper.RefreshToolbar2(section, cmd) end end)

local ctx = ImGui.CreateContext("StudioSync")
-- resizable from any edge (a window taller than the screen can still be shrunk from the top). The Window menu
-- (top bar) fills a screen or half of one. Settings can give it the system's frame instead of ReaImGui's (ExtState
-- panel_native = "on"; on Windows that's REAPER's tool-window frame: light caption, no maximize button)
local native = reaper.GetExtState(band.SECTION, "panel_native") == "on"
ImGui.SetConfigVar(ctx, ImGui.ConfigVar_WindowsResizeFromEdges, 1)
ImGui.SetConfigVar(ctx, ImGui.ConfigVar_ViewportsNoDecoration, native and 0 or 1)
local theme = require("theme")
local GREEN, YELLOW, GREY, RED = theme.GREEN, theme.YELLOW, theme.GREY, theme.RED
local function rgba(c) local k = 255 * theme.STATUS; return math.floor(c[1] * k) << 24 | math.floor(c[2] * k) << 16 | math.floor(c[3] * k) << 8 | 0xFF end

-- ---- the look: sidebar pages, cards, pills and switches.
local ui_font = ImGui.CreateFont("sans-serif")
ImGui.Attach(ctx, ui_font)
local ui = {} -- (what's new goes here: the panel's main chunk is at Lua's limit of 200 locals)
ui.bold = ImGui.CreateFont("sans-serif", ImGui.FontFlags_Bold)
ImGui.Attach(ctx, ui.bold)
local ACCENT, CARD, NAV, MUTED, DARK = theme.ACCENT, theme.CARD, theme.NAV, theme.MUTED, theme.DARK
local function push_theme() theme.push(ctx, ImGui) end
local function pop_theme() theme.pop(ctx, ImGui) end

-- A rounded label: status at a glance. `height`: line it up with buttons (their frame height).
local function pill(text, bg, fg, height)
  local dl = ImGui.GetWindowDrawList(ctx)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local w, h = ImGui.CalcTextSize(ctx, text)
  local ph = height or (h + 6)
  ImGui.Dummy(ctx, w + 16, ph)
  ImGui.DrawList_AddRectFilled(dl, x, y, x + w + 16, y + ph, bg, ph / 2)
  ImGui.DrawList_AddText(dl, x + 8, y + (ph - h) / 2, fg or DARK, text)
end
-- An on/off switch: returns changed, new value.
local function switch(id, on)
  local dl = ImGui.GetWindowDrawList(ctx)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local h = ImGui.GetFrameHeight(ctx) - 4
  local w = h * 1.8
  ImGui.SetCursorScreenPos(ctx, x, y + 2)
  local clicked = ImGui.InvisibleButton(ctx, id, w, h)
  local now = on
  if clicked then now = not on end
  ImGui.DrawList_AddRectFilled(dl, x, y + 2, x + w, y + 2 + h, now and ACCENT or theme.SWITCH_OFF, h / 2) -- (off: light enough to see against a card)
  ImGui.DrawList_AddCircleFilled(dl, now and (x + w - h / 2) or (x + h / 2), y + 2 + h / 2, h / 2 - 3, 0xFFFFFFFF)
  return clicked, now
end
-- A switch with its label; tip shown on hover.
local function switch_row(id, label, on, tip)
  local ch, v = switch(id, on)
  if tip then ImGui.SetItemTooltip(ctx, tip) end
  ImGui.SameLine(ctx)
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.PushTextWrapPos(ctx, 0)
  ImGui.Text(ctx, label)
  ImGui.PopTextWrapPos(ctx)
  if tip then ImGui.SetItemTooltip(ctx, tip) end
  return ch, v
end
local wide = false -- docked wide and short (see layout): everything a little tighter
local function heading(text, size)
  if ui.short then ImGui.AlignTextToFramePadding(ctx) end -- (level with the boxes and switches that start the other columns)
  ImGui.PushFont(ctx, nil, ui.short and 15 or wide and 17 or (size or 19))
  ImGui.Text(ctx, text)
  ImGui.PopFont(ctx)
end
-- A card: a rounded panel sized to what's in it. Returns true when its content should be drawn (then call card_end).
-- `h`: a fixed height, for cards laid side by side (a self-sizing one always took a row of its own).
local open_cards = 0 -- (cards still open when a frame errors: closed before End, or End itself fails and the panel dies)
local function card(id, w, h)
  local bare = ui.bare_cards -- (a card in a docked column is a box in a box, and the walls cost it 26 px each way)
  ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, bare and 0 or CARD)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, bare and 0 or 14, bare and 0 or ui.short and 7 or 12)
  local open = ImGui.BeginChild(ctx, id, w or 0, h or 0, (h and 0 or ImGui.ChildFlags_AutoResizeY) | ImGui.ChildFlags_AlwaysUseWindowPadding,
    ImGui.WindowFlags_NoScrollbar)
  ImGui.PopStyleVar(ctx)
  ImGui.PopStyleColor(ctx)
  if open then ImGui.PushTextWrapPos(ctx, 0); open_cards = open_cards + 1 end
  return open
end
local function card_end() ImGui.PopTextWrapPos(ctx); ImGui.EndChild(ctx); open_cards = open_cards - 1 end

-- Blue to orange, by way of violet: straight across, the middle goes grey. t = 0 to 1.
function ui.blue_orange(t, alpha)
  t = math.max(0, math.min(1, t)) * 2
  local from, to = t < 1 and { 0x1E, 0x9B, 0xFF } or { 0xC2, 0x6B, 0xD6 }, t < 1 and { 0xC2, 0x6B, 0xD6 } or { 0xFF, 0x8A, 0x1E }
  local f, c = t < 1 and t or t - 1, 0
  for i = 1, 3 do c = c << 8 | math.floor(from[i] + (to[i] - from[i]) * f + 0.5) end
  return c << 8 | (alpha or 255)
end
-- ReaImGui has no gradient fill, so `draw(colour)` is drawn once per pixel column, clipped to that column.
function ui.gradient(dl, x0, y0, x1, y1, from, to, draw)
  for x = math.floor(x0), math.ceil(x1) - 1 do
    ImGui.DrawList_PushClipRect(dl, x, y0, x + 1, y1, true)
    draw(ui.blue_orange((x + 0.5 - from) / (to - from)))
    ImGui.DrawList_PopClipRect(dl)
  end
end
-- A pill you can press: part of the blue-to-orange, t0 to t1 along it. Returns clicked.
function ui.crumb(text, t0, t1, h, tip)
  local dl = ImGui.GetWindowDrawList(ctx)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local tw, th = ImGui.CalcTextSize(ctx, text)
  local w = tw + 16
  local clicked = ImGui.InvisibleButton(ctx, "##crumb" .. t0, w, h)
  local span = w / (t1 - t0)
  local from = x - t0 * span
  ui.gradient(dl, x, y, x + w, y + h, from, from + span, function(col) ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + h, col, h / 2) end)
  if ImGui.IsItemHovered(ctx) then
    ImGui.SetMouseCursor(ctx, ImGui.MouseCursor_Hand)
    ImGui.DrawList_AddRect(dl, x, y, x + w, y + h, 0xFFFFFFC0, h / 2, 0, 1.5)
  end
  ImGui.DrawList_AddText(dl, x + 8, y + (h - th) / 2, 0x10131AFF, text) -- (dark on these colours in every theme: Light's white was hard to read)
  ImGui.SetItemTooltip(ctx, tip)
  return clicked
end
-- A window button: "line" (to a strip) or "box" (to the small square). Returns clicked.
function ui.window_icon(id, kind, s, tip)
  local dl = ImGui.GetWindowDrawList(ctx)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local clicked = ImGui.InvisibleButton(ctx, id, s, s)
  if ImGui.IsItemHovered(ctx) then ImGui.DrawList_AddRectFilled(dl, x - 2, y - 2, x + s + 2, y + s + 2, theme.BUTTON_HOVER, 4) end
  if kind == "line" then ImGui.DrawList_AddLine(dl, x + s * 0.2, y + s * 0.68, x + s * 0.8, y + s * 0.68, theme.TEXT, 2)
  else ImGui.DrawList_AddRect(dl, x + s * 0.3, y + s * 0.3, x + s * 0.7, y + s * 0.7, theme.TEXT, 2, 0, 1.5) end
  ImGui.SetItemTooltip(ctx, tip)
  return clicked
end
-- The logo: two linked faders, each a plain line with a portal opening from it towards the other fader, blue into orange.
-- Drawn, so it's sharp at any size (docs/logo has it as SVG). `s` = its height; it's 0.93 s wide. Drawn at the cursor, taking that space.
local FLAMES = { { -72, 26, 6, 2, .9 }, { -48, 26, 7, 2.2, .7 }, { -22, 30, 8, 2.6, .9 }, { 8, 28, 6.5, 2.1, .6 }, { 34, 28, 7.5, 2.4, .9 }, { 60, 22, 6, 2, .75 } } -- angle on the rim, how far round, how far out, width, opacity
local function logo(s)
  local dl = ImGui.GetWindowDrawList(ctx)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local k = s / 60
  local function X(u) return x + (u - 4) * k end
  local function Y(v) return y + (v - 2) * k end
  local function tint(u, a) return ui.blue_orange((u - 12) / 40, a) end
  local line = ImGui.GetColor(ctx, ImGui.Col_Text)
  for _, flip in ipairs({ false, true }) do
    local own = flip and 1 or 0
    -- worked out for the left fader; the right one is it turned half way round the middle of the mark
    local function P(u, v) if flip then return X(64 - u), Y(64 - v) end return X(u), Y(v) end
    local function rim(deg, rx, ry) local t = math.rad(deg); return 18 + rx * math.cos(t), 32 + ry * math.sin(t) end
    local function half(rx, ry, col, thick) -- the half ellipse from the line
      ImGui.DrawList_PathClear(dl)
      for i = -12, 12 do ImGui.DrawList_PathLineTo(dl, P(rim(i * 7.5, rx, ry))) end
      if thick then ImGui.DrawList_PathStroke(dl, col, ImGui.DrawFlags_None, thick) else ImGui.DrawList_PathFillConvex(dl, col) end
    end
    if s >= 40 then
      for _, f in ipairs(FLAMES) do -- all turning the same way round, so the portal spins
        if s >= 80 or f[5] >= 0.7 then -- (small, the faint ones only scribble)
          local x0, y0 = rim(f[1], 7.5, 25)
          local x1, y1 = rim(f[1] + f[2], 7.5 + f[3], 25 + f[3] * 0.3)
          local n = math.sqrt((x1 - x0) ^ 2 + (y1 - y0) ^ 2)
          local px, py, mx, my = -(y1 - y0) / n, (x1 - x0) / n, (x0 + x1) / 2, (y0 + y1) / 2
          local col, ax, ay, bx, by = tint(flip and 64 - mx or mx, math.floor(f[5] * 255))
          for i = 0, 6 do
            local t, u = i / 6, 1 - i / 6
            local cxa, cya = mx + px * (-2 + f[4] / 2), my + py * (-2 + f[4] / 2)
            local cxb, cyb = mx + px * (-2 - f[4] / 2), my + py * (-2 - f[4] / 2)
            local nax, nay = u * u * x0 + 2 * u * t * cxa + t * t * x1, u * u * y0 + 2 * u * t * cya + t * t * y1
            local nbx, nby = u * u * x0 + 2 * u * t * cxb + t * t * x1, u * u * y0 + 2 * u * t * cyb + t * t * y1
            if ax then
              local a1, a2 = P(ax, ay)
              local b1, b2 = P(nax, nay)
              local c1, c2 = P(nbx, nby)
              local d1, d2 = P(bx, by)
              ImGui.DrawList_AddQuadFilled(dl, a1, a2, b1, b2, c1, c2, d1, d2, col)
            end
            ax, ay, bx, by = nax, nay, nbx, nby
          end
        end
      end
    end
    for i = 0, 2 do half(11.5 - i * 1.6, 28 - i, ui.blue_orange(own, 0x24)) end -- its glow
    half(7.5, 25, ui.blue_orange(own, 0x90))
    half(3.2, 22, 0xFFFFFF60)
    half(7.5, 25, ui.blue_orange(own), math.max(1, 1.7 * k))
    local x1, y1 = P(18, 5)
    local x2, y2 = P(18, 59)
    ImGui.DrawList_AddLine(dl, x1, y1, x2, y2, line, math.max(1.5, 3 * k)) -- the fader's own line, on the outside
    if s >= 30 then -- its scale, long and short like a console's (too small, it's only fuzz)
      for n = 0, 8 do
        local v, big = 8 + n * 6, n % 2 == 0
        local ax, ay = P(15, v)
        local bx, by = P(big and 7 or 10.5, v)
        ImGui.DrawList_AddLine(dl, ax, ay, bx, by, big and line or (line & 0xFFFFFF00 | 0xBF), math.max(1, 1.5 * k))
      end
    end
  end
  local px, py
  for i = 0, 16 do -- the link: 18,20 to 46,44, as one S
    local t, u = i / 16, 1 - i / 16
    local bx = u * u * u * 18 + 3 * u * u * t * 32 + 3 * u * t * t * 32 + t * t * t * 46
    local by = u * u * u * 20 + 3 * u * u * t * 20 + 3 * u * t * t * 44 + t * t * t * 44
    if px then
      ImGui.DrawList_AddLine(dl, X(px), Y(py), X(bx), Y(by), tint(bx, 0x50), 5.5 * k)
      ImGui.DrawList_AddLine(dl, X(px), Y(py), X(bx), Y(by), tint(bx), 3.4 * k)
    end
    px, py = bx, by
  end
  for _, c in ipairs({ { 8, 14 }, { 36, 38 } }) do -- the fader caps
    ui.gradient(dl, X(c[1]), Y(c[2]), X(c[1] + 20), Y(c[2] + 12), X(12), X(52), function(col)
      ImGui.DrawList_AddRectFilled(dl, X(c[1]), Y(c[2]), X(c[1] + 20), Y(c[2] + 12), col, 3.5 * k)
    end)
    ImGui.DrawList_AddRectFilled(dl, X(c[1] + 2), Y(c[2] + 5), X(c[1] + 18), Y(c[2] + 7), 0xFFFFFFFF, k)
  end
  ImGui.Dummy(ctx, s * 0.93, s)
end
-- The wordmark: Studio, then Sync in blue to orange.
local function wordmark(size)
  ImGui.PushFont(ctx, nil, size)
  local _, y = ImGui.GetCursorScreenPos(ctx) -- (each piece on the same baseline: SameLine goes back to the line's top)
  ImGui.Text(ctx, "Studio")
  ImGui.SameLine(ctx, 0, 0)
  local x = ImGui.GetCursorScreenPos(ctx)
  ImGui.SetCursorScreenPos(ctx, x, y)
  local w, h = ImGui.CalcTextSize(ctx, "Sync")
  local dl, font = ImGui.GetWindowDrawList(ctx), ImGui.GetFont(ctx)
  ui.gradient(dl, x, y, x + w, y + h, x, x + w, function(col) ImGui.DrawList_AddTextEx(dl, font, size, x, y, col, "Sync") end)
  ImGui.Dummy(ctx, w, h)
  ImGui.PopFont(ctx)
end
-- The panel as a small square ("1"), or a strip with words ("strip"), over REAPER (pill_window), kept across restarts.
function ui.set_minimized(on)
  if on then reaper.SetExtState(band.SECTION, "panel minimized", on == "strip" and "strip" or "1", true)
  else reaper.DeleteExtState(band.SECTION, "panel minimized", true) end
end
local reload_now, dock_req, dock_side -- (Settings: switching the window frame reopens the panel; Dock / Undock; the side its new docker goes to)
local placed_from, placed_how -- where the window was before the Window menu moved it (screen pixels), and how it's placed
local banner_docked -- (docked, the panel never covers the arrange view)
local place_req, win_rect -- a placement for the next frame (ReaImGui units); the window as ReaImGui last drew it
local WINDOW_MENU = { "Fill this screen", "Left half", "Right half", "Top half", "Bottom half", "Move to the next screen", "Back to before" }
local function place_window(how)
  if how == "Dock" or how == "Undock" then dock_req = how == "Dock" and -1 or 0; return end -- (asked for from a script)
  local sw, sh = how:match("^size (%d+) (%d+)$") -- (likewise)
  if sw and win_rect then place_req = { win_rect[1], win_rect[2], tonumber(sw), tonumber(sh) }; return end
  local h = reaper.JS_Window_Find and reaper.JS_Window_Find("StudioSync", true)
  if not h then return band.msg("Placing the window needs js_ReaScriptAPI (ReaPack: 'js_ReaScriptAPI').") end
  local _, l, t, r, btm = reaper.JS_Window_GetRect(h)
  -- moving the system window from outside only stretches what ReaImGui drew: ReaImGui sizes its windows itself, so
  -- the screen's pixels are turned into its units (they differ with display scaling) and it places the window
  local function req(x, y, w, hh)
    if not win_rect or r - l <= 0 then return end
    local sx, sy = (r - l) / win_rect[3], (btm - t) / win_rect[4]
    place_req = { win_rect[1] + (x - l) / sx, win_rect[2] + (y - t) / sy, w / sx, hh / sy }
  end
  if how == "Back to before" then
    if placed_from then req(table.unpack(placed_from)); placed_from = nil end
    placed_how = nil
    return
  end
  placed_how = how
  placed_from = placed_from or { l, t, r - l, btm - t }
  local L, T, R, B = reaper.JS_Window_GetViewportFromRect(l, t, r, btm, true) -- the screen it's on, without the taskbar
  if how == "Move to the next screen" then -- the screen to the right (else the left), filled
    local my = (T + B) // 2
    local nL, nT, nR, nB = reaper.JS_Window_GetViewportFromRect(R + 20, my, R + 21, my + 1, true)
    if nL == L then nL, nT, nR, nB = reaper.JS_Window_GetViewportFromRect(L - 21, my, L - 20, my + 1, true) end
    if nL == L then return band.msg("There's only one screen.") end
    L, T, R, B = nL, nT, nR, nB
    placed_how = "Fill this screen"
  end
  local W, H = R - L, B - T
  local x, y, w, hh = L, T, W, H
  if how == "Left half" then w = W // 2
  elseif how == "Right half" then x, w = L + W // 2, W - W // 2
  elseif how == "Top half" then hh = H // 2
  elseif how == "Bottom half" then y, hh = T + H // 2, H - H // 2 end
  req(x, y, w, hh)
end
-- An on/off option.
local function check(label, v, tip)
  local ch, nv = switch_row("##" .. label, label, v, tip)
  if tip then ImGui.SetItemTooltip(ctx, tip) end
  return ch, nv
end
-- Next to the last item if `label`'s button still fits on this line, else on the next one (narrow or docked panels).
local function next_to(label) -- (or a width: a box's isn't its words')
  ImGui.SameLine(ctx)
  if ImGui.GetContentRegionAvail(ctx) < (type(label) == "number" and label or ImGui.CalcTextSize(ctx, label) + 36) then ImGui.NewLine(ctx) end
end

-- Tooltips for controls that don't set their own, by label (a control's own tooltip, set after it, wins).
local TIPS = {
  ["Start"] = "Start Live sync in this tab: your takes and changes go out, the studio's come in.",
  ["Update"] = "Get the newest StudioSync through ReaPack.",
  ["Let in"] = "Add this machine to the studio folder.",
  ["Take control"] = "Become the driver: your deletes, moves and lane choices reach everyone (except where someone has claimed).",
  ["Take control now"] = "The driver isn't here: carry on as the driver (they can take it back when they return).",
  ["Claim region"] = "Every take that starts in the region at the edit cursor becomes yours to change, whoever drives.",
  ["Release all claims"] = "Let go of all your claims: everything follows the driver again.",
  ["##label"] = "A name for this version, then Save this version.",
  ["Save this version"] = "Save how the session is now (takes, where they sit, what plays) as a version anyone can go back to.",
  ["Update the folder now"] = "Send your plug-in list and rebuild the FX browser folder 'StudioSync (everyone has)' now.",
  ["##drummap"] = "The drum map this drum track uses: notes arriving in another kit's map are translated to it.",
  ["Play along (synced to the project)"] = "Hear each other in time with the project, at any distance (a bar or two late). Needs the studio's NINJAM server.",
  ["Real time (SonoBus, lowest delay)"] = "Hear each other right away, peer to peer (best on wired internet, not too far apart).",
  ["Jam (NINJAM intervals)"] = "Classic NINJAM: everyone hears everyone one interval late.",
  ["Leave"] = "Leave: SonoBus stops (it stays on its track, sending nothing) or ReaNINJAM disconnects.",
  ["##server"] = "The host's Tailscale name and NINJAM port, e.g. my-pc.tail1234.ts.net:2049.",
  ["Save for the studio"] = "Everyone's Connect uses this address.",
  ["##ninjamdir"] = "The folder holding ninjamsrv and bandsync.cfg (only on the computer that runs the server).",
  ["Use server folder"] = "Remember this NINJAM server folder (host only).",
  ["Send my audio (my whole mix)"] = "Off: you listen without sending anything.",
  ["Connect"] = "Join the studio's live audio in the mode above.",
  ["Show it"] = "Open the live plug-in's window.",
  ["Open latest to look"] = "Open the newest Solo edit version to look at.",
  ["Check out"] = "Take a working copy to edit while the others are offline.",
  ["##soloroot"] = "Where Solo edit keeps its versions (usually the shared Google Drive folder).",
  ["Clear"] = "Empty this activity list.",
  ["Open the full console"] = "REAPER's script console, with everything StudioSync has said.",
  ["start from"] = "Where everyone starts: the edit cursor or a region.",
  ["count-in bars"] = "Bars of count-in before the start point.",
  ["Play together"] = "Everyone running Live sync starts playing from the same point at the same moment (5 s after you click).",
  ["Stop together"] = "Everyone stops.",
  ["##note"] = "A note for everyone: on the selected take, or at the cursor. Everyone sees it on the timeline and on the Restore page.",
  ["Note on selected take"] = "Post the note on the selected take (a take marker everyone sees).",
  ["Note at cursor"] = "Post the note at the edit cursor.",
  ["Like selected take"] = "Tell everyone you like the selected take.",
  ["Take back my last take"] = "Remove your newest take for everyone (it waits in the room's trash).",
  ["Print selected MIDI as audio"] = "Render the selected MIDI through its instrument as an audio take everyone hears.",
  ["Insert bars"] = "Insert bars at the edit cursor on every machine (driver only).",
  ["Remove bars"] = "Remove bars at the edit cursor on every machine (driver only).",
  ["##newroom"] = "A name for a new side room.",
  ["Go"] = "Go to the room they're asking you to.",
  ["Not now"] = "Hide this invitation.",
  ["Share this project with the studio"] = "Make this project a studio project: you host it, and everyone joins it from their panel.",
  ["Join the studio's project"] = "Open a project someone in the studio started, in its own tab.",
  ["Come see!"] = "Ask everyone with this project open to come to this room.",
  ["Prepare this project first"] = "A checklist for a busy project before starting a project from it (shows what it would change first).",
  ["Settings"] = "StudioSync's settings: your name, the shared folder, how takes land.",
  ["Open another project"] = "Open another studio project in a new tab.",
  ["Prepare this project"] = "A checklist for a busy project (shows what it would change first).",
}
ImGui.SetItemTooltip = function(c, text)
  if ImGui.BeginItemTooltip(c) then
    ImGui.PushTextWrapPos(c, ImGui.GetFontSize(c) * 26)
    ImGui.Text(c, text)
    ImGui.PopTextWrapPos(c)
    ImGui.EndTooltip(c)
  end
end
for _, name in ipairs({ "Button", "SmallButton", "Checkbox", "InputInt", "InputText", "InputTextWithHint", "BeginCombo", "RadioButton", "Selectable", "TreeNodeEx" }) do
  local f = ImGui[name]
  ImGui[name] = function(c, label, ...)
    local r = table.pack(f(c, label, ...))
    if ui.clipped then -- (asked for by tools/panel_sizes.py: what runs off the right of its window)
      local wx, ww = ImGui.GetWindowPos(c), ImGui.GetWindowSize(c)
      if ImGui.GetItemRectMax(c) > wx + ww + 0.5 then ui.clipped[tostring(label)] = true end
    end
    local t = type(label) == "string" and (TIPS[label] or TIPS[(label:gsub("##.*$", ""))])
    if t then ImGui.SetItemTooltip(c, t) end
    return table.unpack(r, 1, r.n)
  end
end

-- Actions run as REAPER actions (so they see their own action context), registered on first use.
local ids = {}
local function action(name)
  ids[name] = ids[name] or reaper.AddRemoveReaScript(true, 0, dir .. "/StudioSync - " .. name .. ".lua", true)
  if ids[name] > 0 then reaper.Main_OnCommand(ids[name], 0) end
end

local proj, b, view, can, who, points, last, err = nil, nil, nil, nil, nil, {}, 0, nil
local banner_text -- what the banner over REAPER says while someone else drives (set with the view, drawn by banner())
local label = ""
local function refresh()
  proj = reaper.EnumProjects(-1)
  b = band.binding(proj)
  -- the front tab's own band (two bands' songs can be open at once), on this computer's settings as they are now:
  -- an installer, or another panel, may have switched the band since this one started (laptop, 0.35.1)
  local now_root, now_user = reaper.GetExtState(band.SECTION, "sync_root"), reaper.GetExtState(band.SECTION, "user")
  cfg = band.for_tab(now_root ~= "" and now_user ~= "" and { root = now_root, user = now_user } or cfg, b)
  banner_text = nil -- (a tab that isn't a band session has no banner: it showed over a new empty tab)
  if not b then return end
  view = status.gather(cfg, b, proj)
  view.group = band.info(cfg.root).name
  can, who = sync.authority(cfg, b.song, b.room, view.session)
  local here = false -- the driver is someone else, and they're here
  for _, r in ipairs(view.rows) do if r.name == view.driver and r.age < 45 then here = true end end
  if here and view.driver ~= cfg.user and reaper.GetExtState(band.SECTION, "alone " .. tostring(proj)) == "" then
    local mine = 0
    for _, c in pairs(who.tracks) do if c.user == cfg.user then mine = mine + 1 end end
    for _, c in pairs(who.regions) do if c.user == cfg.user then mine = mine + 1 end end
    for _, t in ipairs(who.times or {}) do if t.user == cfg.user then mine = mine + 1 end end
    -- (open: no banner; "x and nil or y" can't say that in Lua, it gives y)
    if who.mode == "driver" then banner_text = "View only: " .. view.driver .. " is driving. Your changes are put back (recording still goes out)."
    elseif who.mode == "admins" and not require("groups").may_manage(cfg.root, cfg.user) then
      banner_text = mine > 0 and "Admins only: you can change what you've been given." or "View only: admins only here. Your changes are put back (recording still goes out)."
    elseif who.mode ~= "open" then
      -- (tracks you made and nobody has claimed are yours to change too, so "view only" wasn't true: sync.maker_may)
      local made = false
      for i = 0, reaper.CountTracks(proj) - 1 do
        local tr = reaper.GetTrack(proj, i)
        local name = sync.base_name(select(2, reaper.GetTrackName(tr)))
        made = made or (not who.tracks[name:lower()] and require("mirror").is_creator(require("mirror").track_oid(tr), cfg.user))
      end
      banner_text = (mine > 0 or made) and (view.driver .. " is driving: you can change what you've claimed or made.")
        or ("View only: " .. view.driver .. " is driving. Claim a track (StudioSync, Home) to edit it.")
    end
  end
  points = recall.list(cfg, b.song, b.room)
end

-- History: re-read only while its tab is open, and not every frame.
local just_looked = {} -- backup tabs someone chose only to look at. (Not by pointer alone: REAPER gives a new tab a closed one's: Mac, 0.58.4)
local entries, groups, hist_at = {}, {}, 0
local function refresh_history()
  entries = recall.entries(cfg, b.song, b.room)
  table.sort(entries, function(a, x) return (a.time .. a.id) < (x.time .. x.id) end)
  groups = recall.groups(entries, view.session and view.session.host)
end
local utc_offset -- shortcut: fixed at start, a DST change mid-session shows an hour off
do local t = os.date("!*t"); t.isdst = false; utc_offset = os.time() - os.time(t) end
local function local_time(iso)
  local y, mo, d, h, mi, s = (iso or ""):match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then return "?" end
  return os.date("%m-%d %H:%M", os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = s, isdst = false }) + utc_offset)
end

-- The bar a time falls in, from the tempo map (the displayed position rounds 4.999 s up into the next bar).
local function bar_num(pos) return select(2, reaper.TimeMap2_timeToBeats(proj, pos)) + 1 end
-- "bar 2" / "bars 9-10" for a stretch of time; an end on a bar line doesn't include that bar
local function bar_span(from, to)
  local a, z = bar_num(from + 1e-6), bar_num(to - 1e-6)
  return a == z and ("bar " .. a) or ("bars " .. a .. "-" .. z)
end
local function bar_of(pos) -- "5", or "5 beat 3" off the bar line
  local bar, beat = reaper.format_timestr_pos(pos, "", 2):match("^(%d+)%.(%d+)")
  return beat == "1" and bar or (bar .. " beat " .. beat)
end

-- What a track is called for ownership: a "(MIDI)" copy track and a "(studio)" mirror belong to their part.
local function part_name(tr)
  local m = band.track_ext(tr, "band_midi_track")
  return m ~= "" and m or sync.base_name(select(2, reaper.GetTrackName(tr)))
end
local function claim(tracks, regions)
  local c, why = sync.my_claims(cfg, b.song, b.room)
  if not c then return band.msg(why) end
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
  if not running and band.synced_elsewhere(proj) then -- (a second copy of the song: syncing it would work on a stale one)
    ImGui.SameLine(ctx)
    ImGui.TextColored(ctx, YELLOW, "this project is open and syncing in another tab: work there")
  elseif not running then -- (no Stop: a StudioSync project always syncs, or the band's copies drift apart)
    ImGui.SameLine(ctx)
    if not require("rooms").is_copy(proj, cfg, b) and ImGui.SmallButton(ctx, "Start") then reaper.DeleteExtState(band.SECTION, "stop " .. key, false); band.start_live(dir) end
  end
  if not tools.autostart_on(dir) and not tools.autostart_tried then -- always on: StudioSync projects start Live sync with REAPER
    tools.autostart_tried = true
    if not tools.set_autostart(true, dir) then band.log("couldn't add StudioSync to Scripts/__startup.lua: Live sync won't start with REAPER") end
  end
  if view.newer then
    -- already on disk (an update, or a bandmate's folder install)? Then only this running panel is old
    local disk = (band.read(dir .. "/lib/band.lua") or ""):match('VERSION = "([^"]+)"')
    if disk == view.newer then
      ImGui.TextColored(ctx, YELLOW, "StudioSync " .. disk .. " is installed: close and reopen this panel to use it.")
    else
      ImGui.TextColored(ctx, YELLOW, "StudioSync " .. view.newer .. " is in use here; you have " .. band.VERSION .. ".")
      ImGui.SameLine(ctx)
      if ImGui.SmallButton(ctx, "Update##banner") then action("Update") end -- "##": same label as More's Update, its own ID
    end
  end
end


local drive_root, drive_at = nil, -math.huge
local MODE_INFO = {
  { "driver", "Only the driver", "Only the driver changes what the studio has. Everyone else's changes are put back (record as usual)." },
  { "claims", "Driver + claims", "The driver, and everyone on what they've claimed (a track, a region, a stretch of time). Other changes are put back." },
  { "admins", "Admins only", "Only the studio's owner and admins change what the studio has, and anyone on what an admin gave them (right-click their name). Other changes are put back." },
  { "open", "Anyone", "Anyone changes anything nobody has claimed, the tempo map and markers too. If two change one thing at once,\n" ..
    "whoever changed it more wins, and the other person gets Use mine." },
}
local function section_driver(beside) -- beside: drawn on the box's row (a short docker has no row to spare)
  local driving = view.driver == cfg.user
  local mode, alone = who.mode or "claims", reaper.GetExtState(band.SECTION, "alone " .. tostring(proj)) ~= ""
  local may_set = driving or alone or require("groups").may_manage(cfg.root, cfg.user)
  local cur = MODE_INFO[2]
  for _, m in ipairs(MODE_INFO) do if m[1] == mode then cur = m end end
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, "Who controls")
  ImGui.SameLine(ctx)
  ImGui.BeginDisabled(ctx, not may_set)
  ImGui.SetNextItemWidth(ctx, ui.short and 150 or 170)
  if ImGui.BeginCombo(ctx, "##whocontrols", cur[2]) then
    for _, m in ipairs(MODE_INFO) do
      if ImGui.Selectable(ctx, m[2], m[1] == mode) and m[1] ~= mode then
        sync.set_mode(cfg, b.song, b.room, m[1], cfg.user)
        band.log("editing in '" .. b.room .. "' is now " .. m[2] .. ": " .. m[3])
        last = 0
      end
      ImGui.SetItemTooltip(ctx, m[3])
    end
    ImGui.EndCombo(ctx)
  end
  ImGui.EndDisabled(ctx)
  ImGui.SetItemTooltip(ctx, cur[3] .. (may_set and "" or "\nThe driver or an admin picks this."))
  if not may_set then ImGui.SameLine(ctx); ImGui.TextDisabled(ctx, "the driver or an admin picks") end
  if beside then beside() end
  if driving or reaper.GetExtState(band.SECTION, "alone " .. tostring(proj)) == "" then -- (alone, "James is driving" sat right above "you have full control": Mac, 0.57.6)
    ImGui.Text(ctx, driving and "You're driving: what nobody has claimed follows you." or (tostring(view.driver) .. " is driving."))
  end
  local away = reaper.GetExtState(band.SECTION, "driver_away " .. tostring(proj))
  if away ~= "" and not driving then
    ImGui.PushTextWrapPos(ctx, 0)
    ImGui.TextColored(ctx, YELLOW, away .. " is driving but isn't here, so only claimed tracks can change. Take control to carry on " ..
      "(they can take it back when they return).")
    ImGui.PopTextWrapPos(ctx)
    if ImGui.Button(ctx, "Take control now") then action("Take control") end
  end
  if reaper.GetExtState(band.SECTION, "alone " .. tostring(proj)) ~= "" then
    ImGui.PushTextWrapPos(ctx, 0)
    ImGui.TextColored(ctx, GREEN, "Nobody else is here: you have full control. Everything you change goes to the others, and reaches " ..
      "them when they're back. When someone joins, the rules above apply again.")
    ImGui.PopTextWrapPos(ctx)
  end
end
local function section_drive()
  ImGui.SeparatorText(ctx, "Google Drive")
  if reaper.time_precise() - drive_at > 30 then drive_at = reaper.time_precise(); drive_root = require("drive").root(cfg) end
  local off = reaper.GetExtState(band.SECTION, "drive_root") == "off"
  local dch, don = check("Keep the studio's copy on Google Drive", drive_root ~= nil)
  if dch then reaper.SetExtState(band.SECTION, "drive_root", don and "" or "off", true); drive_at = -math.huge end
  local mch, mon = check("Make a Drive folder for each studio I start", require("drive").wanted(),
    "On, each studio you start gets its folder in your My Drive. You share it with the others at drive.google.com. Off: nothing's made, and you can make one here later.")
  if mch then reaper.SetExtState(band.SECTION, "drive make", mon and "" or "off", true) end
  ImGui.SetItemTooltip(ctx, drive_root and ("Each room is copied to " .. drive_root .. " (every few minutes, while stopped): what someone " ..
    "does alone reaches the studio whenever they next open the project, and every end-of-session point is kept there.")
    or off and "Off on this machine." or "No Google Drive for desktop here (My Drive not found).")
  if drive_root then -- (which account's Drive it is, in view: with several signed in it matters; Mac, 0.34.5)
    ImGui.TextDisabled(ctx, "Copies to " .. (drive_root:match("GoogleDrive%-([^/]+)/") or drive_root:match("^(%a:)") or drive_root))
    ImGui.SetItemTooltip(ctx, drive_root)
  end
  local missing = not drive_root and not off and require("drive").missing
  if missing then
    local folder = band.info(cfg.root).drive
    ImGui.PushTextWrapPos(ctx, 0)
    ImGui.TextColored(ctx, YELLOW, "No " .. folder .. " folder in " .. missing .. ". On drive.google.com, find the studio's " .. folder .. " folder " ..
      "(Shared with me), right-click > Organize > Add shortcut > My Drive, and keep the name " .. folder .. ". You started this studio? " ..
      "Make a folder called " .. folder .. " in My Drive and share it with everyone as Editor.")
    ImGui.PopTextWrapPos(ctx)
    if require("groups").role(cfg.root, cfg.user) == "owner" and ImGui.SmallButton(ctx, "Make it now") then
      local made = require("drive").make(folder)
      band.log(made and ("made " .. folder .. " in your Google Drive: share it with the others at drive.google.com, as Editor") or "no My Drive found here")
      drive_at = -math.huge
    end
  end
end
-- Two computers' fingerprints differ for 10-15 s after any edit (each publishes its own every few seconds, and the
-- print follows the notes), and red then read as a failed sync (James, 2026-11-01). Red once they've stayed apart 30 s.
local apart = {} -- bandmate -> { key = their fingerprint and ours, since = when that pair first showed }
local function settled_apart(p, mine)
  local key, a = p.mirror .. mine, apart[p.name]
  if not a or a.key ~= key then a = { key = key, since = reaper.time_precise() }; apart[p.name] = a end
  return reaper.time_precise() - a.since >= 30
end
local tabs_at = 0 -- where the page tabs start: the widest the bar beside them has been
-- Every claim there is, or one person's: { full words, what kind if it's mine (for releasing it), what, user, short words }.
function ui.claims_of(user)
  local owned, here = {}, {} -- (a claim on a track that isn't there isn't listed: its owner drops it, sync.drop_gone_claims)
  for i = 0, reaper.CountTracks(proj) - 1 do here[sync.base_name(select(2, reaper.GetTrackName(reaper.GetTrack(proj, i)))):lower()] = true end
  local function add(full, kind, what, u, short)
    if not user or u == user then owned[#owned + 1] = { full, u == cfg.user and kind, what, user = u, short = short } end
  end
  for name, c in pairs(who.tracks) do
    if here[name] then add(string.format("track %s: %s", c.name or name, c.user), "tracks", c.name or name, c.user, c.name or name) end
  end
  for name, c in pairs(who.regions) do add(string.format("region %s: %s", c.name or name, c.user), "regions", c.name or name, c.user, "region " .. (c.name or name)) end
  for _, t in ipairs(who.times or {}) do add(string.format("%s: %s", bar_span(t.from, t.to), t.user), "times", t, t.user, bar_span(t.from, t.to)) end
  table.sort(owned, function(x, y) return x[1] < y[1] end)
  return owned
end
-- chips: yours blue with an x that releases it, others' grey; they wrap like words
function ui.claim_chips(owned, short)
  local function release(o) -- let go of just this one
    local c, why = sync.my_claims(cfg, b.song, b.room)
    if not c then return band.msg(why) end
    local keep = {}
    for _, n in ipairs(c[o[2]] or {}) do
      local same = o[2] == "times" and math.abs(n.from - o[3].from) < 1e-6 and math.abs(n.to - o[3].to) < 1e-6
        or o[2] ~= "times" and n:lower() == o[3]:lower()
      if not same then keep[#keep + 1] = n end
    end
    c[o[2]] = keep
    sync.set_claims(cfg, b.song, b.room, c)
  end
  local avail, used = ImGui.GetContentRegionAvail(ctx), 0
  local h = ImGui.GetFrameHeight(ctx) - 2
  for i, o in ipairs(owned) do
    local words = short and o.short or o[1]
    local w = ImGui.CalcTextSize(ctx, words) + 18 + (o[2] and 16 or 0)
    if i > 1 and used + w + 6 <= avail then ImGui.SameLine(ctx, 0, 6) else used = 0 end
    used = used + w + 6
    local x, y = ImGui.GetCursorScreenPos(ctx)
    local dl = ImGui.GetWindowDrawList(ctx)
    ImGui.InvisibleButton(ctx, "##chip" .. i, w, h)
    local hovered = ImGui.IsItemHovered(ctx)
    ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + h, o[2] and theme.CHIP_MINE or theme.CHIP_OTHER, h / 2)
    ImGui.DrawList_AddText(dl, x + 9, y + (h - ImGui.GetTextLineHeight(ctx)) / 2, theme.TEXT, words)
    if o[2] then
      local over_x = hovered and select(1, ImGui.GetMousePos(ctx)) >= x + w - 22
      local cx, cy, r = x + w - 12, y + h / 2, 3.5
      local col = over_x and RED or MUTED
      ImGui.DrawList_AddLine(dl, cx - r, cy - r, cx + r, cy + r, col, 1.6)
      ImGui.DrawList_AddLine(dl, cx - r, cy + r, cx + r, cy - r, col, 1.6)
      if over_x and ImGui.IsItemClicked(ctx, 0) then release(o) end
      ImGui.SetItemTooltip(ctx, over_x and "Release it: it follows the driver again." or "Yours: only you change it, whoever drives.")
    else
      ImGui.SetItemTooltip(ctx, "Theirs: only they change it, whoever drives.")
    end
  end
end
-- Someone about to leave (lib/removal.lua): a minute to change your mind.
function ui.leaving_row(p)
  local groups, removal = require("groups"), require("removal")
  local m = p.user ~= cfg.user and removal.mark(cfg.root, p.user)
  if not m then return end
  ImGui.TextColored(ctx, YELLOW, string.format("Leaving the studio in %d s", math.max(0, removal.GRACE - (os.time() - (tonumber(m.at) or 0)))))
  if groups.may_manage(cfg.root, cfg.user) then
    next_to("Keep them")
    if ImGui.SmallButton(ctx, "Keep them##" .. p.user) then removal.keep(cfg.root, p.user) end
    ImGui.SetItemTooltip(ctx, "Changed your mind: nothing has happened yet.")
  end
end
-- Right-click a name: what you may do about them.
function ui.person_menu(p)
  local groups, removal = require("groups"), require("removal")
  local me = cfg.user
  if not ImGui.BeginPopupContextItem(ctx, "person " .. p.user) then return end
  ImGui.TextDisabled(ctx, p.user)
  if p.user == me then
    if ImGui.Selectable(ctx, "Change my name, colour...") then ui.go_settings("You") end
    ImGui.EndPopup(ctx)
    return
  end
  local mine, theirs, any = groups.role(cfg.root, me), groups.role(cfg.root, p.user), false
  if mine == "owner" then
    any = true
    if ImGui.Selectable(ctx, theirs == "admin" and "Make member..." or "Make admin...") then
      local on = theirs ~= "admin"
      if reaper.MB(on and ("Make " .. p.user .. " an admin of " .. tostring(view.group) .. "?\n\nThey can let people in, rename the studio, remove members and give claims. Only you can close it.")
          or ("Make " .. p.user .. " a member again?\n\nThey can't let people in, rename the studio or remove anyone any more."), "StudioSync", 4) == 6 then
        groups.set_admin(cfg.root, me, p.user, on)
        band.log(p.user .. (on and " is an admin now: they can let people in, rename the studio, remove members and give claims" or " is a member again"))
      end
    end
    if ImGui.Selectable(ctx, "Make owner...") and reaper.MB("Make " .. p.user .. " the owner of " .. tostring(view.group) .. "?\n\nYou stay on as an admin. Only they can give it back.", "StudioSync", 4) == 6 then
      groups.hand_over(cfg.root, me, p.user)
      band.log(p.user .. " owns " .. tostring(view.group) .. " now, and you're an admin")
    end
  end
  if view.driver == me and p.state ~= "offline" then
    any = true
    if ImGui.Selectable(ctx, "Hand over driving...") and reaper.MB("Make " .. p.user .. " the driver?", "StudioSync", 4) == 6 then
      sync.hand_over(proj, cfg, b.song, b.room, p.user); last = 0
    end
  end
  if groups.may_manage(cfg.root, me) then
    any = true
    if ImGui.BeginMenu(ctx, "Give them control of") then
      local n = reaper.CountSelectedTracks(proj)
      local give = function(words, tracks, regions, times)
        if reaper.MB("Give " .. p.user .. " " .. words .. " to change?\n\nIf someone else has it claimed, it moves to " .. p.user .. ".", "StudioSync", 4) == 6 then
          sync.give_claims(cfg, b.song, b.room, p.user, tracks, regions, times)
          band.log("gave " .. p.user .. " " .. words)
          last = 0
        end
      end
      if ImGui.MenuItem(ctx, n == 1 and "Selected track" or "Selected tracks", nil, false, n > 0) then
        local list = {}
        for i = 0, n - 1 do list[#list + 1] = part_name(reaper.GetSelectedTrack(proj, i)) end
        give(table.concat(list, ", "), list)
      end
      local rg = ui.selected_regions()
      if ImGui.MenuItem(ctx, #rg > 1 and "Selected regions" or "Selected region", nil, false, #rg > 0) then give("the region " .. table.concat(rg, ", "), {}, rg) end
      ImGui.SetItemTooltip(ctx, #rg > 0 and table.concat(rg, ", ") or "Click a region in the ruler first.")
      local from, to = reaper.GetSet_LoopTimeRange2(proj, false, false, 0, 0, false)
      if ImGui.MenuItem(ctx, "Time selection", nil, false, to - from >= 0.01) then give(bar_span(from, to), {}, {}, { { from = from, to = to } }) end
      ImGui.SetItemTooltip(ctx, to - from >= 0.01 and bar_span(from, to) or "Drag across the ruler first.")
      ImGui.EndMenu(ctx)
    end
  end
  if groups.may_remove(cfg.root, me, p.user) and not removal.mark(cfg.root, p.user) then
    any = true
    if ImGui.Selectable(ctx, "Remove from the others...") and reaper.MB("Take " .. p.user .. " out of " .. tostring(view.group) .. "?\n\n" ..
        "Within a few minutes every computer in the studio stops syncing with theirs. Their claims go free. What they made stays in the songs and on Restore.\n\n" ..
        "They keep the copy they already have: that can't be taken back. If they also have the studio's Google Drive folder, remove them there too.\n\n" ..
        "You have a minute to change your mind, and you can invite them again later.", "StudioSync", 4) == 6 then
      local ok, why = removal.remove(cfg.root, p.user, me)
      if ok then band.log(p.user .. " leaves the studio in a minute: Keep them on their card stops it") else reaper.MB(why, "StudioSync", 0) end
    end
  end
  if not any then ImGui.TextDisabled(ctx, "Nothing here for you: the owner and admins manage the studio.") end
  ImGui.EndPopup(ctx)
end
-- A name, with its role beside it. Right-clicking it opens the menu.
function ui.person_name(p, size)
  ImGui.PushFont(ctx, ui.bold, size or 15)
  ImGui.Text(ctx, p.name)
  ImGui.PopFont(ctx)
  ImGui.SetItemTooltip(ctx, p.user == cfg.user and "You. Right-click: your name and colour." or "Right-click: their role, what they can change, or take them out.")
  ui.person_menu(p)
  local role = require("groups").role(cfg.root, p.user)
  if role == "owner" or role == "admin" then
    ImGui.SameLine(ctx, 0, 6)
    ImGui.TextDisabled(ctx, role)
  end
end
-- Hear someone: their whole mix, or (following them) what they play, on top of your own copy of the song. lib/hear.lua.
function ui.listen_button(p)
  local hear = require("hear")
  local key = "listen " .. tostring(proj)
  local on = reaper.GetExtState(band.SECTION, key) == p.user
  if on then ImGui.PushStyleColor(ctx, ImGui.Col_Button, ACCENT) end
  if ImGui.SmallButton(ctx, "Listen##" .. p.user) then
    local ok, why = hear.listen(proj, cfg, b, not on and p.user or nil)
    if ok == nil then band.msg(tostring(why))
    else band.log(on and ("stopped listening to " .. p.user) or ("listening to " .. p.user .. ": they get asked by their computer, a few seconds' wait")) end
  end
  if on then ImGui.PopStyleColor(ctx) end
  ImGui.SetItemTooltip(ctx, on and ("You hear only " .. p.user .. ". Click to stop.") or
    ("Hear only " .. p.user .. ", through SonoBus. With Follow off you get their whole mix; with Follow on you get what they're playing or recording, over your own copy of the song, so it's in better quality and you can watch it land."))
end
-- Under a person in Who's here (James, 2026-11-02): what they're working in or last worked in, opening to all they've claimed.
function ui.person_claims(user, last_track)
  local list = ui.claims_of(user)
  if (last_track or "") ~= "" then -- (a track that's gone isn't where anyone's working: Mac, 0.50.4)
    local there = false
    for i = 0, reaper.CountTracks(proj) - 1 do there = there or select(2, reaper.GetTrackName(reaper.GetTrack(proj, i))) == last_track end
    if not there then last_track = "" end
  end
  if #list == 0 and (last_track or "") == "" then return end
  local head = (last_track or "") ~= "" and ('Working in "' .. last_track .. '"') or list[1].short
  if #list > 0 then head = head .. string.format("  (%d claim%s)", #list, #list == 1 and "" or "s") end
  if ui.short then next_to(ImGui.CalcTextSize(ctx, head) + 34) end -- (beside the name: a line each cost three people half the column)
  if #list == 0 then return ImGui.TextDisabled(ctx, head) end
  local open = ImGui.TreeNodeEx(ctx, "claims " .. user, "", ImGui.TreeNodeFlags_None)
  ImGui.SameLine(ctx, 0, 0)
  ImGui.TextWrapped(ctx, head) -- (a tree node's own label doesn't wrap: a long track name ran off the card)
  if open then
    ImGui.PushID(ctx, user)
    ui.claim_chips(list, true)
    ImGui.PopID(ctx)
    ImGui.TreePop(ctx)
  end
end
-- The regions clicked in the ruler, by name. (A REAPER too old to say: the one at the edit cursor.)
function ui.selected_regions()
  local out = {}
  if reaper.GetRegionOrMarkerInfo_Value then
    for i = 0, reaper.GetNumRegionsOrMarkers(proj) - 1 do
      local m = reaper.GetRegionOrMarker(proj, i, "")
      if reaper.GetRegionOrMarkerInfo_Value(proj, m, "B_ISREGION") == 1 and reaper.GetRegionOrMarkerInfo_Value(proj, m, "B_UISEL") == 1 then
        local _, name = reaper.GetSetRegionOrMarkerInfo_String(proj, m, "P_NAME", "", false)
        if name ~= "" and not name:find("^%[claimed") then out[#out + 1] = name end
      end
    end
  else
    local _, ri = reaper.GetLastMarkerAndCurRegion(proj, reaper.GetCursorPositionEx(proj))
    local _, isrgn, _, _, name = reaper.EnumProjectMarkers3(proj, ri)
    if ri >= 0 and isrgn and name ~= "" then out[1] = name end
  end
  return out
end
local function section_claims()
  local owned = ui.claims_of()
  if who.mode ~= "driver" and who.mode ~= "admins" and cfg.user ~= who.driver then -- (sync.maker_may: shown, or it looks like a hole in the claims)
    local mirror, made = require("mirror"), {}
    for i = 0, reaper.CountTracks(proj) - 1 do
      local tr = reaper.GetTrack(proj, i)
      local name = sync.base_name(select(2, reaper.GetTrackName(tr)))
      if name ~= "" and not who.tracks[name:lower()] and mirror.is_creator(mirror.track_oid(tr), cfg.user) then made[#made + 1] = name end
    end
    if #made > 0 then ImGui.TextDisabled(ctx, "You made these, so they're yours to change until someone claims them: " .. table.concat(made, ", ")) end
  end
  if view.driver == cfg.user then -- the driver lets go of claims held by someone who isn't here (left the band, away)
    local away = {}
    for _, o in ipairs(owned) do
      if o.user ~= cfg.user then
        local here = false
        for _, r in ipairs(view.rows) do if r.name == o.user and r.state ~= "offline" then here = true end end
        if not here then away[o.user] = true end
      end
    end
    for who_ in pairs(away) do
      if ImGui.SmallButton(ctx, "Release " .. who_ .. "'s claims##rel" .. who_) and reaper.MB(who_ .. " isn't here. Release everything " .. who_ ..
          " has claimed, so it follows you (the driver) again? They're told when they're back, and can claim again.", "StudioSync", 4) == 6 then
        sync.release_claims(cfg, b.song, b.room, who_)
        band.log("released " .. who_ .. "'s claims: what they had follows the driver now")
      end
      ImGui.SetItemTooltip(ctx, who_ .. " isn't here: their claims keep those parts locked for everyone until released.")
    end
  end
  local locked = who.mode == "admins" and not require("groups").may_manage(cfg.root, cfg.user)
  if locked then return ImGui.TextDisabled(ctx, "Admins only here: an admin can give you tracks to work on.") end
  if ImGui.Button(ctx, "Claim selected tracks") then
    local list = {}
    for i = 0, reaper.CountSelectedTracks(proj) - 1 do list[#list + 1] = part_name(reaper.GetSelectedTrack(proj, i)) end
    if #list == 0 then band.msg("Select the tracks you want to own first.") else claim(list, {}) end
  end
  ImGui.SetItemTooltip(ctx, "The tracks you've selected become yours: only you can change them, whoever's driving.")
  next_to("Claim selected region")
  if ImGui.Button(ctx, "Claim selected region") then
    local list = ui.selected_regions()
    if #list == 0 then band.msg("Click a named region in the ruler first.") else claim({}, list) end
  end
  ImGui.SetItemTooltip(ctx, "Click a region in the ruler, then this. What's in that region is yours: only you can change it, whoever's driving. The rest of the song isn't touched.")
  next_to("Claim time selection")
  if ImGui.Button(ctx, "Claim time selection") then
    local from, to = reaper.GetSet_LoopTimeRange2(proj, false, false, 0, 0, false)
    if to - from < 0.01 then band.msg("Drag across the timeline to select the stretch of time you want to own first.") else
      local c, why = sync.my_claims(cfg, b.song, b.room)
      if not c then return band.msg(why) end
      c.times = c.times or {}
      c.times[#c.times + 1] = { from = from, to = to, at = os.date("!%Y-%m-%dT%H:%M:%SZ") } -- its own date (newest wins)
      sync.set_claims(cfg, b.song, b.room, c)
    end
  end
  ImGui.SetItemTooltip(ctx, "Drag across the ruler to select some time, then this. Whatever starts inside it is yours to change, whoever's driving (a track someone claimed still wins).\n" ..
    "Everyone sees it as a region named [claimed: you].")
  next_to("Release all claims")
  if ImGui.Button(ctx, "Release all claims") and reaper.MB("Release all your claims (tracks, regions and time)? Everything you claimed follows the driver again.",
      "StudioSync", 4) == 6 then
    local c = sync.my_claims(cfg, b.song, b.room) or {} -- (printing duties stay: "Stop printing them" lets those go)
    sync.set_claims(cfg, b.song, b.room, { tracks = {}, regions = {}, times = {}, prints = c.prints })
  end
end

-- A change in words, its positions as bars ("to bar 9 beat 3", not "to 20.50 s", which also broke mid-number when wrapped).
local function describe(e)
  return (recall.describe(e):gsub("( [at][to]?) (%d+%.%d+) s", function(w, n) return w .. " bar " .. bar_of(tonumber(n)) end))
end
-- History's "kind" filter: a set of event kinds, or a test on the change
local KINDS = {
  { "Every kind" }, { "Items (recordings, MIDI, moves, edits)", function(e) return e.obj == "item" and not e.gone end },
  { "Tracks (names, lanes, mute, folders)", function(e) return e.obj == "track" and not e.gone end },
  { "Plug-ins", function(e) return e.obj == "fx" end }, { "Automation, sends and track settings", function(e) return e.obj == "env" or e.obj == "recv" or e.obj == "misc" end },
  { "Deletes", function(e) return e.gone end },
  { "Brought back (undo, restore)", function(e) return e.restored ~= nil end },
  { "Notes and likes", { note = true, like = true } }, { "Tempo and arrangement", { timeline = true, shift = true } },
  { "Who drives (handovers)", { driver = true } }, { "Played or recorded together", { start = true, stop = true } },
}
local hf = { who = "", kind = 1, track = "", text = "" }
local function combo(label, cur, list, tip)
  ImGui.SetNextItemWidth(ctx, 170)
  local pick
  if ImGui.BeginCombo(ctx, label, cur) then
    for _, v in ipairs(list) do if ImGui.Selectable(ctx, v, v == cur) then pick = v end end
    ImGui.EndCombo(ctx)
  end
  ImGui.SetItemTooltip(ctx, tip)
  return pick
end
-- What can be done with a change, under it once it's clicked: Undo (only that change), restore to it (the selected tracks, or the
-- whole project: driver only), or a look at it in a side room. (Buttons on every row were clutter, and a radio above the list picking
-- what every row does hid Undo behind it, and acted on whatever was clicked next: review D29, James 2026-11-03.)
-- i: History index (the state right after entries[i]); what: words for the confirm box; single: a change of its own.
local function back_button(i, what, single)
  local e, mirror = entries[i], require("mirror")
  local opts = { can = can, mode = who and who.mode, local_mix = select(2, reaper.GetProjExtState(proj, band.SECTION, "local_mix")) == "1" }
  if single then
    ImGui.BeginDisabled(ctx, not e or e.kind ~= "obj")
    if ImGui.SmallButton(ctx, "Undo this change") then
      local others, me = mirror.later_by_others(entries, i), false
      for k = #others, 1, -1 do if others[k] == cfg.user then table.remove(others, k); me = true end end
      if me then table.insert(others, 1, "You") end -- (it named you in the third person: laptop 0.34.4)
      local whose = #others == 1 and me and "your" or "their"
      if #others == 0 or reaper.MB(table.concat(others, ", ") .. " changed it after this: undoing it takes " .. whose .. " change back too. Undo anyway?",
          "StudioSync", 4) == 6 then
        band.log(mirror.revert(proj, cfg, b.song, b.room, mirror.plan_undo_moment(entries, i), opts)); hist_at = 0
      end
    end
    ImGui.EndDisabled(ctx)
    local together = #mirror.same_moment(entries, i)
    ImGui.SetItemTooltip(ctx, e and e.kind == "obj" and ((together > 1 and string.format("Undo this and the %d other change(s) made with it: ", together - 1) or "Undo only this change: ") ..
      describe(e) .. ". Everything else stays; the undo goes to the others as a new change.")
      or "This kind of change (tempo, a handover, a note) isn't undone on its own: restore the whole project to here instead.")
    next_to("Restore selected tracks to here")
  end
  if ImGui.SmallButton(ctx, "Restore selected tracks to here") then
    local scope = mirror.selection_scope(proj)
    if not scope then band.msg("Select the tracks to put back first (click their names in REAPER).")
    elseif reaper.MB("Put the selected tracks (their items and plug-ins) back to how they were " .. what .. "?\n\nEverything else stays as it is now.", "StudioSync", 4) == 6 then
      band.log(mirror.revert(proj, cfg, b.song, b.room, mirror.plan_restore(entries, i, scope), opts)); hist_at = 0
    end
  end
  ImGui.SetItemTooltip(ctx, "The tracks selected in REAPER, as they were " .. what .. ". It goes to the others as new changes.")
  next_to("Restore whole project to here")
  local driving = view.driver == cfg.user
  ImGui.BeginDisabled(ctx, not driving)
  if ImGui.SmallButton(ctx, "Restore whole project to here") and reaper.MB("Make the whole project look like it did " .. what .. "?\n\n" ..
      "Everything since then is undone, for everyone. It's a change like any other, so you can come back the same way.", "StudioSync", 4) == 6 then
    sync.restore_timeline(proj, cfg, b.song, b.room, entries, i, view.session)
    band.log(mirror.revert(proj, cfg, b.song, b.room, mirror.plan_restore(entries, i), opts))
    last, hist_at = 0, 0
  end
  ImGui.EndDisabled(ctx)
  ImGui.SetItemTooltip(ctx, driving and ("The whole project, as it was " .. what .. ". It goes to the others as new changes.") or "The driver does this.")
  next_to("Open in side room")
  if ImGui.SmallButton(ctx, "Open in side room") then
    -- a look at that moment that touches nobody's work: a new room, put back to then. Archive it (Rooms) when you've heard it.
    local name = "Check " .. os.date("%H%M%S")
    local p, why = require("rooms").create(proj, cfg, b, name)
    if not p then band.msg(why) else
      local room_can = sync.authority(cfg, b.song, name, view.session)
      local plan = mirror.plan_restore(entries, i)
      sync.restore_timeline(p, cfg, b.song, name, entries, i, view.session, b.room)
      band.log("'" .. name .. "' is the project as it was " .. what .. ": " .. tostring(mirror.revert(p, cfg, b.song, name, plan, { at_once = true, can = room_can, mode = "claims", exact = true })))
      local beat = tonumber(reaper.GetExtState(band.SECTION, "live " .. tostring(p)))
      if not (beat and reaper.time_precise() - beat < 5) then band.start_live(dir) end
      reaper.SetExtState(band.SECTION, "panel page", "Rooms", false)
    end
  end
  ImGui.SetItemTooltip(ctx, "Opens the project as it was " .. what .. " in a new side room, to check it's the right one. Nothing changes for anyone else.")
end
-- Each person's own colour, as drawings and tracks show them.
function ui.person_colour(user)
  local name = user:gsub(" %(.-%)$", "")
  local rgb = require("people").colours(cfg.root, { name })[name]
  return rgb and ((rgb << 8) | 0xFF) or theme.TEXT
end
-- What a change did, at a glance: taken out in red, brought back in green.
function ui.change_tint(e) return e.gone and RED or e.restored ~= nil and GREEN or nil end
-- One change or saved version: its time and words, the whole line a button that opens its options under it. One open at a time.
function ui.change_row(key, time, words, i, what, single, who_, tint)
  local avail = ImGui.GetContentRegionAvail(ctx)
  local at = ImGui.CalcTextSize(ctx, time) + 8
  local _, h = ImGui.CalcTextSize(ctx, (who_ and (who_ .. ": ") or "") .. words, nil, nil, false, avail - at)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local open = hf.open == key
  if ImGui.Selectable(ctx, "##row", open, ImGui.SelectableFlags_None, avail, h) then hf.open, hf.show = not open and key or nil, true end
  ImGui.SetCursorScreenPos(ctx, x, y)
  ImGui.TextDisabled(ctx, time)
  ImGui.SameLine(ctx, 0, 8)
  if who_ then
    ImGui.PushFont(ctx, ui.bold, 15)
    ImGui.TextColored(ctx, ui.person_colour(who_), who_ .. ":")
    ImGui.PopFont(ctx)
    ImGui.SameLine(ctx, 0, 5)
  end
  if tint then ImGui.PushStyleColor(ctx, ImGui.Col_Text, tint) end
  ImGui.TextWrapped(ctx, words)
  if tint then ImGui.PopStyleColor(ctx) end
  if open then
    ImGui.Indent(ctx, at)
    back_button(i, what, single)
    ImGui.Unindent(ctx, at)
    if hf.show then ImGui.SetScrollHereY(ctx, 1); hf.show = nil end -- (the last row's options opened out of sight, and it looked like nothing happened)
    ImGui.Spacing(ctx)
  end
end

-- Filtered: the matching changes as one list (newest first), each with its own button.
local function history_filtered(driving)
  local want = KINDS[hf.kind][2]
  local text = hf.text:lower()
  local n = 0
  for i = #entries, 1, -1 do
    local e = entries[i]
    local line = describe(e)
    local lane = require("mirror").lane_words(entries, i) -- (in the search too: "lane" found nothing though every row said it: Mac, 0.45.0)
    local ok = not e.auto and (hf.who == "" or e.user == hf.who) and (not want or (type(want) == "function" and want(e)) or (type(want) == "table" and want[e.kind]))
      and (hf.track == "" or (e.name or e.track or ""):lower() == hf.track:lower())
      and (text == "" or (line .. lane .. " " .. tostring(e.user)):lower():find(text, 1, true))
    local moment = ok and require("mirror").same_moment(entries, i) or { i }
    for _, j in ipairs(moment) do if j > i then ok = false end end -- (one row for one act, on the newest of them)
    if ok then line = line .. lane end
    if #moment > 1 then line = line .. string.format(" (%d changes at that moment, undone together)", #moment) end
    if ok then
      n = n + 1
      ImGui.PushID(ctx, i)
      ui.change_row(e.id or i, local_time(e.time), line, i, string.format("right after %s's change at %s", e.user, local_time(e.time)), true, e.user, ui.change_tint(e))
      ImGui.PopID(ctx)
    end
  end
  if n == 0 then ImGui.TextDisabled(ctx, "Nothing matches.") end
end
local function section_recall()
  if not ui.short then ImGui.SeparatorText(ctx, "Saved versions") end -- (short: the box's own words say it, and the list gets the row)
  ImGui.SetNextItemWidth(ctx, -130)
  local _, v = ImGui.InputTextWithHint(ctx, "##label", "name this version (e.g. 'chorus with double guitars')", label, ImGui.InputTextFlags_None)
  label = v
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Save this version") then
    recall.save(proj, cfg, b.song, b.room, label ~= "" and label or "saved by " .. cfg.user)
    label = ""
    last = 0
  end
  if ImGui.SmallButton(ctx, "Render current mix") then action("Final mix") end
  ImGui.SetItemTooltip(ctx, "Renders the whole project as your master has it (in your File > Render format) into the shared folder's mixes/ for everyone, and to Google Drive if you use it.\n" ..
    "Everyone's parts are in it, yours too. Only tracks that stay on this computer ('yours, not sent', StudioSync's helpers) are left out. Nothing is added to the project.")
  ImGui.SameLine(ctx, 0, 4)
  if ImGui.SmallButton(ctx, "Back up") then recall.back_up(proj, cfg, b); last = 0 end
  ImGui.SetItemTooltip(ctx, "Keeps the project as it stands now: a saved version here that's never trimmed, and the project on Google Drive if you use it. No audio is rendered.")
  next_to("Save a copy outside the studio")
  if ImGui.SmallButton(ctx, "Save a copy outside the studio") then
    local keep, wav = "As it is (FLAC, as recorded)", "With WAV files"
    local pick = band.pick({ "#A plain project of its own, with all its media", keep, wav })
    if pick == keep or pick == wav then require("export").ask(proj, b.song, pick == wav) end
  end
  ImGui.SetItemTooltip(ctx, "A separate plain REAPER project in a folder you pick, with every file it uses, that opens anywhere with no StudioSync. Nothing in the studio changes, and nothing you do to the copy goes to anyone.\n\n" ..
    "For an older version: click it below, Open in side room, then save the copy from that room.")
  local driving = view.driver == cfg.user
  -- (docked, the list takes the column's height instead of a short box inside it)
  if ImGui.BeginChild(ctx, "points", 0, wide and math.max(70, select(2, ImGui.GetContentRegionAvail(ctx)) - 4) or 110, ImGui.ChildFlags_Borders) then
    if #points == 0 then ImGui.TextDisabled(ctx, "None yet. Every handover saves one by itself.") end
    local before = select(2, reaper.GetProjExtState(proj, band.SECTION, "before_bandsync"))
    if before ~= "" and reaper.file_exists(before) then
      if ImGui.SmallButton(ctx, "Open it as it was before StudioSync") then reaper.Main_OnCommand(40859, 0); reaper.Main_openProject(before) end
      ImGui.SetItemTooltip(ctx, "Opens the copy saved when this project was first published, in a new tab (it isn't shared).")
    end
    for i, p in ipairs(points) do
      ImGui.PushID(ctx, i)
      local upto = 0 -- (mirror sessions: the point is a moment in History)
      for k, e in ipairs(entries) do if (e.time or "") <= (p.time or "") then upto = k end end
      ui.change_row("version " .. i, local_time(p.time), string.format("%s%s%s", p.label, p.keep and " (kept)" or "", (p.takes or 0) > 0 and string.format("  ·  %d takes", p.takes) or ""), upto, "at '" .. p.label .. "'", nil, tostring(p.by), p.keep and GREEN or nil)
      ImGui.PopID(ctx)
    end
    ImGui.EndChild(ctx)
  end
end

local function section_history()
  local warm, read, total = recall.warm(cfg, b.song, b.room, 0.01)
  if not warm then return ImGui.TextDisabled(ctx, string.format("Reading the history: %d of %d changes...", read, total)) end
  if reaper.time_precise() - hist_at > 4 then hist_at = reaper.time_precise(); refresh_history() end
  if ui.short then ImGui.AlignTextToFramePadding(ctx); ImGui.TextDisabled(ctx, "Every change, newest first"); ImGui.SameLine(ctx)
  else ImGui.SeparatorText(ctx, "Every change, newest first") end
  ImGui.SetItemTooltip(ctx, "Click a change to undo it, restore to it, or open it in a side room.")
  local driving = view.driver == cfg.user
  if #groups == 0 then ImGui.TextDisabled(ctx, "Nothing has happened in this room yet.") end
  -- filters: who, what kind, which track, and words
  local users, tracks, seen = { "Everyone" }, { "Every track" }, {}
  for _, e in ipairs(entries) do
    if e.user and not seen["u" .. e.user] then seen["u" .. e.user] = true; users[#users + 1] = e.user end
    local tn = e.kind == "obj" and e.name or e.track -- (mirror changes carry the track's name; .track is its id)
    if tn and tn ~= "" and not seen["t" .. tn:lower()] then seen["t" .. tn:lower()] = true; tracks[#tracks + 1] = tn end
  end
  local kinds = {}
  for i, k in ipairs(KINDS) do kinds[i] = k[1] end
  local function filters()
    local v = combo("##hwho", hf.who == "" and "Everyone" or hf.who, users, "Only this person's changes.")
    if v then hf.who = v == "Everyone" and "" or v end
    next_to(170)
    v = combo("##hkind", KINDS[hf.kind][1], kinds, "Only this kind of change.")
    if v then for i, k in ipairs(kinds) do if k == v then hf.kind = i end end end
    next_to(170)
    v = combo("##htrack", hf.track == "" and "Every track" or hf.track, tracks, "Only changes on this track.")
    if v then hf.track = v == "Every track" and "" or v end
    next_to(150)
    ImGui.SetNextItemWidth(ctx, 150)
    local _, t = ImGui.InputTextWithHint(ctx, "##htext", "words in it", hf.text, ImGui.InputTextFlags_None)
    hf.text = t
    ImGui.SetItemTooltip(ctx, "Only changes whose description has these words (a take, a track, a note's text...).")
  end
  local filtered = hf.who ~= "" or hf.kind ~= 1 or hf.track ~= "" or hf.text ~= ""
  if wide or ImGui.GetContentRegionAvail(ctx) < 520 then -- (four rows of them came before the first change: design review)
    if ImGui.SmallButton(ctx, filtered and "Filter (on)..." or "Filter...") then ImGui.OpenPopup(ctx, "hfilters") end
    if ImGui.BeginPopup(ctx, "hfilters") then filters(); ImGui.EndPopup(ctx) end
  else filters() end
  if filtered then
    ImGui.SameLine(ctx)
    if ImGui.SmallButton(ctx, "Clear filters") then hf = { who = "", kind = 1, track = "", text = "" } end
    ImGui.SetItemTooltip(ctx, "Back to everything, grouped by who made it.")
  end
  -- (docked, no list box of its own: under the filters it had no height left, so the column itself scrolls instead)
  if wide or ImGui.BeginChild(ctx, "history", 0, math.max(300, select(2, ImGui.GetContentRegionAvail(ctx)) - 4)) then
    if filtered then
      history_filtered(driving)
      if not wide then ImGui.EndChild(ctx) end
      return
    end
    for gi = #groups, 1, -1 do
      local g = groups[gi]
      local shown = {} -- (prints StudioSync refreshed by itself are left out: no one made them)
      for i = g.first, g.last do if not entries[i].auto then shown[#shown + 1] = i end end
      if #shown == 0 then goto next_group end
      ImGui.PushID(ctx, gi)
      local n = #shown
      local who_ = g.user .. (g.solo and " (Solo edit)" or g.user == g.driver and " (driving)" or "")
      if n == 1 then -- (one change: the row itself, no list of one to open first)
        local i = shown[1]
        ui.change_row(entries[i].id or i, local_time(entries[i].time), describe(entries[i]) .. require("mirror").lane_words(entries, i), i,
          string.format("right after %s's change at %s", entries[i].user, local_time(entries[i].time)), true, who_, ui.change_tint(entries[i]))
        ImGui.PopID(ctx)
        goto next_group
      end
      local head = string.format("%s  ·  %s%s", who_, local_time(g.from), g.from ~= g.to and ("-" .. local_time(g.to):sub(7)) or "")
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, ui.person_colour(g.user))
      ImGui.PushFont(ctx, ui.bold, 15)
      local open = ImGui.TreeNodeEx(ctx, "g", head, ui.short and ImGui.TreeNodeFlags_None or ImGui.TreeNodeFlags_SpanAvailWidth)
      ImGui.PopFont(ctx)
      ImGui.PopStyleColor(ctx)
      if not open then -- what it was about, wrapped under the line that opens it (short: beside it, or a group took two rows of six)
        if ui.short then ImGui.SameLine(ctx, 0, 10) else ImGui.Indent(ctx) end
        ImGui.TextDisabled(ctx, describe(entries[shown[#shown]]) .. (n > 1 and string.format("  (+%d more)", n - 1) or ""))
        if not ui.short then ImGui.Unindent(ctx) end
      end
      if open then
        for k = #shown, 1, -1 do -- (newest first, as the page says: opened, a group read the other way, and the wrong moment got restored)
          local i = shown[k]
          local moment, first = require("mirror").same_moment(entries, i), true
          for _, j in ipairs(moment) do if j > i then first = false end end -- (one row for one act, as in the filtered list)
          if first then
            ImGui.PushID(ctx, i)
            ui.change_row(entries[i].id or i, local_time(entries[i].time):sub(7), describe(entries[i]) .. require("mirror").lane_words(entries, i) .. (#moment > 1 and string.format(" (%d changes at that moment, undone together)", #moment) or ""),
              i, string.format("right after %s's change at %s", entries[i].user, local_time(entries[i].time)), true, nil, ui.change_tint(entries[i]))
            ImGui.PopID(ctx)
          end
        end
        ImGui.TreePop(ctx)
      end
      ImGui.PopID(ctx)
      ::next_group::
    end
    if not wide then ImGui.EndChild(ctx) end
  end
end

-- Drum map of the selected tracks. Changing it rewrites the StudioSync MIDI on those tracks into the new map,
-- so the notes keep hitting the same drums with the new instrument.
-- Plug-ins everyone in the band has, as a folder in REAPER's FX browser (lib/plugins.lua).
local plugins = require("plugins")
local plug_info
local function section_plugins()
  heading("Plug-ins everyone has", 17)
  local about = "Each machine sends the studio its list of plug-ins (names only) when Live sync starts. What all of you have " ..
    "goes in the FX browser folder '" .. plugins.FOLDER .. "': use those and the project sounds the same on every machine. " ..
    "JSFX (REAPER's own effects, and ReaPack's) work on Windows and Mac alike."
  if ui.short then -- (the paragraph filled the column, and its button was below the fold)
    ImGui.SetItemTooltip(ctx, about)
    ImGui.TextDisabled(ctx, "A folder in the FX browser of what all of you have.")
    ImGui.SetItemTooltip(ctx, about)
  else
    ImGui.PushTextWrapPos(ctx, 0)
    ImGui.TextDisabled(ctx, about)
    ImGui.PopTextWrapPos(ctx)
  end
  if plug_info then ImGui.Text(ctx, plug_info) end
  if ImGui.Button(ctx, "Update the folder now") then
    local ok, n, why, members = pcall(function() plugins.publish(cfg); return plugins.update_folder(cfg) end)
    plug_info = not ok and ("Error: " .. tostring(n)) or n and string.format("%d plug-ins everyone has (lists from %s). Reopen the FX browser to see them.",
      n, table.concat(members or {}, ", ")) or why
  end
end

-- Live: hear each other while it happens, through ReaNINJAM and the band's NINJAM server.
local live = require("live")
local live_mode, live_send, live_server = "synced", true, nil
local services = require("services")
local srv_at, srv_up, srv_by = 0, false, nil
local LIVE_MODES = { { "synced", "Play along (synced to the project)" }, { "listen", "Real time (SonoBus, lowest delay)" }, { "jam", "Jam (NINJAM intervals)" } }

local setup = require("setup")

-- Real time: SonoBus joins the band's group by itself (StudioSync writes it into SonoBus's state).
local sb_link
local function sonobus_open()
  local link, m, i = setup.sonobus(cfg, b, proj, true)
  if not link then return band.msg(m) end
  sb_link = link
  reaper.TrackFX_Show(m, i, 3)
end

-- Real time mode: the one switch for playing together. Real time (SonoBus, set up for the band's group) plus side by side
-- with no lag: whoever presses play, stop or record, everyone follows at the same spot and hears it at once; what
-- they record shows on your timeline as they play (MIDI notes) and lands as a take when they stop.
local function same_room_on()
  local sm, si = live.fx(proj, false, live.SONOBUS)
  local sb_on = sm and not reaper.TrackFX_GetOffline(sm, si)
  return sb_on and select(2, reaper.GetProjExtState(proj, band.SECTION, "side")) == "0", sm, si
end
local function set_same_room(v)
  local _, sm, si = same_room_on()
  if v then
    local link, why = setup.sonobus(cfg, b, proj, true)
    if not link then return band.msg(why) end
    sb_link = link
    reaper.SetProjExtState(proj, band.SECTION, "side", "0")
    band.log("Real time mode on: you hear everyone, and play, stop and record go to everyone")
  else
    if sm then reaper.TrackFX_SetOffline(sm, si, true) end
    reaper.SetProjExtState(proj, band.SECTION, "side", "")
    band.log("Real time mode off: SonoBus left the studio and side by side is off (edits still sync)")
  end
end
local SAME_ROOM_TIP = "Real time mode. On: you hear each other right away through SonoBus (what each of you plays, over your own copy of the song),\n" ..
  "and whoever presses play, stop or record, everyone follows. What someone records shows on your timeline as they play\n" ..
  "(MIDI notes appear a few seconds behind) and lands as a take when they stop. Off: both off; edits keep syncing."

local server_at = 0
-- Reach the server: curl connects, and with nothing to say it runs out of time (28) or ends clean (0); it can't connect otherwise. (Blocks up to 3 s: only on a click.)
function ui.test_server(addr)
  if services.answers(addr) then return { true, "Reached it." } end
  return { false, "Can't reach it: is the server running, and can this computer reach that address?" }
end
local function section_live(part) -- part: "mode" or "rest" (docked, side by side), nil for all of it
  local lfile = band.song_dir(cfg, b.song) .. "/live.json"
  -- the host may fill the address in after this panel opened (it arrives through the shared folder): re-read it
  -- every few seconds while it's still empty here
  if not live_server or (live_server == "" and reaper.time_precise() - server_at > 3) then
    if not live_server then -- first look: the mode this project was last in (it used to reset to Play along)
      local saved = select(2, reaper.GetProjExtState(proj, band.SECTION, "live_mode"))
      if saved ~= "" then live_mode = saved end
    end
    server_at, live_server = reaper.time_precise(), (band.read_json(lfile) or {}).server or ""
  end
  if part ~= "rest" then
    ImGui.SeparatorText(ctx, "Mode")
    for _, m in ipairs(LIVE_MODES) do
      if ImGui.RadioButton(ctx, m[2], live_mode == m[1]) then live_mode = m[1]; reaper.SetProjExtState(proj, band.SECTION, "live_mode", m[1]) end
    end
    ImGui.TextWrapped(ctx, ({
      synced = "Play to the project; the others hear you in time with it, a bar or two behind you. What you play also shows up on their timeline as an idea until your real take arrives.",
      listen = "Hear each other right away, with no server to run. Best on wired internet, with collaborators not too far away; otherwise use Play along.",
      jam = "Everyone plays at once and hears the others one cycle late (classic NINJAM).",
    })[live_mode])
    if live_mode == "synced" then -- (the number Play along needs: listeners a whole interval behind)
      local ok_cfg, bpi = pcall(function() return tonumber((band.read(services.ninjam_dir() .. "/bandsync.cfg") or ""):match("DefaultBPI%s+(%d+)")) end)
      bpi = ok_cfg and bpi or 4
      local _, _, _, num = reaper.TimeMap_GetTimeSigAtTime(proj, reaper.GetCursorPositionEx(proj))
      local one = math.max(1, math.ceil(bpi / math.max(1, num or 4)))
      ImGui.TextDisabled(ctx, string.format("One NINJAM interval is %d beats, so %d bar%s here.", bpi, one, one == 1 and "" or "s"))
      if ImGui.SmallButton(ctx, "Put listeners one interval behind") then
        ui.want_lag = one -- (their boxes are further down)
        if not same_room_on() then reaper.SetProjExtState(proj, band.SECTION, "side", tostring(one)) end
      end
      ImGui.SetItemTooltip(ctx, "So what they hear of you lines up with their copy of the project. Sets Follow each other and Start together's 'bars later' below.")
    end
    ImGui.Spacing(ctx)
  end
  if part == "mode" then return end
  if same_room_on() then -- (my time / their time, a guest: moved here from Home)
    ImGui.SeparatorText(ctx, "Real time: how you hear the others")
    require("page_hear").realtime(ctx, ImGui, proj)
    ImGui.Spacing(ctx)
  end
  if live_mode == "listen" then
    local sm, si = live.fx(proj, false, live.SONOBUS)
    local on = sm and not reaper.TrackFX_GetOffline(sm, si)
    if ImGui.Button(ctx, on and "Open SonoBus##sb" or "Connect##sb") then sonobus_open() end
    ImGui.SetItemTooltip(ctx, "Turns on SonoBus, already set to join your studio: it sends what you play and brings the others in.")
    if on then
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, "Leave##sb") then reaper.TrackFX_SetOffline(sm, si, true) end
      ImGui.TextColored(ctx, GREEN, "SonoBus is on and connected to your studio, until you Leave.")
    elseif sm then
      ImGui.TextDisabled(ctx, "SonoBus is ready on your master track (off: it sends nothing until you Connect).")
    end
    if sb_link then
      if ImGui.SmallButton(ctx, "Copy join link") then ImGui.SetClipboardText(ctx, sb_link) end
      ImGui.SetItemTooltip(ctx, "For joining from SonoBus's own app (outside REAPER): its paste button fills the studio in.")
    end
    return
  end
  ImGui.SeparatorText(ctx, "Server")
  ImGui.TextDisabled(ctx, "Play along and Jam go through a NINJAM server on one computer, which the others have to be able to reach. The server only lets in addresses from Tailscale, which StudioSync's installer sets up: everyone signs in to the one account.")
  ImGui.SetNextItemWidth(ctx, 220)
  local changed, v = ImGui.InputTextWithHint(ctx, "##server", "its address:2049", live_server, ImGui.InputTextFlags_None)
  if changed then live_server = v end
  next_to("Save for the studio")
  if ImGui.SmallButton(ctx, "Save for the studio") then
    local data = band.read_json(lfile) or {} -- keep whatever else is in it
    data.server, data.by = live_server, nil -- (typed in: a server somewhere, not this computer's to run)
    band.write_json(lfile, data)
  end
  ImGui.SetItemTooltip(ctx, "Only for a server of your own: StudioSync runs one by itself otherwise, on whichever computer needs it first.")
  next_to("Test it")
  ImGui.BeginDisabled(ctx, live_server == "")
  if ImGui.SmallButton(ctx, "Test it") then ui.server_said = ui.test_server(live_server) end
  ImGui.EndDisabled(ctx)
  ImGui.SetItemTooltip(ctx, "Tries to reach the server from this computer.")
  if ui.server_said then ImGui.TextColored(ctx, ui.server_said[1] and GREEN or YELLOW, ui.server_said[2]) end
  do
    if reaper.time_precise() - srv_at > 3 then srv_at, srv_up, srv_by = reaper.time_precise(), services.running("ninjamsrv"), (band.read_json(lfile) or {}).by end -- tasklist is slow: not every frame
    ImGui.TextDisabled(ctx, srv_up and "Server: running on this computer" or (live_server ~= "" and srv_by and srv_by ~= cfg.user) and ("Server: on " .. srv_by .. "'s computer") or "Server: Connect starts one on this computer")
    ImGui.SameLine(ctx)
    if ImGui.SmallButton(ctx, "Host it here") then
      local server, why = services.ninjam_for(cfg, lfile, true, true)
      if server then live_server = server else band.msg(why) end
    end
    ImGui.SetItemTooltip(ctx, "Runs the server on this computer and points the studio at it. Handy when the computer that had it is staying off.")
  end
  local _, s = ImGui.Checkbox(ctx, "Send my audio (my whole mix)", live_send)
  live_send = s
  ImGui.Spacing(ctx)
  local master, idx = live.fx(proj, false)
  if not master then
    if ImGui.Button(ctx, "Connect") then
      if live_server == ((band.read_json(lfile) or {}).server or "") then -- (or an address typed in just now, not saved: that one)
        local server, why = services.ninjam_for(cfg, lfile, true)
        if server then live_server = server else band.msg(why) end
      end
      local sdir = (reaper.GetProjectName(proj) ~= "" and reaper.GetProjectPathEx(proj) or reaper.GetResourcePath()):gsub("\\", "/") .. "/bandsync_live"
      reaper.RecursiveCreateDirectory(sdir, 0)
      reaper.SetProjExtState(proj, band.SECTION, "live_dir", sdir)
      local ok, e = live.configure(cfg, live_server, live_mode, live_send, sdir)
      if not ok then band.msg(e) else
        local m2, i2 = live.fx(proj, true)
        if m2 then
          reaper.TrackFX_Show(m2, i2, 3)
          reaper.SetExtState(band.SECTION, "ninjam connect " .. tostring(proj), "1", false) -- (Live sync presses Connect: lib/producer.lua)
        else band.msg("Couldn't add ReaNINJAM to the master track.") end
      end
    end
    ImGui.SetItemTooltip(ctx, "Adds ReaNINJAM to your master track with everything filled in, and connects it. If nobody's running a server, this computer does.")
  else
    -- (it may sit on any track: say which)
    local where = master == reaper.GetMasterTrack(proj) and "your master track" or ("track '" .. select(2, reaper.GetTrackName(master)) .. "'")
    ImGui.TextColored(ctx, GREEN, "ReaNINJAM is on " .. where .. ".")
    next_to("NINJAM click on/off")
    if ImGui.SmallButton(ctx, "NINJAM click on/off") then
      if not live.toggle_click() then band.msg("Open ReaNINJAM's window first (Show it).") end
    end
    ImGui.SetItemTooltip(ctx, "NINJAM's own metronome ticks the whole time you're connected (at the server's tempo, not the project's).\n" ..
      "StudioSync turns it off for Play along and Real time; this flips it if it's on anyway.")
    local cm = live.channel_mode()
    if live_mode == "synced" and cm and cm ~= "session" then
      ImGui.PushTextWrapPos(ctx, 0)
      ImGui.TextColored(ctx, YELLOW, "It's sending in " .. (cm == "normal" and "Normal" or "Voice Chat") .. " mode, so Play along won't line up: " ..
        "in its window, click the mode button under your channel and pick \"Session mode channel\" (or restart REAPER).")
      ImGui.PopTextWrapPos(ctx)
    end
    if ImGui.Button(ctx, "Show it") then -- also takes it off other song tabs (one ReaNINJAM per REAPER) and loads it
      local m2, i2 = live.fx(proj, true)
      if m2 then reaper.TrackFX_Show(m2, i2, 3) end
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Leave") and not live.close_boxes() then reaper.TrackFX_Delete(master, idx) end -- (lib/live.lua: a second press, with one of its boxes up)
  end
  ImGui.TextDisabled(ctx, "(?) about changing mode or server")
  ImGui.SetItemTooltip(ctx, "ReaNINJAM reads its settings once per REAPER session: after changing the mode or the server, restart REAPER. " ..
    "Play along ideas appear when the listener disconnects (ReaNINJAM writes what it heard only then).")
end

local setup_at, st = 0, {}
-- What StudioSync did lately (sends, what arrived, what was put back and why): it used to pop the console up
local function section_activity()
  local lines = band.activity()
  local newest = lines[1] and lines[1]:sub(7) or "nothing yet"
  if #newest > 64 then newest = newest:sub(1, 61) .. "..." end -- cut short visibly, not mid-word with nothing after
  -- "###": the label changes with every line, the header (and whether it's open) stays the same one
  if ImGui.CollapsingHeader(ctx, "Activity (" .. newest .. ")###activity") then
    if ImGui.BeginChild(ctx, "activity", 0, 140, ImGui.ChildFlags_Borders) then
      for _, l in ipairs(lines) do ImGui.TextWrapped(ctx, l) end
      ImGui.EndChild(ctx)
    end
    if ImGui.SmallButton(ctx, "Clear") then reaper.DeleteExtState(band.SECTION, band.LOG_KEY, false) end
    ImGui.SameLine(ctx)
    if ImGui.SmallButton(ctx, "Open the full console") then reaper.ShowConsoleMsg("") end
  end
end



-- ---- Together: start/stop at once, notes and likes, live ideas, and the tools (lib/tools.lua) ----------------
local countin, lag_bars, note_text, bars = 1, 0, "", 1
local function sel_take()
  local it = reaper.GetSelectedMediaItem(proj, 0)
  local tk = it and reaper.GetActiveTake(it)
  if not tk then return nil end
  local id = band.take_id(tk) or (band.take_ext(tk, "band_dry") ~= "" and band.take_ext(tk, "band_dry")) or nil
  return id, it, tk
end
local function go(ev) -- post it for the band, and fire it here through our own Live sync
  ev.at = math.floor(os.time()) + together.LEAD
  sync.post(cfg, b.song, b.room, ev)
  ev.user = cfg.user
  reaper.SetExtState(band.SECTION, "transport " .. tostring(proj), band.json_encode(ev), false)
end
local start_from, click_on, side_bars_edit = 0, true, 2 -- start_from: 0 = edit cursor, n = the nth region
local function regions()
  local out, i = {}, 0
  while true do
    local ok, isrgn, p, e, name = reaper.EnumProjectMarkers3(proj, i)
    if ok == 0 then break end
    if isrgn then out[#out + 1] = { name = name ~= "" and name or ("region " .. (#out + 1)), pos = p } end
    i = i + 1
  end
  return out
end
local function section_together()
  together.tick()
  if ui.want_lag then lag_bars, side_bars_edit, ui.want_lag = ui.want_lag, ui.want_lag, nil end
  local key = tostring(proj)
  -- Side by side: everyone's normal transport buttons drive everyone
  ImGui.SeparatorText(ctx, "Side by side")
  -- kept in the project (until 0.11.3 it was per tab and lost when the tab was closed and reopened)
  local side = select(2, reaper.GetProjExtState(proj, band.SECTION, "side"))
  local ch, on = check("Follow each other: press play, stop and record as usual", side ~= "")
  if ch then
    reaper.SetProjExtState(proj, band.SECTION, "side", on and tostring(side_bars_edit) or "")
  end
  ImGui.SetItemTooltip(ctx, "Whoever presses play, stop or record (or jumps somewhere while playing), everyone in side by side follows.\n" ..
    "The one who records records; the others hear it. Edits land as usual, every half second.")
  ImGui.SetNextItemWidth(ctx, 118)
  local rt = same_room_on() -- (Real time mode is following at 0 bars: changing it here would quietly switch Real time off)
  ImGui.BeginDisabled(ctx, rt)
  local lc, lv = ImGui.InputInt(ctx, "bars behind whoever plays", side_bars_edit)
  if lc then
    side_bars_edit = math.max(0, lv)
    if side ~= "" then reaper.SetProjExtState(proj, band.SECTION, "side", tostring(side_bars_edit)) end
  end
  ImGui.EndDisabled(ctx)
  ImGui.SetItemTooltip(ctx, rt and "Real time mode is on (Home): everyone follows at the same spot, 0 bars behind. Switch it off there to follow later." or
    "With Play along: 1-2 bars, so you hear them in time with the project.\nWith Real time: 0, everyone at the same spot.")
  if side ~= "" then
    local n = tonumber(side) or 0
    local live_mode_note = live.fx(proj, false) and "Play along / Jam is connected." or (live.fx(proj, false, live.SONOBUS) and "Real time is on."
      or "To hear each other, connect on Play.")
    ImGui.PushTextWrapPos(ctx, 0)
    ImGui.TextDisabled(ctx, string.format("On: you follow %s behind whoever plays. %s", n == 0 and "right along" or (n .. (n == 1 and " bar" or " bars")), live_mode_note))
    local cm = live.fx(proj, false) and live.channel_mode()
    if cm and cm ~= "session" then
      ImGui.TextColored(ctx, YELLOW, "ReaNINJAM is sending in " .. (cm == "normal" and "Normal" or "Voice Chat") ..
        " mode: the others won't hear you in time with the project. In its window, click the mode button under your channel and pick \"Session mode channel\".")
    end
    ImGui.PopTextWrapPos(ctx)
  end

  ImGui.SeparatorText(ctx, "Start together")
  ui.start_together(true)
end
-- Everyone starts at one moment, from one spot. `play_along`: with the Play tab's "bars later for listeners".
function ui.start_together(play_along)
  together.tick()
  local key = tostring(proj)
  local rg = regions()
  local names = { "the edit cursor (bar " .. bar_of(reaper.GetCursorPositionEx(proj)) .. ")" }
  for _, r in ipairs(rg) do names[#names + 1] = r.name .. " (bar " .. bar_of(r.pos) .. ")" end
  if start_from > #rg then start_from = 0 end
  ImGui.SetNextItemWidth(ctx, math.max(120, math.min(260, ImGui.GetContentRegionAvail(ctx) - 90)))
  if ImGui.BeginCombo(ctx, "start from", names[start_from + 1]) then
    for i, n in ipairs(names) do if ImGui.Selectable(ctx, n, start_from == i - 1) then start_from = i - 1 end end
    ImGui.EndCombo(ctx)
  end
  ImGui.SetNextItemWidth(ctx, 118)
  local _, c = ImGui.InputInt(ctx, "count-in bars", countin); countin = math.max(0, c)
  ImGui.SameLine(ctx)
  local _, ck = ImGui.Checkbox(ctx, "click", click_on); click_on = ck
  ImGui.SetItemTooltip(ctx, "The metronome plays during the count-in, then goes back off.")
  if play_along then
    ImGui.SetNextItemWidth(ctx, 118)
    local _, l = ImGui.InputInt(ctx, "bars later for listeners", lag_bars); lag_bars = math.max(0, l)
    ImGui.SetItemTooltip(ctx, "Play along only: the others start this many bars after you\n(one NINJAM interval), so what they hear of you lines up.\nLeave 0 for everything else.")
  end
  local pos = start_from > 0 and rg[start_from].pos or reaper.GetCursorPositionEx(proj)
  local function start(rec)
    go({ type = "start", rec = rec or nil, pos = pos, countin = together.bars_before(proj, pos, countin), click = click_on or nil,
      lag = together.bars_after(proj, pos, play_along and lag_bars or 0), lead = cfg.user })
  end
  if ImGui.Button(ctx, "Play together") then start(false) end
  next_to("Record together")
  if ImGui.Button(ctx, "Record together") then start(true) end
  ImGui.SetItemTooltip(ctx, "Everyone records on the tracks they have armed.")
  next_to("Stop together")
  if ImGui.Button(ctx, "Stop together") then go({ type = "stop" }) end
  local due = tonumber(reaper.GetExtState(band.SECTION, "together_at " .. key))
  if due and due - together.now() > 0 then
    ImGui.TextColored(ctx, YELLOW, string.format("Starting in %.1f s...", due - together.now()))
  else
    ImGui.TextDisabled(ctx, string.format("From bar %s, %d s after the click, on every computer with this project open.", bar_of(pos), together.LEAD))
  end
  local last_go = reaper.GetExtState(band.SECTION, "together " .. key)
  if last_go ~= "" then ImGui.TextDisabled(ctx, "Last: " .. last_go) end
end

local notes_at, notes = 0, {}
local ideas_at, ideas = 0, {}
local function section_notes()
  local id, it = sel_take()
  local place = id and "Note on selected take" or "Note at cursor"
  if ui.short then ImGui.SetNextItemWidth(ctx, -(ImGui.CalcTextSize(ctx, place) + ImGui.CalcTextSize(ctx, "Like selected take") + 48)) -- (buttons beside it: two rows and a line of words pushed the notes themselves out of a short docker)
  else
    ImGui.SeparatorText(ctx, "Notes and likes")
    ImGui.SetNextItemWidth(ctx, -1)
  end
  local entered, t = require("page_chat").input(ctx, ImGui, "##note", "a note for everyone, Enter to post (e.g. 'try the chorus an octave up')", note_text)
  note_text = t
  local whereto = id and string.format("Selected: %s's take on %s, bar %s", (id:match("^(.-)%-%d+%-%d+Z") or "?"):gsub("_", " "),
    sync.track_name(it), bar_of(reaper.GetMediaItemInfo_Value(it, "D_POSITION"))) or "No take selected: notes go at the edit cursor."
  if ui.short then ImGui.SetItemTooltip(ctx, whereto); ImGui.SameLine(ctx) else ImGui.TextDisabled(ctx, whereto) end
  local function mark(kind, text)
    local pos = reaper.GetCursorPositionEx(proj)
    local ev = { type = kind, text = text, take = id, pos = pos, track = it and sync.base_name(select(2, reaper.GetTrackName(reaper.GetMediaItem_Track(it)))) or nil }
    sync.post(cfg, b.song, b.room, ev)
    if it then sync.mark_item(it, pos, (kind == "like" and "+1 " or "") .. cfg.user .. (text and (": " .. text) or "")) end -- as everyone else gets it
    notes_at = 0
  end
  ImGui.BeginDisabled(ctx, note_text == "")
  if (ImGui.Button(ctx, place) or entered) and note_text ~= "" then mark("note", note_text); note_text = "" end
  ImGui.EndDisabled(ctx)
  ImGui.SameLine(ctx)
  ImGui.BeginDisabled(ctx, not id)
  if ImGui.Button(ctx, "Like selected take") then mark("like", nil) end
  ImGui.EndDisabled(ctx)
  if reaper.time_precise() - notes_at > 4 then
    -- (only notes: it read every change there is on the first click, 4500 files on Sunset Drive, and froze REAPER: James, 0.42.28)
    notes_at, notes = reaper.time_precise(), recall.notes(cfg, b.song, b.room)
  end
  -- (docked, the list takes the column's height, as the versions do; a 90 px box left the rest of a tall column empty)
  if ImGui.BeginChild(ctx, "notes", 0, wide and next(ideas) == nil and math.max(70, select(2, ImGui.GetContentRegionAvail(ctx)) - 4) or 90, ImGui.ChildFlags_Borders) then
    if #notes == 0 then ImGui.TextDisabled(ctx, "No notes yet.") end
    local shown_n, only = 0, require("page_chat").only()
    for i, e in ipairs(notes) do
      if only ~= "" and e.user ~= only then goto next_note end
      shown_n = shown_n + 1
      if shown_n > 30 then break end
      ImGui.PushID(ctx, i)
      if ImGui.SmallButton(ctx, "Go") then
        local it2 = e.take and band.find_take(proj, e.take)
        reaper.SetEditCurPos2(proj, e.pos or (it2 and reaper.GetMediaItemInfo_Value(it2, "D_POSITION")) or 0, true, false)
      end
      ImGui.SetItemTooltip(ctx, "Put the edit cursor there.")
      ImGui.SameLine(ctx)
      ImGui.TextWrapped(ctx, string.format("%s  %s: %s%s", local_time(e.time):sub(7), e.user, describe(e),
        e.take and e.pos and (" (bar " .. bar_of(e.pos) .. ")") or ""))
      ImGui.PopID(ctx)
      ::next_note::
    end
    ImGui.EndChild(ctx)
  end
end

local function section_ideas()
  if reaper.time_precise() - ideas_at > 2 then ideas_at, ideas = reaper.time_precise(), tools.ideas(proj) end
  if next(ideas) == nil then return end
  ImGui.SeparatorText(ctx, "Live ideas (what you heard in Play along, until the real takes arrive)")
  for who_, n in pairs(ideas) do
    ImGui.Text(ctx, string.format("%s: %d", who_, n))
    ImGui.SameLine(ctx)
    if ImGui.SmallButton(ctx, "Dismiss##" .. who_) then tools.dismiss_ideas(proj, who_); ideas_at = 0 end
  end
  if ImGui.Button(ctx, "Keep selected") then band.log(tools.keep_ideas(proj) .. " idea(s) kept as your own items"); ideas_at = 0 end
  ImGui.SetItemTooltip(ctx, "The selected placeholders stay for good (no take replaces them). Send them with Send selected to main if the studio should have them.")
end

local rooms = require("rooms")
local room_view, room_at, new_room, merge, dismissed = nil, -math.huge, "", nil, {}
local function live_running(p)
  local beat = tonumber(reaper.GetExtState(band.SECTION, "live " .. tostring(p)))
  return beat and reaper.time_precise() - beat < 5
end
local function go_room(name)
  local p, why = rooms.open(proj, cfg, b, name)
  if not p then return band.msg(why) end
  if not live_running(p) then band.start_live(dir) end -- runs for the tab in front: the room's
  reaper.SetExtState(band.SECTION, "panel page", "Rooms", false)
  room_at, merge = -math.huge, nil
end
local function refresh_rooms()
  if reaper.time_precise() - room_at < 2 and room_view and room_view.room == b.room then return end
  room_at = reaper.time_precise()
  room_view = { room = b.room, list = {}, binned = {}, people = {}, meta = rooms.meta(cfg, b.song, b.room) }
  for _, r in ipairs(rooms.list(cfg, b.song)) do
    table.insert((r.binned and r.name ~= b.room) and room_view.binned or room_view.list, r)
  end
  for _, r in ipairs(room_view.list) do room_view.people[r.name] = rooms.people(cfg, b.song, r.name) end
end

-- Bring this side room into the room it came from: what changed here and there since it was made, compared.
-- Bringing this side room into its parent (mirror sync): what only this room changed since it was made comes in,
-- what both changed stays as the parent has it (listed).
local function look_merge(parent)
  local m = room_view.meta or {}
  local mirror = require("mirror")
  local since = m.time
  if not since then merge = { why = "This room has no start time (made with an older StudioSync)." }; return end
  local bring, clash = mirror.plan_bring(mirror.room_newest(sync.room_dir(cfg, b.song, b.room), since),
    mirror.room_newest(sync.room_dir(cfg, b.song, parent), since), mirror.room_newest(sync.room_dir(cfg, b.song, parent)))
  merge = { bring = bring, clash = clash, parent = parent }
end

local function section_merge()
  if merge.why then ImGui.TextColored(ctx, YELLOW, merge.why); return end
  local parent = merge.parent
  if #merge.bring == 0 and #merge.clash == 0 then ImGui.TextDisabled(ctx, "No new changes here for '" .. parent .. "'. For anything older, or deleted there: select it and use Send selected."); return end
  ImGui.Text(ctx, string.format("%d change(s) to bring into '%s'", #merge.bring, parent))
  local describe = require("recall").describe
  for _, ev in ipairs(merge.bring) do ImGui.BulletText(ctx, describe({ kind = "obj", obj = ev.obj, name = ev.name, rev = ev.rev, gone = ev.gone, pos = ev.pos })) end
  if #merge.clash > 0 then
    ImGui.TextColored(ctx, YELLOW, string.format("%d also changed in '%s' since this room was made: '%s' keeps its own", #merge.clash, parent, parent))
    for _, ev in ipairs(merge.clash) do ImGui.BulletText(ctx, describe({ kind = "obj", obj = ev.obj, name = ev.name, rev = 2, pos = ev.pos })) end
  end
  local driver = sync.driver(cfg, b.song, parent, view.session)
  local may = driver == cfg.user
  ImGui.BeginDisabled(ctx, not may or #merge.bring == 0)
  if ImGui.Button(ctx, "Bring into " .. parent) and reaper.MB("Bring these changes into '" .. parent .. "'?\n\n" ..
      "They go to everyone there as new changes, so Restore there can undo them.", "StudioSync", 4) == 6 then
    -- (by that room's claims, as Send selected: it took James's claimed Drums into main: laptop, 0.42.9)
    local list, refused = require("mirror").allowed_into(cfg, b.song, parent, merge.bring, view.session)
    local ok, res = pcall(require("mirror").post_into, cfg, b.song, b.room, parent, list, rooms.tab(b.song, parent))
    band.log(ok and string.format("brought %d change(s) from '%s' into '%s'%s", res, b.room, parent, refused > 0 and string.format(" (%d not yours to change there, left out)", refused) or "")
      or ("bringing in failed: " .. tostring(res)))
    merge = nil
  end
  ImGui.EndDisabled(ctx)
  if not may then
    ImGui.SameLine(ctx)
    ImGui.TextDisabled(ctx, tostring(driver) .. " drives '" .. parent .. "': they bring it in (or take control there)")
  end
end

function ui.come_see()
  if ImGui.Button(ctx, "Come see!") then
    rooms.invite(cfg, b.song, b.room)
    band.log("asked everyone to come and see '" .. b.room .. "'")
  end
  ImGui.SetItemTooltip(ctx, "Everyone with this project open gets 'come and see " .. b.room .. "' at the top of their panel, with a Go button.")
end
local function rooms_squares()
  refresh_rooms()
  if ImGui.Button(ctx, "Create side room") then new_room = ""; ImGui.OpenPopup(ctx, "New side room") end
  ImGui.SetItemTooltip(ctx, "A copy of this room as it is now, in its own tab. Collaborators can join it from here.")
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, 16, 14)
  local naming = ImGui.BeginPopupModal(ctx, "New side room", nil, ImGui.WindowFlags_AlwaysAutoResize)
  ImGui.PopStyleVar(ctx)
  if naming then
    if ImGui.IsWindowAppearing(ctx) then ImGui.SetKeyboardFocusHere(ctx) end
    ImGui.SetNextItemWidth(ctx, 300)
    -- (no EnterReturnsTrue: with it the name came back only on Return, so pressing Create lost what was typed: Mac, 0.45.0)
    local _, v = ImGui.InputTextWithHint(ctx, "##newroom", "a name (e.g. 'chorus ideas')", new_room)
    new_room = v
    local go = ImGui.Button(ctx, "Create") or ImGui.IsKeyPressed(ctx, ImGui.Key_Enter) or ImGui.IsKeyPressed(ctx, ImGui.Key_KeypadEnter)
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Cancel") or ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then ImGui.CloseCurrentPopup(ctx) end
    if go then
      local p, why = rooms.create(proj, cfg, b, new_room)
      if not p then band.msg(why) else
        band.log("made the side room '" .. new_room .. "' from '" .. b.room .. "' (you drive it)")
        new_room = ""
        if not live_running(p) then band.start_live(dir) end
        reaper.SetExtState(band.SECTION, "panel page", "Rooms", false)
        room_at = -math.huge
        ImGui.CloseCurrentPopup(ctx)
      end
    end
    ImGui.EndPopup(ctx)
  end
  if ui.short and not (room_view.meta and room_view.meta.parent) then ImGui.SameLine(ctx); ui.come_see() end -- (a column of its own for one button: empty, in a short docker)
  ImGui.SameLine(ctx)
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.TextDisabled(ctx, "Try ideas in a side room, then bring back what works. (?)")
  ImGui.SetItemTooltip(ctx, "Each room is its own project tab: click its square to go there. It opens once, then it's a tab switch, and it's still there next " ..
    "session.\n\nCreate side room: a copy of the room you're in, as it is now; you drive it. Try your own edits there, or work on " ..
    "something else.\n\nCome see!: everyone with the project open is asked to join you.\n\nSend selected to main: the items you pick " ..
    "come over as new takes. Bring into main: everything changed in the side room comes over, except where main changed the same " ..
    "thing too (those stay as main has them); main's driver does this, and Restore can undo it.")
  local avail = ImGui.GetContentRegionAvail(ctx)
  local w, gap = 178, 8
  local per = math.max(1, math.floor((avail + gap) / (w + gap)))
  if wide then per = math.min(per, math.max(#room_view.list, 3)) end -- (a wide docker fitted ten thin ones: a few rooms left most of it empty)
  w = math.floor((avail - gap * (per - 1)) / per) -- (they fill the page, as the people's cards do)
  for i, r in ipairs(room_view.list) do
    if (i - 1) % per ~= 0 then ImGui.SameLine(ctx, 0, gap) end
    local here = r.name == b.room
    ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, CARD) -- a card in either look
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, 12, 10)
    local open = ImGui.BeginChild(ctx, "room " .. r.name, w, 0, ImGui.ChildFlags_Borders | ImGui.ChildFlags_AlwaysUseWindowPadding | ImGui.ChildFlags_AutoResizeY,
      ImGui.WindowFlags_NoScrollbar)
    ImGui.PopStyleVar(ctx)
    ImGui.PopStyleColor(ctx)
    if open then
      if not r.parent then -- the main room stands out: the outline, in the logo's colours
        local cx, cy = ImGui.GetWindowPos(ctx)
        local cw, ch = ImGui.GetWindowSize(ctx)
        local dl = ImGui.GetWindowDrawList(ctx)
        ImGui.PushClipRect(ctx, cx, cy, cx + cw, cy + ch, true) -- (true: with the column's own edges, or it ran past them)
        ui.gradient(dl, cx, cy, cx + cw, cy + ch, cx, cx + cw, function(col) ImGui.DrawList_AddRect(dl, cx + 1, cy + 1, cx + cw - 1, cy + ch - 1, col, 8, 0, 2) end)
        ImGui.PopClipRect(ctx)
      end
      if here then ImGui.TextColored(ctx, GREEN, r.name .. "  (this tab)") else ImGui.Text(ctx, r.name) end
      -- (short: a line for where it came from and a line for everyone in it, or three people ran off the foot of the square)
      local function beside(words) if ui.short then next_to(ImGui.CalcTextSize(ctx, words)) end end
      local came = r.parent and ("side room of " .. r.parent) or "main room"
      beside(came)
      ImGui.TextDisabled(ctx, came)
      local people = room_view.people[r.name] or {}
      if #people == 0 then ImGui.TextDisabled(ctx, "nobody") end
      for i, p in ipairs(people) do
        local who_ = p.user .. (p.me and " (you)" or "") .. (p.here and "" or ": tab open")
        if i > 1 then beside(who_) end
        if p.here then ImGui.TextColored(ctx, GREEN, who_) else ImGui.TextDisabled(ctx, who_) end
      end
      if r.parent and not here then
        beside("Archive")
        ImGui.BeginDisabled(ctx, #people > 0)
        if ImGui.SmallButton(ctx, "Archive") and reaper.MB("Take '" .. r.name .. "' off the list for everyone?\n\nNothing is deleted: it can be brought back from this page.", "StudioSync", 4) == 6 then
          rooms.bin(cfg, b.song, r.name, cfg.user); last = 0
        end
        ImGui.EndDisabled(ctx)
        ImGui.SetItemTooltip(ctx, #people > 0 and "Someone has it open: it can be archived once its tabs are closed." or "Takes this idea off the list for everyone. Nothing is deleted.")
      end
      -- the square itself goes there
      local hover = not here and ImGui.IsWindowHovered(ctx, ImGui.HoveredFlags_ChildWindows) and not ImGui.IsAnyItemHovered(ctx)
      if hover then
        ImGui.SetMouseCursor(ctx, ImGui.MouseCursor_Hand)
        local cx, cy = ImGui.GetWindowPos(ctx)
        local cw, ch = ImGui.GetWindowSize(ctx)
        ImGui.DrawList_AddRect(ImGui.GetWindowDrawList(ctx), cx, cy, cx + cw, cy + ch, ACCENT, 10, 0, 2)
        ImGui.SetTooltip(ctx, "Go to " .. r.name)
      end
      local go = hover and ImGui.IsMouseClicked(ctx, 0)
      ImGui.EndChild(ctx)
      if go then go_room(r.name) end
    end
  end
  if #room_view.binned > 0 and ImGui.TreeNodeEx(ctx, "archived", string.format("Archived rooms (%d)", #room_view.binned), ImGui.TreeNodeFlags_SpanAvailWidth) then
    for _, r in ipairs(room_view.binned) do
      if ImGui.SmallButton(ctx, "Bring back##" .. r.name) then rooms.bin(cfg, b.song, r.name, nil); last = 0 end
      ImGui.SameLine(ctx)
      ImGui.TextDisabled(ctx, r.name .. "  (archived by " .. tostring(r.binned) .. ")")
    end
    ImGui.TreePop(ctx)
  end
end
local function rooms_actions()
  if not room_view then return end
  if not wide then ImGui.Separator(ctx) end
  local parent = room_view.meta and room_view.meta.parent
  ui.come_see()
  if not parent then -- (a tall docker: what's in the tooltip, in the room there is)
    if wide then
      ImGui.TextDisabled(ctx, "Asks everyone with this project open to join you in this room.")
      ImGui.Spacing(ctx)
      heading("How rooms work")
      ImGui.TextDisabled(ctx, "Each room is its own project tab: click its square to go there. It opens once, then it's a tab switch.")
      ImGui.TextDisabled(ctx, "A side room is a copy of the room you're in, as it is now, and you drive it. Try your own edits there, or work on something else.")
      ImGui.TextDisabled(ctx, "From a side room, send over the items you pick, or bring in everything that changed. Restore can undo it.")
    end
    return
  end
  next_to("Send selected to " .. parent)
  if ImGui.Button(ctx, "Send selected to " .. parent) then
    local list = require("mirror").selected(proj, cfg, b.song, b.room, parent)
    local chosen = #list
    local refused
    list, refused = require("mirror").allowed_into(cfg, b.song, parent, list, view.session)
    if chosen == 0 then band.msg("Select the items to send first (they go to '" .. parent .. "' as they are here).")
    elseif #list == 0 then band.msg("None of those are yours to change in '" .. parent .. "': someone has claimed them, or " .. parent .. "'s driver owns them. Claim them there first.")
    elseif reaper.MB(string.format("Send the %d selected item(s) to '%s', as they are here? (Any of their tracks '%s' doesn't have yet go too.)",
        reaper.CountSelectedMediaItems(proj), parent, parent), "StudioSync", 4) == 6 then
      band.log(string.format("sent %d change(s) from '%s' to '%s'%s", require("mirror").post_into(cfg, b.song, b.room, parent, list, rooms.tab(b.song, parent)), b.room, parent,
        refused > 0 and string.format(" (%d not yours to change there, left out)", refused) or ""))
    end
  end
  ImGui.SetItemTooltip(ctx, "The easy way back: the selected items go to '" .. parent .. "' as they are here (new changes there, so Restore there can undo them).")
  next_to("Bring into " .. parent .. "...")
  if ImGui.Button(ctx, merge and "Look again" or ("Bring into " .. parent .. "...")) then look_merge(parent) end
  ImGui.SetItemTooltip(ctx, "Compares this room, '" .. parent .. "' and how this room started: everything changed here comes over, " ..
    "except what '" .. parent .. "' changed too since (it keeps its own; use Send selected for those). New recordings come too.")
  if merge then section_merge() end
end



-- Bandmates asking you to come and see their room (any tab of the song).
local invites, invites_at = {}, -math.huge
local function section_invites()
  if reaper.time_precise() - invites_at > 3 then invites_at = reaper.time_precise(); invites = rooms.invites(cfg, b.song) end
  for _, v in ipairs(invites) do
    local key = v.from .. v.time
    if v.room ~= b.room and not dismissed[key] then
      ImGui.PushID(ctx, key)
      if ImGui.SmallButton(ctx, "Go") then dismissed[key] = true; go_room(v.room) end -- (buttons first: long words pushed them off a narrow panel)
      ImGui.SameLine(ctx)
      if ImGui.SmallButton(ctx, "Not now") then dismissed[key] = true end
      ImGui.SameLine(ctx)
      ImGui.TextColored(ctx, YELLOW, v.from .. " asks you to come and see '" .. v.room .. "'")
      ImGui.PopID(ctx)
    end
  end
end

-- Docked wide and short (a bottom docker), a page's parts stand side by side as columns, each scrolling up and down on
-- its own, and the page scrolls sideways when they don't all fit; otherwise they come one under the other.
local function layout(parts, bare) -- { { fn, width } }; bare: what's in them is one card each, and the column is the card
  if not wide then
    for _, part in ipairs(parts) do part[1]() end
    return
  end
  local avail, h = ImGui.GetContentRegionAvail(ctx)
  local total = 0
  for _, part in ipairs(parts) do total = total + (part[2] or 340) end
  local scale = math.max(0.72, (avail - 10 * (#parts - 1)) / total) -- (fixed widths left the right of a wide docker empty: design review; a narrower one had them run off the right: Mac, 0.57.7)
  for i, part in ipairs(parts) do
    if i > 1 then ImGui.SameLine(ctx, 0, 10) end
    ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, theme.COLUMN)
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, 12, ui.short and 6 or 10)
    ImGui.BeginGroup(ctx)
    local open = ImGui.BeginChild(ctx, "col" .. i, math.floor((part[2] or 340) * scale), h, ImGui.ChildFlags_AlwaysUseWindowPadding)
    ImGui.PopStyleVar(ctx)
    ImGui.PopStyleColor(ctx)
    local more = false
    if open then
      ImGui.PushTextWrapPos(ctx, 0)
      ui.bare_cards = bare
      part[1]()
      ui.bare_cards = nil
      ImGui.PopTextWrapPos(ctx)
      -- (a fade at the foot says there's more; a line of words cost every column its height, whether it hid anything or not: design review)
      more = ImGui.GetScrollMaxY(ctx) - ImGui.GetScrollY(ctx) > ImGui.GetTextLineHeight(ctx)
      if more then
        local cx, cy = ImGui.GetWindowPos(ctx)
        local cw, ch = ImGui.GetWindowSize(ctx)
        local solid = theme.COLUMN
        ImGui.DrawList_AddRectFilledMultiColor(ImGui.GetWindowDrawList(ctx), cx, cy + ch - 22, cx + cw, cy + ch, solid & 0xFFFFFF00, solid & 0xFFFFFF00, solid, solid)
      end
      ImGui.EndChild(ctx)
    end
    ImGui.EndGroup(ctx)
  end
end

-- Maintenance: what's set up and working. Red: the band can't sync until it's fixed. Yellow: an extra, or worth a
-- look (dismissable). The sidebar shows the worst one still open.
local maint_st, maint_at = nil, -math.huge
local function maint_rows()
  if not maint_st or maint_st.for_proj ~= proj or reaper.time_precise() - maint_at > 10 then -- (another tab's said "Live sync is off" here: laptop, 0.34.9)
    maint_at, maint_st = reaper.time_precise(), setup.check(cfg, b, proj)
    maint_st.for_proj = proj
    -- MIDI tracks playing an instrument on another track that doesn't load here (lib/prints.lua prints.route)
    maint_st.routed = {}
    local prints = require("prints")
    for i = 0, reaper.CountTracks(proj) - 1 do
      local tr = reaper.GetTrack(proj, i)
      local dest = prints.route(tr)
      if dest and not prints.track_plays(tr) then
        local fx = select(2, reaper.TrackFX_GetFXName(dest, math.max(0, reaper.TrackFX_GetInstrument(dest))))
        maint_st.routed[#maint_st.routed + 1] = { track = select(2, reaper.GetTrackName(tr)), dest = select(2, reaper.GetTrackName(dest)),
          fx = (fx:gsub("^%w+i?: ", ""):gsub(" %(.-%)$", "")) }
      end
    end
  end
  local s = maint_st
  -- (Live sync, read now: a check made while a dialog paused every script, closing a tab, say, kept "Live sync is
  -- off" up for its 10 s)
  local beat = tonumber(reaper.GetExtState(band.SECTION, "live " .. tostring(proj)))
  s.sync = beat ~= nil and reaper.time_precise() - beat < 5
  local rows = {
    { "audio", s.audio, "red", "Audio device is running", "REAPER's audio device is closed: pick one in Preferences > Audio > Device." },
    { "folder", s.folder, "red", "Shared folder is syncing", "Syncthing isn't running: nothing reaches the studio or comes in." },
    { "sync", s.sync, "red", "Live sync is running", "Live sync is off in this tab: press Start at the top." },
    { "same", (tonumber(reaper.GetExtState(band.SECTION, "mirror drift " .. tostring(proj))) or 0) == 0, "red", "Changes from the others come out the same here",
      "Some changes from the others came out different here than on their machine (the Console names them). Ask the driver to " ..
      "use Restore > Back to here... > The whole project, or close and reopen this project." },
    -- (red only when a bandmate is online and we can't reach them: working alone showed red, with "Something needs
    -- fixing" on the tab, though nothing did: review, 2026-10-31)
    { "connected", s.connected, (function()
        for _, r in ipairs(view and view.rows or {}) do if r.age and r.age < 60 then return "red" end end
        return "grey" end)(),
      s.peers and string.format("Connected to %d of %d collaborator machine(s)", s.peers, s.devices) or "Shared folder is a cloud drive",
      s.peers and "Syncthing is connected to nobody. No collaborator is online, so that's fine: your changes reach them later."
      or "Can't tell whether Syncthing is connected." },
    { "sonobus", s.sonobus, "yellow", "SonoBus is ready (Real time mode)", "SonoBus isn't set up yet: Real time mode (Home) adds it." },
    (function() -- (an older REAPER can read a newer one's tracks and items differently: review item 33)
      local mine, other = reaper.GetAppVersion():match("^[%d%.]+"), {}
      for _, r in ipairs(view and view.rows or {}) do
        if r.reaper and r.reaper ~= mine then other[#other + 1] = r.name .. " " .. r.reaper end
      end
      return { "reaper", #other == 0, "yellow", "Everyone runs the same REAPER (" .. mine .. ")",
        "REAPER versions differ (you " .. mine .. "; " .. table.concat(other, ", ") .. "). Something made in a newer REAPER can come out " ..
        "different in an older one: the same version everywhere is safest." }
    end)(),
    (function() -- (a Mac bandmate never saw this in the old look. Mac, 0.42.27)
      local undo = require("undo")
      return { "keys", #undo.keys_left(dir) == 0, "yellow", undo.key_name() .. " never rolls back a collaborator's work",
        undo.key_name() .. " can roll back a collaborator's work: it isn't set to StudioSync's Undo yet." }
    end)(),
    { "tailscale", services.tailscale_up(), "yellow", "Tailscale is on", services.tailscale_installed() and "Tailscale is off or not signed in: open it and turn it on. The NINJAM route needs it." or "Tailscale isn't installed: run StudioSync's installer again, or get it from tailscale.com/download." },
  }
  if ui.play_shown() then
    rows[#rows + 1] = { "server", s.server, "yellow", "Play along server address is set", "No Play along server yet: Connect on the Play page starts one on this computer." }
    if s.hosting then rows[#rows + 1] = { "ninjam", s.ninjam, "yellow", "NINJAM server is running here", "NINJAM server isn't running here: Connect on the Play page starts it." } end
  end
  -- (a Mac showed its items OFFLINE while another app was in front, and nothing said why: 0.45.0)
  if reaper.SNM_GetIntConfigVar and reaper.SNM_GetIntConfigVar("offlineinact", 0) ~= 0 then
    rows[#rows + 1] = { "offline when inactive", false, "yellow", "", "REAPER takes your media offline whenever another app is in front, so parts show OFFLINE then. StudioSync turned this off once and it's back on: turn off 'Set media items offline when application is not active' in Preferences > Media." }
  end
  if view.newer then rows[#rows + 1] = { "update " .. view.newer, false, "yellow", "", "StudioSync " .. view.newer .. " is in use in the studio; you have " .. band.VERSION .. ": press Update below." } end
  pcall(require("drive").root, cfg) -- (what it says next is about the group it last looked at: this tab's, then. Mac, 0.51.12)
  local dmiss = reaper.GetExtState(band.SECTION, "drive_root") ~= "off" and require("drive").missing
  if dmiss then
    local dname = band.info(cfg.root).drive
    rows[#rows + 1] = { "drive", false, "yellow", "", "Google Drive: no shared " .. dname .. " folder in " .. dmiss .. " (at drive.google.com: Shared with me > right-click " .. dname .. " > Organize > Add shortcut > My Drive)." }
  end
  for _, m in ipairs(s.routed or {}) do
    rows[#rows + 1] = { "routed " .. m.track, false, "yellow", "", string.format("'%s' plays %s on '%s', which doesn't load on this computer: " ..
      "you hear the studio's print (the wet take) where there is one, and nothing where there isn't. Installing %s brings the notes back here.",
      m.track, m.fx, m.dest, m.fx) }
  end
  local daway = reaper.GetExtState(band.SECTION, "drive_root") ~= "off" and require("drive").away
  if daway then
    local who = daway:match("GoogleDrive%-([^/]+)/") or daway:match("^(%a:)")
    rows[#rows + 1] = { "drive away", false, "yellow", "", "Google Drive: the studio's folder (" .. tostring(who) .. ") isn't here now. Is that Google " ..
      "account signed out of Drive, or switched for another? Everything still syncs between you; the Drive copy catches up once it's back." }
  end
  return rows
end
local function dismissed_set()
  local set = {}
  for id in reaper.GetExtState(band.SECTION, "dismissed"):gmatch("[^|]+") do set[id] = true end
  return set
end
local function maint_level()
  local gone, worst = dismissed_set(), nil
  for _, r in ipairs(maint_rows()) do
    if not r[2] and r[3] ~= "grey" and not (r[3] == "yellow" and gone[r[1]]) then -- (grey: fine as it is, just said)
      if r[3] == "red" then return "red" end
      worst = "yellow"
    end
  end
  return worst
end
local function dot(col)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local h = ImGui.GetTextLineHeight(ctx)
  ImGui.DrawList_AddCircleFilled(ImGui.GetWindowDrawList(ctx), x + 5, y + h / 2 + 1, 5, col)
  ImGui.Dummy(ctx, 12, h)
end
local function maint_health()
  local gone = dismissed_set()
  if card("health") then
    if not ui.short then heading("Set up and health", 17) end -- (short: the tab above says it)
    local rows, three = {}, wide and ImGui.BeginTable(ctx, "healthrows", 3, ImGui.TableFlags_SizingStretchSame)
    for _, r in ipairs(maint_rows()) do if not r[2] then rows[#rows + 1] = r end end -- (what needs you first: it was below the fold docked)
    for _, r in ipairs(maint_rows()) do if r[2] then rows[#rows + 1] = r end end
    for _, r in ipairs(rows) do
      local ok = r[2]
      if ok or r[3] == "red" or not gone[r[1]] then
        if three then ImGui.TableNextColumn(ctx) end
        ImGui.PushID(ctx, r[1])
        dot(ok and GREEN or (r[3] == "red" and RED or r[3] == "grey" and GREY or YELLOW))
        ImGui.SameLine(ctx)
        ImGui.TextWrapped(ctx, ok and r[4] or r[5])
        if not ok and r[1] == "keys" then
          if ImGui.SmallButton(ctx, "Set " .. require("undo").key_name()) then require("undo").bind_keys(dir); maint_at = 0 end
          ImGui.SetItemTooltip(ctx, "With your own edit on top of REAPER's undo list it undoes that, as ever. With a collaborator's change on top, it undoes your own last change, not theirs.")
          ImGui.SameLine(ctx)
        end
        if not ok and r[3] == "yellow" then
          if three then next_to("Dismiss") end -- (on a row of its own it pushed the button below a short docker's fold)
          if ImGui.SmallButton(ctx, "Dismiss") then
            gone[r[1]] = true
            local list = {}
            for id in pairs(gone) do list[#list + 1] = id end
            reaper.SetExtState(band.SECTION, "dismissed", table.concat(list, "|"), true)
          end
          ImGui.SetItemTooltip(ctx, "Hide this one (it stops lighting up the sidebar). 'Show dismissed' brings it back.")
        end
        ImGui.PopID(ctx)
      end
    end
    if three then ImGui.EndTable(ctx) end
    if next(gone) then
      if ImGui.SmallButton(ctx, "Show dismissed") then reaper.DeleteExtState(band.SECTION, "dismissed", true) end
      ImGui.SetItemTooltip(ctx, "Bring back the yellow lines you dismissed.")
    end
    if ImGui.Button(ctx, "Set up everything I can") then
      local notes = setup.all(cfg, b, proj, maint_st, function() band.start_live(dir) end, ui.play_shown())
      maint_at, live_server = -math.huge, nil
      if #notes > 0 then band.log("Set up: " .. table.concat(notes, "; ")) end
    end
    ImGui.SetItemTooltip(ctx, "Starts Syncthing and Live sync, and adds SonoBus (off). The rest needs you.")
    card_end()
  end
end
local function maint_upkeep()
  if card("upkeep") then
    heading("Upkeep and activity", 17)
    section_activity()
    if ImGui.Button(ctx, "Update") then action("Update") end
    card_end()
  end
end
function ui.about()
  local s = ui.short and 110 or 140 -- (short: the whole logo, not its feet)
  if not wide then ImGui.Dummy(ctx, 0, 12) end
  local w = ImGui.GetContentRegionAvail(ctx)
  ImGui.SetCursorPosX(ctx, ImGui.GetCursorPosX(ctx) + math.max(0, (w - s - 170) / 2))
  logo(s)
  ImGui.SameLine(ctx, 0, 16)
  ImGui.SetCursorPosY(ctx, ImGui.GetCursorPosY(ctx) + (s - 52) / 2)
  ImGui.BeginGroup(ctx)
  wordmark(32)
  ImGui.TextDisabled(ctx, "version " .. band.VERSION)
  ImGui.EndGroup(ctx)
end

-- Home: playing together, who's here and what they're doing, and the session's switches.
local function home_play()
  local on = same_room_on()
  local ch, v = switch_row("##rt", "Real time mode", on, SAME_ROOM_TIP)
  if ch then set_same_room(v) end
  require("page_hear").fit(ctx, ImGui, "Configure SonoBus") -- (beside, or below in a narrow column: it was cut to "Configure Sono")
  if ImGui.SmallButton(ctx, "Configure SonoBus") then sonobus_open() end
  ImGui.SetItemTooltip(ctx, "Opens SonoBus's own window (volume and mute per collaborator, buffer, quality). You don't need it to play together.")
  if not ui.short then -- (a tall docker has the room)
    ImGui.TextDisabled(ctx, on and "You hear everyone live, and play, stop and record follow whoever presses them."
      or "Off: changes still sync, but you don't hear each other live or follow each other's play and stop.")
  end
  if on then require("page_hear").realtime(ctx, ImGui, proj) end
  local silent = reaper.GetExtState(band.SECTION, "rt silent " .. tostring(proj))
  if silent ~= "" then ImGui.TextColored(ctx, YELLOW, silent) end
  local trouble = reaper.GetExtState(band.SECTION, "rt trouble " .. tostring(proj))
  if trouble ~= "" then ImGui.TextColored(ctx, YELLOW, trouble) end
  local who_listens = reaper.GetExtState(band.SECTION, "listeners " .. tostring(proj))
  if who_listens ~= "" then ImGui.TextColored(ctx, ACCENT, who_listens .. " is listening to you") end
end
local function home_who()
  require("page_hear").producer(ctx, ImGui, proj, cfg, b, view and view.rows or {}) -- (at the top: at 560 wide it was past all three people. Mac, 0.58.5)
  heading("Who's here")
  if view.driver ~= cfg.user then -- next to the people: who drives is about them
    next_to("Take control")
    if ImGui.SmallButton(ctx, "Take control") then action("Take control") end
    ImGui.SetItemTooltip(ctx, tostring(view.driver) .. " is driving. Take control to make what nobody has claimed follow you (tell them first).")
  end
  next_to("Invite a collaborator")
  local services = require("services")
  local my_id = services.my_device_id()
  ImGui.BeginDisabled(ctx, not my_id)
  if ImGui.SmallButton(ctx, "Invite a collaborator") then
    ImGui.SetClipboardText(ctx, services.invite_text(my_id, band.info(cfg.root)))
    band.log("an invitation is on your clipboard: paste it to your collaborator (a message, an email). It installs StudioSync " ..
      "already paired with this computer; then press 'Let them in' here when they're done.")
  end
  ImGui.EndDisabled(ctx)
  ImGui.SetItemTooltip(ctx, my_id and "Copies a message with one line to paste on a Mac and one on Windows: it installs everything, " ..
    "already paired with this computer.\nWhen they've run it, 'Let them in' shows here." or "Waiting for Syncthing (it has to be running).")
  local people, armed = {}, {}
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    if reaper.GetMediaTrackInfo_Value(tr, "I_RECARM") == 1 then armed[#armed + 1] = select(2, reaper.GetTrackName(tr)) end
  end
  local ps = reaper.GetPlayStateEx(proj)
  people[1] = { name = cfg.user .. " (you)", user = cfg.user, state = "here", armed = armed, recording = ps & 4 == 4, playing = ps & 1 == 1,
    driving = view.driver == cfg.user, last_track = select(2, reaper.GetProjExtState(proj, band.SECTION, "last_track")) }
  for _, r in ipairs(view.rows) do
    people[#people + 1] = { name = r.name, user = r.name, state = r.state, armed = r.armed, recording = r.recording, playing = r.playing,
      driving = r.name == view.driver, version = r.version, mirror = r.mirror, last_track = r.last_track }
  end
  do -- following whoever drives, whoever that is
    if wide then next_to(ImGui.CalcTextSize(ctx, "Always follow the driver") + ImGui.GetFrameHeight(ctx) * 2 + 16) end -- (beside the heading: docked, its row is a person's)
    local on = reaper.GetExtState(band.SECTION, "follow driver") ~= ""
    local ch, v = switch_row("##followdriver", "Always follow the driver", on, "Your playhead goes with whoever's driving: play, pause, stop, record and where they are (you play along; only they record), and your view goes with theirs.")
    if ch then
      reaper.SetExtState(band.SECTION, "follow driver", v and "1" or "", true)
      if v then reaper.DeleteExtState(band.SECTION, "follow " .. tostring(proj), false) end
    end
  end
  if ui.short then
    for _, p in ipairs(people) do
      dot(p.state == "here" and GREEN or rgba(status.COLORS[p.state] or { 0.55, 0.55, 0.55 }))
      ImGui.SameLine(ctx, 0, 4)
      ui.person_name(p)
      if p.recording then ImGui.SameLine(ctx, 0, 6); pill("recording", RED) elseif p.driving then ImGui.SameLine(ctx, 0, 6); pill("driving", ACCENT, 0xFFFFFFFF) end
      if p.state == "syncing" then ImGui.SameLine(ctx, 0, 6); ImGui.TextColored(ctx, YELLOW, "getting changes") end -- (the bar just says "Sending")
      if p.mirror and view.my_mirror and p.state == "synced" then -- (as on the cards: the docked list said nothing, match or not)
        ImGui.SameLine(ctx, 0, 6)
        if p.mirror == view.my_mirror then ImGui.TextColored(ctx, GREEN, "same project")
        elseif settled_apart(p, view.my_mirror) then ImGui.TextColored(ctx, RED, "project differs")
        else ImGui.TextDisabled(ctx, "settling") end
      end
      if p.state ~= "here" and p.state ~= "offline" then
        next_to("Following"); tools.follow_button(p.name); next_to("Listen"); ui.listen_button(p); next_to("Producing")
        require("page_hear").produce_button(ctx, ImGui, proj, cfg, b, p.user)
      end
      if p.state ~= "here" then pcall(function() require("page_hear").person(ctx, ImGui, proj, p.name) end) end -- (hear them live or not)
      ui.person_claims(p.user, p.last_track)
      ui.leaving_row(p)
    end
    if #view.rows == 0 then ImGui.TextDisabled(ctx, "Nobody else has synced in this room yet.") end
    return
  end
  local avail = ImGui.GetContentRegionAvail(ctx)
  local w, gap = 214, 8
  local per = math.max(1, math.floor((avail + gap) / (w + gap)))
  w = math.floor((avail - gap * (per - 1)) / per) -- (they fill the page: a strip was left empty on the right)
  for i, p in ipairs(people) do
    if (i - 1) % per ~= 0 then ImGui.SameLine(ctx, 0, gap) end
    if card("who " .. p.name, w) then -- (grows with what they have armed)
      ui.person_name(p, 16)
      pill(p.state == "syncing" and "getting changes" or p.state, p.state == "here" and GREEN or rgba(status.COLORS[p.state] or { 0.55, 0.55, 0.55 }))
      ImGui.SetItemTooltip(ctx, ({ here = "This machine.", ["synced"] = "Has every change.", ["syncing"] = "Still getting changes (yours or the studio's).",
        offline = "Not seen for over a minute.", ["no receipt"] = "Has sent takes, but never ran Live sync here." })[p.state] or p.state)
      if p.recording then ImGui.SameLine(ctx, 0, 4); pill("recording", RED)
      elseif p.playing and p.state ~= "offline" then ImGui.SameLine(ctx, 0, 4); pill("playing", ACCENT, 0xFFFFFFFF) end
      if p.driving then ImGui.SameLine(ctx, 0, 4); pill("driving", ACCENT, 0xFFFFFFFF); ImGui.SetItemTooltip(ctx, "What nobody has claimed follows them.") end
      if p.armed and #p.armed > 0 then ImGui.TextDisabled(ctx, "armed: " .. table.concat(p.armed, ", "))
      elseif not wide then ImGui.TextDisabled(ctx, "nothing armed") end -- (docked, the line went to saying nothing)
      if p.version and p.version ~= band.VERSION then ImGui.TextColored(ctx, YELLOW, "StudioSync " .. p.version) end
      if p.mirror and view.my_mirror and p.state == "synced" then -- (while changes are still on their way it's bound to differ)
        if p.mirror == view.my_mirror then ImGui.TextColored(ctx, GREEN, "same project as yours")
        elseif not settled_apart(p, view.my_mirror) then ImGui.TextDisabled(ctx, "settling")
        else ImGui.TextColored(ctx, RED, "project differs from yours"); ImGui.SetItemTooltip(ctx, "They have every change, yet their project isn't the same as yours: " ..
          "Settings > Health says more, and the Console names what came out different.") end
      end
      if p.state ~= "here" and p.state ~= "offline" then
        tools.follow_button(p.name); ImGui.SameLine(ctx, 0, 4); ui.listen_button(p); ImGui.SameLine(ctx, 0, 4)
        require("page_hear").produce_button(ctx, ImGui, proj, cfg, b, p.user)
      end
      if p.state ~= "here" then pcall(function() require("page_hear").person(ctx, ImGui, proj, p.name) end) end -- (hear them live or not)
      ui.person_claims(p.user, p.last_track)
      ui.leaving_row(p)
      card_end()
    end
  end
  if #view.rows == 0 then ImGui.TextDisabled(ctx, "Nobody else has synced in this room yet.") end
  if not wide then home_play() end
end
-- Local mixing: your faders and pan stay yours (not sent, not overwritten). Off again: adopt the band's mix, or
-- send yours.
local function local_mix_row()
  local on = select(2, reaper.GetProjExtState(proj, band.SECTION, "local_mix")) == "1"
  local ch, v = switch_row("##localmix", "Local mixing", on, "Your faders and pan stay yours: nobody else's reach you and yours don't go out.")
  if ch and v then reaper.SetProjExtState(proj, band.SECTION, "local_mix", "1"); require("mirror").begin_local_mix(proj)
  elseif ch then
    -- (named choices: as Yes/No, "No" sent your faders and pan to every bandmate: review, 2026-10-31)
    local take, send = "Use the studio's mix (your faders and pan follow theirs again)", "Send my faders and pan to everyone (the tracks I may change)"
    local r = band.pick({ "#Local mixing off: whose mix?", take, send, "Cancel (keep Local mixing on)" })
    if r == take or r == send then
      require("mirror").end_local_mix(proj, cfg, b.song, b.room, r == take)
      reaper.SetProjExtState(proj, band.SECTION, "local_mix", "")
    end
  end
end
-- A gap between two parts sharing a column.
function ui.spacer() ImGui.Dummy(ctx, 0, 2); ImGui.Separator(ctx); ImGui.Dummy(ctx, 0, 2) end
-- What StudioSync just did, in whatever height is left under something short (Settings > Console keeps all of it).
function ui.feed(apart) -- apart: a line between it and what's above
  if select(2, ImGui.GetContentRegionAvail(ctx)) < 90 then return end
  if apart then ui.spacer() end
  local h = select(2, ImGui.GetContentRegionAvail(ctx))
  heading("What just happened", 17)
  if ImGui.BeginChild(ctx, "feed", 0, h - ImGui.GetFrameHeightWithSpacing(ctx) - 4) then
    ImGui.PushTextWrapPos(ctx, 0)
    local lines = band.activity()
    if #lines == 0 then ImGui.TextDisabled(ctx, "Nothing yet.") end
    for _, l in ipairs(lines) do ImGui.TextDisabled(ctx, l) end
    ImGui.PopTextWrapPos(ctx)
    ImGui.EndChild(ctx)
  end
end
local function home_session()
  if card("session") then
    heading("Edit settings", 17)
    ImGui.SetItemTooltip(ctx, "Who changes what")
    section_driver()
    local_mix_row()
    section_claims()
    card_end()
  end
end

local function home_rules()
  if ui.short then -- (the box and Local mixing share a row, and "Who controls" is the column's title)
    return section_driver(function() next_to(ImGui.CalcTextSize(ctx, "Local mixing") + ImGui.GetFrameHeight(ctx) * 2); local_mix_row() end)
  end
  heading("Edit settings", 17)
  ImGui.SetItemTooltip(ctx, "Who changes what")
  section_driver()
  local_mix_row()
end
local function home_claims()
  heading("Claims", 17)
  section_claims()
end
local function page_home()
  if ui.short then -- (Real time had to be scrolled to, under the people: design review)
    -- (hearing or producing someone, Real time's column has rows and rows of controls: it takes the width from the others, so they all fit without scrolling)
    local busy = same_room_on() or require("producer").who(proj)
    layout(busy and { { home_who, 500 }, { home_play, 440 }, { home_rules, 300 }, { home_claims, 200 } }
      or { { home_who, 540 }, { home_play, 280 }, { home_rules, 340 }, { home_claims, 280 } })
  elseif wide then -- (a tall docker: the people as cards, and nothing left alone in a tall column)
    layout({ { home_who, 760 }, { function() home_play(); ui.feed(true) end, 480 }, { function() home_rules(); ui.spacer(); home_claims() end, 480 } })
  else layout({ { home_who, 360 }, { home_session, 400 } }) end
end

local function settings_look()
  if card("look") then
    heading("Look", 17)
    do
      local pick = combo("Theme##theme", theme.name, theme.NAMES, "How the panel looks on this computer. It reopens to change.")
      if pick and pick ~= theme.name then
        reaper.SetExtState(band.SECTION, "theme", pick, true)
        -- (back where you were: it went to Home, a second trip here each time when comparing them: Mac, 0.45.0)
        reaper.SetExtState(band.SECTION, "panel page", "Settings", false); reaper.SetExtState(band.SECTION, "setup tab", "Options", false)
        reload_now = true
      end
    end
    local ch, v = switch_row("##native", "System window frame", native,
      "On: the system's window frame instead of the panel's own title bar (no docking by dragging the title then: use Dock).\n" ..
      "Off (the default): the panel's own dark title bar; right-click it or use Dock to dock. The panel reopens to switch.\n" ..
      "Either way, the Window button fills a screen or half of one.")
    if ch then reaper.SetExtState(band.SECTION, "panel_native", v and "on" or "", true); reload_now = true end
    local bon = reaper.GetExtState(band.SECTION, "banner") ~= "off"
    ch, v = switch_row("##banner", "Banner over REAPER while someone else drives", bon,
      "A slim note at the foot of REAPER's timeline saying what you can change (it never takes a click).")
    if ch then reaper.SetExtState(band.SECTION, "banner", v and "" or "off", true) end
    card_end()
  end
end
local function settings_sync()
  if card("sync") then
    if b then section_sync() end
    -- MIDI wet/dry, this machine's choice (lib/prints.lua): never changes what anyone else hears
    ImGui.SeparatorText(ctx, "MIDI and audio play as")
    local prints = require("prints")
    for _, m in ipairs({ { "auto", "Auto", "The dry take (the notes, through your instruments) when the track's plug-ins all load here, else the wet one." },
        { "notes", "Dry", "Always the dry take: the notes through your own instruments, so you can change the sound." },
        { "sound", "Wet", "Always the wet take: the sound the studio printed, exactly what whoever played it heard." } }) do
      if m[1] ~= "auto" then ImGui.SameLine(ctx) end
      if ImGui.RadioButton(ctx, m[2] .. "##midiplays", prints.mode() == m[1]) then
        reaper.SetExtState(band.SECTION, "midi_plays", m[1], true)
        if b then for i = 0, reaper.CountMediaItems(proj) - 1 do prints.choose(reaper.GetMediaItem(proj, i)) end end
      end
      ImGui.SetItemTooltip(ctx, m[3])
    end
    prints.options(ctx, ImGui) -- rendering in the background
    require("midiview").options(ctx, ImGui)
    require("people").track_options(ctx, ImGui) -- whose colours tracks show here
    if b and can then require("colours").draw(ctx, ImGui, proj, cfg, function(name, tr) -- (a track you made is yours, as mirror.watch has it: Mac, 0.57.6)
      return can(cfg.user, name) or sync.maker_may(require("mirror").track_oid(tr), cfg.user, name, nil, who and who.mode)
    end, view.driver == cfg.user or (who and who.mode) == "open") end
    card_end()
  end
end
local function settings_drive()
  if card("drive") then
    section_drive()
    card_end()
  end
end
-- You: the same on this computer whatever's open.
function ui.settings_you()
  if card("you") then
    if not ui.short then heading("You", 17) end
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, "You're " .. cfg.user)
    ImGui.SameLine(ctx)
    if ImGui.SmallButton(ctx, "Change name") then
      local ok, name = reaper.GetUserInputs("StudioSync: your name", 1, "Your name (collaborators see it),extrawidth=120", cfg.user)
      name = ok and band.clean(name) or ""
      if name ~= "" and name ~= cfg.user then
        reaper.SetExtState(band.SECTION, "user", name, true)
        band.rename(cfg.root, cfg.user, name)
        cfg.user = name
      end
    end
    ImGui.SetItemTooltip(ctx, "Your name in StudioSync, everywhere (Who's here, claims, who drives). Your tracks stay yours, and\n" ..
      "the studio's machines learn the new name. Changes you made before keep the old one in Restore.")
    local function studios()
      local n = #require("page_groups").live_groups()
      ImGui.AlignTextToFramePadding(ctx)
      ImGui.Text(ctx, string.format("You're in %d studio%s", n, n == 1 and "" or "s"))
      ImGui.SameLine(ctx)
      if ImGui.SmallButton(ctx, "Your studios") then page = "Groups"; require("page_groups").root = nil end
      ImGui.SetItemTooltip(ctx, "All of them: switch between them, invite people, rename, close or leave. The studio pill at the top goes there too.")
    end
    if wide then ImGui.SameLine(ctx, 0, 32); studios() end -- (docked: on your name's row, or it was below the fold)
    require("people").colour_options(ctx, ImGui, cfg)
    if not wide then ImGui.Spacing(ctx); studios() end
    card_end()
  end
end

-- What most people never need: Hold my changes causes more clashes than it saves, and prints happen by themselves.
function ui.settings_advanced()
  if card("advanced") then
    if not ui.short then heading("Advanced", 17) end
    if b then
      local hold = select(2, reaper.GetProjExtState(proj, band.SECTION, "hold")) ~= ""
      local ch, v = switch_row("##hold", "Hold my changes", hold, "Try things: your changes go out once, when you switch this off. Anything someone else changes on the same parts meanwhile clashes with yours.")
      if ch then reaper.SetProjExtState(proj, band.SECTION, "hold", v and "1" or "") end
      require("prints").printing_ui(ctx, ImGui, cfg, b, proj, who)
      if ui.short then next_to("Prepare this project") end
      if ImGui.Button(ctx, "Prepare this project") then action("Prepare session") end
      ImGui.SetItemTooltip(ctx, "Takes into lanes, FLAC (recording and existing WAVs), clear track names, media in the project folder, tidy-up: a checklist first. A shared project's changes go to everyone.")
    end
    local ch0, v0 = switch_row("##showplay", "Show the Play/Jam tab", ui.play_shown(), "Starting together, Play along and Jam. Play along and Jam go through NINJAM, which needs a server the others can reach.\nReal time mode, Follow and Listen don't need any of it.")
    if ch0 then reaper.SetExtState(band.SECTION, "show play", v0 and "1" or "", true) end
    card_end()
  end
end
function ui.settings_buffer()
  if card("rt buffer") then
    heading("Real time buffer", 17)
    ImGui.TextDisabled(ctx, "How much sound SonoBus keeps in hand, on this computer. More holds steadier and arrives later.")
    local sonobus = require("sonobus")
    local cur = reaper.GetExtState(band.SECTION, "rt buffer")
    cur = cur ~= "" and cur or "steady"
    for i, o in ipairs(sonobus.BUFFERS) do
      if ui.short and i > 1 then next_to(o[2]) end
      if ImGui.RadioButton(ctx, o[2], cur == o[1]) and cur ~= o[1] then
        reaper.SetExtState(band.SECTION, "rt buffer", o[1], true)
        if b and same_room_on() then setup.sonobus(cfg, b, proj, true) end
      end
    end
    ImGui.SetItemTooltip(ctx, "If Their time won't stay lined up, or it crackles, go up one. Over the internet nothing's instant: Real time on Wi-Fi landed about 200-300 ms behind in our tests.")
    card_end()
  end
end
function ui.settings_cant_hear()
  if card("cant hear") then
    heading("Can't hear each other?", 17)
    ImGui.TextDisabled(ctx, "Real time goes straight between your computers: SonoBus's public server only introduces you. StudioSync tells you when SonoBus can't join at all, or when someone's playing and nothing's arriving. Then, in this order:")
    ImGui.BulletText(ctx, "Configure SonoBus (Home) shows each person and how their connection is doing. Disconnect and connect again.")
    ImGui.BulletText(ctx, "Wired internet, rather than Wi-Fi.")
    ImGui.BulletText(ctx, "Forward a UDP port on your router to this computer. SonoBus's options can fix the port it uses.")
    ImGui.BulletText(ctx, "A strict router or a work network can stop computers reaching each other directly. A VPN between you gets around that: Tailscale comes with StudioSync, so check everyone's signed in to the one account.")
    if ImGui.SmallButton(ctx, "Get Tailscale") then
      if reaper.CF_ShellExecute then reaper.CF_ShellExecute("https://tailscale.com/download") else band.msg("tailscale.com/download") end
    end
    card_end()
  end
end
local function page_setup()
  if not ImGui.BeginTabBar(ctx, "setup", ImGui.TabBarFlags_FittingPolicyScroll) then return end -- (scrolls when narrow: squeezed, the names read "Hea... Con...")
  -- (the tabs stay put: only what's under them scrolls)
  local function body(id, fn)
    if ImGui.BeginChild(ctx, id, 0, 0, 0, wide and ImGui.WindowFlags_HorizontalScrollbar or 0) then
      if ImGui.IsWindowAppearing(ctx) then ImGui.SetScrollY(ctx, 0) end -- (the red row and the newest lines were out of sight, where it had last been left: Mac, 0.57.7)
      ImGui.PushTextWrapPos(ctx, 0)
      fn()
      ImGui.PopTextWrapPos(ctx)
      ImGui.EndChild(ctx)
    end
  end
  local go_tab = reaper.GetExtState(band.SECTION, "setup tab")
  if go_tab ~= "" then reaper.DeleteExtState(band.SECTION, "setup tab", false) end
  local function tab(name) return ImGui.BeginTabItem(ctx, name, nil, go_tab == name and ImGui.TabItemFlags_SetSelected or 0) end
  if b and tab("Health") then body("s health", function() maint_health(); if wide then ui.feed() end end); ImGui.EndTabItem(ctx) end
  if tab("You") then body("s you", ui.settings_you); ImGui.EndTabItem(ctx) end
  if tab("Options") then
    body("s options", function() layout({ { settings_look, 320 }, { settings_sync, 420 }, { settings_drive, 360 } }, true) end)
    ImGui.EndTabItem(ctx)
  end
  if tab("Advanced") then body("s advanced", function() layout({ { ui.settings_advanced, 360 }, { ui.settings_buffer, 420 }, { ui.settings_cant_hear, 640 } }, true) end); ImGui.EndTabItem(ctx) end
  if tab("Console") then
    -- StudioSync's own log, newest first (REAPER's console only shows it while open)
    if ImGui.SmallButton(ctx, "Clear") then reaper.DeleteExtState(band.SECTION, band.LOG_KEY, false) end
    ImGui.SameLine(ctx)
    if ImGui.SmallButton(ctx, "Copy") then ImGui.SetClipboardText(ctx, table.concat(band.activity(), "\n")) end
    ImGui.SetItemTooltip(ctx, "Copy the whole log, to paste it in a message when something went wrong.")
    if ImGui.BeginChild(ctx, "console", 0, 0, ImGui.ChildFlags_Borders) then
      for _, l in ipairs(band.activity()) do ImGui.TextWrapped(ctx, l) end
      ImGui.EndChild(ctx)
    end
    ImGui.EndTabItem(ctx)
  end
  if tab("Updates") then body("s updates", function() layout({ { maint_upkeep, 1000 }, { ui.about, 400 } }, true) end); ImGui.EndTabItem(ctx) end
  ImGui.EndTabBar(ctx)
end

local PAGES = {
  { "Projects", "This studio's projects, in their folders: open one, share one, file them, or free up space." },
  { "Home", "Who's here and what they're doing, real time mode, following and listening, and who changes what." },
  { "Rooms", "The project's rooms: make a side room to try things, have everyone come and see, and bring work back." },
  { "Play/Jam", "Start together, Play along and Jam (NINJAM). Settings > Advanced shows or hides this tab." },
  { "Chat", "Messages, to-dos, notes and links for this room, this project or the whole studio." },
  { "Restore", "Every change, and three ways back: the whole project, the selected tracks, or one change." },
  { "Plugins", "Every plug-in in this project, who doesn't have it, and the studio's translations for it." },
  { "Settings", "You, options, health (red: needs fixing, yellow: worth a look), the console and updates." },
}
local LOBBY = { Groups = true, Projects = true, Settings = true } -- (what there is with no group project in front. Groups isn't a tab: the group pill goes there)
function ui.play_shown() return reaper.GetExtState(band.SECTION, "show play") == "1" end
function ui.pages()
  local out = {}
  for _, p in ipairs(PAGES) do
    if b and p[1] ~= "Projects" and (p[1] ~= "Play/Jam" or ui.play_shown()) or not b and LOBBY[p[1]] then out[#out + 1] = p end
  end
  return out
end
local OLD_PAGES = { History = "Restore", Together = "Home", Live = "Home", Setup = "Settings", Maintenance = "Settings", Play = "Play/Jam" } -- (links from older versions)
local page = "Home"
local level, level_at = nil, -math.huge
local function nav_dot(p)
  if p == "Settings" and level then return level == "red" and RED or YELLOW end
end
-- The Dock button: left-click picks a side; right-click arms drag-to-dock (green) so moving the window around never
-- docks it by accident (unarmed, dragging docks only with Shift held). On the session's top bar and the start screen.
-- Follow a bandmate's view (lib/presence.lua): Live sync moves this arrange view to theirs, a few seconds behind.
tools.follow_button = function(name)
  local key = "follow " .. tostring(proj)
  local on = reaper.GetExtState(band.SECTION, key) == name
  if on then ImGui.PushStyleColor(ctx, ImGui.Col_Button, ACCENT) end
  if ImGui.SmallButton(ctx, (on and "Following" or "Follow") .. "##follow" .. name) then
    if on then reaper.DeleteExtState(band.SECTION, key, false) else
      reaper.SetExtState(band.SECTION, key, name, false)
      reaper.SetExtState(band.SECTION, "follow driver", "", true)
    end
  end
  if on then ImGui.PopStyleColor(ctx) end
  ImGui.SetItemTooltip(ctx, on and ("You follow " .. name .. ": their play, pause, stop and record, and their view. Click to stop.")
    or ("Follow " .. name .. ": your playhead goes with theirs (play, pause, stop, jumps; when they record you play along), and your view goes where theirs is."))
end

-- Floating, one button for where the window goes: Dock and Full screen were two more, and the row wrapped. Right-click arms drag-to-dock, as Dock's did.
function ui.window_button()
  local armed = reaper.GetExtState(band.SECTION, "dock armed") ~= ""
  if armed then ImGui.PushStyleColor(ctx, ImGui.Col_Button, 0x2E7D4FFF) end
  local clicked = ImGui.Button(ctx, "Window")
  if armed then ImGui.PopStyleColor(ctx) end
  if ImGui.IsItemClicked(ctx, 1) then
    if armed then reaper.DeleteExtState(band.SECTION, "dock armed", false) else reaper.SetExtState(band.SECTION, "dock armed", "1", false) end
  end
  ImGui.SetItemTooltip(ctx, armed and "Drag-to-dock is on: drag the window onto a REAPER docker. Right-click to turn it off."
    or "Dock it, fill the screen it's on or half of it. Right-click: turn on drag-to-dock (or hold Shift while dragging).")
  if clicked then ui.window_menu() end
end
function ui.window_menu()
  local full = placed_how == "Fill this screen"
  local list = { "Dock at the bottom", "Dock at the left", "Dock at the right", full and "Exit full screen" or "Fill this screen" }
  for _, w in ipairs(WINDOW_MENU) do if w ~= "Fill this screen" then list[#list + 1] = w end end
  local pick = band.pick(list)
  local side = pick and ({ ["Dock at the bottom"] = 0, ["Dock at the left"] = 1, ["Dock at the right"] = 3 })[pick]
  if side then tools.dock_at(side)
  elseif pick == "Exit full screen" then place_window("Back to before")
  elseif pick then place_window(pick) end
end
-- Into REAPER's docker on that side (0 bottom, 1 left, 3 right): an empty one goes there if there's none.
tools.dock_at = function(pos)
  local found
  for i = 0, 15 do if reaper.DockGetPosition(i) == pos then found = i; break end end
  if found then dock_req = ~found -- (ReaImGui: dock id -1 is REAPER docker 0, -2 docker 1, ...)
  else
    local free = require("tools").free_docker()
    dock_req = ~free
    dock_side = { docker = free, action = pos == 1 and 41599 or 41601, since = reaper.time_precise() } -- Docker: Show in left / right of main window
  end
end
tools.dock_menu = function(docked)
  local armed = reaper.GetExtState(band.SECTION, "dock armed") ~= ""
  if armed then ImGui.PushStyleColor(ctx, ImGui.Col_Button, 0x2E7D4FFF) end
  if ImGui.Button(ctx, docked and "Undock" or "Dock") then
    if docked then dock_req = 0 else ImGui.OpenPopup(ctx, "dockside") end
  end
  if armed then ImGui.PopStyleColor(ctx) end
  if not docked and ImGui.IsItemClicked(ctx, 1) then
    if armed then reaper.DeleteExtState(band.SECTION, "dock armed", false) else reaper.SetExtState(band.SECTION, "dock armed", "1", false) end
  end
  ImGui.SetItemTooltip(ctx, docked and "Back to a window of its own." or (armed and "Drag-to-dock is on: drag the window onto a REAPER docker. Right-click to turn it off."
    or "Click: dock at the bottom, left or right of REAPER. Right-click: turn on drag-to-dock (or hold Shift while dragging)."))
  if ImGui.BeginPopup(ctx, "dockside") then
    for _, side in ipairs({ { "Bottom", 0 }, { "Left", 1 }, { "Right", 3 } }) do
      if ImGui.Selectable(ctx, side[1]) then tools.dock_at(side[2]) end
    end
    ImGui.EndPopup(ctx)
  end
end

-- Docked, or in the system's frame (no title bar of ours to put them on): to a strip, and to the small square.
function ui.window_buttons(at_row, y0, fh)
  local s = fh - 6
  at_row("  ")
  ImGui.SetCursorPosY(ctx, y0 + 3)
  if ui.window_icon("##tostrip", "line", s, "Minimize to a strip over REAPER. Click it and the panel opens where it was.") then ui.set_minimized("strip") end
  ImGui.SameLine(ctx, 0, 4); ImGui.SetCursorPosY(ctx, y0 + 3)
  if ui.window_icon("##tobox", "box", s, "Shrink to a tiny box over REAPER. Click it and the panel opens where it was.") then ui.set_minimized(true) end
end
-- A page asked for from elsewhere (a new room opens on Rooms; a project just opened, on Home).
function ui.asked_page()
  local want = reaper.GetExtState(band.SECTION, "panel page")
  if want ~= "" then reaper.DeleteExtState(band.SECTION, "panel page", false); page = OLD_PAGES[want] or want end
end
-- The panel goes with the tab in front: a group project opens on Home, anything else on Projects. (A project's own pages stay as you left them
-- when another group project comes to the front.)
function ui.front_changed()
  local now = b and tostring(proj) or ""
  if ui.front == now then return end
  local had = ui.front
  ui.front = now
  if had == nil then return end
  require("page_groups").root = nil
  if not b then page = "Projects"
  elseif had == "" or page == "Groups" or page == "Projects" then page = "Home" end
end
function ui.go_settings(tab)
  page = "Settings"
  reaper.SetExtState(band.SECTION, "setup tab", tab, false)
end
-- Something stopped syncing, said by Autostart (with the panel closed it brings back the tiny box to say so).
function ui.page_body(fn)
  local cards = open_cards
  local ok, e = pcall(fn)
  if ok then return end
  err = tostring(e)
  for _ = cards + 1, open_cards do ImGui.PopTextWrapPos(ctx); ImGui.EndChild(ctx) end
  open_cards = cards
end
function ui.sync_problem()
  local words = reaper.GetExtState(band.SECTION, "sync problem")
  if words == "" then return end
  ImGui.SetCursorPosX(ctx, 16)
  ImGui.TextColored(ctx, RED, words)
end
local function frame_app()
  local ww, wh = ImGui.GetWindowSize(ctx)
  local compact = wh < 440 or ww > wh * 2.4 -- a bottom dock: a row of pages instead of a sidebar
  if reaper.time_precise() - level_at > 2 then level_at, level = reaper.time_precise(), maint_level() end
  -- top bar: one row, every piece the height of a button
  local fh = ImGui.GetFrameHeight(ctx)
  wide = compact and ww > wh * 2
  -- docked at REAPER's left or right (narrow and tall): pages as a row of tabs, one column, never the sidebar
  local dock_id = ImGui.GetWindowDockID(ctx)
  local side = dock_id < 0 and reaper.DockGetPosition(~dock_id) -- (ReaImGui dock id -1 is REAPER's docker 0)
  if side == 1 or side == 3 or ww < 520 then compact, wide = true, false end
  -- (a docker as low as the mixer lets it go, 235 px here: every row above the page gets tight, and what's said in a line of words moves
  -- to a tooltip when it would push out what you press. Taller, the pages have room and rearrange: see page_home)
  ui.short = wide and wh < 320
  if ui.short then ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, 8, 3); fh = ImGui.GetFrameHeight(ctx) end
  local function nav_item(p, w, h)
    local x, y = ImGui.GetCursorScreenPos(ctx)
    if ImGui.Selectable(ctx, (compact and "" or "  ") .. p[1] .. "##nav", p[1] == page, ImGui.SelectableFlags_None, w, h) then page = p[1] end
    local c = nav_dot(p[1])
    ImGui.SetItemTooltip(ctx, p[2] .. (c and (level == "red" and "\n\nSomething needs fixing before the studio can sync: open it to see what."
      or "\n\nSomething is worth a look (or an extra isn't set up): open it to see, or dismiss it there.") or ""))
    if c then
      local iw = ImGui.GetItemRectSize(ctx)
      ImGui.DrawList_AddCircleFilled(ImGui.GetWindowDrawList(ctx), x + iw - 10, y + h / 2, 4.5, c)
    end
    if p[1] == page and not compact then ImGui.DrawList_AddRectFilled(ImGui.GetWindowDrawList(ctx), x - 8, y + 6, x - 4, y + h - 6, ACCENT, 2) end
  end
  local y0 = ImGui.GetCursorPosY(ctx) + (ui.short and -4 or 8)
  ImGui.SetCursorPos(ctx, 16, y0)
  if ui.crumb(view.group or "", 0, 1 / 3, fh, "The studio this project belongs to. Click: all your studios.") then page = "Groups"; require("page_groups").root = nil end
  local function at_row(label) -- next to the last piece, or on a new line when `label`'s piece doesn't fit
    ImGui.SameLine(ctx, 0, 8)
    if label and ImGui.GetContentRegionAvail(ctx) < ImGui.CalcTextSize(ctx, label) + 24 then
      ImGui.SetCursorPos(ctx, 16, y0 + fh + 6)
      y0 = y0 + fh + 6
    else
      ImGui.SetCursorPosY(ctx, y0)
    end
  end
  local key = tostring(proj)
  local beat = tonumber(reaper.GetExtState(band.SECTION, "live " .. key))
  local running = beat and reaper.time_precise() - beat < 5
  at_row(b.song)
  if ui.crumb(b.song, 1 / 3, 2 / 3, fh, "The project in this tab. Click: this studio's projects.") then page = "Projects"; require("page_groups").root = cfg.root end
  at_row(b.room)
  if ui.crumb(b.room, 2 / 3, 1, fh, "The room this tab is in. Click: the Rooms page.") then page = "Rooms" end
  -- what sync is actually doing, not just whether it runs ("Sync on" was green with nothing reaching anyone: review)
  local label, colour, tip = "Sync off", RED, "Live sync is off in this tab."
  if running then
    local online, behind, lines = 0, {}, {}
    for _, r in ipairs(view.rows) do
      local here = r.state ~= "offline" and r.state ~= "no receipt"
      if here then online = online + 1 end
      if here and r.state == "syncing" then behind[#behind + 1] = r.name end
      lines[#lines + 1] = r.name .. ": " .. (not here and "not here (gets your changes when back)" or r.state == "syncing" and "still getting changes" or "has everything")
    end
    if (view.my_pending or 0) > 0 then label, colour = string.format("Receiving %d", view.my_pending), YELLOW
    elseif #behind > 0 then label, colour = "Sending", YELLOW -- (who to: Who's here; names here crowded the bar, James)
    elseif online == 0 then label, colour = "Sync on", GREEN -- (Who's here says nobody else is: James)
    else label, colour = "Synced", GREEN end
    tip = "Live sync is running in this tab: your takes and changes go out, the studio's come in." .. (#lines > 0 and ("\n\n" .. table.concat(lines, "\n")) or "")
  end
  local driver_gone = reaper.GetExtState(band.SECTION, "alone " .. tostring(proj)) ~= "" or reaper.GetExtState(band.SECTION, "driver_away " .. tostring(proj)) ~= "" -- (Mac, 0.58.5: "James drives" beside "you have full control")
  local drives = view.driver == cfg.user and "you drive" or view.driver and (view.driver .. (driver_gone and " drives (away)" or " drives")) or "nobody drives yet"
  ui.status = { label = label, colour = colour, tip = tip, drives = drives }
  at_row(label)
  if ImGui.GetCursorPosX(ctx) > 17 then ImGui.SetCursorPosX(ctx, ImGui.GetCursorPosX(ctx) + 10) end -- (apart from the coloured pills: those say where you are, this how sync is going)
  pill(label, colour, DARK, fh)
  ImGui.SetItemTooltip(ctx, tip)
  if select(2, reaper.GetProjExtState(proj, band.SECTION, "hold")) ~= "" then -- (Hold my changes was invisible once on: review)
    local n = tonumber(reaper.GetExtState(band.SECTION, "held " .. key)) or 0
    local held = n > 0 and string.format("Holding %d change%s", n, n == 1 and "" or "s") or "Holding your changes"
    at_row(held); pill(held, YELLOW, DARK, fh)
    ImGui.SetItemTooltip(ctx, "Hold my changes is on: what you change stays here until you send it.")
    at_row("Send now")
    if ImGui.SmallButton(ctx, "Send now##hold") then reaper.SetProjExtState(proj, band.SECTION, "hold", "") end
    ImGui.SetItemTooltip(ctx, "Switch Hold my changes off: everything you changed goes to the others.")
  end
  do -- two people armed on one track: both record onto it at once (review item 33)
    local mine, both = {}, {}
    for i = 0, reaper.CountTracks(proj) - 1 do
      local tr = reaper.GetTrack(proj, i)
      if reaper.GetMediaTrackInfo_Value(tr, "I_RECARM") == 1 then mine[select(2, reaper.GetTrackName(tr))] = true end
    end
    for _, r in ipairs(view.rows) do
      if r.state ~= "offline" then
        for _, t in ipairs(r.armed or {}) do if mine[t] then both[#both + 1] = r.name .. " (" .. t .. ")" end end
      end
    end
    if #both > 0 then
      local armed = "Armed together: " .. table.concat(both, ", ")
      at_row(armed); pill(armed, YELLOW, DARK, fh)
      ImGui.SetItemTooltip(ctx, "You and they both have this track armed: if you both record, two takes land on it at once.\n" ..
        "Fine for trying parts; otherwise agree who records it, or record onto a track of your own.")
    end
  end
  if not running and rooms.is_copy(proj, cfg, b) then
    at_row("older copy")
    pill("older copy", YELLOW, DARK, fh)
    ImGui.SetItemTooltip(ctx, "A backup or autosave of this song, not your project for it. Nothing goes in or out of it.")
  elseif not running and band.synced_elsewhere(proj) then -- (a second copy of the song: syncing it would work on a stale one)
    at_row("open in another tab")
    pill("open in another tab", YELLOW, DARK, fh)
    ImGui.SetItemTooltip(ctx, "This project is already open and syncing in another tab: work there. This tab is a second copy, not synced.")
  elseif not running then -- (Stop is in Settings: nobody needs it at hand, and it sat next to buttons people do press)
    at_row("Start")
    if ImGui.Button(ctx, "Start") then reaper.DeleteExtState(band.SECTION, "stop " .. key, false); band.start_live(dir) end
  end
  at_row(drives)
  ImGui.SetCursorPosY(ctx, y0 + (fh - ImGui.GetTextLineHeight(ctx)) / 2) -- (not AlignTextToFramePadding: it carries along the row, and the page tabs sat low: design review)
  ImGui.TextDisabled(ctx, drives)
  ImGui.SetItemTooltip(ctx, "The driver's changes go to everyone, except on what someone has claimed.")
  -- (no buttons for these: Ctrl+Z and Ctrl+Shift+Z do it, and Edit > Undo: Live sync steps in. The radial menu still asks for them here.)
  local function undo_redo(redo) -- (lib/undo.lua: the same as the StudioSync - Undo / Redo actions, but always asks)
    local res, why = require("undo").step(proj, cfg, b, redo, { ask = true, describe = describe })
    if res then band.log(res) elseif why then band.msg(why) end
    hist_at = 0
  end
  if wide then -- the pages, in the bar
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_SelectableTextAlign, 0.5, 0.5)
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_ItemSpacing, 8, 0) -- (a selectable grows by the spacing: the highlight stood taller than the pills)
    for i, p in ipairs(ui.pages()) do
      ImGui.SameLine(ctx, 0, i == 1 and 24 or 2)
      -- (they stay put: going by the status beside them, they slid when "In sync" became "Receiving 13", under the mouse)
      if i == 1 then tabs_at = math.max(math.min(tabs_at, ww * 0.4), ImGui.GetCursorPosX(ctx)); ImGui.SetCursorPosX(ctx, tabs_at) end
      ImGui.SetCursorPosY(ctx, y0)
      nav_item(p, ImGui.CalcTextSize(ctx, p[1]) + 28 + (nav_dot(p[1]) and 12 or 0), fh)
    end
    ImGui.PopStyleVar(ctx, 2)
    if wh < y0 + fh + 60 then
      local words = "Too short to show a page: drag the line above the docker's tabs up."
      ImGui.SameLine(ctx, 0, 16)
      ImGui.SetCursorPosY(ctx, y0 + 3)
      if ImGui.GetContentRegionAvail(ctx) <= ImGui.CalcTextSize(ctx, words) + 240 then words = "Too short: drag it up" end -- (pressing a page showed nothing, with no hint: Mac, 0.57.7)
      if ImGui.GetContentRegionAvail(ctx) > ImGui.CalcTextSize(ctx, words) + 240 then ImGui.TextColored(ctx, YELLOW, words) else ImGui.Dummy(ctx, 0, 0) end
    end
  end
  local docked = ImGui.IsWindowDocked(ctx)
  -- the window's own buttons sit at the right end of the bar (when they fit there), apart from the session's
  local bar_min = docked or native -- (no title bar of ours to put it on: else it sits by the close button)
  local labels = docked and { "Sync and exit", "Undock" } or { "Sync and exit", "Window" }
  local need = bar_min and 2 * (fh - 6) + 28 or 0 -- (the two window icons: as a word's width, the second fell off the right edge)
  for _, l in ipairs(labels) do need = need + ImGui.CalcTextSize(ctx, l) + 28 end
  ImGui.SameLine(ctx, 0, 8)
  local room = ImGui.GetContentRegionAvail(ctx)
  local toast_place
  if ww >= 520 and room - need > 160 then -- (the bar has room: a blank line under it cost a short docker 30 px for something shown 6 s at a time)
    local tx = ImGui.GetCursorScreenPos(ctx)
    local _, ty = ImGui.GetWindowPos(ctx)
    toast_place = { x = tx + 8, y = ty + y0 + (fh - ImGui.GetTextLineHeight(ctx)) / 2, w = room - need - 16 }
  elseif ui.short then -- (no room in the bar, and no blank row to spare: over the top of the page while it's being said)
    toast_place = { x = ImGui.GetWindowPos(ctx) + 16, w = ww - 32, over = true }
  end
  if ww < 520 then -- (narrow, "Window" wrapped alone onto a row of its own: design review)
    at_row("...")
    if ImGui.Button(ctx, "...##window") then
      local pick = band.pick({ "Sync and exit", docked and "Undock" or "Window..." })
      if pick == "Sync and exit" then require("leave").start(proj, cfg, b)
      elseif pick == "Undock" then dock_req = 0
      elseif pick then ui.window_menu() end
    end
    ImGui.SetItemTooltip(ctx, "Sync and exit, and where the panel sits.")
  else
    if room > need + 12 then ImGui.SetCursorPosX(ctx, ImGui.GetCursorPosX(ctx) + room - need); ImGui.SetCursorPosY(ctx, y0)
    else at_row("Sync and exit") end
    if ImGui.Button(ctx, "Sync and exit") then require("leave").start(proj, cfg, b) end
    ImGui.SetItemTooltip(ctx, "Leaving? Saves, gets everything you've done out to the others, says who has it, then lets you close the project or quit REAPER.")
    at_row(docked and "Undock" or "Window")
    if docked then tools.dock_menu(true) else ui.window_button() end
  end
  if bar_min then ui.window_buttons(at_row, y0, fh) end
  ImGui.SetCursorPos(ctx, 16, y0 + fh + (ui.short and 5 or 8))
  -- narrow: the pages first, so a row arriving under them can't slide them from under the mouse (design review)
  if compact and not wide then
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_SelectableTextAlign, 0.5, 0.5)
    for i, p in ipairs(ui.pages()) do
      local w = ImGui.CalcTextSize(ctx, p[1]) + 28 + (nav_dot(p[1]) and 12 or 0)
      if i > 1 then
        ImGui.SameLine(ctx, 0, 2)
        if ImGui.GetContentRegionAvail(ctx) < w then ImGui.NewLine(ctx); ImGui.SetCursorPosX(ctx, 16) end -- (a narrow panel lost Plugins and Setup off the right)
      end
      nav_item(p, w, fh)
    end
    ImGui.PopStyleVar(ctx)
    ImGui.SetCursorPosX(ctx, 16)
  end
  -- what StudioSync just did, under the bar for a few seconds (actions used to report only to the Console)
  local log = band.activity()
  local newest = log[1]
  if newest ~= tools.toast_newest then
    local before = tools.toast_newest
    tools.toast_newest = newest
    -- (a routine count doesn't push out what's being said: a first comp's warning lasted an instant, Mac 0.42.27. Both can arrive
    -- between two frames, the count on top, so this looks through all that's new: Mac, 0.45.0)
    local routine = function(l) return l:find("change(s) went to the others", 1, true) end
    local say = newest
    for _, l in ipairs(log) do
      if l == before then break end
      if not routine(l) then say = l; break end
    end
    local saying = tools.toast_at and reaper.time_precise() - tools.toast_at < 6
    local kept = band.json_decode(reaper.GetExtState(band.SECTION, "put back"))
    local in_bar = kept and kept.text and say and say:find(kept.text, 1, true) -- (the bar says it and stays: Mac, 0.57.6)
    if not in_bar and not (saying and say and routine(say)) then
      tools.toast_line, tools.toast_at = say, tools.toast_seen and reaper.time_precise() or -math.huge
    end
  end
  tools.toast_seen = true -- (opening the panel doesn't replay the old newest line)
  local saying = tools.toast_line and reaper.time_precise() - tools.toast_at < 6 and tools.toast_line or nil
  if toast_place and toast_place.over then
    local tx, ty = toast_place.x, select(2, ImGui.GetWindowPos(ctx)) + y0 + fh + 8
    toast_place.y = ty
    if saying then ImGui.DrawList_AddRectFilled(ImGui.GetForegroundDrawList(ctx), tx - 6, ty - 3, tx + toast_place.w + 6, ty + ImGui.GetTextLineHeight(ctx) + 5, theme.BG, 4) end
  end
  tools.toast_show(ctx, ImGui, saying, toast_place)
  local bars_at = ImGui.GetCursorPosY(ctx)
  ImGui.SetNextWindowSizeConstraints(ctx, 0, 0, 100000, (wide or wh < 440) and (ImGui.GetFrameHeightWithSpacing(ctx) * 2 + 2) or wh * 0.25)
  local bars_open = ImGui.BeginChild(ctx, "bars", 0, 0, ImGui.ChildFlags_AutoResizeY)
  if bars_open then ImGui.Indent(ctx, 16) end
  tools.removed_bar(ctx, ImGui)
  ui.sync_problem()
  require("leave").draw(ctx, ImGui)
  section_invites()
  tools.join_requests(ctx, ImGui) -- (someone asking to join the band folder)
  if b and can then -- (an edit touching a claim, before the rest: lib/suggest.lua)
    require("suggest").bar(ctx, ImGui, proj, cfg, sync.room_dir(cfg, b.song, b.room), can, select(2, reaper.GetProjExtState(proj, band.SECTION, "local_mix")) == "1")
  end
  for p in pairs(just_looked) do if not reaper.ValidatePtr(p, "ReaProject*") then just_looked[p] = nil end end
  if b and rooms.is_copy(proj, cfg, b) and not band.live_here(proj) then -- (lib/rooms.lua: a backup or autosave, opened by hand)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, YELLOW)
    ImGui.TextWrapped(ctx, "This is a backup or autosave of '" .. b.song .. "', not your project for it. Nothing goes in or out of it.")
    ImGui.PopStyleColor(ctx)
    if just_looked[proj] ~= tostring(reaper.GetTrack(proj, 0)) then
      if ImGui.SmallButton(ctx, "Open as a side room") then
        local p, what = rooms.from_backup(proj, cfg, b)
        if not p then band.msg(what) else
          band.log("this backup is now the side room '" .. what .. "': Bring into main offers what nobody has, Send selected anything else")
          if not live_running(p) then band.start_live(dir) end
          reaper.SetExtState(band.SECTION, "panel page", "Rooms", false)
          room_at, merge = -math.huge, nil
          local copy = proj
          reaper.defer(function() -- (its own tab goes: two of a room's tabs, and rooms.tab can't tell which is which)
            if reaper.ValidatePtr(copy, "ReaProject*") and reaper.IsProjectDirty(copy) == 0 then
              local front = reaper.EnumProjects(-1)
              reaper.SelectProjectInstance(copy)
              reaper.Main_OnCommand(40860, 0)
              if front ~= copy then reaper.SelectProjectInstance(front) end
            end
          end)
        end
      end
      ImGui.SetItemTooltip(ctx, "A side room with this copy in it, yours to drive. Nobody else's project changes. From there, Bring into main offers what nobody has, and Send selected sends anything you pick.")
      ImGui.SameLine(ctx)
      if ImGui.SmallButton(ctx, "Just look") then just_looked[proj] = tostring(reaper.GetTrack(proj, 0)) end
      ImGui.SetItemTooltip(ctx, "Leave it as it is, for looking or for copying things out of by hand.")
    elseif (rooms.file_of(proj) or "") == "" then
      ImGui.TextDisabled(ctx, "If this really is your project, save it under a name first: File > Save project as.")
    else
      if ImGui.SmallButton(ctx, "Make this my project") and reaper.MB("Sync this copy as your project for '" .. b.song .. "'?\n\n" ..
          "What the studio has changed since comes in over it, and any edits in it on your own tracks go to everyone.", "StudioSync", 4) == 6 then
        band.start_live(dir)
      end
      ImGui.SetItemTooltip(ctx, "For when this really is your project (the folder moved, say). Otherwise use a side room.")
    end
  end
  tools.put_back_bar(ctx, ImGui, b and b.song, b and can and function(mine) -- (an edit of yours that was undone, and why: stays until dismissed)
    band.log(tostring(require("mirror").use_mine(proj, cfg, b.song, b.room, mine, { can = can, mode = who and who.mode,
      local_mix = select(2, reaper.GetProjExtState(proj, band.SECTION, "local_mix")) == "1" })))
  end, function(name) return can(cfg.user, name) end)
  if bars_open then ImGui.Unindent(ctx, 16); ImGui.EndChild(ctx) end
  local _, bars_h = ImGui.GetItemRectSize(ctx)
  if bars_h < 6 then ImGui.SetCursorPosY(ctx, bars_at) end -- (nothing in them: no gap. An empty child is still 4 px tall, and 8 more of spacing)
  ui.asked_page()
  local want
  want = reaper.GetExtState(band.SECTION, "panel do") -- a choice from the radial menu
  if want ~= "" then
    reaper.DeleteExtState(band.SECTION, "panel do", false)
    if want == "undo" or want == "redo" then undo_redo(want == "redo")
    elseif want == "realtime" then set_same_room(not same_room_on())
    elseif want == "chat" then page = "Chat"
    elseif want:match("^history") then page = "Restore" end
  end
  if ui.short then ImGui.PushStyleVar(ctx, ImGui.StyleVar_ItemSpacing, 8, 3) end
  ImGui.Separator(ctx)
  if ui.short then ImGui.PopStyleVar(ctx, 2) end -- (and the frame padding from the top of the bar)
  if not compact then
    ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, NAV)
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, 8, 10)
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_SelectableTextAlign, 0, 0.5)
    if ImGui.BeginChild(ctx, "nav", 150, 0, ImGui.ChildFlags_AlwaysUseWindowPadding) then
      ImGui.PushFont(ctx, nil, 16)
      for _, p in ipairs(ui.pages()) do nav_item(p, 0, 36) end
      ImGui.PopFont(ctx)
      ImGui.EndChild(ctx)
    end
    ImGui.PopStyleVar(ctx, 2)
    ImGui.PopStyleColor(ctx)
    ImGui.SameLine(ctx, 0, 0)
  end
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, 16, ui.short and 4 or 12)
  -- (rows coming or going above it move the page under the mouse: its buttons wait a moment too, or a Remove or Restore could take a click aimed elsewhere)
  local settling = require("suggest").settling()
  ImGui.BeginDisabled(ctx, settling)
  if wide then -- (two full-size buttons filled a short column: design review)
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, 8, ui.short and 3 or 4)
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_ItemSpacing, 8, 5)
  end
  local was_wide = wide
  if ImGui.BeginChild(ctx, "page", 0, 0, ImGui.ChildFlags_AlwaysUseWindowPadding, wide and ImGui.WindowFlags_HorizontalScrollbar or 0) then
    ImGui.PushTextWrapPos(ctx, 0) -- text wraps to the page, whatever its width
    if page == "Play/Jam" and not ui.play_shown() then page = "Home" end
    if page == "Groups" then ui.page_body(function() require("page_groups").draw_groups(ui.env) end)
    elseif page == "Projects" then ui.page_body(function() require("page_groups").draw_projects(ui.env) end)
    elseif page == "Home" then page_home()
    elseif page == "Rooms" then
      refresh_rooms()
      if ui.short and not (room_view.meta and room_view.meta.parent) then layout({ { rooms_squares, 900 } })
      else layout({ { rooms_squares, 900 }, { rooms_actions, 300 } }) end
    elseif page == "Play/Jam" then
      if wide then layout({ { section_together, 380 }, { function() section_live("mode") end, 420 }, { function() section_live("rest") end, 520 } })
      else layout({ { section_together, 380 }, { section_live, 480 } }) end
    elseif page == "Chat" then
      layout({ { function() require("page_chat").draw(ctx, ImGui, cfg, b) end, 560 }, { function() section_notes(); section_ideas() end, 420 } })
    elseif page == "Restore" then layout({ { section_recall, 400 }, { section_history, 600 } })
    elseif page == "Plugins" then
      layout({ { function() require("page_plugins").draw(ctx, ImGui, proj, cfg) end, 760 }, { function() require("page_plugins").drums(ctx, ImGui, proj, cfg) end, 420 }, { section_plugins, 420 } })
    elseif page == "Settings" then page_setup() end
    ImGui.PopTextWrapPos(ctx)
    ImGui.EndChild(ctx)
  end
  if was_wide then ImGui.PopStyleVar(ctx, 2) end
  ImGui.EndDisabled(ctx)
  ImGui.PopStyleVar(ctx)
end

local start_songs -- (the start screen's song list, read every few seconds)
-- With no group project in front: your groups, a group's projects, and settings.
function ui.frame_lobby()
  ui.status = nil
  ui.asked_page()
  local pg = require("page_groups")
  local none = #pg.live_groups() == 0
  if none and page ~= "Settings" then page = "Groups"
  elseif not LOBBY[page] then page = "Projects" end
  local fh = ImGui.GetFrameHeight(ctx)
  wide, ui.short = false, false
  local y0 = ImGui.GetCursorPosY(ctx) + 8
  ImGui.SetCursorPos(ctx, 16, y0)
  local root = pg.root or cfg.root
  if not none and not require("groups").is_old(root) then
    if ui.crumb(band.info(root).name, 0, 1, fh, "The studio you're working in. Click: all your studios.") then page = "Groups" end
    ImGui.SameLine(ctx, 0, 12)
    ImGui.SetCursorPosY(ctx, y0)
  end
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_SelectableTextAlign, 0.5, 0.5)
  for i, p in ipairs(ui.pages()) do
    if p[1] ~= "Groups" and not (none and p[1] == "Projects") then
      if i > 1 then ImGui.SameLine(ctx, 0, 2) end
      ImGui.SetCursorPosY(ctx, y0)
      if ImGui.Selectable(ctx, p[1] .. "##nav", p[1] == page, ImGui.SelectableFlags_None, ImGui.CalcTextSize(ctx, p[1]) + 28, fh) then page = p[1] end
      ImGui.SetItemTooltip(ctx, p[2])
    end
  end
  ImGui.PopStyleVar(ctx)
  ImGui.SameLine(ctx, 0, 8)
  ImGui.SetCursorPosY(ctx, y0)
  local docked = ImGui.IsWindowDocked(ctx)
  local room = ImGui.GetContentRegionAvail(ctx)
  local need = ImGui.CalcTextSize(ctx, docked and "Undock" or "Window") + 28 + ((docked or native) and 60 or 0)
  if room > need then ImGui.SetCursorPosX(ctx, ImGui.GetCursorPosX(ctx) + room - need); ImGui.SetCursorPosY(ctx, y0)
  else ImGui.SetCursorPos(ctx, 16, y0 + fh + 6); y0 = y0 + fh + 6 end
  if docked then tools.dock_menu(true) else ui.window_button() end
  local function at_row() ImGui.SameLine(ctx, 0, 8); ImGui.SetCursorPosY(ctx, y0) end
  if docked or native then ui.window_buttons(at_row, y0, fh) end
  ImGui.SetCursorPos(ctx, 16, y0 + fh + 8)
  local log = band.activity()
  if log[1] ~= tools.toast_newest then tools.toast_line, tools.toast_at = tools.toast_seen and log[1] or nil, reaper.time_precise(); tools.toast_newest = log[1] end
  tools.toast_seen = true
  tools.toast_show(ctx, ImGui, tools.toast_line and reaper.time_precise() - (tools.toast_at or 0) < 6 and tools.toast_line or nil)
  tools.removed_bar(ctx, ImGui)
  ui.sync_problem()
  tools.join_requests(ctx, ImGui)
  ImGui.Separator(ctx)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, 16, 12)
  if ImGui.BeginChild(ctx, "page", 0, 0, ImGui.ChildFlags_AlwaysUseWindowPadding) then
    ImGui.PushTextWrapPos(ctx, 0)
    if page == "Groups" then ui.page_body(function() pg.draw_groups(ui.env) end)
    elseif page == "Projects" then ui.page_body(function() pg.draw_projects(ui.env) end)
    else page_setup() end
    ImGui.PopTextWrapPos(ctx)
    ImGui.EndChild(ctx)
  end
  ImGui.PopStyleVar(ctx)
end
ui.env = { ctx = ctx, ImGui = ImGui, card = card, card_end = card_end, heading = heading, action = action,
  cfg = function() return cfg end, wide = function() return wide end, go = function(p) page = p end, project = function() return b and b.song end,
  reload_cfg = function() cfg = band.settings(); start_songs = nil; drive_at = -math.huge; last = 0 end }
local function frame()
  if b and cfg then recall.warm(cfg, b.song, b.room, 0.004) end
  if reaper.time_precise() - last > 1.5 or reaper.EnumProjects(-1) ~= proj then
    last = reaper.time_precise()
    local ok, e = pcall(refresh)
    err = not ok and tostring(e) or nil
  end
  ui.front_changed()
  ImGui.SetCursorPosY(ctx, ImGui.GetCursorPosY(ctx) + 10); ImGui.Indent(ctx, 16) -- (the window has no padding of its own)
  if err then
    ImGui.TextColored(ctx, RED, "Something went wrong in the panel: " .. err)
    if ImGui.SmallButton(ctx, "Copy it") then ImGui.SetClipboardText(ctx, "StudioSync " .. band.VERSION .. ": " .. err) end
    ImGui.SetItemTooltip(ctx, "Copy the message, to send it to whoever looks after StudioSync.")
    ImGui.SameLine(ctx)
    if ImGui.SmallButton(ctx, "Try again") then err, last = nil, 0 end
    return
  end
  ImGui.Unindent(ctx, 16)
  if not b then return ui.frame_lobby() end
  return frame_app()
end

-- A running script keeps the code it started with, so after an update this panel showed none of the new buttons
-- until someone closed and reopened it (Mac, 2026-10-28). Once the installed version has changed (and held for two
-- looks, so a half-finished update isn't loaded), it loads the new code in place: same window, new panel.
local seen_disk, disk_at = nil, 0
local function updated()
  if reaper.time_precise() - disk_at < 3 then return false end
  disk_at = reaper.time_precise()
  local disk = (band.read(dir .. "/lib/band.lua") or ""):match('VERSION = "([^"]+)"')
  local ready = disk and disk ~= band.VERSION and disk == seen_disk
  seen_disk = disk
  return ready
end

-- While someone else drives and is here, a slim banner at the foot of REAPER's arrange view says what you can change.
-- It takes no clicks (no inputs, no focus). Placed in ReaImGui's units from the screen's pixels of REAPER's main
-- window and its arrange view. Settings can turn it off (ExtState banner = "off").
local function banner()
  if not banner_text or reaper.GetExtState(band.SECTION, "banner") == "off" or not reaper.JS_Window_FindChildByID then return end
  local main = reaper.GetMainHwnd()
  local arrange = reaper.JS_Window_FindChildByID(main, 1000)
  if not arrange then return end
  local _, ml, mt, mr, mb = reaper.JS_Window_GetRect(main)
  local _, al, at, ar, ab = reaper.JS_Window_GetRect(arrange)
  local vp = ImGui.GetMainViewport(ctx)
  local vx, vy = ImGui.Viewport_GetPos(vp)
  local vw, vh = ImGui.Viewport_GetSize(vp)
  if mr - ml <= 0 or vw <= 0 then return end
  local sx, sy = (mr - ml) / vw, (mb - mt) / vh
  local cx, by = vx + ((al + ar) / 2 - ml) / sx, vy + (ab - mt) / sy
  -- the panel floating over that spot (the banner was drawn on top of it): no banner then, the panel says it all
  if win_rect and not banner_docked and cx > win_rect[1] - 200 and cx < win_rect[1] + win_rect[3] + 200
      and by > win_rect[2] and by - 70 < win_rect[2] + win_rect[4] then return end
  -- (40 up: lower, it sat on the bottom docker's splitter and caught the drag meant for it)
  ImGui.SetNextWindowPos(ctx, cx, by - 40, ImGui.Cond_Always, 0.5, 1)
  ImGui.SetNextWindowBgAlpha(ctx, 0.88)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowRounding, 8)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, 12, 6)
  ImGui.PushStyleColor(ctx, ImGui.Col_WindowBg, theme.BANNER)
  local f = ImGui.WindowFlags_NoDecoration | ImGui.WindowFlags_NoInputs | ImGui.WindowFlags_NoFocusOnAppearing | ImGui.WindowFlags_NoNav |
    ImGui.WindowFlags_NoDocking | ImGui.WindowFlags_AlwaysAutoResize | ImGui.WindowFlags_NoSavedSettings
  if ImGui.Begin(ctx, "StudioSync banner", nil, f) then
    ImGui.TextColored(ctx, YELLOW, banner_text)
    ImGui.End(ctx)
  end
  ImGui.PopStyleColor(ctx)
  ImGui.PopStyleVar(ctx, 2)
end

-- Minimized: a tiny box over REAPER, its edge saying whether sync runs and a count for what's waiting (the words are its tooltip), or a strip with
-- the words on it; from the title bar's two buttons (its X really closes); a click brings the panel back where it was (floating or docked). Dragged, it stays
-- where it's dropped, pinned to REAPER's window so it goes along when REAPER moves. Right-click to lock it there, close the panel or remove it.
-- shortcut: it's kept inside REAPER's window: past it, a screen unplugged (or a virtual one gone) could lose the button for good.
-- Returns false when the panel should close.
local function pill_window()
  local front = reaper.EnumProjects(-1)
  local fb = band.binding(front)
  local beat = tonumber(reaper.GetExtState(band.SECTION, "live " .. tostring(front)))
  local live_on = beat and reaper.time_precise() - beat < 5
  local unread = fb and require("page_chat").unread(cfg, fb) or 0
  local strip = reaper.GetExtState(band.SECTION, "panel minimized") == "strip"
  local S = tonumber(reaper.GetExtState(band.SECTION, "pill size")) or 28
  local vx, vy = ImGui.Viewport_GetWorkPos(ImGui.GetMainViewport(ctx))
  local vw, vh = ImGui.Viewport_GetWorkSize(ImGui.GetMainViewport(ctx))
  local locked = reaper.GetExtState(band.SECTION, "pill lock") ~= ""
  local mx, my = ImGui.GetMousePos(ctx)
  -- (each has its own place: James keeps them in different spots)
  local kx, ky = strip and "strip dx" or "pill dx", strip and "strip dy" or "pill dy"
  local W = strip and (ui.strip_w or 320) or S
  local px, py = vx + (tonumber(reaper.GetExtState(band.SECTION, kx)) or (vw - W - 24)), vy + (tonumber(reaper.GetExtState(band.SECTION, ky)) or 64)
  if ui.pill_drag and ui.pill_drag.moved then px, py = ui.pill_drag.x + mx - ui.pill_drag.mx, ui.pill_drag.y + my - ui.pill_drag.my
  else px, py = math.max(vx, math.min(px, vx + vw - W)), math.max(vy, math.min(py, vy + vh - S)) end
  ImGui.SetNextWindowPos(ctx, px, py)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowRounding, strip and 14 or S / 4)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, strip and 8 or 0, strip and 4 or 0)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowBorderSize, 0)
  local keep = true
  local f = ImGui.WindowFlags_NoDecoration | ImGui.WindowFlags_AlwaysAutoResize | ImGui.WindowFlags_NoDocking | ImGui.WindowFlags_NoMove |
    ImGui.WindowFlags_NoSavedSettings | ImGui.WindowFlags_NoFocusOnAppearing | ImGui.WindowFlags_NoNav
  if ImGui.Begin(ctx, "StudioSync pill", nil, f) then
    local x, y = ImGui.GetCursorScreenPos(ctx)
    if strip then ui.strip_w = ImGui.GetWindowSize(ctx) end
    local problem = reaper.GetExtState(band.SECTION, "sync problem")
    if problem ~= "" then live_on = false end
    local words = "StudioSync  ·  " .. (problem ~= "" and problem or live_on and (ui.status and ui.status.label or "Sync on") or "Sync off") .. (view and view.driver and ("  ·  " .. (view.driver == cfg.user and "you drive" or (view.driver .. " drives"))) or "") ..
      (unread > 0 and string.format("  ·  %d new message%s", unread, unread == 1 and "" or "s") or "")
    local waiting = unread
    local pb = band.json_decode(reaper.GetExtState(band.SECTION, "put back"))
    if pb and pb.text then
      words = words .. string.format("  ·  %d edit%s undone", pb.n or 1, (pb.n or 1) == 1 and "" or "s")
      waiting = waiting + (pb.n or 1)
    end
    if b then
      local asks = #require("suggest").rows(sync.room_dir(cfg, b.song, b.room), cfg.user)
      if asks > 0 then words = words .. string.format("  ·  %d suggestion%s", asks, asks == 1 and "" or "s") end
      waiting = waiting + asks
    end
    local clicked
    if strip then
      logo(18)
      ImGui.SameLine(ctx, 0, 6)
      dot(live_on and GREEN or RED)
      ImGui.SameLine(ctx, 0, 6)
      clicked = ImGui.SmallButton(ctx, words .. "##pill")
    else clicked = ImGui.InvisibleButton(ctx, "##pill", S, S) end
    local hovered = ImGui.IsItemHovered(ctx)
    -- (anywhere on it, its edges too: only the button in its middle did, and an edge is where a hand goes first)
    -- (the flag: pressed, the button is the active item, and a plain IsWindowHovered says no, so it never moved: Mac, 0.45.0)
    if ImGui.IsWindowHovered(ctx, ImGui.HoveredFlags_AllowWhenBlockedByActiveItem) and ImGui.IsMouseClicked(ctx, 0) and not locked and not ui.pill_drag then ui.pill_drag = { mx = mx, my = my, x = px, y = py } end
    local dragged = false
    if ui.pill_drag then
      -- (a few pixels are a click with an unsteady hand, not a move)
      ui.pill_drag.moved = ui.pill_drag.moved or math.abs(mx - ui.pill_drag.mx) + math.abs(my - ui.pill_drag.my) > 4
      dragged = ui.pill_drag.moved
      if not ImGui.IsMouseDown(ctx, 0) then
        if dragged then
          reaper.SetExtState(band.SECTION, kx, tostring(px - vx), true); reaper.SetExtState(band.SECTION, ky, tostring(py - vy), true)
        end
        ui.pill_drag = nil
      end
    end
    if clicked and not dragged then ui.set_minimized(false) end
    local how = locked and "Click: open the panel. Locked where it is (right-click to unlock)." or "Click: open the panel. Drag: move it, and it stays there. Right-click: lock it, and more."
    ImGui.SetItemTooltip(ctx, words .. (pb and pb.text and ("\nUndone: " .. pb.text) or "") .. "\n" .. how)
    if ImGui.BeginPopupContextItem(ctx, "pillmenu") then
      if ImGui.Selectable(ctx, "Open the panel") then ui.set_minimized(false) end
      if ImGui.Selectable(ctx, "Lock position", locked) then reaper.SetExtState(band.SECTION, "pill lock", locked and "" or "1", true) end
      if ImGui.Selectable(ctx, strip and "Make it a tiny box" or "Make it a strip") then ui.set_minimized(strip and true or "strip") end
      if not strip and ImGui.BeginMenu(ctx, "Size") then
        for _, sz in ipairs({ { "Small", 22 }, { "Medium", 28 }, { "Large", 40 }, { "Big", 56 } }) do
          if ImGui.MenuItem(ctx, sz[1], nil, S == sz[2]) then reaper.SetExtState(band.SECTION, "pill size", tostring(sz[2]), true) end
        end
        ImGui.EndMenu(ctx)
      end
      if fb and ImGui.Selectable(ctx, "Sync and exit...") then ui.set_minimized(false); require("leave").start(front, band.for_tab(cfg, fb), fb) end
      if ImGui.Selectable(ctx, "Close the panel") then ui.set_minimized(false); keep = false end
      ImGui.EndPopup(ctx)
    end
    local dl = ImGui.GetWindowDrawList(ctx)
    if not strip then
    local L = S * 0.76
    if hovered then ImGui.DrawList_AddRectFilled(dl, x, y, x + S, y + S, theme.BUTTON, S / 4) end
    ImGui.SetCursorScreenPos(ctx, x + (S - L * 0.93) / 2, y + (S - L) / 2)
    logo(L)
    ImGui.DrawList_AddRect(dl, x + 1, y + 1, x + S - 1, y + S - 1, live_on and GREEN or RED, S / 4, 0, 2)
    end
    if not strip and waiting > 0 then -- what's waiting, in the corner
      local n = waiting > 99 and "99" or tostring(waiting)
      local tw, th = ImGui.CalcTextSize(ctx, n)
      local cx, cy, r = x + S - 9, y + 9, math.max(tw, th) / 2 + 2
      ImGui.DrawList_AddCircleFilled(dl, cx, cy, r, RED)
      ImGui.DrawList_AddText(dl, cx - tw / 2, cy - th / 2, 0xFFFFFFFF, n)
    end
    ImGui.End(ctx)
  end
  ImGui.PopStyleVar(ctx, 3)
  return keep
end

local function loop()
  if updated() or reload_now then -- reload in place: relaunching itself as an action is ignored (or asks to terminate instances)
    band.log("the panel reloaded for StudioSync " .. tostring(seen_disk))
    restarting = true
    for _, f in ipairs(band.files(dir .. "/lib", ".lua")) do package.loaded[f:sub(1, -5)] = nil end
    return dofile(dir .. "/StudioSync - Panel.lua")
  end
  ImGui.SetNextWindowSize(ctx, 560, 640, ImGui.Cond_FirstUseEver)
  local wx, wy = ImGui.Viewport_GetWorkPos(ImGui.GetMainViewport(ctx)) -- first time: inside REAPER, below its menus
  ImGui.SetNextWindowPos(ctx, wx + 60, wy + 90, ImGui.Cond_FirstUseEver)
  -- no collapse arrow: collapsed and opened again, the window came back tiny on macOS (dock it, or close it instead)
  push_theme(); ImGui.PushFont(ctx, ui_font, 15)
  -- (the app's pages scroll inside; the window itself never does, so the top bar stays put)
  local flags = ImGui.WindowFlags_NoCollapse | ImGui.WindowFlags_NoScrollbar | ImGui.WindowFlags_NoScrollWithMouse
    | (native and ImGui.WindowFlags_NoTitleBar or 0) -- (the system frame has the title; docked, REAPER's tab does)
  if dock_req then ImGui.SetNextWindowDockID(ctx, dock_req); dock_req = nil end
  ImGui.SetConfigVar(ctx, ImGui.ConfigVar_DockingWithShift, reaper.GetExtState(band.SECTION, "dock armed") ~= "" and 0 or 1)
  if reaper.GetExtState(band.SECTION, "panel clipped") == "?" or ui.clipped then -- (the test reads it back, then clears it to stop)
    if ui.clipped and reaper.GetExtState(band.SECTION, "panel clipped") == "" then ui.clipped = nil
    else
      if ui.clipped then reaper.SetExtState(band.SECTION, "panel clipped", band.json_encode(ui.clipped), false) end
      ui.clipped = {}
    end
  end
  local ask = reaper.GetExtState(band.SECTION, "panel place") -- (the Window menu, asked for from a script)
  if ask ~= "" then reaper.DeleteExtState(band.SECTION, "panel place", false); place_window(ask) end
  if place_req then
    ImGui.SetNextWindowPos(ctx, place_req[1], place_req[2])
    ImGui.SetNextWindowSize(ctx, place_req[3], place_req[4])
    place_req = nil
  end
  local minimized = reaper.GetExtState(band.SECTION, "panel minimized") ~= ""
  local visible, open = false, true
  if minimized then open = pill_window()
  else
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowTitleAlign, 0.5, 0.5) -- (the logo has the left corner)
    ImGui.PushStyleColor(ctx, ImGui.Col_Button, 0) -- (the little triangle in a docked window's corner is drawn in this colour as it begins)
    visible, open = ImGui.Begin(ctx, "StudioSync###StudioSync", true, flags)
    ImGui.PopStyleColor(ctx)
    ImGui.PopStyleVar(ctx)
  end
  if visible then
    local wx, wy = ImGui.GetWindowPos(ctx)
    local ww, wh = ImGui.GetWindowSize(ctx)
    local was_docked = win_rect and win_rect.docked
    win_rect = { wx, wy, ww, wh, docked = ImGui.IsWindowDocked(ctx) }
    banner_docked = win_rect.docked
    if was_docked and not banner_docked then -- out of a docker: back to the usual size, not the docker's long thin shape
      local vx, vy = ImGui.Viewport_GetWorkPos(ImGui.GetMainViewport(ctx))
      place_req = { vx + 60, vy + 90, 560, 640 }
    end
    if dock_side then
      -- the action moves whichever docker has the focus, so only once this window is really in its new one, and has the focus:
      -- on the first docked frame it isn't yet, and it moved the Mixer's docker instead
      -- (ReaImGui's own word for where it is: on a Mac the window JS_Window_Find hands back isn't always one DockIsChildOfDock
      -- takes, and that threw: Mac, 0.42.27)
      local me = ImGui.GetWindowDockID(ctx) == ~dock_side.docker and reaper.JS_Window_Find and reaper.JS_Window_Find("StudioSync", true)
      if me then
        pcall(reaper.JS_Window_SetFocus, me)
        -- (no asking whether the focus took: on a Mac it never reads as ours, and this ended with nothing said. move_docker looks afterwards
        -- and puts back whatever else moved: Mac, 0.45.0)
        local where = dock_side.action == 41599 and "left" or "right"
        if require("tools").move_docker(dock_side.docker, where == "left" and 1 or 3) then
          band.msg("StudioSync is docked at the " .. where .. " of REAPER.\n\nREAPER opens a new docker there very narrow, " ..
            "and a script can't widen it: drag its inner edge across. REAPER remembers the width after that.")
        else
          band.msg("REAPER wouldn't move StudioSync's docker to the " .. where .. ", so the panel is at the bottom and everything else is where it was.\n\n" ..
            "To try by hand: right-click the 'StudioSync' tab at the foot of the docker, and look for the docker's position there.")
        end
        dock_side = nil
      elseif reaper.time_precise() - dock_side.since > 3 then
        dock_side = nil
        band.log("the panel didn't settle into its new docker, so it stays where it is")
      end
    end
    open_cards = 0
    local ok, e = pcall(frame) -- an error in our logic must still reach End
    if not ok then -- (and End must find no card open: 0.33.2's broken lib file failed inside one, and End killed the panel)
      err = tostring(e)
      reaper.ShowConsoleMsg("StudioSync panel: " .. err .. "\n") -- (a failure inside a plain child ends the panel with ImGui's complaint instead of this)
      for _ = 1, open_cards do ImGui.PopTextWrapPos(ctx); ImGui.EndChild(ctx) end
      open_cards = 0
    end
    -- a focused panel keeps the keys from REAPER, so Ctrl+Z did nothing after a click here. (Cmd on a Mac. Not while typing: a text box has its own undo)
    if ImGui.IsWindowFocused(ctx, ImGui.FocusedFlags_RootAndChildWindows) and not ImGui.IsAnyItemActive(ctx)
      and ImGui.IsKeyDown(ctx, ImGui.Mod_Ctrl) and ImGui.IsKeyPressed(ctx, ImGui.Key_Z, false) then
      action(ImGui.IsKeyDown(ctx, ImGui.Mod_Shift) and "Redo" or "Undo")
    end
    if banner_docked then reaper.DeleteExtState(band.SECTION, "dock armed", false) -- docked: drag-to-dock did its job
    elseif not native then
      -- the top corners resize too (Dear ImGui only has grips at the bottom); the grips sit over the frame's corners
      ImGui.PushClipRect(ctx, wx, wy, wx + ww, wy + wh, false)
      for k, x in ipairs({ wx, wx + ww - 12 }) do
        ImGui.SetCursorScreenPos(ctx, x, wy)
        ImGui.InvisibleButton(ctx, "##grip" .. k, 12, 12)
        if ImGui.IsItemHovered(ctx) or ImGui.IsItemActive(ctx) then
          ImGui.SetMouseCursor(ctx, k == 1 and ImGui.MouseCursor_ResizeNWSE or ImGui.MouseCursor_ResizeNESW)
        end
        if ImGui.IsItemActive(ctx) then
          local dx, dy = ImGui.GetMouseDragDelta(ctx, 0)
          ImGui.ResetMouseDragDelta(ctx, 0)
          if dx ~= 0 or dy ~= 0 then
            place_req = k == 1 and { wx + dx, wy + dy, math.max(300, ww - dx), math.max(200, wh - dy) }
              or { wx, wy + dy, math.max(300, ww + dx), math.max(200, wh - dy) }
          end
        end
      end
      do -- the logo in the corner; beside the close button (which closes), minimize to a strip and the tiny box
        local s, pad = ImGui.GetFontSize(ctx), ImGui.GetStyleVar(ctx, ImGui.StyleVar_FramePadding)
        local tbh = ImGui.GetFrameHeight(ctx)
        if not ImGui.GetWindowDockID or ImGui.GetWindowDockID(ctx) == 0 then
          ImGui.SetCursorScreenPos(ctx, wx + 7, wy + 2)
          logo(tbh - 4)
          local st = ui.status
          if st then
            ImGui.DrawList_AddCircleFilled(ImGui.GetWindowDrawList(ctx), wx + 7 + (tbh - 4) * 0.93 + 9, wy + tbh / 2, 4.5, st.colour)
            if ImGui.IsMouseHoveringRect(ctx, wx + 7, wy, wx + ww - pad - s * 3 - 20, wy + tbh) and ImGui.IsWindowHovered(ctx, ImGui.HoveredFlags_RootAndChildWindows) then
              ImGui.SetTooltip(ctx, st.tip .. "\n\n" .. st.drives)
            end
          end
        end
        local by = wy + (tbh - s) / 2
        ImGui.SetCursorScreenPos(ctx, wx + ww - pad - s * 2 - 8, by)
        if ui.window_icon("##minimize", "line", s, "Minimize to a strip over REAPER. Click it and the panel opens where it was.") then ui.set_minimized("strip") end
        ImGui.SetCursorScreenPos(ctx, wx + ww - pad - s * 3 - 14, by)
        if ui.window_icon("##tobox", "box", s, "Shrink to a tiny box over REAPER. Click it and the panel opens where it was.") then ui.set_minimized(true) end
      end
      ImGui.PopClipRect(ctx)
    end
    ImGui.Dummy(ctx, 0, 0) -- (a frame that ended just after setting the cursor, as while a tab closes: End kills the panel for that)
    ImGui.End(ctx)
  end
  ImGui.PopFont(ctx); pop_theme()
  banner()
  reaper.SetExtState(band.SECTION, "panel alive", tostring(reaper.time_precise()), false) -- (so Autostart never opens a second one)
  if open then return reaper.defer(loop) end
  if reaper.GetExtState(band.SECTION, "sync problem") == "" then -- (it keeps syncing: Live sync is its own script, one per tab)
    local mx, my = reaper.GetMousePosition()
    local at = reaper.time_precise()
    reaper.TrackCtl_SetToolTip("StudioSync keeps syncing with the panel closed.\nIf sync stops, the tiny box comes back in red to say so.", mx + 14, my + 14, true)
    local function clear()
      if reaper.time_precise() - at < 5 then return reaper.defer(clear) end
      reaper.TrackCtl_SetToolTip("", 0, 0, true)
    end
    reaper.defer(clear)
  end
end
reaper.defer(loop)
