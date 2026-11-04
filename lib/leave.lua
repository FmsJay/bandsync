-- Sync and exit: leaving a session with everything out. Saves, waits for Live sync to have sent what's changed (prints too), has Syncthing look and
-- waits until it's handed over, then says plainly who has it. Only then close the project or quit REAPER. A slice each frame, from the panel.
-- (Syncthing's own numbers count someone ignoring a project as having it: fine here, they don't need it. Someone who's offline gets it when they're back,
-- from whoever's on, or from Google Drive: so when nobody else is on, Drive gets a last copy.)
local band = require("band")
local leave = {}

local function folder_id(cfg) return band.info(cfg.root).id end
local names = {}

-- Who's online and what they still need of this folder, and what this computer still needs: { peers = { { name, need } }, need }. Slow: called every couple of seconds.
function leave.ask_syncthing(cfg)
  local services = require("services")
  local id = folder_id(cfg)
  local conn = band.json_decode(services.ask("/rest/system/connections", 3) or "")
  local folder = band.json_decode(services.ask("/rest/config/folders/" .. id, 3) or "")
  local status = band.json_decode(services.ask("/rest/db/status?folder=" .. id, 3) or "")
  if type(conn) ~= "table" or type(conn.connections) ~= "table" or type(status) ~= "table" or type(folder) ~= "table" then return nil end
  local out = { peers = {}, need = status.needBytes or 0, state = status.state }
  for _, d in ipairs(folder.devices or {}) do -- (only who this group's folder is shared with: someone in another group of yours read as "sending 0.0 MB")
    local dev = d.deviceID
    if conn.connections[dev] and conn.connections[dev].connected then
      local comp = band.json_decode(services.ask("/rest/db/completion?folder=" .. id .. "&device=" .. dev, 3) or "")
      if type(comp) == "table" and not comp.error and comp.remoteState ~= "notSharing" then
        names[dev] = names[dev] or services.device_name(dev) -- (slow: once)
        out.peers[#out.peers + 1] = { name = names[dev], need = comp.needBytes or 0 }
      end
    end
  end
  return out
end

-- Everything out? Pure. -> done, what's still going in words.
function leave.settled(st)
  if not st then return false, "Waiting for Syncthing to answer" end
  if st.state ~= "idle" then return false, "Syncthing is looking through the folder" end
  local out = {}
  for _, p in ipairs(st.peers) do
    if p.need > 0 then out[#out + 1] = string.format("%.1f MB to %s", p.need / 1048576, p.name) end
  end
  if #out > 0 then return false, "Sending " .. table.concat(out, ", ") end
  return true
end

function leave.start(proj, cfg, b)
  leave.job = { proj = proj, cfg = cfg, b = b, step = "save", since = reaper.time_precise(), words = "Saving", open = true }
end

local function save_tab(j)
  if select(2, reaper.GetProjExtState(j.proj, band.SECTION, "hold")) ~= "" then
    reaper.SetProjExtState(j.proj, band.SECTION, "hold", "") -- (what you held goes out: you're leaving)
    j.unheld = true
  end
  reaper.Main_SaveProject(j.proj, false)
  -- a restore point for this session (Live sync's own, as when it goes quiet for 20 minutes)
  reaper.SetExtState(band.SECTION, "end session " .. tostring(j.proj), "Sync and exit", false)
end

-- Live sync has looked since we saved, and has nothing waiting (it says so each pass: "outbox").
local function sent(j, now)
  local key = tostring(j.proj)
  local box = band.json_decode(reaper.GetExtState(band.SECTION, "outbox " .. key))
  if type(box) ~= "table" then return false end
  return (tonumber(box.at) or 0) > j.saved_at + 0.5 and not box.more and now - j.saved_at > 2, box
end

function leave.tick()
  local j = leave.job
  if not j or j.finished then return end
  local now = reaper.time_precise()
  if not reaper.ValidatePtr2(0, j.proj, "ReaProject*") then leave.job = nil; return end
  if j.step == "save" then
    save_tab(j)
    j.saved_at, j.step, j.words = now, "send", "Sending your changes to the group"
  elseif j.step == "send" then
    local beat = tonumber(reaper.GetExtState(band.SECTION, "live " .. tostring(j.proj)))
    if not beat or now - beat > 10 then
      j.problem = "Live sync isn't running in this tab, so what you changed since it stopped hasn't gone out. Press Start, or stay and sort it out."
      j.step = "done"
      return
    end
    local ok, box = sent(j, now)
    if ok then
      require("services").rescan(folder_id(j.cfg))
      j.step, j.at, j.words, j.scan_at = "syncthing", -math.huge, "Handing over to the others", now
    elseif box and box.more then j.words = "Sending your changes (" .. tostring(box.more) .. ")"
    end
  elseif j.step == "syncthing" then
    if now - j.at < 3 or now - j.scan_at < 2 then return end
    j.at = now
    j.st = leave.ask_syncthing(j.cfg)
    local done, words = leave.settled(j.st)
    j.words = words or j.words
    if done then j.step = "drive" end
  elseif j.step == "drive" then
    local droot = require("drive").root(j.cfg)
    if droot and #j.st.peers == 0 then
      j.words = "Nobody else is online: copying to Google Drive"
      local drive, sync = require("drive"), require("sync")
      local more = false
      for _, room in ipairs(band.subdirs(band.song_dir(j.cfg, j.b.song) .. "/rooms")) do
        local ok, _, m = pcall(drive.mirror, sync.room_dir(j.cfg, j.b.song, room), droot .. "/" .. j.b.song .. "/rooms/" .. room, 0.1, j.cfg.user)
        if ok and m then more = true end
      end
      j.drove = true
      if more and now - j.since < 600 then return end
      j.drive_left = more
    end
    j.step = "done"
  elseif j.step == "done" then
    j.finished = true
    local lines = {}
    if j.problem then lines[#lines + 1] = j.problem
    else
      lines[#lines + 1] = "Saved."
      if j.unheld then lines[#lines + 1] = "Hold my changes was on: what you held went out." end
      local names = {}
      for _, p in ipairs(j.st and j.st.peers or {}) do names[#names + 1] = p.name end
      if #names > 0 then lines[#lines + 1] = "Everything's with " .. table.concat(names, ", ") .. "."
      elseif j.drove then
        lines[#lines + 1] = j.drive_left and "Nobody else is online. Google Drive has some of it and the rest is still copying: it carries on while this computer's on."
          or "Nobody else is online. Google Drive has it, so they get it from there or from this computer."
      else
        lines[#lines + 1] = "Nobody else is online, and this group/session has no Google Drive copy here: it reaches them when this computer and theirs are on at the same time."
        j.only_here = true
      end
      if (j.st and j.st.need or 0) > 0 then lines[#lines + 1] = string.format("There's %.1f MB on its way to you.", j.st.need / 1048576) end
    end
    j.lines = lines
  end
end

function leave.draw(ctx, ImGui)
  local j = leave.job
  if not j then return end
  leave.tick()
  j = leave.job
  if not j then return end
  if j.open then j.open = nil; ImGui.OpenPopup(ctx, "Sync and exit") end
  ImGui.SetNextWindowSize(ctx, 440, 0)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, 16, 12)
  local shown = ImGui.BeginPopupModal(ctx, "Sync and exit", nil, ImGui.WindowFlags_NoResize)
  ImGui.PopStyleVar(ctx)
  if shown then
    ImGui.PushTextWrapPos(ctx, 0)
    if not j.finished then
      ImGui.Text(ctx, j.words .. "...")
      ImGui.TextDisabled(ctx, string.format("%d s", math.floor(reaper.time_precise() - j.since)))
      if reaper.time_precise() - j.since > 60 then
        ImGui.TextDisabled(ctx, "If you go now, whoever's online gets the rest next time you're both on.")
      end
      if ImGui.Button(ctx, "Stop waiting") then j.finished, j.lines = true, { "Not everything has gone out yet: " .. tostring(j.words) .. "." } end
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, "Cancel") then leave.job = nil; ImGui.CloseCurrentPopup(ctx) end
    else
      for _, l in ipairs(j.lines or {}) do ImGui.Text(ctx, l) end
      ImGui.Spacing(ctx)
      if not j.problem and not j.only_here then ImGui.TextDisabled(ctx, "Safe to close up or log off.") end
      if ImGui.Button(ctx, "Close this project") then
        leave.job = nil
        ImGui.CloseCurrentPopup(ctx)
        reaper.Main_OnCommand(40860, 0) -- Close current project tab
      end
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, "Quit REAPER") then
        leave.job = nil
        ImGui.CloseCurrentPopup(ctx)
        reaper.Main_OnCommand(40004, 0) -- File: Quit REAPER
      end
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, "Stay") then leave.job = nil; ImGui.CloseCurrentPopup(ctx) end
    end
    ImGui.PopTextWrapPos(ctx)
    ImGui.EndPopup(ctx)
  end
end

return leave
