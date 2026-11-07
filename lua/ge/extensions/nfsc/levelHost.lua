-- nfsc_levelHost: the level's component host.
--
-- The level holds only mainLevel.lua and its data; every piece of level code lives under
-- lua/ge/extensions/nfsc. The section streamer and manager stay core and independent of this file. The host
-- sits beside them and runs the level components (components/*.lua) through one fixed interface:
--
--   component.init(ctx)                    -- once; ctx is shared by all components (see below)
--   component.onSectionChanged(new, old)   -- optional; the streamer's onNfscSectionChanged hook, forwarded
--   component.onObjectCreated(key, obj, item), onObjectDeleted(key), onStreamerReset()
--                                          -- optional; the streamer's object events (the host is the one listener)
--   component.onUpdate(dtReal, dtSim)      -- optional; every frame
--   component.getStatus()                  -- optional; a table for the panel
--   component.describeZone(zoneId)         -- optional; short text about what the component does for a zone
--   component.serialize() / restore(data)  -- optional; state that survives an engine Lua reload
--   component.shutdown()                   -- once; undo everything the component created
--
-- ctx = { levelRoot, zOffset, zones (the zone list of lua/zones.json, read once), zonesPath,
--         util = { zonePolygon }, configPath(name) }
--
-- The host also knows which zones (of every type in zones.json) the camera is in: getCurrentZones() and
-- describeCurrentZones() feed the Section Manager panel.
--
-- Config: optional lua/components/host.json { "zOffset": 150 }. Each component reads its own file in
-- lua/components/ (ctx.configPath("soundZones") -> levels/nfsc/lua/components/soundZones.json).
--
-- Components are loaded with loadfile from the game folder, not registered as engine extensions, so the
-- engine does not call their onUpdate itself and the host decides the order.

local M = {}
M.dependencies = { "nfsc_sectionStreamer" }

-- ---------------------------------------------------------------------------
-- Tuning
-- ---------------------------------------------------------------------------
local TUNING = {
  levelRoot = "levels/nfsc",
  zonesFile = "lua/zones.json",
  configDir = "lua/components",
  componentDir = "/lua/ge/extensions/nfsc/components",
  zOffset = 150,                -- height every object of the level is raised by (game limitation); shared by all components
  locateInterval = 0.2,         -- seconds between two zone lookups of the camera
  debugLog = false,
}

-- Components in load order. Add a name here and a file components/<name>.lua.
local COMPONENTS = { "soundZones", "volumeScatter", "roughness", "sway", "textureAnimation" }

-- TrackPathZone enum, used when a zone has no typeName.
local TYPE_NAMES = {
  [0] = "RESET", "RESET_TO_POINT", "GUIDED_RESET", "TUNNEL", "OVERPASS", "OVERPASS_SMALL", "STREAMER_PREDICTION",
  "GARAGE", "HIDDEN", "TRAFFIC_PATTERN", "DYNAMIC", "NEIGHBOURHOOD", "JUMP_CAM", "NO_COP_SPAWN", "PURSUIT_START",
  "HIGHWAY", "CANYON_DROP", "VERTIGO_CAMERA",
}

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
local ctx = nil
local components = {}               -- { name, mod, ok, err, failed } in load order
local records = {}                  -- one per usable zone: id, typeName, poly, bounds, elevation
local zonesState = { loaded = false, source = nil, count = 0, usable = 0, error = nil }
local located = { list = {}, x = nil, y = nil, z = nil, inside = false }
local locateTimer = 0
local warned = {}
local listener = {}                 -- registered on the streamer; forwards the object events to the components
local pendingState = nil            -- serialized component state from before a Lua reload, applied by initialize

local function logMsg(level, fmt, ...)
  if level == "D" and not TUNING.debugLog then return end
  local text = select("#", ...) > 0 and string.format(fmt, ...) or fmt
  if log then log(level, "nfscLevelHost", text) end
end

local function warnOnce(key, fmt, ...)
  if warned[key] then return end
  warned[key] = true
  logMsg("W", fmt, ...)
end

-- ---------------------------------------------------------------------------
-- Zones (plain {x, y} points)
-- ---------------------------------------------------------------------------
local function xyOf(pt)
  if type(pt) ~= "table" then return nil end
  local x, y = tonumber(pt[1] or pt.x), tonumber(pt[2] or pt.y)
  if x and y then return x, y end
  return nil
end

local function zonePolygon(zone)
  local poly = {}
  for _, pt in ipairs(zone.points or {}) do
    local x, y = xyOf(pt)
    if x then poly[#poly + 1] = { x = x, y = y } end
  end
  if #poly >= 3 then return poly end
  local x0, y0 = xyOf(zone.boundsMin)                           -- no usable points: the zone's own bounds
  local x1, y1 = xyOf(zone.boundsMax)
  if x0 and x1 then
    return { { x = x0, y = y0 }, { x = x1, y = y0 }, { x = x1, y = y1 }, { x = x0, y = y1 } }
  end
  return nil
end

-- The zone list: the file itself when it is an array, its "zones" field, else the first field that holds an
-- array of zone-looking tables (a record with type / typeName / points).
local function zoneList(data)
  if type(data) ~= "table" then return nil, nil end
  if type(data[1]) == "table" then return data, "(array)" end
  if type(data.zones) == "table" then return data.zones, "zones" end
  for key, value in pairs(data) do
    if type(value) == "table" and type(value[1]) == "table"
       and (value[1].type ~= nil or value[1].typeName ~= nil or value[1].points ~= nil) then
      return value, tostring(key)
    end
  end
  return nil, nil
end

local function typeNameOf(zone)
  if type(zone.typeName) == "string" and zone.typeName ~= "" then return zone.typeName:upper() end
  local byType = TYPE_NAMES[tonumber(zone.type)]
  if byType then return byType end
  return "TYPE_" .. tostring(zone.type)
end

local function buildRecord(zone, index)
  local poly = zonePolygon(zone)
  if not poly then return nil end
  local minx, miny, maxx, maxy = math.huge, math.huge, -math.huge, -math.huge
  for i = 1, #poly do
    local p = poly[i]
    if p.x < minx then minx = p.x end
    if p.x > maxx then maxx = p.x end
    if p.y < miny then miny = p.y end
    if p.y > maxy then maxy = p.y end
  end
  return { id = tostring(zone.id or index), typeName = typeNameOf(zone), poly = poly,
           minx = minx, miny = miny, maxx = maxx, maxy = maxy, elevation = tonumber(zone.elevation) or 0 }
end

local function insidePoly(poly, x, y)                           -- even-odd ray casting
  local inside = false
  local j = #poly
  for i = 1, #poly do
    local a, b = poly[i], poly[j]
    if (a.y > y) ~= (b.y > y) and x < (b.x - a.x) * (y - a.y) / (b.y - a.y) + a.x then inside = not inside end
    j = i
  end
  return inside
end

-- The elevation gate of the game: 0 = always, > 0 = only when z >= elevation, < 0 = only when z <= |elevation|.
-- z is in the game's own units, so the level's height offset comes off first.
local function gateOpen(elevation, zGame)
  if elevation > 0 then return zGame >= elevation end
  if elevation < 0 then return zGame <= -elevation end
  return true
end

local function loadZones()
  records = {}
  zonesState = { loaded = false, source = TUNING.levelRoot .. "/" .. TUNING.zonesFile, count = 0, usable = 0, error = nil }
  local data = jsonReadFile(zonesState.source)
  if type(data) ~= "table" then
    zonesState.error = "could not read " .. zonesState.source
    logMsg("W", "%s (missing or not valid JSON); no zones loaded", zonesState.error)
    return nil
  end
  local list, listKey = zoneList(data)
  if not list then
    zonesState.error = "no zone list in " .. zonesState.source
    logMsg("W", "%s; no zones loaded", zonesState.error)
    return nil
  end
  zonesState.loaded, zonesState.count = true, #list
  for i, zone in ipairs(list) do
    if type(zone) == "table" then
      local rec = buildRecord(zone, i)
      if rec then records[#records + 1] = rec end
    end
  end
  zonesState.usable = #records
  logMsg("I", "read %d zones from %s (list: %s), %d with a usable polygon", #list, zonesState.source, listKey, #records)
  return list
end

-- ---------------------------------------------------------------------------
-- Components
-- ---------------------------------------------------------------------------
local function callComponent(comp, fn, ...)
  local f = comp.mod and comp.mod[fn]
  if type(f) ~= "function" then return true end
  local ok, res = pcall(f, ...)
  if not ok then
    comp.failed = true
    warnOnce(comp.name .. ":" .. fn, "component %s: %s failed: %s", comp.name, fn, tostring(res))
    return false
  end
  return true, res
end

-- Events from the streamer: a failing handler is logged once but never switches the component off.
local function forward(method, ...)
  for i = 1, #components do
    local comp = components[i]
    local f = comp.ok and not comp.failed and comp.mod[method]
    if type(f) == "function" then
      local ok, err = pcall(f, ...)
      if not ok then warnOnce(comp.name .. ":" .. method, "component %s: %s failed: %s", comp.name, method, tostring(err)) end
    end
  end
end

function listener:onObjectCreated(key, obj, item) forward("onObjectCreated", key, obj, item) end
function listener:onObjectDeleted(key) forward("onObjectDeleted", key) end
function listener:onStreamerReset() forward("onStreamerReset") end

local function loadComponent(name)
  local comp = { name = name, mod = nil, ok = false, err = nil, failed = false }
  local path = TUNING.componentDir .. "/" .. name .. ".lua"
  local chunk, err = loadfile(path)
  if not chunk then comp.err = "could not load " .. path .. ": " .. tostring(err); return comp end
  local ok, mod = pcall(chunk)
  if not ok or type(mod) ~= "table" then comp.err = "component did not return a table: " .. tostring(mod); return comp end
  comp.mod = mod
  local initOk, res = callComponent(comp, "init", ctx)
  if initOk then
    comp.ok = true
  else
    comp.err = "init failed"
  end
  return comp
end

local function shutdownComponents()
  for i = #components, 1, -1 do
    local comp = components[i]
    if comp.mod then callComponent(comp, "shutdown") end
  end
  components = {}
end

-- ---------------------------------------------------------------------------
-- Zone lookup of the camera
-- ---------------------------------------------------------------------------
local function describeZone(rec)
  for i = 1, #components do
    local comp = components[i]
    if comp.ok and not comp.failed and comp.mod.describeZone then
      local ok, res = pcall(comp.mod.describeZone, rec.id)
      if ok and type(res) == "string" and res ~= "" then return res end
    end
  end
  return nil
end

local function locate(x, y, z)
  local list = {}
  local zGame = z - TUNING.zOffset
  for i = 1, #records do
    local rec = records[i]
    if x >= rec.minx and x <= rec.maxx and y >= rec.miny and y <= rec.maxy
       and gateOpen(rec.elevation, zGame) and insidePoly(rec.poly, x, y) then
      list[#list + 1] = { id = rec.id, typeName = rec.typeName, info = describeZone(rec) }
    end
  end
  located = { list = list, x = x, y = y, z = z, inside = #list > 0 }
end

local function updateLocator(dt)
  locateTimer = locateTimer + dt
  if locateTimer < TUNING.locateInterval then return end
  locateTimer = 0
  if #records == 0 then return end
  local cam = core_camera and core_camera.getPosition and core_camera.getPosition()
  if not cam then return end
  locate(cam.x, cam.y, cam.z)
end

-- The zones the camera is in: an array of { id, typeName, info }, empty outside every zone.
function M.getCurrentZones() return located.list end

function M.describeCurrentZones()
  if #records == 0 then return zonesState.error and "zones not loaded" or "none" end
  if #located.list == 0 then return "none" end
  local parts = {}
  for i = 1, #located.list do
    local z = located.list[i]
    parts[i] = string.format("%s #%s%s", z.typeName, z.id, z.info and (" (" .. z.info .. ")") or "")
  end
  return table.concat(parts, ", ")
end

-- ---------------------------------------------------------------------------
-- Section events and frame
-- ---------------------------------------------------------------------------
-- Called by the streamer's hook (extensions.hook), nothing is registered on the streamer.
function M.onNfscSectionChanged(newID, oldID)
  for i = 1, #components do
    local comp = components[i]
    if comp.ok and not comp.failed then callComponent(comp, "onSectionChanged", newID, oldID) end
  end
end

function M.onUpdate(dtReal, dtSim)
  dtReal = dtReal or 0.016
  local ok, err = pcall(updateLocator, dtReal)
  if not ok then warnOnce("locator", "zone lookup failed: %s", tostring(err)) end
  for i = 1, #components do
    local comp = components[i]
    if comp.ok and not comp.failed then callComponent(comp, "onUpdate", dtReal, dtSim or dtReal) end
  end
end

-- ---------------------------------------------------------------------------
-- Status, lifecycle
-- ---------------------------------------------------------------------------
function M.getComponent(name)
  for i = 1, #components do
    if components[i].name == name then return components[i].mod end
  end
  return nil
end

function M.getStatus()
  local comps = {}
  for i = 1, #components do
    local comp = components[i]
    local status = nil
    if comp.ok and comp.mod.getStatus then
      local ok, res = pcall(comp.mod.getStatus)
      if ok then status = res end
    end
    comps[#comps + 1] = { name = comp.name, ok = comp.ok and not comp.failed, err = comp.err, status = status }
  end
  return { zOffset = TUNING.zOffset, zones = zonesState, components = comps, currentZones = located.list }
end

function M.setDebugLog(flag) TUNING.debugLog = flag and true or false end
function M.getDebugLog() return TUNING.debugLog end

function M.initialize(basePath)
  shutdownComponents()
  warned, located, locateTimer = {}, { list = {}, inside = false }, 0
  TUNING.levelRoot = ((basePath or TUNING.levelRoot):gsub("/+$", ""))
  local cfg = jsonReadFile(TUNING.levelRoot .. "/" .. TUNING.configDir .. "/host.json")
  if type(cfg) == "table" and tonumber(cfg.zOffset) then TUNING.zOffset = tonumber(cfg.zOffset) end

  local list = loadZones()
  ctx = {
    levelRoot = TUNING.levelRoot,
    zOffset = TUNING.zOffset,
    zones = list,
    zonesPath = zonesState.source,
    util = { zonePolygon = zonePolygon },
    configPath = function(name) return TUNING.levelRoot .. "/" .. TUNING.configDir .. "/" .. name .. ".json" end,
  }
  for _, name in ipairs(COMPONENTS) do
    local comp = loadComponent(name)
    components[#components + 1] = comp
    if comp.ok then logMsg("I", "component %s ready", name) else logMsg("W", "component %s not available: %s", name, tostring(comp.err)) end
  end
  if pendingState then                                          -- a Lua reload happened: the components pick their state up again
    for i = 1, #components do
      local comp = components[i]
      if comp.ok and pendingState[comp.name] ~= nil then callComponent(comp, "restore", pendingState[comp.name]) end
    end
    pendingState = nil
  end
end

-- The runtime state survives a Lua reload; the components that have something to keep return it from serialize().
function M.onSerialize()
  local data = {}
  for i = 1, #components do
    local comp = components[i]
    if comp.ok and not comp.failed and type(comp.mod.serialize) == "function" then
      local ok, res = pcall(comp.mod.serialize)
      if ok and res ~= nil then data[comp.name] = res end
    end
  end
  return data
end

function M.onDeserialized(data)
  if type(data) == "table" then pendingState = data end
end

function M.onExtensionLoaded()
  if nfsc_sectionStreamer and nfsc_sectionStreamer.addListener then nfsc_sectionStreamer.addListener(listener) end
end

function M.onExtensionUnloaded()
  if nfsc_sectionStreamer and nfsc_sectionStreamer.removeListener then nfsc_sectionStreamer.removeListener(listener) end
  shutdownComponents()
  records, ctx = {}, nil
  located = { list = {}, inside = false }
end

return M
