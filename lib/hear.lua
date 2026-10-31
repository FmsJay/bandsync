-- Who you hear live, and in whose time. SonoBus (Real time mode's own track) sends each bandmate to their own output
-- pair (lib/sonobus.lua set_outputs writes that into its per-person cache), the track passes all 16 channels on to the
-- master's channels 3-18, and BandSync's live mix there turns each person up, down or off and puts everything back on
-- 1-2. "Their time" delays your own backing instead, so what arrives late lines up with it. Everything here is this
-- machine's own: the mix is never sent (mirror.live_fx), and the switches live in the project, not in the band's files.
local band = require("band")
local hear = {}

hear.NAME = "BandSync live mix"
hear.PAIRS = 8 -- SonoBus pairs on the Real time track: 1 for everyone without their own, 7 for bandmates
hear.MAX_MS = 1000

hear.JSFX = [[
desc:BandSync live mix
//tags: BandSync
// Written by BandSync (lib/hear.lua) and rewritten when BandSync changes it: edits here don't last.
// Channels 1-2: your own backing and playing. 3-18: what SonoBus brings in, a pair per person (3-4: everyone without
// their own pair). Out on 1-2: the backing (delayed by "their time") plus each person at their level.
slider1:0<0,1000,1>Their time: your backing later by (ms)
slider2:1<0,2,0.01>Everyone else
slider3:1<0,2,0.01>Bandmate 1
slider4:1<0,2,0.01>Bandmate 2
slider5:1<0,2,0.01>Bandmate 3
slider6:1<0,2,0.01>Bandmate 4
slider7:1<0,2,0.01>Bandmate 5
slider8:1<0,2,0.01>Bandmate 6
slider9:1<0,2,0.01>Bandmate 7
in_pin:backing L
in_pin:backing R
in_pin:everyone else L
in_pin:everyone else R
in_pin:bandmate 1 L
in_pin:bandmate 1 R
in_pin:bandmate 2 L
in_pin:bandmate 2 R
in_pin:bandmate 3 L
in_pin:bandmate 3 R
in_pin:bandmate 4 L
in_pin:bandmate 4 R
in_pin:bandmate 5 L
in_pin:bandmate 5 R
in_pin:bandmate 6 L
in_pin:bandmate 6 R
in_pin:bandmate 7 L
in_pin:bandmate 7 R
out_pin:L
out_pin:R
out_pin:none 3
out_pin:none 4
out_pin:none 5
out_pin:none 6
out_pin:none 7
out_pin:none 8
out_pin:none 9
out_pin:none 10
out_pin:none 11
out_pin:none 12
out_pin:none 13
out_pin:none 14
out_pin:none 15
out_pin:none 16
out_pin:none 17
out_pin:none 18
@init
maxd = srate * 1.1 | 0;
buf = 0;
pos = 0;
@slider
d = min(slider1 * srate / 1000 | 0, maxd - 1);
@sample
buf[pos * 2] = spl0; buf[pos * 2 + 1] = spl1;
rp = pos - d; rp < 0 ? rp += maxd;
l = buf[rp * 2]; r = buf[rp * 2 + 1];
pos += 1; pos >= maxd ? pos = 0;
l += slider2 * spl2 + slider3 * spl4 + slider4 * spl6 + slider5 * spl8 + slider6 * spl10 + slider7 * spl12 + slider8 * spl14 + slider9 * spl16;
r += slider2 * spl3 + slider3 * spl5 + slider4 * spl7 + slider5 * spl9 + slider6 * spl11 + slider7 * spl13 + slider8 * spl15 + slider9 * spl17;
spl0 = l; spl1 = r;
spl2 = spl3 = spl4 = spl5 = spl6 = spl7 = spl8 = spl9 = spl10 = spl11 = spl12 = spl13 = spl14 = spl15 = spl16 = spl17 = 0;
]]

-- The effect file, in REAPER's Effects folder (rewritten only when it differs). Returns its name for TrackFX_AddByName.
function hear.install()
  local dir = reaper.GetResourcePath() .. "/Effects/BandSync"
  local path = dir .. "/BandSync live mix.jsfx"
  if band.read(path) ~= hear.JSFX then
    reaper.RecursiveCreateDirectory(dir, 0)
    local f = io.open(path, "wb")
    if not f then return nil end
    f:write(hear.JSFX)
    f:close()
  end
  return "JS:BandSync/BandSync live mix.jsfx"
end

-- The live mix on the master (added when `add`), and its index.
function hear.mix(proj, add)
  local m = reaper.GetMasterTrack(proj)
  for i = 0, reaper.TrackFX_GetCount(m) - 1 do
    if select(2, reaper.TrackFX_GetFXName(m, i, "")):find(hear.NAME, 1, true) then return m, i end
  end
  if not add then return nil end
  local name = hear.install()
  local i = name and reaper.TrackFX_AddByName(m, name, false, -1) or -1
  if i < 0 then return nil end
  return m, i
end

-- Wire it: the Real time track keeps 16 channels and feeds the master's 3-18; the master gets the channels for them,
-- and the mix sits last on it (after any master plug-ins of the band's, which then only touch the backing).
function hear.route(proj, rt)
  local m, i = hear.mix(proj, true)
  if not m then return false end
  if reaper.GetMediaTrackInfo_Value(m, "I_NCHAN") < 2 + 2 * hear.PAIRS then reaper.SetMediaTrackInfo_Value(m, "I_NCHAN", 2 + 2 * hear.PAIRS) end
  if rt then
    if reaper.GetMediaTrackInfo_Value(rt, "I_NCHAN") < 2 * hear.PAIRS then reaper.SetMediaTrackInfo_Value(rt, "I_NCHAN", 2 * hear.PAIRS) end
    reaper.SetMediaTrackInfo_Value(rt, "C_MAINSEND_OFFS", 2)
    reaper.SetMediaTrackInfo_Value(rt, "C_MAINSEND_NCH", 0)
  end
  local last = reaper.TrackFX_GetCount(m) - 1
  if i ~= last then reaper.TrackFX_CopyToTrack(m, i, m, last, true) end
  return true
end

-- Who gets their own pair: the room's bandmates (everyone with a Who's here file, here now or not), in name order so
-- it doesn't shuffle as people come and go; the first 7. { [name] = first SonoBus output channel, 0-based }. Pure
-- apart from reading the folder.
function hear.order(names, me)
  local list, out = {}, {}
  for _, n in ipairs(names) do if n ~= me then list[#list + 1] = n end end
  table.sort(list)
  for k = 1, math.min(#list, hear.PAIRS - 1) do out[list[k]] = 2 * k end
  return out
end
function hear.bandmates(cfg, b)
  local dir, names, seen = require("sync").room_dir(cfg, b.song, b.room or "main") .. "/status", {}, {}
  for _, f in ipairs(band.files(dir, ".json")) do
    local st = band.read_json(dir .. "/" .. f)
    if type(st) == "table" and type(st.user) == "string" and not seen[st.user] then seen[st.user] = true; names[#names + 1] = st.user end
  end
  return names
end

-- The pairs written into SonoBus here (by setup.sonobus), as the project remembers them.
function hear.pairs(proj)
  return band.json_decode(select(2, reaper.GetProjExtState(proj, band.SECTION, "hear pairs"))) or {}
end
function hear.set_pairs(proj, outs) reaper.SetProjExtState(proj, band.SECTION, "hear pairs", band.json_encode(outs)) end

-- Hearing one person (or "everyone else", name nil): their level in the mix, 1 or 0.
local function slot(proj, name)
  local start = name and hear.pairs(proj)[name]
  return start and (start // 2 + 1) or 1 -- (param 0 is the delay, 1 is everyone else, 2.. the bandmates' pairs)
end
function hear.is_on(proj, name)
  local m, i = hear.mix(proj, false)
  return not m or reaper.TrackFX_GetParam(m, i, slot(proj, name)) > 0.001
end
function hear.set_on(proj, name, on)
  local m, i = hear.mix(proj, false)
  if m then reaper.TrackFX_SetParam(m, i, slot(proj, name), on and 1 or 0) end
end
-- Whether `name` has a pair of their own here (else they share "everyone else" with anyone else without one).
function hear.own_pair(proj, name) return hear.pairs(proj)[name] ~= nil end

-- Their time: your backing later by ms (0 = your own time).
function hear.delay(proj)
  local m, i = hear.mix(proj, false)
  return m and reaper.TrackFX_GetParam(m, i, 0) or 0
end
function hear.set_delay(proj, ms)
  local m, i = hear.mix(proj, false)
  if m then reaper.TrackFX_SetParam(m, i, 0, math.max(0, math.min(hear.MAX_MS, ms))) end
end

return hear
