-- Level component "sway": Lua-transform sway of Swayable objects.
--
-- Run by nfsc_levelHost (components/ folder, loaded with loadfile). Moved out of the environment manager with
-- the code unchanged; only the wrapper is new. It never creates or deletes anything.
--
-- The streamer's object events (the host registers one listener on the streamer and forwards onObjectCreated,
-- onObjectDeleted and onStreamerReset) feed a registry of live objects whose instanceFlags contain Swayable
-- (objects with IdentityMatrix or ChoppedRoadway are skipped: their origin is world zero). Only the nearest
-- maxObjects within radius metres move: a small lean about the object's own origin is composed on top of its
-- exported rotation each frame. An object that leaves that set, is released by the streamer (deleted or
-- deactivated) or when sway is switched off gets its exported position and rotation back, so a recycled shell
-- never keeps a tilted pose. Nothing runs while sway is off, nothing is registered or the simulation is paused.
--
-- Interface (see levelHost.lua): init(ctx), onObjectCreated(key, obj, item), onObjectDeleted(key),
-- onStreamerReset(), onUpdate(dtReal, dtSim), getStatus(), serialize(), restore(data), shutdown().
-- API for the panel: setSwayEnabled, isSwayEnabled, setSway, getSway.
--
-- Flagged for in-engine verification (nothing here has run in BeamNG): obj:getRotation() and
-- obj:setPosRot(x, y, z, qx, qy, qz, qw) on a TSStatic. Every engine call is wrapped in pcall; a failure is
-- counted and logged once, never thrown.

local M = {}

local TUNING = { debugLog = false }

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
local TWO_PI = math.pi * 2

local W = {                                -- sway
  registry = {}, count = 0, active = {}, activeCount = 0,
  time = 0, sinceSelect = 100,
  stats = { restored = 0, errors = 0, skipped = 0, peakActive = 0 },
  unavailable = nil,                       -- reason text once an engine call failed
}

local function logMsg(level, fmt, ...)
  if level == "D" and not TUNING.debugLog then return end
  if log then log(level, "nfsc_sway", string.format(fmt, ...)) end
end

local loggedFailure = {}
local function failOnce(key, fmt, ...)
  if loggedFailure[key] then return end
  loggedFailure[key] = true
  logMsg("E", fmt, ...)
end

local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end

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
  if on then W.unavailable = nil; loggedFailure.getRotation, loggedFailure.setPosRot = nil, nil end   -- a fresh try
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

function M.onObjectCreated(key, obj, item)
  if not hasSwayFlag(item and item.instanceFlags) then return end
  if W.registry[key] then removeRec(key, true) end
  local okP, pos = pcall(obj.getPosition, obj)
  if not okP or pos == nil then return end
  local id = obj.getID and obj:getID() or W.count
  W.registry[key] = { key = key, obj = obj, px = pos.x, py = pos.y, pz = pos.z, phase = (id * 2.399963) % TWO_PI }
  W.count = W.count + 1
end

function M.onObjectDeleted(key) removeRec(key, true) end

function M.onStreamerReset()
  W.registry, W.active, W.count, W.activeCount = {}, {}, 0, 0
end


-- ---------------------------------------------------------------------------
-- Status, lifecycle
-- ---------------------------------------------------------------------------
function M.getStatus()
  return {
    swayEnabled = SWAY.enabled, swayRegistered = W.count, swayMoving = W.activeCount, swayPeak = W.stats.peakActive,
    swayRestored = W.stats.restored, swayErrors = W.stats.errors, swaySkipped = W.stats.skipped, swayUnavailable = W.unavailable,
  }
end

function M.setDebugLog(flag) TUNING.debugLog = flag and true or false end
function M.getDebugLog() return TUNING.debugLog end

function M.init(ctx)
  return true                                                -- the registry fills from the streamer's events
end

function M.onUpdate(dtReal, dtSim)
  dtReal = dtReal or 0.016
  local ok, err = pcall(updateSway, dtReal, dtSim or dtReal)
  if not ok then failOnce("sway-update", "sway update failed: %s", tostring(err)) end
end

function M.shutdown()
  releaseAll(true)
end

function M.serialize()
  return { sway = M.getSway() }
end

function M.restore(data)
  if type(data) ~= "table" or type(data.sway) ~= "table" then return end
  M.setSway(data.sway)
  if data.sway.enabled then SWAY.enabled = true end
end

return M
