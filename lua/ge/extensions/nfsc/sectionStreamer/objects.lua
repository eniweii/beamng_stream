-- nfsc_sectionStreamer, part "objects": the runtime group, field text, creating a streamed object, readback, the live registry, deleting, and hiding / showing the ambient geometry.
-- Loaded by sectionStreamer.lua into the shared streamer environment; every name here is shared with the other parts.

-- ---------------------------------------------------------------------------
-- Object creation / deletion
-- ---------------------------------------------------------------------------
function ensureRuntimeGroup()
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

function destroyRuntimeGroup()
  local g = scenetree.findObject(TUNING.runtimeGroupName)
  if g then pcall(g.delete, g) end
  runtimeGroup = nil
  if shellScratch then pcall(shellScratch.delete, shellScratch); shellScratch = nil end
end

function fieldText(value)
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

function itemSections(item)
  local ids = item.__streamSections
  if type(ids) == "table" then return ids end
  local out = {}
  for token in tostring(item.sectionID or ""):gmatch("[^,%s]+") do
    local n = tonumber(token)
    if n then out[#out + 1] = n end
  end
  return out
end

function anyActive(ids)
  for i = 1, #ids do
    if activeSet[ids[i]] then return true end
  end
  return false
end

function runtimeName(item, key)
  if TUNING.skipNameLookup then return "nfsc_" .. tostring(key) end
  local wanted = (type(item.name) == "string" and item.name ~= "") and item.name or ("nfsc_" .. key)
  if scenetree.findObject(wanted) then wanted = wanted .. "_s" .. tostring(key):gsub("[^%w]", ""):sub(-6) end
  return wanted
end

function createStreamedObject(item, nameOverride, diag)
  local shape = item.shapeName
  if type(shape) ~= "string" or shape == "" then return nil, "missing shapeName" end
  split.diagRegisterMs = nil
  local pooled = nameOverride == nil and shellMode() and not hold.bypassPool(item)      -- probe objects (named) and animated objects take the plain path
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

function verifyReadback(key, item, obj)
  if verified >= TUNING.verifyFirstN then return end
  verified = verified + 1
  local ok, pos = pcall(obj.getPosition, obj)
  local ok2, scl = pcall(obj.getScale, obj)
  local p, s = item.position or {}, item.scale or {}
  logMsg("D", "verify %s exported pos=(%s) scale=(%s) readback pos=%s scale=%s", tostring(key),
    table.concat(p, ", "), table.concat(s, ", "), ok and tostring(pos) or "n/a", ok2 and tostring(scl) or "n/a")
end

function registerLive(key, obj, item)
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

function unregisterLive(key)
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

function deleteLive(key, diag)
  local entry = unregisterLive(key)
  if not entry then return end
  notify("onObjectDeleted", key)
  deletedTotal = deletedTotal + 1
  local plain = hold.bypassPool(entry.item)                    -- animated objects are deleted, never pooled
  if not plain and residentMode() and deactivateDormant(key, entry) then return end
  if not plain and shellMode() then
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

-- Animated objects (playAmbient on) are frozen when a pooled object is shown again. So playAmbient is switched off when the
-- object is hidden (resting in the pool, parked) and switched on again, with a postApply, once it is visible.
-- hideAmbient: only for an object that was given a playAmbient field (shellFields). showAmbient: only for an animated item.
function hold.hideAmbient(obj, id)
  if not TUNING.restartAmbient then return end
  local applied = shellFields[id]
  if not (applied and applied.playAmbient) then return end
  pcall(obj.setField, obj, "playAmbient", 0, "0")
  pcall(obj.postApply, obj)
end

function hold.showAmbient(obj, item)
  local v = item.playAmbient
  if not TUNING.restartAmbient or not (v == true or v == 1 or v == "1" or v == "true") then return end
  pcall(obj.setField, obj, "playAmbient", 0, "1")
  pcall(obj.postApply, obj)
  hold.stats.ambient = hold.stats.ambient + 1
end

-- Objects in the runtime group according to the engine, nil when the engine gives no way to count them.
function sceneCount()
  local g = runtimeGroup
  if not g then return 0 end
  local ok, n = pcall(function() return g:size() end)
  if ok and type(n) == "number" then return n end
  ok, n = pcall(function() return #g:getObjects() end)
  if ok and type(n) == "number" then return n end
  return nil
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
