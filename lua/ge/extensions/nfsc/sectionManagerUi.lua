-- nfsc_sectionManagerUi: imgui panel for the section streamer and section manager.
-- A viewer/control surface only; all state lives in nfsc_sectionStreamer (what exists)
-- and nfsc_sectionManager (which overrides are visible).
--
-- Flagged for in-engine verification: the ui_imgui calls below (Begin/End, BoolPtr,
-- Checkbox, TreeNode1/TreePop, Text, Button) follow the same conventions as the earlier
-- tsstatic_section_manager_ui.lua, which has not been run in the engine yet either.

local M = {}
M.dependencies = { "nfsc_sectionManager" }

local im = ui_imgui
local windowOpen = im.BoolPtr(true)

-- One radio pair. RadioButton1(label, active) follows the overload-suffix convention of the other
-- imgui calls here; unverified in the engine like the rest of this panel.
local function radio(label, active)
  local fn = im.RadioButton1 or im.RadioButton
  return fn(label, active)
end

local function radioPair(title, leftLabel, rightLabel, leftActive)
  im.Text(title)
  im.SameLine()
  local clickedLeft = radio(leftLabel .. "##" .. title, leftActive)
  im.SameLine()
  local clickedRight = radio(rightLabel .. "##" .. title, not leftActive)
  return clickedLeft, clickedRight
end

local function drawOverrideList(label, names)
  if im.TreeNode1(label) then
    if #names == 0 then im.TextDisabled("(none)") end
    for _, name in ipairs(names) do
      local ptr = im.BoolPtr(nfsc_sectionManager.isOverrideEnabled(name))
      if im.Checkbox(name, ptr) then nfsc_sectionManager.setOverrideEnabled(name, ptr[0]) end
    end
    im.TreePop()
  end
end

function M.onUpdate()
  if not nfsc_sectionStreamer or not nfsc_sectionManager then return end
  im.Begin("Section Manager", windowOpen)

  local st = nfsc_sectionManager.getStatus()
  im.Text("Current section: " .. tostring(st.currentSectionName or "none"))
  im.Text(string.format("Active sections: %d    Live objects: %d", st.activeSectionCount or 0, st.liveObjectCount or 0))
  im.Text(string.format("Queued: %d objects, %d section reads    Pending unload: %d",
    st.queuedObjectCount or 0, st.queuedSectionReads or 0, st.pendingUnloadCount or 0))
  im.Text(string.format("Created: %d    Deleted: %d    Failures: %d",
    st.createdTotal or 0, st.deletedTotal or 0, st.failureCount or 0))

  local left, right = radioPair("Emitters:", "On", "Off", st.emittersOn)
  if left then nfsc_sectionManager.setSceneClassEnabled("emitters", true) end
  if right then nfsc_sectionManager.setSceneClassEnabled("emitters", false) end
  left, right = radioPair("Lights:", "On", "Off", st.lightsOn)
  if left then nfsc_sectionManager.setSceneClassEnabled("lights", true) end
  if right then nfsc_sectionManager.setSceneClassEnabled("lights", false) end
  left, right = radioPair("Game mode:", "Freeroam", "Racing", st.gameMode == "freeroam")
  if left then nfsc_sectionManager.setGameMode("freeroam") end
  if right then nfsc_sectionManager.setGameMode("racing") end
  left, right = radioPair("Platform:", "High", "Low", st.platform == "high")
  if left then nfsc_sectionManager.setPlatform("high") end
  if right then nfsc_sectionManager.setPlatform("low") end
  im.Text(string.format("Scene: %d emitters, %d lights, %d shown    Managed streamed objects: %d    Unknown flags: %d",
    st.sceneEmitters or 0, st.sceneLights or 0, st.sceneShown or 0, st.managedObjectsLive or 0, st.unknownFlagCount or 0))

  if nfsc_sectionCollision then
    local c = nfsc_sectionCollision.getStatus()
    im.Text(string.format("Collision: %s    refreshes: %d  last %.1f ms  max %.1f ms%s", c.mode, c.reloads,
      c.lastMs, c.maxMs, c.dirty and "  (pending)" or ""))
  end

  if im.Button(nfsc_sectionStreamer.isSuspended() and "Resume streaming" or "Suspend streaming") then
    nfsc_sectionStreamer.setSuspended(not nfsc_sectionStreamer.isSuspended())
  end
  im.SameLine()
  if im.Button("Reload streamed scenery") then nfsc_sectionStreamer.reset() end
  im.Separator()

  local on, off = {}, {}
  for _, name in ipairs(nfsc_sectionManager.getOverrideNames()) do
    if nfsc_sectionManager.isOverrideEnabled(name) then on[#on + 1] = name else off[#off + 1] = name end
  end
  drawOverrideList("Enabled overrides", on)
  drawOverrideList("Hidden overrides", off)

  if (st.failureCount or 0) > 0 and im.TreeNode1("Last failures") then
    for _, msg in ipairs(nfsc_sectionStreamer.getFailures()) do im.TextWrapped(msg) end
    im.TreePop()
  end
  im.End()
end

return M
