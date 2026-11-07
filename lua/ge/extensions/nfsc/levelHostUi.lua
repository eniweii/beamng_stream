-- nfsc_levelHostUi: imgui panel for nfsc_levelHost and its components.
-- A control surface only; all state lives in nfsc_levelHost and the components. The imgui calls follow the
-- same conventions as the former environment manager panel (unverified in the engine).

local M = {}
M.dependencies = { "nfsc_levelHost" }

local im = ui_imgui
local windowOpen = im.BoolPtr(true)

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
    log("W", "nfsc_levelHostUi", "tooltips turned off: " .. tostring(err))
  end
end

local ptrs = {}
local function boolPtr(key, value)
  local p = ptrs[key]
  if not p then p = im.BoolPtr(value); ptrs[key] = p end
  p[0] = value
  return p
end

local function floatPtr(key, value)
  local p = ptrs[key]
  if not p then p = im.FloatPtr(value); ptrs[key] = p end
  p[0] = value
  return p
end
local function intPtr(key, value)
  local p = ptrs[key]
  if not p then p = im.IntPtr(value); ptrs[key] = p end
  p[0] = value
  return p
end

local userMult, userFade = 1.0, 0.0           -- what the sliders hold between frames

local function roughnessBody(env, st)
  if st.indexState == "failed" then
    im.TextDisabled("Material index failed: " .. tostring(st.indexInfo.error))
  elseif st.indexState ~= "ready" then
    im.TextDisabled("Reading the materials...")
    return
  else
    im.Text(string.format("%d materials with a shader class, %d selected", st.materials, st.selected))
    tip("Materials whose name ends in a shader class, read once from the level's materials files. Only the selected shaders are changed.")
  end

  for _, c in ipairs(env.getClasses()) do
    local p = boolPtr("cls_" .. c.name, c.selected)
    if im.Checkbox(string.format("%s (%d)##cls_%s", c.name, c.count, c.name), p) then env.setClassSelected(c.name, p[0]) end
    tip("Include the materials of this shader in the roughness change.")
  end

  local mp = floatPtr("mult", userMult)
  if im.SliderFloat("Roughness (x baseline)##rough", mp, 0, 2, "%.2f") then
    userMult = mp[0]
    env.setRoughness("user", userMult, { priority = 10, fade = userFade })
  end
  tip("Scales every selected material's own roughness. 1.00 is the exported value. The result is kept between 0 and 1, so a value above 1 only changes materials that are not fully rough.")
  local fp = floatPtr("fade", userFade)
  if im.SliderFloat("Fade (s)##roughfade", fp, 0, 10, "%.1f") then userFade = fp[0] end
  tip("0 applies the change at once. Above 0 the change is spread over that many seconds in coarse steps.")
  if im.Button("Reset roughness") then
    userMult = 1.0
    env.clearRoughness("user", { fade = userFade })
  end
  tip("Back to the exported roughness of every material.")

  if st.passActive then
    im.Text(string.format("Writing materials: %d of %d", st.passTotal - st.passPending, st.passTotal))
  elseif st.fading then
    im.Text(string.format("Fading: x%.2f towards x%.2f", st.shown, st.desired))
  else
    im.Text(string.format("Applied: x%.2f", st.shown))
  end
end


local function drawRoughness(env, st)
  roughnessBody(env, st)
  if im.CollapsingHeader1("Debug##roughdebug") then
    local dp = boolPtr("roughdbg", env.getDebugLog())
    if im.Checkbox("Detailed logs##roughlogs", dp) then env.setDebugLog(dp[0]) end
    if im.Button("Rebuild material index") then env.rebuildMaterialIndex() end
    tip("Reads the materials files again. The selection of shaders is kept.")
    im.SameLine()
    if im.Button("Probe one material") then env.probeRoughness() end
    tip("Writes half the baseline roughness to one material of the first selected shader, logs what the write and the refresh cost, reads it back and restores it.")
    im.Text(string.format("Passes: %d, writes: %d, %.1f ms in total (worst frame %.2f ms)", st.passes, st.writes, st.writeMs, st.maxWriteMs))
    im.Text(string.format("Missing in the engine: %d, errors: %d", st.missing, st.errors))
  end
end

local function drawSway(env, st)
  local on = boolPtr("swayon", st.swayEnabled)
  if im.Checkbox("Sway swayable objects##swayon", on) then env.setSwayEnabled(on[0]) end
  tip("Objects flagged Swayable lean back and forth about their own origin. Only the nearest ones move; every other object keeps its exported pose.")
  if st.swayUnavailable then im.TextDisabled("Sway unavailable: " .. st.swayUnavailable) end

  local sw = env.getSway()
  local changed = {}
  local p = floatPtr("amp", sw.amplitudeDeg)
  if im.SliderFloat("Amplitude (deg)##swayamp", p, 0, 15, "%.2f") then changed.amplitudeDeg = p[0] end
  tip("The largest lean along the wind. A gust variation and a smaller sideways lean come on top.")
  p = floatPtr("speed", sw.speedHz)
  if im.SliderFloat("Speed (Hz)##swayspeed", p, 0.05, 2, "%.2f") then changed.speedHz = p[0] end
  tip("Back and forth cycles per second.")
  p = floatPtr("wind", sw.windDirDeg)
  if im.SliderFloat("Wind direction (deg)##swaywind", p, 0, 360, "%.0f") then changed.windDirDeg = p[0] end
  tip("The world direction the objects lean towards. 0 is +X, 90 is +Y.")
  p = floatPtr("radius", sw.radius)
  if im.SliderFloat("Radius (m)##swayradius", p, 20, 1000, "%.0f") then changed.radius = p[0] end
  tip("Only objects this close to the camera move.")
  local ip = intPtr("maxobj", sw.maxObjects)
  if im.SliderInt("Max objects##swaymax", ip, 1, 500) then changed.maxObjects = ip[0] end
  tip("At most this many objects move at once, the nearest first. Each one costs one transform write per frame.")
  if next(changed) then env.setSway(changed) end

  im.Text(string.format("Swayable objects: %d registered, %d moving", st.swayRegistered, st.swayMoving))

  if im.CollapsingHeader1("Debug##swaydebug") then
    local dp = boolPtr("swaydbg", env.getDebugLog())
    if im.Checkbox("Detailed logs##swaylogs", dp) then env.setDebugLog(dp[0]) end
    im.Text(string.format("Sway: peak %d moving, %d restored, %d skipped (identity or chopped), %d errors", st.swayPeak, st.swayRestored, st.swaySkipped, st.swayErrors))
  end
end

local function animationBody(env, st)
  local on = boolPtr("animon", st.animEnabled)
  if im.Checkbox("Animate image sequences##animon", on) then env.setAnimationEnabled(on[0]) end
  tip("Signs, screens and lights that cycle through several textures. Only the textures of the materials change; a scroll on the same material keeps running. Switching it off puts every material back on its exported frame.")
  if st.animState == "failed" then
    im.TextDisabled("Animation file failed: " .. tostring(st.animInfo.error))
  elseif st.animState == "missing" then
    im.TextDisabled("No image sequences found. Run Populate animations in the materials populator first.")
  elseif st.animState ~= "ready" then
    im.TextDisabled("Reading the animation file...")
  else
    im.Text(string.format("%d image sequences on %d materials", st.animSequences, st.animMaterials))
    if st.animPending > 0 then im.Text(string.format("Writing materials: %d waiting", st.animPending)) end
  end
end


local function drawAnimation(env, st)
  animationBody(env, st)
  if im.CollapsingHeader1("Debug##animdebug") then
    local dp = boolPtr("animdbg", env.getDebugLog())
    if im.Checkbox("Detailed logs##animlogs", dp) then env.setDebugLog(dp[0]) end
    if im.Button("Reload animation file") then env.rebuildAnimationIndex() end
    tip("Reads material_animations.json again.")
    im.SameLine()
    if im.Button("Probe one animated material") then env.probeAnimation() end
    tip("Writes the next frame to the first animated material, logs what the write and the refresh cost, reads it back and restores the frame. Watch whether its scroll keeps moving.")
    local bp = intPtr("animbudget", env.getAnimationBudget())
    if im.SliderInt("Materials per frame##animbudget", bp, 1, 100) then env.setAnimationBudget(bp[0]) end
    tip("At most this many animated materials are rewritten each frame. Each rewrite reloads the material.")
    if st.animInfo and st.animInfo.targets then
      im.Text(string.format("Animation file: %d file(s), %d stage(s) on %d materials, %d skipped, %d with another time base",
        st.animInfo.files, st.animInfo.targets, st.animInfo.materials, st.animInfo.skipped, st.animInfo.otherTimeBase))
    end
    im.Text(string.format("Animation writes: %d, %.1f ms in total (worst %.2f ms), missing in the engine: %d, errors: %d",
      st.animWrites, st.animWriteMs, st.animMaxWriteMs, st.animMissing, st.animErrors))
  end
end

local function drawSoundZones(comp)
  local sz = nfsc_levelHost.getComponent("soundZones")
  local st = comp.status
  if not sz or not st then return end
  im.Text(string.format("Zones with a sound: %d, spaces: %d, skipped: %d, errors: %d", st.zones, st.boxes, st.skipped, st.errors))
  for role, r in pairs(st.byRole or {}) do
    im.Text(string.format("  %s: %d zones, %d spaces", role, r.zones, r.boxes))
  end
  for name, missing in pairs(st.ambienceMissing or {}) do
    if missing then im.Text("  ambience not found by name: " .. name) end
  end
  if im.Button("Rebuild sound zones") then sz.rebuild() end
  im.SameLine()
  local dp = boolPtr("szdebug", sz.getDebugLog())
  if im.Checkbox("Detailed logs##szdebug", dp) then sz.setDebugLog(dp[0]) end
end

local function drawVolumeScatter(comp)
  local vs = nfsc_levelHost.getComponent("volumeScatter")
  local st = comp.status
  if not vs or not st then return end
  im.Text(string.format("Volume emitter nodes: %d", st.nodes))
  if st.broken then im.Text("  setPosition failed on an emitter node; the scatter switched itself off") end
  local ep = boolPtr("vsenabled", st.enabled)
  if im.Checkbox("Scatter volume emitters##vsenabled", ep) then vs.setEnabled(ep[0]) end
  local dp = floatPtr("vsdist", st.maxDistance)
  if im.SliderFloat("Max distance from camera##vsdist", dp, 0, 1000, "%.0f") then vs.setMaxDistance(dp[0]) end
  local up = intPtr("vsupdates", st.maxUpdatesPerFrame)
  if im.SliderInt("Nodes moved per frame##vsupdates", up, 1, 1000) then vs.setMaxUpdates(up[0]) end
end

local LABEL = { soundZones = "Sound zones", volumeScatter = "Volume scatter", roughness = "Roughness",
               sway = "Sway", textureAnimation = "Texture animation" }

function M.onUpdate()
  if not nfsc_levelHost then return end
  im.Begin("Level Host", windowOpen)
  local st = nfsc_levelHost.getStatus()

  im.Text("Zones I am in: " .. nfsc_levelHost.describeCurrentZones())
  im.Text(string.format("zones.json: %s (%d zones, %d with a polygon), height offset %s",
    st.zones.loaded and "loaded" or "not loaded", st.zones.count, st.zones.usable, tostring(st.zOffset)))
  if st.zones.error then im.Text("  " .. st.zones.error) end
  im.Separator()
  for _, comp in ipairs(st.components) do
    if im.CollapsingHeader1((LABEL[comp.name] or comp.name) .. (comp.ok and "" or " (not running)") .. "##comp_" .. comp.name) then
      if comp.err then im.Text("  " .. comp.err) end
      if comp.name == "soundZones" then drawSoundZones(comp) end
      if comp.name == "volumeScatter" then drawVolumeScatter(comp) end
      local mod = nfsc_levelHost.getComponent(comp.name)
      if mod and comp.status then
        if comp.name == "roughness" then drawRoughness(mod, comp.status) end
        if comp.name == "sway" then drawSway(mod, comp.status) end
        if comp.name == "textureAnimation" then drawAnimation(mod, comp.status) end
      end
    end
  end
  im.Separator()
  if im.CollapsingHeader1("Debug") then
    local dp = boolPtr("hostdebug", nfsc_levelHost.getDebugLog())
    if im.Checkbox("Detailed logs##hostdebug", dp) then nfsc_levelHost.setDebugLog(dp[0]) end
  end
  im.End()
end

return M
