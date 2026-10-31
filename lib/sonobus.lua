-- SonoBus's saved state, read and written so BandSync can put the band's group straight into it: SonoBus then
-- joins by itself (its "Reconnect Last" rejoins the newest recent connection whenever it's instantiated), with no
-- paste and no clipboard. Layout, from SonoBus 1.7.2 / JUCE (SonobusPluginProcessor::getStateInformation, verified
-- against a real REAPER vst_chunk, tests/fixtures/sonobus_1.7.2_state.bin):
--   REAPER VST3 chunk = u32 LE length L, u32 (1), L bytes of component state, 8 trailing bytes
--   component state   = a JUCE ValueTree (binary) followed by JUCE's private data, which JUCE finds from the end
--   ValueTree         = type\0, cint #props, (name\0, cint size, var bytes) ..., cint #children, children ...
--   cint              = one byte holding the byte count (0x80 = negative), then that many little-endian bytes
-- Everything here is pure (no reaper.*), so it's tested outside REAPER.
local sonobus = {}

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64I = {}
for i = 1, 64 do B64I[B64:byte(i)] = i - 1 end

function sonobus.b64decode(s)
  s = s:gsub("[^%w%+/]", "")
  local out = {}
  for i = 1, #s, 4 do
    local a, b, c, d = B64I[s:byte(i)], B64I[s:byte(i + 1) or 0], B64I[s:byte(i + 2) or 0], B64I[s:byte(i + 3) or 0]
    local n = (a << 18) | ((b or 0) << 12) | ((c or 0) << 6) | (d or 0)
    out[#out + 1] = string.char((n >> 16) & 255)
    if c then out[#out + 1] = string.char((n >> 8) & 255) end
    if d then out[#out + 1] = string.char(n & 255) end
  end
  return table.concat(out)
end

function sonobus.b64encode(s)
  local out = {}
  for i = 1, #s, 3 do
    local a, b, c = s:byte(i, i + 2)
    local n = (a << 16) | ((b or 0) << 8) | (c or 0)
    out[#out + 1] = B64:sub((n >> 18) + 1, (n >> 18) + 1) .. B64:sub(((n >> 12) & 63) + 1, ((n >> 12) & 63) + 1)
      .. (b and B64:sub(((n >> 6) & 63) + 1, ((n >> 6) & 63) + 1) or "=") .. (c and B64:sub((n & 63) + 1, (n & 63) + 1) or "=")
  end
  return table.concat(out)
end

local function rd_cint(s, p)
  local h = s:byte(p)
  local n, v = h & 0x7F, 0
  for i = n, 1, -1 do v = v * 256 + s:byte(p + i) end
  return (h & 0x80 ~= 0) and -v or v, p + 1 + n
end
local function wr_cint(v)
  local u, bytes = math.abs(v), {}
  while u > 0 do bytes[#bytes + 1] = string.char(u & 255); u = u >> 8 end
  return string.char(#bytes | (v < 0 and 0x80 or 0)) .. table.concat(bytes)
end
local function rd_str(s, p)
  local e = s:find("\0", p, true)
  return s:sub(p, e - 1), e + 1
end

-- A ValueTree as { type = "...", props = { { name, raw } ... }, children = { ... } }; raw = the var's bytes.
local function rd_tree(s, p)
  local t = { props = {}, children = {} }
  t.type, p = rd_str(s, p)
  local n
  n, p = rd_cint(s, p)
  for i = 1, n do
    local name, size
    name, p = rd_str(s, p)
    size, p = rd_cint(s, p)
    t.props[i] = { name, s:sub(p, p + size - 1) }
    p = p + size
  end
  n, p = rd_cint(s, p)
  for i = 1, n do t.children[i], p = rd_tree(s, p) end
  return t, p
end
local function wr_tree(t, out)
  out[#out + 1] = t.type .. "\0" .. wr_cint(#t.props)
  for _, pr in ipairs(t.props) do out[#out + 1] = pr[1] .. "\0" .. wr_cint(#pr[2]) .. pr[2] end
  out[#out + 1] = wr_cint(#t.children)
  for _, c in ipairs(t.children) do wr_tree(c, out) end
end

-- JUCE var bytes
local function v_str(s) return "\5" .. s .. "\0" end
local function v_int(i) return "\1" .. string.pack("<i4", i) end
local function v_int64(i) return "\6" .. string.pack("<i8", i) end
local function v_double(d) return "\4" .. string.pack("<d", d) end
local V_FALSE = "\3"

local function child(t, type)
  for _, c in ipairs(t.children) do if c.type == type then return c end end
end
local function prop(t, name)
  for _, pr in ipairs(t.props) do if pr[1] == name then return pr end end
end

-- Split a vst_chunk into { head, tree, rest_of_component, trailer }, or nil.
local function unpack_chunk(b64)
  local s = sonobus.b64decode(b64 or "")
  if #s < 16 then return nil end
  local len = string.unpack("<I4", s, 1)
  if 8 + len > #s then return nil end
  local ok, tree, p = pcall(rd_tree, s, 9)
  if not ok or tree.type ~= "SonoBusAoO" then return nil end
  return { head = s:sub(5, 8), tree = tree, rest = s:sub(p, 8 + len), trailer = s:sub(9 + len) }
end
local function pack_chunk(c)
  local out = {}
  wr_tree(c.tree, out)
  local comp = table.concat(out) .. c.rest
  return sonobus.b64encode(string.pack("<I4", #comp) .. c.head .. comp .. c.trailer)
end

-- Jitter buffer defaults for new peers. SonoBus's own default (Auto-Full from 1 ms) also shrinks the buffer, and
-- each change jumps the delay: on Wi-Fi that was 5-9 jumps of up to ~110 ms per 30 s (2026-10-28 test). Auto-
-- Increase from 40 ms only ever grows, so after the first seconds the delay holds still.
sonobus.BUFFER = { defnetauto = 1, defnetbuf = 0.04 } -- 1 = "Auto-Increase"; seconds

local function param_value(tree, id)
  for _, pc in ipairs(tree.children) do
    local pid = pc.type == "PARAM" and prop(pc, "id")
    if pid and pid[2] == v_str(id) then
      local v = prop(pc, "value")
      return v and v[2]:sub(1, 1) == "\4" and string.unpack("<d", v[2], 2), pc
    end
  end
end

-- Whether a SonoBus state is already in `group` (as `user`, when given) with BandSync's buffer defaults.
function sonobus.is_set_up(b64, group, user)
  local c = unpack_chunk(b64)
  if not c or sonobus.state_group(b64) ~= group then return false end
  if user and not sonobus.same_user(sonobus.state_user(b64), user) then return false end -- a renamed bandmate rejoins under the new name
  for id, want in pairs(sonobus.BUFFER) do
    if math.abs((param_value(c.tree, id) or -1) - want) > 1e-6 then return false end
  end
  return true
end

-- The group SonoBus would rejoin (its newest recent connection), or nil.
function sonobus.state_group(b64)
  local c = unpack_chunk(b64)
  local rec = c and child(c.tree, "RecentConnections")
  local info = rec and rec.children[1]
  local g = info and prop(info, "groupName")
  return g and g[2]:match("^\5(.*)%z$")
end

-- Whether SonoBus's name is this bandmate's: the group's server renames a second "Laptop" to "Laptop 5" (another
-- SonoBus of theirs still in the group), and SonoBus saves that. Rewriting it to "Laptop" only rejoined as "Laptop 6".
function sonobus.same_user(name, user)
  return name == user or (name ~= nil and name:sub(1, #user + 1) == user .. " " and name:sub(#user + 2):match("^%d+$") ~= nil)
end

-- The name SonoBus would rejoin under, or nil.
function sonobus.state_user(b64)
  local c = unpack_chunk(b64)
  local rec = c and child(c.tree, "RecentConnections")
  local info = rec and rec.children[1]
  local u = info and prop(info, "userName")
  return u and u[2]:match("^(.*)%z$")
end

-- The same state, set to join `info` ({ user, group, password, host?, port?, now? }) and to rejoin by itself.
-- Returns the new vst_chunk, or nil + why.
function sonobus.join_state(b64, info)
  local c = unpack_chunk(b64)
  if not c then return nil, "not a SonoBus state BandSync understands" end
  local rec = child(c.tree, "RecentConnections")
  if not rec then
    rec = { type = "RecentConnections", props = {}, children = {} }
    table.insert(c.tree.children, rec)
  end
  rec.children = { { type = "ServerConnectionInfo", children = {}, props = {
    { "userName", v_str(info.user) }, { "userPassword", v_str("") },
    { "groupName", v_str(info.group) }, { "groupPassword", v_str(info.password) },
    { "serverHost", v_str(info.host or "aoo.sonobus.net") }, { "serverPort", v_int(info.port or 10998) },
    { "timestamp", v_int64((info.now or os.time()) * 1000) }, { "groupIsPublic", V_FALSE },
  } } }
  local want = { reconnectlast = 1 } -- "Reconnect Last" on: SonoBus rejoins on every load
  for id, v in pairs(sonobus.BUFFER) do want[id] = v end
  for id, value in pairs(want) do
    local _, pc = param_value(c.tree, id)
    if pc then
      local v = prop(pc, "value")
      if v then v[2] = v_double(value) else pc.props[#pc.props + 1] = { "value", v_double(value) } end
    end
  end
  return pack_chunk(c)
end

-- Whether SonoBus has joined a group since `ms` (Unix ms): each join puts a new entry, with the join's time, at the
-- top of its recent connections (seen 2026-10-31: the laptop's state gained "Laptop 5" on top when it joined). A
-- written but unjoined state keeps BandSync's own entry and time.
function sonobus.joined_since(b64, ms)
  local c = unpack_chunk(b64)
  local rec = c and child(c.tree, "RecentConnections")
  local ts = rec and rec.children[1] and prop(rec.children[1], "timestamp")
  return ts ~= nil and ts[2]:sub(1, 1) == "\6" and string.unpack("<i8", ts[2], 2) > ms
end

-- Each bandmate's own output pair. SonoBus keeps what you set for each person by name (PeerStateCacheMap, saved
-- when they leave) and puts it back when someone of that name joins; a renamed "Laptop 5" takes "Laptop"'s. So
-- writing an entry per bandmate sends each one to their own pair, and BandSync's mix on the master (lib/hear.lua)
-- can turn each person up, down or off. `outs`: { [name] = first output channel (0-based) }. Layout from SonoBus
-- 1.7.2 (PeerStateCache::getValueTree), read from a real saved state.
local function channel_group(start)
  local d0, d1, dm1 = v_double(0), v_double(1), v_double(-1)
  return { type = "ChannelGroup", children = {}, props = {
    { "gain", d1 }, { "chanstart", v_int(0) }, { "numchan", v_int(2) }, { "muted", V_FALSE }, { "span1", dm1 }, { "span2", d1 },
    { "monreverbsend", d0 }, { "inreverbsend", d0 }, { "monitorlev", d1 }, { "mondeststart", v_int(0) }, { "mondestchans", v_int(2) },
    { "pandeststart", v_int(start) }, { "pandestchans", v_int(2) }, { "sendmainmix", "\2" }, { "invertpolarity", V_FALSE }, { "name", v_str("") },
  } }
end
function sonobus.set_outputs(b64, outs)
  local c = unpack_chunk(b64)
  if not c then return nil, "not a SonoBus state BandSync understands" end
  local map = child(c.tree, "PeerStateCacheMap")
  if not map then
    map = { type = "PeerStateCacheMap", props = {}, children = {} }
    table.insert(c.tree.children, map)
  end
  local function set_start(entry, start)
    local groups = child(entry, "ChannelGroups")
    if not groups then groups = { type = "ChannelGroups", props = {}, children = {} }; table.insert(entry.children, groups) end
    if #groups.children == 0 then groups.children[1] = channel_group(start) end
    for _, g in ipairs(groups.children) do -- (a stereo send is one group; a multi-group sender gets every group on the pair)
      local p = prop(g, "pandeststart")
      if p then p[2] = v_int(start) else g.props[#g.props + 1] = { "pandeststart", v_int(start) } end
    end
  end
  for name, start in pairs(outs) do
    local found = false
    for _, e in ipairs(map.children) do
      local n = prop(e, "name")
      local en = n and n[2]:match("^\5(.*)%z$")
      if en and sonobus.same_user(en, name) then set_start(e, start); found = found or en == name end -- (and its renamed copies)
    end
    if not found then
      local e = { type = "PeerStateCache", children = {}, props = {
        { "name", v_str(name) }, { "netbuf", v_double(sonobus.BUFFER.defnetbuf * 1000) }, { "netbufauto", v_int(sonobus.BUFFER.defnetauto) },
        { "sendformat", v_int(4) }, { "numChanGroups", v_int(1) }, { "level", v_double(1) }, { "orderpriority", v_int(-1) },
        { "numMultiChanGroups", v_int(0) }, { "modifiedChanGroups", V_FALSE },
      } }
      e.children = { { type = "ChannelGroups", props = {}, children = { channel_group(start) } }, { type = "MultiChannelGroups", props = {}, children = {} } }
      map.children[#map.children + 1] = e
    end
  end
  return pack_chunk(c)
end

-- Where SonoBus sends `name` (first output channel), or nil when it has no entry for them.
function sonobus.output_of(b64, name)
  local c = unpack_chunk(b64)
  local map = c and child(c.tree, "PeerStateCacheMap")
  for _, e in ipairs(map and map.children or {}) do
    local n = prop(e, "name")
    if n and n[2] == v_str(name) then
      local g = child(e, "ChannelGroups")
      local p = g and g.children[1] and prop(g.children[1], "pandeststart")
      return p and string.unpack("<i4", p[2], 2)
    end
  end
end

return sonobus
