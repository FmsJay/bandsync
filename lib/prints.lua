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

-- What a print is made from: the notes, the item's length and the band's plug-in chain on its track (`fx_hash`:
-- mirror's hash of it, which leaves this machine's translations out, so it's the same on every machine).
function prints.source(it, mtk, fx_hash)
  return require("mirror").hash(select(2, reaper.MIDI_GetHash(mtk, false, "")) .. (fx_hash or "") ..
    string.format("%.6f", reaper.GetMediaItemInfo_Value(it, "D_LENGTH")))
end

-- This machine's choice: "auto" (default), "notes" or "sound".
function prints.mode() local m = reaper.GetExtState(band.SECTION, "midi_plays"); return m ~= "" and m or "auto" end

-- Make the item play what this machine chose.
function prints.choose(it)
  local midi, print = prints.takes(it)
  if print and not midi then -- an ARA take: editable only where it was edited (see prints.ARA)
    local ara = prints.ara_take(it)
    local want = ara and take_ext(ara, prints.HERE) == take_ext(print, prints.KEY) and ara or print
    if reaper.GetActiveTake(it) ~= want then reaper.SetActiveTake(want); reaper.UpdateItemInProject(it) end
    return
  end
  if not (midi and print) then return end
  local mode = prints.mode()
  local want = mode == "sound" and print or mode == "notes" and midi
    or (prints.track_plays(reaper.GetMediaItem_Track(it)) and midi or print)
  if reaper.GetActiveTake(it) ~= want then reaper.SetActiveTake(want); reaper.UpdateItemInProject(it) end
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
  local path = require("sync").print_item(proj, it, ara, media_dir, "print-" .. (oid ~= "" and oid or "item") .. "-" .. h, nil, true)
  if not path then return false end
  local ptk = print or reaper.AddTakeToMediaItem(it)
  reaper.SetMediaItemTake_Source(ptk, reaper.PCM_Source_CreateFromFile(path))
  reaper.SetMediaItemTakeInfo_Value(ptk, "D_STARTOFFS", 0)
  reaper.GetSetMediaItemTakeInfo_String(ptk, "P_NAME", "print of " .. select(2, reaper.GetSetMediaItemTakeInfo_String(ara, "P_NAME", "", false)), true)
  reaper.GetSetMediaItemTakeInfo_String(ptk, "P_EXT:" .. prints.KEY, h, true)
  reaper.GetSetMediaItemTakeInfo_String(ara, "P_EXT:" .. prints.HERE, h, true)
  prints.choose(it)
  reaper.UpdateItemInProject(it)
  return true
end

-- Make or refresh the print of a MIDI item (rendered through its track: this tab in front, transport stopped).
-- Only when the track's plug-ins all load here (else the print would be silent). Returns true when the item changed.
-- An audio take with Melodyne (or another ARA plug-in) gets its print the same way (see prints.ARA).
function prints.refresh(proj, it, media_dir, fx_hash)
  local midi, print = prints.takes(it)
  if not midi then return refresh_ara(proj, it, media_dir) end
  local tr = reaper.GetMediaItem_Track(it)
  if reaper.TrackFX_GetCount(tr) == 0 or not prints.track_plays(tr) then return false end
  local h = prints.source(it, midi, fx_hash)
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
