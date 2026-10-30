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
  im.TextDisabled(string.format("Streaming per frame (avg): reads %.2f, deletes %.2f, creates %.2f, shells %.2f, holds %.2f ms",
    b.avgMs.reads, b.avgMs.deletes, b.avgMs.creates, b.avgMs.shells, b.avgMs.warm))
  im.TextDisabled(string.format("Streaming per frame: budget %.1f ms", b.mainMs))
  tip("Time each streaming task used per frame, averaged over about 10 frames. Reads, deletes, creates, shell building and holds share the frame budget: each is capped by what the frame has left, so together they stay within it. One indivisible engine call (a first-use import) can still overrun it.")
end

local function drawPresets(mode)
  if im.TreeNode1("Presets for " .. (MODE_LABEL[mode] or mode) .. " mode##tp") then
    for _, p in ipairs(nfsc_sectionStreamer.getModePresets(mode)) do
      im.Text("Preset " .. p.slot)
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
    im.TextDisabled("Factory values are untested starting points: frame budget and fill pace only.")
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

-- Search bar of the override lists: part of a name, case ignored; filters both lists.
local ovSearch, ovBroken = nil, false
local okFfi, ffi = pcall(require, "ffi")                 -- LuaJIT in the game; the search bar turns itself off without it
if not okFfi then ffi = nil end

local function drawOverrideSearch()
  if ovBroken then return "" end
  local ok, text = pcall(function()
    if not ovSearch then ovSearch = im.ArrayChar(128) end
    im.InputText("##ovsearch", ovSearch, 128)
    tip("Type part of an override name to list only the matching overrides, in both the enabled and the hidden list. Case is ignored. Clear shows all again.")
    local typed = ffi.string(ovSearch)
    im.SameLine()
    if im.Button("Clear##ovsearch") then ffi.copy(ovSearch, ""); typed = "" end
    return typed
  end)
  if not ok then
    ovBroken = true
    log("W", "nfsc_sectionManagerUi", "override search turned off: " .. tostring(text))
    return ""
  end
  return text
end

local function drawOverrideList(label, names)
  if im.TreeNode1(label .. " (" .. #names .. ")###" .. label) then
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

-- A progress bar: the imgui one when it exists, else the text bar.
local barBroken = false
local function progressBar(done, total, text, width)
  if not barBroken and im.ProgressBar then
    local ok = pcall(function()
      im.ProgressBar(total > 0 and math.max(0, math.min(1, done / total)) or 0, im.ImVec2(width or -1, 0), text)
    end)
    if ok then return end
    barBroken = true
  end
  im.Text(textBar(done, total) .. "   " .. text)
end

local function gb(v) return v and string.format("%.1f", v) or "n/a" end

-- Shape cache: the headline data, always visible, right under the status lines.
local function drawShapeCache(st)
  local sc, si = st.shapeCache, st.shapeIndex
  if not sc then return end
  if not groupHeader("Shape cache##scache") then return end
  if not sc.enabled and sc.held == 0 then
    im.TextDisabled("Off: meshes load while streaming. Turn it on under Tuning > Shape cache.")
    im.TreePop()
    return
  end
  if si and si.state == "scanning" then
    im.Text("Indexing shape names from the section files (no shapes.json)")
    progressBar(si.files, si.total, string.format("%d of %d section files, %d unique shapes so far", si.files, si.total, si.unique))
    im.TextDisabled(string.format("Reading for %s    ETA: %s. The fill starts when the index is done.", duration(si.seconds), duration(si.etaSeconds)))
    im.TreePop()
    return
  end
  im.Text("Fill: " .. tostring(sc.phase))
  tip("What the fill is doing. It only holds shapes while nothing is queued, so waiting phases are normal during streaming. A shape a create needs is held at once, whatever this says.")
  progressBar(sc.island.held, math.max(sc.island.meshes, 1), string.format("%d / %d meshes of the island held (%d held in all)", sc.island.held, sc.island.meshes, sc.held))
  tip("Meshes of the section island the camera is in (the sections connected through their relations), each kept loaded by a hidden object: creates then only revive, retarget and unhide.")
  im.Text("Lane: " .. string.upper(sc.lane or "asleep") .. (sc.laneReason and (" (" .. sc.laneReason .. ")") or "")
    .. (sc.current and string.format("    last: %s, %.1f ms    holds: %d (avg %.2f ms)", sc.current:match("([^/\\]+)$") or sc.current, sc.lastHoldMs, sc.held, sc.avgMs) or ""))
  tip("asleep: complete, off or nothing to do. filling: holding shapes. paused: waiting, the reason is in brackets (busy: sections are streaming, heavy: heavy shapes wait for a still camera, ram: free RAM is under the floor, user: Pause fill). Colour is not needed to read it.")
  local v = sc.visit
  if v then
    im.Text(string.format("Visit: section %s    neighbours ready %d/%d    cold arrivals: %d    teleport: %s", tostring(v.id), v.ready, v.neighbours, v.cold, v.teleport and "yes" or "no"))
  else
    im.Text("Visit: none")
  end
  tip("The section the camera is in. Neighbours are its related sections: ready means every shape of the section is held. A cold arrival is an object whose shape was not held when the section asked for it. A teleport (a section not related to the one before) is not counted in the late and dropped numbers.")
  im.Text(string.format("Last hitch: %s    pauses: busy %d, heavy-wait %d, RAM floor %d",
    sc.lastHitch and string.format("%s, %.1f ms", sc.lastHitch.name:match("([^/\\]+)$") or sc.lastHitch.name, sc.lastHitch.ms) or "none",
    sc.pauses.busy, sc.pauses.heavy, sc.pauses.ram))
  tip("The latest create or hold slower than the heavy shape threshold.")
  local m = sc.memory or {}
  if sc.ramSource then
    im.Text(string.format("Memory (GB): free %s  available %s  process %s  Lua %.1f    min free %s", gb(m.freeGB), gb(m.availableGB), gb(m.processGB), m.luaGB or 0, gb(sc.minFreeGB)))
    im.Text(string.format("RAM floor: %s (%.2f)", sc.ramPaused and "PAUSED, free RAM is under it" or "clear", sc.ramFloor))
  else
    im.Text(string.format("Memory (GB): Lua %.1f (peak %.1f)    no free-RAM source: the RAM floor is not checked", m.luaGB or 0, sc.luaPeakGB or 0))
  end
  tip("Free, available and process RAM need a source: nfsc_sectionStreamer.setMemoryProvider(fn), fn returns { freeGB, availableGB, processGB }. Lua is the Lua heap.")
  im.Text(string.format("Placeholders ready: %d / %d    absent (no file): %d    failed: %d    heavy waiting: %d", sc.placeholders, sc.placeholderWindow, sc.absent, sc.failed, sc.deferredHeavy))
  if im.Button(sc.paused and "Resume fill##scfill" or "Pause fill##scfill") then nfsc_sectionStreamer.pauseShapeCache(not sc.paused) end
  tip("Stop the fill without losing what it holds. Shapes a create needs are still held.")
  im.SameLine()
  if im.Button("Restart fill##scfill") then nfsc_sectionStreamer.restartShapeCache() end
  tip("Forget which shapes failed or were postponed and walk the index again. Held shapes stay held.")
  im.TreePop()
end

local function pctText(v) return v and string.format("%.0f%%", v * 100) or "n/a" end

-- Run results of the shape cache and its slowest shapes (below the pool lines).
local function drawShapeCacheResults(st)
  local sc = st.shapeCache
  if not sc or not (sc.enabled or sc.held > 0) then return end
  if im.TreeNode1("Run results (shape cache)##scres") then
    local c = sc.creates
    local function cls(x) return string.format("%d | avg %.1f | max %.1f ms", x.n, x.n > 0 and x.ms / x.n or 0, x.max) end
    im.Text("Creates held-hit:  " .. cls(c.held))
    im.Text("Creates live-hit:  " .. cls(c.live))
    im.Text("Creates cold:      " .. cls(c.cold))
    tip("held-hit: the shape was held. live-hit: an instance kept it loaded. cold: it had to be loaded; the ms include the hold the create waited for.")
    im.Text(string.format("Cost shifted: stall %.1f s busy | holds %.1f s idle", sc.stallMs / 1000, sc.idleMs / 1000))
    im.Text(string.format("Readiness at entry: avg %s | p10 %s | min %s", pctText(sc.readinessAvg), pctText(sc.readinessP10), pctText(sc.readinessMin)))
    tip("Per visit: the share of the entered section's shapes that were already held when the camera arrived.")
    im.Text(string.format("Fully ready after entry: avg %s | worst %.1f s", sc.fullAvgSeconds and string.format("%.1f s", sc.fullAvgSeconds) or "n/a", sc.fullMaxSeconds or 0))
    im.Text(string.format("Visits ready / late / dropped: %d / %d / %d    teleport visits: %d (cold start %s)", sc.visitsReady, sc.visitsLate, sc.visitsDropped,
      sc.visitsTeleport, sc.coldStartAvgSeconds and string.format("%.1f s", sc.coldStartAvgSeconds) or "n/a"))
    im.Text(string.format("Fills by channel: idle %d | need %d    cold before the fill finished: %d", sc.idleN, sc.needN, sc.coldBeforeFill))
    im.Text(string.format("Retargets: already held %d | needed a fill %d    animations restarted: %d", sc.retargetHeld, sc.retargetFilled, sc.ambientRestarts or 0))
    im.Text(string.format("Idle frame, holders: off %s | on %s", sc.idleFrameOffMs and string.format("%.1f", sc.idleFrameOffMs) or "n/a",
      sc.idleFrameOnMs and string.format("%.1f ms", sc.idleFrameOnMs) or "n/a"))
    im.TreePop()
  end
  if sc.slow and #sc.slow > 0 and im.TreeNode1("Slowest shapes (top 10)##scslow") then
    for i, e in ipairs(sc.slow) do
      im.Text(string.format("%2d. %s    %.0f ms    %s", i, (e.name:match("([^/\\]+)$") or e.name), e.ms, e.kind))
    end
    im.TreePop()
  end
end

-- The preload controls: what a user needs. Island progress, Preload on/off, Preload always, Max meshes to save.
local maxMeshesPtr, debugLogPtr = nil, nil
local function drawPreload(st)
  local sc = st.shapeCache
  if not sc then return end
  local streamer = nfsc_sectionStreamer
  im.Text("Preload:")
  im.SameLine()
  if radio("On##preload", sc.enabled) then streamer.setTuning({ shapeCache = true }, true) end
  tip("Hold the meshes of the section island you are in, so streaming only revives and unhides objects instead of loading meshes. Runs when the car and camera are still.")
  im.SameLine()
  if radio("Off##preload", not sc.enabled) then streamer.setTuning({ shapeCache = false }, true) end
  tip("Release the held meshes: meshes load while streaming, with hitches.")
  if not sc.enabled then return end
  local si = st.shapeIndex
  if si and si.state == "scanning" then
    progressBar(si.files, si.total, string.format("reading %d / %d section files", si.files, si.total), -150)
  else
    progressBar(sc.island.held, math.max(sc.island.meshes, 1), string.format("%d / %d meshes cached", sc.island.held, sc.island.meshes), -150)
  end
  tip("Meshes of the island you are in that are already held. The island is the set of sections connected to the current one through their relations; other islands (far districts, canyons) are not loaded.")
  im.SameLine()
  if im.Button((sc.always and "Preload when idle" or "Preload always") .. "##preloadalways") then streamer.setTuning({ shapeCacheAlways = not sc.always }, true) end
  tip(sc.always and "Back to filling only while the car and camera are still." or "Also fill while the car moves. Heavy meshes still wait for a still camera. Use it for the first minutes in a new area, then switch back.")
  im.TextDisabled(tostring(sc.phase))
  if not maxMeshesPtr then maxMeshesPtr = im.IntPtr(sc.max) end
  maxMeshesPtr[0] = sc.max
  if im.SliderInt("Max meshes to save###maxmeshes", maxMeshesPtr, 0, math.max(sc.total, 1)) then streamer.setTuning({ shapeCacheMax = maxMeshesPtr[0] }, true) end
  tip("Most meshes kept held (RAM). The fill stops there, and when you move to another island the holders of the old one are evicted first. All the way right: everything the island needs.")
end

-- The statistics a player can use: what is cached, how many shells exist and how many are in use.
local statsOpen = nil
local function drawStatsWindow(st)
  if not statsOpen then statsOpen = im.BoolPtr(false) end
  if not statsOpen[0] then return end
  im.Begin("Section Manager stats", statsOpen)
  local sc = st.shapeCache
  if sc and sc.enabled then
    progressBar(sc.island.held, math.max(sc.island.meshes, 1), string.format("%d / %d meshes cached", sc.island.held, sc.island.meshes))
    im.Text(string.format("Meshes held in all: %d    Max meshes to save: %d", sc.held, sc.max))
    tip("Held in all counts the meshes of islands you left too, until the cap evicts them.")
  else
    im.TextDisabled("Preload is off: no meshes are cached.")
  end
  im.Text(string.format("Shells created: %d", st.poolTotal or 0))
  tip("Every object the streamer ever made for streaming. They are reused for the rest of the session.")
  im.Text(string.format("Active shells: %d in use    %d resting    %d free    cap %d    peak in use %d",
    st.liveObjectCount or 0, st.residentDormant or 0, st.shellsFree or 0, st.residentMax or 0, st.shellPeakLive or 0))
  tip("In use: showing a streamed object now. Resting: hidden, waiting to be shown again without a load. Free: ready for any shape. The cap is fixed.")
  im.Text(string.format("Dropped sections: %d", st.droppedSections or 0))
  tip("Counted when the camera enters a new section before the previous section change finished loading.")
  if sc and sc.enabled then
    im.Text(string.format("Late neighbours: %d    dropped neighbours: %d", sc.neighboursLate, sc.neighboursDropped))
    tip("Per visit to a drivable section, each neighbour in its related list that was not ready at entry is checked at exit. Ready before the camera left: late. Still not ready: dropped. Arriving at a section that is not in the previous section's related list is a teleport and is not counted.")
  end
  im.End()
end

function M.onUpdate()
  if not nfsc_sectionStreamer or not nfsc_sectionManager then return end
  im.Begin("Section Manager", windowOpen)

  local st = nfsc_sectionManager.getStatus()
  im.Text("Current section: " .. tostring(st.currentSectionName or "none"))
  tip("The section the camera is in. Objects load when an active section wants them: the current section and the one the camera is heading into. Objects no active section wants any more are deactivated, and only evicted when the pool is full.")
  drawPreload(st)
  if im.Button(nfsc_sectionStreamer.isSuspended() and "Resume streaming" or "Suspend streaming") then
    nfsc_sectionStreamer.setSuspended(not nfsc_sectionStreamer.isSuspended())
  end
  im.SameLine()
  if im.Button("Reload streamed scenery") then nfsc_sectionStreamer.reset() end
  if not statsOpen then statsOpen = im.BoolPtr(false) end
  im.SameLine()
  im.Checkbox("Stats window##statswin", statsOpen)
  tip("Open the statistics in their own window: meshes cached, shells created, active shells, dropped sections.")
  drawPresets(st.creationMode or "resident")

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
  im.Separator()

  local on, off = {}, {}
  for _, name in ipairs(nfsc_sectionManager.getOverrideNames()) do
    if nfsc_sectionManager.isOverrideEnabled(name) then on[#on + 1] = name else off[#off + 1] = name end
  end
  local total = #on + #off
  local typed = drawOverrideSearch()
  local needle = typed:lower()
  if needle ~= "" then
    local function keep(list)
      local out = {}
      for _, name in ipairs(list) do if name:lower():find(needle, 1, true) then out[#out + 1] = name end end
      return out
    end
    on, off = keep(on), keep(off)
  end
  if not ovBroken then
    im.SameLine()
    im.TextDisabled(needle == "" and string.format("Search overrides    %d overrides", total) or string.format("showing %d of %d", #on + #off, total))
  end
  drawOverrideList("Enabled overrides", on)
  drawOverrideList("Hidden overrides", off)
  im.Separator()

  -- Everything else, for debugging only.
  if im.CollapsingHeader1("Debug") then
    if not debugLogPtr then debugLogPtr = im.BoolPtr(false) end
    debugLogPtr[0] = nfsc_sectionStreamer.getTuning().debugLog == true
    if im.Checkbox("Detailed logs##debuglog", debugLogPtr) then nfsc_sectionStreamer.setTuning({ debugLog = debugLogPtr[0] }, true) end
    tip("The cacher lines, the full run summary and the fill progress go to the log.")
    im.Text(string.format("Active sections: %d    Live objects: %d    Queued: %d objects, %d section reads    Pending unload: %d",
      st.activeSectionCount or 0, st.liveObjectCount or 0, st.queuedObjectCount or 0, st.queuedSectionReads or 0, st.pendingUnloadCount or 0))
    im.Text(string.format("Created: %d    Deleted: %d    Failures: %d", st.createdTotal or 0, st.deletedTotal or 0, st.failureCount or 0))
    drawCreationMode(st)
    drawShapeCache(st)
    if st.shellPoolActive then
      im.Text(string.format("Pool: %d (%d free, %d dormant, %d live), %d built ahead (target %d)",
        st.poolTotal or 0, st.shellsFree or 0, st.residentDormant or 0, st.liveObjectCount or 0, st.shellsBuilt or 0, st.shellTarget or 0))
      im.Text(string.format("Pool: recycled %d (avg %.3f ms)    fresh %d    parked %d    peak live %d",
        st.shellsRecycled or 0, st.shellRecycleAvgMs or 0, st.shellsFresh or 0, st.shellsParked or 0, st.shellPeakLive or 0))
    end
    if st.residentActive then
      im.Text(string.format("Resident: revived %d (avg %.3f ms), deactivated %d, evicted %d, cap %d, reserve %d",
        st.residentRevived or 0, st.residentReviveAvgMs or 0, st.residentDeactivated or 0, st.residentEvicted or 0,
        st.residentMax or 0, st.residentReserve or 0))
    end
    if st.shapeIndex and st.shapeIndex.state == "done" then
      im.TextDisabled(string.format("Shape index: %d unique shapes from %d section files (read in %s)", st.shapeIndex.unique, st.shapeIndex.files, duration(st.shapeIndex.readSeconds)))
    end
    drawShapeCacheResults(st)
    local run = st.run
    if run and st.residentActive then
      local p = run.paths
      im.Text(string.format("Run: revive %d, same-shape %d, refill %d (avg %.3f ms), fresh %d",
        p["resident-revive"].n, p["resident-same-shape-reuse"].n, p["shell-refill"].n, p["shell-refill"].avgMs, p["pool-empty-fresh-object"].n))
      im.Text(string.format("Run: asleep %.0f%% (idle frame %.3f ms)    caps hit: cheap %d, refill %d", run.sleepShare * 100, run.idleAvgMs, run.cheapCapHits, run.costlyCapHits))
    end
    im.Text(string.format("Dropped sections: %d (%d objects missing at exit)", st.droppedSections or 0, st.droppedObjects or 0))
    tip("Counted when the camera enters a new section before the previous section change finished loading. The objects still queued or waiting at that moment are the ones missing at exit.")
    local d = st.droppedLast
    if d then
      im.TextDisabled(string.format("last: %s after %.2f s, %d created, %d queued, %d waiting", tostring(d.section), d.after or 0,
        d.created or 0, d.queued or 0, d.waiting or 0))
    end
    im.Text(string.format("Scene: %d emitters, %d lights, %d shown    Managed streamed objects: %d    Unknown flags: %d",
      st.sceneEmitters or 0, st.sceneLights or 0, st.sceneShown or 0, st.managedObjectsLive or 0, st.unknownFlagCount or 0))
    drawPurge(st)
    im.Separator()
    drawTuning(st)
    if (st.failureCount or 0) > 0 and im.TreeNode1("Last failures") then
      for _, msg in ipairs(nfsc_sectionStreamer.getFailures()) do im.TextWrapped(msg) end
      im.TreePop()
    end
  end
  im.End()
  drawStatsWindow(st)
end

return M
