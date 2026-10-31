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

-- Does every plug-in on the item's track load here? (A missing one shows offline: its notes would play silent.)
function prints.track_plays(tr)
  for i = 0, reaper.TrackFX_GetCount(tr) - 1 do
    if reaper.TrackFX_GetOffline(tr, i) then return false end
  end
  return true
end

-- What a print is made from: the notes and the track's plug-in chain (mirror's normalized chain).
function prints.source(it, mtk)
  local tr = reaper.GetMediaItem_Track(it)
  local _, chunk = reaper.GetTrackStateChunk(tr, "", false)
  local mirror = require("mirror")
  return mirror.hash(select(2, reaper.MIDI_GetHash(mtk, false, "")) .. (mirror.fxchain(chunk) or "") ..
    string.format("%.6f", reaper.GetMediaItemInfo_Value(it, "D_LENGTH")))
end

-- This machine's choice: "auto" (default), "notes" or "sound".
function prints.mode() local m = reaper.GetExtState(band.SECTION, "midi_plays"); return m ~= "" and m or "auto" end

-- Make the item play what this machine chose.
function prints.choose(it)
  local midi, print = prints.takes(it)
  if not (midi and print) then return end
  local mode = prints.mode()
  local want = mode == "sound" and print or mode == "notes" and midi
    or (prints.track_plays(reaper.GetMediaItem_Track(it)) and midi or print)
  if reaper.GetActiveTake(it) ~= want then reaper.SetActiveTake(want); reaper.UpdateItemInProject(it) end
end

-- Make or refresh the print of a MIDI item (rendered through its track: this tab in front, transport stopped).
-- Only when the track's plug-ins all load here (else the print would be silent). Returns true when the item changed.
function prints.refresh(proj, it, media_dir)
  local midi, print = prints.takes(it)
  if not midi then return false end
  local tr = reaper.GetMediaItem_Track(it)
  if reaper.TrackFX_GetCount(tr) == 0 or not prints.track_plays(tr) then return false end
  local h = prints.source(it, midi)
  if print and take_ext(print, prints.KEY) == h then return false end
  local oid = select(2, reaper.GetSetMediaItemInfo_String(it, "P_EXT:band_oid", "", false))
  local name = "print-" .. (oid ~= "" and oid or "item") .. "-" .. h
  reaper.RecursiveCreateDirectory(media_dir, 0)
  local path = require("sync").print_item(proj, it, midi, media_dir, name, nil)
  if not path then return false end
  local was = reaper.GetActiveTake(it)
  local ptk = print or reaper.AddTakeToMediaItem(it)
  reaper.SetMediaItemTake_Source(ptk, reaper.PCM_Source_CreateFromFile(path))
  reaper.SetMediaItemTakeInfo_Value(ptk, "D_STARTOFFS", 0)
  reaper.GetSetMediaItemTakeInfo_String(ptk, "P_NAME", "print of " .. select(2, reaper.GetSetMediaItemTakeInfo_String(midi, "P_NAME", "", false)), true)
  reaper.GetSetMediaItemTakeInfo_String(ptk, "P_EXT:" .. prints.KEY, h, true)
  if was then reaper.SetActiveTake(was) end
  prints.choose(it)
  reaper.UpdateItemInProject(it)
  return true
end

return prints
