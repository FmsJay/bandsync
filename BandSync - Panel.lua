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
local function classic() return reaper.GetExtState(band.SECTION, "panel_ui") == "classic" end
local theme = require("theme")
if classic() then theme.use("Dark") end -- (the classic panel is REAPER's plain ImGui, which is dark)
local GREEN, YELLOW, GREY, RED = theme.GREEN, theme.YELLOW, theme.GREY, theme.RED
local function rgba(c) local k = 255 * theme.STATUS; return math.floor(c[1] * k) << 24 | math.floor(c[2] * k) << 16 | math.floor(c[3] * k) << 8 | 0xFF end

-- ---- the app look: sidebar pages, cards, pills and switches (the default). The classic panel (tabs, plain
-- widgets) is the backup: "BandSync - Classic panel", or the switch on the Settings page. Same sections underneath.
local ui_font = ImGui.CreateFont("sans-serif")
ImGui.Attach(ctx, ui_font)
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
-- A small square button with a drawn curved arrow: undo points left, redo right. Returns clicked.
local function arrow_button(id, redo, tip)
  local dl = ImGui.GetWindowDrawList(ctx)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local s = ImGui.GetFrameHeight(ctx)
  local clicked = ImGui.InvisibleButton(ctx, id, s, s)
  local bg = ImGui.IsItemActive(ctx) and ACCENT or ImGui.IsItemHovered(ctx) and theme.BUTTON_HOVER or theme.BUTTON
  ImGui.DrawList_AddRectFilled(dl, x, y, x + s, y + s, bg, 6)
  -- drawn as points and mirrored for redo, so the two are exactly the same size; on whole pixels so neither blurs
  -- the usual undo icon: an arrowhead pointing left, a stem, and a half-circle hooking back underneath (redo: mirrored)
  local cx, cy, col = math.floor(x + s / 2 + 0.5), math.floor(y + s / 2 + 0.5), theme.TEXT
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
local open_cards = 0 -- (cards still open when a frame errors: closed before End, or End itself fails and the panel dies)
local function card(id, w, h)
  ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, CARD)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, 14, 12)
  local open = ImGui.BeginChild(ctx, id, w or 0, h or 0, (h and 0 or ImGui.ChildFlags_AutoResizeY) | ImGui.ChildFlags_AlwaysUseWindowPadding,
    ImGui.WindowFlags_NoScrollbar)
  ImGui.PopStyleVar(ctx)
  ImGui.PopStyleColor(ctx)
  if open then ImGui.PushTextWrapPos(ctx, 0); open_cards = open_cards + 1 end
  return open
end
local function card_end() ImGui.PopTextWrapPos(ctx); ImGui.EndChild(ctx); open_cards = open_cards - 1 end

-- The logo (James's idea): a sink dripping through a portal into another sink, drawn, so it's sharp at any size.
-- `s` = its height; it's 0.8 s wide. Drawn at the cursor, taking that space.
local function logo(s)
  local dl = ImGui.GetWindowDrawList(ctx)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local w = s * 0.8
  local cx = x + w / 2
  local steel, water, ring1, ring2 = theme.STEEL, 0x7CC4FFFF, ACCENT, 0x9B7BF2FF
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
-- The wordmark: KitchenSync, its "y" in the accent colour, standing in for the "i" of "Sink" too.
local function wordmark(size)
  ImGui.PushFont(ctx, nil, size)
  local y = ImGui.GetCursorPosY(ctx) -- (each piece on the same baseline: SameLine goes back to the line's top)
  ImGui.Text(ctx, "KitchenS")
  ImGui.SameLine(ctx, 0, 0)
  ImGui.SetCursorPosY(ctx, y)
  ImGui.TextColored(ctx, ACCENT, "y")
  ImGui.SameLine(ctx, 0, 0)
  ImGui.SetCursorPosY(ctx, y)
  ImGui.Text(ctx, "nc")
  ImGui.PopFont(ctx)
end
local ui = {} -- (what's new goes here: the panel's main chunk is at Lua's limit of 200 locals)
-- The panel as a small square over REAPER (pill_window), kept across restarts.
function ui.set_minimized(on)
  if on then reaper.SetExtState(band.SECTION, "panel minimized", "1", true)
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
  local h = reaper.JS_Window_Find and reaper.JS_Window_Find("KitchenSync", true)
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
local function next_to(label) -- (or a width: a box's isn't its words')
  ImGui.SameLine(ctx)
  if ImGui.GetContentRegionAvail(ctx) < (type(label) == "number" and label or ImGui.CalcTextSize(ctx, label) + 36) then ImGui.NewLine(ctx) end
end

-- Tooltips for controls that don't set their own, by label (a control's own tooltip, set after it, wins).
local TIPS = {
  ["Start"] = "Start Live sync in this tab: your takes and changes go out, the group's come in.",
  ["Update"] = "Get the newest KitchenSync through ReaPack.",
  ["Let in"] = "Add this machine to the group folder.",
  ["Take control"] = "Become the driver: your deletes, moves and lane choices reach everyone (except where someone has claimed).",
  ["Take control now"] = "The driver isn't here: carry on as the driver (they can take it back when they return).",
  ["Claim region"] = "Every take that starts in the region at the edit cursor becomes yours to change, whoever drives.",
  ["Release all claims"] = "Let go of all your claims: everything follows the driver again.",
  ["##label"] = "A name for this version, then Save this version.",
  ["Save this version"] = "Save how the session is now (takes, where they sit, what plays) as a version anyone can go back to.",
  ["Update the folder now"] = "Send your plug-in list and rebuild the FX browser folder 'BandSync (everyone has)' now.",
  ["##drummap"] = "The drum map this drum track uses: notes arriving in another kit's map are translated to it.",
  ["Play along (synced to the project)"] = "Hear each other in time with the project, at any distance (a bar or two late). Needs the group's NINJAM server.",
  ["Real time (SonoBus, lowest delay)"] = "Hear each other right away, peer to peer (best on wired internet, not too far apart).",
  ["Jam (NINJAM intervals)"] = "Classic NINJAM: everyone hears everyone one interval late.",
  ["Leave"] = "Leave: SonoBus stops (it stays on its track, sending nothing) or ReaNINJAM disconnects.",
  ["##server"] = "The host's Tailscale address and NINJAM port, e.g. 100.64.0.1:2049.",
  ["Save for the group"] = "Everyone's Connect uses this address.",
  ["##ninjamdir"] = "The folder holding ninjamsrv and bandsync.cfg (host only).",
  ["Use server folder"] = "Remember this NINJAM server folder (host only).",
  ["Send my audio (my whole mix)"] = "Off: you listen without sending anything.",
  ["Connect"] = "Join the group's live audio in the mode above.",
  ["Show it"] = "Open the live plug-in's window.",
  ["Open latest to look"] = "Open the newest Solo edit version to look at.",
  ["Check out"] = "Take a working copy to edit while the others are offline.",
  ["##soloroot"] = "Where Solo edit keeps its versions (usually the shared Google Drive folder).",
  ["Clear"] = "Empty this activity list.",
  ["Open the full console"] = "REAPER's script console, with everything KitchenSync has said.",
  ["start from"] = "Where everyone starts: the edit cursor or a region.",
  ["count-in bars"] = "Bars of count-in before the start point.",
  ["Play together"] = "Everyone running Live sync starts playing from the same point at the same moment (5 s after you click).",
  ["Stop together"] = "Everyone stops.",
  ["##note"] = "A note for the group: on the selected take, or at the cursor. Everyone sees it on the timeline and on the Restore page.",
  ["Note on selected take"] = "Post the note on the selected take (a take marker everyone sees).",
  ["Note at cursor"] = "Post the note at the edit cursor.",
  ["Like selected take"] = "Tell the group you like the selected take.",
  ["Take back my last take"] = "Remove your newest take for everyone (it waits in the room's trash).",
  ["Print selected MIDI as audio"] = "Render the selected MIDI through its instrument as an audio take everyone hears.",
  ["Insert bars"] = "Insert bars at the edit cursor on every machine (driver only).",
  ["Remove bars"] = "Remove bars at the edit cursor on every machine (driver only).",
  ["##newroom"] = "A name for a new side room.",
  ["Go"] = "Go to the room they're asking you to.",
  ["Not now"] = "Hide this invitation.",
  ["Share this project with the group"] = "Make this project a group project: you host it, and everyone joins it from their panel.",
  ["Join the group's project"] = "Open a project someone in the group started, in its own tab.",
  ["Prepare this project first"] = "A checklist for a busy project before starting a project from it (shows what it would change first).",
  ["Switch to the new look"] = "The app layout with a sidebar of pages.",
  ["Settings"] = "KitchenSync's settings: your name, the shared folder, how takes land.",
  ["Calibrate latency"] = "Measure how late recordings land (needs a cable from an output to an input).",
  ["Open another project"] = "Open another group project in a new tab.",
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
  ids[name] = ids[name] or reaper.AddRemoveReaScript(true, 0, dir .. "/BandSync - " .. name .. ".lua", true)
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
    elseif who.mode ~= "open" then
      -- (tracks you made and nobody has claimed are yours to change too, so "view only" wasn't true: sync.maker_may)
      local made = false
      for i = 0, reaper.CountTracks(proj) - 1 do
        local tr = reaper.GetTrack(proj, i)
        local name = sync.base_name(select(2, reaper.GetTrackName(tr)))
        made = made or (not who.tracks[name:lower()] and require("mirror").is_creator(require("mirror").track_oid(tr), cfg.user))
      end
      banner_text = (mine > 0 or made) and (view.driver .. " is driving: you can change what you've claimed or made.")
        or ("View only: " .. view.driver .. " is driving. Claim a track (KitchenSync, Home) to edit it.")
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
  if not running and band.synced_elsewhere(proj) then -- (a second copy of the song: syncing it would work on a stale one)
    ImGui.SameLine(ctx)
    ImGui.TextColored(ctx, YELLOW, "this project is open and syncing in another tab: work there")
  elseif not running then -- (no Stop: a BandSync project always syncs, or the band's copies drift apart)
    ImGui.SameLine(ctx)
    if ImGui.SmallButton(ctx, "Start") then reaper.DeleteExtState(band.SECTION, "stop " .. key, false); band.start_live(dir) end
  end
  if not tools.autostart_on() and not tools.autostart_tried then -- always on: BandSync projects start Live sync with REAPER
    tools.autostart_tried = true
    if not tools.set_autostart(true, dir) then band.log("couldn't add KitchenSync to Scripts/__startup.lua: Live sync won't start with REAPER") end
  end
  local hold = select(2, reaper.GetProjExtState(proj, band.SECTION, "hold")) ~= ""
  local changed, v = check("Hold my changes (try things; they go out once, when you switch this off)", hold)
  if changed then reaper.SetProjExtState(proj, band.SECTION, "hold", v and "1" or "") end
  ImGui.Text(ctx, string.format("Here: %d/%d takes%s", view.total - view.my_missing, view.total,
    view.my_missing > 0 and (", " .. view.my_missing .. " still arriving") or ""))
  if view.newer then
    -- already on disk (an update, or a bandmate's folder install)? Then only this running panel is old
    local disk = (band.read(dir .. "/lib/band.lua") or ""):match('VERSION = "([^"]+)"')
    if disk == view.newer then
      ImGui.TextColored(ctx, YELLOW, "KitchenSync " .. disk .. " is installed: close and reopen this panel to use it.")
    else
      ImGui.TextColored(ctx, YELLOW, "KitchenSync " .. view.newer .. " is in use here; you have " .. band.VERSION .. ".")
      ImGui.SameLine(ctx)
      if ImGui.SmallButton(ctx, "Update##banner") then action("Update") end -- "##": same label as More's Update, its own ID
    end
  end
end

local function section_band()
  ImGui.SeparatorText(ctx, "Collaborators")
  -- (machines asking to join: at the top of every page, tools.join_requests)
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
  { "driver", "Only the driver", "Only the driver changes what the group has. Everyone else's changes are put back (record as usual)." },
  { "claims", "Driver + claims", "The driver, and everyone on what they've claimed (a track, a region, a stretch of time). Other changes are put back." },
  { "open", "Anyone", "Anyone changes anything nobody has claimed, the tempo map and markers too. If two change one thing at once,\n" ..
    "whoever changed it more wins (the other's is on Restore)." },
}
local function section_driver()
  local driving = view.driver == cfg.user
  local mode, alone = who.mode or "claims", reaper.GetExtState(band.SECTION, "alone " .. tostring(proj)) ~= ""
  for i, m in ipairs(MODE_INFO) do
    if i > 1 then next_to(m[2]) end
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
    ImGui.TextColored(ctx, GREEN, "Nobody else is here: you have full control. Everything you change goes to the group, and reaches " ..
      "them when they're back. When someone joins, the rules above apply again.")
    ImGui.PopTextWrapPos(ctx)
  end
end
local function section_drive()
  ImGui.SeparatorText(ctx, "Google Drive")
  if reaper.time_precise() - drive_at > 30 then drive_at = reaper.time_precise(); drive_root = require("drive").root(cfg) end
  local off = reaper.GetExtState(band.SECTION, "drive_root") == "off"
  local dch, don = check("Keep the group's copy on Google Drive", drive_root ~= nil)
  if dch then reaper.SetExtState(band.SECTION, "drive_root", don and "" or "off", true); drive_at = -math.huge end
  ImGui.SetItemTooltip(ctx, drive_root and ("Each room is copied to " .. drive_root .. " (every few minutes, while stopped): what someone " ..
    "does alone reaches the group whenever they next open the project, and every end-of-session point is kept there.")
    or off and "Off on this machine." or "No Google Drive for desktop here (My Drive not found).")
  if drive_root then -- (which account's Drive it is, in view: with several signed in it matters; Mac, 0.34.5)
    ImGui.TextDisabled(ctx, "Copies to " .. (drive_root:match("GoogleDrive%-([^/]+)/") or drive_root:match("^(%a:)") or drive_root))
    ImGui.SetItemTooltip(ctx, drive_root)
  end
  local missing = not drive_root and not off and require("drive").missing
  if missing then
    ImGui.PushTextWrapPos(ctx, 0)
    ImGui.TextColored(ctx, YELLOW, "No BandSync folder in " .. missing .. ". On drive.google.com, find the group's BandSync folder " ..
      "(Shared with me), right-click > Organize > Add shortcut > My Drive, and keep the name BandSync. Starting a group? " ..
      "Make a folder called BandSync in My Drive and share it with everyone as Editor.")
    ImGui.PopTextWrapPos(ctx)
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
-- Take someone out of the group, for the driver or the song's host (lib/removal.lua). A minute to change your mind.
function ui.remove_button(p)
  if p.user == cfg.user then return end
  local removal = require("removal")
  local m = removal.mark(cfg.root, p.user)
  if m then
    ImGui.TextColored(ctx, YELLOW, string.format("Leaving the group in %d s", math.max(0, removal.GRACE - (os.time() - (tonumber(m.at) or 0)))))
    next_to("Keep them")
    if ImGui.SmallButton(ctx, "Keep them##" .. p.user) then removal.keep(cfg.root, p.user) end
    return ImGui.SetItemTooltip(ctx, "Changed your mind: nothing has happened yet.")
  end
  if not (view.driver == cfg.user or (view.session and view.session.host == cfg.user)) then return end
  if ImGui.SmallButton(ctx, "Remove##" .. p.user) and reaper.MB("Take " .. p.user .. " out of " .. tostring(view.group) .. "?\n\n" ..
      "Within a few minutes every computer in the group stops syncing with theirs. Their claims go free. What they made stays in the songs and on Restore.\n\n" ..
      "They keep the copy they already have: that can't be taken back. If they also have the group's Google Drive folder, remove them there too.\n\n" ..
      "You have a minute to change your mind, and you can invite them again later.", "KitchenSync", 4) == 6 then
    local ok, why = removal.remove(cfg.root, p.user, cfg.user)
    if ok then band.log(p.user .. " leaves the group in a minute: Keep them on their card stops it") else reaper.MB(why, "KitchenSync", 0) end
  end
  ImGui.SetItemTooltip(ctx, "Take them out of the group: every computer stops syncing with theirs.")
end
-- Under a person in Who's here (James, 2026-11-02): what they're working in or last worked in, opening to all they've claimed.
function ui.person_claims(user, last_track)
  local list = ui.claims_of(user)
  if #list == 0 and (last_track or "") == "" then return end
  local head = (last_track or "") ~= "" and ("Working in " .. last_track) or list[1].short
  if #list == 0 then return ImGui.TextDisabled(ctx, head) end
  head = head .. string.format("  (%d claim%s)", #list, #list == 1 and "" or "s")
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
local function section_claims(with_list)
  local owned = ui.claims_of()
  if with_list then -- (the classic panel: it has no Who's here to list them under)
    if #owned == 0 then ImGui.TextDisabled(ctx, "Nothing claimed: everything follows the driver.") end
    ui.claim_chips(owned)
  end
  if who.mode ~= "driver" and cfg.user ~= who.driver then -- (sync.maker_may: shown, or it looks like a hole in the claims)
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
          " has claimed, so it follows you (the driver) again? They're told when they're back, and can claim again.", "KitchenSync", 4) == 6 then
        sync.release_claims(cfg, b.song, b.room, who_)
        band.log("released " .. who_ .. "'s claims: what they had follows the driver now")
      end
      ImGui.SetItemTooltip(ctx, who_ .. " isn't here: their claims keep those parts locked for everyone until released.")
    end
  end
  if ImGui.Button(ctx, "Claim selected tracks") then
    local list = {}
    for i = 0, reaper.CountSelectedTracks(proj) - 1 do list[#list + 1] = part_name(reaper.GetSelectedTrack(proj, i)) end
    if #list == 0 then band.msg("Select the tracks you want to own first.") else claim(list, {}) end
  end
  ImGui.SetItemTooltip(ctx, "Only you can move, trim, delete or re-pick takes on them; everyone follows you there.")
  next_to("Claim region")
  if ImGui.Button(ctx, "Claim region") then
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
  next_to("Release all claims")
  if ImGui.Button(ctx, "Release all claims") and reaper.MB("Release all your claims (tracks, regions and time)? Everything you claimed follows the driver again.",
      "KitchenSync", 4) == 6 then
    local c = sync.my_claims(cfg, b.song, b.room) or {} -- (printing duties stay: "Stop printing them" lets those go)
    sync.set_claims(cfg, b.song, b.room, { tracks = {}, regions = {}, times = {}, prints = c.prints })
  end
end
local function section_control()
  ImGui.SeparatorText(ctx, "Edit settings")
  section_driver()
  section_claims(true)
  require("prints").printing_ui(ctx, ImGui, cfg, b, proj, who)
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
          "KitchenSync", 4) == 6 then
        band.log(mirror.revert(proj, cfg, b.song, b.room, mirror.plan_undo_moment(entries, i), opts)); hist_at = 0
      end
    end
    ImGui.EndDisabled(ctx)
    local together = #mirror.same_moment(entries, i)
    ImGui.SetItemTooltip(ctx, e and e.kind == "obj" and ((together > 1 and string.format("Undo this and the %d other change(s) made with it: ", together - 1) or "Undo only this change: ") ..
      describe(e) .. ". Everything else stays; the undo goes to the group as a new change.")
      or "This kind of change (tempo, a handover, a note) isn't undone on its own: restore the whole project to here instead.")
    next_to("Restore selected tracks to here")
  end
  if ImGui.SmallButton(ctx, "Restore selected tracks to here") then
    local scope = mirror.selection_scope(proj)
    if not scope then band.msg("Select the tracks to put back first (click their names in REAPER).")
    elseif reaper.MB("Put the selected tracks (their items and plug-ins) back to how they were " .. what .. "?\n\nEverything else stays as it is now.", "KitchenSync", 4) == 6 then
      band.log(mirror.revert(proj, cfg, b.song, b.room, mirror.plan_restore(entries, i, scope), opts)); hist_at = 0
    end
  end
  ImGui.SetItemTooltip(ctx, "The tracks selected in REAPER, as they were " .. what .. ". It goes to the group as new changes.")
  next_to("Restore whole project to here")
  local driving = view.driver == cfg.user
  ImGui.BeginDisabled(ctx, not driving)
  if ImGui.SmallButton(ctx, "Restore whole project to here") and reaper.MB("Make the whole project look like it did " .. what .. "?\n\n" ..
      "Everything since then is undone, for everyone. It's a change like any other, so you can come back the same way.", "KitchenSync", 4) == 6 then
    sync.restore_timeline(proj, cfg, b.song, b.room, entries, i, view.session)
    band.log(mirror.revert(proj, cfg, b.song, b.room, mirror.plan_restore(entries, i), opts))
    last, hist_at = 0, 0
  end
  ImGui.EndDisabled(ctx)
  ImGui.SetItemTooltip(ctx, driving and ("The whole project, as it was " .. what .. ". It goes to the group as new changes.") or "The driver does this.")
  next_to("Open in side room")
  if ImGui.SmallButton(ctx, "Open in side room") then
    -- a look at that moment that touches nobody's work: a new room, put back to then. Archive it (Rooms) when you've heard it.
    local name = "Check " .. os.date("%H%M%S")
    local p, why = require("rooms").create(proj, cfg, b, name)
    if not p then band.msg(why) else
      local room_can = sync.authority(cfg, b.song, name, view.session)
      local plan = mirror.plan_restore(entries, i)
      sync.restore_timeline(p, cfg, b.song, name, entries, i, view.session, b.room)
      band.log("'" .. name .. "' is the project as it was " .. what .. ": " .. tostring(mirror.revert(p, cfg, b.song, name, plan, { can = room_can, mode = "claims", exact = true })))
      local beat = tonumber(reaper.GetExtState(band.SECTION, "live " .. tostring(p)))
      if not (beat and reaper.time_precise() - beat < 5) then band.start_live(dir) end
      reaper.SetExtState(band.SECTION, "panel page", "Rooms", false)
    end
  end
  ImGui.SetItemTooltip(ctx, "Opens the project as it was " .. what .. " in a new side room, to check it's the right one. Nothing changes for anyone else.")
end
-- One change or saved version: its time and words, the whole line a button that opens its options under it. One open at a time.
function ui.change_row(key, time, words, i, what, single)
  local avail = ImGui.GetContentRegionAvail(ctx)
  local at = ImGui.CalcTextSize(ctx, time) + 8
  local _, h = ImGui.CalcTextSize(ctx, words, nil, nil, false, avail - at)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local open = hf.open == key
  if ImGui.Selectable(ctx, "##row", open, ImGui.SelectableFlags_None, avail, h) then hf.open, hf.show = not open and key or nil, true end
  ImGui.SetCursorScreenPos(ctx, x, y)
  ImGui.TextDisabled(ctx, time)
  ImGui.SameLine(ctx, 0, 8)
  ImGui.TextWrapped(ctx, words)
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
      ui.change_row(e.id or i, local_time(e.time), e.user .. ": " .. line, i, string.format("right after %s's change at %s", e.user, local_time(e.time)), true)
      ImGui.PopID(ctx)
    end
  end
  if n == 0 then ImGui.TextDisabled(ctx, "Nothing matches.") end
end
local function section_recall()
  ImGui.SeparatorText(ctx, "Saved versions")
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
    "Everyone's parts are in it, yours too. Only tracks that stay on this computer ('yours, not sent', KitchenSync's helpers) are left out. Nothing is added to the project.")
  ImGui.SameLine(ctx, 0, 4)
  if ImGui.SmallButton(ctx, "Back up") then recall.back_up(proj, cfg, b); last = 0 end
  ImGui.SetItemTooltip(ctx, "Keeps the project as it stands now: a saved version here that's never trimmed, and the project on Google Drive if you use it. No audio is rendered.")
  local driving = view.driver == cfg.user
  -- (docked, the list takes the column's height instead of a short box inside it)
  if ImGui.BeginChild(ctx, "points", 0, wide and math.max(110, select(2, ImGui.GetContentRegionAvail(ctx)) - 4) or 110, ImGui.ChildFlags_Borders) then
    if #points == 0 then ImGui.TextDisabled(ctx, "None yet. Every handover saves one by itself.") end
    local before = select(2, reaper.GetProjExtState(proj, band.SECTION, "before_bandsync"))
    if before ~= "" and reaper.file_exists(before) then
      if ImGui.SmallButton(ctx, "Open it as it was before BandSync") then reaper.Main_OnCommand(40859, 0); reaper.Main_openProject(before) end
      ImGui.SetItemTooltip(ctx, "Opens the copy saved when this project was first published, in a new tab (it isn't a group session).")
    end
    for i, p in ipairs(points) do
      ImGui.PushID(ctx, i)
      local upto = 0 -- (mirror sessions: the point is a moment in History)
      for k, e in ipairs(entries) do if (e.time or "") <= (p.time or "") then upto = k end end
      ui.change_row("version " .. i, local_time(p.time), string.format("%s%s  ·  %s  ·  %d takes", p.label, p.keep and " (kept)" or "", tostring(p.by), p.takes), upto, "at '" .. p.label .. "'")
      ImGui.PopID(ctx)
    end
    ImGui.EndChild(ctx)
  end
end

local function section_history()
  local warm, read, total = recall.warm(cfg, b.song, b.room, 0.01)
  if not warm then return ImGui.TextDisabled(ctx, string.format("Reading the history: %d of %d changes...", read, total)) end
  if reaper.time_precise() - hist_at > 4 then hist_at = reaper.time_precise(); refresh_history() end
  ImGui.SeparatorText(ctx, "Every change, newest first")
  ImGui.TextDisabled(ctx, "Click a change to undo it, restore to it, or open it in a side room.")
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
  local filtered = hf.who ~= "" or hf.kind ~= 1 or hf.track ~= "" or hf.text ~= ""
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
      local shown = {} -- (prints BandSync refreshed by itself are left out: no one made them)
      for i = g.first, g.last do if not entries[i].auto then shown[#shown + 1] = i end end
      if #shown == 0 then goto next_group end
      ImGui.PushID(ctx, gi)
      local n = #shown
      local who_ = g.user .. (g.solo and " (Solo edit)" or g.user == g.driver and " (driving)" or "")
      if n == 1 then -- (one change: the row itself, no list of one to open first)
        local i = shown[1]
        ui.change_row(entries[i].id or i, local_time(entries[i].time), who_ .. ": " .. describe(entries[i]) .. require("mirror").lane_words(entries, i), i,
          string.format("right after %s's change at %s", entries[i].user, local_time(entries[i].time)), true)
        ImGui.PopID(ctx)
        goto next_group
      end
      local head = string.format("%s  ·  %s%s", who_, local_time(g.from), g.from ~= g.to and ("-" .. local_time(g.to):sub(7)) or "")
      local open = ImGui.TreeNodeEx(ctx, "g", head, ImGui.TreeNodeFlags_SpanAvailWidth)
      if not open then -- what it was about, wrapped under the line that opens it
        ImGui.Indent(ctx)
        ImGui.TextDisabled(ctx, describe(entries[shown[#shown]]) .. (n > 1 and string.format("  (+%d more)", n - 1) or ""))
        ImGui.Unindent(ctx)
      end
      if open then
        for k = #shown, 1, -1 do -- (newest first, as the page says: opened, a group read the other way, and the wrong moment got restored)
          local i = shown[k]
          local moment, first = require("mirror").same_moment(entries, i), true
          for _, j in ipairs(moment) do if j > i then first = false end end -- (one row for one act, as in the filtered list)
          if first then
            ImGui.PushID(ctx, i)
            ui.change_row(entries[i].id or i, local_time(entries[i].time):sub(7), describe(entries[i]) .. require("mirror").lane_words(entries, i) .. (#moment > 1 and string.format(" (%d changes at that moment, undone together)", #moment) or ""),
              i, string.format("right after %s's change at %s", entries[i].user, local_time(entries[i].time)), true)
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

-- Drum map of the selected tracks. Changing it rewrites the BandSync MIDI on those tracks into the new map,
-- so the notes keep hitting the same drums with the new instrument.
-- Plug-ins everyone in the band has, as a folder in REAPER's FX browser (lib/plugins.lua).
local plugins = require("plugins")
local plug_info
local function section_plugins()
  heading("Plug-ins everyone has", 17)
  ImGui.PushTextWrapPos(ctx, 0)
  ImGui.TextDisabled(ctx, "Each machine sends the group its list of plug-ins (names only) when Live sync starts. What all of you have " ..
    "goes in the FX browser folder '" .. plugins.FOLDER .. "': use those and the project sounds the same on every machine. " ..
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
local LIVE_MODES = { { "synced", "Play along (synced to the project)" }, { "listen", "Real time (SonoBus, lowest delay)" }, { "jam", "Jam (NINJAM intervals)" } }

local setup = require("setup")

-- Real time: SonoBus joins the band's group by itself (BandSync writes it into SonoBus's state).
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
    band.log("Real time mode off: SonoBus left the group and side by side is off (edits still sync)")
  end
end
local SAME_ROOM_TIP = "Real time mode. On: SonoBus joins the group's group (you hear each other right away), and side by side\n" ..
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
      synced = "Play to the project; the others hear you in time with it, a bar or two behind you. What you play also shows up on their timeline as an idea until your real take arrives.",
      listen = "Hear each other right away, with no server to run. Best on wired internet, with collaborators not too far away; otherwise use Play along.",
      jam = "Everyone plays at once and hears the others one cycle late (classic NINJAM).",
    })[live_mode])
    ImGui.Spacing(ctx)
  end
  if part == "mode" then return end
  if same_room_on() then -- (my time / their time, a guest: moved here from Home)
    ImGui.SeparatorText(ctx, "Real time: how you hear the group")
    require("page_hear").realtime(ctx, ImGui, proj)
    ImGui.Spacing(ctx)
  end
  if live_mode == "listen" then
    local sm, si = live.fx(proj, false, live.SONOBUS)
    local on = sm and not reaper.TrackFX_GetOffline(sm, si)
    if ImGui.Button(ctx, on and "Open SonoBus##sb" or "Connect##sb") then sonobus_open() end
    ImGui.SetItemTooltip(ctx, "Turns on SonoBus on your master track, already set to join the group's group: it sends your mix and plays the group into it.")
    if on then
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, "Leave##sb") then reaper.TrackFX_SetOffline(sm, si, true) end
      ImGui.TextColored(ctx, GREEN, "SonoBus is on and in the group's group, until you Leave.")
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
  next_to("Save for the group")
  if ImGui.SmallButton(ctx, "Save for the group") then
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
    ImGui.SetItemTooltip(ctx, "NINJAM's own metronome ticks the whole time you're connected (at the server's tempo, not the project's).\n" ..
      "BandSync turns it off for Play along and Real time; this flips it if it's on anyway.")
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
  if reaper.time_precise() - setup_at > 5 then
    setup_at, st = reaper.time_precise(), setup.check(cfg, b, proj) -- tasklist is slow
    st.keys = #require("undo").keys_left(dir) == 0
  end
  local rows = {
    { st.audio, "Audio device is running", "REAPER's audio device is closed: pick one in Preferences > Audio > Device" },
    { st.folder, "Shared folder is syncing", "Syncthing isn't running" },
    { st.connected, st.peers and string.format("Connected to %d of %d collaborator machine(s)", st.peers, st.devices) or "Shared folder is a cloud drive",
      st.peers and "Syncthing is running but connected to nobody: is anyone else online? (If they are, this machine's Syncthing identity may have changed: check its device ID.)" or "Can't tell whether Syncthing is connected" },
    { st.sync, "Live sync is running", "Live sync is off" },
    { st.sonobus, "SonoBus is ready on the master track (Real time)", "SonoBus isn't on the master track" },
    { st.server, "Play along server address is set", b.role == "host" and "Play along server address not set (needs Tailscale signed in)" or "Waiting for the host to set the Play along server address" },
    { st.keys, require("undo").key_name() .. " never rolls back a collaborator's work", require("undo").key_name() .. " can roll back a collaborator's work: not set to KitchenSync's Undo yet" },
    { st.latency, "Recording latency checked", st.latency_ms and string.format("Recordings land %.1f ms off: fix the input offset and calibrate again", st.latency_ms) or "Recording latency not checked yet (needs a cable: Calibrate latency)" },
  }
  if b.role == "host" then table.insert(rows, 7, { st.ninjam, "NINJAM server is running here", "NINJAM server isn't running (set its folder on Play)" }) end
  local all, essential, left = true, st.audio and st.folder and st.connected and st.sync, 0
  for _, r in ipairs(rows) do all = all and r[1]; if not r[1] then left = left + 1 end end
  -- only what stops the band from syncing opens this by itself; extras (Real time, latency...) just count
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
      if not st.keys then
        ImGui.SameLine(ctx)
        if ImGui.Button(ctx, "Set " .. require("undo").key_name()) then require("undo").bind_keys(dir); setup_at = 0 end
        ImGui.SetItemTooltip(ctx, "With your own edit on top of REAPER's undo list it undoes that, as ever. With a collaborator's change on top, it undoes your own last change, not theirs.")
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
  if ImGui.Button(ctx, "Open another project") then reaper.SetExtState(band.SECTION, "open_other", "1", false); action("Open session") end
  ImGui.SetItemTooltip(ctx, "The project chooser: another project or room opens in a new tab (this one stays open, and keeps syncing).")
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
  local entered, t = ImGui.InputTextWithHint(ctx, "##note", "a note for the group, Enter to post (e.g. 'try the chorus an octave up')", note_text, ImGui.InputTextFlags_EnterReturnsTrue)
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
    -- (only notes: it read every change there is on the first click, 4500 files on Sunset Drive, and froze REAPER: James, 0.42.28)
    notes_at, notes = reaper.time_precise(), recall.notes(cfg, b.song, b.room)
  end
  if ImGui.BeginChild(ctx, "notes", 0, 90, ImGui.ChildFlags_Borders) then
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
  ImGui.SetItemTooltip(ctx, "The selected placeholders stay for good (no take replaces them). Send them with Send selected to main if the group should have them.")
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
  if not since then merge = { why = "This room has no start time (made with an older KitchenSync)." }; return end
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
      "They go to everyone there as new changes, so Restore there can undo them.", "KitchenSync", 4) == 6 then
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
  ImGui.SameLine(ctx)
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.TextDisabled(ctx, "Try ideas in a side room, then bring back what works. (?)")
  ImGui.SetItemTooltip(ctx, "Each room is its own project tab: click its square to go there. It opens once, then it's a tab switch, and it's still there next " ..
    "session.\n\nCreate side room: a copy of the room you're in, as it is now; you drive it. Try your own edits there, or work on " ..
    "something else.\n\nCome see: everyone with the project open is asked to join you.\n\nSend selected to main: the items you pick " ..
    "come over as new takes. Bring into main: everything changed in the side room comes over, except where main changed the same " ..
    "thing too (those stay as main has them); main's driver does this, and Restore can undo it.")
  local avail = ImGui.GetContentRegionAvail(ctx)
  local w, gap = 178, 8
  local per = math.max(1, math.floor((avail + gap) / (w + gap)))
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
      if here then ImGui.TextColored(ctx, GREEN, r.name .. "  (this tab)") else ImGui.Text(ctx, r.name) end
      ImGui.TextDisabled(ctx, r.parent and ("side room of " .. r.parent) or "the project")
      local people = room_view.people[r.name] or {}
      if #people == 0 then ImGui.TextDisabled(ctx, "nobody") end
      for _, p in ipairs(people) do
        if p.here then ImGui.TextColored(ctx, GREEN, p.user .. (p.me and " (you)" or ""))
        else ImGui.TextDisabled(ctx, p.user .. (p.me and " (you)" or "") .. ": tab open") end
      end
      if r.parent and not here then
        ImGui.BeginDisabled(ctx, #people > 0)
        if ImGui.SmallButton(ctx, "Archive") and reaper.MB("Take '" .. r.name .. "' off the list for everyone?\n\nNothing is deleted: it can be brought back from this page.", "KitchenSync", 4) == 6 then
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
  if ImGui.Button(ctx, "Open another project") then reaper.SetExtState(band.SECTION, "open_other", "1", false); action("Open session") end
  next_to("Come see")
  if ImGui.Button(ctx, "Come see") then
    rooms.invite(cfg, b.song, b.room)
    band.log("asked everyone to come and see '" .. b.room .. "'")
  end
  ImGui.SetItemTooltip(ctx, "Everyone with this project open gets 'come and see " .. b.room .. "' at the top of their panel, with a Go button.")
  if not parent then return end
  next_to("Send selected to " .. parent)
  if ImGui.Button(ctx, "Send selected to " .. parent) then
    local list = require("mirror").selected(proj, cfg, b.song, b.room, parent)
    local chosen = #list
    local refused
    list, refused = require("mirror").allowed_into(cfg, b.song, parent, list, view.session)
    if chosen == 0 then band.msg("Select the items to send first (they go to '" .. parent .. "' as they are here).")
    elseif #list == 0 then band.msg("None of those are yours to change in '" .. parent .. "': someone has claimed them, or " .. parent .. "'s driver owns them. Claim them there first.")
    elseif reaper.MB(string.format("Send the %d selected item(s) to '%s', as they are here? (Any of their tracks '%s' doesn't have yet go too.)",
        reaper.CountSelectedMediaItems(proj), parent, parent), "KitchenSync", 4) == 6 then
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

local function section_rooms() rooms_squares(); rooms_actions() end

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
local function layout(parts) -- { { fn, width } }
  if not wide then
    for _, part in ipairs(parts) do part[1]() end
    return
  end
  local _, h = ImGui.GetContentRegionAvail(ctx)
  for i, part in ipairs(parts) do
    if i > 1 then ImGui.SameLine(ctx, 0, 10) end
    ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, theme.COLUMN)
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
    { "folder", s.folder, "red", "Shared folder is syncing", "Syncthing isn't running: nothing reaches the group or comes in." },
    { "sync", s.sync, "red", "Live sync is running", "Live sync is off in this tab: press Start at the top." },
    { "same", (tonumber(reaper.GetExtState(band.SECTION, "mirror drift " .. tostring(proj))) or 0) == 0, "red", "Changes from the group come out the same here",
      "Some changes from the group came out different here than on their machine (the Console names them). Ask the driver to " ..
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
    { "server", s.server, "yellow", "Play along server address is set", b.role == "host" and "Play along server address not set (needs Tailscale signed in)."
      or "Waiting for the host to set the Play along server address." },
    (function() -- (an older REAPER can read a newer one's tracks and items differently: review item 33)
      local mine, other = reaper.GetAppVersion():match("^[%d%.]+"), {}
      for _, r in ipairs(view and view.rows or {}) do
        if r.reaper and r.reaper ~= mine then other[#other + 1] = r.name .. " " .. r.reaper end
      end
      return { "reaper", #other == 0, "yellow", "Everyone runs the same REAPER (" .. mine .. ")",
        "REAPER versions differ (you " .. mine .. "; " .. table.concat(other, ", ") .. "). Something made in a newer REAPER can come out " ..
        "different in an older one: the same version everywhere is safest." }
    end)(),
    (function() -- (only the classic look had this: a Mac bandmate never saw it. Mac, 0.42.27)
      local undo = require("undo")
      return { "keys", #undo.keys_left(dir) == 0, "yellow", undo.key_name() .. " never rolls back a collaborator's work",
        undo.key_name() .. " can roll back a collaborator's work: it isn't set to KitchenSync's Undo yet." }
    end)(),
    { "latency", s.latency, "yellow", "Recording latency checked", s.latency_ms and
      string.format("Recordings land %.1f ms off: fix the input offset and calibrate again.", s.latency_ms) or "Recording latency not checked yet (needs a cable: Calibrate latency below)." },
  }
  if b.role == "host" then table.insert(rows, 6, { "ninjam", s.ninjam, "yellow", "NINJAM server is running here", "NINJAM server isn't running (set its folder on the Play page)." }) end
  if view.newer then rows[#rows + 1] = { "update " .. view.newer, false, "yellow", "", "KitchenSync " .. view.newer .. " is in use in the group; you have " .. band.VERSION .. ": press Update below." } end
  local dmiss = reaper.GetExtState(band.SECTION, "drive_root") ~= "off" and require("drive").missing
  if dmiss then rows[#rows + 1] = { "drive", false, "yellow", "", "Google Drive: no shared BandSync folder in " .. dmiss .. " (at drive.google.com: Shared with me > right-click BandSync > Organize > Add shortcut > My Drive)." } end
  for _, m in ipairs(s.routed or {}) do
    rows[#rows + 1] = { "routed " .. m.track, false, "yellow", "", string.format("'%s' plays %s on '%s', which doesn't load on this computer: " ..
      "you hear the group's print (the wet take) where there is one, and nothing where there isn't. Installing %s brings the notes back here.",
      m.track, m.fx, m.dest, m.fx) }
  end
  local daway = reaper.GetExtState(band.SECTION, "drive_root") ~= "off" and require("drive").away
  if daway then
    local who = daway:match("GoogleDrive%-([^/]+)/") or daway:match("^(%a:)")
    rows[#rows + 1] = { "drive away", false, "yellow", "", "Google Drive: the group's folder (" .. tostring(who) .. ") isn't here now. Is that Google " ..
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
    heading("Set up and health", 17)
    for _, r in ipairs(maint_rows()) do
      local ok = r[2]
      if ok or r[3] == "red" or not gone[r[1]] then
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
  require("page_hear").fit(ctx, ImGui, "Configure SonoBus") -- (beside, or below in a narrow column: it was cut to "Configure Sono")
  if ImGui.SmallButton(ctx, "Configure SonoBus") then sonobus_open() end
  ImGui.SetItemTooltip(ctx, "Opens SonoBus's own window (volume and mute per collaborator, buffer, quality). You don't need it to play together.")
  if not wide then
    ImGui.TextDisabled(ctx, on and "You hear everyone live, and play, stop and record follow whoever presses them (Play: my time or theirs, a guest)."
      or "Off: changes still sync, but you don't hear each other live or follow each other's play and stop.")
  end
end
local function home_who()
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
    band.log("an invitation is on your clipboard: paste it to your collaborator (a message, an email). It installs KitchenSync " ..
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
  if wide then
    for _, p in ipairs(people) do
      dot(p.state == "here" and GREEN or rgba(status.COLORS[p.state] or { 0.55, 0.55, 0.55 }))
      ImGui.SameLine(ctx, 0, 4)
      ImGui.Text(ctx, p.name)
      ImGui.SetItemTooltip(ctx, p.state .. (p.armed and #p.armed > 0 and (", armed: " .. table.concat(p.armed, ", ")) or ", nothing armed") ..
        (p.version and p.version ~= band.VERSION and (", KitchenSync " .. p.version) or ""))
      if p.recording then ImGui.SameLine(ctx, 0, 6); pill("recording", RED) elseif p.driving then ImGui.SameLine(ctx, 0, 6); pill("driving", YELLOW) end
      if p.state == "syncing" then ImGui.SameLine(ctx, 0, 6); ImGui.TextColored(ctx, YELLOW, "getting changes") end -- (the bar just says "Sending")
      if p.mirror and view.my_mirror and p.state == "synced" then -- (as on the cards: the docked list said nothing, match or not)
        ImGui.SameLine(ctx, 0, 6)
        if p.mirror == view.my_mirror then ImGui.TextColored(ctx, GREEN, "same project")
        elseif settled_apart(p, view.my_mirror) then ImGui.TextColored(ctx, RED, "project differs")
        else ImGui.TextDisabled(ctx, "settling") end
      end
      if p.state ~= "here" and p.state ~= "offline" then ImGui.SameLine(ctx, 0, 6); tools.follow_button(p.name) end
      if p.state ~= "here" then pcall(function() require("page_hear").person(ctx, ImGui, proj, p.name) end) end -- (hear them live or not)
      ui.person_claims(p.user, p.last_track)
      ui.remove_button(p)
    end
    if #view.rows == 0 then ImGui.TextDisabled(ctx, "Nobody else has synced in this room yet.") end
    return home_play()
  end
  local avail = ImGui.GetContentRegionAvail(ctx)
  local w, gap = 214, 8
  local per = math.max(1, math.floor((avail + gap) / (w + gap)))
  w = math.floor((avail - gap * (per - 1)) / per) -- (they fill the page: a strip was left empty on the right)
  for i, p in ipairs(people) do
    if (i - 1) % per ~= 0 then ImGui.SameLine(ctx, 0, gap) end
    if card("who " .. p.name, w) then -- (grows with what they have armed)
      ImGui.PushFont(ctx, nil, 16)
      ImGui.Text(ctx, p.name)
      ImGui.PopFont(ctx)
      pill(p.state == "syncing" and "getting changes" or p.state, p.state == "here" and GREEN or rgba(status.COLORS[p.state] or { 0.55, 0.55, 0.55 }))
      ImGui.SetItemTooltip(ctx, ({ here = "This machine.", ["synced"] = "Has every change.", ["syncing"] = "Still getting changes (yours or the group's).",
        offline = "Not seen for over a minute.", ["no receipt"] = "Has sent takes, but never ran Live sync here." })[p.state] or p.state)
      if p.recording then ImGui.SameLine(ctx, 0, 4); pill("recording", RED)
      elseif p.playing and p.state ~= "offline" then ImGui.SameLine(ctx, 0, 4); pill("playing", ACCENT, 0xFFFFFFFF) end
      if p.driving then ImGui.SameLine(ctx, 0, 4); pill("driving", YELLOW); ImGui.SetItemTooltip(ctx, "What nobody has claimed follows them.") end
      ImGui.TextDisabled(ctx, p.armed and #p.armed > 0 and ("armed: " .. table.concat(p.armed, ", ")) or "nothing armed")
      if p.version and p.version ~= band.VERSION then ImGui.TextColored(ctx, YELLOW, "KitchenSync " .. p.version) end
      if p.mirror and view.my_mirror and p.state == "synced" then -- (while changes are still on their way it's bound to differ)
        if view.driver == cfg.user and p.state ~= "offline" and p.name ~= cfg.user then
          if ImGui.SmallButton(ctx, "Hand over##" .. p.name) and reaper.MB("Make " .. p.name .. " the driver?", "KitchenSync", 4) == 6 then
            sync.hand_over(proj, cfg, b.song, b.room, p.name); last = 0
          end
          ImGui.SetItemTooltip(ctx, "Make them the driver: what nobody has claimed then follows them.")
        end
        if p.mirror == view.my_mirror then ImGui.TextColored(ctx, GREEN, "same project as yours")
        elseif not settled_apart(p, view.my_mirror) then ImGui.TextDisabled(ctx, "settling")
        else ImGui.TextColored(ctx, RED, "project differs from yours"); ImGui.SetItemTooltip(ctx, "They have every change, yet their project isn't the same as yours: " ..
          "Setup > Health says more, and the Console names what came out different.") end
      end
      if p.state ~= "here" and p.state ~= "offline" then tools.follow_button(p.name) end
      if p.state ~= "here" then pcall(function() require("page_hear").person(ctx, ImGui, proj, p.name) end) end -- (hear them live or not)
      ui.person_claims(p.user, p.last_track)
      ui.remove_button(p)
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
  if ch and v then reaper.SetProjExtState(proj, band.SECTION, "local_mix", "1"); require("mirror").begin_local_mix(proj)
  elseif ch then
    -- (named choices: as Yes/No, "No" sent your faders and pan to every bandmate: review, 2026-10-31)
    local take, send = "Use the group's mix (your faders and pan follow theirs again)", "Send my faders and pan to everyone (the tracks I may change)"
    local r = band.pick({ "#Local mixing off: whose mix?", take, send, "Cancel (keep Local mixing on)" })
    if r == take or r == send then
      require("mirror").end_local_mix(proj, cfg, b.song, b.room, r == take)
      reaper.SetProjExtState(proj, band.SECTION, "local_mix", "")
    end
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
  if wide then layout({ { home_who, 300 }, { home_rules, 420 }, { home_claims, 420 } })
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
        reaper.SetExtState(band.SECTION, "panel page", "Setup", false); reaper.SetExtState(band.SECTION, "setup tab", "Options", false)
        reload_now = true
      end
    end
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
    ImGui.SeparatorText(ctx, "MIDI and audio play as")
    local prints = require("prints")
    for _, m in ipairs({ { "auto", "Auto", "The dry take (the notes, through your instruments) when the track's plug-ins all load here, else the wet one." },
        { "notes", "Dry", "Always the dry take: the notes through your own instruments, so you can change the sound." },
        { "sound", "Wet", "Always the wet take: the sound the group printed, exactly what whoever played it heard." } }) do
      if m[1] ~= "auto" then ImGui.SameLine(ctx) end
      if ImGui.RadioButton(ctx, m[2] .. "##midiplays", prints.mode() == m[1]) then
        reaper.SetExtState(band.SECTION, "midi_plays", m[1], true)
        for i = 0, reaper.CountMediaItems(proj) - 1 do prints.choose(reaper.GetMediaItem(proj, i)) end
      end
      ImGui.SetItemTooltip(ctx, m[3])
    end
    prints.options(ctx, ImGui) -- rendering in the background
    require("midiview").options(ctx, ImGui)
    require("people").options(ctx, ImGui, cfg) -- your colour, and whose colours tracks show here
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
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, "You're " .. cfg.user)
    ImGui.SameLine(ctx)
    if ImGui.SmallButton(ctx, "Change name") then
      local ok, name = reaper.GetUserInputs("KitchenSync: your name", 1, "Your name (collaborators see it),extrawidth=120", cfg.user)
      name = ok and band.clean(name) or ""
      if name ~= "" and name ~= cfg.user then
        reaper.SetExtState(band.SECTION, "user", name, true)
        band.rename(cfg.root, cfg.user, name)
        cfg.user = name
      end
    end
    ImGui.SetItemTooltip(ctx, "Your name in KitchenSync, everywhere (Who's here, claims, who drives). Your tracks stay yours, and\n" ..
      "the group's machines learn the new name. Changes you made before keep the old one in Restore.")
    section_drums()
    card_end()
  end
end

-- What most people never need: Hold my changes causes more clashes than it saves, and prints happen by themselves.
function ui.settings_advanced()
  if card("advanced") then
    heading("Advanced", 17)
    local hold = select(2, reaper.GetProjExtState(proj, band.SECTION, "hold")) ~= ""
    local ch, v = switch_row("##hold", "Hold my changes", hold, "Try things: your changes go out once, when you switch this off. Anything someone else changes on the same parts meanwhile clashes with yours.")
    if ch then reaper.SetProjExtState(proj, band.SECTION, "hold", v and "1" or "") end
    require("prints").printing_ui(ctx, ImGui, cfg, b, proj, who)
    card_end()
  end
end
local function page_setup()
  if not ImGui.BeginTabBar(ctx, "setup", ImGui.TabBarFlags_FittingPolicyScroll) then return end -- (scrolls when narrow: squeezed, the names read "Hea... Con...")
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
  if ImGui.BeginTabItem(ctx, "Advanced") then layout({ { ui.settings_advanced, 460 } }); ImGui.EndTabItem(ctx) end
  local to_options = reaper.GetExtState(band.SECTION, "setup tab") == "Options"
  if to_options then reaper.DeleteExtState(band.SECTION, "setup tab", false) end
  if ImGui.BeginTabItem(ctx, "Options", nil, to_options and ImGui.TabItemFlags_SetSelected or 0) then
    -- (Songs: inline, the panel's main chunk is near Lua's 200-locals limit) per-song sync, lib/songsync.lua
    layout({ { settings_look, 320 }, { settings_sync, 420 }, { function()
  if card("bands") then -- (each band its own shared folder: docs/bands-design.md)
    heading("Groups", 17)
    local here = band.info(cfg.root)
    ImGui.TextWrapped(ctx, "You're working in " .. here.name .. ".")
    ImGui.SetItemTooltip(ctx, (cfg.base or cfg).root)
    for _, x in ipairs(band.bands()) do
      if x.root ~= (cfg.base or cfg).root then
        if ImGui.SmallButton(ctx, "Switch to##group" .. x.root) then
          band.use_band(x.root); cfg = band.settings(); drive_at = -math.huge
          band.log("working in " .. x.name .. " now: its projects, plug-ins and collaborators")
        end
        ImGui.SameLine(ctx)
        ImGui.Text(ctx, x.name)
        ImGui.SetItemTooltip(ctx, x.root)
      end
    end
    if ImGui.Button(ctx, "Start a group") then
      local ok, name = reaper.GetUserInputs("KitchenSync: start a group", 1, "Group name,extrawidth=120", "")
      if ok and name ~= "" then
        local root, why = require("services").new_band(cfg, name)
        if root then
          cfg = band.settings(); drive_at = -math.huge
          band.log("started the group " .. band.info(root).name .. " in " .. root)
          band.msg("You're working in " .. band.info(root).name .. " now: its own projects, plug-ins and collaborators, shared with nobody yet.\n\n" ..
            "Open a project and Share a project with the group from it, then Invite a collaborator (Home) to bring people in. Switch groups in Setup > Options.")
        else band.msg(tostring(why)) end
      end
    end
    ImGui.SetItemTooltip(ctx, "A group of its own (another group of people): its own shared folder, projects, plug-ins and Drive copy.\n" ..
      "Nobody in your other groups sees it.")
    card_end()
  end
end, 360 }, { settings_drive, 360 }, { function()
  if card("songs") then
    heading("Projects on this computer", 17)
    local ss = require("songsync")
    local all = ss.keep_all()
    local ch, v = check("Keep every project on this computer", all)
    if ch then reaper.SetExtState(band.SECTION, "projects keep all", v and "1" or "", true); ss.apply(cfg) end
    ImGui.SetItemTooltip(ctx, "On: every group project comes here in full (the computer that stays on, so new collaborators always have a source).\n" ..
      "Off: every project's listing comes, and a project in full once you open it here.")
    if not all then
      local list, wanted = band.songs(cfg), ss.wanted(cfg)
      local n = 0
      for _, s in ipairs(list) do if wanted[s] then n = n + 1 end end
      ImGui.TextDisabled(ctx, string.format("%d of %d projects in full here; the rest come when you open them.", n, #list))
      for _, s in ipairs(list) do
        if wanted[s] and s ~= (b and b.song) then
          if ImGui.SmallButton(ctx, "Stop downloading##ss" .. s) and reaper.MB("Stop downloading '" .. s .. "' to this computer?\n\n" ..
              "Its files stay here (remove them yourself to free the space), and it comes back in full when you open it again. " ..
              "Nothing changes for the group.", "KitchenSync", 4) == 6 then ss.drop(cfg, s) end
          ImGui.SameLine(ctx)
          ImGui.Text(ctx, s)
        end
      end
    end
    card_end()
  end
end, 360 }, { settings_more, 400 } })
    ImGui.EndTabItem(ctx)
  end
  if ImGui.BeginTabItem(ctx, "Updates") then maint_upkeep(); ImGui.EndTabItem(ctx) end
  ImGui.EndTabBar(ctx)
end

local PAGES = {
  { "Home", "Who's here and what they're doing, real time mode, and who changes what." },
  { "Rooms", "The project's rooms: make a side room to try things, have everyone come and see, and bring work back." },
  { "Play", "Play or record together, follow each other, and how you hear each other (real time, play along or jam)." },
  { "Chat", "Messages, to-dos, notes and links for this room, this project or the whole group." },
  { "Restore", "Every change, and three ways back: the whole project, the selected tracks, or one change." },
  { "Plugins", "Every plug-in in this project, who doesn't have it, and the group's translations for it." },
  { "Setup", "Health (red: needs fixing, yellow: worth a look), the console, options and updates." },
}
local OLD_PAGES = { History = "Restore", Together = "Play", Live = "Play", Settings = "Setup", Maintenance = "Setup" } -- (links from older versions)
local page = "Home"
local level, level_at = nil, -math.huge
local function nav_dot(p)
  if p == "Setup" and level then return level == "red" and RED or YELLOW end
end
-- The Dock button: left-click picks a side; right-click arms drag-to-dock (green) so moving the window around never
-- docks it by accident (unarmed, dragging docks only with Shift held). On the session's top bar and the start screen.
-- Follow a bandmate's view (lib/presence.lua): Live sync moves this arrange view to theirs, a few seconds behind.
tools.follow_button = function(name)
  local key = "follow " .. tostring(proj)
  local on = reaper.GetExtState(band.SECTION, key) == name
  if ImGui.SmallButton(ctx, (on and "Following" or "Follow") .. "##follow" .. name) then
    if on then reaper.DeleteExtState(band.SECTION, key, false) else reaper.SetExtState(band.SECTION, key, name, false) end
  end
  ImGui.SetItemTooltip(ctx, on and ("Your view follows " .. name .. "'s (a few seconds behind). Click to stop.")
    or ("Keep your view where " .. name .. "'s is: scroll and zoom follow theirs, a few seconds behind."))
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
      if ImGui.Selectable(ctx, side[1]) then
        local found
        for i = 0, 15 do if reaper.DockGetPosition(i) == side[2] then found = i; break end end
        if found then dock_req = ~found -- (ReaImGui: dock id -1 is REAPER docker 0, -2 docker 1, ...)
        else -- no docker on that side yet: an empty one goes there (it was a message about right-clicking a tab nobody could find)
          local free = require("tools").free_docker()
          dock_req = ~free
          dock_side = { docker = free, action = side[2] == 1 and 41599 or 41601, since = reaper.time_precise() } -- Docker: Show in left / right of main window
        end
      end
    end
    ImGui.EndPopup(ctx)
  end
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
    ImGui.SetItemTooltip(ctx, p[2] .. (c and (level == "red" and "\n\nSomething needs fixing before the group can sync: open it to see what."
      or "\n\nSomething is worth a look (or an extra isn't set up): open it to see, or dismiss it there.") or ""))
    if c then
      local iw = ImGui.GetItemRectSize(ctx)
      ImGui.DrawList_AddCircleFilled(ImGui.GetWindowDrawList(ctx), x + iw - 10, y + h / 2, 4.5, c)
    end
    if p[1] == page and not compact then ImGui.DrawList_AddRectFilled(ImGui.GetWindowDrawList(ctx), x - 8, y + 6, x - 4, y + h - 6, ACCENT, 2) end
  end
  local y0 = ImGui.GetCursorPosY(ctx) + 8
  ImGui.SetCursorPos(ctx, 16, y0)
  pill(view.group or "", theme.PILL_GROUP, theme.PILL_TEXT, fh)
  ImGui.SetItemTooltip(ctx, "The group this project belongs to (Setup > Options: switch groups).")
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
  at_row(b.song); pill(b.song, theme.PILL_PROJECT, theme.PILL_TEXT, fh)
  ImGui.SetItemTooltip(ctx, "The project in this tab.")
  at_row(b.room); pill(b.room, theme.PILL_ROOM, theme.PILL_TEXT, fh)
  ImGui.SetItemTooltip(ctx, "The room this tab is in (Rooms page: side rooms).")
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
    elseif online == 0 then label, colour = "Sync on (nobody else here)", GREEN
    else label, colour = "In sync", GREEN end
    tip = "Live sync is running in this tab: your takes and changes go out, the group's come in." .. (#lines > 0 and ("\n\n" .. table.concat(lines, "\n")) or "")
  end
  at_row(label); pill(label, colour, DARK, fh)
  ImGui.SetItemTooltip(ctx, tip)
  if select(2, reaper.GetProjExtState(proj, band.SECTION, "hold")) ~= "" then -- (Hold my changes was invisible once on: review)
    local n = tonumber(reaper.GetExtState(band.SECTION, "held " .. key)) or 0
    local held = n > 0 and string.format("Holding %d change%s", n, n == 1 and "" or "s") or "Holding your changes"
    at_row(held); pill(held, YELLOW, DARK, fh)
    ImGui.SetItemTooltip(ctx, "Hold my changes is on: what you change stays here until you send it.")
    at_row("Send now")
    if ImGui.SmallButton(ctx, "Send now##hold") then reaper.SetProjExtState(proj, band.SECTION, "hold", "") end
    ImGui.SetItemTooltip(ctx, "Switch Hold my changes off: everything you changed goes to the group.")
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
  if not running and band.synced_elsewhere(proj) then -- (a second copy of the song: syncing it would work on a stale one)
    at_row("open in another tab")
    pill("open in another tab", YELLOW, DARK, fh)
    ImGui.SetItemTooltip(ctx, "This project is already open and syncing in another tab: work there. This tab is a second copy, not synced.")
  elseif not running then -- (Stop is in Settings: nobody needs it at hand, and it sat next to buttons people do press)
    at_row("Start")
    if ImGui.Button(ctx, "Start") then reaper.DeleteExtState(band.SECTION, "stop " .. key, false); band.start_live(dir) end
  end
  local drives = view.driver == cfg.user and "you drive" or view.driver and (view.driver .. " drives") or "nobody drives yet"
  at_row(drives); ImGui.AlignTextToFramePadding(ctx)
  ImGui.TextDisabled(ctx, drives)
  ImGui.SetItemTooltip(ctx, "The driver's changes go to everyone, except on what someone has claimed.")
  at_row("Undo")
  -- your own changes only, for everyone (a bandmate's change since is never touched, unlike Ctrl+Z); each asks first,
  -- naming the change. Read from History's events on click (not every frame).
  local function undo_redo(redo) -- (lib/undo.lua: the same as the BandSync - Undo / Redo actions, but always asks)
    local res, why = require("undo").step(proj, cfg, b, redo, { ask = true, describe = describe })
    if res then band.log(res) elseif why then band.msg(why) end
    hist_at = 0
  end
  if arrow_button("##undo", false, "Undo your own last change, for everyone (it asks first, and says if a collaborator changed the same " ..
      "thing since). Press again to go further back.") then undo_redo(false) end
  ImGui.SameLine(ctx, 0, 4); ImGui.SetCursorPosY(ctx, y0)
  if arrow_button("##redo", true, "Redo: bring back the change you undid last (for everyone).") then undo_redo(true) end
  if wide then -- the pages, in the bar
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_SelectableTextAlign, 0.5, 0.5)
    for i, p in ipairs(PAGES) do
      ImGui.SameLine(ctx, 0, i == 1 and 24 or 2)
      -- (they stay put: going by the status beside them, they slid when "In sync" became "Receiving 13", under the mouse)
      if i == 1 then tabs_at = math.max(tabs_at, ImGui.GetCursorPosX(ctx)); ImGui.SetCursorPosX(ctx, tabs_at) end
      ImGui.SetCursorPosY(ctx, y0)
      nav_item(p, ImGui.CalcTextSize(ctx, p[1]) + 28, fh)
    end
    ImGui.PopStyleVar(ctx)
  end
  local docked = ImGui.IsWindowDocked(ctx)
  -- the window's own buttons sit at the right end of the bar (when they fit there), apart from the session's
  local bar_min = docked or native -- (no title bar of ours to put it on: else it sits by the close button)
  local labels = docked and { "Undock", "Minimize" } or { "Undock", "Exit full screen", "Window", bar_min and "Minimize" or nil }
  local need = 0
  for _, l in ipairs(labels) do need = need + ImGui.CalcTextSize(ctx, l) + 28 end
  ImGui.SameLine(ctx, 0, 8)
  local room = ImGui.GetContentRegionAvail(ctx)
  if room > need + 12 then ImGui.SetCursorPosX(ctx, ImGui.GetCursorPosX(ctx) + room - need); ImGui.SetCursorPosY(ctx, y0)
  else at_row("Undock") end
  tools.dock_menu(docked)
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
  if bar_min then
    at_row("Minimize")
    if ImGui.Button(ctx, "Minimize") then ui.set_minimized(true) end
    ImGui.SetItemTooltip(ctx, "Shrink the panel to a small square over REAPER. Click the square and the panel opens where it was.")
  end
  ImGui.SetCursorPos(ctx, 16, y0 + fh + 8)
  -- what BandSync just did, under the bar for a few seconds (actions used to report only to the Console)
  local log = band.activity()
  local newest = log[1]
  if newest ~= tools.toast_newest then
    local before = tools.toast_newest
    tools.toast_newest = newest
    -- (a routine count doesn't push out what's being said: a first comp's warning lasted an instant, Mac 0.42.27. Both can arrive
    -- between two frames, the count on top, so this looks through all that's new: Mac, 0.45.0)
    local routine = function(l) return l:find("change(s) went to the group", 1, true) end
    local say = newest
    for _, l in ipairs(log) do
      if l == before then break end
      if not routine(l) then say = l; break end
    end
    local saying = tools.toast_at and reaper.time_precise() - tools.toast_at < 6
    if not (saying and say and routine(say)) then
      tools.toast_line, tools.toast_at = say, tools.toast_seen and reaper.time_precise() or -math.huge
    end
  end
  tools.toast_seen = true -- (opening the panel doesn't replay the old newest line)
  -- (the line keeps its height when it clears: what's under it mustn't jump as you go to click it)
  if tools.toast_line and reaper.time_precise() - tools.toast_at < 6 then ImGui.TextColored(ctx, theme.TOAST, tools.toast_line:sub(7)) else ImGui.Dummy(ctx, 0, ImGui.GetTextLineHeight(ctx)) end
  tools.removed_bar(ctx, ImGui)
  section_invites()
  tools.join_requests(ctx, ImGui, b) -- (someone asking to join the band folder)
  if b and can then -- (an edit touching a claim, before the rest: lib/suggest.lua)
    require("suggest").bar(ctx, ImGui, proj, cfg, sync.room_dir(cfg, b.song, b.room), can, select(2, reaper.GetProjExtState(proj, band.SECTION, "local_mix")) == "1")
  end
  tools.put_back_bar(ctx, ImGui, b and b.song) -- (an edit of yours that was undone, and why: stays until dismissed)
  local want = reaper.GetExtState(band.SECTION, "panel page") -- a page asked for from elsewhere (a new room opens on Rooms)
  if want ~= "" then reaper.DeleteExtState(band.SECTION, "panel page", false); page = OLD_PAGES[want] or want end
  want = reaper.GetExtState(band.SECTION, "panel do") -- a choice from the radial menu
  if want ~= "" then
    reaper.DeleteExtState(band.SECTION, "panel do", false)
    if want == "undo" or want == "redo" then undo_redo(want == "redo")
    elseif want == "realtime" then set_same_room(not same_room_on())
    elseif want == "chat" then page = "Chat"
    elseif want:match("^history") then page = "Restore" end
  end
  if compact and not wide then
    ImGui.SetCursorPosX(ctx, 16)
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_SelectableTextAlign, 0.5, 0.5)
    for i, p in ipairs(PAGES) do
      local w = ImGui.CalcTextSize(ctx, p[1]) + 28
      if i > 1 then
        ImGui.SameLine(ctx, 0, 2)
        if ImGui.GetContentRegionAvail(ctx) < w then ImGui.NewLine(ctx); ImGui.SetCursorPosX(ctx, 16) end -- (a narrow panel lost Plugins and Setup off the right)
      end
      nav_item(p, w, fh)
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
    if page == "Home" then page_home()
    elseif page == "Rooms" then layout({ { rooms_squares, 560 }, { rooms_actions, 560 } })
    elseif page == "Play" then
      if wide then layout({ { section_together, 380 }, { function() section_live("mode") end, 420 }, { function() section_live("rest") end, 520 } })
      else layout({ { section_together, 380 }, { section_live, 480 } }) end
    elseif page == "Chat" then
      layout({ { function() require("page_chat").draw(ctx, ImGui, cfg, b) end, 560 }, { function() section_notes(); section_ideas() end, 420 } })
    elseif page == "Restore" then layout({ { section_recall, 400 }, { section_history, 600 } })
    elseif page == "Plugins" then
      layout({ { function() require("page_plugins").draw(ctx, ImGui, proj, cfg) end, 760 }, { section_plugins, 420 } })
    elseif page == "Setup" then page_setup() end
    ImGui.PopTextWrapPos(ctx)
    ImGui.EndChild(ctx)
  end
  ImGui.PopStyleVar(ctx)
end

local start_songs -- (the start screen's song list, read every few seconds)
local function frame()
  if b and cfg then recall.warm(cfg, b.song, b.room, 0.004) end
  if reaper.time_precise() - last > 1.5 or reaper.EnumProjects(-1) ~= proj then
    last = reaper.time_precise()
    local ok, e = pcall(refresh)
    err = not ok and tostring(e) or nil
  end
  local app = not classic()
  if app then ImGui.SetCursorPosY(ctx, ImGui.GetCursorPosY(ctx) + 10); ImGui.Indent(ctx, 16) end -- (the app window has no padding of its own)
  if err then
    ImGui.TextColored(ctx, RED, "Something went wrong in the panel: " .. err)
    if ImGui.SmallButton(ctx, "Copy it") then ImGui.SetClipboardText(ctx, "KitchenSync " .. band.VERSION .. ": " .. err) end
    ImGui.SetItemTooltip(ctx, "Copy the message, to send it to whoever looks after KitchenSync.")
    ImGui.SameLine(ctx)
    if ImGui.SmallButton(ctx, "Try again") then err, last = nil, 0 end
    return
  end
  if not b then
    -- joining is what most bandmates do, so it leads, with what's waiting in the folder (review D22, 2026-10-31:
    -- "Publish (I'm the host)" came first and read as a role)
    if not start_songs or reaper.time_precise() - start_songs.at > 5 then
      start_songs = { at = reaper.time_precise(), list = {} } -- (in the chooser's order: worked on last first)
      for _, r in ipairs(require("chooser").songs(cfg)) do start_songs.list[#start_songs.list + 1] = r.song end
    end
    local list = start_songs.list
    local bands = band.bands()
    ImGui.TextWrapped(ctx, "This project isn't a group project. Group: " .. band.info(cfg.root).name)
    if #bands > 1 then
      ImGui.SameLine(ctx)
      if ImGui.SmallButton(ctx, "Switch group") then
        local names = { "#Work in which group?" }
        for _, x in ipairs(bands) do names[#names + 1] = x.name end
        local pick = band.pick(names)
        for _, x in ipairs(bands) do
          if x.name == pick then band.use_band(x.root); cfg = band.settings(); start_songs = nil; drive_at = -math.huge end
        end
      end
      ImGui.SetItemTooltip(ctx, "You're in several groups: new projects, Join the group's project and the project list are this group's.")
    end
    ImGui.PushStyleColor(ctx, ImGui.Col_Button, 0x2E7D4FFF)
    if ImGui.Button(ctx, "Join the group's project") then action("Open session") end
    ImGui.PopStyleColor(ctx)
    ImGui.SameLine(ctx)
    if #list == 0 then
      ImGui.TextColored(ctx, GREY, "nothing from the group has arrived yet")
      ImGui.SetItemTooltip(ctx, "The group's projects arrive in your shared folder (" .. cfg.root .. ") once a collaborator lets you in: " ..
        "their panel shows a 'Let you in' button for your computer. Setup > Health shows whether the folder is connected.")
    else
      ImGui.TextColored(ctx, GREY, string.format("%d project%s in the group folder, worked on last: %s", #list, #list == 1 and "" or "s", list[1]))
    end
    if ImGui.Button(ctx, "Share this project with the group") then action("Publish session") end
    ImGui.SameLine(ctx)
    if ImGui.SmallButton(ctx, "Prepare this project first") then action("Prepare session") end
    ImGui.SetItemTooltip(ctx, "For a busy project: takes into lanes, FLAC recording, clear track names, media in the project folder, tidy-up. Shows a checklist first.")
    ImGui.Spacing(ctx)
    tools.dock_menu(ImGui.IsWindowDocked(ctx)) -- (place the panel before any session is open)
    if not ImGui.IsWindowDocked(ctx) then
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, "Window") then local pick = band.pick(WINDOW_MENU); if pick then place_window(pick) end end
      ImGui.SetItemTooltip(ctx, "Fill the screen the panel is on, or half of it (left, right, top, bottom), and back.")
    end
    if ImGui.IsWindowDocked(ctx) or native then
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, "Minimize") then ui.set_minimized(true) end
      ImGui.SetItemTooltip(ctx, "Shrink the panel to a small square over REAPER. Click the square and the panel opens where it was.")
    end
    return
  end
  if not app then
    ImGui.Text(ctx, string.format("%s  ·  room %s  ·  %s  ·  you are %s", b.song, b.room, b.role, cfg.user))
  end
  if app then ImGui.Unindent(ctx, 16); return frame_app() end
  if ImGui.SmallButton(ctx, "Switch to the new look") then reaper.DeleteExtState(band.SECTION, "panel_ui", true) end
  section_invites()
  tools.join_requests(ctx, ImGui, b) -- (someone asking to join the band folder)
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
    if ImGui.BeginTabItem(ctx, "Restore") then
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
  ImGui.PushStyleColor(ctx, ImGui.Col_WindowBg, theme.BANNER)
  local f = ImGui.WindowFlags_NoDecoration | ImGui.WindowFlags_NoInputs | ImGui.WindowFlags_NoFocusOnAppearing | ImGui.WindowFlags_NoNav |
    ImGui.WindowFlags_NoDocking | ImGui.WindowFlags_AlwaysAutoResize | ImGui.WindowFlags_NoSavedSettings
  if ImGui.Begin(ctx, "BandSync banner", nil, f) then
    ImGui.TextColored(ctx, YELLOW, banner_text)
    ImGui.End(ctx)
  end
  ImGui.PopStyleColor(ctx)
  ImGui.PopStyleVar(ctx, 2)
end

-- Minimized: a small square over REAPER, its edge saying whether sync runs and a count for what's waiting (the words are its tooltip),
-- from the minimize button or closing the panel; a click brings the panel back where it was (floating or docked). Dragged, it stays
-- where it's dropped, pinned to REAPER's window so it goes along when REAPER moves. Right-click to lock it there, close the panel or remove it.
-- shortcut: it's kept inside REAPER's window: past it, a screen unplugged (or a virtual one gone) could lose the button for good.
-- Returns false when the panel should close.
local function pill_window()
  local front = reaper.EnumProjects(-1)
  local fb = band.binding(front)
  local beat = tonumber(reaper.GetExtState(band.SECTION, "live " .. tostring(front)))
  local live_on = beat and reaper.time_precise() - beat < 5
  local unread = fb and require("page_chat").unread(cfg, fb) or 0
  local S = 40
  local vx, vy = ImGui.Viewport_GetWorkPos(ImGui.GetMainViewport(ctx))
  local vw, vh = ImGui.Viewport_GetWorkSize(ImGui.GetMainViewport(ctx))
  local locked = reaper.GetExtState(band.SECTION, "pill lock") ~= ""
  local mx, my = ImGui.GetMousePos(ctx)
  local px, py = vx + (tonumber(reaper.GetExtState(band.SECTION, "pill dx")) or (vw - S - 24)), vy + (tonumber(reaper.GetExtState(band.SECTION, "pill dy")) or 64)
  if ui.pill_drag and ui.pill_drag.moved then px, py = ui.pill_drag.x + mx - ui.pill_drag.mx, ui.pill_drag.y + my - ui.pill_drag.my
  else px, py = math.max(vx, math.min(px, vx + vw - S)), math.max(vy, math.min(py, vy + vh - S)) end
  ImGui.SetNextWindowPos(ctx, px, py)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowRounding, 10)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, 0, 0)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowBorderSize, 0)
  local keep = true
  local f = ImGui.WindowFlags_NoDecoration | ImGui.WindowFlags_AlwaysAutoResize | ImGui.WindowFlags_NoDocking | ImGui.WindowFlags_NoMove |
    ImGui.WindowFlags_NoSavedSettings | ImGui.WindowFlags_NoFocusOnAppearing | ImGui.WindowFlags_NoNav
  if ImGui.Begin(ctx, "BandSync pill", nil, f) then
    local x, y = ImGui.GetCursorScreenPos(ctx)
    local words = "KitchenSync  ·  " .. (live_on and "Sync on" or "Sync off") .. (view and view.driver and ("  ·  " .. (view.driver == cfg.user and "you drive" or (view.driver .. " drives"))) or "") ..
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
    local clicked = ImGui.InvisibleButton(ctx, "##pill", S, S)
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
          reaper.SetExtState(band.SECTION, "pill dx", tostring(px - vx), true); reaper.SetExtState(band.SECTION, "pill dy", tostring(py - vy), true)
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
      if ImGui.Selectable(ctx, "Close the panel") then ui.set_minimized(false); keep = false end
      if ImGui.Selectable(ctx, "Remove this button (Setup > Options brings it back)") then ui.set_minimized(false); reaper.SetExtState(band.SECTION, "pill", "off", true); keep = false end
      ImGui.EndPopup(ctx)
    end
    local dl = ImGui.GetWindowDrawList(ctx)
    if hovered then ImGui.DrawList_AddRectFilled(dl, x, y, x + S, y + S, theme.BUTTON, 10) end
    ImGui.SetCursorScreenPos(ctx, x + (S - 24) / 2, y + 5)
    logo(30)
    ImGui.DrawList_AddRect(dl, x + 1, y + 1, x + S - 1, y + S - 1, live_on and GREEN or RED, 10, 0, 2)
    if waiting > 0 then -- what's waiting, in the corner
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
    band.log("the panel reloaded for KitchenSync " .. tostring(seen_disk))
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
  else visible, open = ImGui.Begin(ctx, "KitchenSync###BandSync", true, flags) end
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
      local me = ImGui.GetWindowDockID(ctx) == ~dock_side.docker and reaper.JS_Window_Find and reaper.JS_Window_Find("KitchenSync", true)
      if me then
        pcall(reaper.JS_Window_SetFocus, me)
        -- (no asking whether the focus took: on a Mac it never reads as ours, and this ended with nothing said. move_docker looks afterwards
        -- and puts back whatever else moved: Mac, 0.45.0)
        local where = dock_side.action == 41599 and "left" or "right"
        if require("tools").move_docker(dock_side.docker, where == "left" and 1 or 3) then
          band.msg("KitchenSync is docked at the " .. where .. " of REAPER.\n\nREAPER opens a new docker there very narrow, " ..
            "and a script can't widen it: drag its inner edge across. REAPER remembers the width after that.")
        else
          band.msg("REAPER wouldn't move KitchenSync's docker to the " .. where .. ", so the panel is at the bottom and everything else is where it was.\n\n" ..
            "To try by hand: right-click the 'KitchenSync' tab at the foot of the docker, and look for the docker's position there.")
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
      do -- minimize, beside the close button, as on any window
        local s, pad = ImGui.GetFontSize(ctx), ImGui.GetStyleVar(ctx, ImGui.StyleVar_FramePadding)
        local bx, by = wx + ww - pad - s * 2 - 8, wy + (ImGui.GetFrameHeight(ctx) - s) / 2
        ImGui.SetCursorScreenPos(ctx, bx, by)
        if ImGui.InvisibleButton(ctx, "##minimize", s, s) then ui.set_minimized(true) end
        local dl = ImGui.GetWindowDrawList(ctx)
        if ImGui.IsItemHovered(ctx) then ImGui.DrawList_AddRectFilled(dl, bx - 2, by - 2, bx + s + 2, by + s + 2, theme.BUTTON_HOVER, 4) end
        ImGui.DrawList_AddLine(dl, bx + s * 0.2, by + s * 0.68, bx + s * 0.8, by + s * 0.68, theme.TEXT, 2)
        ImGui.SetItemTooltip(ctx, "Minimize: a small square over REAPER. Click it and the panel opens where it was.")
      end
      ImGui.PopClipRect(ctx)
    end
    ImGui.End(ctx)
  end
  if not minimized and not open and reaper.GetExtState(band.SECTION, "pill") ~= "off" then -- closed: minimized to the pill
    ui.set_minimized(true)
    open = true
  end
  if app then ImGui.PopFont(ctx); pop_theme() end
  banner()
  reaper.SetExtState(band.SECTION, "panel alive", tostring(reaper.time_precise()), false) -- (so Autostart never opens a second one)
  if open then reaper.defer(loop) end
end
reaper.defer(loop)
