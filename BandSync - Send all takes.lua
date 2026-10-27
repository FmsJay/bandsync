-- @description BandSync: send every unsent take (all recorded passes), so the host can comp from all of them
BAND_SEND_ALL = true
dofile(debug.getinfo(1, "S").source:match("^@?(.*)[/\\]") .. "/BandSync - Send takes.lua")
