-- band.color_out / color_in: colours travel in Windows' byte order whatever the machine (lupa or Lua 5.4, repo root)
package.path = "lib/?.lua;" .. package.path
reaper = {}
local band = require("band")
local function as(platform) -- REAPER's native colour: 0x00BBGGRR on Windows, 0x00RRGGBB on macOS
  if platform == "win" then
    reaper.ColorToNative = function(r, g, b) return r | (g << 8) | (b << 16) end
    reaper.ColorFromNative = function(c) return c & 0xFF, (c >> 8) & 0xFF, (c >> 16) & 0xFF end
  else
    reaper.ColorToNative = function(r, g, b) return (r << 16) | (g << 8) | b end
    reaper.ColorFromNative = function(c) return (c >> 16) & 0xFF, (c >> 8) & 0xFF, c & 0xFF end
  end
end
local red_win, red_mac = 0x10000FF, 0x1FF0000 -- the same red, as each platform's REAPER holds it (flag set)
as("win")
assert(band.color_out(red_win) == red_win and band.color_in(red_win) == red_win, "Windows: travels as it is")
as("mac")
assert(band.color_out(red_mac) == red_win, "a Mac's red travels as Windows' red")
assert(band.color_in(red_win) == red_mac, "and arrives on a Mac as its own red")
assert(band.color_out(0) == 0 and band.color_in(0) == 0 and band.color_in(nil) == 0, "no colour stays none")
print("ok")
