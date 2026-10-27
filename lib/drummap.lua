-- Drum maps: every drum VST puts kick, snare, hats... on its own notes. A MIDI drum take travels in its
-- player's map, named in the take; each receiver translates it into the map of their own drum track, and
-- note edits travel back the same way. Translation goes through named drum sounds: General MIDI's
-- percussion names, plus finer articulations that fall back to the nearest GM sound where a map lacks them.
-- Maps are JSON files { "name": "...", "notes": { "<sound>": <note>, ... } } in <shared folder>/drummaps,
-- so the whole band uses the same ones. Notes no map knows pass through unchanged.
local drummap = {}

-- General MIDI percussion (note 35-81).
drummap.GM = {
  kick_acoustic = 35, kick = 36, side_stick = 37, snare = 38, clap = 39, snare_electric = 40,
  tom_floor_low = 41, hihat_closed = 42, tom_floor_high = 43, hihat_pedal = 44, tom_low = 45,
  hihat_open = 46, tom_low_mid = 47, tom_high_mid = 48, crash = 49, tom_high = 50, ride = 51,
  china = 52, ride_bell = 53, tambourine = 54, splash = 55, cowbell = 56, crash_2 = 57, vibraslap = 58,
  ride_2 = 59, bongo_high = 60, bongo_low = 61, conga_mute = 62, conga_high = 63, conga_low = 64,
  timbale_high = 65, timbale_low = 66, agogo_high = 67, agogo_low = 68, cabasa = 69, maracas = 70,
  whistle_short = 71, whistle_long = 72, guiro_short = 73, guiro_long = 74, claves = 75,
  woodblock_high = 76, woodblock_low = 77, cuica_mute = 78, cuica_open = 79, triangle_mute = 80, triangle_open = 81,
}

-- Articulations finer than GM, and the GM sound each falls back to.
drummap.FALLBACK = {
  snare_rimshot = "snare", snare_flam = "snare", snare_ghost = "snare", snare_roll = "snare", snare_rim_click = "side_stick",
  hihat_half_open = "hihat_open", hihat_quarter_open = "hihat_closed", hihat_tip = "hihat_closed", hihat_shank = "hihat_closed",
  hihat_splash = "hihat_open", hihat_choke = "hihat_closed",
  ride_edge = "ride", ride_crash = "crash", crash_choke = "crash", crash_2_choke = "crash_2", china_choke = "china",
  splash_choke = "splash", tom_floor_low_rim = "tom_floor_low", tom_high_rim = "tom_high", kick_2 = "kick",
}

local function sound_note(map, sound)
  local n = map.notes[sound]
  local back = drummap.FALLBACK[sound]
  return n or (back and (map.notes[back] or drummap.GM[back])) or drummap.GM[sound]
end

-- note -> sound for one map. Where a map puts several sounds on one note, the GM-named one wins, then the
-- alphabetically first, so the result doesn't depend on table order.
local function reverse(map)
  local r = {}
  for sound, n in pairs(map.notes) do
    local cur = r[n]
    if not cur or (drummap.GM[sound] and not drummap.GM[cur]) or ((drummap.GM[sound] ~= nil) == (drummap.GM[cur] ~= nil) and sound < cur) then
      r[n] = sound
    end
  end
  return r
end

-- note -> note table taking `from` to `to` (both { notes = {...} }); nil when nothing changes.
function drummap.table(from, to)
  if not from or not to or from == to then return nil end
  local r, t, any = reverse(from), {}, false
  for n, sound in pairs(r) do
    local m = sound_note(to, sound)
    if m and m ~= n then t[n], any = m, true end
  end
  return any and t or nil
end

-- Rewrite note numbers in a MIDI_GetAllEvts buffer (note on/off and poly aftertouch on every channel).
function drummap.translate(buf, t)
  if not t then return buf end
  local out, pos = {}, 1
  while pos <= #buf do
    local offset, flags, msg, nxt = string.unpack("i4Bs4", buf, pos)
    local st = msg:byte(1)
    if st and #msg >= 2 and (st & 0xF0 == 0x80 or st & 0xF0 == 0x90 or st & 0xF0 == 0xA0) then
      local n = t[msg:byte(2)]
      if n then msg = string.char(st, n) .. msg:sub(3) end
    end
    out[#out + 1] = string.pack("i4Bs4", offset, flags, msg)
    pos = nxt
  end
  return table.concat(out)
end

drummap.GM_MAP = { name = "gm", notes = drummap.GM }

-- Map by name from <root>/drummaps/<name>.json ("gm" is built in). Needs band (REAPER) for file access.
function drummap.load(root, name)
  if not name or name == "" then return nil end
  if name == "gm" then return drummap.GM_MAP end
  local m = require("band").read_json(root .. "/drummaps/" .. name .. ".json")
  return m and m.notes and m or nil
end

return drummap
