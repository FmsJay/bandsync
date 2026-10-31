-- The panel's live-listening controls (shown with Real time mode on): hear each bandmate or not, my time / their
-- time, and a guest who joins with only SonoBus. The mechanics are lib/hear.lua and lib/guest.lua.
local band = require("band")
local hear, guest = require("hear"), require("guest")
local page = {}

local function ext(proj, k) return select(2, reaper.GetProjExtState(proj, band.SECTION, k)) end
local function run(name)
  local script = (debug.getinfo(1, "S").source:match("^@?(.*)[/\\]lib[/\\]") or "") .. "/BandSync - " .. name .. ".lua"
  local id = reaper.AddRemoveReaScript(true, 0, script, true)
  if id > 0 then reaper.Main_OnCommand(id, 0) end
end

-- After a bandmate's name in Who's here: "hear" / "muted". Only with the live mix in place (Real time mode on).
function page.person(ctx, ImGui, proj, name)
  if not hear.mix(proj, false) then return end
  local on = hear.is_on(proj, name)
  ImGui.SameLine(ctx, 0, 6)
  if on then
    if ImGui.SmallButton(ctx, "hear##" .. name) then hear.set_on(proj, name, false) end
  else
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xE06C6CFF)
    if ImGui.SmallButton(ctx, "muted##" .. name) then hear.set_on(proj, name, true) end
    ImGui.PopStyleColor(ctx)
  end
  ImGui.SetItemTooltip(ctx, (on and ("You hear " .. name .. " live. Click to stop hearing them (only here: they still hear you).")
    or ("You don't hear " .. name .. " live. Click to hear them again.")) ..
    (hear.own_pair(proj, name) and "" or "\n(They share one level with anyone else SonoBus has no pair for: they get their own when Real time mode next starts.)"))
end

-- Under the Real time mode switch, while it's on.
function page.realtime(ctx, ImGui, proj)
  if not hear.mix(proj, false) then return end
  local their = ext(proj, "hear their time") == "1"
  local ms = math.floor(hear.delay(proj) + 0.5)
  if ImGui.RadioButton(ctx, "My time", not their) and their then
    reaper.SetProjExtState(proj, band.SECTION, "hear their time", "")
    hear.set_delay(proj, 0)
  end
  ImGui.SetItemTooltip(ctx, "You hear everyone as it arrives: your backing on time, them a little late (the network).")
  ImGui.SameLine(ctx)
  if ImGui.RadioButton(ctx, "Their time", their) and not their then
    reaper.SetProjExtState(proj, band.SECTION, "hear their time", "1")
    local want = guest.on(proj) and guest.delay(proj) or tonumber(ext(proj, "their ms")) or 100
    hear.set_delay(proj, want)
    ms = want
  end
  ImGui.SetItemTooltip(ctx, "Your backing (and your own playing) comes later, so what they play lines up with it:\n" ..
    "for listening along, not for playing (you'd be playing late). With a guest, use their measured delay;\n" ..
    "for bandmates, SonoBus's window shows each one's delay (the number after the down arrow).")
  if their then
    ImGui.SameLine(ctx)
    ImGui.SetNextItemWidth(ctx, 90)
    local ch, v = ImGui.DragInt(ctx, "##their", ms, 1, 0, hear.MAX_MS, "%d ms")
    if ch then hear.set_delay(proj, v); reaper.SetProjExtState(proj, band.SECTION, "their ms", tostring(v)) end
    ImGui.SetItemTooltip(ctx, "How much later your backing comes. Drag, or double-click to type.")
  end
  ImGui.SameLine(ctx, 0, 16)
  local g = guest.on(proj)
  local chg, gv = ImGui.Checkbox(ctx, "Guest", g)
  if chg then guest.set(proj, gv) end
  ImGui.SetItemTooltip(ctx, "For someone joining with only SonoBus (a singer at home): they hear your whole mix, and what they sing\n" ..
    "is recorded on the Real time track whenever you record. Send them the band's SonoBus link (Configure SonoBus).")
  if g then
    ImGui.SameLine(ctx)
    local d = guest.delay(proj)
    if ImGui.SmallButton(ctx, d and string.format("Measure again (%d ms)", d) or "Measure their delay") then run("Measure guest delay") end
    ImGui.SetItemTooltip(ctx, "They clap along to 8 clicks; BandSync times where the claps land. Once is enough per guest and connection.")
    if d then
      ImGui.SameLine(ctx)
      if ImGui.SmallButton(ctx, "Line up their takes") then
        local _, name = reaper.GetUserInputs("BandSync: the guest's takes", 1, "Guest's name (their track)", ext(proj, "guest name"))
        if _ then
          reaper.SetProjExtState(proj, band.SECTION, "guest name", name)
          local n, label = guest.line_up(proj, name)
          band.log(n > 0 and string.format("%d take(s) moved %d ms earlier onto '%s': the band gets them now", n, d, label)
            or "nothing recorded from the guest yet: record (they sing along), then line up")
        end
      end
      ImGui.SetItemTooltip(ctx, "Moves what you recorded from them onto a band track of their own, earlier by their delay, so it sits\n" ..
        "where they sang it. The band gets it like any take.")
    end
  end
end

return page
