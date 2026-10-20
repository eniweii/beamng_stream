-- Offline tests for nfsc_sectionStreamer and nfsc_sectionManager.
-- usage: lua5.1 tests/lua/test_sections.lua <repo> <levelRoot>   (levelRoot holds levels/nfsc/lua/...)
local repo, root = arg[1], arg[2]
package.path = repo .. "/tests/lua/?.lua;" .. package.path
local H = require("harness")

local passed, failed = 0, 0
local function check(cond, label)
  if cond then passed = passed + 1 else failed = failed + 1; print("FAIL: " .. label) end
end
local function eq(a, b, label)
  if a == b then passed = passed + 1
  else failed = failed + 1; print(string.format("FAIL: %s (got %s, want %s)", label, tostring(a), tostring(b))) end
end

-- The manager registers a create filter; most tests exercise the streamer alone, so it is removed
-- unless keepFilter is set.
local function fresh(tuning, keepFilter)
  H.hookCalls, H.created, H.loaded = {}, {}, {}
  H.install(root)
  H.cam = { x = 3950, y = -200, z = 0 }
  local streamer = H.load(repo .. "/lua/ge/extensions/nfsc/sectionStreamer.lua")
  nfsc_sectionStreamer = streamer
  local manager = H.load(repo .. "/lua/ge/extensions/nfsc/sectionManager.lua")
  nfsc_sectionManager = manager
  H.loaded = { streamer, manager }
  if tuning then streamer.setTuning(tuning) end
  manager.onExtensionLoaded()
  if not keepFilter then streamer.setCreateFilter(nil) end
  local ok, err = streamer.initialize("levels/nfsc")
  assert(ok, err)
  return streamer, manager
end
local function settle(streamer, n) H.tick(streamer, n or 20, 0.1) end

-- 1. startup: camera in 1021 -> 1021 + related 1022 resident, shared object created once ------------
do
  local s = fresh()
  settle(s, 5)
  local st = s.getStatus()
  eq(st.currentSectionID, 1021, "current section is 1021")
  eq(st.currentSectionName, "1021 (J21)", "display name")
  eq(st.activeSectionCount, 2, "1021 + related 1022 active")
  eq(st.liveObjectCount, 9, "9 unique objects live (7 + 2, shared pole once)")
  eq(H.created["XTU_SHAREDPOLE_1A_00_900"], 1, "multi-section object created exactly once")
  eq(st.createdTotal, 9, "createdTotal")
  eq(st.failureCount, 0, "no failures")
  eq(#H.hooks("onNfscStreamerInitialized"), 1, "initialized hook fired")
  eq(H.hooks("onNfscSectionChanged")[1].args[1], 1021, "section changed to 1021")
  local g = H.byName("NFSC_StreamedScenery")
  check(g and #g.children == 9, "all objects live in the runtime group")
end

-- 2. throttle: objects are created across frames, not all at once ------------------------------
do
  local s = fresh({ maxCreatesPerFrame = 2 })
  H.tick(s, 1, 0.016)
  eq(s.getStatus().liveObjectCount, 2, "frame 1 creates only 2")
  eq(s.getStatus().queuedObjectCount, 5, "rest of the section still queued")
  settle(s, 10)
  eq(s.getStatus().liveObjectCount, 9, "everything arrives eventually")
end

-- 3. transforms and fields are applied exactly as exported ---------------------------------------
do
  local s = fresh()
  settle(s, 5)
  local o = H.byName("XTU_TREESPINGA_1A_00_291")
  eq(o.fields.position, "3913.101562 -224.145584 186.619926", "position text")
  eq(o.fields.rotationEuler, "1.7e-08 -3.141592503 0.192116633", "rotationEuler text, no conversion")
  eq(o.fields.scale, "-0.9251 -0.9251 -0.9252", "negative scale kept")
  eq(o.fields.shapeName, "/levels/nfsc/assets/meshes/XTU_TREESPINGA_1A_00.dae", "shapeName")
  eq(o.fields.sectionID, "1021", "sectionID kept as a field")
  eq(o.fields.dae_node, "scene_ScenerySection_1021_node_12", "dae_node kept")
  eq(o.fields.instanceFlags, "IncludeRearView,IncludeReflection,Swayable,InvertedMatrix", "instanceFlags untouched")
  eq(o.fields.collisionType, "None", "collision forced off by default")
  eq(o.fields.__streamKey, nil, "builder bookkeeping not written to the object")
end
do
  local s = fresh({ forceCollisionNone = false })
  settle(s, 5)
  eq(H.byName("XTU_TREESPINGA_1A_00_291").fields.collisionType, "Collision Mesh", "collision as exported when not forced")
end

-- 4. leaving a section: objects survive the cooldown, then are deleted; shared ones stay --------
do
  local s = fresh()
  settle(s, 5)
  H.cam = { x = 4100, y = -320, z = 0 }
  H.tick(s, 5, 0.1)
  eq(s.getStatus().currentSectionID, 1101, "moved to 1101")
  check(s.getStatus().liveObjectCount >= 9, "nothing deleted inside the cooldown")
  settle(s, 30)
  local st = s.getStatus()
  eq(st.liveObjectCount, 4, "pole + 1022's two + rock remain")
  eq(st.deletedTotal, 6, "six 1021-only objects deleted")
  check(H.byName("XTU_SHAREDPOLE_1A_00_900") ~= nil, "multi-section object kept by its other section")
  check(H.byName("XTU_TREEDEADB_1A_00_053") == nil, "1021-only object is gone")
end

-- 5. coming back inside the cooldown cancels the unload; nothing is recreated --------------------
do
  local s = fresh()
  settle(s, 5)
  H.cam = { x = 4100, y = -320, z = 0 }
  H.tick(s, 5, 0.1)
  H.cam = { x = 3950, y = -200, z = 0 }
  settle(s, 40)
  local st = s.getStatus()
  eq(st.liveObjectCount, 9, "back to the original nine")
  eq(st.createdTotal, 10, "only the rock was extra; no recreation churn")
  eq(st.deletedTotal, 1, "only the rock deleted")
end

-- 6. outside every section: everything unloads (after the cooldown), no fallback ------------------
do
  local s = fresh()
  settle(s, 5)
  H.cam = { x = 0, y = 0, z = 0 }
  H.tick(s, 3, 0.1)
  eq(s.getStatus().currentSectionID, nil, "no section")
  eq(s.getStatus().activeSectionCount, 0, "nothing active")
  settle(s, 30)
  eq(s.getStatus().liveObjectCount, 0, "all unloaded")
  local last = H.hooks("onNfscSectionChanged")
  eq(last[#last].args[1], nil, "hook reports nil section")
end

-- 7. tolerance fallback: just outside a polygon edge still resolves to that section ---------------
do
  local s = fresh()
  H.cam = { x = 3800 - 0.05, y = -200, z = 0 }
  H.tick(s, 2, 0.2)
  eq(s.getStatus().currentSectionID, 1021, "0.05 outside an edge resolves within tolerance")
end

-- 8. manager: overrides decide what exists and what is visible; streamer never looks at them -----
do
  local s, m = fresh(nil, true)
  settle(s, 5)
  local tree = H.byName("XTU_TREEDEADB_1A_00_053")
  eq(H.byName("XWS_BARRIERCHGATE_1A_00_016"), nil, "override object is not created while no name is enabled")
  eq(H.byName("XTU_TREESPINGA_1A_00_500"), nil, "two-name override object is not created either")
  eq(tree.hidden, false, "object without an override is untouched")
  eq(s.getStatus().liveObjectCount, 7, "7 of the 9 objects exist")
  eq(s.getStatus().deferredCount, 2, "the two override objects are held back")
  local names = m.getOverrideNames()
  eq(table.concat(names, ","), "0x454C22D2,0x1111AAAA,0x2222BBBB", "nearest-first ordering in 1021")

  m.setOverrideEnabled("0x454C22D2", true)
  settle(s, 5)
  local barrier = H.byName("XWS_BARRIERCHGATE_1A_00_016")
  check(barrier ~= nil and barrier.hidden == false, "enabling creates it, visible from the first frame")
  m.setOverrideEnabled("0x2222BBBB", true)
  settle(s, 5)
  local two = H.byName("XTU_TREESPINGA_1A_00_500")
  check(two ~= nil and two.hidden == false, "any one enabled name is enough")
  m.setOverrideEnabled("0x2222BBBB", false)
  eq(two.hidden, true, "disabling hides it at once")
  settle(s, 40)
  eq(two.deleted, true, "and the object is deleted after the cooldown")
  eq(s.getStatus().deferredCount, 1, "held back again")
  local ch = H.hooks("onNfscOverrideChanged")
  eq(#ch, 3, "override hook fired per real change")
  m.setOverrideEnabled("0x2222BBBB", false)
  eq(#H.hooks("onNfscOverrideChanged"), 3, "no hook when nothing changed")

  -- re-enabling inside the cooldown keeps the live object
  m.setOverrideEnabled("0x2222BBBB", true)
  settle(s, 5)
  local two2 = H.byName("XTU_TREESPINGA_1A_00_500")
  m.setOverrideEnabled("0x2222BBBB", false)
  m.setOverrideEnabled("0x2222BBBB", true)
  settle(s, 40)
  eq(H.byName("XTU_TREESPINGA_1A_00_500"), two2, "re-enabled inside the cooldown: same object, no churn")
  eq(two2.hidden, false, "and visible")
  m.setOverrideEnabled("0x2222BBBB", false)
  settle(s, 40)

  -- state survives the object being deleted and recreated
  H.cam = { x = 4100, y = -320, z = 0 }
  settle(s, 40)
  check(H.byName("XWS_BARRIERCHGATE_1A_00_016") == nil, "barrier unloaded away from 1021")
  eq(m.getStatus().overrideObjectsLive, 0, "manager forgot the deleted barrier; the 1022 override object is not enabled")
  names = m.getOverrideNames()
  eq(table.concat(names, ","), "0x1111AAAA,0x2222BBBB,0x454C22D2", "ordering follows the current section")
  H.cam = { x = 3950, y = -200, z = 0 }
  settle(s, 10)
  eq(H.byName("XWS_BARRIERCHGATE_1A_00_016").hidden, false, "recreated object gets the current override state")

  -- Lua-reload persistence
  local saved = m.onSerialize()
  eq(table.concat(saved.enabled, ","), "0x454C22D2", "serialize keeps the enabled set")
  m.onDeserialized({ enabled = { "0x1111AAAA" } })
  eq(m.isOverrideEnabled("0x1111AAAA"), true, "deserialize restores")
  eq(m.isOverrideEnabled("0x454C22D2"), false, "and replaces")
end

-- 9. reset wipes the runtime group and the manager's tracking, then streams again -------------------
do
  local s, m = fresh()
  settle(s, 5)
  local pole = H.byName("XTU_SHAREDPOLE_1A_00_900")
  s.reset()
  eq(pole.deleted, true, "reset deletes the runtime group's objects")
  eq(s.getStatus().liveObjectCount, 0, "nothing live right after reset")
  eq(m.getStatus().overrideObjectsLive, 0, "manager tracking cleared")
  settle(s, 5)
  eq(s.getStatus().liveObjectCount, 9, "streams again from the camera position")
end

-- 10. bad inputs are reported, not fatal -----------------------------------------------------------
do
  local s = fresh()
  H.readFilter = function(path)
    if path:find("1101.json", 1, true) then return false end   -- missing file
  end
  H.cam = { x = 4100, y = -320, z = 0 }
  settle(s, 10)
  eq(s.getStatus().failureCount, 1, "missing section file counted as one failure")
  check(s.getStatus().liveObjectCount > 0, "other sections still stream")
  H.readFilter = function(path)
    if path:find("index.json", 1, true) then return { schemaVersion = 1, sections = {} } end
  end
  local ok = s.initialize("levels/nfsc")
  eq(ok, false, "old index schema is rejected")
  H.readFilter = nil
end

-- 12. flags policy (hyperlinked draw gate): everything the game's culling uses is honoured -----------
do
  local s, m = fresh()
  local n = 0
  local function streamed(flags, over)
    n = n + 1
    local obj = createObject("TSStatic")
    obj:registerObject("fake" .. n)
    m.listener:onObjectCreated("k" .. n, obj, { instanceFlags = flags, sectionOverrideName = over, __streamSections = { 1021 } })
    return obj
  end
  eq(#m.FLAGS, 32, "all 32 instance flags are described")
  local seen = {}
  for _, f in ipairs(m.FLAGS) do seen[f[1]:lower()] = true end
  local distinct = 0
  for _ in pairs(seen) do distinct = distinct + 1 end
  eq(distinct, 32, "flag names are distinct")

  local plain = streamed("IncludeRearView,Swayable,Collidable,VisibleFurther")
  eq(plain.hidden, false, "metadata-only flags leave the object visible")
  eq(m.getStatus().managedObjectsLive, 0, "and it is not tracked at all")
  eq(streamed("ExcludeMainView").hidden, true, "ExcludeMainView is never drawn")

  local fr, rc = streamed("ExcludeFreeroam"), streamed("ExcludeRacing")
  eq(fr.hidden, true, "ExcludeFreeroam hidden in freeroam")
  eq(rc.hidden, false, "ExcludeRacing visible in freeroam")
  m.setGameMode("racing")
  eq(fr.hidden, false, "ExcludeFreeroam visible in racing")
  eq(rc.hidden, true, "ExcludeRacing hidden in racing")
  m.setGameMode("freeroam")
  eq(fr.hidden, true, "back to freeroam")

  local lo, hi, loEnv = streamed("LowPlatformOnly"), streamed("HighPlatformOnly"), streamed("LowPlatformOnly,EnvMapShadow")
  eq(lo.hidden, true, "LowPlatformOnly hidden on the high platform")
  eq(hi.hidden, false, "HighPlatformOnly visible on the high platform")
  eq(loEnv.hidden, false, "EnvmapShadow exempts LowPlatformOnly")
  m.setPlatform("low")
  eq(lo.hidden, false, "LowPlatformOnly visible on the low platform")
  eq(hi.hidden, true, "HighPlatformOnly hidden on the low platform")
  m.setPlatform("high")

  local edr = streamed("ExcludeDisableRendering")
  eq(edr.hidden, false, "ExcludeDisableRendering is drawn and exempt from distance disabling, never hidden")
  local gd = streamed("ExcludeGroupDisable")
  eq(gd.hidden, true, "group-disabled flag without an override stays hidden")
  local gdo = streamed("ExcludeDisableRendering", "0xBEEF")
  eq(gdo.hidden, true, "group-disabled member hidden until its group is enabled")
  m.setOverrideEnabled("0xBEEF", true)
  eq(gdo.hidden, false, "enabling the group shows it")
  local both = streamed("ExcludeMainView", "0xBEEF")
  eq(both.hidden, true, "an enabled override cannot bring back a main-view exclusion")
  m.setTuning({ honorGroupDisableFlags = false })
  eq(gd.hidden, false, "tuning can ignore the group-disable baseline")

  local set, unknown = m.parseFlags("IncludeReflectionNG, Collidable|BogusFlag")
  check(set.includereflectionng and set.collidable and set.bogusflag, "parseFlags normalizes and splits , and |")
  eq(unknown, 1, "one unknown flag token")
  streamed("BogusFlag,ExcludeMainView")
  eq(m.getStatus().unknownFlagCount, 1, "unknown flags are counted, not fatal")
  eq(table.concat(m.getUnknownFlags(), ","), "bogusflag", "unknown flag listed")
  check((m.getFlagCounts().excludemainview or 0) >= 2, "flag counts accumulate")

  m.setPlatform("low"); m.setGameMode("racing"); m.setSceneClassEnabled("lights", false)
  local saved = m.onSerialize()
  eq(saved.platform .. saved.gameMode, "lowracing", "mode and platform persist")
  eq(saved.lights, false, "radio persists")
  m.onDeserialized({ gameMode = "freeroam", platform = "high", lights = true })
  eq(m.getGameMode() .. m.getPlatform(), "freeroamhigh", "restored")
end

-- 13. emitters and lights: section residency + override + radios + farClip ---------------------------
do
  local s, m = fresh()
  local eNear = H.addSceneObject{ class = "ParticleEmitterNode", name = "emit_near", sectionID = "1021", farClip = "50",
                                  volBase = "3950 -200 5", pos = { x = 3950, y = -200, z = 5 } }
  local eFar = H.addSceneObject{ class = "ParticleEmitterNode", name = "emit_far", sectionID = "1021", farClip = "50",
                                 volBase = "4050 -200 0", pos = { x = 4050, y = -200, z = 0 } }
  local l1 = H.addSceneObject{ class = "PointLight", name = "light_1021", sectionID = "1021" }
  local l2 = H.addSceneObject{ class = "PointLight", name = "light_1101", sectionID = "1101" }
  local l3 = H.addSceneObject{ class = "PointLight", name = "light_ovr", sectionID = "1021", sectionOverrideName = "0xAAAA" }
  H.addSceneObject{ class = "TSStatic", name = "ignored", sectionID = "1021" }
  m.rescanScene()
  eq(l1.isEnabled, false, "scene objects are off until a section is active")
  eq(m.getSceneStatus().emitters, 2, "two emitters indexed")
  eq(m.getSceneStatus().lights, 3, "three lights indexed (other classes ignored)")
  settle(s, 5)
  eq(l1.isEnabled, true, "light in an active section is on")
  eq(l2.isEnabled, false, "light in an inactive section is off")
  eq(l3.isEnabled, false, "override light waits for its group")
  eq(eNear.active, true, "emitter inside its farClip is on")
  eq(eFar.active, false, "emitter beyond its farClip is off")

  m.setSceneClassEnabled("lights", false)
  eq(l1.isEnabled, false, "lights radio Off")
  eq(eNear.active, true, "emitters unaffected by the lights radio")
  m.setSceneClassEnabled("lights", true)
  eq(l1.isEnabled, true, "lights radio On")
  m.setSceneClassEnabled("emitters", false)
  eq(eNear.active, false, "emitters radio Off")
  m.setSceneClassEnabled("emitters", true)
  eq(eNear.active, true, "emitters radio On")

  m.setOverrideEnabled("0xAAAA", true)
  eq(l3.isEnabled, true, "enabling the override turns the light on")
  eq(table.concat(m.getOverrideNames(), ","), "0x454C22D2,0xAAAA,0x1111AAAA,0x2222BBBB", "scene override joins the ordered list")

  H.cam = { x = 4040, y = -200, z = 0 }
  H.tick(s, 3, 0.3)
  eq(eFar.active, true, "emitter comes on when the camera gets inside its farClip")
  eq(eNear.active, false, "and the one now beyond its farClip goes off")

  H.cam = { x = 4100, y = -320, z = 0 }
  H.tick(s, 3, 0.1)
  eq(l1.isEnabled, false, "light in 1021 goes off once 1021 is no longer active")
  eq(l2.isEnabled, true, "light in 1101 comes on")
  H.cam = { x = 0, y = 0, z = 0 }
  H.tick(s, 3, 0.1)
  eq(l2.isEnabled, false, "outside every section all scene objects are off at once")
  eq(eFar.active, false, "including emitters")
end

-- 11. collision policy: decides WHEN to refresh, once per settled change, and measures it ------------
local function freshWithCollision(mode, tuning)
  local s, m = fresh({ maxCreatesPerFrame = 2 })
  local c = H.load(repo .. "/lua/ge/extensions/nfsc/sectionCollision.lua")
  nfsc_sectionCollision = c
  H.loaded[#H.loaded + 1] = c
  c.onExtensionLoaded()
  c.setTuning(tuning or {})
  c.setMode(mode)
  s.reset()
  return s, m, c
end
do
  local s, m, c = freshWithCollision("off")
  settle(s, 30)
  eq(H.reloadCalls, 0, "mode off never refreshes collision")
  eq(H.byName("XTU_TREEDEADB_1A_00_053").fields.collisionType, "None", "mode off creates without collision")
end
do
  local s, m, c = freshWithCollision("settled")
  H.tick(s, 3, 0.1)
  eq(H.reloadCalls, 0, "no refresh while objects are still being created")
  settle(s, 30)
  eq(H.reloadCalls, 1, "one refresh for the whole batch, not one per object")
  eq(H.byName("XTU_TREEDEADB_1A_00_053").fields.collisionType, "Collision Mesh", "settled keeps exported collision")
  local st = c.getStatus()
  eq(st.reloads, 1, "refresh counted")
  check(st.lastMs >= 0 and st.dirty == false, "refresh timed and cleared")
  m.setOverrideEnabled("0x454C22D2", true)
  settle(s, 30)
  eq(H.reloadCalls, 2, "override change schedules a refresh")
  H.cam = { x = 4100, y = -320, z = 0 }
  settle(s, 60)
  check(H.reloadCalls >= 3 and H.reloadCalls <= 5, "section change refreshes a small, bounded number of times")
  local before = H.reloadCalls
  settle(s, 60)
  eq(H.reloadCalls, before, "nothing changing means no more refreshes")
end
do
  local s, m, c = freshWithCollision("settled", { minInterval = 100 })
  settle(s, 30)
  eq(H.reloadCalls, 1, "first refresh is allowed immediately")
  m.setOverrideEnabled("0x454C22D2", true)
  settle(s, 30)
  eq(H.reloadCalls, 1, "minInterval rate-limits refreshes")
end

-- 14. the load queue is bounded: a big section waits in pending lists, not in the queue -------------
do
  local s = fresh({ maxQueuedItems = 3, maxCreatesPerFrame = 1 })
  local over = false
  for _ = 1, 40 do
    H.tick(s, 1, 0.1)
    if s.getStatus().queuedObjectCount > 3 then over = true end
  end
  eq(over, false, "queue never exceeds maxQueuedItems")
  local st = s.getStatus()
  eq(st.queueHighWater, 3, "high-water mark reports the cap")
  eq(st.liveObjectCount, 9, "everything still arrives")
  eq(st.pendingRecordCount, 0, "pending data is released once fed")
  eq(st.createdPeakFrame, 1, "creates per frame are tracked")
  check(s.isIdle(), "idle afterwards")
end

-- 15. a section change drops stale queue entries at once ---------------------------------------------
do
  local s = fresh({ maxQueuedItems = 6, maxCreatesPerFrame = 1 })
  H.tick(s, 2, 0.1)
  check(s.getStatus().queuedObjectCount >= 3, "a backlog exists before the move")
  H.cam = { x = 4100, y = -320, z = 0 }
  H.tick(s, 1, 0.1)
  check(s.getStatus().staleDiscarded > 0, "entries of the abandoned section were dropped from the queue")
  settle(s, 40)
  eq(s.getStatus().liveObjectCount, 4, "same end state as without a backlog")
  eq(s.getStatus().pendingRecordCount, 0, "no pending data left")
end

-- 16. load order: terrain first, then the rest; same shapeName together -------------------------------
do
  local s = fresh({ maxCreatesPerFrame = 100 })
  local order = {}
  s.addListener({ onObjectCreated = function(self, key) order[#order + 1] = key end })
  H.readFilter = function(path)
    if path:find("1021.json", 1, true) then
      local function item(i, shape, flags)
        return { class = "TSStatic", name = "syn" .. i, shapeName = shape, instanceFlags = flags,
                 __streamKey = "syn:" .. i, __streamSections = { 1021 }, sectionID = "1021" }
      end
      return { schemaVersion = 2, sectionID = 1021, objectCount = 7, objects = {
        item(1, "/a.dae"), item(2, "/b.dae"), item(3, "/a.dae"), item(4, "/t.dae", "IdentityMatrix"),
        item(5, "/b.dae"), item(6, "/c.dae", "IncludeRearView,ChoppedRoadway"), item(7, "/a.dae") } }
    end
  end
  H.tick(s, 1, 0.1)
  eq(table.concat(order, ",", 1, 7), "syn:4,syn:6,syn:1,syn:3,syn:7,syn:2,syn:5",
    "terrain first, then grouped by shapeName in order of first appearance")
  H.readFilter = nil
end

-- 17. create filter at streamer level: hold back, release, cancel ------------------------------------
do
  local s = fresh()
  local allow = false
  local seen = {}
  s.addListener({ onObjectCreated = function(self, key, obj, item) seen[item.name] = { key = key, item = item } end })
  s.setCreateFilter(function(item) return item.name ~= "XTU_HOUSE_1A_00_001" or allow end)
  settle(s, 5)
  eq(s.getStatus().liveObjectCount, 8, "held-back object is not created")
  eq(s.getStatus().deferredCount, 1, "and remembered")
  allow = true
  s.refreshFilter()
  settle(s, 5)
  eq(s.getStatus().liveObjectCount, 9, "refreshFilter creates it")
  eq(s.getStatus().deferredCount, 0, "nothing deferred any more")
  allow = false
  local house = seen["XTU_HOUSE_1A_00_001"]
  s.releaseObject(house.key, house.item)
  settle(s, 40)
  eq(s.getStatus().liveObjectCount, 8, "releaseObject deletes it after the cooldown")
  eq(s.getStatus().deferredCount, 1, "and holds it back again")
  allow = true
  s.releaseObject(house.key, house.item)
  s.refreshFilter()
  settle(s, 5)
  eq(s.getStatus().liveObjectCount, 9, "accepted again")
  H.cam = { x = 4100, y = -320, z = 0 }
  settle(s, 40)
  eq(s.getStatus().deferredCount, 0, "deferred lists are released with their section")
end

-- 18. look-ahead: the section ahead becomes current before the camera crosses the border ---------------
do
  local s = fresh({ maxCreatesPerFrame = 100 })
  H.cam = { x = 3905, y = -320, z = 0 }
  H.tick(s, 1, 0.1)
  eq(s.getStatus().currentSectionID, 1022, "starts in 1022")
  local switched
  for i = 1, 16 do
    H.cam.x = H.cam.x + 6                                       -- 60 m/s
    H.tick(s, 1, 0.1)
    if s.getStatus().currentSectionID ~= 1022 then switched = i; break end
  end
  check(switched ~= nil, "switched to the section ahead")
  eq(s.getStatus().currentSectionID, 1101, "1101 is current ...")
  eq(s.getStatus().cameraSectionID, 1022, "... while the camera is still in 1022")
  check(H.cam.x < 4000, "camera has not crossed the border yet")
  check(s.getStatus().cameraSpeed > 50, "speed is tracked")
end

do
  local s = fresh({ maxCreatesPerFrame = 100, predictionEnabled = false })
  H.cam = { x = 3905, y = -320, z = 0 }
  H.tick(s, 1, 0.1)
  for _ = 1, 14 do
    H.cam.x = H.cam.x + 6
    H.tick(s, 1, 0.1)
  end
  eq(s.getStatus().currentSectionID, 1022, "without prediction nothing switches before the border")
  eq(s.getStatus().predictedSectionID, nil, "and nothing is predicted")
end

do
  local s = fresh({ maxCreatesPerFrame = 100 })
  H.cam = { x = 3905, y = -320, z = 0 }
  H.tick(s, 1, 0.1)
  H.cam = { x = 4300, y = -320, z = 0 }                          -- a jump is not driving
  H.tick(s, 1, 0.1)
  eq(s.getStatus().cameraSpeed, 0, "jump: no velocity")
  eq(s.getStatus().currentSectionID, nil, "outside every section: nothing current")
end

-- 19. load order follows the heading (the game's three priority bands) --------------------------------
do
  local s = fresh()
  H.readFilter = function(path)
    if path:find("sections.json", 1, true) then
      local function box(id, x0, x1, related)
        return { id = id, points = { { x0, -50 }, { x1, -50 }, { x1, 50 }, { x0, 50 } },
                 boundsMin = { x0, -50 }, boundsMax = { x1, 50 }, related = related }
      end
      return { sections = { box(9001, -50, 50, { 9002, 9003 }), box(9002, 150, 250, { 9001 }), box(9003, -250, -150, { 9001 }) } }
    end
  end
  s.initialize("levels/nfsc")
  H.cam = { x = 0, y = 0, z = 0 }
  H.tick(s, 1, 0.1)
  eq(table.concat(s.getLoadOrder(), ","), "9001,9002,9003", "standing still: static order")
  for _ = 1, 8 do
    H.cam.x = H.cam.x - 3                                        -- 30 m/s west
    H.tick(s, 1, 0.1)
  end
  eq(table.concat(s.getLoadOrder(), ","), "9001,9003,9002", "heading west: the section ahead loads first")
  H.readFilter = nil
end

-- 20. timing counters ---------------------------------------------------------------------------------
do
  local s = fresh()
  settle(s, 10)
  local st = s.getStatus()
  eq(st.firstUseCreates + st.repeatCreates, st.createdTotal, "every create is counted as first use or repeat")
  check(st.firstUseCreates > 0, "first-use creates are separated")
  eq(st.createdSinceChange, st.createdTotal, "creates since the last section change")
  check(st.settleSeconds >= 0 and st.avgCreateMs >= 0 and st.maxCreateMs >= 0 and st.loadFramePeakMs >= 0, "timings are reported")
  check(st.maxReadMs >= 0, "section read time is reported")
end

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
