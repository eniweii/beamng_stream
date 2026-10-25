-- nfsc_sectionStreamer: Section Streamer (base scenery lifecycle).
--
-- Streaming determines which base objects EXIST. This extension:
--   * finds the camera's section from sections.json (drivable polygons only),
--   * keeps that section plus its related sections resident,
--   * creates their TSStatic objects from whole-section files and deletes them again
--     after a cooldown, spread across frames,
--   * reports what happened to other extensions. It never decides override visibility
--     (that is nfsc_sectionManager) and never looks at override or flag values.
--
-- Files (all under <levelRoot>/):
--   lua/sections.json                   {sections = {{id, points, boundsMin, boundsMax, related}}}
--   lua/carbon_stream/index.json        written by the builder (schemaVersion 2)
--   lua/carbon_stream/shapes.json       written by the builder (schemaVersion 1): unique shapes + per-section lists
--   lua/carbon_stream/sections/<id>.json  one whole file per section
--
-- Events (coarse, via extensions.hook):
--   onNfscStreamerInitialized()
--   onNfscSectionChanged(newSectionID, oldSectionID)   -- nil = camera outside every section
-- Events (fine, via M.addListener(table)); each is called as listener:method(...):
--   onObjectCreated(key, obj, item)   onObjectDeleted(key)   onStreamerReset()
--
-- Queue model: reading a section file fills a per-section PENDING list (terrain first, then the
-- rest, each grouped by shapeName). Pending records are fed into the load queue, which never
-- holds more than maxQueuedItems, current section first and then its related sections. A
-- section change drops queue entries and pending data that no active section needs any more.
--
-- Look-ahead and priority (as in the game's TrackStreamer): the camera velocity gives a point
-- min(1.5 s, 100 m) ahead. When that point lies in another section for a short, stable time, that
-- section becomes the current one before the camera crosses the border. Related sections are fed
-- in the game's three loading-priority bands (distance of the point one second ahead outside the
-- section, shrunk when heading towards it), the old static order breaks ties. Timing counters in
-- getStatus() and one log line per finished load show where the time goes.
--
-- Create filter (optional, set by the manager): M.setCreateFilter(fn). fn(item) == false means
-- "do not create this object now"; such items wait in a deferred list for as long as their
-- section is active, and M.refreshFilter() re-evaluates them. M.releaseObject(key, item) deletes
-- a live object and defers it again. The streamer never looks at what the filter decides on.
--
-- Exported transforms are applied exactly as exported: position, rotationEuler and scale
-- are written with setField as space-joined text, the same way every other field is.
--
-- Shape cache warm-up (idle lane): BeamNG builds <shape>.cdae from the .dae the first time a shape is
-- used ("Importing COLLADA..."), inside the registerObject call, which cannot be split across frames.
-- When both queues have been empty for cacheWarmIdleSeconds, the lane takes the shapes of the current and
-- related sections first, then the rest of shapes.json, skips shapes whose .cdae already exists
-- (FS:fileExists) and imports the others one at a time, cacheWarmGapSeconds apart: a hidden TSStatic
-- below the camera, created and deleted in the same call, so it is never drawn and keeps no memory. The
-- .cdae on disk is the progress record. Without FS:fileExists or shapes.json the lane stays off.
-- getCacheWarmStatus() feeds a progress display.
--
-- "Everything is warm" (TUNING.warmAll, a test mode): the streamer holds every shape of shapes.json with one hidden
-- TSStatic each (collision none, in its own group NFSC_WarmMeshes, outside the pool and the live counts), so no mesh
-- is ever loaded or built while streaming. Whatever the creation mode then costs is object work only:
-- registerObject, field writes, hide/unhide, shapeName retargets of shells. The lane runs while nothing is queued
-- (idle before it starts: Cache warm-up settings), a few shapes per frame within a share of the frame budget.
-- Switching it off releases the holders in batches. Purge, mode switches and "Reload streamed scenery" leave them alone.
-- getWarmAllStatus() feeds the panel; the run summary states whether the mode was on.
--
-- Creation methods (TUNING.creationMode, switch at runtime with M.setCreationMode):
--   "current": every streamed object is created with createObject/registerObject and deleted again.
--   "shells":  objects are never deleted. A released object is PARKED: it gets the tiny shellShape, is hidden and
--              goes to a free list (a TSStatic cannot be registered without a shape). A load takes a parked
--              shell and fills it in: shapeName, every item field, one postApply, unhide. Fields the previous
--              item set and the new one does not are put back to the engine default, so nothing leaks between
--              items. With no parked shell left the object is created the current way and joins the pool when
--              it is released. TUNING.shellTarget > 0 builds parked shells ahead, in the background, while the
--              urgent queue is empty. Objects are named nfsc_shell_<n>; everything is keyed by section ID.
--   "resident": shells, plus a resting state like the game's LOADED section. An object nobody wants any more is
--              DEACTIVATED at once (residentCooldown, default 0): hidden, still bound to its key with its shape and
--              fields, no field writes. Wanting it again REVIVES it: unhide, nothing else. Only when a load needs a
--              shell and the pool is at TUNING.residentMax the oldest deactivated object is EVICTED and its shell
--              reused (the way the game frees the oldest LOADED section). residentReserve keeps that many shells
--              free ahead of time, evicting in idle frames. The cap bounds RAM; nothing else grows with the level.
--
-- Tuning: M.getTuning / setTuning / resetTuning change the values live; savePreset / loadPreset / listPresets /
-- deletePreset keep named sets in lua/carbon_stream/tuning_presets.json (a preset called "startup" is applied
-- at initialize). The manager panel has sliders for the common ones.

local M = {}

-- Bounded, opt-in stall diagnostics. Detailed work is only sampled while Testing Mode is enabled.
-- os.clockhp is preferred when this GE-Lua runtime exposes it; every timing site below uses the
-- same seconds-based source. Backwards jumps are counted and clamped in the diagnostic accumulator.
local STALL = {
  enabled = false,
  slowMs = 2.0,
  spikeMs = 25.0,
  topLimit = 12,
  recentLimit = 64,
  clockSource = type(os.clockhp) == "function" and "os.clockhp" or "os.clock (fallback)",
}
M.stallDiagnostics = STALL

function STALL:now()
  local fn = type(os.clockhp) == "function" and os.clockhp or os.clock
  local value = fn()
  if type(value) ~= "number" then value = os.clock() end
  if self.lastClock and value < self.lastClock then
    self.clockRegressions = (self.clockRegressions or 0) + 1
    return self.lastClock
  end
  self.lastClock = value
  return value
end

function STALL:newStats()
  return {
    frames = 0, totalMs = 0, maxFrameMs = 0, worstFrame = nil,
    spikes = 0, overruns = 0, totalOverrunMs = 0, unattributedMs = 0,
    backlogGrowthFrames = 0, poolMismatchFrames = 0,
    stageStats = {}, operations = {}, topOps = {},
    poolActivity = { built = 0, recycled = 0, fresh = 0, evicted = 0, revived = 0, deactivated = 0, parked = 0 },
  }
end

function STALL:reset()
  self.global = self:newStats()
  self.sections = {}
  self.current = nil
  self.lastFrame = nil
  self.spikes = {}
  self.frameId = 0
  self.clockRegressions = 0
  self.lastClock = nil
  self.stageBookkeepingUs = nil
end

function STALL:sectionStats(section)
  local key = tostring(section == nil and "none" or section)
  local stats = self.sections[key]
  if not stats then
    stats = self:newStats()
    self.sections[key] = stats
  end
  return stats, key
end

function STALL:pushTop(list, entry, limit)
  local at = #list + 1
  for i = 1, #list do
    if entry.ms > list[i].ms then at = i; break end
  end
  if at > limit then return end
  table.insert(list, at, entry)
  if #list > limit then table.remove(list) end
end

function STALL:recordOperationStats(stats, kind, ms)
  local item = stats.operations[kind]
  if not item then item = { count = 0, totalMs = 0, maxMs = 0, slowCount = 0 }; stats.operations[kind] = item end
  item.count = item.count + 1
  item.totalMs = item.totalMs + ms
  if ms > item.maxMs then item.maxMs = ms end
  if ms >= self.slowMs then item.slowCount = item.slowCount + 1 end
end

function STALL:recordOperation(kind, ms, section, object, shape, path, apiMs, scope)
  if not self.enabled or type(ms) ~= "number" then return end
  self:recordOperationStats(self.global, kind, ms)
  local sectionStats = self:sectionStats(section)
  self:recordOperationStats(sectionStats, kind, ms)
  if ms < self.slowMs then return end

  local pct = apiMs and ms > 0 and math.max(0, math.min(100, apiMs / ms * 100)) or nil
  local entry = {
    kind = kind, ms = ms, section = tostring(section == nil and "none" or section),
    object = tostring(object or "?"), shape = tostring(shape or "?"), path = tostring(path or "n/a"),
    apiMs = apiMs, outsideApiMs = apiMs and math.max(0, ms - apiMs) or nil,
    apiPercent = pct, scope = scope or "elapsed operation time",
    dominant = pct and pct >= 70 and "engine/API-call elapsed dominant"
      or (pct and "mixed elapsed time" or (scope or "streamer-side or mixed elapsed time")),
  }
  self:pushTop(self.global.topOps, entry, self.topLimit)
  self:pushTop(sectionStats.topOps, entry, math.min(self.topLimit, 8))
  if self.current then
    self.current.slowCount = self.current.slowCount + 1
    self:pushTop(self.current.slowOps, entry, 5)
  end
end

function STALL:beginFrame(context)
  if not self.enabled then return nil end
  context = context or {}
  self.frameId = self.frameId + 1
  self.current = {
    id = self.frameId, started = context.started or self:now(), sectionStart = context.section,
    budgetMs = context.budgetMs or 0, queueStart = context.queue, poolStart = context.pool,
    stages = {}, stageCounts = {}, slowOps = {}, slowCount = 0,
  }
  return self.current
end

function STALL:beginStage(name)
  if not self.enabled or not self.current then return nil end
  return self:now()
end

function STALL:endStage(name, started, itemCount)
  if not self.enabled or not self.current or not started then return 0 end
  local ms = math.max(0, (self:now() - started) * 1000)
  self.current.stages[name] = ms
  self.current.stageCounts[name] = itemCount or 0
  return ms
end

function STALL:addFrameStats(stats, frame)
  stats.frames = stats.frames + 1
  stats.totalMs = stats.totalMs + frame.totalMs
  stats.unattributedMs = stats.unattributedMs + frame.unattributedMs
  if frame.totalMs > stats.maxFrameMs then
    stats.maxFrameMs, stats.worstFrame = frame.totalMs, frame
  end
  if frame.isSpike then stats.spikes = stats.spikes + 1 end
  if frame.overrunMs > 0 then
    stats.overruns = stats.overruns + 1
    stats.totalOverrunMs = stats.totalOverrunMs + frame.overrunMs
  end
  if frame.backlogGrowth then stats.backlogGrowthFrames = stats.backlogGrowthFrames + 1 end
  if frame.poolMismatch then stats.poolMismatchFrames = stats.poolMismatchFrames + 1 end
  for name, ms in pairs(frame.stages) do
    local stage = stats.stageStats[name]
    if not stage then stage = { count = 0, totalMs = 0, maxMs = 0, items = 0 }; stats.stageStats[name] = stage end
    stage.count = stage.count + 1
    stage.totalMs = stage.totalMs + ms
    stage.items = stage.items + (frame.stageCounts[name] or 0)
    if ms > stage.maxMs then stage.maxMs = ms end
  end
  for name, count in pairs(frame.poolActivity) do stats.poolActivity[name] = (stats.poolActivity[name] or 0) + count end
end

function STALL:endFrame(context)
  if not self.enabled or not self.current then return nil end
  context = context or {}
  local frame = self.current
  frame.totalMs = math.max(0, (self:now() - frame.started) * 1000)
  frame.sectionEnd = context.section
  frame.queueEnd = context.queue
  frame.poolEnd = context.pool
  frame.work = context.work or {}
  frame.remainingMs = context.remainingMs
  frame.consumedMs = frame.budgetMs - (frame.remainingMs or (frame.budgetMs - frame.totalMs))
  frame.overrunMs = math.max(0, frame.consumedMs - frame.budgetMs)
  frame.isSpike = frame.totalMs >= self.spikeMs
  local stageSum = 0
  for _, ms in pairs(frame.stages) do stageSum = stageSum + ms end
  frame.unattributedMs = math.max(0, frame.totalMs - stageSum)
  frame.backlogGrowth = frame.queueStart and frame.queueEnd
    and (frame.queueEnd.backlog or 0) > (frame.queueStart.backlog or 0) or false
  frame.poolMismatch = false
  if frame.poolStart and frame.poolEnd then
    local startSum = (frame.poolStart.live or 0) + (frame.poolStart.dormant or 0) + (frame.poolStart.free or 0)
    local endSum = (frame.poolEnd.live or 0) + (frame.poolEnd.dormant or 0) + (frame.poolEnd.free or 0)
    frame.poolMismatch = startSum ~= (frame.poolStart.total or startSum) or endSum ~= (frame.poolEnd.total or endSum)
    frame.poolActivity = {}
    for _, name in ipairs({ "built", "recycled", "fresh", "evicted", "revived", "deactivated", "parked" }) do
      frame.poolActivity[name] = (frame.poolEnd[name] or 0) - (frame.poolStart[name] or 0)
    end
  else
    frame.poolActivity = {}
  end

  local sectionStats = self:sectionStats(frame.sectionEnd ~= nil and frame.sectionEnd or frame.sectionStart)
  self:addFrameStats(self.global, frame)
  self:addFrameStats(sectionStats, frame)
  self.lastFrame = frame
  if frame.isSpike then
    self.spikes[#self.spikes + 1] = frame
    if #self.spikes > self.recentLimit then table.remove(self.spikes, 1) end
  end
  self.current = nil
  return frame
end

function STALL:calibrate()
  -- This only estimates the cost of recording a stage pair; it is not a full profiler-overhead benchmark.
  local previous = self.current
  self.current = { stages = {}, stageCounts = {}, slowOps = {}, slowCount = 0 }
  local n, start = 100, self:now()
  for _ = 1, n do
    local mark = self:beginStage("__calibration")
    self:endStage("__calibration", mark, 0)
  end
  local elapsed = math.max(0, self:now() - start)
  self.current = previous
  self.stageBookkeepingUs = elapsed * 1000000 / n
end

function STALL:setEnabled(flag)
  flag = flag and true or false
  if flag == self.enabled then return end
  self.enabled = flag
  if flag then
    self:reset()
    self:calibrate()
  end
end

function STALL:summary(section)
  local stats = section ~= nil and self.sections[tostring(section)] or self.global
  if not stats then stats = self:newStats() end
  local stages = {}
  for name, item in pairs(stats.stageStats) do
    stages[name] = {
      count = item.count, avgMs = item.count > 0 and item.totalMs / item.count or 0,
      maxMs = item.maxMs, items = item.items,
    }
  end
  local operations = {}
  for name, item in pairs(stats.operations) do
    operations[name] = {
      count = item.count, totalMs = item.totalMs,
      avgMs = item.count > 0 and item.totalMs / item.count or 0,
      maxMs = item.maxMs, slowCount = item.slowCount,
    }
  end
  local last = self.lastFrame
  return {
    enabled = self.enabled, scope = section ~= nil and ("section " .. tostring(section)) or "run",
    clockSource = self.clockSource, clockRegressions = self.clockRegressions or 0,
    stageBookkeepingEstimateUs = self.stageBookkeepingUs,
    frames = stats.frames, avgFrameMs = stats.frames > 0 and stats.totalMs / stats.frames or 0,
    worstFrameMs = stats.maxFrameMs, worstFrame = stats.worstFrame,
    spikeCount = stats.spikes, overrunFrames = stats.overruns,
    totalOverrunMs = stats.totalOverrunMs, avgUnattributedMs = stats.frames > 0 and stats.unattributedMs / stats.frames or 0,
    backlogGrowthFrames = stats.backlogGrowthFrames, poolMismatchFrames = stats.poolMismatchFrames,
    stageStats = stages, operations = operations, topOps = stats.topOps,
    poolActivity = stats.poolActivity, lastFrame = last, recentSpikes = self.spikes,
  }
end

function STALL:logFrame(frame, logger)
  local q0, q1 = frame.queueStart or {}, frame.queueEnd or {}
  local p0, p1 = frame.poolStart or {}, frame.poolEnd or {}
  local stages = frame.stages or {}
  local kind = frame.isSpike and "SPIKE" or "BUDGET OVERRUN"
  logger("W", "TEST frame #%d %s: %.2f ms; budget %.2f, consumed %.2f, remaining %.2f, overrun %.2f ms; section %s -> %s",
    frame.id, kind, frame.totalMs, frame.budgetMs, frame.consumedMs, frame.remainingMs or 0, frame.overrunMs,
    tostring(frame.sectionStart or "none"), tostring(frame.sectionEnd or "none"))
  logger("W", "  stages ms: selection %.2f, section-read %.2f, queue-feed %.2f, unload %.2f, load %.2f, shell-build %.2f, resident-trim %.2f, cache-warm %.2f, settle/probe %.2f, unattributed %.2f",
    stages.selection or 0, stages.section_reads or 0, stages.queue_feed or 0, stages.unloads or 0,
    stages.loads or 0, stages.shell_build or 0, stages.resident_trim or 0, stages.cache_warm or 0,
    stages.settle_report or 0, frame.unattributedMs or 0)
  local activity = frame.poolActivity or {}
  logger("W", "  queue backlog %d -> %d (queued %d -> %d, pending records %d -> %d, reads %d -> %d, deferred %d -> %d); work reads %d, queued %+d, unload %d, create %d, skipped %d, shells %d, evicted %d, warmed %d, stale-drop %+d",
    q0.backlog or 0, q1.backlog or 0, q0.queued or 0, q1.queued or 0, q0.pending or 0, q1.pending or 0,
    q0.reads or 0, q1.reads or 0, q0.deferred or 0, q1.deferred or 0,
    frame.work.reads or 0, frame.work.queued or 0, frame.work.deletes or 0, frame.work.creates or 0,
    frame.work.skipped or 0, frame.work.shells or 0, frame.work.evicted or 0, frame.work.warmed or 0,
    (q1.staleDiscarded or 0) - (q0.staleDiscarded or 0))
  logger("W", "  pool live %d -> %d, deactivated %d -> %d, free %d -> %d, total %d -> %d, cap %s; deltas recycled %+d, fresh %+d, built %+d, revived %+d, evicted %+d; category sum %s",
    p0.live or 0, p1.live or 0, p0.dormant or 0, p1.dormant or 0, p0.free or 0, p1.free or 0,
    p0.total or 0, p1.total or 0, tostring(p1.cap or "n/a"), activity.recycled or 0, activity.fresh or 0,
    activity.built or 0, activity.revived or 0, activity.evicted or 0, frame.poolMismatch and "MISMATCH" or "matches tracked total")
  for i = 1, math.min(3, #(frame.slowOps or {})) do
    local op = frame.slowOps[i]
    logger("W", "  slow op %d: %s %.2f ms; section %s; object %s; shape %s; path %s; API %.2f ms, outside-API %.2f ms; %s",
      i, op.kind, op.ms, op.section, op.object, op.shape, op.path,
      op.apiMs or 0, op.outsideApiMs or op.ms, op.dominant or op.scope)
  end
end

STALL:reset()


-- ---------------------------------------------------------------------------
-- Tuning (override at runtime with M.setTuning{...})
-- ---------------------------------------------------------------------------
local TUNING = {
  levelRoot = "levels/nfsc",
  maxCreatesPerFrame = 16,
  maxRefillsPerFrame = 128,       -- resident mode: creates that must change a shell's shape (the expensive path) per frame
  maxCheapPerFrame = 1024,        -- resident mode: revives and same-shape reuses (nearly free) per frame
  maxDeletesPerFrame = 256,
  frameBudgetMs = 16.0,           -- one budget for the whole frame: deletes first, creates get what is left
  deleteBudgetShare = 0.25,       -- deletes may use at most this share of frameBudgetMs (and never more than the frame has left)
  maxFirstUsePerFrame = 3,        -- new shapes (4-20 ms each) per frame; a later new shape waits for the next frame
  firstUseGuessMs = 6.0,          -- expected first-use cost until a real average exists
  currentSectionFirst = true,     -- objects of the section the camera is in (and the one streamed for) load before everything else
  probeOnSettle = true,           -- after a section settled with new objects, time a few test registerObject calls and log them
  probeCount = 20,                -- test objects per probe pass when it runs by itself
  skipNameLookup = false,         -- true: name every object "nfsc_<key>" without the scenetree.findObject duplicate check
  stallLogMs = 100,               -- a single create or cache import slower than this is logged at once (shape, kind)
  testingMode = false,            -- detailed bounded frame/stall diagnostics; off by default
  logEmptySettles = false,        -- true: also print the settled line of a change that created nothing
  cacheWarm = true,               -- idle-time warm-up of the .cdae shape cache (see header)
  cacheWarmPerFrame = 1,          -- shapes imported per frame; each one is a stall of its own import time
  cacheWarmGapSeconds = 0.25,     -- pause after every import (0 = back to back, for a loading screen)
  cacheWarmIdleSeconds = 1.0,     -- both load queues must have been empty this long before the lane starts
  cacheWarmCheckShare = 0.0625,   -- share of frameBudgetMs per frame for skipping shapes that already have a .cdae (1 ms at 16)
  cacheWarmLogEvery = 100,        -- progress line after this many imports (0 = none)
  warmAll = false,                -- "Everything is warm" test mode: hold every mesh with one hidden object each (see header)
  warmAllPerFrame = 8,            -- meshes held per frame while the lane runs
  warmAllBudgetShare = 0.5,       -- share of frameBudgetMs per frame for holding (a first import can still run longer)
  warmAllLogEvery = 2000,         -- progress line after this many meshes (0 = none)
  warmGroupName = "NFSC_WarmMeshes",
  maxSectionReadsPerFrame = 1,
  maxQueuedItems = 512,           -- hard cap of the load queue; the rest waits in pending lists
  maxPendingRecords = 8192,       -- do not read another section file while this many records wait
  unloadCooldown = 2.0,           -- seconds a no-longer-wanted object survives
  containmentTolerance = 0.1,     -- GetDistanceOutside fallback, same as the game
  noSectionLookupInterval = 0.1,  -- seconds between lookups while outside every section
  forceCollisionNone = true,      -- collision policy for the first in-game test (see docs)
  verifyFirstN = 3,               -- log readbacks of the first N created objects
  runtimeGroupName = "NFSC_StreamedScenery",
  predictionEnabled = true,       -- switch to the section ahead before the camera crosses the border
  predictionSeconds = 1.5,        -- look-ahead time, same as the game
  predictionMaxDistance = 100.0,  -- look-ahead cap in metres, same as the game
  predictionMinSpeed = 1.0,       -- m/s; slower than this there is no prediction
  predictionMaxSpeed = 178.81,    -- m/s (400 mph); faster is treated as a jump and not predicted
  predictionStableTime = 0.25,    -- seconds the section ahead must stay the same before switching
  selectionInterval = 0.05,       -- seconds between section lookups
  priorityRefreshInterval = 0.5,  -- seconds between load-order refreshes
  logSettle = true,               -- one log line when the load of a section change has finished
  creationMode = "current",       -- "current", "shells" or "resident" (see header); M.setCreationMode(mode) switches it
  residentMax = 6000,             -- resident mode: pool size (live + deactivated + free) before the oldest deactivated one is evicted
  residentReserve = 0,            -- resident mode: free shells kept ready by evicting in idle frames (0 = evict only when a load needs one)
  residentCooldown = 0.0,         -- resident mode: seconds before an unwanted object is deactivated (it is cheap, so 0)
  shellShape = "/levels/nfsc/Assets/Meshes/NFSC_DOT.dae",  -- shape of a parked shell (tiny, never drawn: parked shells are hidden)
  shellTarget = 0,                -- keep at least this many shells (free + in use); built ahead in the background. 0 = off
  shellBuildPerFrame = 8,         -- shells built ahead per frame ...
  shellBuildBudgetShare = 0.125,  -- ... and at most this share of frameBudgetMs of it (2 ms at 16), and never more than the frame has left
}

local TUNING_DEFAULTS = {}
for k, v in pairs(TUNING) do TUNING_DEFAULTS[k] = v end
local readPresets                      -- defined with the tuning API further down

-- Tuning schema: one row per setting the panel can show (the panel builds itself from it).
--   kind     "float", "int", "bool" or "share" (a part 0..1 of frameBudgetMs; the panel shows the ms it is worth)
--   min/max  slider range;  lo/hi  hard limits setTuning enforces (numbers: lo defaults to 0, shares: 0..1)
--   modes    creation modes the setting does something in (nil = all);  requires  a bool setting that must be on
--   desc     the tooltip text: what it does and what raising or lowering it changes
local tun = {}                          -- tuning schema, presets, change tracking and helpers: one local
do
local SHELL_MODES = { shells = true, resident = true }
tun.schema = {
  { key = "frameBudgetMs", group = "Frame budget", label = "Frame budget (ms)", kind = "float", min = 1, max = 50,
    desc = "Time one frame may spend on streaming: section reads, deletes, creates and shell building together. Every task below is capped by what is left of it. Higher: sections settle sooner but frames run longer. Lower: smoother frames, slower loading." },
  { key = "deleteBudgetShare", group = "Frame budget", label = "Delete / park share", kind = "share", min = 0.05, max = 1,
    desc = "Largest part of the frame budget that deleting (or parking / deactivating) objects may use. Deletes run first, creates get the rest. Lower: more time for creates, but objects wait longer to be removed. Higher: the unload backlog clears faster and loading slows." },
  { key = "shellBuildBudgetShare", group = "Frame budget", label = "Shell build share", kind = "share", min = 0.01, max = 1, modes = SHELL_MODES,
    desc = "Largest part of the frame budget for building parked shells ahead (see Shells built ahead). It runs after the loads and only takes what they left, so a busy frame builds none. Higher: the pool fills sooner but idle frames get longer." },
  { key = "maxCreatesPerFrame", group = "Section loading", label = "Max creates per frame", kind = "int", min = 1, max = 256, lo = 1, modes = { current = true, shells = true },
    desc = "Hard cap on objects created per frame, on top of the time budget. Higher: faster loading when objects are cheap, bigger frame spikes when they are not. Lower: steadier frames, slower loading." },
  { key = "maxRefillsPerFrame", group = "Section loading", label = "Max refills per frame", kind = "int", min = 1, max = 1024, lo = 1, modes = { resident = true },
    desc = "Hard cap per frame on objects that need a shell with a different shape (no deactivated object of the same shape was left). This is the expensive path: a shape change costs about 1 ms or more. Higher: faster loading, bigger spikes. Lower: steadier frames, slower loading. Revives and same-shape reuses are not counted here." },
  { key = "maxCheapPerFrame", group = "Section loading", label = "Max cheap reuses per frame", kind = "int", min = 1, max = 4096, lo = 1, modes = { resident = true },
    desc = "Hard cap per frame on objects brought back by a revive or a same-shape reuse (about 0.01 ms each, no shape change, no registerObject). They are still limited by the frame budget. Higher: a returning section is back in very few frames, then the streamer sleeps. Lower: gentler." },
  { key = "maxDeletesPerFrame", group = "Section loading", label = "Max deletes per frame", kind = "int", min = 1, max = 2048, lo = 1,
    desc = "Hard cap on objects deleted (or parked) per frame, on top of the delete share. Lower: a long unload trails over more frames; higher: it finishes sooner, in a bigger spike." },
  { key = "maxFirstUsePerFrame", group = "Section loading", label = "Max first uses per frame", kind = "int", min = 1, max = 16, lo = 1,
    desc = "How many never-used shapes may be created per frame. A first use loads the mesh and can cost 4-100 ms (a COLLADA import when there is no .cdae yet). Lower: fewer big stalls in one frame, new shapes appear later." },
  { key = "firstUseGuessMs", group = "Section loading", label = "First use guess (ms)", kind = "float", min = 1, max = 40,
    desc = "Expected cost of a first use until a real average exists. A new shape is only started when this much budget is left. Higher: more cautious, shapes wait for a quieter frame. Lower: shapes start earlier and may overrun the budget." },
  { key = "maxSectionReadsPerFrame", group = "Section loading", label = "Section reads per frame", kind = "int", min = 1, max = 8, lo = 1,
    desc = "Section files read per frame. A read is a JSON parse and cannot be split. Higher: sections get their data sooner, with a heavier frame. A second read only starts while the frame budget has time left." },
  { key = "maxQueuedItems", group = "Section loading", label = "Load queue cap", kind = "int", min = 64, max = 4096, lo = 1,
    desc = "Most objects held in the load queue; the rest wait in per-section lists. Higher: the queue holds more at once and reorders less often. Lower: the order follows the camera more closely." },

  { key = "unloadCooldown", group = "Unloading", label = "Unload cooldown (s)", kind = "float", min = 0, max = 10, modes = { current = true, shells = true },
    desc = "Seconds an object that no active section wants survives before it is deleted or parked. Higher: going back to a section you just left is instant, more objects stay in memory. Lower: memory is freed sooner." },
  { key = "residentCooldown", group = "Unloading", label = "Deactivate delay (s)", kind = "float", min = 0, max = 10, modes = { resident = true },
    desc = "Seconds before an unwanted object is deactivated (hidden, kept bound to its shape and fields). Deactivating is cheap, so 0 is normal. Higher: the object stays drawn a little longer after the camera leaves." },

  { key = "shellTarget", group = "Shell pool", label = "Shells built ahead", kind = "int", min = 0, max = 30000, modes = SHELL_MODES,
    desc = "Keep at least this many shells (free + in use), built in the background while nothing urgent is queued. 0 = build on demand. Near the peak live count (about 3200 seen) avoids creating during loads; each hidden shell costs a little every frame." },
  { key = "shellBuildPerFrame", group = "Shell pool", label = "Shells per frame", kind = "int", min = 1, max = 64, lo = 1, modes = SHELL_MODES,
    desc = "Most shells built ahead per frame, within the shell build share. Higher: the pool fills in fewer frames. Lower: gentler on frame time." },

  { key = "residentMax", group = "Resident pool", label = "Pool size", kind = "int", min = 500, max = 30000, lo = 1, modes = { resident = true },
    desc = "Most objects held at once (live + deactivated + free). Beyond it the oldest deactivated object is evicted and its shell reused. Higher: more sections stay instantly revivable, more RAM. Lower: more evictions and re-fills. Near 1.2 x the peak live count is a start." },
  { key = "residentReserve", group = "Resident pool", label = "Free reserve", kind = "int", min = 0, max = 2000, modes = { resident = true },
    desc = "Free shells kept ready by evicting in idle frames. 0 = evict only when a load needs a shell. Higher: loads rarely have to evict mid-frame, but fewer objects stay resident." },

  { key = "currentSectionFirst", group = "Look-ahead and order", label = "Current section first", kind = "bool",
    desc = "Objects of the camera's section (and the one being streamed for) load before everything else. Off: strict distance bands only." },
  { key = "predictionEnabled", group = "Look-ahead and order", label = "Look-ahead", kind = "bool",
    desc = "Switch to the section ahead before the camera crosses the border, from the camera velocity. On: the next section starts loading earlier. Off: loading starts at the border." },
  { key = "predictionSeconds", group = "Look-ahead and order", label = "Look-ahead time (s)", kind = "float", min = 0, max = 5, requires = "predictionEnabled",
    desc = "How far ahead (in seconds of travel, capped at 100 m) the look-ahead point lies. Higher: earlier loading, more wrong guesses on turns. Lower: later switches." },

  { key = "cacheWarm", group = "Cache warm-up", label = "Cache warm-up lane", kind = "bool",
    desc = "While nothing is queued, import shapes that have no .cdae yet, one at a time, so later first uses are cache reads. Each import is a stall of its own length." },
  { key = "cacheWarmPerFrame", group = "Cache warm-up", label = "Imports per frame", kind = "int", min = 1, max = 4, lo = 1, requires = "cacheWarm",
    desc = "Shapes imported per frame. Each one stalls the frame for its import time. Higher: the cache fills sooner with longer stalls. A second import is skipped once the frame budget is spent." },
  { key = "cacheWarmGapSeconds", group = "Cache warm-up", label = "Gap after an import (s)", kind = "float", min = 0, max = 2, requires = "cacheWarm",
    desc = "Pause after every import. Higher: stalls are spread out. 0 = back to back, for a loading screen." },
  { key = "cacheWarmIdleSeconds", group = "Cache warm-up", label = "Idle before it starts (s)", kind = "float", min = 0, max = 5, requires = "cacheWarm",
    desc = "Both load queues must have been empty this long before the lane starts. Higher: it stays out of the way after every section change." },
  { key = "cacheWarmCheckShare", group = "Cache warm-up", label = "Skip-check share", kind = "share", min = 0.01, max = 1, requires = "cacheWarm",
    desc = "Part of the frame budget the lane may spend looking for shapes that already have a .cdae (skipping is cheap but there are about 30k shapes). Higher: the scan finishes sooner, with a heavier idle frame." },

  { key = "warmAll", group = "Everything is warm", label = "Everything is warm", kind = "bool",
    desc = "Test mode: keep every mesh of shapes.json loaded by holding it with one hidden object each (about 30k, RAM only, nothing drawn). Then no mesh is ever loaded while streaming, so a run measures object work only: registerObject, field writes, hide/unhide, shell retargets. Starts while nothing is queued; Off releases the meshes. Purge and mode switches leave them alone. The hidden objects cost the engine a little every frame, the same in every mode." },
  { key = "warmAllPerFrame", group = "Everything is warm", label = "Meshes held per frame", kind = "int", min = 1, max = 64, lo = 1, requires = "warmAll",
    desc = "Most shapes held in one frame. Each one is a mesh load (about 1 to 2 ms from the .cdae cache, 5 ms or more when it must be imported first). Higher: warm sooner, longer frames while it runs. Lower: gentler." },
  { key = "warmAllBudgetShare", group = "Everything is warm", label = "Frame share for holding", kind = "share", min = 0.05, max = 4, requires = "warmAll",
    desc = "Part of the frame budget the holding may use per frame (a single first import can still run longer). Higher: warm sooner. Use 1 or more with a high per-frame count for a loading-screen style warm-up, standing still." },

  { key = "forceCollisionNone", group = "Other", label = "Collision off", kind = "bool",
    desc = "Created objects get no collision. On is the current test policy: collision is its own system, deferred." },
  { key = "logSettle", group = "Other", label = "Log settled sections", kind = "bool",
    desc = "Write a timing block to the log when the load of a section change has finished." },
  { key = "testingMode", group = "Other", label = "Testing Mode", kind = "bool",
    desc = "Enable bounded per-frame stage timings, slow-operation traces, pool/queue deltas and spike summaries. Adds a small amount of timing/bookkeeping work; turn off for normal play." },
  { key = "probeOnSettle", group = "Other", label = "Probe after settle", kind = "bool", requires = "logSettle",
    desc = "After a settle, time a few test creates and log them next to the real averages. Diagnostic only; it adds a little work to that frame." },
}
tun.byKey = {}
for _, row in ipairs(tun.schema) do tun.byKey[row.key] = row end

-- Three presets per creation mode. Until the user saves a slot, it holds these values (only budget and pool
-- settings; everything else keeps its current value). Starting points, not measured results.
tun.slots = { "A", "B", "C" }
tun.factory = {
  current = {
    A = { label = "Gentle", values = { frameBudgetMs = 8, deleteBudgetShare = 0.25, maxCreatesPerFrame = 4, maxFirstUsePerFrame = 1, unloadCooldown = 2 } },
    B = { label = "Balanced", values = { frameBudgetMs = 16, deleteBudgetShare = 0.25, maxCreatesPerFrame = 16, maxFirstUsePerFrame = 3, unloadCooldown = 2 } },
    C = { label = "Fast", values = { frameBudgetMs = 24, deleteBudgetShare = 0.5, maxCreatesPerFrame = 64, maxFirstUsePerFrame = 8, unloadCooldown = 1 } },
  },
  shells = {
    A = { label = "Gentle", values = { frameBudgetMs = 8, deleteBudgetShare = 0.25, maxCreatesPerFrame = 8, maxFirstUsePerFrame = 1, unloadCooldown = 2, shellTarget = 0, shellBuildPerFrame = 4, shellBuildBudgetShare = 0.1 } },
    B = { label = "Balanced", values = { frameBudgetMs = 16, deleteBudgetShare = 0.25, maxCreatesPerFrame = 32, maxFirstUsePerFrame = 3, unloadCooldown = 2, shellTarget = 3500, shellBuildPerFrame = 8, shellBuildBudgetShare = 0.125 } },
    C = { label = "Fast", values = { frameBudgetMs = 24, deleteBudgetShare = 0.5, maxCreatesPerFrame = 128, maxFirstUsePerFrame = 8, unloadCooldown = 1, shellTarget = 4000, shellBuildPerFrame = 16, shellBuildBudgetShare = 0.2 } },
  },
  resident = {
    A = { label = "Gentle", values = { frameBudgetMs = 8, deleteBudgetShare = 0.25, maxRefillsPerFrame = 8, maxCheapPerFrame = 64, maxFirstUsePerFrame = 1, residentCooldown = 0, residentMax = 3800, residentReserve = 0, shellBuildBudgetShare = 0.1 } },
    B = { label = "Balanced", values = { frameBudgetMs = 16, deleteBudgetShare = 0.25, maxRefillsPerFrame = 32, maxCheapPerFrame = 256, maxFirstUsePerFrame = 3, residentCooldown = 0, residentMax = 6000, residentReserve = 200, shellBuildBudgetShare = 0.125 } },
    C = { label = "Fast", values = { frameBudgetMs = 24, deleteBudgetShare = 0.5, maxRefillsPerFrame = 128, maxCheapPerFrame = 1024, maxFirstUsePerFrame = 8, residentCooldown = 0, residentMax = 9000, residentReserve = 500, shellBuildBudgetShare = 0.2 } },
  },
}

-- What changed in the tuning and when: the panel shows it so a change can be checked, not assumed.
tun.state = { revision = 0, last = nil, log = {} }
end

local SUPPORTED_SCHEMA = 2
local SECTIONS_JSON = "lua/sections.json"
local STREAM_INDEX = "lua/carbon_stream/index.json"
local SHAPES_JSON = "lua/carbon_stream/shapes.json"
local PRESETS_JSON = "lua/carbon_stream/tuning_presets.json"
local SKIP_CAP = 4096

local RESERVED = {
  class = true, name = true, __parent = true,
  __streamKey = true, __streamSections = true, __streamSource = true,
}

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
local levelRoot = TUNING.levelRoot
local initialized, suspended = false, false

local sections, sectionOrder = {}, {}
local sectionIndex, overrideIndex = {}, {}

local currentSectionID, activeSet = nil, {}
local sectionRead, sectionReading = {}, {}
local sectionReadQueue, srHead, srTail = {}, 1, 0
local loadQueue, lqHead, lqTail = {}, 1, 0
local priQueue, pqHead, pqTail = {}, 1, 0      -- urgent: objects of the current / camera section, served before loadQueue
local promotedTotal = 0                         -- queued objects moved ahead when a section changed
local queuedKeys = {}
local pending, pendingCount = {}, 0   -- id -> { terrain = tier, rest = tier }, tier = { list, at, n }
local deferred = {}                   -- id -> items the create filter held back
local createFilter = nil
local staleDiscarded, queueHighWater, createdLastFrame, createdPeakFrame = 0, 0, 0, 0
local live, liveBySection, liveCount = {}, {}, 0
local pendingUnload, unloadQueue, uqHead, uqTail = {}, {}, 1, 0

local totalTime, selectTimer = 0, 0
local camPos, camVel = nil, { x = 0, y = 0 }   -- last camera position and smoothed velocity (m/s)
local cameraSectionID, predictedSectionID = nil, nil
local aheadCandidate, aheadTime = nil, 0
local feedOrder, priorityTimer = {}, 0         -- sections in loading order: current first
local timing = { creates = 0, createMs = 0, createMax = 0, firsts = 0, firstMs = 0, repeats = 0, repeatMs = 0,
                 reads = 0, readMs = 0, readMax = 0, frameLast = 0, framePeak = 0 }
local seenShapes = {}
local shapeLive = {}                 -- shape -> number of live instances (0/nil: the engine may have freed it)
local recentFirstMs = nil            -- moving average of the latest first-use creates
local function newChange()
  return { creates = 0, createMs = 0, firsts = 0, firstMs = 0, repeats = 0, repeatMs = 0, maxMs = 0,
           objectMs = 0, fieldsMs = 0, registerMs = 0, groupMs = 0, frames = 0, workMs = 0, dtSum = 0, dtMax = 0, workMax = 0,
           importN = 0, importMs = 0, hitN = 0, hitMs = 0, unkN = 0, unkMs = 0,   -- first use: no .cdae before / .cdae existed / unknown
           deleted = 0, deleteMs = 0, deferredFirst = 0, shellRecycles = 0, shellRecycleMs = 0, shellFresh = 0, shellParks = 0, shellParkMs = 0,
           residentRevives = 0, residentReviveMs = 0, residentShapeReuses = 0, residentShapeReuseMs = 0,
           residentDeacts = 0, residentEvicts = 0,
           reloads = 0, reloadMs = 0, warms = 0, warmMs = 0, shapes = {},
           dist = { { n = 0, ms = 0 }, { n = 0, ms = 0 }, { n = 0, ms = 0 } }, nameMs = 0, liveSum = 0, liveMin = nil, liveMax = 0, rn = 0, rx = 0, ry = 0, rxx = 0, rxy = 0 }   -- r*: regression sums of registerObject ms over live count   -- shapes: name -> { n, ms, max, first, reload }
end
local change = newChange()                -- everything since the last section change
local split = { objectMs = 0, fieldsMs = 0, registerMs = 0, groupMs = 0, nameMs = 0, live = 0, path = "new-object" }
local idleFrameMs = nil              -- moving average of the frame time while nothing is loading   -- cost of the last create
local frameDeleteMs = 0
-- One clock for the whole frame: every task is capped by what is left of frameBudgetMs at the moment it starts.
local fb = {
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
local function newRun(stamp)
  local r = { stamp = stamp or 0, frames = 0, busy = 0, busyMs = 0, busyMax = 0, idle = 0, idleMs = 0, idleMax = 0,
              warmFrames = 0, warmMs = 0, settles = 0, settleSum = 0, settleMax = 0, capHits = { cheap = 0, costly = 0 }, paths = {} }
  r.order = { "resident-revive", "resident-same-shape-reuse", "shell-refill", "pool-empty-fresh-object", "new-object" }
  for _, name in ipairs(r.order) do r.paths[name] = { n = 0, ms = 0, max = 0 } end
  return r
end
local run = newRun(0)
-- Everything-warm: state and lane functions in one table (the main chunk is close to Lua's 200 locals limit).
local hold = { shape = {}, ids = {}, held = 0, cursor = 1, failed = 0, ms = 0, max = 0, maxShape = nil, group = nil,
               idle = 0, seconds = 0, complete = false }
local changeStamp, createdSinceChange, settled, settleSeconds, settlePeak = 0, 0, true, 0, 0
local createdTotal, deletedTotal, failureCount, verified = 0, 0, 0, 0
local failures = {}
local listeners = {}
local runtimeGroup = nil
local shellFree, shellFreeN = {}, 0      -- object ids of parked shells, last in first out
local shellFields = {}                   -- object id -> set of field names its current item applied
local shellDefaults, shellScratch = {}, nil   -- field name -> engine default text (read once from an untouched object)
local droppedSections, droppedObjects, droppedLast = 0, 0, nil   -- sections entered but left before their load settled
local shellSerial, shellBuildFails, shellBuildOff = 0, 0, false
local dormant, dormantOrder, doHead, doTail, dormantCount, dormantSerial = {}, {}, 1, 0, 0, 0   -- resident mode: key -> { id, shape, stamp }, oldest first
local dormantByShape = {}                -- shape -> keys of deactivated residents that can be reused without changing shapeName
local shellStats = { built = 0, buildMs = 0, recycled = 0, recycleMs = 0, fresh = 0, parked = 0, parkMs = 0, peakLive = 0,
                     revived = 0, reviveMs = 0, deactivated = 0, evicted = 0, residentShapeReuses = 0, residentShapeReuseMs = 0 }
local scratch = { x = 0, y = 0 }
local aheadPoint = { x = 0, y = 0 }

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
local function logMsg(level, fmt, ...)
  local msg = select("#", ...) > 0 and string.format(fmt, ...) or fmt
  if log then log(level, "nfscSectionStreamer", msg) else print("[nfscSectionStreamer] " .. msg) end
end

local function recordFailure(msg)
  failureCount = failureCount + 1
  failures[#failures + 1] = msg
  if #failures > 20 then table.remove(failures, 1) end
  logMsg("E", "%s", msg)
end

local function notify(method, ...)
  for i = 1, #listeners do
    local l = listeners[i]
    local fn = l[method]
    if fn then
      local ok, err = pcall(fn, l, ...)
      if not ok then recordFailure(string.format("listener %s failed: %s", method, tostring(err))) end
    end
  end
end

local function hook(name, ...)
  if extensions and extensions.hook then extensions.hook(name, ...) end
end

local function safePath(rel)
  return type(rel) == "string" and rel ~= "" and rel:sub(1, 1) ~= "/" and not rel:find("%.%.")
end

-- ---------------------------------------------------------------------------
-- Section geometry (2D, height ignored). Mirrors the game's VisibleSection lookup:
-- exact containment first, else closest edge within a tolerance (ties -> lower ID).
-- ---------------------------------------------------------------------------
local function pointInBounds(p, bmin, bmax)
  return p.x >= bmin.x and p.x <= bmax.x and p.y >= bmin.y and p.y <= bmax.y
end

local function pointInPolygon(p, points)
  local inside = false
  local n = #points
  local j = n
  for i = 1, n do
    local pi, pj = points[i], points[j]
    if (pi.y > p.y) ~= (pj.y > p.y) then
      local xCross = (pj.x - pi.x) * (p.y - pi.y) / (pj.y - pi.y) + pi.x
      if p.x < xCross then inside = not inside end
    end
    j = i
  end
  return inside
end

local function distanceToPolygonEdges(p, points)
  local minDist = math.huge
  local n = #points
  local j = n
  for i = 1, n do
    local a, b = points[j], points[i]
    local abx, aby = b.x - a.x, b.y - a.y
    local apx, apy = p.x - a.x, p.y - a.y
    local lenSq = abx * abx + aby * aby
    local t = 0
    if lenSq > 0 then t = math.max(0, math.min(1, (apx * abx + apy * aby) / lenSq)) end
    local dx, dy = p.x - (a.x + t * abx), p.y - (a.y + t * aby)
    local dist = math.sqrt(dx * dx + dy * dy)
    if dist < minDist then minDist = dist end
    j = i
  end
  return minDist
end

local function isInSection(p, id)
  local s = sections[id]
  return s ~= nil and pointInBounds(p, s.boundsMin, s.boundsMax) and pointInPolygon(p, s.points)
end

local function findSection(p)
  for i = 1, #sectionOrder do
    local id = sectionOrder[i]
    if isInSection(p, id) then return id end
  end
  local bestID, bestDist = nil, math.huge
  for i = 1, #sectionOrder do
    local id = sectionOrder[i]
    local d = distanceToPolygonEdges(p, sections[id].points)
    if d <= TUNING.containmentTolerance and d < bestDist then bestID, bestDist = id, d end
  end
  return bestID
end

local function computeActive(id)
  local set = {}
  if id and sections[id] then
    set[id] = true
    for _, rel in ipairs(sections[id].related) do set[rel] = true end
  end
  return set
end

-- ---------------------------------------------------------------------------
-- Loading the section/stream metadata
-- ---------------------------------------------------------------------------
local function loadSections()
  sections, sectionOrder = {}, {}
  local data = jsonReadFile(levelRoot .. "/" .. SECTIONS_JSON)
  if type(data) ~= "table" or type(data.sections) ~= "table" then
    error("could not read " .. levelRoot .. "/" .. SECTIONS_JSON)
  end
  for _, entry in ipairs(data.sections) do
    local id = tonumber(entry.id)
    local points = {}
    for _, pt in ipairs(entry.points or {}) do points[#points + 1] = { x = pt[1], y = pt[2] } end
    if id and entry.boundsMin and entry.boundsMax and #points >= 3 then
      local related = {}
      for _, r in ipairs(entry.related or {}) do
        local n = tonumber(r)
        if n then related[#related + 1] = n end
      end
      sections[id] = {
        id = id, points = points, related = related,
        boundsMin = { x = entry.boundsMin[1], y = entry.boundsMin[2] },
        boundsMax = { x = entry.boundsMax[1], y = entry.boundsMax[2] },
      }
      sectionOrder[#sectionOrder + 1] = id
    end
  end
  table.sort(sectionOrder)
end

local function loadStreamIndex()
  sectionIndex, overrideIndex = {}, {}
  local data = jsonReadFile(levelRoot .. "/" .. STREAM_INDEX)
  if type(data) ~= "table" or type(data.sections) ~= "table" then
    error("could not read " .. levelRoot .. "/" .. STREAM_INDEX)
  end
  if data.schemaVersion ~= SUPPORTED_SCHEMA then
    error(string.format("stream index schemaVersion %s is not supported (need %d): rebuild with the current builder",
      tostring(data.schemaVersion), SUPPORTED_SCHEMA))
  end
  for _, entry in ipairs(data.sections) do
    local id = tonumber(entry.id)
    if id and safePath(entry.file) then
      sectionIndex[id] = { file = levelRoot .. "/" .. entry.file, count = entry.count or 0 }
    end
  end
  if type(data.overrides) == "table" then overrideIndex = data.overrides end
end

-- ---------------------------------------------------------------------------
-- Object creation / deletion
-- ---------------------------------------------------------------------------
local function ensureRuntimeGroup()
  if runtimeGroup then return runtimeGroup end
  local g = scenetree.findObject(TUNING.runtimeGroupName)
  if not g then
    g = createObject("SimGroup")
    if not g then error("could not create runtime group") end
    g:registerObject(TUNING.runtimeGroupName)
    local mission = scenetree.findObject("MissionGroup")
    if mission then mission:addObject(g) end
  end
  runtimeGroup = g
  return g
end

local function destroyRuntimeGroup()
  local g = scenetree.findObject(TUNING.runtimeGroupName)
  if g then pcall(g.delete, g) end
  runtimeGroup = nil
  if shellScratch then pcall(shellScratch.delete, shellScratch); shellScratch = nil end
end

local function fieldText(value)
  local t = type(value)
  if t == "boolean" then return value and "1" or "0" end
  if t == "number" or t == "string" then return tostring(value) end
  if t == "table" then
    local parts = {}
    for i = 1, #value do
      if type(value[i]) ~= "number" then return nil end
      parts[i] = tostring(value[i])
    end
    if #parts > 0 then return table.concat(parts, " ") end
  end
  return nil
end

local function itemSections(item)
  local ids = item.__streamSections
  if type(ids) == "table" then return ids end
  local out = {}
  for token in tostring(item.sectionID or ""):gmatch("[^,%s]+") do
    local n = tonumber(token)
    if n then out[#out + 1] = n end
  end
  return out
end

local function anyActive(ids)
  for i = 1, #ids do
    if activeSet[ids[i]] then return true end
  end
  return false
end

local function runtimeName(item, key)
  if TUNING.skipNameLookup then return "nfsc_" .. tostring(key) end
  local wanted = (type(item.name) == "string" and item.name ~= "") and item.name or ("nfsc_" .. key)
  if scenetree.findObject(wanted) then wanted = wanted .. "_s" .. tostring(key):gsub("[^%w]", ""):sub(-6) end
  return wanted
end

-- ---------------------------------------------------------------------------
-- Shell pool (creationMode = "shells", see header)
-- ---------------------------------------------------------------------------
local shellChecked, shellDisabled = false, false

-- true only when FS:fileExists is available and says the shell shape is not there
local function shellShapeMissing()
  local fs = rawget(_G, "FS")
  if not fs then return false end
  local path = TUNING.shellShape
  local alt = path:sub(1, 1) == "/" and path:sub(2) or ("/" .. path)
  local ok1, a = pcall(function() return fs:fileExists(path) end)
  local ok2, b = pcall(function() return fs:fileExists(alt) end)
  if not ok1 and not ok2 then return false end
  return not ((ok1 and a) or (ok2 and b))
end

local function shellMode()           -- true in "shells" and "resident": objects come from and go back to the pool
  if (TUNING.creationMode ~= "shells" and TUNING.creationMode ~= "resident") or shellDisabled then return false end
  if not shellChecked then
    shellChecked = true
    if shellShapeMissing() then
      shellDisabled = true
      recordFailure("shell pool off, creating the current way: shellShape not found: " .. tostring(TUNING.shellShape))
      return false
    end
  end
  return true
end

local function residentMode()
  return TUNING.creationMode == "resident" and shellMode()
end

local function poolTotal() return liveCount + dormantCount + shellFreeN end

local function shellName()
  shellSerial = shellSerial + 1
  return "nfsc_shell_" .. shellSerial
end

-- The engine default of a field as text, read once from an object nobody has set anything on.
local function shellDefault(field)
  local d = shellDefaults[field]
  if d ~= nil then return d end
  if not shellScratch then shellScratch = createObject("TSStatic") end
  local text = ""
  if shellScratch then
    local ok, v = pcall(shellScratch.getField, shellScratch, field, 0)
    if ok and v ~= nil then text = tostring(v) end
  end
  shellDefaults[field] = text
  return text
end

local function forceNoCollision(obj)
  if TUNING.forceCollisionNone then
    pcall(obj.setField, obj, "collisionType", 0, "None")
    pcall(obj.setField, obj, "decalType", 0, "None")
  end
end

-- Takes a parked shell and fills it in from item. Returns the object, or nil when no parked shell is left.
local function acquireShell(item)
  while shellFreeN > 0 do
    local id = shellFree[shellFreeN]
    shellFree[shellFreeN] = nil
    shellFreeN = shellFreeN - 1
    local obj = scenetree.findObjectById(id)
    if obj then
      local last, applied = shellFields[id], {}
      pcall(obj.setField, obj, "shapeName", 0, item.shapeName)
      for field, value in pairs(item) do
        if field ~= "shapeName" and not RESERVED[field] then
          local text = fieldText(value)
          if text ~= nil then
            pcall(obj.setField, obj, field, 0, text)
            applied[field] = true
          end
        end
      end
      if last then                                   -- what the previous item set and this one does not
        for field in pairs(last) do
          if not applied[field] then pcall(obj.setField, obj, field, 0, shellDefault(field)) end
        end
      end
      shellFields[id] = applied
      forceNoCollision(obj)
      pcall(obj.postApply, obj)
      pcall(function() obj.hidden = false end)
      return obj
    end
    shellFields[id] = nil                            -- the engine lost it (level change, manual delete)
  end
  return nil
end

-- Releases an object to the pool instead of deleting it. false: the object is already gone.
local function parkShell(id)
  local obj = scenetree.findObjectById(id)
  if not obj then shellFields[id] = nil; return false end
  pcall(function() obj.hidden = true end)
  pcall(obj.setField, obj, "shapeName", 0, TUNING.shellShape)
  pcall(obj.postApply, obj)
  shellFreeN = shellFreeN + 1
  shellFree[shellFreeN] = id
  return true
end

-- One new parked shell. Returns true, or false and the reason.
local function buildShell()
  local obj = createObject("TSStatic")
  if not obj then return false, "createObject(TSStatic) returned nil" end
  pcall(obj.setField, obj, "shapeName", 0, TUNING.shellShape)
  forceNoCollision(obj)
  pcall(function() obj.hidden = true end)
  local ok, err = pcall(obj.registerObject, obj, shellName())
  if ok and err == false then ok, err = false, "the engine refused it (returned false)" end
  if not ok then
    pcall(obj.delete, obj)
    return false, tostring(err)
  end
  local okId, id = pcall(obj.getID, obj)
  if not okId or not id or not scenetree.findObjectById(id) then return false, "the object is not alive after registerObject" end
  local group = ensureRuntimeGroup()
  pcall(group.addObject, group, obj)
  shellFreeN = shellFreeN + 1
  shellFree[shellFreeN] = id
  shellStats.built = shellStats.built + 1
  return true
end

-- Remove a dormant key from the per-shape index in O(1). The last key fills the removed slot.
local function removeDormantShapeIndex(key, d)
  if not d or not d.shape or not d.shapeAt then return end
  local list = dormantByShape[d.shape]
  if list then
    local at = d.shapeAt
    local lastAt = #list
    local last = list[lastAt]
    if list[at] == key then
      list[at] = last
      list[lastAt] = nil
      if last and last ~= key then
        local other = dormant[last]
        if other then other.shapeAt = at end
      end
      if #list == 0 then dormantByShape[d.shape] = nil end
    end
  end
  d.shapeAt = nil
end

-- Resident mode: the resting state ------------------------------------------------------------------------
-- Deactivate: hide, keep key, shape and fields. Returns false when the engine object is gone.
local function deactivateDormant(key, entry)
  local obj = scenetree.findObjectById(entry.id)
  if not obj then shellFields[entry.id] = nil; return false end
  pcall(function() obj.hidden = true end)
  dormantSerial = dormantSerial + 1
  local d = { id = entry.id, shape = entry.shape, stamp = dormantSerial }
  dormant[key] = d
  if d.shape then
    local list = dormantByShape[d.shape]
    if not list then list = {}; dormantByShape[d.shape] = list end
    d.shapeAt = #list + 1
    list[#list + 1] = key
  end
  doTail = doTail + 1
  dormantOrder[doTail] = { key = key, stamp = dormantSerial }
  dormantCount = dormantCount + 1
  if entry.shape then shapeLive[entry.shape] = (shapeLive[entry.shape] or 0) + 1 end   -- the shape stays loaded
  shellStats.deactivated = shellStats.deactivated + 1
  change.residentDeacts = change.residentDeacts + 1
  return true
end

local function forgetDormantShape(d)
  if d.shape and shapeLive[d.shape] then
    local left = shapeLive[d.shape] - 1
    shapeLive[d.shape] = left > 0 and left or nil
  end
end

-- Revive: the object of this item's key, shown again as it was. nil when there is none.
local function reviveDormant(item)
  local key = item.__streamKey
  local d = key and dormant[key]
  if not d then return nil end
  dormant[key] = nil
  dormantCount = dormantCount - 1
  removeDormantShapeIndex(key, d)
  forgetDormantShape(d)                                  -- registerLive counts it again
  local obj = scenetree.findObjectById(d.id)
  if not obj then shellFields[d.id] = nil; return nil end
  pcall(function() obj.hidden = false end)
  return obj
end

-- Reuse a deactivated resident with the requested shape, even when its old stream key differs.
-- Exact-key revival is attempted first. This path preserves shapeName and avoids a new registration.
local function acquireDormantShape(item)
  local shape = item.shapeName
  local list = dormantByShape[shape]
  while list and #list > 0 do
    local key = list[#list]
    local d = dormant[key]
    if not d or d.shape ~= shape then
      list[#list] = nil
      if #list == 0 then dormantByShape[shape] = nil end
    else
      dormant[key] = nil
      dormantCount = dormantCount - 1
      removeDormantShapeIndex(key, d)
      forgetDormantShape(d)
      local obj = scenetree.findObjectById(d.id)
      if obj then
        local last, applied = shellFields[d.id], {}
        for field, value in pairs(item) do
          if field ~= "shapeName" and not RESERVED[field] then
            local text = fieldText(value)
            if text ~= nil then
              pcall(obj.setField, obj, field, 0, text)
              applied[field] = true
            end
          end
        end
        if last then
          for field in pairs(last) do
            if not applied[field] then pcall(obj.setField, obj, field, 0, shellDefault(field)) end
          end
        end
        shellFields[d.id] = applied
        forceNoCollision(obj)
        pcall(obj.postApply, obj)
        pcall(function() obj.hidden = false end)
        return obj
      end
      shellFields[d.id] = nil
    end
    list = dormantByShape[shape]
  end
  return nil
end

-- true when a resident can serve this item without a shape change (its own key, or one of the same shape).
local function dormantAvailable(item)
  local key = item.__streamKey
  if key and dormant[key] then return true end
  local list = item.shapeName and dormantByShape[item.shapeName]
  return list ~= nil and #list > 0
end

-- Evicts the n oldest deactivated objects: their shells go to the free list as they are (hidden, old shape).
local function evictOldest(n)
  local done = 0
  while done < n and doHead <= doTail do
    local q = dormantOrder[doHead]
    dormantOrder[doHead] = nil
    doHead = doHead + 1
    local d = q and dormant[q.key]
    if d and d.stamp == q.stamp then                     -- skip entries that were revived meanwhile
      removeDormantShapeIndex(q.key, d)
      dormant[q.key] = nil
      dormantCount = dormantCount - 1
      forgetDormantShape(d)
      shellFreeN = shellFreeN + 1
      shellFree[shellFreeN] = d.id
      shellStats.evicted = shellStats.evicted + 1
      change.residentEvicts = change.residentEvicts + 1
      done = done + 1
    end
  end
  if doHead > doTail then dormantOrder, doHead, doTail = {}, 1, 0 end
  return done
end

-- Every deactivated object back to the pool (mode switch): parked on the dot, or deleted.
local function releaseDormant(deleteThem)
  local n = 0
  for key, d in pairs(dormant) do
    removeDormantShapeIndex(key, d)
    forgetDormantShape(d)
    if deleteThem then
      local obj = scenetree.findObjectById(d.id)
      if obj then pcall(obj.delete, obj) end
      shellFields[d.id] = nil
    else
      parkShell(d.id)
    end
    dormant[key] = nil
    n = n + 1
  end
  dormantOrder, doHead, doTail, dormantCount = {}, 1, 0, 0
  dormantByShape = {}
  return n
end

local function createStreamedObject(item, nameOverride, diag)
  local shape = item.shapeName
  if type(shape) ~= "string" or shape == "" then return nil, "missing shapeName" end
  split.diagRegisterMs = nil
  local pooled = nameOverride == nil and shellMode()      -- probe objects (named) always take the plain path
  if pooled then
    local ta = os.clock()
    if residentMode() then
      local back = reviveDormant(item)
      if back then
        local ms = (os.clock() - ta) * 1000
        split.objectMs, split.fieldsMs, split.registerMs, split.groupMs, split.nameMs, split.live = 0, 0, 0, 0, 0, liveCount
        split.path = "resident-revive"
        if diag then diag:recordOperation("resident-revive", ms, currentSectionID, item.__streamKey or item.name, shape, split.path, nil, "resident revive elapsed; includes lookup and unhide") end
        shellStats.revived, shellStats.reviveMs = shellStats.revived + 1, shellStats.reviveMs + ms
        change.residentRevives, change.residentReviveMs = change.residentRevives + 1, change.residentReviveMs + ms
        return back
      end
      local sameShape = acquireDormantShape(item)
      if sameShape then
        local ms = (os.clock() - ta) * 1000
        split.objectMs, split.fieldsMs, split.registerMs, split.groupMs, split.nameMs, split.live = 0, ms, 0, 0, 0, liveCount
        split.path = "resident-same-shape-reuse"
        if diag then diag:recordOperation("resident-same-shape-reuse", ms, currentSectionID, item.__streamKey or item.name, shape, split.path, nil, "same-shape resident reused across stream keys; no shapeName write or registerObject") end
        shellStats.residentShapeReuses = shellStats.residentShapeReuses + 1
        shellStats.residentShapeReuseMs = shellStats.residentShapeReuseMs + ms
        change.residentShapeReuses = change.residentShapeReuses + 1
        change.residentShapeReuseMs = change.residentShapeReuseMs + ms
        return sameShape
      end
      if shellFreeN == 0 and dormantCount > 0 and poolTotal() >= TUNING.residentMax then evictOldest(1) end
    end
    local shell = acquireShell(item)
    if shell then
      local ms = (os.clock() - ta) * 1000
      split.objectMs, split.fieldsMs, split.registerMs, split.groupMs, split.nameMs, split.live = 0, ms, 0, 0, 0, liveCount
      split.path = "shell-refill"
      if diag then diag:recordOperation("shell-refill", ms, currentSectionID, item.__streamKey or item.name, shape, split.path, nil, "field reset/refill, postApply and unhide elapsed; mixed engine/Lua scope") end
      shellStats.recycled, shellStats.recycleMs = shellStats.recycled + 1, shellStats.recycleMs + ms
      change.shellRecycles, change.shellRecycleMs = change.shellRecycles + 1, change.shellRecycleMs + ms
      return shell
    end
    shellStats.fresh = shellStats.fresh + 1                  -- no parked shell left: the current way, the object joins the pool later
    change.shellFresh = change.shellFresh + 1
  end
  local applied = pooled and {} or nil
  split.path = pooled and "pool-empty-fresh-object" or "new-object"
  local diagCreateObjectStart = diag and diag:now()
  local t0 = os.clock()
  local obj = createObject("TSStatic")
  local diagCreateObjectMs = diag and ((diag:now() - diagCreateObjectStart) * 1000)
  local t1 = os.clock()
  if diag then diag:recordOperation("createObject", diagCreateObjectMs, currentSectionID, item.__streamKey or item.name, shape, split.path, diagCreateObjectMs, "createObject API elapsed") end
  if not obj then return nil, "createObject(TSStatic) returned nil" end
  local diagFieldsStart = diag and diag:now()
  pcall(obj.setField, obj, "shapeName", 0, shape)
  for field, value in pairs(item) do
    if field ~= "shapeName" and not RESERVED[field] then
      local text = fieldText(value)
      if text ~= nil then
        pcall(obj.setField, obj, field, 0, text)
        if applied then applied[field] = true end
      end
    end
  end
  if TUNING.forceCollisionNone then
    pcall(obj.setField, obj, "collisionType", 0, "None")
    pcall(obj.setField, obj, "decalType", 0, "None")
  end
  local t2 = os.clock()
  if diag then diag:recordOperation("field-application", (diag:now() - diagFieldsStart) * 1000, currentSectionID, item.__streamKey or item.name, shape, split.path, nil, "fieldText formatting + setField API calls; mixed elapsed scope") end
  local diagNameStart = diag and diag:now()
  local wantedName = nameOverride or (pooled and shellName() or runtimeName(item, item.__streamKey or "x"))
  local tn = os.clock()
  if diag then diag:recordOperation("name-prepare", (diag:now() - diagNameStart) * 1000, currentSectionID, item.__streamKey or wantedName, shape, split.path, nil, "streamer-side name generation elapsed") end
  local diagRegisterStart = diag and diag:now()
  local ok, err = pcall(obj.registerObject, obj, wantedName)
  if diag then
    local ms = (diag:now() - diagRegisterStart) * 1000
    split.diagRegisterMs = ms
    diag:recordOperation("registerObject", ms, currentSectionID, item.__streamKey or wantedName, shape, split.path, ms, "registerObject API elapsed; includes engine work invoked synchronously")
  end
  if ok and err == false then ok, err = false, "the engine refused it (returned false)" end
  if not ok then
    pcall(obj.delete, obj)
    return nil, "registerObject failed: " .. tostring(err)
  end
  local t3 = os.clock()
  local group = ensureRuntimeGroup()
  pcall(group.addObject, group, obj)
  local t4 = os.clock()
  if diag then diag:recordOperation("group-add", (t4 - t3) * 1000, currentSectionID, item.__streamKey or wantedName, shape, split.path, (t4 - t3) * 1000, "SimGroup.addObject API elapsed") end
  if applied then shellFields[obj:getID()] = applied end
  split.objectMs, split.fieldsMs, split.registerMs, split.groupMs =
    (t1 - t0) * 1000, (t2 - t1) * 1000, (t3 - tn) * 1000, (t4 - t3) * 1000
  split.nameMs, split.live = (tn - t2) * 1000, liveCount
  return obj
end

local function verifyReadback(key, item, obj)
  if verified >= TUNING.verifyFirstN then return end
  verified = verified + 1
  local ok, pos = pcall(obj.getPosition, obj)
  local ok2, scl = pcall(obj.getScale, obj)
  local p, s = item.position or {}, item.scale or {}
  logMsg("I", "verify %s exported pos=(%s) scale=(%s) readback pos=%s scale=%s", tostring(key),
    table.concat(p, ", "), table.concat(s, ", "), ok and tostring(pos) or "n/a", ok2 and tostring(scl) or "n/a")
end

local function registerLive(key, obj, item)
  local ids = itemSections(item)
  live[key] = { id = obj:getID(), sections = ids, shape = item.shapeName, item = item }
  liveCount = liveCount + 1
  if liveCount > shellStats.peakLive then shellStats.peakLive = liveCount end
  if item.shapeName then shapeLive[item.shapeName] = (shapeLive[item.shapeName] or 0) + 1 end
  for i = 1, #ids do
    local bucket = liveBySection[ids[i]]
    if not bucket then bucket = {}; liveBySection[ids[i]] = bucket end
    bucket[key] = true
  end
end

local function unregisterLive(key)
  local entry = live[key]
  if not entry then return nil end
  live[key] = nil
  liveCount = liveCount - 1
  if entry.shape and shapeLive[entry.shape] then
    local left = shapeLive[entry.shape] - 1
    shapeLive[entry.shape] = left > 0 and left or nil
  end
  for i = 1, #entry.sections do
    local bucket = liveBySection[entry.sections[i]]
    if bucket then bucket[key] = nil end
  end
  return entry
end

local function deleteLive(key, diag)
  local entry = unregisterLive(key)
  if not entry then return end
  notify("onObjectDeleted", key)
  deletedTotal = deletedTotal + 1
  if residentMode() and deactivateDormant(key, entry) then return end
  if shellMode() then
    local ta = os.clock()
    if parkShell(entry.id) then
      local ms = (os.clock() - ta) * 1000
      shellStats.parked, shellStats.parkMs = shellStats.parked + 1, shellStats.parkMs + ms
      change.shellParks, change.shellParkMs = change.shellParks + 1, change.shellParkMs + ms
      return
    end
  end
  local obj = scenetree.findObjectById(entry.id)
  if obj then
    local deleteStart = diag and diag:now()
    pcall(obj.delete, obj)
    if diag then local ms = (diag:now() - deleteStart) * 1000; diag:recordOperation("object-delete-api", ms, currentSectionID, key, entry.shape, "delete", ms, "object.delete API elapsed") end
  end
end

-- ---------------------------------------------------------------------------
-- Queues
-- ---------------------------------------------------------------------------
-- The game's GetLoadingPriority: the point one second ahead, its distance outside the section,
-- shrunk when the heading points at the section, in three 75 m bands. 0 loads first.
local function loadingPriority(id)
  local sec = sections[id]
  local speed = math.sqrt(camVel.x * camVel.x + camVel.y * camVel.y)
  if not sec or not camPos or speed < 1.0 then return 0 end
  local p = { x = camPos.x + camVel.x, y = camPos.y + camVel.y }
  local distance = isInSection(p, id) and 0 or distanceToPolygonEdges(p, sec.points)
  local cx, cy = (sec.boundsMin.x + sec.boundsMax.x) * 0.5, (sec.boundsMin.y + sec.boundsMax.y) * 0.5
  local vx, vy = cx - p.x, cy - p.y
  local len = math.sqrt(vx * vx + vy * vy)
  local dot = 1
  if len > 1e-6 then dot = (camVel.x * vx + camVel.y * vy) / (speed * len) end
  dot = math.max(-1, math.min(1, dot))
  local angle = math.max(20, math.min(90, math.deg(math.acos(dot))))
  local speedFactor = math.min(speed * 0.016666668, 1)
  local adjusted = distance * (1 - (90 - angle) * 0.014285714 * speedFactor * 0.67)
  return math.max(0, math.min(2, math.floor(adjusted * 0.013333334)))
end

-- Current section first, then its related sections by priority band; the static order breaks ties.
local function rebuildFeedOrder()
  feedOrder = {}
  if not currentSectionID or not sections[currentSectionID] then return end
  local entries = {}
  for rank, id in ipairs(sections[currentSectionID].related) do
    if id ~= currentSectionID then entries[#entries + 1] = { id = id, tier = loadingPriority(id), rank = rank } end
  end
  table.sort(entries, function(a, b)
    if a.tier ~= b.tier then return a.tier < b.tier end
    return a.rank < b.rank
  end)
  feedOrder[1] = currentSectionID
  for i = 1, #entries do feedOrder[i + 1] = entries[i].id end
end

local function queueSectionRead(id)
  if sectionRead[id] or sectionReading[id] then return end
  if not sectionIndex[id] then sectionRead[id] = true; return end   -- section with no streamed objects
  sectionReading[id] = true
  srTail = srTail + 1
  sectionReadQueue[srTail] = id
end

-- Objects of the section the camera is in, or the one the streamer is currently loading for, are
-- urgent: they are served before anything left over from the section just left.
local function isUrgent(item)
  if not TUNING.currentSectionFirst then return false end
  local ids = itemSections(item)
  for i = 1, #ids do
    local id = ids[i]
    if id == currentSectionID or id == cameraSectionID then return true end
  end
  return false
end

local function queueItem(item)
  local key = item.__streamKey
  if not key or live[key] or queuedKeys[key] then return end
  queuedKeys[key] = true
  if isUrgent(item) then
    pqTail = pqTail + 1
    priQueue[pqTail] = item
  else
    lqTail = lqTail + 1
    loadQueue[lqTail] = item
  end
end
local function priLength() return pqTail - pqHead + 1 end
local function queueLength() return (lqTail - lqHead + 1) + (pqTail - pqHead + 1) end

-- Terrain-like objects (identity matrix / chopped roadway) are loaded before everything else.
local function isTerrainItem(item)
  local flags = item.instanceFlags
  if type(flags) ~= "string" then return false end
  flags = flags:lower():gsub("[^%w]", "")
  return flags:find("identitymatrix", 1, true) ~= nil or flags:find("choppedroadway", 1, true) ~= nil
end

-- Same shapeName next to each other (first appearance decides the order of the groups).
local function groupByShape(items)
  local order, buckets = {}, {}
  for i = 1, #items do
    local shape = items[i].shapeName or ""
    local bucket = buckets[shape]
    if not bucket then bucket = {}; buckets[shape] = bucket; order[#order + 1] = shape end
    bucket[#bucket + 1] = items[i]
  end
  local out = {}
  for i = 1, #order do
    local bucket = buckets[order[i]]
    for j = 1, #bucket do out[#out + 1] = bucket[j] end
  end
  return out
end

local function appendTier(tier, items)
  if #items == 0 then return end
  local grouped = groupByShape(items)
  local list = tier.list
  for i = 1, #grouped do list[tier.n + i] = grouped[i] end
  tier.n = tier.n + #grouped
  pendingCount = pendingCount + #grouped
end

local function addPending(id, items)
  local terrain, rest = {}, {}
  for i = 1, #items do
    local item = items[i]
    if isTerrainItem(item) then terrain[#terrain + 1] = item else rest[#rest + 1] = item end
  end
  local entry = pending[id]
  if not entry then
    entry = { terrain = { list = {}, at = 1, n = 0 }, rest = { list = {}, at = 1, n = 0 } }
    pending[id] = entry
  end
  appendTier(entry.terrain, terrain)
  appendTier(entry.rest, rest)
end

local function releasePending(id)
  local entry = pending[id]
  if entry then
    pendingCount = pendingCount - (entry.terrain.n - entry.terrain.at + 1) - (entry.rest.n - entry.rest.at + 1)
    pending[id] = nil
  end
  deferred[id] = nil
end

local function deferItem(id, item)
  local list = deferred[id]
  if not list then list = {}; deferred[id] = list end
  list[#list + 1] = item
end

-- Feeds one tier of one section into the load queue until the queue is full.
local function feedTier(id, tierName)
  local entry = pending[id]
  if not entry then return end
  local tier = entry[tierName]
  local list = tier.list
  while tier.at <= tier.n do
    local item = list[tier.at]
    -- urgent objects have a queue of their own, so a full queue of leftovers never holds them back
    if isUrgent(item) then
      if priLength() >= TUNING.maxQueuedItems then break end
    elseif queueLength() >= TUNING.maxQueuedItems then
      break
    end
    list[tier.at] = nil
    tier.at = tier.at + 1
    pendingCount = pendingCount - 1
    if createFilter and not createFilter(item) then deferItem(id, item) else queueItem(item) end
  end
  if tier.at > tier.n then tier.list, tier.at, tier.n = {}, 1, 0 end
  if entry.terrain.n == 0 and entry.rest.n == 0 then pending[id] = nil end
end

-- Terrain of every active section first, then the rest; sections in feedOrder (current first).
local function feedQueue()
  if pendingCount <= 0 or not currentSectionID or not sections[currentSectionID] then return end
  if TUNING.currentSectionFirst then                       -- the camera's section and the streamed one, terrain first
    for _, tierName in ipairs({ "terrain", "rest" }) do
      feedTier(currentSectionID, tierName)
      if cameraSectionID and cameraSectionID ~= currentSectionID then feedTier(cameraSectionID, tierName) end
    end
  end
  for _, tierName in ipairs({ "terrain", "rest" }) do
    for i = 1, #feedOrder do
      if queueLength() >= TUNING.maxQueuedItems then break end
      feedTier(feedOrder[i], tierName)
    end
  end
  local length = queueLength()
  if length > queueHighWater then queueHighWater = length end
end

-- Keeps only the entries some active section still needs and sorts them into the two queues: what
-- belongs to the camera's section or the streamed one goes first (in its original order), what was
-- urgent for a section that is no longer current goes to the front of the rest.
local function purgeQueue()
  if lqHead > lqTail and pqHead > pqTail then return end
  local urgent, rest, nu, nr = {}, {}, 0, 0
  local promoted = 0
  queuedKeys = {}
  local function sort(queue, from, to, wasUrgent)
    for i = from, to do
      local item = queue[i]
      local key = item.__streamKey
      if not live[key] and anyActive(itemSections(item)) then
        queuedKeys[key] = true
        if isUrgent(item) then
          nu = nu + 1
          urgent[nu] = item
          if not wasUrgent then promoted = promoted + 1 end
        else
          nr = nr + 1
          rest[nr] = item
        end
      else
        staleDiscarded = staleDiscarded + 1
      end
    end
  end
  sort(priQueue, pqHead, pqTail, true)                    -- old urgent items first: demoted ones lead the rest
  sort(loadQueue, lqHead, lqTail, false)
  priQueue, pqHead, pqTail = urgent, 1, nu
  loadQueue, lqHead, lqTail = rest, 1, nr
  promotedTotal = promotedTotal + promoted
  return promoted
end

local function scheduleUnload(key)
  if pendingUnload[key] then return end
  pendingUnload[key] = totalTime
  uqTail = uqTail + 1
  unloadQueue[uqTail] = { key = key, stamp = totalTime }
end

local function processSectionReads(diag)
  local reads = 0
  while srHead <= srTail and reads < TUNING.maxSectionReadsPerFrame and pendingCount < TUNING.maxPendingRecords
        and (reads == 0 or fb.remaining() > 0) do      -- the first read always goes, more only while the budget lasts
    local id = sectionReadQueue[srHead]
    sectionReadQueue[srHead] = nil
    srHead = srHead + 1
    if activeSet[id] and sectionReading[id] then
      reads = reads + 1
      local entry = sectionIndex[id]
      local readStart = os.clock()
      local diagReadStart = diag and diag:now()
      local ok, data = pcall(jsonReadFile, entry.file)
      local readMs = (os.clock() - readStart) * 1000
      if diag then diag:recordOperation("section-json-read", (diag:now() - diagReadStart) * 1000, id, entry.file, nil, "section-read", nil, "jsonReadFile elapsed; file I/O + JSON decoding, mixed scope") end
      timing.reads, timing.readMs = timing.reads + 1, timing.readMs + readMs
      if readMs > timing.readMax then timing.readMax = readMs end
      if ok and type(data) == "table" and type(data.objects) == "table" then
        addPending(id, data.objects)
      else
        recordFailure("could not read section file " .. tostring(entry.file))
      end
      sectionRead[id] = true
    end
    sectionReading[id] = nil
  end
  if srHead > srTail then sectionReadQueue, srHead, srTail = {}, 1, 0 end
  return reads
end

-- Expected cost of creating the first instance of a shape (real average once there is one).
local function shortShapeName(name)
  local base = (name:match("([^/\\]+)$") or name):gsub("%.dae$", "")
  return base
end

-- Does the engine already have a .cdae for this shape? true: a load is a cache read; false: the first use
-- imports the COLLADA and writes the cache; nil: cannot tell (no FS:fileExists, or not a .dae shape).
local fsUnavailable = false
local function fileExists(fs, path)
  local ok, res = pcall(function() return fs:fileExists(path) end)
  if not ok then return nil end
  return res and true or false
end
local function shapeCached(shape)
  if fsUnavailable or type(shape) ~= "string" or not shape:lower():find("%.dae$") then return nil end
  local fs = rawget(_G, "FS")
  if fs == nil then fsUnavailable = true; return nil end
  local path = shape:gsub("%.[Dd][Aa][Ee]$", ".cdae")
  local found = fileExists(fs, path)
  if found == nil then fsUnavailable = true; return nil end
  if found then return true end
  local alt = path:sub(1, 1) == "/" and path:sub(2) or ("/" .. path)          -- with and without the leading slash
  return fileExists(fs, alt) == true
end

local function expectedFirstMs()
  return recentFirstMs or TUNING.firstUseGuessMs
end

local function processLoads(diag)
  local started = os.clock()
  local budget = fb.remaining()                      -- creates get what reads and deletes left of the frame
  local made, firstUse, skipped = 0, 0, 0
  local resident = residentMode()                    -- resident mode caps cheap and expensive creates separately
  local cheapMade, costlyMade = 0, 0
  while (pqHead <= pqTail or lqHead <= lqTail) and (resident or made < TUNING.maxCreatesPerFrame) and skipped < SKIP_CAP do
    local fromUrgent = pqHead <= pqTail
    local item = fromUrgent and priQueue[pqHead] or loadQueue[lqHead]
    local key = item.__streamKey
    local shape = item.shapeName
    if live[key] or not anyActive(itemSections(item)) then
      if fromUrgent then priQueue[pqHead] = nil; pqHead = pqHead + 1 else loadQueue[lqHead] = nil; lqHead = lqHead + 1 end
      queuedKeys[key] = nil
      skipped = skipped + 1
    else
      local cheap = false
      if resident then
        cheap = dormantAvailable(item)
        if cheap and cheapMade >= TUNING.maxCheapPerFrame then run.capHits.cheap = run.capHits.cheap + 1; break end
        if not cheap and costlyMade >= TUNING.maxRefillsPerFrame then run.capHits.costly = run.capHits.costly + 1; break end
      end
      local isHeld = shape ~= nil and hold.shape[shape] == true        -- everything-warm: a hidden holder keeps it loaded
      local isFirst = shape ~= nil and not seenShapes[shape] and not isHeld
      local isWarm = shape ~= nil and (isHeld or (shapeLive[shape] or 0) > 0)    -- a live instance keeps the shape loaded
      if isFirst and made > 0 then
        -- a new shape is the expensive create: at most maxFirstUsePerFrame, and never one the budget cannot hold
        local elapsed = (os.clock() - started) * 1000
        if firstUse >= TUNING.maxFirstUsePerFrame or elapsed + expectedFirstMs() > budget then
          change.deferredFirst = change.deferredFirst + 1
          break                                          -- stays at the head of the queue for the next frame
        end
      end
      if fromUrgent then priQueue[pqHead] = nil; pqHead = pqHead + 1 else loadQueue[lqHead] = nil; lqHead = lqHead + 1 end
      queuedKeys[key] = nil
      local firstKind = nil
      if isFirst then
        local cached = shapeCached(shape)
        firstKind = (cached == true and "cached") or (cached == false and "import") or "unknown"
      end
      local createStart = os.clock()
      local diagCreateStart = diag and diag:now()
      local obj, err = createStreamedObject(item, nil, diag)
      local createMs = (os.clock() - createStart) * 1000
      if diag then diag:recordOperation("create-total", (diag:now() - diagCreateStart) * 1000, currentSectionID, key, shape, split.path, split.diagRegisterMs, "whole streamed-create elapsed; API time is nested registerObject only for new objects; remainder is not pure Lua CPU") end
      if createMs >= TUNING.stallLogMs then
        logMsg("W", "slow create: %s %.0f ms (%s), section %s", shape and shortShapeName(shape) or "?", createMs,
          isFirst and ("first use, " .. firstKind) or (isWarm and "warm" or "reload"), tostring(currentSectionID))
      end
      timing.creates, timing.createMs = timing.creates + 1, timing.createMs + createMs
      change.creates, change.createMs = change.creates + 1, change.createMs + createMs
      if createMs > timing.createMax then timing.createMax = createMs end
      if createMs > change.maxMs then change.maxMs = createMs end
      if shape then
        local cost = change.shapes[shape]
        if not cost then cost = { n = 0, ms = 0, max = 0, first = 0, reload = 0 }; change.shapes[shape] = cost end
        cost.n, cost.ms = cost.n + 1, cost.ms + createMs
        if createMs > cost.max then cost.max = createMs end
        if isFirst then
          seenShapes[shape] = true
          firstUse = firstUse + 1
          cost.first = cost.first + 1
          recentFirstMs = recentFirstMs and (recentFirstMs * 0.7 + createMs * 0.3) or createMs
          timing.firsts, timing.firstMs = timing.firsts + 1, timing.firstMs + createMs
          change.firsts, change.firstMs = change.firsts + 1, change.firstMs + createMs
          if firstKind == "import" then change.importN, change.importMs = change.importN + 1, change.importMs + createMs
          elseif firstKind == "cached" then change.hitN, change.hitMs = change.hitN + 1, change.hitMs + createMs
          else change.unkN, change.unkMs = change.unkN + 1, change.unkMs + createMs end
        else
          timing.repeats, timing.repeatMs = timing.repeats + 1, timing.repeatMs + createMs
          change.repeats, change.repeatMs = change.repeats + 1, change.repeatMs + createMs
          if isWarm then
            local p = item.position
            if camPos and p and p[1] and p[2] then
              local d = math.sqrt((p[1] - camPos.x) ^ 2 + (p[2] - camPos.y) ^ 2)
              local bucket = change.dist[d < 100 and 1 or (d < 300 and 2 or 3)]
              bucket.n, bucket.ms = bucket.n + 1, bucket.ms + createMs
            end
            change.warms, change.warmMs = change.warms + 1, change.warmMs + createMs
          else
            cost.reload = cost.reload + 1
            change.reloads, change.reloadMs = change.reloads + 1, change.reloadMs + createMs
          end
        end
      end
      createdSinceChange = createdSinceChange + 1
      if resident then
        if cheap then cheapMade = cheapMade + 1 else costlyMade = costlyMade + 1 end
      end
      if obj then
        local pr = run.paths[split.path]
        if pr then
          pr.n, pr.ms = pr.n + 1, pr.ms + createMs
          if createMs > pr.max then pr.max = createMs end
        end
        change.objectMs, change.fieldsMs = change.objectMs + split.objectMs, change.fieldsMs + split.fieldsMs
        change.registerMs, change.groupMs = change.registerMs + split.registerMs, change.groupMs + split.groupMs
        change.nameMs = change.nameMs + split.nameMs
        local live, reg = split.live, split.registerMs
        change.liveSum = change.liveSum + live
        if not change.liveMin or live < change.liveMin then change.liveMin = live end
        if live > change.liveMax then change.liveMax = live end
        change.rn, change.rx, change.ry = change.rn + 1, change.rx + live, change.ry + reg
        change.rxx, change.rxy = change.rxx + live * live, change.rxy + live * reg
        registerLive(key, obj, item)
        createdTotal = createdTotal + 1
        verifyReadback(key, item, obj)
        notify("onObjectCreated", key, obj, item)
      else
        recordFailure(string.format("create %s failed: %s", tostring(item.name), tostring(err)))
      end
      made = made + 1
      if (os.clock() - started) * 1000 >= budget then break end
    end
  end
  if lqHead > lqTail then loadQueue, lqHead, lqTail = {}, 1, 0 end
  if pqHead > pqTail then priQueue, pqHead, pqTail = {}, 1, 0 end
  createdLastFrame = made
  if made > createdPeakFrame then createdPeakFrame = made end
  timing.frameLast = (os.clock() - started) * 1000
  if timing.frameLast > timing.framePeak then timing.framePeak = timing.frameLast end
  return made, skipped
end

local function processUnloads(diag)
  local started = os.clock()
  local limit = fb.cap(TUNING.deleteBudgetShare)
  local removed = 0
  while uqHead <= uqTail and removed < TUNING.maxDeletesPerFrame do
    local entry = unloadQueue[uqHead]
    local key = entry.key
    if pendingUnload[key] ~= entry.stamp then
      unloadQueue[uqHead] = nil; uqHead = uqHead + 1          -- cancelled or rescheduled
    elseif not live[key] then
      pendingUnload[key] = nil
      unloadQueue[uqHead] = nil; uqHead = uqHead + 1
    elseif totalTime - entry.stamp >= (residentMode() and TUNING.residentCooldown or TUNING.unloadCooldown) then
      pendingUnload[key] = nil
      unloadQueue[uqHead] = nil; uqHead = uqHead + 1
      local deleteStart = diag and diag:now()
      deleteLive(key, diag)
      if diag then diag:recordOperation("delete-live-total", (diag:now() - deleteStart) * 1000, currentSectionID, key, nil, "unload", nil, "deleteLive bookkeeping plus deactivation/delete elapsed") end
      removed = removed + 1
      if (os.clock() - started) * 1000 >= limit then break end
    else
      break                                                     -- FIFO by time: the rest are newer
    end
  end
  if uqHead > uqTail then unloadQueue, uqHead, uqTail = {}, 1, 0 end
  frameDeleteMs = (os.clock() - started) * 1000
  change.deleted, change.deleteMs = change.deleted + removed, change.deleteMs + frameDeleteMs
  return removed
end

-- ---------------------------------------------------------------------------
-- Section residency
-- ---------------------------------------------------------------------------
local function setCurrentSection(newID)
  local oldID, oldActive = currentSectionID, activeSet
  currentSectionID = newID
  activeSet = computeActive(newID)

  for id in pairs(oldActive) do
    if not activeSet[id] then
      sectionRead[id], sectionReading[id] = nil, nil
      releasePending(id)
      local bucket = liveBySection[id]
      if bucket then
        for key in pairs(bucket) do
          if not anyActive(live[key].sections) then scheduleUnload(key) end
        end
      end
    end
  end
  for id in pairs(activeSet) do
    if not oldActive[id] then
      local bucket = liveBySection[id]
      if bucket then
        for key in pairs(bucket) do pendingUnload[key] = nil end   -- came back within the cooldown
      end
    end
  end
  if not settled and oldID ~= nil then                             -- the camera left before the last change finished loading
    local waiting = (pqTail - pqHead + 1) + (lqTail - lqHead + 1)
    local reads = srTail - srHead + 1
    droppedSections = droppedSections + 1
    droppedObjects = droppedObjects + waiting + pendingCount
    droppedLast = { section = oldID, after = totalTime - changeStamp, created = createdSinceChange,
                    queued = waiting, waiting = pendingCount, reads = reads, to = newID }
    logMsg("W", "dropped section %s: left after %.2f s with %d objects created, %d queued and %d waiting records not loaded (%d section reads pending), going to %s",
      tostring(oldID), totalTime - changeStamp, createdSinceChange, waiting, pendingCount, reads, tostring(newID))
  end
  local promoted = purgeQueue()                                    -- nothing stale waits behind new work
  if promoted and promoted > 0 and TUNING.logSettle then
    logMsg("I", "section %s: %d queued objects of this section moved ahead of the leftovers", tostring(newID), promoted)
  end
  changeStamp, createdSinceChange, settled = totalTime, 0, (newID == nil)
  change = newChange()
  priorityTimer = 0
  rebuildFeedOrder()
  for i = 1, #feedOrder do queueSectionRead(feedOrder[i]) end      -- current section first
  hook("onNfscSectionChanged", newID, oldID)
end

local function sectionAt(p)
  if currentSectionID and isInSection(p, currentSectionID) then return currentSectionID end
  return findSection(p)
end

-- Tracks the camera velocity and picks the section to stream for: the one under the camera, or,
-- once it has been stable for predictionStableTime, the one the camera is about to enter.
local function updateCamera(dt)
  local cam = core_camera and core_camera.getPosition and core_camera.getPosition()
  if not cam then return end
  selectTimer = selectTimer + dt
  local interval = currentSectionID and TUNING.selectionInterval or TUNING.noSectionLookupInterval
  if selectTimer < interval then return end
  local step = math.min(selectTimer, 1.0)
  selectTimer = 0

  local vx, vy = 0, 0
  if camPos then vx, vy = (cam.x - camPos.x) / step, (cam.y - camPos.y) / step end
  camPos = camPos or { x = 0, y = 0 }
  camPos.x, camPos.y = cam.x, cam.y
  if math.sqrt(vx * vx + vy * vy) > TUNING.predictionMaxSpeed then
    camVel.x, camVel.y = 0, 0                                      -- a jump, not driving
  else
    camVel.x, camVel.y = camVel.x * 0.5 + vx * 0.5, camVel.y * 0.5 + vy * 0.5
  end

  scratch.x, scratch.y = cam.x, cam.y
  local actual = sectionAt(scratch)
  local desired = actual
  predictedSectionID = nil
  local speed = math.sqrt(camVel.x * camVel.x + camVel.y * camVel.y)
  if TUNING.predictionEnabled and speed >= TUNING.predictionMinSpeed then
    local reach = math.min(TUNING.predictionSeconds, TUNING.predictionMaxDistance / speed)
    aheadPoint.x, aheadPoint.y = cam.x + camVel.x * reach, cam.y + camVel.y * reach
    predictedSectionID = sectionAt(aheadPoint)
  end
  if predictedSectionID and predictedSectionID ~= actual then
    if aheadCandidate == predictedSectionID then
      aheadTime = aheadTime + step
    else
      aheadCandidate, aheadTime = predictedSectionID, 0
    end
    if aheadTime >= TUNING.predictionStableTime then desired = predictedSectionID end
  else
    aheadCandidate, aheadTime = nil, 0
  end
  local cameraMoved = cameraSectionID ~= actual
  cameraSectionID = actual
  if desired ~= currentSectionID then
    setCurrentSection(desired)
  elseif cameraMoved then
    purgeQueue()                                                   -- the camera crossed into the section streamed ahead
  end
end

-- ---------------------------------------------------------------------------
-- Shape cache warm-up (idle lane, see header)
-- ---------------------------------------------------------------------------
local function newWarm()
  return { loaded = false, names = {}, bySection = {}, total = 0, done = {}, processed = 0,
           near = {}, nearPos = 1, nearFor = false, cursor = 1, idle = 0, gap = 0,
           hadCdae = 0, imported = 0, failed = 0, skipped = 0, importMs = 0, importMax = 0, importMaxShape = nil,
           current = nil, finished = false }
end
local warm = newWarm()

local function loadShapeList()
  warm = newWarm()
  local data = jsonReadFile(levelRoot .. "/" .. SHAPES_JSON)
  if type(data) ~= "table" or type(data.shapes) ~= "table" then
    logMsg("I", "no %s: the shape cache warm-up is off (rebuild with the current builder)", SHAPES_JSON)
    return
  end
  warm.names, warm.total = data.shapes, #data.shapes
  if type(data.sections) == "table" then
    for id, list in pairs(data.sections) do
      local n = tonumber(id)
      if n and type(list) == "table" then warm.bySection[n] = list end
    end
  end
  warm.loaded = warm.total > 0
end

-- shapes of the current section and its related sections, in loading order, not done yet
local function warmRefreshNear()
  warm.near, warm.nearPos, warm.nearFor = {}, 1, currentSectionID
  local seen = {}
  for i = 1, #feedOrder do
    local list = warm.bySection[feedOrder[i]]
    if list then
      for j = 1, #list do
        local idx = list[j]
        if not seen[idx] and warm.done[idx] == nil then
          seen[idx] = true
          warm.near[#warm.near + 1] = idx
        end
      end
    end
  end
end

local function warmNextCandidate()
  while warm.nearPos <= #warm.near do
    local idx = warm.near[warm.nearPos]
    warm.nearPos = warm.nearPos + 1
    if warm.done[idx] == nil then return idx end
  end
  while warm.cursor <= warm.total do
    local idx = warm.cursor
    warm.cursor = warm.cursor + 1
    if warm.done[idx] == nil then return idx end
  end
  return nil
end

local function warmMark(idx, value)
  warm.done[idx] = value
  warm.processed = warm.processed + 1
end

-- Creates one hidden TSStatic of the shape below the camera and deletes it in the same call: the engine
-- imports the COLLADA and writes the .cdae, nothing is drawn and nothing stays in memory.
local function warmImport(idx, name, diag)
  warm.current = name
  local diagStarted = diag and diag:now()
  local started = os.clock()
  local cam = core_camera and core_camera.getPosition and core_camera.getPosition()
  local pos = cam and string.format("%.3f %.3f %.3f", cam.x, cam.y, cam.z - 800) or "0 0 -800"
  local ok = false
  local obj = createObject("TSStatic")
  if obj then
    pcall(function() obj.hidden = true end)
    pcall(obj.setField, obj, "shapeName", 0, name)
    pcall(obj.setField, obj, "position", 0, pos)
    pcall(obj.setField, obj, "collisionType", 0, "None")
    pcall(obj.setField, obj, "decalType", 0, "None")
    local registerStart = diag and diag:now()
    local okc, res = pcall(obj.registerObject, obj, "")
    if diag then local ms = (diag:now() - registerStart) * 1000; diag:recordOperation("cache-warm-registerObject", ms, currentSectionID, name, name, "cache-warm", ms, "registerObject API elapsed inside cache warm import") end
    ok = okc and res ~= false
    pcall(obj.delete, obj)
  end
  local ms = (os.clock() - started) * 1000
  if diag then diag:recordOperation("cache-warm-total", (diag:now() - diagStarted) * 1000, currentSectionID, name, name, "cache-warm-fresh", nil, "whole hidden import lifecycle; includes create, fields, register and delete") end
  if ok then
    warmMark(idx, true)
    warm.imported = warm.imported + 1
    warm.importMs = warm.importMs + ms
    if ms > warm.importMax then warm.importMax, warm.importMaxShape = ms, name end
    if TUNING.cacheWarmLogEvery > 0 and warm.imported % TUNING.cacheWarmLogEvery == 0 then
      logMsg("I", "cache warm: %d of %d shapes done (%d already had a .cdae, %d imported now, %d failed), import avg %.1f ms, max %.0f ms (%s)",
        warm.processed, warm.total, warm.hadCdae, warm.imported, warm.failed, warm.importMs / warm.imported,
        warm.importMax, shortShapeName(warm.importMaxShape or "?"))
    end
  else
    warmMark(idx, false)
    warm.failed = warm.failed + 1
    if warm.failed <= 10 then logMsg("W", "cache warm: %s could not be created", shortShapeName(name)) end
  end
  if ms >= TUNING.stallLogMs then logMsg("W", "slow cache warm import: %s %.0f ms", shortShapeName(name), ms) end
end

local function cacheWarmUpdate(dt, diag)
  if not TUNING.cacheWarm or TUNING.warmAll or not warm.loaded or warm.finished or suspended or not initialized then return end
  if not M.isIdle() then warm.idle = 0; return end                -- the section streamer has work: it goes first
  warm.idle = warm.idle + dt
  if warm.idle < TUNING.cacheWarmIdleSeconds then return end
  if warm.gap > 0 then
    warm.gap = warm.gap - dt
    if warm.gap > 0 then return end
  end
  local checkMs = fb.cap(TUNING.cacheWarmCheckShare)
  if checkMs <= 0 then return end                                 -- the frame is already spent
  if warm.nearFor ~= currentSectionID then warmRefreshNear() end
  local imports, mark = 0, os.clock()
  while imports < math.max(1, TUNING.cacheWarmPerFrame) do
    if imports > 0 and fb.remaining() <= 0 then break end     -- an import is a stall of its own: no second one in a spent frame
    local idx = warmNextCandidate()
    if not idx then
      warm.finished, warm.current = true, nil
      logMsg("I", "cache warm finished: %d shapes (%d already had a .cdae, %d imported now, %d failed, %d skipped), import avg %.1f ms",
        warm.total, warm.hadCdae, warm.imported, warm.failed, warm.skipped,
        warm.imported > 0 and warm.importMs / warm.imported or 0)
      return
    end
    local name = warm.names[idx]
    local cached
    if seenShapes[name] or shapeLive[name] then cached = true else cached = shapeCached(name) end
    if cached == nil then
      if fsUnavailable then
        warm.loaded = false
        logMsg("W", "cache warm is off: FS:fileExists is not available here")
        return
      end
      warmMark(idx, false)                                        -- not a .dae shape: nothing to cache
      warm.skipped = warm.skipped + 1
    elseif cached then
      warmMark(idx, true)
      warm.hadCdae = warm.hadCdae + 1
    else
      warmImport(idx, name, diag)
      imports = imports + 1
      warm.gap = TUNING.cacheWarmGapSeconds
      mark = os.clock()
    end
    if (os.clock() - mark) * 1000 >= checkMs then break end       -- the time cap is for the skipping
  end
end

-- ---------------------------------------------------------------------------
-- Everything is warm: one hidden holder object per shape
-- ---------------------------------------------------------------------------
function hold.reset()
  hold.shape, hold.ids, hold.held, hold.cursor, hold.failed = {}, {}, 0, 1, 0
  hold.ms, hold.max, hold.maxShape, hold.group, hold.idle, hold.seconds, hold.complete = 0, 0, nil, nil, 0, 0, false
end

function hold.ensureGroup()
  if hold.group then return hold.group end
  local g = scenetree.findObject(TUNING.warmGroupName)
  if not g then
    g = createObject("SimGroup")
    if not g then return nil end
    g:registerObject(TUNING.warmGroupName)
    local mission = scenetree.findObject("MissionGroup")
    if mission then mission:addObject(g) end
  end
  hold.group = g
  return g
end

-- Creates the holder of one shape: hidden, no collision, below the camera. Returns true when the engine took it.
function hold.add(name)
  local group = hold.ensureGroup()
  if not group then return false end
  local cam = core_camera and core_camera.getPosition and core_camera.getPosition()
  local pos = cam and string.format("%.3f %.3f %.3f", cam.x, cam.y, cam.z - 800) or "0 0 -800"
  local started = os.clock()
  local ok = false
  local obj = createObject("TSStatic")
  if obj then
    pcall(function() obj.hidden = true end)
    pcall(obj.setField, obj, "shapeName", 0, name)
    pcall(obj.setField, obj, "position", 0, pos)
    pcall(obj.setField, obj, "collisionType", 0, "None")
    pcall(obj.setField, obj, "decalType", 0, "None")
    local okc, res = pcall(obj.registerObject, obj, "")
    ok = okc and res ~= false
    if ok then
      pcall(group.addObject, group, obj)
      hold.ids[name], hold.shape[name] = obj:getID(), true
      hold.held = hold.held + 1
    else
      pcall(obj.delete, obj)
    end
  end
  local ms = (os.clock() - started) * 1000
  if ok then
    hold.ms = hold.ms + ms
    if ms > hold.max then hold.max, hold.maxShape = ms, name end
    if TUNING.warmAllLogEvery > 0 and hold.held % TUNING.warmAllLogEvery == 0 then
      logMsg("I", "everything warm: %d of %d meshes held (%d failed), avg %.2f ms, max %.0f ms (%s)",
        hold.held, warm.total, hold.failed, hold.ms / hold.held, hold.max, shortShapeName(hold.maxShape or "?"))
    end
  else
    hold.failed = hold.failed + 1
    if hold.failed <= 10 then logMsg("W", "everything warm: %s could not be held", shortShapeName(name)) end
  end
  if ms >= TUNING.stallLogMs then logMsg("W", "slow mesh hold: %s %.0f ms", shortShapeName(name), ms) end
  return ok
end

-- Deletes the holders (a batch per call). Returns true when all are gone and the group too.
function hold.release(batch)
  local n = 0
  for name, id in pairs(hold.ids) do
    local obj = scenetree.findObjectById(id)
    if obj then pcall(obj.delete, obj) end
    hold.ids[name], hold.shape[name] = nil, nil
    hold.held = hold.held - 1
    n = n + 1
    if n >= batch then return false end
  end
  local g = scenetree.findObject(TUNING.warmGroupName)
  if g then pcall(g.delete, g) end
  logMsg("I", "everything warm: meshes released")
  hold.reset()
  return true
end

-- The lane, once per frame. Returns how many meshes it held.
function hold.update(dt)
  if not TUNING.warmAll then
    if hold.held > 0 or hold.group then hold.release(512) end
    return 0
  end
  if suspended or not initialized or warm.total <= 0 or hold.complete then return 0 end
  hold.seconds = hold.seconds + dt
  if not M.isIdle() then hold.idle = 0; return 0 end             -- the section streamer goes first
  hold.idle = hold.idle + dt
  if hold.idle < TUNING.cacheWarmIdleSeconds then return 0 end
  local limit = fb.cap(TUNING.warmAllBudgetShare)
  if limit <= 0 then return 0 end
  local started, made = os.clock(), 0
  while made < TUNING.warmAllPerFrame do
    if made > 0 and (os.clock() - started) * 1000 >= limit then break end
    local idx = hold.cursor
    if idx > warm.total then
      hold.complete = true
      logMsg("I", "everything warm: all %d meshes held (%d failed), avg %.2f ms per mesh, %.0f s", hold.held, hold.failed,
        hold.held > 0 and hold.ms / hold.held or 0, hold.seconds)
      break
    end
    hold.cursor = idx + 1
    local name = warm.names[idx]
    if name and not hold.shape[name] then
      hold.add(name)
      made = made + 1
    end
  end
  return made
end

-- ---------------------------------------------------------------------------
-- State reset
-- ---------------------------------------------------------------------------
-- The pool, resting and dropped-section state. Its own function: LuaJIT allows 60 upvalues per function and
-- resetState is already near that.
local function resetPoolState()
  shellFree, shellFreeN, shellFields = {}, 0, {}
  shellChecked, shellDisabled, shellBuildFails, shellBuildOff = false, false, 0, false
  dormant, dormantOrder, doHead, doTail, dormantCount = {}, {}, 1, 0, 0
  dormantByShape = {}
  droppedSections, droppedObjects, droppedLast = 0, 0, nil
  for k in pairs(shellStats) do shellStats[k] = 0 end
  run = newRun(totalTime)
end

-- Drops every job and the section selection: queues, pending lists, held-back items, section reads, unloads.
-- Nothing that was queued can create an object afterwards; the next frame looks the camera's section up again.
local function clearWork()
  currentSectionID, activeSet = nil, {}
  sectionRead, sectionReading = {}, {}
  sectionReadQueue, srHead, srTail = {}, 1, 0
  loadQueue, lqHead, lqTail, queuedKeys = {}, 1, 0, {}
  priQueue, pqHead, pqTail, promotedTotal = {}, 1, 0, 0
  pending, pendingCount, deferred = {}, 0, {}
  pendingUnload, unloadQueue, uqHead, uqTail = {}, {}, 1, 0
  selectTimer = 1e9                                                -- look up at once after a reset
  cameraSectionID, predictedSectionID, aheadCandidate, aheadTime = nil, nil, nil, 0
  feedOrder, priorityTimer = {}, 0
end

local function resetState()
  clearWork()
  staleDiscarded, queueHighWater, createdLastFrame, createdPeakFrame = 0, 0, 0, 0
  live, liveBySection, liveCount = {}, {}, 0
  camPos, camVel.x, camVel.y = nil, 0, 0
  for k in pairs(timing) do timing[k] = 0 end
  seenShapes, shapeLive, recentFirstMs, idleFrameMs = {}, {}, nil, nil
  change, frameDeleteMs = newChange(), 0
  for k in pairs(fb.ms) do fb.ms[k], fb.avg[k] = 0, 0 end
  changeStamp, createdSinceChange, settled, settleSeconds, settlePeak = 0, 0, true, 0, 0
  resetPoolState()                                             -- the runtime group (and its shells) was deleted before this
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------
function M.initialize(basePath)
  notify("onStreamerReset")
  destroyRuntimeGroup()
  while not hold.release(100000) do end                        -- a fresh start also drops the held meshes
  resetState()
  initialized = false
  levelRoot = ((basePath or TUNING.levelRoot):gsub("/+$", ""))
  local ok, err = pcall(function()
    loadSections()
    loadStreamIndex()
    ensureRuntimeGroup()
  end)
  if not ok then
    recordFailure("initialize failed: " .. tostring(err))
    return false, tostring(err)
  end
  initialized = true
  if readPresets().startup then M.loadPreset("startup") end
  local okShapes, errShapes = pcall(loadShapeList)
  if not okShapes then warm = newWarm(); logMsg("W", "shapes.json could not be read: %s", tostring(errShapes)) end
  logMsg("I", "initialized: %d sections, %d with streamed objects", #sectionOrder, (function()
    local n = 0
    for _ in pairs(sectionIndex) do n = n + 1 end
    return n
  end)())
  hook("onNfscStreamerInitialized")
  return true
end

-- Deletes every streamed object and starts again from the current camera position.
function M.reset()
  notify("onStreamerReset")
  destroyRuntimeGroup()
  resetState()
  if initialized then ensureRuntimeGroup() end
end

-- Counters and timings back to zero (tuning, pool contents and live objects are not touched), so a measurement starts clean.
function M.resetStats()
  staleDiscarded, queueHighWater, createdLastFrame, createdPeakFrame, promotedTotal = 0, 0, 0, 0, 0
  for k in pairs(timing) do timing[k] = 0 end
  change, frameDeleteMs = newChange(), 0
  for k in pairs(fb.ms) do fb.ms[k], fb.avg[k] = 0, 0 end
  changeStamp, createdSinceChange, settled, settleSeconds, settlePeak = totalTime, 0, true, 0, 0
  createdTotal, deletedTotal, failureCount, failures = 0, 0, 0, {}
  droppedSections, droppedObjects, droppedLast = 0, 0, nil
  for k in pairs(shellStats) do shellStats[k] = 0 end
  shellStats.peakLive = liveCount
  run = newRun(totalTime)
  if M.stallDiagnostics then M.resetDiagnostics() end
  logMsg("I", "statistics reset (tuning and pool unchanged)")
end

-- Objects in the runtime group according to the engine, nil when the engine gives no way to count them.
local function sceneCount()
  local g = runtimeGroup
  if not g then return 0 end
  local ok, n = pcall(function() return g:size() end)
  if ok and type(n) == "number" then return n end
  ok, n = pcall(function() return #g:getObjects() end)
  if ok and type(n) == "number" then return n end
  return nil
end

-- Empties the scene for a repeatable measurement (camera track, empty canvas):
--   1. every queued job is cancelled first (load queues, pending lists, held-back items, section reads, unloads), so
--      nothing can create an object afterwards;
--   2. every live object is removed the way the creation mode removes one (deleted, parked or deactivated);
--   3. releasePool = true also deletes the parked shells and the deactivated (resident) objects;
--   4. the section selection is cleared, so streaming starts from nothing at the camera's position, as after a level
--      load; hold = true keeps it suspended until M.setSuspended(false) (move the camera, then resume);
--   5. statistics are reset unless keepStats = true.
-- Returns a report: what was cancelled and removed, and the result of a bookkeeping and scene check.
function M.purge(opts)
  opts = opts or {}
  if not initialized then return nil, "streamer not initialized" end
  local started = os.clock()
  local before = {
    live = liveCount, queued = math.max(0, lqTail - lqHead + 1) + math.max(0, pqTail - pqHead + 1), pending = pendingCount,
    reads = math.max(0, srTail - srHead + 1), unloads = math.max(0, uqTail - uqHead + 1),
    dormant = dormantCount, shellsFree = shellFreeN, deferred = 0,
  }
  for _, list in pairs(deferred) do before.deferred = before.deferred + #list end
  clearWork()                                                      -- 1. cancel everything that is waiting
  local keys = {}
  for key in pairs(live) do keys[#keys + 1] = key end
  for i = 1, #keys do deleteLive(keys[i]) end                      -- 2. one pass over the live objects
  local released = { dormant = 0, shells = 0 }
  if opts.releasePool then                                         -- 3.
    released.dormant = releaseDormant(true)
    released.shells = M.clearShellPool()
  end
  if not opts.keepStats then M.resetStats() end                    -- 5.
  suspended = opts.hold and true or false                          -- 4.
  local report = {
    cancelled = before, removedLive = #keys, released = released, mode = TUNING.creationMode,
    poolAfter = { dormant = dormantCount, shellsFree = shellFreeN }, held = suspended, ms = (os.clock() - started) * 1000,
    problems = {},
  }
  local problems = report.problems                                 -- verification: bookkeeping, then the engine's scene
  local function check(ok, what) if not ok then problems[#problems + 1] = what end end
  check(liveCount == 0 and next(live) == nil, "live table not empty")
  check(next(liveBySection) == nil or (function() for _, b in pairs(liveBySection) do if next(b) then return false end end return true end)(), "per-section live lists not empty")
  check(lqHead > lqTail and pqHead > pqTail, "load queues not empty")
  check(pendingCount == 0 and next(pending) == nil and next(deferred) == nil, "pending or held-back items remain")
  check(srHead > srTail and next(sectionReading) == nil, "section reads remain")
  check(next(pendingUnload) == nil and uqHead > uqTail and next(queuedKeys) == nil, "unload or queue-key bookkeeping not empty")
  check(next(activeSet) == nil and currentSectionID == nil, "section selection not cleared")
  if opts.releasePool then check(dormantCount == 0 and shellFreeN == 0, "pool not empty after release") end
  report.sceneObjects = sceneCount()
  report.sceneExpected = dormantCount + shellFreeN
  if report.sceneObjects and report.sceneObjects ~= report.sceneExpected then
    problems[#problems + 1] = string.format("runtime group holds %d objects, bookkeeping expects %d (pool)", report.sceneObjects, report.sceneExpected)
  end
  report.ok = #problems == 0
  logMsg(report.ok and "I" or "W", "purge (%s%s): cancelled %d queued, %d pending, %d held back, %d section reads, %d unloads; removed %d live objects%s in %.0f ms; pool now %d deactivated + %d free; scene %s; %s%s",
    report.mode, opts.releasePool and ", pool released" or "", before.queued, before.pending, before.deferred, before.reads, before.unloads,
    report.removedLive, opts.releasePool and string.format(" and released %d deactivated + %d parked", released.dormant, released.shells) or "", report.ms,
    dormantCount, shellFreeN, report.sceneObjects and tostring(report.sceneObjects) .. " objects" or "count n/a",
    report.ok and "verified clear" or "CHECK FAILED: " .. table.concat(problems, "; "), suspended and "; streaming held" or "")
  tun.state.purge = report
  return report
end

-- fn(item) -> false holds an object back (see header). Pass nil to create everything again.
function M.setCreateFilter(fn)
  createFilter = fn
  if initialized then M.refreshFilter() end
end

-- Re-evaluates held-back items of the active sections; those the filter now accepts are queued.
function M.refreshFilter()
  for id, list in pairs(deferred) do
    if activeSet[id] then
      local keep, accepted = {}, {}
      for i = 1, #list do
        local item = list[i]
        if createFilter and not createFilter(item) then
          keep[#keep + 1] = item
        elseif live[item.__streamKey] then
          pendingUnload[item.__streamKey] = nil                    -- still alive: cancel its unload
        else
          accepted[#accepted + 1] = item
        end
      end
      deferred[id] = #keep > 0 and keep or nil
      if #accepted > 0 then addPending(id, accepted) end
    end
  end
end

-- Deletes a live object (after the unload cooldown) and holds the item back for its active sections.
function M.releaseObject(key, item)
  if live[key] then scheduleUnload(key) end
  if item then
    local ids = itemSections(item)
    for i = 1, #ids do
      if activeSet[ids[i]] then deferItem(ids[i], item) end
    end
  end
end

-- "current": create and delete every object. "shells": recycle parked shells. "resident": shells plus a resting
-- state (see header). Switching to "current" deletes the pool; leaving "resident" parks (or deletes) the
-- deactivated objects; objects already live are handled the way the new mode handles them.
function M.setCreationMode(mode)
  if mode ~= "current" and mode ~= "shells" and mode ~= "resident" then return false, "unknown creation mode: " .. tostring(mode) end
  if mode ~= "current" and shellShapeMissing() then
    recordFailure("shell pool not started: shellShape not found: " .. tostring(TUNING.shellShape))
    return false, "shellShape not found"
  end
  local old = TUNING.creationMode
  TUNING.creationMode = mode
  shellChecked, shellDisabled, shellBuildFails, shellBuildOff = false, false, 0, false
  if old == "resident" and mode ~= "resident" then releaseDormant(mode == "current") end
  if mode == "current" then M.clearShellPool() end
  logMsg("I", "creation mode: %s", mode)
  return true
end

function M.getCreationMode() return TUNING.creationMode end

-- Deletes every parked shell; returns how many.
function M.clearShellPool()
  local n = 0
  for i = shellFreeN, 1, -1 do
    local id = shellFree[i]
    local obj = scenetree.findObjectById(id)
    if obj then pcall(obj.delete, obj) end
    shellFields[id] = nil
    shellFree[i] = nil
    n = n + 1
  end
  shellFreeN = 0
  return n
end

-- Builds n parked shells at once (for tests and loading screens); returns how many were built.
function M.buildShells(n)
  local built = 0
  local started = os.clock()
  for _ = 1, n or 0 do
    local ok, err = buildShell()
    if not ok then recordFailure("buildShells stopped: " .. tostring(err)); break end
    built = built + 1
  end
  shellStats.buildMs = shellStats.buildMs + (os.clock() - started) * 1000
  return built
end

function M.setSuspended(flag) suspended = flag and true or false end
function M.isSuspended() return suspended end

-- A copy of the current tuning values (for the console: dump(extensions.nfsc_sectionStreamer.getTuning())).
function M.getTuning()
  local copy = {}
  for k, v in pairs(TUNING) do copy[k] = v end
  return copy
end

-- Live tuning ---------------------------------------------------------------------------------------------
local function presetPath() return levelRoot .. "/" .. PRESETS_JSON end

readPresets = function()
  local ok, data = pcall(jsonReadFile, presetPath())
  return (ok and type(data) == "table") and data or {}
end

local NOT_TUNABLE = { levelRoot = true, runtimeGroupName = true, warmGroupName = true }

local function tunableValues()
  local out = {}
  for k, v in pairs(TUNING) do
    local t = type(v)
    if not NOT_TUNABLE[k] and (t == "number" or t == "boolean" or k == "creationMode" or k == "shellShape") then out[k] = v end
  end
  return out
end

function M.getDefaultTuning()
  local copy = {}
  for k, v in pairs(TUNING_DEFAULTS) do copy[k] = v end
  return copy
end

-- The panel builds itself from this (read only).
function M.getTuningSchema() return tun.schema end
function M.getCreationModes() return { "current", "shells", "resident" } end

function tun.fmt(v)
  if type(v) == "number" then return string.format("%.4g", v) end
  return tostring(v)
end

-- Presets saved before the budgets became shares of the frame: ms -> share of the frame budget they were saved with.
function tun.migrate(values)
  local out = {}
  for k, v in pairs(values or {}) do out[k] = v end
  local main = type(out.frameBudgetMs) == "number" and out.frameBudgetMs or TUNING.frameBudgetMs
  for old, new in pairs({ shellBuildBudgetMs = "shellBuildBudgetShare", cacheWarmCheckMs = "cacheWarmCheckShare" }) do
    local ms = out[old]
    out[old] = nil
    if ms ~= nil and out[new] == nil and type(ms) == "number" and main > 0 then out[new] = ms / main end
  end
  return out
end

-- Applies values with checks: unknown keys and wrong types are rejected, numbers are held to the hard limits of
-- their schema row (integers rounded), creationMode goes through setCreationMode. Returns the list of changes
-- { key, old, new } and the list of rejections { key, why }; both are remembered for the panel.
function tun.apply(values, source)
  local data = tun.migrate(values)
  local keys = {}
  for k in pairs(data) do keys[#keys + 1] = k end
  table.sort(keys)
  local changed, rejected, mode = {}, {}, nil
  for _, k in ipairs(keys) do
    local v, want, row = data[k], TUNING_DEFAULTS[k], tun.byKey[k]
    if want == nil or NOT_TUNABLE[k] then
      rejected[#rejected + 1] = { key = k, why = "unknown setting" }
    elseif type(v) ~= type(want) then
      rejected[#rejected + 1] = { key = k, why = "expected " .. type(want) }
    elseif type(v) == "number" and (v ~= v or v == math.huge or v == -math.huge) then
      rejected[#rejected + 1] = { key = k, why = "not a finite number" }
    elseif k == "creationMode" then
      mode = v
    else
      if type(v) == "number" then
        local lo, hi = 0, nil
        if row then
          lo = row.lo or 0
          hi = row.hi or (row.kind == "share" and 1 or nil)
          if row.kind == "int" then v = math.floor(v + 0.5) end
        end
        if v < lo then v = lo end
        if hi and v > hi then v = hi end
      end
      local old = TUNING[k]
      if old ~= v then
        TUNING[k] = v
        changed[#changed + 1] = { key = k, old = old, new = v }
      end
    end
  end
  if mode and mode ~= TUNING.creationMode then
    local old = TUNING.creationMode
    local ok, err = M.setCreationMode(mode)
    if ok then changed[#changed + 1] = { key = "creationMode", old = old, new = mode }
    else rejected[#rejected + 1] = { key = "creationMode", why = tostring(err) } end
  end
  if #changed > 0 then tun.state.revision = tun.state.revision + 1 end
  if #changed > 0 or #rejected > 0 or source:find("^preset") or source == "reset" then
    local now = os.clock()
    tun.state.last = { source = source, time = now, changed = changed, rejected = rejected, revision = tun.state.revision }
    for _, c in ipairs(changed) do
      local log = tun.state.log
      log[#log + 1] = { time = now, source = source, key = c.key, old = c.old, new = c.new }
      if #log > 16 then table.remove(log, 1) end
    end
  end
  if M.stallDiagnostics then M.stallDiagnostics:setEnabled(TUNING.testingMode) end
  return changed, rejected
end

-- Values to apply from the console or code. quiet = true (the panel) skips the log lines: the panel shows the change itself.
-- Returns the list of changes and the list of rejections.
function M.setTuning(values, quiet)
  local changed, rejected = tun.apply(values or {}, quiet and "panel" or "setTuning")
  if not quiet then
    for _, c in ipairs(changed) do logMsg("I", "tuning: %s %s -> %s", c.key, tun.fmt(c.old), tun.fmt(c.new)) end
    for _, r in ipairs(rejected) do logMsg("W", "tuning: %s not applied (%s)", r.key, r.why) end
  end
  return changed, rejected
end

-- Revision (counts every real change), the last change and the recent changes, for the panel or the console.
function M.getTuningInfo()
  local recent = {}
  for i, e in ipairs(tun.state.log) do recent[i] = e end
  return { revision = tun.state.revision, last = tun.state.last, recent = recent, now = os.clock() }
end

function tun.defaults()
  local out = {}
  for k, v in pairs(TUNING_DEFAULTS) do if not NOT_TUNABLE[k] then out[k] = v end end
  return out
end

function M.resetTuning()
  local changed = tun.apply(tun.defaults(), "reset")
  logMsg("I", "tuning reset to the defaults (%d values changed)", #changed)
  return #changed
end

function M.listPresets()
  local names = {}
  for name in pairs(readPresets()) do names[#names + 1] = name end
  table.sort(names)
  return names
end

function tun.write(presets)
  local ok, err = pcall(function() return jsonWriteFile(presetPath(), presets, true) end)
  if not ok then recordFailure("could not write the presets: " .. tostring(err)); return false, tostring(err) end
  return true
end

function M.savePreset(name)
  if type(name) ~= "string" or name == "" then return false, "no name" end
  local presets = readPresets()
  presets[name] = tunableValues()
  local ok, err = tun.write(presets)
  if not ok then return false, err end
  logMsg("I", "preset saved: %s", name)
  return true
end

function M.loadPreset(name)
  local values = readPresets()[name]
  if type(values) ~= "table" then return false, "no such preset" end
  local changed, rejected = tun.apply(values, "preset " .. tostring(name))
  logMsg("I", "preset loaded: %s (%d values changed, %d not applied)", name, #changed, #rejected)
  return true
end

function M.deletePreset(name)
  local presets = readPresets()
  if presets[name] == nil then return false, "no such preset" end
  presets[name] = nil
  return tun.write(presets)
end

-- Presets per creation mode: three slots (A, B, C) for each of current, shells and resident, stored as "<mode>/<slot>".
-- A slot nobody saved holds its factory values; a flat A/B/C from before is used for the mode it was saved in.
function tun.validSlot(mode, slot)
  if not tun.factory[mode] then return false, "unknown creation mode: " .. tostring(mode) end
  if not tun.factory[mode][slot] then return false, "unknown preset slot: " .. tostring(slot) end
  return true
end

function tun.resolve(presets, mode, slot)
  local saved = presets[mode .. "/" .. slot]
  if type(saved) == "table" then return saved, "saved" end
  local legacy = presets[slot]
  if type(legacy) == "table" and (legacy.creationMode or "current") == mode then return legacy, "saved" end
  local values = { creationMode = mode }
  for k, v in pairs(tun.factory[mode][slot].values) do values[k] = v end
  return values, "factory"
end

-- { slot, label, source = "saved" | "factory" } for the three slots of a mode.
function M.getModePresets(mode)
  local out = {}
  if not tun.factory[mode] then return out end
  local presets = readPresets()
  for _, slot in ipairs(tun.slots) do
    local _, source = tun.resolve(presets, mode, slot)
    out[#out + 1] = { slot = slot, label = tun.factory[mode][slot].label, source = source }
  end
  return out
end

function M.loadModePreset(mode, slot)
  local ok, err = tun.validSlot(mode, slot)
  if not ok then return false, err end
  local values, source = tun.resolve(readPresets(), mode, slot)
  local name = mode .. "/" .. slot
  local changed, rejected = tun.apply(values, "preset " .. name .. " (" .. source .. ")")
  logMsg("I", "preset loaded: %s (%s, %d values changed, %d not applied)", name, source, #changed, #rejected)
  return true, #changed
end

function M.saveModePreset(mode, slot)
  local ok, err = tun.validSlot(mode, slot)
  if not ok then return false, err end
  if mode ~= TUNING.creationMode then return false, "the active creation mode is " .. TUNING.creationMode end
  local presets = readPresets()
  presets[mode .. "/" .. slot] = tunableValues()
  local saved, why = tun.write(presets)
  if not saved then return false, why end
  logMsg("I", "preset saved: %s/%s", mode, slot)
  return true
end

-- Back to the factory values: removes the saved slot (and a flat A/B/C that stood in for it).
function M.deleteModePreset(mode, slot)
  local ok, err = tun.validSlot(mode, slot)
  if not ok then return false, err end
  local presets = readPresets()
  local key, removed = mode .. "/" .. slot, false
  if presets[key] ~= nil then presets[key] = nil; removed = true end
  local legacy = presets[slot]
  if type(legacy) == "table" and (legacy.creationMode or "current") == mode then presets[slot] = nil; removed = true end
  if not removed then return false, "nothing saved in this slot" end
  return tun.write(presets)
end

-- The current values as a Lua table, one line each, in the log (to paste back into TUNING).
function M.printTuning()
  local keys = {}
  for k in pairs(tunableValues()) do keys[#keys + 1] = k end
  table.sort(keys)
  logMsg("I", "TUNING values:")
  for _, k in ipairs(keys) do
    local v = TUNING[k]
    logMsg("I", "  %s = %s,", k, type(v) == "string" and string.format("%q", v) or tostring(v))
  end
end

function M.addListener(listener)
  for i = 1, #listeners do if listeners[i] == listener then return end end
  listeners[#listeners + 1] = listener
end

function M.removeListener(listener)
  for i = #listeners, 1, -1 do
    if listeners[i] == listener then table.remove(listeners, i) end
  end
end

function M.getCurrentSectionID() return currentSectionID end
function M.isSectionActive(id) return activeSet[id] == true end

function M.getActiveSections()
  local out = {}
  for id in pairs(activeSet) do out[#out + 1] = id end
  table.sort(out)
  return out
end

function M.getRelatedSections(id)
  local s = sections[id]
  return s and s.related or {}
end

-- name -> list of section IDs, straight from the builder's index
function M.getOverrideIndex() return overrideIndex end

-- 1101 -> "1101 (K01)": letter index above the last two digits, section number below
function M.sectionIDToDisplayName(id)
  if not id then return "none" end
  local letterIndex = math.floor(id / 100)
  if letterIndex < 1 or letterIndex > 26 then return tostring(id) end
  return string.format("%d (%s%02d)", id, string.char(64 + letterIndex), id % 100)
end

-- Least-squares slope of registerObject ms over the live object count, per 1000 objects (nil: too little spread).
local function registerSlopePer1000()
  local c = change
  if c.rn < 20 then return nil end
  local denom = c.rn * c.rxx - c.rx * c.rx
  if denom <= 0 or (c.liveMax - (c.liveMin or 0)) < 200 then return nil end
  return (c.rn * c.rxy - c.rx * c.ry) / denom * 1000
end

-- The shapes that cost the most since the last section change, by total create time.
local function topShapes(limit)
  local list = {}
  for name, c in pairs(change.shapes) do list[#list + 1] = { name = name, n = c.n, ms = c.ms, max = c.max, first = c.first, reload = c.reload } end
  table.sort(list, function(a, b) if a.ms ~= b.ms then return a.ms > b.ms end return a.name < b.name end)
  for i = #list, limit + 1, -1 do list[i] = nil end
  return list
end

-- Controlled measurement of what registerObject costs, run once from the console:
--   extensions.nfsc_sectionStreamer.probeRegister()                 (any live shape, 40 objects)
--   extensions.nfsc_sectionStreamer.probeRegister("<shapeName>", 80)
-- Creates `count` test TSStatics of one shape underground below the camera in four passes
-- (unnamed, named with the duplicate check timed on its own, unnamed again to expose order/warm-up
-- effects), logs the averages with the first and last quarter of each pass, and deletes them again.
-- It blocks the game for a moment (count x about 5 ms per pass).
local function runProbe(shapeName, count, auto, diag)
  if not initialized then return nil, "the streamer is not initialized (is the level loaded?)" end
  count = math.max(4, math.min(tonumber(count) or 40, 200))
  if not shapeName then
    for _, entry in pairs(live) do
      if entry.shape then shapeName = entry.shape; break end
    end
  end
  if not shapeName then return nil, "no streamed object is live yet (stand in a loaded section, or pass a shapeName)" end
  local cam = core_camera and core_camera.getPosition and core_camera.getPosition()
  local pos = cam and string.format("%.3f %.3f %.3f", cam.x, cam.y, cam.z - 800) or "0 0 -800"
  local results = {}
  local function pass(label, named)
    local objs, regMs, lookupMs, failed = {}, {}, {}, 0
    for i = 1, count do
      local obj = createObject("TSStatic")
      if not obj then break end
      pcall(obj.setField, obj, "shapeName", 0, shapeName)
      pcall(obj.setField, obj, "position", 0, pos)
      pcall(obj.setField, obj, "collisionType", 0, "None")
      pcall(obj.setField, obj, "decalType", 0, "None")
      local name = ""
      if named then
        name = "nfsc_probe_" .. label .. "_" .. i
        local a = os.clock()
        scenetree.findObject(name)
        lookupMs[i] = (os.clock() - a) * 1000
      end
      local a = os.clock()
      local diagRegStart = diag and diag:now()
      local okc, res = pcall(obj.registerObject, obj, name)
      local diagRegMs = diag and ((diag:now() - diagRegStart) * 1000)
      regMs[i] = (os.clock() - a) * 1000
      if diag then diag:recordOperation("probe-registerObject", diagRegMs, currentSectionID, name ~= "" and name or ("unnamed-" .. label .. "-" .. i), shapeName, "settle-probe-" .. label, diagRegMs, "registerObject API elapsed during settle probe; includes pcall and synchronous engine call") end
      -- registered for real? refused (false), or not findable afterwards (by name, or by a non-zero id)
      local found = okc and res ~= false
      if found and named then found = scenetree.findObject(name) ~= nil end
      if found and not named then
        local idOk, id = pcall(obj.getID, obj)
        found = idOk and id ~= nil and id ~= 0
      end
      if not found then failed = failed + 1 end
      objs[i] = obj
    end
    local d0 = os.clock()
    for i = 1, #objs do pcall(objs[i].delete, objs[i]) end
    local deleteMs = (os.clock() - d0) * 1000
    local function avg(list, from, to)
      local sum, n = 0, 0
      for i = from, to do if list[i] then sum, n = sum + list[i], n + 1 end end
      return n > 0 and sum / n or 0
    end
    local n, q = #regMs, math.max(1, math.floor(#regMs / 4))
    local r = { label = label, n = n, register = avg(regMs, 1, n), first = avg(regMs, 1, q), last = avg(regMs, n - q + 1, n),
                lookup = named and avg(lookupMs, 1, n) or 0, delete = n > 0 and deleteMs / n or 0, failed = failed }
    results[#results + 1] = r
    local short = shapeName:match("([^/\\]+)$") or shapeName
    logMsg("I", "probe %s: %d x %s: registerObject avg %.2f ms (first quarter %.2f, last quarter %.2f), name lookup %.3f ms, delete %.2f ms each%s",
      label, r.n, short, r.register, r.first, r.last, r.lookup, r.delete,
      failed > 0 and string.format(" -- %d of %d registers FAILED, timing not valid", failed, n) or "")
  end

  -- the same shape as a real streamed object: its real fields and position, created through the normal
  -- create path (which also adds it to the runtime group), under probe names, deleted again
  local function realPass()
    local item
    for _, entry in pairs(live) do
      if entry.item and entry.shape == shapeName then item = entry.item; break end
    end
    if not item then return end
    local objs, totalMs, regMs, failed = {}, 0, 0, 0
    for i = 1, count do
      local diagCreateStart = diag and diag:now()
      local a = os.clock()
      local probeName = "nfsc_probe_real_" .. i
      local obj = createStreamedObject(item, probeName, diag)
      local diagCreateMs = diag and ((diag:now() - diagCreateStart) * 1000)
      local createMs = (os.clock() - a) * 1000
      totalMs = totalMs + createMs
      if diag then diag:recordOperation("probe-create-total", diagCreateMs, currentSectionID, probeName, shapeName, "settle-probe-real", obj and split.diagRegisterMs or nil, "real-field probe create elapsed; includes nested registerObject API call") end
      if obj then
        objs[#objs + 1] = obj
        regMs = regMs + split.registerMs
      else
        failed = failed + 1
      end
    end
    for i = 1, #objs do pcall(objs[i].delete, objs[i]) end
    local n = math.max(1, #objs)
    local r = { label = "real", n = #objs, register = regMs / n, total = totalMs / math.max(1, count), failed = failed }
    results[#results + 1] = r
    local short = shapeName:match("([^/\\\\]+)$") or shapeName
    logMsg("I", "probe real: %d x %s with its real fields and position: create avg %.2f ms (registerObject %.2f ms)%s",
      r.n, short, r.total, r.register,
      failed > 0 and string.format(" -- %d of %d FAILED", failed, count) or "")
  end
  if auto then
    pass("named", true)
    pass("unnamed", false)
    realPass()
  else
    pass("named", true)
    pass("unnamed", false)
    pass("unnamed2", false)
    realPass()
  end
  return results
end

-- Always says something in the log: the reason it could not run, or the Lua error it hit.
function M.probeRegister(shapeName, count)
  logMsg("I", "probeRegister called (shape %s, count %s)", tostring(shapeName or "any live shape"), tostring(count or "default"))
  local ok, results, err = pcall(runProbe, shapeName, count)
  if not ok then
    logMsg("E", "probeRegister failed: %s", tostring(results))
    return nil, tostring(results)
  end
  if not results then logMsg("W", "probeRegister did not run: %s", tostring(err)) end
  return results, err
end

-- The run so far (since the last statistics reset or purge) as plain numbers.
function M.getRunStats()
  local r = run
  local paths, total = {}, 0
  for _, name in ipairs(r.order) do
    local pr = r.paths[name]
    paths[name] = { n = pr.n, avgMs = pr.n > 0 and pr.ms / pr.n or 0, maxMs = pr.max, totalMs = pr.ms }
    total = total + pr.n
  end
  return {
    seconds = totalTime - r.stamp, creates = total, paths = paths,
    frames = r.frames, busyFrames = r.busy, busyAvgMs = r.busy > 0 and r.busyMs / r.busy or 0, busyMaxMs = r.busyMax,
    idleFrames = r.idle, idleAvgMs = r.idle > 0 and r.idleMs / r.idle or 0, idleMaxMs = r.idleMax,
    sleepShare = r.frames > 0 and r.idle / r.frames or 0,
    warmFrames = r.warmFrames, warmMs = r.warmMs,
    settles = r.settles, settleAvgSeconds = r.settles > 0 and r.settleSum / r.settles or 0, settleMaxSeconds = r.settleMax,
    cheapCapHits = r.capHits.cheap, costlyCapHits = r.capHits.costly,
  }
end

-- One log block for a camera-track run: press Reset statistics (or Purge) first, run, then print this.
function M.logRunSummary()
  local r = M.getRunStats()
  logMsg("I", "RUN SUMMARY: %.1f s, mode %s, %d creates, %d dropped sections (%d objects), %d failures; peak live %d, pool %d (%d live, %d dormant, %d free), built %d",
    r.seconds, tostring(TUNING.creationMode), r.creates, droppedSections, droppedObjects, failureCount,
    shellStats.peakLive, poolTotal(), liveCount, dormantCount, shellFreeN, shellStats.built)
  local wa = M.getWarmAllStatus()
  logMsg("I", "  everything warm: %s", wa.enabled and string.format("ON, %d of %d meshes held%s", wa.held, wa.total, wa.complete and "" or " (NOT complete)") or "off")
  local function line(label, name)
    local p = r.paths[name]
    logMsg("I", "  %-26s %6d x avg %.3f ms, max %.1f ms, %.0f ms total (%.0f%% of creates)", label, p.n, p.avgMs, p.maxMs, p.totalMs,
      r.creates > 0 and p.n * 100 / r.creates or 0)
  end
  line("revive (same key)", "resident-revive")
  line("same-shape reuse", "resident-same-shape-reuse")
  line("refill (shape change)", "shell-refill")
  line("fresh (registerObject)", "pool-empty-fresh-object")
  line("plain create", "new-object")
  logMsg("I", "  streamer frames: %d total, %d busy (avg %.2f ms, worst %.1f ms), %d idle (avg %.3f ms, worst %.2f ms) = %.0f%% asleep; cache warm %d frames, %.0f ms",
    r.frames, r.busyFrames, r.busyAvgMs, r.busyMaxMs, r.idleFrames, r.idleAvgMs, r.idleMaxMs, r.sleepShare * 100, r.warmFrames, r.warmMs)
  logMsg("I", "  settles: %d, time to idle avg %.2f s, longest %.2f s; per-frame caps hit: cheap %d, refill %d",
    r.settles, r.settleAvgSeconds, r.settleMaxSeconds, r.cheapCapHits, r.costlyCapHits)
  if r.paths["pool-empty-fresh-object"].n > 0 and shellMode() then
    logMsg("W", "  %d objects needed a fresh registerObject while a pool was active: the pool was too small or not built yet", r.paths["pool-empty-fresh-object"].n)
  end
end

function M.getStatus()
  local pending = 0
  for _ in pairs(pendingUnload) do pending = pending + 1 end
  local active = 0
  for _ in pairs(activeSet) do active = active + 1 end
  return {
    initialized = initialized, suspended = suspended,
    currentSectionID = currentSectionID,
    currentSectionName = M.sectionIDToDisplayName(currentSectionID),
    activeSectionCount = active,
    liveObjectCount = liveCount,
    queuedObjectCount = (lqTail - lqHead + 1) + (pqTail - pqHead + 1),
    queuedUrgentCount = pqTail - pqHead + 1, promotedObjectCount = promotedTotal,
    queuedSectionReads = srTail - srHead + 1,
    pendingRecordCount = pendingCount,
    deferredCount = (function()
      local n = 0
      for _, list in pairs(deferred) do n = n + #list end
      return n
    end)(),
    staleDiscarded = staleDiscarded,
    queueHighWater = queueHighWater,
    createdLastFrame = createdLastFrame, createdPeakFrame = createdPeakFrame,
    cameraSectionID = cameraSectionID, predictedSectionID = predictedSectionID,
    cameraSpeed = math.sqrt(camVel.x * camVel.x + camVel.y * camVel.y),
    createdSinceChange = createdSinceChange,
    settleSeconds = settleSeconds, settlePeakSeconds = settlePeak,
    avgCreateMs = timing.creates > 0 and timing.createMs / timing.creates or 0, maxCreateMs = timing.createMax,
    firstUseCreates = timing.firsts, firstUseAvgMs = timing.firsts > 0 and timing.firstMs / timing.firsts or 0,
    repeatCreates = timing.repeats, repeatAvgMs = timing.repeats > 0 and timing.repeatMs / timing.repeats or 0,
    avgReadMs = timing.reads > 0 and timing.readMs / timing.reads or 0, maxReadMs = timing.readMax,
    loadFrameLastMs = timing.frameLast, loadFramePeakMs = timing.framePeak,
    changeCreates = change.creates, changeCreateMs = change.createMs, changeFrames = change.frames,
    changeFps = change.dtSum > 0 and change.frames / change.dtSum or 0, changeWorstFrameMs = change.dtMax * 1000,
    changeWorkPeakMs = change.workMax,
    changeFirstUseSplit = { import = { n = change.importN, ms = change.importMs }, cached = { n = change.hitN, ms = change.hitMs },
                            unknown = { n = change.unkN, ms = change.unkMs } },
    cacheWarm = M.getCacheWarmStatus(), warmAll = M.getWarmAllStatus(),
    changeDeferredFirstUse = change.deferredFirst,
    changeFirstUse = change.firsts, changeReload = change.reloads, changeWarm = change.warms,
    changeReloadAvgMs = change.reloads > 0 and change.reloadMs / change.reloads or 0,
    changeWarmAvgMs = change.warms > 0 and change.warmMs / change.warms or 0,
    changeTopShapes = topShapes(5),
    changeWarmByDistance = { c1 = change.dist[1], c2 = change.dist[2], c3 = change.dist[3] }, expectedFirstUseMs = expectedFirstMs(), idleFrameMs = idleFrameMs,
    changeNameAvgMs = change.creates > 0 and change.nameMs / change.creates or 0, changeRegisterSlopePer1000 = registerSlopePer1000(),
    changeSplitMs = { createObject = change.objectMs, setField = change.fieldsMs,
                      registerObject = change.registerMs, groupAdd = change.groupMs },
    pendingUnloadCount = pending,
    createdTotal = createdTotal, deletedTotal = deletedTotal,
    failureCount = failureCount,
    forceCollisionNone = TUNING.forceCollisionNone,
    creationMode = TUNING.creationMode, shellPoolActive = (TUNING.creationMode == "shells" or TUNING.creationMode == "resident") and not shellDisabled,
    shellsFree = shellFreeN, shellsBuilt = shellStats.built, shellTarget = TUNING.shellTarget,
    shellsRecycled = shellStats.recycled, shellsFresh = shellStats.fresh, shellsParked = shellStats.parked,
    shellRecycleAvgMs = shellStats.recycled > 0 and shellStats.recycleMs / shellStats.recycled or 0,
    shellParkAvgMs = shellStats.parked > 0 and shellStats.parkMs / shellStats.parked or 0,
    shellBuildMs = shellStats.buildMs, shellPeakLive = shellStats.peakLive,
    residentActive = TUNING.creationMode == "resident" and not shellDisabled,
    residentDormant = dormantCount, residentRevived = shellStats.revived, residentDeactivated = shellStats.deactivated,
    residentEvicted = shellStats.evicted, residentMax = TUNING.residentMax, residentReserve = TUNING.residentReserve,
    residentReviveAvgMs = shellStats.revived > 0 and shellStats.reviveMs / shellStats.revived or 0,
    residentShapeReuses = shellStats.residentShapeReuses,
    residentShapeReuseAvgMs = shellStats.residentShapeReuses > 0 and shellStats.residentShapeReuseMs / shellStats.residentShapeReuses or 0,
    poolTotal = poolTotal(),
    diagnostics = TUNING.testingMode and M.stallDiagnostics:summary() or nil,
    frameBudget = {
      mainMs = TUNING.frameBudgetMs,
      lastMs = { reads = fb.ms.reads, deletes = fb.ms.deletes, creates = fb.ms.creates, shells = fb.ms.shells, warm = fb.ms.warm },
      avgMs = { reads = fb.avg.reads, deletes = fb.avg.deletes, creates = fb.avg.creates, shells = fb.avg.shells, warm = fb.avg.warm },
      capsMs = { deletes = TUNING.frameBudgetMs * TUNING.deleteBudgetShare, shells = TUNING.frameBudgetMs * TUNING.shellBuildBudgetShare,
                 warmCheck = TUNING.frameBudgetMs * TUNING.cacheWarmCheckShare },
    },
    tuningRevision = tun.state.revision, lastPurge = tun.state.purge, run = M.getRunStats(),
    droppedSections = droppedSections, droppedObjects = droppedObjects, droppedLast = droppedLast,
    changeResident = { revived = change.residentRevives, reviveMs = change.residentReviveMs,
                       deactivated = change.residentDeacts, evicted = change.residentEvicts },
    changeShells = { recycled = change.shellRecycles, recycleMs = change.shellRecycleMs, fresh = change.shellFresh,
                     parked = change.shellParks, parkMs = change.shellParkMs },
  }
end

function M.resetDiagnostics()
  M.stallDiagnostics:reset()
  if TUNING.testingMode then M.stallDiagnostics:calibrate() end
end

function M.logDiagnosticSummary(section)
  local s = M.stallDiagnostics:summary(section)
  logMsg("I", "STALL diagnostics (%s): clock %s, frames %d, avg %.2f ms, worst %.2f ms, spikes %d (>= %.1f ms), budget overruns %d (%.2f ms total), queue-growth frames %d, pool mismatches %d, clock regressions %d",
    s.scope, s.clockSource, s.frames, s.avgFrameMs, s.worstFrameMs, s.spikeCount, M.stallDiagnostics.spikeMs,
    s.overrunFrames, s.totalOverrunMs, s.backlogGrowthFrames, s.poolMismatchFrames, s.clockRegressions)
  logMsg("I", "  timing scope: total frame begins before section selection and ends after cache-warm and settle/probe work; operation time is elapsed time, not pure Lua CPU; profiler Lua/LuaGC remains the CPU-side cross-check")
  logMsg("I", "  instrument estimate: stage begin/end pair %.2f us (microbenchmark only, not total instrumentation overhead); avg unassigned frame time %.2f ms",
    s.stageBookkeepingEstimateUs or 0, s.avgUnattributedMs)
  local names = { "selection", "section_reads", "queue_feed", "unloads", "loads", "shell_build", "resident_trim", "cache_warm", "settle_report" }
  for _, name in ipairs(names) do
    local stage = s.stageStats[name]
    if stage then logMsg("I", "  stage %-14s avg %.2f ms, max %.2f ms, work items %d", name, stage.avgMs, stage.maxMs, stage.items) end
  end
  logMsg("I", "  operation rows are overlapping scopes where noted (for example create-total contains registerObject); do not add nested totals together")
  local opNames = { "create-total", "registerObject", "createObject", "field-application", "shell-refill", "resident-revive", "delete-live-total", "object-delete-api", "section-json-read", "cache-warm-total", "cache-warm-registerObject", "shell-construction", "probe-registerObject", "probe-create-total" }
  for _, name in ipairs(opNames) do
    local op = s.operations[name]
    if op then logMsg("I", "  op %-22s count %d, total %.2f ms, avg %.3f ms, max %.2f ms, >=slow threshold %d", name, op.count, op.totalMs, op.avgMs, op.maxMs, op.slowCount) end
  end
  local p = s.poolActivity or {}
  logMsg("I", "  pool activity: built %d, shell reuse %d, fresh/refill %d, resident revived %d, evicted %d, deactivated %d, parked %d",
    p.built or 0, p.recycled or 0, p.fresh or 0, p.revived or 0, p.evicted or 0, p.deactivated or 0, p.parked or 0)
  for i = 1, math.min(5, #(s.topOps or {})) do
    local op = s.topOps[i]
    logMsg("I", "  slow op %d: %s %.2f ms; section %s; object %s; shape %s; path %s; API %.2f ms, outside-API %.2f ms; %s",
      i, op.kind, op.ms, op.section, op.object, op.shape, op.path,
      op.apiMs or 0, op.outsideApiMs or op.ms, op.dominant or op.scope)
  end
  if s.worstFrame then M.stallDiagnostics:logFrame(s.worstFrame, logMsg) end
end

function M.getFailures() return failures end

-- Sections in loading order (current first); a copy.
function M.getLoadOrder()
  local out = {}
  for i = 1, #feedOrder do out[i] = feedOrder[i] end
  return out
end

-- true when no section file and no object is waiting to be created (cheap, per-frame safe)
function M.isIdle() return lqHead > lqTail and pqHead > pqTail and srHead > srTail and pendingCount <= 0 end

-- Progress of the shape cache warm-up, for a console check or a progress display.
function M.getCacheWarmStatus()
  local imported = warm.imported
  return {
    enabled = TUNING.cacheWarm, available = warm.loaded, finished = warm.finished,
    running = TUNING.cacheWarm and warm.loaded and not warm.finished and not suspended and M.isIdle()
      and warm.idle >= TUNING.cacheWarmIdleSeconds,
    total = warm.total, processed = warm.processed, remaining = warm.total - warm.processed,
    alreadyCached = warm.hadCdae, imported = imported, failed = warm.failed, skipped = warm.skipped,
    importAvgMs = imported > 0 and warm.importMs / imported or 0, importMaxMs = warm.importMax,
    importMaxShape = warm.importMaxShape, current = warm.current,
    nearQueued = math.max(0, #warm.near - warm.nearPos + 1),
  }
end

function M.setCacheWarm(flag) TUNING.cacheWarm = flag and true or false end

-- Progress of the everything-warm mode (panel line, console check).
function M.getWarmAllStatus()
  return {
    enabled = TUNING.warmAll, available = warm.total > 0, total = warm.total, held = hold.held, failed = hold.failed,
    remaining = math.max(0, warm.total - hold.held - hold.failed), complete = hold.complete,
    releasing = not TUNING.warmAll and hold.held > 0, avgMs = hold.held > 0 and hold.ms / hold.held or 0,
    maxMs = hold.max, maxShape = hold.maxShape, seconds = hold.seconds,
  }
end

function M.setWarmAll(flag) TUNING.warmAll = flag and true or false end

-- Forgets what the lane has checked (after .cdae files were deleted, say) and starts over.
function M.restartCacheWarm()
  local names, bySection, total = warm.names, warm.bySection, warm.total
  warm = newWarm()
  warm.names, warm.bySection, warm.total, warm.loaded = names, bySection, total, total > 0
end

-- Builds parked shells ahead (TUNING.shellTarget) while nothing urgent is queued: a little per frame, never in a burst.
local function shellBuildUpdate(diag)
  if shellBuildOff or TUNING.shellTarget <= 0 or pqHead <= pqTail or not shellMode() then return 0 end
  local limit = fb.cap(TUNING.shellBuildBudgetShare)
  if limit <= 0 then return 0 end                       -- the loads used the frame: no shells built ahead this frame
  local started = os.clock()
  local n = 0
  while n < TUNING.shellBuildPerFrame and poolTotal() < TUNING.shellTarget do
    local buildStart = diag and diag:now()
    local ok, err = buildShell()
    if diag then diag:recordOperation("shell-construction", (diag:now() - buildStart) * 1000, currentSectionID, "nfsc_shell_" .. tostring(shellSerial), TUNING.shellShape, "pool-build", nil, "shell constructor and registration elapsed; mixed engine/Lua scope") end
    if not ok then
      shellBuildFails = shellBuildFails + 1
      if shellBuildFails >= 3 then
        shellBuildOff = true
        recordFailure("building shells stopped after 3 failures (is shellShape " .. tostring(TUNING.shellShape) .. " there?): " .. tostring(err))
      end
      break
    end
    shellBuildFails = 0
    n = n + 1
    if (os.clock() - started) * 1000 >= limit then break end
  end
  shellStats.buildMs = shellStats.buildMs + (os.clock() - started) * 1000
  return n
end

-- Resident mode, idle frames only: keep residentReserve shells free and the pool at residentMax by evicting the oldest.
local function residentTrim()
  if not residentMode() or pqHead <= pqTail or dormantCount == 0 or fb.remaining() <= 0 then return 0 end
  local total = poolTotal()
  local over = total - TUNING.residentMax
  local short = TUNING.residentReserve - shellFreeN
  if over <= 0 and not (short > 0 and total >= TUNING.residentMax) then return 0 end
  return evictOldest(math.min(dormantCount, 8, math.max(over, short, 1)))
end

function M.onUpdate(dtReal)
  if not initialized or suspended then return end
  fb.start = os.clock()
  local frameStarted = fb.start
  local diag = TUNING.testingMode and M.stallDiagnostics or nil
  local sectionBefore = currentSectionID
  if diag then
    local deferredN = 0
    for _, list in pairs(deferred) do deferredN = deferredN + #list end
    local queuedN = math.max(0, lqTail - lqHead + 1) + math.max(0, pqTail - pqHead + 1)
    local poolN = poolTotal()
    diag:beginFrame({
      started = diag:now(), section = currentSectionID, budgetMs = TUNING.frameBudgetMs,
      queue = { urgent = math.max(0, pqTail - pqHead + 1), load = math.max(0, lqTail - lqHead + 1),
        queued = queuedN, pending = pendingCount, reads = math.max(0, srTail - srHead + 1),
        unloads = math.max(0, uqTail - uqHead + 1), deferred = deferredN, backlog = queuedN + pendingCount + deferredN + math.max(0, srTail - srHead + 1),
        staleDiscarded = staleDiscarded, droppedObjects = droppedObjects, deferredFirst = change.deferredFirst },
      pool = { live = liveCount, dormant = dormantCount, free = shellFreeN, total = poolN,
        cap = residentMode() and TUNING.residentMax or nil, mode = TUNING.creationMode,
        built = shellStats.built, recycled = shellStats.recycled, fresh = shellStats.fresh, evicted = shellStats.evicted,
        revived = shellStats.revived, deactivated = shellStats.deactivated, parked = shellStats.parked },
    })
  end
  local selectionStart = diag and diag:beginStage("selection")
  totalTime = totalTime + (dtReal or 0)
  updateCamera(dtReal or 0)
  priorityTimer = priorityTimer + (dtReal or 0)
  if priorityTimer >= TUNING.priorityRefreshInterval then
    priorityTimer = 0
    rebuildFeedOrder()
  end
  if diag then diag:endStage("selection", selectionStart, currentSectionID ~= sectionBefore and 1 or 0) end
  if settled and M.isIdle() then
    local dt = dtReal or 0
    if dt > 0 and dt < 0.5 then idleFrameMs = idleFrameMs and (idleFrameMs * 0.98 + dt * 1000 * 0.02) or dt * 1000 end
  end
  local t0 = os.clock()
  local readStageStart = diag and diag:beginStage("section_reads")
  local readCount = processSectionReads(diag)
  if diag then diag:endStage("section_reads", readStageStart, readCount) end
  local queuedBefore = queueLength()
  local queueStageStart = diag and diag:beginStage("queue_feed")
  feedQueue()
  local queuedAfter = queueLength()
  local queuedCount = math.max(0, queuedAfter - queuedBefore)
  if diag then diag:endStage("queue_feed", queueStageStart, queuedCount) end
  local t1 = os.clock()
  fb.record("reads", (t1 - t0) * 1000)
  local unloadStageStart = diag and diag:beginStage("unloads")
  local unloadCount = processUnloads(diag)               -- deletes first, within their share of the frame budget
  if diag then diag:endStage("unloads", unloadStageStart, unloadCount) end
  local t2 = os.clock()
  fb.record("deletes", (t2 - t1) * 1000)
  local loadStageStart = diag and diag:beginStage("loads")
  local createCount, skippedCount = processLoads(diag)  -- creates use what is left of it
  if diag then diag:endStage("loads", loadStageStart, createCount); diag.current.workSkipped = skippedCount end
  local t3 = os.clock()
  fb.record("creates", (t3 - t2) * 1000)
  local shellStageStart = diag and diag:beginStage("shell_build")
  local shellsBuilt = shellBuildUpdate(diag)             -- idle shell construction, limited by remaining budget
  if diag then diag:endStage("shell_build", shellStageStart, shellsBuilt) end
  local trimStageStart = diag and diag:beginStage("resident_trim")
  local evictedCount = residentTrim()
  if diag then diag:endStage("resident_trim", trimStageStart, evictedCount) end
  fb.record("shells", (os.clock() - t3) * 1000)
  do
    local coreMs = (os.clock() - frameStarted) * 1000       -- reads, unloads, loads, shell build and trim; not the warm lane
    run.frames = run.frames + 1
    if readCount > 0 or unloadCount > 0 or createCount > 0 or shellsBuilt > 0 or evictedCount > 0 then
      run.busy, run.busyMs = run.busy + 1, run.busyMs + coreMs
      if coreMs > run.busyMax then run.busyMax = coreMs end
    else
      run.idle, run.idleMs = run.idle + 1, run.idleMs + coreMs
      if coreMs > run.idleMax then run.idleMax = coreMs end
    end
  end
  if not settled then
    local workMs = (os.clock() - frameStarted) * 1000
    change.frames = change.frames + 1
    change.workMs = change.workMs + workMs
    if workMs > change.workMax then change.workMax = workMs end
    local dt = dtReal or 0
    change.dtSum = change.dtSum + dt
    if dt > change.dtMax then change.dtMax = dt end
  end
  local tw = os.clock()
  local warmBefore = warm.processed
  local warmStageStart = diag and diag:beginStage("cache_warm")
  cacheWarmUpdate(dtReal or 0, diag)                  -- idle lane: only while nothing is queued
  local heldNow = hold.update(dtReal or 0)             -- everything-warm lane (the cache warm lane stands down)
  local warmedCount = warm.processed - warmBefore + heldNow
  if diag then diag:endStage("cache_warm", warmStageStart, warmedCount) end
  fb.record("warm", (os.clock() - tw) * 1000)
  if warmedCount > 0 then run.warmFrames, run.warmMs = run.warmFrames + 1, run.warmMs + fb.ms.warm end
  local settleStageStart = diag and diag:beginStage("settle_report")
  if not settled and M.isIdle() then
    settled = true
    settleSeconds = totalTime - changeStamp
    if settleSeconds > settlePeak then settlePeak = settleSeconds end
    run.settles, run.settleSum = run.settles + 1, run.settleSum + settleSeconds
    if settleSeconds > run.settleMax then run.settleMax = settleSeconds end
    if TUNING.logSettle and (createdSinceChange > 0 or TUNING.logEmptySettles) then
      local c = change
      logMsg("I", "section %s settled: %d objects in %.2f s (%.0f/s), %d frames, %.1f fps (worst frame %.0f ms), core streaming %.1f ms/frame (peak %.0f ms; excludes cache-warm and settle/probe work)",
        tostring(currentSectionID), createdSinceChange, settleSeconds,
        settleSeconds > 0 and createdSinceChange / settleSeconds or 0,
        c.frames, c.dtSum > 0 and c.frames / c.dtSum or 0, c.dtMax * 1000, c.frames > 0 and c.workMs / c.frames or 0, c.workMax)
      if c.creates > 0 then
        logMsg("I", "  creates: %.0f ms total, avg %.2f ms, max %.1f ms; first use %d x %.2f ms, reload %d x %.2f ms, warm %d x %.2f ms, new shapes deferred %d times",
          c.createMs, c.createMs / c.creates, c.maxMs,
          c.firsts, c.firsts > 0 and c.firstMs / c.firsts or 0,
          c.reloads, c.reloads > 0 and c.reloadMs / c.reloads or 0,
          c.warms, c.warms > 0 and c.warmMs / c.warms or 0, c.deferredFirst)
        if c.firsts > 0 then
          logMsg("I", "  first use split: import (no .cdae yet) %d x %.2f ms, cached (.cdae existed) %d x %.2f ms, unknown %d x %.2f ms",
            c.importN, c.importN > 0 and c.importMs / c.importN or 0, c.hitN, c.hitN > 0 and c.hitMs / c.hitN or 0,
            c.unkN, c.unkN > 0 and c.unkMs / c.unkN or 0)
        end
        local top = topShapes(5)
        for i = 1, #top do
          local t = top[i]
          logMsg("I", "  top %d: %s %d x, %.0f ms total, avg %.2f, max %.1f ms (first %d, reload %d)",
            i, shortShapeName(t.name), t.n, t.ms, t.ms / t.n, t.max, t.first, t.reload)
        end
        local slope = registerSlopePer1000()
        logMsg("I", "  per create: createObject %.2f, setField %.2f, name %.2f, registerObject %.2f, group add %.2f ms; deleted %d in %.0f ms; section read max %.1f ms",
          c.objectMs / c.creates, c.fieldsMs / c.creates, c.nameMs / c.creates, c.registerMs / c.creates, c.groupMs / c.creates,
          c.deleted, c.deleteMs, timing.readMax)
        if TUNING.creationMode == "resident" then
          logMsg("I", "  resident: revived %d x %.3f ms, same-shape reused %d x %.3f ms, deactivated %d, evicted %d; dormant %d, free %d, pool %d of %d",
            c.residentRevives, c.residentRevives > 0 and c.residentReviveMs / c.residentRevives or 0,
            c.residentShapeReuses, c.residentShapeReuses > 0 and c.residentShapeReuseMs / c.residentShapeReuses or 0,
            c.residentDeacts, c.residentEvicts, dormantCount, shellFreeN, poolTotal(), TUNING.residentMax)
        end
        if TUNING.creationMode ~= "current" then
          logMsg("I", "  shells: recycled %d x %.3f ms, fresh %d, parked %d x %.3f ms; free %d, peak live %d, built ahead %d",
            c.shellRecycles, c.shellRecycles > 0 and c.shellRecycleMs / c.shellRecycles or 0, c.shellFresh,
            c.shellParks, c.shellParks > 0 and c.shellParkMs / c.shellParks or 0, shellFreeN, shellStats.peakLive, shellStats.built)
        end
        logMsg("I", "  scene: live objects %d to %d (avg %.0f) while creating, registerObject trend %s, idle frame %s",
          c.liveMin or 0, c.liveMax, c.liveSum / c.creates,
          slope and string.format("%+.2f ms per 1000 live", slope) or "n/a (live count barely changed)",
          idleFrameMs and string.format("%.1f ms (%.0f fps)", idleFrameMs, 1000 / idleFrameMs) or "n/a")
        local mgr = rawget(_G, "nfsc_sectionManager")
        local okState, lightsOn, emittersOn = false, nil, nil
        if mgr and mgr.getSceneClassState then okState, lightsOn, emittersOn = pcall(mgr.getSceneClassState) end
        local function onOff(v) if not okState or v == nil then return "n/a" end return v and "on" or "off" end
        local function bucket(b) return string.format("%d x %.2f ms", b.n, b.n > 0 and b.ms / b.n or 0) end
        logMsg("I", "  warm creates by horizontal distance to the camera: under 100 m %s, 100-300 m %s, over 300 m %s; lights %s, emitters %s",
          bucket(c.dist[1]), bucket(c.dist[2]), bucket(c.dist[3]), onOff(lightsOn), onOff(emittersOn))
        if TUNING.probeOnSettle then
          -- the shape with the most creates in this change: its real average sits next to the probe
          local bestName, best = nil, nil
          for name, cost in pairs(c.shapes) do
            if not best or cost.n > best.n or (cost.n == best.n and name < bestName) then bestName, best = name, cost end
          end
          if bestName then
            local ok, results, why = pcall(runProbe, bestName, TUNING.probeCount, true, diag)
            if not ok then
              logMsg("E", "probe after settle failed: %s", tostring(results))
            elseif not results then
              logMsg("W", "probe after settle did not run: %s", tostring(why))
            else
              local byLabel = {}
              for _, r in ipairs(results) do byLabel[r.label] = r end
              local function ms(r) return r and string.format("%.2f ms%s", r.register, (r.failed or 0) > 0 and " (FAILED)" or "") or "n/a" end
              logMsg("I", "  probe vs real: %s real avg %.2f ms over %d creates in this change (warm avg %.2f ms); probe named %s, unnamed %s, real fields %s",
                shortShapeName(bestName), best.ms / best.n, best.n, c.warms > 0 and c.warmMs / c.warms or 0,
                ms(byLabel.named), ms(byLabel.unnamed), ms(byLabel.real))
            end
          end
        end
      end
    end
  end
  if diag then diag:endStage("settle_report", settleStageStart, 0) end
  if diag then
    local deferredAfter = 0
    for _, list in pairs(deferred) do deferredAfter = deferredAfter + #list end
    local queuedEnd = math.max(0, lqTail - lqHead + 1) + math.max(0, pqTail - pqHead + 1)
    local poolEnd = poolTotal()
    local frameReport = diag:endFrame({
      section = currentSectionID, remainingMs = fb.remaining(),
      queue = { urgent = math.max(0, pqTail - pqHead + 1), load = math.max(0, lqTail - lqHead + 1),
        queued = queuedEnd, pending = pendingCount, reads = math.max(0, srTail - srHead + 1),
        unloads = math.max(0, uqTail - uqHead + 1), deferred = deferredAfter,
        backlog = queuedEnd + pendingCount + deferredAfter + math.max(0, srTail - srHead + 1), staleDiscarded = staleDiscarded,
        droppedObjects = droppedObjects, deferredFirst = change.deferredFirst },
      pool = { live = liveCount, dormant = dormantCount, free = shellFreeN, total = poolEnd,
        cap = residentMode() and TUNING.residentMax or nil, mode = TUNING.creationMode,
        built = shellStats.built, recycled = shellStats.recycled, fresh = shellStats.fresh, evicted = shellStats.evicted,
        revived = shellStats.revived, deactivated = shellStats.deactivated, parked = shellStats.parked },
      work = { reads = readCount, queued = queuedCount, deletes = unloadCount, creates = createCount,
        skipped = skippedCount, shells = shellsBuilt, evicted = evictedCount, warmed = warmedCount },
    })
    if frameReport and (frameReport.isSpike or frameReport.overrunMs >= 3.0) then
      logMsg("W", "TEST frame #%d %s: %.2f ms; budget %.2f, consumed %.2f, remaining %.2f, overrun %.2f ms; section %s -> %s (details retained; use Print run + section stall report)",
        frameReport.id, frameReport.isSpike and "SPIKE" or "BUDGET OVERRUN", frameReport.totalMs,
        frameReport.budgetMs, frameReport.consumedMs, frameReport.remainingMs or 0, frameReport.overrunMs,
        tostring(frameReport.sectionStart or "none"), tostring(frameReport.sectionEnd or "none"))
    end
  end
end

function M.onExtensionUnloaded()
  notify("onStreamerReset")
  destroyRuntimeGroup()
  while not hold.release(100000) do end
  resetState()
  initialized = false
end

return M
