-- nfsc_sectionStreamer, part "tuning": the TUNING table and its defaults, the settings schema, presets (file and mode presets) and the get/set functions.
-- Loaded by sectionStreamer.lua into the shared streamer environment; every name here is shared with the other parts.

-- ---------------------------------------------------------------------------
-- Tuning (override at runtime with M.setTuning{...})
-- ---------------------------------------------------------------------------
TUNING = {
  levelRoot = "levels/nfsc",
  maxCreatesPerFrame = 16,
  maxRefillsPerFrame = 128,       -- resident mode: creates that must change a shell's shape (the expensive path) per frame
  maxCheapPerFrame = 1024,        -- resident mode: revives and same-shape reuses (nearly free) per frame
  maxDeletesPerFrame = 256,
  frameBudgetMs = 16.0,           -- one budget for the whole frame: deletes first, creates get what is left
  deleteBudgetShare = 0.25,       -- deletes may use at most this share of frameBudgetMs (and never more than the frame has left)
  maxFirstUsePerFrame = 3,        -- new shapes (4-20 ms each) per frame; a later new shape waits for the next frame
  firstUseGuessMs = 6.0,          -- expected first-use cost until a real average exists
  currentSectionFirst = true,     -- objects of the section the camera is in (and the one streamed for) load before everything else
  probeOnSettle = true,           -- after a section settled with new objects, time a few test registerObject calls and log them
  probeCount = 20,                -- test objects per probe pass when it runs by itself
  skipNameLookup = false,         -- true: name every object "nfsc_<key>" without the scenetree.findObject duplicate check
  stallLogMs = 100,               -- a single create or cache import slower than this is logged at once (shape, kind)
  testingMode = false,            -- detailed bounded frame/stall diagnostics; off by default
  logEmptySettles = false,        -- true: also print the settled line of a change that created nothing
  shapeIndexBudgetShare = 0.25,   -- share of frameBudgetMs per frame for reading section files into the shape index (one file always goes)
  indexBeforeStreaming = true,    -- at level load, read every section file into the shape index first; nothing is streamed until it is done
  shapeCache = true,              -- Preload: hold the meshes of the section island you are in with one hidden object each (see header)
  shapeCacheMax = 100000,         -- Max meshes to save: most holders kept (the fill stops there; holders of other islands are evicted first)
  shapeCacheAlways = false,       -- Preload always: fill while the camera moves too (default: only when it is still)
  debugLog = false,               -- Debug: the detailed logs (cacher lines, run summary details, fill progress)
  shapeCacheAtLoad = true,        -- start filling at level load (no idle wait before the first hold)
  shapeCacheIdleSeconds = 1.0,    -- both load queues must have been empty this long before a hold (after the first)
  shapeCacheGapSeconds = 0.02,    -- pause after every hold (0 = back to back, for a loading screen)
  shapeCachePerFrame = 1,         -- most shapes held per idle frame
  shapeCacheBudgetShare = 0.125,  -- share of frameBudgetMs per frame for holding (a single load can still run longer)
  shapeCacheRamFloorGB = 1.5,     -- pause the fill while free RAM is below this (0 = off; needs M.setMemoryProvider)
  shapeCacheHeavyMs = 10.0,       -- a shape measured slower than this is heavy
  shapeCacheHeavyWait = true,     -- heavy shapes are held only while the camera is still
  shapeCacheStillSeconds = 1.5,   -- seconds the camera must be still
  shapeCachePlaceholders = 200,   -- hidden holders on the dot built ahead of the fill (0 = none)
  shapeCacheLogEvery = 2000,      -- progress line after this many holds (0 = none)
  animatedInShells = false,       -- debug: animated objects use the shell pool too (false: plain create and delete, so they restart cleanly)
  restartAmbient = true,          -- only with animatedInShells: playAmbient is off while a pooled object is hidden and on once it is visible
  warmGroupName = "NFSC_WarmMeshes",
  maxSectionReadsPerFrame = 1,
  maxQueuedItems = 512,           -- hard cap of the load queue; the rest waits in pending lists
  maxPendingRecords = 8192,       -- do not read another section file while this many records wait
  unloadCooldown = 2.0,           -- seconds a no-longer-wanted object survives
  containmentTolerance = 0.1,     -- GetDistanceOutside fallback, same as the game
  elevationZOffset = -150.0,      -- added to the camera height before it is compared with the elevation triangles (stacked sections): every object of the level sits 150 higher than in the game
  elevationTolerance = 0.0,       -- a triangle counts as below the camera when its surface is at most this far above it
  noSectionLookupInterval = 0.1,  -- seconds between lookups while outside every section
  forceCollisionNone = true,      -- collision policy for the first in-game test (see docs)
  verifyFirstN = 3,               -- log readbacks of the first N created objects
  runtimeGroupName = "NFSC_StreamedScenery",
  predictionEnabled = true,       -- switch to the section ahead before the camera crosses the border
  predictionSeconds = 1.5,        -- look-ahead time, same as the game
  predictionMaxDistance = 100.0,  -- look-ahead cap in metres, same as the game
  predictionMinSpeed = 1.0,       -- m/s; slower than this there is no prediction
  predictionMaxSpeed = 178.81,    -- m/s (400 mph); faster is treated as a jump and not predicted
  predictionStableTime = 0.25,    -- seconds the section ahead must stay the same before switching
  selectionInterval = 0.05,       -- seconds between section lookups
  priorityRefreshInterval = 0.5,  -- seconds between load-order refreshes
  logSettle = true,               -- one log line when the load of a section change has finished
  creationMode = "resident",      -- "resident" (default), "current" or "shells" (see header); M.setCreationMode(mode) switches it
  residentMax = 6000,             -- resident mode: pool size (live + deactivated + free) before the oldest deactivated one is evicted
  residentReserve = 0,            -- resident mode: free shells kept ready by evicting in idle frames (0 = evict only when a load needs one)
  residentCooldown = 0.0,         -- resident mode: seconds before an unwanted object is deactivated (it is cheap, so 0)
  shellShape = "/levels/nfsc/Assets/Meshes/NFSC_DOT.dae",  -- shape of a parked shell (tiny, never drawn: parked shells are hidden)
  shellTarget = 0,                -- keep at least this many shells (free + in use); built ahead in the background. 0 = off
  shellBuildPerFrame = 8,         -- shells built ahead per frame ...
  shellBuildBudgetShare = 0.125,  -- ... and at most this share of frameBudgetMs of it (2 ms at 16), and never more than the frame has left
}

TUNING_DEFAULTS = {}
for k, v in pairs(TUNING) do TUNING_DEFAULTS[k] = v end
readPresets = nil                      -- defined with the tuning API further down

-- Tuning schema: one row per setting the panel can show (the panel builds itself from it).
--   kind     "float", "int", "bool" or "share" (a part 0..1 of frameBudgetMs; the panel shows the ms it is worth)
--   min/max  slider range;  lo/hi  hard limits setTuning enforces (numbers: lo defaults to 0, shares: 0..1)
--   modes    creation modes the setting does something in (nil = all);  requires  a bool setting that must be on
--   desc     the tooltip text: what it does and what raising or lowering it changes
tun = {}                          -- tuning schema, presets, change tracking and helpers: one local
do
local SHELL_MODES = { shells = true, resident = true }
tun.schema = {
  { key = "frameBudgetMs", debug = true, group = "Frame budget", label = "Frame budget (ms)", kind = "float", min = 1, max = 50,
    desc = "Time one frame may spend on streaming: section reads, deletes, creates and shell building together. Every task below is capped by what is left of it. Higher: sections settle sooner but frames run longer. Lower: smoother frames, slower loading." },
  { key = "deleteBudgetShare", debug = true, group = "Frame budget", label = "Delete / park share", kind = "share", min = 0.05, max = 1,
    desc = "Largest part of the frame budget that deleting (or parking / deactivating) objects may use. Deletes run first, creates get the rest. Lower: more time for creates, but objects wait longer to be removed. Higher: the unload backlog clears faster and loading slows." },
  { key = "shellBuildBudgetShare", debug = true, group = "Frame budget", label = "Shell build share", kind = "share", min = 0.01, max = 1, modes = SHELL_MODES,
    desc = "Largest part of the frame budget for building parked shells ahead (see Shells built ahead). It runs after the loads and only takes what they left, so a busy frame builds none. Higher: the pool fills sooner but idle frames get longer." },
  { key = "maxCreatesPerFrame", debug = true, group = "Section loading", label = "Max creates per frame", kind = "int", min = 1, max = 256, lo = 1, modes = { current = true, shells = true },
    desc = "Hard cap on objects created per frame, on top of the time budget. Higher: faster loading when objects are cheap, bigger frame spikes when they are not. Lower: steadier frames, slower loading." },
  { key = "maxRefillsPerFrame", debug = true, group = "Section loading", label = "Max refills per frame", kind = "int", min = 1, max = 1024, lo = 1, modes = { resident = true },
    desc = "Hard cap per frame on objects that need a shell with a different shape (no deactivated object of the same shape was left). This is the expensive path: a shape change costs about 1 ms or more. Higher: faster loading, bigger spikes. Lower: steadier frames, slower loading. Revives and same-shape reuses are not counted here." },
  { key = "maxCheapPerFrame", debug = true, group = "Section loading", label = "Max cheap reuses per frame", kind = "int", min = 1, max = 4096, lo = 1, modes = { resident = true },
    desc = "Hard cap per frame on objects brought back by a revive or a same-shape reuse (about 0.01 ms each, no shape change, no registerObject). They are still limited by the frame budget. Higher: a returning section is back in very few frames, then the streamer sleeps. Lower: gentler." },
  { key = "maxDeletesPerFrame", debug = true, group = "Section loading", label = "Max deletes per frame", kind = "int", min = 1, max = 2048, lo = 1,
    desc = "Hard cap on objects deleted (or parked) per frame, on top of the delete share. Lower: a long unload trails over more frames; higher: it finishes sooner, in a bigger spike." },
  { key = "maxFirstUsePerFrame", debug = true, group = "Section loading", label = "Max first uses per frame", kind = "int", min = 1, max = 16, lo = 1,
    desc = "How many never-used shapes may be created per frame. A first use loads the mesh and can cost 4-100 ms (a COLLADA import when there is no .cdae yet). Lower: fewer big stalls in one frame, new shapes appear later." },
  { key = "firstUseGuessMs", debug = true, group = "Section loading", label = "First use guess (ms)", kind = "float", min = 1, max = 40,
    desc = "Expected cost of a first use until a real average exists. A new shape is only started when this much budget is left. Higher: more cautious, shapes wait for a quieter frame. Lower: shapes start earlier and may overrun the budget." },
  { key = "maxSectionReadsPerFrame", debug = true, group = "Section loading", label = "Section reads per frame", kind = "int", min = 1, max = 8, lo = 1,
    desc = "Section files read per frame. A read is a JSON parse and cannot be split. Higher: sections get their data sooner, with a heavier frame. A second read only starts while the frame budget has time left." },
  { key = "maxQueuedItems", debug = true, group = "Section loading", label = "Load queue cap", kind = "int", min = 64, max = 4096, lo = 1,
    desc = "Most objects held in the load queue; the rest wait in per-section lists. Higher: the queue holds more at once and reorders less often. Lower: the order follows the camera more closely." },

  { key = "unloadCooldown", debug = true, group = "Unloading", label = "Unload cooldown (s)", kind = "float", min = 0, max = 10, modes = { current = true, shells = true },
    desc = "Seconds an object that no active section wants survives before it is deleted or parked. Higher: going back to a section you just left is instant, more objects stay in memory. Lower: memory is freed sooner." },
  { key = "residentCooldown", debug = true, group = "Unloading", label = "Deactivate delay (s)", kind = "float", min = 0, max = 10, modes = { resident = true },
    desc = "Seconds before an unwanted object is deactivated (hidden, kept bound to its shape and fields). Deactivating is cheap, so 0 is normal. Higher: the object stays drawn a little longer after the camera leaves." },

  { key = "shellTarget", debug = true, group = "Shell pool", label = "Shells built ahead", kind = "int", min = 0, max = 30000, modes = SHELL_MODES,
    desc = "Keep at least this many shells (free + in use), built in the background while nothing urgent is queued. 0 = build on demand. Near the peak live count (about 3200 seen) avoids creating during loads; each hidden shell costs a little every frame." },
  { key = "shellBuildPerFrame", debug = true, group = "Shell pool", label = "Shells per frame", kind = "int", min = 1, max = 64, lo = 1, modes = SHELL_MODES,
    desc = "Most shells built ahead per frame, within the shell build share. Higher: the pool fills in fewer frames. Lower: gentler on frame time." },

  { key = "residentMax", debug = true, group = "Resident pool", label = "Pool size", kind = "int", min = 500, max = 30000, lo = 1, modes = { resident = true },
    desc = "Active shells: the most objects resident at once (live + deactivated + free). With the shape cache on every mesh is already held, so a shell only revives, retargets and unhides: size this to the most resident at once (about 4,200 seen), not to the shape count. Beyond it the oldest deactivated object is evicted and its shell reused. Higher: more sections stay instantly revivable, more RAM. Lower: more evictions and re-targets." },
  { key = "residentReserve", debug = true, group = "Resident pool", label = "Free reserve", kind = "int", min = 0, max = 2000, modes = { resident = true },
    desc = "Free shells kept ready by evicting in idle frames. 0 = evict only when a load needs a shell. Higher: loads rarely have to evict mid-frame, but fewer objects stay resident." },

  { key = "currentSectionFirst", debug = true, group = "Look-ahead and order", label = "Current section first", kind = "bool",
    desc = "Objects of the camera's section (and the one being streamed for) load before everything else. Off: strict distance bands only." },
  { key = "predictionEnabled", debug = true, group = "Look-ahead and order", label = "Look-ahead", kind = "bool",
    desc = "Switch to the section ahead before the camera crosses the border, from the camera velocity. On: the next section starts loading earlier. Off: loading starts at the border." },
  { key = "elevationZOffset", debug = true, group = "Stacked sections", label = "Elevation height offset (m)", kind = "float", min = -500, max = 500,
    desc = "Stacked sections (a tunnel under a road, an overpass): added to the camera height before it is compared with the elevation triangles of sections.json, which are in game heights. The level sits 150 higher than the game, so the default is -150; change it only if a drive shows the wrong section below or above a stacked spot." },
  { key = "elevationTolerance", debug = true, group = "Stacked sections", label = "Elevation tolerance (m)", kind = "float", min = 0, max = 20,
    desc = "Stacked sections: a triangle surface counts as below the camera when it is at most this far above it. Raise it a little if the camera sits right on the road surface and flickers between the two sections." },
  { key = "predictionSeconds", debug = true, group = "Look-ahead and order", label = "Look-ahead time (s)", kind = "float", min = 0, max = 5, requires = "predictionEnabled",
    desc = "How far ahead (in seconds of travel, capped at 100 m) the look-ahead point lies. Higher: earlier loading, more wrong guesses on turns. Lower: later switches." },

  { key = "animatedInShells", debug = true, group = "Shell pool", label = "Animated objects in shells", kind = "bool", modes = SHELL_MODES,
    desc = "For performance tests. Off (default): an animated object (playAmbient on, or an _anim shape) never uses the pool: it is created fresh and deleted when its section goes, so its animation restarts cleanly. On: it is pooled like every other object (revive, same-shape reuse, refill); see Reset animations for what happens to its animation." },
  { key = "restartAmbient", debug = true, group = "Shell pool", label = "Reset animations", kind = "bool", modes = SHELL_MODES, requires = "animatedInShells",
    desc = "Only with Animated objects in shells. A pooled animated object that is shown again otherwise stays frozen. On: playAmbient is switched off when the object is hidden and on again, with a postApply, once it is visible, which restarts the animation. Off: shown as it is." },
  { key = "shapeCache", group = "Shape cache", label = "Preload", kind = "bool",
    desc = "Hold the meshes of the section island you are in (the sections connected to the current one through their relations) with one hidden object each, kept loaded. A mesh is then loaded once, by its holder, and streaming only revives, retargets and unhides objects. The fill runs only while the car and camera are still (unless Preload always is on) and only while nothing is queued; a mesh a create needs is held at once. Off releases the holders." },
  { key = "shapeCacheMax", group = "Shape cache", label = "Max meshes to save", kind = "int", min = 0, max = 100000, requires = "shapeCache",
    desc = "Most meshes kept held. The fill stops there, and when you move to another island the holders of the old one are evicted first. Up to the number of meshes read: everything the island needs. Lower: less RAM, more cold loads in busy frames." },
  { key = "shapeCacheAlways", group = "Shape cache", debug = true, label = "Preload always", kind = "bool", requires = "shapeCache",
    desc = "On: the fill also runs while the car and camera move (still only while nothing is queued; heavy meshes still wait for a still camera). Off: it runs only when they are still." },
  { key = "debugLog", group = "Debug", debug = true, label = "Detailed logs", kind = "bool",
    desc = "On: the cacher lines, the full run summary and the fill progress go to the log. Off: only a short summary and warnings." },
  { key = "shapeCacheAtLoad", debug = true, group = "Shape cache", label = "Fill at level load", kind = "bool", requires = "shapeCache",
    desc = "On: the fill starts at once, without waiting for the idle time. Off: it waits for the idle time before the first hold like after every section change." },
  { key = "shapeCacheIdleSeconds", debug = true, group = "Shape cache", label = "Idle before fill (s)", kind = "float", min = 0, max = 5, requires = "shapeCache",
    desc = "Both load queues must have been empty this long before the fill holds a shape. Higher: it stays out of the way after every section change." },
  { key = "shapeCacheGapSeconds", debug = true, group = "Shape cache", label = "Gap after a hold (s)", kind = "float", min = 0, max = 2, requires = "shapeCache",
    desc = "Pause after every hold. Higher: the loads are spread out, the fill takes longer. 0 = back to back, for a loading screen." },
  { key = "shapeCachePerFrame", debug = true, group = "Shape cache", label = "Holds per frame", kind = "int", min = 1, max = 64, lo = 1, requires = "shapeCache",
    desc = "Most shapes held in one idle frame. Each one is a mesh load (about 1 to 2 ms from the .cdae cache, 5 ms or more when it must be imported first). Higher: filled sooner, longer idle frames." },
  { key = "shapeCacheBudgetShare", debug = true, group = "Shape cache", label = "Frame share for holding", kind = "share", min = 0.05, max = 4, requires = "shapeCache",
    desc = "Part of the frame budget the holding may use per idle frame (a single first import can still run longer). Higher: filled sooner. Use 1 or more with a high per-frame count for a loading-screen style fill, standing still." },
  { key = "shapeCacheRamFloorGB", debug = true, group = "Shape cache", label = "RAM floor (free GB)", kind = "float", min = 0, max = 32, requires = "shapeCache",
    desc = "The fill pauses while free RAM is below this and resumes above it. 0 = off. Needs a memory source (setMemoryProvider); without one nothing is compared and the panel says so." },
  { key = "shapeCacheHeavyMs", debug = true, group = "Shape cache", label = "Heavy shape threshold (ms)", kind = "float", min = 1, max = 200, requires = "shapeCache",
    desc = "A shape whose measured load time is above this is heavy (the times are kept between sessions). Lower: more shapes count as heavy. A slower hold or create than this also shows as the last hitch." },
  { key = "shapeCacheHeavyWait", debug = true, group = "Shape cache", label = "Heavy shapes wait for a still camera", kind = "bool", requires = "shapeCache",
    desc = "On: heavy shapes are held only while the camera is still (at level load it is), never mid-drive. Off: they are held like any other shape. A heavy shape a create needs is held at once either way." },
  { key = "shapeCacheStillSeconds", debug = true, group = "Shape cache", label = "Still time (s)", kind = "float", min = 0, max = 10, requires = "shapeCacheHeavyWait",
    desc = "How long the camera must stand (under 0.5 m/s) before heavy shapes are held. Higher: heavy shapes wait for a longer stop." },
  { key = "shapeCachePlaceholders", debug = true, group = "Shape cache", label = "Placeholder shells ahead", kind = "int", min = 0, max = 2000, requires = "shapeCache",
    desc = "Hidden holders on the dot built ahead of the fill. A hold takes one and only changes its shapeName, so the object cost is paid earlier, in idle frames. 0 = create the holder with the hold." },
  { key = "indexBeforeStreaming", debug = true, group = "Shape cache", label = "Index before streaming", kind = "bool", requires = "shapeCache",
    desc = "On: at level load the section files are read into the shape index first, using the whole frame budget, and no scenery is streamed until that is done. Off: the index is read only while nothing is queued, which never happens while a section is still streaming." },
  { key = "shapeIndexBudgetShare", debug = true, group = "Shape cache", label = "Shape index share", kind = "share", min = 0.05, max = 4, requires = "shapeCache",
    desc = "Part of the frame budget the shape index may spend per frame reading section files (one file is always read per idle frame). Higher: the index is ready sooner, with longer idle frames." },

  { key = "logSettle", debug = true, group = "Other", label = "Log settled sections", kind = "bool",
    desc = "Write a timing block to the log when the load of a section change has finished." },
  { key = "testingMode", debug = true, group = "Other", label = "Testing Mode", kind = "bool",
    desc = "Enable bounded per-frame stage timings, slow-operation traces, pool/queue deltas and spike summaries. Adds a small amount of timing/bookkeeping work; turn off for normal play." },
  { key = "probeOnSettle", debug = true, group = "Other", label = "Probe after settle", kind = "bool", requires = "logSettle",
    desc = "After a settle, time a few test creates and log them next to the real averages. Diagnostic only; it adds a little work to that frame." },
}
tun.byKey = {}
for _, row in ipairs(tun.schema) do tun.byKey[row.key] = row end

-- Three presets per creation mode. Until the user saves a slot, it holds these values (only budget and pool
-- settings; everything else keeps its current value). Starting points, not measured results.
tun.slots = { "A", "B", "C" }
tun.factory = {
  current = {
    A = { label = "A", values = { frameBudgetMs = 8, deleteBudgetShare = 0.25, maxCreatesPerFrame = 4, maxFirstUsePerFrame = 1, unloadCooldown = 2 } },
    B = { label = "B", values = { frameBudgetMs = 16, deleteBudgetShare = 0.25, maxCreatesPerFrame = 16, maxFirstUsePerFrame = 3, unloadCooldown = 2 } },
    C = { label = "C", values = { frameBudgetMs = 24, deleteBudgetShare = 0.5, maxCreatesPerFrame = 64, maxFirstUsePerFrame = 8, unloadCooldown = 1 } },
  },
  shells = {
    A = { label = "A", values = { frameBudgetMs = 8, deleteBudgetShare = 0.25, maxCreatesPerFrame = 8, maxFirstUsePerFrame = 1, unloadCooldown = 2, shellTarget = 0, shellBuildPerFrame = 4, shellBuildBudgetShare = 0.1 } },
    B = { label = "B", values = { frameBudgetMs = 16, deleteBudgetShare = 0.25, maxCreatesPerFrame = 32, maxFirstUsePerFrame = 3, unloadCooldown = 2, shellTarget = 3500, shellBuildPerFrame = 8, shellBuildBudgetShare = 0.125 } },
    C = { label = "C", values = { frameBudgetMs = 24, deleteBudgetShare = 0.5, maxCreatesPerFrame = 128, maxFirstUsePerFrame = 8, unloadCooldown = 1, shellTarget = 4000, shellBuildPerFrame = 16, shellBuildBudgetShare = 0.2 } },
  },
  resident = {
    A = { label = "A", values = { frameBudgetMs = 8, deleteBudgetShare = 0.25, maxRefillsPerFrame = 8, maxCheapPerFrame = 64, maxFirstUsePerFrame = 1, residentCooldown = 0, shapeCachePerFrame = 1, shapeCacheBudgetShare = 0.1 } },
    B = { label = "B", values = { frameBudgetMs = 16, deleteBudgetShare = 0.25, maxRefillsPerFrame = 32, maxCheapPerFrame = 256, maxFirstUsePerFrame = 3, residentCooldown = 0, shapeCachePerFrame = 1, shapeCacheBudgetShare = 0.125 } },
    C = { label = "C", values = { frameBudgetMs = 24, deleteBudgetShare = 0.5, maxRefillsPerFrame = 128, maxCheapPerFrame = 1024, maxFirstUsePerFrame = 8, residentCooldown = 0, shapeCachePerFrame = 2, shapeCacheBudgetShare = 0.25 } },
  },
}

-- What changed in the tuning and when: the panel shows it so a change can be checked, not assumed.
tun.state = { revision = 0, last = nil, log = {} }
end

SUPPORTED_SCHEMA = 2
SECTIONS_JSON = "lua/sections.json"
STREAM_INDEX = "lua/streamer/index.json"
PRESETS_JSON = "lua/streamer/tuning_presets.json"
SKIP_CAP = 4096

RESERVED = {
  class = true, name = true, __parent = true,
  __streamKey = true, __streamSections = true, __streamSource = true,
}

-- A copy of the current tuning values (for the console: dump(extensions.nfsc_sectionStreamer.getTuning())).
function M.getTuning()
  local copy = {}
  for k, v in pairs(TUNING) do copy[k] = v end
  return copy
end

-- Live tuning ---------------------------------------------------------------------------------------------
function presetPath() return levelRoot .. "/" .. PRESETS_JSON end

readPresets = function()
  local ok, data = pcall(jsonReadFile, presetPath())
  return (ok and type(data) == "table") and data or {}
end

NOT_TUNABLE = { levelRoot = true, runtimeGroupName = true, warmGroupName = true }

function tunableValues()
  local out = {}
  for k, v in pairs(TUNING) do
    local t = type(v)
    if not NOT_TUNABLE[k] and (t == "number" or t == "boolean" or k == "creationMode" or k == "shellShape") then out[k] = v end
  end
  return out
end

function M.getDefaultTuning()
  local copy = {}
  for k, v in pairs(TUNING_DEFAULTS) do copy[k] = v end
  return copy
end

-- The panel builds itself from this (read only).
function M.getTuningSchema() return tun.schema end
function M.getCreationModes() return { "current", "shells", "resident" } end

function tun.fmt(v)
  if type(v) == "number" then return string.format("%.4g", v) end
  return tostring(v)
end

-- Presets saved before the budgets became shares of the frame: ms -> share of the frame budget they were saved with.
function tun.migrate(values)
  local out = {}
  for k, v in pairs(values or {}) do out[k] = v end
  local main = type(out.frameBudgetMs) == "number" and out.frameBudgetMs or TUNING.frameBudgetMs
  for old, new in pairs({ shellBuildBudgetMs = "shellBuildBudgetShare", cacheWarmCheckMs = "cacheWarmCheckShare" }) do
    local ms = out[old]
    out[old] = nil
    if ms ~= nil and out[new] == nil and type(ms) == "number" and main > 0 then out[new] = ms / main end
  end
  for old, new in pairs({ warmAll = "shapeCache", warmAllPerFrame = "shapeCachePerFrame", warmAllBudgetShare = "shapeCacheBudgetShare",
                          cacheWarmIdleSeconds = "shapeCacheIdleSeconds", cacheWarmGapSeconds = "shapeCacheGapSeconds" }) do
    local v = out[old]
    out[old] = nil
    if v ~= nil and out[new] == nil then out[new] = v end
  end
  for _, old in ipairs({ "cacheWarm", "cacheWarmPerFrame", "cacheWarmCheckShare", "cacheWarmLogEvery", "warmAllLogEvery" }) do out[old] = nil end
  return out
end

-- Applies values with checks: unknown keys and wrong types are rejected, numbers are held to the hard limits of
-- their schema row (integers rounded), creationMode goes through setCreationMode. Returns the list of changes
-- { key, old, new } and the list of rejections { key, why }; both are remembered for the panel.
function tun.apply(values, source)
  local data = tun.migrate(values)
  local keys = {}
  for k in pairs(data) do keys[#keys + 1] = k end
  table.sort(keys)
  local changed, rejected, mode = {}, {}, nil
  for _, k in ipairs(keys) do
    local v, want, row = data[k], TUNING_DEFAULTS[k], tun.byKey[k]
    if want == nil or NOT_TUNABLE[k] then
      rejected[#rejected + 1] = { key = k, why = "unknown setting" }
    elseif type(v) ~= type(want) then
      rejected[#rejected + 1] = { key = k, why = "expected " .. type(want) }
    elseif type(v) == "number" and (v ~= v or v == math.huge or v == -math.huge) then
      rejected[#rejected + 1] = { key = k, why = "not a finite number" }
    elseif k == "creationMode" then
      mode = v
    else
      if type(v) == "number" then
        local lo, hi = 0, nil
        if row then
          lo = row.lo or 0
          hi = row.hi or (row.kind == "share" and 1 or nil)
          if row.kind == "int" then v = math.floor(v + 0.5) end
        end
        if v < lo then v = lo end
        if hi and v > hi then v = hi end
      end
      local old = TUNING[k]
      if old ~= v then
        TUNING[k] = v
        changed[#changed + 1] = { key = k, old = old, new = v }
      end
    end
  end
  if mode and mode ~= TUNING.creationMode then
    local old = TUNING.creationMode
    local ok, err = M.setCreationMode(mode)
    if ok then changed[#changed + 1] = { key = "creationMode", old = old, new = mode }
    else rejected[#rejected + 1] = { key = "creationMode", why = tostring(err) } end
  end
  if #changed > 0 then tun.state.revision = tun.state.revision + 1 end
  if #changed > 0 or #rejected > 0 or source:find("^preset") or source == "reset" then
    local now = os.clock()
    tun.state.last = { source = source, time = now, changed = changed, rejected = rejected, revision = tun.state.revision }
    for _, c in ipairs(changed) do
      local log = tun.state.log
      log[#log + 1] = { time = now, source = source, key = c.key, old = c.old, new = c.new }
      if #log > 16 then table.remove(log, 1) end
    end
  end
  if M.stallDiagnostics then M.stallDiagnostics:setEnabled(TUNING.testingMode) end
  return changed, rejected
end

-- Values to apply from the console or code. quiet = true (the panel) skips the log lines: the panel shows the change itself.
-- Returns the list of changes and the list of rejections.
function M.setTuning(values, quiet)
  local changed, rejected = tun.apply(values or {}, quiet and "panel" or "setTuning")
  if not quiet then
    for _, c in ipairs(changed) do logMsg("I", "tuning: %s %s -> %s", c.key, tun.fmt(c.old), tun.fmt(c.new)) end
    for _, r in ipairs(rejected) do logMsg("W", "tuning: %s not applied (%s)", r.key, r.why) end
  end
  return changed, rejected
end

-- Revision (counts every real change), the last change and the recent changes, for the panel or the console.
function M.getTuningInfo()
  local recent = {}
  for i, e in ipairs(tun.state.log) do recent[i] = e end
  return { revision = tun.state.revision, last = tun.state.last, recent = recent, now = os.clock() }
end

function tun.defaults()
  local out = {}
  for k, v in pairs(TUNING_DEFAULTS) do if not NOT_TUNABLE[k] then out[k] = v end end
  return out
end

function M.resetTuning()
  local changed = tun.apply(tun.defaults(), "reset")
  logMsg("I", "tuning reset to the defaults (%d values changed)", #changed)
  return #changed
end

function M.listPresets()
  local names = {}
  for name in pairs(readPresets()) do names[#names + 1] = name end
  table.sort(names)
  return names
end

function tun.write(presets)
  local ok, err = pcall(function() return jsonWriteFile(presetPath(), presets, true) end)
  if not ok then recordFailure("could not write the presets: " .. tostring(err)); return false, tostring(err) end
  return true
end

function M.savePreset(name)
  if type(name) ~= "string" or name == "" then return false, "no name" end
  local presets = readPresets()
  presets[name] = tunableValues()
  local ok, err = tun.write(presets)
  if not ok then return false, err end
  logMsg("I", "preset saved: %s", name)
  return true
end

function M.loadPreset(name)
  local values = readPresets()[name]
  if type(values) ~= "table" then return false, "no such preset" end
  local changed, rejected = tun.apply(values, "preset " .. tostring(name))
  logMsg("I", "preset loaded: %s (%d values changed, %d not applied)", name, #changed, #rejected)
  return true
end

function M.deletePreset(name)
  local presets = readPresets()
  if presets[name] == nil then return false, "no such preset" end
  presets[name] = nil
  return tun.write(presets)
end

-- Presets per creation mode: three slots (A, B, C) for each of current, shells and resident, stored as "<mode>/<slot>".
-- A slot nobody saved holds its factory values; a flat A/B/C from before is used for the mode it was saved in.
function tun.validSlot(mode, slot)
  if not tun.factory[mode] then return false, "unknown creation mode: " .. tostring(mode) end
  if not tun.factory[mode][slot] then return false, "unknown preset slot: " .. tostring(slot) end
  return true
end

function tun.resolve(presets, mode, slot)
  local saved = presets[mode .. "/" .. slot]
  if type(saved) == "table" then return saved, "saved" end
  local legacy = presets[slot]
  if type(legacy) == "table" and (legacy.creationMode or "current") == mode then return legacy, "saved" end
  local values = { creationMode = mode }
  for k, v in pairs(tun.factory[mode][slot].values) do values[k] = v end
  return values, "factory"
end

-- { slot, label, source = "saved" | "factory" } for the three slots of a mode.
function M.getModePresets(mode)
  local out = {}
  if not tun.factory[mode] then return out end
  local presets = readPresets()
  for _, slot in ipairs(tun.slots) do
    local _, source = tun.resolve(presets, mode, slot)
    out[#out + 1] = { slot = slot, label = tun.factory[mode][slot].label, source = source }
  end
  return out
end

function M.loadModePreset(mode, slot)
  local ok, err = tun.validSlot(mode, slot)
  if not ok then return false, err end
  local values, source = tun.resolve(readPresets(), mode, slot)
  local name = mode .. "/" .. slot
  local changed, rejected = tun.apply(values, "preset " .. name .. " (" .. source .. ")")
  logMsg("I", "preset loaded: %s (%s, %d values changed, %d not applied)", name, source, #changed, #rejected)
  return true, #changed
end

function M.saveModePreset(mode, slot)
  local ok, err = tun.validSlot(mode, slot)
  if not ok then return false, err end
  if mode ~= TUNING.creationMode then return false, "the active creation mode is " .. TUNING.creationMode end
  local presets = readPresets()
  presets[mode .. "/" .. slot] = tunableValues()
  local saved, why = tun.write(presets)
  if not saved then return false, why end
  logMsg("I", "preset saved: %s/%s", mode, slot)
  return true
end

-- Back to the factory values: removes the saved slot (and a flat A/B/C that stood in for it).
function M.deleteModePreset(mode, slot)
  local ok, err = tun.validSlot(mode, slot)
  if not ok then return false, err end
  local presets = readPresets()
  local key, removed = mode .. "/" .. slot, false
  if presets[key] ~= nil then presets[key] = nil; removed = true end
  local legacy = presets[slot]
  if type(legacy) == "table" and (legacy.creationMode or "current") == mode then presets[slot] = nil; removed = true end
  if not removed then return false, "nothing saved in this slot" end
  return tun.write(presets)
end

-- The current values as a Lua table, one line each, in the log (to paste back into TUNING).
function M.printTuning()
  local keys = {}
  for k in pairs(tunableValues()) do keys[#keys + 1] = k end
  table.sort(keys)
  logMsg("I", "TUNING values:")
  for _, k in ipairs(keys) do
    local v = TUNING[k]
    logMsg("I", "  %s = %s,", k, type(v) == "string" and string.format("%q", v) or tostring(v))
  end
end
