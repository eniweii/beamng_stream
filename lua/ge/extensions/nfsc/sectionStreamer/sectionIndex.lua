-- nfsc_sectionStreamer, part "sectionIndex": sections.json and the stream index, point-in-polygon lookup, stacked sections (depth), the active set and the section getters.
-- Loaded by sectionStreamer.lua into the shared streamer environment; every name here is shared with the other parts.

-- ---------------------------------------------------------------------------
-- Section geometry (2D, height ignored). Mirrors the game's VisibleSection lookup:
-- exact containment first, else closest edge within a tolerance (ties -> lower ID).
-- ---------------------------------------------------------------------------
function pointInBounds(p, bmin, bmax)
  return p.x >= bmin.x and p.x <= bmax.x and p.y >= bmin.y and p.y <= bmax.y
end

function pointInPolygon(p, points)
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

function distanceToPolygonEdges(p, points)
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

function isInSection(p, id)
  local s = sections[id]
  return s ~= nil and pointInBounds(p, s.boundsMin, s.boundsMax) and pointInPolygon(p, s.points)
end

function findSection(p)
  for i = 1, #sectionOrder do
    local id = sectionOrder[i]
    if isInSection(p, id) then return id end
  end
  local bestID, bestDist = nil, math.huge
  local tol = TUNING.containmentTolerance
  local px, py = p.x, p.y
  for i = 1, #sectionOrder do
    local id = sectionOrder[i]
    local s = sections[id]
    local bmin, bmax = s.boundsMin, s.boundsMax
    -- a polygon lies inside its bounds, so it is no closer than the bounds widened by the tolerance: skip it before measuring
    if px >= bmin.x - tol and px <= bmax.x + tol and py >= bmin.y - tol and py <= bmax.y + tol then
      local d = distanceToPolygonEdges(p, s.points)
      if d <= tol and d < bestDist then bestID, bestDist = id, d end
    end
  end
  return bestID
end

-- ---------------------------------------------------------------------------
-- Stacked (depth) sections. A drivable section with depth sections (a tunnel under a road, an overpass) is found in 2D
-- like any other; the camera height then picks between it and its depth section (Hyperlinked / MW decomp rule): the
-- elevation triangle that contains the camera in x/y and whose surface is the highest one at or below the camera
-- height names the depth section with the same name, otherwise the base section stays. A depth section has a related
-- list but no polygon and no stream data, so it lives here and not in `sections`.
-- ---------------------------------------------------------------------------
hold.stack = { depth = {}, byBase = {}, tris = {}, last = nil }

function hold.baseOf(id)
  local d = id and hold.stack.depth[id]
  return d and d.base or id
end

function hold.relatedOf(id)
  local s = id and sections[id]
  if s then return s.related end
  local d = id and hold.stack.depth[id]
  return d and d.related or {}
end

function hold.hasSection(id)
  return id ~= nil and (sections[id] ~= nil or hold.stack.depth[id] ~= nil)
end

function triangleHit(t, x, y)
  if x < t.minX or x > t.maxX or y < t.minY or y > t.maxY then return nil end
  local a, b, c = t.a, t.b, t.c
  local det = (b.y - c.y) * (a.x - c.x) + (c.x - b.x) * (a.y - c.y)
  if math.abs(det) < 1e-9 then return nil end                      -- a vertical triangle has no surface
  local l1 = ((b.y - c.y) * (x - c.x) + (c.x - b.x) * (y - c.y)) / det
  local l2 = ((c.y - a.y) * (x - c.x) + (a.x - c.x) * (y - c.y)) / det
  local l3 = 1 - l1 - l2
  if l1 < 0 or l2 < 0 or l3 < 0 then return nil end
  return l1 * a.z + l2 * b.z + l3 * c.z                            -- surface height under (x, y)
end

-- The section to stream for when the camera is in the base section `baseID` at height z.
function hold.resolveDepth(baseID, p, z)
  local list = baseID and hold.stack.byBase[baseID]
  if not list or not z then return baseID end
  local limit = z + TUNING.elevationZOffset + TUNING.elevationTolerance
  local bestZ, bestName
  for i = 1, #hold.stack.tris do
    local t = hold.stack.tris[i]
    local sz = triangleHit(t, p.x, p.y)
    if sz and sz <= limit and (bestZ == nil or sz > bestZ) then bestZ, bestName = sz, t.name end
  end
  local chosen = baseID
  if bestName then
    for i = 1, #list do
      if list[i].name == bestName then chosen = list[i].id; break end
    end
  end
  hold.stack.last = { base = baseID, triangle = bestName, surface = bestZ, z = z, chosen = chosen }
  return chosen
end

function computeActive(id)
  local set = {}
  for always in pairs(hold.always.set) do set[always] = true end   -- always-loaded sections stay active everywhere
  if id and hold.hasSection(id) then
    set[id] = true
    for _, rel in ipairs(hold.relatedOf(id)) do set[rel] = true end
  end
  return set
end

-- ---------------------------------------------------------------------------
-- Loading the section/stream metadata
-- ---------------------------------------------------------------------------
function loadSections()
  sections, sectionOrder = {}, {}
  hold.stack.depth, hold.stack.byBase, hold.stack.tris, hold.stack.last = {}, {}, {}, nil
  local data = jsonReadFile(levelRoot .. "/" .. SECTIONS_JSON)
  if type(data) ~= "table" or type(data.sections) ~= "table" then
    error("could not read " .. levelRoot .. "/" .. SECTIONS_JSON)
  end
  -- Hex key -> name of the override groups the exporter could name (the viewer writes it into sections.json). The
  -- section manager folds a hex token and its name into one override with it, so no hash is computed in game.
  hold.overrideAlias = {}
  if type(data.overrideNames) == "table" then
    for key, name in pairs(data.overrideNames) do
      if type(key) == "string" and type(name) == "string" and name ~= "" then
        hold.overrideAlias[(key:gsub("^0[xX](%x+)$", function(h) return "0x" .. h:upper() end))] = name
      end
    end
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
      for _, d in ipairs(entry.depth or {}) do
        local did, dname = tonumber(d.id), tonumber(d.name)
        if did and not sections[did] then
          local drel = {}
          for _, r in ipairs(d.related or {}) do
            local n = tonumber(r)
            if n then drel[#drel + 1] = n end
          end
          local rec = { id = did, base = id, name = dname, related = drel }
          hold.stack.depth[did] = rec
          local list = hold.stack.byBase[id] or {}
          list[#list + 1] = rec
          hold.stack.byBase[id] = list
        end
      end
    end
  end
  table.sort(sectionOrder)
  for _, poly in ipairs(data.elevationPolys or {}) do
    local name, pts = tonumber(poly.name), poly.points
    if name and type(pts) == "table" and #pts >= 3 then
      local v = {}
      for i = 1, 3 do v[i] = { x = pts[i][1], y = pts[i][2], z = pts[i][3] or 0 } end
      hold.stack.tris[#hold.stack.tris + 1] = {
        name = name, a = v[1], b = v[2], c = v[3],
        minX = math.min(v[1].x, v[2].x, v[3].x), maxX = math.max(v[1].x, v[2].x, v[3].x),
        minY = math.min(v[1].y, v[2].y, v[3].y), maxY = math.max(v[1].y, v[2].y, v[3].y),
      }
    end
  end
  local nDepth, nBase = 0, 0
  for _ in pairs(hold.stack.depth) do nDepth = nDepth + 1 end
  for _ in pairs(hold.stack.byBase) do nBase = nBase + 1 end
  if nDepth > 0 then
    logMsg("I", "stacked sections: %d depth sections under %d base sections, %d elevation triangles", nDepth, nBase, #hold.stack.tris)
  end
end

function loadStreamIndex()
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

-- A section with streamed objects that is in no polygon and in no related list can never be reached through the camera
-- (the section table comes from the level's own data): it is always loaded. Needs loadSections and loadStreamIndex first.
function hold.findAlways()
  local reached = {}
  for _, sec in pairs(sections) do
    for _, rel in ipairs(sec.related) do reached[rel] = true end
  end
  for _, d in pairs(hold.stack.depth) do
    for _, rel in ipairs(d.related) do reached[rel] = true end
  end
  local set, list = {}, {}
  for id, entry in pairs(sectionIndex) do
    if not hold.hasSection(id) and not reached[id] then set[id], list[#list + 1] = true, id end
  end
  table.sort(list)
  hold.always = { set = set, list = list, dirty = true }
  for _, id in ipairs(list) do
    logMsg("I", "always-loaded section %d: %d objects, in no section polygon and in no related list", id, sectionIndex[id].count or 0)
  end
end

function sectionAt(p, z)
  local cur = hold.baseOf(currentSectionID)
  local base
  if cur and isInSection(p, cur) then base = cur else base = findSection(p) end
  return hold.resolveDepth(base, p, z)
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
  return hold.relatedOf(id)
end

-- name -> list of section IDs, straight from the builder's index
function M.getOverrideIndex() return overrideIndex end
function M.getOverrideAlias() return hold.overrideAlias or {} end        -- hex key -> override name, from sections.json

-- 1101 -> "1101 (K01)": letter index above the last two digits, section number below
function M.sectionIDToDisplayName(id)
  if not id then return "none" end
  local letterIndex = math.floor(id / 100)
  if letterIndex < 1 or letterIndex > 26 then return tostring(id) end
  return string.format("%d (%s%02d)", id, string.char(64 + letterIndex), id % 100)
end
