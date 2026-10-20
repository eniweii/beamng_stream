-- nfsc_sectionManager: Section Manager (section status, flags and override controls).
--
-- The manager decides what is VISIBLE. It never creates or deletes streamed scenery; that is
-- nfsc_sectionStreamer. Interface:
--   from the streamer (listener):  onObjectCreated(key, obj, item), onObjectDeleted(key), onStreamerReset()
--   from the streamer (hook):      onNfscStreamerInitialized(), onNfscSectionChanged(new, old)
--   to everyone (hook):            onNfscOverrideChanged(name, enabled), onNfscSceneClassChanged(kind, on)
--
-- Streamed TSStatic rules (modelled on hyperlinked's draw_a_scenery gate, see docs/FIDELITY.md):
--   * ExcludeMainView                      -> never drawn in the main view
--   * ExcludeFreeroam / ExcludeRacing      -> hidden in that game mode (radio, default freeroam)
--   * LowPlatformOnly / HighPlatformOnly   -> hidden on the other platform (radio, default high);
--                                             EnvmapShadow exempts LowPlatformOnly like the game
--   * ExcludeGroupDisable                  -> the object starts as a disabled group member:
--                                             visible only while one of its override names is enabled
--   * ExcludeDisableRendering              -> NOT hidden: the object is drawn and exempt from the
--                                             game's distance disabling (metadata here)
--   * sectionOverrideName (comma separated) -> visible only while at least one name is enabled
-- Every other flag is parsed and counted but changes nothing here (see FLAGS).
--
-- Creation filter: the manager registers itself with the streamer, so an object whose
-- sectionOverrideName has no enabled name is not even created. Enabling a name makes the streamer
-- create the held-back objects; disabling it releases the live ones again.
--
-- Scene objects (ParticleEmitterNode, lights) are not streamed. They are switched by section
-- residency + their override names + one On/Off radio per class; emitters also hide beyond their
-- own farClip.
--
-- The enabled set, radios and modes exist only at runtime and survive a Lua reload (onSerialize).

local M = {}
M.dependencies = { "nfsc_sectionStreamer" }

-- ---------------------------------------------------------------------------
-- Tuning
-- ---------------------------------------------------------------------------
local ALWAYS_ON_OVERRIDES = {}          -- override names enabled on a fresh load
local TUNING = {
  honorGroupDisableFlags = true,        -- ExcludeGroupDisable starts the object hidden
  emitterFarClipScale = 1.0,
  emitterHysteresis = 0.05,             -- shown again only inside farClip * (1 - this)
  emitterCheckInterval = 0.25,
}

-- ---------------------------------------------------------------------------
-- Flags. Exported names are normalized (lower case, letters and digits only) before lookup.
-- role: gate = acts in this manager; baked = already in the exported transform/data;
--       metadata = parsed and counted only.
-- ---------------------------------------------------------------------------
local FLAGS = {
  { "ExcludeSplitScreen", "metadata", "split screen does not exist in BeamNG" },
  { "ExcludeMainView", "gate", "never drawn in the main view" },
  { "ExcludeRacing", "gate", "hidden in racing mode" },
  { "ExcludeDisableRendering", "metadata", "drawn and exempt from distance disabling, never hidden" },
  { "ExcludeGroupDisable", "gate", "group-disabled baseline" },
  { "ExcludeFreeroam", "gate", "hidden in freeroam mode" },
  { "IncludeRearView", "metadata", "rear-view mirror inclusion; no per-view include in BeamNG" },
  { "IncludeReflection", "metadata", "reflection inclusion; no per-view include in BeamNG" },
  { "EnvmapShadow", "gate", "exempts LowPlatformOnly; otherwise shadow/envmap view flag" },
  { "ChoppedRoadway", "metadata", "reflection LOD detail" },
  { "IdentityMatrix", "baked", "position baked into vertex data, node matrix is identity" },
  { "ArtworkFlipped", "metadata", "group flip state; transforms are never changed at runtime" },
  { "Reflection", "metadata", "view flag" },
  { "EnvironmentMap", "metadata", "view flag" },
  { "Swayable", "metadata", "wind sway; not implemented" },
  { "EnableWind", "metadata", "wind view flag" },
  { "AlwaysFacing", "metadata", "billboard; not implemented" },
  { "DontReceiveShadows", "metadata", "shadow option" },
  { "LowPlatformOnly", "gate", "hidden on the high platform" },
  { "HighPlatformOnly", "gate", "hidden on the low platform" },
  { "CastShadowVolume", "metadata", "shadow option" },
  { "CastShadowMap", "metadata", "shadow option" },
  { "InvertedMatrix", "baked", "mirrored matrix; the exported negative scale already carries it" },
  { "FlipOnBackwardsTrack", "metadata", "track direction flip; not implemented" },
  { "ReflectInOcean", "metadata", "reflection option" },
  { "VisibleFurther", "metadata", "draw distance bias; not implemented" },
  { "CastShadowMapMesh", "metadata", "shadow option" },
  { "IncludeReflectionNG", "metadata", "reflection inclusion; no per-view include in BeamNG" },
  { "AuxLighting", "metadata", "lighting option" },
  { "PCPlatform", "metadata", "no use found in the game's culling" },
  { "Collidable", "metadata", "smackable group membership, NOT world collision" },
  { "Lightmapped", "metadata", "lighting option" },
}
M.FLAGS = FLAGS

local flagRole = {}
local function normalizeFlag(name) return (tostring(name):lower():gsub("[^%w]", "")) end
for _, f in ipairs(FLAGS) do flagRole[normalizeFlag(f[1])] = f[2] end

local GATE_FLAGS = {}
for key, role in pairs(flagRole) do if role == "gate" then GATE_FLAGS[key] = true end end

local unknownFlags, unknownCount = {}, 0
local flagCounts = {}

-- Returns set (normalized name -> true) and the number of unknown tokens.
function M.parseFlags(value)
  local set, unknown = {}, 0
  if type(value) ~= "string" then return set, unknown end
  for token in value:gmatch("[^,|%s]+") do
    local key = normalizeFlag(token)
    if key ~= "" then
      set[key] = true
      if not flagRole[key] then unknown = unknown + 1 end
    end
  end
  return set, unknown
end

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
local enabled = {}                       -- override name -> true
local gameMode, platform = "freeroam", "high"
local sceneClassOn = { emitters = true, lights = true }

local overrideSections = {}              -- name -> { [sectionID] = true }
local tracked = {}                       -- streamed key -> { objId, names, flags }
local byOverride = {}                    -- name -> { [key] = true }
local trackedCount = 0
local sortedCache, sortedDirty = {}, true
local listener = {}

local sceneBySection, sceneByOverride, sceneRecs = {}, {}, {}
local lastActive = {}
local activeFarRecs = {}
local farTimer = 0

for _, name in ipairs(ALWAYS_ON_OVERRIDES) do enabled[name] = true end

local function streamer() return nfsc_sectionStreamer end

local function splitNames(value)
  local out = {}
  if type(value) ~= "string" then return out end
  for token in value:gmatch("[^,]+") do
    local name = token:match("^%s*(.-)%s*$")
    if name ~= "" then out[#out + 1] = name end
  end
  return out
end

local function isAllowed(names)
  for i = 1, #names do
    if enabled[names[i]] then return true end
  end
  return false
end

-- Streamer create filter: an object with override names exists only while one of them is enabled.
local function creationAllowed(item)
  local value = item.sectionOverrideName
  if type(value) ~= "string" or value == "" then return true end
  return isAllowed(splitNames(value))
end

-- ---------------------------------------------------------------------------
-- Streamed TSStatic visibility
-- ---------------------------------------------------------------------------
local function baselineAllowed(f)
  if f.excludemainview then return false end
  if gameMode == "freeroam" and f.excludefreeroam then return false end
  if gameMode == "racing" and f.excluderacing then return false end
  if platform == "high" and f.lowplatformonly and not f.envmapshadow then return false end
  if platform == "low" and f.highplatformonly then return false end
  return true
end

local function streamedVisible(rec)
  if not baselineAllowed(rec.flags) then return false end
  if #rec.names > 0 then return isAllowed(rec.names) end
  if TUNING.honorGroupDisableFlags and rec.flags.excludegroupdisable then
    return false
  end
  return true
end

local function applyStreamed(rec)
  local obj = scenetree.findObjectById(rec.objId)
  if obj then obj.hidden = not streamedVisible(rec) end
end

local function noteOverrideSections(name, ids)
  local set = overrideSections[name]
  if not set then set = {}; overrideSections[name] = set; sortedDirty = true end
  for _, id in ipairs(ids or {}) do set[tonumber(id) or id] = true end
end

local function loadOverrideIndex()
  local s = streamer()
  if not s or not s.getOverrideIndex then return end
  for name, ids in pairs(s.getOverrideIndex()) do noteOverrideSections(name, ids) end
  sortedDirty = true
end

function listener:onObjectCreated(key, obj, item)
  local all, unknown = M.parseFlags(item.instanceFlags)
  if unknown > 0 then
    for token in tostring(item.instanceFlags):gmatch("[^,|%s]+") do
      local k = normalizeFlag(token)
      if not flagRole[k] and not unknownFlags[k] then unknownFlags[k] = true; unknownCount = unknownCount + 1 end
    end
  end
  local gate = {}
  local any = false
  for k in pairs(all) do
    flagCounts[k] = (flagCounts[k] or 0) + 1
    if GATE_FLAGS[k] then gate[k] = true; any = true end
  end
  local names = splitNames(item.sectionOverrideName)
  if #names == 0 and not any then return end          -- nothing to manage for this object
  local rec = { objId = obj:getID(), names = names, flags = gate, item = #names > 0 and item or nil }
  tracked[key] = rec
  trackedCount = trackedCount + 1
  for i = 1, #names do
    local bucket = byOverride[names[i]]
    if not bucket then bucket = {}; byOverride[names[i]] = bucket end
    bucket[key] = true
    noteOverrideSections(names[i], item.__streamSections)
  end
  applyStreamed(rec)          -- before the first render: never visible-then-hidden
end

function listener:onObjectDeleted(key)
  local rec = tracked[key]
  if not rec then return end
  tracked[key] = nil
  trackedCount = trackedCount - 1
  for i = 1, #rec.names do
    local bucket = byOverride[rec.names[i]]
    if bucket then bucket[key] = nil end
  end
end

function listener:onStreamerReset()
  tracked, byOverride, trackedCount = {}, {}, 0
end
M.listener = listener

-- ---------------------------------------------------------------------------
-- Scene objects: emitters and lights
-- ---------------------------------------------------------------------------
local function isLight(obj)
  return obj:isSubClassOf("PointLight") or obj:isSubClassOf("SpotLight") or obj:isSubClassOf("LightBase")
end

local function anySectionActive(ids)
  local s = streamer()
  if not s then return false end
  for i = 1, #ids do
    if s.isSectionActive(ids[i]) then return true end
  end
  return false
end

local function cameraPos()
  return core_camera and core_camera.getPosition and core_camera.getPosition()
end

local function updateFar(rec, cam)
  if not rec.farSq or not cam then return end
  local dx, dy, dz = cam.x - rec.bx, cam.y - rec.by, cam.z - rec.bz
  local d2 = dx * dx + dy * dy + dz * dz
  if rec.far then
    if d2 < rec.nearSq then rec.far = false end
  elseif d2 > rec.farSq then
    rec.far = true
  end
end

local function sceneVisible(rec)
  if not sceneClassOn[rec.kind] then return false end
  if not anySectionActive(rec.sections) then return false end
  if #rec.names > 0 and not isAllowed(rec.names) then return false end
  if rec.far then return false end
  return true
end

local function applyScene(rec)
  local visible = sceneVisible(rec)
  if rec.shown == visible then return end
  rec.shown = visible
  local obj = scenetree.findObjectById(rec.id)
  if not obj then return end
  if rec.kind == "lights" then
    obj.isEnabled = visible
  else
    local ok = pcall(obj.setActive, obj, visible)
    if not ok then obj.active = visible end
  end
end

local function rebuildActiveFarRecs()
  activeFarRecs = {}
  local seen = {}
  for id in pairs(lastActive) do
    for _, rec in ipairs(sceneBySection[id] or {}) do
      if rec.farSq and not seen[rec] then seen[rec] = true; activeFarRecs[#activeFarRecs + 1] = rec end
    end
  end
end

local function syncActiveSections()
  local s = streamer()
  local newSet = {}
  if s then for _, id in ipairs(s.getActiveSections()) do newSet[id] = true end end
  local cam = cameraPos()
  for id in pairs(newSet) do
    if not lastActive[id] then
      for _, rec in ipairs(sceneBySection[id] or {}) do updateFar(rec, cam); applyScene(rec) end
    end
  end
  for id in pairs(lastActive) do
    if not newSet[id] then
      for _, rec in ipairs(sceneBySection[id] or {}) do applyScene(rec) end
    end
  end
  lastActive = newSet
  rebuildActiveFarRecs()
end

function M.rescanScene()
  sceneBySection, sceneByOverride, sceneRecs = {}, {}, {}
  lastActive = {}
  activeFarRecs = {}
  local names = scenetree:getAllObjects()
  if names then
    for _, name in pairs(names) do
      local obj = scenetree.findObject(name)
      local sectionID = obj and obj.sectionID
      if sectionID and sectionID ~= "" then
        local kind = obj:isSubClassOf("ParticleEmitterNode") and "emitters" or (isLight(obj) and "lights" or nil)
        if kind then
          local ids = {}
          for token in tostring(sectionID):gmatch("[^,%s]+") do
            local n = tonumber(token)
            if n then ids[#ids + 1] = n end
          end
          local rec = { id = obj:getID(), kind = kind, sections = ids, names = splitNames(obj.sectionOverrideName) }
          if kind == "emitters" then
            local farClip = tonumber(obj.farClip)
            if farClip and farClip > 0 then
              -- volume twins move every frame, so measure from the box centre (volBase)
              local bx, by, bz = tostring(obj.volBase or ""):match("^%s*(%S+)%s+(%S+)%s+(%S+)")
              bx, by, bz = tonumber(bx), tonumber(by), tonumber(bz)
              if not (bx and by and bz) then
                local p = obj:getPosition()
                bx, by, bz = p.x, p.y, p.z
              end
              local far = farClip * TUNING.emitterFarClipScale
              local near = far * (1 - TUNING.emitterHysteresis)
              rec.bx, rec.by, rec.bz, rec.farSq, rec.nearSq = bx, by, bz, far * far, near * near
            end
          end
          sceneRecs[#sceneRecs + 1] = rec
          for _, id in ipairs(ids) do
            local list = sceneBySection[id]
            if not list then list = {}; sceneBySection[id] = list end
            list[#list + 1] = rec
          end
          for _, n in ipairs(rec.names) do
            local set = sceneByOverride[n]
            if not set then set = {}; sceneByOverride[n] = set end
            set[rec] = true
            noteOverrideSections(n, ids)
          end
        end
      end
    end
  end
  syncActiveSections()
  for _, rec in ipairs(sceneRecs) do applyScene(rec) end   -- everything off until a section is active
end

function M.getSceneStatus()
  local counts = { emitters = 0, lights = 0, shown = 0 }
  for _, rec in ipairs(sceneRecs) do
    counts[rec.kind] = counts[rec.kind] + 1
    if rec.shown then counts.shown = counts.shown + 1 end
  end
  return counts
end

function M.setSceneClassEnabled(kind, on)
  if sceneClassOn[kind] == nil then return false end
  on = on and true or false
  if sceneClassOn[kind] == on then return true end
  sceneClassOn[kind] = on
  for _, rec in ipairs(sceneRecs) do
    if rec.kind == kind then applyScene(rec) end
  end
  if extensions and extensions.hook then extensions.hook("onNfscSceneClassChanged", kind, on) end
  return true
end

function M.isSceneClassEnabled(kind) return sceneClassOn[kind] == true end

-- ---------------------------------------------------------------------------
-- Overrides, mode, platform
-- ---------------------------------------------------------------------------
function M.setOverrideEnabled(name, on)
  local was = enabled[name] == true
  local now = on and true or false
  if was == now then return end
  enabled[name] = now and true or nil
  for key in pairs(byOverride[name] or {}) do applyStreamed(tracked[key]) end
  for rec in pairs(sceneByOverride[name] or {}) do applyScene(rec) end
  local s = streamer()
  if s then
    if now then
      if s.refreshFilter then s.refreshFilter() end          -- create what was held back
    elseif s.releaseObject then
      for key in pairs(byOverride[name] or {}) do             -- delete what no name keeps alive
        local rec = tracked[key]
        if rec and not isAllowed(rec.names) then s.releaseObject(key, rec.item) end
      end
    end
  end
  if extensions and extensions.hook then extensions.hook("onNfscOverrideChanged", name, now) end
end

function M.isOverrideEnabled(name) return enabled[name] == true end

local function reapplyAllStreamed()
  for _, rec in pairs(tracked) do applyStreamed(rec) end
end

function M.setGameMode(mode)
  if mode ~= "freeroam" and mode ~= "racing" then return false end
  if gameMode ~= mode then gameMode = mode; reapplyAllStreamed() end
  return true
end
function M.getGameMode() return gameMode end

function M.setPlatform(p)
  if p ~= "high" and p ~= "low" then return false end
  if platform ~= p then platform = p; reapplyAllStreamed() end
  return true
end
function M.getPlatform() return platform end

function M.setTuning(values)
  for k, v in pairs(values or {}) do
    if TUNING[k] ~= nil then TUNING[k] = v end
  end
  reapplyAllStreamed()
end

function M.getCurrentSectionID()
  local s = streamer()
  return s and s.getCurrentSectionID() or nil
end

-- Nearest first: 0 = used in the current section, 1 = in a related section, 2 = elsewhere.
local function proximityRank(name)
  local set = overrideSections[name]
  local s = streamer()
  local current = s and s.getCurrentSectionID()
  if not set or not current then return 2 end
  if set[current] then return 0 end
  for _, rel in ipairs(s.getRelatedSections(current)) do
    if set[rel] then return 1 end
  end
  return 2
end

function M.getOverrideNames()
  if sortedDirty then
    sortedCache = {}
    for name in pairs(overrideSections) do sortedCache[#sortedCache + 1] = name end
    local rank = {}
    for _, name in ipairs(sortedCache) do rank[name] = proximityRank(name) end
    table.sort(sortedCache, function(a, b)
      if rank[a] ~= rank[b] then return rank[a] < rank[b] end
      return a < b
    end)
    sortedDirty = false
  end
  return sortedCache
end

function M.getOverrideSections(name)
  local out = {}
  for id in pairs(overrideSections[name] or {}) do out[#out + 1] = id end
  table.sort(out)
  return out
end

function M.getFlagCounts() return flagCounts end
function M.getUnknownFlags()
  local out = {}
  for k in pairs(unknownFlags) do out[#out + 1] = k end
  table.sort(out)
  return out
end

function M.getStatus()
  local s = streamer()
  local status = s and s.getStatus() or {}
  local on = 0
  for _ in pairs(enabled) do on = on + 1 end
  status.overridesKnown = #M.getOverrideNames()
  status.overridesEnabled = on
  status.managedObjectsLive = trackedCount
  status.overrideObjectsLive = trackedCount        -- kept for the older panel field name
  status.gameMode, status.platform = gameMode, platform
  status.unknownFlagCount = unknownCount
  local scene = M.getSceneStatus()
  status.sceneEmitters, status.sceneLights, status.sceneShown = scene.emitters, scene.lights, scene.shown
  status.emittersOn, status.lightsOn = sceneClassOn.emitters, sceneClassOn.lights
  return status
end

-- ---------------------------------------------------------------------------
-- Hooks and lifecycle
-- ---------------------------------------------------------------------------
function M.onNfscStreamerInitialized()
  loadOverrideIndex()
  M.rescanScene()
end

function M.onNfscSectionChanged(newID, oldID)
  sortedDirty = true
  syncActiveSections()
end

function M.onUpdate(dtReal)
  farTimer = farTimer + (dtReal or 0)
  if farTimer < TUNING.emitterCheckInterval then return end
  farTimer = 0
  if #activeFarRecs == 0 then return end
  local cam = cameraPos()
  if not cam then return end
  for i = 1, #activeFarRecs do
    local rec = activeFarRecs[i]
    local before = rec.far
    updateFar(rec, cam)
    if rec.far ~= before then applyScene(rec) end
  end
end

function M.onExtensionLoaded()
  local s = streamer()
  if s then
    s.addListener(listener)
    if s.setCreateFilter then s.setCreateFilter(creationAllowed) end
    loadOverrideIndex()
  end
end

function M.onExtensionUnloaded()
  local s = streamer()
  if s then
    s.removeListener(listener)
    if s.setCreateFilter then s.setCreateFilter(nil) end
  end
end

function M.onSerialize()
  local names = {}
  for name in pairs(enabled) do names[#names + 1] = name end
  table.sort(names)
  return { enabled = names, gameMode = gameMode, platform = platform,
           emitters = sceneClassOn.emitters, lights = sceneClassOn.lights }
end

function M.onDeserialized(data)
  if type(data) ~= "table" then return end
  if type(data.enabled) == "table" then
    enabled = {}
    for _, name in ipairs(data.enabled) do enabled[name] = true end
    local s = streamer()
    if s and s.refreshFilter then s.refreshFilter() end
  end
  if data.gameMode == "freeroam" or data.gameMode == "racing" then gameMode = data.gameMode end
  if data.platform == "high" or data.platform == "low" then platform = data.platform end
  if type(data.emitters) == "boolean" then sceneClassOn.emitters = data.emitters end
  if type(data.lights) == "boolean" then sceneClassOn.lights = data.lights end
end

return M
