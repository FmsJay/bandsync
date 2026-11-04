-- The panel's look, for every window (the chooser and the drawing bar had REAPER's plain ImGui grey). A theme is a few
-- colours; the rest is worked out from them, so a new one is one line here.
-- Setup > Options picks it, per computer (ExtState "theme"). The panel reloads to change; the others pick it up on their next frame.
local theme = {}

theme.NAMES = { "Dark", "Light", "Midnight", "Warm" }
local PALETTES = {
  Dark = { bg = 0x1A1C1F, card = 0x26292E, nav = 0x1F2124, text = 0xE6E8EB, muted = 0x8D939B, accent = 0x4C8DF6,
    green = 0x59CC73, yellow = 0xF2BF40, red = 0xE0605A, on_status = 0x15171A, steel = 0xC9CED6 },
  Light = { bg = 0xF2F3F5, card = 0xFFFFFF, nav = 0xE4E6EA, text = 0x1F2328, muted = 0x626A73, accent = 0x2F6FE0,
    green = 0x1C8A47, yellow = 0x9A6B00, red = 0xC8372F, on_status = 0xFFFFFF, steel = 0x7A8390, status = 0.72 },
  Midnight = { bg = 0x0F1626, card = 0x1B2540, nav = 0x141D32, text = 0xE3E9F5, muted = 0x8A97B3, accent = 0x6C8CFF,
    green = 0x5AD08F, yellow = 0xF0C25A, red = 0xEE6B7A, on_status = 0x0F1626, steel = 0xC4CEE2 },
  Warm = { bg = 0x221D18, card = 0x312A23, nav = 0x29231D, text = 0xEFE6DA, muted = 0xA19383, accent = 0xE0954A,
    green = 0x8CC56A, yellow = 0xEDC05A, red = 0xE5705A, on_status = 0x221D18, steel = 0xD6CBBC },
}

local function mix(a, b, t) -- a towards b, each channel; no alpha
  local out = 0
  for s = 16, 0, -8 do
    local x, y = a >> s & 0xFF, b >> s & 0xFF
    out = out | math.floor(x + (y - x) * t + 0.5) << s
  end
  return out
end
local function solid(c) return c << 8 | 0xFF end

local cols, vars
local cols_for -- (which theme `cols` was built for)
-- Which theme this script draws in.
function theme.use(name)
  local p = PALETTES[name] or PALETTES.Dark
  theme.name = PALETTES[name] and name or "Dark"
  local bg, text = p.bg, p.text
  theme.ACCENT, theme.CARD, theme.NAV, theme.MUTED, theme.TEXT = solid(p.accent), solid(p.card), solid(p.nav), solid(p.muted), solid(text)
  theme.BG, theme.DARK = solid(bg), solid(p.on_status) -- (DARK: the words on a coloured status pill)
  theme.GREEN, theme.YELLOW, theme.RED, theme.GREY = solid(p.green), solid(p.yellow), solid(p.red), solid(p.muted)
  theme.STEEL, theme.STATUS = solid(p.steel), p.status or 1
  theme.BUTTON, theme.BUTTON_HOVER = solid(mix(bg, text, 0.12)), solid(mix(bg, text, 0.18))
  theme.FRAME = solid(mix(bg, text, 0.16))
  theme.SWITCH_OFF = solid(mix(bg, text, 0.36))
  theme.COLUMN = solid(mix(bg, text, 0.03))
  theme.CHIP_MINE, theme.CHIP_OTHER = solid(mix(p.card, p.accent, 0.38)), solid(mix(p.card, text, 0.16))
  theme.SELECTED = solid(mix(bg, p.accent, 0.35))
  theme.TOAST = solid(mix(text, p.accent, 0.4))
  theme.BANNER = solid(mix(bg, p.yellow, 0.14))
  theme.BAR = bg << 8 | 0xE6
  cols = nil
end
local function current() return reaper.GetExtState(require("band").SECTION, "theme") end
theme.use(current())

local function lists(ImGui)
  if cols and cols_for == theme.name then return end
  cols_for = theme.name
  local p = PALETTES[theme.name]
  local bg, text, accent = p.bg, p.text, p.accent
  local ACCENT, MUTED = theme.ACCENT, theme.MUTED
  local function t(x) return solid(mix(bg, text, x)) end
  local function a(x) return solid(mix(bg, accent, x)) end
  cols = {
    { ImGui.Col_WindowBg, theme.BG }, { ImGui.Col_ChildBg, 0x00000000 }, { ImGui.Col_PopupBg, solid(mix(p.card, text, 0.03)) },
    { ImGui.Col_Text, theme.TEXT }, { ImGui.Col_TextDisabled, MUTED }, { ImGui.Col_Border, t(0.12) },
    { ImGui.Col_FrameBg, theme.FRAME }, { ImGui.Col_FrameBgHovered, t(0.21) }, { ImGui.Col_FrameBgActive, t(0.26) },
    { ImGui.Col_Button, theme.BUTTON }, { ImGui.Col_ButtonHovered, theme.BUTTON_HOVER }, { ImGui.Col_ButtonActive, ACCENT },
    { ImGui.Col_Header, a(0.2) }, { ImGui.Col_HeaderHovered, a(0.28) }, { ImGui.Col_HeaderActive, a(0.38) },
    { ImGui.Col_CheckMark, ACCENT }, { ImGui.Col_SliderGrab, ACCENT }, { ImGui.Col_Separator, t(0.12) },
    { ImGui.Col_SeparatorHovered, ACCENT }, { ImGui.Col_Tab, t(0.08) }, { ImGui.Col_TabHovered, a(0.3) },
    { ImGui.Col_TabSelected, theme.SELECTED }, { ImGui.Col_TitleBg, solid(p.nav) }, { ImGui.Col_TitleBgActive, solid(mix(p.nav, text, 0.03)) },
    { ImGui.Col_TableHeaderBg, t(0.08) }, { ImGui.Col_TableRowBgAlt, t(0.04) }, { ImGui.Col_ScrollbarBg, 0x00000000 },
  }
  vars = vars or {
    { ImGui.StyleVar_WindowPadding, 0, 0 }, { ImGui.StyleVar_FramePadding, 10, 6 }, { ImGui.StyleVar_ItemSpacing, 8, 8 },
    { ImGui.StyleVar_FrameRounding, 6 }, { ImGui.StyleVar_ChildRounding, 10 }, { ImGui.StyleVar_WindowRounding, 8 },
    { ImGui.StyleVar_GrabRounding, 6 }, { ImGui.StyleVar_PopupRounding, 6 }, { ImGui.StyleVar_TabRounding, 6 },
    { ImGui.StyleVar_ScrollbarRounding, 8 }, { ImGui.StyleVar_ChildBorderSize, 0 }, { ImGui.StyleVar_FrameBorderSize, 0 },
  }
end

-- padding: a window with no cards in it needs its own room around what's in it (the panel's cards bring theirs).
function theme.push(ctx, ImGui, padding)
  lists(ImGui)
  for _, c in ipairs(cols) do ImGui.PushStyleColor(ctx, c[1], c[2]) end
  for _, v in ipairs(vars) do ImGui.PushStyleVar(ctx, v[1], v[2], v[3]) end
  if padding then ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, 14, 12) end
end
function theme.pop(ctx, ImGui, padding)
  ImGui.PopStyleVar(ctx, #vars + (padding and 1 or 0))
  ImGui.PopStyleColor(ctx, #cols)
end
-- The chooser and the drawing bar, once a frame before pushing: Setup may have just changed it.
function theme.follow() local n = current(); if (PALETTES[n] and n or "Dark") ~= theme.name then theme.use(n) end end

return theme
