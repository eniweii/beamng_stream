-- mainLevel.lua for the nfsc level using the section streaming extensions.
--
-- The streamer, manager, collision policy and panel are engine extensions
-- (lua/ge/extensions/nfsc/): this file only loads them, initializes the streamer, and unloads
-- them with the level. The engine calls their onUpdate itself, so nothing is forwarded here.
-- The level host (nfsc_levelHost) and its panel run the level components: the sound zones (tunnel / overpass /
-- garage ambience spaces, from lua/zones.json, read once), the volume emitter scatter, the material roughness,
-- the object sway and the texture animation. The host is the streamer's one object-event listener.
-- The manager also owns emitter and light visibility now, so the legacy
-- tsstatic_section_streaming.lua and its panel must NOT be loaded any more.
-- The level's lua/ folder holds data only; nothing is loaded from it with loadfile any more.

local M = {}

local levelName = "nfsc"
local basePath = "levels/" .. levelName      -- no leading slash

local EXTENSIONS = { "nfsc_sectionStreamer", "nfsc_sectionManager", "nfsc_sectionCollision", "nfsc_sectionManagerUi",
                     "nfsc_levelHost", "nfsc_levelHostUi" }

local luaLoaded = false
local beta = false
local levelfolder = "/" .. basePath .. "/"
local tool_version = "3.0"

local function onLoad()
  luaLoaded = true
  log('I', 'onLoad', 'Level base path: ' .. basePath)

  for _, name in ipairs(EXTENSIONS) do extensions.load(name) end
  if nfsc_sectionStreamer then
    local ok, err = nfsc_sectionStreamer.initialize(basePath)
    if not ok then log('E', 'onLoad', 'Section streamer failed to initialize: ' .. tostring(err)) end
  end
  if nfsc_levelHost then nfsc_levelHost.initialize(basePath) end                     -- reads lua/zones.json once and starts the level components
end

local function onUpdate(dtReal, dtSim, dtRaw)
  if luaLoaded == false then extensions.mainLevel.onLoad() end
end

local function getMainData()
  return { beta = beta, levelfolder = levelfolder, levelname = levelName, tool_version = tool_version }
end

local function onExtensionUnloaded()
  for i = #EXTENSIONS, 1, -1 do
    if extensions.unload then extensions.unload(EXTENSIONS[i]) end
  end
end

M.onExtensionUnloaded = onExtensionUnloaded
M.onLoad = onLoad
M.getMainData = getMainData
M.onUpdate = onUpdate

return M