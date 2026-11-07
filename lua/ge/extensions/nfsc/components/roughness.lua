-- Level component "roughness": manual global roughness of shader-class materials.
--
-- Run by nfsc_levelHost (components/ folder, loaded with loadfile). Moved out of the environment manager with
-- the code unchanged; only the wrapper (init / onUpdate / shutdown / getStatus / serialize / restore) is new.
--
-- Every material whose name ends in a shader class (for example PAN_BLDS_LOWTOWERS_02_D_WorldReflectShader) can
-- have its roughness scaled globally. The material index is read once from the level's *materials.json files
-- (name, class, used stages, baseline roughnessFactor); nothing is polled afterwards. Requests are layered:
-- M.setRoughness(source, multiplier, {priority, fade}); the highest priority wins, the newest wins a tie, and no
-- request means baseline (x1). The panel is the only source for now. A change is written as passes over the
-- selected materials, at most maxWritesPerFrame per frame, and a fade is a series of passes. Nothing runs while
-- nothing changes.
--
-- Interface (see levelHost.lua): init(ctx), onUpdate(dtReal, dtSim), getStatus(), serialize(), restore(data),
-- shutdown(). API for the panel: setRoughness, clearRoughness, setClassSelected, getClasses, rebuildMaterialIndex,
-- probeRoughness, setDebugLog.
--
-- Flagged for in-engine verification (nothing here has run in BeamNG): Material setField with a layer index plus
-- reload()/flush(). Every engine call is wrapped in pcall; a failure is counted and logged once, never thrown.

local M = {}

local TUNING = {
  levelRoot = "levels/nfsc",
  materialFiles = "*materials.json",
  defaultClass = "WorldReflectShader",     -- selected on a fresh load
  maxWritesPerFrame = 40,                  -- materials written per frame
  minPassInterval = 0.25,                  -- seconds between the passes of a fade
  valueEpsilon = 0.0005,
  debugLog = false,
}

-- Shader classes carried by the material names (EffectId names). The name must end in "_" + class.
local KNOWN_CLASSES = {
  "WorldReflectShader", "WorldBoneShader", "WorldNormalMap", "WorldShader", "CarShader",
  "CARNORMALMAP", "GLASS_REFLECT", "WATER", "skyshader", "UCAP",
}
local ENGINE_LAYERS = 4

local R = {                                -- roughness
  mats = {}, classes = {}, classOrder = {},
  indexState = "pending",                  -- pending | ready | failed
  indexInfo = {},
  requests = {}, seq = 0,
  desired = 1.0, shown = 1.0, fadeRate = 0, lastPassAt = -100, clock = 0,
  selectionDirty = false,
  pass = nil,                              -- { value, list, cursor }
  stats = { passes = 0, writes = 0, writeMs = 0, maxMs = 0, missing = 0, errors = 0 },
}

local function logMsg(level, fmt, ...)
  if level == "D" and not TUNING.debugLog then return end
  if log then log(level, "nfsc_roughness", string.format(fmt, ...)) end
end

local loggedFailure = {}
local function failOnce(key, fmt, ...)
  if loggedFailure[key] then return end
  loggedFailure[key] = true
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
  }
end

function M.setDebugLog(flag) TUNING.debugLog = flag and true or false end
function M.getDebugLog() return TUNING.debugLog end

function M.init(ctx)
  TUNING.levelRoot = ((ctx and ctx.levelRoot or TUNING.levelRoot):gsub("/+$", ""))
  R.indexState = "pending"
  return true
end

function M.onUpdate(dtReal, dtSim)
  local ok, err = pcall(updateRoughness, dtReal or 0.016)
  if not ok then failOnce("roughness-update", "roughness update failed: %s", tostring(err)) end
end

function M.shutdown()
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
function M.serialize()
  local classes, requests = {}, {}
  for name, c in pairs(R.classes) do classes[name] = c.selected end
  for source, req in pairs(R.requests) do requests[source] = { mult = req.mult, priority = req.priority, fade = req.fade } end
  return { classes = classes, requests = requests }
end

function M.restore(data)
  if type(data) ~= "table" then return end
  if type(data.classes) == "table" then
    for name, sel in pairs(data.classes) do R.classes[name] = R.classes[name] or { count = 0, selected = sel and true or false } end
  end
  if type(data.requests) == "table" then
    for source, req in pairs(data.requests) do M.setRoughness(source, req.mult, { priority = req.priority, fade = 0 }) end
  end
end

return M
