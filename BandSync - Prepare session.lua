-- @description BandSync: prepare this project for BandSync (lanes, FLAC, names, media, tidy-up), as a checklist
-- For a project that's already busy, before it's published or joined: shows what it would change, each a checkbox,
-- then, on Continue, saves a backup copy and does the ticked ones as one undo (file conversions keep their originals in a
-- 'BandSync originals' folder next to the project).
local dir = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
package.path = dir .. "/lib/?.lua;" .. package.path
local band = require("band")
local prep = require("prep")

local cfg = band.settings()
if not cfg then return end
if not reaper.APIExists("ImGui_GetBuiltinPath") then
  return band.msg("This needs ReaImGui. Install it with ReaPack (Extensions > ReaPack > Browse packages: ReaImGui), then run this again.")
end
package.path = reaper.ImGui_GetBuiltinPath() .. "/?.lua;" .. package.path
local ImGui = require "imgui" "0.10"

local proj = reaper.EnumProjects(-1)
local b = band.binding(proj)
if b and b.role == "solo" then return band.msg("This is a Solo edit copy: prepare the song itself, not the copy.") end
local rows = prep.scan(proj, cfg, b)
local ctx = ImGui.CreateContext("BandSync: prepare")
local result -- summary lines once applied
local GREY, GREEN = 0x8C8C8CFF, 0x59CC73FF

local function loop()
  ImGui.SetNextWindowSize(ctx, 620, 460, ImGui.Cond_FirstUseEver)
  ImGui.SetNextWindowBgAlpha(ctx, 1) -- opaque: the arrange view showing through made it hard to read
  local shown, open = ImGui.Begin(ctx, "Prepare this project for BandSync###bandsync_prep", true)
  local close = false
  if shown then
    if not reaper.ValidatePtr2(0, proj, "ReaProject*") then close = true
    elseif result then
      ImGui.TextColored(ctx, GREEN, "Done:")
      for _, l in ipairs(result) do ImGui.Bullet(ctx); ImGui.TextWrapped(ctx, l) end
      ImGui.Spacing(ctx)
      ImGui.TextWrapped(ctx, "Undo (Ctrl+Z) takes back the project changes; converted files' originals are in 'BandSync originals'.")
      if ImGui.Button(ctx, "Close") or ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then close = true end
    elseif #rows == 0 then
      ImGui.TextColored(ctx, GREEN, "Nothing to do: this project is ready for BandSync.")
      if ImGui.Button(ctx, "Close") or ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then close = true end
    else
      ImGui.TextWrapped(ctx, "What this project needs for BandSync. Untick anything you'd rather keep, then Continue: a backup copy of the project is saved first.")
      ImGui.Spacing(ctx)
      if ImGui.BeginChild(ctx, "rows", 0, -40) then
        for i, r in ipairs(rows) do
          ImGui.PushID(ctx, tostring(i))
          if r.todo ~= nil then
            local _, v = ImGui.Checkbox(ctx, r.title, r.on)
            r.on = v
          else -- a note: nothing BandSync can change for you
            ImGui.TextColored(ctx, GREY, "-  " .. r.title)
          end
          ImGui.Indent(ctx, 28)
          ImGui.PushStyleColor(ctx, ImGui.Col_Text, GREY)
          ImGui.TextWrapped(ctx, r.detail)
          ImGui.PopStyleColor(ctx)
          ImGui.Unindent(ctx, 28)
          ImGui.Spacing(ctx)
          ImGui.PopID(ctx)
        end
        ImGui.EndChild(ctx)
      end
      local any = false
      for _, r in ipairs(rows) do if r.on and r.todo ~= nil then any = true end end
      ImGui.BeginDisabled(ctx, not any)
      if ImGui.Button(ctx, "Continue") then
        ImGui.EndDisabled(ctx)
        local ok, res = pcall(prep.apply, proj, cfg, b, rows, dir)
        result = ok and res or { "Stopped: " .. tostring(res) }
        for _, l in ipairs(result) do band.log("prepare: " .. l) end
      else
        ImGui.EndDisabled(ctx)
      end
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, "Cancel") or ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then close = true end
    end
    ImGui.End(ctx)
  end
  if open and not close then reaper.defer(loop) end
end
reaper.defer(loop)
