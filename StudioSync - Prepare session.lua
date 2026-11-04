-- @description StudioSync: prepare this project for StudioSync (lanes, FLAC, names, media, tidy-up), as a checklist
-- For a project that's already busy, before it's published or joined: shows what it would change, each a checkbox,
-- then, on Continue, saves a backup copy and does the ticked ones as one undo (file conversions keep their originals in a
-- 'StudioSync originals' folder next to the project).
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
if b and b.role == "solo" then return band.msg("This is a Solo edit copy: prepare the project itself, not the copy.") end
local rows = prep.scan(proj, cfg, b)
local ctx = ImGui.CreateContext("StudioSync: prepare")
local result -- summary lines once applied
local sharing = reaper.GetExtState(band.SECTION, "share after prepare") ~= "" -- (Share sent us: the last button goes on to it)
reaper.DeleteExtState(band.SECTION, "share after prepare", false)
local function share_now(ImGui_ctx)
  if not (sharing and ImGui.Button(ImGui_ctx, "Share it")) then return false end
  reaper.SetExtState(band.SECTION, "prepared " .. tostring(proj), "1", false)
  local id = reaper.AddRemoveReaScript(true, 0, dir .. "/StudioSync - Publish session.lua", true)
  if id > 0 then reaper.defer(function() reaper.Main_OnCommand(id, 0) end) end
  return true
end
local GREY, GREEN = 0x8C8C8CFF, 0x59CC73FF

local theme = require("theme")
local function loop()
  theme.push(ctx, ImGui, true) -- (it was REAPER's plain ImGui grey, next to the panel)
  ImGui.SetNextWindowSize(ctx, 620, 460, ImGui.Cond_FirstUseEver)
  ImGui.SetNextWindowBgAlpha(ctx, 1) -- opaque: the arrange view showing through made it hard to read
  local shown, open = ImGui.Begin(ctx, "Prepare this project for StudioSync###bandsync_prep", true)
  local close = false
  if shown then
    if not reaper.ValidatePtr2(0, proj, "ReaProject*") then close = true
    elseif result then
      ImGui.TextColored(ctx, GREEN, "Done:")
      for _, l in ipairs(result) do ImGui.Bullet(ctx); ImGui.TextWrapped(ctx, l) end
      ImGui.Spacing(ctx)
      ImGui.TextWrapped(ctx, "Undo (Ctrl+Z; Cmd+Z on a Mac) takes back the project changes; converted files' originals are in 'StudioSync originals'.")
      if share_now(ctx) then close = true end
      if sharing then ImGui.SameLine(ctx) end
      if ImGui.Button(ctx, sharing and "Not now" or "Close") or ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then close = true end
    elseif #rows == 0 then
      ImGui.TextColored(ctx, GREEN, "Nothing to do: this project is ready for StudioSync.")
      if share_now(ctx) then close = true end
      if sharing then ImGui.SameLine(ctx) end
      if ImGui.Button(ctx, sharing and "Not now" or "Close") or ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then close = true end
    else
      if b then
        ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xF2BF40FF)
        ImGui.TextWrapped(ctx, "This project is already shared: what you change here goes to everyone as your changes, and whatever isn't yours to change is put back. Best done when nobody else is working on it.")
        ImGui.PopStyleColor(ctx)
      end
      ImGui.TextWrapped(ctx, "What this project needs for StudioSync. Untick anything you'd rather keep, then Continue: a backup copy of the project is saved first.")
      ImGui.Spacing(ctx)
      if ImGui.BeginChild(ctx, "rows", 0, -40) then
        for i, r in ipairs(rows) do
          ImGui.PushID(ctx, tostring(i))
          if r.todo ~= nil then
            local _, v = ImGui.Checkbox(ctx, r.title, r.on)
            r.on = v
          else -- a note: nothing StudioSync can change for you
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
  theme.pop(ctx, ImGui, true)
  if open and not close then reaper.defer(loop) end
end
reaper.defer(loop)
