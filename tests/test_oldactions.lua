reaper = setmetatable({}, { __index = function() return function() end end })
package.path = "lib/?.lua;" .. package.path
local band = require("band")
local files = {
  ["/R/Scripts/BandSync tabs/BandSync - Live sync (tab 1).lua"] = "dofile([[/R/Scripts/BandSync/BandSync/BandSync - Live sync.lua]])\n",
  ["/R/Scripts/BandSync tabs/BandSync - Live sync (tab 2).lua"] = "dofile([[/R/Scripts/Kept/BandSync - Live sync.lua]])\n",
  ["/R/Scripts/Kept/BandSync - Live sync.lua"] = "-- still here\n",
  ["/R/Scripts/StudioSync/StudioSync - Undo.lua"] = "-- current\n",
}
local text = [[
SCR 4 32060 RS1 "Custom: BandSync - Undo.lua" "BandSync/BandSync/BandSync - Undo.lua"
SCR 4 0 RS2 "Custom: BandSync - Live sync (tab 1).lua" "BandSync tabs/BandSync - Live sync (tab 1).lua"
SCR 4 0 RS3 "Custom: BandSync - Live sync (tab 2).lua" "BandSync tabs/BandSync - Live sync (tab 2).lua"
SCR 4 0 RS4 "Custom: StudioSync - Undo.lua" "StudioSync/StudioSync - Undo.lua"
SCR 4 0 RS5 "Custom: Someone else's.lua" "Other/Something - Else.lua"
]]
local out = band.old_actions(text, "/R/Scripts", function(p) return files[p] ~= nil end, function(p) return files[p] end)
assert(#out == 2, "two are old, got " .. #out)
assert(out[1].section == 32060 and out[1].path == "/R/Scripts/BandSync/BandSync/BandSync - Undo.lua", out[1].path)
assert(out[2].section == 0 and out[2].path:find("(tab 1)", 1, true), out[2].path)
print("ok")
