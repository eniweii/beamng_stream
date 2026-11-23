-- Offline tests for the barrierSets level host component. Run with: python tests/run_lua_tests_lupa.py --barriers
-- arg[1] = repo root
local repo = arg[1]
package.path = repo .. "/tests/lua/?.lua;" .. package.path
local H = dofile(repo .. "/tests/lua/harness.lua")

local passed, failed = 0, 0
local function check(name, cond, extra)
  if cond then passed = passed + 1 else failed = failed + 1; print("FAIL: " .. name .. (extra and (" (" .. tostring(extra) .. ")") or "")) end
end

local CONFIG = "levels/nfsc/lua/components/barrierSets.json"
local realLoadfile = loadfile

-- A stand-in for nfsc_sectionManager: the override table, the game mode and the calls it received.
local function installManager(preEnabled)
  local sm = { enabled = {}, mode = "freeroam", calls = {} }
  for _, n in ipairs(preEnabled or {}) do sm.enabled[n] = true end
  function sm.setOverrideEnabled(name, on)
    sm.calls[#sm.calls + 1] = name .. "=" .. tostring(on and true or false)
    sm.enabled[name] = on and true or nil
  end
  function sm.isOverrideEnabled(name) return sm.enabled[name] == true end
  function sm.setGameMode(m) if m ~= "freeroam" and m ~= "racing" then return false end; sm.mode = m; return true end
  function sm.getGameMode() return sm.mode end
  nfsc_sectionManager = sm
  return sm
end

local function fresh(files)
  H.install(repo)
  H.files = {}
  H.hookCalls = {}
  for path, data in pairs(files or {}) do H.files[path] = data end
  loadfile = function(path)
    local game = path:match("^/lua/ge/extensions/nfsc/components/(.+)$")
    return realLoadfile(game and (repo .. "/lua/ge/extensions/nfsc/components/" .. game) or path)
  end
  return dofile(repo .. "/lua/ge/extensions/nfsc/levelHost.lua")
end

local function barrierHooks()
  local out = {}
  for _, c in ipairs(H.hooks("onNfscBarrierSetChanged")) do out[#out + 1] = c.args[1] .. "=" .. tostring(c.args[2]) .. (c.args[3] and "/flip" or "") end
  return table.concat(out, ",")
end

local M1 = { id = "nfsc/aiRace/tuner_3_3_2", missionFolder = "/gameplay/missions/nfsc/aiRace/tuner_3_3_2" }
local DATA1 = { enable = { { name = "BARRIER_SPLINE_1000", flip = false }, { name = "BARRIER_SPLINE_1001", flip = true }, "SCENERY_GROUP_CTD1" },
                disable = { "SCENERY_GROUP_CTD2" } }

-- 1. the host runs the component and forwards the mission hook
do
  local sm = installManager({ "SCENERY_GROUP_CTD2" })
  local host = fresh({ [M1.missionFolder .. "/race_groups.json"] = DATA1 })
  host.initialize("levels/nfsc")
  local st = host.getStatus()
  check("barrierSets is the sixth component", #st.components == 6 and st.components[6].name == "barrierSets" and st.components[6].ok == true, st.components[6] and st.components[6].err)
  check("idle at start", st.components[6].status and st.components[6].status.active == nil)

  host.onAnyMissionChanged("started", M1)
  check("enabled groups are on", sm.enabled.BARRIER_SPLINE_1000 and sm.enabled.BARRIER_SPLINE_1001 and sm.enabled.SCENERY_GROUP_CTD1)
  check("disabled group is off", sm.enabled.SCENERY_GROUP_CTD2 == nil)
  check("game mode racing", sm.mode == "racing")
  check("status shows the mission", host.getStatus().components[6].status.active == M1.id and host.getStatus().components[6].status.enabled == 3
    and host.getStatus().components[6].status.disabled == 1)
  check("messenger hooks with flip", barrierHooks() == "BARRIER_SPLINE_1000=true,BARRIER_SPLINE_1001=true/flip,SCENERY_GROUP_CTD1=true,SCENERY_GROUP_CTD2=false", barrierHooks())

  H.hookCalls = {}
  host.onAnyMissionChanged("stopped", M1)
  check("stop turns the groups back", not sm.enabled.BARRIER_SPLINE_1000 and not sm.enabled.BARRIER_SPLINE_1001 and not sm.enabled.SCENERY_GROUP_CTD1)
  check("stop restores the disabled group", sm.enabled.SCENERY_GROUP_CTD2 == true)
  check("stop restores freeroam", sm.mode == "freeroam")
  check("stop announces the undo", barrierHooks() == "SCENERY_GROUP_CTD1=false,BARRIER_SPLINE_1001=false/flip,BARRIER_SPLINE_1000=false,SCENERY_GROUP_CTD2=true", barrierHooks())
  check("idle again", host.getStatus().components[6].status.active == nil)
  host.onExtensionUnloaded()
end

-- 2. a group somebody else already switched is left alone, and a changed mode is not forced back
do
  local sm = installManager({ "BARRIER_SPLINE_1000" })
  local host = fresh({ [M1.missionFolder .. "/race_groups.json"] = DATA1 })
  host.initialize("levels/nfsc")
  host.onAnyMissionChanged("started", M1)
  check("already-on group is not announced", not barrierHooks():find("BARRIER_SPLINE_1000", 1, true), barrierHooks())
  sm.mode = "freeroam"                                          -- somebody changes the mode during the race
  sm.setGameMode("freeroam")
  host.onAnyMissionChanged("stopped", M1)
  check("already-on group stays on", sm.enabled.BARRIER_SPLINE_1000 == true)
  check("the other groups are off again", not sm.enabled.BARRIER_SPLINE_1001 and not sm.enabled.SCENERY_GROUP_CTD1)
  host.onExtensionUnloaded()
end

-- 3. a stop for another mission is ignored; a new mission undoes the previous groups first
do
  local sm = installManager()
  local M2 = { id = "nfsc/timeTrial/muscle_2_1_3", missionFolder = "/gameplay/missions/nfsc/timeTrial/muscle_2_1_3" }
  local host = fresh({ [M1.missionFolder .. "/race_groups.json"] = DATA1,
                       [M2.missionFolder .. "/race_groups.json"] = { enable = { "BARRIER_SPLINE_2000" }, gameMode = "none" } })
  host.initialize("levels/nfsc")
  host.onAnyMissionChanged("started", M1)
  host.onAnyMissionChanged("stopped", M2)
  check("stop of another mission ignored", sm.enabled.BARRIER_SPLINE_1000 == true and host.getStatus().components[6].status.active == M1.id)
  host.onAnyMissionChanged("started", M2)
  check("previous mission undone", not sm.enabled.BARRIER_SPLINE_1000 and not sm.enabled.SCENERY_GROUP_CTD1)
  check("new mission groups on", sm.enabled.BARRIER_SPLINE_2000 == true and not sm.enabled.BARRIER_SPLINE_1000)
  check("gameMode none leaves the mode", sm.mode == "freeroam")
  host.onAnyMissionChanged("stopped", M2)
  check("everything off", next(sm.enabled) == nil)
  host.onExtensionUnloaded()
end

-- 4. the config table works without a file in the mission folder, and a mission without data does nothing
do
  local sm = installManager()
  local host = fresh({ [CONFIG] = { missions = { [M1.id] = { enable = { "BARRIER_SPLINE_3000" } } } } })
  host.initialize("levels/nfsc")
  host.onAnyMissionChanged("started", { id = "nfsc/aiRace/other", missionFolder = "/gameplay/missions/nfsc/aiRace/other" })
  check("no data, nothing happens", #sm.calls == 0 and sm.mode == "freeroam")
  host.onAnyMissionChanged("started", M1)
  check("config data used", sm.enabled.BARRIER_SPLINE_3000 == true and sm.mode == "racing")
  host.onAnyMissionChanged("stopped", M1)
  check("config data undone", sm.enabled.BARRIER_SPLINE_3000 == nil and sm.mode == "freeroam")
  host.onExtensionUnloaded()
end

-- 5. the state survives a Lua reload, and shutdown undoes the groups
do
  local sm = installManager()
  local host = fresh({ [M1.missionFolder .. "/race_groups.json"] = DATA1 })
  host.initialize("levels/nfsc")
  host.onAnyMissionChanged("started", M1)
  local saved = host.onSerialize()
  check("state serialized", saved.barrierSets and saved.barrierSets.active.id == M1.id and #saved.barrierSets.active.enabled == 3 and saved.barrierSets.flipped[1] == "BARRIER_SPLINE_1001")
  host.onExtensionUnloaded()                                    -- shutdown undoes the groups
  check("shutdown undoes the groups", next(sm.enabled) == nil and sm.mode == "freeroam")

  sm = installManager()
  sm.setOverrideEnabled("BARRIER_SPLINE_1000", true)            -- as the reload leaves them
  sm.setOverrideEnabled("BARRIER_SPLINE_1001", true)
  sm.setOverrideEnabled("SCENERY_GROUP_CTD1", true)
  sm.setGameMode("racing")
  local host2 = fresh({ [M1.missionFolder .. "/race_groups.json"] = DATA1 })
  host2.onDeserialized(saved)
  host2.initialize("levels/nfsc")
  check("restored state is active again", host2.getStatus().components[6].status.active == M1.id)
  host2.onAnyMissionChanged("stopped", M1)
  check("stop after reload undoes", next(sm.enabled) == nil and sm.mode == "freeroam", sm.mode)
  host2.onExtensionUnloaded()
end

-- 6. without a Section Manager the component only warns
do
  nfsc_sectionManager = nil
  local host = fresh({ [M1.missionFolder .. "/race_groups.json"] = DATA1 })
  host.initialize("levels/nfsc")
  host.onAnyMissionChanged("started", M1)
  check("no manager: idle, host ok", host.getStatus().components[6].ok == true and host.getStatus().components[6].status.active == nil)
  host.onExtensionUnloaded()
end

-- 7. flip: flagged objects of a flipped group are mirrored (one scale axis), restored when the group goes
do
  local sm = installManager()
  local host = fresh({ [M1.missionFolder .. "/race_groups.json"] = DATA1 })
  host.initialize("levels/nfsc")
  local bs = host.getComponent("barrierSets")
  local function fakeObj(sx, sy, sz)
    local o = { sx = sx, sy = sy, sz = sz, writes = 0 }
    function o.getScale(self) return { x = self.sx, y = self.sy, z = self.sz } end
    function o.setScaleXYZ(self, x, y, z) self.sx, self.sy, self.sz = x, y, z; self.writes = self.writes + 1 end
    return o
  end
  local function item(group, scale, flags) return { sectionOverrideName = group, scale = scale, instanceFlags = flags or "FlipOnBackwardsTrack,VisibleFurther" } end
  local function scaleOf(o) return string.format("%g %g %g", o.sx, o.sy, o.sz) end

  local A, B, C = fakeObj(1, 1, 1), fakeObj(1, 1, 1), fakeObj(1, 1, 1)
  bs.onObjectCreated("a", A, item("BARRIER_SPLINE_1001", "1 1 1"))
  bs.onObjectCreated("b", B, item("BARRIER_SPLINE_1001", "1 1 1", "VisibleFurther"))            -- no flip flag
  bs.onObjectCreated("c", C, item("BARRIER_SPLINE_1000", "1 1 1"))                              -- group on without flip
  check("registered only flagged objects", bs.getStatus().flippable == 2 and bs.getStatus().mirrored == 0)

  host.onAnyMissionChanged("started", M1)
  check("flagged object of the flipped group is mirrored", scaleOf(A) == "-1 1 1", scaleOf(A))
  check("object without the flag is untouched", scaleOf(B) == "1 1 1" and B.writes == 0)
  check("object of an unflipped group is untouched", scaleOf(C) == "1 1 1" and C.writes == 0)
  check("status counts the mirror", bs.getStatus().mirrored == 1 and bs.getStatus().flippedGroups == 1)

  local D = fakeObj(2, 1, 1)
  bs.onObjectCreated("d", D, item("BARRIER_SPLINE_1001", "2 1 1"))
  check("object that streams in later is mirrored", scaleOf(D) == "-2 1 1", scaleOf(D))
  bs.onObjectDeleted("d")
  check("released object gets its scale back first", scaleOf(D) == "2 1 1", scaleOf(D))
  check("released object is forgotten", bs.getStatus().flippable == 2)

  host.onAnyMissionChanged("stopped", M1)
  check("stop restores the artwork", scaleOf(A) == "1 1 1" and bs.getStatus().mirrored == 0 and bs.getStatus().flippedGroups == 0)

  check("axis y accepted, z accepted, junk refused", bs.setFlipAxis("y") and bs.setFlipAxis("Z") and not bs.setFlipAxis("w") and bs.getStatus().flipAxis == "z")
  bs.setFlipAxis("y")
  host.onAnyMissionChanged("started", M1)
  check("axis y mirrors the second scale", scaleOf(A) == "1 -1 1", scaleOf(A))
  bs.setFlipEnabled(false)
  check("flip off restores live objects", scaleOf(A) == "1 1 1" and bs.getStatus().mirrored == 0)
  bs.setFlipEnabled(true)
  check("flip on mirrors them again", scaleOf(A) == "1 -1 1")
  host.onAnyMissionChanged("stopped", M1)
  bs.setFlipAxis("x")

  local R = fakeObj(-1, 1, 1)                                   -- revived object that still wears a mirror, group not flipped
  bs.onObjectCreated("r", R, item("BARRIER_SPLINE_1001", "1 1 1"))
  check("revived object is set back to the exported scale", scaleOf(R) == "1 1 1", scaleOf(R))

  local N = fakeObj(-1, 1, 1)                                   -- exported with a negative scale on purpose
  bs.onObjectCreated("n", N, item("BARRIER_SPLINE_1001", "-1 1 1"))
  host.onAnyMissionChanged("started", M1)
  check("negative exported scale mirrors back", scaleOf(N) == "1 1 1", scaleOf(N))
  host.onAnyMissionChanged("stopped", M1)
  check("negative exported scale restored", scaleOf(N) == "-1 1 1", scaleOf(N))

  -- a group somebody else already switched on still gets the flip, and loses it on stop
  sm.setOverrideEnabled("BARRIER_SPLINE_1001", true)
  host.onAnyMissionChanged("started", M1)
  check("flip only on an already-on group", scaleOf(A) == "-1 1 1" and sm.enabled.BARRIER_SPLINE_1001 == true)
  host.onAnyMissionChanged("stopped", M1)
  check("flip removed, group stays on", scaleOf(A) == "1 1 1" and sm.enabled.BARRIER_SPLINE_1001 == true)

  bs.onStreamerReset()
  check("streamer reset clears the registry", bs.getStatus().flippable == 0)
  host.onExtensionUnloaded()
end

loadfile = realLoadfile
print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
