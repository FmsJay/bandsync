-- @description BandSync: live sync for this project (runs in the background; run again to stop)
-- Keeps this project in step with the band:
--   * your new recordings go out by themselves a moment after you stop (slivers under 0.5 s are skipped);
--     what was already in the project when sync first ran stays put (send it with "Send takes" if wanted)
--   * everyone's takes arrive in the song's comping style (lanes or takes), preview first, then full quality
--   * the session driver's deletes, moves/trims and which take or lane plays are mirrored here
-- Never touches the project while recording.
local dir = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
package.path = dir .. "/lib/?.lua;" .. package.path
local band = require("band")
local sync = require("sync")

local cfg = band.settings()
if not cfg then return end
local proj = reaper.EnumProjects(-1)
local b = band.binding(proj)
if not b then return band.msg("Publish (host) or open (guest) a session in this project first.") end
local host = b.role == "host"
local s0 = band.read_json(band.session_path(cfg, b.song)) or {}
local mode = b.take_mode or "mirror" -- rebuild each sender's lanes and multi-take items as they are
local baseline = sync.mark_baseline(proj)

local _, _, section, cmd = reaper.get_action_context()
local function toggle(v)
  if cmd > 0 then reaper.SetToggleCommandState(section, cmd, v); reaper.RefreshToolbar2(section, cmd) end
end
toggle(1)
reaper.atexit(function() toggle(0) end)

local sizes, warned_version, last, recording, stopped_at = {}, nil, 0, false, 0
local last_reprint, last_status, status_json = 0, 0, ""
-- A file is ready once it exists, is non-empty, and its size held still across two polls.
local function ready(path)
  local n = band.size(path)
  local ok = n and n > 0 and sizes[path] == n
  sizes[path] = n
  return ok
end

local function import(room)
  local tdir = band.takes_dir(cfg, b.song, room)
  for _, f in ipairs(band.files(tdir, ".json")) do
    local t = band.read_json(tdir .. "/" .. f)
    if t and t.id and t.full then
      band.check_version(t.bandsync, "A take from " .. t.user, true)
      local state = band.take_state(proj, t.id)
      local full, prev = tdir .. "/" .. t.full, t.preview and (tdir .. "/" .. t.preview)
      local dry = t.dry and (tdir .. "/" .. t.dry)
      local rev, held = t.rev or 1, tonumber(sync.ext(proj, sync.REV, t.id)) or 1
      local midi = t.midi and (tdir .. "/" .. t.midi)
      local function place_midi() -- the notes, as an editable MIDI copy under the print
        if not midi or not reaper.file_exists(midi) then return end
        local _, mtk = band.place_midi(proj, t, midi, cfg.root)
        if mtk then sync.midi_seen(proj, t.id, mtk) end
      end
      local _, mine = band.find_take(proj, t.id)
      if mine and band.take_ext(mine, "band_sent") == "" then mine = nil end
      if state == "full" and rev > held and mine then -- someone printed our MIDI take with their instrument
        sync.setext(proj, sync.REV, t.id, tostring(rev))
        sync.setext(proj, sync.PRINTER, t.id, t.printed_by or "")
        band.log(string.format("%s printed your take %s with their own sound: the band hears theirs now", tostring(t.printed_by), t.id))
      elseif state == "full" and rev > held then -- reprinted (FX/volume/note change): update in place
        if ready(full) and (not dry or ready(dry)) then
          reaper.Undo_BeginBlock2(proj)
          local ok = band.update_take(proj, t, full, dry)
          if ok then place_midi() end
          reaper.Undo_EndBlock2(proj, "BandSync: updated take from " .. t.user, -1)
          if ok then
            sync.setext(proj, sync.REV, t.id, tostring(rev))
            sync.setext(proj, sync.PRINTER, t.id, t.printed_by or "")
            band.log(string.format("take from %s updated (revision %d%s) -> %s", t.user, rev,
              (t.printed_by and t.printed_by ~= t.user) and (", printed by " .. t.printed_by) or "", t.track))
          end
        end
      elseif state ~= "full" and state ~= "deleted" then -- "full" also covers takes this project sent itself
        local want, path
        if ready(full) and (not dry or ready(dry)) then want, path = "full", full
        elseif state == "" and prev and ready(prev) then want, path = "preview", prev end
        if want then
          reaper.Undo_BeginBlock2(proj)
          local ok = band.place_take(proj, t, path, mode, want == "full" and dry or nil)
          if ok then place_midi() end
          reaper.Undo_EndBlock2(proj, "BandSync: " .. want .. " take from " .. t.user, -1)
          if ok then
            band.set_take_state(proj, t.id, want)
            sync.setext(proj, sync.REV, t.id, tostring(rev))
            sync.setext(proj, sync.PRINTER, t.id, t.printed_by or "")
            local pending = sync.ext(proj, sync.PENDING, t.id) -- brought back by a recall point: put it where that had it
            if pending ~= "" then
              local p = band.json_decode(pending)
              if p then sync.apply(proj, { type = "edit", take = t.id, track = p.track, pos = p.pos, len = p.len, lane = p.lane, mute = p.mute, offs = p.offs }) end
              sync.setext(proj, sync.PENDING, t.id, "")
            end
            band.log(string.format("%s take from %s (%s) -> %s", want, t.user, room, t.track))
          end
        end
      end
    end
  end
end

local last_driver
local function poll()
  local s = band.read_json(band.session_path(cfg, b.song))
  local can, who = sync.authority(cfg, b.song, b.room, s)
  local driver = who.driver
  if last_driver and driver ~= last_driver then -- handovers are announced, never silent
    band.log(driver == cfg.user and "you're driving now" or (tostring(driver) .. " took control" ..
      (last_driver == cfg.user and ": you're no longer driving (what you don't own is view-only)" or "")))
  end
  last_driver = driver
  local rooms = host and band.subdirs(band.song_dir(cfg, b.song) .. "/rooms") or { b.room }
  for _, room in ipairs(rooms) do
    import(room)
    local room_can = room == b.room and can or sync.authority(cfg, b.song, room, s)
    local n = sync.receive(proj, cfg, b.song, room, room_can)
    if n > 0 then band.log(n .. " change(s) from the band (" .. room .. ")") end
  end

  -- Hold sync: keep working without sending anything; releasing it sends the net result once
  local hold = select(2, reaper.GetProjExtState(proj, band.SECTION, "hold")) ~= ""

  -- our own new recordings go out once the transport has been stopped for a moment, and takes whose
  -- sound changed are reprinted (rendering needs this tab in front and the transport stopped)
  local print_mode = (s and s.print) or "wet"
  local now = reaper.time_precise()
  local copies = sync.split_copies(proj) -- pasted/duplicated/split items: new material, not the original
  if copies > 0 then band.log(copies .. " copied or split item(s) will go out as new takes") end
  if not hold and reaper.EnumProjects(-1) == proj and reaper.GetPlayStateEx(proj) == 0 and now - stopped_at > 1.5 then
    local units = sync.own_takes(proj, { all = true, unsent = true, min_len = sync.MIN_LEN })
    if #units > 0 then band.log("sent " .. sync.send(proj, cfg, b, units, print_mode) .. " new take(s)") end
    if now - last_reprint > 10 then
      last_reprint = now
      local n = sync.reprint(proj, cfg, b, print_mode)
      if n > 0 then band.log("reprinted " .. n .. " take(s) after a sound change") end
    end
  end

  -- what we may change (owned tracks/regions, or everything unclaimed while driving) goes out; the rest
  -- is view-only (locked) so it can't silently drift from the band's version
  if not hold then sync.watch(proj, cfg, b.song, b.room, can) end
  sync.apply_locks(proj, can, cfg.user)

  -- status receipt for the Status window: written when it changes, else every 15 s as a heartbeat
  -- pending + hold let "Take control" wait until everyone has caught up before switching
  local info = { driver = driver, role = b.role, song = b.song, hold = hold or nil,
    pending = sync.pending_events(proj, cfg, b.song, b.room) }
  local fingerprint = band.json_encode(sync.holdings(proj)) .. tostring(driver) .. info.pending .. tostring(hold)
  if fingerprint ~= status_json or now - last_status > 15 then
    status_json, last_status = fingerprint, now
    sync.write_status(proj, cfg, b.song, b.room, info)
  end

  if s then band.check_version(s.bandsync, "'" .. b.song .. "'", true) end
  if s and not host then
    if band.sync_stems(proj, cfg, b.song, s, true) > 0 then band.log("upgraded stems to full quality") end
    if tostring(s.version) ~= tostring(b.version) and warned_version ~= s.version then
      warned_version = s.version
      band.log(s.host .. " published v" .. s.version .. ": run 'BandSync - Open session' to refresh")
    end
  end
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
end

-- The panel stops us with a flag (re-running the action would raise REAPER's task-control dialog), and sees
-- we're alive from a heartbeat; both live in non-persistent ExtState so the project isn't marked modified.
local key = tostring(proj)
local function tick()
  if not reaper.ValidatePtr2(0, proj, "ReaProject*") then return end -- project closed: stop
  if reaper.GetExtState(band.SECTION, "stop " .. key) ~= "" then
    reaper.DeleteExtState(band.SECTION, "stop " .. key, false)
    reaper.DeleteExtState(band.SECTION, "live " .. key, false)
    return band.log("live sync stopped for '" .. b.song .. "'")
  end
  reaper.SetExtState(band.SECTION, "live " .. key, tostring(reaper.time_precise()), false)
  local st = reaper.GetPlayStateEx(proj)
  if st & 4 ~= 0 then recording = true
  elseif recording then recording, stopped_at = false, reaper.time_precise() end
  if not recording and reaper.time_precise() - last > 2 then
    last = reaper.time_precise()
    local ok, err = pcall(poll)
    if not ok then band.log("sync error: " .. tostring(err)) end
  end
  reaper.defer(tick)
end

band.log(string.format("live sync for '%s' (%s, room %s, takes as %s, driver %s)%s", b.song, b.role, b.room, mode,
  tostring(sync.driver(cfg, b.song, b.room, s0)), baseline > 0 and (", " .. baseline .. " existing take(s) left as baseline") or ""))
tick()
