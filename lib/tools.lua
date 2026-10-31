-- The panel's tools: keep/dismiss live ideas, and starting Live sync with REAPER. (Dry mode, take back, print audio
-- and the take-based undo went with mirror sync in 0.30: Restore and the top bar's Undo/Redo replace them.)
local band = require("band")
local tools = {}

-- ---- live ideas (placeholders from Play along) ---------------------------------------------------------------
function tools.ideas(proj)
  local by = {}
  for i = 0, reaper.CountMediaItems(proj) - 1 do
    local it = reaper.GetMediaItem(proj, i)
    if band.item_ext(it, "band_live") ~= "" then
      local who = select(2, reaper.GetTrackName(reaper.GetMediaItem_Track(it))):gsub(" %(live%)$", "")
      by[who] = (by[who] or 0) + 1
    end
  end
  return by
end
-- Keep: the selected placeholders become ordinary items of ours (no take will ever replace them).
function tools.keep_ideas(proj)
  local n = 0
  for i = 0, reaper.CountSelectedMediaItems(proj) - 1 do
    local it = reaper.GetSelectedMediaItem(proj, i)
    if band.item_ext(it, "band_live") ~= "" then
      for _, k in ipairs({ "band_live", "band_live_since", "band_live_heard" }) do band.set_item_ext(it, k, "") end
      n = n + 1
    end
  end
  return n
end
-- Dismiss: every placeholder (of `who`, or everyone's) goes.
function tools.dismiss_ideas(proj, who)
  local n = 0
  for i = reaper.CountMediaItems(proj) - 1, 0, -1 do
    local it = reaper.GetMediaItem(proj, i)
    if band.item_ext(it, "band_live") ~= "" then
      local tr = reaper.GetMediaItem_Track(it)
      if not who or select(2, reaper.GetTrackName(tr)):gsub(" %(live%)$", "") == who then
        reaper.DeleteTrackMediaItem(tr, it)
        n = n + 1
      end
    end
  end
  return n
end

-- ---- Live sync with REAPER: a block in Scripts/__startup.lua runs BandSync - Autostart.lua -------------------
local MARK_A, MARK_Z = "-- BandSync autostart", "-- /BandSync autostart"
local function startup_path() return reaper.GetResourcePath() .. "/Scripts/__startup.lua" end
function tools.autostart_on()
  return (band.read(startup_path()) or ""):find(MARK_A, 1, true) ~= nil
end
function tools.set_autostart(on, dir)
  local text = band.read(startup_path()) or ""
  local a = text:find(MARK_A, 1, true)
  if a then
    local z = text:find(MARK_Z, a, true)
    text = text:sub(1, a - 1) .. (z and text:sub(z + #MARK_Z + 1) or "")
  end
  if on then
    text = text .. (text ~= "" and not text:match("\n$") and "\n" or "") ..
      MARK_A .. "\ndofile([[" .. dir .. "/BandSync - Autostart.lua]])\n" .. MARK_Z .. "\n"
  end
  reaper.RecursiveCreateDirectory(reaper.GetResourcePath() .. "/Scripts", 0)
  return pcall(band.write_atomic, startup_path(), text) -- (write_atomic returns nothing: it raises when it can't)
end

return tools
