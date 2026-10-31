-- Plug-ins the whole band has. Each machine publishes the plug-ins it has (<shared folder>/plugins/<user>.json,
-- names only); what everyone has goes in a folder of REAPER's FX browser, "BandSync (everyone has)", so you
-- can pick from it knowing the song will open with that sound on every bandmate's machine.
--   reaper-fxfolders.ini (format as REAPER writes it, and as Sexan's FX Browser parser reads it):
--     [Folders] IdN=<folder number> NameN=<name> NbFolders=<count>
--     [Folder<number>] ItemK=<ident> TypeK=<3 VST/VST3, 2 JS, 7 CLAP, 5 AU, 1 LV2> Nb=<count>
local band = require("band")
local plugins = {}
plugins.FOLDER = "BandSync (everyone has)"

-- "VST3: Surge XT (Surge Synth Team) (2->6ch)" -> "surge xt (surge synth team)": the same plug-in in any format,
-- on any OS. Pure.
function plugins.key(name)
  local n = (name or ""):gsub("^%w+:%s*", "")
  n = n:gsub("%s*%(%d+%->%d+ch%)$", ""):gsub("%s*%(%d+ out%)$", ""):gsub("%s*%(x64%)$", ""):gsub("%s*%(x86%)$", "")
  return n:lower()
end

-- Which format to list when a plug-in comes in several: VST3 first (Windows and Mac both have it, so a chain
-- saved with it loads everywhere), then CLAP, VST, AU, LV2; JSFX are one of a kind. Pure.
local RANK = { VST3 = 1, VST3i = 1, CLAP = 2, CLAPi = 2, VST = 3, VSTi = 3, AU = 4, AUi = 4, LV2 = 5, LV2i = 5, JS = 1 }
local TYPE = { VST3 = 3, VST3i = 3, VST = 3, VSTi = 3, CLAP = 7, CLAPi = 7, AU = 5, AUi = 5, LV2 = 1, LV2i = 1, JS = 2 }
function plugins.kind(name) return (name or ""):match("^(%w+):") end

-- This machine's plug-ins: { {name, ident} } (REAPER's own list, as the FX browser has it).
function plugins.installed()
  local out = {}
  for i = 0, math.huge do
    local ok, name, ident = reaper.EnumInstalledFX(i)
    if not ok then break end
    if TYPE[plugins.kind(name) or ""] then out[#out + 1] = { name = name, ident = ident } end
  end
  return out
end

local function dir(cfg) return cfg.root .. "/plugins" end

-- Publish this machine's list (only when it changed). Returns the number of plug-ins.
function plugins.publish(cfg)
  local seen, names = {}, {}
  for _, p in ipairs(plugins.installed()) do
    local k = plugins.key(p.name)
    if not seen[k] then seen[k] = true; names[#names + 1] = k end
  end
  table.sort(names)
  local path = dir(cfg) .. "/" .. (cfg.user:gsub("[^%w%-_]", "_")) .. ".json"
  local old = band.read_json(path)
  if not (old and band.json_encode(old.names or {}) == band.json_encode(names)) then
    reaper.RecursiveCreateDirectory(dir(cfg), 0)
    band.write_json(path, { user = cfg.user, os = reaper.GetOS(), time = os.date("!%Y-%m-%dT%H:%M:%SZ"), names = names })
  end
  return #names
end

-- What every published list has in common: set of keys, and who published (lists under 90 days old). Pure
-- over `lists` ({ {user, names} }).
function plugins.common(lists)
  local count, members = {}, {}
  for _, l in ipairs(lists) do
    members[#members + 1] = l.user
    local once = {}
    for _, k in ipairs(l.names or {}) do
      if not once[k] then once[k] = true; count[k] = (count[k] or 0) + 1 end
    end
  end
  local set = {}
  for k, n in pairs(count) do if n == #lists then set[k] = true end end
  return set, members
end

function plugins.band(cfg)
  local lists = {}
  for _, f in ipairs(band.files(dir(cfg), ".json")) do
    local l = band.read_json(dir(cfg) .. "/" .. f)
    if type(l) == "table" and type(l.user) == "string" and type(l.names) == "table" and type(l.time) == "string"
        and band.age(l.time) < 90 * 86400 then lists[#lists + 1] = l end
  end
  return plugins.common(lists)
end

-- reaper-fxfolders.ini with our folder set to `items` ({ {ident, type} }), every other folder as it was. Pure.
function plugins.folders_ini(text, name, items)
  local sections, order = {}, {}
  local cur
  for line in ((text or "") .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    local sec = line:match("^%[(.-)%]%s*$")
    if sec then cur = sec; if not sections[sec] then sections[sec] = {}; order[#order + 1] = sec end
    elseif cur and line ~= "" then sections[cur][#sections[cur] + 1] = line end
  end
  local folders = {} -- { {id, name} } in order
  local f = {}
  for _, l in ipairs(sections.Folders or {}) do
    local k, i, v = l:match("^(%a+)(%d+)=(.*)$")
    if k == "Id" or k == "Name" then
      f[tonumber(i)] = f[tonumber(i)] or {}
      f[tonumber(i)][k == "Id" and "id" or "name"] = v
    end
  end
  for i = 0, #f + 1 do if f[i] and f[i].id then folders[#folders + 1] = f[i] end end
  local ours, top = nil, -1
  for _, x in ipairs(folders) do
    top = math.max(top, tonumber(x.id) or -1)
    if x.name == name then ours = x end
  end
  if not ours then ours = { id = tostring(top + 1), name = name }; folders[#folders + 1] = ours end
  local body = {}
  for k, it in ipairs(items) do
    body[#body + 1] = "Item" .. (k - 1) .. "=" .. it.ident
    body[#body + 1] = "Type" .. (k - 1) .. "=" .. it.type
  end
  body[#body + 1] = "Nb=" .. #items
  local fs = "Folder" .. ours.id
  if not sections[fs] then order[#order + 1] = fs end
  sections[fs] = body
  local list = {}
  for i, x in ipairs(folders) do
    list[#list + 1] = "Id" .. (i - 1) .. "=" .. x.id
    list[#list + 1] = "Name" .. (i - 1) .. "=" .. x.name
  end
  list[#list + 1] = "NbFolders=" .. #folders
  if not sections.Folders then order[#order + 1] = "Folders" end
  sections.Folders = list
  local out = {}
  for _, sec in ipairs(order) do
    out[#out + 1] = "[" .. sec .. "]"
    for _, l in ipairs(sections[sec]) do out[#out + 1] = l end
    out[#out + 1] = ""
  end
  return table.concat(out, "\n") .. "\n"
end

-- REAPER's FX browser lists categories from reaper-fxtags.ini ([category] <plug-in file or CLAP id>=A|B|C). The
-- plug-ins everyone in the band has also go in a "BandSync" category (next to its Categories and Developers).
plugins.CATEGORY = "BandSync"
-- The category key REAPER uses for an installed plug-in: the file name for VST/VST3, the id for CLAP; nil for a
-- plug-in inside a shell (Waves) or a JSFX. Pure.
function plugins.tag_key(ident, kind)
  if (kind or ""):match("^CLAP") then return ident end
  if (kind or ""):match("^VST") and not ident:find("<", 1, true) then return ident:match("[^\\/]+$") end
end
-- reaper-fxtags.ini with "BandSync" on exactly the keys in `set`, every other category kept. Pure.
function plugins.tags_ini(text, set)
  local lines, sec, seen, at, out = {}, nil, {}, nil, {}
  for line in ((text or "") .. "\n"):gmatch("([^\r\n]*)\r?\n") do lines[#lines + 1] = line end
  if lines[#lines] == "" then lines[#lines] = nil end
  for _, line in ipairs(lines) do
    local name = line:match("^%[(.-)%]%s*$")
    if name then
      sec = name
      out[#out + 1] = line
      if name == "category" then at = #out end -- (new entries go right under the header)
    elseif sec == "category" and line:find("=", 1, true) then
      local k, v = line:match("^(.-)=(.*)$")
      local cats = {}
      for c in (v .. "|"):gmatch("([^|]*)|") do if c ~= "" and c ~= plugins.CATEGORY then cats[#cats + 1] = c end end
      if set[k] then cats[#cats + 1] = plugins.CATEGORY; seen[k] = true end
      if #cats > 0 then out[#out + 1] = k .. "=" .. table.concat(cats, "|") end
    else
      out[#out + 1] = line
    end
  end
  local add = {}
  for k in pairs(set) do if not seen[k] then add[#add + 1] = k .. "=" .. plugins.CATEGORY end end
  table.sort(add)
  if not at then out[#out + 1] = "[category]"; at = #out end
  for i, l in ipairs(add) do table.insert(out, at + i, l) end
  return table.concat(out, "\n") .. "\n"
end

-- The band's folder for this machine: its own plug-ins that everyone has, one format each. Returns how many,
-- and the members, or nil + why (fewer than two lists: nothing to compare yet).
function plugins.update_folder(cfg, min_members)
  local set, members = plugins.band(cfg)
  if #members < (min_members or 2) then return nil, "waiting for bandmates' plug-in lists (they're sent when Live sync starts)", members end
  local best = {}
  for _, p in ipairs(plugins.installed()) do
    local k, kind = plugins.key(p.name), plugins.kind(p.name)
    if set[k] and (not best[k] or RANK[kind] < RANK[best[k].kind]) then best[k] = { ident = p.ident, type = TYPE[kind], kind = kind, name = p.name } end
  end
  local items = {}
  for _, v in pairs(best) do items[#items + 1] = v end
  table.sort(items, function(a, z) return a.name:lower() < z.name:lower() end)
  local path = reaper.GetResourcePath() .. "/reaper-fxfolders.ini"
  local old = band.read(path) or ""
  local new = plugins.folders_ini(old, plugins.FOLDER, items)
  if new ~= old then band.write_atomic(path, new) end
  -- and the BandSync category (REAPER reads both when it starts: a new list shows after a restart)
  local keys = {}
  for _, it in ipairs(items) do local k = plugins.tag_key(it.ident, it.kind); if k then keys[k] = true end end
  local tpath = reaper.GetResourcePath() .. "/reaper-fxtags.ini"
  local told = band.read(tpath) or ""
  local tnew = plugins.tags_ini(told, keys)
  if tnew ~= told then band.write_atomic(tpath, tnew) end
  return #items, nil, members
end

return plugins
