-- nfsc_environmentManager: Environment Manager (material roughness and object sway).
--
-- It never creates or deletes anything. Two independent jobs:
--
--   1. Roughness. Every material whose name ends in a shader class (for example
--      PAN_BLDS_LOWTOWERS_02_D_WorldReflectShader) can have its roughness scaled globally. The
--      material index is read once from the level's *materials.json files (name, class, used
--      stages, baseline roughnessFactor); nothing is polled afterwards. Requests are layered:
--      M.setRoughness(source, multiplier, {priority, fade}); the highest priority wins, the newest
--      wins a tie, and no request means baseline (x1). The panel is the only source for now.
--      A change is written as passes over the selected materials, at most maxWritesPerFrame per
--      frame, and a fade is a series of passes. Nothing runs while nothing changes.
--
--   2. Sway. The streamer's listener events feed a registry of live objects whose instanceFlags
--      contain Swayable (objects with IdentityMatrix or ChoppedRoadway are skipped: their origin is
--      world zero). Only the nearest maxObjects within radius metres move: a small lean about the
--      object's own origin is composed on top of its exported rotation each frame. An object that
--      leaves that set, is released by the streamer (deleted or deactivated) or when sway is switched
--      off gets its exported position and rotation back, so a recycled shell never keeps a tilted
--      pose. Nothing runs while sway is off, nothing is registered or the simulation is paused.
--
-- Interface:
--   from the streamer (listener):  onObjectCreated(key, obj, item), onObjectDeleted(key), onStreamerReset()
--   API: initialize(basePath), setRoughness(source, mult, opts), clearRoughness(source, opts),
--        setClassSelected(class, on), setSwayEnabled(on), setSway(values), getStatus(), ...
--
-- Flagged for in-engine verification (nothing here has run in BeamNG): Material setField with a layer
-- index plus reload()/flush(), obj:getRotation() and obj:setPosRot(x, y, z, qx, qy, qz, qw) on a TSStatic.
-- Every engine call is wrapped in pcall; a failure is counted and logged once, never thrown.

local M = {}
M.dependencies = { "nfsc_sectionStreamer" }

-- ---------------------------------------------------------------------------
-- Tuning
-- ---------------------------------------------------------------------------
local TUNING = {
  levelRoot = "levels/nfsc",
  materialFiles = "*materials.json",
  defaultClass = "WorldReflectShader",     -- selected on a fresh load
  maxWritesPerFrame = 40,                  -- materials written per frame
  minPassInterval = 0.25,                  -- seconds between the passes of a fade
  valueEpsilon = 0.0005,
  debugLog = false,
}

local SWAY = {
  enabled = false,
  amplitudeDeg = 2.0,                      -- peak lean along the wind
  speedHz = 0.35,
  windDirDeg = 0.0,                        -- world direction the objects lean towards (0 = +X, 90 = +Y)
  radius = 250.0,                          -- metres from the camera
  maxObjects = 64,
  selectInterval = 0.25,                   -- seconds between picks of the moving set
  exitMargin = 1.1,                        -- an object that already moves stays up to radius * this
}

-- Shader classes carried by the material names (EffectId names). The name must end in "_" + class.
local KNOWN_CLASSES = {
  "WorldReflectShader", "WorldBoneShader", "WorldNormalMap", "WorldShader", "CarShader",
  "CARNORMALMAP", "GLASS_REFLECT", "WATER", "skyshader", "UCAP",
}
local ENGINE_LAYERS = 4
local TWO_PI = math.pi * 2

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
local R = {                                -- roughness
  mats = {}, classes = {}, classOrder = {},
  indexState = "pending",                  -- pending | ready | failed
  indexInfo = {},
  requests = {}, seq = 0,
  desired = 1.0, shown = 1.0, fadeRate = 0, lastPassAt = -100, clock = 0,
  selectionDirty = false,
  pass = nil,                              -- { value, list, cursor }
  stats = { passes = 0, writes = 0, writeMs = 0, maxMs = 0, missing = 0, errors = 0 },
  loggedFailure = {},
}
local W = {                                -- sway
  registry = {}, count = 0, active = {}, activeCount = 0,
  time = 0, sinceSelect = 100,
  stats = { restored = 0, errors = 0, skipped = 0, peakActive = 0 },
  unavailable = nil,                       -- reason text once an engine call failed
}
local listener = {}

local function logMsg(level, fmt, ...)
  if level == "D" and not TUNING.debugLog then return end
  if log then log(level, "nfsc_environmentManager", string.format(fmt, ...)) end
end

local function failOnce(key, fmt, ...)
  if R.loggedFailure[key] then return end
  R.loggedFailure[key] = true
  logMsg("E", fmt, ...)
end

local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end

-- ---------------------------------------------------------------------------
-- Roughness: material index
-- ---------------------------------------------------------------------------
local function classOf(name)
  local lower = name:lower()
  for i = 1, #KNOWN_CLASSES do
    local suffix = "_" .. KNOWN_CLASSES[i]:lower()
    if #lower > #suffix and lower:sub(-#suffix) == suffix then return KNOWN_CLASSES[i] end
  end
  return nil
end
M.classOf = classOf

local function stageUsed(stage)
  if type(stage) ~= "table" then return false end
  for _, key in ipairs({ "baseColorMap", "colorMap", "diffuseMap" }) do
    local v = stage[key]
    if type(v) == "string" and v ~= "" then return true end
  end
  return false
end

local function stageBase(stage)
  return clamp(tonumber(type(stage) == "table" and stage.roughnessFactor) or 1.0, 0, 1)
end

local function indexMaterial(name, def)
  local cls = classOf(name)
  if not cls then return nil end
  local layers = {}
  for i = 1, math.min(#def.Stages, ENGINE_LAYERS) do
    if stageUsed(def.Stages[i]) then layers[#layers + 1] = { idx = i - 1, base = stageBase(def.Stages[i]) } end
  end
  if #layers == 0 then layers[1] = { idx = 0, base = stageBase(def.Stages[1]) } end
  return { name = name, class = cls, layers = layers, mult = 1.0 }
end

local function buildIndex()
  local started = os.clock()
  local previous = {}
  for name, c in pairs(R.classes) do previous[name] = c.selected end
  R.mats, R.classes, R.classOrder, R.pass = {}, {}, {}, nil
  R.shown, R.selectionDirty = 1.0, false
  R.stats.missing = 0
  local files = {}
  if FS and FS.findFiles then
    local ok, found = pcall(FS.findFiles, FS, TUNING.levelRoot, TUNING.materialFiles, -1, true, false)
    if ok and type(found) == "table" then files = found end
  end
  local seen, fileCount = {}, 0
  for _, path in ipairs(files) do
    local data = jsonReadFile and jsonReadFile(path)
    if type(data) == "table" then
      fileCount = fileCount + 1
      for name, def in pairs(data) do
        if type(name) == "string" and not seen[name] and type(def) == "table" and def.class == "Material"
            and type(def.Stages) == "table" then
          local rec = indexMaterial(name, def)
          if rec then
            seen[name] = true
            R.mats[#R.mats + 1] = rec
            local c = R.classes[rec.class]
            if not c then
              local keep = previous[rec.class]
              if keep == nil then keep = rec.class == TUNING.defaultClass end
              c = { count = 0, selected = keep }
              R.classes[rec.class] = c
            end
            c.count = c.count + 1
          end
        end
      end
    end
  end
  table.sort(R.mats, function(a, b) return a.name < b.name end)
  for name in pairs(R.classes) do R.classOrder[#R.classOrder + 1] = name end
  table.sort(R.classOrder)
  R.indexInfo = { files = fileCount, materials = #R.mats, ms = (os.clock() - started) * 1000 }
  R.indexState = "ready"
  R.selectionDirty = true
  logMsg("I", "material index: %d materials with a shader class in %d file(s), %.1f ms", #R.mats, fileCount, R.indexInfo.ms)
end

function M.rebuildMaterialIndex()
  local ok, err = pcall(buildIndex)
  if not ok then
    R.indexState = "failed"
    R.indexInfo = { error = tostring(err) }
    logMsg("E", "material index failed: %s", tostring(err))
    return false
  end
  return true
end

-- ---------------------------------------------------------------------------
-- Roughness: requests and passes
-- ---------------------------------------------------------------------------
local function resolveRequests()
  local best
  for _, req in pairs(R.requests) do
    if not best or req.priority > best.priority or (req.priority == best.priority and req.seq > best.seq) then best = req end
  end
  return best
end

local function updateDesired(fade)
  local best = resolveRequests()
  local value = best and best.mult or 1.0
  if math.abs(value - R.desired) <= 1e-9 then return end
  R.desired = value
  R.lastPassAt = R.clock - TUNING.minPassInterval              -- the first step of a fade is one interval long
  local f = fade
  if f == nil and best then f = best.fade end
  R.fadeRate = (f and f > 0) and (math.abs(value - R.shown) / f) or 0
end

-- source: free text ("user", or the name of an event); opts: { priority = 0, fade = seconds }
function M.setRoughness(source, mult, opts)
  opts = opts or {}
  mult = clamp(tonumber(mult) or 1.0, 0, 4)
  R.seq = R.seq + 1
  R.requests[source] = { mult = mult, priority = opts.priority or 0, fade = opts.fade or 0, seq = R.seq }
  updateDesired(opts.fade or 0)
end

function M.clearRoughness(source, opts)
  opts = opts or {}
  if R.requests[source] == nil then return end
  R.requests[source] = nil
  updateDesired(opts.fade or 0)
end

function M.getRoughnessRequests()
  local out = {}
  for source, req in pairs(R.requests) do out[source] = { mult = req.mult, priority = req.priority, fade = req.fade } end
  return out
end

function M.setClassSelected(cls, on)
  local c = R.classes[cls]
  if not c or c.selected == (on and true or false) then return end
  c.selected = on and true or false
  R.selectionDirty = true
end

function M.isClassSelected(cls) local c = R.classes[cls]; return c ~= nil and c.selected end
function M.getClasses()
  local out = {}
  for i, name in ipairs(R.classOrder) do out[i] = { name = name, count = R.classes[name].count, selected = R.classes[name].selected } end
  return out
end

local function wantMult(rec, value)
  local c = R.classes[rec.class]
  if c and c.selected then return value end
  return 1.0
end

-- Refreshes the engine material after a field write. reload first, flush as the fallback.
local function refreshMaterial(obj)
  if pcall(obj.reload, obj) then return true end
  return pcall(obj.flush, obj)
end

local function writeMaterial(rec, mult)
  local obj = scenetree and scenetree.findObject(rec.name)
  if not obj then
    rec.mult = mult
    R.stats.missing = R.stats.missing + 1
    return false
  end
  for i = 1, #rec.layers do
    local layer = rec.layers[i]
    local ok, err = pcall(obj.setField, obj, "roughnessFactor", layer.idx, string.format("%.4f", clamp(layer.base * mult, 0, 1)))
    if not ok then R.stats.errors = R.stats.errors + 1; failOnce("setField", "setField roughnessFactor failed on %s: %s", rec.name, tostring(err)) end
  end
  if not refreshMaterial(obj) then
    R.stats.errors = R.stats.errors + 1
    failOnce("reload", "neither reload() nor flush() worked on %s; the new roughness may not show", rec.name)
  end
  rec.mult = mult
  return true
end

local function startPass(now)
  local value = R.desired
  if R.fadeRate > 0 then
    local step = R.fadeRate * math.max(TUNING.minPassInterval, now - R.lastPassAt)
    local delta = R.desired - R.shown
    if math.abs(delta) > step then value = R.shown + (delta > 0 and step or -step) end
  end
  local list = {}
  for i = 1, #R.mats do
    local rec = R.mats[i]
    if math.abs(wantMult(rec, value) - rec.mult) > 1e-6 then list[#list + 1] = rec end
  end
  R.lastPassAt = now
  R.selectionDirty = false
  R.stats.passes = R.stats.passes + 1
  R.pass = { value = value, list = list, cursor = 1 }
end

local function runPass()
  local pass = R.pass
  local list, n = pass.list, #pass.list
  local last = math.min(n, pass.cursor + TUNING.maxWritesPerFrame - 1)
  local t0 = os.clock()
  for i = pass.cursor, last do
    if writeMaterial(list[i], wantMult(list[i], pass.value)) then R.stats.writes = R.stats.writes + 1 end
  end
  local ms = (os.clock() - t0) * 1000
  R.stats.writeMs = R.stats.writeMs + ms
  if ms > R.stats.maxMs then R.stats.maxMs = ms end
  pass.cursor = last + 1
  if pass.cursor > n then
    R.shown = pass.value
    R.pass = nil
    logMsg("D", "roughness pass done: x%.3f, %d material(s), last frame %.2f ms", R.shown, n, ms)
  end
end

local function updateRoughness(dtReal)
  R.clock = R.clock + dtReal
  if R.indexState == "pending" then M.rebuildMaterialIndex() end
  if R.indexState ~= "ready" then return end
  if R.pass then runPass(); return end
  if math.abs(R.desired - R.shown) > TUNING.valueEpsilon or R.selectionDirty then
    if R.fadeRate > 0 and R.clock - R.lastPassAt < TUNING.minPassInterval and not R.selectionDirty then return end
    startPass(R.clock)
    if #R.pass.list == 0 then R.shown = R.pass.value; R.pass = nil else runPass() end
  end
end

-- Step 0 probe: writes one material of the class, logs the cost of the field write and of the refresh, reads the
-- value back and puts the baseline back. Returns the numbers.
function M.probeRoughness(cls, mult)
  cls = cls or TUNING.defaultClass
  mult = mult or 0.5
  for i = 1, #R.mats do
    local rec = R.mats[i]
    if rec.class == cls then
      local obj = scenetree and scenetree.findObject(rec.name)
      if not obj then return { ok = false, name = rec.name, reason = "the engine has no material of that name" } end
      local layer = rec.layers[1]
      local value = string.format("%.4f", clamp(layer.base * mult, 0, 1))
      local t0 = os.clock()
      local ok1, err1 = pcall(obj.setField, obj, "roughnessFactor", layer.idx, value)
      local t1 = os.clock()
      local ok2 = refreshMaterial(obj)
      local t2 = os.clock()
      local okRead, back = pcall(obj.getField, obj, "roughnessFactor", layer.idx)
      pcall(obj.setField, obj, "roughnessFactor", layer.idx, string.format("%.4f", layer.base))
      refreshMaterial(obj)
      local res = { ok = ok1 and ok2, name = rec.name, layer = layer.idx, wrote = value, readBack = okRead and tostring(back) or "n/a",
                    setFieldMs = (t1 - t0) * 1000, refreshMs = (t2 - t1) * 1000, error = (not ok1) and tostring(err1) or nil }
      logMsg("I", "probe %s layer %d: wrote %s, read back %s, setField %.3f ms, refresh %.3f ms%s", rec.name, layer.idx, value,
        res.readBack, res.setFieldMs, res.refreshMs, ok2 and "" or " (refresh failed)")
      return res
    end
  end
  return { ok = false, reason = "no indexed material of class " .. tostring(cls) }
end

-- ---------------------------------------------------------------------------
-- Sway
-- ---------------------------------------------------------------------------
local function qmul(a, b)          -- Hamilton product: b is applied first, then a (a acts in the world frame)
  return {
    x = a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
    y = a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
    z = a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
    w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
  }
end

-- A lean of angle |t| towards the horizontal direction t = (tx, ty): the up vector ends up tilted towards +t.
local function leanQuat(tx, ty)
  local mag = math.sqrt(tx * tx + ty * ty)
  if mag < 1e-9 then return { x = 0, y = 0, z = 0, w = 1 } end
  local s = math.sin(mag * 0.5) / mag
  return { x = -ty * s, y = tx * s, z = 0, w = math.cos(mag * 0.5) }
end
M.leanQuat, M.qmul = leanQuat, qmul

local function setPose(rec, x, y, z, q)
  return pcall(rec.obj.setPosRot, rec.obj, x, y, z, q.x, q.y, q.z, q.w)
end

local function restoreRec(rec)
  if rec.base then
    local ok = setPose(rec, rec.px, rec.py, rec.pz, rec.base)
    if ok then W.stats.restored = W.stats.restored + 1 else W.stats.errors = W.stats.errors + 1 end
  end
  rec.base = nil
end

local function deactivate(key, rec)
  if W.active[key] then
    W.active[key] = nil
    W.activeCount = W.activeCount - 1
  end
  restoreRec(rec)
end

local function removeRec(key, restore)
  local rec = W.registry[key]
  if not rec then return end
  if restore then deactivate(key, rec)
  elseif W.active[key] then W.active[key] = nil; W.activeCount = W.activeCount - 1 end
  W.registry[key] = nil
  W.count = W.count - 1
end

local function activate(key, rec)
  local okR, rot = pcall(rec.obj.getRotation, rec.obj)          -- a quat may be a table or engine userdata
  local okF, x, y, z, w
  if okR and rot ~= nil then okF, x, y, z, w = pcall(function() return rot.x, rot.y, rot.z, rot.w end) end
  if not okF or w == nil then
    W.unavailable = "obj:getRotation() gave nothing usable on a TSStatic"
    failOnce("getRotation", "sway unavailable: %s", W.unavailable)
    rec.dead = true
    return false
  end
  rec.base = { x = x, y = y, z = z, w = w }
  W.active[key] = rec
  W.activeCount = W.activeCount + 1
  return true
end

local function selectMoving(cam)
  local r2 = SWAY.radius * SWAY.radius
  local keep2 = (SWAY.radius * SWAY.exitMargin) ^ 2
  local cand = {}
  for key, rec in pairs(W.registry) do
    if not rec.dead then
      local dx, dy, dz = rec.px - cam.x, rec.py - cam.y, rec.pz - cam.z
      local d2 = dx * dx + dy * dy + dz * dz
      if d2 <= r2 or (W.active[key] and d2 <= keep2) then cand[#cand + 1] = { key = key, d2 = d2 } end
    end
  end
  if #cand > SWAY.maxObjects then
    table.sort(cand, function(a, b) return a.d2 < b.d2 end)
    for i = #cand, SWAY.maxObjects + 1, -1 do cand[i] = nil end
  end
  local want = {}
  for i = 1, #cand do want[cand[i].key] = true end
  local leaving = {}
  for key in pairs(W.active) do if not want[key] then leaving[#leaving + 1] = key end end
  for i = 1, #leaving do deactivate(leaving[i], W.registry[leaving[i]]) end
  for key in pairs(want) do
    if not W.active[key] then activate(key, W.registry[key]) end
  end
  if W.activeCount > W.stats.peakActive then W.stats.peakActive = W.activeCount end
end

local function swayPose(rec, t)
  local w = TWO_PI * SWAY.speedHz
  local amp = math.rad(SWAY.amplitudeDeg)
  local dirX, dirY = math.cos(math.rad(SWAY.windDirDeg)), math.sin(math.rad(SWAY.windDirDeg))
  local gust = 0.65 + 0.35 * math.sin(w * 0.37 * t + rec.phase * 0.5)
  local along = amp * gust * math.sin(w * t + rec.phase)
  local across = amp * 0.4 * math.sin(w * 0.73 * t + rec.phase * 1.7)
  return qmul(leanQuat(along * dirX - across * dirY, along * dirY + across * dirX), rec.base)
end

local function updateSway(dtReal, dtSim)
  if not SWAY.enabled or W.unavailable or W.count == 0 then return end
  W.sinceSelect = W.sinceSelect + dtReal
  if W.sinceSelect >= SWAY.selectInterval then
    W.sinceSelect = 0
    local cam = core_camera and core_camera.getPosition and core_camera.getPosition()
    if cam then selectMoving(cam) end
  end
  if W.activeCount == 0 or (dtSim or 0) <= 0 then return end        -- paused: nothing moves, nothing to do
  W.time = W.time + dtSim
  local failed
  for key, rec in pairs(W.active) do
    if not rec.obj.hidden then
      local ok = setPose(rec, rec.px, rec.py, rec.pz, swayPose(rec, W.time))
      if not ok then failed = failed or {}; failed[#failed + 1] = key end
    end
  end
  if failed then
    for i = 1, #failed do
      W.stats.errors = W.stats.errors + 1
      failOnce("setPosRot", "setPosRot failed on a swaying object; it is dropped from the sway set")
      local rec = W.registry[failed[i]]
      if rec then rec.dead = true end
      W.active[failed[i]] = nil
      W.activeCount = W.activeCount - 1
    end
  end
end

local function releaseAll(restore)
  local keys = {}
  for key in pairs(W.active) do keys[#keys + 1] = key end
  for i = 1, #keys do
    local rec = W.registry[keys[i]]
    W.active[keys[i]] = nil
    W.activeCount = W.activeCount - 1
    if rec and restore then restoreRec(rec) end
  end
end

function M.setSwayEnabled(on)
  on = on and true or false
  if SWAY.enabled == on then return end
  SWAY.enabled = on
  if on then W.unavailable = nil; R.loggedFailure.getRotation, R.loggedFailure.setPosRot = nil, nil end   -- a fresh try
  if not on then releaseAll(true) end
  W.sinceSelect = 100
end
function M.isSwayEnabled() return SWAY.enabled end

local SWAY_LIMITS = {
  amplitudeDeg = { 0, 15 }, speedHz = { 0.02, 3 }, windDirDeg = { 0, 360 }, radius = { 10, 5000 }, maxObjects = { 1, 2000 },
}
function M.setSway(values)
  for key, limit in pairs(SWAY_LIMITS) do
    local v = tonumber(values and values[key])
    if v then SWAY[key] = clamp(key == "maxObjects" and math.floor(v) or v, limit[1], limit[2]) end
  end
  W.sinceSelect = 100
end
function M.getSway()
  local out = { enabled = SWAY.enabled }
  for key in pairs(SWAY_LIMITS) do out[key] = SWAY[key] end
  return out
end

local function hasSwayFlag(flags)
  if type(flags) ~= "string" then return false end
  local lower = flags:lower()
  if not lower:find("swayable", 1, true) then return false end
  if lower:find("identitymatrix", 1, true) or lower:find("choppedroadway", 1, true) then W.stats.skipped = W.stats.skipped + 1; return false end
  return true
end

function listener:onObjectCreated(key, obj, item)
  if not hasSwayFlag(item and item.instanceFlags) then return end
  if W.registry[key] then removeRec(key, true) end
  local okP, pos = pcall(obj.getPosition, obj)
  if not okP or pos == nil then return end
  local id = obj.getID and obj:getID() or W.count
  W.registry[key] = { key = key, obj = obj, px = pos.x, py = pos.y, pz = pos.z, phase = (id * 2.399963) % TWO_PI }
  W.count = W.count + 1
end

function listener:onObjectDeleted(key) removeRec(key, true) end

function listener:onStreamerReset()
  W.registry, W.active, W.count, W.activeCount = {}, {}, 0, 0
end
M.listener = listener

-- ---------------------------------------------------------------------------
-- Status, lifecycle
-- ---------------------------------------------------------------------------
function M.getStatus()
  local selected, pending = 0, 0
  for i = 1, #R.mats do if R.classes[R.mats[i].class].selected then selected = selected + 1 end end
  if R.pass then pending = #R.pass.list - R.pass.cursor + 1 end
  return {
    indexState = R.indexState, indexInfo = R.indexInfo, materials = #R.mats, selected = selected,
    desired = R.desired, shown = R.shown, fading = R.fadeRate > 0 and math.abs(R.desired - R.shown) > TUNING.valueEpsilon,
    passActive = R.pass ~= nil, passTotal = R.pass and #R.pass.list or 0, passPending = pending,
    writes = R.stats.writes, writeMs = R.stats.writeMs, maxWriteMs = R.stats.maxMs, passes = R.stats.passes,
    missing = R.stats.missing, errors = R.stats.errors,
    swayEnabled = SWAY.enabled, swayRegistered = W.count, swayMoving = W.activeCount, swayPeak = W.stats.peakActive,
    swayRestored = W.stats.restored, swayErrors = W.stats.errors, swaySkipped = W.stats.skipped, swayUnavailable = W.unavailable,
  }
end

function M.setDebugLog(flag) TUNING.debugLog = flag and true or false end
function M.getDebugLog() return TUNING.debugLog end

function M.initialize(basePath)
  TUNING.levelRoot = ((basePath or TUNING.levelRoot):gsub("/+$", ""))
  R.indexState = "pending"
end

function M.onUpdate(dtReal, dtSim)
  dtReal = dtReal or 0.016
  local ok, err = pcall(updateRoughness, dtReal)
  if not ok then failOnce("roughness-update", "roughness update failed: %s", tostring(err)) end
  ok, err = pcall(updateSway, dtReal, dtSim or dtReal)
  if not ok then failOnce("sway-update", "sway update failed: %s", tostring(err)) end
end

function M.onExtensionLoaded()
  if nfsc_sectionStreamer and nfsc_sectionStreamer.addListener then nfsc_sectionStreamer.addListener(listener) end
end

function M.onExtensionUnloaded()
  if nfsc_sectionStreamer and nfsc_sectionStreamer.removeListener then nfsc_sectionStreamer.removeListener(listener) end
  releaseAll(true)
  local keys = {}
  for key in pairs(R.requests) do keys[#keys + 1] = key end
  for i = 1, #keys do R.requests[keys[i]] = nil end
  R.desired = 1.0
  R.pass = nil
  for i = 1, #R.mats do                                     -- put every written material back to baseline
    if R.mats[i].mult ~= 1.0 then pcall(writeMaterial, R.mats[i], 1.0) end
  end
end

-- The runtime state survives a Lua reload. Requests are re-created, the pass restarts from the written state.
function M.onSerialize()
  local classes, requests = {}, {}
  for name, c in pairs(R.classes) do classes[name] = c.selected end
  for source, req in pairs(R.requests) do requests[source] = { mult = req.mult, priority = req.priority, fade = req.fade } end
  return { classes = classes, requests = requests, sway = M.getSway() }
end

function M.onDeserialized(data)
  if type(data) ~= "table" then return end
  if type(data.classes) == "table" then
    for name, sel in pairs(data.classes) do R.classes[name] = R.classes[name] or { count = 0, selected = sel and true or false } end
  end
  if type(data.requests) == "table" then
    for source, req in pairs(data.requests) do M.setRoughness(source, req.mult, { priority = req.priority, fade = 0 }) end
  end
  if type(data.sway) == "table" then
    M.setSway(data.sway)
    if data.sway.enabled then SWAY.enabled = true end
  end
end

return M
