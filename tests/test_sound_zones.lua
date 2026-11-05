-- Offline tests for nfsc_soundZones. Run with: python tests/run_sound_zones_lupa.py
-- arg[1] = repo root
local repo = arg[1]
package.path = repo .. "/tests/lua/?.lua;" .. package.path
local H = dofile(repo .. "/tests/lua/harness.lua")

local passed, failed = 0, 0
local function check(name, cond, extra)
  if cond then passed = passed + 1 else failed = failed + 1; print("FAIL: " .. name .. (extra and (" (" .. tostring(extra) .. ")") or "")) end
end
local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-3) end

local ZONES = "levels/nfsc/lua/zones.json"
local OVERRIDES = "levels/nfsc/lua/sound_zones.json"

local function fresh(zones, overrides)
  H.install(repo)
  H.files = {}
  H.files[ZONES] = zones and { zones = zones } or nil
  H.files[OVERRIDES] = overrides
  local mod = dofile(repo .. "/lua/ge/extensions/nfsc/soundZones.lua")
  return mod
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

-- 1. an axis-aligned tunnel rectangle becomes one box with the tunnel ambience
do
  local m = fresh({
    { id = 7, type = 3, typeName = "TUNNEL", elevation = 0,
      points = { { 0, 0 }, { 100, 0 }, { 100, 20 }, { 0, 20 } } },
  })
  local ok = m.initialize("levels/nfsc")
  local s = spaces()
  check("initialize ok", ok == true)
  check("one box for a rectangle", #s == 1, #s)
  if s[1] then
    local f = s[1].fields
    check("class", s[1].class == "SFXSpace")
    check("ambience", f.soundAmbience == "Level_Tunnel_Closed", f.soundAmbience)
    local p, sc = nums(f.position), nums(f.scale)
    check("centre x/y", near(p[1], 50) and near(p[2], 10), f.position)
    check("scale long x short", near(sc[1], 100) and near(sc[2], 20), f.scale)
    check("height range", near(sc[3], 2500), f.scale)
  end
  local st = m.getStatus()
  check("status counts", st.zones == 1 and st.boxes == 1 and st.errors == 0)
end

-- 2. rotated rectangle: the long axis drives the rotation matrix
do
  local m = fresh({
    { id = 1, typeName = "GARAGE", points = { { 0, 0 }, { 30, 30 }, { 25, 35 }, { -5, 5 } } },
  })
  m.initialize("levels/nfsc")
  local s = spaces()
  check("rotated: one box", #s == 1, #s)
  if s[1] then
    local r = nums(s[1].fields.rotationMatrix)
    local sc = nums(s[1].fields.scale)
    check("rotated: matrix is a z rotation", #r == 9 and near(r[3], 0) and near(r[9], 1), s[1].fields.rotationMatrix)
    check("rotated: unit axis", near(r[1] * r[1] + r[4] * r[4], 1, 1e-4))
    check("rotated: long side first", sc[1] >= sc[2], s[1].fields.scale)
    check("garage ambience", s[1].fields.soundAmbience == "Level_Parking_House")
  end
end

-- 3. an L-shaped overpass is cut into several boxes that cover it without covering the empty corner
do
  local L = { { 0, 0 }, { 200, 0 }, { 200, 20 }, { 20, 20 }, { 20, 200 }, { 0, 200 } }
  local m = fresh({ { id = 3, type = 4, points = L } })
  m.initialize("levels/nfsc")
  local s = spaces()
  check("L: more than one box", #s > 1, #s)
  check("L: box cap respected", #s <= 24)
  local covered = 0
  for _, o in ipairs(s) do
    local sc = nums(o.fields.scale)
    covered = covered + sc[1] * sc[2]
    check("L: ambience", o.fields.soundAmbience == "Level_Under_Bridge")
  end
  local polyArea = 200 * 20 + 20 * 180
  check("L: boxes cover the polygon", covered >= polyArea * 0.95, covered)
  check("L: boxes do not blanket the bounding square", covered < 200 * 200 * 0.4, covered)
end

-- 4. the elevation gate narrows the vertical range
do
  local m = fresh({
    { id = 10, typeName = "TUNNEL", elevation = 30, points = { { 0, 0 }, { 50, 0 }, { 50, 50 }, { 0, 50 } } },
    { id = 11, typeName = "TUNNEL", elevation = -20, points = { { 100, 0 }, { 150, 0 }, { 150, 50 }, { 100, 50 } } },
  })
  m.initialize("levels/nfsc")
  local s = spaces()
  check("gate: two boxes", #s == 2, #s)
  if #s == 2 then
    local a, b = nums(s[1].fields.position), nums(s[1].fields.scale)
    check("gate above: z from 30 + 150", near(a[3] - b[3] * 0.5, 30 + 150), s[1].fields.position .. " / " .. s[1].fields.scale)
    local a2, b2 = nums(s[2].fields.position), nums(s[2].fields.scale)
    check("gate below: z up to 20 + 150", near(a2[3] + b2[3] * 0.5, 20 + 150), s[2].fields.position .. " / " .. s[2].fields.scale)
  end
end

-- 4b. the height offset comes from the overrides file when given
do
  local m = fresh({ { id = 1, typeName = "TUNNEL", elevation = 10, points = { { 0, 0 }, { 50, 0 }, { 50, 50 }, { 0, 50 } } } },
    { zOffset = 0 })
  m.initialize("levels/nfsc")
  local s = spaces()
  if s[1] then
    local a, b = nums(s[1].fields.position), nums(s[1].fields.scale)
    check("zOffset override", near(a[3] - b[3] * 0.5, 10), s[1].fields.position .. " / " .. s[1].fields.scale)
  else
    check("zOffset override builds", false)
  end
end

-- 5. zones without a sound role are ignored; typeName wins, the number is the fallback
do
  local m = fresh({
    { id = 1, type = 6, typeName = "STREAMER_PREDICTION", points = { { 0, 0 }, { 10, 0 }, { 10, 10 } } },
    { id = 2, type = 0, typeName = "RESET", points = { { 0, 0 }, { 10, 0 }, { 10, 10 } } },
    { id = 3, type = 5, points = { { 0, 0 }, { 40, 0 }, { 40, 10 }, { 0, 10 } } },
  })
  m.initialize("levels/nfsc")
  local s = spaces()
  check("only the overpass-small zone builds", #s == 1, #s)
  if s[1] then check("type number fallback", s[1].fields.soundAmbience == "Level_Under_Bridge_A", s[1].fields.soundAmbience) end
end

-- 6. overrides file: role replaced, one zone replaced, one zone off
do
  local m = fresh({
    { id = 1, typeName = "TUNNEL", points = { { 0, 0 }, { 40, 0 }, { 40, 10 }, { 0, 10 } } },
    { id = 2, typeName = "TUNNEL", points = { { 100, 0 }, { 140, 0 }, { 140, 10 }, { 100, 10 } } },
    { id = 3, typeName = "TUNNEL", points = { { 200, 0 }, { 240, 0 }, { 240, 10 }, { 200, 10 } } },
    { id = 4, typeName = "GARAGE", points = { { 300, 0 }, { 340, 0 }, { 340, 10 }, { 300, 10 } } },
  }, { roles = { TUNNEL = "Level_Tunnel_Open", GARAGE = false }, zones = { ["2"] = "Level_Tunnel_Closed_Dynamic", ["3"] = false } })
  m.initialize("levels/nfsc")
  local s = spaces()
  check("overrides: two spaces left", #s == 2, #s)
  local byName = {}
  for _, o in ipairs(s) do byName[o.name] = o.fields.soundAmbience end
  check("overrides: role replaced", byName["nfsc_sfx_1_1"] == "Level_Tunnel_Open", byName["nfsc_sfx_1_1"])
  check("overrides: zone replaced", byName["nfsc_sfx_2_1"] == "Level_Tunnel_Closed_Dynamic", byName["nfsc_sfx_2_1"])
  check("overrides: zone off", byName["nfsc_sfx_3_1"] == nil)
  check("overrides: role off", byName["nfsc_sfx_4_1"] == nil)
  check("overrides: skipped counted", m.getStatus().skipped == 2, m.getStatus().skipped)
end

-- 7. bounds fallback, bad zones, missing file, rebuild and unload
do
  local m = fresh({
    { id = 1, typeName = "TUNNEL", boundsMin = { 0, 0 }, boundsMax = { 60, 12 } },
    { id = 2, typeName = "TUNNEL" },
    { id = 3, typeName = "TUNNEL", elevation = 3000, points = { { 0, 0 }, { 40, 0 }, { 40, 10 }, { 0, 10 } } },
  })
  m.initialize("levels/nfsc")
  check("bounds fallback builds one box", #spaces() == 1, #spaces())
  check("zone without geometry and an empty gate are skipped", m.getStatus().skipped == 2, m.getStatus().skipped)
  m.rebuild()
  check("rebuild does not stack spaces", #spaces() == 1, #spaces())
  m.onExtensionUnloaded()
  check("unload removes the group", H.byName("nfsc_sound_zones") == nil)

  local m2 = fresh(nil)
  local ok = m2.initialize("levels/nfsc")
  check("missing zones.json reports failure", ok == false)
  check("missing zones.json builds nothing", H.byName("nfsc_sound_zones") == nil or #spaces() == 0)
end

-- 8. a refused registerObject is counted, not thrown
do
  local m = fresh({ { id = 1, typeName = "TUNNEL", points = { { 0, 0 }, { 40, 0 }, { 40, 10 }, { 0, 10 } } } })
  H.refuseRegister = true
  local ok = pcall(m.initialize, "levels/nfsc")
  H.refuseRegister = nil
  check("refusal does not throw", ok)
  check("refusal counted", m.getStatus().errors >= 1 and m.getStatus().boxes == 0, m.getStatus().errors)
end

-- 9. other file shapes: bare array, another wrapper key, {x=, y=} points
do
  local rect = { { x = 0, y = 0 }, { x = 40, y = 0 }, { x = 40, y = 10 }, { x = 0, y = 10 } }
  H.install(repo); H.files = {}
  H.files[ZONES] = { { id = 1, typeName = "tunnel", points = rect } }
  local m = dofile(repo .. "/lua/ge/extensions/nfsc/soundZones.lua")
  check("bare array, xy points, lower-case type", m.initialize("levels/nfsc") == true and #spaces() == 1, #spaces())

  H.install(repo); H.files = {}
  H.files[ZONES] = { trackPathZones = { { id = 1, type = 3, points = rect } }, count = 1 }
  m = dofile(repo .. "/lua/ge/extensions/nfsc/soundZones.lua")
  check("other wrapper key found", m.initialize("levels/nfsc") == true and #spaces() == 1, #spaces())

  H.install(repo); H.files = {}
  H.files[ZONES] = { note = "x" }
  m = dofile(repo .. "/lua/ge/extensions/nfsc/soundZones.lua")
  check("no zone list reports failure", m.initialize("levels/nfsc") == false)
end

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
