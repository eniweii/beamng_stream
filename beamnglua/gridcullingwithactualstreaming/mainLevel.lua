-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local luaLoaded = false
local extensionsLoaded = {}

local beta = false

--level data
local levelfolder = nil
local levelname =  nil

local tool_version = "3.0"

local function onClientStartMission()
  luaLoaded = true
  log('I', 'onClientStartMission', 'Getting current level path' )
  levelname = getCurrentLevelIdentifier()
  log('I', 'onClientStartMission', 'Level is loaded '..levelname )
  levelfolder = ("/levels/" .. levelname .. "/")
  levels_nfsps_autobahn_lua_tsstatic_grid_culling.initializeObjects()
end

local function onUpdate(dtReal, dtSim, dtRaw)
  if luaLoaded == false then
    extensions.mainLevel.onClientStartMission()
  end
  levels_nfsps_autobahn_lua_tsstatic_grid_culling.onUpdate(dtReal, dtSim, dtRaw)
end

local function getMainData()
  local mainData = {
    beta = beta,
    levelfolder = levelfolder,
    levelname = levelname,
    tool_version = tool_version
  }
  return mainData
end

local function onExtensionLoaded()
  local luaModules = FS:findFiles('levels/nfsps_autobahn/lua', '*.lua', 1, true, false)
  for k,fn in pairs(luaModules) do
    log('I', 'onExtensionLoaded', 'Loading: '..fn )
    local dir, basefilename, ext = path.splitWithoutExt(fn)
    local extensionName = dir..basefilename
    extensionName = extensionName:gsub("/levels", "levels")
    extensionName = extensionName:gsub("/", "_")
    local chunk, err = loadfile(fn)
    if chunk then
      _G[extensionName] = chunk()
    else
      log('E', 'onExtensionLoaded', 'Failed to load '..fn..': '..tostring(err))
    end
    table.insert(extensionsLoaded, extensionName)
  end
end

local function onExtensionUnloaded()
  for k,v in pairs(extensionsLoaded) do
    log('I', 'onExtensionUnloaded', 'Unloading extension '..v)
    _G[v] = nil
  end
end

M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onClientStartMission = onClientStartMission
M.getMainData = getMainData
M.onUpdate = onUpdate

return M
