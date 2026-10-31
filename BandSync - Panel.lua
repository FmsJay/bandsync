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
reaper.DeleteExtState(band.SECTION, "panel_open", true) -- (0.21.5 kept this; Autostart now opens the panel with any BandSync session)
local restarting = false -- an update landed: a new panel took over, and its toolbar state is on
reaper.atexit(function() if cmd > 0 and not restarting then reaper.SetToggleCommandState(section, cmd, 0); reaper.RefreshToolbar2(section, cmd) end end)

local ctx = ImGui.CreateContext("BandSync")
-- resizable from any edge (a window taller than the screen can still be shrunk from the top). The Window menu
-- (top bar) fills a screen or half of one. Settings can give it the system's frame instead of ReaImGui's (ExtState
-- panel_native = "on"; on Windows that's REAPER's tool-window frame: light caption, no maximize button)
local native = reaper.GetExtState(band.SECTION, "panel_native") == "on"
ImGui.SetConfigVar(ctx, ImGui.ConfigVar_WindowsResizeFromEdges, 1)
ImGui.SetConfigVar(ctx, ImGui.ConfigVar_ViewportsNoDecoration, native and 0 or 1)
local GREEN, YELLOW, GREY, RED = 0x59CC73FF, 0xF2BF40FF, 0x8C8C8CFF, 0xE0605AFF
local function rgba(c) return math.floor(c[1] * 255) << 24 | math.floor(c[2] * 255) << 16 | math.floor(c[3] * 255) << 8 | 0xFF end

-- ---- the app look: sidebar pages, cards, pills and switches (the default). The classic panel (tabs, plain
-- widgets) is the backup: "BandSync - Classic panel", or the switch on the Settings page. Same sections underneath.
local function classic() return reaper.GetExtState(band.SECTION, "panel_ui") == "classic" end
local ui_font = ImGui.CreateFont("sans-serif")
ImGui.Attach(ctx, ui_font)
local ACCENT, CARD, NAV, MUTED = 0x4C8DF6FF, 0x26292EFF, 0x1F2124FF, 0x8D939BFF
local DARK = 0x15171AFF
local THEME_COLS = {
  { ImGui.Col_WindowBg, 0x1A1C1FFF }, { ImGui.Col_ChildBg, 0x00000000 }, { ImGui.Col_PopupBg, 0x24272BFF },
  { ImGui.Col_Text, 0xE6E8EBFF }, { ImGui.Col_TextDisabled, MUTED }, { ImGui.Col_Border, 0x34383EFF },
  { ImGui.Col_FrameBg, 0x3B4049FF }, { ImGui.Col_FrameBgHovered, 0x474D57FF }, { ImGui.Col_FrameBgActive, 0x505762FF },
  { ImGui.Col_Button, 0x33373DFF }, { ImGui.Col_ButtonHovered, 0x40454CFF }, { ImGui.Col_ButtonActive, ACCENT },
  { ImGui.Col_Header, 0x2C3646FF }, { ImGui.Col_HeaderHovered, 0x33405AFF }, { ImGui.Col_HeaderActive, 0x3B4E74FF },
  { ImGui.Col_CheckMark, ACCENT }, { ImGui.Col_SliderGrab, ACCENT }, { ImGui.Col_Separator, 0x34383EFF },
  { ImGui.Col_SeparatorHovered, ACCENT }, { ImGui.Col_Tab, 0x2A2D32FF }, { ImGui.Col_TabHovered, 0x3A4558FF },
  { ImGui.Col_TabSelected, 0x34415AFF }, { ImGui.Col_TitleBg, 0x15171AFF }, { ImGui.Col_TitleBgActive, 0x1E2126FF },
  { ImGui.Col_TableHeaderBg, 0x2A2D32FF }, { ImGui.Col_TableRowBgAlt, 0x22252AFF }, { ImGui.Col_ScrollbarBg, 0x00000000 },
}
local THEME_VARS = {
  { ImGui.StyleVar_WindowPadding, 0, 0 }, { ImGui.StyleVar_FramePadding, 10, 6 }, { ImGui.StyleVar_ItemSpacing, 8, 8 },
  { ImGui.StyleVar_FrameRounding, 6 }, { ImGui.StyleVar_ChildRounding, 10 }, { ImGui.StyleVar_WindowRounding, 8 },
  { ImGui.StyleVar_GrabRounding, 6 }, { ImGui.StyleVar_PopupRounding, 6 }, { ImGui.StyleVar_TabRounding, 6 },
  { ImGui.StyleVar_ScrollbarRounding, 8 }, { ImGui.StyleVar_ChildBorderSize, 0 }, { ImGui.StyleVar_FrameBorderSize, 0 },
}
local function push_theme()
  for _, c in ipairs(THEME_COLS) do ImGui.PushStyleColor(ctx, c[1], c[2]) end
  for _, v in ipairs(THEME_VARS) do ImGui.PushStyleVar(ctx, v[1], v[2], v[3]) end
end
local function pop_theme()
  ImGui.PopStyleVar(ctx, #THEME_VARS)
  ImGui.PopStyleColor(ctx, #THEME_COLS)
end

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
  ImGui.DrawList_AddRectFilled(dl, x, y + 2, x + w, y + 2 + h, now and ACCENT or 0x6A707AFF, h / 2) -- (off: light enough to see against a card)
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
-- A small square button with a drawn curved arrow: undo points left, redo right. Returns clicked.
local function arrow_button(id, redo, tip)
  local dl = ImGui.GetWindowDrawList(ctx)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local s = ImGui.GetFrameHeight(ctx)
  local clicked = ImGui.InvisibleButton(ctx, id, s, s)
  local bg = ImGui.IsItemActive(ctx) and ACCENT or ImGui.IsItemHovered(ctx) and 0x40454CFF or 0x33373DFF
  ImGui.DrawList_AddRectFilled(dl, x, y, x + s, y + s, bg, 6)
  -- drawn as points and mirrored for redo, so the two are exactly the same size; on whole pixels so neither blurs
  -- the usual undo icon: an arrowhead pointing left, a stem, and a half-circle hooking back underneath (redo: mirrored)
  local cx, cy, col = math.floor(x + s / 2 + 0.5), math.floor(y + s / 2 + 0.5), 0xE6E8EBFF
  local r, h = math.floor(s * 0.2 + 0.5), math.max(3, math.floor(s * 0.16 + 0.5))
  local function px(dx) return redo and (cx - dx) or (cx + dx) end
  local tip, hook = -math.floor(s * 0.3 + 0.5), math.floor(s * 0.06 + 0.5)
  ImGui.DrawList_PathLineTo(dl, px(tip + h - 1), cy - r)
  ImGui.DrawList_PathLineTo(dl, px(hook), cy - r)
  for i = 1, 11 do -- round the right side, top to bottom
    local a = -math.pi / 2 + math.pi * i / 11
    ImGui.DrawList_PathLineTo(dl, px(hook + math.cos(a) * r), cy + math.sin(a) * r)
  end
  ImGui.DrawList_PathLineTo(dl, px(tip + h), cy + r)
  ImGui.DrawList_PathStroke(dl, col, ImGui.DrawFlags_None, 2)
  ImGui.DrawList_AddTriangleFilled(dl, px(tip), cy - r, px(tip + h), cy - r - h, px(tip + h), cy - r + h, col)
  if tip then ImGui.SetItemTooltip(ctx, tip) end
  return clicked
end
local wide = false -- docked wide and short (see layout): everything a little tighter
local function heading(text, size)
  ImGui.PushFont(ctx, nil, wide and 15 or (size or 19))
  ImGui.Text(ctx, text)
  ImGui.PopFont(ctx)
end
-- A card: a rounded panel sized to what's in it. Returns true when its content should be drawn (then call card_end).
-- `h`: a fixed height, for cards laid side by side (a self-sizing one always took a row of its own).
local function card(id, w, h)
  ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, CARD)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, 14, 12)
  local open = ImGui.BeginChild(ctx, id, w or 0, h or 0, (h and 0 or ImGui.ChildFlags_AutoResizeY) | ImGui.ChildFlags_AlwaysUseWindowPadding,
    ImGui.WindowFlags_NoScrollbar)
  ImGui.PopStyleVar(ctx)
  ImGui.PopStyleColor(ctx)
  if open then ImGui.PushTextWrapPos(ctx, 0) end
  return open
end
local function card_end() ImGui.PopTextWrapPos(ctx); ImGui.EndChild(ctx) end

-- The logo (James's idea): a sink dripping through a portal into another sink, drawn, so it's sharp at any size.
-- `s` = its height; it's 0.8 s wide. Drawn at the cursor, taking that space.
local function logo(s)
  local dl = ImGui.GetWindowDrawList(ctx)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local w = s * 0.8
  local cx = x + w / 2
  local steel, water, ring1, ring2 = 0xC9CED6FF, 0x7CC4FFFF, ACCENT, 0x9B7BF2FF
  ImGui.DrawList_AddLine(dl, x + w * 0.2, y + s * 0.05, cx, y + s * 0.05, steel, s * 0.06) -- the tap
  ImGui.DrawList_AddLine(dl, cx, y + s * 0.05, cx, y + s * 0.13, steel, s * 0.06)
  ImGui.DrawList_AddQuadFilled(dl, x, y + s * 0.17, x + w, y + s * 0.17, x + w * 0.8, y + s * 0.35, x + w * 0.2, y + s * 0.35, steel) -- sink
  ImGui.DrawList_AddEllipse(dl, cx, y + s * 0.43, w * 0.27, s * 0.05, ring1, 0, 0, s * 0.05) -- under its drain: a portal...
  ImGui.DrawList_AddEllipse(dl, cx, y + s * 0.6, w * 0.27, s * 0.05, ring2, 0, 0, s * 0.05) -- ...that opens over the other
  ImGui.DrawList_AddTriangleFilled(dl, cx, y + s * 0.64, cx - s * 0.045, y + s * 0.73, cx + s * 0.045, y + s * 0.73, water) -- the drop
  ImGui.DrawList_AddCircleFilled(dl, cx, y + s * 0.74, s * 0.045, water)
  ImGui.DrawList_AddQuadFilled(dl, x, y + s * 0.82, x + w, y + s * 0.82, x + w * 0.8, y + s, x + w * 0.2, y + s, steel) -- the other sink
  ImGui.Dummy(ctx, w, s)
end
-- The wordmark: BandSync, its "y" in the accent colour, standing in for the "i" of "Sink" too.
local function wordmark(size)
  ImGui.PushFont(ctx, nil, size)
  local y = ImGui.GetCursorPosY(ctx) -- (each piece on the same baseline: SameLine goes back to the line's top)
  ImGui.Text(ctx, "BandS")
  ImGui.SameLine(ctx, 0, 0)
  ImGui.SetCursorPosY(ctx, y)
  ImGui.TextColored(ctx, ACCENT, "y")
  ImGui.SameLine(ctx, 0, 0)
  ImGui.SetCursorPosY(ctx, y)
  ImGui.Text(ctx, "nc")
  ImGui.PopFont(ctx)
end
local reload_now, dock_req -- (Settings: switching the window frame reopens the panel; Dock / Undock)
local placed_from, placed_how -- where the window was before the Window menu moved it (screen pixels), and how it's placed
local banner_docked -- (docked, the panel never covers the arrange view)
local place_req, win_rect -- a placement for the next frame (ReaImGui units); the window as ReaImGui last drew it
local WINDOW_MENU = { "Fill this screen", "Left half", "Right half", "Top half", "Bottom half", "Move to the next screen", "Back to before" }
local function place_window(how)
  if how == "Dock" or how == "Undock" then dock_req = how == "Dock" and -1 or 0; return end -- (asked for from a script)
  local h = reaper.JS_Window_Find and reaper.JS_Window_Find("BandSync", true)
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
-- An on/off option: a switch in the app look, a checkbox in the classic one.
local function check(label, v, tip)
  local ch, nv
  if classic() then ch, nv = ImGui.Checkbox(ctx, label, v) else ch, nv = switch_row("##" .. label, label, v, tip) end
  if tip then ImGui.SetItemTooltip(ctx, tip) end
  return ch, nv
end
-- Next to the last item if `label`'s button still fits on this line, else on the next one (narrow or docked panels).
local function next_to(label)
  ImGui.SameLine(ctx)
  if ImGui.GetContentRegionAvail(ctx) < ImGui.CalcTextSize(ctx, label) + 24 then ImGui.NewLine(ctx) end
end

-- Tooltips for controls that don't set their own, by label (a control's own tooltip, set after it, wins).
local TIPS = {
  ["Start"] = "Start Live sync in this tab: your takes and changes go out, the band's come in.",
  ["Update"] = "Get the newest BandSync through ReaPack.",
  ["Let in"] = "Add this machine to the band folder.",
  ["Take control"] = "Become the driver: your deletes, moves and lane choices reach everyone (except where someone has claimed).",
  ["Take control now"] = "The driver isn't here: carry on as the driver (they can take it back when they return).",
  ["Claim region at cursor"] = "Every take that starts in the region at the edit cursor becomes yours to change, whoever drives.",
  ["Release mine"] = "Let go of all your claims: everything follows the driver again.",
  ["##label"] = "A name for this version, then Save point.",
  ["Save point"] = "Save how the session is now (takes, where they sit, what plays) as a restore point anyone can go back to.",
  ["Update the folder now"] = "Send your plug-in list and rebuild the FX browser folder 'BandSync (everyone has)' now.",
  ["##drummap"] = "The drum map this drum track uses: notes arriving in another kit's map are translated to it.",
  ["Play along (synced to the song)"] = "Hear each other in time with the song, at any distance (a bar or two late). Needs the band's NINJAM server.",
  ["Listen live (SonoBus, lowest delay)"] = "Hear each other right away, peer to peer (best on wired internet, not too far apart).",
  ["Jam (NINJAM intervals)"] = "Classic NINJAM: everyone hears everyone one interval late.",
  ["Leave"] = "Leave: SonoBus stops (it stays on its track, sending nothing) or ReaNINJAM disconnects.",
  ["##server"] = "The host's Tailscale address and NINJAM port, e.g. 100.64.0.1:2049.",
  ["Save for the band"] = "Everyone's Connect uses this address.",
  ["##ninjamdir"] = "The folder holding ninjamsrv and bandsync.cfg (host only).",
  ["Use server folder"] = "Remember this NINJAM server folder (host only).",
  ["Send my audio (my whole mix)"] = "Off: you listen without sending anything.",
  ["Connect"] = "Join the band's live audio in the mode above.",
  ["Show it"] = "Open the live plug-in's window.",
  ["Open latest to look"] = "Open the newest Solo edit version to look at.",
  ["Check out"] = "Take a working copy to edit while the others are offline.",
  ["##soloroot"] = "Where Solo edit keeps its versions (usually the shared Google Drive folder).",
  ["Clear"] = "Empty this activity list.",
  ["Open the full console"] = "REAPER's script console, with everything BandSync has said.",
  ["start from"] = "Where everyone starts: the edit cursor or a region.",
  ["count-in bars"] = "Bars of count-in before the start point.",
  ["Play together"] = "Everyone running Live sync starts playing from the same point at the same moment (5 s after you click).",
  ["Stop together"] = "Everyone stops.",
  ["##note"] = "A note for the band: on the selected take, or at the cursor. Everyone sees it on the timeline and in History.",
  ["Note on selected take"] = "Post the note on the selected take (a take marker everyone sees).",
  ["Note at cursor"] = "Post the note at the edit cursor.",
  ["Like selected take"] = "Tell the band you like the selected take.",
  ["Take back my last take"] = "Remove your newest take for everyone (it waits in the room's trash).",
  ["Print selected MIDI as audio"] = "Render the selected MIDI through its instrument as an audio take everyone hears.",
  ["Insert bars"] = "Insert bars at the edit cursor on every machine (driver only).",
  ["Remove bars"] = "Remove bars at the edit cursor on every machine (driver only).",
  ["Go there"] = "Go to this room (its own project tab).",
  ["##newroom"] = "A name for a new side room.",
  ["Go"] = "Go to the room they're asking you to.",
  ["Not now"] = "Hide this invitation.",
  ["Publish this project (I'm the host)"] = "Make this project the band's song: it becomes the session everyone joins.",
  ["Open a band session / room"] = "Join a song the host published, or one of its rooms.",
  ["Prepare this project for BandSync"] = "A checklist for a busy project before publishing (shows what it would change first).",
  ["Switch to the new look"] = "The app layout with a sidebar of pages.",
  ["Settings"] = "BandSync's settings: your name, the shared folder, how takes land.",
  ["Calibrate latency"] = "Measure how late recordings land (needs a cable from an output to an input).",
  ["Open another song"] = "Open another band song in a new tab.",
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
for _, name in ipairs({ "Button", "SmallButton", "Checkbox", "InputInt", "InputText", "InputTextWithHint", "BeginCombo", "RadioButton" }) do
  local f = ImGui[name]
  ImGui[name] = function(c, label, ...)
    local r = table.pack(f(c, label, ...))
    local t = type(label) == "string" and (TIPS[label] or TIPS[(label:gsub("##.*$", ""))])
    if t then ImGui.SetItemTooltip(c, t) end
    return table.unpack(r, 1, r.n)
  end
end

-- Actions run as REAPER actions (so they see their own action context), registered on first use.
local ids = {}
local function action(name)
  ids[name] = ids[name] or reaper.AddRemoveReaScript(true, 0, dir .. "/BandSync - " .. name .. ".lua", true)
  if ids[name] > 0 then reaper.Main_OnCommand(ids[name], 0) end
end

local proj, b, view, can, who, points, last, err = nil, nil, nil, nil, nil, {}, 0, nil
local banner_text -- what the banner over REAPER says while someone else drives (set with the view, drawn by banner())
local label = ""
local function refresh()
  proj = reaper.EnumProjects(-1)
  b = band.binding(proj)
  banner_text = nil -- (a tab that isn't a band session has no banner: it showed over a new empty tab)
  if not b then return end
  view = status.gather(cfg, b, proj)
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
    elseif who.mode ~= "open" then
      banner_text = mine > 0 and (view.driver .. " is driving: you can change what you've claimed.")
        or ("View only: " .. view.driver .. " is driving. Claim a track (BandSync, Home) to edit it.")
    end
  end
  points = recall.list(cfg, b.song, b.room)
end

-- History: re-read only while its tab is open, and not every frame.
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

-- What a track is called for ownership: a "(MIDI)" copy track and a "(band)" mirror belong to their part.
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
  if not running then -- (no Stop: a BandSync project always syncs, or the band's copies drift apart)
    ImGui.SameLine(ctx)
    if ImGui.SmallButton(ctx, "Start") then reaper.DeleteExtState(band.SECTION, "stop " .. key, false); band.start_live(dir) end
  end
  if not tools.autostart_on() and not tools.autostart_tried then -- always on: BandSync projects start Live sync with REAPER
    tools.autostart_tried = true
    if not tools.set_autostart(true, dir) then band.log("couldn't add BandSync to Scripts/__startup.lua: Live sync won't start with REAPER") end
  end
  local hold = select(2, reaper.GetProjExtState(proj, band.SECTION, "hold")) ~= ""
  if ImGui.SmallButton(ctx, "Undo my last change") then
    local c, why = tools.my_last_change(proj, cfg, b)
    if not c then band.msg(why)
    elseif reaper.MB("Put back " .. c.what .. " the way it was before?\n\nOnly your own changes, newest first (press again for the one " ..
        "before): a bandmate's change in between isn't touched. It goes to the band like any change.", "BandSync", 4) == 6 then
      local msg, e = tools.undo_mine(proj, cfg, b)
      if msg then band.log(msg) else band.msg(e) end
    end
  end
  ImGui.SetItemTooltip(ctx, "Unlike Ctrl+Z (which steps back whatever came last, a bandmate's change included), this goes back\n" ..
    "through only your own changes: moves and trims, fader/pan/mute, deletes.")
  local changed, v = check("Hold my changes (try things; they go out once, when you switch this off)", hold)
  if changed then reaper.SetProjExtState(proj, band.SECTION, "hold", v and "1" or "") end
  ImGui.Text(ctx, string.format("Here: %d/%d takes%s", view.total - view.my_missing, view.total,
    view.my_missing > 0 and (", " .. view.my_missing .. " still arriving") or ""))
  if view.newer then
    -- already on disk (an update, or a bandmate's folder install)? Then only this running panel is old
    local disk = (band.read(dir .. "/lib/band.lua") or ""):match('VERSION = "([^"]+)"')
    if disk == view.newer then
      ImGui.TextColored(ctx, YELLOW, "BandSync " .. disk .. " is installed: close and reopen this panel to use it.")
    else
      ImGui.TextColored(ctx, YELLOW, "BandSync " .. view.newer .. " is in use here; you have " .. band.VERSION .. ".")
      ImGui.SameLine(ctx)
      if ImGui.SmallButton(ctx, "Update##banner") then action("Update") end -- "##": same label as More's Update, its own ID
    end
  end
end

local function section_band()
  ImGui.SeparatorText(ctx, "Bandmates")
  -- machines asking to join that didn't come over the band's Tailscale (those are let in by Live sync)
  local asking = b.role == "host" and band.json_decode(reaper.GetExtState(band.SECTION, "pending_join")) or {}
  for _, d in ipairs(type(asking) == "table" and asking or {}) do
    ImGui.TextColored(ctx, YELLOW, string.format("'%s' (%s, from %s) asks to join the band folder.", d.name, d.id:sub(1, 7), d.address))
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Let in##" .. d.id) then
      local ok, why = require("services").add_device(d.id, d.name)
      band.log(ok and ("let '" .. d.name .. "' into the band folder") or ("couldn't add '" .. d.name .. "': " .. tostring(why)))
      reaper.DeleteExtState(band.SECTION, "pending_join", false)
    end
    ImGui.SetItemTooltip(ctx, "Only if you know this machine: anyone with your Syncthing ID can ask. Band machines on the band's Tailscale are let in by themselves.")
  end
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

local drive_root, drive_at = nil, -math.huge
local MODE_INFO = {
  { "driver", "Driver only", "Only the driver changes what the band has. Everyone else's changes are put back (record as usual)." },
  { "claims", "Claims", "The driver, and everyone on what they've claimed (a track, a region, a stretch of time). Other changes are put back." },
  { "open", "Open", "Anyone changes anything nobody has claimed; the newest change wins. The tempo map stays the driver's." },
}
local function section_driver()
  local driving = view.driver == cfg.user
  local mode, alone = who.mode or "claims", reaper.GetExtState(band.SECTION, "alone " .. tostring(proj)) ~= ""
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, "Editing:")
  for _, m in ipairs(MODE_INFO) do
    ImGui.SameLine(ctx)
    ImGui.BeginDisabled(ctx, not (driving or alone))
    if ImGui.RadioButton(ctx, m[2] .. "##mode", mode == m[1]) and mode ~= m[1] then
      sync.set_mode(cfg, b.song, b.room, m[1], cfg.user)
      band.log("editing in '" .. b.room .. "' is now " .. m[2] .. ": " .. m[3])
      last = 0
    end
    ImGui.EndDisabled(ctx)
    ImGui.SetItemTooltip(ctx, m[3] .. ((driving or alone) and "" or "\nThe driver picks this."))
  end
  ImGui.Text(ctx, driving and "You're driving: what nobody has claimed follows you." or (tostring(view.driver) .. " is driving."))
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
    ImGui.TextColored(ctx, GREEN, "Nobody else is here: you have full control. Everything you change goes to the band, and reaches " ..
      "them when they're back. When someone joins, the rules above apply again.")
    ImGui.PopTextWrapPos(ctx)
  end
end
local function section_drive()
  ImGui.SeparatorText(ctx, "Google Drive")
  if reaper.time_precise() - drive_at > 30 then drive_at = reaper.time_precise(); drive_root = require("drive").root(cfg) end
  local off = reaper.GetExtState(band.SECTION, "drive_root") == "off"
  local dch, don = check("Keep the band's copy on Google Drive", drive_root ~= nil)
  if dch then reaper.SetExtState(band.SECTION, "drive_root", don and "" or "off", true); drive_at = -math.huge end
  ImGui.SetItemTooltip(ctx, drive_root and ("Each room is copied to " .. drive_root .. " (every few minutes, while stopped): what someone " ..
    "does alone reaches the band whenever they next open the song, and every end-of-session point is kept there.")
    or off and "Off on this machine." or "No Google Drive for desktop here (My Drive not found).")
  local missing = not drive_root and not off and require("drive").missing
  if missing then
    ImGui.PushTextWrapPos(ctx, 0)
    ImGui.TextColored(ctx, YELLOW, "No BandSync folder in " .. missing .. ". On drive.google.com, find the band's BandSync folder " ..
      "(Shared with me), right-click > Organize > Add shortcut > My Drive, and keep the name BandSync. Starting a band? " ..
      "Make a folder called BandSync in My Drive and share it with everyone as Editor.")
    ImGui.PopTextWrapPos(ctx)
  end
end
local function section_claims()
  local owned = {}
  for name, c in pairs(who.tracks) do owned[#owned + 1] = { string.format("track %s: %s", c.name or name, c.user), c.user == cfg.user and "tracks", c.name or name } end
  for name, c in pairs(who.regions) do owned[#owned + 1] = { string.format("region %s: %s", c.name or name, c.user), c.user == cfg.user and "regions", c.name or name } end
  for _, t in ipairs(who.times or {}) do
    owned[#owned + 1] = { string.format("%s: %s", bar_span(t.from, t.to), t.user), t.user == cfg.user and "times", t }
  end
  table.sort(owned, function(x, y) return x[1] < y[1] end)
  if #owned == 0 then ImGui.TextDisabled(ctx, "Nothing claimed: everything follows the driver.") end
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
  -- chips: yours blue with an x that releases it, others' grey; they wrap like words
  local avail, used = ImGui.GetContentRegionAvail(ctx), 0
  local h = ImGui.GetFrameHeight(ctx) - 2
  for i, o in ipairs(owned) do
    local w = ImGui.CalcTextSize(ctx, o[1]) + 18 + (o[2] and 16 or 0)
    if i > 1 and used + w + 6 <= avail then ImGui.SameLine(ctx, 0, 6) else used = 0 end
    used = used + w + 6
    local x, y = ImGui.GetCursorScreenPos(ctx)
    local dl = ImGui.GetWindowDrawList(ctx)
    ImGui.InvisibleButton(ctx, "##chip" .. i, w, h)
    local hovered = ImGui.IsItemHovered(ctx)
    ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + h, o[2] and 0x2F4A6BFF or 0x3A3F46FF, h / 2)
    ImGui.DrawList_AddText(dl, x + 9, y + (h - ImGui.GetTextLineHeight(ctx)) / 2, 0xE6E8EBFF, o[1])
    if o[2] then
      local over_x = hovered and select(1, ImGui.GetMousePos(ctx)) >= x + w - 22
      local cx, cy, r = x + w - 12, y + h / 2, 3.5
      local col = over_x and RED or 0xB8BEC6FF
      ImGui.DrawList_AddLine(dl, cx - r, cy - r, cx + r, cy + r, col, 1.6)
      ImGui.DrawList_AddLine(dl, cx - r, cy + r, cx + r, cy - r, col, 1.6)
      if over_x and ImGui.IsItemClicked(ctx, 0) then release(o) end
      ImGui.SetItemTooltip(ctx, over_x and "Release it: it follows the driver again." or "Yours: only you change it, whoever drives.")
    else
      ImGui.SetItemTooltip(ctx, "Theirs: only they change it, whoever drives.")
    end
  end
  if ImGui.Button(ctx, "Claim selected tracks") then
    local list = {}
    for i = 0, reaper.CountSelectedTracks(proj) - 1 do list[#list + 1] = part_name(reaper.GetSelectedTrack(proj, i)) end
    if #list == 0 then band.msg("Select the tracks you want to own first.") else claim(list, {}) end
  end
  ImGui.SetItemTooltip(ctx, "Only you can move, trim, delete or re-pick takes on them; everyone follows you there.")
  next_to("Claim region at cursor")
  if ImGui.Button(ctx, "Claim region at cursor") then
    local _, ri = reaper.GetLastMarkerAndCurRegion(proj, reaper.GetCursorPositionEx(proj))
    local _, isrgn, _, _, name = reaper.EnumProjectMarkers3(proj, ri)
    if ri < 0 or not isrgn or name == "" then band.msg("Put the edit cursor inside a named region first.") else claim({}, { name }) end
  end
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
  ImGui.SetItemTooltip(ctx, "Takes that start inside the selected time are yours to change (a track someone claimed still wins).\n" ..
    "Everyone sees it as a region named [claimed: you].")
  next_to("Release mine")
  if ImGui.Button(ctx, "Release mine") and reaper.MB("Release all your claims (tracks, regions and time)? Everything you claimed follows the driver again.",
      "BandSync", 4) == 6 then
    sync.set_claims(cfg, b.song, b.room, { tracks = {}, regions = {}, times = {} })
  end
end
local function section_control()
  ImGui.SeparatorText(ctx, "Who changes what")
  section_driver()
  section_claims()
  section_drive()
end

-- A change in words, its positions as bars ("to bar 9 beat 3", not "to 20.50 s", which also broke mid-number when wrapped).
local function describe(e)
  return (recall.describe(e):gsub("( [at][to]?) (%d+%.%d+) s", function(w, n) return w .. " bar " .. bar_of(tonumber(n)) end))
end
-- History's "kind" filter: a set of event kinds, or a test on the change
local KINDS = {
  { "Every kind" }, { "Items (recordings, MIDI, moves, edits)", function(e) return e.obj == "item" and not e.gone end },
  { "Tracks (names, lanes, mute, folders)", function(e) return e.obj == "track" and not e.gone end },
  { "Plug-ins", function(e) return e.obj == "fx" end }, { "Deletes", function(e) return e.gone end },
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
-- One "go back" button, the kind the History radio picks: the whole project, the selected tracks, or this one change.
-- i: History index (the state right after entries[i]); what: words for the confirm box; point: a recall point file.
local function back_button(i, what)
  local mode, e, mirror = hf.mode or "project", entries[i], require("mirror")
  local opts = { can = can, mode = who and who.mode, local_mix = select(2, reaper.GetProjExtState(proj, band.SECTION, "local_mix")) == "1" }
  if mode == "change" then
    if not e then return end
    ImGui.BeginDisabled(ctx, e.kind ~= "obj")
    if ImGui.SmallButton(ctx, "Undo this") then
      band.log(mirror.revert(proj, cfg, b.song, b.room, mirror.plan_undo(entries, i), opts)); hist_at = 0
    end
    ImGui.EndDisabled(ctx)
    ImGui.SetItemTooltip(ctx, e.kind == "obj" and ("Undo only this change: " .. describe(e) .. ". Everything else stays; the undo goes to the band as a new change.")
      or "This kind of change (tempo, a handover, a note) isn't undone on its own: use Restore project state.")
  elseif mode == "selection" then
    if ImGui.SmallButton(ctx, "Selected tracks to here") then
      local scope = mirror.selection_scope(proj)
      if not scope then band.msg("Select the tracks to put back first (click their names in REAPER).")
      elseif reaper.MB("Put the selected tracks (their items and plug-ins) back to how they were " .. what .. "?\n\nEverything else stays as it is now.", "BandSync", 4) == 6 then
        band.log(mirror.revert(proj, cfg, b.song, b.room, mirror.plan_restore(entries, i, scope), opts)); hist_at = 0
      end
    end
    ImGui.SetItemTooltip(ctx, "Only the tracks selected in REAPER go back to how they were " .. what .. "; everything else stays. Goes to the band as new changes.")
  else
    local driving = view.driver == cfg.user
    ImGui.BeginDisabled(ctx, not driving)
    if ImGui.SmallButton(ctx, "Go back to here") and reaper.MB("Make the whole project look like it did " .. what .. "?\n\n" ..
        "Everything since then is undone, for everyone. It's a change like any other, so you can come back the same way.", "BandSync", 4) == 6 then
      band.log(mirror.revert(proj, cfg, b.song, b.room, mirror.plan_restore(entries, i), opts))
      last, hist_at = 0, 0
    end
    ImGui.EndDisabled(ctx)
    ImGui.SetItemTooltip(ctx, driving and "The whole project goes back to how it was " .. what .. "." or "Only the driver restores the whole project (take control first).")
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
    local ok = (hf.who == "" or e.user == hf.who) and (not want or (type(want) == "function" and want(e)) or (type(want) == "table" and want[e.kind]))
      and (hf.track == "" or (e.name or e.track or ""):lower() == hf.track:lower())
      and (text == "" or (line .. " " .. tostring(e.user)):lower():find(text, 1, true))
    if ok then
      n = n + 1
      ImGui.PushID(ctx, i)
      local roomy = ImGui.GetContentRegionAvail(ctx) > 620 -- narrow (docked): the change on its own line, its buttons under it
      if not roomy then
        if n > 1 then ImGui.Spacing(ctx) end
        ImGui.TextDisabled(ctx, local_time(e.time))
        ImGui.SameLine(ctx)
        ImGui.TextWrapped(ctx, e.user .. ": " .. line)
      end
      back_button(i, string.format("right after %s's change at %s", e.user, local_time(e.time)))
      if roomy then
        ImGui.SameLine(ctx)
        ImGui.TextDisabled(ctx, local_time(e.time))
        ImGui.SameLine(ctx)
        ImGui.TextWrapped(ctx, e.user .. ": " .. line)
      end
      ImGui.PopID(ctx)
    end
  end
  if n == 0 then ImGui.TextDisabled(ctx, "Nothing matches.") end
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
  -- (docked, the list takes the column's height instead of a short box inside it)
  if ImGui.BeginChild(ctx, "points", 0, wide and math.max(110, select(2, ImGui.GetContentRegionAvail(ctx)) - 4) or 110, ImGui.ChildFlags_Borders) then
    if #points == 0 then ImGui.TextDisabled(ctx, "None yet. Every handover saves one by itself.") end
    local before = select(2, reaper.GetProjExtState(proj, band.SECTION, "before_bandsync"))
    if before ~= "" and reaper.file_exists(before) then
      if ImGui.SmallButton(ctx, "Open it as it was before BandSync") then reaper.Main_OnCommand(40859, 0); reaper.Main_openProject(before) end
      ImGui.SetItemTooltip(ctx, "Opens the copy saved when this project was first published, in a new tab (it isn't a band session).")
    end
    for i, p in ipairs(points) do
      ImGui.PushID(ctx, i)
      local upto = 0 -- (mirror sessions: the point is a moment in History)
      for k, e in ipairs(entries) do if (e.time or "") <= (p.time or "") then upto = k end end
      if hf.mode ~= "change" then back_button(upto, "at '" .. p.label .. "'") end
      if hf.mode ~= "change" and ImGui.GetContentRegionAvail(ctx) > 520 then ImGui.SameLine(ctx) end -- narrow (docked): the words go under the buttons
      ImGui.TextWrapped(ctx, string.format("%s%s  ·  %s  ·  %s  ·  %d takes", p.label, p.keep and " (kept)" or "", tostring(p.by), local_time(p.time), p.takes))
      ImGui.PopID(ctx)
    end
    ImGui.EndChild(ctx)
  end
end

local function section_history()
  if reaper.time_precise() - hist_at > 4 then hist_at = reaper.time_precise(); refresh_history() end
  ImGui.SeparatorText(ctx, "Every change, newest first")
  hf.mode = hf.mode or (view.driver == cfg.user and "project" or "selection") -- (only the driver restores the whole song)
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.TextDisabled(ctx, "Buttons go back for:")
  for _, m in ipairs({ { "project", "Restore project state", "Each button brings the whole song back to that moment (the driver only)." },
      { "selection", "Restore selection's state", "Each button brings only the tracks selected in REAPER back to that moment." },
      { "change", "Undo specific change", "Each button undoes only that one change; everything after it stays." } }) do
    next_to(m[2])
    if ImGui.RadioButton(ctx, m[2], hf.mode == m[1]) then hf.mode = m[1] end
    ImGui.SetItemTooltip(ctx, m[3])
  end
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
  local v = combo("##hwho", hf.who == "" and "Everyone" or hf.who, users, "Only this person's changes.")
  if v then hf.who = v == "Everyone" and "" or v end
  next_to("Every kind of change")
  v = combo("##hkind", KINDS[hf.kind][1], kinds, "Only this kind of change.")
  if v then for i, k in ipairs(kinds) do if k == v then hf.kind = i end end end
  next_to("Every track")
  v = combo("##htrack", hf.track == "" and "Every track" or hf.track, tracks, "Only changes on this track.")
  if v then hf.track = v == "Every track" and "" or v end
  next_to("words in it")
  ImGui.SetNextItemWidth(ctx, 150)
  local _, t = ImGui.InputTextWithHint(ctx, "##htext", "words in it", hf.text, ImGui.InputTextFlags_None)
  hf.text = t
  ImGui.SetItemTooltip(ctx, "Only changes whose description has these words (a take, a track, a note's text...).")
  local filtered = hf.who ~= "" or hf.kind ~= 1 or hf.track ~= "" or hf.text ~= ""
  if filtered then
    ImGui.SameLine(ctx)
    if ImGui.SmallButton(ctx, "Clear filters") then hf = { who = "", kind = 1, track = "", text = "", mode = hf.mode } end
    ImGui.SetItemTooltip(ctx, "Back to everything, grouped by who made it.")
  end
  -- (docked, no list box of its own: under the filters it had no height left, so the column itself scrolls instead)
  if wide or ImGui.BeginChild(ctx, "history", 0, -4) then
    if filtered then
      history_filtered(driving)
      if not wide then ImGui.EndChild(ctx) end
      return
    end
    for gi = #groups, 1, -1 do
      local g = groups[gi]
      ImGui.PushID(ctx, gi)
      if hf.mode ~= "change" then
        back_button(g.last, string.format("right after %s's changes at %s", g.user, local_time(g.to)))
        ImGui.SameLine(ctx)
      end
      local n = g.last - g.first + 1
      local head = string.format("%s%s  ·  %s%s", g.user, g.solo and " (Solo edit)" or g.user == g.driver and " (driving)" or "",
        local_time(g.from), g.from ~= g.to and ("-" .. local_time(g.to):sub(7)) or "")
      local open = ImGui.TreeNodeEx(ctx, "g", head, ImGui.TreeNodeFlags_SpanAvailWidth)
      if not open then -- what it was about, wrapped under the line that opens it
        ImGui.Indent(ctx)
        ImGui.TextDisabled(ctx, describe(entries[g.first]) .. (n > 1 and string.format("  (+%d more)", n - 1) or ""))
        ImGui.Unindent(ctx)
      end
      if open then
        for i = g.first, g.last do
          ImGui.PushID(ctx, i)
          back_button(i, string.format("right after %s's change at %s", entries[i].user, local_time(entries[i].time)))
          ImGui.SameLine(ctx)
          ImGui.TextDisabled(ctx, local_time(entries[i].time):sub(7))
          ImGui.SameLine(ctx)
          ImGui.TextWrapped(ctx, describe(entries[i]))
          ImGui.PopID(ctx)
        end
        ImGui.TreePop(ctx)
      end
      ImGui.PopID(ctx)
    end
    if not wide then ImGui.EndChild(ctx) end
  end
end

-- Drum map of the selected tracks. Changing it rewrites the BandSync MIDI on those tracks into the new map,
-- so the notes keep hitting the same drums with the new instrument.
-- Plug-ins everyone in the band has, as a folder in REAPER's FX browser (lib/plugins.lua).
local plugins = require("plugins")
local plug_info
local function section_plugins()
  heading("Plug-ins everyone has", 17)
  ImGui.PushTextWrapPos(ctx, 0)
  ImGui.TextDisabled(ctx, "Each machine sends the band its list of plug-ins (names only) when Live sync starts. What all of you have " ..
    "goes in the FX browser folder '" .. plugins.FOLDER .. "': use those and the song sounds the same on every machine. " ..
    "JSFX (REAPER's own effects, and ReaPack's) work on Windows and Mac alike.")
  ImGui.PopTextWrapPos(ctx)
  if plug_info then ImGui.Text(ctx, plug_info) end
  if ImGui.Button(ctx, "Update the folder now") then
    local ok, n, why, members = pcall(function() plugins.publish(cfg); return plugins.update_folder(cfg) end)
    plug_info = not ok and ("Error: " .. tostring(n)) or n and string.format("%d plug-ins everyone has (lists from %s). Reopen the FX browser to see them.",
      n, table.concat(members or {}, ", ")) or why
  end
end

local drummap = require("drummap")
local function section_drums()
  if not ImGui.CollapsingHeader(ctx, "Drum map (selected tracks)") then return end
  local tr = reaper.GetSelectedTrack(proj, 0)
  if not tr then return ImGui.TextDisabled(ctx, "Select a drum track (yours, or a '(MIDI)' copy).") end
  local cur = band.track_ext(tr, "band_drummap")
  local names = { "", "gm" }
  for _, f in ipairs(band.files(cfg.root .. "/drummaps", ".json")) do names[#names + 1] = f:sub(1, -6) end
  ImGui.SetNextItemWidth(ctx, 220)
  if ImGui.BeginCombo(ctx, "##drummap", cur == "" and "none (notes as they come)" or cur) then
    for _, n in ipairs(names) do
      if ImGui.Selectable(ctx, n == "" and "none (notes as they come)" or n, n == cur) and n ~= cur then
        for i = 0, reaper.CountSelectedTracks(proj) - 1 do
          local t2 = reaper.GetSelectedTrack(proj, i)
          local old = band.track_ext(t2, "band_drummap")
          local conv = old ~= "" and n ~= "" and drummap.table(drummap.load(cfg.root, old), drummap.load(cfg.root, n))
          for j = 0, reaper.CountTrackMediaItems(t2) - 1 do
            local tk = reaper.GetActiveTake(reaper.GetTrackMediaItem(t2, j))
            local id = tk and reaper.TakeIsMIDI(tk) and (band.take_ext(tk, "band_midi") ~= "" and band.take_ext(tk, "band_midi") or band.take_ext(tk, "band_sent"))
            if conv and id and id ~= "" then
              local _, buf = reaper.MIDI_GetAllEvts(tk, "")
              reaper.MIDI_SetAllEvts(tk, drummap.translate(buf, conv))
              reaper.MIDI_Sort(tk)
              if band.take_ext(tk, "band_midi") ~= "" then sync.midi_seen(proj, id, tk) end -- a new view, not a note edit
            end
          end
          reaper.GetSetMediaTrackInfo_String(t2, "P_EXT:band_drummap", n, true)
        end
      end
    end
    ImGui.EndCombo(ctx)
  end
  ImGui.SetItemTooltip(ctx, "Which notes this track's drum instrument uses. Maps live in <shared folder>/drummaps; 'gm' is General MIDI.")
end

-- Live: hear each other while it happens, through ReaNINJAM and the band's NINJAM server.
local live = require("live")
local live_mode, live_send, live_server = "synced", true, nil
local services = require("services")
local ninjam_dir_edit, srv_at, srv_up = nil, 0, false
local LIVE_MODES = { { "synced", "Play along (synced to the song)" }, { "listen", "Listen live (SonoBus, lowest delay)" }, { "jam", "Jam (NINJAM intervals)" } }

local setup = require("setup")

-- Listen live: SonoBus joins the band's group by itself (BandSync writes it into SonoBus's state).
local sb_link
local function sonobus_open()
  local link, m, i = setup.sonobus(cfg, b, proj, true)
  if not link then return band.msg(m) end
  sb_link = link
  reaper.TrackFX_Show(m, i, 3)
end

-- Real time mode: the one switch for playing together. Listen live (SonoBus, set up for the band's group) plus side by side
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
    band.log("same room: Listen live is on and you follow the session (play, stop and record go to everyone)")
  else
    if sm then reaper.TrackFX_SetOffline(sm, si, true) end
    reaper.SetProjExtState(proj, band.SECTION, "side", "")
    band.log("same room off: SonoBus left the group and side by side is off (edits still sync)")
  end
end
local SAME_ROOM_TIP = "Real time mode. On: SonoBus joins the band's group (you hear each other right away), and side by side\n" ..
  "follows with no lag: whoever presses play, stop or record, everyone follows. What someone records shows on your timeline\n" ..
  "as they play (MIDI notes appear a few seconds behind) and lands as a take when they stop. Off: both off; edits keep syncing."
local function section_room()
  local on = same_room_on()
  local ch, v = ImGui.Checkbox(ctx, "Real time mode: hear everyone and follow the session together", on)
  if ch then set_same_room(v) end
  ImGui.SetItemTooltip(ctx, SAME_ROOM_TIP)
  if on then ImGui.SameLine(ctx); ImGui.TextColored(ctx, GREEN, "on") end
end

local server_at = 0
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
      synced = "Play to the song; the others hear you in time with it, a bar or two behind you. What you play also shows up on their timeline as an idea until your real take arrives.",
      listen = "Hear each other right away, with no server to run. Best on wired internet, with bandmates not too far away; otherwise use Play along.",
      jam = "Everyone plays at once and hears the others one cycle late (classic NINJAM).",
    })[live_mode])
    ImGui.Spacing(ctx)
  end
  if part == "mode" then return end
  if live_mode == "listen" then
    local sm, si = live.fx(proj, false, live.SONOBUS)
    local on = sm and not reaper.TrackFX_GetOffline(sm, si)
    if ImGui.Button(ctx, on and "Open SonoBus##sb" or "Connect##sb") then sonobus_open() end
    ImGui.SetItemTooltip(ctx, "Turns on SonoBus on your master track, already set to join the band's group: it sends your mix and plays the band into it.")
    if on then
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, "Leave##sb") then reaper.TrackFX_SetOffline(sm, si, true) end
      ImGui.TextColored(ctx, GREEN, "SonoBus is on and in the band's group, until you Leave.")
    elseif sm then
      ImGui.TextDisabled(ctx, "SonoBus is ready on your master track (off: it sends nothing until you Connect).")
    end
    if sb_link then
      if ImGui.SmallButton(ctx, "Copy join link") then ImGui.SetClipboardText(ctx, sb_link) end
      ImGui.SetItemTooltip(ctx, "For joining from SonoBus's own app (outside REAPER): its paste button fills the group in.")
    end
    return
  end
  ImGui.SeparatorText(ctx, "Server")
  ImGui.SetNextItemWidth(ctx, 220)
  local changed, v = ImGui.InputTextWithHint(ctx, "##server", "host's Tailscale IP:2049", live_server, ImGui.InputTextFlags_None)
  if changed then live_server = v end
  ImGui.SameLine(ctx)
  if ImGui.SmallButton(ctx, "Save for the band") then
    local data = band.read_json(lfile) or {} -- keep whatever else is in it
    data.server, data.by = live_server, cfg.user
    band.write_json(lfile, data)
  end
  ImGui.SetItemTooltip(ctx, "The host runs the NINJAM server (tools/ninjam-server); everyone connects to its address.")
  if b.role == "host" then -- the host's Connect starts the server here if it isn't running
    ninjam_dir_edit = ninjam_dir_edit or services.ninjam_dir()
    ImGui.SetNextItemWidth(ctx, -150)
    local c2, v2 = ImGui.InputTextWithHint(ctx, "##ninjamdir", "folder with ninjamsrv + bandsync.cfg", ninjam_dir_edit, ImGui.InputTextFlags_None)
    if c2 then ninjam_dir_edit = v2 end
    ImGui.SameLine(ctx)
    if ImGui.SmallButton(ctx, "Use server folder") then reaper.SetExtState(band.SECTION, "ninjam_dir", (ninjam_dir_edit:gsub("\\", "/")), true) end
    if reaper.time_precise() - srv_at > 3 then srv_at, srv_up = reaper.time_precise(), services.running("ninjamsrv") end -- tasklist is slow: not every frame
    ImGui.TextDisabled(ctx, srv_up and "Server: running on this machine" or "Server: not running (Connect starts it)")
  end
  local _, s = ImGui.Checkbox(ctx, "Send my audio (my whole mix)", live_send)
  live_send = s
  ImGui.Spacing(ctx)
  local master, idx = live.fx(proj, false)
  if not master then
    ImGui.BeginDisabled(ctx, live_server == "")
    if ImGui.Button(ctx, "Connect") then
      if b.role == "host" then
        local ok2, why = services.ensure_ninjam()
        if ok2 == "started" then band.log("started the NINJAM server") elseif not ok2 then band.msg("NINJAM server: " .. why) end
      end
      local sdir = (reaper.GetProjectName(proj) ~= "" and reaper.GetProjectPathEx(proj) or reaper.GetResourcePath()):gsub("\\", "/") .. "/bandsync_live"
      reaper.RecursiveCreateDirectory(sdir, 0)
      reaper.SetProjExtState(proj, band.SECTION, "live_dir", sdir)
      local ok, e = live.configure(cfg, live_server, live_mode, live_send, sdir)
      if not ok then band.msg(e) else
        local m2, i2 = live.fx(proj, true)
        if m2 then reaper.TrackFX_Show(m2, i2, 3) else band.msg("Couldn't add ReaNINJAM to the master track.") end
      end
    end
    ImGui.EndDisabled(ctx)
    ImGui.SetItemTooltip(ctx, "Adds ReaNINJAM to your master track with everything filled in: click Connect in its window.")
  else
    -- (it may sit on any track: say which)
    local where = master == reaper.GetMasterTrack(proj) and "your master track" or ("track '" .. select(2, reaper.GetTrackName(master)) .. "'")
    ImGui.TextColored(ctx, GREEN, "ReaNINJAM is on " .. where .. ".")
    next_to("NINJAM click on/off")
    if ImGui.SmallButton(ctx, "NINJAM click on/off") then
      if not live.toggle_click() then band.msg("Open ReaNINJAM's window first (Show it).") end
    end
    ImGui.SetItemTooltip(ctx, "NINJAM's own metronome ticks the whole time you're connected (at the server's tempo, not the song's).\n" ..
      "BandSync turns it off for Play along and Listen live; this flips it if it's on anyway.")
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
    if ImGui.Button(ctx, "Leave") then reaper.TrackFX_Delete(master, idx) end
  end
  ImGui.TextDisabled(ctx, "(?) about changing mode or server")
  ImGui.SetItemTooltip(ctx, "ReaNINJAM reads its settings once per REAPER session: after changing the mode or the server, restart REAPER. " ..
    "Play along ideas appear when the listener disconnects (ReaNINJAM writes what it heard only then).")
end

local setup_at, st = 0, {}
-- What BandSync did lately (sends, what arrived, what was put back and why): it used to pop the console up
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

local function section_setup()
  if reaper.time_precise() - setup_at > 5 then setup_at, st = reaper.time_precise(), setup.check(cfg, b, proj) end -- tasklist is slow
  local rows = {
    { st.audio, "Audio device is running", "REAPER's audio device is closed: pick one in Preferences > Audio > Device" },
    { st.folder, "Shared folder is syncing", "Syncthing isn't running" },
    { st.connected, st.peers and string.format("Connected to %d of %d bandmate machine(s)", st.peers, st.devices) or "Shared folder is a cloud drive",
      st.peers and "Syncthing is running but connected to nobody: is anyone else online? (If they are, this machine's Syncthing identity may have changed: check its device ID.)" or "Can't tell whether Syncthing is connected" },
    { st.sync, "Live sync is running", "Live sync is off" },
    { st.sonobus, "SonoBus is ready on the master track (Listen live)", "SonoBus isn't on the master track" },
    { st.server, "Play along server address is set", b.role == "host" and "Play along server address not set (needs Tailscale signed in)" or "Waiting for the host to set the Play along server address" },
    { st.latency, "Recording latency checked", st.latency_ms and string.format("Recordings land %.1f ms off: fix the input offset and calibrate again", st.latency_ms) or "Recording latency not checked yet (needs a cable: Calibrate latency)" },
  }
  if b.role == "host" then table.insert(rows, 7, { st.ninjam, "NINJAM server is running here", "NINJAM server isn't running (set its folder on Live)" }) end
  local all, essential, left = true, st.audio and st.folder and st.connected and st.sync, 0
  for _, r in ipairs(rows) do all = all and r[1]; if not r[1] then left = left + 1 end end
  -- only what stops the band from syncing opens this by itself; extras (Listen live, latency...) just count
  local head = all and "Set up: all done" or not essential and "Set up: needs attention" or string.format("Set up: ready (%d optional extra%s left)", left, left == 1 and "" or "s")
  if not essential then ImGui.SetNextItemOpen(ctx, true, ImGui.Cond_Always) end
  if ImGui.CollapsingHeader(ctx, head .. "###setup") then
    for _, r in ipairs(rows) do ImGui.TextColored(ctx, r[1] and GREEN or YELLOW, (r[1] and "OK   " or "--   ") .. (r[1] and r[2] or r[3])) end
    if not all then
      if ImGui.Button(ctx, "Set up everything I can") then
        local notes = setup.all(cfg, b, proj, st, function() band.start_live(dir) end)
        setup_at, live_server = 0, nil -- re-check, and re-read the server address it may have filled in
        if #notes > 0 then band.log("Set up: " .. table.concat(notes, "; ")) end
      end
      ImGui.SetItemTooltip(ctx, "Starts Syncthing and Live sync, adds SonoBus (off), and on the host fills in the Play along server address and starts the NINJAM server. The rest needs you: a cable, a sign-in or a share.")
    end
  end
end

local function section_actions()
  ImGui.SeparatorText(ctx, "More")
  for i, name in ipairs({ "Settings", "Calibrate latency", "Update" }) do
    if i > 1 then next_to(name) end
    if ImGui.Button(ctx, name) then action(name) end
  end
  if ImGui.Button(ctx, "Open another song") then reaper.SetExtState(band.SECTION, "open_other", "1", false); action("Open session") end
  ImGui.SetItemTooltip(ctx, "The song chooser: another song or room opens in a new tab (this one stays open, and keeps syncing).")
  next_to("Prepare this project")
  if ImGui.Button(ctx, "Prepare this project") then action("Prepare session") end
  ImGui.SetItemTooltip(ctx, "Takes into lanes, FLAC (recording and existing WAVs), clear track names, media in the project folder, tidy-up: a checklist first.")
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
  local lc, lv = ImGui.InputInt(ctx, "bars behind whoever plays", side_bars_edit)
  if lc then
    side_bars_edit = math.max(0, lv)
    if side ~= "" then reaper.SetProjExtState(proj, band.SECTION, "side", tostring(side_bars_edit)) end
  end
  ImGui.SetItemTooltip(ctx, "With Play along (Live): 1-2 bars, so you hear them in time with the song.\nWith Listen live: 0, everyone at the same spot.")
  if side ~= "" then
    local n = tonumber(side) or 0
    local live_mode_note = live.fx(proj, false) and "Play along / Jam is connected." or (live.fx(proj, false, live.SONOBUS) and "Listen live is on."
      or "To hear each other, connect on Live.")
    ImGui.PushTextWrapPos(ctx, 0)
    ImGui.TextDisabled(ctx, string.format("On: you follow %s behind whoever plays. %s", n == 0 and "right along" or (n .. (n == 1 and " bar" or " bars")), live_mode_note))
    local cm = live.fx(proj, false) and live.channel_mode()
    if cm and cm ~= "session" then
      ImGui.TextColored(ctx, YELLOW, "ReaNINJAM is sending in " .. (cm == "normal" and "Normal" or "Voice Chat") ..
        " mode: the others won't hear you in time with the song. In its window, click the mode button under your channel and pick \"Session mode channel\".")
    end
    ImGui.PopTextWrapPos(ctx)
  end

  ImGui.SeparatorText(ctx, "Start together")
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
  ImGui.SetNextItemWidth(ctx, 118)
  local _, l = ImGui.InputInt(ctx, "bars later for listeners", lag_bars); lag_bars = math.max(0, l)
  ImGui.SetItemTooltip(ctx, "Play along only: the others start this many bars after you\n(one NINJAM interval), so what they hear of you lines up.\nLeave 0 for everything else.")
  local pos = start_from > 0 and rg[start_from].pos or reaper.GetCursorPositionEx(proj)
  local function start(rec)
    go({ type = "start", rec = rec or nil, pos = pos, countin = together.bars_before(proj, pos, countin), click = click_on or nil,
      lag = together.bars_after(proj, pos, lag_bars), lead = cfg.user })
  end
  if ImGui.Button(ctx, "Play together") then start(false) end
  next_to("Record together")
  if ImGui.Button(ctx, "Record together") then start(true) end
  ImGui.SetItemTooltip(ctx, "Everyone records on the tracks they have armed (listed below).")
  next_to("Stop together")
  if ImGui.Button(ctx, "Stop together") then go({ type = "stop" }) end
  local due = tonumber(reaper.GetExtState(band.SECTION, "together_at " .. key))
  if due and due - together.now() > 0 then
    ImGui.TextColored(ctx, YELLOW, string.format("Starting in %.1f s...", due - together.now()))
  else
    ImGui.TextDisabled(ctx, string.format("From bar %s, %d s after the click, on every machine running Live sync.", bar_of(pos), together.LEAD))
  end
  local last_go = reaper.GetExtState(band.SECTION, "together " .. key)
  if last_go ~= "" then ImGui.TextDisabled(ctx, "Last: " .. last_go) end
  -- who's ready: Live sync running (seen recently), what they have armed, side by side or not
  if #view.rows > 0 then
    ImGui.TextDisabled(ctx, "Who's ready:")
    for _, r in ipairs(view.rows) do
      local ready = r.age < 30
      ImGui.TextColored(ctx, ready and GREEN or GREY, string.format("  %s: %s%s%s", r.name, ready and "Live sync on" or ("not seen for " .. status.ago(r.age)),
        (r.armed and #r.armed > 0) and (", armed " .. table.concat(r.armed, ", ")) or ", nothing armed",
        r.side and (", side by side (" .. r.side .. (tonumber(r.side) == 1 and " bar" or " bars") .. " behind)") or ""))
    end
  end
end

local notes_at, notes = 0, {}
local function section_notes()
  ImGui.SeparatorText(ctx, "Notes and likes")
  ImGui.SetNextItemWidth(ctx, -1)
  local entered, t = ImGui.InputTextWithHint(ctx, "##note", "a note for the band, Enter to post (e.g. 'try the chorus an octave up')", note_text, ImGui.InputTextFlags_EnterReturnsTrue)
  note_text = t
  local id, it = sel_take()
  ImGui.TextDisabled(ctx, id and string.format("Selected: %s's take on %s, bar %s", (id:match("^(.-)%-%d+%-%d+Z") or "?"):gsub("_", " "),
    sync.track_name(it), bar_of(reaper.GetMediaItemInfo_Value(it, "D_POSITION"))) or "No take selected: notes go at the edit cursor.")
  local function mark(kind, text)
    local pos = reaper.GetCursorPositionEx(proj)
    local ev = { type = kind, text = text, take = id, pos = pos, track = it and sync.base_name(select(2, reaper.GetTrackName(reaper.GetMediaItem_Track(it)))) or nil }
    sync.post(cfg, b.song, b.room, ev)
    if it then sync.mark_item(it, pos, (kind == "like" and "+1 " or "") .. cfg.user .. (text and (": " .. text) or "")) end -- as everyone else gets it
    notes_at = 0
  end
  ImGui.BeginDisabled(ctx, note_text == "")
  if (ImGui.Button(ctx, id and "Note on selected take" or "Note at cursor") or entered) and note_text ~= "" then mark("note", note_text); note_text = "" end
  ImGui.EndDisabled(ctx)
  ImGui.SameLine(ctx)
  ImGui.BeginDisabled(ctx, not id)
  if ImGui.Button(ctx, "Like selected take") then mark("like", nil) end
  ImGui.EndDisabled(ctx)
  if reaper.time_precise() - notes_at > 4 then
    notes_at, notes = reaper.time_precise(), {}
    for _, e in ipairs(recall.entries(cfg, b.song, b.room)) do
      if e.kind == "note" or e.kind == "like" then table.insert(notes, 1, e) end
    end
  end
  if ImGui.BeginChild(ctx, "notes", 0, 90, ImGui.ChildFlags_Borders) then
    if #notes == 0 then ImGui.TextDisabled(ctx, "No notes yet.") end
    for i, e in ipairs(notes) do
      if i > 30 then break end
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
    end
    ImGui.EndChild(ctx)
  end
end

local ideas_at, ideas = 0, {}
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
  ImGui.SetItemTooltip(ctx, "The selected placeholders stay for good (no take replaces them). Send them with Send selection if the band should have them.")
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
  room_view = { room = b.room, list = rooms.list(cfg, b.song), people = {}, meta = rooms.meta(cfg, b.song, b.room) }
  for _, r in ipairs(room_view.list) do room_view.people[r.name] = rooms.people(cfg, b.song, r.name) end
end

-- Bring this side room into the room it came from: what changed here and there since it was made, compared.
-- Bringing this side room into its parent (mirror sync): what only this room changed since it was made comes in,
-- what both changed stays as the parent has it (listed).
local function look_merge(parent)
  local m = room_view.meta or {}
  local mirror = require("mirror")
  local since = m.time
  if not since then merge = { why = "This room has no start time (made with an older BandSync)." }; return end
  local bring, clash = mirror.plan_bring(mirror.room_newest(sync.room_dir(cfg, b.song, b.room), since),
    mirror.room_newest(sync.room_dir(cfg, b.song, parent), since))
  merge = { bring = bring, clash = clash, parent = parent }
end

local function section_merge()
  if merge.why then ImGui.TextColored(ctx, YELLOW, merge.why); return end
  local parent = merge.parent
  if #merge.bring == 0 and #merge.clash == 0 then ImGui.TextDisabled(ctx, "Nothing here that '" .. parent .. "' doesn't have."); return end
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
      "They go to everyone there as new changes, so History there can undo them.", "BandSync", 4) == 6 then
    local ok, res = pcall(require("mirror").post_into, cfg, b.song, b.room, parent, merge.bring, rooms.tab(b.song, parent))
    band.log(ok and string.format("brought %d change(s) from '%s' into '%s'", res, b.room, parent) or ("bringing in failed: " .. tostring(res)))
    merge = nil
  end
  ImGui.EndDisabled(ctx)
  if not may then
    ImGui.SameLine(ctx)
    ImGui.TextDisabled(ctx, tostring(driver) .. " drives '" .. parent .. "': they bring it in (or take control there)")
  end
end

local function rooms_squares()
  refresh_rooms()
  ImGui.TextDisabled(ctx, "Try ideas in a side room, then bring back what works. (?)")
  ImGui.SetItemTooltip(ctx, "Each room is its own project tab: Go there opens it once, then it's a tab switch, and it's still there next " ..
    "session.\n\nCreate side room: a copy of the room you're in, as it is now; you drive it. Try your own edits there, or work on " ..
    "something else.\n\nCome see: everyone with the song open is asked to join you.\n\nSend selected to main: the items you pick " ..
    "come over as new takes. Bring into main: everything changed in the side room comes over, except where main changed the same " ..
    "thing too (those stay as main has them); main's driver does this, and History can undo it.")
  local avail = ImGui.GetContentRegionAvail(ctx)
  local w, gap = 178, 8
  local per = math.max(1, math.floor((avail + gap) / (w + gap)))
  for i, r in ipairs(room_view.list) do
    if (i - 1) % per ~= 0 then ImGui.SameLine(ctx, 0, gap) end
    local here = r.name == b.room
    ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, 0x26292EFF) -- a card in either look
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, 12, 10)
    local open = ImGui.BeginChild(ctx, "room " .. r.name, w, 0, ImGui.ChildFlags_Borders | ImGui.ChildFlags_AlwaysUseWindowPadding | ImGui.ChildFlags_AutoResizeY,
      ImGui.WindowFlags_NoScrollbar)
    ImGui.PopStyleVar(ctx)
    ImGui.PopStyleColor(ctx)
    if open then
      if here then ImGui.TextColored(ctx, GREEN, r.name .. "  (this tab)") else ImGui.Text(ctx, r.name) end
      ImGui.TextDisabled(ctx, r.parent and ("side room of " .. r.parent) or "the song")
      local people = room_view.people[r.name] or {}
      if #people == 0 then ImGui.TextDisabled(ctx, "nobody") end
      for _, p in ipairs(people) do
        if p.here then ImGui.TextColored(ctx, GREEN, p.user .. (p.me and " (you)" or ""))
        else ImGui.TextDisabled(ctx, p.user .. (p.me and " (you)" or "") .. ": tab open") end
      end
      if not here and ImGui.SmallButton(ctx, "Go there") then go_room(r.name) end
      ImGui.EndChild(ctx)
    end
  end
end
local function rooms_actions()
  if not room_view then return end
  if not wide then ImGui.Separator(ctx) end
  ImGui.SetNextItemWidth(ctx, math.min(260, math.max(120, ImGui.GetContentRegionAvail(ctx) - 150)))
  local _, v = ImGui.InputTextWithHint(ctx, "##newroom", "side room name (e.g. 'chorus ideas')", new_room, ImGui.InputTextFlags_None)
  new_room = v
  next_to("Create side room")
  if ImGui.Button(ctx, "Create side room") then
    local p, why = rooms.create(proj, cfg, b, new_room)
    if not p then band.msg(why) else
      band.log("made the side room '" .. new_room .. "' from '" .. b.room .. "' (you drive it)")
      new_room = ""
      if not live_running(p) then band.start_live(dir) end
      reaper.SetExtState(band.SECTION, "panel page", "Rooms", false)
      room_at = -math.huge
    end
  end
  ImGui.SetItemTooltip(ctx, "A copy of this room as it is now, in its own tab. Bandmates can join it from here.")
  local parent = room_view.meta and room_view.meta.parent
  if ImGui.Button(ctx, "Come see") then
    rooms.invite(cfg, b.song, b.room)
    band.log("asked everyone to come and see '" .. b.room .. "'")
  end
  ImGui.SetItemTooltip(ctx, "Everyone with this song open gets 'come and see " .. b.room .. "' at the top of their panel, with a Go button.")
  if not parent then return end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Send selected to " .. parent) then
    local list = require("mirror").selected(proj, cfg, b.song, b.room, parent)
    if #list == 0 then band.msg("Select the items to send first (they go to '" .. parent .. "' as they are here).")
    elseif reaper.MB(string.format("Send the %d selected item(s) to '%s', as they are here? (Any of their tracks '%s' doesn't have yet go too.)",
        #list, parent, parent), "BandSync", 4) == 6 then
      band.log(string.format("sent %d change(s) from '%s' to '%s'", require("mirror").post_into(cfg, b.song, b.room, parent, list, rooms.tab(b.song, parent)), b.room, parent))
    end
  end
  ImGui.SetItemTooltip(ctx, "The easy way back: the selected items go to '" .. parent .. "' as they are here (new changes there, so History there can undo them).")
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, merge and "Look again" or ("Bring into " .. parent .. "...")) then look_merge(parent) end
  ImGui.SetItemTooltip(ctx, "Compares this room, '" .. parent .. "' and how this room started: everything changed here comes over, " ..
    "except what '" .. parent .. "' changed too since (it keeps its own; use Send selected for those). New recordings come too.")
  if merge then section_merge() end
end

local function section_rooms() rooms_squares(); rooms_actions() end

-- Bandmates asking you to come and see their room (any tab of the song).
local invites, invites_at = {}, -math.huge
local function section_invites()
  if reaper.time_precise() - invites_at > 3 then invites_at = reaper.time_precise(); invites = rooms.invites(cfg, b.song) end
  for _, v in ipairs(invites) do
    local key = v.from .. v.time
    if v.room ~= b.room and not dismissed[key] then
      ImGui.PushID(ctx, key)
      ImGui.TextColored(ctx, YELLOW, v.from .. " asks you to come and see '" .. v.room .. "'")
      ImGui.SameLine(ctx)
      if ImGui.SmallButton(ctx, "Go") then dismissed[key] = true; go_room(v.room) end
      ImGui.SameLine(ctx)
      if ImGui.SmallButton(ctx, "Not now") then dismissed[key] = true end
      ImGui.PopID(ctx)
    end
  end
end


-- Docked wide and short (a bottom docker), a page's parts stand side by side as columns, each scrolling up and down on
-- its own, and the page scrolls sideways when they don't all fit; otherwise they come one under the other.
local function layout(parts) -- { { fn, width } }
  if not wide then
    for _, part in ipairs(parts) do part[1]() end
    return
  end
  local _, h = ImGui.GetContentRegionAvail(ctx)
  for i, part in ipairs(parts) do
    if i > 1 then ImGui.SameLine(ctx, 0, 10) end
    ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, 0x202327FF)
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, 12, 10)
    ImGui.BeginGroup(ctx)
    local fh = ImGui.GetTextLineHeightWithSpacing(ctx) -- a line under the column says when it hides more (drawn over the column, it covered text)
    local open = ImGui.BeginChild(ctx, "col" .. i, part[2] or 340, h - fh, ImGui.ChildFlags_AlwaysUseWindowPadding)
    ImGui.PopStyleVar(ctx)
    ImGui.PopStyleColor(ctx)
    local more = false
    if open then
      ImGui.PushTextWrapPos(ctx, 0)
      part[1]()
      ImGui.PopTextWrapPos(ctx)
      more = ImGui.GetScrollMaxY(ctx) - ImGui.GetScrollY(ctx) > fh -- (less than a line out of sight isn't "more")
      ImGui.EndChild(ctx)
    end
    if more then
      ImGui.SetCursorPosX(ctx, ImGui.GetCursorPosX(ctx) + 12)
      ImGui.TextDisabled(ctx, "more below: scroll this column")
    else
      ImGui.Dummy(ctx, 1, fh - 4)
    end
    ImGui.EndGroup(ctx)
  end
  if h < 170 and reaper.GetExtState(band.SECTION, "dock_hint") == "" then -- once: a short docker hides most of each page
    ImGui.SameLine(ctx, 0, 10)
    ImGui.BeginGroup(ctx)
    ImGui.TextColored(ctx, YELLOW, "Short on room: drag the thin line just above the docker's tabs upward to see more.")
    if ImGui.SmallButton(ctx, "Got it") then reaper.SetExtState(band.SECTION, "dock_hint", "1", true) end
    ImGui.EndGroup(ctx)
  end
end

-- Maintenance: what's set up and working. Red: the band can't sync until it's fixed. Yellow: an extra, or worth a
-- look (dismissable). The sidebar shows the worst one still open.
local maint_st, maint_at = nil, -math.huge
local function maint_rows()
  if not maint_st or reaper.time_precise() - maint_at > 10 then maint_at, maint_st = reaper.time_precise(), setup.check(cfg, b, proj) end
  local s = maint_st
  local rows = {
    { "audio", s.audio, "red", "Audio device is running", "REAPER's audio device is closed: pick one in Preferences > Audio > Device." },
    { "folder", s.folder, "red", "Shared folder is syncing", "Syncthing isn't running: nothing reaches the band or comes in." },
    { "sync", s.sync, "red", "Live sync is running", "Live sync is off in this tab: press Start at the top." },
    { "same", (tonumber(reaper.GetExtState(band.SECTION, "mirror drift " .. tostring(proj))) or 0) == 0, "red", "Changes from the band come out the same here",
      "Some changes from the band came out different here than on their machine (the Console names them). Ask the driver to " ..
      "use History > Restore project state, or close and reopen this project." },
    { "connected", s.connected, #(view and view.rows or {}) > 0 and "red" or "yellow", s.peers and string.format("Connected to %d of %d bandmate machine(s)", s.peers, s.devices) or "Shared folder is a cloud drive",
      s.peers and "Syncthing is connected to nobody. Fine if you're alone; if bandmates are online, check this machine's Syncthing device ID."
      or "Can't tell whether Syncthing is connected." },
    { "sonobus", s.sonobus, "yellow", "SonoBus is ready (Real time mode)", "SonoBus isn't set up yet: Real time mode (Home) adds it." },
    { "server", s.server, "yellow", "Play along server address is set", b.role == "host" and "Play along server address not set (needs Tailscale signed in)."
      or "Waiting for the host to set the Play along server address." },
    { "latency", s.latency, "yellow", "Recording latency checked", s.latency_ms and
      string.format("Recordings land %.1f ms off: fix the input offset and calibrate again.", s.latency_ms) or "Recording latency not checked yet (needs a cable: Calibrate latency below)." },
  }
  if b.role == "host" then table.insert(rows, 6, { "ninjam", s.ninjam, "yellow", "NINJAM server is running here", "NINJAM server isn't running (set its folder on the Play page)." }) end
  if view.newer then rows[#rows + 1] = { "update " .. view.newer, false, "yellow", "", "BandSync " .. view.newer .. " is in use in the band; you have " .. band.VERSION .. ": press Update below." } end
  local dmiss = reaper.GetExtState(band.SECTION, "drive_root") ~= "off" and require("drive").missing
  if dmiss then rows[#rows + 1] = { "drive", false, "yellow", "", "Google Drive: no shared BandSync folder in " .. dmiss .. " (Settings shows how to add it)." } end
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
    if not r[2] and not (r[3] == "yellow" and gone[r[1]]) then
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
    heading("Set up and health", 17)
    for _, r in ipairs(maint_rows()) do
      local ok = r[2]
      if ok or r[3] == "red" or not gone[r[1]] then
        ImGui.PushID(ctx, r[1])
        dot(ok and GREEN or (r[3] == "red" and RED or YELLOW))
        ImGui.SameLine(ctx)
        ImGui.TextWrapped(ctx, ok and r[4] or r[5])
        if not ok and r[3] == "yellow" then
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
    if next(gone) then
      if ImGui.SmallButton(ctx, "Show dismissed") then reaper.DeleteExtState(band.SECTION, "dismissed", true) end
      ImGui.SetItemTooltip(ctx, "Bring back the yellow lines you dismissed.")
    end
    if ImGui.Button(ctx, "Set up everything I can") then
      local notes = setup.all(cfg, b, proj, maint_st, function() band.start_live(dir) end)
      maint_at, live_server = -math.huge, nil
      if #notes > 0 then band.log("Set up: " .. table.concat(notes, "; ")) end
    end
    ImGui.SetItemTooltip(ctx, "Starts Syncthing and Live sync, adds SonoBus (off), and on the host fills in the Play along server address and starts the NINJAM server. The rest needs you: a cable, a sign-in or a share.")
    card_end()
  end
end
local function maint_upkeep()
  if card("upkeep") then
    heading("Upkeep and activity", 17)
    section_activity()
    section_actions()
    card_end()
  end
  ImGui.Dummy(ctx, 0, 12)
  local w = ImGui.GetContentRegionAvail(ctx)
  ImGui.SetCursorPosX(ctx, ImGui.GetCursorPosX(ctx) + math.max(0, (w - 150) / 2))
  logo(48)
  ImGui.SameLine(ctx, 0, 10)
  ImGui.SetCursorPosY(ctx, ImGui.GetCursorPosY(ctx) + 8)
  ImGui.BeginGroup(ctx)
  wordmark(20)
  ImGui.TextDisabled(ctx, "version " .. band.VERSION)
  ImGui.EndGroup(ctx)
end

-- Home: playing together, who's here and what they're doing, and the session's switches.
local function home_play()
  local on = same_room_on()
  local ch, v = switch_row("##rt", "Real time mode", on, SAME_ROOM_TIP)
  if ch then set_same_room(v) end
  ImGui.SameLine(ctx)
  if ImGui.SmallButton(ctx, "Configure SonoBus") then sonobus_open() end
  ImGui.SetItemTooltip(ctx, "Opens SonoBus's own window (volume and mute per bandmate, buffer, quality). You don't need it to play together.")
  if not wide then
    ImGui.TextDisabled(ctx, on and "You hear everyone live, and play, stop and record follow whoever presses them."
      or "Off: changes still sync, but you don't hear each other live or follow each other's play and stop.")
  end
end
local function home_who()
  heading("Who's here")
  if view.driver ~= cfg.user then -- next to the people: who drives is about them
    ImGui.SameLine(ctx, 0, 12)
    if ImGui.SmallButton(ctx, "Take control") then action("Take control") end
    ImGui.SetItemTooltip(ctx, tostring(view.driver) .. " is driving. Take control to make what nobody has claimed follow you (tell them first).")
  end
  local people, armed = {}, {}
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    if reaper.GetMediaTrackInfo_Value(tr, "I_RECARM") == 1 then armed[#armed + 1] = select(2, reaper.GetTrackName(tr)) end
  end
  local ps = reaper.GetPlayStateEx(proj)
  people[1] = { name = cfg.user .. " (you)", state = "here", armed = armed, recording = ps & 4 == 4, playing = ps & 1 == 1,
    driving = view.driver == cfg.user }
  for _, r in ipairs(view.rows) do
    people[#people + 1] = { name = r.name, state = r.state, armed = r.armed, recording = r.recording, playing = r.playing,
      driving = r.name == view.driver, version = r.version, mirror = r.mirror }
  end
  if wide then
    for _, p in ipairs(people) do
      dot(p.state == "here" and GREEN or rgba(status.COLORS[p.state] or { 0.55, 0.55, 0.55 }))
      ImGui.SameLine(ctx, 0, 4)
      ImGui.Text(ctx, p.name)
      ImGui.SetItemTooltip(ctx, p.state .. (p.armed and #p.armed > 0 and (", armed: " .. table.concat(p.armed, ", ")) or ", nothing armed") ..
        (p.version and p.version ~= band.VERSION and (", BandSync " .. p.version) or ""))
      if p.recording then ImGui.SameLine(ctx, 0, 6); pill("recording", RED) elseif p.driving then ImGui.SameLine(ctx, 0, 6); pill("driving", YELLOW) end
    end
    if #view.rows == 0 then ImGui.TextDisabled(ctx, "Nobody else has synced in this room yet.") end
    return home_play()
  end
  local avail = ImGui.GetContentRegionAvail(ctx)
  local w, gap = 158, 8
  local per = math.max(1, math.floor((avail + gap) / (w + gap)))
  for i, p in ipairs(people) do
    if (i - 1) % per ~= 0 then ImGui.SameLine(ctx, 0, gap) end
    if card("who " .. p.name, w) then -- (grows with what they have armed)
      ImGui.PushFont(ctx, nil, 16)
      ImGui.Text(ctx, p.name)
      ImGui.PopFont(ctx)
      pill(p.state, p.state == "here" and GREEN or rgba(status.COLORS[p.state] or { 0.55, 0.55, 0.55 }))
      ImGui.SetItemTooltip(ctx, ({ here = "This machine.", ["synced"] = "Has every change.", ["syncing"] = "Still receiving changes.",
        offline = "Not seen for over a minute.", ["no receipt"] = "Has sent takes, but never ran Live sync here." })[p.state] or p.state)
      if p.recording then ImGui.SameLine(ctx, 0, 4); pill("recording", RED)
      elseif p.playing and p.state ~= "offline" then ImGui.SameLine(ctx, 0, 4); pill("playing", 0x8FB3F8FF) end
      if p.driving then ImGui.SameLine(ctx, 0, 4); pill("driving", YELLOW); ImGui.SetItemTooltip(ctx, "What nobody has claimed follows them.") end
      ImGui.TextDisabled(ctx, p.armed and #p.armed > 0 and ("armed: " .. table.concat(p.armed, ", ")) or "nothing armed")
      if p.version and p.version ~= band.VERSION then ImGui.TextColored(ctx, YELLOW, "BandSync " .. p.version) end
      if p.mirror and view.my_mirror and p.state == "synced" then -- (while changes are still on their way it's bound to differ)
        if p.mirror == view.my_mirror then ImGui.TextColored(ctx, GREEN, "same project as yours")
        else ImGui.TextColored(ctx, RED, "project differs from yours"); ImGui.SetItemTooltip(ctx, "They have every change, yet their project isn't the same as yours: " ..
          "Setup > Health says more, and the Console names what came out different.") end
      end
      card_end()
    end
  end
  if #view.rows == 0 then ImGui.TextDisabled(ctx, "Nobody else has synced in this room yet.") end
  home_play()
end
-- Local mixing: your faders and pan stay yours (not sent, not overwritten). Off again: adopt the band's mix, or
-- send yours.
local function local_mix_row()
  local on = select(2, reaper.GetProjExtState(proj, band.SECTION, "local_mix")) == "1"
  local ch, v = switch_row("##localmix", "Local mixing", on, "Your faders and pan stay yours: nobody else's reach you and yours don't go out.")
  if ch and v then reaper.SetProjExtState(proj, band.SECTION, "local_mix", "1")
  elseif ch then
    local r = reaper.MB("Local mixing off. Take the band's mix (faders and pan)?\n\nYes: use the band's mix.\nNo: send your mix to the band " ..
      "(the tracks you may change).", "BandSync", 3)
    if r ~= 2 then
      require("mirror").end_local_mix(proj, cfg, b.song, b.room, r == 6)
      reaper.SetProjExtState(proj, band.SECTION, "local_mix", "")
    end
  end
end
local function home_session()
  if card("session") then
    heading("Who changes what", 17)
    section_driver()
    local hold = select(2, reaper.GetProjExtState(proj, band.SECTION, "hold")) ~= ""
    local ch, v = switch_row("##hold", "Hold my changes", hold, "Try things: your changes go out once, when you switch this off.")
    if ch then reaper.SetProjExtState(proj, band.SECTION, "hold", v and "1" or "") end
    local_mix_row()
    section_claims()
    card_end()
  end
end

local function home_rules()
  heading("Who changes what", 17)
  section_driver()
  local hold = select(2, reaper.GetProjExtState(proj, band.SECTION, "hold")) ~= ""
  local ch, v = switch_row("##hold", "Hold my changes", hold, "Try things: your changes go out once, when you switch this off.")
  if ch then reaper.SetProjExtState(proj, band.SECTION, "hold", v and "1" or "") end
  local_mix_row()
end
local function home_claims()
  heading("Claims", 17)
  section_claims()
end
local function page_home()
  if wide then layout({ { home_who, 300 }, { home_rules, 420 }, { home_claims, 420 } })
  else layout({ { home_who, 360 }, { home_session, 400 } }) end
end

local function settings_look()
  if card("look") then
    heading("Look", 17)
    if ImGui.Button(ctx, "Use the classic panel") then reaper.SetExtState(band.SECTION, "panel_ui", "classic", true) end
    ImGui.SetItemTooltip(ctx, "The plain panel with tabs (everything is the same underneath). 'BandSync - Classic panel' opens it too.")
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
    section_sync()
    local pill_on = reaper.GetExtState(band.SECTION, "pill") ~= "off"
    local pch, pv = check("Closing the panel leaves a small button over REAPER", pill_on)
    if pch then reaper.SetExtState(band.SECTION, "pill", pv and "" or "off", true) end
    ImGui.SetItemTooltip(ctx, "A click on the button opens the panel again where it was. Off: closing the panel closes it.")
    -- MIDI wet/dry, this machine's choice (lib/prints.lua): never changes what anyone else hears
    ImGui.SeparatorText(ctx, "MIDI plays as")
    local prints = require("prints")
    for _, m in ipairs({ { "auto", "Auto", "Your instruments when the track's plug-ins all load here, else the sound the band printed." },
        { "notes", "Notes", "Always your own instruments (dry): you can change the sound." },
        { "sound", "Sound", "Always the printed sound (wet): exactly what whoever played it heard." } }) do
      if m[1] ~= "auto" then ImGui.SameLine(ctx) end
      if ImGui.RadioButton(ctx, m[2] .. "##midiplays", prints.mode() == m[1]) then
        reaper.SetExtState(band.SECTION, "midi_plays", m[1], true)
        for i = 0, reaper.CountMediaItems(proj) - 1 do prints.choose(reaper.GetMediaItem(proj, i)) end
      end
      ImGui.SetItemTooltip(ctx, m[3])
    end
    card_end()
  end
end
local function settings_drive()
  if card("drive") then
    section_drive()
    card_end()
  end
end
local function settings_more()
  if card("more") then
    section_drums()
    card_end()
  end
end

local function page_setup()
  if not ImGui.BeginTabBar(ctx, "setup") then return end
  if ImGui.BeginTabItem(ctx, "Health") then layout({ { maint_health, 460 }, { section_actions, 440 } }); ImGui.EndTabItem(ctx) end
  if ImGui.BeginTabItem(ctx, "Console") then
    -- BandSync's own log, newest first (REAPER's console only shows it while open)
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
  if ImGui.BeginTabItem(ctx, "Options") then
    layout({ { settings_look, 320 }, { settings_sync, 420 }, { settings_drive, 360 }, { settings_more, 400 } })
    ImGui.EndTabItem(ctx)
  end
  if ImGui.BeginTabItem(ctx, "Updates") then maint_upkeep(); ImGui.EndTabItem(ctx) end
  ImGui.EndTabBar(ctx)
end

local PAGES = {
  { "Home", "Who's here and what they're doing, real time mode, and who changes what." },
  { "Rooms", "The song's rooms: make a side room to try things, have everyone come and see, and bring work back." },
  { "Play", "Play or record together, follow each other, and how you hear each other (real time, play along or jam)." },
  { "Chat", "Messages, to-dos, notes and links for this room, this song or the whole band." },
  { "History", "Every change, and three ways back: the whole project, the selected tracks, or one change." },
  { "Plugins", "Every plug-in in this project, who doesn't have it, and the band's translations for it." },
  { "Setup", "Health (red: needs fixing, yellow: worth a look), the console, options and updates." },
}
local OLD_PAGES = { Together = "Play", Live = "Play", Settings = "Setup", Maintenance = "Setup" } -- (links from older versions)
local page = "Home"
local level, level_at = nil, -math.huge
local function nav_dot(p)
  if p == "Setup" and level then return level == "red" and RED or YELLOW end
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
  local function nav_item(p, w, h)
    local x, y = ImGui.GetCursorScreenPos(ctx)
    if ImGui.Selectable(ctx, (compact and "" or "  ") .. p[1] .. "##nav", p[1] == page, ImGui.SelectableFlags_None, w, h) then page = p[1] end
    local c = nav_dot(p[1])
    ImGui.SetItemTooltip(ctx, p[2] .. (c and (level == "red" and "\n\nSomething needs fixing before the band can sync: open it to see what."
      or "\n\nSomething is worth a look (or an extra isn't set up): open it to see, or dismiss it there.") or ""))
    if c then
      local iw = ImGui.GetItemRectSize(ctx)
      ImGui.DrawList_AddCircleFilled(ImGui.GetWindowDrawList(ctx), x + iw - 10, y + h / 2, 4.5, c)
    end
    if p[1] == page and not compact then ImGui.DrawList_AddRectFilled(ImGui.GetWindowDrawList(ctx), x - 8, y + 6, x - 4, y + h - 6, ACCENT, 2) end
  end
  local y0 = ImGui.GetCursorPosY(ctx) + 8
  ImGui.SetCursorPos(ctx, 16, y0)
  ImGui.PushFont(ctx, nil, 21)
  local _, th = ImGui.CalcTextSize(ctx, "Project: " .. b.song)
  ImGui.SetCursorPosY(ctx, y0 + (fh - th) / 2)
  ImGui.Text(ctx, "Project: " .. b.song)
  ImGui.PopFont(ctx)
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
  at_row("room: " .. b.room); pill("room: " .. b.room, 0x34415AFF, 0xD6E4FFFF, fh)
  ImGui.SetItemTooltip(ctx, "The room this tab is in (Rooms page: side rooms).")
  at_row(running and "Sync on" or "Sync off"); pill(running and "Sync on" or "Sync off", running and GREEN or RED, DARK, fh)
  ImGui.SetItemTooltip(ctx, running and "Live sync is running in this tab: your takes and changes go out, the band's come in." or "Live sync is off in this tab.")
  if not running then -- (Stop is in Settings: nobody needs it at hand, and it sat next to buttons people do press)
    at_row("Start")
    if ImGui.Button(ctx, "Start") then reaper.DeleteExtState(band.SECTION, "stop " .. key, false); band.start_live(dir) end
  end
  local drives = view.driver == cfg.user and "you drive" or (tostring(view.driver) .. " drives")
  at_row(drives); ImGui.AlignTextToFramePadding(ctx)
  ImGui.TextDisabled(ctx, drives)
  ImGui.SetItemTooltip(ctx, "The driver's changes go to everyone, except on what someone has claimed.")
  at_row("Undo")
  -- your own changes only, for everyone (a bandmate's change since is never touched, unlike Ctrl+Z); each asks first,
  -- naming the change. Read from History's events on click (not every frame).
  local function undo_redo(redo)
    local mirror = require("mirror")
    local all = recall.entries(cfg, b.song, b.room)
    local i = redo and mirror.last_undo(all, cfg.user) or mirror.last_mine(all, cfg.user)
    if not i then return band.msg(redo and "Nothing to redo: you haven't undone anything since your last change." or "You haven't changed anything here yet.") end
    local e = all[i]
    local what = redo and ("redo: " .. describe(all[i])) or ("undo: " .. describe(e))
    if reaper.MB(what:sub(1, 1):upper() .. what:sub(2) .. "?\n\nIt goes to everyone; nothing anyone else changed is touched.", "BandSync", 4) ~= 6 then return end
    local opts = { can = can, mode = who and who.mode, local_mix = select(2, reaper.GetProjExtState(proj, band.SECTION, "local_mix")) == "1" }
    if redo then opts.redoes = e.id else opts.undoes = e.id end
    local ok, res = pcall(mirror.revert, proj, cfg, b.song, b.room, mirror.plan_undo(all, i), opts)
    band.log(ok and res or ("undo failed: " .. tostring(res)))
    hist_at = 0
  end
  if arrow_button("##undo", false, "Undo your own last change, for everyone (it asks first). Unlike Ctrl+Z, a bandmate's change " ..
      "that came in since is never touched. Press again to go further back.") then undo_redo(false) end
  ImGui.SameLine(ctx, 0, 4); ImGui.SetCursorPosY(ctx, y0)
  if arrow_button("##redo", true, "Redo: bring back the change you undid last (for everyone).") then undo_redo(true) end
  if wide then -- the pages, in the bar
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_SelectableTextAlign, 0.5, 0.5)
    for i, p in ipairs(PAGES) do
      ImGui.SameLine(ctx, 0, i == 1 and 24 or 2)
      ImGui.SetCursorPosY(ctx, y0)
      nav_item(p, ImGui.CalcTextSize(ctx, p[1]) + 28, fh)
    end
    ImGui.PopStyleVar(ctx)
  end
  local docked = ImGui.IsWindowDocked(ctx)
  -- the window's own buttons sit at the right end of the bar (when they fit there), apart from the session's
  local labels = docked and { "Undock" } or { "Undock", "Exit full screen", "Window" }
  local need = 0
  for _, l in ipairs(labels) do need = need + ImGui.CalcTextSize(ctx, l) + 28 end
  ImGui.SameLine(ctx, 0, 8)
  local room = ImGui.GetContentRegionAvail(ctx)
  if room > need + 12 then ImGui.SetCursorPosX(ctx, ImGui.GetCursorPosX(ctx) + room - need); ImGui.SetCursorPosY(ctx, y0)
  else at_row("Undock") end
  -- Dock: left-click picks a side; right-click arms drag-to-dock (green) so moving the window around never docks it
  -- by accident (unarmed, dragging docks only with Shift held)
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
      if ImGui.Selectable(ctx, side[1]) then
        local found
        for i = 0, 15 do if reaper.DockGetPosition(i) == side[2] then found = i; break end end
        if found then dock_req = ~found -- (ReaImGui: dock id -1 is REAPER docker 0, -2 docker 1, ...)
        else
          dock_req = side[2] == 0 and -1 or -2
          band.msg("REAPER has no docker on the " .. side[1]:lower() .. " yet. BandSync is in a docker now: right-click its tab, " ..
            "Docker position, " .. side[1] .. ". REAPER remembers it.")
        end
      end
    end
    ImGui.EndPopup(ctx)
  end
  if not docked then
    at_row("Exit full screen")
    local full = placed_how == "Fill this screen"
    if ImGui.Button(ctx, full and "Exit full screen" or "Full screen") then place_window(full and "Back to before" or "Fill this screen") end
    ImGui.SetItemTooltip(ctx, full and "Back to where the window was." or "Fill the screen the panel is on (drag it to another screen first to use that one).")
    at_row("Window")
    if ImGui.Button(ctx, "Window") then
      local pick = band.pick(WINDOW_MENU)
      if pick then place_window(pick) end
    end
    ImGui.SetItemTooltip(ctx, "Fill the screen the panel is on, or half of it (left, right, top, bottom), and back.")
  end
  ImGui.SetCursorPos(ctx, 16, y0 + fh + 8)
  -- what BandSync just did, under the bar for a few seconds (actions used to report only to the Console)
  local newest = band.activity()[1]
  if newest ~= tools.toast_line then tools.toast_line, tools.toast_at = newest, tools.toast_seen and reaper.time_precise() or -math.huge end
  tools.toast_seen = true -- (opening the panel doesn't replay the old newest line)
  if newest and reaper.time_precise() - tools.toast_at < 6 then ImGui.TextColored(ctx, 0xBFD3FFFF, newest:sub(7)) end
  section_invites()
  local want = reaper.GetExtState(band.SECTION, "panel page") -- a page asked for from elsewhere (a new room opens on Rooms)
  if want ~= "" then reaper.DeleteExtState(band.SECTION, "panel page", false); page = OLD_PAGES[want] or want end
  if compact and not wide then
    ImGui.SetCursorPosX(ctx, 16)
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_SelectableTextAlign, 0.5, 0.5)
    for i, p in ipairs(PAGES) do
      if i > 1 then ImGui.SameLine(ctx, 0, 2) end
      nav_item(p, ImGui.CalcTextSize(ctx, p[1]) + 28, fh)
    end
    ImGui.PopStyleVar(ctx)
  end
  ImGui.Separator(ctx)
  if not compact then
    ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, NAV)
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, 8, 10)
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_SelectableTextAlign, 0, 0.5)
    if ImGui.BeginChild(ctx, "nav", 150, 0, ImGui.ChildFlags_AlwaysUseWindowPadding) then
      ImGui.PushFont(ctx, nil, 16)
      for _, p in ipairs(PAGES) do nav_item(p, 0, 36) end
      ImGui.PopFont(ctx)
      ImGui.EndChild(ctx)
    end
    ImGui.PopStyleVar(ctx, 2)
    ImGui.PopStyleColor(ctx)
    ImGui.SameLine(ctx, 0, 0)
  end
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, 16, 12)
  if ImGui.BeginChild(ctx, "page", 0, 0, ImGui.ChildFlags_AlwaysUseWindowPadding, wide and ImGui.WindowFlags_HorizontalScrollbar or 0) then
    ImGui.PushTextWrapPos(ctx, 0) -- text wraps to the page, whatever its width
    if not compact then heading(page, 20) end
    if page == "Home" then page_home()
    elseif page == "Rooms" then layout({ { rooms_squares, 560 }, { rooms_actions, 560 } })
    elseif page == "Play" then
      if wide then layout({ { section_together, 380 }, { function() section_live("mode") end, 420 }, { function() section_live("rest") end, 520 } })
      else layout({ { section_together, 380 }, { section_live, 480 } }) end
    elseif page == "Chat" then
      layout({ { function() require("page_chat").draw(ctx, ImGui, cfg, b) end, 560 }, { function() section_notes(); section_ideas() end, 420 } })
    elseif page == "History" then layout({ { section_recall, 400 }, { section_history, 600 } })
    elseif page == "Plugins" then
      layout({ { function() require("page_plugins").draw(ctx, ImGui, proj, cfg) end, 760 }, { section_plugins, 420 } })
    elseif page == "Setup" then page_setup() end
    ImGui.PopTextWrapPos(ctx)
    ImGui.EndChild(ctx)
  end
  ImGui.PopStyleVar(ctx)
end

local function frame()
  if reaper.time_precise() - last > 1.5 or reaper.EnumProjects(-1) ~= proj then
    last = reaper.time_precise()
    local ok, e = pcall(refresh)
    err = not ok and tostring(e) or nil
  end
  local app = not classic()
  if app then ImGui.SetCursorPosY(ctx, ImGui.GetCursorPosY(ctx) + 10); ImGui.Indent(ctx, 16) end -- (the app window has no padding of its own)
  if err then
    ImGui.TextColored(ctx, RED, "Something went wrong in the panel: " .. err)
    if ImGui.SmallButton(ctx, "Copy it") then ImGui.SetClipboardText(ctx, "BandSync " .. band.VERSION .. ": " .. err) end
    ImGui.SetItemTooltip(ctx, "Copy the message, to send it to whoever looks after BandSync.")
    ImGui.SameLine(ctx)
    if ImGui.SmallButton(ctx, "Try again") then err, last = nil, 0 end
    return
  end
  if not b then
    ImGui.TextWrapped(ctx, "This project isn't a BandSync session yet.")
    if ImGui.Button(ctx, "Publish this project (I'm the host)") then action("Publish session") end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Open a band session / room") then action("Open session") end
    if ImGui.Button(ctx, "Prepare this project for BandSync") then action("Prepare session") end
    ImGui.SetItemTooltip(ctx, "Before publishing a busy project: takes into lanes, FLAC recording, clear track names, media in the project folder, tidy-up. Shows a checklist first.")
    return
  end
  if not app then
    ImGui.Text(ctx, string.format("%s  ·  room %s  ·  %s  ·  you are %s", b.song, b.room, b.role, cfg.user))
  end
  if app then ImGui.Unindent(ctx, 16); return frame_app() end
  if ImGui.SmallButton(ctx, "Switch to the new look") then reaper.DeleteExtState(band.SECTION, "panel_ui", true) end
  section_invites()
  if ImGui.BeginTabBar(ctx, "tabs") then
    if ImGui.BeginTabItem(ctx, "Session") then
      section_room()
      section_setup()
      section_activity()
      section_sync()
      section_band()
      section_control()
      section_drums()
      section_plugins()
      section_actions()
      ImGui.EndTabItem(ctx)
    end
    -- a room you just made or went to opens on this tab (its panel is the new tab's: ExtState, so any panel sees it)
    local to_rooms = reaper.GetExtState(band.SECTION, "panel page") == "Rooms"
    if to_rooms then reaper.DeleteExtState(band.SECTION, "panel page", false) end
    if ImGui.BeginTabItem(ctx, "Rooms", nil, to_rooms and ImGui.TabItemFlags_SetSelected or ImGui.TabItemFlags_None) then
      section_rooms()
      ImGui.EndTabItem(ctx)
    end
    if ImGui.BeginTabItem(ctx, "Together") then
      section_together()
      section_notes()
      section_ideas()
      ImGui.EndTabItem(ctx)
    end
    if ImGui.BeginTabItem(ctx, "Live") then
      section_live()
      ImGui.EndTabItem(ctx)
    end
    if ImGui.BeginTabItem(ctx, "History & restore") then
      section_recall()
      section_history()
      ImGui.EndTabItem(ctx)
    end
    ImGui.EndTabBar(ctx)
  end
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
  ImGui.PushStyleColor(ctx, ImGui.Col_WindowBg, 0x2A2010FF)
  local f = ImGui.WindowFlags_NoDecoration | ImGui.WindowFlags_NoInputs | ImGui.WindowFlags_NoFocusOnAppearing | ImGui.WindowFlags_NoNav |
    ImGui.WindowFlags_NoDocking | ImGui.WindowFlags_AlwaysAutoResize | ImGui.WindowFlags_NoSavedSettings
  if ImGui.Begin(ctx, "BandSync banner", nil, f) then
    ImGui.TextColored(ctx, YELLOW, banner_text)
    ImGui.End(ctx)
  end
  ImGui.PopStyleColor(ctx)
  ImGui.PopStyleVar(ctx, 2)
end

-- Minimized: closing the panel leaves a small pill over REAPER (Live, who drives, new chat); a click brings the panel
-- back where it was (floating or docked). Drag it anywhere; right-click to close BandSync or remove the button.
-- Returns false when BandSync should close.
local function pill_window()
  local front = reaper.EnumProjects(-1)
  local fb = band.binding(front)
  local beat = tonumber(reaper.GetExtState(band.SECTION, "live " .. tostring(front)))
  local live_on = beat and reaper.time_precise() - beat < 5
  local unread = fb and require("page_chat").unread(cfg, fb) or 0
  local vx, vy = ImGui.Viewport_GetWorkPos(ImGui.GetMainViewport(ctx))
  local vw = ImGui.Viewport_GetWorkSize(ImGui.GetMainViewport(ctx))
  local px, py = tonumber(reaper.GetExtState(band.SECTION, "pill x")), tonumber(reaper.GetExtState(band.SECTION, "pill y"))
  ImGui.SetNextWindowPos(ctx, px or (vx + vw - 340), py or (vy + 64), ImGui.Cond_Appearing)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowRounding, 14)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, 8, 5)
  local keep = true
  local f = ImGui.WindowFlags_NoDecoration | ImGui.WindowFlags_AlwaysAutoResize | ImGui.WindowFlags_NoDocking |
    ImGui.WindowFlags_NoSavedSettings | ImGui.WindowFlags_NoFocusOnAppearing | ImGui.WindowFlags_NoNav
  if ImGui.Begin(ctx, "BandSync pill", nil, f) then
    local x, y = ImGui.GetWindowPos(ctx)
    if x ~= px or y ~= py then -- dragged (by its edge): remembered
      reaper.SetExtState(band.SECTION, "pill x", tostring(x), true); reaper.SetExtState(band.SECTION, "pill y", tostring(y), true)
    end
    dot(live_on and GREEN or RED)
    ImGui.SameLine(ctx, 0, 6)
    local label = "BandSync  ·  " .. (live_on and "Sync on" or "Sync off") .. (view and view.driver and ("  ·  " .. (view.driver == cfg.user and "you drive" or (view.driver .. " drives"))) or "") ..
      (unread > 0 and string.format("  ·  %d new message%s", unread, unread == 1 and "" or "s") or "")
    if ImGui.SmallButton(ctx, label .. "##pill") then reaper.DeleteExtState(band.SECTION, "panel minimized", false) end
    ImGui.SetItemTooltip(ctx, "Open the BandSync panel (right-click for more). Drag the pill's edge to move it.")
    if ImGui.BeginPopupContextItem(ctx, "pillmenu") then
      if ImGui.Selectable(ctx, "Open the panel") then reaper.DeleteExtState(band.SECTION, "panel minimized", false) end
      if ImGui.Selectable(ctx, "Close BandSync's panel") then keep = false end
      if ImGui.Selectable(ctx, "Remove this button (Setup > Options brings it back)") then reaper.SetExtState(band.SECTION, "pill", "off", true); keep = false end
      ImGui.EndPopup(ctx)
    end
    ImGui.End(ctx)
  end
  ImGui.PopStyleVar(ctx, 2)
  return keep
end

local function loop()
  if updated() or reload_now then -- reload in place: relaunching itself as an action is ignored (or asks to terminate instances)
    band.log("the panel reloaded for BandSync " .. tostring(seen_disk))
    restarting = true
    for _, f in ipairs(band.files(dir .. "/lib", ".lua")) do package.loaded[f:sub(1, -5)] = nil end
    return dofile(dir .. "/BandSync - Panel.lua")
  end
  ImGui.SetNextWindowSize(ctx, 560, 640, ImGui.Cond_FirstUseEver)
  local wx, wy = ImGui.Viewport_GetWorkPos(ImGui.GetMainViewport(ctx)) -- first time: inside REAPER, below its menus
  ImGui.SetNextWindowPos(ctx, wx + 60, wy + 90, ImGui.Cond_FirstUseEver)
  -- no collapse arrow: collapsed and opened again, the window came back tiny on macOS (dock it, or close it instead)
  local app = not classic() -- (read once: the Settings page can switch it mid-frame)
  if app then push_theme(); ImGui.PushFont(ctx, ui_font, 15) end
  -- (the app's pages scroll inside; the window itself never does, so the top bar stays put)
  local flags = ImGui.WindowFlags_NoCollapse | (app and (ImGui.WindowFlags_NoScrollbar | ImGui.WindowFlags_NoScrollWithMouse) or 0)
    | (native and ImGui.WindowFlags_NoTitleBar or 0) -- (the system frame has the title; docked, REAPER's tab does)
  if dock_req then ImGui.SetNextWindowDockID(ctx, dock_req); dock_req = nil end
  ImGui.SetConfigVar(ctx, ImGui.ConfigVar_DockingWithShift, reaper.GetExtState(band.SECTION, "dock armed") ~= "" and 0 or 1)
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
  else visible, open = ImGui.Begin(ctx, "BandSync", true, flags) end
  if visible then
    local wx, wy = ImGui.GetWindowPos(ctx)
    local ww, wh = ImGui.GetWindowSize(ctx)
    win_rect = { wx, wy, ww, wh }
    banner_docked = ImGui.IsWindowDocked(ctx)
    local ok, e = pcall(frame) -- an error in our logic must still reach End
    if not ok then err = tostring(e) end
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
      ImGui.PopClipRect(ctx)
    end
    ImGui.End(ctx)
  end
  if not minimized and not open and reaper.GetExtState(band.SECTION, "pill") ~= "off" then -- closed: minimized to the pill
    reaper.SetExtState(band.SECTION, "panel minimized", "1", false)
    open = true
  end
  if app then ImGui.PopFont(ctx); pop_theme() end
  banner()
  reaper.SetExtState(band.SECTION, "panel alive", tostring(reaper.time_precise()), false) -- (so Autostart never opens a second one)
  if open then reaper.defer(loop) end
end
reaper.defer(loop)
