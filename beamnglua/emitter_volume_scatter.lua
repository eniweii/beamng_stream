-- Volume emitter scatter for the Carbon -> BeamNG particle port.
-- Carbon spawns every particle at its own random point inside the layer's
-- VolumeExtent box (EmitterSystem: vol_center + random(extent) - extent/2,
-- then rotated by the emitter matrix). BeamNG emitters have no box, so
-- build_beamng_particles.py writes several ParticleEmitterNode twins per
-- volume layer and this module moves each one to a new random point in the
-- box every frame.
--
-- Node dynamic fields (all strings, written by the builder):
--   volExtent = "ex ey ez"                 full box side lengths (local axes)
--   volAxes   = "r0x r0y r0z r1x .. r2z"   local axes in world space (rows)
--   volBase   = "x y z"                    box center in world space
--
-- Same wiring pattern as tsstatic_section_streaming.lua: load with loadfile,
-- call initialize() once after level load, forward onUpdate every frame.

local M = {}

-- TWEAKS
local enabled = true
local maxDistance = 250        -- world units from the camera; farther nodes stay put
local maxUpdatesPerFrame = 400 -- cost cap; nodes are served round-robin
local nodeClass = "ParticleEmitterNode"

-- DATA, DON'T TOUCH
local nodes = {}               -- {id, ex, ey, ez, ax = {9}, bx, by, bz}
local cursor = 1
local selfCheckDone = false
local broken = false           -- true once a setPosition call has failed

local function parseFloats(str, count)
  if type(str) ~= "string" or str == "" then return nil end
  local out = {}
  for token in string.gmatch(str, "%S+") do
    local v = tonumber(token)
    if not v then return nil end
    out[#out + 1] = v
  end
  if #out ~= count then return nil end
  return out
end

-- Rescans the scene by the volExtent field (not cached IDs, which go stale
-- across restarts). Nodes moved by an earlier run restart from volBase.
local function scanNodes()
  nodes = {}
  cursor = 1
  local all = scenetree:getAllObjects()
  if not all then return end

  for _, name in pairs(all) do
    local object = scenetree.findObject(name)
    if object and object:isSubClassOf(nodeClass) and object.volExtent and object.volExtent ~= "" then
      local ext = parseFloats(object.volExtent, 3)
      local axes = parseFloats(object.volAxes, 9)
      local base = parseFloats(object.volBase, 3)
      if ext and axes and base then
        nodes[#nodes + 1] = {
          id = object:getID(),
          ex = ext[1], ey = ext[2], ez = ext[3],
          ax = axes,
          bx = base[1], by = base[2], bz = base[3],
        }
      else
        print("[volumeScatter] bad volume fields on " .. tostring(name))
      end
    end
  end
  print(string.format("[volumeScatter] found %d volume emitter nodes", #nodes))
end

-- One new random point: base + (rx-0.5)*ex*row0 + (ry-0.5)*ey*row1 + (rz-0.5)*ez*row2
local function randomPoint(n)
  local a = (math.random() - 0.5) * n.ex
  local b = (math.random() - 0.5) * n.ey
  local c = (math.random() - 0.5) * n.ez
  local r = n.ax
  return n.bx + a * r[1] + b * r[4] + c * r[7],
         n.by + a * r[2] + b * r[5] + c * r[8],
         n.bz + a * r[3] + b * r[6] + c * r[9]
end

local function moveNode(n)
  local object = scenetree.findObjectById(n.id)
  if not object or object.hidden then return true end
  local x, y, z = randomPoint(n)
  return pcall(function() object:setPosition(vec3(x, y, z)) end)
end

-- Tries one move on the first node and reports. If setPosition does not work
-- on ParticleEmitterNode in this build, the module switches itself off.
local function selfCheck()
  selfCheckDone = true
  local n = nodes[1]
  if not n then return end
  local ok, err = moveNode(n)
  if ok then
    print("[volumeScatter] self-check ok: setPosition works on " .. nodeClass)
  else
    broken = true
    print("[volumeScatter] self-check FAILED, module disabled: " .. tostring(err))
  end
end

local function initialize()
  math.randomseed(os.time())
  selfCheckDone = false
  broken = false
  scanNodes()
end

local function onUpdate(dtReal, dtSim, dtRaw)
  if not enabled or broken or #nodes == 0 then return end
  if not selfCheckDone then selfCheck() end
  if broken then return end

  local cam = core_camera.getPosition()
  if not cam then return end
  local maxD2 = maxDistance * maxDistance

  local count = #nodes
  local budget = math.min(maxUpdatesPerFrame, count)
  for _ = 1, budget do
    if cursor > count then cursor = 1 end
    local n = nodes[cursor]
    cursor = cursor + 1
    local dx, dy, dz = n.bx - cam.x, n.by - cam.y, n.bz - cam.z
    if dx * dx + dy * dy + dz * dz <= maxD2 then
      local ok = moveNode(n)
      if not ok then
        broken = true
        print("[volumeScatter] setPosition failed, module disabled")
        return
      end
    end
  end
end

local function setEnabled(value) enabled = value and true or false end
local function isEnabled() return enabled end
local function getNodeCount() return #nodes end

M.initialize = initialize
M.onUpdate = onUpdate
M.setEnabled = setEnabled
M.isEnabled = isEnabled
M.getNodeCount = getNodeCount

return M
