-- @description BandSync: draw on the arrange view, for everyone (and see what the band drew)
-- Shows every bandmate's drawings over the arrange view (clicks go straight through to REAPER). The Draw button in
-- Chat (or this action with "draw" asked) turns drawing on: drag to draw, Done or Esc to stop; "Clear mine" takes
-- your drawings away. A stroke sits on song time and on a track, so it stays on the right bar and track however
-- anyone scrolls or zooms. Each stroke is a file in rooms/<room>/drawings/ (synced like chat). Run it again to close.
local dir = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
package.path = dir .. "/lib/?.lua;" .. package.path
local band = require("band")
if not reaper.APIExists("ImGui_GetBuiltinPath") or not reaper.JS_Window_FindChildByID then
  return band.msg("Drawing needs ReaImGui and js_ReaScriptAPI (ReaPack: both are in BandSync's installer).")
end
package.path = reaper.ImGui_GetBuiltinPath() .. "/?.lua;" .. package.path
local ImGui = require "imgui" "0.10"
local cfg = band.settings()
if not cfg then return end
local sync, mirror = require("sync"), require("mirror")
if reaper.set_action_options then reaper.set_action_options(1) end
local _, _, section, cmd = reaper.get_action_context()
if cmd > 0 then reaper.SetToggleCommandState(section, cmd, 1); reaper.RefreshToolbar2(section, cmd) end
-- While drawing, the arrange view's own mouse messages are held back (REAPER would select, drag or marquee under
-- the pen); the overlay reads the button from the OS. Given back when drawing stops or this closes.
local MOUSE = "WM_LBUTTONDOWN,WM_LBUTTONUP,WM_LBUTTONDBLCLK,WM_MOUSEMOVE"
local held = false
local function hold_mouse(on)
  local arr = reaper.JS_Window_FindChildByID(reaper.GetMainHwnd(), 1000)
  if on and not held then
    for m in MOUSE:gmatch("[^,]+") do reaper.JS_WindowMessage_Intercept(arr, m, false) end
  elseif held and not on then
    reaper.JS_WindowMessage_Release(arr, MOUSE)
  end
  held = on
end
reaper.atexit(function()
  hold_mouse(false)
  if cmd > 0 then reaper.SetToggleCommandState(section, cmd, 0); reaper.RefreshToolbar2(section, cmd) end
  reaper.DeleteExtState(band.SECTION, "draw on", false)
end)

local ctx = ImGui.CreateContext("BandSync drawings")
local PALETTE = { 0xFF5A5AFF, 0x4CC2FFFF, 0x7BE07BFF, 0xFFC24CFF, 0xC88BFFFF, 0xFF8BD0FF }
local main = reaper.GetMainHwnd()
local arrange = reaper.JS_Window_FindChildByID(main, 1000) -- (REAPER's arrange view, "trackview")

local cache, cache_at, n_made, was_drawing, placed, was_down = {}, -math.huge, 0, false, nil, false
local stroke -- the one being drawn: { points = { {time, track oid, y fraction} } }
local function drawings_dir(b) return sync.room_dir(cfg, b.song, b.room) .. "/drawings" end
local function load(b) -- every stroke in the room, re-read once a second
  if reaper.time_precise() - cache_at < 1 then return cache end
  cache_at, cache = reaper.time_precise(), {}
  local d = drawings_dir(b)
  for _, f in ipairs(band.files(d, ".json")) do
    local s = band.read_json(d .. "/" .. f)
    if type(s) == "table" and type(s.points) == "table" then s.file = d .. "/" .. f; cache[#cache + 1] = s end
  end
  return cache
end
-- One colour each: the room's people (here now, or who drew) in name order, so every machine agrees. (A colour from
-- a hash of the name gave James and Laptop the same one: laptop, 2026-10-31.)
local function colours(b)
  local set, names, out = { [cfg.user] = true }, {}, {}
  for _, s in ipairs(load(b)) do if type(s.user) == "string" then set[s.user] = true end end
  for _, st in ipairs(require("presence").peers(cfg, b.song, b.room)) do set[st.user] = true end
  for n in pairs(set) do names[#names + 1] = n end
  table.sort(names)
  for i, n in ipairs(names) do out[n] = PALETTE[(i - 1) % #PALETTE + 1] end
  return out
end

-- screen (native pixels) <-> song: time across the arrange view, track and height within it down it
local function layout(proj)
  local _, l, t, r, btm = reaper.JS_Window_GetClientRect(arrange)
  local a, z = reaper.GetSet_ArrangeView2(proj, false, 0, 0, 0, 0)
  local rows = {}
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    local oid = mirror.track_oid(tr)
    if oid ~= "" and reaper.GetMediaTrackInfo_Value(tr, "B_SHOWINTCP") ~= 0 then
      rows[#rows + 1] = { oid = oid, y = reaper.GetMediaTrackInfo_Value(tr, "I_TCPY"), h = reaper.GetMediaTrackInfo_Value(tr, "I_TCPH") }
    end
  end
  return { l = l, t = t, r = r, b = btm, a = a, z = z, rows = rows }
end
local function to_song(L, x, y)
  if x < L.l or x > L.r or y < L.t or y > L.b or L.z <= L.a then return nil end
  local time = L.a + (x - L.l) / (L.r - L.l) * (L.z - L.a)
  for _, row in ipairs(L.rows) do
    if y - L.t >= row.y and y - L.t < row.y + row.h then return { time, row.oid, (y - L.t - row.y) / math.max(1, row.h) } end
  end
end
local function to_screen(L, p)
  for _, row in ipairs(L.rows) do
    if row.oid == p[2] then
      local x, y = L.l + (p[1] - L.a) / (L.z - L.a) * (L.r - L.l), L.t + row.y + p[3] * row.h
      return ImGui.PointConvertNative(ctx, x, y, false)
    end
  end
end

local function loop()
  if reaper.GetExtState(band.SECTION, "draw quit") ~= "" then reaper.DeleteExtState(band.SECTION, "draw quit", false); return end -- (Hide drawings)
  local proj = reaper.EnumProjects(-1)
  local b = band.binding(proj)
  if not b then return reaper.defer(loop) end -- (not a BandSync tab: nothing to show; keeps running for when one is)
  local drawing = reaper.GetExtState(band.SECTION, "draw on") ~= ""
  hold_mouse(drawing)
  local L = layout(proj)
  local x0, y0 = ImGui.PointConvertNative(ctx, L.l, L.t, false)
  local x1, y1 = ImGui.PointConvertNative(ctx, L.r, L.b, false)
  local rect = string.format("%d %d %d %d", x0, y0, x1, y1)
  if rect ~= placed then -- (only when the arrange view moved: placing it every frame lost clicks)
    placed = rect
    ImGui.SetNextWindowPos(ctx, x0, y0, ImGui.Cond_Always)
    ImGui.SetNextWindowSize(ctx, x1 - x0, y1 - y0, ImGui.Cond_Always)
  end
  if drawing then ImGui.SetNextWindowBgAlpha(ctx, 0.06) end
  if drawing and not was_drawing then ImGui.SetNextWindowFocus(ctx) end -- (unfocused, its first click only activated it)
  was_drawing = drawing
  local flags = ImGui.WindowFlags_NoDecoration | ImGui.WindowFlags_NoSavedSettings | ImGui.WindowFlags_NoMove | ImGui.WindowFlags_NoDocking |
    -- (drawing: TopMost, a window of its own above the arrange view, or REAPER's arrange view takes the clicks)
    (drawing and ImGui.WindowFlags_TopMost or (ImGui.WindowFlags_NoInputs | ImGui.WindowFlags_NoBackground | ImGui.WindowFlags_NoFocusOnAppearing))
  local visible = ImGui.Begin(ctx, "BandSync drawings", nil, flags)
  if visible then
    local dl = ImGui.GetWindowDrawList(ctx)
    local function draw_points(points, col)
      local last
      for _, p in ipairs(points) do
        local sx, sy = to_screen(L, p)
        if sx and last then ImGui.DrawList_AddLine(dl, last[1], last[2], sx, sy, col, 3) end
        last = sx and { sx, sy } or nil
      end
    end
    local col = colours(b)
    for _, s in ipairs(load(b)) do draw_points(s.points, col[s.user] or PALETTE[1]) end
    if stroke then draw_points(stroke.points, col[cfg.user]) end
    if drawing then
      local mx, my = reaper.GetMousePosition()
      local inside = mx >= L.l and mx <= L.r and my >= L.t and my <= L.b
      local on_bar = ImGui.IsAnyItemHovered(ctx)
      -- the button straight from the OS (the arrange view gets no clicks now, and an overlay can miss its own)
      local down = reaper.JS_Mouse_GetState(1) & 1 == 1
      local pressed = down and not was_down
      was_down = down
      if down and (inside or stroke) and not (on_bar and not stroke) then
        local p = to_song(L, mx, my)
        stroke = stroke or { points = {} }
        local q = stroke.points[#stroke.points]
        if p and not (q and q[1] == p[1] and q[2] == p[2] and q[3] == p[3]) then stroke.points[#stroke.points + 1] = p end -- (the mouse held still)
      elseif stroke then -- the stroke is done: it goes to the band
        if #stroke.points > 1 then
          n_made = n_made + 1
          local d = drawings_dir(b)
          reaper.RecursiveCreateDirectory(d, 0)
          band.write_json(string.format("%s/%s-%s-%d.json", d, (cfg.user:gsub("[^%w%-_]", "_")), os.date("!%Y%m%d-%H%M%S"), n_made),
            { user = cfg.user, time = os.date("!%Y-%m-%dT%H:%M:%SZ"), points = stroke.points })
          cache_at = -math.huge
        end
        stroke = nil
      end
      local keys = reaper.JS_VKeys_GetState and reaper.JS_VKeys_GetState(0) or ""
      if ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) or keys:byte(28) == 1 then reaper.DeleteExtState(band.SECTION, "draw on", false) end -- (Esc)
      -- the bar: what drawing mode is, and the way out (in this window: a window of its own could sit under it)
      ImGui.SetCursorPos(ctx, 8, 8)
      ImGui.TextColored(ctx, col[cfg.user],"Drawing for the band: drag on the tracks.")
      ImGui.SameLine(ctx)
      local function button(label) return ImGui.SmallButton(ctx, label) or (pressed and ImGui.IsItemHovered(ctx)) end
      if button("Done") then reaper.DeleteExtState(band.SECTION, "draw on", false); stroke = nil end
      ImGui.SameLine(ctx)
      if button("Clear mine") then
        for _, s in ipairs(load(b)) do if s.user == cfg.user then os.remove(s.file) end end
        cache_at, stroke = -math.huge, nil
      end
      ImGui.SetItemTooltip(ctx, "Take away every drawing you made in this room (everyone's copy goes too).")
    end
    ImGui.End(ctx)
  end
  reaper.defer(loop)
end
reaper.defer(loop)
