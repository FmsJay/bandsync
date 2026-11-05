-- The stamp channel: hearing someone record on your own grid, over SonoBus, with no server.
-- The performer's voice goes on the left of SonoBus's stereo send, and on the right, quietly, a burst every half second of song position that
-- says what position it is. The producer's reader finds the bursts, so it knows where in the song each incoming sample belongs whatever the
-- network did, and keeps the voice on a tape by song position. Their playhead reads the tape: however far behind they run, it lines up.
-- Tried before building, through Opus, stereo, voice beside it: every burst read and none out by a sample, 24-192 kb/s, down to -26 dB (0.57).
-- A burst: a 24 ms chirp to find the moment, then 24 bits of "which half second" and 8 of check, two tones at 6 ms a bit.
-- Everything here is this computer's own: both effects sit on the Real time track, which is never mirrored.
local band = require("band")
local stamp = {}

stamp.SEND_NAME, stamp.READ_NAME = "StudioSync stamp send", "StudioSync stamp read"

stamp.SEND = [[
desc:StudioSync stamp send
//tags: StudioSync
// Written by StudioSync (lib/stamp.lua) and rewritten when StudioSync changes it: edits here don't last.
// While the song plays: your sound on the left, a position burst on the right. Stopped: your sound as it is, so you can talk.
slider1:0<0,1,1{Off,On}>Stamp
slider2:0<0,1000,1>Take off your input and output delay (ms)
in_pin:L
in_pin:R
out_pin:Voice
out_pin:Stamp
@init
EVERY = 0.5; LEVEL = 0.05;
CHIRP = 0.024; GAP = 0.004; BIT_LEN = 0.006; F0 = 900; F1 = 1800;
chirp_n = floor(CHIRP * srate); gap_n = floor(GAP * srate); bit_n = floor(BIT_LEN * srate);
total = chirp_n + gap_n + 32 * bit_n;
at = -1; last_k = -1; ph = 0;
function crc8(v) local(c, i, b) (
  c = 165; i = 23; // (from 0, all zeros checked out: a steady tone near F0 read as "position 0", real SonoBus, 0.57.2)
  while (i >= 0) (
    b = ((v >> i) & 1) ~ ((c >> 7) & 1);
    c = (c << 1) & 255;
    b ? c ~= 7;
    i -= 1;
  );
  c;
);
@block
on = slider1 > 0.5 && (play_state & 1);
pos = play_position - slider2 / 1000;
step = 0;
!on ? (at = -1; last_k = -1);
@sample
on ? (
  spl0 = (spl0 + spl1) * 0.5;
  p = pos + step / srate; step += 1;
  k = floor(p / EVERY);
  p >= 0 && k != last_k && at < 0 && p - k * EVERY < 8 / srate ? (
    last_k = k; at = 0; ph = 0;
    hi = k >> 16; lo = k & 65535; word_crc = crc8(k);
  );
  s = 0;
  at >= 0 ? (
    at < chirp_n ? (
      t = at / srate;
      s = sin(2 * $pi * (300 * t + 50000 * t * t));
    ) : at >= chirp_n + gap_n ? (
      b = floor((at - chirp_n - gap_n) / bit_n);
      bit = b < 8 ? (hi >> (7 - b)) & 1 : b < 24 ? (lo >> (23 - b)) & 1 : (word_crc >> (31 - b)) & 1;
      ph += 2 * $pi * (bit ? F1 : F0) / srate;
      s = sin(ph);
    );
    at += 1;
    at >= total ? at = -1;
  );
  spl1 = s * LEVEL;
);
]]

stamp.READ = [[
desc:StudioSync stamp read
//tags: StudioSync
// Written by StudioSync (lib/stamp.lua) and rewritten when StudioSync changes it: edits here don't last.
// Finds the bursts in one person's SonoBus pair, keeps their voice on a tape by song position, and plays the tape at your playhead.
// While they aren't playing and you've heard everything, their live voice comes through: that's talkback.
options:gmem=StudioSyncStamp
slider1:0<0,1,1{Off,On}>Read
slider2:0<0,14,2>Their pair (first channel)
in_pin:1
in_pin:2
in_pin:3
in_pin:4
in_pin:5
in_pin:6
in_pin:7
in_pin:8
in_pin:9
in_pin:10
in_pin:11
in_pin:12
in_pin:13
in_pin:14
in_pin:15
in_pin:16
out_pin:1
out_pin:2
out_pin:3
out_pin:4
out_pin:5
out_pin:6
out_pin:7
out_pin:8
out_pin:9
out_pin:10
out_pin:11
out_pin:12
out_pin:13
out_pin:14
out_pin:15
out_pin:16
@init
ext_noinit = 1; // (REAPER runs @init again when the transport starts, and this one starts just after the first bursts: it lost them and the tape. Real SonoBus, 0.57.2)
EVERY = 0.5; CHIRP = 0.024; GAP = 0.004; BIT_LEN = 0.006; F0 = 900; F1 = 1800;
D = 8; WAIT = floor(0.3 * srate); HOLD = srate | 0; KEEP = floor(0.5 * srate);
n_t = floor(CHIRP * srate / D); bit_n = floor(BIT_LEN * srate); data_at = floor((CHIRP + GAP) * srate);
tmpl = 0; low = 4096; low2 = 8192; ringv = 32768; ring_n = floor(1.2 * srate) | 0;
tape = ringv + ring_n + 1024; tape_n = (__memtop() - tape) | 0;
gone = floor(2 * srate);
// the chirp to look for, as the bursts are heard after keeping every 8th sample
i = 0; sum = 0; e_t = 0;
while (i < n_t) ( t = i * D / srate; tmpl[i] = sin(2 * $pi * (300 * t + 50000 * t * t)); sum += tmpl[i]; i += 1; );
i = 0; while (i < n_t) ( tmpl[i] -= sum / n_t; e_t += tmpl[i] * tmpl[i]; i += 1; );
e_t = sqrt(e_t);
s_now = 0; dcount = 0; dsum = 0; lp = 0; e_lo = 0;
best = 0; best_at = -1; look_until = -1; reading = 0; ready = 0; offset = -1; last_stamp = -1000000000000; next_offset = -1; next_from = 0;
write_end = -1; was_active = 0; count = 0; gaps = 0;
function crc8(v) local(c, i, b) (
  c = 165; i = 23; // (from 0, all zeros checked out: a steady tone near F0 read as "position 0", real SonoBus, 0.57.2)
  while (i >= 0) (
    b = ((v >> i) & 1) ~ ((c >> 7) & 1);
    c = (c << 1) & 255;
    b ? c ~= 7;
    i -= 1;
  );
  c;
);
function tape_write(p, v) local(x) (
  x = p % tape_n; x < 0 ? x += tape_n;
  tape[x] = v;
  x = (p + gone) % tape_n; x < 0 ? x += tape_n;
  tape[x] = 0; // (what an earlier pass left, just ahead of this one)
);
@block
on = slider1 > 0.5;
ch = slider2 | 0;
playing = play_state & 1;
rpos = floor(play_position * srate + 0.5);
@sample
on ? (
  v = spl(ch); r = spl(ch + 1);
  ringv[s_now % ring_n] = v;
  // ---- find a burst, on every 8th sample
  dsum += r; dcount += 1;
  dcount >= D ? (
    y = dsum / D; dsum = 0; dcount = 0;
    e_lo += y * y - low[lp] * low[lp];
    low[lp] = y; lp = (lp + 1) % n_t;
    e_lo > 0.000000001 ? (
      c = 0; i = 0; j = lp;
      while (i < n_t) ( c += tmpl[i] * low[j]; j += 1; j >= n_t ? j = 0; i += 1; );
      score = c / (sqrt(e_lo) * e_t);
      score > 0.6 && reading == 0 && s_now > look_until ? (
        score > best ? ( best = score; best_at = s_now - floor(CHIRP * srate) + 1; settle = s_now + floor(0.004 * srate); );
      );
    );
    best > 0 && s_now >= settle ? (
      reading = 1; read_from = best_at + data_at; bits = 0; bit_i = 0; word_hi = 0; word_lo = 0;
      acc0c = acc0s = acc1c = acc1s = 0; n_acc = 0;
      look_until = best_at + floor(0.3 * srate); burst_at = best_at; best = 0;
      // (the samples since it began are behind us: read them from a short tape of the stamp channel)
    );
  );
  low2[s_now % 16384] = r;
  // ---- read its bits, a little behind, from that short tape
  reading ? (
    while (reading && read_from + n_acc <= s_now) (
      x = low2[(read_from + n_acc) % 16384];
      w0 = 2 * $pi * F0 * n_acc / srate; w1 = 2 * $pi * F1 * n_acc / srate;
      acc0c += x * cos(w0); acc0s += x * sin(w0); acc1c += x * cos(w1); acc1s += x * sin(w1);
      n_acc += 1;
      n_acc >= bit_n ? (
        bit = (acc1c * acc1c + acc1s * acc1s) > (acc0c * acc0c + acc0s * acc0s) ? 1 : 0;
        bit_i < 16 ? word_hi = word_hi * 2 + bit : word_lo = word_lo * 2 + bit;
        bit_i += 1;
        read_from += bit_n; acc0c = acc0s = acc1c = acc1s = 0; n_acc = 0;
        bit_i >= 32 ? (
          reading = 0;
          k = word_hi * 256 + (word_lo >> 8);
          (word_lo & 255) == crc8(k) ? (
            count += 1;
            new_off = floor(k * EVERY * srate + 0.5) - burst_at;
            s_now - last_stamp > HOLD ? (
              // a new pass: what came just before the first burst belongs to it too
              i = max(burst_at - KEEP, s_now - ring_n + 1); i = max(i, s_now - WAIT - KEEP);
              while (i < s_now - WAIT) ( tape_write(i + new_off, ringv[i % ring_n]); i += 1; );
              offset = new_off;
              write_end = s_now - WAIT + new_off;
            ) : ( next_offset = new_off; next_from = burst_at; );
            last_stamp = s_now;
            gmem[0] = count; gmem[1] = k * EVERY;
          ) : ( gmem[6] += 1; );
        );
      );
    );
  );
  // ---- onto the tape, late enough that the burst saying where has been read
  active = s_now - last_stamp < HOLD && last_stamp > 0;
  active ? (
    w = s_now - WAIT;
    next_offset != -1 && w >= next_from ? ( offset = next_offset; next_offset = -1; );
    tape_write(w + offset, ringv[w % ring_n]);
    write_end = w + offset;
  );
  gmem[2] = write_end / srate;
  gmem[5] = active;
  // ---- out: the tape at your playhead; their live voice only when there's nothing still to hear
  out = 0;
  playing ? (
    x = rpos % tape_n; x < 0 ? x += tape_n;
    out = rpos >= 0 ? tape[x] : 0;
    was_ahead = rpos > write_end;
    rpos += 1;
  );
  !active && (!playing || was_ahead) ? out = v;
  spl(ch) = out; spl(ch + 1) = out;
  s_now += 1;
  gmem[3] = rpos / srate;
);
]]

-- -> true, and whether either file had to change.
function stamp.install()
  local dir = reaper.GetResourcePath() .. "/Effects/StudioSync"
  reaper.RecursiveCreateDirectory(dir, 0)
  local changed = false
  for name, text in pairs({ [stamp.SEND_NAME] = stamp.SEND, [stamp.READ_NAME] = stamp.READ }) do
    local path = dir .. "/" .. name .. ".jsfx"
    if band.read(path) ~= text then
      local f = io.open(path, "wb")
      if not f then return nil end
      f:write(text)
      f:close()
      changed = true
    end
  end
  return true, changed
end

local function find(tr, name)
  for i = 0, reaper.TrackFX_GetCount(tr) - 1 do
    if select(2, reaper.TrackFX_GetFXName(tr, i, "")):find(name, 1, true) then return i end
  end
end
-- One of them on the Real time track: the sender before SonoBus, the reader after it.
local checked = false
local function place(tr, name, first)
  local i = find(tr, name)
  if not checked then -- (once per run: an effect already loaded keeps the old code until it's put on again)
    checked = true
    local ok, changed = stamp.install()
    if not ok then return nil end
    if changed and i then reaper.TrackFX_Delete(tr, i); i = nil end
  end
  if not i then
    if not stamp.install() then return nil end
    i = reaper.TrackFX_AddByName(tr, "JS:StudioSync/" .. name .. ".jsfx", false, -1)
    if i < 0 then return nil end
  end
  local want = first and 0 or reaper.TrackFX_GetCount(tr) - 1
  if i ~= want then reaper.TrackFX_CopyToTrack(tr, i, tr, want, true); i = want end
  return i
end

-- This computer sends stamps (someone's producing it), or stops. delay_ms: this computer's input and output delay, so the stamp says where they
-- played it, not where it left: a singer on time to what they heard is that much late by the time it's here. REAPER takes the same off a take.
function stamp.send(proj, on, delay_ms)
  local tr = require("live").rt_track(proj, on)
  if not tr then return false end
  local i = find(tr, stamp.SEND_NAME)
  if on then i = place(tr, stamp.SEND_NAME, true) end
  if not i then return not on end
  reaper.TrackFX_SetParam(tr, i, 0, on and 1 or 0)
  reaper.TrackFX_SetParam(tr, i, 1, delay_ms or 0)
  return true
end
-- This computer reads one person's pair (first channel `start`), or stops.
function stamp.read(proj, on, start)
  local tr = require("live").rt_track(proj, on)
  if not tr then return false end
  local i = find(tr, stamp.READ_NAME)
  if on then i = place(tr, stamp.READ_NAME, false) end
  if not i then return not on end
  reaper.TrackFX_SetParam(tr, i, 0, on and 1 or 0)
  if on then reaper.TrackFX_SetParam(tr, i, 1, start or 0) end
  return true
end
-- What the reader's found, for this computer: { count, pos (the newest stamp's song position), written (how far the tape goes), active (they're playing), at (your playhead) }.
function stamp.status()
  if reaper.gmem_attach then reaper.gmem_attach("StudioSyncStamp") end
  return { count = reaper.gmem_read(0), pos = reaper.gmem_read(1), written = reaper.gmem_read(2), at = reaper.gmem_read(3), active = reaper.gmem_read(5) > 0.5 }
end

return stamp
