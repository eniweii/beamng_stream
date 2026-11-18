-- nfsc_sectionStreamer, part "queues": loading priority and feed order, section reads, pending / deferred items, the load, urgent and unload queues, processLoads / processUnloads and the create filter.
-- Loaded by sectionStreamer.lua into the shared streamer environment; every name here is shared with the other parts.

-- ---------------------------------------------------------------------------
-- Queues
-- ---------------------------------------------------------------------------
-- The game's GetLoadingPriority: the point one second ahead, its distance outside the section,
-- shrunk when the heading points at the section, in three 75 m bands. 0 loads first.
function loadingPriority(id)
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
function rebuildFeedOrder()
  feedOrder = {}
  if currentSectionID and hold.hasSection(currentSectionID) then
    local entries = {}
    for rank, id in ipairs(hold.relatedOf(currentSectionID)) do
      if id ~= currentSectionID then entries[#entries + 1] = { id = id, tier = loadingPriority(id), rank = rank } end
    end
    table.sort(entries, function(a, b)
      if a.tier ~= b.tier then return a.tier < b.tier end
      return a.rank < b.rank
    end)
    feedOrder[1] = currentSectionID
    for i = 1, #entries do feedOrder[i + 1] = entries[i].id end
  end
  for _, id in ipairs(hold.always.list) do feedOrder[#feedOrder + 1] = id end    -- always-loaded sections go last
end

function queueSectionRead(id)
  if sectionRead[id] or sectionReading[id] then return end
  if not sectionIndex[id] then sectionRead[id] = true; return end   -- section with no streamed objects
  sectionReading[id] = true
  srTail = srTail + 1
  sectionReadQueue[srTail] = id
end

-- Makes the always-loaded sections active (at start, and again after a purge cleared the selection).
function hold.activateAlways()
  hold.always.dirty = false
  if next(hold.always.set) == nil then return end
  activeSet = computeActive(currentSectionID)
  rebuildFeedOrder()
  for i = 1, #feedOrder do queueSectionRead(feedOrder[i]) end
end

-- Objects of the section the camera is in, or the one the streamer is currently loading for, are
-- urgent: they are served before anything left over from the section just left.
function isUrgent(item)
  if not TUNING.currentSectionFirst then return false end
  local ids = itemSections(item)
  for i = 1, #ids do
    local id = ids[i]
    if id == currentSectionID or id == cameraSectionID then return true end
    local d = hold.stack.depth[currentSectionID or 0]
    if d and id == d.base then return true end
  end
  return false
end

function queueItem(item)
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
function priLength() return pqTail - pqHead + 1 end
function queueLength() return (lqTail - lqHead + 1) + (pqTail - pqHead + 1) end

-- Terrain-like objects (identity matrix / chopped roadway) are loaded before everything else.
function isTerrainItem(item)
  local flags = item.instanceFlags
  if type(flags) ~= "string" then return false end
  flags = flags:lower():gsub("[^%w]", "")
  return flags:find("identitymatrix", 1, true) ~= nil or flags:find("choppedroadway", 1, true) ~= nil
end

-- Same shapeName next to each other (first appearance decides the order of the groups).
function groupByShape(items)
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

function appendTier(tier, items)
  if #items == 0 then return end
  local grouped = groupByShape(items)
  local list = tier.list
  for i = 1, #grouped do list[tier.n + i] = grouped[i] end
  tier.n = tier.n + #grouped
  pendingCount = pendingCount + #grouped
end

function addPending(id, items)
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

function releasePending(id)
  local entry = pending[id]
  if entry then
    pendingCount = pendingCount - (entry.terrain.n - entry.terrain.at + 1) - (entry.rest.n - entry.rest.at + 1)
    pending[id] = nil
  end
  deferred[id] = nil
end

function deferItem(id, item)
  local list = deferred[id]
  if not list then list = {}; deferred[id] = list end
  list[#list + 1] = item
end

-- Feeds one tier of one section into the load queue until the queue is full.
function feedTier(id, tierName)
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
function feedQueue()
  if pendingCount <= 0 or #feedOrder == 0 then return end
  if TUNING.currentSectionFirst and currentSectionID and hold.hasSection(currentSectionID) then                       -- the camera's section and the streamed one, terrain first
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
function purgeQueue()
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

function scheduleUnload(key)
  if pendingUnload[key] then return end
  pendingUnload[key] = totalTime
  uqTail = uqTail + 1
  unloadQueue[uqTail] = { key = key, stamp = totalTime }
end

function processSectionReads(diag)
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
function shortShapeName(name)
  local base = (name:match("([^/\\]+)$") or name):gsub("%.dae$", "")
  return base
end

-- Does the engine already have a .cdae for this shape? true: a load is a cache read; false: the first use
-- imports the COLLADA and writes the cache; nil: cannot tell (no FS:fileExists, or not a .dae shape).
fsUnavailable = false
function fileExists(fs, path)
  local ok, res = pcall(function() return fs:fileExists(path) end)
  if not ok then return nil end
  return res and true or false
end
function shapeCached(shape)
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

function expectedFirstMs()
  return recentFirstMs or TUNING.firstUseGuessMs
end

function processLoads(diag)
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
      local isHeld = shape ~= nil and hold.shape[shape] == true        -- shape cache: a hidden holder keeps it loaded
      local wasHeld = isHeld
      -- a shape nobody holds and no instance keeps loaded: the holder loads it first (need channel), the create then retargets
      local needHold = shape ~= nil and TUNING.shapeCache and not isHeld and (shapeLive[shape] or 0) == 0 and not hold.isAbsent(shape)
      local isFirst = shape ~= nil and not seenShapes[shape] and not isHeld
      local isWarm = shape ~= nil and (isHeld or (shapeLive[shape] or 0) > 0)    -- a live instance keeps the shape loaded
      if (isFirst or needHold) and made > 0 then
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
      local needMs = nil
      if needHold then
        local okHold, holdMs = hold.add(shape, "need")
        if okHold then
          needMs = holdMs
          if not isFirst then firstUse = firstUse + 1 end          -- a first use counts itself below
        end
      end
      local createStart = os.clock()
      local diagCreateStart = diag and diag:now()
      local obj, err = createStreamedObject(item, nil, diag)
      local createOnlyMs = (os.clock() - createStart) * 1000       -- the create itself; createMs adds the hold it waited for
      local createMs = createOnlyMs + (needMs or 0)
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
          pr.n, pr.ms = pr.n + 1, pr.ms + createOnlyMs
          if createOnlyMs > pr.max then pr.max = createOnlyMs end
        end
        hold.noteCreate(needMs and "cold" or (wasHeld and "held" or (isWarm and "live" or "cold")), createMs, shape)
        if split.path == "shell-refill" then
          if needMs then hold.stats.retargetFilled = hold.stats.retargetFilled + 1
          elseif wasHeld then hold.stats.retargetHeld = hold.stats.retargetHeld + 1 end
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

function processUnloads(diag)
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

-- Drops every job and the section selection: queues, pending lists, held-back items, section reads, unloads.
-- Nothing that was queued can create an object afterwards; the next frame looks the camera's section up again.
function clearWork()
  currentSectionID, activeSet = nil, {}
  hold.always.dirty = true                                      -- the always-loaded sections come back on the next frame
  sectionRead, sectionReading = {}, {}
  sectionReadQueue, srHead, srTail = {}, 1, 0
  loadQueue, lqHead, lqTail, queuedKeys = {}, 1, 0, {}
  priQueue, pqHead, pqTail, promotedTotal = {}, 1, 0, 0
  pending, pendingCount, deferred = {}, 0, {}
  pendingUnload, unloadQueue, uqHead, uqTail = {}, {}, 1, 0
  selectTimer = 1e9                                                -- look up at once after a reset
  cameraSectionID, predictedSectionID, aheadCandidate, aheadTime = nil, nil, nil, 0
  feedOrder, priorityTimer = {}, 0
  hold.visit = nil
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
