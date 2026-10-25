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
  streamer.setTuning({ maxFirstUsePerFrame = 1000 })   -- the first-use cap has its own test (21)
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

-- 21. first-use cap, shared frame budget, per-change cost split (fake clock: 1 ms per os.clock call) -----
do
  local realClock, ticks = os.clock, 0
  os.clock = function() ticks = ticks + 0.001; return ticks end
  -- every shape in the fixture counts as new on a fresh streamer: with the cap at 1, frame 1 may start
  -- one new shape only, and the head of the queue is not lost
  local s = fresh({ maxCreatesPerFrame = 100, frameBudgetMs = 1000, maxFirstUsePerFrame = 1 })
  H.tick(s, 1, 0.016)
  local st = s.getStatus()
  eq(st.liveObjectCount, 1, "frame 1 creates one new shape and stops before the next new one")
  check(st.changeDeferredFirstUse >= 1, "a deferred new shape is counted")
  settle(s, 60)
  st = s.getStatus()
  eq(st.liveObjectCount, 9, "the cap only spreads the work, all 9 objects get created")
  eq(st.failureCount, 0, "no failures with the cap")
  -- a budget smaller than one create still creates one object per frame (progress is guaranteed)
  local s2 = fresh({ maxCreatesPerFrame = 100, frameBudgetMs = 0.001, maxFirstUsePerFrame = 1000 })
  H.tick(s2, 1, 0.016)
  eq(s2.getStatus().liveObjectCount, 1, "a tiny budget still makes progress: one create per frame")
  settle(s2, 40)
  eq(s2.getStatus().liveObjectCount, 9, "and the section completes")
  -- the split is filled and the change accumulators follow the section change
  local st2 = s2.getStatus()
  check(st2.changeCreates == 9 and st2.changeFrames > 0 and st2.changeFps > 0, "per-change creates, frames and fps are reported")
  local sum = st2.changeSplitMs.createObject + st2.changeSplitMs.setField + st2.changeSplitMs.registerObject + st2.changeSplitMs.groupAdd
  check(sum > 0 and sum <= st2.changeCreateMs + 1e-6, "split parts add up to no more than the create time")
  os.clock = realClock
end

-- 22. first use / reload / warm split and the most expensive shapes ----------------------------------
do
  local s = fresh({ unloadCooldown = 0.2 })
  settle(s, 10)
  local st = s.getStatus()
  eq(st.changeFirstUse + st.changeReload + st.changeWarm, st.changeCreates, "every create is first use, reload or warm")
  check(st.changeFirstUse > 0, "new shapes are first use")
  eq(st.changeReload, 0, "nothing is a reload on the first visit")
  check(#st.changeTopShapes >= 1 and #st.changeTopShapes <= 5, "top shapes are reported, at most 5")
  for i = 2, #st.changeTopShapes do
    check(st.changeTopShapes[i - 1].ms >= st.changeTopShapes[i].ms, "top shapes are sorted by total time")
  end
  -- leave: the 1021-only objects are deleted; come back: shapes without a live instance are reloads
  H.cam = { x = 4100, y = -320, z = 0 }
  settle(s, 40)
  eq(s.getStatus().deletedTotal, 6, "six objects deleted after leaving")
  H.cam = { x = 3950, y = -200, z = 0 }
  settle(s, 40)
  st = s.getStatus()
  eq(st.liveObjectCount, 9, "everything is back")
  check(st.changeReload > 0, "shapes that lost their last instance come back as reloads, not first use")
  eq(st.changeFirstUse, 0, "no shape is new the second time")
  eq(st.changeFirstUse + st.changeReload + st.changeWarm, st.changeCreates, "split still adds up")
end

-- 23. the new-shape deferral uses the recent first-use cost -----------------------------------------
do
  local realClock, ticks, step = os.clock, 0, 0.001
  os.clock = function() ticks = ticks + step; return ticks end
  local s = fresh({ maxCreatesPerFrame = 100, frameBudgetMs = 1000, maxFirstUsePerFrame = 1000 })
  settle(s, 20)
  local st = s.getStatus()
  check(st.expectedFirstUseMs > 0 and st.expectedFirstUseMs < 1000, "expected first-use cost follows the measured creates")
  os.clock = realClock
end

-- 24. registerObject probe, name lookup switch, scene trend, idle baseline ---------------------------
do
  local s = fresh()
  settle(s, 10)
  local before = s.getStatus().liveObjectCount
  local results, err = s.probeRegister(nil, 8)
  check(results ~= nil, "probe runs with a live shape: " .. tostring(err))
  eq(#results, 4, "four passes: unnamed, named, unnamed again, real fields")
  eq(results[4].label, "real", "the last pass uses a real item's fields")
  eq(results[4].failed, 0, "no probe register failed")
  eq(results[1].n, 8, "probe creates the requested number of objects")
  eq(s.getStatus().liveObjectCount, before, "probe leaves the streamed objects alone")
  check(H.byName("nfsc_probe_named_1") == nil and H.byName("nfsc_probe_named_8") == nil, "probe objects are deleted again")
  local none = fresh()
  local r2, e2 = none.probeRegister(nil, 8)
  check(r2 == nil and e2 ~= nil, "probe without any live shape explains itself")
  local logged = false
  for _, line in ipairs(H.logs) do if line:find("probeRegister did not run", 1, true) then logged = true end end
  check(logged, "the reason is also written to the log, not only returned")
  local logged2 = false
  for _, line in ipairs(H.logs) do if line:find("probeRegister called", 1, true) then logged2 = true end end
  check(logged2, "every call leaves a log line")
end
do
  local s = fresh({ skipNameLookup = true })
  settle(s, 10)
  eq(s.getStatus().liveObjectCount, 9, "skipNameLookup still creates everything")
  eq(s.getStatus().failureCount, 0, "no failures without the name check")
end
do
  local realClock, ticks = os.clock, 0
  os.clock = function() ticks = ticks + 0.001; return ticks end
  local s = fresh()
  settle(s, 10)
  H.tick(s, 400, 0.033)                       -- the average starts from the 0.1 s settle ticks and needs time to follow
  local st = s.getStatus()
  check(st.idleFrameMs ~= nil and math.abs(st.idleFrameMs - 33) < 5, "idle frame baseline follows the frame time while nothing loads")
  check(st.changeNameAvgMs >= 0, "name lookup time is reported")
  os.clock = realClock
end

-- 25. the probe runs by itself after a section settled with new objects ------------------------------
do
  local function count(pattern)
    local n = 0
    for _, line in ipairs(H.logs) do if line:find(pattern, 1, true) then n = n + 1 end end
    return n
  end
  local s = fresh()
  local base = count("probe vs real")
  settle(s, 10)
  eq(count("probe vs real") - base, 1, "one probe summary after the section settled")
  check(count("probe named:") >= 1 and count("probe unnamed:") >= 1, "named and unnamed passes are logged")
  eq(s.getStatus().liveObjectCount, 9, "the probe leaves the streamed objects alone")
  H.tick(s, 30, 0.1)
  eq(count("probe vs real") - base, 1, "an idle section does not probe again")
  local off = fresh({ probeOnSettle = false })
  local before = count("probe vs real")
  settle(off, 10)
  eq(count("probe vs real"), before, "probeOnSettle = false keeps the log quiet")
end

-- 26. refused registers, distance buckets, lights state, cap 3 -------------------------------------
do
  H.refuseRegister = true
  local s = fresh()
  settle(s, 10)
  local st = s.getStatus()
  eq(st.liveObjectCount, 0, "an engine that refuses registerObject leaves nothing live")
  check(st.failureCount > 0, "a refused register is counted as a failure, not as a created object")
  H.refuseRegister = false
end
do
  local s = fresh()
  settle(s, 10)
  local st = s.getStatus()
  local d = st.changeWarmByDistance
  local sum = d.c1.n + d.c2.n + d.c3.n
  check(sum <= st.changeWarm, "distance buckets hold warm creates only")
  eq(st.liveObjectCount, 9, "nothing else changed")
  local seen = false
  for _, line in ipairs(H.logs) do if line:find("warm creates by horizontal distance", 1, true) then seen = true end end
  check(seen, "the distance line is logged with the settled block")
end
do
  local s = fresh()
  local untouched = H.load(repo .. "/lua/ge/extensions/nfsc/sectionStreamer.lua")
  eq(untouched.getTuning().maxFirstUsePerFrame, 3, "default cap of new shapes per frame is 3")
  eq(untouched.getTuning().frameBudgetMs, 16, "default frame budget is the tested 16 ms")
  settle(s, 10)
  local on = false
  for _, line in ipairs(H.logs) do if line:find("lights on, emitters on", 1, true) then on = true end end
  check(on, "the settled block says whether lights and emitters were on")
end

-- 27. the section the camera is in jumps ahead of the leftovers of the section it left --------------
do
  local only1021 = { "XTU_SPRINGTREETREELINEB_1A_00_10071", "XTU_TREEDEADB_1A_00_053", "XTU_TREEJPNMAPLE_1A_00_379",
                     "XTU_TREESPINGA_1A_00_291", "XWS_BARRIERCHGATE_1A_00_016", "XWU_CHAINLINKCAS8MA_1B_00_445" }
  local function run(tuning)
    local s = fresh(tuning)
    H.tick(s, 3, 0.1)                                  -- a few objects of 1021, the rest waits in the queue (1022 is read by now)
    H.cam = { x = 3950, y = -310, z = 0 }              -- into 1022 (its own objects: a tree and a house)
    local frames = 0
    while frames < 40 and not (H.byName("XTU_TREESPINGA_1A_00_500") and H.byName("XTU_HOUSE_1A_00_001")) do
      H.tick(s, 1, 0.1)
      frames = frames + 1
    end
    local left = 0
    for _, name in ipairs(only1021) do if not H.byName(name) then left = left + 1 end end
    return s, left, frames
  end
  -- (every fresh() reinstalls the engine mock, so the comparison run goes first)
  local _, leftOff = run({ maxCreatesPerFrame = 1, frameBudgetMs = 1000, currentSectionFirst = false })
  local s, left = run({ maxCreatesPerFrame = 1, frameBudgetMs = 1000 })
  eq(s.getStatus().currentSectionID, 1022, "camera moved into 1022")
  check(left > leftOff, "the new section's objects were created before old-section leftovers (left: " .. left .. " against " .. leftOff .. " without the switch)")
  check(s.getStatus().promotedObjectCount > 0, "queued objects of the new section were moved ahead")
  settle(s, 60)
  local st = s.getStatus()
  eq(st.failureCount, 0, "no failures")
  check(st.queuedObjectCount == 0, "both queues drain")
end
do
  -- a full queue of leftovers does not keep the current section's objects out
  local s = fresh({ maxCreatesPerFrame = 1, frameBudgetMs = 1000, maxQueuedItems = 2 })
  H.tick(s, 1, 0.1)
  H.cam = { x = 3950, y = -310, z = 0 }
  local frames = 0
  while frames < 12 and not H.byName("XTU_HOUSE_1A_00_001") do H.tick(s, 1, 0.1); frames = frames + 1 end
  check(H.byName("XTU_HOUSE_1A_00_001") ~= nil, "the house of the camera's section loads within a few frames despite a full queue")
  settle(s, 60)
  eq(s.getStatus().liveObjectCount, 10, "everything arrives in the end (1022 also brings the 1101 rock)")
end

-- 27. patch 0014: first use split into import / cached / unknown, stall log, empty settles, cache warm-up lane
local MESH = "/levels/nfsc/assets/meshes/"
local function logHas(text)
  for _, line in ipairs(H.logs) do if line:find(text, 1, true) then return true end end
  return false
end
local function logCount(text)
  local n = 0
  for _, line in ipairs(H.logs) do if line:find(text, 1, true) then n = n + 1 end end
  return n
end
do
  -- with FS:fileExists the first use is told apart: one shape already has its .cdae, the others get imported
  H.fsMock, H.preCdae = true, { MESH .. "XTU_TREESPINGA_1A_00.cdae" }
  local s = fresh({ cacheWarm = false })
  settle(s, 40)
  local sp = s.getStatus().changeFirstUseSplit
  eq(sp.cached.n, 1, "27a: one first use found its .cdae")
  check(sp.import.n >= 1 and sp.unknown.n == 0, "27a: the rest are imports, nothing unknown")
  check(logHas("first use split: import (no .cdae yet)"), "27a: the settled block prints the split")
  check(s.getStatus().changeWorkPeakMs >= 0, "27a: the peak frame work is reported")
  check(logHas("(peak "), "27a: the settled header carries the peak")
  -- a shape that was imported earlier in the session counts as cached when it is used for real
  H.fsMock, H.preCdae = false, nil
  local s2 = fresh({ cacheWarm = false })
  settle(s2, 40)
  local sp2 = s2.getStatus().changeFirstUseSplit
  check(sp2.unknown.n >= 1 and sp2.import.n == 0 and sp2.cached.n == 0, "27b: without FS:fileExists every first use is 'unknown'")
end
do
  -- a single create over stallLogMs is logged at once with its kind
  local s = fresh({ cacheWarm = false, stallLogMs = 0 })
  settle(s, 40)
  check(logHas("slow create: "), "27c: slow create line")
  check(logHas("first use, unknown"), "27c: ... with the first use kind")
  H.logs = {}
  local quiet = fresh({ cacheWarm = false })
  settle(quiet, 40)
  check(not logHas("slow create: "), "27c: nothing is logged below stallLogMs")
end
do
  -- a change that created nothing prints no settled block unless asked to
  local function run(tuning)
    local s = fresh(tuning)
    settle(s, 40)
    local before = logCount("settled:")
    H.cam = { x = 3950, y = -310, z = 0 }              -- into 1022: its objects load, then the camera goes back
    settle(s, 40)
    H.cam = { x = 3950, y = -200, z = 0 }
    settle(s, 40)
    return before, logCount("settled:"), s
  end
  local before, after = run({ cacheWarm = false, unloadCooldown = 1000 })
  eq(after - before, 1, "27d: only the change that created objects prints a block")
  local before2, after2 = run({ cacheWarm = false, unloadCooldown = 1000, logEmptySettles = true })
  eq(after2 - before2, 2, "27d: logEmptySettles brings the empty one back")
end
do
  -- the warm-up lane walks every shape once: used ones and ones with a .cdae are skipped, the rest imported
  H.fsMock, H.preCdae = true, { MESH .. "XTU_TREESPINGA_1A_00.cdae" }
  local baseline = fresh({ cacheWarm = false })       -- (every fresh() reinstalls the mock, so the comparison run goes first)
  settle(baseline, 80)
  local liveWithout = baseline.getStatus().liveObjectCount
  local s = fresh({ cacheWarmIdleSeconds = 0, cacheWarmGapSeconds = 0, cacheWarmPerFrame = 1, maxCreatesPerFrame = 1, frameBudgetMs = 1000 })
  H.tick(s, 3, 0.1)
  eq(s.getCacheWarmStatus().imported, 0, "27e: the lane waits while the load queues have work")
  settle(s, 80)
  local w = s.getCacheWarmStatus()
  check(w.available and w.finished, "27e: the lane finished")
  eq(w.total, 9, "27e: all unique shapes of shapes.json")
  eq(w.processed, 9, "27e: every shape was looked at once")
  eq(w.failed, 0, "27e: no failures")
  eq(w.imported + w.alreadyCached + w.skipped, 9, "27e: imported + already cached + skipped covers everything")
  check(w.imported >= 1, "27e: shapes nobody used yet were imported (" .. w.imported .. ")")
  check(#H.imported >= w.imported, "27e: the engine wrote their .cdae")
  eq(s.getStatus().liveObjectCount, liveWithout, "27e: the warm-up objects are gone again, only the streamed ones are live")
  check(logHas("cache warm finished"), "27e: finish line")
  -- the same shapes are not imported twice
  local importedNow = w.imported
  settle(s, 40)
  eq(s.getCacheWarmStatus().imported, importedNow, "27e: a finished lane does nothing more")
  H.fsMock, H.preCdae = false, nil
end
do
  -- no FS:fileExists: the lane stays off instead of importing blindly
  local s = fresh({ cacheWarmIdleSeconds = 0, cacheWarmGapSeconds = 0 })
  settle(s, 60)
  local w = s.getCacheWarmStatus()
  check(not w.available and w.imported == 0, "27f: the lane switched itself off")
  check(logHas("FS:fileExists is not available"), "27f: and says why")
  -- switched off by tuning: nothing happens either
  H.fsMock = true
  local off = fresh({ cacheWarm = false, cacheWarmIdleSeconds = 0, cacheWarmGapSeconds = 0 })
  settle(off, 60)
  eq(off.getCacheWarmStatus().imported, 0, "27f: cacheWarm = false keeps the lane idle")
  off.setCacheWarm(true)
  settle(off, 60)
  check(off.getCacheWarmStatus().finished, "27f: setCacheWarm(true) starts it")
  off.restartCacheWarm()
  check(not off.getCacheWarmStatus().finished and off.getCacheWarmStatus().processed == 0, "27f: restartCacheWarm starts over")
  H.fsMock = false
end

-- 28. patch 0015: shell pool (creationMode = "shells") ---------------------------------------------
do
  local DOT = "/levels/nfsc/Assets/Meshes/NFSC_DOT.dae"
  local s = fresh({ creationMode = "shells" })
  local made = {}
  s.addListener({ onObjectCreated = function(self, key, obj, item) made[item.name] = { key = key, obj = obj, item = item } end })
  settle(s, 5)
  local st = s.getStatus()
  eq(st.creationMode, "shells", "28a: mode is shells")
  check(st.shellPoolActive, "28a: pool active")
  eq(st.liveObjectCount, 9, "28a: same objects as the current way")
  eq(st.shellsFresh, 9, "28a: empty pool: every object is created the current way")
  eq(st.shellsRecycled, 0, "28a: nothing recycled yet")
  local gate = made["XWS_BARRIERCHGATE_1A_00_016"]
  check(gate and gate.obj.name:find("^nfsc_shell_"), "28a: pooled objects are named nfsc_shell_<n>")
  check(gate.obj.fields.sectionOverrideName ~= nil and gate.obj.fields.instanceFlags ~= nil, "28a: the gate carries override and flags")

  -- 28b: released objects are parked, not deleted
  s.releaseObject(gate.key, gate.item)
  settle(s, 40)
  st = s.getStatus()
  eq(st.liveObjectCount, 8, "28b: the gate left the live set")
  eq(st.shellsFree, 1, "28b: and sits in the pool")
  eq(st.shellsParked, 1, "28b: parked once")
  check(not gate.obj.deleted and H.byName(gate.obj.name) == gate.obj, "28b: the engine object still exists")
  eq(gate.obj.fields.shapeName, DOT, "28b: a parked shell shows the dot shape")
  eq(gate.obj.hidden, true, "28b: and is hidden")
  check((gate.obj.postApplied or 0) >= 1, "28b: postApply was called")
  eq(st.deletedTotal, 1, "28b: counted as a release")

  -- 28c: the next load takes the parked shell and fills it in; stale fields go back to the default
  H.cam = { x = 4100, y = -320, z = 0 }
  H.tick(s, 3, 0.1)
  local rock = made["XTU_ROCK_1A_00_002"]
  check(rock ~= nil, "28c: the rock was created")
  check(rock.obj == gate.obj, "28c: it reuses the parked gate shell")
  st = s.getStatus()
  eq(st.shellsRecycled, 1, "28c: one recycle")
  eq(st.shellsFree, 0, "28c: pool empty again")
  eq(rock.obj.fields.shapeName, rock.item.shapeName, "28c: shapeName of the new item")
  eq(rock.obj.fields.scale, "1.5 1.5 1.5", "28c: scale of the new item")
  eq(rock.obj.fields.sectionOverrideName, "", "28c: the gate's override name is cleared (engine default)")
  eq(rock.obj.fields.instanceFlags, "", "28c: and its flags")
  eq(rock.obj.fields.isRenderEnabled, "1", "28c: isRenderEnabled stays as exported")
  eq(rock.obj.fields.collisionType, "None", "28c: collision forced off again")
  eq(rock.obj.hidden, false, "28c: shown")

  -- 28d: leaving 1021 parks its objects; coming back reuses them, the group does not grow
  settle(s, 40)
  st = s.getStatus()
  eq(st.liveObjectCount, 4, "28d: pole + 1022's two + rock")
  eq(st.shellsFree, 5, "28d: the other five are parked")
  local group = H.byName("NFSC_StreamedScenery")
  eq(#group.children, 9, "28d: nothing was deleted, nothing added")
  H.cam = { x = 3950, y = -200, z = 0 }
  settle(s, 40)
  st = s.getStatus()
  eq(st.liveObjectCount, 9, "28d: back in 1021 everything is live again")
  eq(st.shellsRecycled, 6, "28d: five more recycles")
  eq(st.shellsFresh, 10, "28d: one fresh create for the gate (nine plus one)")
  check(#group.children >= st.shellPeakLive and #group.children <= st.createdTotal, "28d: group size follows the peak, not the traffic")
  eq(st.failureCount, 0, "28d: no failures")
  check(st.shellRecycleAvgMs >= 0 and st.shellParkAvgMs >= 0, "28d: timing counters exist")
end
do
  -- 28e: shells are built ahead up to the target, a few per frame, only while nothing urgent waits
  local s = fresh({ creationMode = "shells", shellTarget = 20, shellBuildPerFrame = 4, maxCreatesPerFrame = 2 })
  H.tick(s, 1, 0.1)
  check(s.getStatus().queuedUrgentCount > 0, "28e: the current section is still loading")
  eq(s.getStatus().shellsBuilt, 0, "28e: no shell is built while urgent objects wait")
  settle(s, 60)
  local st = s.getStatus()
  eq(st.liveObjectCount, 9, "28e: all objects arrived")
  eq(st.shellsFree + st.liveObjectCount, 20, "28e: free + live reaches the target exactly")
  eq(st.shellsBuilt + st.shellsFresh, 20, "28e: every pooled object was built ahead or created fresh")
  check(st.shellsBuilt >= 11, "28e: at least the eleven spare ones were built ahead")
  local group = H.byName("NFSC_StreamedScenery")
  eq(#group.children, 20, "28e: all of them live in the runtime group")
  local hiddenDots = 0
  for _, o in ipairs(group.children) do
    if o.hidden and o.fields.shapeName == "/levels/nfsc/Assets/Meshes/NFSC_DOT.dae" then hiddenDots = hiddenDots + 1 end
  end
  eq(hiddenDots, st.shellsFree, "28e: the free ones are hidden dots")
  eq(s.buildShells(3), 3, "28e: buildShells(n) builds at once")
  eq(s.getStatus().shellsFree, st.shellsFree + 3, "28e: and they are free")
  local freshBefore, recycledBefore = s.getStatus().shellsFresh, s.getStatus().shellsRecycled
  -- the next section change needs no fresh create for its first objects
  H.cam = { x = 4100, y = -320, z = 0 }
  H.tick(s, 3, 0.1)
  eq(s.getStatus().shellsFresh, freshBefore, "28e: a build-ahead pool means no fresh create")
  eq(s.getStatus().shellsRecycled, recycledBefore + 1, "28e: the rock took a built shell")
end
do
  -- 28f: switching modes and the shell shape check
  H.fsMock = true
  local s = fresh({ creationMode = "current" })
  settle(s, 5)
  local ok, why = s.setCreationMode("shells")
  check(not ok and why == "shellShape not found", "28f: refused while FS says the shell shape is missing")
  eq(s.getCreationMode(), "current", "28f: mode unchanged")
  check(select(1, s.setCreationMode("bogus")) == false, "28f: unknown mode refused")
  H.cdaeFiles["/levels/nfsc/Assets/Meshes/NFSC_DOT.dae"] = true            -- the mock's FS:fileExists now finds it
  ok = s.setCreationMode("shells")
  check(ok and s.getCreationMode() == "shells", "28f: accepted once the shape exists")
  eq(s.buildShells(4), 4, "28f: four shells")
  eq(s.getStatus().shellsFree, 4, "28f: pool has four")
  check(s.setCreationMode("current"), "28f: back to current")
  eq(s.getStatus().shellsFree, 0, "28f: parked shells are deleted when leaving shells mode")
  eq(#H.byName("NFSC_StreamedScenery").children, 9, "28f: only the nine live objects remain in the group")
  H.fsMock = false
  -- configured as shells from the start with a missing shape: falls back to the current way and says so
  H.fsMock = true
  local t = fresh({ creationMode = "shells" })
  settle(t, 5)
  eq(t.getStatus().liveObjectCount, 9, "28f: the missing shape does not stop streaming")
  check(not t.getStatus().shellPoolActive, "28f: the pool switched itself off")
  check(t.getStatus().failureCount >= 1, "28f: and recorded why")
  H.fsMock = false
end
do
  -- 28g: building stops after repeated failures, streaming goes on, reset empties the pool
  local s = fresh({ creationMode = "shells" })
  settle(s, 5)
  H.refuseRegister = true
  s.setTuning({ shellTarget = 50 })
  settle(s, 10)
  H.refuseRegister = false
  local st = s.getStatus()
  eq(st.shellsBuilt, 0, "28g: nothing was built")
  eq(st.failureCount, 1, "28g: one failure line, not one per frame")
  eq(st.liveObjectCount, 9, "28g: the live objects are untouched")
  s.buildShells(2)
  eq(s.getStatus().shellsFree, 2, "28g: manual building still works")
  s.setTuning({ shellTarget = 0 })
  s.reset()
  st = s.getStatus()
  eq(st.shellsFree, 0, "28g: reset empties the pool")
  eq(st.shellsRecycled + st.shellsFresh + st.shellsParked, 0, "28g: and the counters")
  settle(s, 5)
  eq(s.getStatus().liveObjectCount, 9, "28g: reset streams everything again")
end

-- 29. patch 0016: resident mode ----------------------------------------------------------------------
do
  local DOT = "/levels/nfsc/Assets/Meshes/NFSC_DOT.dae"
  local s = fresh({ creationMode = "resident" })
  local made = {}
  s.addListener({ onObjectCreated = function(self, key, obj, item) made[item.name] = { key = key, obj = obj, item = item } end })
  settle(s, 5)
  local st = s.getStatus()
  check(st.residentActive and st.shellPoolActive, "29a: resident mode is active")
  eq(st.liveObjectCount, 9, "29a: same objects as the other modes")
  eq(st.shellsFresh, 9, "29a: the pool starts empty")
  H.cam = { x = 4100, y = -320, z = 0 }
  settle(s, 5)
  st = s.getStatus()
  eq(st.liveObjectCount, 4, "29b: pole + 1022's two + rock")
  eq(st.residentDormant, 6, "29b: the six objects of 1021 rest, no cooldown")
  eq(st.residentDeactivated, 6, "29b: six deactivations")
  eq(st.shellsParked, 0, "29b: nothing is parked on the dot")
  eq(st.shellsFree, 0, "29b: and no shell was released")
  local group = H.byName("NFSC_StreamedScenery")
  eq(#group.children, 10, "29b: nine plus the rock, nothing deleted")
  local gate = made["XWS_BARRIERCHGATE_1A_00_016"]
  check(gate.obj.hidden == true and not gate.obj.deleted, "29b: a resting object is hidden and still there")
  eq(gate.obj.fields.shapeName, gate.item.shapeName, "29b: it keeps its shape")
  eq(gate.obj.postApplied or 0, 0, "29b: no field writes happened")
  -- the resting objects without an override (the manager does not hide those)
  local resting = {}
  for name, m in pairs(made) do
    if m.obj.hidden and m.item.sectionOverrideName == nil then resting[#resting + 1] = { name = name, obj = m.obj, applied = m.obj.postApplied or 0 } end
  end
  check(#resting >= 4, "29b: at least four resting objects without an override")
  local freshBefore = st.shellsFresh
  H.cam = { x = 3950, y = -200, z = 0 }
  settle(s, 5)
  st = s.getStatus()
  eq(st.liveObjectCount, 9, "29c: back in 1021")
  eq(st.residentRevived, 6, "29c: the six come back by revive")
  eq(st.shellsFresh, freshBefore, "29c: no fresh create")
  eq(st.shellsRecycled, 0, "29c: and no recycle")
  local allBack = true
  for _, r in ipairs(resting) do
    if r.obj.hidden or (r.obj.postApplied or 0) ~= r.applied or made[r.name].obj ~= r.obj then allBack = false end
  end
  check(allBack, "29c: same objects, shown, no field writes")
  eq(st.residentDormant, 1, "29c: the rock rests now")
  check(st.residentReviveAvgMs >= 0, "29c: revive timing exists")
  eq(st.failureCount, 0, "29c: no failures")

  -- 29d: leaving resident mode
  H.cam = { x = 4100, y = -320, z = 0 }
  settle(s, 5)
  eq(s.getStatus().residentDormant, 6, "29d: six rest again")
  check(s.setCreationMode("shells"), "29d: switch to shells")
  st = s.getStatus()
  eq(st.residentDormant, 0, "29d: nobody rests in shells mode")
  eq(st.shellsFree, 6, "29d: the six are parked shells now")
  eq(gate.obj.fields.shapeName, DOT, "29d: on the dot")
  check(s.setCreationMode("resident"), "29d: and back")
  H.cam = { x = 3950, y = -200, z = 0 }
  settle(s, 5)
  eq(s.getStatus().liveObjectCount, 9, "29d: everything live again")
  H.cam = { x = 4100, y = -320, z = 0 }
  settle(s, 5)
  check(s.setCreationMode("current"), "29d: switch to current")
  eq(s.getStatus().shellsFree, 0, "29d: pool is empty")
  eq(#H.byName("NFSC_StreamedScenery").children, s.getStatus().liveObjectCount, "29d: only live objects remain")
end
do
  -- 29e: the pool cap evicts the oldest resting object; the group never outgrows it
  local s = fresh({ creationMode = "resident", residentMax = 9 })
  settle(s, 5)
  H.cam = { x = 4100, y = -320, z = 0 }
  settle(s, 5)
  local st = s.getStatus()
  eq(st.liveObjectCount, 4, "29e: rock side")
  check(st.residentEvicted >= 1, "29e: the rock took an evicted shell")
  eq(st.shellsFresh, 9, "29e: no tenth object was created")
  eq(#H.byName("NFSC_StreamedScenery").children, 9, "29e: the group stays at the cap")
  H.cam = { x = 3950, y = -200, z = 0 }
  settle(s, 10)
  st = s.getStatus()
  eq(st.liveObjectCount, 9, "29e: everything is back, evicted ones were refilled")
  check(#H.byName("NFSC_StreamedScenery").children <= 10, "29e: the group is still at the cap (the rock may need one more)")
  eq(st.failureCount, 0, "29e: no failures")
end
do
  -- 29f: the free reserve is kept by evicting in idle frames
  local s = fresh({ creationMode = "resident", residentMax = 9, residentReserve = 3 })
  settle(s, 5)
  H.cam = { x = 4100, y = -320, z = 0 }
  settle(s, 10)
  local st = s.getStatus()
  check(st.shellsFree >= 3, "29f: at least three shells are free")
  eq(st.liveObjectCount, 4, "29f: live objects unchanged")
  check(st.poolTotal <= 9, "29f: pool at the cap")
end

-- 30. patch 0016: live tuning and presets ------------------------------------------------------------
do
  H.files = {}
  local s = fresh()
  local defaults = s.getDefaultTuning()
  eq(defaults.maxCreatesPerFrame, 16, "30a: defaults are available")
  s.setTuning({ maxCreatesPerFrame = 3, frameBudgetMs = 7.5 })
  check(s.savePreset("A"), "30b: save a preset")
  check(not s.savePreset(""), "30b: an empty name is refused")
  eq(table.concat(s.listPresets(), ","), "A", "30b: listed")
  s.setTuning({ maxCreatesPerFrame = 9 })
  check(s.loadPreset("A"), "30c: load it")
  eq(s.getTuning().maxCreatesPerFrame, 3, "30c: values applied")
  eq(s.getTuning().frameBudgetMs, 7.5, "30c: all of them")
  check(not s.loadPreset("nope"), "30c: unknown preset")
  s.resetTuning()
  eq(s.getTuning().maxCreatesPerFrame, 16, "30d: reset restores the defaults")
  eq(s.getTuning().frameBudgetMs, 16.0, "30d: all of them")
  -- values of the wrong type or unknown keys are ignored
  H.files["levels/nfsc/lua/carbon_stream/tuning_presets.json"].bad = { maxCreatesPerFrame = "many", nonsense = 5, logSettle = false }
  check(s.loadPreset("bad"), "30e: a damaged preset still loads")
  eq(s.getTuning().maxCreatesPerFrame, 16, "30e: wrong type ignored")
  eq(s.getTuning().logSettle, false, "30e: valid key applied")
  check(s.deletePreset("bad") and s.deletePreset("A"), "30f: delete")
  eq(#s.listPresets(), 0, "30f: none left")
  -- a preset named startup (with a creation mode) is applied at initialize
  s.setCreationMode("resident")
  s.setTuning({ residentMax = 1234 })
  s.savePreset("startup")
  local t = fresh()
  eq(t.getCreationMode(), "resident", "30g: startup preset sets the creation mode")
  eq(t.getTuning().residentMax, 1234, "30g: and the values")
  H.logs = {}
  t.printTuning()
  local printed = false
  for _, line in ipairs(H.logs) do if line:find("residentMax = 1234", 1, true) then printed = true end end
  check(printed, "30h: printTuning lists the values")
  H.files = {}
end

-- 31. patch 0016: dropped sections -------------------------------------------------------------------
do
  local s = fresh({ maxCreatesPerFrame = 1 })
  H.logs = {}
  H.tick(s, 2, 0.1)
  H.cam = { x = 4100, y = -320, z = 0 }
  H.tick(s, 3, 0.1)
  local st = s.getStatus()
  eq(st.droppedSections, 1, "31a: leaving before the load settled counts as a dropped section")
  check(st.droppedLast and st.droppedLast.queued + st.droppedLast.waiting + st.droppedLast.reads > 0, "31a: it knows what was missing")
  local logged = false
  for _, line in ipairs(H.logs) do if line:find("dropped section", 1, true) then logged = true end end
  check(logged, "31a: and logs it")
  s.setTuning({ maxCreatesPerFrame = 16 })
  settle(s, 20)
  H.cam = { x = 3950, y = -200, z = 0 }
  settle(s, 20)
  H.cam = { x = 4100, y = -320, z = 0 }
  settle(s, 20)
  eq(s.getStatus().droppedSections, 1, "31b: sections that settled are not dropped")
  s.reset()
  eq(s.getStatus().droppedSections, 0, "31c: reset clears the counter")
end

-- 32. patch 0016: panel smoke test (mock imgui) ------------------------------------------------------
do
  local s, m = fresh()
  settle(s, 5)
  local texts, clicks, sliders = {}, {}, {}
  local function ptr(v) return { [0] = v } end
  local im
  im = setmetatable({
    BoolPtr = ptr, IntPtr = ptr, FloatPtr = ptr,
    Begin = function() return true end,
    Text = function(t) texts[#texts + 1] = t end,
    TextDisabled = function(t) texts[#texts + 1] = t end,
    CollapsingHeader1 = function() return true end,
    TreeNode1 = function() return true end,
    TreeNodeEx1 = function() return true end,
    RadioButton1 = function(label) return clicks[label] == true end,
    Button = function(label) return clicks[label] == true end,
    SliderInt = function(label, p) if sliders[label] then p[0] = sliders[label]; return true end return false end,
    SliderFloat = function(label, p) if sliders[label] then p[0] = sliders[label]; return true end return false end,
    Checkbox = function(label, p) if sliders[label] ~= nil then p[0] = sliders[label]; return true end return false end,
  }, { __index = function() return function() return false end end })
  ui_imgui = im
  local ui = H.load(repo .. "/lua/ge/extensions/nfsc/sectionManagerUi.lua")
  clicks["Resident##creation"] = true
  sliders["Max refills per frame###tmaxRefillsPerFrame"] = 5
  sliders["Look-ahead###tpredictionEnabled"] = false
  clicks["Save##pA"] = true
  ui.onUpdate()
  clicks, sliders = {}, {}
  check(ui ~= nil, "32a: the panel loads")
  eq(s.getCreationMode(), "resident", "32b: the radio switches the creation mode")
  eq(s.getTuning().maxRefillsPerFrame, 5, "32c: a slider changes the tuning at once")
  eq(s.getTuning().predictionEnabled, false, "32c: so does a checkbox")
  eq(table.concat(s.listPresets(), ","), "resident/A", "32d: the save button saves the slot of the active mode")
  texts = {}
  ui.onUpdate()                                  -- the next frame shows the new mode
  local sawDropped, sawPool = false, false
  for _, t in ipairs(texts) do
    if t:find("Dropped sections: 0", 1, true) then sawDropped = true end
    if t:find("Pool: ", 1, true) then sawPool = true end
  end
  check(sawDropped and sawPool, "32e: the panel shows the dropped counter and the pool line")
  clicks["Reset to defaults"] = true
  ui.onUpdate()
  clicks = {}
  eq(s.getTuning().maxCreatesPerFrame, 16, "32f: reset to defaults")
  eq(s.getCreationMode(), "current", "32f: including the creation mode")
  ui_imgui = nil
  H.files = {}
end

-- 34. frame budget: every task is capped by the main budget and the shares follow it ------------------
do
  local s = fresh({ creationMode = "shells" })
  settle(s, 5)
  s.setTuning({ shellTarget = 50, frameBudgetMs = 0 })
  settle(s, 10)
  eq(s.getStatus().shellsBuilt, 0, "34a: with no frame budget no shell is built ahead")
  s.setTuning({ frameBudgetMs = 16 })
  settle(s, 10)
  check(s.getStatus().shellsBuilt > 0, "34a: with a budget they are built")
  s.setTuning({ frameBudgetMs = 20, shellBuildBudgetShare = 0.5, deleteBudgetShare = 0.25, cacheWarmCheckShare = 0.1 })
  local caps = s.getStatus().frameBudget.capsMs
  eq(caps.shells, 10, "34b: shell build cap = share x main budget")
  eq(caps.deletes, 5, "34b: delete cap too")
  eq(caps.warmCheck, 2, "34b: and the warm-up check")
  s.setTuning({ frameBudgetMs = 8 })
  caps = s.getStatus().frameBudget.capsMs
  eq(caps.shells, 4, "34c: changing the main budget rescales the shell cap")
  eq(caps.deletes, 2, "34c: and the delete cap")
  -- section reads: the first always goes, more only while the frame has budget left
  local r0 = fresh({ frameBudgetMs = 0, maxSectionReadsPerFrame = 8 })
  H.tick(r0, 1, 0.016)
  eq(r0.getStatus().queuedSectionReads, 1, "34d: a spent frame budget allows one section read per frame")
  local r1 = fresh({ frameBudgetMs = 1000, maxSectionReadsPerFrame = 8 })
  H.tick(r1, 1, 0.016)
  eq(r1.getStatus().queuedSectionReads, 0, "34d: with budget all reads of the frame go")
  local b = r1.getStatus().frameBudget
  check(b.mainMs == 1000 and b.avgMs.reads >= 0 and b.lastMs.creates >= 0, "34e: the per-task timing is reported")
end

-- 35. tuning is checked, clamped and its changes are remembered --------------------------------------
do
  local s = fresh()
  local rev = s.getTuningInfo().revision
  local changed, rejected = s.setTuning({ maxCreatesPerFrame = 7.6, frameBudgetMs = 12, nonsense = 1, logSettle = "yes" })
  eq(#changed, 2, "35a: two real changes")
  eq(#rejected, 2, "35a: unknown key and wrong type are rejected")
  eq(s.getTuning().maxCreatesPerFrame, 8, "35a: an integer setting is rounded")
  local info = s.getTuningInfo()
  eq(info.revision, rev + 1, "35b: the revision counts the change")
  eq(info.last.source, "setTuning", "35b: and where it came from")
  s.setTuning({ maxCreatesPerFrame = 0, deleteBudgetShare = 7, maxQueuedItems = -5 })
  eq(s.getTuning().maxCreatesPerFrame, 1, "35c: a count cannot go below its hard minimum")
  eq(s.getTuning().deleteBudgetShare, 1, "35c: a share cannot exceed the whole frame budget")
  eq(s.getTuning().maxQueuedItems, 1, "35c: negative counts are clamped")
  s.setTuning({ frameBudgetMs = 250.5, shellTarget = 99999 })
  eq(s.getTuning().frameBudgetMs, 250.5, "35d: values far beyond the slider range are accepted")
  eq(s.getTuning().shellTarget, 99999, "35d: also integers")
  local none = s.setTuning({ frameBudgetMs = 250.5 })
  eq(#none, 0, "35e: setting the same value changes nothing")
  eq(s.getTuningInfo().revision, rev + 3, "35e: and does not bump the revision")
  s.setTuning({ creationMode = "resident" })
  eq(s.getCreationMode(), "resident", "35f: creationMode through setTuning goes through the mode switch")
  check(s.getStatus().residentActive, "35f: so the resident state is really on")
  -- presets saved before the budgets became shares are converted
  H.files["levels/nfsc/lua/carbon_stream/tuning_presets.json"] = { old = { frameBudgetMs = 20, shellBuildBudgetMs = 5, cacheWarmCheckMs = 2 } }
  check(s.loadPreset("old"), "35g: an old preset loads")
  eq(s.getTuning().shellBuildBudgetShare, 0.25, "35g: shell build ms became a share of the budget saved with it")
  eq(s.getTuning().cacheWarmCheckShare, 0.1, "35g: so did the warm-up check")
  H.files = {}
end

-- 36. three presets per creation mode ------------------------------------------------------------------
do
  H.files = {}
  local s = fresh()
  local list = s.getModePresets("shells")
  eq(#list, 3, "36a: three slots per mode")
  eq(list[1].source, "factory", "36a: untouched slots hold factory values")
  check(s.loadModePreset("shells", "B"), "36b: a factory slot loads")
  eq(s.getCreationMode(), "shells", "36b: and sets its mode")
  eq(s.getTuning().shellTarget, 3500, "36b: with its values")
  eq(s.getTuning().predictionEnabled, true, "36b: settings the preset does not hold stay as they were")
  local ok = s.saveModePreset("resident", "A")
  check(not ok, "36c: only the active mode's slots can be saved")
  s.setTuning({ frameBudgetMs = 11 })
  check(s.saveModePreset("shells", "A"), "36d: save into the active mode")
  eq(s.getModePresets("shells")[1].source, "saved", "36d: the slot shows as saved")
  eq(s.getModePresets("resident")[1].source, "factory", "36d: other modes are independent")
  eq(s.getModePresets("current")[1].source, "factory", "36d: all of them")
  s.setTuning({ frameBudgetMs = 30 })
  s.loadModePreset("shells", "A")
  eq(s.getTuning().frameBudgetMs, 11, "36e: the saved values come back")
  check(s.deleteModePreset("shells", "A"), "36f: delete returns the slot to factory")
  eq(s.getModePresets("shells")[1].source, "factory", "36f: factory again")
  check(not s.loadModePreset("shells", "Z"), "36g: unknown slot refused")
  check(not s.loadModePreset("nope", "A"), "36g: unknown mode refused")
  -- a flat A from before belongs to the mode it was saved in
  H.files["levels/nfsc/lua/carbon_stream/tuning_presets.json"] = { A = { creationMode = "resident", residentMax = 777 } }
  eq(s.getModePresets("resident")[1].source, "saved", "36h: an old flat slot shows in its own mode")
  eq(s.getModePresets("current")[1].source, "factory", "36h: not in the others")
  s.loadModePreset("resident", "A")
  eq(s.getTuning().residentMax, 777, "36h: and loads")
  H.files = {}
end

-- 37. purge ---------------------------------------------------------------------------------------------
do
  check(nfsc_sectionStreamer ~= nil, "37: setup")
  -- current mode, in the middle of a load
  local s, m = fresh({ maxCreatesPerFrame = 1 })
  H.tick(s, 3, 0.016)
  local mid = s.getStatus()
  check(mid.liveObjectCount > 0 and mid.liveObjectCount < 9, "37a: a load is in progress")
  local rep = s.purge({})
  check(rep and rep.ok, "37a: the purge verifies clear: " .. (rep and table.concat(rep.problems, "; ") or "no report"))
  eq(rep.removedLive, mid.liveObjectCount, "37a: every live object removed")
  check(rep.cancelled.queued + rep.cancelled.pending > 0, "37a: waiting jobs were cancelled")
  local st = s.getStatus()
  eq(st.liveObjectCount, 0, "37b: nothing live")
  eq(st.queuedObjectCount, 0, "37b: nothing queued")
  eq(st.createdTotal, 0, "37b: statistics were reset")
  eq(m.getStatus().managedObjectsLive, 0, "37b: the manager's bookkeeping is clear")
  eq(rep.sceneObjects, 0, "37b: the engine's scene is clear")
  settle(s, 40)
  eq(s.getStatus().liveObjectCount, 9, "37c: without hold, streaming starts again from the camera, as after a level load")
  -- hold: cancelled jobs cannot come back, nothing is created until resumed
  H.tick(s, 1, 0.016)
  local held = s.purge({ hold = true })
  check(held.held and s.isSuspended(), "37d: hold suspends streaming")
  settle(s, 30)
  eq(s.getStatus().liveObjectCount, 0, "37d: nothing is created while held")
  s.setSuspended(false)
  settle(s, 40)
  eq(s.getStatus().liveObjectCount, 9, "37d: resuming streams the camera's section")
  -- shells: live objects are parked, a released pool is empty and the scene agrees
  local t = fresh({ creationMode = "shells" })
  settle(t, 10)
  local kept = t.purge({})
  check(kept.ok, "37e: shells purge verifies: " .. table.concat(kept.problems, "; "))
  eq(kept.poolAfter.shellsFree, 9, "37e: the objects were parked")
  eq(kept.sceneObjects, 9, "37e: the scene holds exactly the parked shells")
  settle(t, 30)
  check(t.getStatus().shellsRecycled > 0, "37e: the next load recycles them")
  local rel = t.purge({ releasePool = true })
  check(rel.ok, "37f: a released pool verifies: " .. table.concat(rel.problems, "; "))
  eq(rel.poolAfter.shellsFree, 0, "37f: no parked shells")
  eq(rel.sceneObjects, 0, "37f: and an empty scene")
  -- resident
  local r = fresh({ creationMode = "resident" })
  settle(r, 10)
  local rr = r.purge({})
  check(rr.ok, "37g: resident purge verifies: " .. table.concat(rr.problems, "; "))
  eq(rr.poolAfter.dormant, 9, "37g: the objects rest as deactivated")
  local rr2 = r.purge({ releasePool = true })
  check(rr2.ok and rr2.poolAfter.dormant == 0, "37g: released")
  local u = nfsc_sectionStreamer
  local before = u.getStatus().lastPurge
  check(before ~= nil, "37h: the last purge is reported in the status")
  eq(select("#", s.resetStats()), 0, "37i: resetStats works on its own")
end

-- 38. the panel builds itself from the schema and follows the mode -------------------------------------
do
  local s = fresh()
  settle(s, 5)
  local labels, tips, clicks, sliders, inputs, sliderVals = {}, {}, {}, {}, {}, {}
  local function ptr(v) return { [0] = v } end
  local im = setmetatable({
    BoolPtr = ptr, IntPtr = ptr, FloatPtr = ptr,
    Begin = function() return true end,
    CollapsingHeader1 = function() return true end,
    TreeNode1 = function() return true end,
    TreeNodeEx1 = function() return true end,
    RadioButton1 = function(label) return clicks[label] == true end,
    Button = function(label) return clicks[label] == true end,
    Checkbox = function(label, p) labels[#labels + 1] = label; if sliders[label] ~= nil then p[0] = sliders[label]; return true end return false end,
    SliderInt = function(label, p) labels[#labels + 1] = label; sliderVals[label] = p[0]; if sliders[label] then p[0] = sliders[label]; return true end return false end,
    SliderFloat = function(label, p) labels[#labels + 1] = label; sliderVals[label] = p[0]; if sliders[label] then p[0] = sliders[label]; return true end return false end,
    InputInt = function(label, p) inputs[label] = "int"; if sliders[label] then p[0] = sliders[label]; return true end return false end,
    InputFloat = function(label, p) inputs[label] = "float"; if sliders[label] then p[0] = sliders[label]; return true end return false end,
    IsItemHovered = function() return true end,
    GetFontSize = function() return 14 end,
    TextUnformatted = function(t) tips[#tips + 1] = t end,
  }, { __index = function() return function() return false end end })
  ui_imgui = im
  local ui = H.load(repo .. "/lua/ge/extensions/nfsc/sectionManagerUi.lua")
  local function frame()
    labels, tips = {}, {}
    ui.onUpdate()
  end
  local function has(prefix)
    for _, l in ipairs(labels) do if l:find(prefix, 1, true) then return true end end
    return false
  end
  frame()
  check(has("Max creates per frame"), "38a: a common setting shows in current mode")
  check(not has("Pool size") and not has("Shells built ahead") and not has("Deactivate delay"), "38a: pool settings are hidden in current mode")
  check(has("Unload cooldown"), "38a: the unload cooldown shows")
  clicks["Shells##creation"] = true
  frame(); clicks = {}
  frame()
  check(has("Shells built ahead") and has("Shell build share"), "38b: shell settings appear in shells mode")
  check(not has("Pool size") and not has("Deactivate delay"), "38b: resident-only settings stay hidden")
  clicks["Resident##creation"] = true
  frame(); clicks = {}
  frame()
  check(has("Pool size") and has("Deactivate delay"), "38c: resident settings appear in resident mode")
  check(not has("Unload cooldown"), "38c: the unload cooldown is hidden (resident uses its own delay)")
  s.setTuning({ predictionEnabled = false })
  frame()
  check(not has("Look-ahead time"), "38d: a dependent setting hides while its switch is off")
  s.setTuning({ predictionEnabled = true })
  -- every shown setting has its tooltip
  frame()
  local joined = table.concat(tips, "\n")
  local missing = {}
  local tuning = s.getTuning()
  for _, row in ipairs(s.getTuningSchema()) do
    local applies = (not row.modes or row.modes[tuning.creationMode]) and (not row.requires or tuning[row.requires])
    if applies and not joined:find(row.desc:sub(1, 40), 1, true) then missing[#missing + 1] = row.key end
  end
  eq(table.concat(missing, ","), "", "38e: every shown setting has its tooltip")
  for _, row in ipairs(s.getTuningSchema()) do check(#row.desc > 20, "38e: " .. row.key .. " has a real description") end
  -- shares are edited in ms of the main budget and follow it
  s.setTuning({ frameBudgetMs = 16, deleteBudgetShare = 0.25 })
  frame()
  eq(sliderVals["Delete / park share###tdeleteBudgetShare"], 4, "38f: a share is shown in ms of the main budget")
  s.setTuning({ frameBudgetMs = 8 })
  frame()
  eq(sliderVals["Delete / park share###tdeleteBudgetShare"], 2, "38f: it follows the main budget")
  sliders["Delete / park share###tdeleteBudgetShare"] = 4
  frame(); sliders = {}
  eq(s.getTuning().deleteBudgetShare, 0.5, "38g: editing the ms stores the matching share")
  -- typed values beyond the slider range are accepted, input boxes replace sliders in typing mode
  sliders["Max refills per frame###tmaxRefillsPerFrame"] = 5000
  frame(); sliders = {}
  eq(s.getTuning().maxRefillsPerFrame, 5000, "38h: a value beyond the slider range is accepted")
  frame()
  frame()
  eq(sliderVals["* Max refills per frame###tmaxRefillsPerFrame"], 5000, "38h: and shown")
  sliders["Type values (input boxes instead of sliders)##ttyping"] = true
  frame(); sliders = {}
  frame()
  check(inputs["* Max refills per frame###tmaxRefillsPerFrame"] == "int", "38i: typing mode uses input boxes (changed settings are starred)")
  -- purge buttons
  clicks["Purge scene"] = true
  frame(); clicks = {}
  eq(s.getStatus().liveObjectCount, 0, "38j: the purge button purges")
  check(s.getStatus().lastPurge ~= nil, "38j: and the panel can show the result")
  frame()
  check(true, "38k: the panel draws after a purge")
  ui_imgui = nil
  H.files = {}
end

-- 39. Testing Mode stall diagnostics ---------------------------------------------------------------
do
  local s = fresh({ testingMode = true, cacheWarm = false, probeOnSettle = false, logSettle = false })
  H.tick(s, 6, 0.1)
  local st = s.getStatus()
  local d = st.diagnostics
  check(d ~= nil and d.enabled, "39: Testing Mode exposes diagnostic status")
  check(d and d.frames > 0, "39: diagnostic frame samples were collected")
  check(d and d.stageStats.selection ~= nil, "39: section selection has its own stage timing")
  check(d and d.stageStats.section_reads ~= nil, "39: section reads are separated from queue feeding")
  check(d and d.stageStats.queue_feed ~= nil, "39: queue feeding has its own stage timing")
  check(d and d.lastFrame and d.lastFrame.poolEnd ~= nil, "39: frame report records pool composition")
  if d and d.lastFrame and d.lastFrame.poolEnd then
    local p = d.lastFrame.poolEnd
    eq(p.total, p.live + p.dormant + p.free, "39: pool total reconciles with mutually exclusive categories")
  end
  check(d and (d.clockSource == "os.clockhp" or d.clockSource == "os.clock (fallback)"), "39: diagnostic reports the selected timer")

  -- Synthetic slow operations exercise aggregation and bounded top-N storage, without relying on
  -- the machine speed of the offline mock to generate a naturally slow engine API call.
  local diag = s.stallDiagnostics
  for i = 1, 20 do
    diag:recordOperation("synthetic-test", i + 2, st.currentSectionID, "unit-test-key", "unit-test-shape.dae", "resident-revive", i + 1, "synthetic API elapsed")
  end
  local section = diag:summary(st.currentSectionID)
  eq(section.operations["synthetic-test"].count, 20, "39: operation counts aggregate")
  check(#section.topOps <= diag.topLimit, "39: detailed outliers remain top-N bounded")
  eq(section.topOps[1].ms, 22, "39: top-N keeps the slowest operation")
  eq(section.topOps[1].apiMs, 21, "39: top operation retains API elapsed time")
  local logsBefore = #H.logs
  s.logDiagnosticSummary(st.currentSectionID)
  check(#H.logs > logsBefore, "39: diagnostic report writes a summary to the log")

  s.setTuning({ testingMode = false })
  H.tick(s, 2, 0.1)
  eq(s.getStatus().diagnostics, nil, "39: detailed status is gated off when Testing Mode is disabled")
end

-- 40. patch 0018/0019: run statistics, same-shape reuse counters, cost-class caps --------------------
do
  local s = fresh({ creationMode = "resident" })
  settle(s, 5)
  local r = s.getRunStats()
  eq(r.paths["pool-empty-fresh-object"].n, 9, "40a: the first nine came in through fresh creates")
  eq(r.paths["resident-revive"].n, 0, "40a: no revive yet")
  check(r.frames > 0 and r.idleFrames > 0, "40a: frames counted, some of them idle")
  check(r.settles >= 1, "40a: a settle was recorded")
  H.cam = { x = 4100, y = -320, z = 0 }
  settle(s, 5)
  H.cam = { x = 3950, y = -200, z = 0 }
  settle(s, 5)
  r = s.getRunStats()
  local back = r.paths["resident-revive"].n + r.paths["resident-same-shape-reuse"].n
  check(back >= 6, "40b: the six that rested came back by revive or same-shape reuse (" .. back .. ")")
  eq(r.paths["pool-empty-fresh-object"].n, 10, "40b: nine plus the rock were fresh, the way back needed no further fresh create")
  eq(s.getStatus().run.creates, r.creates, "40b: getStatus carries the run")
  local before = #H.logs
  s.logRunSummary()
  local found = false
  for i = before + 1, #H.logs do if H.logs[i]:find("RUN SUMMARY", 1, true) then found = true end end
  check(found, "40c: the run summary is logged")
  s.resetStats()
  r = s.getRunStats()
  eq(r.creates + r.frames + r.settles, 0, "40d: reset statistics zeroes the run")
end
do
  -- 40e: the expensive path has its own cap; the cheap path is not held back by it
  local s = fresh({ creationMode = "resident", maxRefillsPerFrame = 1, maxCheapPerFrame = 100, frameBudgetMs = 1000 })
  settle(s, 1)
  check(s.getRunStats().costlyCapHits > 0, "40e: a refill cap of 1 was hit")
  settle(s, 20)
  eq(s.getStatus().liveObjectCount, 9, "40e: everything still loads, over more frames")
  H.cam = { x = 4100, y = -320, z = 0 }
  settle(s, 5)
  H.cam = { x = 3950, y = -200, z = 0 }
  local capsBefore = s.getRunStats().costlyCapHits
  settle(s, 3)
  eq(s.getStatus().liveObjectCount, 9, "40e: the returning section is back fast, the refill cap does not hold revives")
  eq(s.getRunStats().costlyCapHits, capsBefore, "40e: and it did not touch the refill cap")
end

-- 33. LuaJIT: no function may get near the 60 upvalue limit ------------------------------------------
-- BeamNG runs LuaJIT, which refuses to load a file with a function that has more than 60 upvalues (a local
-- that a function reads or assigns counts). Lua 5.4 allows 255, so only a LuaJIT run can show it.
if jit then
  local fresh_s = fresh()
  local seen, worst, worstName = {}, 0, ""
  local function walk(f, name)
    if seen[f] then return end
    seen[f] = true
    local info = debug.getinfo(f, "uS")
    if info.nups > worst then worst, worstName = info.nups, name .. " (line " .. tostring(info.linedefined) .. ")" end
    local i = 1
    while true do
      local n, v = debug.getupvalue(f, i)
      if not n then break end
      if type(v) == "function" then walk(v, n) end
      i = i + 1
    end
  end
  for k, v in pairs(nfsc_sectionStreamer) do if type(v) == "function" then walk(v, k) end end
  check(worst <= 56, "33: a function has " .. worst .. " upvalues, the LuaJIT limit is 60: " .. worstName)
end

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
