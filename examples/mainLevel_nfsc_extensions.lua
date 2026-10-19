-- mainLevel.lua for the nfsc level using the section streaming extensions.
--
-- The streamer, manager, collision policy and panel are engine extensions
-- (lua/ge/extensions/nfsc/): this file only loads them, initializes the streamer, and unloads
-- them with the level. The engine calls their onUpdate itself, so nothing is forwarded here.
-- The manager also owns emitter and light visibility now, so the legacy
-- tsstatic_section_streaming.lua and its panel must NOT be loaded any more.
-- Other level-local modules in <basePath>/lua (for example the emitter scatter script) still load
-- with loadfile as before.

local M = {}

local levelName = "nfsc"
local basePath = "levels/" .. levelName      -- no leading slash

local EXTENSIONS = { "nfsc_sectionStreamer", "nfsc_sectionManager", "nfsc_sectionCollision", "nfsc_sectionManagerUi" }
local SKIP_LEGACY = { tsstatic_section_streaming = true, tsstatic_section_manager_ui = true }

local luaLoaded = false
local modules = {}
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

  local scatter = modules["emitter_volume_scatter"]
  if scatter and scatter.initialize then scatter.initialize() end
end

local function onUpdate(dtReal, dtSim, dtRaw)
  if luaLoaded == false then extensions.mainLevel.onLoad() end
  local scatter = modules["emitter_volume_scatter"]
  if scatter and scatter.onUpdate then scatter.onUpdate(dtReal, dtSim, dtRaw) end
end

local function getMainData()
  return { beta = beta, levelfolder = levelfolder, levelname = levelName, tool_version = tool_version }
end

local function onExtensionLoaded()
  local luaModules = FS:findFiles(basePath .. '/lua', '*.lua', 1, true, false)
  for _, fn in pairs(luaModules) do
    local _, basefilename = path.splitWithoutExt(fn)
    if not SKIP_LEGACY[basefilename] then
      local chunk, err = loadfile(fn)
      if chunk then modules[basefilename] = chunk()
      else log('E', 'onExtensionLoaded', 'Failed to load ' .. fn .. ': ' .. tostring(err)) end
    end
  end
end

local function onExtensionUnloaded()
  for i = #EXTENSIONS, 1, -1 do
    if extensions.unload then extensions.unload(EXTENSIONS[i]) end
  end
  modules = {}
end

M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onLoad = onLoad
M.getMainData = getMainData
M.onUpdate = onUpdate

return M
