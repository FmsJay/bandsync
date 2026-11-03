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
  return pcall(band.write_atomic, startup_path(), GUARD_A .. " (the hidden REAPER that renders BandSync's wet takes stops here)\n" ..
    "if os.getenv(\"BANDSYNC_RENDER\") then return end\n" .. GUARD_Z .. "\n" .. text)
end

-- A machine asking to join the band folder (the host's Syncthing has it waiting; one on the band's Tailscale is let in
-- by Live sync by itself). On every page of the panel, at the top: in the classic panel only, a new bandmate who
-- wasn't on Tailscale never got in, and nobody saw why (review, 2026-10-31).
function tools.join_requests(ctx, ImGui, b)
  if not b then return end -- (any bandmate's invite brings a request here: not only the host's)
  local binfo = band.info(b.root or reaper.GetExtState(band.SECTION, "sync_root"))
  local asking = band.json_decode(reaper.GetExtState(band.SECTION, "pending_join"))
  local skip = band.json_decode(reaper.GetExtState(band.SECTION, "join skipped")) or {}
  for _, d in ipairs(type(asking) == "table" and asking or {}) do
    if type(d) == "table" and d.id and not skip[d.id] then
      ImGui.TextColored(ctx, 0xF2BF40FF, string.format("%s's computer wants to join %s.", tostring(d.name), d.band or binfo.name))
      ImGui.SetItemTooltip(ctx, string.format("Syncthing device %s, from %s.", d.id:sub(1, 7), tostring(d.address)))
      ImGui.SameLine(ctx)
      if ImGui.SmallButton(ctx, "Let " .. tostring(d.name) .. " in##" .. d.id .. (d.folder or "")) then
        local services = require("services")
        local ok, why
        if d.folder then ok, why = services.share_folder(d.folder, d.id) -- (already a bandmate: just this band's folder)
        else ok, why = services.add_device(d.id, d.name, binfo.id) end
        band.log(ok and ("let '" .. tostring(d.name) .. "' into " .. (d.band or binfo.name) .. ": the songs reach them now")
          or ("couldn't add '" .. tostring(d.name) .. "': " .. tostring(why)))
        reaper.DeleteExtState(band.SECTION, "pending_join", false)
      end
      ImGui.SetItemTooltip(ctx, "Only if you know this computer: anyone who has your Syncthing ID can ask.")
      ImGui.SameLine(ctx)
      if ImGui.SmallButton(ctx, "Not my bandmate##" .. d.id) then
        skip[d.id] = true
        reaper.SetExtState(band.SECTION, "join skipped", band.json_encode(skip), false)
      end
      ImGui.SetItemTooltip(ctx, "Hide this request (until REAPER restarts). Nothing is shared with it.")
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
  for i = 2, 14 do if not used[i] then return i end end
  return 1
end

function tools.put_back_bar(ctx, ImGui, song)
  local pb = band.json_decode(reaper.GetExtState(band.SECTION, "put back"))
  if not (pb and pb.text) then return end
  if pb.song and song and pb.song ~= song then return end -- (another song's, in another tab: laptop, 0.42.4)
  if pb.at and os.time() - pb.at > 600 then return end -- (old news: it's still in Setup > Console. Mac, 0.42.4)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xF2BF40FF)
  ImGui.TextWrapped(ctx, "Undone: " .. tostring(pb.text) .. ((pb.n or 1) > 1 and string.format("  (%d edits undone)", pb.n) or ""))
  ImGui.PopStyleColor(ctx)
  if ImGui.SmallButton(ctx, "OK##putback") then reaper.DeleteExtState(band.SECTION, "put back", false) end
  ImGui.SetItemTooltip(ctx, "Hide this. Every undone edit is also in Setup > Log.")
end

return tools
