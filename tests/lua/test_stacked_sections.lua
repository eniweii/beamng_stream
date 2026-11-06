-- Offline tests for stacked (depth) sections in nfsc_sectionStreamer.
-- usage: python tests/run_lua_tests_lupa.py --stacked
local repo, root = arg[1], arg[2]
package.path = repo .. "/tests/lua/?.lua;" .. package.path
local H = require("harness")

local passed, failed = 0, 0
local function eq(a, b, label)
  if a == b then passed = passed + 1
  else failed = failed + 1; print(string.format("FAIL: %s (got %s, want %s)", label, tostring(a), tostring(b))) end
end

local function fresh(cam)
  H.hookCalls, H.created, H.loaded = {}, {}, {}
  H.install(root)
  H.cam = cam
  local streamer = H.load(repo .. "/lua/ge/extensions/nfsc/sectionStreamer.lua")
  nfsc_sectionStreamer = streamer
  H.loaded = { streamer }
  streamer.setTuning({ maxFirstUsePerFrame = 1000, predictionEnabled = false, elevationZOffset = 0 })   -- the fixture heights are level heights
  streamer.setCreateFilter(nil)
  local ok, err = streamer.initialize("levels/nfsc")
  assert(ok, err)
  return streamer
end
local function settle(s, n) H.tick(s, n or 20, 0.1) end

-- 1. camera between the two surfaces: the lower triangle's name picks the depth section ---------------
do
  local s = fresh({ x = 3930, y = -200, z = 5 })
  settle(s, 5)
  eq(s.getCurrentSectionID(), 1500, "z 5: depth section 1500")
  eq(s.isSectionActive(1500), true, "depth section is active")
  eq(s.isSectionActive(1101), true, "its own related list is used (1101)")
  eq(s.isSectionActive(1021), false, "base section is not active unless the depth list has it")
  eq(s.getStatus().failureCount, 0, "no failures")
end

-- 2. above every surface: the highest one below is named 555, no depth section has it -> base ----------
do
  local s = fresh({ x = 3930, y = -200, z = 25 })
  settle(s, 5)
  eq(s.getCurrentSectionID(), 1021, "z 25: base section 1021")
  eq(s.isSectionActive(1022), true, "base related list (1022)")
  eq(s.isSectionActive(1101), false, "base list has no 1101")
end

-- 3. below every surface: no triangle qualifies -> base ---------------------------------------------
do
  local s = fresh({ x = 3930, y = -200, z = -10 })
  settle(s, 5)
  eq(s.getCurrentSectionID(), 1021, "z -10: base section")
end

-- 4. outside the triangles in x/y: base -------------------------------------------------------------
do
  local s = fresh({ x = 3820, y = -200, z = 5 })
  settle(s, 5)
  eq(s.getCurrentSectionID(), 1021, "outside the triangles: base section")
end

-- 5. moving up and down inside one base section switches the set, and back --------------------------
do
  local s = fresh({ x = 3930, y = -200, z = 25 })
  settle(s, 5)
  eq(s.getCurrentSectionID(), 1021, "start on the upper level")
  H.cam = { x = 3930, y = -200, z = 5 }
  settle(s, 5)
  eq(s.getCurrentSectionID(), 1500, "dropped to the lower level")
  H.cam = { x = 3935, y = -200, z = 5 }                      -- still inside 1021's polygon: sectionAt keeps the base
  settle(s, 5)
  eq(s.getCurrentSectionID(), 1500, "stays on the lower level")
  H.cam = { x = 3935, y = -200, z = 25 }
  settle(s, 5)
  eq(s.getCurrentSectionID(), 1021, "back on the upper level")
  eq(#H.hooks("onNfscSectionChanged"), 3, "three section changes (1021, 1500, 1021)")
end

-- 6. offset and tolerance move the decision ----------------------------------------------------------
do
  local s = fresh({ x = 3930, y = -200, z = -3 })
  settle(s, 5)
  eq(s.getCurrentSectionID(), 1021, "z -3: below the surface, base")
  s.setTuning({ elevationZOffset = 4 })
  H.cam = { x = 3931, y = -200, z = -3 }
  settle(s, 5)
  eq(s.getCurrentSectionID(), 1500, "offset 4 lifts the camera onto the lower level")
end

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
