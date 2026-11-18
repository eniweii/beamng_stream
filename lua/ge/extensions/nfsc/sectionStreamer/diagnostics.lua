-- nfsc_sectionStreamer, part "diagnostics": status, run stats and summary, probe, failures, load order and the shape index status.
-- Loaded by sectionStreamer.lua into the shared streamer environment; every name here is shared with the other parts.

-- Least-squares slope of registerObject ms over the live object count, per 1000 objects (nil: too little spread).
function registerSlopePer1000()
  local c = change
  if c.rn < 20 then return nil end
  local denom = c.rn * c.rxx - c.rx * c.rx
  if denom <= 0 or (c.liveMax - (c.liveMin or 0)) < 200 then return nil end
  return (c.rn * c.rxy - c.rx * c.ry) / denom * 1000
end

-- The shapes that cost the most since the last section change, by total create time.
function topShapes(limit)
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
function runProbe(shapeName, count, auto, diag)
  if not initialized then return nil, "the streamer is not initialized (is the level loaded?)" end
  count = math.max(4, math.min(tonumber(count) or 40, 200))
  if not shapeName then
    for _, entry in pairs(live) do
      if entry.shape then shapeName = entry.shape; break end
    end
  end
  if not shapeName then return nil, "no streamed object is live yet (stand in a loaded section, or pass a shapeName)" end
  local cx, cy, cz = cameraXYZ()
  local pos = cx and string.format("%.3f %.3f %.3f", cx, cy, cz - 800) or "0 0 -800"
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
    warmFrames = r.warmFrames, warmMs = r.warmMs, coldFrames = r.coldFrames,
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
  local si = M.getShapeIndexStatus()
  if si.state == "scanning" or si.state == "done" then
    logMsg("I", "  shape index: %s, %d of %d section files, %d unique shapes, %d unreadable, %.1f s reading", si.state, si.files, si.total,
      si.unique, si.failed, si.readSeconds)
  end
  hold.logSummary()
  if not TUNING.debugLog then return end                  -- the paths, frames and settle lines are Debug
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
  logMsg("I", "  streamer frames: %d total, %d busy (avg %.2f ms, worst %.1f ms), %d idle (avg %.3f ms, worst %.2f ms) = %.0f%% asleep; holds %d frames, %.0f ms",
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
    shapeCache = M.getShapeCacheStatus(), shapeIndex = M.getShapeIndexStatus(),
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
    engineFailCount = engineFails.total,
    forceCollisionNone = TUNING.forceCollisionNone,
    creationMode = TUNING.creationMode, shellPoolActive = (TUNING.creationMode == "shells" or TUNING.creationMode == "resident") and not shellDisabled,
    shellsFree = shellFreeN, shellsBuilt = shellStats.built, shellTarget = TUNING.shellTarget,
    shellsRecycled = shellStats.recycled, shellsFresh = shellStats.fresh, shellsParked = shellStats.parked,
    shellsShapeKept = shellStats.shapeKept, fieldsSkipped = shellStats.fieldsSkipped, fieldsWritten = shellStats.fieldsWritten,
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
      mainMs = TUNING.frameBudgetMs, effectiveMs = fb.budget(), adaptive = TUNING.adaptiveBudget == true, frameEmaMs = fb.frameEma,
      lastMs = { reads = fb.ms.reads, deletes = fb.ms.deletes, creates = fb.ms.creates, shells = fb.ms.shells, warm = fb.ms.warm },
      avgMs = { reads = fb.avg.reads, deletes = fb.avg.deletes, creates = fb.avg.creates, shells = fb.avg.shells, warm = fb.avg.warm },
      capsMs = { deletes = fb.budget() * TUNING.deleteBudgetShare, shells = fb.budget() * TUNING.shellBuildBudgetShare,
                 holds = fb.budget() * TUNING.shapeCacheBudgetShare },
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

-- Failed engine calls per place, most frequent first: { site, count, first error text }.
function M.getEngineFailures()
  local out = {}
  for i, key in ipairs(engineFails.order) do
    local rec = engineFails.sites[key]
    out[i] = { site = key, count = rec.n, first = rec.first }
  end
  table.sort(out, function(a, b) return a.count > b.count end)
  return out
end

-- Sections in loading order (current first); a copy.
function M.getLoadOrder()
  local out = {}
  for i = 1, #feedOrder do out[i] = feedOrder[i] end
  return out
end

-- true when no section file and no object is waiting to be created (cheap, per-frame safe)
function M.isIdle() return lqHead > lqTail and pqHead > pqTail and srHead > srTail and pendingCount <= 0 end

-- The shape index: "scanning" / "done" (built from the section files) or "none".
function M.getShapeIndexStatus()
  local sc = warm.scan
  if not sc then return { state = "none", unique = warm.total, files = 0, total = 0, failed = 0, records = 0, seconds = 0, readSeconds = 0 } end
  return {
    state = sc.done and "done" or "scanning", files = sc.files, total = #sc.ids, failed = sc.failed, records = sc.records,
    unique = sc.unique, seconds = sc.runSeconds, readSeconds = sc.ms / 1000,
    etaSeconds = (not sc.done and sc.files > 0 and sc.runSeconds > 0) and (#sc.ids - sc.files) * sc.runSeconds / sc.files or nil,
  }
end
