-- See a bandmate's MIDI edits as they land (James, 2026-11-01): off by default, this machine's choice. When their
-- change to a MIDI part arrives, the part opens in the MIDI editor here with the notes that changed selected. Which
-- notes they had selected never travels (lib/mirror.lua leaves it out): what's shown is worked out here, old against
-- new. An editor you opened on another part is left alone, so it never takes over what you're working on.
local midiview = {}

midiview.RECENT = 60 -- seconds: catching up on an old change opens nothing

function midiview.on() return reaper.GetExtState(require("band").SECTION, "show midi edits") == "on" end

-- Is this event's time (UTC, "2026-11-01T17:54:51Z") within RECENT of `now` (os.time of UTC's date, as here)?
function midiview.recent(time, now)
  local y, mo, d, h, mi, s = (time or ""):match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then return false end
  local t = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = tonumber(h), min = tonumber(mi), sec = tonumber(s) })
  return math.abs((now or os.time(os.date("!*t"))) - t) <= midiview.RECENT
end

-- Pure. Two lists of note keys -> the positions in `after` that are new, and how many of `before` are gone.
function midiview.diff(before, after)
  local had, has = {}, {}
  for _, k in ipairs(before) do had[k] = (had[k] or 0) + 1 end
  local new = {}
  for i, k in ipairs(after) do
    if (had[k] or 0) > 0 then had[k] = had[k] - 1; has[k] = true else new[#new + 1] = i end
  end
  local gone = 0
  for _, n in pairs(had) do gone = gone + n end
  return new, gone
end

-- An item's notes as keys (its MIDI take's; {} for anything else).
function midiview.notes(it)
  local tk = it and require("prints").takes(it)
  local keys = {}
  if not tk then return keys end
  for i = 0, select(2, reaper.MIDI_CountEvts(tk)) - 1 do
    local _, _, muted, a, b, chan, pitch, vel = reaper.MIDI_GetNote(tk, i)
    keys[#keys + 1] = string.format("%.0f|%.0f|%d|%d|%d|%s", a, b, chan, pitch, vel, tostring(muted))
  end
  return keys
end

local ours -- the item whose editor this opened last: that editor may move on to the next change
function midiview.show(proj, it, before)
  if reaper.EnumProjects(-1) ~= proj or reaper.GetPlayStateEx(proj) & 4 == 4 then return false end -- (in front, not recording)
  if not (it and reaper.ValidatePtr2(proj, it, "MediaItem*")) then return false end
  local tk = require("prints").takes(it)
  if not tk then return false end
  local new, gone = midiview.diff(before, midiview.notes(it))
  if #new == 0 and gone == 0 then return false end -- (its print, or anything else that isn't notes)
  local is_new = {}
  for _, i in ipairs(new) do is_new[i] = true end
  for i = 0, select(2, reaper.MIDI_CountEvts(tk)) - 1 do
    reaper.MIDI_SetNote(tk, i, is_new[i + 1] == true, nil, nil, nil, nil, nil, nil, true)
  end
  reaper.MIDI_Sort(tk)
  local ed = reaper.MIDIEditor_GetActive()
  local shown = ed and reaper.MIDIEditor_GetTake(ed)
  local at = shown and reaper.ValidatePtr2(proj, shown, "MediaItem_Take*") and reaper.GetMediaItemTake_Item(shown)
  if at == it then return true end
  if ed and at ~= ours then return false end
  -- 40153 opens the selected items' active takes: only this one, on its notes, then everything back as it was
  local picked = {}
  for i = 0, reaper.CountSelectedMediaItems(proj) - 1 do picked[#picked + 1] = reaper.GetSelectedMediaItem(proj, i) end
  for _, x in ipairs(picked) do reaper.SetMediaItemSelected(x, false) end
  local was = reaper.GetActiveTake(it)
  reaper.SetActiveTake(tk)
  reaper.SetMediaItemSelected(it, true)
  reaper.Main_OnCommand(40153, 0)
  reaper.SetMediaItemSelected(it, false)
  if was then reaper.SetActiveTake(was) end
  for _, x in ipairs(picked) do reaper.SetMediaItemSelected(x, true) end
  ours = it
  return true
end

function midiview.options(ctx, ImGui)
  local rv, v = ImGui.Checkbox(ctx, "Open bandmates' MIDI edits as they happen##midiview", midiview.on())
  if rv then reaper.SetExtState(require("band").SECTION, "show midi edits", v and "on" or "", true) end
  ImGui.SetItemTooltip(ctx, "When someone's change to a MIDI part reaches you, it opens in the MIDI editor with the notes they changed selected.\n" ..
    "A MIDI editor you opened yourself is left alone. Only on this computer.")
end

return midiview
