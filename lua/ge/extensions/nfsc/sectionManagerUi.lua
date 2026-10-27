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

-- Hover text. Never lets a missing imgui call turn the tuning section off: it falls back to SetTooltip and, failing
-- that, stops drawing tooltips (tipBroken). Calls are unverified in the engine like the rest of this panel.
local tipBroken = false
local function tip(text)
  if tipBroken or not text or text == "" then return end
  local ok, err = pcall(function()
    if not im.IsItemHovered() then return end
    if im.BeginTooltip and im.EndTooltip and im.PushTextWrapPos and im.PopTextWrapPos and im.TextUnformatted and im.GetFontSize then
      im.BeginTooltip()
      im.PushTextWrapPos(im.GetFontSize() * 28)
      im.TextUnformatted(text)
      im.PopTextWrapPos()
      im.EndTooltip()
    else
      im.SetTooltip(text)
    end
  end)
  if not ok then
    tipBroken = true
    log("W", "nfsc_sectionManagerUi", "tooltips turned off: " .. tostring(err))
  end
end

-- Creation method: three radios.
local CREATION_MODES = {
  { "current", "Current", "Every object is created when its section loads and deleted when it unloads. Lowest memory, highest cost per object (about 0.5-2.5 ms to create)." },
  { "shells", "Shells", "Deleted objects are parked as hidden shells and refilled for the next load (about 0.005-0.04 ms of engine work, about 1.2 ms measured in game). Needs the shell shape; shells wait in a pool." },
  { "resident", "Resident", "Shells plus a resting state: an unwanted object is only hidden and keeps its shape and fields, so wanting it again is just an unhide. The oldest is evicted only when the pool is full. Fastest return to a section, most memory." },
}
local MODE_LABEL = { current = "Current", shells = "Shells", resident = "Resident" }

local function drawCreationMode(st)
  im.Text("Creation:")
  for _, m in ipairs(CREATION_MODES) do
    im.SameLine()
    if radio(m[2] .. "##creation", (st.creationMode or "current") == m[1]) then nfsc_sectionStreamer.setCreationMode(m[1]) end
    tip(m[3])
  end
end

local tuningPtrs = {}
local tuningBroken = false
local typingPtr = nil
local defaultsCache = nil

local function fmtNum(v)
  if type(v) == "number" then return string.format("%.4g", v) end
  return tostring(v)
end

-- Does the setting do anything right now? Only settings of the active creation mode (and whose parent switch is on) show.
local function appliesNow(row, mode, tuning)
  if row.modes and not row.modes[mode] then return false end
  if row.requires and not tuning[row.requires] then return false end
  return true
end

-- One setting. Sliders follow the value (their range grows when a typed value is beyond it); a share is edited in
-- ms of the main frame budget and stored as a share of it, so it follows the main budget when that changes.
local function drawTuningRow(tuning, defaults, row, typing)
  local key, kind = row.key, row.kind
  local value = tuning[key]
  if value == nil then return end
  local main = tuning.frameBudgetMs or 16
  local isDefault = defaults[key] == nil or value == defaults[key]
  local label = (isDefault and "" or "* ") .. row.label .. "###t" .. key      -- ### keeps the widget id when the star comes and goes
  local ptr = tuningPtrs[key]
  local extra
  if kind == "bool" then
    if not ptr then ptr = im.BoolPtr(value); tuningPtrs[key] = ptr end
    ptr[0] = value
    if im.Checkbox(label, ptr) then nfsc_sectionStreamer.setTuning({ [key] = ptr[0] }, true) end
    extra = "Default: " .. tostring(defaults[key])
  elseif kind == "int" then
    if not ptr then ptr = im.IntPtr(value); tuningPtrs[key] = ptr end
    ptr[0] = value
    local hit
    if typing then hit = im.InputInt(label, ptr) else hit = im.SliderInt(label, ptr, row.min, math.max(row.max, value)) end
    if hit then nfsc_sectionStreamer.setTuning({ [key] = ptr[0] }, true) end
    extra = "Default: " .. fmtNum(defaults[key])
  elseif kind == "share" then
    if not ptr then ptr = im.FloatPtr(value * main); tuningPtrs[key] = ptr end
    ptr[0] = value * main
    local hit
    if typing then
      hit = im.InputFloat(label, ptr, 0, 0, "%.3f")
    else
      hit = im.SliderFloat(label, ptr, 0, math.max(main, ptr[0]), string.format("%%.2f ms  (%.0f%%%% of the frame budget)", value * 100))
    end
    if hit and main > 0 then nfsc_sectionStreamer.setTuning({ [key] = ptr[0] / main }, true) end
    extra = string.format("Stored as a share of the frame budget, so it follows the frame budget when that changes. Default: %.0f%% (%.2f ms now).",
      (defaults[key] or 0) * 100, (defaults[key] or 0) * main)
  else
    if not ptr then ptr = im.FloatPtr(value); tuningPtrs[key] = ptr end
    ptr[0] = value
    local hit
    if typing then hit = im.InputFloat(label, ptr, 0, 0, "%.3f") else hit = im.SliderFloat(label, ptr, row.min, math.max(row.max, value), "%.2f") end
    if hit then nfsc_sectionStreamer.setTuning({ [key] = ptr[0] }, true) end
    extra = "Default: " .. fmtNum(defaults[key])
  end
  tip(row.desc .. "\n" .. extra)
end

-- What changed last and when, so a change can be checked instead of assumed.
local function drawChangeInfo()
  local info = nfsc_sectionStreamer.getTuningInfo()
  local last = info.last
  if not last then
    im.TextDisabled("Tuning revision 0: nothing changed yet")
    return
  end
  local n, age = #last.changed, math.max(0, info.now - last.time)
  local what
  if n == 1 then
    local c = last.changed[1]
    what = string.format("%s %s -> %s", c.key, fmtNum(c.old), fmtNum(c.new))
  elseif n > 1 then
    local c = last.changed[1]
    what = string.format("%d values (%s %s -> %s, ...)", n, c.key, fmtNum(c.old), fmtNum(c.new))
  else
    what = "no value changed"
  end
  im.Text(string.format("Tuning revision %d. Last: %s [%s, %.0f s ago]", info.revision, what, tostring(last.source), age))
  if #last.rejected > 0 then
    local r = last.rejected[1]
    im.TextDisabled(string.format("Not applied: %d (%s: %s)", #last.rejected, r.key, r.why))
  end
end

local function drawBudgetUse(st)
  local b = st.frameBudget
  if not b then return end
  im.TextDisabled(string.format("Streaming per frame (avg): reads %.2f, deletes %.2f, creates %.2f, shells %.2f, cache warm %.2f ms   budget %.1f ms",
    b.avgMs.reads, b.avgMs.deletes, b.avgMs.creates, b.avgMs.shells, b.avgMs.warm, b.mainMs))
  tip("Time each streaming task used per frame, averaged over about 10 frames. Reads, deletes, creates and shell building share the frame budget: each is capped by what the frame has left, so together they stay within it. One indivisible engine call (a first-use import) can still overrun it.")
end

local function drawPresets(mode)
  if im.TreeNode1("Presets for " .. (MODE_LABEL[mode] or mode) .. " mode##tp") then
    for _, p in ipairs(nfsc_sectionStreamer.getModePresets(mode)) do
      im.Text(string.format("%s  %s", p.slot, p.label))
      im.SameLine()
      im.TextDisabled(p.source == "saved" and "(saved)" or "(factory)")
      im.SameLine()
      if im.Button("Load##p" .. p.slot) then nfsc_sectionStreamer.loadModePreset(mode, p.slot) end
      tip("Apply this preset's values. Only the settings the preset holds change.")
      im.SameLine()
      if im.Button("Save##p" .. p.slot) then nfsc_sectionStreamer.saveModePreset(mode, p.slot) end
      tip("Store all current tuning values in this slot of this mode (each mode has its own three slots).")
      if p.source == "saved" then
        im.SameLine()
        if im.Button("Factory##p" .. p.slot) then nfsc_sectionStreamer.deleteModePreset(mode, p.slot) end
        tip("Throw away the saved values; the slot holds its factory starting values again.")
      end
    end
    im.Text("startup")
    im.SameLine()
    if im.Button("Load##pstartup") then nfsc_sectionStreamer.loadPreset("startup") end
    im.SameLine()
    if im.Button("Save##pstartup") then nfsc_sectionStreamer.savePreset("startup") end
    tip("Saved values (including the creation mode) are applied when the streamer starts.")
    im.SameLine()
    if im.Button("Delete##pstartup") then nfsc_sectionStreamer.deletePreset("startup") end
    im.TextDisabled("Factory values are untested starting points: budget and pool settings only.")
    im.TreePop()
  end
end

local function groupHeader(label)
  local ex, flag = im.TreeNodeEx1, im.TreeNodeFlags_DefaultOpen
  if ex and flag then return ex(label, flag) end
  return im.TreeNode1(label)
end

-- Built from the streamer's schema: only the settings that do something in the active creation mode are shown.
local function drawTuning(st)
  if tuningBroken then return end
  local ok, err = pcall(function()
    if not im.CollapsingHeader1("Tuning (live)") then return end
    local streamer = nfsc_sectionStreamer
    local tuning = streamer.getTuning()
    defaultsCache = defaultsCache or streamer.getDefaultTuning()
    local mode = tuning.creationMode or "current"
    drawChangeInfo()
    drawBudgetUse(st)
    if tuning.testingMode and st.diagnostics then
      local d = st.diagnostics
      im.TextDisabled(string.format("STALL diagnostics: %d frames, avg %.1f ms, worst %.1f ms, spikes %d, budget overruns %d, clock %s",
        d.frames or 0, d.avgFrameMs or 0, d.worstFrameMs or 0, d.spikeCount or 0, d.overrunFrames or 0, tostring(d.clockSource)))
      if im.Button("Print run + section stall report") then streamer.logDiagnosticSummary(); streamer.logDiagnosticSummary(st.currentSectionID) end
      tip("Print the current section's bounded stage summary and slowest operations to the game log. Use Reset statistics before each repeatable camera-track run.")
    end
    if not typingPtr then typingPtr = im.BoolPtr(false) end
    im.Checkbox("Type values (input boxes instead of sliders)##ttyping", typingPtr)
    tip("Input boxes take any number. With sliders, Ctrl+click a slider to type one: values beyond the slider range are accepted and the range grows to fit. Hard limits (for example a share cannot exceed the whole frame budget) are enforced by the streamer.")
    local groups, byGroup, hidden = {}, {}, {}
    for _, row in ipairs(streamer.getTuningSchema()) do
      if appliesNow(row, mode, tuning) then
        if not byGroup[row.group] then byGroup[row.group] = {}; groups[#groups + 1] = row.group end
        local list = byGroup[row.group]
        list[#list + 1] = row
      else
        hidden[#hidden + 1] = row.label
      end
    end
    for _, name in ipairs(groups) do
      if groupHeader(name .. "##tg") then
        for _, row in ipairs(byGroup[name]) do drawTuningRow(tuning, defaultsCache, row, typingPtr[0]) end
        im.TreePop()
      end
    end
    if #hidden > 0 then
      im.TextDisabled(string.format("%d settings are hidden: not used in %s mode, or their switch is off", #hidden, MODE_LABEL[mode] or mode))
      tip(table.concat(hidden, ", "))
    end
    drawPresets(mode)
    if im.Button("Reset to defaults") then streamer.resetTuning() end
    tip("Every tuning value back to its default, including the creation mode.")
    im.SameLine()
    if im.Button("Print values to log") then streamer.printTuning() end
    tip("Write the current values to the log as a Lua table, to paste into TUNING.")
  end)
  if not ok then
    tuningBroken = true
    log("E", "nfsc_sectionManagerUi", "tuning section turned off: " .. tostring(err))
  end
end

-- Purge: an empty scene for repeatable measurements (camera track, console log).
local purgePool, purgeHold = nil, nil
local function drawPurge(st)
  if not purgePool then purgePool, purgeHold = im.BoolPtr(false), im.BoolPtr(false) end
  if im.Button("Purge scene") then nfsc_sectionStreamer.purge({ releasePool = purgePool[0], hold = purgeHold[0] }) end
  tip("Cancels every queued job, removes all live objects and clears the section selection, then verifies the bookkeeping and the scene. Statistics are reset. Without 'hold', streaming starts again at once from the camera's position, like after a level load.")
  im.SameLine()
  im.Checkbox("Release pool##purgepool", purgePool)
  tip("Also delete the parked shells and the deactivated (resident) objects, so memory and the pool start empty too. Leave off to measure with a warm pool.")
  im.SameLine()
  im.Checkbox("Hold##purgehold", purgeHold)
  tip("Keep streaming suspended after the purge. Move the camera to the start of the track, then press Resume streaming.")
  im.SameLine()
  if im.Button("Reset statistics") then nfsc_sectionStreamer.resetStats() end
  tip("Zero the counters and timings without touching tuning, pool or live objects.")
  im.SameLine()
  if im.Button("Log run summary") then nfsc_sectionStreamer.logRunSummary() end
  tip("Write one block to the log for everything since the last Reset statistics or Purge: how objects came back (revive, same-shape reuse, refill, fresh), how busy and how idle the streamer was, time to idle per section, dropped sections.")
  local p = st.lastPurge
  if p then
    im.TextDisabled(string.format("Last purge (%s): cancelled %d queued, %d pending, %d held back; removed %d live%s; pool %d deactivated + %d free; scene %s; %.0f ms%s",
      p.mode, p.cancelled.queued, p.cancelled.pending, p.cancelled.deferred, p.removedLive,
      (p.released.dormant + p.released.shells) > 0 and string.format(" + released %d", p.released.dormant + p.released.shells) or "",
      p.poolAfter.dormant, p.poolAfter.shellsFree, p.sceneObjects and tostring(p.sceneObjects) or "n/a", p.ms, p.held and "; held" or ""))
    if p.ok then
      im.TextDisabled("Verified clear")
    else
      im.Text("Check failed: " .. table.concat(p.problems, "; "))
    end
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

-- Mesh warm-up readout: which lane is on, what it is doing right now, how far it got, how long it will take.
local function duration(sec)
  if not sec then return "unknown" end
  sec = math.floor(sec + 0.5)
  if sec >= 3600 then return string.format("%d h %02d min", math.floor(sec / 3600), math.floor((sec % 3600) / 60)) end
  if sec >= 60 then return string.format("%d min %02d s", math.floor(sec / 60), sec % 60) end
  return string.format("%d s", sec)
end

local function textBar(done, total)
  local frac = total > 0 and math.max(0, math.min(1, done / total)) or 0
  local n = math.floor(frac * 30 + 0.5)
  return string.format("[%s%s] %.1f%%", string.rep("#", n), string.rep("-", 30 - n), frac * 100)
end

local function drawSlowList(label, list)
  if not list or #list == 0 then return end
  if im.TreeNode1(label) then
    for i, e in ipairs(list) do
      im.Text(string.format("%2d. %s    %.0f ms    %s", i, (e.name:match("([^/\\]+)$") or e.name), e.ms, e.kind))
    end
    im.TreePop()
  end
end

local function drawMeshWarm(st)
  local wa, cw, si = st.warmAll, st.cacheWarm, st.shapeIndex
  if si and si.state == "scanning" and ((wa and wa.enabled) or (cw and cw.enabled)) then
    im.Text("Mesh warm-up: indexing shape names from the section files (no shapes.json)")
    im.Text(textBar(si.files, si.total) .. string.format("   %d of %d section files, %d unique shapes so far%s", si.files, si.total, si.unique,
      si.failed > 0 and string.format(", %d unreadable", si.failed) or ""))
    im.Text(string.format("Reading for %s (waiting not counted)    ETA: %s", duration(si.seconds), duration(si.etaSeconds)))
    im.TextDisabled("The index is read while nothing is queued, one section file per frame. The warm-up starts when it is done.")
    return
  end
  if si and si.state == "done" then
    im.TextDisabled(string.format("Shape index: %d unique shapes from %d section files (read in %s)", si.unique, si.files, duration(si.readSeconds)))
  end
  if wa and (wa.enabled or wa.held > 0) then
    local k = wa.kind
    im.Text("Mesh warm-up (Everything is warm): " .. tostring(wa.phase))
    local done = wa.held + wa.failed
    im.Text(textBar(done, wa.total) .. string.format("   %d of %d meshes held%s", wa.held, wa.total,
      wa.failed > 0 and string.format(", %d failed", wa.failed) or ""))
    tip("Every mesh used by the streamed sections is held by one hidden object each, so no mesh is loaded while streaming. The lane only works while nothing is queued, so 'waiting' phases are normal during streaming.")
    im.Text(string.format("Already had a .cdae: %d (avg %.2f ms)    Imported now: %d (avg %.1f ms, %s in total)    Unknown: %d",
      k.cached.n, k.cached.n > 0 and k.cached.ms / k.cached.n or 0, k.import.n, k.import.n > 0 and k.import.ms / k.import.n or 0,
      duration(k.import.ms / 1000), k.unknown.n))
    im.Text(string.format("Holding for %s (waiting not counted)    ETA while holding: %s    slowest so far: %.0f ms",
      duration(wa.runSeconds), wa.complete and "done" or duration(wa.etaSeconds), wa.maxMs or 0))
    if wa.complete then
      im.Text("Object-cost measurements: VALID, every mesh is held")
    elseif wa.releasing then
      im.Text("Releasing the held meshes")
    else
      im.Text(string.format("Object-cost measurements: NOT valid yet, %d meshes still to load", math.max(0, wa.remaining or 0)))
    end
    drawSlowList("Slowest mesh holds##warmallslow", wa.slow)
  elseif cw and (cw.enabled or cw.finished) then
    im.Text("Mesh warm-up (cache lane): " .. tostring(cw.phase))
    if cw.available then
      im.Text(textBar(cw.processed, cw.total) .. string.format("   %d of %d shapes checked%s", cw.processed, cw.total,
        cw.failed > 0 and string.format(", %d failed", cw.failed) or ""))
      im.Text(string.format("Already had a .cdae: %d    Imported now: %d (avg %.1f ms, max %.0f ms, %s in total)    Skipped: %d",
        cw.alreadyCached, cw.imported, cw.importAvgMs, cw.importMaxMs, duration(cw.importSeconds), cw.skipped))
      im.Text(string.format("Running for %s (waiting not counted)    ETA: %s (rough: cached shapes are skipped fast, imports are slow)",
        duration(cw.runSeconds), cw.finished and "done" or duration(cw.etaSeconds)))
      im.TextDisabled("This lane only builds .cdae files, nothing stays loaded: a first use afterwards is a cache read, not an import. Turn on Everything is warm to hold the meshes.")
      drawSlowList("Slowest imports##cachewarmslow", cw.slow)
    else
      im.TextDisabled("Unavailable: no shape names or no FS:fileExists in this build (see the log)")
    end
  else
    im.TextDisabled("Mesh warm-up: off (Cache warm-up lane and Everything is warm are both off)")
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
  drawMeshWarm(st)
  local run = st.run
  if run and st.residentActive then
    local p = run.paths
    im.Text(string.format("Run: revive %d, same-shape %d, refill %d (avg %.3f ms), fresh %d    asleep %.0f%% (idle frame %.3f ms)    caps hit: cheap %d, refill %d",
      p["resident-revive"].n, p["resident-same-shape-reuse"].n, p["shell-refill"].n, p["shell-refill"].avgMs,
      p["pool-empty-fresh-object"].n, run.sleepShare * 100, run.idleAvgMs, run.cheapCapHits, run.costlyCapHits))
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
  drawPurge(st)
  im.Separator()
  drawTuning(st)
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
