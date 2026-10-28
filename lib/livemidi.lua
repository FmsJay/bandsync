-- Live MIDI view: while someone records MIDI, the notes they play show up on everyone else's timeline a few seconds
-- later (as fast as the shared folder syncs), growing as they play. You hear their instrument through Listen live;
-- this shows what's being recorded. The placeholder is muted (their sound comes over the audio stream) and goes as
-- soon as their real take arrives (live.retire: any take of theirs sent after they started).
--   rooms/<room>/live_midi/<user>/<since>-<nnnn>.json   { user, since = "YYYYMMDD-HHMMSSZ", time, at, done, parts = { [track] = { {s, e, p, v} } } }
-- Every second while recording the recorder writes the whole picture so far as a NEW file (and removes the one
-- before last): one file rewritten twice a second never synced while it kept changing (2026-10-28, laptop -> PC:
-- nothing until the recording stopped). Receivers read each bandmate's newest file.
local band = require("band")
local sync = require("sync")
local live = require("live")
local lm = {}

local function dir(cfg, b) return sync.room_dir(cfg, b.song, b.room) .. "/live_midi" end
local function safe(user) return (user:gsub("[^%w%-_ ]", "")) end

-- Which armed tracks take this MIDI event (device and channel as their record input says). Pure but for reaper reads.
local function armed_midi(proj)
  local out = {}
  for t = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, t)
    local input = reaper.GetMediaTrackInfo_Value(tr, "I_RECINPUT")
    if reaper.GetMediaTrackInfo_Value(tr, "I_RECARM") == 1 and input >= 0 and input & 4096 ~= 0 then
      out[#out + 1] = { name = sync.base_name(select(2, reaper.GetTrackName(tr))), dev = (input >> 5) & 63, chan = input & 31 }
    end
  end
  return out
end
function lm.takes(t, dev, status) -- t: one armed track; dev: the event's device index. Pure.
  return (t.dev == 63 or t.dev == (dev & 0xFFFF)) and (t.chan == 0 or t.chan == (status & 15) + 1)
end

-- ---- the recorder's side ----------------------------------------------------------------------------------
local rec -- { since, parts, open, tracks, last_seq, wrote_at, changed }
local function latest_seq() return (reaper.MIDI_GetRecentInputEvent(0)) end

-- Call on every Live sync tick with whether we're recording now.
function lm.send_tick(proj, cfg, b, recording)
  if recording and rec == nil then
    local tracks = armed_midi(proj)
    if #tracks == 0 then rec = false; return end -- recording audio only: nothing to show
    rec = { since = os.date("!%Y%m%d-%H%M%SZ"), parts = {}, open = {}, tracks = tracks, last_seq = latest_seq(), wrote_at = 0, n = 0 }
    local udir = dir(cfg, b) .. "/" .. safe(cfg.user) -- an earlier recording's files: not needed any more
    for _, f in ipairs(band.files(udir, ".json")) do os.remove(udir .. "/" .. f) end
    os.remove(dir(cfg, b) .. "/" .. safe(cfg.user) .. ".json") -- (0.15.1-0.15.2 kept one file per person)
  end
  if not rec then
    if not recording then rec = nil end -- (false: this recording had no MIDI track armed)
    return
  end
  -- new input since last look, oldest first
  local new, i = {}, 0
  local newest = latest_seq() -- (idx 0 latches the history)
  while i < 4000 do
    local seq, buf, _, dev, pos = reaper.MIDI_GetRecentInputEvent(i)
    if seq == 0 or seq == rec.last_seq then break end
    new[#new + 1] = { buf = buf, dev = dev, pos = pos }
    i = i + 1
  end
  rec.last_seq = newest
  for k = #new, 1, -1 do
    local e = new[k]
    local st, p, v = e.buf:byte(1) or 0, e.buf:byte(2) or 0, e.buf:byte(3) or 0
    local kind = st & 0xF0
    if e.pos >= 0 and (kind == 0x90 or kind == 0x80) then
      for _, t in ipairs(rec.tracks) do
        if lm.takes(t, e.dev, st) then
          local key = t.name .. "\0" .. (st & 15) .. ":" .. p
          if kind == 0x90 and v > 0 then
            local n = { s = e.pos, p = p, v = v }
            rec.parts[t.name] = rec.parts[t.name] or {}
            table.insert(rec.parts[t.name], n)
            rec.open[key] = n
          elseif rec.open[key] then
            rec.open[key].e = e.pos
            rec.open[key] = nil
          end
          rec.changed = true
        end
      end
    end
  end
  if not recording then -- stopped (the last notes read above): notes still held end where we stopped; receivers
    -- keep showing them until our take arrives
    for _, n in pairs(rec.open) do n.e = n.e or rec.at end
    rec.done = true
    lm.write(cfg, b, rec.at)
    rec = nil
    return
  end
  rec.at = reaper.GetPlayPosition2Ex(proj)
  -- every second, changed or not: a held note or a pause still moves "at", so their view keeps growing
  if reaper.time_precise() - rec.wrote_at >= 1 then lm.write(cfg, b, rec.at) end
end

function lm.write(cfg, b, at)
  if not rec then return end
  local udir = dir(cfg, b) .. "/" .. safe(cfg.user)
  reaper.RecursiveCreateDirectory(udir, 0)
  rec.n = rec.n + 1
  band.write_json(string.format("%s/%s-%04d.json", udir, rec.since, rec.n), { user = cfg.user, since = rec.since,
    time = os.date("!%Y-%m-%dT%H:%M:%SZ"), at = at, done = rec.done or nil, parts = rec.parts })
  if rec.n > 2 then os.remove(string.format("%s/%s-%04d.json", udir, rec.since, rec.n - 2)) end -- (one spare while it syncs)
  rec.wrote_at, rec.changed = reaper.time_precise(), false
end

-- ---- everyone else's side ---------------------------------------------------------------------------------
local shown = {} -- user -> what was last drawn (so unchanged streams aren't redrawn)
local tidied_at = -math.huge

-- Placeholders go when their real take arrives (live.retire); one whose take never came (deleted, or REAPER closed
-- before sending) goes 15 minutes after its recording began.
local function tidy(proj)
  live.retire(proj)
  for i = reaper.CountMediaItems(proj) - 1, 0, -1 do
    local it = reaper.GetMediaItem(proj, i)
    local y, mo, d, H, M, S = band.item_ext(it, "band_live"):match("^midi:(%d%d%d%d)(%d%d)(%d%d)%-(%d%d)(%d%d)(%d%d)Z")
    if y and band.age(string.format("%s-%s-%sT%s:%s:%sZ", y, mo, d, H, M, S)) > 900 then
      reaper.DeleteTrackMediaItem(reaper.GetMediaItem_Track(it), it)
    end
  end
end

-- Draw every bandmate's stream as a muted MIDI placeholder on their "(live)" track. Call every half second or so.
function lm.receive_tick(proj, cfg, b)
  if reaper.time_precise() - tidied_at > 2 then tidied_at = reaper.time_precise(); tidy(proj) end
  for _, u in ipairs(band.subdirs(dir(cfg, b))) do
    local files = band.files(dir(cfg, b) .. "/" .. u, ".json") -- sorted: the newest is last
    local s = files[1] and band.read_json(dir(cfg, b) .. "/" .. u .. "/" .. files[#files])
    if type(s) == "table" and type(s.user) == "string" and s.user ~= cfg.user and type(s.parts) == "table"
        and type(s.since) == "string" and band.age(s.time) < 600 then
      local sig = s.since .. "|" .. tostring(s.time) .. "|" .. tostring(s.done)
      if shown[s.user] ~= sig then
        shown[s.user] = sig
        lm.draw(proj, s)
      end
    end
  end
end

function lm.draw(proj, s)
  local name = s.user .. live.TRACK_SUFFIX
  local tr = band.find_track(proj, name) or band.new_track(proj, name)
  if not tr then return end
  reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_live_track", "1", true)
  for part, notes in pairs(s.parts) do
    if type(notes) == "table" and #notes > 0 then
      local tag = "midi:" .. s.since .. ":" .. part
      local it
      for j = 0, reaper.CountTrackMediaItems(tr) - 1 do
        local x = reaper.GetTrackMediaItem(tr, j)
        if band.item_ext(x, "band_live") == tag then it = x end
      end
      local from, to = math.huge, tonumber(s.at) or 0
      for _, n in ipairs(notes) do from = math.min(from, n.s); to = math.max(to, n.e or n.s) end
      if not it then
        it = reaper.CreateNewMIDIItemInProj(tr, from, to + 0.5)
        if not it then return end
        band.set_item_ext(it, "band_live", tag) -- someone else's: never sent as ours (sync.own_takes)
        band.set_item_ext(it, "band_live_since", s.since) -- live.retire: goes when a take of theirs sent since arrives
        reaper.SetMediaItemInfo_Value(it, "B_MUTE", 1) -- you hear them over Listen live; this only shows the notes
      else
        reaper.SetMediaItemInfo_Value(it, "D_LENGTH", math.max(0.5, to + 0.5 - reaper.GetMediaItemInfo_Value(it, "D_POSITION")))
      end
      local tk = reaper.GetActiveTake(it)
      reaper.GetSetMediaItemTakeInfo_String(tk, "P_NAME", part .. (s.done and " (recorded, take on its way)" or " (recording...)"), true)
      for k = select(2, reaper.MIDI_CountEvts(tk)) - 1, 0, -1 do reaper.MIDI_DeleteNote(tk, k) end
      for _, n in ipairs(notes) do
        local a = reaper.MIDI_GetPPQPosFromProjTime(tk, n.s)
        local z = reaper.MIDI_GetPPQPosFromProjTime(tk, n.e or math.max(n.s + 0.05, to))
        reaper.MIDI_InsertNote(tk, false, false, a, math.max(z, a + 1), 0, n.p, n.v, true)
      end
      reaper.MIDI_Sort(tk)
      reaper.UpdateItemInProject(it)
    end
  end
end

return lm
