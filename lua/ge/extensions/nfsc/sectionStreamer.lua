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
--   lua/carbon_stream/sections/<id>.json  one whole file per section
--
-- Events (coarse, via extensions.hook):
--   onNfscStreamerInitialized()
--   onNfscSectionChanged(newSectionID, oldSectionID)   -- nil = camera outside every section
-- Events (fine, via M.addListener(table)); each is called as listener:method(...):
--   onObjectCreated(key, obj, item)   onObjectDeleted(key)   onStreamerReset()
--
-- Exported transforms are applied exactly as exported: position, rotationEuler and scale
-- are written with setField as space-joined text, the same way every other field is.

local M = {}

-- ---------------------------------------------------------------------------
-- Tuning (override at runtime with M.setTuning{...})
-- ---------------------------------------------------------------------------
local TUNING = {
  levelRoot = "levels/nfsc",
  maxCreatesPerFrame = 24,
  maxDeletesPerFrame = 60,
  frameBudgetMs = 3.0,            -- stop creating/deleting for this frame after this many ms
  maxSectionReadsPerFrame = 1,
  maxQueuedItems = 512,           -- do not read another section file while this many wait
  unloadCooldown = 2.0,           -- seconds a no-longer-wanted object survives
  containmentTolerance = 0.1,     -- GetDistanceOutside fallback, same as the game
  noSectionLookupInterval = 0.1,  -- seconds between lookups while outside every section
  forceCollisionNone = true,      -- collision policy for the first in-game test (see docs)
  verifyFirstN = 3,               -- log readbacks of the first N created objects
  runtimeGroupName = "NFSC_StreamedScenery",
}

local SUPPORTED_SCHEMA = 2
local SECTIONS_JSON = "lua/sections.json"
local STREAM_INDEX = "lua/carbon_stream/index.json"
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
local queuedKeys = {}
local live, liveBySection, liveCount = {}, {}, 0
local pendingUnload, unloadQueue, uqHead, uqTail = {}, {}, 1, 0

local totalTime, lookupTimer = 0, 0
local createdTotal, deletedTotal, failureCount, verified = 0, 0, 0, 0
local failures = {}
local listeners = {}
local runtimeGroup = nil
local scratch = { x = 0, y = 0 }

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
  local wanted = (type(item.name) == "string" and item.name ~= "") and item.name or ("nfsc_" .. key)
  if scenetree.findObject(wanted) then wanted = wanted .. "_s" .. tostring(key):gsub("[^%w]", ""):sub(-6) end
  return wanted
end

local function createStreamedObject(item)
  local shape = item.shapeName
  if type(shape) ~= "string" or shape == "" then return nil, "missing shapeName" end
  local obj = createObject("TSStatic")
  if not obj then return nil, "createObject(TSStatic) returned nil" end
  pcall(obj.setField, obj, "shapeName", 0, shape)
  for field, value in pairs(item) do
    if field ~= "shapeName" and not RESERVED[field] then
      local text = fieldText(value)
      if text ~= nil then pcall(obj.setField, obj, field, 0, text) end
    end
  end
  if TUNING.forceCollisionNone then
    pcall(obj.setField, obj, "collisionType", 0, "None")
    pcall(obj.setField, obj, "decalType", 0, "None")
  end
  local ok, err = pcall(obj.registerObject, obj, runtimeName(item, item.__streamKey or "x"))
  if not ok then
    pcall(obj.delete, obj)
    return nil, "registerObject failed: " .. tostring(err)
  end
  local group = ensureRuntimeGroup()
  pcall(group.addObject, group, obj)
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
  live[key] = { id = obj:getID(), sections = ids }
  liveCount = liveCount + 1
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
  for i = 1, #entry.sections do
    local bucket = liveBySection[entry.sections[i]]
    if bucket then bucket[key] = nil end
  end
  return entry
end

local function deleteLive(key)
  local entry = unregisterLive(key)
  if not entry then return end
  notify("onObjectDeleted", key)
  local obj = scenetree.findObjectById(entry.id)
  if obj then pcall(obj.delete, obj) end
  deletedTotal = deletedTotal + 1
end

-- ---------------------------------------------------------------------------
-- Queues
-- ---------------------------------------------------------------------------
local function queueSectionRead(id)
  if sectionRead[id] or sectionReading[id] then return end
  if not sectionIndex[id] then sectionRead[id] = true; return end   -- section with no streamed objects
  sectionReading[id] = true
  srTail = srTail + 1
  sectionReadQueue[srTail] = id
end

local function queueItem(item)
  local key = item.__streamKey
  if not key or live[key] or queuedKeys[key] then return end
  queuedKeys[key] = true
  lqTail = lqTail + 1
  loadQueue[lqTail] = item
end

local function scheduleUnload(key)
  if pendingUnload[key] then return end
  pendingUnload[key] = totalTime
  uqTail = uqTail + 1
  unloadQueue[uqTail] = { key = key, stamp = totalTime }
end

local function processSectionReads()
  local reads = 0
  while srHead <= srTail and reads < TUNING.maxSectionReadsPerFrame and (lqTail - lqHead + 1) < TUNING.maxQueuedItems do
    local id = sectionReadQueue[srHead]
    sectionReadQueue[srHead] = nil
    srHead = srHead + 1
    if activeSet[id] and sectionReading[id] then
      reads = reads + 1
      local entry = sectionIndex[id]
      local ok, data = pcall(jsonReadFile, entry.file)
      if ok and type(data) == "table" and type(data.objects) == "table" then
        for i = 1, #data.objects do queueItem(data.objects[i]) end
      else
        recordFailure("could not read section file " .. tostring(entry.file))
      end
      sectionRead[id] = true
    end
    sectionReading[id] = nil
  end
  if srHead > srTail then sectionReadQueue, srHead, srTail = {}, 1, 0 end
end

local function processLoads()
  local started = os.clock()
  local made, skipped = 0, 0
  while lqHead <= lqTail and made < TUNING.maxCreatesPerFrame and skipped < SKIP_CAP do
    local item = loadQueue[lqHead]
    loadQueue[lqHead] = nil
    lqHead = lqHead + 1
    local key = item.__streamKey
    queuedKeys[key] = nil
    if live[key] or not anyActive(itemSections(item)) then
      skipped = skipped + 1
    else
      local obj, err = createStreamedObject(item)
      if obj then
        registerLive(key, obj, item)
        createdTotal = createdTotal + 1
        verifyReadback(key, item, obj)
        notify("onObjectCreated", key, obj, item)
      else
        recordFailure(string.format("create %s failed: %s", tostring(item.name), tostring(err)))
      end
      made = made + 1
      if (os.clock() - started) * 1000 >= TUNING.frameBudgetMs then break end
    end
  end
  if lqHead > lqTail then loadQueue, lqHead, lqTail = {}, 1, 0 end
end

local function processUnloads()
  local started = os.clock()
  local removed = 0
  while uqHead <= uqTail and removed < TUNING.maxDeletesPerFrame do
    local entry = unloadQueue[uqHead]
    local key = entry.key
    if pendingUnload[key] ~= entry.stamp then
      unloadQueue[uqHead] = nil; uqHead = uqHead + 1          -- cancelled or rescheduled
    elseif not live[key] then
      pendingUnload[key] = nil
      unloadQueue[uqHead] = nil; uqHead = uqHead + 1
    elseif totalTime - entry.stamp >= TUNING.unloadCooldown then
      pendingUnload[key] = nil
      unloadQueue[uqHead] = nil; uqHead = uqHead + 1
      deleteLive(key)
      removed = removed + 1
      if (os.clock() - started) * 1000 >= TUNING.frameBudgetMs then break end
    else
      break                                                     -- FIFO by time: the rest are newer
    end
  end
  if uqHead > uqTail then unloadQueue, uqHead, uqTail = {}, 1, 0 end
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
  if newID then
    queueSectionRead(newID)                                        -- current section first
    for _, rel in ipairs(sections[newID].related) do queueSectionRead(rel) end
  end
  hook("onNfscSectionChanged", newID, oldID)
end

local function updateCamera(dt)
  local cam = core_camera and core_camera.getPosition and core_camera.getPosition()
  if not cam then return end
  scratch.x, scratch.y = cam.x, cam.y
  if currentSectionID and isInSection(scratch, currentSectionID) then return end
  if not currentSectionID then
    lookupTimer = lookupTimer - dt
    if lookupTimer > 0 then return end
    lookupTimer = TUNING.noSectionLookupInterval
  end
  local newID = findSection(scratch)
  if newID ~= currentSectionID then setCurrentSection(newID) end
end

-- ---------------------------------------------------------------------------
-- State reset
-- ---------------------------------------------------------------------------
local function resetState()
  currentSectionID, activeSet = nil, {}
  sectionRead, sectionReading = {}, {}
  sectionReadQueue, srHead, srTail = {}, 1, 0
  loadQueue, lqHead, lqTail, queuedKeys = {}, 1, 0, {}
  live, liveBySection, liveCount = {}, {}, 0
  pendingUnload, unloadQueue, uqHead, uqTail = {}, {}, 1, 0
  lookupTimer = 0
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------
function M.initialize(basePath)
  notify("onStreamerReset")
  destroyRuntimeGroup()
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

function M.setSuspended(flag) suspended = flag and true or false end
function M.isSuspended() return suspended end

function M.setTuning(values)
  for k, v in pairs(values or {}) do
    if TUNING[k] ~= nil then TUNING[k] = v end
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
    queuedObjectCount = lqTail - lqHead + 1,
    queuedSectionReads = srTail - srHead + 1,
    pendingUnloadCount = pending,
    createdTotal = createdTotal, deletedTotal = deletedTotal,
    failureCount = failureCount,
    forceCollisionNone = TUNING.forceCollisionNone,
  }
end

function M.getFailures() return failures end

-- true when no section file and no object is waiting to be created (cheap, per-frame safe)
function M.isIdle() return lqHead > lqTail and srHead > srTail end

function M.onUpdate(dtReal)
  if not initialized or suspended then return end
  totalTime = totalTime + (dtReal or 0)
  updateCamera(dtReal or 0)
  processSectionReads()
  processLoads()
  processUnloads()
end

function M.onExtensionUnloaded()
  notify("onStreamerReset")
  destroyRuntimeGroup()
  resetState()
  initialized = false
end

return M
