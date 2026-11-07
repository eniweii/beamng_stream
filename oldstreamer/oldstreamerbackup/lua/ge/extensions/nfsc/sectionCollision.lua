-- nfsc_sectionCollision: collision policy for streamed scenery. Kept apart from rendering so it
-- can be tested and tuned on its own.
--
-- Whether static collision can be refreshed cheaply after objects are created or deleted is not
-- known yet, and a refresh (be:reloadCollision) cannot run asynchronously. So this policy only
-- decides WHEN to pay for it, and measures what it costs:
--   mode "off"     streamed objects are created without collision (the streamer's default).
--   mode "settled" streamed objects keep their exported collisionType. One refresh is done after
--                  the streamer has been idle for settleDelay seconds and at least minInterval
--                  seconds after the previous refresh, however many objects changed meanwhile.
--                  An override change also schedules a refresh, since hidden objects must stop
--                  colliding.
-- Every refresh is timed; the numbers are in getStatus() and the panel.

local M = {}
M.dependencies = { "nfsc_sectionStreamer" }

local TUNING = {
  mode = "off",
  settleDelay = 0.5,    -- seconds with no creates/deletes and nothing queued
  minInterval = 2.0,    -- minimum seconds between refreshes
  warnMs = 8,           -- log refreshes slower than this
}

local dirty, sinceChange, sinceReload = false, 0, math.huge
local reloads, lastMs, maxMs, totalMs, failedReloads = 0, 0, 0, 0, 0
local listener = {}

local function markDirty()
  dirty = true
  sinceChange = 0
end

function listener:onObjectCreated() markDirty() end
function listener:onObjectDeleted() markDirty() end
function listener:onStreamerReset() markDirty() end

local function doReload()
  local started = os.clock()
  local ok = be and pcall(be.reloadCollision, be)
  local ms = (os.clock() - started) * 1000
  dirty = false
  sinceReload = 0
  if not ok then
    failedReloads = failedReloads + 1
    return
  end
  reloads = reloads + 1
  lastMs = ms
  totalMs = totalMs + ms
  if ms > maxMs then maxMs = ms end
  if ms > TUNING.warnMs and log then
    log("W", "nfscSectionCollision", string.format("collision refresh took %.1f ms", ms))
  end
end

local function applyModeToStreamer()
  if nfsc_sectionStreamer and nfsc_sectionStreamer.setTuning then
    nfsc_sectionStreamer.setTuning({ forceCollisionNone = (TUNING.mode == "off") })
  end
end

-- Objects that already exist keep the collision they were created with, so pass rebuild = true
-- to delete and re-stream them under the new mode.
function M.setMode(mode, rebuild)
  if mode ~= "off" and mode ~= "settled" then return false end
  TUNING.mode = mode
  applyModeToStreamer()
  if rebuild and nfsc_sectionStreamer then nfsc_sectionStreamer.reset() end
  return true
end

function M.getMode() return TUNING.mode end

function M.setTuning(values)
  for k, v in pairs(values or {}) do
    if k == "mode" then M.setMode(v) elseif TUNING[k] ~= nil then TUNING[k] = v end
  end
end

function M.refreshNow() doReload() end

function M.getStatus()
  return {
    mode = TUNING.mode, dirty = dirty, reloads = reloads, failedReloads = failedReloads,
    lastMs = lastMs, maxMs = maxMs, avgMs = reloads > 0 and totalMs / reloads or 0,
  }
end

function M.onNfscOverrideChanged() markDirty() end

function M.onUpdate(dtReal)
  dtReal = dtReal or 0
  sinceReload = sinceReload + dtReal
  if TUNING.mode ~= "settled" or not dirty then return end
  sinceChange = sinceChange + dtReal
  if sinceChange >= TUNING.settleDelay and sinceReload >= TUNING.minInterval
      and nfsc_sectionStreamer and nfsc_sectionStreamer.isIdle() then
    doReload()
  end
end

function M.onExtensionLoaded()
  if nfsc_sectionStreamer then nfsc_sectionStreamer.addListener(listener) end
  applyModeToStreamer()
end

function M.onExtensionUnloaded()
  if nfsc_sectionStreamer then nfsc_sectionStreamer.removeListener(listener) end
end

return M
