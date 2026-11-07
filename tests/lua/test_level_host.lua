-- Offline tests for nfsc_levelHost and its soundZones component. Run with: python tests/run_lua_tests_lupa.py --host
-- arg[1] = repo root
local repo = arg[1]
package.path = repo .. "/tests/lua/?.lua;" .. package.path
local H = dofile(repo .. "/tests/lua/harness.lua")

local passed, failed = 0, 0
local function check(name, cond, extra)
  if cond then passed = passed + 1 else failed = failed + 1; print("FAIL: " .. name .. (extra and (" (" .. tostring(extra) .. ")") or "")) end
end

local ZONES = "levels/nfsc/lua/zones.json"
local SZ_CONFIG = "levels/nfsc/lua/components/soundZones.json"
local HOST_CONFIG = "levels/nfsc/lua/components/host.json"

local realLoadfile = loadfile
local function fresh(zones, extraFiles)
  H.install(repo)
  H.files = {}
  H.files[ZONES] = zones and { zones = zones } or nil
  for path, data in pairs(extraFiles or {}) do H.files[path] = data end
  loadfile = function(path)                                      -- the host loads components by their game path
    local game = path:match("^/lua/ge/extensions/nfsc/components/(.+)$")
    return realLoadfile(game and (repo .. "/lua/ge/extensions/nfsc/components/" .. game) or path)
  end
  return dofile(repo .. "/lua/ge/extensions/nfsc/levelHost.lua")
end

local function spaces()
  local g = H.byName("nfsc_sound_zones")
  local out = {}
  if g then for _, c in ipairs(g.children) do out[#out + 1] = c end end
  return out
end
local function nums(text)
  local t = {}
  for n in tostring(text):gmatch("%-?[%d%.]+") do t[#t + 1] = tonumber(n) end
  return t
end

local TUNNEL = { id = 7, type = 3, typeName = "TUNNEL", elevation = 0, points = { { 0, 0 }, { 100, 0 }, { 100, 20 }, { 0, 20 } } }
local PREDICT = { id = 9, type = 6, elevation = 0, points = { { 50, -10 }, { 150, -10 }, { 150, 10 }, { 50, 10 } } }
local LOW = { id = 11, type = 6, typeName = "STREAMER_PREDICTION", elevation = -32, points = { { 200, 0 }, { 300, 0 }, { 300, 50 }, { 200, 50 } } }

-- 1. the host starts the sound zones component with the zone list it read once
do
  local host = fresh({ TUNNEL })
  host.initialize("levels/nfsc")
  local st = host.getStatus()
  check("five components in order", #st.components == 5 and st.components[1].name == "soundZones" and st.components[2].name == "volumeScatter"
    and st.components[3].name == "roughness" and st.components[4].name == "sway" and st.components[5].name == "textureAnimation")
  check("component running", st.components[1].ok == true, st.components[1].err)
  check("scatter running without nodes", st.components[2].ok == true and st.components[2].status.nodes == 0, st.components[2].err)
  check("component status passed on", st.components[1].status and st.components[1].status.boxes == 1)
  check("one space built", #spaces() == 1, #spaces())
  check("zones counted", st.zones.loaded and st.zones.count == 1 and st.zones.usable == 1)
  check("shared offset 150", st.zOffset == 150)
  if spaces()[1] then
    local p = nums(spaces()[1].fields.position)
    check("space centre height uses the offset", math.abs(p[3] - 900) < 1e-3, spaces()[1].fields.position)
  end
end

-- 2. the shared height offset comes from the host config
do
  local host = fresh({ TUNNEL }, { [HOST_CONFIG] = { zOffset = 100 } })
  host.initialize("levels/nfsc")
  check("host.json offset", host.getStatus().zOffset == 100)
  if spaces()[1] then
    local p = nums(spaces()[1].fields.position)
    check("space follows the host offset", math.abs(p[3] - 850) < 1e-3, spaces()[1].fields.position)
  end
end

-- 3. the component's own config: zone off, role replaced
do
  local host = fresh({ TUNNEL, { id = 8, type = 7, typeName = "GARAGE", points = { { 0, 100 }, { 40, 100 }, { 40, 130 }, { 0, 130 } } } },
    { [SZ_CONFIG] = { zones = { ["7"] = false }, roles = { GARAGE = "Level_Tunnel_Open" } } })
  host.initialize("levels/nfsc")
  local s = spaces()
  check("switched-off zone has no space, garage has one", #s == 1, #s)
  check("role replaced", s[1] and s[1].fields.soundAmbience == "Level_Tunnel_Open")
  local sz = host.getComponent("soundZones")
  check("describeZone off", sz.describeZone(7) == "sound off")
  check("describeZone ambience", sz.describeZone(8) == "Level_Tunnel_Open")
  check("describeZone unknown", sz.describeZone(99) == nil)
end

-- 4. which zones the camera is in
do
  local host = fresh({ TUNNEL, PREDICT, LOW })
  host.initialize("levels/nfsc")
  H.cam = { x = 70, y = 5, z = 150 }
  host.onUpdate(0.3, 0.3)
  local cur = host.getCurrentZones()
  check("two zones overlap here", #cur == 2, #cur)
  check("tunnel with its ambience", host.describeCurrentZones():find("TUNNEL #7 (Level_Tunnel_Closed)", 1, true) ~= nil, host.describeCurrentZones())
  check("zone without a component role", host.describeCurrentZones():find("STREAMER_PREDICTION #9", 1, true) ~= nil, host.describeCurrentZones())

  H.cam = { x = 500, y = 500, z = 150 }
  host.onUpdate(0.3, 0.3)
  check("outside every zone", host.describeCurrentZones() == "none" and #host.getCurrentZones() == 0)

  H.cam = { x = 250, y = 20, z = 150 + 10 }                      -- game z 10 <= 32: the gate is open
  host.onUpdate(0.3, 0.3)
  check("negative elevation gate open below", #host.getCurrentZones() == 1)
  H.cam = { x = 250, y = 20, z = 150 + 100 }                     -- game z 100 > 32: closed
  host.onUpdate(0.3, 0.3)
  check("negative elevation gate closed above", #host.getCurrentZones() == 0)

  H.cam = { x = 70, y = 5, z = 150 }
  host.onUpdate(0.05, 0.05)                                       -- inside the lookup interval: unchanged
  check("lookup is throttled", #host.getCurrentZones() == 0)
end

-- 5. a missing zones file does not break anything
do
  local host = fresh(nil)
  host.initialize("levels/nfsc")
  local st = host.getStatus()
  check("not loaded reported", st.zones.loaded == false and st.zones.error ~= nil)
  check("no spaces", #spaces() == 0)
  check("describe says so", host.describeCurrentZones() == "zones not loaded")
  host.onUpdate(0.3, 0.3)
  host.onNfscSectionChanged(1021, nil)                            -- forwarding with a component that has no handler is fine
  check("still alive", true)
end

-- 6. unloading the host removes the spaces and clears the zones
do
  local host = fresh({ TUNNEL })
  host.initialize("levels/nfsc")
  check("built before unload", #spaces() == 1)
  host.onExtensionUnloaded()
  check("spaces removed", #spaces() == 0, #spaces())
  check("no zone text after unload", host.describeCurrentZones() == "zones not loaded" or host.describeCurrentZones() == "none")
end

-- 7. volume scatter: finds the twins by their fields, moves them inside their box, leaves far ones alone
do
  vec3 = function(x, y, z) return { x = x, y = y, z = z } end
  local host = fresh({ TUNNEL })
  local function twin(name, base)
    local o = H.addSceneObject({ class = "ParticleEmitterNode", name = name })
    o.volExtent = "10 4 2"
    o.volAxes = "1 0 0 0 1 0 0 0 1"
    o.volBase = base
    o.moves = 0
    function o:setPosition(v) self.moves = self.moves + 1; self.pos = v end
    return o
  end
  local near_, far_ = twin("vs_near", "10 10 5"), twin("vs_far", "900 900 5")
  H.addSceneObject({ class = "ParticleEmitterNode", name = "vs_plain" })   -- no volume fields: ignored
  local broken = H.addSceneObject({ class = "ParticleEmitterNode", name = "vs_bad" })
  broken.volExtent, broken.volAxes, broken.volBase = "10 4", "1 0 0 0 1 0 0 0 1", "0 0 0"
  H.cam = { x = 0, y = 0, z = 0 }
  host.initialize("levels/nfsc")
  local vs = host.getComponent("volumeScatter")
  local st = vs.getStatus()
  check("two valid twins found", st.nodes == 2, st.nodes)
  check("defaults reported", st.enabled == true and st.maxDistance == 250 and st.maxUpdatesPerFrame == 400 and st.broken == false)

  for _ = 1, 5 do host.onUpdate(0.016, 0.016) end
  check("near twin moved every frame", near_.moves >= 5, near_.moves)
  check("far twin left alone (the one self-check move aside)", far_.moves <= 1, far_.moves)
  local p = near_.pos
  check("inside the box", p and math.abs(p.x - 10) <= 5 + 1e-6 and math.abs(p.y - 10) <= 2 + 1e-6 and math.abs(p.z - 5) <= 1 + 1e-6)

  vs.setEnabled(false)
  local before = near_.moves
  host.onUpdate(0.016, 0.016)
  check("disabled: no moves", near_.moves == before)
  vs.setEnabled(true)
  vs.setMaxDistance(2000)
  host.onUpdate(0.016, 0.016)
  check("raised distance reaches the far twin", far_.moves >= 1, far_.moves)
  vs.setMaxUpdates(1)
  check("setters stored", vs.getStatus().maxDistance == 2000 and vs.getStatus().maxUpdatesPerFrame == 1)
  vs.setMaxUpdates(0)
  check("updates per frame never below 1", vs.getStatus().maxUpdatesPerFrame == 1)

  near_.setPosition = function() error("no setPosition") end        -- the engine refuses: the scatter switches itself off
  vs.setMaxUpdates(400)
  host.onUpdate(0.016, 0.016)
  host.onUpdate(0.016, 0.016)
  check("broken reported", vs.getStatus().broken == true)
  host.onExtensionUnloaded()
  check("shutdown clears the nodes", vs.getStatus().nodes == 0)
end

loadfile = realLoadfile
print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
