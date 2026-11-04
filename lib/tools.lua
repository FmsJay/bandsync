-- The panel's tools: keep/dismiss live ideas, and starting Live sync with REAPER. (Dry mode, take back, print audio
-- and the take-based undo went with mirror sync in 0.30: Restore and the top bar's Undo/Redo replace them.)
local band = require("band")
local tools = {}

-- ---- live ideas (placeholders from Play along) ---------------------------------------------------------------
function tools.ideas(proj)
  local by = {}
  for i = 0, reaper.CountMediaItems(proj) - 1 do
    local it = reaper.GetMediaItem(proj, i)
    if band.item_ext(it, "band_live") ~= "" then
      local who = select(2, reaper.GetTrackName(reaper.GetMediaItem_Track(it))):gsub(" %(live%)$", "")
      by[who] = (by[who] or 0) + 1
    end
  end
  return by
end
-- Keep: the selected placeholders become ordinary items of ours (no take will ever replace them).
function tools.keep_ideas(proj)
  local n = 0
  for i = 0, reaper.CountSelectedMediaItems(proj) - 1 do
    local it = reaper.GetSelectedMediaItem(proj, i)
    if band.item_ext(it, "band_live") ~= "" then
      for _, k in ipairs({ "band_live", "band_live_since", "band_live_heard" }) do band.set_item_ext(it, k, "") end
      n = n + 1
    end
  end
  return n
end
-- Dismiss: every placeholder (of `who`, or everyone's) goes.
function tools.dismiss_ideas(proj, who)
  local n = 0
  for i = reaper.CountMediaItems(proj) - 1, 0, -1 do
    local it = reaper.GetMediaItem(proj, i)
    if band.item_ext(it, "band_live") ~= "" then
      local tr = reaper.GetMediaItem_Track(it)
      if not who or select(2, reaper.GetTrackName(tr)):gsub(" %(live%)$", "") == who then
        reaper.DeleteTrackMediaItem(tr, it)
        n = n + 1
      end
    end
  end
  return n
end

-- ---- Live sync with REAPER: a block in Scripts/__startup.lua runs BandSync - Autostart.lua -------------------
local MARK_A, MARK_Z = "-- BandSync autostart", "-- /BandSync autostart"
local function startup_path() return reaper.GetResourcePath() .. "/Scripts/__startup.lua" end
function tools.autostart_on()
  return (band.read(startup_path()) or ""):find(MARK_A, 1, true) ~= nil
end
function tools.set_autostart(on, dir)
  local text = band.read(startup_path()) or ""
  local a = text:find(MARK_A, 1, true)
  if a then
    local z = text:find(MARK_Z, a, true)
    text = text:sub(1, a - 1) .. (z and text:sub(z + #MARK_Z + 1) or "")
  end
  if on then
    text = text .. (text ~= "" and not text:match("\n$") and "\n" or "") ..
      MARK_A .. "\ndofile([[" .. dir .. "/BandSync - Autostart.lua]])\n" .. MARK_Z .. "\n"
  end
  reaper.RecursiveCreateDirectory(reaper.GetResourcePath() .. "/Scripts", 0)
  return pcall(band.write_atomic, startup_path(), text) -- (write_atomic returns nothing: it raises when it can't)
end

-- The hidden REAPER that renders wet takes (lib/bgrender.lua) would run everything in Scripts/__startup.lua too (on
-- James's PC: Chordbox, Adaptive grid, Gridbox, the Reaper Daemon bridge, BandSync's Autostart). A guard at the top
-- of that file stops it there: the render REAPER is started with BANDSYNC_RENDER set. Added once; the rest of the
-- file is the person's and stays as it is.
local GUARD_A, GUARD_Z = "-- BandSync render guard", "-- /BandSync render guard"
function tools.render_guard()
  local text = band.read(startup_path()) or ""
  if text:find(GUARD_A, 1, true) then return true end
  reaper.RecursiveCreateDirectory(reaper.GetResourcePath() .. "/Scripts", 0)
  return pcall(band.write_atomic, startup_path(), GUARD_A .. " (the hidden REAPER that renders StudioSync's wet takes stops here)\n" ..
    "if os.getenv(\"BANDSYNC_RENDER\") then return end\n" .. GUARD_Z .. "\n" .. text)
end

-- A machine asking to join the band folder (the host's Syncthing has it waiting; one on the band's Tailscale is let in
-- by Live sync by itself). On every page of the panel, at the top: in the classic panel only, a new bandmate who
-- wasn't on Tailscale never got in, and nobody saw why (review, 2026-10-31).
local let_at, let_device, asked_at, asking = {}, {}, -math.huge, {} -- (let_at, who was just let in: Syncthing's own list says they're asking for up to 20 s more, and the row stayed)
local function let_in(d, me)
  local services = require("services")
  local ok, why
  if d.folder then
    ok, why = services.share_folder(d.folder, d.id)
    if ok then
      require("removal").let_in(d.root, d.id) -- (taken out before, and back)
      do -- a kept version of what's open, from before they arrived
        local recall = require("recall")
        local base = { root = reaper.GetExtState(band.SECTION, "sync_root"), user = me }
        for i = 0, math.huge do
          local p = reaper.EnumProjects(i)
          if not p then break end
          local tb = band.binding(p)
          if tb and band.for_tab(base, tb).root == d.root then
            pcall(recall.save, p, { root = d.root, user = me }, tb.song, tb.room, "before " .. tostring(d.name) .. " joined", true)
          end
        end
      end
    end
  else
    ok, why = services.add_device(d.id, d.name)
    if ok then let_device[d.id] = true end
  end
  if ok then let_at[d.id .. (d.folder or "")] = reaper.time_precise() end
  band.log(ok and (d.folder and ("let '" .. tostring(d.name) .. "' into " .. d.band .. ": the projects reach them now") or ("let '" .. tostring(d.name) .. "' connect: the studio they were invited to follows in a moment"))
    or ("couldn't add '" .. tostring(d.name) .. "': " .. tostring(why)))
end
function tools.join_requests(ctx, ImGui)
  local me = reaper.GetExtState(band.SECTION, "user")
  if reaper.time_precise() - asked_at > 2 then asked_at, asking = reaper.time_precise(), require("services").join_asks(me) end
  if not asking[1] then return end
  local skip = band.json_decode(reaper.GetExtState(band.SECTION, "join skipped")) or {}
  for _, d in ipairs(asking) do
    if not skip[d.id] and reaper.time_precise() - (let_at[d.id .. (d.folder or "")] or -math.huge) > 40 and d.folder and let_device[d.id] then
      let_device[d.id] = nil -- (the one press covers the studio they were invited to; another one later asks again)
      let_in(d, me)
    elseif not skip[d.id] and reaper.time_precise() - (let_at[d.id .. (d.folder or "")] or -math.huge) > 40 then
      -- (buttons first: the words pushed them off a narrow panel)
      ImGui.SetCursorPosX(ctx, math.max(ImGui.GetCursorPosX(ctx), 16)) -- (no project open, there is no margin here: Mac, 0.52.5)
      if ImGui.SmallButton(ctx, "Let " .. tostring(d.name) .. " in##" .. d.id .. (d.folder or "")) then let_in(d, me) end
      ImGui.SetItemTooltip(ctx, "Only if you know this computer: anyone who has your Syncthing ID can ask.")
      ImGui.SameLine(ctx)
      if ImGui.SmallButton(ctx, "Not my collaborator##" .. d.id) then
        skip[d.id] = true
        reaper.SetExtState(band.SECTION, "join skipped", band.json_encode(skip), false)
        require("services").dismiss_pending(d.id) -- (only hidden, it came back at every restart)
      end
      ImGui.SetItemTooltip(ctx, "Dismiss this request. Nothing is shared with it. It only comes back if that computer asks again.")
      ImGui.SameLine(ctx)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, require("theme").YELLOW)
      local out, from
      for _, x in ipairs(d.folder and { { root = d.root, name = d.band } } or band.bands()) do
        out = out or require("removal").who_was(x.root, d.id)
        from = from or (out and x.name)
      end
      ImGui.TextWrapped(ctx, out and string.format("%s was taken out of %s, and their computer is still asking. Leave it unless you've invited them back.", out, from)
        or d.folder and string.format("%s's computer wants to join %s.", tostring(d.name), d.band)
        or string.format("%s's computer is asking to join a studio of yours. It says which once it's let in.", tostring(d.name)))
      ImGui.PopStyleColor(ctx)
      ImGui.SetItemTooltip(ctx, string.format("Syncthing device %s, from %s.", d.id:sub(1, 7), tostring(d.address)))
    end
  end
end

-- Your newest undone edit (sync.put_back), in a yellow bar under the top bar until you dismiss it: the six-second
-- message line was easy to miss, and the next log line replaced it (review, 2026-10-31).
-- A docker with nothing in it, to put in a new place: REAPER lists what's in each in its ini file ("name=size docker"), and says
-- bottom for one it has never placed. Beyond the first two, as those are the ones people use.
function tools.free_docker()
  local used, inside = {}, false
  for line in (band.read(reaper.get_ini_file()) or ""):gmatch("[^\r\n]+") do
    if line:sub(1, 1) == "[" then inside = line == "[REAPERdockpref]"
    elseif inside then
      local n = line:match("=[%-%d%.]+ (%d+)")
      if n then used[tonumber(n)] = true end
    end
  end
  -- (and one with no side saved: one left at the left from an earlier try took the panel there on Dock > Right: Mac, 0.42.30)
  for i = 2, 14 do if not used[i] and reaper.DockGetPosition(i) == 0 then return i end end
  return 1
end

-- The docker action moves whichever docker REAPER counts as having the focus, and on a Mac that can be the Mixer's though the
-- panel's has the focus by every check. So look afterwards: anything else that moved goes straight back. -> true when `docker` is
-- on `side` (0 bottom, 1 left, 2 top, 3 right, the order of the actions).
local DOCKER_SIDE = { [0] = 41598, [1] = 41599, [2] = 41600, [3] = 41601 }
function tools.move_docker(docker, side)
  local before = {}
  for i = 0, 15 do before[i] = reaper.DockGetPosition(i) end
  reaper.Main_OnCommand(DOCKER_SIDE[side], 0)
  for i = 0, 15 do
    if i ~= docker and reaper.DockGetPosition(i) ~= before[i] and DOCKER_SIDE[before[i]] then reaper.Main_OnCommand(DOCKER_SIDE[before[i]], 0) end
  end
  return reaper.DockGetPosition(docker) == side
end

-- Said on the computer of someone taken out of a group, until they're let back in (lib/removal.lua).
function tools.removed_bar(ctx, ImGui)
  local text = reaper.GetExtState(band.SECTION, "removed from")
  if text == "" then return end
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, require("theme").YELLOW)
  ImGui.TextWrapped(ctx, text)
  ImGui.PopStyleColor(ctx)
end

function tools.put_back_bar(ctx, ImGui, song)
  local pb = band.json_decode(reaper.GetExtState(band.SECTION, "put back"))
  if not (pb and pb.text) then return end
  if pb.song and song and pb.song ~= song then return end -- (another song's, in another tab: laptop, 0.42.4)
  if pb.at and os.time() - pb.at > 600 then return end -- (old news: it's still in Setup > Console. Mac, 0.42.4)
  if ImGui.SmallButton(ctx, "OK##putback") then reaper.DeleteExtState(band.SECTION, "put back", false) end -- (first: a panel docked short showed the text, and no way to dismiss it)
  ImGui.SetItemTooltip(ctx, "Hide this. Every undone edit is also in Settings > Console.")
  ImGui.SameLine(ctx)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, require("theme").YELLOW)
  ImGui.TextWrapped(ctx, "Undone: " .. tostring(pb.text) .. ((pb.n or 1) > 1 and string.format("  (%d edits undone)", pb.n) or ""))
  ImGui.PopStyleColor(ctx)
end

return tools
