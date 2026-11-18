-- nfsc_sectionStreamer, part "camera": the current-section change and the per-frame camera update (velocity, look-ahead, prediction).
-- Loaded by sectionStreamer.lua into the shared streamer environment; every name here is shared with the other parts.

-- ---------------------------------------------------------------------------
-- Section residency
-- ---------------------------------------------------------------------------
function setCurrentSection(newID)
  local oldID, oldActive = currentSectionID, activeSet
  currentSectionID = newID
  activeSet = computeActive(newID)

  for id in pairs(oldActive) do
    if not activeSet[id] then
      sectionRead[id], sectionReading[id] = nil, nil
      releasePending(id)
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
  if not settled and oldID ~= nil then                             -- the camera left before the last change finished loading
    local waiting = (pqTail - pqHead + 1) + (lqTail - lqHead + 1)
    local reads = srTail - srHead + 1
    droppedSections = droppedSections + 1
    droppedObjects = droppedObjects + waiting + pendingCount
    droppedLast = { section = oldID, after = totalTime - changeStamp, created = createdSinceChange,
                    queued = waiting, waiting = pendingCount, reads = reads, to = newID }
    logMsg("W", "dropped section %s: left after %.2f s with %d objects created, %d queued and %d waiting records not loaded (%d section reads pending), going to %s",
      tostring(oldID), totalTime - changeStamp, createdSinceChange, waiting, pendingCount, reads, tostring(newID))
  end
  local promoted = purgeQueue()                                    -- nothing stale waits behind new work
  if promoted and promoted > 0 and TUNING.logSettle then
    logMsg("D", "section %s: %d queued objects of this section moved ahead of the leftovers", tostring(newID), promoted)
  end
  changeStamp, createdSinceChange, settled = totalTime, 0, (newID == nil)
  change = newChange()
  priorityTimer = 0
  rebuildFeedOrder()
  for i = 1, #feedOrder do queueSectionRead(feedOrder[i]) end      -- current section first
  local newBase, oldBase = hold.baseOf(newID), hold.baseOf(oldID)
  if newBase ~= oldBase then                                       -- the shape cache follows base sections only
    hold.sectionEntered(newBase)
    hold.visitChange(oldBase, newBase)
  end
  local st = hold.stack.last
  if st and st.chosen == newID and (hold.stack.depth[newID or 0] or hold.stack.depth[oldID or 0] or hold.stack.byBase[newID or 0]) then
    logMsg("I", "stacked section: %s -> %s (base %s), elevation triangle %s, surface height %s, camera height %.2f (offset %.2f)",
      tostring(oldID), tostring(newID), tostring(st.base), tostring(st.triangle),
      st.surface and string.format("%.2f", st.surface) or "none", st.z, TUNING.elevationZOffset)
  end
  hook("onNfscSectionChanged", newID, oldID)
end

-- Tracks the camera velocity and picks the section to stream for: the one under the camera, or,
-- once it has been stable for predictionStableTime, the one the camera is about to enter.
function updateCamera(dt)
  local cam = core_camera and core_camera.getPosition and core_camera.getPosition()
  if not cam then return end
  selectTimer = selectTimer + dt
  local interval = currentSectionID and TUNING.selectionInterval or TUNING.noSectionLookupInterval
  if selectTimer < interval then return end
  local step = math.min(selectTimer, 1.0)
  selectTimer = 0

  local vx, vy = 0, 0
  if camPos then vx, vy = (cam.x - camPos.x) / step, (cam.y - camPos.y) / step end
  camPos = camPos or { x = 0, y = 0 }
  camPos.x, camPos.y = cam.x, cam.y
  if math.sqrt(vx * vx + vy * vy) > TUNING.predictionMaxSpeed then
    camVel.x, camVel.y = 0, 0                                      -- a jump, not driving
  else
    camVel.x, camVel.y = camVel.x * 0.5 + vx * 0.5, camVel.y * 0.5 + vy * 0.5
  end

  scratch.x, scratch.y = cam.x, cam.y
  local actual = sectionAt(scratch, cam.z)
  local desired = actual
  predictedSectionID = nil
  local speed = math.sqrt(camVel.x * camVel.x + camVel.y * camVel.y)
  if TUNING.predictionEnabled and speed >= TUNING.predictionMinSpeed then
    local reach = math.min(TUNING.predictionSeconds, TUNING.predictionMaxDistance / speed)
    aheadPoint.x, aheadPoint.y = cam.x + camVel.x * reach, cam.y + camVel.y * reach
    predictedSectionID = sectionAt(aheadPoint, cam.z)
  end
  if predictedSectionID and predictedSectionID ~= actual then
    if aheadCandidate == predictedSectionID then
      aheadTime = aheadTime + step
    else
      aheadCandidate, aheadTime = predictedSectionID, 0
    end
    if aheadTime >= TUNING.predictionStableTime then desired = predictedSectionID end
  else
    aheadCandidate, aheadTime = nil, 0
  end
  local cameraMoved = cameraSectionID ~= actual
  cameraSectionID = actual
  if desired ~= currentSectionID then
    setCurrentSection(desired)
  elseif cameraMoved then
    purgeQueue()                                                   -- the camera crossed into the section streamed ahead
  end
end
