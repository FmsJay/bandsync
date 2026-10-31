-- fxfiles: finding the files a plug-in loads by itself, in plain text and in base64 state (pure)
package.path = "lib/?.lua;" .. package.path
local fx = require("fxfiles")

local function b64(s)
  local A = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  local out = {}
  for i = 1, #s, 3 do
    local a, b, c = s:byte(i, i + 2)
    local n = a * 65536 + (b or 0) * 256 + (c or 0)
    for k = 3, 0, -1 do
      local idx = math.floor(n / 64 ^ k) % 64
      out[#out + 1] = (k == 1 and not b or k == 0 and not c) and "=" or A:sub(idx + 1, idx + 1)
    end
  end
  return table.concat(out)
end
assert(fx.unbase64(b64("hello world!")) == "hello world!", "base64 round trip")
assert(fx.unbase64(b64("ab")) == "ab", "base64 with padding")

-- a NAM model path inside a VST's binary state, an IR in a JS slider string, a sample in UTF-16, a folder with a dot
local state = "\1\0\0\0modelPath\0C:\\Users\\Bee\\Models\\Plexi v1.2\\crunch.nam\0\2\3"
local wide = ("D:\\Samples\\kick.wav"):gsub(".", "%0\0")
local chain = "<FXCHAIN\nBYPASS 0 0 0\n<VST \"VST3: NAM\" nam.vst3 0 \"\"\n" .. b64(state) .. "\n" .. b64("\0\0" .. wide .. "\0\0") .. "\n>\n" ..
  "BYPASS 0 0 0\n<JS convolver \"\"\n0 - - \"/Users/bee/IRs/room.wav\"\n>\nWAK 0 0\n>\n"
local paths = fx.paths(chain)
local set = {}
for _, p in ipairs(paths) do set[p] = true end
assert(set["C:\\Users\\Bee\\Models\\Plexi v1.2\\crunch.nam"], "NAM model in base64 state (folder with a dot): " .. table.concat(paths, " | "))
assert(set["/Users/bee/IRs/room.wav"], "impulse response in plain text: " .. table.concat(paths, " | "))
assert(set["D:\\Samples\\kick.wav"], "sample path in UTF-16: " .. table.concat(paths, " | "))
assert(#fx.paths("<FXCHAIN\nBYPASS 0 0 0\n<JS eq \"\"\n1 2 3\n>\n>\n") == 0, "a chain without files")
print("ok")
