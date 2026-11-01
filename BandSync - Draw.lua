-- @description BandSync: draw on the arrange view, for everyone (and see what the band drew)
-- Shows every bandmate's drawings over the arrange view (clicks go straight through to REAPER). The Draw button in
-- Chat (or this action with "draw" asked) turns drawing on, with a toolbar: Pen, Highlighter, Line, Arrow, Box,
-- Text and Eraser, a colour, a size, Undo (your last one) and Clear mine; Done or Esc stops. A drawing sits on song
-- time and on a track, so it stays on the right bar and track however anyone scrolls or zooms. Each is a file in
-- rooms/<room>/drawings/ (synced like chat): { user, time, points, kind, color, size, text }, a file without a kind
-- being a pen stroke (as before 0.35.3). Run it again to close.
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
-- the toolbar (James, 2026-11-01: "drawing on the project like it's microsoft paint"): this machine's choices, kept
local TOOLS = { { "pen", "Pen" }, { "marker", "Highlighter" }, { "line", "Line" }, { "arrow", "Arrow" }, { "box", "Box" },
  { "text", "Text" }, { "erase", "Eraser" } }
local SIZES = { { 2, "S" }, { 4, "M" }, { 8, "L" } }
local SWATCHES = { 0xFFFFFFFF, 0x202020FF, 0xFFF04DFF, 0xB8FF3DFF, 0x3DFFF2FF, 0xFF3DD8FF } -- (none anyone's own: PALETTE)
local function pick(key, default) local v = reaper.GetExtState(band.SECTION, "draw " .. key); return v ~= "" and v or default end
local function keep(key, v) reaper.SetExtState(band.SECTION, "draw " .. key, tostring(v), true) end
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
-- One colour each: everyone's own (lib/people.lua: picked in Setup > Options, else a default nobody else has), the
-- same on every machine. (A colour from a hash of the name gave James and Laptop the same one: laptop, 2026-10-31.)
local function colours(b)
  local names, out = { cfg.user }, {}
  for _, s in ipairs(load(b)) do if type(s.user) == "string" then names[#names + 1] = s.user end end
  for _, st in ipairs(require("presence").peers(cfg, b.song, b.room)) do names[#names + 1] = st.user end
  for n, rgb in pairs(require("people").colours(cfg.root, names)) do out[n] = (rgb << 8) | 0xFF end
  return out
end

-- screen (native pixels) <-> song: time across the arrange view, track and height within it down it. A track's rows
-- reach down over its envelope lanes (a drawing there sits on the track's lower edge); BandSync's own tracks (Real
-- time, live views) are there with no oid: each machine has its own, so nothing drawn on them could be shared.
local function layout(proj)
  local _, l, t, r, btm = reaper.JS_Window_GetClientRect(arrange)
  local a, z = reaper.GetSet_ArrangeView2(proj, false, 0, 0, 0, 0)
  local rows = {}
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    if reaper.GetMediaTrackInfo_Value(tr, "B_SHOWINTCP") ~= 0 then
      local oid, h = mirror.track_oid(tr), reaper.GetMediaTrackInfo_Value(tr, "I_TCPH")
      rows[#rows + 1] = { oid = oid ~= "" and oid or false, y = reaper.GetMediaTrackInfo_Value(tr, "I_TCPY"), h = h,
        full = math.max(h, reaper.GetMediaTrackInfo_Value(tr, "I_WNDH")) }
    end
  end
  -- (on macOS native y grows upwards: the top edge is the larger number, and "down the arrange view" is t - y)
  local flip = t > btm
  return { l = l, t = t, r = r, b = btm, a = a, z = z, rows = rows, flip = flip, h = math.abs(btm - t) }
end
local function down(L, y) return L.flip and (L.t - y) or (y - L.t) end -- (pixels down from the arrange view's top)
local function inside(L, x, y) local d = down(L, y); return x >= L.l and x <= L.r and d >= 0 and d <= L.h end
-- -> { time, track oid, height fraction }, or nil + "local" over one of BandSync's own tracks
local function to_song(L, x, y)
  if not inside(L, x, y) or L.z <= L.a then return nil end
  local time = L.a + (x - L.l) / (L.r - L.l) * (L.z - L.a)
  local d = down(L, y)
  for _, row in ipairs(L.rows) do
    if d >= row.y and d < row.y + row.full then
      if not row.oid then return nil, "local" end
      return { time, row.oid, math.min(1, (d - row.y) / math.max(1, row.h)) }
    end
  end
end
local function to_screen(L, p)
  for _, row in ipairs(L.rows) do
    if row.oid == p[2] then
      local d = row.y + p[3] * row.h
      local x, y = L.l + (p[1] - L.a) / (L.z - L.a) * (L.r - L.l), L.flip and (L.t - d) or (L.t + d)
      return ImGui.PointConvertNative(ctx, x, y, false)
    end
  end
end
-- how far (ImGui pixels) a point is from a segment
local function seg_dist(cx, cy, a, z)
  local vx, vy = z[1] - a[1], z[2] - a[2]
  local n = vx * vx + vy * vy
  local t = n > 0 and math.max(0, math.min(1, ((cx - a[1]) * vx + (cy - a[2]) * vy) / n)) or 0
  local ex, ey = a[1] + t * vx - cx, a[2] + t * vy - cy
  return math.sqrt(ex * ex + ey * ey)
end
local TEXT_SIZE = { [2] = 14, [4] = 20, [8] = 30 }
local bar_ext -- the toolbar's screen rectangle last frame: its dark backing, and where a press isn't drawing
local press_n, fired = 0, {} -- each press counted; a toolbar button acts once per press (see button())

local function loop()
  if reaper.GetExtState(band.SECTION, "draw quit") ~= "" then reaper.DeleteExtState(band.SECTION, "draw quit", false); return end -- (Hide drawings)
  local proj = reaper.EnumProjects(-1)
  local b = band.binding(proj)
  if not b then return reaper.defer(loop) end -- (not a BandSync tab: nothing to show; keeps running for when one is)
  -- ReaImGui lets go of a context that went a frame unused (the frames above, in another tab), so it's made again:
  -- the laptop's "expected a valid ImGui_Context*" after closing a second Mirror Test tab (block K)
  if not ImGui.ValidatePtr(ctx, "ImGui_Context*") then ctx, placed = ImGui.CreateContext("BandSync drawings"), nil end
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
    local col = colours(b)
    -- one drawing, in its own colour (or its maker's), size and kind; returns where it is on screen, for the eraser:
    -- { segs = { {a, z}... }, rect = { x0, y0, x1, y1 } }
    local function draw(s)
      local c = math.tointeger(tonumber(s.color)) or col[s.user] or PALETTE[1]
      local w = tonumber(s.size) or 3
      local kind = s.kind or "pen"
      local pts, segs = {}, {}
      for _, p in ipairs(s.points) do local x, y = to_screen(L, p); pts[#pts + 1] = x and { x, y } or false end
      local a, z = pts[1], pts[#pts]
      if kind == "text" then
        if not a then return { segs = segs } end
        local fs, words = TEXT_SIZE[w] or 18, tostring(s.text or "")
        ImGui.DrawList_AddTextEx(dl, ImGui.GetFont(ctx), fs, a[1], a[2], c, words)
        local tw, th = ImGui.CalcTextSize(ctx, words)
        local k = fs / math.max(1, ImGui.GetFontSize(ctx))
        return { segs = segs, rect = { a[1], a[2], a[1] + tw * k, a[2] + th * k } } -- (anywhere on the words erases them)
      elseif kind == "box" then
        if a and z then
          local l, t, r, bt = math.min(a[1], z[1]), math.min(a[2], z[2]), math.max(a[1], z[1]), math.max(a[2], z[2])
          ImGui.DrawList_AddRect(dl, l, t, r, bt, c, 0, 0, w)
          segs = { { { l, t }, { r, t } }, { { r, t }, { r, bt } }, { { r, bt }, { l, bt } }, { { l, bt }, { l, t } } } -- (its four edges)
        end
      elseif kind == "line" or kind == "arrow" then
        if a and z then
          ImGui.DrawList_AddLine(dl, a[1], a[2], z[1], z[2], c, w)
          segs = { { a, z } }
          local dx, dy = z[1] - a[1], z[2] - a[2]
          local len = math.sqrt(dx * dx + dy * dy)
          if kind == "arrow" and len > 1 then -- (a filled head at the end, sized to the line)
            local ux, uy, head = dx / len, dy / len, 10 + w * 2
            ImGui.DrawList_AddTriangleFilled(dl, z[1], z[2], z[1] - head * ux - head * 0.5 * uy, z[2] - head * uy + head * 0.5 * ux,
              z[1] - head * ux + head * 0.5 * uy, z[2] - head * uy - head * 0.5 * ux, c)
          end
        end
      else
        for i = 2, #pts do if pts[i] and pts[i - 1] then segs[#segs + 1] = { pts[i - 1], pts[i] } end end
        if kind == "marker" and #segs > 0 then
          -- (see-through and wide, in one stroke: segments drawn one by one overlapped into darker seams)
          local arr = reaper.new_array(2 * (#segs + 1))
          local n = 0
          for i, sg in ipairs(segs) do
            if i == 1 then arr[n + 1], arr[n + 2], n = sg[1][1], sg[1][2], n + 2 end
            arr[n + 1], arr[n + 2], n = sg[2][1], sg[2][2], n + 2
          end
          arr.resize(n)
          ImGui.DrawList_AddPolyline(dl, arr, (c & 0xFFFFFF00) | 0x55, ImGui.DrawFlags_None, w * 3)
        else
          for _, sg in ipairs(segs) do ImGui.DrawList_AddLine(dl, sg[1][1], sg[1][2], sg[2][1], sg[2][2], c, w) end
        end
      end
      return { segs = segs }
    end
    local shown = {} -- (each drawing on screen, for the eraser)
    for _, s in ipairs(load(b)) do shown[s] = draw(s) end
    if stroke then draw(stroke) end
    if drawing then
      local tool, size = pick("tool", "pen"), tonumber(pick("size", "4")) or 4
      local mine = math.tointeger(tonumber(pick("color", ""))) or col[cfg.user]
      local listed = mine == col[cfg.user]
      for _, c in ipairs(SWATCHES) do if c == mine then listed = true end end
      if not listed then mine = col[cfg.user]; reaper.DeleteExtState(band.SECTION, "draw color", true) end -- (a colour 0.35.3 had: yours again)
      local mx, my = reaper.GetMousePosition()
      local cx, cy = ImGui.PointConvertNative(ctx, mx, my, false)
      local in_bar = bar_ext and cx >= bar_ext[1] and cx <= bar_ext[3] and cy >= bar_ext[2] and cy <= bar_ext[4]
      local on_bar = ImGui.IsAnyItemHovered(ctx) or in_bar
      -- a press: ImGui's own (it catches a click quicker than a frame, and where it was: a fast drag started late),
      -- or the button straight from the OS (an overlay can miss its own first click)
      local down = reaper.JS_Mouse_GetState(1) & 1 == 1
      local clicked = ImGui.IsMouseClicked(ctx, 0)
      local pressed = clicked or (down and not was_down)
      if pressed and not (down and was_down) then press_n = press_n + 1 end
      was_down = down
      local px, py = mx, my -- (where the press was, native)
      if clicked then
        local kx, ky = ImGui.GetMouseClickedPos(ctx, 0)
        px, py = ImGui.PointConvertNative(ctx, kx, ky, true)
      end
      local here = inside(L, px, py) and not on_bar
      local _, why = to_song(L, mx, my)
      if on_bar then why = nil end -- (the track under the toolbar isn't where you're drawing)
      local function save(s) -- a finished drawing goes to the band
        n_made = n_made + 1
        local d = drawings_dir(b)
        reaper.RecursiveCreateDirectory(d, 0)
        s.user, s.time = cfg.user, os.date("!%Y-%m-%dT%H:%M:%SZ")
        band.write_json(string.format("%s/%s-%s-%d.json", d, (cfg.user:gsub("[^%w%-_]", "_")), os.date("!%Y%m%d-%H%M%S"), n_made), s)
        cache_at = -math.huge
      end
      if tool == "erase" or tool == "text" then -- (one click each, not a drag)
        if pressed and here then
          local p = to_song(L, px, py)
          if tool == "text" and p then
            local ok, words = reaper.GetUserInputs("BandSync: text on the tracks", 1, "Text (everyone sees it),extrawidth=200", "")
            if ok and words:match("%S") then save({ kind = "text", points = { p }, text = words, color = mine, size = size }) end
          elseif tool == "erase" then -- the nearest of your own drawings within a few pixels (on its lines, or on its words)
            local ex, ey = ImGui.PointConvertNative(ctx, px, py, false)
            local best, bd = nil, 12
            for s, at in pairs(shown) do
              if s.user == cfg.user then
                local r = at.rect
                if r and ex >= r[1] - 4 and ex <= r[3] + 4 and ey >= r[2] - 4 and ey <= r[4] + 4 then best, bd = s, 0 end
                for _, sg in ipairs(at.segs) do
                  local dist = seg_dist(ex, ey, sg[1], sg[2])
                  if dist < bd then best, bd = s, dist end
                end
              end
            end
            if best then os.remove(best.file); cache_at = -math.huge end
          end
        end
      elseif (down or clicked) and (here or stroke) then
        local p = to_song(L, mx, my)
        if not stroke then
          stroke = { kind = tool, points = {}, color = mine, size = size }
          stroke.points[1] = to_song(L, px, py) -- (it starts where the button went down, however fast the drag)
        end
        if tool == "pen" or tool == "marker" then
          local q = stroke.points[#stroke.points]
          if p and not (q and q[1] == p[1] and q[2] == p[2] and q[3] == p[3]) then stroke.points[#stroke.points + 1] = p end -- (the mouse held still)
        elseif p then -- line, arrow, box: where it started, and where the mouse is now
          stroke.points[1] = stroke.points[1] or p
          stroke.points[2] = p
        end
      elseif stroke then
        if #stroke.points > 1 then save(stroke) end
        stroke = nil
      end
      -- the mouse wheel goes on to REAPER (zoom, scroll, as set there): the overlay on top took it
      local wheel = ImGui.GetMouseWheel(ctx)
      if wheel ~= 0 and inside(L, mx, my) and reaper.JS_WindowMessage_Send then
        local m = reaper.JS_Mouse_GetState(4 | 8)
        reaper.JS_WindowMessage_Send(arrange, "WM_MOUSEWHEEL", (m & 4 ~= 0 and 8 or 0) | (m & 8 ~= 0 and 4 or 0), math.floor(wheel * 120 + 0.5), mx, my)
      end
      local keys = reaper.JS_VKeys_GetState and reaper.JS_VKeys_GetState(0) or ""
      if ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) or keys:byte(28) == 1 then reaper.DeleteExtState(band.SECTION, "draw on", false) end -- (Esc)
      -- the bar, at the foot of the arrange view (at the top it covered drawings on the first track), on a dark backing
      -- so it reads over any item. Each button also reads the OS's click, as the drawing does: the overlay can miss its own.
      if bar_ext then ImGui.DrawList_AddRectFilled(dl, bar_ext[1], bar_ext[2], bar_ext[3], bar_ext[4], 0x1B1D20E6, 6) end
      local fh = ImGui.GetFrameHeightWithSpacing(ctx)
      local _, wh = ImGui.GetWindowSize(ctx)
      local at_top = pick("bar", "bottom") == "top" -- (wherever it is it covers a track: Top/Bottom moves it)
      ImGui.SetCursorPos(ctx, 12, at_top and 8 or math.max(8, wh - 2 * fh - 12))
      local sx, sy = ImGui.GetCursorScreenPos(ctx)
      local maxx, maxy = sx, sy
      local function grew() local x, y = ImGui.GetItemRectMax(ctx); maxx, maxy = math.max(maxx, x), math.max(maxy, y) end
      -- once per press: the OS's press (on the way down) and ImGui's own click (on the way up) were two, and Undo took
      -- two drawings away (laptop, 0.35.4)
      local function once(id, hit)
        if not hit or fired[id] == press_n then return false end
        fired[id] = press_n
        return true
      end
      local function button(label, on)
        if on then ImGui.PushStyleColor(ctx, ImGui.Col_Button, 0x2E7D4FFF) end
        local hit = once(label, ImGui.SmallButton(ctx, label) or (pressed and ImGui.IsItemHovered(ctx)))
        if on then ImGui.PopStyleColor(ctx) end
        grew()
        return hit
      end
      for i, t in ipairs(TOOLS) do
        if i > 1 then ImGui.SameLine(ctx, 0, 3) end
        if button(t[2] .. "##tool", tool == t[1]) then keep("tool", t[1]); stroke = nil end
      end
      ImGui.SameLine(ctx, 0, 12)
      for i, c in ipairs(SWATCHES) do
        if i > 1 then ImGui.SameLine(ctx, 0, 3) end
        local hit = once("swatch" .. i, ImGui.ColorButton(ctx, "##swatch" .. i, c, ImGui.ColorEditFlags_NoTooltip, 16, 16) or (pressed and ImGui.IsItemHovered(ctx)))
        grew()
        if hit then keep("color", c) end
        local ax, ay = ImGui.GetItemRectMin(ctx)
        local zx, zy = ImGui.GetItemRectMax(ctx)
        ImGui.DrawList_AddRect(ImGui.GetWindowDrawList(ctx), ax, ay, zx, zy, 0x8A8F96FF, 0, 0, 1) -- (the dark one shows on the dark bar)
        if c == mine then ImGui.DrawList_AddRect(ImGui.GetWindowDrawList(ctx), ax - 2, ay - 2, zx + 2, zy + 2, 0xFFFFFFFF, 0, 0, 2) end
      end
      ImGui.SameLine(ctx, 0, 3)
      if button("Mine##colour", mine == col[cfg.user]) then reaper.DeleteExtState(band.SECTION, "draw color", true) end
      ImGui.SetItemTooltip(ctx, "Your own colour (the one Who's here and the drawings show you in).")
      ImGui.SameLine(ctx, 0, 12)
      for i, z in ipairs(SIZES) do
        if i > 1 then ImGui.SameLine(ctx, 0, 3) end
        if button(z[2] .. "##size", size == z[1]) then keep("size", z[1]) end
      end
      -- second row: the buttons first, where they always are (with the hint first, they moved with its length and a
      -- click meant for Done hit Clear mine: laptop, 0.35.3), then what the tool does
      ImGui.SetCursorPosX(ctx, 12)
      if button("Done") then reaper.DeleteExtState(band.SECTION, "draw on", false); stroke = nil end
      ImGui.SameLine(ctx, 0, 3)
      if button("Undo") then -- your newest drawing in this room
        local last
        for _, s in ipairs(load(b)) do
          if s.user == cfg.user and (not last or tostring(s.time) .. s.file > tostring(last.time) .. last.file) then last = s end
        end
        if last then os.remove(last.file); cache_at, stroke = -math.huge, nil end
      end
      ImGui.SetItemTooltip(ctx, "Take away your last drawing (everyone's copy goes too).")
      ImGui.SameLine(ctx, 0, 24)
      if button("Clear mine") then
        for _, s in ipairs(load(b)) do if s.user == cfg.user then os.remove(s.file) end end
        cache_at, stroke = -math.huge, nil
      end
      ImGui.SetItemTooltip(ctx, "Take away every drawing you made in this room (everyone's copy goes too).")
      ImGui.SameLine(ctx, 0, 12)
      if button(at_top and "Bottom##bar" or "Top##bar") then keep("bar", at_top and "bottom" or "top") end
      ImGui.SetItemTooltip(ctx, "Move this bar to the " .. (at_top and "foot" or "top") .. " of the tracks (it covers whatever's under it).")
      ImGui.SameLine(ctx, 0, 12)
      ImGui.AlignTextToFramePadding(ctx)
      ImGui.Text(ctx, why == "local" and "That's one of BandSync's own tracks: draw on a band track." or ({ pen = "Drag to draw.",
        marker = "Drag to highlight.", line = "Drag from one end to the other.", arrow = "Drag from the tail to the point.",
        box = "Drag from corner to corner.", text = "Click where the words go.", erase = "Click one of your drawings to take it away." })[tool] or "")
      grew()
      bar_ext = { sx - 6, sy - 6, maxx + 8, maxy + 6 }
    else
      bar_ext = nil
    end
    ImGui.End(ctx)
  end
  reaper.defer(loop)
end
reaper.defer(loop)
