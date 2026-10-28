-- prep.wav_format: which WAVs convert to FLAC exactly (lupa or any Lua 5.4, from the repo root)
package.loaded.band = package.loaded.band or {}
package.path = "lib/?.lua;" .. package.path
local prep = require("prep")
local function wav(tag, bits, ext_tag)
  local fmt = string.pack("<I2I2I4I4I2I2", tag, 2, 48000, 48000 * 2 * bits // 8, 2 * bits // 8, bits)
  if tag == 0xFFFE then fmt = fmt .. string.pack("<I2I2I4I2", 22, bits, 3, ext_tag) .. string.rep("\0", 14) end
  return "RIFF" .. string.pack("<I4", 100) .. "WAVE" .. "JUNK" .. string.pack("<I4", 3) .. "abc\0" -- an odd-sized chunk first
    .. "fmt " .. string.pack("<I4", #fmt) .. fmt .. "data" .. string.pack("<I4", 0)
end
local t, b = prep.wav_format(wav(1, 16)); assert(t == 1 and b == 16, "16-bit PCM")
t, b = prep.wav_format(wav(1, 24)); assert(t == 1 and b == 24, "24-bit PCM")
t, b = prep.wav_format(wav(3, 32)); assert(t == 3 and b == 32, "float")
t, b = prep.wav_format(wav(0xFFFE, 24, 1)); assert(t == 1 and b == 24, "extensible PCM reads its sub-format")
t, b = prep.wav_format(wav(0xFFFE, 32, 3)); assert(t == 3, "extensible float")
assert(prep.wav_format("not a wav at all, just some text that is long enough to pass the length check") == nil, "not a WAV")
print("ok")
