-- nfsc_sectionStreamer, part "state": the variables every part reads and writes (queues, live objects, pools, timers), the frame budget, run stats, and the log / failure / notify helpers.
-- Loaded by sectionStreamer.lua into the shared streamer environment; every name here is shared with the other parts.

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
levelRoot = TUNING.levelRoot
initialized, suspended = false, false

sections, sectionOrder = {}, {}
sectionIndex, overrideIndex = {}, {}

currentSectionID, activeSet = nil, {}
sectionRead, sectionReading = {}, {}
sectionReadQueue, srHead, srTail = {}, 1, 0
loadQueue, lqHead, lqTail = {}, 1, 0
priQueue, pqHead, pqTail = {}, 1, 0      -- urgent: objects of the current / camera section, served before loadQueue
promotedTotal = 0                         -- queued objects moved ahead when a section changed
queuedKeys = {}
pending, pendingCount = {}, 0   -- id -> { terrain = tier, rest = tier }, tier = { list, at, n }
deferred = {}                   -- id -> items the create filter held back
createFilter = nil
staleDiscarded, queueHighWater, createdLastFrame, createdPeakFrame = 0, 0, 0, 0
live, liveBySection, liveCount = {}, {}, 0
pendingUnload, unloadQueue, uqHead, uqTail = {}, {}, 1, 0

totalTime, selectTimer = 0, 0
camPos, camVel = nil, { x = 0, y = 0 }   -- last camera position and smoothed velocity (m/s)
cameraSectionID, predictedSectionID = nil, nil
aheadCandidate, aheadTime = nil, 0
feedOrder, priorityTimer = {}, 0         -- sections in loading order: current first
timing = { creates = 0, createMs = 0, createMax = 0, firsts = 0, firstMs = 0, repeats = 0, repeatMs = 0,
                 reads = 0, readMs = 0, readMax = 0, frameLast = 0, framePeak = 0 }
seenShapes = {}
shapeLive = {}                 -- shape -> number of live instances (0/nil: the engine may have freed it)
recentFirstMs = nil            -- moving average of the latest first-use creates
function newChange()
  return { creates = 0, createMs = 0, firsts = 0, firstMs = 0, repeats = 0, repeatMs = 0, maxMs = 0,
           objectMs = 0, fieldsMs = 0, registerMs = 0, groupMs = 0, frames = 0, workMs = 0, dtSum = 0, dtMax = 0, workMax = 0,
           importN = 0, importMs = 0, hitN = 0, hitMs = 0, unkN = 0, unkMs = 0,   -- first use: no .cdae before / .cdae existed / unknown
           deleted = 0, deleteMs = 0, deferredFirst = 0, shellRecycles = 0, shellRecycleMs = 0, shellFresh = 0, shellParks = 0, shellParkMs = 0,
           residentRevives = 0, residentReviveMs = 0, residentShapeReuses = 0, residentShapeReuseMs = 0,
           residentDeacts = 0, residentEvicts = 0,
           reloads = 0, reloadMs = 0, warms = 0, warmMs = 0, shapes = {},
           dist = { { n = 0, ms = 0 }, { n = 0, ms = 0 }, { n = 0, ms = 0 } }, nameMs = 0, liveSum = 0, liveMin = nil, liveMax = 0, rn = 0, rx = 0, ry = 0, rxx = 0, rxy = 0 }   -- r*: regression sums of registerObject ms over live count   -- shapes: name -> { n, ms, max, first, reload }
end
change = newChange()                -- everything since the last section change
split = { objectMs = 0, fieldsMs = 0, registerMs = 0, groupMs = 0, nameMs = 0, live = 0, path = "new-object" }
idleFrameMs = nil              -- moving average of the frame time while nothing is loading   -- cost of the last create
frameDeleteMs = 0
-- One clock for the whole frame: every task is capped by what is left of frameBudgetMs at the moment it starts.
fb = {
  start = 0,                                                       -- os.clock() when this frame's streaming work began
  ms = { reads = 0, deletes = 0, creates = 0, shells = 0, warm = 0 },      -- ms each task used in the last frame
  avg = { reads = 0, deletes = 0, creates = 0, shells = 0, warm = 0 },     -- the same as a moving average (0.9 / 0.1)
}

function fb.remaining() return TUNING.frameBudgetMs - (os.clock() - fb.start) * 1000 end

-- min(share of the main budget, what the frame has left); 0 when the frame is already spent.
function fb.cap(share)
  local cap = TUNING.frameBudgetMs * share
  local left = fb.remaining()
  if left < cap then cap = left end
  return cap > 0 and cap or 0
end

function fb.record(name, ms)
  fb.ms[name] = ms
  fb.avg[name] = fb.avg[name] * 0.9 + ms * 0.1
end
-- Everything since the last statistics reset (a purge resets it too): which way objects came back, how busy the
-- streamer was and how long it slept. One table, so the big functions do not read more locals.
function newRun(stamp)
  local r = { stamp = stamp or 0, frames = 0, busy = 0, busyMs = 0, busyMax = 0, idle = 0, idleMs = 0, idleMax = 0,
              warmFrames = 0, warmMs = 0, coldFrames = 0, settles = 0, settleSum = 0, settleMax = 0, capHits = { cheap = 0, costly = 0 }, paths = {} }
  r.order = { "resident-revive", "resident-same-shape-reuse", "shell-refill", "pool-empty-fresh-object", "new-object" }
  for _, name in ipairs(r.order) do r.paths[name] = { n = 0, ms = 0, max = 0 } end
  return r
end
run = newRun(0)
-- Shape cache: state and lane functions in one table (the main chunk is close to Lua's 200 locals limit).
hold = { shape = {}, ids = {}, held = 0, cursor = 1, failed = 0, ms = 0, max = 0, maxShape = nil, group = nil,
               idle = 0, seconds = 0, complete = false, started = false, paused = false, ramPaused = false,
               runSeconds = 0, phase = "off", slow = {}, lane = "asleep", laneReason = nil, lastHoldMs = 0, lastShape = nil,
               gap = 0, still = 0, evicted = 0, evictKey = nil, absent = {}, absentN = 0, tries = {}, deferred = {}, deferredN = 0,
               rings = {}, ringPos = 1, pass = 1, secIdx = 1, shpIdx = 1, nearFor = nil, nearAt = 0, adj = nil,
               islandId = nil, islandSet = nil, islandN = 0, islandHeld = 0, islandSections = 0, ph = {}, phN = 0, phMs = 0,
               always = { set = {}, list = {}, dirty = true },       -- sections kept active everywhere (found from the data)
               cost = {}, costDirty = 0, visit = nil, visitTimer = 0, lastHitch = nil, lastPause = nil,
               mem = { time = -1e9, last = nil, provider = nil, luaPeakKB = 0, minFree = nil, minAvail = nil, peakProcess = nil } }
changeStamp, createdSinceChange, settled, settleSeconds, settlePeak = 0, 0, true, 0, 0
createdTotal, deletedTotal, failureCount, verified = 0, 0, 0, 0
failures = {}
listeners = {}
runtimeGroup = nil
shellFree, shellFreeN = {}, 0      -- object ids of parked shells, last in first out
shellFields = {}                   -- object id -> set of field names its current item applied
shellDefaults, shellScratch = {}, nil   -- field name -> engine default text (read once from an untouched object)
droppedSections, droppedObjects, droppedLast = 0, 0, nil   -- sections entered but left before their load settled
shellSerial, shellBuildFails, shellBuildOff = 0, 0, false
dormant, dormantOrder, doHead, doTail, dormantCount, dormantSerial = {}, {}, 1, 0, 0, 0   -- resident mode: key -> { id, shape, stamp }, oldest first
dormantByShape = {}                -- shape -> keys of deactivated residents that can be reused without changing shapeName
shellStats = { built = 0, buildMs = 0, recycled = 0, recycleMs = 0, fresh = 0, parked = 0, parkMs = 0, peakLive = 0,
                     revived = 0, reviveMs = 0, deactivated = 0, evicted = 0, residentShapeReuses = 0, residentShapeReuseMs = 0 }
scratch = { x = 0, y = 0 }
aheadPoint = { x = 0, y = 0 }

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
function logMsg(level, fmt, ...)
  if level == "D" then                                  -- routine information: only with Debug > Detailed logs
    if not TUNING.debugLog then return end
    level = "I"
  end
  local msg = select("#", ...) > 0 and string.format(fmt, ...) or fmt
  if log then log(level, "nfscSectionStreamer", msg) else print("[nfscSectionStreamer] " .. msg) end
end

function recordFailure(msg)
  failureCount = failureCount + 1
  failures[#failures + 1] = msg
  if #failures > 20 then table.remove(failures, 1) end
  logMsg("E", "%s", msg)
end

function notify(method, ...)
  for i = 1, #listeners do
    local l = listeners[i]
    local fn = l[method]
    if fn then
      local ok, err = pcall(fn, l, ...)
      if not ok then recordFailure(string.format("listener %s failed: %s", method, tostring(err))) end
    end
  end
end

function hook(name, ...)
  if extensions and extensions.hook then extensions.hook(name, ...) end
end

function safePath(rel)
  return type(rel) == "string" and rel ~= "" and rel:sub(1, 1) ~= "/" and not rel:find("%.%.")
end
