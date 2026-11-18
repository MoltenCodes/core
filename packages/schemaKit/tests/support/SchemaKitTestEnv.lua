--- Package-specific test environment for the SchemaKit suite.
---
--- The `package.loaded` bookkeeping and the error capture live in the shared
--- `FrameworkTestEnv` fixture at `tests/support/`. What stays here is this
--- package's own module load order and the helpers only its specs describe:
--- a local `issecretvalue` stub, allocation measurement and an in-place
--- upgrade.
---
--- SchemaKit is pure Lua and depends on Registry alone, so the environment
--- installs no World of Warcraft API; the one host facility SchemaKit reads,
--- `issecretvalue`, is installed by the specs that need it.
---
--- `NewPackage` loads the core and both parts (`SchemaKit-Rules`,
--- `SchemaKit-Apply`), the whole surface most specs describe; `NewCore` loads
--- the core alone, as an addon that embeds no part does, and `LoadPart` adds
--- one part on top.
local FrameworkTestEnv = require("FrameworkTestEnv")

local SchemaKitTestEnv = FrameworkTestEnv.New({
  modules = { "Registry", "SchemaKit" },
  wowApi = false,
})

--- The part modules, in the order an addon embedding both loads them.
local PART_MODULES = { "SchemaKit-Rules", "SchemaKit-Apply" }

local SUPPORT_DIRECTORY = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"

-- The last single-file revision, kept verbatim so an "older copy" in the
-- upgrade specs is the whole file an addon of that time embedded.
local REVISION_6_FIXTURE = SUPPORT_DIRECTORY .. "../fixtures/SchemaKit-revision6.lua"

local baseReset = SchemaKitTestEnv.Reset
local baseNewPackage = SchemaKitTestEnv.NewPackage

---Clear the fixture's modules and the part modules.
function SchemaKitTestEnv.Reset()
  baseReset()
  for index = 1, #PART_MODULES do
    package.loaded[PART_MODULES[index]] = nil
  end
end

---Load Registry, the SchemaKit core and both parts.
---@return table SchemaKit, table Registry
function SchemaKitTestEnv.NewPackage()
  local SchemaKit, Registry = baseNewPackage()
  for index = 1, #PART_MODULES do
    require(PART_MODULES[index])
  end
  return SchemaKit, Registry
end

---Load Registry and the SchemaKit core without any part.
---@return table SchemaKit, table Registry
function SchemaKitTestEnv.NewCore()
  return baseNewPackage()
end

---Load one part (`"Rules"` or `"Apply"`) after the core, as an addon that
---embeds it does. The part's module is run again even when it was loaded.
---@param partName string
---@return any result what the part file returns
function SchemaKitTestEnv.LoadPart(partName)
  local moduleName = "SchemaKit-" .. partName
  package.loaded[moduleName] = nil
  return require(moduleName)
end

---Run the revision 6 fixture, the last single-file SchemaKit, as an addon of
---that time embedding it does.
---@return table SchemaKit
function SchemaKitTestEnv.LoadRevision6()
  local file = assert(io.open(REVISION_6_FIXTURE, "r"))
  local text = file:read("*a")
  file:close()
  local chunk = assert(loadstring(text, "@" .. REVISION_6_FIXTURE))
  return chunk()
end

---Install an `issecretvalue` stub that reports every value in `secrets` as
---secret, and return a function that counts how often it was asked.
---
---SchemaKit looks the probe up at every check, so the stub may be installed
---after the package has loaded. `Reset` removes it with the other globals the
---fixture owns.
---@param secrets table<any, true>
---@return fun(): integer calls
function SchemaKitTestEnv.InstallSecretProbe(secrets)
  local calls = 0
  -- The package reads this host global at check time, so the helper has to install it in the global table.
  -- selene: allow(global_usage)
  rawset(_G, "issecretvalue", function(value)
    calls = calls + 1
    return value ~= nil and secrets[value] == true
  end)
  return function()
    return calls
  end
end

---Return a table that stands in for a secret value: every operation a secret
---refuses in the client (comparison, indexing, assignment, length,
---concatenation, calling) raises here too, so a spec proves SchemaKit asked
---`issecretvalue` before touching it.
---@return table secret
function SchemaKitTestEnv.NewSecret()
  local function refuse()
    error("attempt to use a secret value", 2)
  end
  return setmetatable({}, {
    __index = refuse,
    __newindex = refuse,
    __len = refuse,
    __concat = refuse,
    __call = refuse,
    __eq = refuse,
    __lt = refuse,
    __le = refuse,
    __tostring = refuse,
  })
end

---Measure the allocation a workload causes, in kilobytes, with the collector
---stopped so that a collection cycle cannot hide or invent growth.
---@param workload fun()
---@return number kilobytes
function SchemaKitTestEnv.AllocatedKilobytes(workload)
  collectgarbage()
  collectgarbage("stop")
  local before = collectgarbage("count")
  workload()
  local after = collectgarbage("count")
  collectgarbage("restart")
  return after - before
end

---Load the SchemaKit source again as a copy carrying `revision`, the way a
---newer embedded copy loads over an older one in the client. A revision up to
---6 is loaded from the revision 6 fixture (every builder and `Apply` in one
---file, no parts); a later one from the core in `src/`.
---@param revision integer
---@return table SchemaKit
function SchemaKitTestEnv.LoadRevision(revision)
  -- Lua 5.1 has no `package.searchpath`, so walk the path templates the way
  -- `require` does.
  local path = nil
  if revision <= 6 then
    path = REVISION_6_FIXTURE
  else
    for template in package.path:gmatch("[^;]+") do
      local candidate = template:gsub("%?", "SchemaKit")
      local file = io.open(candidate, "r")
      if file ~= nil then
        file:close()
        path = candidate
        break
      end
    end
  end
  if path == nil then
    error("SchemaKitTestEnv.LoadRevision could not find SchemaKit.lua on package.path", 2)
  end

  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()

  local patched, replacements =
    text:gsub("local IMPLEMENTATION_REVISION = %d+", "local IMPLEMENTATION_REVISION = " .. revision)
  if replacements ~= 1 then
    error("SchemaKitTestEnv.LoadRevision could not find IMPLEMENTATION_REVISION", 2)
  end

  local chunk = assert(loadstring(patched, "@" .. path))
  return chunk()
end

return SchemaKitTestEnv
