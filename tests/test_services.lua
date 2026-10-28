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
assert(not services.on_tailnet("[fd7a:115c:a1e1::1]:22000") and not services.on_tailnet(""), "other IPv6, nothing")
print("ok")
