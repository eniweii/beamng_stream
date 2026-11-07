-- Offline tests for the environment components run by nfsc_levelHost: roughness, sway, textureAnimation.
-- Run with: python tests/run_lua_tests_lupa.py --env      arg[1] = repo root
local repo = arg[1]
package.path = repo .. "/tests/lua/?.lua;" .. package.path
local H = dofile(repo .. "/tests/lua/harness.lua")

local passed, failed = 0, 0
local function check(name, cond, extra)
  if cond then passed = passed + 1 else failed = failed + 1; print("FAIL: " .. name .. (extra and (" (" .. tostring(extra) .. ")") or "")) end
end

local MATERIALS_FILE = "levels/nfsc/main.materials.json"
local ANIM_FILE = "levels/nfsc/material_animations.json"

local realLoadfile = loadfile
local mats, captured

local function newMaterial()
  local m = { fields = {}, reloads = 0 }
  function m:setField(field, idx, value) self.fields[idx] = self.fields[idx] or {}; self.fields[idx][field] = value end
  function m:reload() self.reloads = self.reloads + 1 end
  return m
end

local function fresh(files)
  H.install(repo)
  H.files = files or {}
  mats = {}
  captured = nil
  scenetree.findObject = function(name) return mats[name] end
  FS = { findFiles = function(self, root, pattern)
    if pattern == "*materials.json" and H.files[MATERIALS_FILE] then return { MATERIALS_FILE } end
    if pattern == "material_animations.json" and H.files[ANIM_FILE] then return { ANIM_FILE } end
    return {}
  end }
  nfsc_sectionStreamer = { addListener = function(l) captured = l end, removeListener = function() captured = nil end }
  loadfile = function(path)
    local game = path:match("^/lua/ge/extensions/nfsc/components/(.+)$")
    return realLoadfile(game and (repo .. "/lua/ge/extensions/nfsc/components/" .. game) or path)
  end
  local host = dofile(repo .. "/lua/ge/extensions/nfsc/levelHost.lua")
  host.onExtensionLoaded()
  return host
end

local function stage(color, rough) return { baseColorMap = color, roughnessFactor = rough } end
local MATERIAL_DATA = {
  PAN_A_D_WorldReflectShader = { class = "Material", Stages = { stage("a.dds", 0.8), {}, {}, {} } },
  PAN_B_D_WorldShader = { class = "Material", Stages = { stage("b.dds", 0.5), {}, {}, {} } },
  PLAIN = { class = "Material", Stages = { stage("p.dds", 0.5) } },
}
local function rough(mat, idx) return mats[mat] and mats[mat].fields[idx or 0] and mats[mat].fields[idx or 0].roughnessFactor end
local function frames(host, n, dt) for _ = 1, n do host.onUpdate(dt or 0.016, dt or 0.016) end end

-- 1. roughness: index, selection, requests, layering
do
  local host = fresh({ [MATERIALS_FILE] = MATERIAL_DATA })
  mats.PAN_A_D_WorldReflectShader, mats.PAN_B_D_WorldShader = newMaterial(), newMaterial()
  host.initialize("levels/nfsc")
  local r = host.getComponent("roughness")
  check("roughness running", host.getStatus().components[3].name == "roughness" and host.getStatus().components[3].ok)
  frames(host, 2)
  local st = r.getStatus()
  check("index ready", st.indexState == "ready", st.indexState)
  check("two classed materials, plain one ignored", st.materials == 2, st.materials)
  check("default class selected", st.selected == 1, st.selected)
  check("nothing written at baseline", rough("PAN_A_D_WorldReflectShader") == nil)

  r.setRoughness("user", 0.5, { priority = 10, fade = 0 })
  frames(host, 3)
  check("selected material scaled", rough("PAN_A_D_WorldReflectShader") == "0.4000", rough("PAN_A_D_WorldReflectShader"))
  check("unselected material untouched", rough("PAN_B_D_WorldShader") == nil)
  check("material refreshed", mats.PAN_A_D_WorldReflectShader.reloads >= 1)

  r.setClassSelected("WorldShader", true)
  frames(host, 3)
  check("newly selected class follows", rough("PAN_B_D_WorldShader") == "0.2500", rough("PAN_B_D_WorldShader"))

  r.setRoughness("low", 0.25, { priority = 1 })
  r.setRoughness("high", 1.5, { priority = 5 })
  r.clearRoughness("user", { fade = 0 })
  frames(host, 3)
  check("highest priority wins, result clamped to 1", rough("PAN_A_D_WorldReflectShader") == "1.0000", rough("PAN_A_D_WorldReflectShader"))
  r.clearRoughness("high", { fade = 0 })
  r.clearRoughness("low", { fade = 0 })
  frames(host, 3)
  check("back to baseline", rough("PAN_A_D_WorldReflectShader") == "0.8000", rough("PAN_A_D_WorldReflectShader"))
  check("status counts writes", r.getStatus().writes >= 2 and r.getStatus().errors == 0)
end

-- 2. roughness: shutdown restores baseline, state survives a reload through the host
local savedState
do
  local host = fresh({ [MATERIALS_FILE] = MATERIAL_DATA })
  mats.PAN_A_D_WorldReflectShader = newMaterial()
  host.initialize("levels/nfsc")
  frames(host, 2)
  host.getComponent("roughness").setRoughness("user", 0.5, { priority = 10, fade = 0 })
  frames(host, 3)
  check("scaled before reload", rough("PAN_A_D_WorldReflectShader") == "0.4000")
  host.getComponent("sway").setSwayEnabled(true)
  host.getComponent("textureAnimation").setAnimationBudget(3)
  savedState = host.onSerialize()
  check("serialized per component", savedState.roughness and savedState.sway and savedState.textureAnimation)
  host.onExtensionUnloaded()
  check("unload restores baseline", rough("PAN_A_D_WorldReflectShader") == "0.8000", rough("PAN_A_D_WorldReflectShader"))
  check("listener removed on unload", captured == nil)
end
do
  local host = fresh({ [MATERIALS_FILE] = MATERIAL_DATA })
  mats.PAN_A_D_WorldReflectShader = newMaterial()
  host.onDeserialized(savedState)                                -- the engine hands the state back before mainLevel initializes
  host.initialize("levels/nfsc")
  frames(host, 4)
  check("request restored after reload", rough("PAN_A_D_WorldReflectShader") == "0.4000", rough("PAN_A_D_WorldReflectShader"))
  check("sway switch restored", host.getComponent("sway").isSwayEnabled() == true)
  check("animation budget restored", host.getComponent("textureAnimation").getAnimationBudget() == 3)
end

-- 3. sway through the host's object events
do
  local host = fresh({})
  host.initialize("levels/nfsc")
  check("host listener registered", captured ~= nil)
  local function mk(x, y, id)
    local o = { id = id, x = x, y = y, poses = 0 }
    function o:getPosition() return { x = self.x, y = self.y, z = 0 } end
    function o:getRotation() return { x = 0, y = 0, z = 0, w = 1 } end
    function o:getID() return self.id end
    function o:setPosRot(px, py, pz, qx, qy, qz, qw) self.poses = self.poses + 1; self.last = { qx, qy, qz, qw } end
    return o
  end
  local near_, far_, ident = mk(10, 0, 1), mk(5000, 0, 2), mk(20, 0, 3)
  captured:onObjectCreated("near", near_, { instanceFlags = "Swayable" })
  captured:onObjectCreated("far", far_, { instanceFlags = "Swayable" })
  captured:onObjectCreated("ident", ident, { instanceFlags = "Swayable, IdentityMatrix" })
  captured:onObjectCreated("plain", mk(1, 1, 4), { instanceFlags = "Visible" })
  local sway = host.getComponent("sway")
  local st = sway.getStatus()
  check("two swayable registered, identity skipped", st.swayRegistered == 2 and st.swaySkipped == 1, st.swayRegistered)

  H.cam = { x = 0, y = 0, z = 0 }
  frames(host, 3, 0.3)
  check("off: nothing moves", near_.poses == 0)
  sway.setSwayEnabled(true)
  frames(host, 3, 0.3)
  check("on: nearest object moves", near_.poses >= 1, near_.poses)
  check("on: far object stays", far_.poses == 0)
  check("one moving", sway.getStatus().swayMoving == 1, sway.getStatus().swayMoving)

  local before = near_.poses
  captured:onObjectDeleted("near")
  check("deleted object gets its exported pose back", near_.poses == before + 1 and near_.last[4] == 1 and near_.last[1] == 0)
  check("registry shrank", sway.getStatus().swayRegistered == 1)

  captured:onObjectCreated("bad", nil, { instanceFlags = "Swayable" })     -- a failing handler must not switch the component off
  check("component survives a failing event", host.getStatus().components[4].ok == true)
  captured:onObjectCreated("near2", mk(15, 0, 5), { instanceFlags = "Swayable" })
  check("still registers afterwards", sway.getStatus().swayRegistered == 2)

  captured:onStreamerReset()
  check("reset clears the registry", sway.getStatus().swayRegistered == 0 and sway.getStatus().swayMoving == 0)
  sway.setSway({ amplitudeDeg = 99, maxObjects = 0 })
  local g = sway.getSway()
  check("setters clamp", g.amplitudeDeg == 15 and g.maxObjects == 1, g.amplitudeDeg)
end

-- 4. texture animation: frame swap on the shared clock, restore on shutdown
do
  local ANIM = {
    animations = { sign = { name = "sign", fps = 2, timeBase = "World", frames = { { path = "a0.dds" }, { path = "a1.dds" } } } },
    materials = { SIGN_01_D_WorldShader = { { type = "frame_swap", animation = "sign", stage = 0, frame = 0 } } },
  }
  local host = fresh({ [ANIM_FILE] = ANIM })
  mats.SIGN_01_D_WorldShader = newMaterial()
  host.initialize("levels/nfsc")
  local anim = host.getComponent("textureAnimation")
  frames(host, 2)
  local st = anim.getStatus()
  check("animation file read", st.animState == "ready" and st.animSequences == 1 and st.animMaterials == 1, st.animState)
  check("off by default, nothing written", mats.SIGN_01_D_WorldShader.fields[0] == nil)
  anim.setAnimationEnabled(true)
  frames(host, 1, 0.6)
  check("frame 1 shown", mats.SIGN_01_D_WorldShader.fields[0] and mats.SIGN_01_D_WorldShader.fields[0].baseColorMap == "a1.dds",
    mats.SIGN_01_D_WorldShader.fields[0] and mats.SIGN_01_D_WorldShader.fields[0].baseColorMap)
  frames(host, 1, 0.5)
  check("clock wraps back to frame 0", mats.SIGN_01_D_WorldShader.fields[0].baseColorMap == "a0.dds", mats.SIGN_01_D_WorldShader.fields[0].baseColorMap)
  frames(host, 1, 0.5)
  check("and forward again", mats.SIGN_01_D_WorldShader.fields[0].baseColorMap == "a1.dds")
  host.onExtensionUnloaded()
  check("shutdown puts the exported frame back", mats.SIGN_01_D_WorldShader.fields[0].baseColorMap == "a0.dds", mats.SIGN_01_D_WorldShader.fields[0].baseColorMap)
  check("no write errors", anim.getStatus().animErrors == 0)
end

-- 5. missing data does not break the host
do
  local host = fresh({})
  host.initialize("levels/nfsc")
  frames(host, 3)
  local st = host.getStatus()
  check("all five components present", #st.components == 5)
  check("roughness: no materials file reported as ready/empty", host.getComponent("roughness").getStatus().materials == 0)
  check("animation: missing reported", host.getComponent("textureAnimation").getStatus().animState == "missing")
end

-- 6. the host panel draws every component block without errors (imgui is a recording stub)
do
  local calls = {}
  local function ptr(v) return setmetatable({ [0] = v }, {}) end
  local im = setmetatable({
    BoolPtr = ptr, FloatPtr = ptr, IntPtr = ptr,
    CollapsingHeader1 = function() return true end,
    Checkbox = function() return false end, Button = function() return false end,
    SliderFloat = function() return false end, SliderInt = function() return false end,
    IsItemHovered = function() return false end,
  }, { __index = function(_, k) return function(...) calls[#calls + 1] = k; return false end end })
  ui_imgui = im
  local ANIM = { animations = { sign = { fps = 2, frames = { { path = "a0.dds" }, { path = "a1.dds" } } } },
                 materials = { SIGN_01_D_WorldShader = { { type = "frame_swap", animation = "sign", stage = 0, frame = 0 } } } }
  local host = fresh({ [MATERIALS_FILE] = MATERIAL_DATA, [ANIM_FILE] = ANIM, ["levels/nfsc/lua/zones.json"] = { zones = {} } })
  nfsc_levelHost = host
  host.initialize("levels/nfsc")
  frames(host, 3)
  local ui = dofile(repo .. "/lua/ge/extensions/nfsc/levelHostUi.lua")
  local ok, err = pcall(ui.onUpdate)
  check("panel draws all five blocks", ok, err)
  check("panel drew something", #calls > 10, #calls)
  nfsc_levelHost = nil
end

loadfile = realLoadfile
print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
