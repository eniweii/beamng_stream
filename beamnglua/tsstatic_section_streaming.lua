-- Section-based TSStatic streaming, driven by sections.json.
-- Streams TSStatic objects, emitter nodes and flare lights in/out based on which drivable section currently
-- contains the camera, plus that section's precomputed `related` sections.
-- Distinct from tsstatic_grid_culling.lua (generic distance/frustum grid) -
-- this keys visibility off game section membership, not a spatial grid.
--
-- Modes (streamingMode):
--   0 = disabled       - everything loaded/visible, no logic runs
--   1 = .hidden mode    - instant .hidden toggle, no cooldown (implemented)
--   2 = shapeName mode  - real load/unload streaming (NOT YET IMPLEMENTED -
--                         currently falls back to .hidden behavior; the
--                         mid-session-restart shape-recovery problem is
--                         unsolved and intentionally left alone for now)

local M = {}

-- TWEAKS
local basePath = "levels/nfsc"  -- default level folder (no leading slash); mainLevel.lua
                                 -- passes its own basePath into initializeObjects()
local streamingMode = 1     -- 0 disabled, 1 hidden, 2 streaming (stub, behaves like 1)
local alwaysShowOrphanSections = true -- sections with no boundary in sections.json that no drivable
                                       -- section lists in `related` can never stream in; keep them visible

-- Override groups that start out always-on. Put sectionOverrideName values here;
-- every other override group starts hidden. Toggle at runtime from the panel.
local alwaysOnOverrideList = {
  -- "ExampleOverrideName",
}
local containmentTolerance = 0.1 -- world units - GetDistanceOutside-style fallback tolerance

-- Emitter nodes (Carbon FX) also hide beyond their own farClip (meters, node field
-- written by build_beamng_particles.py). Nodes without farClip are never distance-culled.
local emitterDistanceCulling = true
local emitterCheckInterval = 0.25   -- seconds between distance checks
local emitterFarClipScale = 1.0     -- multiplies every farClip
local emitterHysteresis = 0.05      -- shown again only inside farClip * (1 - this), stops flicker

-- DATA, DON'T TOUCH
local sectionsJsonPath = nil   -- built from basePath in initializeObjects
local sections = {}            -- sectionID -> {points, boundsMin, boundsMax, related}
local objectsBySection = {}    -- sectionID -> {objectIndex, ...}
local allObjectIds = {}        -- objectIndex -> persistent object ID (re-resolved at use time)

local emitterInfo = {}         -- objectIndex -> {x, y, z, farSq, nearSq} (only nodes with a farClip)
local emitterFar = {}          -- objectIndex -> true, emitter currently beyond its farClip
local emitterTimer = 0

local currentSectionID = nil
local activeSet = {}           -- objectIndex -> true, currently-visible objects
local orphanSectionIDs = {}     -- sectionID -> true, object sections not drivable and not in any related list
local streamingHalted = false   -- true: streaming paused, every object shown (overrides included)
local pendingRestoreFrames = 0  -- frames left before re-applying section streaming after a collision refresh
local lastMode = nil           -- last-applied streamingMode, for transition handling

local objectOverrides = {}     -- objectIndex -> {overrideName1, ...} (only set for objects that have one)
local alwaysOnOverrides = {}   -- overrideName -> true, static allow-list (no game states available)
for _, overrideName in ipairs(alwaysOnOverrideList) do
  alwaysOnOverrides[overrideName] = true
end
local knownOverrideNames = {}  -- overrideName -> true, every name ever seen during a scan (for later UI)
local overrideSectionSet = {}  -- overrideName -> {sectionID -> true}, for nearest-first sorting

-- Light objects (Carbon flare lights). They are switched with isEnabled, not .hidden.
local function isLightObject(object)
  return object:isSubClassOf("PointLight") or object:isSubClassOf("SpotLight")
      or object:isSubClassOf("LightBase")
end

local function tableSize(t)
  local count = 0
  for _ in pairs(t) do count = count + 1 end
  return count
end

-- ---------------------------------------------------------------------------
-- sections.json loading
-- ---------------------------------------------------------------------------

local function toXY(arr)
  return { x = arr[1], y = arr[2] }
end

local function loadSectionsJson()
  sections = {}
  local data = jsonReadFile(sectionsJsonPath)
  if not data or not data.sections then
    print(string.format("[sectionStreamer] ERROR: could not read %s", sectionsJsonPath))
    return
  end
  for _, entry in ipairs(data.sections) do
    local points = {}
    for i, pt in ipairs(entry.points) do
      points[i] = toXY(pt)
    end
    sections[entry.id] = {
      points = points,
      boundsMin = toXY(entry.boundsMin),
      boundsMax = toXY(entry.boundsMax),
      related = entry.related or {},
    }
  end
  print(string.format("[sectionStreamer] loaded %d sections from %s", tableSize(sections), sectionsJsonPath))
end

-- ---------------------------------------------------------------------------
-- Point-in-polygon (2D, X/Y only - height ignored)
-- ---------------------------------------------------------------------------

local function pointInBounds(p, boundsMin, boundsMax)
  return p.x >= boundsMin.x and p.x <= boundsMax.x
     and p.y >= boundsMin.y and p.y <= boundsMax.y
end

-- Standard ray-cast (even-odd rule) point-in-polygon test, 2D.
local function pointInPolygon(p, points)
  local inside = false
  local n = #points
  local j = n
  for i = 1, n do
    local pi, pj = points[i], points[j]
    if (pi.y > p.y) ~= (pj.y > p.y) then
      local xCross = (pj.x - pi.x) * (p.y - pi.y) / (pj.y - pi.y) + pi.x
      if p.x < xCross then
        inside = not inside
      end
    end
    j = i
  end
  return inside
end

-- Closest distance from p to a polygon's edges (2D). Mirrors GetDistanceOutside.
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
    if lenSq > 0 then
      t = math.max(0, math.min(1, (apx * abx + apy * aby) / lenSq))
    end
    local cx, cy = a.x + t * abx, a.y + t * aby
    local dx, dy = p.x - cx, p.y - cy
    local dist = math.sqrt(dx * dx + dy * dy)
    if dist < minDist then minDist = dist end
    j = i
  end
  return minDist
end

local function isInSection(p, id)
  local section = sections[id]
  if not section then return false end
  return pointInBounds(p, section.boundsMin, section.boundsMax)
     and pointInPolygon(p, section.points)
end

-- Finds which drivable section contains p, following the real VisibleSection
-- fallback: exact containment first, else closest edge within tolerance
-- (ties broken by lower section ID), else nil (no section found).
local function findSection(p)
  for id, section in pairs(sections) do
    if pointInBounds(p, section.boundsMin, section.boundsMax)
       and pointInPolygon(p, section.points) then
      return id
    end
  end

  local bestID, bestDist = nil, math.huge
  for id, section in pairs(sections) do
    local dist = distanceToPolygonEdges(p, section.points)
    if dist <= containmentTolerance
       and (dist < bestDist or (dist == bestDist and (not bestID or id < bestID))) then
      bestID, bestDist = id, dist
    end
  end
  return bestID
end

-- ---------------------------------------------------------------------------
-- Scene scan / object index
-- ---------------------------------------------------------------------------

local function splitSectionIDs(str)
  local ids = {}
  for id in string.gmatch(str, "[^,]+") do
    table.insert(ids, (id:gsub("^%s*(.-)%s*$", "%1")))
  end
  return ids
end

-- Rescans the scene fresh by sectionID/dae_node/sectionOverrideName custom
-- properties (not cached object IDs, which go stale across restarts).
local function scanObjects()
  objectsBySection = {}
  allObjectIds = {}
  objectOverrides = {}
  knownOverrideNames = {}
  overrideSectionSet = {}
  emitterInfo = {}
  emitterFar = {}

  local scenetreeData = scenetree:getAllObjects()
  if not scenetreeData then return end

  local nextIndex = 1
  for _, name in pairs(scenetreeData) do
    local object = scenetree.findObject(name)
    if object and (object:isSubClassOf("TSStatic") or object:isSubClassOf("ParticleEmitterNode")
                   or isLightObject(object))
       and object.sectionID and object.sectionID ~= "" then
      local objectIndex = nextIndex
      nextIndex = nextIndex + 1
      allObjectIds[objectIndex] = object:getID()

      if object:isSubClassOf("ParticleEmitterNode") then
        local farClip = tonumber(object.farClip)
        if farClip and farClip > 0 then
          -- Volume twins move every frame, so measure from the box center (volBase)
          local bx, by, bz = string.match(tostring(object.volBase or ""), "^%s*(%S+)%s+(%S+)%s+(%S+)")
          bx, by, bz = tonumber(bx), tonumber(by), tonumber(bz)
          if not (bx and by and bz) then
            local pos = object:getPosition()
            bx, by, bz = pos.x, pos.y, pos.z
          end
          local far = farClip * emitterFarClipScale
          local near = far * (1 - emitterHysteresis)
          emitterInfo[objectIndex] = { x = bx, y = by, z = bz, farSq = far * far, nearSq = near * near }
        end
      end

      for _, id in ipairs(splitSectionIDs(object.sectionID)) do
        local numID = tonumber(id)
        if numID then
          objectsBySection[numID] = objectsBySection[numID] or {}
          table.insert(objectsBySection[numID], objectIndex)
        end
      end

      if object.sectionOverrideName and object.sectionOverrideName ~= "" then
        local names = splitSectionIDs(object.sectionOverrideName) -- same comma-split logic
        objectOverrides[objectIndex] = names
        for _, overrideName in ipairs(names) do
          knownOverrideNames[overrideName] = true
          overrideSectionSet[overrideName] = overrideSectionSet[overrideName] or {}
          for _, id in ipairs(splitSectionIDs(object.sectionID)) do
            local numID = tonumber(id)
            if numID then overrideSectionSet[overrideName][numID] = true end
          end
        end
      end
    end
  end

  print(string.format("[sectionStreamer] scanned %d streamable objects across %d sections",
    nextIndex - 1, tableSize(objectsBySection)))
end

local function resolveObject(objectIndex)
  return scenetree.findObjectById(allObjectIds[objectIndex])
end

-- ---------------------------------------------------------------------------
-- Visibility application
-- ---------------------------------------------------------------------------

-- Mode 2 (shapeName streaming) is not built yet - dispatches to the same
-- .hidden behavior as mode 1 until the shape-recovery problem is solved.
local emitterActiveErrorLogged = false

local function applyVisible(objectIndex, visible)
  local object = resolveObject(objectIndex)
  if not object then return end

  -- Lights: switch the light itself off/on (isEnabled). .hidden is not touched.
  if isLightObject(object) then
    object.isEnabled = visible
    return
  end

  object.hidden = not visible
  -- Emitter nodes (Carbon FX): active must be off to stop emitting.
  -- setActive() is tried first, the plain field is the fallback.
  if object:isSubClassOf("ParticleEmitterNode") then
    local ok, err = pcall(function() object:setActive(visible) end)
    if not ok then
      pcall(function() object.active = visible end)
      if not emitterActiveErrorLogged then
        emitterActiveErrorLogged = true
        print("[sectionStreamer] WARNING: setActive failed on emitter, using field: " .. tostring(err))
      end
    end
  end
end

-- Section logic calls this. A section-visible emitter also needs to be inside its
-- farClip, measured fresh here. ignoreDistance = true skips that (show-everything modes).
local function setObjectVisible(objectIndex, visible, ignoreDistance)
  local info = emitterInfo[objectIndex]
  if visible and info and emitterDistanceCulling and not ignoreDistance then
    local cam = core_camera.getPosition()
    if cam then
      local dx, dy, dz = info.x - cam.x, info.y - cam.y, info.z - cam.z
      local far = dx * dx + dy * dy + dz * dz > info.farSq
      emitterFar[objectIndex] = far or nil
      if far then visible = false end
    end
  else
    emitterFar[objectIndex] = nil
  end
  applyVisible(objectIndex, visible)
end

-- Periodic check for emitters whose section is active: hide beyond farClip, show again inside it.
local function updateEmitterDistance(dtReal)
  if not emitterDistanceCulling or next(emitterInfo) == nil then return end
  emitterTimer = emitterTimer + dtReal
  if emitterTimer < emitterCheckInterval then return end
  emitterTimer = 0

  local cam = core_camera.getPosition()
  if not cam then return end
  for objectIndex, info in pairs(emitterInfo) do
    if activeSet[objectIndex] then
      local dx, dy, dz = info.x - cam.x, info.y - cam.y, info.z - cam.z
      local d2 = dx * dx + dy * dy + dz * dz
      local wasFar = emitterFar[objectIndex] == true
      local isFar
      if wasFar then isFar = d2 > info.nearSq else isFar = d2 > info.farSq end
      if isFar ~= wasFar then
        emitterFar[objectIndex] = isFar or nil
        applyVisible(objectIndex, not isFar)
      end
    end
  end
end

-- Finds object sections that the streamer could never show: not a drivable
-- section (no polygon) and not in any drivable section's related list.
local function computeOrphanSections()
  orphanSectionIDs = {}
  local reachable = {}
  for id, section in pairs(sections) do
    reachable[id] = true
    for _, relID in ipairs(section.related) do reachable[relID] = true end
  end
  local list = {}
  for id in pairs(objectsBySection) do
    if not reachable[id] then
      orphanSectionIDs[id] = true
      table.insert(list, id)
    end
  end
  table.sort(list)
  print(string.format("[sectionStreamer] %d orphan sections (never reachable via related): %s",
    #list, table.concat(list, ",", 1, math.min(#list, 40))))
end

-- true if the object has no override group, or at least one of its groups is always-on
local function isOverrideAllowed(objectIndex)
  local overrides = objectOverrides[objectIndex]
  if not overrides then return true end
  for _, overrideName in ipairs(overrides) do
    if alwaysOnOverrides[overrideName] then return true end
  end
  return false
end

local function computeActiveSet(sectionID)
  local newActive = {}
  if sectionID then
    local ids = { [sectionID] = true }
    for _, relID in ipairs(sections[sectionID].related or {}) do
      ids[relID] = true
    end
    if alwaysShowOrphanSections then
      for id in pairs(orphanSectionIDs) do ids[id] = true end
    end
    for id in pairs(ids) do
      for _, objectIndex in ipairs(objectsBySection[id] or {}) do
        if isOverrideAllowed(objectIndex) then
          newActive[objectIndex] = true
        end
      end
    end
  end
  return newActive
end

local function applyActiveSet(newActive)
  for objectIndex in pairs(activeSet) do
    if not newActive[objectIndex] then
      setObjectVisible(objectIndex, false)
    end
  end
  for objectIndex in pairs(newActive) do
    if not activeSet[objectIndex] then
      setObjectVisible(objectIndex, true)
    end
  end
  activeSet = newActive
end

local function showEverything()
  for objectIndex in pairs(allObjectIds) do
    setObjectVisible(objectIndex, true, true)
    activeSet[objectIndex] = true
  end
end

local function hideEverything()
  for objectIndex in pairs(allObjectIds) do
    setObjectVisible(objectIndex, false)
  end
  activeSet = {}
end

-- ---------------------------------------------------------------------------
-- Public entry points
-- ---------------------------------------------------------------------------

-- Hard re-apply: hides every indexed object first, then shows the active set.
-- Needed because the level loads with everything visible - applyActiveSet alone
-- only hides objects it previously showed, so untouched objects would stay visible.
local function refreshVisibility()
  if streamingMode == 0 then
    showEverything()
    return
  end
  hideEverything()
  local camPos = core_camera.getPosition()
  currentSectionID = camPos and findSection(camPos) or nil
  applyActiveSet(computeActiveSet(currentSectionID))
end

-- Calls the engine's static-collision rebuild. The exact API name is unverified,
-- so try the known candidates guarded and log which one worked.
local function reloadStaticCollision()
  for _, fnName in ipairs({ "reloadCollision", "reloadStaticCollision" }) do
    if be and be[fnName] then
      local ok, err = pcall(function() be[fnName](be) end)
      print(string.format("[sectionStreamer] be:%s() -> %s", fnName, ok and "ok" or tostring(err)))
      if ok then return true end
    end
  end
  print("[sectionStreamer] WARNING: no static collision reload function found on 'be'")
  return false
end

-- Refresh button: show every indexed object except hidden override groups,
-- rebuild static collision with all of those present, then (a few frames later,
-- so the rebuild has settled) hide whatever the streamer says is out of range.
local function refreshWithCollision()
  streamingHalted = false -- a refresh always resumes streaming
  for objectIndex in pairs(allObjectIds) do
    -- mode 0 is the pure "show everything" debug mode and ignores overrides
    setObjectVisible(objectIndex, streamingMode == 0 or isOverrideAllowed(objectIndex))
  end
  activeSet = {}
  reloadStaticCollision()
  if streamingMode ~= 0 then
    pendingRestoreFrames = 3
  end
end

-- Temporary halt for testing: show every object (overrides included) and pause
-- all streaming logic. Resuming re-applies the normal state (no collision rebuild).
local function setHalted(halted)
  if halted == streamingHalted then return end
  streamingHalted = halted
  pendingRestoreFrames = 0
  if halted then
    showEverything()
  else
    currentSectionID = nil
    refreshVisibility()
  end
end

local function isHalted()
  return streamingHalted
end

-- Full reset: called on level load and whenever this Lua module is reloaded
-- (e.g. gameEngine Lua restart), so state never depends on what was loaded
-- before the restart.
local function initializeObjects(basePathOverride)
  currentSectionID = nil
  activeSet = {}
  lastMode = streamingMode

  if basePathOverride then basePath = basePathOverride end
  sectionsJsonPath = basePath .. "/lua/sections.json"
  loadSectionsJson()
  scanObjects()
  computeOrphanSections()

  -- Level load starts from the clean level: every object visible except hidden
  -- override groups, static collision rebuilt from that, then streaming applies.
  refreshWithCollision()
end

local function onUpdate(dtReal, dtSim, dtRaw)
  if streamingHalted then return end

  if pendingRestoreFrames > 0 then
    pendingRestoreFrames = pendingRestoreFrames - 1
    if pendingRestoreFrames == 0 then
      refreshVisibility()
    end
    return
  end

  if lastMode ~= streamingMode then
    -- Mode changed at runtime - force back to a clean, consistent state.
    currentSectionID = nil
    refreshVisibility()
    lastMode = streamingMode
    return
  end

  if streamingMode == 0 then return end

  updateEmitterDistance(dtReal)

  local camPos = core_camera.getPosition()
  if not camPos then return end

  -- Fast path: still inside the current section, nothing to do.
  if currentSectionID and isInSection(camPos, currentSectionID) then
    return
  end

  -- Slow path: full section lookup (containment, then edge-distance fallback).
  local newSectionID = findSection(camPos)
  if newSectionID ~= currentSectionID then
    currentSectionID = newSectionID
    applyActiveSet(computeActiveSet(currentSectionID))
  end
end

M.initializeObjects = initializeObjects
M.onUpdate = onUpdate

-- Override-group control (static allow-list stand-in for game states).
-- Re-applies immediately so a toggle shows up without waiting for a section change.
local function setOverrideEnabled(overrideName, enabled)
  alwaysOnOverrides[overrideName] = enabled or nil
  if streamingMode ~= 0 and not streamingHalted then
    applyActiveSet(computeActiveSet(currentSectionID))
  end
end

local function isOverrideEnabled(overrideName)
  return alwaysOnOverrides[overrideName] == true
end

-- For a future imgui panel: every override name seen on any object, and which
-- section the camera is currently in.
local function getKnownOverrideNames()
  local names = {}
  for name in pairs(knownOverrideNames) do table.insert(names, name) end
  table.sort(names)
  return names
end

local function getCurrentSectionID()
  return currentSectionID
end

-- Section ID -> display name, e.g. 1101 -> "1101 (K01)": digits above the
-- last two are a 1-26 letter index (A-Z), the last two digits are the
-- section number - same convention the region viewer uses.
local function sectionIDToDisplayName(id)
  if not id then return "none" end
  local letterIndex = math.floor(id / 100)
  local sectionNum = id % 100
  if letterIndex < 1 or letterIndex > 26 then
    return tostring(id)
  end
  return string.format("%d (%s%02d)", id, string.char(64 + letterIndex), sectionNum)
end

-- Proximity rank for sorting override lists: 0 = used in the current
-- section itself, 1 = used in one of its related sections, 2 = elsewhere.
local function getOverrideProximityRank(overrideName)
  local secSet = overrideSectionSet[overrideName]
  if not secSet or not currentSectionID then return 2 end
  if secSet[currentSectionID] then return 0 end
  local related = sections[currentSectionID] and sections[currentSectionID].related or {}
  for _, relID in ipairs(related) do
    if secSet[relID] then return 1 end
  end
  return 2
end

-- All known override names, nearest-to-current-section first (topology-based:
-- current section, then related sections, then everything else), alphabetical
-- within each rank.
local function getSortedOverrideNames()
  local names = getKnownOverrideNames()
  table.sort(names, function(a, b)
    local ra, rb = getOverrideProximityRank(a), getOverrideProximityRank(b)
    if ra ~= rb then return ra < rb end
    return a < b
  end)
  return names
end

M.setOverrideEnabled = setOverrideEnabled
M.isOverrideEnabled = isOverrideEnabled
M.getKnownOverrideNames = getKnownOverrideNames
M.getCurrentSectionID = getCurrentSectionID
M.sectionIDToDisplayName = sectionIDToDisplayName
M.getSortedOverrideNames = getSortedOverrideNames
M.refresh = refreshWithCollision
M.setHalted = setHalted
M.isHalted = isHalted

return M
