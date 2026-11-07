-- nfsc_soundZones: ambience (reverb) spaces built at level load from the TrackPathZones in lua/zones.json.
--
-- zones.json sits next to sections.json (levels/nfsc/lua/) and is the blanket export of every zone. This
-- extension reads only the zones whose type has a sound role and turns each one into one or more SFXSpace
-- boxes carrying that role's SFXAmbience. The engine does the enter / exit detection, so nothing runs per
-- frame: there is no onUpdate.
--
--   role (zone type)      ambience
--   TUNNEL                Level_Tunnel_Closed
--   OVERPASS              Level_Under_Bridge
--   OVERPASS_SMALL        Level_Under_Bridge_A
--   GARAGE                Level_Parking_House
--
-- A zone is a 2D polygon (zone points, same plane as the section polygons), an SFXSpace is a box. Each polygon
-- is fitted with its smallest oriented rectangle; when that rectangle is mostly empty the polygon is cut across
-- its long axis and each half is fitted again, until the boxes fill the polygon well enough, the pieces are
-- short, or the per-zone box cap is reached. The zone's elevation gate (elevation > 0: only at z >= elevation,
-- elevation < 0: only at z <= |elevation|) narrows the vertical range; the zone has no height of its own, so
-- the box height is zMin..zMax from TUNING unless the gate narrows it. Those heights are in the game's own
-- units; every object of the level sits zOffset (150) higher than in the game, so the finished range is
-- shifted up by zOffset (x and y are not offset).
--
-- Optional lua/sound_zones.json changes the mapping without touching this file:
--   { "roles": { "TUNNEL": "Level_Tunnel_Open" }, "zones": { "145": "Level_Tunnel_Open", "146": false }, "zOffset": 150 }
-- "roles" replaces a role's ambience (false switches the role off), "zones" replaces one zone's ambience by
-- the zone id of zones.json (false switches that zone off); "zOffset" replaces the height offset.
--
-- Interface: initialize(basePath), rebuild(), getStatus(). Unloading the extension deletes the spaces.
--
-- Flagged for in-engine verification (nothing here has run in BeamNG): createObject("SFXSpace") with the
-- fields soundAmbience, position, rotationMatrix (row-major 3x3) and scale set through setField, and that the
-- named ambience datablocks are found by name. Every engine call is wrapped in pcall; a failure is counted
-- and logged once, never thrown.

local M = {}

-- ---------------------------------------------------------------------------
-- Tuning
-- ---------------------------------------------------------------------------
local TUNING = {
  levelRoot = "levels/nfsc",
  zonesFile = "lua/zones.json",
  overridesFile = "lua/sound_zones.json",
  groupName = "nfsc_sound_zones",
  zOffset = 150,                -- height every object of the level is raised by (game limitation); added to all box heights
  zMin = -500,                  -- vertical range of a box (game units) when the zone's elevation gate does not narrow it
  zMax = 2000,
  fillTarget = 0.75,            -- polygon area / box area at which a box is accepted
  minSplitLength = 24,          -- a box this long (m) or shorter is never cut
  maxDepth = 6,                 -- cuts in a row on one piece
  maxBoxesPerZone = 24,
  minBoxSide = 2,               -- a box side is never thinner than this (m)
  debugLog = false,
}

-- zone type name -> ambience. The type numbers are the TrackPathZone enum, used when typeName is missing.
local ROLES = {
  TUNNEL = "Level_Tunnel_Closed",
  OVERPASS = "Level_Under_Bridge",
  OVERPASS_SMALL = "Level_Under_Bridge_A",
  GARAGE = "Level_Parking_House",
}
local TYPE_NAMES = { [3] = "TUNNEL", [4] = "OVERPASS", [5] = "OVERPASS_SMALL", [7] = "GARAGE" }

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
local roles = {}                                -- role -> ambience, ROLES plus the overrides file
local zoneOverrides = {}                        -- zone id (text) -> ambience or false
local group = nil
local stats
local warned = {}

local function resetStats()
  stats = { zones = 0, boxes = 0, skipped = 0, errors = 0, byRole = {}, ambienceMissing = {}, loaded = false, source = nil }
end
resetStats()

local function logMsg(level, fmt, ...)
  if level == "D" and not TUNING.debugLog then return end
  local text = select("#", ...) > 0 and string.format(fmt, ...) or fmt
  if log then log(level, "nfscSoundZones", text) end
end

local function warnOnce(key, fmt, ...)
  if warned[key] then return end
  warned[key] = true
  logMsg("W", fmt, ...)
end

local function failOnce(key, fmt, ...)
  stats.errors = stats.errors + 1
  warnOnce(key, fmt, ...)
end

-- ---------------------------------------------------------------------------
-- Geometry (plain {x, y} points)
-- ---------------------------------------------------------------------------
local function polyArea(p)
  local s = 0
  for i = 1, #p do
    local a, b = p[i], p[i % #p + 1]
    s = s + (a.x * b.y - b.x * a.y)
  end
  return math.abs(s) * 0.5
end

local function convexHull(points)
  local pts = {}
  for i = 1, #points do pts[i] = points[i] end
  table.sort(pts, function(a, b) if a.x ~= b.x then return a.x < b.x end return a.y < b.y end)
  local function cross(o, a, b) return (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) end
  local lower = {}
  for i = 1, #pts do
    while #lower >= 2 and cross(lower[#lower - 1], lower[#lower], pts[i]) <= 0 do lower[#lower] = nil end
    lower[#lower + 1] = pts[i]
  end
  local upper = {}
  for i = #pts, 1, -1 do
    while #upper >= 2 and cross(upper[#upper - 1], upper[#upper], pts[i]) <= 0 do upper[#upper] = nil end
    upper[#upper + 1] = pts[i]
  end
  lower[#lower] = nil
  upper[#upper] = nil
  for i = 1, #upper do lower[#lower + 1] = upper[i] end
  return lower
end

-- Smallest-area oriented rectangle of the points: centre, unit long axis u, length along u, width across it.
local function fitBox(points)
  local hull = convexHull(points)
  if #hull < 3 then return nil end
  local best
  for i = 1, #hull do
    local a, b = hull[i], hull[i % #hull + 1]
    local ex, ey = b.x - a.x, b.y - a.y
    local len = math.sqrt(ex * ex + ey * ey)
    if len > 1e-9 then
      ex, ey = ex / len, ey / len
      local nx, ny = -ey, ex
      local u0, u1, v0, v1 = math.huge, -math.huge, math.huge, -math.huge
      for j = 1, #hull do
        local pu = hull[j].x * ex + hull[j].y * ey
        local pv = hull[j].x * nx + hull[j].y * ny
        if pu < u0 then u0 = pu end
        if pu > u1 then u1 = pu end
        if pv < v0 then v0 = pv end
        if pv > v1 then v1 = pv end
      end
      local area = (u1 - u0) * (v1 - v0)
      if not best or area < best.area then
        best = { area = area, ex = ex, ey = ey, nx = nx, ny = ny, u0 = u0, u1 = u1, v0 = v0, v1 = v1 }
      end
    end
  end
  if not best then return nil end
  local lenU, lenV = best.u1 - best.u0, best.v1 - best.v0
  local midU, midV = (best.u0 + best.u1) * 0.5, (best.v0 + best.v1) * 0.5
  local cx = best.ex * midU + best.nx * midV
  local cy = best.ey * midU + best.ny * midV
  if lenU >= lenV then
    return { cx = cx, cy = cy, ux = best.ex, uy = best.ey, len = lenU, wid = lenV }
  end
  return { cx = cx, cy = cy, ux = best.nx, uy = best.ny, len = lenV, wid = lenU }   -- the long side is always u
end

-- Keeps the part of the polygon where nx * x + ny * y <= d (Sutherland-Hodgman against one half-plane).
local function clipHalfPlane(poly, nx, ny, d)
  local out = {}
  for i = 1, #poly do
    local a, b = poly[i], poly[i % #poly + 1]
    local da, db = nx * a.x + ny * a.y - d, nx * b.x + ny * b.y - d
    if da <= 0 then out[#out + 1] = a end
    if (da < 0 and db > 0) or (da > 0 and db < 0) then
      local t = da / (da - db)
      out[#out + 1] = { x = a.x + (b.x - a.x) * t, y = a.y + (b.y - a.y) * t }
    end
  end
  return out
end

local function decompose(poly, depth, out)
  local box = fitBox(poly)
  if not box then return end
  local area = polyArea(poly)
  if area < 1e-6 then return end
  local boxArea = box.len * box.wid
  local fill = boxArea > 1e-9 and area / boxArea or 1
  if fill >= TUNING.fillTarget or depth >= TUNING.maxDepth or box.len <= TUNING.minSplitLength
     or #out >= TUNING.maxBoxesPerZone then
    box.fill = fill
    out[#out + 1] = box
    return
  end
  local d = box.cx * box.ux + box.cy * box.uy
  local a = clipHalfPlane(poly, box.ux, box.uy, d)
  local b = clipHalfPlane(poly, -box.ux, -box.uy, -d)
  if #a < 3 or #b < 3 then
    box.fill = fill
    out[#out + 1] = box
    return
  end
  decompose(a, depth + 1, out)
  decompose(b, depth + 1, out)
end
M._decompose = decompose            -- for the offline tests

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

-- ---------------------------------------------------------------------------
-- Scene objects
-- ---------------------------------------------------------------------------
local function ensureGroup()
  if group then return group end
  local g = scenetree.findObject(TUNING.groupName)
  if not g then
    g = createObject("SimGroup")
    if not g then error("could not create the sound zone group") end
    g:registerObject(TUNING.groupName)
    local mission = scenetree.findObject("MissionGroup")
    if mission then mission:addObject(g) end
  end
  group = g
  return g
end

local function destroyGroup()
  local g = scenetree.findObject(TUNING.groupName)
  if g then pcall(g.delete, g) end
  group = nil
end

local function createSpace(name, ambience, box, zLo, zHi)
  local obj = createObject("SFXSpace")
  if not obj then return false, "createObject(SFXSpace) returned nil" end
  local c, s = box.ux, box.uy                                    -- rotation about z: local x runs along u
  pcall(obj.setField, obj, "soundAmbience", 0, ambience)
  pcall(obj.setField, obj, "position", 0, string.format("%.4f %.4f %.4f", box.cx, box.cy, (zLo + zHi) * 0.5))
  pcall(obj.setField, obj, "rotationMatrix", 0, string.format("%.6f %.6f 0 %.6f %.6f 0 0 0 1", c, -s, s, c))
  pcall(obj.setField, obj, "scale", 0, string.format("%.4f %.4f %.4f", math.max(box.len, TUNING.minBoxSide),
    math.max(box.wid, TUNING.minBoxSide), zHi - zLo))
  pcall(function() obj.canSave = false end)
  local ok, err = pcall(obj.registerObject, obj, name)
  if ok and err == false then ok, err = false, "the engine refused it (returned false)" end
  if not ok then
    pcall(obj.delete, obj)
    return false, "registerObject failed: " .. tostring(err)
  end
  pcall(ensureGroup().addObject, ensureGroup(), obj)
  pcall(obj.postApply, obj)
  if not stats.readback then                                    -- one readback: what the engine kept of the fields
    stats.readback = true
    local function field(n) local good, v = pcall(obj.getField, obj, n, 0); return good and tostring(v) or "?" end
    logMsg("I", "first space %s: id=%s soundAmbience=%s position=%s scale=%s rotationMatrix=%s", name,
      tostring(pcall(obj.getID, obj) and obj:getID() or "?"), field("soundAmbience"), field("position"), field("scale"),
      field("rotationMatrix"))
  end
  return true
end

local function checkAmbience(name)
  if stats.ambienceMissing[name] ~= nil then return end
  local found = false
  local ok, res = pcall(scenetree.findObject, name)
  if ok and res then found = true end
  stats.ambienceMissing[name] = not found
  if not found then warnOnce("amb:" .. name, "ambience '%s' was not found by name; the spaces using it are still created", name) end
end

-- ---------------------------------------------------------------------------
-- Build
-- ---------------------------------------------------------------------------
local function readOverrides()
  roles, zoneOverrides = {}, {}
  for role, ambience in pairs(ROLES) do roles[role] = ambience end
  local data = jsonReadFile(TUNING.levelRoot .. "/" .. TUNING.overridesFile)
  if type(data) ~= "table" then return end
  if tonumber(data.zOffset) then TUNING.zOffset = tonumber(data.zOffset) end
  if type(data.roles) == "table" then
    for role, ambience in pairs(data.roles) do
      if ROLES[role] ~= nil and (type(ambience) == "string" or ambience == false) then roles[role] = ambience end
    end
  end
  if type(data.zones) == "table" then
    for id, ambience in pairs(data.zones) do
      if type(ambience) == "string" or ambience == false then zoneOverrides[tostring(id)] = ambience end
    end
  end
end

local function roleOf(zone)
  local name = type(zone.typeName) == "string" and zone.typeName:upper() or nil
  if name and roles[name] ~= nil then return name end
  local byType = TYPE_NAMES[tonumber(zone.type)]
  if byType and roles[byType] ~= nil then return byType end
  return nil
end

local function buildZone(zone, index)
  local role = roleOf(zone)
  if not role then return end
  local id = tostring(zone.id or index)
  local ambience = zoneOverrides[id]
  if ambience == nil then ambience = roles[role] end
  if not ambience then stats.skipped = stats.skipped + 1; return end
  local poly = zonePolygon(zone)
  if not poly then stats.skipped = stats.skipped + 1; warnOnce("poly:" .. id, "zone %s has no usable polygon or bounds; skipped", id); return end

  local zLo, zHi = TUNING.zMin, TUNING.zMax
  local elevation = tonumber(zone.elevation) or 0
  if elevation > 0 and elevation > zLo then zLo = elevation end
  if elevation < 0 and -elevation < zHi then zHi = -elevation end
  if zHi - zLo < 1 then stats.skipped = stats.skipped + 1; warnOnce("z:" .. id, "zone %s: the elevation gate leaves no height; skipped", id); return end
  zLo, zHi = zLo + TUNING.zOffset, zHi + TUNING.zOffset

  local boxes = {}
  decompose(poly, 0, boxes)
  if #boxes == 0 then stats.skipped = stats.skipped + 1; return end
  checkAmbience(ambience)
  stats.zones = stats.zones + 1
  for i = 1, #boxes do
    local ok, err = createSpace(string.format("nfsc_sfx_%s_%d", id, i), ambience, boxes[i], zLo, zHi)
    if ok then
      stats.boxes = stats.boxes + 1
      local r = stats.byRole[role] or { zones = 0, boxes = 0 }
      r.boxes = r.boxes + 1
      if i == 1 then r.zones = r.zones + 1 end
      stats.byRole[role] = r
    else
      failOnce("create:" .. role, "a sound space could not be created: %s", tostring(err))
    end
  end
end

function M.rebuild()
  destroyGroup()
  resetStats()
  warned = {}
  readOverrides()
  local path = TUNING.levelRoot .. "/" .. TUNING.zonesFile
  stats.source = path
  local data = jsonReadFile(path)
  if type(data) ~= "table" then
    logMsg("W", "could not read %s (missing or not valid JSON); no sound zones were built", path)
    return false, "could not read " .. path
  end
  local list, listKey = zoneList(data)
  if not list then
    local keys = {}
    for key in pairs(data) do keys[#keys + 1] = tostring(key) end
    table.sort(keys)
    logMsg("W", "%s has no zone list (top-level fields: %s); no sound zones were built", path, table.concat(keys, ", "))
    return false, "no zone list in " .. path
  end
  stats.loaded = true
  local seen = {}
  for _, zone in ipairs(list) do
    if type(zone) == "table" then
      local key = tostring(zone.typeName or zone.type)
      seen[key] = (seen[key] or 0) + 1
    end
  end
  local parts = {}
  for key, n in pairs(seen) do parts[#parts + 1] = key .. "=" .. n end
  table.sort(parts)
  logMsg("I", "read %d zones from %s (list: %s; types: %s)", #list, path, listKey, table.concat(parts, " "))
  ensureGroup()
  for i, zone in ipairs(list) do
    if type(zone) == "table" then
      local ok, err = pcall(buildZone, zone, i)
      if not ok then failOnce("zone:" .. tostring(zone.id or i), "zone %s failed: %s", tostring(zone.id or i), tostring(err)) end
    end
  end
  logMsg("I", "built %d sound spaces for %d zones (%d skipped, %d errors)", stats.boxes, stats.zones, stats.skipped, stats.errors)
  return true
end

-- ---------------------------------------------------------------------------
-- Status, lifecycle
-- ---------------------------------------------------------------------------
function M.getStatus()
  return { loaded = stats.loaded, source = stats.source, zones = stats.zones, boxes = stats.boxes,
           skipped = stats.skipped, errors = stats.errors, byRole = stats.byRole, ambienceMissing = stats.ambienceMissing }
end

function M.setDebugLog(flag) TUNING.debugLog = flag and true or false end
function M.getDebugLog() return TUNING.debugLog end

function M.initialize(basePath)
  TUNING.levelRoot = ((basePath or TUNING.levelRoot):gsub("/+$", ""))
  return M.rebuild()
end

function M.onExtensionUnloaded()
  destroyGroup()
  resetStats()
end

return M
