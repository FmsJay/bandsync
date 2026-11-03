-- The panel's look, for every BandSync window (the chooser and the drawing bar had REAPER's plain ImGui grey).
local theme = {}

theme.ACCENT, theme.CARD, theme.NAV, theme.MUTED = 0x4C8DF6FF, 0x26292EFF, 0x1F2124FF, 0x8D939BFF
theme.DARK = 0x15171AFF

local cols, vars
local function lists(ImGui)
  if cols then return end
  local ACCENT, MUTED = theme.ACCENT, theme.MUTED
  cols = {
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
  vars = {
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

return theme
