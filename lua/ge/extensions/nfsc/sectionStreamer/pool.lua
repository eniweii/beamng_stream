-- nfsc_sectionStreamer, part "pool": parked shells, the resident (dormant) pool, reviving, evicting, shell building and the creation modes.
-- Loaded by sectionStreamer.lua into the shared streamer environment; every name here is shared with the other parts.

-- Animated objects: playAmbient on, or an _anim shape. They stay out of the pool unless Animated objects in shells is on.
function hold.animated(item)
  if type(item) ~= "table" then return false end
  local v = item.playAmbient
  if v == true or v == 1 or v == "1" or v == "true" then return true end
  local shape = item.shapeName
  return type(shape) == "string" and shape:lower():find("_anim%.dae$") ~= nil
end

function hold.bypassPool(item)
  return not TUNING.animatedInShells and hold.animated(item)
end

-- ---------------------------------------------------------------------------
-- Shell pool (creationMode = "shells", see header)
-- ---------------------------------------------------------------------------
shellChecked, shellDisabled = false, false

-- true only when FS:fileExists is available and says the shell shape is not there
function shellShapeMissing()
  local fs = rawget(_G, "FS")
  if not fs then return false end
  local path = TUNING.shellShape
  local alt = path:sub(1, 1) == "/" and path:sub(2) or ("/" .. path)
  local ok1, a = pcall(function() return fs:fileExists(path) end)
  local ok2, b = pcall(function() return fs:fileExists(alt) end)
  if not ok1 and not ok2 then return false end
  return not ((ok1 and a) or (ok2 and b))
end

function shellMode()           -- true in "shells" and "resident": objects come from and go back to the pool
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

function residentMode()
  return TUNING.creationMode == "resident" and shellMode()
end

function poolTotal() return liveCount + dormantCount + shellFreeN end

function shellName()
  shellSerial = shellSerial + 1
  return "nfsc_shell_" .. shellSerial
end

-- The engine default of a field as text, read once from an object nobody has set anything on.
function shellDefault(field)
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

function forceNoCollision(obj)
  if TUNING.forceCollisionNone then
    do local ok_, e_ = pcall(obj.setField, obj, "collisionType", 0, "None") if not ok_ then engineFail("pool.setField", e_, "collisionType") end end
    do local ok_, e_ = pcall(obj.setField, obj, "decalType", 0, "None") if not ok_ then engineFail("pool.setField", e_, "decalType") end end
  end
end

-- Free shells, indexed by the shape they wear: shellFreeDot (parked on the dot shape) and shellFreeByShape[shape] (evicted
-- from the resident pool, still wearing their old shape). shellFreeInfo[id] = { shape, at } gives O(1) removal. A shell that
-- wears the shape an item needs skips the shapeName write; otherwise a dot shell is taken first so shaped ones stay available.
function freeShellAdd(id, shape)
  if shape == TUNING.shellShape then shape = nil end
  local list
  if shape then
    list = shellFreeByShape[shape]
    if not list then list = {}; shellFreeByShape[shape] = list end
  else
    list = shellFreeDot
  end
  list[#list + 1] = id
  shellFreeInfo[id] = { shape = shape, at = #list }
  shellFreeN = shellFreeN + 1
end

function freeShellRemove(id)
  local info = shellFreeInfo[id]
  if not info then return end
  local list = info.shape and shellFreeByShape[info.shape] or shellFreeDot
  local at, lastAt = info.at, #list
  local last = list[lastAt]
  list[at] = last
  list[lastAt] = nil
  if last ~= id then shellFreeInfo[last].at = at end
  if info.shape and lastAt == 1 then shellFreeByShape[info.shape] = nil end
  shellFreeInfo[id] = nil
  shellFreeN = shellFreeN - 1
end

-- id of a free shell for this shape, removed from the pool; second value true when it already wears the shape.
function freeShellTake(shape)
  local list = shape and (shape == TUNING.shellShape and shellFreeDot or shellFreeByShape[shape])
  if list and #list > 0 then
    local id = list[#list]
    freeShellRemove(id)
    return id, true
  end
  if #shellFreeDot > 0 then
    local id = shellFreeDot[#shellFreeDot]
    freeShellRemove(id)
    return id, false
  end
  local _, any = next(shellFreeByShape)
  if any then
    local id = any[#any]
    freeShellRemove(id)
    return id, false
  end
  return nil, false
end

-- Fields that are always written, never skipped as "unchanged": the transform (the sway manager moves live objects) and
-- playAmbient (hideAmbient / showAmbient change it behind shellFields).
SKIP_NEVER = { position = true, rotation = true, rotationEuler = true, rotationMatrix = true, scale = true, playAmbient = true }

-- Writes the item's fields into obj, skipping the ones whose text is what the previous item wrote. Resets what the previous
-- item had and this one has not. Returns the table of applied texts (id -> shellFields).
function hold.refillFields(obj, item, last)
  local applied = {}
  local skipNone = TUNING.forceCollisionNone
  for field, value in pairs(item) do
    if field ~= "shapeName" and not RESERVED[field] then
      local text = fieldText(value)
      if text ~= nil then
        if last and last[field] == text and not SKIP_NEVER[field] and not (skipNone and (field == "collisionType" or field == "decalType")) then
          shellStats.fieldsSkipped = shellStats.fieldsSkipped + 1
        else
          do local ok_, e_ = pcall(obj.setField, obj, field, 0, text) if not ok_ then engineFail("pool.setField", e_, field) end end
          shellStats.fieldsWritten = shellStats.fieldsWritten + 1
        end
        applied[field] = text
      end
    end
  end
  if last then
    for field in pairs(last) do
      if not applied[field] then do local ok_, e_ = pcall(obj.setField, obj, field, 0, shellDefault(field)) if not ok_ then engineFail("pool.setField", e_, field) end end end
    end
  end
  return applied
end

-- Debug setting: the game's show/hide node calls updateInstanceRenderData after it sets obj.hidden; the streamer's objects
-- use useInstanceRenderData but never did.
function hold.renderData(obj)
  if not TUNING.updateRenderData or not obj.updateInstanceRenderData then return end
  local ok_, e_ = pcall(obj.updateInstanceRenderData, obj)
  if not ok_ then engineFail("pool.updateInstanceRenderData", e_) end
end

-- Takes a parked shell and fills it in from item. Returns the object, or nil when no parked shell is left.
function acquireShell(item)
  while shellFreeN > 0 do
    local id, wears = freeShellTake(item.shapeName)
    if not id then break end
    local obj = scenetree.findObjectById(id)
    if obj then
      if wears then
        shellStats.shapeKept = shellStats.shapeKept + 1                       -- already wears the shape: no shapeName write
      else
        do local ok_, e_ = pcall(obj.setField, obj, "shapeName", 0, item.shapeName) if not ok_ then engineFail("pool.setField", e_, "shapeName") end end
      end
      shellFields[id] = hold.refillFields(obj, item, shellFields[id])
      forceNoCollision(obj)
      do local ok_, e_ = pcall(obj.postApply, obj) if not ok_ then engineFail("pool.postApply", e_) end end
      do local ok_, e_ = pcall(function() obj.hidden = false end) if not ok_ then engineFail("pool.hidden", e_) end end
      hold.renderData(obj)
      hold.showAmbient(obj, item)
      return obj
    end
    shellFields[id] = nil                            -- the engine lost it (level change, manual delete)
  end
  return nil
end

-- Releases an object to the pool instead of deleting it. false: the object is already gone.
function parkShell(id)
  local obj = scenetree.findObjectById(id)
  if not obj then shellFields[id] = nil; return false end
  do local ok_, e_ = pcall(function() obj.hidden = true end) if not ok_ then engineFail("pool.hidden", e_) end end
  hold.hideAmbient(obj, id)
  do local ok_, e_ = pcall(obj.setField, obj, "shapeName", 0, TUNING.shellShape) if not ok_ then engineFail("pool.setField", e_, "shapeName") end end
  do local ok_, e_ = pcall(obj.postApply, obj) if not ok_ then engineFail("pool.postApply", e_) end end
  freeShellAdd(id, nil)
  return true
end

-- One new parked shell. Returns true, or false and the reason.
function buildShell()
  local obj = createObject("TSStatic")
  if not obj then return false, "createObject(TSStatic) returned nil" end
  do local ok_, e_ = pcall(obj.setField, obj, "shapeName", 0, TUNING.shellShape) if not ok_ then engineFail("pool.setField", e_, "shapeName") end end
  forceNoCollision(obj)
  do local ok_, e_ = pcall(function() obj.hidden = true end) if not ok_ then engineFail("pool.hidden", e_) end end
  local ok, err = pcall(obj.registerObject, obj, shellName())
  if ok and err == false then ok, err = false, "the engine refused it (returned false)" end
  if not ok then
    do local ok_, e_ = pcall(obj.delete, obj) if not ok_ then engineFail("pool.delete", e_) end end
    return false, tostring(err)
  end
  local okId, id = pcall(obj.getID, obj)
  if not okId or not id or not scenetree.findObjectById(id) then return false, "the object is not alive after registerObject" end
  local group = ensureRuntimeGroup()
  do local ok_, e_ = pcall(group.addObject, group, obj) if not ok_ then engineFail("pool.addObject", e_) end end
  freeShellAdd(id, nil)
  shellStats.built = shellStats.built + 1
  return true
end

-- Remove a dormant key from the per-shape index in O(1). The last key fills the removed slot.
function removeDormantShapeIndex(key, d)
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
function deactivateDormant(key, entry)
  local obj = scenetree.findObjectById(entry.id)
  if not obj then shellFields[entry.id] = nil; return false end
  do local ok_, e_ = pcall(function() obj.hidden = true end) if not ok_ then engineFail("pool.hidden", e_) end end
  hold.hideAmbient(obj, entry.id)
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

function forgetDormantShape(d)
  if d.shape and shapeLive[d.shape] then
    local left = shapeLive[d.shape] - 1
    shapeLive[d.shape] = left > 0 and left or nil
  end
end

-- Revive: the object of this item's key, shown again as it was. nil when there is none.
function reviveDormant(item)
  local key = item.__streamKey
  local d = key and dormant[key]
  if not d then return nil end
  dormant[key] = nil
  dormantCount = dormantCount - 1
  removeDormantShapeIndex(key, d)
  forgetDormantShape(d)                                  -- registerLive counts it again
  local obj = scenetree.findObjectById(d.id)
  if not obj then shellFields[d.id] = nil; return nil end
  do local ok_, e_ = pcall(function() obj.hidden = false end) if not ok_ then engineFail("pool.hidden", e_) end end
  hold.renderData(obj)
  hold.showAmbient(obj, item)
  return obj
end

-- Reuse a deactivated resident with the requested shape, even when its old stream key differs.
-- Exact-key revival is attempted first. This path preserves shapeName and avoids a new registration.
function acquireDormantShape(item)
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
        shellFields[d.id] = hold.refillFields(obj, item, shellFields[d.id])
        forceNoCollision(obj)
        do local ok_, e_ = pcall(obj.postApply, obj) if not ok_ then engineFail("pool.postApply", e_) end end
        do local ok_, e_ = pcall(function() obj.hidden = false end) if not ok_ then engineFail("pool.hidden", e_) end end
        hold.renderData(obj)
        hold.showAmbient(obj, item)
        return obj
      end
      shellFields[d.id] = nil
    end
    list = dormantByShape[shape]
  end
  return nil
end

-- true when a resident can serve this item without a shape change (its own key, or one of the same shape).
function dormantAvailable(item)
  local key = item.__streamKey
  if key and dormant[key] then return true end
  local list = item.shapeName and dormantByShape[item.shapeName]
  return list ~= nil and #list > 0
end

-- Evicts the n oldest deactivated objects: their shells go to the free list as they are (hidden, old shape).
function evictOldest(n)
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
      freeShellAdd(d.id, d.shape)                        -- keeps wearing its shape: an item of that shape reuses it as it is
      shellStats.evicted = shellStats.evicted + 1
      change.residentEvicts = change.residentEvicts + 1
      done = done + 1
    end
  end
  if doHead > doTail then dormantOrder, doHead, doTail = {}, 1, 0 end
  return done
end

-- Every deactivated object back to the pool (mode switch): parked on the dot, or deleted.
function releaseDormant(deleteThem)
  local n = 0
  for key, d in pairs(dormant) do
    removeDormantShapeIndex(key, d)
    forgetDormantShape(d)
    if deleteThem then
      local obj = scenetree.findObjectById(d.id)
      if obj then do local ok_, e_ = pcall(obj.delete, obj) if not ok_ then engineFail("pool.delete", e_) end end end
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

-- The pool, resting and dropped-section state. Its own function: LuaJIT allows 60 upvalues per function and
-- resetState is already near that.
function resetPoolState()
  shellFreeDot, shellFreeByShape, shellFreeInfo, shellFreeN, shellFields = {}, {}, {}, 0, {}
  shellChecked, shellDisabled, shellBuildFails, shellBuildOff = false, false, 0, false
  dormant, dormantOrder, doHead, doTail, dormantCount = {}, {}, 1, 0, 0
  dormantByShape = {}
  droppedSections, droppedObjects, droppedLast = 0, 0, nil
  for k in pairs(shellStats) do shellStats[k] = 0 end
  hold.stats = hold.statsNew()
  run = newRun(totalTime)
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
  logMsg("D", "creation mode: %s", mode)
  return true
end

function M.getCreationMode() return TUNING.creationMode end

-- Deletes every parked shell; returns how many.
function M.clearShellPool()
  local n = 0
  for id in pairs(shellFreeInfo) do
    local obj = scenetree.findObjectById(id)
    if obj then do local ok_, e_ = pcall(obj.delete, obj) if not ok_ then engineFail("pool.delete", e_) end end end
    shellFields[id] = nil
    n = n + 1
  end
  shellFreeDot, shellFreeByShape, shellFreeInfo, shellFreeN = {}, {}, {}, 0
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

-- Builds parked shells ahead (TUNING.shellTarget) while nothing urgent is queued: a little per frame, never in a burst.
function shellBuildUpdate(diag)
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
function residentTrim()
  if not residentMode() or pqHead <= pqTail or dormantCount == 0 or fb.remaining() <= 0 then return 0 end
  local total = poolTotal()
  local over = total - TUNING.residentMax
  local short = TUNING.residentReserve - shellFreeN
  if over <= 0 and not (short > 0 and total >= TUNING.residentMax) then return 0 end
  return evictOldest(math.min(dormantCount, 8, math.max(over, short, 1)))
end
