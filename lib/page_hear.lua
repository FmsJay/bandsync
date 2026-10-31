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

-- Beside the last item if `label` (plus a box or field `extra` wide) still fits, else on the next line: the docked
-- panel's columns are narrow, and a SameLine past their edge is just cut off (laptop, 0.33.0: the hear button, "Guest").
function page.fit(ctx, ImGui, label, extra)
  ImGui.SameLine(ctx, 0, 6)
  local pad = 2 * select(1, ImGui.GetStyleVar(ctx, ImGui.StyleVar_FramePadding)) + ImGui.GetFrameHeight(ctx) + 4
  if ImGui.GetContentRegionAvail(ctx) < ImGui.CalcTextSize(ctx, label) + pad + (extra or 0) then ImGui.NewLine(ctx) end
end

-- After a bandmate's name in Who's here: "hear" / "muted". Only with the live mix in place (Real time mode on).
function page.person(ctx, ImGui, proj, name)
  if not hear.mix(proj, false) then return end
  local on = hear.is_on(proj, name)
  page.fit(ctx, ImGui, "muted")
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
  local function beside(label, extra) page.fit(ctx, ImGui, label, extra) end
  local their = ext(proj, "hear their time") == "1"
  local ms = math.floor(hear.delay(proj) + 0.5)
  if ImGui.RadioButton(ctx, "My time", not their) and their then
    reaper.SetProjExtState(proj, band.SECTION, "hear their time", "")
    hear.set_delay(proj, 0)
    band.log("you hear in your own time again: your backing on time, the band as it arrives")
  end
  ImGui.SetItemTooltip(ctx, "You hear everyone as it arrives: your backing on time, them a little late (the network).")
  -- (the label says whose side moves: "Their time" alone read as their audio being delayed, on the laptop)
  beside("Their time (my backing later)")
  if ImGui.RadioButton(ctx, "Their time (my backing later)", their) and not their then
    reaper.SetProjExtState(proj, band.SECTION, "hear their time", "1")
    local want = guest.on(proj) and guest.delay(proj) or tonumber(ext(proj, "their ms")) or 100
    hear.set_delay(proj, want)
    ms = want
    band.log(string.format("you hear in their time: your backing %d ms later, so the band lines up with it (listening, not playing)", want))
  end
  ImGui.SetItemTooltip(ctx, "Your backing (and your own playing) comes later, so what they play lines up with it:\n" ..
    "for listening along, not for playing (you'd be playing late). With a guest, use their measured delay;\n" ..
    "for bandmates, SonoBus's window shows each one's delay (the number after the down arrow).")
  if their then
    beside("", 90)
    ImGui.SetNextItemWidth(ctx, 90)
    local ch, v = ImGui.DragInt(ctx, "##their", ms, 1, 0, hear.MAX_MS, "%d ms")
    if ch then hear.set_delay(proj, v); reaper.SetProjExtState(proj, band.SECTION, "their ms", tostring(v)) end
    if ImGui.IsItemDeactivatedAfterEdit(ctx) then band.log(string.format("their time: your backing %d ms later", math.floor(hear.delay(proj) + 0.5))) end
    ImGui.SetItemTooltip(ctx, "How much later your backing comes. Drag, or double-click to type.")
  end
  local g = guest.on(proj)
  beside("Guest")
  local chg, gv = ImGui.Checkbox(ctx, "Guest", g)
  if chg then guest.set(proj, gv) end
  ImGui.SetItemTooltip(ctx, "For someone joining with only SonoBus (a singer at home): they hear your whole mix, and what they sing\n" ..
    "is recorded on the Real time track whenever you record. Send them the band's SonoBus link (Configure SonoBus).")
  if g then
    local d = guest.delay(proj)
    local label = d and string.format("Measure again (%d ms)", d) or "Measure their delay"
    beside(label)
    if ImGui.SmallButton(ctx, label) then run("Measure guest delay") end
    ImGui.SetItemTooltip(ctx, "They clap along to 8 clicks; BandSync times where the claps land. Measure right before you record:
" ..
      "the delay through SonoBus drifts as it adjusts its buffers (tested over Wi-Fi: 426-555 ms within two minutes).")
    if d then
      beside("Line up their takes")
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
