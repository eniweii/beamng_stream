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

-- Creation method: three radios.
local CREATION_MODES = { { "current", "Current" }, { "shells", "Shells" }, { "resident", "Resident" } }

local function drawCreationMode(st)
  im.Text("Creation:")
  for _, m in ipairs(CREATION_MODES) do
    im.SameLine()
    if radio(m[2] .. "##creation", (st.creationMode or "current") == m[1]) then nfsc_sectionStreamer.setCreationMode(m[1]) end
  end
end

-- Live tuning: { key, label, kind, min, max }. A change is applied at once through setTuning.
local TUNING_GROUPS = {
  { "Load budget", {
    { "frameBudgetMs", "Frame budget (ms)", "float", 1, 50 },
    { "deleteBudgetShare", "Share for deletes / parks", "float", 0.05, 1 },
    { "maxCreatesPerFrame", "Max creates per frame", "int", 1, 256 },
    { "maxDeletesPerFrame", "Max deletes per frame", "int", 1, 2048 },
    { "maxFirstUsePerFrame", "Max first uses per frame", "int", 1, 16 },
    { "firstUseGuessMs", "First use guess (ms)", "float", 1, 40 },
    { "maxSectionReadsPerFrame", "Section reads per frame", "int", 1, 8 },
    { "maxQueuedItems", "Load queue cap", "int", 64, 4096 },
  } },
  { "Unloading and pool", {
    { "unloadCooldown", "Unload cooldown (s)", "float", 0, 10 },
    { "residentCooldown", "Resident deactivate delay (s)", "float", 0, 10 },
    { "residentMax", "Resident pool size", "int", 500, 30000 },
    { "residentReserve", "Resident free reserve", "int", 0, 2000 },
    { "shellTarget", "Shells built ahead (target)", "int", 0, 30000 },
    { "shellBuildPerFrame", "Shells per frame", "int", 1, 64 },
    { "shellBuildBudgetMs", "Shell build budget (ms)", "float", 0.1, 8 },
  } },
  { "Look-ahead and order", {
    { "predictionEnabled", "Look-ahead", "bool" },
    { "predictionSeconds", "Look-ahead time (s)", "float", 0, 5 },
    { "currentSectionFirst", "Current section first", "bool" },
  } },
  { "Cache warm-up", {
    { "cacheWarm", "Cache warm-up lane", "bool" },
    { "cacheWarmPerFrame", "Imports per frame", "int", 1, 4 },
    { "cacheWarmGapSeconds", "Gap after an import (s)", "float", 0, 2 },
    { "cacheWarmIdleSeconds", "Idle time before it starts (s)", "float", 0, 5 },
  } },
  { "Other", {
    { "forceCollisionNone", "Collision off", "bool" },
    { "logSettle", "Log settled sections", "bool" },
    { "probeOnSettle", "Probe after settle", "bool" },
  } },
}
local PRESET_SLOTS = { "startup", "A", "B", "C" }

local tuningPtrs = {}
local tuningBroken = false

local function drawTuningRow(tuning, row)
  local key, label, kind = row[1], row[2], row[3]
  local value = tuning[key]
  if value == nil then return end
  local ptr = tuningPtrs[key]
  if kind == "bool" then
    if not ptr then ptr = im.BoolPtr(value); tuningPtrs[key] = ptr end
    ptr[0] = value
    if im.Checkbox(label .. "##t" .. key, ptr) then nfsc_sectionStreamer.setTuning({ [key] = ptr[0] }) end
  elseif kind == "int" then
    if not ptr then ptr = im.IntPtr(value); tuningPtrs[key] = ptr end
    ptr[0] = value
    if im.SliderInt(label .. "##t" .. key, ptr, row[4], row[5]) then nfsc_sectionStreamer.setTuning({ [key] = ptr[0] }) end
  else
    if not ptr then ptr = im.FloatPtr(value); tuningPtrs[key] = ptr end
    ptr[0] = value
    if im.SliderFloat(label .. "##t" .. key, ptr, row[4], row[5], "%.2f") then nfsc_sectionStreamer.setTuning({ [key] = ptr[0] }) end
  end
end

-- Not engine-verified like the rest of this panel; if an imgui call is missing the section turns itself off.
local function drawTuning()
  if tuningBroken then return end
  local ok, err = pcall(function()
    if not im.CollapsingHeader1("Tuning (live)") then return end
    local tuning = nfsc_sectionStreamer.getTuning()
    for _, group in ipairs(TUNING_GROUPS) do
      if im.TreeNode1(group[1] .. "##tg") then
        for _, row in ipairs(group[2]) do drawTuningRow(tuning, row) end
        im.TreePop()
      end
    end
    if im.TreeNode1("Presets##tp") then
      local saved = {}
      for _, name in ipairs(nfsc_sectionStreamer.listPresets()) do saved[name] = true end
      for _, name in ipairs(PRESET_SLOTS) do
        im.Text(name .. (saved[name] and "  (saved)" or "  (empty)"))
        im.SameLine()
        if im.Button("Load##p" .. name) then nfsc_sectionStreamer.loadPreset(name) end
        im.SameLine()
        if im.Button("Save##p" .. name) then nfsc_sectionStreamer.savePreset(name) end
        im.SameLine()
        if im.Button("Delete##p" .. name) then nfsc_sectionStreamer.deletePreset(name) end
      end
      im.TextDisabled("\"startup\" is applied when the streamer starts")
      im.TreePop()
    end
    if im.Button("Reset to defaults") then nfsc_sectionStreamer.resetTuning() end
    im.SameLine()
    if im.Button("Print values to log") then nfsc_sectionStreamer.printTuning() end
  end)
  if not ok then
    tuningBroken = true
    log("E", "nfsc_sectionManagerUi", "tuning section turned off: " .. tostring(err))
  end
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

  drawCreationMode(st)
  if st.shellPoolActive then
    im.Text(string.format("Pool: %d (%d free, %d dormant, %d live), %d built ahead (target %d)    recycled %d (avg %.3f ms)    fresh %d    parked %d    peak live %d",
      st.poolTotal or 0, st.shellsFree or 0, st.residentDormant or 0, st.liveObjectCount or 0, st.shellsBuilt or 0, st.shellTarget or 0,
      st.shellsRecycled or 0, st.shellRecycleAvgMs or 0, st.shellsFresh or 0, st.shellsParked or 0, st.shellPeakLive or 0))
  end
  if st.residentActive then
    im.Text(string.format("Resident: revived %d (avg %.3f ms), deactivated %d, evicted %d, pool cap %d, free reserve %d",
      st.residentRevived or 0, st.residentReviveAvgMs or 0, st.residentDeactivated or 0, st.residentEvicted or 0,
      st.residentMax or 0, st.residentReserve or 0))
  end
  im.Text(string.format("Dropped sections: %d (%d objects were still missing when the camera left)", st.droppedSections or 0, st.droppedObjects or 0))
  local d = st.droppedLast
  if d then
    im.TextDisabled(string.format("last: %s after %.2f s, %d created, %d queued, %d waiting records", tostring(d.section), d.after or 0,
      d.created or 0, d.queued or 0, d.waiting or 0))
  end
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
  drawTuning()
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
