-- Integration sketch only. Adapt the call timing to your existing mainLevel.lua.
-- The ordinary scene must load only from the staged/ patched items.level.json files.

local function initCarbonSectionStreaming()
  extensions.load("nfscSectionStreamPrototype")
  local ok = nfscSectionStreamPrototype.initializeObjects("levels/nfsc")
  if not ok then
    log("E", "nfscSectionStreamPrototype", "section streaming initialization failed")
  end
end

-- Call initCarbonSectionStreaming() once after the level scene exists.
-- Do not also initialize the old scan-all-objects section culler for this test.
