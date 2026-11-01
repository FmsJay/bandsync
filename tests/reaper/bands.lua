-- Run inside REAPER (ReaScript). Bands (docs/bands-design.md): starting a band makes its own folder, band.json and
-- Syncthing folder, this computer then works in it, both bands are listed, a song tab keeps its own band, and an
-- invitation names the band. Scratch folders only; Syncthing's commands are recorded here, not run, and this
-- computer's own band settings (ExtState sync_root, bands) are put back at the end.
local D = reaper.GetResourcePath() .. "/BandSync/tests"
local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/"
package.path = lib .. "?.lua;" .. package.path
for _, m in ipairs({ "band", "services", "json" }) do package.loaded[m] = nil end
local band, services = require("band"), require("services")
local out, fails = {}, 0
local function say(s) out[#out + 1] = s end
local function check(ok, what) if not ok then fails = fails + 1 end; say((ok and "PASS " or "FAIL ") .. what) end
local saved = { root = reaper.GetExtState(band.SECTION, "sync_root"), bands = reaper.GetExtState(band.SECTION, "bands") }
local real_exec, cmds = reaper.ExecProcess, {}
local base = D .. "/broot_" .. os.time() .. "/BandSync"
local ok, err = pcall(function()
  reaper.RecursiveCreateDirectory(base .. "/Lantern/rooms/main", 0)
  reaper.RecursiveCreateDirectory(base .. "/_band", 0)
  band.write_json(base .. "/_band/band.json", { name = "Chilio", id = "bandsync", drive = "BandSync" })
  reaper.SetExtState(band.SECTION, "sync_root", base, false)
  reaper.SetExtState(band.SECTION, "bands", "", false)
  local cfg = { root = base, user = "James" }
  check(band.info(base).name == "Chilio" and band.info(base).id == "bandsync" and band.info(base).drive == "BandSync", "the first band reads as Chilio")
  check(band.info(D .. "/nowhere").id == "bandsync" and band.info(D .. "/nowhere").drive == "BandSync", "a folder without band.json is the first band")
  reaper.ExecProcess = function(c) cmds[#cmds + 1] = c; return "0\n" end -- (Syncthing's commands recorded, not run)
  local root, why = services.new_band(cfg, "Night Shift")
  reaper.ExecProcess = real_exec
  check(root == D .. "/broot_" .. base:match("broot_(%d+)") .. "/BandSync Night Shift", "its folder beside the first band's (" .. tostring(root or why) .. ")")
  local info = band.info(root)
  check(info.name == "Night Shift" and info.id == "bandsync-night-shift" and info.drive == "BandSync - Night Shift", "band.json says who it is")
  local added = false
  for _, c in ipairs(cmds) do if c:find("folders add --id bandsync-night-shift", 1, true) and c:find("BandSync Night Shift", 1, true) then added = true end end
  check(added, "Syncthing gets a folder of its own for it")
  check(reaper.GetExtState(band.SECTION, "sync_root") == root, "this computer works in the new band now")
  local names = {}
  for _, x in ipairs(band.bands()) do names[#names + 1] = x.name end
  check(table.concat(names, ",") == "Chilio,Night Shift", "both bands are listed (" .. table.concat(names, ",") .. ")")
  check(select(2, services.new_band(cfg, "night shift")) ~= nil, "a second band with the same name is refused")
  -- a Chilio song tab keeps Chilio while the computer works in Night Shift
  local now = band.settings()
  local tab = band.for_tab(now, { song = "Lantern", root = base })
  check(tab.root == base and tab.base.root == root, "a song tab keeps its own band")
  check(band.for_tab(tab, nil).root == root, "and a tab that isn't a song is the band you're working in")
  check(band.for_tab(now, { song = "Old" }).root == root, "a tab from before bands is in the current band")
  local inv = services.invite_text("2MOGZMD-MVLUUSO-D6GXQIG-HMDVUBG-AOW6LHR-LMQQT6P-V4V5P73-6ZR5NQZ", band.info(root))
  check(inv:find("BS_BAND_ID=bandsync-night-shift BS_BAND_NAME='Night Shift'", 1, true) and inv:find("-BandId bandsync-night-shift", 1, true), "an invitation is for this band")
  band.use_band(base)
  check(reaper.GetExtState(band.SECTION, "sync_root") == base and #band.bands() == 2, "switching back keeps both")
end)
reaper.ExecProcess = real_exec
if not ok then say("ERROR " .. tostring(err)); fails = fails + 1 end
reaper.SetExtState(band.SECTION, "sync_root", saved.root, true)
if saved.bands ~= "" then reaper.SetExtState(band.SECTION, "bands", saved.bands, true) else reaper.DeleteExtState(band.SECTION, "bands", true) end
say("(put back: sync_root " .. reaper.GetExtState(band.SECTION, "sync_root") .. ")")
return (fails == 0 and "ALL PASS" or (fails .. " FAILED")) .. "\n" .. table.concat(out, "\n")
