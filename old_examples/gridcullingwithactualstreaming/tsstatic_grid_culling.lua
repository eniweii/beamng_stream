-- Generic grid-based TSStatic streaming (baseline)
-- Loads/unloads TSStatic shape data based on camera cell + view frustum,
-- with distance-radius and time-cooldown hysteresis to avoid I/O thrashing
-- at cell/frustum boundaries. This reassigns shapeName (real resource
-- load/unload via refcounting), not .hidden visibility toggling.

local M = {}

-- TWEAKS
local partitionGridSpaceSize = 16.0  -- dense grid cell size, in world units
local reloadViewDistance = 300.0     -- world units: objects within this + in frustum get loaded
local unloadViewDistance = 450.0     -- world units: must be > reloadViewDistance (distance hysteresis buffer)
local cullingEnabled = true  -- hardcoded on/off flag
local cameraAspect = 16.0 / 9.0 -- assumed fixed aspect, no live window-size query available
local frustumRecheckAngleDeg = 3.0  -- re-run reload/frustum test once camera forward rotates past this
local frustumRecheckCooldown = 0.1  -- seconds, minimum gap between frustum rechecks regardless of angle
local unloadCooldown = 2.0   -- seconds an object must stay outside unloadViewDistance before it's actually unloaded

-- Derived cell-radius from the world-distance tweaks above (recomputed once, since
-- partitionGridSpaceSize is a fixed constant here, not something changed at runtime)
local gridRadius = math.ceil(reloadViewDistance / partitionGridSpaceSize)
local unloadGridRadius = math.ceil(unloadViewDistance / partitionGridSpaceSize)

-- DATA, DON'T TOUCH
local partitionGridMin
local partitionGridMax
local partitionGridSpacesX
local partitionGridSpacesY
local totalPartitionGridSpaces
local partitionGrid = {}
local partitionWorldMinZ
local partitionWorldMaxZ

local lastValue = nil
local lastCameraCell = -1
local allObjects = {}
local allObjectIds = {} -- objectIndex -> persistent object ID, re-resolved at use time
                         -- (cached Lua object references can go stale once postApply()
                         -- rebuilds the underlying SimObject on an empty shapeName)
local originalShapeNames = {} -- objectIndex -> shapeName captured at init, restored on reload

local loadedSet = {}     -- objectIndex -> true, objects that currently have their real shape assigned
local pendingUnload = {} -- objectIndex -> totalTime timestamp when it became an unload candidate
local totalTime = 0      -- accumulated dtReal, used as the cooldown clock

local lastFrustumForward = nil
local timeSinceLastRecheck = 0

local function cross(a, b)
  return vec3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
end

local function rotateAroundAxis(v, axis, angleRad)
  local cosA, sinA = math.cos(angleRad), math.sin(angleRad)
  local dot = v.x * axis.x + v.y * axis.y + v.z * axis.z
  local cx = axis.y * v.z - axis.z * v.y
  local cy = axis.z * v.x - axis.x * v.z
  local cz = axis.x * v.y - axis.y * v.x
  return vec3(
    v.x * cosA + cx * sinA + axis.x * dot * (1 - cosA),
    v.y * cosA + cy * sinA + axis.y * dot * (1 - cosA),
    v.z * cosA + cz * sinA + axis.z * dot * (1 - cosA)
  )
end

local function orientedNormal(n, refDir)
  if n.x * refDir.x + n.y * refDir.y + n.z * refDir.z < 0 then
    return vec3(-n.x, -n.y, -n.z)
  end
  return n
end

-- Builds the 4 side planes of the camera's view frustum (near/far skipped -
-- distance hysteresis via gridRadius/unloadGridRadius already handles depth cutoff).
-- All 4 planes pass through the camera position since it's the frustum apex.
local function getFrustumPlanes()
  local camPos = core_camera.getPosition()
  local fwd = core_camera.getForward()
  local right = core_camera.getRight()
  local up = core_camera.getUp()
  local fovRad = core_camera.getFovRad()

  local halfVFov = fovRad * 0.5
  local halfHFov = math.atan(math.tan(halfVFov) * cameraAspect)

  local edgeLeft = rotateAroundAxis(fwd, up, halfHFov)
  local edgeRight = rotateAroundAxis(fwd, up, -halfHFov)
  local edgeTop = rotateAroundAxis(fwd, right, halfVFov)
  local edgeBottom = rotateAroundAxis(fwd, right, -halfVFov)

  local nLeft = orientedNormal(cross(edgeLeft, up), fwd)
  local nRight = orientedNormal(cross(up, edgeRight), fwd)
  local nTop = orientedNormal(cross(edgeTop, right), fwd)
  local nBottom = orientedNormal(cross(right, edgeBottom), fwd)

  return {
    { normal = nLeft, point = camPos },
    { normal = nRight, point = camPos },
    { normal = nTop, point = camPos },
    { normal = nBottom, point = camPos },
  }
end

-- Positive-vertex AABB-vs-frustum test: false only if the box is fully
-- behind at least one plane (guaranteed outside).
local function boxIntersectsFrustum(boxMin, boxMax, planes)
  for _, plane in ipairs(planes) do
    local n = plane.normal
    local px = n.x >= 0 and boxMax.x or boxMin.x
    local py = n.y >= 0 and boxMax.y or boxMin.y
    local pz = n.z >= 0 and boxMax.z or boxMin.z
    local dist = n.x * (px - plane.point.x) + n.y * (py - plane.point.y) + n.z * (pz - plane.point.z)
    if dist < 0 then
      return false
    end
  end
  return true
end

local function getCellForPosition(p)
  local xCell = math.floor((p.x - partitionGridMin.x) / partitionGridSpaceSize)
  local yCell = math.floor((p.y - partitionGridMin.y) / partitionGridSpaceSize)
  return xCell, yCell
end

local function getCellIndexForPosition(p)
  local xCell, yCell = getCellForPosition(p)
  return (yCell * partitionGridSpacesX) + xCell
end

local function positionInRange(p)
  return p.x >= partitionGridMin.x and p.x <= partitionGridMax.x
     and p.y >= partitionGridMin.y and p.y <= partitionGridMax.y
end

local function loadObject(objectIndex)
  local object = scenetree.findObjectById(allObjectIds[objectIndex])
  if not object then return end
  object.shapeName = originalShapeNames[objectIndex]
  object:postApply()
  loadedSet[objectIndex] = true
  pendingUnload[objectIndex] = nil
end

local function unloadObject(objectIndex)
  local object = scenetree.findObjectById(allObjectIds[objectIndex])
  if not object then
    loadedSet[objectIndex] = nil
    pendingUnload[objectIndex] = nil
    return
  end
  object.shapeName = ""
  object:postApply()
  print(string.format("[streaming] UNLOAD objIndex=%d totalTime=%.2f", objectIndex, totalTime))
  loadedSet[objectIndex] = nil
  pendingUnload[objectIndex] = nil
end

-- Computes the reload candidates (cells within gridRadius AND in the view frustum)
-- and the keep-alive candidates (cells within the larger unloadGridRadius, distance only,
-- no frustum test) around the camera's current cell.
local function computeCandidateSets(xCell, zCell, planes)
  local reloadSet = {}
  local keepAliveSet = {}

  local minXReload = math.max(0, xCell - gridRadius)
  local maxXReload = math.min(partitionGridSpacesX - 1, xCell + gridRadius)
  local minYReload = math.max(0, zCell - gridRadius)
  local maxYReload = math.min(partitionGridSpacesY - 1, zCell + gridRadius)

  local minXKeep = math.max(0, xCell - unloadGridRadius)
  local maxXKeep = math.min(partitionGridSpacesX - 1, xCell + unloadGridRadius)
  local minYKeep = math.max(0, zCell - unloadGridRadius)
  local maxYKeep = math.min(partitionGridSpacesY - 1, zCell + unloadGridRadius)

  for x = minXKeep, maxXKeep, 1 do
    for z = minYKeep, maxYKeep, 1 do
      local cellObjects = partitionGrid[1 + (z * partitionGridSpacesX) + x]

      for _, objectIndex in ipairs(cellObjects) do
        keepAliveSet[objectIndex] = true
      end

      local inReloadRange = x >= minXReload and x <= maxXReload and z >= minYReload and z <= maxYReload
      if inReloadRange then
        local cellMin = vec3(partitionGridMin.x + x * partitionGridSpaceSize,
                              partitionGridMin.y + z * partitionGridSpaceSize, partitionWorldMinZ)
        local cellMax = vec3(cellMin.x + partitionGridSpaceSize, cellMin.y + partitionGridSpaceSize, partitionWorldMaxZ)
        if boxIntersectsFrustum(cellMin, cellMax, planes) then
          for _, objectIndex in ipairs(cellObjects) do
            reloadSet[objectIndex] = true
          end
        end
      end
    end
  end

  return reloadSet, keepAliveSet
end

-- Reload anything newly in range/frustum immediately, and mark anything that
-- fell outside the keep-alive radius as an unload candidate (not unloaded yet).
local function applyStreaming(xCell, zCell)
  local planes = getFrustumPlanes()
  local reloadSet, keepAliveSet = computeCandidateSets(xCell, zCell, planes)

  local reloadCount, keepAliveCount = 0, 0
  for _ in pairs(reloadSet) do reloadCount = reloadCount + 1 end
  for _ in pairs(keepAliveSet) do keepAliveCount = keepAliveCount + 1 end
  print(string.format("[streaming] cell(%d,%d) reloadSet=%d keepAliveSet=%d", xCell, zCell, reloadCount, keepAliveCount))

  for objectIndex in pairs(reloadSet) do
    if not loadedSet[objectIndex] then
      loadObject(objectIndex)
    else
      pendingUnload[objectIndex] = nil -- cancel any scheduled unload, it's back in view
    end
  end

  for objectIndex in pairs(loadedSet) do
    if not keepAliveSet[objectIndex] and not pendingUnload[objectIndex] then
      pendingUnload[objectIndex] = totalTime
    end
  end
end

-- Cheap per-frame pass: only iterates the (small) pending-unload list, not all objects.
local function processPendingUnloads()
  local pendingCount = 0
  for _ in pairs(pendingUnload) do pendingCount = pendingCount + 1 end
  if pendingCount > 0 then
    print(string.format("[streaming] pendingUnload=%d totalTime=%.2f", pendingCount, totalTime))
  end
  for objectIndex, scheduledAt in pairs(pendingUnload) do
    if totalTime - scheduledAt >= unloadCooldown then
      unloadObject(objectIndex)
    end
  end
end

local function initializeObjects()
  allObjects = {}
  allObjectIds = {}
  partitionGrid = {}
  originalShapeNames = {}
  loadedSet = {}
  pendingUnload = {}
  totalTime = 0
  lastFrustumForward = nil
  timeSinceLastRecheck = 0
  partitionWorldMinZ = nil
  partitionWorldMaxZ = nil

  local scenetreeData = scenetree:getAllObjects()
  if scenetreeData then
    for k, name in pairs(scenetreeData) do
      local object = scenetree.findObject(name)
      if object and object:isSubClassOf("TSStatic") then
        table.insert(allObjects, object)
      end
    end
  end

  local minX, minY = 99999.0, 99999.0
  local maxX, maxY = -99999.0, -99999.0

  for i, v in ipairs(allObjects) do
    local pos = v:getWorldBoxCenter()
    minX = math.min(pos.x, minX)
    minY = math.min(pos.y, minY)
    maxX = math.max(pos.x, maxX)
    maxY = math.max(pos.y, maxY)
  end

  partitionGridMin = vec3(minX, minY, 0)
  partitionGridMax = vec3(maxX, maxY, 0)
  partitionGridSpacesX = math.ceil((partitionGridMax.x - partitionGridMin.x) / partitionGridSpaceSize)
  partitionGridSpacesY = math.ceil((partitionGridMax.y - partitionGridMin.y) / partitionGridSpaceSize)
  totalPartitionGridSpaces = partitionGridSpacesX * partitionGridSpacesY

  for i = 1, totalPartitionGridSpaces, 1 do
    table.insert(partitionGrid, {})
  end

  -- Insert each object into every cell its world-space bounding box overlaps,
  -- not just the cell containing its center. Otherwise an object whose bounds
  -- cross a cell boundary can be unloaded even while part of it is in view.
  for i, v in ipairs(allObjects) do
    local box = v:getWorldBox() -- box3F: .minExtents / .maxExtents
    partitionWorldMinZ = math.min(partitionWorldMinZ or box.minExtents.z, box.minExtents.z)
    partitionWorldMaxZ = math.max(partitionWorldMaxZ or box.maxExtents.z, box.maxExtents.z)

    originalShapeNames[i] = v.shapeName
    allObjectIds[i] = v:getID()

    local minXCell, minYCell = getCellForPosition(box.minExtents)
    local maxXCell, maxYCell = getCellForPosition(box.maxExtents)
    minXCell = math.max(0, math.min(minXCell, partitionGridSpacesX - 1))
    maxXCell = math.max(0, math.min(maxXCell, partitionGridSpacesX - 1))
    minYCell = math.max(0, math.min(minYCell, partitionGridSpacesY - 1))
    maxYCell = math.max(0, math.min(maxYCell, partitionGridSpacesY - 1))
    for x = minXCell, maxXCell, 1 do
      for z = minYCell, maxYCell, 1 do
        table.insert(partitionGrid[1 + (z * partitionGridSpacesX) + x], i)
      end
    end
  end

  if cullingEnabled then
    local camPos = core_camera.getPosition()
    if positionInRange(camPos) then
      local xCell, zCell = getCellForPosition(camPos)
      local planes = getFrustumPlanes()
      local reloadSet, keepAliveSet = computeCandidateSets(xCell, zCell, planes)

      -- Objects already within keep-alive range are already spawned with their
      -- real shape - just record them as loaded, no need to touch shapeName/postApply.
      for i, v in ipairs(allObjects) do
        if keepAliveSet[i] then
          loadedSet[i] = true
        else
          unloadObject(i)
        end
      end

      lastCameraCell = getCellIndexForPosition(camPos)
    else
      -- Camera position not valid yet (e.g. too early in mission start) - safe fallback
      for i, v in ipairs(allObjects) do
        unloadObject(i)
      end
      lastCameraCell = -1
    end
  else
    for i, v in ipairs(allObjects) do
      loadObject(i)
    end
    lastCameraCell = -1
  end

  lastValue = cullingEnabled
end

local function onUpdate(dtReal, dtSim, dtRaw)
  totalTime = totalTime + (dtReal or 0)

  if cullingEnabled then
    if lastValue ~= cullingEnabled then
      for i, v in ipairs(allObjects) do
        unloadObject(i)
      end
      lastValue = cullingEnabled
      lastCameraCell = -1
      lastFrustumForward = nil
    end

    local camPos = core_camera.getPosition()
    if positionInRange(camPos) then
      local cameraCell = getCellIndexForPosition(camPos)
      local fwd = core_camera.getForward()
      timeSinceLastRecheck = timeSinceLastRecheck + (dtReal or 0)

      local angleChanged = false
      if lastFrustumForward then
        local dot = math.max(-1, math.min(1, fwd.x * lastFrustumForward.x + fwd.y * lastFrustumForward.y + fwd.z * lastFrustumForward.z))
        local angleDeg = math.deg(math.acos(dot))
        angleChanged = angleDeg >= frustumRecheckAngleDeg
      else
        angleChanged = true
      end

      if cameraCell ~= lastCameraCell
         or (angleChanged and timeSinceLastRecheck >= frustumRecheckCooldown) then
        local xCell, zCell = getCellForPosition(camPos)
        applyStreaming(xCell, zCell)
        lastCameraCell = cameraCell
        lastFrustumForward = fwd
        timeSinceLastRecheck = 0
      end
    end

    -- Runs every tick regardless of throttle, but only touches the small pending-unload list
    processPendingUnloads()
  else
    if lastValue ~= cullingEnabled then
      for i, v in ipairs(allObjects) do
        loadObject(i)
      end
      lastValue = cullingEnabled
    end
  end
end

M.initializeObjects = initializeObjects
M.onUpdate = onUpdate

return M
