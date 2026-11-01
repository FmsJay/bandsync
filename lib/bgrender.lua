-- Prints rendered in the background (James, 2026-11-01: render wet takes so people can keep editing meanwhile).
-- REAPER renders only in the project in front, holding its window until done. A second REAPER, started hidden on a
-- saved copy with -renderproject, renders while this one carries on: the copy is saved set up exactly as the
-- render in front would be (band.render saves it instead of rendering when a job is open), then that's put back.
-- Measured on the PC (REAPER 7.84): a short MIDI print through a VST3 instrument took ~4 s, no window in front.
-- The copy keeps every track (routing still points at the right ones) with the plug-ins of the tracks the print
-- doesn't go through switched offline, so only what it needs loads.
-- Costs: the second REAPER writes reaper.ini when it quits (as it read it when it started) and puts the copy in the
-- recent-projects list; this REAPER writes its own over both when it quits. Where background renders don't work
-- (two failures, none done), prints render in front again for the rest of the session.
local band = require("band")
local bg = {}

local WIN = reaper.GetOS():find("^Win") ~= nil
local TMP = ((WIN and (os.getenv("TEMP") or os.getenv("TMP")) or os.getenv("TMPDIR") or "/tmp"):gsub("\\", "/"):gsub("/+$", "")) .. "/bandsync-render"
bg.WAIT = 180 -- seconds before a job that hasn't finished counts as failed
local jobs = {} -- name -> { dir, started, sizes, at }
local done, failed = 0, 0

-- Whether prints go to the background here (ExtState "bg render" = "off" turns it off for good).
function bg.on()
  if reaper.GetExtState(band.SECTION, "bg render") == "off" then return false end
  if failed >= 2 and done == 0 then return false end
  return WIN or reaper.GetOS():find("^OSX") ~= nil or reaper.GetOS():find("^macOS") ~= nil
end

-- The copy, with the plug-ins of every track not in `keep` (REAPER track GUIDs) and the master's switched offline
-- (BYPASS <bypass> <offline> ...). Pure.
function bg.offline_others(text, keep)
  local out, depth, inside, keeping = {}, 0, nil, true
  for raw in text:gmatch("[^\n]*\n?") do
    if raw == "" then break end
    local line = raw
    local s = line:match("^%s*(.-)%s*$")
    if depth == 1 and s:sub(1, 1) == "<" then
      local guid = s:match("^<TRACK%s+(%b{})")
      inside, keeping = s:match("^<(%S+)"), guid ~= nil and keep[guid:upper()] or false
    end
    if (inside == "TRACK" or inside == "MASTERFXLIST") and not keeping then
      line = line:gsub("^(%s*BYPASS %d+ )%d+", "%11")
    end
    if s:sub(1, 1) == "<" then depth = depth + 1 elseif s == ">" then depth = depth - 1 end
    if depth == 1 and s == ">" then inside, keeping = nil, true end
    out[#out + 1] = line
  end
  return table.concat(out)
end

local function launch(exe, job)
  if WIN then
    local cmd, vbs = job:gsub("%.rpp$", ".cmd"), TMP .. "/hidden.vbs"
    band.write_atomic(cmd, string.format('@"%s" -newinst -nosplash -ignoreerrors -noactivate -renderproject "%s"\r\n', exe, job))
    if not reaper.file_exists(vbs) then band.write_atomic(vbs, 'CreateObject("WScript.Shell").Run """" & WScript.Arguments(0) & """", 0, False\r\n') end
    reaper.ExecProcess(string.format('wscript.exe //B //Nologo "%s" "%s"', vbs, cmd), -1)
  else -- shortcut: untried on a Mac; a job that never finishes counts as failed, and prints render in front again
    local sh = job:gsub("%.rpp$", ".sh")
    band.write_atomic(sh, string.format("nohup '%s' -newinst -nosplash -ignoreerrors -noactivate -renderproject '%s' >/dev/null 2>&1 &\n", exe, job))
    reaper.ExecProcess("/bin/sh '" .. sh .. "'", -1)
  end
end
local function exe_path()
  local d = reaper.GetExePath():gsub("\\", "/")
  if WIN then return d .. "/reaper.exe" end
  if d:match("%.app$") then return d .. "/Contents/MacOS/REAPER" end
  return d .. "/REAPER"
end

-- Render in the background, one print per item (`key`) at a time: `render(dir)` sets the project up and calls
-- band.render as it always does (which saves the copy into `dir` instead of rendering); `keep`: the tracks the
-- print goes through. Active tab only.
function bg.start(key, name, keep, render)
  local dir = TMP .. "/" .. name
  reaper.RecursiveCreateDirectory(dir, 0)
  for _, f in ipairs(band.files(dir)) do os.remove(dir .. "/" .. f) end
  local job = dir .. "/job.rpp"
  band.render_job = { dir = dir, copy = job }
  local ok, err = pcall(render, dir)
  band.render_job = nil
  if not ok or not reaper.file_exists(job) then return false, err end
  local set = {}
  for _, g in ipairs(keep) do set[g:upper()] = true end
  band.write_atomic(job, bg.offline_others(band.read(job), set))
  launch(exe_path(), job)
  jobs[key] = { name = name, dir = dir, started = reaper.time_precise(), sizes = {} }
  return true
end

-- A job's output files once it has finished, else nil. Finished: on Windows, they can be renamed (REAPER holds
-- them open while it writes; each is renamed and back); elsewhere, their sizes held still for 2 s.
local function finished(j)
  local files = {}
  for _, f in ipairs(band.files(j.dir)) do
    local ext = f:match("%.(%a+)$")
    if ext == "flac" or ext == "opus" then files[#files + 1] = f end
  end
  if #files < 2 then return nil end
  if WIN then
    for _, f in ipairs(files) do
      local a = j.dir .. "/" .. f
      if not os.rename(a, a .. ".x") then return nil end
      os.rename(a .. ".x", a)
    end
    return files
  end
  local now, same = reaper.time_precise(), j.at ~= nil and reaper.time_precise() - j.at >= 2
  for _, f in ipairs(files) do
    local n = band.size(j.dir .. "/" .. f)
    if not n or n == 0 or n ~= j.sizes[f] then same = false end
    j.sizes[f] = n
  end
  if same then return files end
  if not j.at or now - j.at >= 2 then j.at = now end
  return nil
end
local function drop(key)
  local j = jobs[key]
  for _, f in ipairs(band.files(j.dir)) do os.remove(j.dir .. "/" .. f) end
  jobs[key] = nil
end
local function timed_out(key)
  failed = failed + 1
  drop(key)
  band.log("a print didn't render in the background within " .. bg.WAIT .. " s: it renders here instead" ..
    ((failed >= 2 and done == 0) and " (and so will the rest this session)" or ""))
end

-- Whether a background render is still going (one at a time: each is a whole REAPER).
function bg.busy()
  for key, j in pairs(jobs) do
    if not finished(j) then
      if reaper.time_precise() - j.started <= bg.WAIT then return true end
      timed_out(key)
    end
  end
  return false
end

-- The item's print `name`, moved into `out` once rendered: its .flac path. Else nil and "running", "failed", or
-- nothing (no job for it, or the job was for what the item was before: that one's dropped).
function bg.claim(key, name, out)
  local j = jobs[key]
  if not j then return nil end
  local files = finished(j)
  if not files then
    if reaper.time_precise() - j.started <= bg.WAIT then return nil, "running" end
    timed_out(key)
    return nil, "failed"
  end
  if j.name ~= name then drop(key); return nil end
  reaper.RecursiveCreateDirectory(out, 0)
  local flac
  for _, f in ipairs(files) do
    -- (whatever the render called it: a stem render may add the track's name, a leftover a "-2")
    local ext = f:match("%.(%a+)$")
    os.remove(out .. "/" .. name .. "." .. ext)
    if os.rename(j.dir .. "/" .. f, out .. "/" .. name .. "." .. ext) and ext == "flac" then flac = out .. "/" .. name .. "." .. ext end
  end
  drop(key)
  if flac then done = done + 1 end
  return flac, not flac and "failed" or nil
end

return bg
