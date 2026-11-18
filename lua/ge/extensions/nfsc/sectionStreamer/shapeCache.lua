-- nfsc_sectionStreamer, part "shapeCache": shape index scan, placeholders, mesh warming (idle lane and need channel), RAM floor, visits and the cache status.
-- Loaded by sectionStreamer.lua into the shared streamer environment; every name here is shared with the other parts.

-- ---------------------------------------------------------------------------
-- Shape cache warm-up (idle lane, see header)
-- ---------------------------------------------------------------------------
function newWarm()
  return { loaded = false, names = {}, bySection = {}, total = 0, done = {}, processed = 0,
           near = {}, nearPos = 1, nearFor = false, cursor = 1, idle = 0, gap = 0,
           hadCdae = 0, imported = 0, failed = 0, skipped = 0, importMs = 0, importMax = 0, importMaxShape = nil,
           current = nil, finished = false,
           phase = "waiting: idle timer", runSeconds = 0, slow = {}, scan = nil, terrain = {}, terrainN = 0 }      -- progress readout: lane phase, time spent running, slowest imports
end
warm = newWarm()

function loadShapeList()
  warm = newWarm()
  local ids = {}
  for id in pairs(sectionIndex) do ids[#ids + 1] = id end
  table.sort(ids)
  if #ids == 0 then logMsg("D", "no streamed sections: the shape cache warm-up is off"); return end
  warm.scan = { ids = ids, pos = 1, perSection = {}, counts = {}, terrain = {}, unique = 0, files = 0, failed = 0, records = 0,
                ms = 0, runSeconds = 0, idle = 0, done = false }
  logMsg("D", "shape names are indexed from the %d section files %s", #ids, TUNING.indexBeforeStreaming and "first, before any section is streamed" or "while nothing is queued")
end

-- ---------------------------------------------------------------------------
-- Shape cache: one hidden holder object per shape (see the header)
-- ---------------------------------------------------------------------------
-- Everything below hangs off the table `hold`: the main chunk is close to Lua's 200 locals limit and a LuaJIT
-- function may reach 60 upvalues at most, so the lane adds no local and no function with many upvalues.
function hold.statsNew()
  local function c() return { n = 0, ms = 0, max = 0 } end
  return { creates = { held = c(), live = c(), cold = c() }, needN = 0, needMs = 0, idleN = 0, idleMs = 0,
           retargetHeld = 0, retargetFilled = 0, coldBeforeFill = 0, stallMs = 0,
           pauses = { busy = 0, heavy = 0, ram = 0, moving = 0, cap = 0 },
           visits = 0, vReady = 0, vLate = 0, vDropped = 0, vTeleport = 0, nLate = 0, nDropped = 0,
           ready = {}, readySum = 0, readyN = 0, readyMin = nil, fullSum = 0, fullN = 0, fullMax = 0, coldSum = 0, coldN = 0,
           idleOff = nil, ambient = 0 }
end
hold.stats = hold.statsNew()

function hold.reset()
  hold.shape, hold.ids, hold.held, hold.cursor, hold.failed = {}, {}, 0, 1, 0
  hold.ms, hold.max, hold.maxShape, hold.group, hold.idle, hold.seconds, hold.complete = 0, 0, nil, nil, 0, 0, false
  hold.runSeconds, hold.phase, hold.slow, hold.started = 0, "off", {}, false
  hold.lane, hold.laneReason, hold.lastHoldMs, hold.lastShape, hold.gap, hold.lastPause = "asleep", nil, 0, nil, 0, nil
  hold.absent, hold.absentN, hold.tries, hold.deferred, hold.deferredN = {}, 0, {}, {}, 0
  hold.rings, hold.ringPos, hold.pass, hold.secIdx, hold.shpIdx, hold.nearFor, hold.nearAt, hold.adj = {}, 1, 1, 1, 1, nil, 0, nil
  hold.islandId, hold.islandSet, hold.islandN, hold.islandHeld, hold.islandSections = nil, nil, 0, 0, 0
  hold.still, hold.evicted, hold.evictKey = 0, 0, nil
  hold.ph, hold.phN, hold.visit, hold.visitTimer = {}, 0, nil, 0
end

-- Keeps the 10 slowest loads of a lane (shape, ms, channel), slowest first.
function hold.noteSlow(list, name, ms, kind)
  local n = #list
  if n >= 10 and ms <= list[n].ms then return end
  list[n + 1] = { name = name, ms = ms, kind = kind }
  table.sort(list, function(a, b) return a.ms > b.ms end)
  if #list > 10 then list[#list] = nil end
end

-- Cost table: the load time measured for every shape, kept between sessions so a heavy shape is known before it is
-- held again (heavy shapes wait for a still camera). A shape not in it has never been measured.
function hold.costLoad()
  hold.cost, hold.costDirty = {}, 0
  local ok, data = pcall(jsonReadFile, levelRoot .. "/lua/streamer/shape_costs.json")
  if ok and type(data) == "table" then
    for name, ms in pairs(data) do
      if type(name) == "string" and type(ms) == "number" then hold.cost[name] = ms end
    end
  end
end

function hold.costSave()
  if hold.costDirty <= 0 then return end
  hold.costDirty = 0
  local ok, err = pcall(jsonWriteFile, levelRoot .. "/lua/streamer/shape_costs.json", hold.cost, true)
  if not ok then logMsg("W", "shape cache: the cost table could not be written: %s", tostring(err)) end
end

-- Memory: the Lua heap is always known. Free / available / process RAM need a source: M.setMemoryProvider(fn) with
-- fn returning { freeGB, availableGB, processGB }. Without one the RAM floor has nothing to compare and stays off.
function hold.memSample(force)
  local m = hold.mem
  local now = totalTime                                              -- streamer time, so the sampling follows the frames
  if not force and m.last and now - m.time < 1.0 then return m.last end
  m.time = now
  local kb = collectgarbage("count")
  if kb > m.luaPeakKB then m.luaPeakKB = kb end
  local s = { luaGB = kb / 1048576 }
  if m.provider then
    local ok, r = pcall(m.provider)
    if ok and type(r) == "table" then
      s.freeGB, s.availableGB, s.processGB = tonumber(r.freeGB), tonumber(r.availableGB), tonumber(r.processGB)
      if s.freeGB and (not m.minFree or s.freeGB < m.minFree) then m.minFree = s.freeGB end
      if s.availableGB and (not m.minAvail or s.availableGB < m.minAvail) then m.minAvail = s.availableGB end
      if s.processGB and (not m.peakProcess or s.processGB > m.peakProcess) then m.peakProcess = s.processGB end
    end
  end
  m.last = s
  return s
end

-- A shape the game has no file for (neither .dae nor .cdae): it is never held and not retried. Needs FS:fileExists.
function hold.isAbsent(name)
  local known = hold.absent[name]
  if known ~= nil then return known end
  local res = false
  if not fsUnavailable and type(name) == "string" then
    local fs = rawget(_G, "FS")
    if fs then
      local alt = name:sub(1, 1) == "/" and name:sub(2) or ("/" .. name)
      if fileExists(fs, name) == false and fileExists(fs, alt) == false then res = shapeCached(name) == false end
    end
  end
  hold.absent[name] = res
  if res then hold.absentN = hold.absentN + 1 end
  return res
end

-- The section files are read once, one per idle frame within shapeIndexBudgetShare, and every shapeName is collected.
-- Result: every unique shape once (widest use first) and per-section positions.
function hold.scanFinish(sc)
  local counts, names = sc.counts, {}
  for name in pairs(counts) do names[#names + 1] = name end
  table.sort(names, function(a, b)
    if counts[a] ~= counts[b] then return counts[a] > counts[b] end
    return a < b
  end)
  local position = {}
  for i = 1, #names do position[names[i]] = i end
  local bySection = {}
  for id, list in pairs(sc.perSection) do
    local out = {}
    for i = 1, #list do out[i] = position[list[i]] end
    table.sort(out)
    bySection[id] = out
  end
  warm.names, warm.total, warm.bySection, warm.loaded = names, #names, bySection, #names > 0
  hold.adj = nil                                                       -- the islands are made again with the new index
  hold.nearFor = nil                                                   -- and so is the ring walk (terrain shapes are known now)
  for name in pairs(sc.terrain) do warm.terrain[name], warm.terrainN = true, warm.terrainN + 1 end
  sc.done, sc.perSection, sc.counts, sc.terrain = true, nil, nil, nil               -- the working tables are no longer needed
  logMsg("D", "shape index built: %d unique shapes from %d section files (%d records, %d unreadable), %.1f s of reads in %.0f s of idle time",
    #names, sc.files, sc.records, sc.failed, sc.ms / 1000, sc.runSeconds)
end

-- Returns how many section files it read this frame.
-- True while the level-load indexing runs: the section files are read first and nothing is streamed meanwhile.
function hold.indexFirst()
  local sc = warm.scan
  return TUNING.indexBeforeStreaming and TUNING.shapeCache and sc ~= nil and not sc.done and initialized and not suspended
end

function hold.scanUpdate(dt)
  local sc = warm.scan
  if not sc or sc.done or suspended or not initialized then return 0 end
  if not TUNING.shapeCache then return 0 end                         -- nobody needs the names yet
  local first = TUNING.indexBeforeStreaming
  if not first then
    if not M.isIdle() then sc.idle = 0; return 0 end                 -- the section streamer goes first
    sc.idle = sc.idle + dt
    if sc.idle < ((TUNING.shapeCacheAtLoad and not hold.started) and 0 or TUNING.shapeCacheIdleSeconds) then return 0 end
  end
  sc.runSeconds = sc.runSeconds + dt
  local limit = first and TUNING.frameBudgetMs or fb.cap(TUNING.shapeIndexBudgetShare)
  local started, n = os.clock(), 0
  while sc.pos <= #sc.ids do
    if n > 0 and (os.clock() - started) * 1000 >= limit then break end
    local id = sc.ids[sc.pos]
    sc.pos = sc.pos + 1
    local t0 = os.clock()
    local ok, data = pcall(jsonReadFile, sectionIndex[id].file)
    n, sc.files = n + 1, sc.files + 1
    if ok and type(data) == "table" and type(data.objects) == "table" then
      local seen, list = {}, {}
      for i = 1, #data.objects do
        local rec = data.objects[i]
        local shape = type(rec) == "table" and rec.shapeName or nil
        if type(shape) == "string" and shape ~= "" then
          sc.records = sc.records + 1
          if isTerrainItem(rec) then sc.terrain[shape] = true end
          if not seen[shape] then
            seen[shape] = true
            list[#list + 1] = shape
            if not sc.counts[shape] then sc.unique = sc.unique + 1 end
            sc.counts[shape] = (sc.counts[shape] or 0) + 1
          end
        end
      end
      sc.perSection[id] = list
    else
      sc.failed = sc.failed + 1
      if sc.failed <= 5 then logMsg("W", "shape index: could not read section file %s", tostring(sectionIndex[id].file)) end
    end
    local ms = (os.clock() - t0) * 1000
    sc.ms = sc.ms + ms
    if ms >= TUNING.stallLogMs then logMsg("W", "slow shape index read: section %s %.0f ms", tostring(id), ms) end
  end
  if sc.pos > #sc.ids then hold.scanFinish(sc) end
  return n
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

-- Placeholders: hidden holders on the dot, built ahead of the fill cursor in a rolling window (shapeCachePlaceholders).
-- A hold takes one and only changes its shapeName, so the registerObject cost is paid earlier, in idle frames.
function hold.takePlaceholder()
  while hold.phN > 0 do
    local id = hold.ph[hold.phN]
    hold.ph[hold.phN] = nil
    hold.phN = hold.phN - 1
    local obj = scenetree.findObjectById(id)
    if obj then return obj end
  end
  return nil
end

function hold.placeholderStep()
  local want = math.min(TUNING.shapeCachePlaceholders, warm.total - hold.held - hold.absentN)
  if want <= 0 or hold.phN >= want then return 0 end
  local limit = fb.cap(TUNING.shapeCacheBudgetShare)
  if limit <= 0 then return 0 end
  local group = hold.ensureGroup()
  if not group then return 0 end
  local cam = core_camera and core_camera.getPosition and core_camera.getPosition()
  local pos = cam and string.format("%.3f %.3f %.3f", cam.x, cam.y, cam.z - 800) or "0 0 -800"
  local started, built = os.clock(), 0
  while hold.phN < want and built < 8 do
    local obj = createObject("TSStatic")
    if not obj then break end
    pcall(function() obj.hidden = true end)
    pcall(obj.setField, obj, "shapeName", 0, TUNING.shellShape)
    pcall(obj.setField, obj, "position", 0, pos)
    pcall(obj.setField, obj, "collisionType", 0, "None")
    pcall(obj.setField, obj, "decalType", 0, "None")
    local okc, res = pcall(obj.registerObject, obj, "")
    if not (okc and res ~= false) then pcall(obj.delete, obj); break end
    pcall(group.addObject, group, obj)
    hold.phN = hold.phN + 1
    hold.ph[hold.phN] = obj:getID()
    built = built + 1
    if (os.clock() - started) * 1000 >= limit then break end
  end
  hold.phMs = hold.phMs + (os.clock() - started) * 1000
  return built
end

-- Holds one shape: a hidden object without collision that keeps it loaded for the rest of the session. channel is "idle"
-- (the fill lane) or "need" (a create wants a shape nobody holds yet). Returns true and the ms it took, or false.
function hold.add(name, channel)
  local group = hold.ensureGroup()
  if not group then return false, 0 end
  hold.tries[name] = (hold.tries[name] or 0) + 1
  local started = os.clock()
  local ok = false
  local obj = hold.takePlaceholder()
  if obj then
    pcall(obj.setField, obj, "shapeName", 0, name)             -- the load happens here, on the dot-wearing object
    pcall(obj.postApply, obj)
    ok = true
  else
    local cam = core_camera and core_camera.getPosition and core_camera.getPosition()
    local pos = cam and string.format("%.3f %.3f %.3f", cam.x, cam.y, cam.z - 800) or "0 0 -800"
    obj = createObject("TSStatic")
    if obj then
      pcall(function() obj.hidden = true end)
      pcall(obj.setField, obj, "shapeName", 0, name)
      pcall(obj.setField, obj, "position", 0, pos)
      pcall(obj.setField, obj, "collisionType", 0, "None")
      pcall(obj.setField, obj, "decalType", 0, "None")
      local okc, res = pcall(obj.registerObject, obj, "")
      ok = okc and res ~= false
      if ok then pcall(group.addObject, group, obj) else pcall(obj.delete, obj) end
    end
  end
  local ms = (os.clock() - started) * 1000
  local st = hold.stats
  if ok then
    hold.ids[name], hold.shape[name] = obj:getID(), true
    hold.held = hold.held + 1
    if hold.islandSet and hold.islandSet[name] then hold.islandHeld = hold.islandHeld + 1 end
    hold.ms, hold.lastHoldMs, hold.lastShape = hold.ms + ms, ms, name
    if channel == "need" then st.needN, st.needMs = st.needN + 1, st.needMs + ms
    else st.idleN, st.idleMs = st.idleN + 1, st.idleMs + ms end
    hold.noteSlow(hold.slow, name, ms, channel)
    if ms > hold.max then hold.max, hold.maxShape = ms, name end
    hold.cost[name] = math.floor(ms * 10 + 0.5) / 10
    hold.costDirty = hold.costDirty + 1
    if channel ~= "need" and ms >= TUNING.shapeCacheHeavyMs then hold.lastHitch = { name = name, ms = ms } end
    if TUNING.debugLog and TUNING.shapeCacheLogEvery > 0 and hold.held % TUNING.shapeCacheLogEvery == 0 then
      logMsg("I", "shape cache: %d of %d shapes held (%d failed), avg %.2f ms, max %.0f ms (%s)",
        hold.held, warm.total, hold.failed, hold.ms / hold.held, hold.max, shortShapeName(hold.maxShape or "?"))
    end
  else
    hold.failed = hold.failed + 1
    if hold.failed <= 10 then logMsg("W", "shape cache: %s could not be held", shortShapeName(name)) end
  end
  if ms >= TUNING.stallLogMs then logMsg("W", "slow mesh hold: %s %.0f ms (%s)", shortShapeName(name), ms, tostring(channel)) end
  return ok, ms
end

-- Deletes the holders and placeholders (a batch per call). Returns true when all are gone and the group too.
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
  while hold.phN > 0 do
    local obj = scenetree.findObjectById(hold.ph[hold.phN])
    if obj then pcall(obj.delete, obj) end
    hold.ph[hold.phN] = nil
    hold.phN = hold.phN - 1
    n = n + 1
    if n >= batch then return false end
  end
  local g = scenetree.findObject(TUNING.warmGroupName)
  if g then pcall(g.delete, g) end
  if hold.group or hold.costDirty > 0 then logMsg("D", "shape cache: holders released") end
  hold.costSave()
  hold.reset()
  return true
end

-- Fill order ---------------------------------------------------------------------------------------------------------
-- Sections are connected through their relations, and those connections form self-contained islands (the city is one big
-- island, the canyons and districts away from it are others). The fill takes only the island the camera is in: the section
-- it is in first, then its related sections, then theirs, outward by hops. Within a hop ring the shapes of terrain-like
-- objects (IdentityMatrix / ChoppedRoadway) come before the rest. Another island is never touched until the camera is in it.
function hold.adjacency()
  if hold.adj then return hold.adj end
  -- sections.json holds the drivable sections only. Their related lists also name sections that are not drivable
  -- (scenery only, known to the stream index): those are part of the island, their meshes are held, but they are leaves,
  -- so the walk never goes on through them into another island.
  local adj = {}
  for id in pairs(sections) do adj[id] = {} end
  for id in pairs(sections) do
    local rel = M.getRelatedSections(id)
    for i = 1, #rel do
      local o = rel[i]
      if o ~= id then
        if sections[o] then
          adj[id][o], adj[o][id] = true, true
        elseif warm.bySection[o] then
          adj[id][o] = true
          adj[o] = adj[o] or {}                        -- a leaf: nothing to expand from
        end
      end
    end
  end
  -- The island of every drivable section, named by its lowest section id, made once here (not polled while driving).
  local islandOf = {}
  for id in pairs(sections) do
    if not islandOf[id] then
      local members, stack, minId = { id }, { id }, id
      islandOf[id] = true
      while #stack > 0 do
        local cur = stack[#stack]
        stack[#stack] = nil
        for o in pairs(adj[cur]) do
          if sections[o] and not islandOf[o] then
            islandOf[o] = true
            members[#members + 1], stack[#stack + 1] = o, o
            if o < minId then minId = o end
          end
        end
      end
      for i = 1, #members do islandOf[members[i]] = minId end
    end
  end
  hold.adj, hold.islandOf = adj, islandOf
  return adj
end

-- Called on every section change (not polled): entering a section of another island makes the preload switch to that island,
-- whatever the lane was doing (an island that is held does not wake the walk by itself).
function hold.sectionEntered(newID)
  if not newID or not TUNING.shapeCache or warm.total <= 0 or next(warm.bySection) == nil then return end
  hold.adjacency()
  local island = hold.islandOf[newID]
  if island and island ~= hold.islandId then hold.nearRebuild() end
end

-- Outside every section (a spawn, a jump): the nearest section stands in as the start.
function hold.nearestSection(adj)
  if not camPos then return nil end
  local best, bestD
  for id in pairs(adj) do
    if sections[id] and warm.bySection[id] then
      local d = isInSection(camPos, id) and 0 or distanceToPolygonEdges(camPos, sections[id].points)
      if not bestD or d < bestD then best, bestD = id, d end
    end
  end
  return best
end

function hold.islandChange(seen, id)
  hold.islandId, hold.complete = id, false
  local set, n, held, secs = {}, 0, 0, 0
  for sid in pairs(seen) do
    secs = secs + 1
    local list = warm.bySection[sid]
    if list then
      for i = 1, #list do
        local name = warm.names[list[i]]
        if name and not set[name] then
          set[name], n = true, n + 1
          if hold.shape[name] then held = held + 1 end
        end
      end
    end
  end
  hold.islandSet, hold.islandN, hold.islandHeld, hold.islandSections = set, n, held, secs
  hold.deferred, hold.deferredN = {}, 0               -- the postponed heavy shapes belonged to the old island
  logMsg("D", "shape cache: island of section %s: %d sections, %d meshes (%d already held)", tostring(id), secs, n, held)
end

function hold.nearRebuild()
  hold.nearFor, hold.nearAt = hold.baseOf(currentSectionID), totalTime
  hold.rings, hold.ringPos, hold.pass, hold.secIdx, hold.shpIdx = {}, 1, warm.terrainN > 0 and 1 or 2, 1, 1
  local adj = hold.adjacency()
  local root = hold.baseOf(currentSectionID)
  if not (root and adj[root]) then root = hold.nearestSection(adj) end
  if not root then return end
  local seen, ring, rings, minId = { [root] = true }, { root }, {}, root
  while #ring > 0 do
    rings[#rings + 1] = ring
    local nextRing = {}
    for i = 1, #ring do
      for o in pairs(adj[ring[i]]) do
        if not seen[o] then
          seen[o] = true
          nextRing[#nextRing + 1] = o
          if sections[o] and o < minId then minId = o end
        end
      end
    end
    table.sort(nextRing)
    ring = nextRing
  end
  hold.rings = rings
  if hold.islandId ~= minId then hold.islandChange(seen, minId) end
end

-- true: hold it now. false: skip (held, absent, tried twice) or park it for a still camera (heavy, or a failed first try).
function hold.candidate(name, heavyOk)
  if hold.shape[name] or (hold.tries[name] or 0) >= 2 or hold.isAbsent(name) then return false end
  local cost = hold.cost[name]
  if cost and cost > TUNING.shapeCacheHeavyMs and not heavyOk then
    if not hold.deferred[name] then hold.deferred[name], hold.deferredN = true, hold.deferredN + 1 end
    return false
  end
  return true
end

-- Returns the next shape to hold, or nil and why: "done" (the island is held), "heavy" (only heavy shapes left, the camera
-- is moving), "scan" (a long run of held shapes was skipped, the walk goes on next frame).
function hold.nextShape()
  local heavyOk = (not TUNING.shapeCacheHeavyWait) or hold.still >= TUNING.shapeCacheStillSeconds
  if heavyOk and hold.deferredN > 0 then
    local name = next(hold.deferred)
    hold.deferred[name], hold.deferredN = nil, hold.deferredN - 1
    if not hold.shape[name] and (hold.tries[name] or 0) < 2 and not hold.isAbsent(name) then return name end
  end
  if next(warm.bySection) == nil then                                 -- a pack without per-section lists: the whole index is the island
    if not hold.islandId then
      hold.islandId, hold.islandSet, hold.islandN, hold.islandSections = 0, {}, warm.total, 0
      for i = 1, warm.total do hold.islandSet[warm.names[i]] = true end
    end
    local steps = 0
    while hold.cursor <= warm.total and steps < 512 do
      local name = warm.names[hold.cursor]
      hold.cursor, steps = hold.cursor + 1, steps + 1
      if name and hold.candidate(name, heavyOk) then return name end
    end
    if hold.cursor <= warm.total then return nil, "scan" end
    return nil, hold.deferredN > 0 and "heavy" or "done"
  end
  if hold.nearFor ~= hold.baseOf(currentSectionID) or (hold.islandId == nil and #hold.rings == 0 and totalTime - hold.nearAt > 1.0) then
    hold.nearRebuild()
  end
  local steps = 0
  while hold.ringPos <= #hold.rings and steps < 512 do
    local ring = hold.rings[hold.ringPos]
    if hold.secIdx > #ring then
      hold.secIdx, hold.shpIdx = 1, 1
      if hold.pass == 1 then hold.pass = 2
      else hold.pass, hold.ringPos = warm.terrainN > 0 and 1 or 2, hold.ringPos + 1 end
    else
      local list = warm.bySection[ring[hold.secIdx]]
      if not list or hold.shpIdx > #list then
        hold.secIdx, hold.shpIdx = hold.secIdx + 1, 1
      else
        local name = warm.names[list[hold.shpIdx]]
        hold.shpIdx, steps = hold.shpIdx + 1, steps + 1
        if name and (hold.pass == 2 or warm.terrain[name]) and hold.candidate(name, heavyOk) then return name end
      end
    end
  end
  if hold.ringPos <= #hold.rings then return nil, "scan" end
  if #hold.rings == 0 then return nil, "none" end                     -- no section to start from
  return nil, hold.deferredN > 0 and "heavy" or "done"
end


-- Visits: readiness at entry and the dropped-section rule ------------------------------------------------------------
-- A section is ready when every shape of it is held (absent shapes do not count).
function hold.sectionState(id)
  local list = warm.bySection[id]
  if not list then return 0, 0 end
  local held, total = 0, 0
  for i = 1, #list do
    local name = warm.names[list[i]]
    if name and not hold.isAbsent(name) then
      total = total + 1
      if hold.shape[name] then held = held + 1 end
    end
  end
  return held, total
end

function hold.related(fromID, toID)
  local list = M.getRelatedSections(fromID)
  for i = 1, #list do if list[i] == toID then return true end end
  return false
end

function hold.visitCheck(v)
  local t = totalTime - v.t0
  local allReady = true
  if not v.readyAt then
    local h, n = hold.sectionState(v.id)
    if h >= n then v.readyAt = t else allReady = false end
  end
  v.ready = 0
  for id, e in pairs(v.neigh) do
    if not e.readyAt then
      local h, n = hold.sectionState(id)
      if h >= n then e.readyAt = t end
    end
    if e.readyAt then v.ready = v.ready + 1 else allReady = false end
  end
  if allReady and not v.fullAt then v.fullAt = t end
end

-- The visit to a section ended (the camera went on): late = a neighbour that was not ready at entry was ready by exit,
-- dropped = it was still not ready. A teleport (the section is not in the related list of the one before) is left out and
-- its time to ready is the cold-start cost.
function hold.visitClose(v)
  hold.visitCheck(v)
  local st = hold.stats
  if v.teleport then
    st.vTeleport = st.vTeleport + 1
    st.coldSum, st.coldN = st.coldSum + (v.readyAt or (totalTime - v.t0)), st.coldN + 1
    return
  end
  st.visits = st.visits + 1
  local missed, dropped = 0, 0
  for _, e in pairs(v.neigh) do
    if not e.ready0 then
      missed = missed + 1
      if e.readyAt then st.nLate = st.nLate + 1 else st.nDropped, dropped = st.nDropped + 1, dropped + 1 end
    end
  end
  if missed == 0 then st.vReady = st.vReady + 1
  elseif dropped > 0 then st.vDropped = st.vDropped + 1
  else st.vLate = st.vLate + 1 end
  local frac = v.entryTotal > 0 and v.entryHeld / v.entryTotal or 1
  st.readyN, st.readySum = st.readyN + 1, st.readySum + frac
  if not st.readyMin or frac < st.readyMin then st.readyMin = frac end
  if #st.ready < 4096 then st.ready[#st.ready + 1] = frac end
  if v.fullAt then
    st.fullN, st.fullSum = st.fullN + 1, st.fullSum + v.fullAt
    if v.fullAt > st.fullMax then st.fullMax = v.fullAt end
  end
end

function hold.visitChange(oldID, newID)
  if hold.visit then hold.visitClose(hold.visit) end
  hold.visit = nil
  if not newID or not TUNING.shapeCache or warm.total <= 0 then return end
  local v = { id = newID, t0 = totalTime, neigh = {}, cold = 0, ready = 0, neighN = 0 }
  v.teleport = oldID == nil or (oldID ~= newID and not hold.related(oldID, newID))
  v.entryHeld, v.entryTotal = hold.sectionState(newID)
  if v.entryHeld >= v.entryTotal then v.readyAt = 0 end
  local allReady = v.readyAt ~= nil
  local rel = M.getRelatedSections(newID)
  for i = 1, #rel do
    local id = rel[i]
    if id ~= newID and not v.neigh[id] then
      local h, n = hold.sectionState(id)
      local e = { ready0 = h >= n }
      if e.ready0 then e.readyAt = 0; v.ready = v.ready + 1 else allReady = false end
      v.neigh[id], v.neighN = e, v.neighN + 1
    end
  end
  if allReady then v.fullAt = 0 end
  hold.visit = v
end

function hold.visitUpdate(dt)
  local v = hold.visit
  if not v then return end
  hold.visitTimer = hold.visitTimer + dt
  if hold.visitTimer < 0.5 then return end
  hold.visitTimer = 0
  hold.visitCheck(v)
end

-- One create finished: class "held" (the shape was held), "live" (an instance kept it loaded) or "cold" (it had to be loaded:
-- the ms then include the hold the create waited for).
function hold.noteCreate(cls, ms, name)
  local c = hold.stats.creates[cls]
  c.n, c.ms = c.n + 1, c.ms + ms
  if ms > c.max then c.max = ms end
  if cls == "cold" then
    hold.stats.stallMs = hold.stats.stallMs + ms
    if not hold.complete then hold.stats.coldBeforeFill = hold.stats.coldBeforeFill + 1 end
    if hold.visit then hold.visit.cold = hold.visit.cold + 1 end
  end
  if ms >= TUNING.shapeCacheHeavyMs then hold.lastHitch = { name = name, ms = ms } end
end

-- Over the cap (Max meshes to save, or after moving to another island): deletes holders of shapes the current island does not
-- use and no live object keeps, a few per call. Returns how many it deleted.
function hold.evictStep(cap)
  local n, k = 0, hold.evictKey
  for _ = 1, 256 do
    local okNext, name, id = pcall(next, hold.ids, k)
    if not okNext or name == nil then k = nil; break end             -- a changed table: start over next time
    k = name
    if not (hold.islandSet and hold.islandSet[name]) and (shapeLive[name] or 0) == 0 then
      local obj = scenetree.findObjectById(id)
      if obj then pcall(obj.delete, obj) end
      hold.ids[name], hold.shape[name] = nil, nil
      hold.held, hold.evicted, n = hold.held - 1, hold.evicted + 1, n + 1
      if hold.held <= cap or n >= 16 then break end
    end
  end
  hold.evictKey = k
  return n
end

function hold.pause(reason, phase)
  hold.lane, hold.laneReason, hold.phase = "paused", reason, phase
  if hold.lastPause ~= reason then
    hold.lastPause = reason
    local p = hold.stats.pauses
    if p[reason] ~= nil then p[reason] = p[reason] + 1 end
  end
end

-- The lane, once per frame, only while nothing is queued. Returns how many shapes (and placeholders) it made.
function hold.update(dt)
  if not TUNING.shapeCache then
    hold.lane, hold.laneReason = "asleep", nil
    hold.phase = (hold.held > 0 or hold.phN > 0) and "releasing" or "off"
    if hold.held > 0 or hold.phN > 0 or hold.group then hold.release(512) end
    return 0
  end
  if suspended or not initialized or warm.total <= 0 then
    hold.lane, hold.laneReason = "asleep", nil
    hold.phase = (not initialized and "starting") or (suspended and "suspended")
      or ((warm.scan and not warm.scan.done) and "waiting: indexing shape names") or "no shape names"
    return 0
  end
  hold.visitUpdate(dt)
  local mem = hold.memSample()
  hold.seconds = hold.seconds + dt
  local speed = math.sqrt(camVel.x * camVel.x + camVel.y * camVel.y)
  if speed < 0.5 then hold.still = hold.still + dt else hold.still = 0 end
  if hold.complete then hold.lane, hold.laneReason, hold.phase = "asleep", nil, "island held"; return 0 end
  if hold.paused then hold.pause("user", "paused by the Pause fill button"); return 0 end
  if not M.isIdle() then hold.idle = 0; hold.pause("busy", "waiting: sections are streaming"); return 0 end   -- the section streamer goes first
  hold.idle = hold.idle + dt
  if hold.idle < ((TUNING.shapeCacheAtLoad and not hold.started) and 0 or TUNING.shapeCacheIdleSeconds) then
    hold.pause("busy", "waiting: idle timer"); return 0
  end
  local cap = TUNING.shapeCacheMax
  if hold.held > cap then
    hold.lane, hold.laneReason, hold.phase = "filling", nil, "releasing meshes over Max meshes to save"
    if hold.evictStep(cap) > 0 then return 1 end
  end
  if not TUNING.shapeCacheAlways and hold.still < TUNING.shapeCacheStillSeconds and not (TUNING.shapeCacheAtLoad and not hold.started) then
    hold.pause("moving", "waiting: the car is moving (Preload always is off)"); return 0
  end
  if hold.held == 0 and idleFrameMs and not hold.stats.idleOff then hold.stats.idleOff = idleFrameMs end   -- idle frame with no holders
  local floor = TUNING.shapeCacheRamFloorGB
  if floor > 0 and mem and mem.freeGB then
    if mem.freeGB < floor then
      if not hold.ramPaused then
        hold.ramPaused = true
        logMsg("W", "shape cache: paused, free RAM %.2f GB is under the floor of %.2f GB", mem.freeGB, floor)
      end
      hold.pause("ram", "waiting: free RAM under the floor")
      return 0
    end
    if hold.ramPaused then
      hold.ramPaused = false
      logMsg("D", "shape cache: resumed, free RAM %.2f GB", mem.freeGB)
    end
  end
  if hold.gap > 0 then
    hold.gap = hold.gap - dt
    if hold.gap > 0 then hold.lane, hold.laneReason, hold.phase = "filling", nil, "holding (gap)"; return 0 end
  end
  local limit = fb.cap(TUNING.shapeCacheBudgetShare)
  if limit <= 0 then hold.pause("busy", "waiting: frame budget spent"); return 0 end
  hold.lane, hold.laneReason, hold.phase, hold.lastPause = "filling", nil, "holding", nil
  hold.runSeconds = hold.runSeconds + dt
  local started, made = os.clock(), hold.placeholderStep()
  local holds = 0
  while holds < TUNING.shapeCachePerFrame do
    if holds > 0 and (os.clock() - started) * 1000 >= limit then break end
    if hold.held >= cap then
      hold.pause("cap", "Max meshes to save reached")
      break
    end
    local name, why = hold.nextShape()
    if not name then
      if why == "done" then
        hold.complete, hold.lane, hold.phase = true, "asleep", "complete"
        hold.costDirty = hold.costDirty + 1
        hold.costSave()
        logMsg("D", "shape cache: the island is held: %d of %d meshes held (%d failed, %d absent), avg %.2f ms per shape, %.0f s (%.0f s of it holding)",
          hold.islandHeld, hold.islandN, hold.failed, hold.absentN, hold.held > 0 and hold.ms / hold.held or 0, hold.seconds, hold.runSeconds)
      elseif why == "heavy" then
        hold.pause("heavy", "waiting: heavy shapes wait for a still camera")
      elseif why == "none" then
        hold.lane, hold.laneReason, hold.phase = "asleep", nil, "waiting: no section to start from"
      end
      break
    end
    hold.started = true
    hold.add(name, "idle")
    holds, made = holds + 1, made + 1
    if TUNING.shapeCacheGapSeconds > 0 then hold.gap = TUNING.shapeCacheGapSeconds; break end
  end
  if hold.costDirty >= 500 then hold.costSave() end
  return made
end

-- Progress of the shape cache (panel and console). lane: "asleep" | "filling" | "paused" (+ reason).
function M.getShapeCacheStatus()
  local st, v, m = hold.stats, hold.visit, hold.memSample()
  local remaining = math.max(0, warm.total - hold.held - hold.failed - hold.absentN)
  local sorted, p10 = {}, nil
  for i = 1, #st.ready do sorted[i] = st.ready[i] end
  table.sort(sorted)
  if #sorted > 0 then p10 = sorted[math.max(1, math.ceil(#sorted * 0.1))] end
  return {
    enabled = TUNING.shapeCache, available = warm.total > 0, total = warm.total, held = hold.held, failed = hold.failed,
    absent = hold.absentN, remaining = remaining, complete = hold.complete, paused = hold.paused,
    placeholders = hold.phN, placeholderWindow = TUNING.shapeCachePlaceholders,
    island = { id = hold.islandId, sections = hold.islandSections, meshes = hold.islandN, held = hold.islandHeld },
    max = TUNING.shapeCacheMax, always = TUNING.shapeCacheAlways, evicted = hold.evicted,
    lane = hold.lane, laneReason = hold.laneReason, phase = hold.phase, current = hold.lastShape, lastHoldMs = hold.lastHoldMs,
    avgMs = hold.held > 0 and hold.ms / hold.held or 0, maxMs = hold.max, maxShape = hold.maxShape,
    seconds = hold.seconds, runSeconds = hold.runSeconds, slow = hold.slow, deferredHeavy = hold.deferredN,
    etaSeconds = (hold.held > 0 and hold.runSeconds > 0) and remaining * hold.runSeconds / hold.held or nil,
    visit = v and { id = v.id, ready = v.ready, neighbours = v.neighN, cold = v.cold, teleport = v.teleport,
                    entryHeld = v.entryHeld, entryTotal = v.entryTotal, readyAt = v.readyAt } or nil,
    lastHitch = hold.lastHitch, memory = m, ramPaused = hold.ramPaused == true, ramFloor = TUNING.shapeCacheRamFloorGB,
    ramSource = hold.mem.provider ~= nil, minFreeGB = hold.mem.minFree, peakProcessGB = hold.mem.peakProcess,
    luaPeakGB = hold.mem.luaPeakKB / 1048576,
    creates = st.creates, needN = st.needN, needMs = st.needMs, idleN = st.idleN, idleMs = st.idleMs,
    stallMs = st.stallMs, retargetHeld = st.retargetHeld, retargetFilled = st.retargetFilled, coldBeforeFill = st.coldBeforeFill,
    pauses = st.pauses, visits = st.visits, visitsReady = st.vReady, visitsLate = st.vLate, visitsDropped = st.vDropped,
    visitsTeleport = st.vTeleport, neighboursLate = st.nLate, neighboursDropped = st.nDropped,
    readinessAvg = st.readyN > 0 and st.readySum / st.readyN or nil, readinessP10 = p10, readinessMin = st.readyMin,
    fullAvgSeconds = st.fullN > 0 and st.fullSum / st.fullN or nil, fullMaxSeconds = st.fullMax,
    coldStartAvgSeconds = st.coldN > 0 and st.coldSum / st.coldN or nil,
    ambientRestarts = st.ambient, idleFrameOffMs = st.idleOff, idleFrameOnMs = hold.held > 0 and idleFrameMs or nil,
  }
end

function M.setShapeCache(flag) TUNING.shapeCache = flag and true or false end
function M.pauseShapeCache(flag) hold.paused = flag and true or false end

-- Forgets what the lane tried (shapes that failed twice, heavy shapes waiting) and walks the index again; held shapes stay held.
function M.restartShapeCache()
  hold.cursor, hold.tries, hold.deferred, hold.deferredN, hold.complete = 1, {}, {}, 0, false
  hold.rings, hold.ringPos, hold.pass, hold.secIdx, hold.shpIdx, hold.nearFor, hold.paused = {}, 1, 1, 1, 1, nil, false
end

-- fn() returns { freeGB, availableGB, processGB } (any may be nil). Without a provider the RAM floor has nothing to compare.
function M.setMemoryProvider(fn) hold.mem.provider = type(fn) == "function" and fn or nil end

-- The shape cache lines of the run summary: key=value, fixed order, units in the names (header cacher-log v1).
function hold.logSummary()
  if not TUNING.debugLog then return end
  local s = M.getShapeCacheStatus()
  local function onOff(v) return v and "on" or "off" end
  local function pct(v) return v and string.format("%.0f", v * 100) or "n/a" end
  local function cls(c) return string.format("n=%d avg_ms=%.2f max_ms=%.1f", c.n, c.n > 0 and c.ms / c.n or 0, c.max) end
  logMsg("I", "cacher-log v1 cfg shapeCache=%s atLoad=%s idle_s=%.2f gap_s=%.2f perFrame=%d share=%.3f ramFloor_gb=%.2f heavy_ms=%.1f heavyWait=%s still_s=%.2f placeholders=%d residentMax=%d mode=%s",
    onOff(TUNING.shapeCache), onOff(TUNING.shapeCacheAtLoad), TUNING.shapeCacheIdleSeconds, TUNING.shapeCacheGapSeconds,
    TUNING.shapeCachePerFrame, TUNING.shapeCacheBudgetShare, TUNING.shapeCacheRamFloorGB, TUNING.shapeCacheHeavyMs,
    onOff(TUNING.shapeCacheHeavyWait), TUNING.shapeCacheStillSeconds, TUNING.shapeCachePlaceholders, TUNING.residentMax, tostring(TUNING.creationMode))
  logMsg("I", "cacher island=%s sections=%d meshes=%d island_held=%d max=%d evicted=%d always=%s", tostring(s.island.id), s.island.sections, s.island.meshes, s.island.held, s.max, s.evicted, tostring(s.always))
  logMsg("I", "cacher fill held=%d total=%d absent=%d failed=%d complete=%s phase=%q seconds=%.0f hold_s=%.0f placeholders=%d heavy_waiting=%d",
    s.held, s.total, s.absent, s.failed, tostring(s.complete), tostring(s.phase), s.seconds, s.runSeconds, s.placeholders, s.deferredHeavy)
  logMsg("I", "cacher creates held{%s} live{%s} cold{%s}", cls(s.creates.held), cls(s.creates.live), cls(s.creates.cold))
  logMsg("I", "cacher cost stall_ms=%.0f warm_ms=%.0f need_n=%d need_ms=%.0f idle_n=%d idle_ms=%.0f", s.stallMs, s.idleMs, s.needN, s.needMs, s.idleN, s.idleMs)
  logMsg("I", "cacher lane pauses_busy=%d pauses_moving=%d pauses_heavy=%d pauses_ram=%d pauses_cap=%d cold_before_fill=%d", s.pauses.busy, s.pauses.moving, s.pauses.heavy, s.pauses.ram, s.pauses.cap, s.coldBeforeFill)
  logMsg("I", "cacher retargets already_held=%d needed_fill=%d ambient_restarts=%d", s.retargetHeld, s.retargetFilled, s.ambientRestarts)
  logMsg("I", "cacher readiness_pct avg=%s p10=%s min=%s full_avg_s=%s full_max_s=%.1f", pct(s.readinessAvg), pct(s.readinessP10), pct(s.readinessMin),
    s.fullAvgSeconds and string.format("%.1f", s.fullAvgSeconds) or "n/a", s.fullMaxSeconds)
  logMsg("I", "cacher visits n=%d ready=%d late=%d dropped=%d teleport=%d cold_start_avg_s=%s neighbours_late=%d neighbours_dropped=%d old_rule_dropped=%d",
    s.visits, s.visitsReady, s.visitsLate, s.visitsDropped, s.visitsTeleport,
    s.coldStartAvgSeconds and string.format("%.1f", s.coldStartAvgSeconds) or "n/a", s.neighboursLate, s.neighboursDropped, droppedSections)
  local m, parts = s.memory or {}, {}
  for i = 1, math.min(10, #s.slow) do parts[i] = string.format("%s:%.0f", shortShapeName(s.slow[i].name), s.slow[i].ms) end
  logMsg("I", "cacher heavy top10_ms=%s", #parts > 0 and table.concat(parts, ",") or "none")
  logMsg("I", "cacher memory lua_gb=%.2f lua_peak_gb=%.2f free_gb=%s free_min_gb=%s avail_gb=%s process_gb=%s process_peak_gb=%s",
    m.luaGB or 0, s.luaPeakGB, m.freeGB and string.format("%.2f", m.freeGB) or "n/a", s.minFreeGB and string.format("%.2f", s.minFreeGB) or "n/a",
    m.availableGB and string.format("%.2f", m.availableGB) or "n/a", m.processGB and string.format("%.2f", m.processGB) or "n/a",
    s.peakProcessGB and string.format("%.2f", s.peakProcessGB) or "n/a")
  logMsg("I", "cacher idle_frame_ms holders_off=%s holders_on=%s", s.idleFrameOffMs and string.format("%.1f", s.idleFrameOffMs) or "n/a",
    s.idleFrameOnMs and string.format("%.1f", s.idleFrameOnMs) or "n/a")
end
