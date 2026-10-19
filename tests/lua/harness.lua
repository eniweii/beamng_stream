-- Minimal BeamNG GE-Lua mock for running the nfsc section extensions offline (Lua 5.1/LuaJIT).
-- Not a BeamNG emulator: it only provides what the streamer, manager and tests touch.
local H = { logs = {}, hookCalls = {}, loaded = {}, created = {}, cam = { x = 0, y = 0, z = 0 } }
local byName, byId, nextId = {}, {}, 1

-- JSON decoder (enough for the builder output) ------------------------------
local function decode(str)
  local pos = 1
  local parseValue
  local function skip() pos = str:find("[^ \n\r\t]", pos) or (#str + 1) end
  local escapes = { n = "\n", t = "\t", r = "\r", b = "\b", f = "\f", ["/"] = "/", ["\\"] = "\\", ['"'] = '"' }
  local function parseString()
    local out = {}
    pos = pos + 1
    while true do
      local c = str:sub(pos, pos)
      if c == '"' then pos = pos + 1; break
      elseif c == "\\" then
        local n = str:sub(pos + 1, pos + 1)
        if n == "u" then
          local code = tonumber(str:sub(pos + 2, pos + 5), 16)
          out[#out + 1] = code < 128 and string.char(code) or "?"
          pos = pos + 6
        else out[#out + 1] = escapes[n]; pos = pos + 2 end
      else out[#out + 1] = c; pos = pos + 1 end
    end
    return table.concat(out)
  end
  function parseValue()
    skip()
    local c = str:sub(pos, pos)
    if c == "{" then
      local t = {}
      pos = pos + 1; skip()
      if str:sub(pos, pos) == "}" then pos = pos + 1; return t end
      while true do
        skip()
        local k = parseString(); skip(); pos = pos + 1   -- ':'
        t[k] = parseValue(); skip()
        local d = str:sub(pos, pos); pos = pos + 1
        if d == "}" then return t end
      end
    elseif c == "[" then
      local t = {}
      pos = pos + 1; skip()
      if str:sub(pos, pos) == "]" then pos = pos + 1; return t end
      while true do
        t[#t + 1] = parseValue(); skip()
        local d = str:sub(pos, pos); pos = pos + 1
        if d == "]" then return t end
      end
    elseif c == '"' then return parseString()
    elseif str:sub(pos, pos + 3) == "true" then pos = pos + 4; return true
    elseif str:sub(pos, pos + 4) == "false" then pos = pos + 5; return false
    elseif str:sub(pos, pos + 3) == "null" then pos = pos + 4; return nil
    else
      local num = str:match("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
      pos = pos + #num
      return tonumber(num)
    end
  end
  return parseValue()
end
H.decode = decode

-- Engine mocks ----------------------------------------------------------------
local function newObject(class)
  local o = { class = class, fields = {}, id = nextId, deleted = false, hidden = false, children = {} }
  nextId = nextId + 1
  function o:setField(name, idx, value) self.fields[name] = value end
  function o:getID() return self.id end
  function o:registerObject(name)
    assert(not byName[name], "name already registered: " .. name)
    self.name = name; byName[name] = self; byId[self.id] = self
    H.created[name] = (H.created[name] or 0) + 1
  end
  function o:addObject(child) self.children[#self.children + 1] = child end
  function o:delete()
    if self.deleted then return end
    self.deleted = true
    if self.name then byName[self.name] = nil end
    byId[self.id] = nil
    for _, c in ipairs(self.children) do c:delete() end
  end
  function o:isSubClassOf(c) return self.class == c end
  function o:getPosition() return self.fields.position end
  function o:getScale() return self.fields.scale end
  return o
end

function H.install(root)
  for k in pairs(byName) do byName[k] = nil end
  for k in pairs(byId) do byId[k] = nil end
  H.root = root
  createObject = newObject
  scenetree = {
    findObject = function(name) return byName[name] end,
    findObjectById = function(id) return byId[id] end,
    getAllObjects = function(self)
      local names = {}
      for name in pairs(byName) do names[#names + 1] = name end
      return names
    end,
  }
  local mission = newObject("SimGroup"); mission:registerObject("MissionGroup")
  H.reloadCalls = 0
  be = { reloadCollision = function() H.reloadCalls = H.reloadCalls + 1 end }
  core_camera = { getPosition = function() return H.cam end }
  log = function(level, origin, msg) H.logs[#H.logs + 1] = level .. " " .. msg end
  H.readFilter = nil
  jsonReadFile = function(path)
    if H.readFilter then
      local replaced = H.readFilter(path)
      if replaced ~= nil then return replaced or nil end
    end
    local f = io.open(root .. "/" .. path, "rb")
    if not f then return nil end
    local text = f:read("*a"); f:close()
    return decode(text)
  end
  extensions = {
    hook = function(name, ...)
      H.hookCalls[#H.hookCalls + 1] = { name = name, args = { ... } }
      for _, ext in ipairs(H.loaded) do
        if ext[name] then ext[name](...) end
      end
    end,
  }
end

-- A scene object that was NOT streamed (emitter or light baked into the level).
function H.addSceneObject(spec)
  local o = { class = spec.class, id = nextId, name = spec.name, deleted = false, active = true, isEnabled = true,
              sectionID = spec.sectionID, sectionOverrideName = spec.sectionOverrideName,
              farClip = spec.farClip, volBase = spec.volBase, pos = spec.pos or { x = 0, y = 0, z = 0 } }
  nextId = nextId + 1
  function o:getID() return self.id end
  function o:isSubClassOf(c)
    return self.class == c or (c == "LightBase" and (self.class == "PointLight" or self.class == "SpotLight"))
  end
  function o:setActive(v) self.active = v end
  function o:getPosition() return self.pos end
  function o:delete() self.deleted = true; byName[self.name] = nil; byId[self.id] = nil end
  byName[o.name] = o
  byId[o.id] = o
  return o
end

function H.load(path)
  local chunk = assert(loadfile(path))
  return chunk()
end

function H.byName(name) return byName[name] end
function H.hooks(name)
  local out = {}
  for _, c in ipairs(H.hookCalls) do if c.name == name then out[#out + 1] = c end end
  return out
end

-- the engine calls onUpdate on every loaded extension, in load order
function H.tick(streamer, n, dt)
  for _ = 1, n do
    for _, ext in ipairs(H.loaded) do
      if ext.onUpdate then ext.onUpdate(dt or 0.016) end
    end
  end
end

return H
