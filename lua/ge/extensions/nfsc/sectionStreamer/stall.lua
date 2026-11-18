-- nfsc_sectionStreamer, part "stall": bounded, opt-in frame and stage timing, sampled while Testing Mode is on.
-- Loaded by sectionStreamer.lua into the shared streamer environment; every name here is shared with the other parts.

-- Bounded, opt-in stall diagnostics. Detailed work is only sampled while Testing Mode is enabled.
-- os.clockhp is preferred when this GE-Lua runtime exposes it; every timing site below uses the
-- same seconds-based source. Backwards jumps are counted and clamped in the diagnostic accumulator.
STALL = {
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
