-- Run inside REAPER (ReaScript). Melodyne (ARA) on a take: the machine that edits it gets a print that travels; it
-- keeps playing the editable take, a bandmate plays the print; closing the Melodyne window makes a new print.
-- Needs Melodyne installed. Scratch folder and scratch tabs only.
local D = reaper.GetResourcePath() .. "/BandSync/tests"
reaper.RecursiveCreateDirectory(D, 0)
local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/"
package.path = lib .. "?.lua;" .. package.path
for _, m in ipairs({ "band", "sync", "mirror", "recall", "json", "prints" }) do package.loaded[m] = nil end
local sync, mirror, prints = require("sync"), require("mirror"), require("prints")
local stamp = os.time()
local root = D .. "/aroot_" .. stamp
local song, room = "AraLab", "main"
local A, B = { user = "James", root = root }, { user = "Bee", root = root }
reaper.RecursiveCreateDirectory(sync.room_dir(A, song, room) .. "/events", 0)
local yes = function() return true end
local out, fails = {}, 0
local function check(ok, what) if not ok then fails = fails + 1 end; out[#out + 1] = (ok and "PASS " or "FAIL ") .. what end
local function pass(p, cfg) reaper.SelectProjectInstance(p); local n = 0; for _ = 1, 3 do n = n + mirror.watch(p, cfg, song, room, { can = yes, mode = "claims" }) end; return n end
local function recv(p, cfg) reaper.SelectProjectInstance(p); local n = 0; for _ = 1, 3 do n = n + sync.receive(p, cfg, song, room, yes) end; return n end
local front = reaper.EnumProjects(-1)
local pa, pb
local ok, err = pcall(function()
  reaper.Main_OnCommand(40859, 0); pa = reaper.EnumProjects(-1)
  reaper.Main_OnCommand(40859, 0); pb = reaper.EnumProjects(-1)
  local wav = D .. "/ara_vox_" .. stamp .. ".wav"
  local n, sr = 96000, 48000
  local s = {}
  for i = 0, n - 1 do s[#s + 1] = string.pack("<i2", math.floor(8000 * math.sin(2 * math.pi * 220 * i / sr))) end
  local f = assert(io.open(wav, "wb"))
  f:write("RIFF", string.pack("<I4", 36 + 2 * n), "WAVEfmt ", string.pack("<I4I2I2I4I4I2I2", 16, 1, 1, sr, sr * 2, 2, 16), "data", string.pack("<I4", 2 * n), table.concat(s))
  f:close()
  reaper.SelectProjectInstance(pa)
  reaper.InsertTrackInProject(pa, 0, 0)
  local tr = reaper.GetTrack(pa, 0)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "Vox", true)
  local it = reaper.AddMediaItemToTrack(tr)
  reaper.SetMediaItemInfo_Value(it, "D_LENGTH", 2)
  local tk = reaper.AddTakeToMediaItem(it)
  reaper.SetMediaItemTake_Source(tk, reaper.PCM_Source_CreateFromFile(wav))
  reaper.GetSetMediaItemTakeInfo_String(tk, "P_NAME", "lead vox", true)
  check(reaper.TakeFX_AddByName(tk, "VST3: Melodyne (Celemony)", -1) == 0, "Melodyne on the take")
  check(prints.ara_take(it) == tk, "it's recognised as an ARA take")
  out[#out + 1] = "A sent " .. pass(pa, A)
  local _, pr = prints.takes(it)
  check(pr ~= nil and reaper.CountTakes(it) == 2, "A made a print (takes " .. reaper.CountTakes(it) .. ")")
  check(reaper.GetActiveTake(it) == tk, "A keeps playing the editable take")
  local h1 = pr and select(2, reaper.GetSetMediaItemTakeInfo_String(pr, "P_EXT:" .. prints.KEY, "", false))
  recv(pb, B)
  local bit = mirror.find(pb, "item", mirror.item_oid(it))
  out[#out + 1] = string.format("  B: item %s, takes %s, arriving %q, items on B %d", tostring(bit ~= nil), bit and reaper.CountTakes(bit) or "-",
    bit and select(2, reaper.GetSetMediaItemInfo_String(bit, "P_EXT:band_arriving", "", false)) or "", reaper.CountMediaItems(pb))
  local _, _, kev = mirror.known(pa, mirror.item_oid(it))
  local ev = require("band").read_json(sync.room_dir(A, song, room) .. "/events/" .. tostring(kev) .. ".json") or {}
  for fl in (ev.state or ""):gmatch('FILE "([^"]+)"') do
    out[#out + 1] = "  source " .. fl .. " here: " .. tostring(reaper.file_exists(mirror.resolve_media('FILE "' .. fl .. '"', sync.room_dir(A, song, room) .. "/media"):match('"(.-)"')))
  end
  out[#out + 1] = "  A holds rev " .. tostring((mirror.known(pa, mirror.item_oid(it)))) .. ", B holds rev " .. tostring((mirror.known(pb, mirror.item_oid(it))))
  for k = 1, 5 do out[#out + 1] = "  log: " .. tostring(require("band").activity()[k]) end
  check(bit and reaper.CountTakes(bit) == 2, "B has the item with its print")
  local _, bpr = prints.takes(bit) -- (not `bit and prints.takes(bit)`: and keeps only the first value)
  check(bit and reaper.GetActiveTake(bit) == bpr, "B plays the print (its Melodyne doesn't have A's edits)")
  check(pass(pb, B) == 0, "B sends nothing back")
  -- an editing pass: the Melodyne window opens, then closes
  reaper.SelectProjectInstance(pa)
  reaper.TakeFX_Show(tk, 0, 3)
  prints.watch_ara(pa)
  reaper.TakeFX_Show(tk, 0, 2)
  out[#out + 1] = "A sent after the edit " .. pass(pa, A)
  local _, pr2 = prints.takes(it)
  local h2 = pr2 and select(2, reaper.GetSetMediaItemTakeInfo_String(pr2, "P_EXT:" .. prints.KEY, "", false))
  check(h2 and h2 ~= h1, "closing the window made a new print")
  recv(pb, B)
  bit = mirror.find(pb, "item", mirror.item_oid(it)) -- (an ARA item is rebuilt fresh on each change)
  local _, bpr2 = prints.takes(bit)
  check(bpr2 and select(2, reaper.GetSetMediaItemTakeInfo_String(bpr2, "P_EXT:" .. prints.KEY, "", false)) == h2, "B got the new print")
end)
if not ok then fails = fails + 1; out[#out + 1] = "ERROR " .. tostring(err) end
for _, p in pairs({ pa, pb }) do
  if reaper.ValidatePtr2(0, p, "ReaProject*") then
    reaper.SelectProjectInstance(p)
    reaper.Main_SaveProjectEx(p, D .. "/ara_" .. stamp .. "_end.rpp", 8)
    reaper.Main_OnCommand(40860, 0)
  end
end
if front and reaper.ValidatePtr2(0, front, "ReaProject*") then reaper.SelectProjectInstance(front) end
return (fails == 0 and "ALL PASS" or fails .. " FAILED") .. "\n" .. table.concat(out, "\n")
