-- Start and stop together. Someone clicks "Play together" (or "Record together"): a start event says WHEN (a wall-clock
-- moment a few seconds ahead) and WHERE (song position, with a count-in). Each machine's Live sync fires its transport
-- at that moment. The event travels through the shared folder, which can take seconds; a machine that gets it late
-- starts right away at the position the song has reached by now, so it still lines up instead of starting late.
-- In Play along (NINJAM synced) the listeners must run behind the one playing: they start `lag` seconds later.
-- Clocks: machines keep internet time (NTP), usually within tens of milliseconds of each other.
local together = {}

together.LEAD = 3 -- seconds between the click and the start, so the event reaches everyone in time on a LAN

-- When and from where this machine starts. Pure.
-- ev = { at = epoch seconds, pos = song position, countin = seconds, lag = seconds, lead = user }; me; now (epoch).
-- Returns fire (epoch) and from (position). Already past fire: fire now, from as far into the song as time has gone.
function together.plan(ev, me, now)
  local fire = ev.at + ((ev.lead and ev.lead ~= me) and (ev.lag or 0) or 0)
  local from = (ev.pos or 0) - (ev.countin or 0)
  if from < 0 then fire, from = fire - from, 0 end -- can't play before 0: start at 0, that much later
  if now and now > fire then return now, from + (now - fire) end
  return fire, from
end

-- Seconds of `bars` bars ending at pos (the count-in), by the project's own tempo map and time signature.
function together.bars_before(proj, pos, bars)
  if (bars or 0) <= 0 then return 0 end
  local num, den = reaper.TimeMap_GetTimeSigAtTime(proj, pos)
  local qn = reaper.TimeMap2_timeToQN(proj, pos)
  return pos - reaper.TimeMap2_QNToTime(proj, qn - bars * num * 4 / den)
end

-- Wall clock with sub-second precision: os.time() only counts whole seconds, so note where reaper.time_precise()
-- stands when the second ticks over (call tick() often; precise to about one defer cycle after the first tick).
local offset, last_sec
function together.tick()
  local s = os.time()
  if last_sec and s ~= last_sec then offset = s - reaper.time_precise() end
  last_sec = s
end
function together.now()
  return reaper.time_precise() + (offset or (os.time() - reaper.time_precise()))
end

return together
