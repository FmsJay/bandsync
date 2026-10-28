-- @description BandSync: control panel (sync, bandmates, who drives, who owns what, recall points)
-- One dockable window for everything BandSync does in the project in front: start/stop Live sync, hold
-- it while you try things, see who has what, take control, claim tracks and regions, and save/restore
-- recall points. Needs ReaImGui (ReaPack: "ReaImGui: ReaScript binding for Dear ImGui").
local dir = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
package.path = dir .. "/lib/?.lua;" .. package.path
local band = require("band")
local sync = require("sync")
local recall = require("recall")
local status = require("status")

if not reaper.APIExists("ImGui_GetBuiltinPath") then
  return band.msg("The panel needs ReaImGui. Install it with ReaPack (Extensions > ReaPack > Browse packages: ReaImGui), then run this again.")
end
package.path = reaper.ImGui_GetBuiltinPath() .. "/?.lua;" .. package.path
local ImGui = require "imgui" "0.10"

local cfg = band.settings()
if not cfg then return end

if reaper.set_action_options then reaper.set_action_options(1) end -- running it again closes it (no task dialog)
local _, _, section, cmd = reaper.get_action_context()
if cmd > 0 then reaper.SetToggleCommandState(section, cmd, 1); reaper.RefreshToolbar2(section, cmd) end
reaper.atexit(function() if cmd > 0 then reaper.SetToggleCommandState(section, cmd, 0); reaper.RefreshToolbar2(section, cmd) end end)

local ctx = ImGui.CreateContext("BandSync")
local GREEN, YELLOW, GREY, RED = 0x59CC73FF, 0xF2BF40FF, 0x8C8C8CFF, 0xE0605AFF
local function rgba(c) return math.floor(c[1] * 255) << 24 | math.floor(c[2] * 255) << 16 | math.floor(c[3] * 255) << 8 | 0xFF end

-- Actions run as REAPER actions (so they see their own action context), registered on first use.
local ids = {}
local function action(name)
  ids[name] = ids[name] or reaper.AddRemoveReaScript(true, 0, dir .. "/BandSync - " .. name .. ".lua", true)
  if ids[name] > 0 then reaper.Main_OnCommand(ids[name], 0) end
end

local proj, b, view, can, who, points, last, err = nil, nil, nil, nil, nil, {}, 0, nil
local label = ""
local function refresh()
  proj = reaper.EnumProjects(-1)
  b = band.binding(proj)
  if not b then return end
  view = status.gather(cfg, b, proj)
  can, who = sync.authority(cfg, b.song, b.room, view.session)
  points = recall.list(cfg, b.song, b.room)
end

-- History: re-read only while its tab is open, and not every frame.
local entries, groups, hist_at = {}, {}, 0
local function refresh_history()
  entries = recall.entries(cfg, b.song, b.room)
  groups = recall.groups(entries, view.session and view.session.host)
end
local utc_now = os.date("!*t")
utc_now.isdst = false
local utc_offset = os.time() - os.time(utc_now) -- shortcut: fixed at start, a DST change mid-session shows an hour off
local function local_time(iso)
  local y, mo, d, h, mi, s = (iso or ""):match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then return "?" end
  return os.date("%m-%d %H:%M", os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = s, isdst = false }) + utc_offset)
end

-- What a track is called for ownership: a "(MIDI)" copy track and a "(band)" mirror belong to their part.
local function part_name(tr)
  local m = band.track_ext(tr, "band_midi_track")
  return m ~= "" and m or sync.base_name(select(2, reaper.GetTrackName(tr)))
end
local function claim(tracks, regions)
  local c = sync.my_claims(cfg, b.song, b.room)
  c.tracks, c.regions = c.tracks or {}, c.regions or {}
  local function add(list, name)
    for _, n in ipairs(list) do if n:lower() == name:lower() then return end end
    list[#list + 1] = name
  end
  for _, n in ipairs(tracks) do add(c.tracks, n) end
  for _, n in ipairs(regions) do add(c.regions, n) end
  sync.set_claims(cfg, b.song, b.room, c)
end

local function section_sync()
  ImGui.SeparatorText(ctx, "Sync")
  local key = tostring(proj)
  local beat = tonumber(reaper.GetExtState(band.SECTION, "live " .. key))
  local running = beat and reaper.time_precise() - beat < 5
  ImGui.TextColored(ctx, running and GREEN or RED, running and "Live sync is running" or "Live sync is not running")
  ImGui.SameLine(ctx)
  if ImGui.SmallButton(ctx, running and "Stop" or "Start") then
    if running then reaper.SetExtState(band.SECTION, "stop " .. key, "1", false) -- Live sync sees it on its next tick
    else reaper.DeleteExtState(band.SECTION, "stop " .. key, false); action("Live sync") end
  end
  local hold = select(2, reaper.GetProjExtState(proj, band.SECTION, "hold")) ~= ""
  local changed, v = ImGui.Checkbox(ctx, "Hold sync (try things; your changes go out once, when you release)", hold)
  if changed then reaper.SetProjExtState(proj, band.SECTION, "hold", v and "1" or "") end
  ImGui.Text(ctx, string.format("Here: %d/%d takes%s", view.total - view.my_missing, view.total,
    view.my_missing > 0 and (", " .. view.my_missing .. " still arriving") or ""))
  if view.newer then
    ImGui.TextColored(ctx, YELLOW, "BandSync " .. view.newer .. " is in use here; you have " .. band.VERSION .. ".")
    ImGui.SameLine(ctx)
    if ImGui.SmallButton(ctx, "Update##banner") then action("Update") end -- "##": same label as More's Update, its own ID
  end
end

local function section_band()
  ImGui.SeparatorText(ctx, "Bandmates")
  if #view.rows == 0 then return ImGui.TextDisabled(ctx, "Nobody else has synced in this room yet.") end
  if ImGui.BeginTable(ctx, "mates", 5, ImGui.TableFlags_RowBg | ImGui.TableFlags_SizingStretchProp) then
    for _, h in ipairs({ "Who", "State", "Seen", "Has", "Version" }) do ImGui.TableSetupColumn(ctx, h) end
    ImGui.TableHeadersRow(ctx)
    for _, r in ipairs(view.rows) do
      local c = rgba(status.COLORS[r.state])
      ImGui.TableNextRow(ctx)
      ImGui.TableNextColumn(ctx); ImGui.Text(ctx, r.name .. (r.name == view.driver and "  (driving)" or ""))
      ImGui.TableNextColumn(ctx); ImGui.TextColored(ctx, c, r.state)
      ImGui.TableNextColumn(ctx); ImGui.TextColored(ctx, c, status.ago(r.age))
      ImGui.TableNextColumn(ctx); ImGui.TextColored(ctx, c, r.has .. "/" .. view.total)
      ImGui.TableNextColumn(ctx); ImGui.TextColored(ctx, r.version == band.VERSION and GREY or YELLOW, r.version)
    end
    ImGui.EndTable(ctx)
  end
end

local function section_control()
  ImGui.SeparatorText(ctx, "Who changes what")
  local driving = view.driver == cfg.user
  ImGui.Text(ctx, driving and "You're driving: what nobody has claimed follows you." or (tostring(view.driver) .. " is driving."))
  if not driving then
    ImGui.SameLine(ctx)
    if ImGui.SmallButton(ctx, "Take control") then action("Take control") end
  end
  local owned = {}
  for name, c in pairs(who.tracks) do owned[#owned + 1] = string.format("track %s: %s", c.name or name, c.user) end
  for name, c in pairs(who.regions) do owned[#owned + 1] = string.format("region %s: %s", c.name or name, c.user) end
  table.sort(owned)
  if #owned == 0 then ImGui.TextDisabled(ctx, "Nothing claimed: everything follows the driver.") end
  for _, o in ipairs(owned) do ImGui.BulletText(ctx, o) end
  if ImGui.Button(ctx, "Claim selected tracks") then
    local list = {}
    for i = 0, reaper.CountSelectedTracks(proj) - 1 do list[#list + 1] = part_name(reaper.GetSelectedTrack(proj, i)) end
    if #list == 0 then band.msg("Select the tracks you want to own first.") else claim(list, {}) end
  end
  ImGui.SetItemTooltip(ctx, "Only you can move, trim, delete or re-pick takes on them; everyone follows you there.")
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Claim region at cursor") then
    local _, ri = reaper.GetLastMarkerAndCurRegion(proj, reaper.GetCursorPositionEx(proj))
    local _, isrgn, _, _, name = reaper.EnumProjectMarkers3(proj, ri)
    if ri < 0 or not isrgn or name == "" then band.msg("Put the edit cursor inside a named region first.") else claim({}, { name }) end
  end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Release mine") then sync.set_claims(cfg, b.song, b.room, { tracks = {}, regions = {} }) end
end

local function section_recall()
  ImGui.SeparatorText(ctx, "Recall points")
  ImGui.SetNextItemWidth(ctx, -90)
  local _, v = ImGui.InputTextWithHint(ctx, "##label", "name this version (e.g. 'chorus with double guitars')", label, ImGui.InputTextFlags_None)
  label = v
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Save point") then
    recall.save(proj, cfg, b.song, b.room, label ~= "" and label or "saved by " .. cfg.user)
    label = ""
    last = 0
  end
  local driving = view.driver == cfg.user
  if ImGui.BeginChild(ctx, "points", 0, 110, ImGui.ChildFlags_Borders) then
    if #points == 0 then ImGui.TextDisabled(ctx, "None yet. Every handover saves one by itself.") end
    for i, p in ipairs(points) do
      ImGui.PushID(ctx, i)
      ImGui.BeginDisabled(ctx, not driving)
      if ImGui.SmallButton(ctx, "Restore") and reaper.MB("Make the session match '" .. p.label .. "'?\n\n" ..
          "Where things are now is saved as a recall point first, so you can come back.", "BandSync", 4) == 6 then
        band.log(recall.restore(proj, cfg, b.song, b.room, p.file) or "restore failed")
        last = 0
      end
      ImGui.EndDisabled(ctx)
      if not driving then ImGui.SetItemTooltip(ctx, "Only the driver restores (take control first).") end
      ImGui.SameLine(ctx)
      ImGui.Text(ctx, string.format("%s  ·  %s  ·  %s  ·  %d takes", p.label, tostring(p.by), (p.time or ""):sub(1, 16):gsub("T", " "), p.takes))
      ImGui.PopID(ctx)
    end
    ImGui.EndChild(ctx)
  end
end

local function section_history()
  if reaper.time_precise() - hist_at > 4 then hist_at = reaper.time_precise(); refresh_history() end
  ImGui.SeparatorText(ctx, "Every change, newest first")
  local driving = view.driver == cfg.user
  if #groups == 0 then ImGui.TextDisabled(ctx, "Nothing has happened in this room yet.") end
  if ImGui.BeginChild(ctx, "history", 0, -4) then
    for gi = #groups, 1, -1 do
      local g = groups[gi]
      ImGui.PushID(ctx, gi)
      ImGui.BeginDisabled(ctx, not driving)
      if ImGui.SmallButton(ctx, "Restore") and reaper.MB(string.format("Make the session look like it did right after %s's changes at %s?\n\n" ..
          "Takes recorded since then are put away (not destroyed), deleted ones come back, positions and what plays go back. " ..
          "Where things are now is saved as a recall point first, so you can come back.", g.user, local_time(g.to)), "BandSync", 4) == 6 then
        local st = recall.replay(entries, g.last)
        band.log(recall.restore_state(proj, cfg, b.song, b.room, st, string.format("%s's changes at %s", g.user, local_time(g.to))) or "restore failed")
        last, hist_at = 0, 0
      end
      ImGui.EndDisabled(ctx)
      ImGui.SetItemTooltip(ctx, driving and "Go back to right after this group of changes." or "Only the driver restores (take control first).")
      ImGui.SameLine(ctx)
      local n = g.last - g.first + 1
      local head = string.format("%s%s  ·  %s%s  ·  %d change%s", g.user, g.user == g.driver and " (driving)" or "",
        local_time(g.from), g.from ~= g.to and ("-" .. local_time(g.to):sub(7)) or "", n, n == 1 and "" or "s")
      if ImGui.TreeNodeEx(ctx, "g", head, ImGui.TreeNodeFlags_SpanAvailWidth) then
        for i = g.first, g.last do
          ImGui.TextDisabled(ctx, local_time(entries[i].time):sub(7))
          ImGui.SameLine(ctx)
          ImGui.Text(ctx, recall.describe(entries[i]))
        end
        ImGui.TreePop(ctx)
      end
      ImGui.PopID(ctx)
    end
    ImGui.EndChild(ctx)
  end
end

-- Drum map of the selected tracks. Changing it rewrites the BandSync MIDI on those tracks into the new map,
-- so the notes keep hitting the same drums with the new instrument.
local drummap = require("drummap")
local function section_drums()
  ImGui.SeparatorText(ctx, "Drum map (selected tracks)")
  local tr = reaper.GetSelectedTrack(proj, 0)
  if not tr then return ImGui.TextDisabled(ctx, "Select a drum track (yours, or a '(MIDI)' copy).") end
  local cur = band.track_ext(tr, "band_drummap")
  local names = { "", "gm" }
  for _, f in ipairs(band.files(cfg.root .. "/drummaps", ".json")) do names[#names + 1] = f:sub(1, -6) end
  ImGui.SetNextItemWidth(ctx, 220)
  if ImGui.BeginCombo(ctx, "##drummap", cur == "" and "none (notes as they come)" or cur) then
    for _, n in ipairs(names) do
      if ImGui.Selectable(ctx, n == "" and "none (notes as they come)" or n, n == cur) and n ~= cur then
        for i = 0, reaper.CountSelectedTracks(proj) - 1 do
          local t2 = reaper.GetSelectedTrack(proj, i)
          local old = band.track_ext(t2, "band_drummap")
          local conv = old ~= "" and n ~= "" and drummap.table(drummap.load(cfg.root, old), drummap.load(cfg.root, n))
          for j = 0, reaper.CountTrackMediaItems(t2) - 1 do
            local tk = reaper.GetActiveTake(reaper.GetTrackMediaItem(t2, j))
            local id = tk and reaper.TakeIsMIDI(tk) and (band.take_ext(tk, "band_midi") ~= "" and band.take_ext(tk, "band_midi") or band.take_ext(tk, "band_sent"))
            if conv and id and id ~= "" then
              local _, buf = reaper.MIDI_GetAllEvts(tk, "")
              reaper.MIDI_SetAllEvts(tk, drummap.translate(buf, conv))
              reaper.MIDI_Sort(tk)
              if band.take_ext(tk, "band_midi") ~= "" then sync.midi_seen(proj, id, tk) end -- a new view, not a note edit
            end
          end
          reaper.GetSetMediaTrackInfo_String(t2, "P_EXT:band_drummap", n, true)
        end
      end
    end
    ImGui.EndCombo(ctx)
  end
  ImGui.SetItemTooltip(ctx, "Which notes this track's drum instrument uses. Maps live in <shared folder>/drummaps; 'gm' is General MIDI.")
end

-- Live: hear each other while it happens, through ReaNINJAM and the band's NINJAM server.
local live = require("live")
local live_mode, live_send, live_server = "synced", true, nil
local services = require("services")
local ninjam_dir_edit, srv_at, srv_up = nil, 0, false
local LIVE_MODES = { { "synced", "Play along (synced to the song)" }, { "listen", "Listen live (SonoBus, lowest delay)" }, { "jam", "Jam (NINJAM intervals)" } }

local setup = require("setup")

-- Listen live: SonoBus joins the band's group by itself (BandSync writes it into SonoBus's state).
local sb_link
local function sonobus_open()
  local link, m, i = setup.sonobus(cfg, b, proj, true)
  if not link then return band.msg(m) end
  sb_link = link
  reaper.TrackFX_Show(m, i, 3)
end

local server_at = 0
local function section_live()
  local lfile = band.song_dir(cfg, b.song) .. "/live.json"
  -- the host may fill the address in after this panel opened (it arrives through the shared folder): re-read it
  -- every few seconds while it's still empty here
  if not live_server or (live_server == "" and reaper.time_precise() - server_at > 3) then
    server_at, live_server = reaper.time_precise(), (band.read_json(lfile) or {}).server or ""
  end
  ImGui.SeparatorText(ctx, "Mode")
  for _, m in ipairs(LIVE_MODES) do
    if ImGui.RadioButton(ctx, m[2], live_mode == m[1]) then live_mode = m[1] end
  end
  ImGui.TextWrapped(ctx, ({
    synced = "Your audio is stamped with its song position. Listeners start playback a bar or two after you and hear you in time with the song; what you play also lands on their timeline as a placeholder until your real take arrives (placeholders appear when the listener disconnects: ReaNINJAM only writes its clip log then).",
    listen = "Hear each other as it happens, peer to peer through SonoBus: no server to run. Playing together in time only works when the delay is low (wired internet, roughly the same region); otherwise use Play along.",
    jam = "Classic NINJAM: everyone hears everyone one interval late, so you can all play at once.",
  })[live_mode])
  ImGui.Spacing(ctx)
  if live_mode == "listen" then
    local sm, si = live.fx(proj, false, live.SONOBUS)
    local on = sm and not reaper.TrackFX_GetOffline(sm, si)
    if ImGui.Button(ctx, on and "Open SonoBus##sb" or "Connect##sb") then sonobus_open() end
    ImGui.SetItemTooltip(ctx, "Turns on SonoBus on your master track, already set to join the band's group: it sends your mix and plays the band into it.")
    if on then
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, "Leave##sb") then reaper.TrackFX_SetOffline(sm, si, true) end
      ImGui.TextColored(ctx, GREEN, "SonoBus is on and in the band's group, until you Leave.")
    elseif sm then
      ImGui.TextDisabled(ctx, "SonoBus is ready on your master track (off: it sends nothing until you Connect).")
    end
    if sb_link then
      if ImGui.SmallButton(ctx, "Copy join link") then ImGui.SetClipboardText(ctx, sb_link) end
      ImGui.SetItemTooltip(ctx, "For joining from SonoBus's own app (outside REAPER): its paste button fills the group in.")
    end
    return
  end
  ImGui.SeparatorText(ctx, "Server")
  ImGui.SetNextItemWidth(ctx, 220)
  local changed, v = ImGui.InputTextWithHint(ctx, "##server", "host's Tailscale IP:2049", live_server, ImGui.InputTextFlags_None)
  if changed then live_server = v end
  ImGui.SameLine(ctx)
  if ImGui.SmallButton(ctx, "Save for the band") then
    local data = band.read_json(lfile) or {} -- keep whatever else is in it
    data.server, data.by = live_server, cfg.user
    band.write_json(lfile, data)
  end
  ImGui.SetItemTooltip(ctx, "The host runs the NINJAM server (tools/ninjam-server); everyone connects to its address.")
  if b.role == "host" then -- the host's Connect starts the server here if it isn't running
    ninjam_dir_edit = ninjam_dir_edit or services.ninjam_dir()
    ImGui.SetNextItemWidth(ctx, -150)
    local c2, v2 = ImGui.InputTextWithHint(ctx, "##ninjamdir", "folder with ninjamsrv + bandsync.cfg", ninjam_dir_edit, ImGui.InputTextFlags_None)
    if c2 then ninjam_dir_edit = v2 end
    ImGui.SameLine(ctx)
    if ImGui.SmallButton(ctx, "Use server folder") then reaper.SetExtState(band.SECTION, "ninjam_dir", (ninjam_dir_edit:gsub("\\", "/")), true) end
    if reaper.time_precise() - srv_at > 3 then srv_at, srv_up = reaper.time_precise(), services.running("ninjamsrv") end -- tasklist is slow: not every frame
    ImGui.TextDisabled(ctx, srv_up and "Server: running on this machine" or "Server: not running (Connect starts it)")
  end
  local _, s = ImGui.Checkbox(ctx, "Send my audio (my whole mix)", live_send)
  live_send = s
  ImGui.Spacing(ctx)
  local master, idx = live.fx(proj, false)
  if not master then
    ImGui.BeginDisabled(ctx, live_server == "")
    if ImGui.Button(ctx, "Connect") then
      if b.role == "host" then
        local ok2, why = services.ensure_ninjam()
        if ok2 == "started" then band.log("started the NINJAM server") elseif not ok2 then band.msg("NINJAM server: " .. why) end
      end
      local sdir = (reaper.GetProjectName(proj) ~= "" and reaper.GetProjectPathEx(proj) or reaper.GetResourcePath()):gsub("\\", "/") .. "/bandsync_live"
      reaper.RecursiveCreateDirectory(sdir, 0)
      reaper.SetProjExtState(proj, band.SECTION, "live_dir", sdir)
      local ok, e = live.configure(cfg, live_server, live_mode, live_send, sdir)
      if not ok then band.msg(e) else
        local m2, i2 = live.fx(proj, true)
        if m2 then reaper.TrackFX_Show(m2, i2, 3) else band.msg("Couldn't add ReaNINJAM to the master track.") end
      end
    end
    ImGui.EndDisabled(ctx)
    ImGui.SetItemTooltip(ctx, "Adds ReaNINJAM to your master track with everything filled in: click Connect in its window.")
  else
    ImGui.TextColored(ctx, GREEN, "ReaNINJAM is on your master track.")
    if ImGui.Button(ctx, "Show it") then reaper.TrackFX_Show(master, idx, 3) end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Leave") then reaper.TrackFX_Delete(master, idx) end
  end
  ImGui.TextDisabled(ctx, "If ReaNINJAM was already open since REAPER started, restart REAPER for new settings.")
end

-- Solo edit: one person at a time through the cloud folder, with every checked-in version kept.
local solo = require("solo")
local solo_hist, solo_at, solo_root_edit = {}, 0, nil
local function section_solo()
  solo_root_edit = solo_root_edit or solo.root(cfg)
  ImGui.SetNextItemWidth(ctx, -120)
  local ch, v = ImGui.InputText(ctx, "##soloroot", solo_root_edit, ImGui.InputTextFlags_None)
  if ch then solo_root_edit = v end
  ImGui.SameLine(ctx)
  if ImGui.SmallButton(ctx, "Use this folder") then reaper.SetExtState(band.SECTION, "solo_root", solo_root_edit, true); solo_at = 0 end
  ImGui.SetItemTooltip(ctx, "Where solo versions live: a cloud folder everyone shares (Google Drive works well).")
  if reaper.time_precise() - solo_at > 3 then solo_at = reaper.time_precise(); solo_hist = solo.history(cfg, b.song) end
  local l = solo.lock(cfg, b.song)
  ImGui.SeparatorText(ctx, "Who's editing")
  if not l then ImGui.TextColored(ctx, GREEN, "Nobody: '" .. b.song .. "' is free to check out.")
  elseif l.mine then ImGui.TextColored(ctx, GREEN, "You have it checked out (since " .. local_time(l.since) .. ").")
  elseif l.stale then ImGui.TextColored(ctx, YELLOW, string.format("%s had it, but hasn't been seen for %d min: you can take over.", l.user, math.floor(l.age / 60)))
  else ImGui.TextColored(ctx, RED, string.format("%s is editing (since %s, seen %d s ago). Look, but don't edit.", l.user, local_time(l.since), math.floor(l.age))) end
  if not (l and l.mine) then
    if ImGui.Button(ctx, l and not l.stale and "Open latest to look" or "Check out") then action("Solo edit") end
  else
    if ImGui.Button(ctx, "Check in") then action("Check in") end
  end
  ImGui.SeparatorText(ctx, "Versions, newest first")
  if #solo_hist == 0 then ImGui.TextDisabled(ctx, "None yet. The first check-out starts from the project in front.") end
  if ImGui.BeginChild(ctx, "solohist", 0, -4) then
    for i, h in ipairs(solo_hist) do
      ImGui.PushID(ctx, "s" .. i)
      ImGui.BeginDisabled(ctx, not (l and l.mine) or i == 1)
      if ImGui.SmallButton(ctx, "Restore") and reaper.MB("Go back to " .. (h.user or "?") .. "'s version from " .. local_time(h.time) ..
          "?\n\nWhat you have now is checked in first, so you can come back to it.", "BandSync", 4) == 6 then
        local msg, e = solo.restore(proj, cfg, b.song, h.file)
        band.log(msg or e)
        solo_at, last = 0, 0
      end
      ImGui.EndDisabled(ctx)
      ImGui.SetItemTooltip(ctx, i == 1 and "This is the current version." or "Check out first to restore.")
      ImGui.SameLine(ctx)
      local head = string.format("%s  ·  %s  ·  %d change%s%s", h.user or "?", local_time(h.time), #(h.changes or {}),
        #(h.changes or {}) == 1 and "" or "s", h.note and ("  ·  " .. h.note) or "")
      if ImGui.TreeNodeEx(ctx, "v", head, ImGui.TreeNodeFlags_SpanAvailWidth) then
        for _, line in ipairs(h.changes or {}) do ImGui.BulletText(ctx, line) end
        if (h.printed or 0) > 0 then ImGui.TextDisabled(ctx, h.printed .. " wet print(s) made") end
        ImGui.TreePop(ctx)
      end
      ImGui.PopID(ctx)
    end
    ImGui.EndChild(ctx)
  end
end

-- Set up: everything this project and machine need (lib/setup.lua), and one button for every fix that needs no human.
local setup_at, st = 0, {}
local function section_setup()
  if reaper.time_precise() - setup_at > 5 then setup_at, st = reaper.time_precise(), setup.check(cfg, b, proj) end -- tasklist is slow
  local rows = {
    { st.audio, "Audio device is running", "REAPER's audio device is closed: pick one in Preferences > Audio > Device" },
    { st.folder, "Shared folder is syncing", "Syncthing isn't running" },
    { st.sync, "Live sync is running", "Live sync is off" },
    { st.sonobus, "SonoBus is ready on the master track (Listen live)", "SonoBus isn't on the master track" },
    { st.server, "Live server address is set", b.role == "host" and "Live server address not set (needs Tailscale signed in)" or "Waiting for the host to set the Live server address" },
    { st.solo, "Solo edit folder found", "Solo edit folder not found: " .. tostring(st.solo_root) .. " (share it / add the Drive shortcut, or set it in Solo edit)" },
    { st.latency, "Recording latency checked", st.latency_ms and string.format("Recordings land %.1f ms off: fix the input offset and calibrate again", st.latency_ms) or "Recording latency not checked yet (needs a cable: More > Calibrate latency)" },
  }
  if b.role == "host" then table.insert(rows, 6, { st.ninjam, "NINJAM server is running here", "NINJAM server isn't running (set its folder in the Live tab)" }) end
  local all = true
  for _, r in ipairs(rows) do all = all and r[1] end
  if ImGui.CollapsingHeader(ctx, all and "Set up: all done###setup" or "Set up: needs attention###setup", nil, all and ImGui.TreeNodeFlags_None or ImGui.TreeNodeFlags_DefaultOpen) then
    for _, r in ipairs(rows) do ImGui.TextColored(ctx, r[1] and GREEN or YELLOW, (r[1] and "OK   " or "--   ") .. (r[1] and r[2] or r[3])) end
    if not all then
      if ImGui.Button(ctx, "Set up everything I can") then
        local notes = setup.all(cfg, b, proj, st, function() action("Live sync") end)
        setup_at, live_server = 0, nil -- re-check, and re-read the server address it may have filled in
        if #notes > 0 then band.log("Set up: " .. table.concat(notes, "; ")) end
      end
      ImGui.SetItemTooltip(ctx, "Starts Syncthing and Live sync, adds SonoBus (off), and on the host fills in the Live server address and starts the NINJAM server. The rest needs you: a cable, a sign-in or a share.")
    end
  end
end

local function section_actions()
  ImGui.SeparatorText(ctx, "More")
  for i, name in ipairs({ "Send takes", "Print my MIDI", "Settings", "Calibrate latency", "Update" }) do
    if i > 1 then ImGui.SameLine(ctx) end
    if ImGui.Button(ctx, name) then action(name) end
  end
end

local function frame()
  if reaper.time_precise() - last > 1.5 or reaper.EnumProjects(-1) ~= proj then
    last = reaper.time_precise()
    local ok, e = pcall(refresh)
    err = not ok and tostring(e) or nil
  end
  if err then return ImGui.TextColored(ctx, RED, "Error: " .. err) end
  if not b then
    ImGui.TextWrapped(ctx, "This project isn't a BandSync session yet.")
    if ImGui.Button(ctx, "Publish this project (I'm the host)") then action("Publish session") end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Open a band session / room") then action("Open session") end
    return
  end
  ImGui.Text(ctx, string.format("%s  ·  room %s  ·  %s  ·  you are %s", b.song, b.room, b.role, cfg.user))
  if ImGui.BeginTabBar(ctx, "tabs") then
    if ImGui.BeginTabItem(ctx, "Session") then
      section_setup()
      section_sync()
      section_band()
      section_control()
      section_drums()
      section_actions()
      ImGui.EndTabItem(ctx)
    end
    if ImGui.BeginTabItem(ctx, "Solo edit") then
      section_solo()
      ImGui.EndTabItem(ctx)
    end
    if ImGui.BeginTabItem(ctx, "Live") then
      section_live()
      ImGui.EndTabItem(ctx)
    end
    if ImGui.BeginTabItem(ctx, "History & restore") then
      section_recall()
      section_history()
      ImGui.EndTabItem(ctx)
    end
    ImGui.EndTabBar(ctx)
  end
end

local function loop()
  ImGui.SetNextWindowSize(ctx, 560, 640, ImGui.Cond_FirstUseEver)
  local visible, open = ImGui.Begin(ctx, "BandSync", true)
  if visible then
    local ok, e = pcall(frame) -- an error in our logic must still reach End
    if not ok then err = tostring(e) end
    ImGui.End(ctx)
  end
  if open then reaper.defer(loop) end
end
reaper.defer(loop)
