-- Level component "textureAnimation": image sequences (frame swap) for animated materials.
--
-- Run by nfsc_levelHost (components/ folder, loaded with loadfile). Moved out of the environment manager; the
-- frame swap is unchanged, the native sequence mode is new.
--
-- The materials populator writes material_animations.json next to the materials files: image sequences (a list
-- of frame textures) and the stages that show them. One shared clock (timeBase World) picks the frame, so a
-- material is rewritten once and every object that uses it shows the same frame. Only texture fields change:
-- baseColorMap, plus emissiveMap for stages that have one (screens). A scroll set natively on the same stage is
-- never touched. Writes are queued, at most animWritesPerFrame materials per frame, and nothing runs while the
-- mode needs no frame swap and the queue is empty.
--
-- Modes (setAnimationMode): "export" the materials as exported (default, nothing written; a sequence that
-- sequence_strips.py converted runs natively on the GPU), "off" every material on its exported frame, static,
-- "native" converted sequences run natively (strip texture + animFlags sequence, no Lua cost per frame) and the
-- rest use the frame swap, "frameswap" every sequence uses the frame swap. Native needs the strip and sequence
-- blocks that specconvert/sequence_strips.py writes in material_animations.json. Shutdown goes back to "export".
--
-- Interface (see levelHost.lua): init(ctx), onUpdate(dtReal, dtSim), getStatus(), serialize(), restore(data),
-- shutdown(). API for the panel: setAnimationMode, getAnimationMode, setAnimationEnabled, isAnimationEnabled,
-- setAnimationBudget, getAnimationBudget, rebuildAnimationIndex, probeAnimation, setDebugLog.
--
-- Flagged for in-engine verification (nothing here has run in BeamNG): Material setField with a texture path for
-- baseColorMap and emissiveMap plus reload()/flush(), whether a reload keeps a native scroll running, and
-- (native mode) Material setField on animFlags with the stage as the array index. Every engine call is wrapped
-- in pcall; a failure is counted and logged once, never thrown.

local M = {}

local TUNING = {
  levelRoot = "levels/nfsc",
  animFile = "material_animations.json",
  animWritesPerFrame = 8,                  -- animated materials rewritten per frame
  debugLog = false,
}

local A = {                                -- texture animation (image sequences)
  state = "pending",                       -- pending | ready | missing | failed
  info = {},
  mode = "export",                         -- export | off | native | frameswap
  animList = {},                           -- { key, name, fps, count, frames, strip, mats, has, want }
  anims = {},                              -- key -> the same records
  mats = {}, matList = {},                 -- name -> { name, targets = { { anim, stage, base, shown, emissive, seq, native } }, queued }
  queue = {}, qHead = 1, qTail = 0,
  clock = 0,
  stats = { writes = 0, writeMs = 0, maxMs = 0, missing = 0, errors = 0 },
}

local function logMsg(level, fmt, ...)
  if level == "D" and not TUNING.debugLog then return end
  if log then log(level, "nfsc_textureAnimation", string.format(fmt, ...)) end
end

local loggedFailure = {}
local function failOnce(key, fmt, ...)
  if loggedFailure[key] then return end
  loggedFailure[key] = true
  logMsg("E", fmt, ...)
end

local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end

-- Refreshes the engine material after a field write. reload first, flush as the fallback.
local function refreshMaterial(obj)
  if pcall(obj.reload, obj) then return true end
  return pcall(obj.flush, obj)
end

-- ---------------------------------------------------------------------------
-- Texture animation: image sequences
-- ---------------------------------------------------------------------------
local function parseFrames(list)
  local frames = {}
  for i = 1, #list do
    local f = list[i]
    local isTable = type(f) == "table"
    frames[i] = {
      path = (isTable and type(f.path) == "string" and f.path ~= "") and f.path or nil,
      emissive = (isTable and type(f.emissive) == "string" and f.emissive ~= "") and f.emissive or nil,
    }
  end
  return frames
end

local function queueMaterial(rec)
  if rec.queued then return end
  rec.queued = true
  A.qTail = A.qTail + 1
  A.queue[A.qTail] = rec
end

-- What a stage should show in the current mode: (native, frame). native true = the strip with the sequence flags
-- (only for a stage with a seq block); otherwise the single frame texture of that number.
local function targetState(t)
  local m = A.mode
  if m == "export" then return t.seq ~= nil, t.base end
  if m == "native" and t.seq then return true, t.base end
  if (m == "native" or m == "frameswap") and t.anim.want then return false, t.anim.want end
  return false, t.base
end

local function targetDiffers(t)
  local native, want = targetState(t)
  return t.native ~= native or (not native and t.shown ~= want)
end

-- Is this stage shown through the Lua frame swap in the current mode (so the clock has to rewrite it)?
local function needsFrameSwap(t)
  return A.mode == "frameswap" or (A.mode == "native" and not t.seq)
end

local function queueDiffering()
  for i = 1, #A.matList do
    local rec = A.matList[i]
    for j = 1, #rec.targets do
      if targetDiffers(rec.targets[j]) then queueMaterial(rec); break end
    end
  end
end

local function loadAnimations()
  local started = os.clock()
  A.anims, A.animList, A.mats, A.matList = {}, {}, {}, {}
  A.queue, A.qHead, A.qTail = {}, 1, 0
  local files = {}
  if FS and FS.findFiles then
    local ok, found = pcall(FS.findFiles, FS, TUNING.levelRoot, TUNING.animFile, -1, true, false)
    if ok and type(found) == "table" then files = found end
  end
  table.sort(files)
  local info = { files = 0, animations = 0, materials = 0, targets = 0, skipped = 0, otherTimeBase = 0, native = 0 }
  for _, path in ipairs(files) do
    local data = jsonReadFile and jsonReadFile(path)
    if type(data) == "table" and type(data.animations) == "table" then
      info.files = info.files + 1
      for key, anim in pairs(data.animations) do
        local frames = (type(anim) == "table" and type(anim.frames) == "table") and parseFrames(anim.frames) or nil
        local fps = type(anim) == "table" and tonumber(anim.fps) or nil
        if frames and #frames >= 2 and fps and fps > 0 and not A.anims[key] then
          local strip = type(anim.strip) == "table" and type(anim.strip.path) == "string" and anim.strip.path ~= "" and {
            path = anim.strip.path,
            emissive = (type(anim.strip.emissive) == "string" and anim.strip.emissive ~= "") and anim.strip.emissive or nil,
          } or nil
          local rec = { key = key, name = anim.name or key, fps = fps, count = #frames, frames = frames, strip = strip, mats = {}, has = {} }
          A.anims[key] = rec
          A.animList[#A.animList + 1] = rec
          info.animations = info.animations + 1
          if anim.timeBase ~= nil and anim.timeBase ~= "World" then info.otherTimeBase = info.otherTimeBase + 1 end
        else
          info.skipped = info.skipped + 1
        end
      end
      local materials = type(data.materials) == "table" and data.materials or {}
      for name, entries in pairs(materials) do
        if type(name) == "string" and type(entries) == "table" then
          for _, e in ipairs(entries) do
            local anim = type(e) == "table" and e.type == "frame_swap" and A.anims[e.animation] or nil
            local stage, frame = type(e) == "table" and tonumber(e.stage) or nil, type(e) == "table" and tonumber(e.frame) or nil
            if anim and stage and frame then
              local rec = A.mats[name]
              if not rec then
                rec = { name = name, targets = {}, queued = false }
                A.mats[name] = rec
                A.matList[#A.matList + 1] = rec
                info.materials = info.materials + 1
              end
              local base = clamp(math.floor(frame), 0, anim.count - 1)
              local on = type(e.sequence) == "table" and anim.strip and tonumber(e.sequence.flagsOn) or nil
              local off = type(e.sequence) == "table" and tonumber(e.sequence.flagsOff) or nil
              local seq = (on and off) and { on = math.floor(on), off = math.floor(off) } or nil
              if seq then info.native = info.native + 1 end
              -- native = what the material shows right now: a converted stage was exported with the strip written on it
              rec.targets[#rec.targets + 1] = { anim = anim, stage = math.floor(stage), base = base, shown = base, emissive = e.emissive == true,
                                                seq = seq, native = seq ~= nil }
              if not anim.has[rec] then anim.has[rec] = true; anim.mats[#anim.mats + 1] = rec end
              info.targets = info.targets + 1
            end
          end
        end
      end
    end
  end
  table.sort(A.matList, function(a, b) return a.name < b.name end)
  info.ms = (os.clock() - started) * 1000
  A.info = info
  A.state = info.animations > 0 and "ready" or "missing"
  logMsg("I", "animation index: %d image sequence(s), %d material(s), %d stage(s) (%d with a native strip) from %d file(s), %.1f ms%s", info.animations,
    info.materials, info.targets, info.native, info.files, info.ms, info.otherTimeBase > 0 and string.format(" (%d with a time base other than World, played on the world clock)", info.otherTimeBase) or "")
end

local function stepClock(dt)
  A.clock = A.clock + dt
  for i = 1, #A.animList do
    local anim = A.animList[i]
    local want = math.floor(A.clock * anim.fps) % anim.count
    if want ~= anim.want then
      anim.want = want
      for j = 1, #anim.mats do
        local rec = anim.mats[j]
        for k = 1, #rec.targets do
          local t = rec.targets[k]
          if t.anim == anim and needsFrameSwap(t) then queueMaterial(rec); break end
        end
      end
    end
  end
end

-- Picks the frame of every sequence again and queues what is not showing what the mode asks for.
local function kickAnimation()
  for i = 1, #A.animList do A.animList[i].want = nil end
  if A.mode == "native" or A.mode == "frameswap" then stepClock(0) end
  queueDiffering()
end

function M.rebuildAnimationIndex()
  local ok, err = pcall(loadAnimations)
  if not ok then
    A.state = "failed"
    A.info = { error = tostring(err) }
    logMsg("E", "animation index failed: %s", tostring(err))
    return false
  end
  kickAnimation()
  return true
end

local function setMap(obj, rec, field, stage, path)
  local ok, err = pcall(obj.setField, obj, field, stage, path)
  if not ok then
    A.stats.errors = A.stats.errors + 1
    failOnce("anim-setField-" .. field, "setField %s failed on %s: %s", field, rec.name, tostring(err))
  end
end

local function writeAnimated(rec)
  local obj = scenetree and scenetree.findObject(rec.name)
  if not obj then
    A.stats.missing = A.stats.missing + 1
    return false
  end
  local wrote = false
  for i = 1, #rec.targets do
    local t = rec.targets[i]
    local native, want = targetState(t)
    if native then
      if not t.native then                       -- the strip and the sequence flags (a scroll bit in them stays)
        local strip = t.anim.strip
        setMap(obj, rec, "baseColorMap", t.stage, strip.path)
        if t.emissive and strip.emissive then setMap(obj, rec, "emissiveMap", t.stage, strip.emissive) end
        setMap(obj, rec, "animFlags", t.stage, t.seq.on)
        t.native = true
        wrote = true
      end
    elseif t.native or want ~= t.shown then
      local frame = t.anim.frames[want + 1]
      if frame and frame.path then
        setMap(obj, rec, "baseColorMap", t.stage, frame.path)
        if t.emissive and frame.emissive then setMap(obj, rec, "emissiveMap", t.stage, frame.emissive) end
        if t.native and t.seq then setMap(obj, rec, "animFlags", t.stage, t.seq.off) end
        t.native = false
        wrote = true
      else
        A.stats.missing = A.stats.missing + 1
      end
      t.shown = want
    end
  end
  if wrote and not refreshMaterial(obj) then
    A.stats.errors = A.stats.errors + 1
    failOnce("anim-reload", "neither reload() nor flush() worked on %s; the new frame may not show", rec.name)
  end
  return wrote
end

local function drainQueue(limit)
  local n = 0
  while A.qHead <= A.qTail and (not limit or n < limit) do
    local rec = A.queue[A.qHead]
    A.queue[A.qHead] = nil
    A.qHead = A.qHead + 1
    rec.queued = false
    local t0 = os.clock()
    local ok, wrote = pcall(writeAnimated, rec)
    if not ok then
      A.stats.errors = A.stats.errors + 1
      failOnce("anim-write", "animation write failed on %s: %s", rec.name, tostring(wrote))
    elseif wrote then
      local ms = (os.clock() - t0) * 1000
      A.stats.writes = A.stats.writes + 1
      A.stats.writeMs = A.stats.writeMs + ms
      if ms > A.stats.maxMs then A.stats.maxMs = ms end
    end
    n = n + 1
  end
  if A.qHead > A.qTail then A.queue, A.qHead, A.qTail = {}, 1, 0 end
end

local function updateAnimation(dtReal)
  if A.state == "pending" then M.rebuildAnimationIndex() end
  if A.state ~= "ready" then return end
  if A.mode == "native" or A.mode == "frameswap" then stepClock(dtReal) end
  if A.qHead <= A.qTail then drainQueue(TUNING.animWritesPerFrame) end
end

local MODES = { export = true, off = true, native = true, frameswap = true }

function M.setAnimationMode(mode)
  if not MODES[mode] or A.mode == mode then return end
  A.mode = mode
  if A.state == "ready" then kickAnimation() end        -- a pending index kicks itself once it is read
end
function M.getAnimationMode() return A.mode end

-- On/off for the older callers: on = native where converted, frame swap for the rest; off = as exported.
function M.setAnimationEnabled(on) M.setAnimationMode(on and "native" or "export") end
function M.isAnimationEnabled() return A.mode == "native" or A.mode == "frameswap" end

function M.setAnimationBudget(n)
  n = tonumber(n)
  if n then TUNING.animWritesPerFrame = clamp(math.floor(n), 1, 200) end
end
function M.getAnimationBudget() return TUNING.animWritesPerFrame end

-- Writes the next frame of the first animated material, reads it back, logs what write and refresh cost, restores it.
function M.probeAnimation()
  if A.state == "pending" then M.rebuildAnimationIndex() end
  local rec = A.matList[1]
  if not rec then return { ok = false, reason = "no image sequence was read from " .. TUNING.animFile } end
  local obj = scenetree and scenetree.findObject(rec.name)
  if not obj then return { ok = false, name = rec.name, reason = "the engine has no material of that name" } end
  local t = rec.targets[1]
  local from, to = t.shown, (t.shown + 1) % t.anim.count
  local fromFrame, toFrame = t.anim.frames[from + 1], t.anim.frames[to + 1]
  if not (toFrame and toFrame.path and fromFrame and fromFrame.path) then return { ok = false, name = rec.name, reason = "a frame has no texture file" } end
  local okBefore, before = pcall(obj.getField, obj, "baseColorMap", t.stage)
  if not okBefore then before = nil end
  local t0 = os.clock()
  local ok1, err1 = pcall(obj.setField, obj, "baseColorMap", t.stage, toFrame.path)
  local t1 = os.clock()
  local ok2 = refreshMaterial(obj)
  local t2 = os.clock()
  local okRead, back = pcall(obj.getField, obj, "baseColorMap", t.stage)
  local restore = (before ~= nil and tostring(before) ~= "") and tostring(before) or fromFrame.path
  pcall(obj.setField, obj, "baseColorMap", t.stage, restore)
  refreshMaterial(obj)
  local res = { ok = ok1 and ok2, name = rec.name, stage = t.stage, wrote = toFrame.path, readBack = okRead and tostring(back) or "n/a",
                setFieldMs = (t1 - t0) * 1000, refreshMs = (t2 - t1) * 1000, error = (not ok1) and tostring(err1) or nil }
  logMsg("I", "animation probe %s stage %d: wrote %s, read back %s, setField %.3f ms, refresh %.3f ms%s", rec.name, t.stage, toFrame.path,
    res.readBack, res.setFieldMs, res.refreshMs, ok2 and "" or " (refresh failed)")
  return res
end


-- ---------------------------------------------------------------------------
-- Status, lifecycle
-- ---------------------------------------------------------------------------
function M.getStatus()
  return {
    animEnabled = A.mode == "native" or A.mode == "frameswap", animMode = A.mode, animNativeStages = A.info.native or 0, animState = A.state, animInfo = A.info, animSequences = #A.animList, animMaterials = #A.matList,
    animPending = math.max(0, A.qTail - A.qHead + 1), animBudget = TUNING.animWritesPerFrame,
    animWrites = A.stats.writes, animWriteMs = A.stats.writeMs, animMaxWriteMs = A.stats.maxMs,
    animMissing = A.stats.missing, animErrors = A.stats.errors,
  }
end

function M.setDebugLog(flag) TUNING.debugLog = flag and true or false end
function M.getDebugLog() return TUNING.debugLog end

function M.init(ctx)
  TUNING.levelRoot = ((ctx and ctx.levelRoot or TUNING.levelRoot):gsub("/+$", ""))
  A.state = "pending"
  return true
end

function M.onUpdate(dtReal, dtSim)
  local ok, err = pcall(updateAnimation, dtReal or 0.016)
  if not ok then failOnce("animation-update", "animation update failed: %s", tostring(err)) end
end

function M.shutdown()
  A.mode = "export"                                          -- every animated material back as exported
  if A.state == "ready" then
    pcall(kickAnimation)
    pcall(drainQueue, nil)
  end
end

function M.serialize()
  return { animation = { mode = A.mode, budget = TUNING.animWritesPerFrame } }
end

function M.restore(data)
  if type(data) ~= "table" or type(data.animation) ~= "table" then return end
  M.setAnimationBudget(data.animation.budget)
  if data.animation.mode then M.setAnimationMode(data.animation.mode)
  elseif data.animation.enabled then M.setAnimationEnabled(true) end        -- saved before the modes existed
end

return M
