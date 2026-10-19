-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

-- TWEAKS - set per level/project, everything else derives from this.
-- Underscores in the level name are fine: modules are loaded with loadfile()
-- and kept in a local table keyed by file name, so no name-to-path guessing.
local levelName = "nfsc"                 -- folder name under levels/
local basePath = "levels/" .. levelName  -- no leading slash

local luaLoaded = false
local modules = {}  -- module file name (no extension) -> loaded module table

local beta = false

--level data
local levelfolder = "/" .. basePath .. "/"
local tool_version = "3.0"

local function onLoad()
  luaLoaded = true
  log('I', 'onLoad', 'Level base path: '..basePath )

  local streamer = modules["tsstatic_section_streaming"]
  local ui = modules["tsstatic_section_manager_ui"]
  local scatter = modules["emitter_volume_scatter"]

  if streamer then
    streamer.initializeObjects(basePath)
  else
    log('E', 'onLoad', 'Streamer module not found in '..basePath..'/lua')
  end

  if scatter and scatter.initialize then
    scatter.initialize()
  else
    log('W', 'onLoad', 'Volume scatter module not found in '..basePath..'/lua')
  end

  if ui and ui.setStreamerModule then
    ui.setStreamerModule(streamer)
  end
end

local function onUpdate(dtReal, dtSim, dtRaw)
  if luaLoaded == false then
    extensions.mainLevel.onLoad()
  end
  local streamer = modules["tsstatic_section_streaming"]
  if streamer then
    streamer.onUpdate(dtReal, dtSim, dtRaw)
  end
  local scatter = modules["emitter_volume_scatter"]
  if scatter and scatter.onUpdate then
    scatter.onUpdate(dtReal, dtSim, dtRaw)
  end
  local ui = modules["tsstatic_section_manager_ui"]
  if ui and ui.onUpdate then
    ui.onUpdate(dtReal, dtSim, dtRaw)
  end
end

local function getMainData()
  local mainData = {
    beta = beta,
    levelfolder = levelfolder,
    levelname = levelName,
    tool_version = tool_version
  }
  return mainData
end

local function onExtensionLoaded()
  local luaModules = FS:findFiles(basePath .. '/lua', '*.lua', 1, true, false)
  for k,fn in pairs(luaModules) do
    log('I', 'onExtensionLoaded', 'Loading: '..fn )
    local dir, basefilename, ext = path.splitWithoutExt(fn)
    local chunk, err = loadfile(fn)
    if chunk then
      modules[basefilename] = chunk()
    else
      log('E', 'onExtensionLoaded', 'Failed to load '..fn..': '..tostring(err))
    end
  end
end

local function onExtensionUnloaded()
  for name in pairs(modules) do
    log('I', 'onExtensionUnloaded', 'Unloading module '..name)
  end
  modules = {}
end

M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onLoad = onLoad
M.getMainData = getMainData
M.onUpdate = onUpdate

return M
