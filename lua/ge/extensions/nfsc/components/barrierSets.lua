-- nfsc level host component: barrier sets.
--
-- A mission (race) switches scenery groups on and off while it runs. This component listens to the host's
-- onMissionChanged (the engine's onAnyMissionChanged hook, forwarded), reads the groups of that mission and
-- sends them to the Section Manager through its override API. When the mission stops, it undoes exactly what
-- it did. Nothing in here is specific to one game: the data says which groups, the Section Manager knows how
-- to show and hide them.
--
-- Data of a mission, first found wins:
--   1. <mission folder>/race_groups.json
--   2. lua/components/barrierSets.json  ->  missions["<mission id>"]
-- Shape (names are group names or hex keys, the same names the Section Manager uses as override names):
--   { "gameMode": "racing",                       -- optional; "none" leaves the mode alone
--     "enable":  [ { "name": "BARRIER_SPLINE_1000", "flip": false }, "SCENERY_GROUP_CTD1" ],
--     "disable": [ "SCENERY_GROUP_CTD2" ] }
-- The component config may also hold { "dataFile": "race_groups.json", "gameMode": "racing", "flipEnabled": true, "flipAxis": "x" }
-- (defaults shown; flip on/off and the axis are also in the Level Host window).
--
-- Flip (mirrored artwork): an enable entry with "flip": true mirrors the objects of that group that carry the
-- FlipOnBackwardsTrack instance flag (and only those). The mirror is the sign of one local scale axis (flipAxis, "x" by
-- default, which is the first basis vector the game negates), derived from the object's exported scale each time and
-- undone when the group goes off, so nothing accumulates. Objects that stream in later are mirrored as they appear
-- (the host forwards the streamer's onObjectCreated); an object that is released gets its scale back first, because the
-- streamer revives parked objects without rewriting their fields.
--
-- Messenger: every change is announced with extensions.hook("onNfscBarrierSetChanged", name, enabled, flip), so
-- other systems (the collision streamer later, a mirror of flipped artwork) can follow the same event.
-- Only changes this component made are undone: a group somebody else had already switched stays as it was.
--
-- Interface of the level host (see levelHost.lua): init, onMissionChanged, getStatus, serialize/restore, shutdown.

local M = {}

local TUNING = {
  dataFile = "race_groups.json",
  gameMode = "racing",           -- Section Manager game mode while a mission with groups runs
  flipEnabled = true,            -- mirror the artwork of flipped groups
  flipAxis = "x",                -- local scale axis that changes sign: "x", "y" or "z"
  debugLog = false,
}
local AXIS_INDEX = { x = 1, y = 2, z = 3 }
local EPS = 1e-6

local ctx = nil
local cfg = {}
local active = nil               -- { id, enabled = { {name, flip} }, disabled = { name }, flipOnly = { name }, modeBefore, modeSet }
local warned = {}
local flipped = {}               -- canonical group name -> true while the group is on with flip
local registry = {}              -- streamer key -> { obj, names = { canonical names }, orig = {sx, sy, sz}, mirrored }
local byName = {}                -- canonical group name -> { key -> rec } (only objects with the flip flag)
local stats = { mirrored = 0, restored = 0, errors = 0 }

local function logMsg(level, fmt, ...)
  if level == "D" and not TUNING.debugLog then return end
  local text = select("#", ...) > 0 and string.format(fmt, ...) or fmt
  if log then log(level, "nfscBarrierSets", text) end
end

local function warnOnce(key, fmt, ...)
  if warned[key] then return end
  warned[key] = true
  logMsg("W", fmt, ...)
end

local function manager() return nfsc_sectionManager end

local function announce(name, enabled, flip)
  if extensions and extensions.hook then extensions.hook("onNfscBarrierSetChanged", name, enabled, flip and true or false) end
end

-- ---------------------------------------------------------------------------
-- Data
-- ---------------------------------------------------------------------------
local function entryOf(item)
  if type(item) == "string" then return item, false end
  if type(item) == "table" and type(item.name) == "string" then return item.name, item.flip == true end
  return nil, false
end

local function loadData(mission)
  if type(mission) ~= "table" then return nil end
  local data
  if type(mission.missionFolder) == "string" and jsonReadFile then
    data = jsonReadFile((mission.missionFolder:gsub("/+$", "")) .. "/" .. TUNING.dataFile)
  end
  if type(data) ~= "table" and mission.id ~= nil and type(cfg.missions) == "table" then data = cfg.missions[mission.id] end
  if type(data) ~= "table" then return nil end
  return data
end

-- ---------------------------------------------------------------------------
-- Flip: mirror the flagged objects of flipped groups
-- ---------------------------------------------------------------------------
local function canon(name)
  local hex = name:match("^0[xX](%x+)$")
  if hex then name = "0x" .. hex:upper() end
  local streamer = nfsc_sectionStreamer
  local alias = streamer and streamer.getOverrideAlias and streamer.getOverrideAlias()
  return alias and alias[name] or name
end

local function namesOf(value)
  local out = {}
  if type(value) ~= "string" then return out end
  for token in value:gmatch("[^,]+") do
    local name = token:match("^%s*(.-)%s*$")
    if name ~= "" then out[#out + 1] = canon(name) end
  end
  return out
end

local function hasFlipFlag(flags)
  if type(flags) ~= "string" then return false end
  return flags:lower():gsub("[^%w]", ""):find("fliponbackwardstrack", 1, true) ~= nil
end

local function parseScale(v)
  local a, b, c
  if type(v) == "string" then
    a, b, c = v:match("^%s*(%S+)%s+(%S+)%s+(%S+)")
  elseif type(v) == "table" then
    a, b, c = v[1] or v.x, v[2] or v.y, v[3] or v.z
  end
  a, b, c = tonumber(a), tonumber(b), tonumber(c)
  if a and b and c then return { a, b, c } end
  return nil
end

local function currentScale(obj)
  local ok, sc = pcall(obj.getScale, obj)
  if ok and sc and sc.x then return { sc.x, sc.y, sc.z } end
  return nil
end

local function writeScale(obj, t)
  local ok = pcall(obj.setScaleXYZ, obj, t[1], t[2], t[3])
  if not ok then
    local okF = pcall(obj.setField, obj, "scale", 0, string.format("%.9g %.9g %.9g", t[1], t[2], t[3]))
    if okF then pcall(obj.postApply, obj) end
    ok = okF
  end
  if not ok then stats.errors = stats.errors + 1; warnOnce("scale", "setting an object's scale failed; flipped artwork may stay unmirrored") end
  return ok
end

local function wantsMirror(rec)
  if not TUNING.flipEnabled then return false end
  for i = 1, #rec.names do
    if flipped[rec.names[i]] then return true end
  end
  return false
end

local function mirroredScale(rec)
  local idx = AXIS_INDEX[TUNING.flipAxis] or 1
  local t = { rec.orig[1], rec.orig[2], rec.orig[3] }
  t[idx] = -t[idx]
  return t
end

-- Brings one object to the scale it should have now: mirrored when one of its groups is flipped, else as exported.
local function settle(rec)
  local want = wantsMirror(rec)
  local target = want and mirroredScale(rec) or rec.orig
  local cur = currentScale(rec.obj)
  if cur and math.abs(cur[1] - target[1]) < EPS and math.abs(cur[2] - target[2]) < EPS and math.abs(cur[3] - target[3]) < EPS then
    rec.mirrored = want
    return
  end
  if writeScale(rec.obj, target) then
    if want and not rec.mirrored then stats.mirrored = stats.mirrored + 1
    elseif not want and rec.mirrored then stats.restored = stats.restored + 1 end
    rec.mirrored = want
  end
end

local function setGroupFlip(name, on)
  local key = canon(name)
  if (flipped[key] == true) == (on == true) then return end
  flipped[key] = on and true or nil
  local bucket = byName[key]
  if bucket then
    for _, rec in pairs(bucket) do settle(rec) end
  end
end

local function unregister(key)
  local rec = registry[key]
  if not rec then return nil end
  registry[key] = nil
  for i = 1, #rec.names do
    local bucket = byName[rec.names[i]]
    if bucket then
      bucket[key] = nil
      if next(bucket) == nil then byName[rec.names[i]] = nil end
    end
  end
  return rec
end

-- ---------------------------------------------------------------------------
-- Apply and undo
-- ---------------------------------------------------------------------------
local function undo()
  local state = active
  if not state then return end
  active = nil
  local sm = manager()
  if not sm then return end
  for i = #(state.flipOnly or {}), 1, -1 do                    -- groups that were already on and only got the flip
    setGroupFlip(state.flipOnly[i], false)
    announce(state.flipOnly[i], true, false)
  end
  for i = #state.enabled, 1, -1 do                             -- reverse order of what was done
    local e = state.enabled[i]
    if e.flip then setGroupFlip(e.name, false) end             -- the artwork gets its scale back before the group goes
    sm.setOverrideEnabled(e.name, false)
    announce(e.name, false, e.flip)
  end
  for i = #state.disabled, 1, -1 do
    local name = state.disabled[i]
    sm.setOverrideEnabled(name, true)
    announce(name, true, false)
  end
  if state.modeSet and sm.getGameMode and sm.getGameMode() == state.modeSet and state.modeBefore then
    sm.setGameMode(state.modeBefore)                           -- only when nobody changed the mode meanwhile
  end
  logMsg("D", "mission %s: groups restored", tostring(state.id))
end

local function apply(mission)
  local data = loadData(mission)
  if not data then return end
  local sm = manager()
  if not (sm and sm.setOverrideEnabled and sm.isOverrideEnabled) then
    warnOnce("noManager", "Section Manager is not available, barrier groups of %s are not applied", tostring(mission.id))
    return
  end
  if active then undo() end                                    -- a new mission starts while another still has groups on
  local state = { id = mission.id, enabled = {}, disabled = {}, flipOnly = {} }
  active = state
  for _, item in ipairs(data.enable or {}) do
    local name, flip = entryOf(item)
    if name and not sm.isOverrideEnabled(name) then
      if flip then setGroupFlip(name, true) end                -- before the objects exist: they are mirrored as they stream in
      sm.setOverrideEnabled(name, true)
      state.enabled[#state.enabled + 1] = { name = name, flip = flip }
      announce(name, true, flip)
    elseif name and flip and not flipped[canon(name)] then     -- already on by someone else: only the flip is ours
      setGroupFlip(name, true)
      state.flipOnly[#state.flipOnly + 1] = name
      announce(name, true, true)
    end
  end
  for _, item in ipairs(data.disable or {}) do
    local name = entryOf(item)
    if name and sm.isOverrideEnabled(name) then
      sm.setOverrideEnabled(name, false)
      state.disabled[#state.disabled + 1] = name
      announce(name, false, false)
    end
  end
  local mode = data.gameMode or cfg.gameMode or TUNING.gameMode
  if mode and mode ~= "none" and sm.getGameMode and sm.setGameMode then
    local before = sm.getGameMode()
    if before ~= mode and sm.setGameMode(mode) then state.modeBefore, state.modeSet = before, mode end
  end
  logMsg("I", "mission %s: %d groups enabled, %d disabled, game mode %s", tostring(mission.id), #state.enabled, #state.disabled,
    tostring(state.modeSet or "(unchanged)"))
end

-- ---------------------------------------------------------------------------
-- Host interface
-- ---------------------------------------------------------------------------
function M.init(hostCtx)
  ctx = hostCtx
  warned = {}
  local data = jsonReadFile and ctx and ctx.configPath and jsonReadFile(ctx.configPath("barrierSets"))
  cfg = type(data) == "table" and data or {}
  if type(cfg.dataFile) == "string" and cfg.dataFile ~= "" then TUNING.dataFile = cfg.dataFile end
  if type(cfg.gameMode) == "string" then TUNING.gameMode = cfg.gameMode end
  if type(cfg.flipEnabled) == "boolean" then TUNING.flipEnabled = cfg.flipEnabled end
  if type(cfg.flipAxis) == "string" and AXIS_INDEX[cfg.flipAxis:lower()] then TUNING.flipAxis = cfg.flipAxis:lower() end
end

-- state is "started" or "stopped" (the engine also sends other states; they are ignored)
function M.onMissionChanged(state, mission)
  if state == "started" then
    apply(mission)
  elseif state == "stopped" then
    if active and (type(mission) ~= "table" or mission.id == nil or mission.id == active.id) then undo() end
  end
end

function M.getStatus()
  local live, mirroredNow, groups = 0, 0, 0
  for _, rec in pairs(registry) do live = live + 1; if rec.mirrored then mirroredNow = mirroredNow + 1 end end
  for _ in pairs(flipped) do groups = groups + 1 end
  local out = { active = nil, enabled = 0, disabled = 0, flipEnabled = TUNING.flipEnabled, flipAxis = TUNING.flipAxis,
                flippable = live, mirrored = mirroredNow, flippedGroups = groups,
                mirroredTotal = stats.mirrored, restoredTotal = stats.restored, scaleErrors = stats.errors }
  if active then out.active, out.enabled, out.disabled, out.gameMode = active.id, #active.enabled, #active.disabled, active.modeSet end
  return out
end

-- Settings (the Level Host window): flip on/off and the mirrored axis. Live objects follow at once.
local function resettleAll()
  for _, rec in pairs(registry) do settle(rec) end
end

function M.setFlipEnabled(on)
  TUNING.flipEnabled = on and true or false
  resettleAll()
end

function M.setFlipAxis(axis)
  axis = type(axis) == "string" and axis:lower() or ""
  if not AXIS_INDEX[axis] then return false end
  TUNING.flipAxis = axis
  resettleAll()
  return true
end

-- The streamer's object events (forwarded by the host). Only objects with the FlipOnBackwardsTrack flag matter.
function M.onObjectCreated(key, obj, item)
  if type(item) ~= "table" or not hasFlipFlag(item.instanceFlags) then return end
  local names = namesOf(item.sectionOverrideName)
  if #names == 0 then return end
  unregister(key)
  local rec = { obj = obj, names = names, orig = parseScale(item.scale) or currentScale(obj), mirrored = false }
  if not rec.orig then return end
  registry[key] = rec
  for i = 1, #names do
    local bucket = byName[names[i]]
    if not bucket then bucket = {}; byName[names[i]] = bucket end
    bucket[key] = rec
  end
  settle(rec)                                                  -- mirrored now, or back to the exported scale when a revived object still wears the mirror
end

-- Fired before the streamer parks or deletes the object: parked objects are revived later without a field write.
function M.onObjectDeleted(key)
  local rec = registry[key]
  if not rec then return end
  if rec.mirrored then
    writeScale(rec.obj, rec.orig)
    rec.mirrored = false
    stats.restored = stats.restored + 1
  end
  unregister(key)
end

function M.onStreamerReset()
  registry, byName = {}, {}
end

function M.serialize()
  if not active then return nil end
  local groups = {}
  for name in pairs(flipped) do groups[#groups + 1] = name end
  return { active = active, flipped = groups, flipEnabled = TUNING.flipEnabled, flipAxis = TUNING.flipAxis }
end

function M.restore(data)
  if type(data) ~= "table" then return end
  local a = data.active or data                                -- older saves held the mission state itself
  if type(a) == "table" and type(a.enabled) == "table" and type(a.disabled) == "table" then
    active = a
    if type(data.active) == "table" then
      for _, name in ipairs(data.flipped or {}) do flipped[name] = true end
      if type(data.flipEnabled) == "boolean" then TUNING.flipEnabled = data.flipEnabled end
      if AXIS_INDEX[data.flipAxis or ""] then TUNING.flipAxis = data.flipAxis end
    end
  end
end

function M.shutdown()
  undo()
  resettleAll()
  ctx, cfg, active = nil, {}, nil
  flipped, registry, byName = {}, {}, {}
end

return M
