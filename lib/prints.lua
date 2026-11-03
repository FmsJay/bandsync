-- MIDI wet/dry (docs/mirror-design.md): a MIDI item's notes are the truth and travel as notes; whoever changes it
-- (and has the instrument) also renders a print, the item's second take, which travels with it as audio. Each
-- machine picks which take plays: Notes (dry: your own instruments), Sound (wet: the print) or Auto (notes when the
-- track's plug-ins all load here, else the print). The playing take is never mirrored (lib/mirror.lua drops it), so
-- one person's choice never changes anyone else's.
local band = require("band")
local prints = {}
prints.KEY = "band_m_print" -- on the print take: the source hash it was made from (travels: band_m_ keys do)

local function take_ext(tk, k) return select(2, reaper.GetSetMediaItemTakeInfo_String(tk, "P_EXT:" .. k, "", false)) end

function prints.takes(it)
  local midi, print
  for k = 0, reaper.CountTakes(it) - 1 do
    local tk = reaper.GetTake(it, k)
    if tk then
      if take_ext(tk, prints.KEY) ~= "" then print = print or tk
      elseif reaper.TakeIsMIDI(tk) then midi = midi or tk end
    end
  end
  return midi, print
end

-- A MIDI track that plays an instrument on another track: no instrument of its own, and a send carrying MIDI to a
-- track that has one (a sampler fed by several MIDI tracks, drums on a kit track). -> that track, or nil. (The first
-- such send: a track sending MIDI to several instruments prints through the first.)
-- Whether a track has an instrument: a loaded one, or one that isn't here (offline: TrackFX_GetInstrument doesn't
-- count those, so the computer missing it, the one that most needs the print, didn't see the routing at all), known
-- by REAPER's "VSTi:", "VST3i:", "AUi:", "CLAPi:" name. A JSFX has no such name and TrackFX_GetInstrument doesn't see
-- it (Mac, 0.39.1): one counts when its file says "in_pin:none" (no audio in: chmaha's kits, organ and pianos), tags
-- itself an instrument, or is called a synth; read once per file. (A JS instrument that says none of that is missed.)
local js_inst = {} -- Effects-relative path -> true/false
local function js_instrument(tr, i)
  local _, kind = reaper.TrackFX_GetNamedConfigParm(tr, i, "fx_type")
  if kind ~= "JS" then return false end
  local _, ident = reaper.TrackFX_GetNamedConfigParm(tr, i, "fx_ident")
  ident = (ident or ""):gsub("\\", "/")
  if js_inst[ident] == nil then
    local text = (band.read(reaper.GetResourcePath() .. "/Effects/" .. ident) or ""):sub(1, 65536)
    local head = text:sub(1, (text:find("\n@") or #text)):lower() -- (the header, up to the first @section: chmaha's run 11 KB)
    -- (not one with no audio out either: a MIDI-only effect, an arpeggiator, says in_pin:none too)
    js_inst[ident] = not head:find("\nout_pin:none", 1, true) and (head:find("\nin_pin:none", 1, true) ~= nil
      or head:find("tags:[^\n]*instrument") ~= nil or (head:match("^desc:([^\n]*)") or head:match("\ndesc:([^\n]*)") or ""):find("synth", 1, true) ~= nil)
  end
  return js_inst[ident]
end
local function has_instrument(tr)
  if reaper.TrackFX_GetInstrument(tr) >= 0 then return true end
  for i = 0, reaper.TrackFX_GetCount(tr) - 1 do
    if select(2, reaper.TrackFX_GetFXName(tr, i)):match("^%u+%d*i: ") or js_instrument(tr, i) then return true end
  end
  return false
end
-- A print's file name: the item, what it was made from, and who rendered it. Two machines rendering the same item
-- made one name with different bytes, and on Windows Syncthing can't replace a file REAPER has open, so it retried
-- for good (laptop, 0.35.6).
local function print_name(oid, h)
  local who = (reaper.GetExtState(band.SECTION, "user"):gsub("[^%w%-_]", "_"))
  return "print-" .. (oid ~= "" and oid or "item") .. "-" .. h .. (who ~= "" and ("-" .. who) or "")
end
function prints.route(tr)
  if has_instrument(tr) then return nil end
  for s = 0, reaper.GetTrackNumSends(tr, 0) - 1 do
    local dest = reaper.GetTrackSendInfo_Value(tr, 0, s, "P_DESTTRACK")
    local midi = math.floor(reaper.GetTrackSendInfo_Value(tr, 0, s, "I_MIDIFLAGS")) & 31 ~= 31 -- (31: MIDI off)
    if dest and midi and reaper.GetTrackSendInfo_Value(tr, 0, s, "B_MUTE") == 0 and has_instrument(dest) then return dest end
  end
end

-- The send from a routed MIDI track to its instrument carries MIDI only, when the track has no audio of its own:
-- with the print playing (Wet), a send carrying audio took it into the instrument too, which passed it on, and the
-- band heard it twice, 6 dB hot (laptop, 0.35.6). It goes to the band like any routing change. Returns true if set.
function prints.midi_only(tr, dest)
  for i = 0, reaper.CountTrackMediaItems(tr) - 1 do -- (audio on the track besides prints: its send is left as it is)
    for k = 0, reaper.CountTakes(reaper.GetTrackMediaItem(tr, i)) - 1 do
      local tk = reaper.GetTake(reaper.GetTrackMediaItem(tr, i), k)
      if tk and not reaper.TakeIsMIDI(tk) and take_ext(tk, prints.KEY) == "" then return false end
    end
  end
  for s = 0, reaper.GetTrackNumSends(tr, 0) - 1 do
    if reaper.GetTrackSendInfo_Value(tr, 0, s, "P_DESTTRACK") == dest and reaper.GetTrackSendInfo_Value(tr, 0, s, "I_SRCCHAN") ~= -1 then
      reaper.SetTrackSendInfo_Value(tr, 0, s, "I_SRCCHAN", -1) -- (-1: no audio)
      band.log(string.format("the send from '%s' to '%s' now carries MIDI only, so its print doesn't play twice",
        select(2, reaper.GetTrackName(tr)), select(2, reaper.GetTrackName(dest))))
      return true
    end
  end
  return false
end

-- Whether a track's plug-in really loads here. A missing VST, AU or CLAP shows offline; a missing JSFX doesn't: REAPER
-- keeps an empty stand-in (not offline, silent), so its file is looked for in Effects (Mac, 0.39.1: it printed a
-- JS synth it didn't have, and its silent print replaced the PC's good one).
function prints.fx_here(tr, i)
  if reaper.TrackFX_GetOffline(tr, i) then return false end
  local _, kind = reaper.TrackFX_GetNamedConfigParm(tr, i, "fx_type")
  local _, ident = reaper.TrackFX_GetNamedConfigParm(tr, i, "fx_ident") -- (a JSFX's is relative to Effects: "ReaTeam JSFX/Synth/x.jsfx")
  -- a VST or AU that isn't installed doesn't read as offline either: no file behind it, and only REAPER's own three
  -- knobs (bypass, wet, delta). Taken as loaded, its notes printed silent, and in Auto they played silent where the
  -- print should have (laptop and PC, 0.42.2)
  if kind ~= "JS" then return (ident or "") ~= "" or reaper.TrackFX_GetNumParams(tr, i) > 3 end
  ident = (ident or ""):gsub("\\", "/")
  return ident == "" or reaper.file_exists(reaper.GetResourcePath() .. "/Effects/" .. ident) or reaper.file_exists(ident)
end

-- Does every plug-in on the item's track load here (and on the instrument's track, for a routed one)? A missing one
-- would leave its notes silent.
function prints.track_plays(tr)
  for i = 0, reaper.TrackFX_GetCount(tr) - 1 do
    if not prints.fx_here(tr, i) then return false end
  end
  local dest = prints.route(tr)
  if dest then
    for i = 0, reaper.TrackFX_GetCount(dest) - 1 do
      if not prints.fx_here(dest, i) then return false end
    end
  end
  return true
end

-- What a print is made from: the notes, the item's length and the band's plug-in chain on its track (`fx_hash`:
-- mirror's hash of it, which leaves this machine's translations out, so it's the same on every machine).
-- Not which notes are selected: REAPER's MIDI_GetHash counts that (even notes-only), so an undo after a hand edit,
-- which leaves the moved note selected, rendered the same notes again (laptop, 2026-11-01). Second value: the hash
-- before 0.40.3, so prints made then stay current until their notes change (no re-render of every part at once).
local function unselected(raw, mtk)
  return require("mirror").memo("ms\0" .. raw, function()
    local ok, buf = reaper.MIDI_GetAllEvts(mtk, "")
    if not ok then return raw end
    local out, pos = {}, 1
    while pos + 8 < #buf do -- each event: offset (int32), flags (byte: 1 = selected), message (int32 length, bytes)
      local off, flags, msg, nxt = string.unpack("<i4Bs4", buf, pos)
      out[#out + 1] = string.pack("<i4Bs4", off, flags & ~1, msg)
      pos = nxt
    end
    return table.concat(out)
  end)
end
function prints.source(it, mtk, fx_hash)
  local mirror, raw = require("mirror"), select(2, reaper.MIDI_GetHash(mtk, false, ""))
  local tail = (fx_hash or "") .. string.format("%.6f", reaper.GetMediaItemInfo_Value(it, "D_LENGTH"))
  return mirror.hash(unselected(raw, mtk) .. tail), mirror.hash(raw .. tail)
end

-- The two takes say what they are: "dry" (the notes, or the editable ARA take) and "wet" (the print), each keeping
-- the name it had after a dash ("dry - Keys verse"). It used to be take 1 and "print of ..." (James, 2026-10-31).
-- Pure: an earlier label ("dry - ", "wet - ", "print of ") is taken off first, so naming again never stacks.
function prints.label(kind, name)
  name = (name or ""):gsub("^print of ", ""):gsub("^dry %- ", ""):gsub("^wet %- ", ""):gsub("^dry$", ""):gsub("^wet$", "")
  return name ~= "" and (kind .. " - " .. name) or kind
end
local function label_takes(dry, wet)
  local name = select(2, reaper.GetSetMediaItemTakeInfo_String(dry, "P_NAME", "", false))
  reaper.GetSetMediaItemTakeInfo_String(dry, "P_NAME", prints.label("dry", name), true)
  reaper.GetSetMediaItemTakeInfo_String(wet, "P_NAME", prints.label("wet", name), true)
end

-- This machine's choice: "auto" (default), "notes" or "sound".
function prints.mode() local m = reaper.GetExtState(band.SECTION, "midi_plays"); return m ~= "" and m or "auto" end

-- Make the item play what this machine chose.
function prints.choose(it)
  local midi, print = prints.takes(it)
  local ara = print and not midi and prints.ara_take(it)
  if ara then -- an ARA take: editable only where it was edited (see prints.ARA)
    local want = take_ext(ara, prints.HERE) == take_ext(print, prints.KEY) and ara or print
    if reaper.GetActiveTake(it) ~= want then reaper.SetActiveTake(want); reaper.UpdateItemInProject(it) end
    return
  end
  local dry = midi or (print and prints.audio_take(it))
  if not (dry and print) then return end
  local mode = prints.mode()
  local tr = reaper.GetMediaItem_Track(it)
  local want = mode == "sound" and print or mode == "notes" and dry or (prints.track_plays(tr) and dry or print)
  if reaper.GetActiveTake(it) ~= want then reaper.SetActiveTake(want); reaper.UpdateItemInProject(it) end
  prints.hold_fx(tr)
end

-- A wet take already went through its track's plug-ins: played through them again, the ones that load here would
-- apply twice (a missing amp sim passes the print through, the reverb after it doesn't). So while an item on the
-- track plays its wet take, the track's FX are switched off here (its FX button), and back on once none does.
-- Only here: mirror reads the band's setting from prints.FXEN while it's held. (ARA prints have only the take's
-- own plug-ins in them: their track's still apply.)
prints.FXEN = "band_fxen" -- (on a track, this machine only: the FX button as the band has it, while held off here)
local said_print_only = {}
function prints.hold_fx(tr)
  local wet = false
  for i = 0, reaper.CountTrackMediaItems(tr) - 1 do
    local x = reaper.GetTrackMediaItem(tr, i)
    local tk = reaper.GetActiveTake(x)
    if tk and take_ext(tk, prints.KEY) ~= "" and not prints.ara_take(x) then
      -- (a comp made while a pass played its print: the Neve went off for the whole track, so every dry piece played unprocessed:
      -- Mac, 0.42.5. One piece through its plug-ins twice is the smaller harm, and it says so)
      if reaper.CountTakes(x) > 1 then wet = true; break end
      if not said_print_only[x] then
        said_print_only[x] = true
        band.log("a part on " .. select(2, reaper.GetTrackName(tr)) .. " holds only its print, no dry take, so it plays through this track's plug-ins a second time. If it came from a comp, comp it from the dry take")
      end
    end
  end
  local held = band.track_ext(tr, prints.FXEN)
  if wet and held == "" then
    reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:" .. prints.FXEN, tostring(math.floor(reaper.GetMediaTrackInfo_Value(tr, "I_FXEN"))), true)
    reaper.SetMediaTrackInfo_Value(tr, "I_FXEN", 0)
  elseif not wet and held ~= "" then
    reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:" .. prints.FXEN, "", true)
    reaper.SetMediaTrackInfo_Value(tr, "I_FXEN", tonumber(held) or 1)
  end
end

-- Audio (0.37): the take a wet print stands in for, on an audio item whose track has a plug-in someone in the band
-- lacks: its one take that isn't the print (an item with several takes gets none). nil for MIDI and ARA items.
function prints.audio_take(it)
  local dry, n = nil, 0
  for k = 0, reaper.CountTakes(it) - 1 do
    local tk = reaper.GetTake(it, k)
    if tk and take_ext(tk, prints.KEY) == "" then
      if reaper.TakeIsMIDI(tk) then return nil end
      dry, n = tk, n + 1
    end
  end
  if n ~= 1 or prints.ara_take(it) then return nil end
  return dry
end

-- Whether a track has a plug-in someone in the band doesn't have (everyone's published list, lib/plugins.lua; by
-- its own name, not one it was renamed to). Looked up once a minute.
local common = { at = -math.huge }
function prints.lacking(tr, cfg)
  if not cfg then return false end
  local plugins = require("plugins")
  if reaper.time_precise() - common.at > 60 then
    local ok, set, members = pcall(plugins.band, cfg)
    common.at, common.set, common.n = reaper.time_precise(), ok and set or nil, ok and #members or 0
  end
  if not common.set or common.n < 2 then return false end
  for i = 0, reaper.TrackFX_GetCount(tr) - 1 do
    local ok, name = reaper.TrackFX_GetNamedConfigParm(tr, i, "fx_name")
    if not ok or name == "" then name = select(2, reaper.TrackFX_GetFXName(tr, i)) end
    if not common.set[plugins.key(name)] then return true end
  end
  return false
end

-- What an audio print is made from: the recording, how the take plays it and its own plug-ins, the item's length,
-- and the band's plug-in chain on its track (`fx_hash`). Not the item's volume and fades: prints leave those out,
-- and the item applies them to whichever take plays.
function prints.audio_source(it, tk, fx_hash)
  local f = { (reaper.GetMediaSourceFileName(reaper.GetMediaItemTake_Source(tk), ""):match("[^/\\]*$")) }
  f[#f + 1] = string.format("%.6f", reaper.GetMediaItemInfo_Value(it, "D_LENGTH"))
  for _, k in ipairs({ "D_STARTOFFS", "D_PLAYRATE", "D_PITCH", "D_VOL", "D_PAN", "I_CHANMODE", "B_PPITCH" }) do
    f[#f + 1] = string.format("%.6f", reaper.GetMediaItemTakeInfo_Value(tk, k))
  end
  for i = 0, reaper.TakeFX_GetCount(tk) - 1 do f[#f + 1] = select(2, reaper.TakeFX_GetFXName(tk, i, "")) end
  return require("mirror").hash(table.concat(f, "|") .. "|" .. (fx_hash or ""))
end

-- A part is rendered once it has held still, and those whose last change is oldest go first (James, 2026-11-01): a
-- burst measured on the PC rendered every state it passed through, and one part being edited held up all the others.
-- Going back to a state already printed doesn't wait (prints.render finds it first). `seen`: still asking; one that
-- stopped (deleted, or printed by someone else now) no longer holds anyone up.
prints.SETTLE = 3 -- seconds a part must stay unchanged
local queue = {} -- item oid -> { name, since, seen }
local QUEUE_SEEN = 5
local function my_turn(oid, name)
  if prints.SETTLE <= 0 then return true end
  local now, w = reaper.time_precise(), queue[oid]
  if not w or w.name ~= name or now - w.seen > QUEUE_SEEN then w = { name = name, since = now }; queue[oid] = w end
  w.seen = now
  if now - w.since < prints.SETTLE then return false end
  for k, o in pairs(queue) do
    if k ~= oid and o.since < w.since and now - o.seen <= QUEUE_SEEN then return false end
  end
  return true
end
-- Whether a part is waiting for its turn (Live sync then looks every second).
function prints.waiting()
  local now = reaper.time_precise()
  for _, o in pairs(queue) do if now - o.seen <= QUEUE_SEEN then return true end end
  return false
end

-- Render a print: in the background where that works (lib/bgrender.lua: nil while it renders, and a later pass
-- picks it up), else here and now. `render()` renders it in front and returns its path; `tracks`: what it goes through.
function prints.render(oid, name, out, tracks, render)
  -- already printed: a print's name says what it was made from and who rendered it, so going back to a state it had
  -- (an undo, a note put back) finds its print here. Rendered again, its file (still open in REAPER) couldn't be
  -- replaced, so the background print was dropped and rendered in front as "-2" (laptop, 0.40.0).
  -- Anyone's print of it will do (the same item and source: "print-<oid>-<hash>-<who>"), ours first: going back to the
  -- laptop's state rendered the PC's own copy of it (PC, 0.40.1).
  if reaper.file_exists(out .. "/" .. name .. ".flac") then return out .. "/" .. name .. ".flac" end
  local base = name:match("^(print%-.+%-%x%x%x%x%x%x%x%x)%-") or name
  for _, f in ipairs(band.files(out, ".flac")) do
    local rest = f:sub(#base + 1)
    if f:sub(1, #base) == base and (rest == ".flac" or rest:sub(1, 1) == "-") then return out .. "/" .. f end
  end
  local bg = require("bgrender")
  if bg.on() then
    if bg.stuck[name] then return nil end
    local path, state = bg.claim(oid, name, out)
    if path then return path end
    if state == "running" or state == "stuck" then return nil end
    if state ~= "failed" then
      if not my_turn(oid, name) or bg.busy() then return nil end
      queue[oid] = nil
      local keep = {}
      for _, t in ipairs(tracks) do keep[#keep + 1] = reaper.GetTrackGUID(t) end
      if bg.start(oid, name, keep, render) then return nil end
    end
  elseif not my_turn(oid, name) then return nil end
  queue[oid] = nil
  return render()
end

-- The print goes in as the item's wet take (replacing an older one), the playing take left as it was.
local function attach(it, print, dry, path, h)
  local was = reaper.GetActiveTake(it)
  local ptk = print or reaper.AddTakeToMediaItem(it)
  reaper.SetMediaItemTake_Source(ptk, reaper.PCM_Source_CreateFromFile(path))
  reaper.SetMediaItemTakeInfo_Value(ptk, "D_STARTOFFS", 0)
  label_takes(dry, ptk)
  reaper.GetSetMediaItemTakeInfo_String(ptk, "P_EXT:" .. prints.KEY, h, true)
  if was then reaper.SetActiveTake(was) end
  return ptk
end

-- Melodyne and the other ARA plug-ins on an audio take: their edits live in the project, outside the item, so a
-- bandmate's copy of the item plays the take unedited. The print carries them: rendered with the take's own
-- plug-ins (not its track's), it plays everywhere except on the machine that made it, which keeps the editable take.
-- Closing the plug-in's window ends an editing pass: the take's band_m_ara count goes up and a new print follows.
prints.ARA = { "Melodyne", "RePitch", "Revoice", "SpectraLayers", "VocAlign" }
prints.HERE = "band_ara_here" -- (on the ARA take, this machine only: the print it made, so it plays the editable take)
function prints.ara_take(it)
  for k = 0, reaper.CountTakes(it) - 1 do
    local tk = reaper.GetTake(it, k)
    if tk and take_ext(tk, prints.KEY) == "" and not reaper.TakeIsMIDI(tk) then
      for f = 0, reaper.TakeFX_GetCount(tk) - 1 do
        local _, name = reaper.TakeFX_GetFXName(tk, f, "")
        for _, a in ipairs(prints.ARA) do if name:find(a, 1, true) then return tk end end
      end
    end
  end
end
local ara_open = {} -- take GUID -> its plug-in window was open at the last look
function prints.watch_ara(proj)
  for i = 0, reaper.CountMediaItems(proj) - 1 do
    local tk = prints.ara_take(reaper.GetMediaItem(proj, i))
    if tk then
      local open = false
      for f = 0, reaper.TakeFX_GetCount(tk) - 1 do open = open or reaper.TakeFX_GetOpen(tk, f) end
      local g = select(2, reaper.GetSetMediaItemTakeInfo_String(tk, "GUID", "", false))
      if ara_open[g] and not open then -- (an editing pass ended)
        reaper.GetSetMediaItemTakeInfo_String(tk, "P_EXT:band_m_ara", tostring((tonumber(take_ext(tk, "band_m_ara")) or 0) + 1), true)
      end
      ara_open[g] = open
    end
  end
end
function prints.ara_source(it, tk)
  local fx = {}
  for f = 0, reaper.TakeFX_GetCount(tk) - 1 do fx[#fx + 1] = select(2, reaper.TakeFX_GetFXName(tk, f, "")) end
  return require("mirror").hash(table.concat({ reaper.GetMediaSourceFileName(reaper.GetMediaItemTake_Source(tk), ""),
    string.format("%.6f %.6f %.6f %.6f", reaper.GetMediaItemInfo_Value(it, "D_LENGTH"), reaper.GetMediaItemTakeInfo_Value(tk, "D_STARTOFFS"),
      reaper.GetMediaItemTakeInfo_Value(tk, "D_PLAYRATE"), reaper.GetMediaItemTakeInfo_Value(tk, "D_PITCH")),
    take_ext(tk, "band_m_ara"), table.concat(fx, ",") }, "|"))
end
local function refresh_ara(proj, it, media_dir)
  local ara = prints.ara_take(it)
  if not ara then return false end
  for f = 0, reaper.TakeFX_GetCount(ara) - 1 do if reaper.TakeFX_GetOffline(ara, f) then return false end end
  local _, print = prints.takes(it)
  local h = prints.ara_source(it, ara)
  if print and take_ext(print, prints.KEY) == h then return false end
  local oid = select(2, reaper.GetSetMediaItemInfo_String(it, "P_EXT:band_oid", "", false))
  reaper.RecursiveCreateDirectory(media_dir, 0)
  local name = print_name(oid, h)
  local path = prints.render(oid, name, media_dir, { reaper.GetMediaItem_Track(it) },
    function() return require("sync").print_item(proj, it, ara, media_dir, name, nil, true, true) end)
  if not path then return false end
  attach(it, print, ara, path, h)
  reaper.GetSetMediaItemTakeInfo_String(ara, "P_EXT:" .. prints.HERE, h, true)
  prints.choose(it)
  reaper.UpdateItemInProject(it)
  return true
end

-- Make or refresh the print of a MIDI item (rendered through its track: this tab in front, transport stopped).
-- Only when the track's plug-ins all load here (else the print would be silent). Returns true when the item changed.
-- An audio take with Melodyne (or another ARA plug-in) gets its print the same way (see prints.ARA). A track that
-- plays an instrument on another track (prints.route) prints through that track (sync.print_routed), and that
-- track's chain (`route_hash`) is part of what the print is made from.
-- An audio item gets one too when its track has a plug-in someone in the band lacks (`cfg`: whose band). Prints
-- render in the background where that works (prints.render), so this returns true on the pass that picks one up.
function prints.refresh(proj, it, media_dir, fx_hash, route_hash, cfg)
  local midi, print = prints.takes(it)
  local tr = reaper.GetMediaItem_Track(it)
  -- (a pass on a lane nobody hears: printed once it plays. Every pass of a comp was rendered: laptop, 0.42.5)
  if reaper.GetMediaTrackInfo_Value(tr, "I_FREEMODE") == 2
    and reaper.GetMediaTrackInfo_Value(tr, "C_LANEPLAYS:" .. math.floor(reaper.GetMediaItemInfo_Value(it, "I_FIXEDLANE"))) == 0 then return false end
  local audio = not midi and prints.audio_take(it)
  if not midi and not audio then return refresh_ara(proj, it, media_dir) end
  local dest = midi and prints.route(tr)
  if (reaper.TrackFX_GetCount(tr) == 0 and not dest) or not prints.track_plays(tr) then return false end
  if audio and not prints.lacking(tr, cfg) then return false end
  local dry = midi or audio
  local h, old
  if midi then h, old = prints.source(it, midi, (fx_hash or "") .. (dest and ("\0" .. (route_hash or "")) or ""))
  else h = prints.audio_source(it, audio, fx_hash) end
  if print and (take_ext(print, prints.KEY) == h or old and take_ext(print, prints.KEY) == old) then return false end
  local oid = select(2, reaper.GetSetMediaItemInfo_String(it, "P_EXT:band_oid", "", false))
  local name = print_name(oid, h)
  reaper.RecursiveCreateDirectory(media_dir, 0)
  local sync = require("sync")
  local path = prints.render(oid, name, media_dir, dest and { tr, dest } or { tr }, function()
    if dest then return sync.print_routed(proj, it, midi, dest, media_dir, name) end
    return sync.print_item(proj, it, dry, media_dir, name, nil, false, true)
  end)
  if not path then return false end
  if dest then prints.midi_only(tr, dest) end
  attach(it, print, dry, path, h)
  prints.choose(it)
  reaper.UpdateItemInProject(it)
  return true
end

-- ---- who prints (0.39) -----------------------------------------------------------------------------------------
-- An item's print is made by (James, 2026-11-01):
--   1. the bandmate in charge of printing its track ("Print selected tracks here", kept in their claims file), when
--      they're in the song now and have every plug-in it plays through;
--   2. else whoever changed it last, if they have those plug-ins (here or not: theirs waits for them);
--   3. else the first bandmate in the song now, by name, who has them.
-- Every machine works it out the same way, so one machine prints it. Whether someone has a plug-in: their published
-- list (lib/plugins.lua); this machine: whether it actually loads here.

-- The plug-in keys an item's print goes through: its track's, and the instrument track's for a routed one.
function prints.track_keys(tr)
  local plugins, keys = require("plugins"), {}
  for _, t in ipairs({ tr, prints.route(tr) }) do
    for i = 0, reaper.TrackFX_GetCount(t) - 1 do
      local ok, name = reaper.TrackFX_GetNamedConfigParm(t, i, "fx_name")
      if not ok or name == "" then name = select(2, reaper.TrackFX_GetFXName(t, i)) end
      keys[#keys + 1] = plugins.key(name)
    end
  end
  return keys
end
local lists = { at = -math.huge, by = {} } -- user -> set of plug-in keys (their published list), read once a minute
function prints.has(cfg, user, keys)
  if reaper.time_precise() - lists.at > 60 then
    lists.at, lists.by = reaper.time_precise(), {}
    for _, f in ipairs(band.files(cfg.root .. "/plugins", ".json")) do
      local l = band.read_json(cfg.root .. "/plugins/" .. f)
      if type(l) == "table" and type(l.user) == "string" and type(l.names) == "table" then
        local set = {}
        for _, k in ipairs(l.names) do set[k] = true end
        lists.by[l.user] = set
      end
    end
  end
  local set = lists.by[user]
  if not set then return false end
  for _, k in ipairs(keys) do if not set[k] then return false end end
  return true
end
-- Who prints this item: a user name, or nil (nobody can). `author`: who changed it last; `here`: { user = true }
-- (bandmates in the song now, this machine's user too); `printers`: sync.authority's (lower track name -> {user}).
-- `can(user)`: whether that user has every plug-in it plays through. Pure.
function prints.printer(track, author, here, printers, can)
  local d = printers[(track or ""):lower()]
  if d and here[d.user] and can(d.user) then return d.user end
  if author and can(author) then return author end
  local names = {}
  for u in pairs(here) do names[#names + 1] = u end
  table.sort(names)
  for _, u in ipairs(names) do if can(u) then return u end end
  return nil
end

-- Claims card: "Print selected tracks here", and who prints what. (In this file: the panel is near Lua's limit.)
function prints.printing_ui(ctx, ImGui, cfg, b, proj, who)
  local sync = require("sync")
  local function save(fn)
    local c, why = sync.my_claims(cfg, b.song, b.room)
    if not c then return band.msg(why) end
    c.prints = c.prints or {}
    fn(c)
    sync.set_claims(cfg, b.song, b.room, c)
  end
  if ImGui.Button(ctx, "Print selected tracks here") then
    if reaper.CountSelectedTracks(proj) == 0 then return band.msg("Select the tracks whose wet takes you want to render first.") end
    save(function(c)
      for i = 0, reaper.CountSelectedTracks(proj) - 1 do
        local n = sync.base_name(select(2, reaper.GetTrackName(reaper.GetSelectedTrack(proj, i))))
        local dup = false
        for _, x in ipairs(c.prints) do dup = dup or x:lower() == n:lower() end
        if not dup then c.prints[#c.prints + 1] = n end
      end
    end)
  end
  ImGui.SetItemTooltip(ctx, "Their wet takes are rendered here, with your plug-ins, whoever changes them: while you're in the song\n" ..
    "and have every plug-in they play through. Otherwise whoever changed them prints, or someone here who has the plug-ins.")
  local mine, others = {}, {}
  for _, p in pairs(who and who.printers or {}) do
    if p.user == cfg.user then mine[#mine + 1] = p.name else others[#others + 1] = p.name .. " (" .. p.user .. ")" end
  end
  table.sort(mine); table.sort(others)
  if #mine > 0 then
    ImGui.SameLine(ctx)
    if ImGui.SmallButton(ctx, "Stop printing them") then save(function(c) c.prints = {} end) end
    ImGui.TextDisabled(ctx, "You print: " .. table.concat(mine, ", "))
  end
  if #others > 0 then ImGui.TextDisabled(ctx, "Printed by: " .. table.concat(others, ", ")) end
end

-- Setup > Options: rendering in the background, this machine's choice.
function prints.options(ctx, ImGui)
  local set, default = reaper.GetExtState(band.SECTION, "bg render"), require("bgrender").default_on()
  local on = set == "on" or (default and set ~= "off")
  local rv, v = ImGui.Checkbox(ctx, "Render wet takes in the background##bgrender", on)
  if rv then reaper.SetExtState(band.SECTION, "bg render", v == default and "" or (v and "on" or "off"), true) end
  ImGui.SetItemTooltip(ctx, "On: a hidden second REAPER renders each wet take while you keep working (a few seconds each).\n" ..
    "Off: REAPER renders them in front, holding up the screen for a moment each time." ..
    (default and "" or "\nOff by default here: this computer has no way to keep the second REAPER hidden, so it would take the keyboard for a moment each time."))
end

-- ---- takes become lanes (0.39) -----------------------------------------------------------------------------------
-- In a band song, an item's takes (several in one item, one playing) become fixed lanes, the way REAPER 7 keeps
-- alternatives (James, 2026-11-01): REAPER's own "explode takes to fixed lanes and add comp areas from active takes"
-- (42636), which keeps a comp exactly (tested: the same render, sample for sample, before and after), so a take
-- picked per stretch becomes a comp lane. Wet takes then work on every lane. Per track, only by whoever owns one of
-- its items' takes (`mine(item)`: their newest change, or not sent yet), so two machines never explode one at once;
-- a track holding a wet take (or an ARA one) waits, as exploding would split print from item. Returns tracks done.
-- A track already in lanes: each item with several takes keeps the one playing, in the lane that plays, and each other take
-- becomes its own item on a new lane at the bottom.
local function real_takes(it)
  local real = 0
  for k = 0, reaper.CountTakes(it) - 1 do
    local tk = reaper.GetTake(it, k)
    if tk and take_ext(tk, prints.KEY) == "" then real = real + 1 end
  end
  return real
end
function prints.takes_into_new_lanes(proj, tr, mine)
  local plays = 0
  for l = 0, reaper.GetMediaTrackInfo_Value(tr, "I_NUMFIXEDLANES") - 1 do
    if reaper.GetMediaTrackInfo_Value(tr, "C_LANEPLAYS:" .. l) > 0 then plays = l; break end
  end
  local items = {}
  for j = 0, reaper.CountTrackMediaItems(tr) - 1 do
    local it = reaper.GetTrackMediaItem(tr, j)
    if real_takes(it) > 1 and mine(it) then items[#items + 1] = it end
  end
  local exploding = {}
  for _, it in ipairs(items) do exploding[it] = true end
  local function new_lane()
    local lanes = reaper.GetMediaTrackInfo_Value(tr, "I_NUMFIXEDLANES")
    reaper.SetMediaTrackInfo_Value(tr, "I_NUMFIXEDLANES", lanes + 1)
    reaper.SetMediaTrackInfo_Value(tr, "C_LANEPLAYS:" .. lanes, 0)
    return lanes
  end
  local function crop_to_active(it)
    reaper.SetMediaItemSelected(it, true)
    reaper.Main_OnCommand(40131, 0) -- Take: Crop to active take in items
    reaper.SetMediaItemSelected(it, false)
  end
  for _, it in ipairs(items) do
    local _, chunk = reaper.GetItemStateChunk(it, "", false)
    -- (a copy with ids of its own: REAPER makes them new, and mirror takes it as a new item)
    chunk = chunk:gsub("\n%s*IGUID [^\n]*", ""):gsub("\n%s*GUID [^\n]*", ""):gsub("\n%s*band_oid [^\n]*", ""):gsub("\n%s*band_[%w_]+ [^\n]*", "")
    local active = reaper.GetActiveTake(it)
    for k = reaper.CountTakes(it) - 1, 0, -1 do
      if reaper.GetTake(it, k) ~= active then
        local copy = reaper.AddMediaItemToTrack(tr)
        reaper.SetItemStateChunk(copy, chunk, false)
        reaper.SetActiveTake(reaper.GetTake(copy, k))
        crop_to_active(copy)
        reaper.SetMediaItemInfo_Value(copy, "I_FIXEDLANE", new_lane())
      end
    end
    crop_to_active(it)
    reaper.SetMediaItemInfo_Value(it, "I_FIXEDLANE", plays)
    -- (the part it was played over moves out of the way, or both sound: real Bass Guitar, Verse 2, laptop, 0.42.7)
    local from = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
    local to = from + reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
    for j = reaper.CountTrackMediaItems(tr) - 1, 0, -1 do
      local x = reaper.GetTrackMediaItem(tr, j)
      local x_at = reaper.GetMediaItemInfo_Value(x, "D_POSITION")
      if x ~= it and not exploding[x] and mine(x) and reaper.GetMediaItemInfo_Value(x, "I_FIXEDLANE") == plays
        and x_at < to and x_at + reaper.GetMediaItemInfo_Value(x, "D_LENGTH") > from then
        reaper.SetMediaItemInfo_Value(x, "I_FIXEDLANE", new_lane())
      end
    end
  end
  reaper.UpdateArrange()
end

function prints.takes_to_lanes(proj, mine)
  local done = 0
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    local want, blocked = false, require("mirror").local_track(tr)
    for j = 0, reaper.CountTrackMediaItems(tr) - 1 do
      local it = reaper.GetTrackMediaItem(tr, j)
      local real = real_takes(it)
      if real > 1 and prints.ara_take(it) then blocked = true end
      if real > 1 and mine(it) then want = true end
    end
    if want and not blocked then
      reaper.Undo_BeginBlock2(proj) -- (one point, named BandSync's: Ctrl+Z on "Crop to active take" brought the takes back, to split again)
      -- wet takes go first, or they'd become lanes of their own; the comp's item prints again. (Waiting for a track with no
      -- wet takes meant any comp on a played part stayed takes, and the takes picked never reached the band: laptop, 0.42.4)
      local picked = {}
      for s = 0, reaper.CountSelectedMediaItems(proj) - 1 do picked[#picked + 1] = reaper.GetSelectedMediaItem(proj, s) end
      for _, x in ipairs(picked) do reaper.SetMediaItemSelected(x, false) end
      local in_lanes = reaper.GetMediaTrackInfo_Value(tr, "I_FREEMODE") == 2 and reaper.GetMediaTrackInfo_Value(tr, "I_NUMFIXEDLANES") > 1 -- (one lane is the first time: its comp is th
      for j = 0, reaper.CountTrackMediaItems(tr) - 1 do
        local it = reaper.GetTrackMediaItem(tr, j)
        -- (in lanes only the items being split: the others kept their prints and bandmates' parts were re-sent. And every wet take:
        -- one from an old version holds three, and the other two came out as plain parts on lanes of their own)
        local _, wet = prints.takes(it)
        if in_lanes and not (real_takes(it) > 1 and mine(it)) then wet = nil end
        while wet do
          local was = reaper.GetActiveTake(it)
          if was == wet then was = prints.takes(it) end
          reaper.SetActiveTake(wet)
          reaper.SetMediaItemSelected(it, true)
          reaper.Main_OnCommand(40129, 0) -- Take: Delete active take from items
          reaper.SetMediaItemSelected(it, false)
          if was and reaper.ValidatePtr2(proj, was, "MediaItem_Take*") then reaper.SetActiveTake(was) end
          wet = select(2, prints.takes(it))
        end
      end
      for _, x in ipairs(picked) do if reaper.ValidatePtr2(proj, x, "MediaItem*") then reaper.SetMediaItemSelected(x, true) end end
      local sel = {}
      for s = 0, reaper.CountSelectedTracks(proj) - 1 do sel[#sel + 1] = reaper.GetSelectedTrack(proj, s) end
      -- already in lanes: REAPER's explode adds a new comp lane on top that plays alone, holding only the newest part, and
      -- everything else on the track went silent for everyone, with nothing saying so (laptop, 0.42.5). Moving what it makes
      -- back into the old comp lane loses it (0.42.6). So it isn't used: the take being played stays in the lane that's
      -- playing, and each other take gets a new lane at the bottom.
      reaper.SetOnlyTrackSelected(tr)
      if in_lanes then prints.takes_into_new_lanes(proj, tr, mine)
      else reaper.Main_OnCommand(42636, 0) end -- Take: Explode takes on selected tracks to fixed lanes and add comp areas from active takes
      local n = 0 -- (the take lanes come out "1" and unnamed: "Take 1", "Take 2"...; the comp lane stays "C1")
      for l = 0, reaper.GetMediaTrackInfo_Value(tr, "I_NUMFIXEDLANES") - 1 do -- (and carry on from any there already)
        n = math.max(n, tonumber(select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_LANENAME:" .. l, "", false)):match("^Take (%d+)$")) or 0)
      end
      for l = 0, reaper.GetMediaTrackInfo_Value(tr, "I_NUMFIXEDLANES") - 1 do
        local name = select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_LANENAME:" .. l, "", false))
        if name == "" or name:match("^%d+$") then n = n + 1; reaper.GetSetMediaTrackInfo_String(tr, "P_LANENAME:" .. l, "Take " .. n, true) end
      end
      reaper.SetTrackSelected(tr, false)
      for _, s in ipairs(sel) do if reaper.ValidatePtr2(proj, s, "MediaTrack*") then reaper.SetTrackSelected(s, true) end end
      reaper.Undo_EndBlock2(proj, "BandSync: takes became lanes", -1)
      band.log("the takes on " .. select(2, reaper.GetTrackName(tr)) .. " became lanes (the takes you picked stay the comp)")
      done = done + 1
    end
  end
  return done
end

return prints
