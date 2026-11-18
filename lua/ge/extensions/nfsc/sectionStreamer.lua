-- nfsc_sectionStreamer: Section Streamer (base scenery lifecycle).
--
-- Streaming determines which base objects EXIST. This extension:
--   * finds the camera's section from sections.json (drivable polygons only),
--   * keeps that section plus its related sections resident (and the always-loaded sections, see below),
--   * creates their TSStatic objects from whole-section files and deletes them again
--     after a cooldown, spread across frames,
--   * reports what happened to other extensions. It never decides override visibility
--     (that is nfsc_sectionManager) and never looks at override or flag values.
--
-- Files (all under <levelRoot>/):
--   lua/sections.json                   {sections = {{id, points, boundsMin, boundsMax, related}}}
--   lua/streamer/index.json        written by the builder (schemaVersion 2)
--   lua/streamer/sections/<id>.json  one whole file per section
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
-- Shape cache (TUNING.shapeCache): the streamer holds every shape of the streamed sections with one hidden TSStatic each
-- (collision none, in its own group NFSC_WarmMeshes, outside the pool and the live counts), kept all session and never
-- retargeted. So a mesh is loaded once, by its holder, and the pooled objects only revive, retarget and unhide: in
-- resident mode the pool (residentMax) is sized to the most objects that are resident at once, not to the shape count.
-- Two channels fill it: the idle lane (while both load queues are empty: the shapes of the current and related
-- sections first, then every shape once, widest use first; one holder per frame within shapeCacheBudgetShare) and the
-- need channel (a create wants a shape nobody holds: the holder loads it first, inside the create's frame budget and
-- first-use caps, then the shell retargets to an already loaded shape). Heavy shapes (measured over shapeCacheHeavyMs,
-- kept in lua/streamer/shape_costs.json) wait for a still camera, a RAM floor can pause the lane (needs a memory
-- source: M.setMemoryProvider), a shape without a file is flagged absent, a failed hold is retried once. Placeholders
-- (hidden holders on the dot, shapeCachePlaceholders) are built ahead of the fill cursor so a hold only changes a shapeName.
-- Shape names are found at runtime: hold.scanUpdate reads every section file at level load (nothing streams until it is done; indexBeforeStreaming) and builds the index (unique
-- shapes, widest use first, per-section lists, terrain shapes) from the shapeName fields. No extra file is needed.
--
-- Always-loaded sections: a section that has streamed objects but is in no polygon of sections.json and in no
-- section's related list is never reached through the camera, so it is kept active all the time, also while the camera
-- is outside every section (found at initialize from the data, nothing is listed by hand).
-- Per visit to a section the lane records the readiness at entry and the late / dropped neighbours (hold.visitClose).
-- M.getShapeCacheStatus() feeds the panel; M.logRunSummary prints the cacher-log v1 lines.
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
-- deletePreset keep named sets in lua/streamer/tuning_presets.json (a preset called "startup" is applied
-- at initialize). The manager panel has sliders for the common ones.
--
-- Parts (nfsc/sectionStreamer/, loaded in this order by the loader below; this file keeps initialize / reset / purge,
-- the creation-mode and suspend switches, the listeners and the per-frame onUpdate):
--   stall.lua     bounded, opt-in frame and stage timing, sampled while Testing Mode is on.
--   tuning.lua    the TUNING table and its defaults, the settings schema, presets (file and mode presets) and the get/set functions.
--   state.lua     the variables every part reads and writes (queues, live objects, pools, timers), the frame budget, run stats, and the log / failure / notify helpers.
--   sectionIndex.lua sections.json and the stream index, point-in-polygon lookup, stacked sections (depth), the active set and the section getters.
--   objects.lua   the runtime group, field text, creating a streamed object, readback, the live registry, deleting, and hiding / showing the ambient geometry.
--   pool.lua      parked shells, the resident (dormant) pool, reviving, evicting, shell building and the creation modes.
--   queues.lua    loading priority and feed order, section reads, pending / deferred items, the load, urgent and unload queues, processLoads / processUnloads and the create filter.
--   camera.lua    the current-section change and the per-frame camera update (velocity, look-ahead, prediction).
--   shapeCache.lua shape index scan, placeholders, mesh warming (idle lane and need channel), RAM floor, visits and the cache status.
--   diagnostics.lua status, run stats and summary, probe, failures, load order and the shape index status.

local M = {}

-- The streamer is split over the files in nfsc/sectionStreamer/ (see PARTS). They are loaded with loadfile, like the
-- level host components, not as engine extensions, and all run in ONE shared environment: what used to be a
-- file-level local (state, helpers, hold, TUNING ...) is a field of that environment under the same name, so every
-- function reads and writes the same variables as before. A name the environment does not have falls through to
-- the engine globals. The public API stays on M, which is this extension.
local PARTS = { "stall", "tuning", "state", "sectionIndex", "objects", "pool", "queues", "camera", "shapeCache", "diagnostics" }

local function partsDir()
  local candidates = {}
  local src = debug and debug.getinfo and debug.getinfo(1, "S").source
  local here = type(src) == "string" and src:match("^@(.*)[/\\][^/\\]*$")
  if here then candidates[#candidates + 1] = here .. "/sectionStreamer" end
  candidates[#candidates + 1] = "/lua/ge/extensions/nfsc/sectionStreamer"
  for _, dir in ipairs(candidates) do
    if loadfile(dir .. "/" .. PARTS[1] .. ".lua") then return dir end
  end
  return candidates[#candidates]
end

local env = setmetatable({ M = M }, { __index = _G })
do
  local dir = partsDir()
  for _, name in ipairs(PARTS) do
    local path = dir .. "/" .. name .. ".lua"
    local chunk, err = loadfile(path)
    if not chunk then error("nfsc_sectionStreamer: could not load " .. path .. ": " .. tostring(err)) end
    setfenv(chunk, env)
    chunk()
  end
end
setfenv(1, env)   -- the rest of this file runs in the same environment as the parts

function resetState()
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
    hold.findAlways()
    ensureRuntimeGroup()
  end)
  if not ok then
    recordFailure("initialize failed: " .. tostring(err))
    return false, tostring(err)
  end
  initialized = true
  if readPresets().startup then M.loadPreset("startup") end
  local okShapes, errShapes = pcall(loadShapeList)
  if not okShapes then warm = newWarm(); logMsg("W", "the shape index could not be started: %s", tostring(errShapes)) end
  hold.costLoad()
  logMsg("D", "initialized: %d sections, %d with streamed objects", #sectionOrder, (function()
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
  hold.stats = hold.statsNew()
  run = newRun(totalTime)
  if M.stallDiagnostics then M.resetDiagnostics() end
  logMsg("I", "statistics reset (tuning and pool unchanged)")
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

function M.setSuspended(flag) suspended = flag and true or false end
function M.isSuspended() return suspended end

function M.addListener(listener)
  for i = 1, #listeners do if listeners[i] == listener then return end end
  listeners[#listeners + 1] = listener
end

function M.removeListener(listener)
  for i = #listeners, 1, -1 do
    if listeners[i] == listener then table.remove(listeners, i) end
  end
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
  if hold.always.dirty then hold.activateAlways() end
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
  local indexing = hold.indexFirst()                    -- level-load indexing: reads, feeding, deletes and creates wait for it
  local readCount = indexing and 0 or processSectionReads(diag)
  if diag then diag:endStage("section_reads", readStageStart, readCount) end
  local queuedBefore = queueLength()
  local queueStageStart = diag and diag:beginStage("queue_feed")
  if not indexing then feedQueue() end
  local queuedAfter = queueLength()
  local queuedCount = math.max(0, queuedAfter - queuedBefore)
  if diag then diag:endStage("queue_feed", queueStageStart, queuedCount) end
  local t1 = os.clock()
  fb.record("reads", (t1 - t0) * 1000)
  local unloadStageStart = diag and diag:beginStage("unloads")
  local unloadCount = indexing and 0 or processUnloads(diag)               -- deletes first, within their share of the frame budget
  if diag then diag:endStage("unloads", unloadStageStart, unloadCount) end
  local t2 = os.clock()
  fb.record("deletes", (t2 - t1) * 1000)
  local loadStageStart = diag and diag:beginStage("loads")
  local createCount, skippedCount = 0, 0
  if not indexing then createCount, skippedCount = processLoads(diag) end  -- creates use what is left of it
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
    if not hold.complete then run.coldFrames = run.coldFrames + 1 end      -- frames before every mesh was held (Everything is warm)
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
  local warmStageStart = diag and diag:beginStage("cache_warm")
  local scanned = hold.scanUpdate(dtReal or 0)         -- shape index from the section files 
  local heldNow = hold.update(dtReal or 0)             -- shape cache lane: only while nothing is queued
  local warmedCount = heldNow + scanned
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
