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
--   lua/carbon_stream/shapes.json       written by the builder (schemaVersion 1): unique shapes + per-section lists
--   lua/carbon_stream/sections/<id>.json  one whole file per section
--
-- Events (coarse, via extensions.hook):
--   onNfscStreamerInitialized()
--   onNfscSectionChanged(newSectionID, oldSectionID)   -- nil = camera outside every section
-- Events (fine, via M.addListener(table)); each is called as listener:method(...):
--   onObjectCreated(key, obj, item)   onObjectDeleted(key)   onStreamerReset()
--
-- Queue model: reading a section file fills a per-section PENDING list (terrain first, then the
-- rest, each grouped by shapeName). Pending records are fed into the load queue, which never
-- holds more than maxQueuedItems, current section first and then its related sections. A
-- section change drops queue entries and pending data that no active section needs any more.
--
-- Look-ahead and priority (as in the game's TrackStreamer): the camera velocity gives a point
-- min(1.5 s, 100 m) ahead. When that point lies in another section for a short, stable time, that
-- section becomes the current one before the camera crosses the border. Related sections are fed
-- in the game's three loading-priority bands (distance of the point one second ahead outside the
-- section, shrunk when heading towards it), the old static order breaks ties. Timing counters in
-- getStatus() and one log line per finished load show where the time goes.
--
-- Create filter (optional, set by the manager): M.setCreateFilter(fn). fn(item) == false means
-- "do not create this object now"; such items wait in a deferred list for as long as their
-- section is active, and M.refreshFilter() re-evaluates them. M.releaseObject(key, item) deletes
-- a live object and defers it again. The streamer never looks at what the filter decides on.
--
-- Exported transforms are applied exactly as exported: position, rotationEuler and scale
-- are written with setField as space-joined text, the same way every other field is.
--
-- Shape cache warm-up (idle lane): BeamNG builds <shape>.cdae from the .dae the first time a shape is
-- used ("Importing COLLADA..."), inside the registerObject call, which cannot be split across frames.
-- When both queues have been empty for cacheWarmIdleSeconds, the lane takes the shapes of the current and
-- related sections first, then the rest of shapes.json, skips shapes whose .cdae already exists
-- (FS:fileExists) and imports the others one at a time, cacheWarmGapSeconds apart: a hidden TSStatic
-- below the camera, created and deleted in the same call, so it is never drawn and keeps no memory. The
-- .cdae on disk is the progress record. Without FS:fileExists or shapes.json the lane stays off.
-- getCacheWarmStatus() feeds a progress display.
--
-- Creation methods (TUNING.creationMode, switch at runtime with M.setCreationMode):
--   "current": every streamed object is created with createObject/registerObject and deleted again.
--   "shells":  objects are never deleted. A released object is PARKED: it gets the tiny shellShape, is hidden and
--              goes to a free list (a TSStatic cannot be registered without a shape). A load takes a parked
--              shell and fills it in: shapeName, every item field, one postApply, unhide. Fields the previous
--              item set and the new one does not are put back to the engine default, so nothing leaks between
--              items. With no parked shell left the object is created the current way and joins the pool when
--              it is released. TUNING.shellTarget > 0 builds parked shells ahead, in the background, while the
--              urgent queue is empty. Objects are named nfsc_shell_<n>; everything is keyed by section ID.
--   "resident": shells, plus a resting state like the game's LOADED section. An object nobody wants any more is
--              DEACTIVATED at once (residentCooldown, default 0): hidden, still bound to its key with its shape and
--              fields, no field writes. Wanting it again REVIVES it: unhide, nothing else. Only when a load needs a
--              shell and the pool is at TUNING.residentMax the oldest deactivated object is EVICTED and its shell
--              reused (the way the game frees the oldest LOADED section). residentReserve keeps that many shells
--              free ahead of time, evicting in idle frames. The cap bounds RAM; nothing else grows with the level.
--
-- Tuning: M.getTuning / setTuning / resetTuning change the values live; savePreset / loadPreset / listPresets /
-- deletePreset keep named sets in lua/carbon_stream/tuning_presets.json (a preset called "startup" is applied
-- at initialize). The manager panel has sliders for the common ones.

local M = {}

-- ---------------------------------------------------------------------------
-- Tuning (override at runtime with M.setTuning{...})
-- ---------------------------------------------------------------------------
local TUNING = {
  levelRoot = "levels/nfsc",
  maxCreatesPerFrame = 16,
  maxDeletesPerFrame = 256,
  frameBudgetMs = 16.0,           -- one budget for the whole frame: deletes first, creates get what is left
  deleteBudgetShare = 0.25,       -- deletes may use at most this share of frameBudgetMs
  maxFirstUsePerFrame = 3,        -- new shapes (4-20 ms each) per frame; a later new shape waits for the next frame
  firstUseGuessMs = 6.0,          -- expected first-use cost until a real average exists
  currentSectionFirst = true,     -- objects of the section the camera is in (and the one streamed for) load before everything else
  probeOnSettle = true,           -- after a section settled with new objects, time a few test registerObject calls and log them
  probeCount = 20,                -- test objects per probe pass when it runs by itself
  skipNameLookup = false,         -- true: name every object "nfsc_<key>" without the scenetree.findObject duplicate check
  stallLogMs = 100,               -- a single create or cache import slower than this is logged at once (shape, kind)
  logEmptySettles = false,        -- true: also print the settled line of a change that created nothing
  cacheWarm = true,               -- idle-time warm-up of the .cdae shape cache (see header)
  cacheWarmPerFrame = 1,          -- shapes imported per frame; each one is a stall of its own import time
  cacheWarmGapSeconds = 0.25,     -- pause after every import (0 = back to back, for a loading screen)
  cacheWarmIdleSeconds = 1.0,     -- both load queues must have been empty this long before the lane starts
  cacheWarmCheckMs = 1.0,         -- time per frame for skipping shapes that already have a .cdae
  cacheWarmLogEvery = 100,        -- progress line after this many imports (0 = none)
  maxSectionReadsPerFrame = 1,
  maxQueuedItems = 512,           -- hard cap of the load queue; the rest waits in pending lists
  maxPendingRecords = 8192,       -- do not read another section file while this many records wait
  unloadCooldown = 2.0,           -- seconds a no-longer-wanted object survives
  containmentTolerance = 0.1,     -- GetDistanceOutside fallback, same as the game
  noSectionLookupInterval = 0.1,  -- seconds between lookups while outside every section
  forceCollisionNone = true,      -- collision policy for the first in-game test (see docs)
  verifyFirstN = 3,               -- log readbacks of the first N created objects
  runtimeGroupName = "NFSC_StreamedScenery",
  predictionEnabled = true,       -- switch to the section ahead before the camera crosses the border
  predictionSeconds = 1.5,        -- look-ahead time, same as the game
  predictionMaxDistance = 100.0,  -- look-ahead cap in metres, same as the game
  predictionMinSpeed = 1.0,       -- m/s; slower than this there is no prediction
  predictionMaxSpeed = 178.81,    -- m/s (400 mph); faster is treated as a jump and not predicted
  predictionStableTime = 0.25,    -- seconds the section ahead must stay the same before switching
  selectionInterval = 0.05,       -- seconds between section lookups
  priorityRefreshInterval = 0.5,  -- seconds between load-order refreshes
  logSettle = true,               -- one log line when the load of a section change has finished
  creationMode = "current",       -- "current", "shells" or "resident" (see header); M.setCreationMode(mode) switches it
  residentMax = 6000,             -- resident mode: pool size (live + deactivated + free) before the oldest deactivated one is evicted
  residentReserve = 0,            -- resident mode: free shells kept ready by evicting in idle frames (0 = evict only when a load needs one)
  residentCooldown = 0.0,         -- resident mode: seconds before an unwanted object is deactivated (it is cheap, so 0)
  shellShape = "/levels/nfsc/Assets/Meshes/NFSC_DOT.dae",  -- shape of a parked shell (tiny, never drawn: parked shells are hidden)
  shellTarget = 0,                -- keep at least this many shells (free + in use); built ahead in the background. 0 = off
  shellBuildPerFrame = 8,         -- shells built ahead per frame ...
  shellBuildBudgetMs = 2.0,       -- ... and at most this many ms of it
}

local TUNING_DEFAULTS = {}
for k, v in pairs(TUNING) do TUNING_DEFAULTS[k] = v end
local readPresets                      -- defined with the tuning API further down

local SUPPORTED_SCHEMA = 2
local SECTIONS_JSON = "lua/sections.json"
local STREAM_INDEX = "lua/carbon_stream/index.json"
local SHAPES_JSON = "lua/carbon_stream/shapes.json"
local PRESETS_JSON = "lua/carbon_stream/tuning_presets.json"
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
local priQueue, pqHead, pqTail = {}, 1, 0      -- urgent: objects of the current / camera section, served before loadQueue
local promotedTotal = 0                         -- queued objects moved ahead when a section changed
local queuedKeys = {}
local pending, pendingCount = {}, 0   -- id -> { terrain = tier, rest = tier }, tier = { list, at, n }
local deferred = {}                   -- id -> items the create filter held back
local createFilter = nil
local staleDiscarded, queueHighWater, createdLastFrame, createdPeakFrame = 0, 0, 0, 0
local live, liveBySection, liveCount = {}, {}, 0
local pendingUnload, unloadQueue, uqHead, uqTail = {}, {}, 1, 0

local totalTime, selectTimer = 0, 0
local camPos, camVel = nil, { x = 0, y = 0 }   -- last camera position and smoothed velocity (m/s)
local cameraSectionID, predictedSectionID = nil, nil
local aheadCandidate, aheadTime = nil, 0
local feedOrder, priorityTimer = {}, 0         -- sections in loading order: current first
local timing = { creates = 0, createMs = 0, createMax = 0, firsts = 0, firstMs = 0, repeats = 0, repeatMs = 0,
                 reads = 0, readMs = 0, readMax = 0, frameLast = 0, framePeak = 0 }
local seenShapes = {}
local shapeLive = {}                 -- shape -> number of live instances (0/nil: the engine may have freed it)
local recentFirstMs = nil            -- moving average of the latest first-use creates
local function newChange()
  return { creates = 0, createMs = 0, firsts = 0, firstMs = 0, repeats = 0, repeatMs = 0, maxMs = 0,
           objectMs = 0, fieldsMs = 0, registerMs = 0, groupMs = 0, frames = 0, workMs = 0, dtSum = 0, dtMax = 0, workMax = 0,
           importN = 0, importMs = 0, hitN = 0, hitMs = 0, unkN = 0, unkMs = 0,   -- first use: no .cdae before / .cdae existed / unknown
           deleted = 0, deleteMs = 0, deferredFirst = 0, shellRecycles = 0, shellRecycleMs = 0, shellFresh = 0, shellParks = 0, shellParkMs = 0, residentRevives = 0, residentReviveMs = 0, residentDeacts = 0, residentEvicts = 0,
           reloads = 0, reloadMs = 0, warms = 0, warmMs = 0, shapes = {},
           dist = { { n = 0, ms = 0 }, { n = 0, ms = 0 }, { n = 0, ms = 0 } }, nameMs = 0, liveSum = 0, liveMin = nil, liveMax = 0, rn = 0, rx = 0, ry = 0, rxx = 0, rxy = 0 }   -- r*: regression sums of registerObject ms over live count   -- shapes: name -> { n, ms, max, first, reload }
end
local change = newChange()                -- everything since the last section change
local split = { objectMs = 0, fieldsMs = 0, registerMs = 0, groupMs = 0, nameMs = 0, live = 0 }
local idleFrameMs = nil              -- moving average of the frame time while nothing is loading   -- cost of the last create
local frameStart, frameDeleteMs = 0, 0
local changeStamp, createdSinceChange, settled, settleSeconds, settlePeak = 0, 0, true, 0, 0
local createdTotal, deletedTotal, failureCount, verified = 0, 0, 0, 0
local failures = {}
local listeners = {}
local runtimeGroup = nil
local shellFree, shellFreeN = {}, 0      -- object ids of parked shells, last in first out
local shellFields = {}                   -- object id -> set of field names its current item applied
local shellDefaults, shellScratch = {}, nil   -- field name -> engine default text (read once from an untouched object)
local droppedSections, droppedObjects, droppedLast = 0, 0, nil   -- sections entered but left before their load settled
local shellSerial, shellBuildFails, shellBuildOff = 0, 0, false
local dormant, dormantOrder, doHead, doTail, dormantCount, dormantSerial = {}, {}, 1, 0, 0, 0   -- resident mode: key -> { id, shape, stamp }, oldest first
local shellStats = { built = 0, buildMs = 0, recycled = 0, recycleMs = 0, fresh = 0, parked = 0, parkMs = 0, peakLive = 0,
                     revived = 0, reviveMs = 0, deactivated = 0, evicted = 0 }
local scratch = { x = 0, y = 0 }
local aheadPoint = { x = 0, y = 0 }

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
  if shellScratch then pcall(shellScratch.delete, shellScratch); shellScratch = nil end
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
  if TUNING.skipNameLookup then return "nfsc_" .. tostring(key) end
  local wanted = (type(item.name) == "string" and item.name ~= "") and item.name or ("nfsc_" .. key)
  if scenetree.findObject(wanted) then wanted = wanted .. "_s" .. tostring(key):gsub("[^%w]", ""):sub(-6) end
  return wanted
end

-- ---------------------------------------------------------------------------
-- Shell pool (creationMode = "shells", see header)
-- ---------------------------------------------------------------------------
local shellChecked, shellDisabled = false, false

-- true only when FS:fileExists is available and says the shell shape is not there
local function shellShapeMissing()
  local fs = rawget(_G, "FS")
  if not fs then return false end
  local path = TUNING.shellShape
  local alt = path:sub(1, 1) == "/" and path:sub(2) or ("/" .. path)
  local ok1, a = pcall(function() return fs:fileExists(path) end)
  local ok2, b = pcall(function() return fs:fileExists(alt) end)
  if not ok1 and not ok2 then return false end
  return not ((ok1 and a) or (ok2 and b))
end

local function shellMode()           -- true in "shells" and "resident": objects come from and go back to the pool
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

local function residentMode()
  return TUNING.creationMode == "resident" and shellMode()
end

local function poolTotal() return liveCount + dormantCount + shellFreeN end

local function shellName()
  shellSerial = shellSerial + 1
  return "nfsc_shell_" .. shellSerial
end

-- The engine default of a field as text, read once from an object nobody has set anything on.
local function shellDefault(field)
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

local function forceNoCollision(obj)
  if TUNING.forceCollisionNone then
    pcall(obj.setField, obj, "collisionType", 0, "None")
    pcall(obj.setField, obj, "decalType", 0, "None")
  end
end

-- Takes a parked shell and fills it in from item. Returns the object, or nil when no parked shell is left.
local function acquireShell(item)
  while shellFreeN > 0 do
    local id = shellFree[shellFreeN]
    shellFree[shellFreeN] = nil
    shellFreeN = shellFreeN - 1
    local obj = scenetree.findObjectById(id)
    if obj then
      local last, applied = shellFields[id], {}
      pcall(obj.setField, obj, "shapeName", 0, item.shapeName)
      for field, value in pairs(item) do
        if field ~= "shapeName" and not RESERVED[field] then
          local text = fieldText(value)
          if text ~= nil then
            pcall(obj.setField, obj, field, 0, text)
            applied[field] = true
          end
        end
      end
      if last then                                   -- what the previous item set and this one does not
        for field in pairs(last) do
          if not applied[field] then pcall(obj.setField, obj, field, 0, shellDefault(field)) end
        end
      end
      shellFields[id] = applied
      forceNoCollision(obj)
      pcall(obj.postApply, obj)
      pcall(function() obj.hidden = false end)
      return obj
    end
    shellFields[id] = nil                            -- the engine lost it (level change, manual delete)
  end
  return nil
end

-- Releases an object to the pool instead of deleting it. false: the object is already gone.
local function parkShell(id)
  local obj = scenetree.findObjectById(id)
  if not obj then shellFields[id] = nil; return false end
  pcall(function() obj.hidden = true end)
  pcall(obj.setField, obj, "shapeName", 0, TUNING.shellShape)
  pcall(obj.postApply, obj)
  shellFreeN = shellFreeN + 1
  shellFree[shellFreeN] = id
  return true
end

-- One new parked shell. Returns true, or false and the reason.
local function buildShell()
  local obj = createObject("TSStatic")
  if not obj then return false, "createObject(TSStatic) returned nil" end
  pcall(obj.setField, obj, "shapeName", 0, TUNING.shellShape)
  forceNoCollision(obj)
  pcall(function() obj.hidden = true end)
  local ok, err = pcall(obj.registerObject, obj, shellName())
  if ok and err == false then ok, err = false, "the engine refused it (returned false)" end
  if not ok then
    pcall(obj.delete, obj)
    return false, tostring(err)
  end
  local okId, id = pcall(obj.getID, obj)
  if not okId or not id or not scenetree.findObjectById(id) then return false, "the object is not alive after registerObject" end
  local group = ensureRuntimeGroup()
  pcall(group.addObject, group, obj)
  shellFreeN = shellFreeN + 1
  shellFree[shellFreeN] = id
  shellStats.built = shellStats.built + 1
  return true
end

-- Resident mode: the resting state ------------------------------------------------------------------------
-- Deactivate: hide, keep key, shape and fields. Returns false when the engine object is gone.
local function deactivateDormant(key, entry)
  local obj = scenetree.findObjectById(entry.id)
  if not obj then shellFields[entry.id] = nil; return false end
  pcall(function() obj.hidden = true end)
  dormantSerial = dormantSerial + 1
  dormant[key] = { id = entry.id, shape = entry.shape, stamp = dormantSerial }
  doTail = doTail + 1
  dormantOrder[doTail] = { key = key, stamp = dormantSerial }
  dormantCount = dormantCount + 1
  if entry.shape then shapeLive[entry.shape] = (shapeLive[entry.shape] or 0) + 1 end   -- the shape stays loaded
  shellStats.deactivated = shellStats.deactivated + 1
  change.residentDeacts = change.residentDeacts + 1
  return true
end

local function forgetDormantShape(d)
  if d.shape and shapeLive[d.shape] then
    local left = shapeLive[d.shape] - 1
    shapeLive[d.shape] = left > 0 and left or nil
  end
end

-- Revive: the object of this item's key, shown again as it was. nil when there is none.
local function reviveDormant(item)
  local key = item.__streamKey
  local d = key and dormant[key]
  if not d then return nil end
  dormant[key] = nil
  dormantCount = dormantCount - 1
  forgetDormantShape(d)                                  -- registerLive counts it again
  local obj = scenetree.findObjectById(d.id)
  if not obj then shellFields[d.id] = nil; return nil end
  pcall(function() obj.hidden = false end)
  return obj
end

-- Evicts the n oldest deactivated objects: their shells go to the free list as they are (hidden, old shape).
local function evictOldest(n)
  local done = 0
  while done < n and doHead <= doTail do
    local q = dormantOrder[doHead]
    dormantOrder[doHead] = nil
    doHead = doHead + 1
    local d = q and dormant[q.key]
    if d and d.stamp == q.stamp then                     -- skip entries that were revived meanwhile
      dormant[q.key] = nil
      dormantCount = dormantCount - 1
      forgetDormantShape(d)
      shellFreeN = shellFreeN + 1
      shellFree[shellFreeN] = d.id
      shellStats.evicted = shellStats.evicted + 1
      change.residentEvicts = change.residentEvicts + 1
      done = done + 1
    end
  end
  if doHead > doTail then dormantOrder, doHead, doTail = {}, 1, 0 end
  return done
end

-- Every deactivated object back to the pool (mode switch): parked on the dot, or deleted.
local function releaseDormant(deleteThem)
  local n = 0
  for key, d in pairs(dormant) do
    forgetDormantShape(d)
    if deleteThem then
      local obj = scenetree.findObjectById(d.id)
      if obj then pcall(obj.delete, obj) end
      shellFields[d.id] = nil
    else
      parkShell(d.id)
    end
    dormant[key] = nil
    n = n + 1
  end
  dormantOrder, doHead, doTail, dormantCount = {}, 1, 0, 0
  return n
end

local function createStreamedObject(item, nameOverride)
  local shape = item.shapeName
  if type(shape) ~= "string" or shape == "" then return nil, "missing shapeName" end
  local pooled = nameOverride == nil and shellMode()      -- probe objects (named) always take the plain path
  if pooled then
    local ta = os.clock()
    if residentMode() then
      local back = reviveDormant(item)
      if back then
        local ms = (os.clock() - ta) * 1000
        split.objectMs, split.fieldsMs, split.registerMs, split.groupMs, split.nameMs, split.live = 0, 0, 0, 0, 0, liveCount
        shellStats.revived, shellStats.reviveMs = shellStats.revived + 1, shellStats.reviveMs + ms
        change.residentRevives, change.residentReviveMs = change.residentRevives + 1, change.residentReviveMs + ms
        return back
      end
      if shellFreeN == 0 and dormantCount > 0 and poolTotal() >= TUNING.residentMax then evictOldest(1) end
    end
    local shell = acquireShell(item)
    if shell then
      local ms = (os.clock() - ta) * 1000
      split.objectMs, split.fieldsMs, split.registerMs, split.groupMs, split.nameMs, split.live = 0, ms, 0, 0, 0, liveCount
      shellStats.recycled, shellStats.recycleMs = shellStats.recycled + 1, shellStats.recycleMs + ms
      change.shellRecycles, change.shellRecycleMs = change.shellRecycles + 1, change.shellRecycleMs + ms
      return shell
    end
    shellStats.fresh = shellStats.fresh + 1                  -- no parked shell left: the current way, the object joins the pool later
    change.shellFresh = change.shellFresh + 1
  end
  local applied = pooled and {} or nil
  local t0 = os.clock()
  local obj = createObject("TSStatic")
  if not obj then return nil, "createObject(TSStatic) returned nil" end
  local t1 = os.clock()
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
  local wantedName = nameOverride or (pooled and shellName() or runtimeName(item, item.__streamKey or "x"))
  local tn = os.clock()
  local ok, err = pcall(obj.registerObject, obj, wantedName)
  if ok and err == false then ok, err = false, "the engine refused it (returned false)" end
  if not ok then
    pcall(obj.delete, obj)
    return nil, "registerObject failed: " .. tostring(err)
  end
  local t3 = os.clock()
  local group = ensureRuntimeGroup()
  pcall(group.addObject, group, obj)
  local t4 = os.clock()
  if applied then shellFields[obj:getID()] = applied end
  split.objectMs, split.fieldsMs, split.registerMs, split.groupMs =
    (t1 - t0) * 1000, (t2 - t1) * 1000, (t3 - tn) * 1000, (t4 - t3) * 1000
  split.nameMs, split.live = (tn - t2) * 1000, liveCount
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

local function unregisterLive(key)
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

local function deleteLive(key)
  local entry = unregisterLive(key)
  if not entry then return end
  notify("onObjectDeleted", key)
  deletedTotal = deletedTotal + 1
  if residentMode() and deactivateDormant(key, entry) then return end
  if shellMode() then
    local ta = os.clock()
    if parkShell(entry.id) then
      local ms = (os.clock() - ta) * 1000
      shellStats.parked, shellStats.parkMs = shellStats.parked + 1, shellStats.parkMs + ms
      change.shellParks, change.shellParkMs = change.shellParks + 1, change.shellParkMs + ms
      return
    end
  end
  local obj = scenetree.findObjectById(entry.id)
  if obj then pcall(obj.delete, obj) end
end

-- ---------------------------------------------------------------------------
-- Queues
-- ---------------------------------------------------------------------------
-- The game's GetLoadingPriority: the point one second ahead, its distance outside the section,
-- shrunk when the heading points at the section, in three 75 m bands. 0 loads first.
local function loadingPriority(id)
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
local function rebuildFeedOrder()
  feedOrder = {}
  if not currentSectionID or not sections[currentSectionID] then return end
  local entries = {}
  for rank, id in ipairs(sections[currentSectionID].related) do
    if id ~= currentSectionID then entries[#entries + 1] = { id = id, tier = loadingPriority(id), rank = rank } end
  end
  table.sort(entries, function(a, b)
    if a.tier ~= b.tier then return a.tier < b.tier end
    return a.rank < b.rank
  end)
  feedOrder[1] = currentSectionID
  for i = 1, #entries do feedOrder[i + 1] = entries[i].id end
end

local function queueSectionRead(id)
  if sectionRead[id] or sectionReading[id] then return end
  if not sectionIndex[id] then sectionRead[id] = true; return end   -- section with no streamed objects
  sectionReading[id] = true
  srTail = srTail + 1
  sectionReadQueue[srTail] = id
end

-- Objects of the section the camera is in, or the one the streamer is currently loading for, are
-- urgent: they are served before anything left over from the section just left.
local function isUrgent(item)
  if not TUNING.currentSectionFirst then return false end
  local ids = itemSections(item)
  for i = 1, #ids do
    local id = ids[i]
    if id == currentSectionID or id == cameraSectionID then return true end
  end
  return false
end

local function queueItem(item)
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
local function priLength() return pqTail - pqHead + 1 end
local function queueLength() return (lqTail - lqHead + 1) + (pqTail - pqHead + 1) end

-- Terrain-like objects (identity matrix / chopped roadway) are loaded before everything else.
local function isTerrainItem(item)
  local flags = item.instanceFlags
  if type(flags) ~= "string" then return false end
  flags = flags:lower():gsub("[^%w]", "")
  return flags:find("identitymatrix", 1, true) ~= nil or flags:find("choppedroadway", 1, true) ~= nil
end

-- Same shapeName next to each other (first appearance decides the order of the groups).
local function groupByShape(items)
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

local function appendTier(tier, items)
  if #items == 0 then return end
  local grouped = groupByShape(items)
  local list = tier.list
  for i = 1, #grouped do list[tier.n + i] = grouped[i] end
  tier.n = tier.n + #grouped
  pendingCount = pendingCount + #grouped
end

local function addPending(id, items)
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

local function releasePending(id)
  local entry = pending[id]
  if entry then
    pendingCount = pendingCount - (entry.terrain.n - entry.terrain.at + 1) - (entry.rest.n - entry.rest.at + 1)
    pending[id] = nil
  end
  deferred[id] = nil
end

local function deferItem(id, item)
  local list = deferred[id]
  if not list then list = {}; deferred[id] = list end
  list[#list + 1] = item
end

-- Feeds one tier of one section into the load queue until the queue is full.
local function feedTier(id, tierName)
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
local function feedQueue()
  if pendingCount <= 0 or not currentSectionID or not sections[currentSectionID] then return end
  if TUNING.currentSectionFirst then                       -- the camera's section and the streamed one, terrain first
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
local function purgeQueue()
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

local function scheduleUnload(key)
  if pendingUnload[key] then return end
  pendingUnload[key] = totalTime
  uqTail = uqTail + 1
  unloadQueue[uqTail] = { key = key, stamp = totalTime }
end

local function processSectionReads()
  local reads = 0
  while srHead <= srTail and reads < TUNING.maxSectionReadsPerFrame and pendingCount < TUNING.maxPendingRecords do
    local id = sectionReadQueue[srHead]
    sectionReadQueue[srHead] = nil
    srHead = srHead + 1
    if activeSet[id] and sectionReading[id] then
      reads = reads + 1
      local entry = sectionIndex[id]
      local readStart = os.clock()
      local ok, data = pcall(jsonReadFile, entry.file)
      local readMs = (os.clock() - readStart) * 1000
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
end

-- Expected cost of creating the first instance of a shape (real average once there is one).
local function shortShapeName(name)
  local base = (name:match("([^/\\]+)$") or name):gsub("%.dae$", "")
  return base
end

-- Does the engine already have a .cdae for this shape? true: a load is a cache read; false: the first use
-- imports the COLLADA and writes the cache; nil: cannot tell (no FS:fileExists, or not a .dae shape).
local fsUnavailable = false
local function fileExists(fs, path)
  local ok, res = pcall(function() return fs:fileExists(path) end)
  if not ok then return nil end
  return res and true or false
end
local function shapeCached(shape)
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

local function expectedFirstMs()
  return recentFirstMs or TUNING.firstUseGuessMs
end

local function processLoads()
  local started = os.clock()
  local budget = TUNING.frameBudgetMs - frameDeleteMs    -- creates get what the deletes left
  local made, firstUse, skipped = 0, 0, 0
  while (pqHead <= pqTail or lqHead <= lqTail) and made < TUNING.maxCreatesPerFrame and skipped < SKIP_CAP do
    local fromUrgent = pqHead <= pqTail
    local item = fromUrgent and priQueue[pqHead] or loadQueue[lqHead]
    local key = item.__streamKey
    local shape = item.shapeName
    if live[key] or not anyActive(itemSections(item)) then
      if fromUrgent then priQueue[pqHead] = nil; pqHead = pqHead + 1 else loadQueue[lqHead] = nil; lqHead = lqHead + 1 end
      queuedKeys[key] = nil
      skipped = skipped + 1
    else
      local isFirst = shape ~= nil and not seenShapes[shape]
      local isWarm = shape ~= nil and (shapeLive[shape] or 0) > 0      -- a live instance keeps the shape loaded
      if isFirst and made > 0 then
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
      local createStart = os.clock()
      local obj, err = createStreamedObject(item)
      local createMs = (os.clock() - createStart) * 1000
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
      if obj then
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
end

local function processUnloads()
  local started = os.clock()
  local limit = TUNING.frameBudgetMs * TUNING.deleteBudgetShare
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
      deleteLive(key)
      removed = removed + 1
      if (os.clock() - started) * 1000 >= limit then break end
    else
      break                                                     -- FIFO by time: the rest are newer
    end
  end
  if uqHead > uqTail then unloadQueue, uqHead, uqTail = {}, 1, 0 end
  frameDeleteMs = (os.clock() - started) * 1000
  change.deleted, change.deleteMs = change.deleted + removed, change.deleteMs + frameDeleteMs
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
    logMsg("I", "section %s: %d queued objects of this section moved ahead of the leftovers", tostring(newID), promoted)
  end
  changeStamp, createdSinceChange, settled = totalTime, 0, (newID == nil)
  change = newChange()
  priorityTimer = 0
  rebuildFeedOrder()
  for i = 1, #feedOrder do queueSectionRead(feedOrder[i]) end      -- current section first
  hook("onNfscSectionChanged", newID, oldID)
end

local function sectionAt(p)
  if currentSectionID and isInSection(p, currentSectionID) then return currentSectionID end
  return findSection(p)
end

-- Tracks the camera velocity and picks the section to stream for: the one under the camera, or,
-- once it has been stable for predictionStableTime, the one the camera is about to enter.
local function updateCamera(dt)
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
  local actual = sectionAt(scratch)
  local desired = actual
  predictedSectionID = nil
  local speed = math.sqrt(camVel.x * camVel.x + camVel.y * camVel.y)
  if TUNING.predictionEnabled and speed >= TUNING.predictionMinSpeed then
    local reach = math.min(TUNING.predictionSeconds, TUNING.predictionMaxDistance / speed)
    aheadPoint.x, aheadPoint.y = cam.x + camVel.x * reach, cam.y + camVel.y * reach
    predictedSectionID = sectionAt(aheadPoint)
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

-- ---------------------------------------------------------------------------
-- Shape cache warm-up (idle lane, see header)
-- ---------------------------------------------------------------------------
local function newWarm()
  return { loaded = false, names = {}, bySection = {}, total = 0, done = {}, processed = 0,
           near = {}, nearPos = 1, nearFor = false, cursor = 1, idle = 0, gap = 0,
           hadCdae = 0, imported = 0, failed = 0, skipped = 0, importMs = 0, importMax = 0, importMaxShape = nil,
           current = nil, finished = false }
end
local warm = newWarm()

local function loadShapeList()
  warm = newWarm()
  local data = jsonReadFile(levelRoot .. "/" .. SHAPES_JSON)
  if type(data) ~= "table" or type(data.shapes) ~= "table" then
    logMsg("I", "no %s: the shape cache warm-up is off (rebuild with the current builder)", SHAPES_JSON)
    return
  end
  warm.names, warm.total = data.shapes, #data.shapes
  if type(data.sections) == "table" then
    for id, list in pairs(data.sections) do
      local n = tonumber(id)
      if n and type(list) == "table" then warm.bySection[n] = list end
    end
  end
  warm.loaded = warm.total > 0
end

-- shapes of the current section and its related sections, in loading order, not done yet
local function warmRefreshNear()
  warm.near, warm.nearPos, warm.nearFor = {}, 1, currentSectionID
  local seen = {}
  for i = 1, #feedOrder do
    local list = warm.bySection[feedOrder[i]]
    if list then
      for j = 1, #list do
        local idx = list[j]
        if not seen[idx] and warm.done[idx] == nil then
          seen[idx] = true
          warm.near[#warm.near + 1] = idx
        end
      end
    end
  end
end

local function warmNextCandidate()
  while warm.nearPos <= #warm.near do
    local idx = warm.near[warm.nearPos]
    warm.nearPos = warm.nearPos + 1
    if warm.done[idx] == nil then return idx end
  end
  while warm.cursor <= warm.total do
    local idx = warm.cursor
    warm.cursor = warm.cursor + 1
    if warm.done[idx] == nil then return idx end
  end
  return nil
end

local function warmMark(idx, value)
  warm.done[idx] = value
  warm.processed = warm.processed + 1
end

-- Creates one hidden TSStatic of the shape below the camera and deletes it in the same call: the engine
-- imports the COLLADA and writes the .cdae, nothing is drawn and nothing stays in memory.
local function warmImport(idx, name)
  warm.current = name
  local started = os.clock()
  local cam = core_camera and core_camera.getPosition and core_camera.getPosition()
  local pos = cam and string.format("%.3f %.3f %.3f", cam.x, cam.y, cam.z - 800) or "0 0 -800"
  local ok = false
  local obj = createObject("TSStatic")
  if obj then
    pcall(function() obj.hidden = true end)
    pcall(obj.setField, obj, "shapeName", 0, name)
    pcall(obj.setField, obj, "position", 0, pos)
    pcall(obj.setField, obj, "collisionType", 0, "None")
    pcall(obj.setField, obj, "decalType", 0, "None")
    local okc, res = pcall(obj.registerObject, obj, "")
    ok = okc and res ~= false
    pcall(obj.delete, obj)
  end
  local ms = (os.clock() - started) * 1000
  if ok then
    warmMark(idx, true)
    warm.imported = warm.imported + 1
    warm.importMs = warm.importMs + ms
    if ms > warm.importMax then warm.importMax, warm.importMaxShape = ms, name end
    if TUNING.cacheWarmLogEvery > 0 and warm.imported % TUNING.cacheWarmLogEvery == 0 then
      logMsg("I", "cache warm: %d of %d shapes done (%d already had a .cdae, %d imported now, %d failed), import avg %.1f ms, max %.0f ms (%s)",
        warm.processed, warm.total, warm.hadCdae, warm.imported, warm.failed, warm.importMs / warm.imported,
        warm.importMax, shortShapeName(warm.importMaxShape or "?"))
    end
  else
    warmMark(idx, false)
    warm.failed = warm.failed + 1
    if warm.failed <= 10 then logMsg("W", "cache warm: %s could not be created", shortShapeName(name)) end
  end
  if ms >= TUNING.stallLogMs then logMsg("W", "slow cache warm import: %s %.0f ms", shortShapeName(name), ms) end
end

local function cacheWarmUpdate(dt)
  if not TUNING.cacheWarm or not warm.loaded or warm.finished or suspended or not initialized then return end
  if not M.isIdle() then warm.idle = 0; return end                -- the section streamer has work: it goes first
  warm.idle = warm.idle + dt
  if warm.idle < TUNING.cacheWarmIdleSeconds then return end
  if warm.gap > 0 then
    warm.gap = warm.gap - dt
    if warm.gap > 0 then return end
  end
  if warm.nearFor ~= currentSectionID then warmRefreshNear() end
  local imports, mark = 0, os.clock()
  while imports < math.max(1, TUNING.cacheWarmPerFrame) do
    local idx = warmNextCandidate()
    if not idx then
      warm.finished, warm.current = true, nil
      logMsg("I", "cache warm finished: %d shapes (%d already had a .cdae, %d imported now, %d failed, %d skipped), import avg %.1f ms",
        warm.total, warm.hadCdae, warm.imported, warm.failed, warm.skipped,
        warm.imported > 0 and warm.importMs / warm.imported or 0)
      return
    end
    local name = warm.names[idx]
    local cached
    if seenShapes[name] or shapeLive[name] then cached = true else cached = shapeCached(name) end
    if cached == nil then
      if fsUnavailable then
        warm.loaded = false
        logMsg("W", "cache warm is off: FS:fileExists is not available here")
        return
      end
      warmMark(idx, false)                                        -- not a .dae shape: nothing to cache
      warm.skipped = warm.skipped + 1
    elseif cached then
      warmMark(idx, true)
      warm.hadCdae = warm.hadCdae + 1
    else
      warmImport(idx, name)
      imports = imports + 1
      warm.gap = TUNING.cacheWarmGapSeconds
      mark = os.clock()
    end
    if (os.clock() - mark) * 1000 >= TUNING.cacheWarmCheckMs then break end   -- the time cap is for the skipping
  end
end

-- ---------------------------------------------------------------------------
-- State reset
-- ---------------------------------------------------------------------------
-- The pool, resting and dropped-section state. Its own function: LuaJIT allows 60 upvalues per function and
-- resetState is already near that.
local function resetPoolState()
  shellFree, shellFreeN, shellFields = {}, 0, {}
  shellChecked, shellDisabled, shellBuildFails, shellBuildOff = false, false, 0, false
  dormant, dormantOrder, doHead, doTail, dormantCount = {}, {}, 1, 0, 0
  droppedSections, droppedObjects, droppedLast = 0, 0, nil
  for k in pairs(shellStats) do shellStats[k] = 0 end
end

local function resetState()
  currentSectionID, activeSet = nil, {}
  sectionRead, sectionReading = {}, {}
  sectionReadQueue, srHead, srTail = {}, 1, 0
  loadQueue, lqHead, lqTail, queuedKeys = {}, 1, 0, {}
  priQueue, pqHead, pqTail, promotedTotal = {}, 1, 0, 0
  pending, pendingCount, deferred = {}, 0, {}
  staleDiscarded, queueHighWater, createdLastFrame, createdPeakFrame = 0, 0, 0, 0
  live, liveBySection, liveCount = {}, {}, 0
  pendingUnload, unloadQueue, uqHead, uqTail = {}, {}, 1, 0
  selectTimer = 1e9                                                -- look up at once after a reset
  camPos, camVel.x, camVel.y = nil, 0, 0
  cameraSectionID, predictedSectionID, aheadCandidate, aheadTime = nil, nil, nil, 0
  feedOrder, priorityTimer = {}, 0
  for k in pairs(timing) do timing[k] = 0 end
  seenShapes, shapeLive, recentFirstMs, idleFrameMs = {}, {}, nil, nil
  change, frameDeleteMs = newChange(), 0
  changeStamp, createdSinceChange, settled, settleSeconds, settlePeak = 0, 0, true, 0, 0
  resetPoolState()                                             -- the runtime group (and its shells) was deleted before this
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
  if readPresets().startup then M.loadPreset("startup") end
  local okShapes, errShapes = pcall(loadShapeList)
  if not okShapes then warm = newWarm(); logMsg("W", "shapes.json could not be read: %s", tostring(errShapes)) end
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
  logMsg("I", "creation mode: %s", mode)
  return true
end

function M.getCreationMode() return TUNING.creationMode end

-- Deletes every parked shell; returns how many.
function M.clearShellPool()
  local n = 0
  for i = shellFreeN, 1, -1 do
    local id = shellFree[i]
    local obj = scenetree.findObjectById(id)
    if obj then pcall(obj.delete, obj) end
    shellFields[id] = nil
    shellFree[i] = nil
    n = n + 1
  end
  shellFreeN = 0
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

function M.setSuspended(flag) suspended = flag and true or false end
function M.isSuspended() return suspended end

-- A copy of the current tuning values (for the console: dump(extensions.nfsc_sectionStreamer.getTuning())).
function M.getTuning()
  local copy = {}
  for k, v in pairs(TUNING) do copy[k] = v end
  return copy
end

function M.setTuning(values)
  for k, v in pairs(values or {}) do
    if TUNING[k] ~= nil then TUNING[k] = v end
  end
end

-- Live tuning ---------------------------------------------------------------------------------------------
local function presetPath() return levelRoot .. "/" .. PRESETS_JSON end

readPresets = function()
  local ok, data = pcall(jsonReadFile, presetPath())
  return (ok and type(data) == "table") and data or {}
end

local NOT_TUNABLE = { levelRoot = true, runtimeGroupName = true }

local function tunableValues()
  local out = {}
  for k, v in pairs(TUNING) do
    local t = type(v)
    if not NOT_TUNABLE[k] and (t == "number" or t == "boolean" or k == "creationMode" or k == "shellShape") then out[k] = v end
  end
  return out
end

function M.getDefaultTuning()
  local copy = {}
  for k, v in pairs(TUNING_DEFAULTS) do copy[k] = v end
  return copy
end

local function applyValues(values)
  local mode = nil
  for k, v in pairs(values or {}) do
    local want = TUNING_DEFAULTS[k]
    if want ~= nil and not NOT_TUNABLE[k] and type(v) == type(want) then
      if k == "creationMode" then mode = v else TUNING[k] = v end
    end
  end
  if mode and mode ~= TUNING.creationMode then M.setCreationMode(mode) end
end

function M.resetTuning()
  applyValues(TUNING_DEFAULTS)
  logMsg("I", "tuning reset to the defaults")
end

function M.listPresets()
  local names = {}
  for name in pairs(readPresets()) do names[#names + 1] = name end
  table.sort(names)
  return names
end

function M.savePreset(name)
  if type(name) ~= "string" or name == "" then return false, "no name" end
  local presets = readPresets()
  presets[name] = tunableValues()
  local ok, err = pcall(function() return jsonWriteFile(presetPath(), presets, true) end)
  if not ok then recordFailure("could not save preset " .. name .. ": " .. tostring(err)); return false, tostring(err) end
  logMsg("I", "preset saved: %s", name)
  return true
end

function M.loadPreset(name)
  local values = readPresets()[name]
  if type(values) ~= "table" then return false, "no such preset" end
  applyValues(values)
  logMsg("I", "preset loaded: %s", name)
  return true
end

function M.deletePreset(name)
  local presets = readPresets()
  if presets[name] == nil then return false, "no such preset" end
  presets[name] = nil
  local ok = pcall(function() return jsonWriteFile(presetPath(), presets, true) end)
  return ok
end

-- The current values as a Lua table, one line each, in the log (to paste back into TUNING).
function M.printTuning()
  local keys = {}
  for k in pairs(tunableValues()) do keys[#keys + 1] = k end
  table.sort(keys)
  logMsg("I", "TUNING values:")
  for _, k in ipairs(keys) do
    local v = TUNING[k]
    logMsg("I", "  %s = %s,", k, type(v) == "string" and string.format("%q", v) or tostring(v))
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

-- Least-squares slope of registerObject ms over the live object count, per 1000 objects (nil: too little spread).
local function registerSlopePer1000()
  local c = change
  if c.rn < 20 then return nil end
  local denom = c.rn * c.rxx - c.rx * c.rx
  if denom <= 0 or (c.liveMax - (c.liveMin or 0)) < 200 then return nil end
  return (c.rn * c.rxy - c.rx * c.ry) / denom * 1000
end

-- The shapes that cost the most since the last section change, by total create time.
local function topShapes(limit)
  local list = {}
  for name, c in pairs(change.shapes) do list[#list + 1] = { name = name, n = c.n, ms = c.ms, max = c.max, first = c.first, reload = c.reload } end
  table.sort(list, function(a, b) if a.ms ~= b.ms then return a.ms > b.ms end return a.name < b.name end)
  for i = #list, limit + 1, -1 do list[i] = nil end
  return list
end

-- Controlled measurement of what registerObject costs, run once from the console:
--   extensions.nfsc_sectionStreamer.probeRegister()                 (any live shape, 40 objects)
--   extensions.nfsc_sectionStreamer.probeRegister("<shapeName>", 80)
-- Creates `count` test TSStatics of one shape underground below the camera in four passes
-- (unnamed, named with the duplicate check timed on its own, unnamed again to expose order/warm-up
-- effects), logs the averages with the first and last quarter of each pass, and deletes them again.
-- It blocks the game for a moment (count x about 5 ms per pass).
local function runProbe(shapeName, count, auto)
  if not initialized then return nil, "the streamer is not initialized (is the level loaded?)" end
  count = math.max(4, math.min(tonumber(count) or 40, 200))
  if not shapeName then
    for _, entry in pairs(live) do
      if entry.shape then shapeName = entry.shape; break end
    end
  end
  if not shapeName then return nil, "no streamed object is live yet (stand in a loaded section, or pass a shapeName)" end
  local cam = core_camera and core_camera.getPosition and core_camera.getPosition()
  local pos = cam and string.format("%.3f %.3f %.3f", cam.x, cam.y, cam.z - 800) or "0 0 -800"
  local results = {}
  local function pass(label, named)
    local objs, regMs, lookupMs, failed = {}, {}, {}, 0
    for i = 1, count do
      local obj = createObject("TSStatic")
      if not obj then break end
      pcall(obj.setField, obj, "shapeName", 0, shapeName)
      pcall(obj.setField, obj, "position", 0, pos)
      pcall(obj.setField, obj, "collisionType", 0, "None")
      pcall(obj.setField, obj, "decalType", 0, "None")
      local name = ""
      if named then
        name = "nfsc_probe_" .. label .. "_" .. i
        local a = os.clock()
        scenetree.findObject(name)
        lookupMs[i] = (os.clock() - a) * 1000
      end
      local a = os.clock()
      local okc, res = pcall(obj.registerObject, obj, name)
      regMs[i] = (os.clock() - a) * 1000
      -- registered for real? refused (false), or not findable afterwards (by name, or by a non-zero id)
      local found = okc and res ~= false
      if found and named then found = scenetree.findObject(name) ~= nil end
      if found and not named then
        local idOk, id = pcall(obj.getID, obj)
        found = idOk and id ~= nil and id ~= 0
      end
      if not found then failed = failed + 1 end
      objs[i] = obj
    end
    local d0 = os.clock()
    for i = 1, #objs do pcall(objs[i].delete, objs[i]) end
    local deleteMs = (os.clock() - d0) * 1000
    local function avg(list, from, to)
      local sum, n = 0, 0
      for i = from, to do if list[i] then sum, n = sum + list[i], n + 1 end end
      return n > 0 and sum / n or 0
    end
    local n, q = #regMs, math.max(1, math.floor(#regMs / 4))
    local r = { label = label, n = n, register = avg(regMs, 1, n), first = avg(regMs, 1, q), last = avg(regMs, n - q + 1, n),
                lookup = named and avg(lookupMs, 1, n) or 0, delete = n > 0 and deleteMs / n or 0, failed = failed }
    results[#results + 1] = r
    local short = shapeName:match("([^/\\]+)$") or shapeName
    logMsg("I", "probe %s: %d x %s: registerObject avg %.2f ms (first quarter %.2f, last quarter %.2f), name lookup %.3f ms, delete %.2f ms each%s",
      label, r.n, short, r.register, r.first, r.last, r.lookup, r.delete,
      failed > 0 and string.format(" -- %d of %d registers FAILED, timing not valid", failed, n) or "")
  end

  -- the same shape as a real streamed object: its real fields and position, created through the normal
  -- create path (which also adds it to the runtime group), under probe names, deleted again
  local function realPass()
    local item
    for _, entry in pairs(live) do
      if entry.item and entry.shape == shapeName then item = entry.item; break end
    end
    if not item then return end
    local objs, totalMs, regMs, failed = {}, 0, 0, 0
    for i = 1, count do
      local a = os.clock()
      local obj = createStreamedObject(item, "nfsc_probe_real_" .. i)
      totalMs = totalMs + (os.clock() - a) * 1000
      if obj then
        objs[#objs + 1] = obj
        regMs = regMs + split.registerMs
      else
        failed = failed + 1
      end
    end
    for i = 1, #objs do pcall(objs[i].delete, objs[i]) end
    local n = math.max(1, #objs)
    local r = { label = "real", n = #objs, register = regMs / n, total = totalMs / math.max(1, count), failed = failed }
    results[#results + 1] = r
    local short = shapeName:match("([^/\\\\]+)$") or shapeName
    logMsg("I", "probe real: %d x %s with its real fields and position: create avg %.2f ms (registerObject %.2f ms)%s",
      r.n, short, r.total, r.register,
      failed > 0 and string.format(" -- %d of %d FAILED", failed, count) or "")
  end
  if auto then
    pass("named", true)
    pass("unnamed", false)
    realPass()
  else
    pass("unnamed", false)
    pass("named", true)
    pass("unnamed2", false)
    realPass()
  end
  return results
end

-- Always says something in the log: the reason it could not run, or the Lua error it hit.
function M.probeRegister(shapeName, count)
  logMsg("I", "probeRegister called (shape %s, count %s)", tostring(shapeName or "any live shape"), tostring(count or "default"))
  local ok, results, err = pcall(runProbe, shapeName, count)
  if not ok then
    logMsg("E", "probeRegister failed: %s", tostring(results))
    return nil, tostring(results)
  end
  if not results then logMsg("W", "probeRegister did not run: %s", tostring(err)) end
  return results, err
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
    queuedObjectCount = (lqTail - lqHead + 1) + (pqTail - pqHead + 1),
    queuedUrgentCount = pqTail - pqHead + 1, promotedObjectCount = promotedTotal,
    queuedSectionReads = srTail - srHead + 1,
    pendingRecordCount = pendingCount,
    deferredCount = (function()
      local n = 0
      for _, list in pairs(deferred) do n = n + #list end
      return n
    end)(),
    staleDiscarded = staleDiscarded,
    queueHighWater = queueHighWater,
    createdLastFrame = createdLastFrame, createdPeakFrame = createdPeakFrame,
    cameraSectionID = cameraSectionID, predictedSectionID = predictedSectionID,
    cameraSpeed = math.sqrt(camVel.x * camVel.x + camVel.y * camVel.y),
    createdSinceChange = createdSinceChange,
    settleSeconds = settleSeconds, settlePeakSeconds = settlePeak,
    avgCreateMs = timing.creates > 0 and timing.createMs / timing.creates or 0, maxCreateMs = timing.createMax,
    firstUseCreates = timing.firsts, firstUseAvgMs = timing.firsts > 0 and timing.firstMs / timing.firsts or 0,
    repeatCreates = timing.repeats, repeatAvgMs = timing.repeats > 0 and timing.repeatMs / timing.repeats or 0,
    avgReadMs = timing.reads > 0 and timing.readMs / timing.reads or 0, maxReadMs = timing.readMax,
    loadFrameLastMs = timing.frameLast, loadFramePeakMs = timing.framePeak,
    changeCreates = change.creates, changeCreateMs = change.createMs, changeFrames = change.frames,
    changeFps = change.dtSum > 0 and change.frames / change.dtSum or 0, changeWorstFrameMs = change.dtMax * 1000,
    changeWorkPeakMs = change.workMax,
    changeFirstUseSplit = { import = { n = change.importN, ms = change.importMs }, cached = { n = change.hitN, ms = change.hitMs },
                            unknown = { n = change.unkN, ms = change.unkMs } },
    cacheWarm = M.getCacheWarmStatus(),
    changeDeferredFirstUse = change.deferredFirst,
    changeFirstUse = change.firsts, changeReload = change.reloads, changeWarm = change.warms,
    changeReloadAvgMs = change.reloads > 0 and change.reloadMs / change.reloads or 0,
    changeWarmAvgMs = change.warms > 0 and change.warmMs / change.warms or 0,
    changeTopShapes = topShapes(5),
    changeWarmByDistance = { c1 = change.dist[1], c2 = change.dist[2], c3 = change.dist[3] }, expectedFirstUseMs = expectedFirstMs(), idleFrameMs = idleFrameMs,
    changeNameAvgMs = change.creates > 0 and change.nameMs / change.creates or 0, changeRegisterSlopePer1000 = registerSlopePer1000(),
    changeSplitMs = { createObject = change.objectMs, setField = change.fieldsMs,
                      registerObject = change.registerMs, groupAdd = change.groupMs },
    pendingUnloadCount = pending,
    createdTotal = createdTotal, deletedTotal = deletedTotal,
    failureCount = failureCount,
    forceCollisionNone = TUNING.forceCollisionNone,
    creationMode = TUNING.creationMode, shellPoolActive = (TUNING.creationMode == "shells" or TUNING.creationMode == "resident") and not shellDisabled,
    shellsFree = shellFreeN, shellsBuilt = shellStats.built, shellTarget = TUNING.shellTarget,
    shellsRecycled = shellStats.recycled, shellsFresh = shellStats.fresh, shellsParked = shellStats.parked,
    shellRecycleAvgMs = shellStats.recycled > 0 and shellStats.recycleMs / shellStats.recycled or 0,
    shellParkAvgMs = shellStats.parked > 0 and shellStats.parkMs / shellStats.parked or 0,
    shellBuildMs = shellStats.buildMs, shellPeakLive = shellStats.peakLive,
    residentActive = TUNING.creationMode == "resident" and not shellDisabled,
    residentDormant = dormantCount, residentRevived = shellStats.revived, residentDeactivated = shellStats.deactivated,
    residentEvicted = shellStats.evicted, residentMax = TUNING.residentMax, residentReserve = TUNING.residentReserve,
    residentReviveAvgMs = shellStats.revived > 0 and shellStats.reviveMs / shellStats.revived or 0,
    poolTotal = poolTotal(),
    droppedSections = droppedSections, droppedObjects = droppedObjects, droppedLast = droppedLast,
    changeResident = { revived = change.residentRevives, reviveMs = change.residentReviveMs,
                       deactivated = change.residentDeacts, evicted = change.residentEvicts },
    changeShells = { recycled = change.shellRecycles, recycleMs = change.shellRecycleMs, fresh = change.shellFresh,
                     parked = change.shellParks, parkMs = change.shellParkMs },
  }
end

function M.getFailures() return failures end

-- Sections in loading order (current first); a copy.
function M.getLoadOrder()
  local out = {}
  for i = 1, #feedOrder do out[i] = feedOrder[i] end
  return out
end

-- true when no section file and no object is waiting to be created (cheap, per-frame safe)
function M.isIdle() return lqHead > lqTail and pqHead > pqTail and srHead > srTail and pendingCount <= 0 end

-- Progress of the shape cache warm-up, for a console check or a progress display.
function M.getCacheWarmStatus()
  local imported = warm.imported
  return {
    enabled = TUNING.cacheWarm, available = warm.loaded, finished = warm.finished,
    running = TUNING.cacheWarm and warm.loaded and not warm.finished and not suspended and M.isIdle()
      and warm.idle >= TUNING.cacheWarmIdleSeconds,
    total = warm.total, processed = warm.processed, remaining = warm.total - warm.processed,
    alreadyCached = warm.hadCdae, imported = imported, failed = warm.failed, skipped = warm.skipped,
    importAvgMs = imported > 0 and warm.importMs / imported or 0, importMaxMs = warm.importMax,
    importMaxShape = warm.importMaxShape, current = warm.current,
    nearQueued = math.max(0, #warm.near - warm.nearPos + 1),
  }
end

function M.setCacheWarm(flag) TUNING.cacheWarm = flag and true or false end

-- Forgets what the lane has checked (after .cdae files were deleted, say) and starts over.
function M.restartCacheWarm()
  local names, bySection, total = warm.names, warm.bySection, warm.total
  warm = newWarm()
  warm.names, warm.bySection, warm.total, warm.loaded = names, bySection, total, total > 0
end

-- Builds parked shells ahead (TUNING.shellTarget) while nothing urgent is queued: a little per frame, never in a burst.
local function shellBuildUpdate()
  if shellBuildOff or TUNING.shellTarget <= 0 or pqHead <= pqTail or not shellMode() then return end
  local started = os.clock()
  local n = 0
  while n < TUNING.shellBuildPerFrame and poolTotal() < TUNING.shellTarget do
    local ok, err = buildShell()
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
    if (os.clock() - started) * 1000 >= TUNING.shellBuildBudgetMs then break end
  end
  shellStats.buildMs = shellStats.buildMs + (os.clock() - started) * 1000
end

-- Resident mode, idle frames only: keep residentReserve shells free and the pool at residentMax by evicting the oldest.
local function residentTrim()
  if not residentMode() or pqHead <= pqTail or dormantCount == 0 then return end
  local total = poolTotal()
  local over = total - TUNING.residentMax
  local short = TUNING.residentReserve - shellFreeN
  if over <= 0 and not (short > 0 and total >= TUNING.residentMax) then return end
  evictOldest(math.min(dormantCount, 8, math.max(over, short, 1)))
end

function M.onUpdate(dtReal)
  if not initialized or suspended then return end
  totalTime = totalTime + (dtReal or 0)
  updateCamera(dtReal or 0)
  priorityTimer = priorityTimer + (dtReal or 0)
  if priorityTimer >= TUNING.priorityRefreshInterval then
    priorityTimer = 0
    rebuildFeedOrder()
  end
  if settled and M.isIdle() then
    local dt = dtReal or 0
    if dt > 0 and dt < 0.5 then idleFrameMs = idleFrameMs and (idleFrameMs * 0.98 + dt * 1000 * 0.02) or dt * 1000 end
  end
  local frameStarted = os.clock()
  processSectionReads()
  feedQueue()
  processUnloads()                                   -- deletes first, within their share of the frame budget
  processLoads()                                     -- creates use what is left of it
  shellBuildUpdate()                                 -- shell pool: build parked shells ahead, only while nothing urgent waits
  residentTrim()
  if not settled then
    local workMs = (os.clock() - frameStarted) * 1000
    change.frames = change.frames + 1
    change.workMs = change.workMs + workMs
    if workMs > change.workMax then change.workMax = workMs end
    local dt = dtReal or 0
    change.dtSum = change.dtSum + dt
    if dt > change.dtMax then change.dtMax = dt end
  end
  cacheWarmUpdate(dtReal or 0)                       -- idle lane: only while nothing is queued
  if not settled and M.isIdle() then
    settled = true
    settleSeconds = totalTime - changeStamp
    if settleSeconds > settlePeak then settlePeak = settleSeconds end
    if TUNING.logSettle and (createdSinceChange > 0 or TUNING.logEmptySettles) then
      local c = change
      logMsg("I", "section %s settled: %d objects in %.2f s (%.0f/s), %d frames, %.1f fps (worst frame %.0f ms), streaming %.1f ms/frame (peak %.0f ms)",
        tostring(currentSectionID), createdSinceChange, settleSeconds,
        settleSeconds > 0 and createdSinceChange / settleSeconds or 0,
        c.frames, c.dtSum > 0 and c.frames / c.dtSum or 0, c.dtMax * 1000, c.frames > 0 and c.workMs / c.frames or 0, c.workMax)
      if c.creates > 0 then
        logMsg("I", "  creates: %.0f ms total, avg %.2f ms, max %.1f ms; first use %d x %.2f ms, reload %d x %.2f ms, warm %d x %.2f ms, new shapes deferred %d times",
          c.createMs, c.createMs / c.creates, c.maxMs,
          c.firsts, c.firsts > 0 and c.firstMs / c.firsts or 0,
          c.reloads, c.reloads > 0 and c.reloadMs / c.reloads or 0,
          c.warms, c.warms > 0 and c.warmMs / c.warms or 0, c.deferredFirst)
        if c.firsts > 0 then
          logMsg("I", "  first use split: import (no .cdae yet) %d x %.2f ms, cached (.cdae existed) %d x %.2f ms, unknown %d x %.2f ms",
            c.importN, c.importN > 0 and c.importMs / c.importN or 0, c.hitN, c.hitN > 0 and c.hitMs / c.hitN or 0,
            c.unkN, c.unkN > 0 and c.unkMs / c.unkN or 0)
        end
        local top = topShapes(5)
        for i = 1, #top do
          local t = top[i]
          logMsg("I", "  top %d: %s %d x, %.0f ms total, avg %.2f, max %.1f ms (first %d, reload %d)",
            i, shortShapeName(t.name), t.n, t.ms, t.ms / t.n, t.max, t.first, t.reload)
        end
        local slope = registerSlopePer1000()
        logMsg("I", "  per create: createObject %.2f, setField %.2f, name %.2f, registerObject %.2f, group add %.2f ms; deleted %d in %.0f ms; section read max %.1f ms",
          c.objectMs / c.creates, c.fieldsMs / c.creates, c.nameMs / c.creates, c.registerMs / c.creates, c.groupMs / c.creates,
          c.deleted, c.deleteMs, timing.readMax)
        if TUNING.creationMode == "resident" then
          logMsg("I", "  resident: revived %d x %.3f ms, deactivated %d, evicted %d; dormant %d, free %d, pool %d of %d",
            c.residentRevives, c.residentRevives > 0 and c.residentReviveMs / c.residentRevives or 0, c.residentDeacts,
            c.residentEvicts, dormantCount, shellFreeN, poolTotal(), TUNING.residentMax)
        end
        if TUNING.creationMode ~= "current" then
          logMsg("I", "  shells: recycled %d x %.3f ms, fresh %d, parked %d x %.3f ms; free %d, peak live %d, built ahead %d",
            c.shellRecycles, c.shellRecycles > 0 and c.shellRecycleMs / c.shellRecycles or 0, c.shellFresh,
            c.shellParks, c.shellParks > 0 and c.shellParkMs / c.shellParks or 0, shellFreeN, shellStats.peakLive, shellStats.built)
        end
        logMsg("I", "  scene: live objects %d to %d (avg %.0f) while creating, registerObject trend %s, idle frame %s",
          c.liveMin or 0, c.liveMax, c.liveSum / c.creates,
          slope and string.format("%+.2f ms per 1000 live", slope) or "n/a (live count barely changed)",
          idleFrameMs and string.format("%.1f ms (%.0f fps)", idleFrameMs, 1000 / idleFrameMs) or "n/a")
        local mgr = rawget(_G, "nfsc_sectionManager")
        local okState, lightsOn, emittersOn = false, nil, nil
        if mgr and mgr.getSceneClassState then okState, lightsOn, emittersOn = pcall(mgr.getSceneClassState) end
        local function onOff(v) if not okState or v == nil then return "n/a" end return v and "on" or "off" end
        local function bucket(b) return string.format("%d x %.2f ms", b.n, b.n > 0 and b.ms / b.n or 0) end
        logMsg("I", "  warm creates by horizontal distance to the camera: under 100 m %s, 100-300 m %s, over 300 m %s; lights %s, emitters %s",
          bucket(c.dist[1]), bucket(c.dist[2]), bucket(c.dist[3]), onOff(lightsOn), onOff(emittersOn))
        if TUNING.probeOnSettle then
          -- the shape with the most creates in this change: its real average sits next to the probe
          local bestName, best = nil, nil
          for name, cost in pairs(c.shapes) do
            if not best or cost.n > best.n or (cost.n == best.n and name < bestName) then bestName, best = name, cost end
          end
          if bestName then
            local ok, results, why = pcall(runProbe, bestName, TUNING.probeCount, true)
            if not ok then
              logMsg("E", "probe after settle failed: %s", tostring(results))
            elseif not results then
              logMsg("W", "probe after settle did not run: %s", tostring(why))
            else
              local byLabel = {}
              for _, r in ipairs(results) do byLabel[r.label] = r end
              local function ms(r) return r and string.format("%.2f ms%s", r.register, (r.failed or 0) > 0 and " (FAILED)" or "") or "n/a" end
              logMsg("I", "  probe vs real: %s real avg %.2f ms over %d creates in this change (warm avg %.2f ms); probe named %s, unnamed %s, real fields %s",
                shortShapeName(bestName), best.ms / best.n, best.n, c.warms > 0 and c.warmMs / c.warms or 0,
                ms(byLabel.named), ms(byLabel.unnamed), ms(byLabel.real))
            end
          end
        end
      end
    end
  end
end

function M.onExtensionUnloaded()
  notify("onStreamerReset")
  destroyRuntimeGroup()
  resetState()
  initialized = false
end

return M
