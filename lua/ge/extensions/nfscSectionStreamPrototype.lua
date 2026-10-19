-- Carbon / Palmont section-streaming proof of concept for BeamNG.drive.
--
-- This deliberately does NOT scan scenetree:getAllObjects(). Streamable TSStatic
-- records must first be removed from ordinary items.level.json and emitted by
-- build_palmont_stream_pack.py to lua/carbon_stream/sections/*.json.
--
-- Prototype scope: visual TSStatic residency only. VISUAL_ONLY_PROTOTYPE forces
-- collisionType=None so this can prove load/delete/memory behavior without an
-- expensive static-collision rebuild on every section transition. Collision,
-- emitters, flares, animation ownership and override-state integration are phase 2.

local M = {}

local DEFAULT_LEVEL_ROOT = "levels/nfsc"
local SECTION_JSON_RELATIVE = "lua/sections.json"
local STREAM_INDEX_RELATIVE = "lua/carbon_stream/index.json"

local LOAD_OBJECTS_PER_FRAME = 24
local SECTION_FILES_PER_FRAME = 1
local MAX_QUEUED_ITEMS = 256
local DELETE_OBJECTS_PER_FRAME = 60
local MAX_UNLOAD_CHECKS_PER_FRAME = 256
local UNLOAD_COOLDOWN = 2.0
local CONTAINMENT_TOLERANCE = 0.1
local ALWAYS_SHOW_ORPHAN_SECTIONS = false
local VISUAL_ONLY_PROTOTYPE = true
local DEBUG_LOG = true

-- Put override names here to allow their TSStatic records to stream in this prototype.
-- Empty means override-controlled records remain unloaded, matching the supplied
-- section-culler prototype's default policy.
local alwaysOnOverrideList = {
  -- "ExampleOverrideName",
}

local levelRoot = DEFAULT_LEVEL_ROOT
local sectionJsonPath = nil
local streamIndexPath = nil
local sections = {}
local sectionOrder = {}
local sectionIndex = {}
local orphanSectionIDs = {}
local alwaysOnOverrides = {}

local currentSectionID = nil
local activeSectionSet = {}
local sectionLoading = {}       -- sectionID -> {token, files, nextFile}
local sectionLoaded = {}        -- sectionID -> true after every manifest chunk was read
local sectionLoadQueue = {}     -- {id, token}; stale tokens are ignored
local sectionLoadHead, sectionLoadTail = 1, 0
local loadQueue = {}            -- {key, item}; source tables exist only for queued objects
local loadQueueHead, loadQueueTail = 1, 0
local queuedKeys = {}
local liveObjects = {}          -- stream key -> {id, name, sectionIDs, overrideNames}
local pendingUnload = {}         -- stream key -> time it became undesired
local unloadToken = {}
local unloadQueue = {}
local unloadHead, unloadTail = 1, 0
local nextUnloadToken = 0
local nextSectionToken = 0
local totalTime = 0
local initialized = false
local streamingSuspended = false
local runtimeGroupName = "NFSC_StreamedScenery_Runtime"

for _, name in ipairs(alwaysOnOverrideList) do alwaysOnOverrides[name] = true end

local function log(fmt, ...)
  if DEBUG_LOG then
    print(string.format("[nfscSectionStreamPrototype] " .. fmt, ...))
  end
end

local function tableCount(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

local function vecXY(p)
  if type(p) ~= "table" then return nil end
  return {x = tonumber(p[1]), y = tonumber(p[2])}
end

local function parseIDs(value)
  local ids, seen = {}, {}
  local function add(v)
    local n = tonumber(v)
    if n and n == math.floor(n) and not seen[n] then
      seen[n] = true
      ids[#ids + 1] = n
    end
  end
  if type(value) == "number" then
    add(value)
  elseif type(value) == "table" then
    for _, v in ipairs(value) do
      if type(v) == "string" then
        for token in string.gmatch(v, "[^,]+") do add((token:gsub("^%s*(.-)%s*$", "%1"))) end
      else
        add(v)
      end
    end
  elseif type(value) == "string" then
    for token in string.gmatch(value, "[^,]+") do add((token:gsub("^%s*(.-)%s*$", "%1"))) end
  end
  return ids
end

local function splitNames(value)
  local names = {}
  if type(value) ~= "string" or value == "" then return names end
  for name in string.gmatch(value, "[^,]+") do
    name = name:gsub("^%s*(.-)%s*$", "%1")
    if name ~= "" then names[#names + 1] = name end
  end
  return names
end

local function pointInBounds(p, minP, maxP)
  return p.x >= minP.x and p.x <= maxP.x and p.y >= minP.y and p.y <= maxP.y
end

local function pointInPolygon(p, points)
  local inside = false
  local n = #points
  if n < 3 then return false end
  local j = n
  for i = 1, n do
    local pi, pj = points[i], points[j]
    if ((pi.y <= p.y and p.y < pj.y) or (pj.y <= p.y and p.y < pi.y)) then
      local denom = pj.y - pi.y
      if denom ~= 0 then
        local xCross = (pj.x - pi.x) * (p.y - pi.y) / denom + pi.x
        if p.x < xCross then inside = not inside end
      end
    end
    j = i
  end
  return inside
end

local function distanceToSegments(p, points)
  local best = math.huge
  local n = #points
  if n < 2 then return best end
  for i = 1, n do
    local a, b = points[i], points[(i % n) + 1]
    local abx, aby = b.x - a.x, b.y - a.y
    local apx, apy = p.x - a.x, p.y - a.y
    local lenSq = abx * abx + aby * aby
    local t = 0
    if lenSq > 0 then t = math.max(0, math.min(1, (apx * abx + apy * aby) / lenSq)) end
    local dx, dy = p.x - (a.x + t * abx), p.y - (a.y + t * aby)
    best = math.min(best, math.sqrt(dx * dx + dy * dy))
  end
  return best
end

local function loadSections()
  sections, sectionOrder = {}, {}
  local data = jsonReadFile(sectionJsonPath)
  if not data or type(data.sections) ~= "table" then
    error("cannot read section boundary data: " .. tostring(sectionJsonPath))
  end
  for _, entry in ipairs(data.sections) do
    local points = {}
    for _, pt in ipairs(entry.points or {}) do
      local xy = vecXY(pt)
      if xy and xy.x and xy.y then points[#points + 1] = xy end
    end
    local bmin, bmax = vecXY(entry.boundsMin), vecXY(entry.boundsMax)
    local id = tonumber(entry.id)
    if id and bmin and bmax and #points >= 3 then
      sections[id] = {id = id, points = points, boundsMin = bmin, boundsMax = bmax,
                      related = parseIDs(entry.related)}
      sectionOrder[#sectionOrder + 1] = id
    end
  end
  table.sort(sectionOrder)
  log("loaded %d section polygons from %s", #sectionOrder, sectionJsonPath)
end

local function loadStreamIndex()
  sectionIndex = {}
  local data = jsonReadFile(streamIndexPath)
  if not data or data.schemaVersion ~= 1 or type(data.sections) ~= "table" then
    error("cannot read generated stream index: " .. tostring(streamIndexPath))
  end
  for _, entry in ipairs(data.sections) do
    local id = tonumber(entry.id)
    if id then
      local files = {}
      for _, path in ipairs(entry.files or {}) do
        if type(path) == "string" and path:sub(1, 1) ~= "/" and not path:find("..", 1, true) then
          files[#files + 1] = levelRoot .. "/" .. path
        else
          error("unsafe section data path for section " .. tostring(id))
        end
      end
      sectionIndex[id] = {files = files, count = tonumber(entry.count) or 0}
    end
  end
  log("loaded stream index: %d section record(s)", tableCount(sectionIndex))
end

local function findSection(p)
  -- Deterministic lower-ID tie-break when polygons overlap at a boundary.
  for _, id in ipairs(sectionOrder) do
    local s = sections[id]
    if pointInBounds(p, s.boundsMin, s.boundsMax) and pointInPolygon(p, s.points) then
      return id
    end
  end
  local bestID, bestDist = nil, CONTAINMENT_TOLERANCE
  for _, id in ipairs(sectionOrder) do
    local d = distanceToSegments(p, sections[id].points)
    if d <= bestDist then bestID, bestDist = id, d end
  end
  return bestID
end

local function computeOrphans()
  orphanSectionIDs = {}
  local reachable = {}
  for id, sec in pairs(sections) do
    reachable[id] = true
    for _, relID in ipairs(sec.related) do reachable[relID] = true end
  end
  local orphanList = {}
  for id in pairs(sectionIndex) do
    if not reachable[id] then
      orphanSectionIDs[id] = true
      orphanList[#orphanList + 1] = id
    end
  end
  table.sort(orphanList)
  log("orphan streamed sections: %d%s", #orphanList,
      #orphanList > 0 and (" (" .. table.concat(orphanList, ",", 1, math.min(30, #orphanList)) .. ")") or "")
end

local function computeActiveSections(sectionID)
  local out = {}
  if sectionID and sections[sectionID] then
    out[sectionID] = true
    for _, relID in ipairs(sections[sectionID].related) do out[relID] = true end
  end
  if ALWAYS_SHOW_ORPHAN_SECTIONS then
    for id in pairs(orphanSectionIDs) do out[id] = true end
  end
  return out
end

local function itemSections(item)
  if type(item.__streamSections) == "table" then return item.__streamSections end
  return parseIDs(item.sectionID)
end

local function itemOverrides(item)
  return splitNames(item.sectionOverrideName)
end

local function overrideAllowed(item)
  local names = itemOverrides(item)
  if #names == 0 then return true end
  for _, name in ipairs(names) do
    if alwaysOnOverrides[name] then return true end
  end
  return false
end

local function membershipsIntersect(ids, active)
  for _, id in ipairs(ids or {}) do if active[id] then return true end end
  return false
end

local function itemWanted(item)
  return membershipsIntersect(itemSections(item), activeSectionSet) and overrideAllowed(item)
end

local function ensureRuntimeGroup()
  local g = scenetree.findObject(runtimeGroupName)
  if g then return g end
  g = createObject("SimGroup")
  g:registerObject(runtimeGroupName)
  if scenetree.MissionGroup then scenetree.MissionGroup:addObject(g) end
  return g
end

local function scalarText(value)
  if type(value) == "boolean" then return value and "1" or "0" end
  if type(value) == "number" or type(value) == "string" then return tostring(value) end
  return nil
end

local RESERVED_FIELDS = {
  class = true, name = true, position = true, rotation = true, scale = true,
  __parent = true, __streamKey = true, __streamSections = true, __streamSource = true,
  sectionID = true, sectionOverrideName = true,
}

local function applySerializedField(obj, field, value)
  if RESERVED_FIELDS[field] or field:sub(1, 1) == "_" or field:sub(1, 2) == "__" then return end

  -- The user's export serializes rotationEuler as a three-number array. BeamNG's
  -- rotationEuler field expects a single space-separated vector at field index 0,
  -- not three separate Torque array slots. Preserve the exported radians exactly.
  if field == "rotationEuler" and type(value) == "table" and #value >= 3 then
    local x, y, z = scalarText(value[1]), scalarText(value[2]), scalarText(value[3])
    if x and y and z then pcall(function() obj:setField("rotationEuler", 0, x .. " " .. y .. " " .. z) end) end
    return
  end

  if type(value) == "table" then
    -- Torque field arrays are indexed separately. Nested tables are not interpreted
    -- here; this prototype is aimed at ordinary serialized TSStatic fields.
    for i, v in ipairs(value) do
      local txt = scalarText(v)
      if txt ~= nil then pcall(function() obj:setField(field, i - 1, txt) end) end
    end
  else
    local txt = scalarText(value)
    if txt ~= nil then pcall(function() obj:setField(field, 0, txt) end) end
  end
end

local function runtimeObjectName(item, key)
  local wanted = tostring(item.name or "")
  if wanted == "" then wanted = "nfsc_stream_" .. key:gsub("[^%w]", "") end
  if scenetree.findObject(wanted) then
    local suffix = key:match("([%da-f]+)$") or tostring(math.floor(totalTime * 1000))
    return wanted .. "_cs_" .. suffix
  end
  return wanted
end

local function createStreamedObject(item, key)
  if type(item) ~= "table" or type(item.shapeName) ~= "string" or item.shapeName == "" then
    log("skip malformed item %s (no shapeName)", tostring(key))
    return nil
  end
  local pos, rot, rotEuler = item.position, item.rotation, item.rotationEuler
  if type(pos) ~= "table" or #pos < 3 then
    log("skip %s (invalid position)", tostring(key))
    return nil
  end
  local hasQuaternion = type(rot) == "table" and #rot >= 4
  local hasEuler = type(rotEuler) == "table" and #rotEuler >= 3
  if not hasQuaternion and not hasEuler then rot = {0, 0, 0, 1} end

  local obj = createObject("TSStatic")
  if not obj then
    log("createObject(TSStatic) failed for %s", tostring(key))
    return nil
  end

  -- Shape first, then remaining serialized fields, all before registration.
  pcall(function() obj:setField("shapeName", 0, item.shapeName) end)
  for field, value in pairs(item) do applySerializedField(obj, field, value) end
  if VISUAL_ONLY_PROTOTYPE then
    pcall(function() obj:setField("collisionType", 0, "None") end)
    pcall(function() obj:setField("decalType", 0, "None") end)
  end

  local okTransform, transformErr = pcall(function()
    if hasQuaternion then
      obj:setPosRot(pos[1], pos[2], pos[3], rot[1], rot[2], rot[3], rot[4])
    elseif hasEuler then
      -- rotationEuler was set as a native field above. Only move the object here;
      -- setPosRot with an identity quaternion would clobber the exported rotation.
      obj:setPosition(vec3(pos[1], pos[2], pos[3]))
    else
      obj:setPosRot(pos[1], pos[2], pos[3], rot[1], rot[2], rot[3], rot[4])
    end
    if type(item.scale) == "number" then
      obj:setScale(vec3(item.scale, item.scale, item.scale))
    elseif type(item.scale) == "table" and #item.scale >= 3 then
      obj:setScale(vec3(item.scale[1], item.scale[2], item.scale[3]))
    end
  end)
  if not okTransform then
    pcall(function() obj:delete() end)
    log("transform failed for %s: %s", tostring(key), tostring(transformErr))
    return nil
  end

  local objectName = runtimeObjectName(item, key)
  local okRegister, registerErr = pcall(function() obj:registerObject(objectName) end)
  if not okRegister then
    pcall(function() obj:delete() end)
    log("registerObject failed for %s: %s", tostring(key), tostring(registerErr))
    return nil
  end

  local parent = nil
  if type(item.__parent) == "string" and item.__parent ~= "" then
    parent = scenetree.findObject(item.__parent)
  end
  if not parent then parent = ensureRuntimeGroup() end
  local attached = pcall(function() parent:addObject(obj) end)
  if not attached then
    local fallback = ensureRuntimeGroup()
    pcall(function() fallback:addObject(obj) end)
  end

  return {id = obj:getID(), name = objectName, sectionIDs = itemSections(item),
          overrideNames = itemOverrides(item), source = item.__streamSource}
end

local function deleteStreamedObject(key)
  local entry = liveObjects[key]
  if not entry then return end
  local obj = scenetree.findObjectById(entry.id)
  if obj then
    pcall(function() obj:delete() end)
  end
  liveObjects[key] = nil
  pendingUnload[key] = nil
end

local function queueItem(item)
  local key = item and item.__streamKey
  if type(key) ~= "string" or key == "" or liveObjects[key] or queuedKeys[key] then return end
  queuedKeys[key] = true
  loadQueueTail = loadQueueTail + 1
  loadQueue[loadQueueTail] = {key = key, item = item}
end

local function pruneLoadQueue()
  local kept, newQueued = {}, {}
  for i = loadQueueHead, loadQueueTail do
    local entry = loadQueue[i]
    if entry and itemWanted(entry.item) and not liveObjects[entry.key] then
      kept[#kept + 1] = entry
      newQueued[entry.key] = true
    end
  end
  loadQueue, loadQueueHead, loadQueueTail, queuedKeys = kept, 1, #kept, newQueued
end

local function queueSectionRead(id)
  if sectionLoaded[id] or sectionLoading[id] or not activeSectionSet[id] then return end
  local entry = sectionIndex[id]
  if not entry or #entry.files == 0 then
    sectionLoaded[id] = true
    return
  end
  nextSectionToken = nextSectionToken + 1
  local state = {token = nextSectionToken, files = entry.files, nextFile = 1}
  sectionLoading[id] = state
  sectionLoadTail = sectionLoadTail + 1
  sectionLoadQueue[sectionLoadTail] = {id = id, token = state.token}
end

local function liveWanted(entry)
  local wanted = membershipsIntersect(entry.sectionIDs, activeSectionSet)
  if wanted then
    local anyAllowed = #entry.overrideNames == 0
    for _, name in ipairs(entry.overrideNames) do
      if alwaysOnOverrides[name] then anyAllowed = true; break end
    end
    wanted = anyAllowed
  end
  return wanted
end

local function scheduleUnload(key)
  if pendingUnload[key] then return end
  nextUnloadToken = nextUnloadToken + 1
  pendingUnload[key] = totalTime
  unloadToken[key] = nextUnloadToken
  unloadTail = unloadTail + 1
  unloadQueue[unloadTail] = {key = key, token = nextUnloadToken}
end

local function refreshLiveResidency()
  for key, entry in pairs(liveObjects) do
    if liveWanted(entry) then
      pendingUnload[key] = nil
      unloadToken[key] = nil
    else
      scheduleUnload(key)
    end
  end
end

local function refreshActiveSet(newSectionID)
  currentSectionID = newSectionID
  local newActive = computeActiveSections(newSectionID)

  -- Cancel section-file work for sections that have just left the active set.
  for id in pairs(activeSectionSet) do
    if not newActive[id] then
      sectionLoading[id] = nil
      sectionLoaded[id] = nil
    end
  end
  activeSectionSet = newActive

  for id in pairs(activeSectionSet) do queueSectionRead(id) end
  refreshLiveResidency()
  pruneLoadQueue()

  log("section=%s activeSections=%d live=%d loadQueue=%d",
      tostring(currentSectionID), tableCount(activeSectionSet), tableCount(liveObjects), loadQueueTail - loadQueueHead + 1)
end

local function processSectionReads()
  local processed = 0
  while processed < SECTION_FILES_PER_FRAME and sectionLoadHead <= sectionLoadTail
      and (loadQueueTail - loadQueueHead + 1) < MAX_QUEUED_ITEMS do
    local request = sectionLoadQueue[sectionLoadHead]
    sectionLoadQueue[sectionLoadHead] = nil
    sectionLoadHead = sectionLoadHead + 1
    local state = sectionLoading[request.id]
    if state and state.token == request.token and activeSectionSet[request.id] then
      local path = state.files[state.nextFile]
      if path then
        local okRead, data = pcall(jsonReadFile, path)
        if not okRead or not data or type(data.objects) ~= "table" then
          log("ERROR reading section data %s", tostring(path))
          -- Mark this section read to avoid a permanent retry loop; diagnostic output
          -- makes the missing/corrupt chunk visible during the prototype test.
          state.nextFile = #state.files + 1
        else
          for _, item in ipairs(data.objects) do queueItem(item) end
          state.nextFile = state.nextFile + 1
        end
        processed = processed + 1
      end
      if state.nextFile <= #state.files then
        sectionLoadTail = sectionLoadTail + 1
        sectionLoadQueue[sectionLoadTail] = {id = request.id, token = request.token}
      else
        sectionLoading[request.id] = nil
        sectionLoaded[request.id] = true
        log("section data ready: %s", tostring(request.id))
      end
    end
  end
  if sectionLoadHead > sectionLoadTail then
    sectionLoadQueue, sectionLoadHead, sectionLoadTail = {}, 1, 0
  elseif sectionLoadHead > 256 then
    local compact = {}
    for i = sectionLoadHead, sectionLoadTail do
      if sectionLoadQueue[i] then compact[#compact + 1] = sectionLoadQueue[i] end
    end
    sectionLoadQueue, sectionLoadHead, sectionLoadTail = compact, 1, #compact
  end
end

local function processObjectLoads()
  local made = 0
  while made < LOAD_OBJECTS_PER_FRAME and loadQueueHead <= loadQueueTail do
    local request = loadQueue[loadQueueHead]
    loadQueue[loadQueueHead] = nil
    loadQueueHead = loadQueueHead + 1
    if request then
      queuedKeys[request.key] = nil
      -- Use the freshest queued record; a multi-section item may have appeared in another
      -- active section file while this key was waiting in the queue.
      if not liveObjects[request.key] and itemWanted(request.item) then
        local okCreate, live = pcall(createStreamedObject, request.item, request.key)
        if okCreate and live then
          liveObjects[request.key] = live
          pendingUnload[request.key] = nil
          made = made + 1
        elseif not okCreate then
          log("CREATE ERROR for %s: %s", tostring(request.key), tostring(live))
        end
      end
    end
  end
  if loadQueueHead > loadQueueTail then
    loadQueue, loadQueueHead, loadQueueTail, queuedKeys = {}, 1, 0, {}
  elseif loadQueueHead > 512 then
    local compact = {}
    local newQueued = {}
    for i = loadQueueHead, loadQueueTail do
      local entry = loadQueue[i]
      if entry then compact[#compact + 1] = entry; newQueued[entry.key] = true end
    end
    loadQueue, loadQueueHead, loadQueueTail, queuedKeys = compact, 1, #compact, newQueued
  end
end

local function processPendingUnloads()
  local checked, deleted = 0, 0
  -- Only inspect a bounded slice of the unload queue each frame. Stale queue tokens
  -- are discarded, and a pending object is requeued until its cooldown expires.
  local stopAt = unloadTail
  while checked < MAX_UNLOAD_CHECKS_PER_FRAME and deleted < DELETE_OBJECTS_PER_FRAME
      and unloadHead <= stopAt do
    local request = unloadQueue[unloadHead]
    unloadQueue[unloadHead] = nil
    unloadHead = unloadHead + 1
    checked = checked + 1
    if request and unloadToken[request.key] == request.token and pendingUnload[request.key] ~= nil then
      local entry = liveObjects[request.key]
      if not entry or liveWanted(entry) then
        pendingUnload[request.key] = nil
        unloadToken[request.key] = nil
      elseif totalTime - pendingUnload[request.key] >= UNLOAD_COOLDOWN then
        deleteStreamedObject(request.key)
        unloadToken[request.key] = nil
        deleted = deleted + 1
      else
        unloadTail = unloadTail + 1
        unloadQueue[unloadTail] = request
      end
    end
  end
  if unloadHead > unloadTail then
    unloadQueue, unloadHead, unloadTail = {}, 1, 0
  elseif unloadHead > 512 then
    local compact = {}
    for i = unloadHead, unloadTail do
      if unloadQueue[i] then compact[#compact + 1] = unloadQueue[i] end
    end
    unloadQueue, unloadHead, unloadTail = compact, 1, #compact
  end
end

local function refreshActiveSectionData()
  for id in pairs(activeSectionSet) do
    sectionLoaded[id] = nil
    sectionLoading[id] = nil
    queueSectionRead(id)
  end
  refreshLiveResidency()
  pruneLoadQueue()
end

function M.initializeObjects(basePathOverride)
  levelRoot = (basePathOverride or DEFAULT_LEVEL_ROOT):gsub("/+$", "")
  sectionJsonPath = levelRoot .. "/" .. SECTION_JSON_RELATIVE
  streamIndexPath = levelRoot .. "/" .. STREAM_INDEX_RELATIVE

  sections, sectionOrder, sectionIndex = {}, {}, {}
  currentSectionID, activeSectionSet = nil, {}
  sectionLoading, sectionLoaded, sectionLoadQueue, sectionLoadHead, sectionLoadTail = {}, {}, {}, 1, 0
  loadQueue, loadQueueHead, loadQueueTail, queuedKeys = {}, 1, 0, {}
  liveObjects, pendingUnload, unloadToken = {}, {}, {}
  unloadQueue, unloadHead, unloadTail = {}, 1, 0
  nextUnloadToken, nextSectionToken = 0, 0
  totalTime, initialized, streamingSuspended = 0, false, false

  local ok, err = pcall(function()
    loadSections()
    loadStreamIndex()
    computeOrphans()
  end)
  if not ok then
    log("INIT FAILED: %s", tostring(err))
    return false
  end
  initialized = true
  log("ready. No scene-tree scan performed; streamed records will be read on demand.")
  return true
end

function M.onUpdate(dtReal, _dtSim, _dtRaw)
  if not initialized or streamingSuspended then return end
  totalTime = totalTime + (dtReal or 0)

  local cam = core_camera.getPosition()
  if cam then
    local newSection = currentSectionID
    if not currentSectionID or not sections[currentSectionID]
       or not pointInBounds({x = cam.x, y = cam.y}, sections[currentSectionID].boundsMin,
                            sections[currentSectionID].boundsMax)
       or not pointInPolygon({x = cam.x, y = cam.y}, sections[currentSectionID].points) then
      newSection = findSection({x = cam.x, y = cam.y})
    end
    -- If the camera is temporarily outside all Carbon polygons, retain the last valid
    -- section instead of unloading the whole world during a camera transition.
    if newSection and newSection ~= currentSectionID then refreshActiveSet(newSection) end
  end

  processSectionReads()
  processObjectLoads()
  processPendingUnloads()
end

function M.setOverrideEnabled(overrideName, enabled)
  if type(overrideName) ~= "string" or overrideName == "" then return false end
  alwaysOnOverrides[overrideName] = enabled and true or nil
  if initialized then refreshActiveSectionData() end
  return true
end

function M.setSuspended(suspended)
  streamingSuspended = suspended == true
  if not streamingSuspended and initialized and currentSectionID then
    refreshActiveSectionData()
  end
end

function M.getStatus()
  return {
    initialized = initialized,
    currentSectionID = currentSectionID,
    activeSectionCount = tableCount(activeSectionSet),
    liveObjectCount = tableCount(liveObjects),
    pendingUnloadCount = tableCount(pendingUnload),
    orphanSectionCount = tableCount(orphanSectionIDs),
    queuedObjectCount = math.max(0, loadQueueTail - loadQueueHead + 1),
    sectionReadsQueued = math.max(0, sectionLoadTail - sectionLoadHead + 1),
    visualOnly = VISUAL_ONLY_PROTOTYPE,
  }
end

function M.onExtensionUnloaded()
  -- Best-effort cleanup if the extension is reloaded during development.
  local keys = {}
  for key in pairs(liveObjects) do keys[#keys + 1] = key end
  for _, key in ipairs(keys) do deleteStreamedObject(key) end
  unloadQueue, unloadHead, unloadTail = {}, 1, 0
end

return M
