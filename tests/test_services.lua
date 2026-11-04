-- services.is_device_id / on_tailnet are pure (lupa or any Lua 5.4, from the repo root)
reaper = reaper or { GetOS = function() return "Win64" end }
package.loaded.band = package.loaded.band or {}
package.path = "lib/?.lua;" .. package.path
local services = require("services")
assert(services.is_device_id("2MOGZMD-MVLUUSO-D6GXQIG-HMDVUBG-AOW6LHR-LMQQT6P-V4V5P73-6ZR5NQZ"), "a real device ID")
assert(not services.is_device_id("2MOGZMD-MVLUUSO-D6GXQIG-HMDVUBG-AOW6LHR-LMQQT6P-V4V5P73"), "too short")
assert(not services.is_device_id("2MOGZMD-MVLUUSO-D6GXQIG-HMDVUBG-AOW6LHR-LMQQT6P-V4V5P73-6ZR5NQ;"), "odd characters")
assert(not services.is_device_id("2MOGZMDMVLUUSO-D6GXQIG-HMDVUBG-AOW6LHR-LMQQT6P-V4V5P73-6ZR5NQZ-"), "dashes in the wrong places")
assert(services.on_tailnet("100.97.210.49:22000") and services.on_tailnet("100.64.0.1:22000") and services.on_tailnet("100.127.255.1:1"), "100.64.0.0/10")
assert(not services.on_tailnet("100.63.0.1:22000") and not services.on_tailnet("100.128.0.1:22000"), "just outside it")
assert(not services.on_tailnet("162.157.58.171:22000") and not services.on_tailnet("192.168.1.5:22000"), "internet and LAN")
assert(services.on_tailnet("[fd7a:115c:a1e0::7e48:8e48]:22000"), "Tailscale's IPv6 range")
local ts = '{"Self": {"ID": "1", "DNSName": "pc.tail1234.ts.net.", "OS": "windows"}, "CurrentTailnet": {"MagicDNSEnabled": %s}}'
assert(services.tailscale_name_in(ts:format("true")) == "pc.tail1234.ts.net", "its name, no last dot")
assert(services.tailscale_name_in(ts:format("false")) == nil, "names turned off: not a name that won't resolve")
assert(services.tailscale_name_in("") == nil, "not signed in")
assert(not services.on_tailnet("[fd7a:115c:a1e1::1]:22000") and not services.on_tailnet(""), "other IPv6, nothing")
-- the invitation: both lines carry the ID as the installers read it (BS_HOST_ID on a Mac, -HostId on Windows)
local inv_id = "2MOGZMD-MVLUUSO-D6GXQIG-HMDVUBG-AOW6LHR-LMQQT6P-V4V5P73-6ZR5NQZ"
local inv = services.invite_text(inv_id, { id = "bandsync", name = "Chilio" })
assert(inv:find('install_mac.sh?$(date +%s)" | BS_HOST_ID=' .. inv_id .. " BS_BAND_ID=bandsync BS_BAND_NAME='Chilio' bash", 1, true), "Mac line")
assert(inv:find("-File $f -HostId " .. inv_id .. " -BandId bandsync -BandName 'Chilio'", 1, true) and inv:find('"$env:TEMP\\studiosync_install.ps1"', 1, true), "Windows line")
assert(inv:find("^Join Chilio on StudioSync"), "it says which band")
-- the join code: on its own, in the whole message, from an old invitation's lines; nothing else reads as one
local code = services.parse_join(services.join_code(inv_id, { id = "bandsync-night-shift-1a2b", name = "Night Shift" }))
assert(code and code.id == inv_id and code.band == "bandsync-night-shift-1a2b" and code.name == "Night Shift", "the code")
code = services.parse_join(services.invite_text(inv_id, { id = "bandsync", name = "Chilio" }))
assert(code and code.id == inv_id and code.band == "bandsync" and code.name == "Chilio", "the whole message")
code = services.parse_join("powershell -File $f -HostId " .. inv_id .. " -BandId bandsync-x -BandName 'Old One'\n")
assert(code and code.band == "bandsync-x" and code.name == "Old One", "an old Windows line")
code = services.parse_join("curl x | BS_HOST_ID=" .. inv_id .. " BS_BAND_ID=bandsync-y BS_BAND_NAME='Old Two' bash")
assert(code and code.band == "bandsync-y" and code.name == "Old Two", "an old Mac line")
assert(services.parse_join("") == nil and services.parse_join("hello") == nil and services.parse_join("studiosync-join:ABC:x:y") == nil, "not a code")
code = services.parse_join("studiosync-join:" .. inv_id .. ":bandsync-z:Bad \"; rm -rf ~\n")
assert(code and code.name == "Bad  rm -rf", "a name can't carry anything into a command")
-- who's asking: only the studios you may let people into, and a new computer with no studio named
local bands_stub, groups_stub = { { id = "a", name = "Mine", root = "/a" }, { id = "b", name = "Theirs", root = "/b" }, { id = "c", name = "Closed", root = "/c" } }, nil
package.loaded.band.bands = function() return bands_stub end
groups_stub = { is_old = function(r) return r == "/c" end, may_manage = function(r, me) return me == "Owner" or (me == "Half" and r == "/a") end }
package.loaded.groups = groups_stub
services.pending_devices = function() return { { id = "NEW", name = "New", address = "x" } } end
services.pending_folders = function() return { { folder = "a", id = "K1" }, { folder = "b", id = "K2" }, { folder = "c", id = "K3" }, { folder = "stranger", id = "K4" } } end
services.device_name = function(id) return "name of " .. id end
local asks = services.join_asks("Half")
assert(#asks == 2 and asks[1].id == "NEW" and asks[1].folder == nil, "a new computer asks, with no studio named")
assert(asks[2].id == "K1" and asks[2].root == "/a" and asks[2].band == "Mine" and asks[2].name == "name of K1", "the one studio this person runs, not the others")
assert(#services.join_asks("Member") == 0, "someone who runs nothing is asked nothing")
asks = services.join_asks("Owner")
assert(#asks == 3 and asks[2].band == "Mine" and asks[3].band == "Theirs", "a closed studio and one that isn't here don't ask")
-- a band's Syncthing folder id from its name
assert(services.band_id("The Night Shift") == "studiosync-the-night-shift" and services.band_id("  Chilio ") == "studiosync-chilio", "ids")
assert(services.band_id("") == "studiosync-band" and services.band_id("Jazz--Trio") == "studiosync-jazz-trio", "empty, repeats")
print("ok")
