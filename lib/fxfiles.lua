-- Files a plug-in loads by itself (a sampler's samples, an impulse response, an amp model): their paths sit inside
-- the plug-in's saved state, mostly base64, so a bandmate's copy of the chain points at a file their machine doesn't
-- have. The sender copies each such file into the room's media ("plugin files/"); a receiver puts a missing one back
-- at the same path when that folder can exist there (same drive layout, C:\Users\...), and otherwise says which
-- plug-in wants which file and where the shared copy is. The state itself is never rewritten (it's the plug-in's own
-- binary format).
local fxfiles = {}

-- what a plug-in loads by itself, by extension (samples, impulse responses, amp and capture models, instruments)
fxfiles.EXT = { wav = true, flac = true, aif = true, aiff = true, mp3 = true, ogg = true, nam = true, aidax = true, json = true,
  sfz = true, sf2 = true, ir = true }
fxfiles.MAX = 200 * 1024 * 1024 -- (bigger than this is a library, not a file to pass around)

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local DEC = {}
for i = 1, 64 do DEC[B64:byte(i)] = i - 1 end
function fxfiles.unbase64(s)
  local out, bits, n = {}, 0, 0
  for i = 1, #s do
    local v = DEC[s:byte(i)]
    if v then
      bits, n = bits * 64 + v, n + 6
      if n >= 8 then
        n = n - 8
        local byte = math.floor(bits / 2 ^ n) % 256
        out[#out + 1] = string.char(byte)
        bits = bits % 2 ^ n
      end
    end
  end
  return table.concat(out)
end

-- Absolute paths to such files anywhere in a plug-in chain's text, its base64 state decoded. Pure.
function fxfiles.paths(chain)
  local text, found, seen = { chain }, {}, {}
  -- a plug-in's state: its lines of base64, decoded line by line and joined (REAPER's lines are a multiple of 4
  -- characters long, so that's the same bytes, and a segment padded on its own last line doesn't shift the next)
  local blob = {}
  for line in chain:gmatch("[^\r\n]+") do
    local s = line:match("^%s*(.-)%s*$")
    if s:match("^[A-Za-z0-9+/]+=*$") and #s >= 8 then blob[#blob + 1] = fxfiles.unbase64(s)
    elseif #blob > 0 then text[#text + 1] = table.concat(blob); blob = {} end
  end
  if #blob > 0 then text[#text + 1] = table.concat(blob) end
  local all = table.concat(text, "\0")
  -- (wide strings: a UTF-16 path reads as letters with zero bytes between)
  all = all .. "\0" .. (all:gsub("([^\0])\0", "%1"))
  -- a run of path characters, cut back to its last known file extension (a folder may have a dot in its name)
  local function file_of(run)
    local best
    for z, ext in run:gmatch("()%.(%w+)") do
      local after = run:sub(z + 1 + #ext, z + 1 + #ext)
      if fxfiles.EXT[ext:lower()] and not after:match("%w") then best = run:sub(1, z + #ext) end
    end
    return best
  end
  for _, pat in ipairs({ "%a:[\\/][^%c\"<>|*?]+", "/Users/[^%c\"<>|*?]+", "/Volumes/[^%c\"<>|*?]+" }) do
    for run in all:gmatch(pat) do
      local path = file_of(run)
      if path and not seen[path:lower()] then seen[path:lower()] = true; found[#found + 1] = path end
    end
  end
  return found
end

-- Sender: copy each existing file the chain loads into <media>/plugin files/ (once). Returns { {path, copy} }.
function fxfiles.share(chain, media_dir)
  local band, list = require("band"), {}
  for _, path in ipairs(fxfiles.paths(chain)) do
    local size = reaper.file_exists(path) and band.size(path) or nil
    if size and size <= fxfiles.MAX then
      local name = path:gsub("\\", "/"):match("[^/]+$")
      local copy = "plugin files/" .. require("mirror").hash(path:lower()) .. "-" .. name
      local dst = media_dir .. "/" .. copy
      if not reaper.file_exists(dst) then
        reaper.RecursiveCreateDirectory(media_dir .. "/plugin files", 0)
        pcall(band.copy_atomic, path, dst)
      end
      if reaper.file_exists(dst) then list[#list + 1] = { path = path, copy = copy } end
    end
  end
  return list
end

-- Receiver, before the chain loads: each missing file goes back where the plug-in looks for it, if that folder can
-- exist here; the rest are said once (where the copy is, so the plug-in can be pointed at it).
fxfiles.said = {}
function fxfiles.fetch(list, media_dir, where)
  if type(list) ~= "table" then return end
  local band = require("band")
  for _, f in ipairs(list) do
    if type(f) == "table" and type(f.path) == "string" and type(f.copy) == "string" and not reaper.file_exists(f.path) then
      local src = media_dir .. "/" .. f.copy
      local dir = f.path:gsub("\\", "/"):match("^(.*)/[^/]+$")
      local drive = f.path:match("^(%a:)[\\/]")
      local can = reaper.file_exists(src) and dir and (not drive or reaper.EnumerateSubdirectories(drive .. "/", 0) ~= nil or reaper.EnumerateFiles(drive .. "/", 0) ~= nil)
      if can then
        reaper.RecursiveCreateDirectory(dir, 0)
        pcall(band.copy_atomic, src, f.path)
      end
      if not reaper.file_exists(f.path) and not fxfiles.said[f.path] then
        fxfiles.said[f.path] = true
        band.log(string.format("the plug-ins on %s load %s, which isn't on this machine: a copy is in %s (point the plug-in at it)",
          where, f.path, src))
      end
    end
  end
end

return fxfiles
