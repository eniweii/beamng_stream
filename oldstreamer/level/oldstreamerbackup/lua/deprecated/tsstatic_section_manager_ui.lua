-- imgui debug panel for the section streamer: shows the current section
-- (numeric ID + letter/number display name) and two toggle lists -
-- "Always-on overrides" and "Hidden overrides" - sorted nearest-to-current-
-- section first. Purely a viewer/control surface; all real state lives in
-- tsstatic_section_streaming.lua.
--
-- Assumption flagged for verification in-engine: the ui_imgui API shape used
-- below (im.Begin/End, im.BoolPtr, im.Checkbox, im.TreeNode1/TreePop, im.Text)
-- matches other BeamNG debug-app conventions, but hasn't been run yet.

local M = {}
local im = ui_imgui

local streamer = nil -- set via setStreamerModule() by mainLevel.lua, since the
                      -- streamer's own global name is level-dependent

local windowOpen = im.BoolPtr(true)

local function setStreamerModule(streamerModuleRef)
  streamer = streamerModuleRef
end

local function drawOverrideList(label, names)
  if im.TreeNode1(label) then
    if #names == 0 then
      im.TextDisabled("(none)")
    end
    for _, name in ipairs(names) do
      local checkPtr = im.BoolPtr(streamer.isOverrideEnabled(name))
      if im.Checkbox(name, checkPtr) then
        streamer.setOverrideEnabled(name, checkPtr[0])
      end
    end
    im.TreePop()
  end
end

local function onUpdate(dtReal, dtSim, dtRaw)
  if not streamer then return end

  im.Begin("Section Manager (test)", windowOpen)

  local currentID = streamer.getCurrentSectionID()
  im.Text("Current section: " .. streamer.sectionIDToDisplayName(currentID))
  if im.Button("Refresh") then
    streamer.refresh()
  end
  im.SameLine()
  if im.Button(streamer.isHalted() and "Resume streaming" or "Halt streaming (show all)") then
    streamer.setHalted(not streamer.isHalted())
  end
  im.Separator()

  local sortedNames = streamer.getSortedOverrideNames()
  local alwaysOn, hidden = {}, {}
  for _, name in ipairs(sortedNames) do
    if streamer.isOverrideEnabled(name) then
      table.insert(alwaysOn, name)
    else
      table.insert(hidden, name)
    end
  end

  drawOverrideList("Always-on overrides", alwaysOn)
  drawOverrideList("Hidden overrides", hidden)

  im.End()
end

M.setStreamerModule = setStreamerModule
M.onUpdate = onUpdate

return M
