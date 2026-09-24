--- Package-specific test environment for the LogKit suite.
---
--- The World of Warcraft stubs, the `package.loaded` bookkeeping and the error
--- capture live in the shared `FrameworkTestEnv` fixture at `tests/support/`.
--- What stays here is this package's own module load order and the host
--- surface only LogKit touches, which the shared fixture does not model:
---
---   `DEFAULT_CHAT_FRAME`   a frame whose `AddMessage` records lines, read
---                          back with `ChatLines`, installed by `InstallChatApi`;
---   `SlashCmdList`         a plain table, as in the client, so CommandKit can
---                          register `/log`; `RunSlash` runs a typed line.
---
--- These globals are installed on request and removed again by `Reset`,
--- because they are not among the globals the shared fixture owns.
---
--- CommandKit and SettingsKit are optional dependencies of LogKit, declared
--- under `optionalDependencies`, so the test runner puts them and their own
--- required closure (SchemaKit) on `LUA_PATH`. `NewPackage` loads Registry,
--- SignalKit and LogKit only, as an addon that embeds neither does;
--- `LoadCommandKit` and `LoadSettingsKit` add one on top of the chain, after
--- LogKit, as an addon that embeds it would, and `Reset` unloads them again.
local FrameworkTestEnv = require("FrameworkTestEnv")

local MODULES = { "Registry", "SignalKit", "LogKit" }

-- The mainline profile publishes `issecretvalue`, which the secret-value
-- specs need behind `NewSecretValue`; LogKit reads nothing else from it.
local LogKitTestEnv = FrameworkTestEnv.New({
  modules = MODULES,
  wowProfile = "mainline",
})

--- The host globals this environment installs and removes.
local OWNED_GLOBALS = { "DEFAULT_CHAT_FRAME", "SlashCmdList" }

--- Every module a spec may load on top of the chain, cleared by `Reset`.
local EXTRA_MODULES = { "SchemaKit", "CommandKit", "SettingsKit" }

--- Saved-variable globals specs opened SettingsKit databases over.
local savedVariables = {}

local chatLines = {}

---Write a host global. The fixture stands in for the World of Warcraft client,
---whose API only exists in the global table.
---@param name string
---@param value any
local function setGlobal(name, value)
  -- selene: allow(global_usage)
  rawset(_G, name, value)
end

---Read a host global the same way.
---@param name string
---@return any
local function getGlobal(name)
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

---Write a host global from a spec, for a host function a case replaces.
---@param name string
---@param value any
function LogKitTestEnv.SetGlobal(name, value)
  setGlobal(name, value)
end

---Install `DEFAULT_CHAT_FRAME` recording every line it receives.
function LogKitTestEnv.InstallChatApi()
  setGlobal("DEFAULT_CHAT_FRAME", {
    AddMessage = function(_, text)
      chatLines[#chatLines + 1] = text
    end,
  })
end

---The lines `DEFAULT_CHAT_FRAME` received since the last `Reset`.
---@return string[]
function LogKitTestEnv.ChatLines()
  return chatLines
end

---Make the host's `issecretvalue` report `secret` (compared with `rawequal`)
---as a secret value. The shared fixture owns and clears this global.
---@param secret any
function LogKitTestEnv.InstallSecretProbe(secret)
  setGlobal("issecretvalue", function(value)
    return rawequal(value, secret)
  end)
end

---Load the module chain into a host that publishes no `GetTimePreciseSec`.
---
---`NewPackage` resets the stubs, which would restore the clock, so the chain
---is loaded by hand after withholding it. LogKit binds the clock once at load.
---@return table LogKit
function LogKitTestEnv.NewPackageWithoutClock()
  LogKitTestEnv.Reset()
  LogKitTestEnv.InstallWowApi()
  setGlobal("GetTimePreciseSec", nil)
  require(MODULES[1])
  require(MODULES[2])
  return require(MODULES[3])
end

---Install `SlashCmdList` and load SchemaKit and CommandKit on top of the chain.
---@return table CommandKit
function LogKitTestEnv.LoadCommandKit()
  if getGlobal("SlashCmdList") == nil then
    setGlobal("SlashCmdList", {})
  end
  require("SchemaKit")
  return require("CommandKit")
end

---Load SchemaKit and SettingsKit on top of the chain.
---@return table SettingsKit
---@return table SchemaKit
function LogKitTestEnv.LoadSettingsKit()
  local SchemaKit = require("SchemaKit")
  return require("SettingsKit"), SchemaKit
end

---Remember a saved-variable global a spec opened a database over, so `Reset`
---removes it. `SettingsKit:Open` creates the global when it is missing.
---@param name string
function LogKitTestEnv.SavedVariable(name)
  savedVariables[name] = true
end

---Find the slash-table key whose `SLASH_<key><n>` globals include `slash`,
---ignoring case, as the client does.
---@param slash string `"/name"`
---@return string|nil key
local function findSlashKey(slash)
  local list = getGlobal("SlashCmdList")
  if type(list) ~= "table" then
    return nil
  end
  local upper = slash:upper()
  for key in pairs(list) do
    local index = 1
    while true do
      local value = getGlobal("SLASH_" .. key .. index)
      if value == nil then
        break
      end
      if value:upper() == upper then
        return key
      end
      index = index + 1
    end
  end
  return nil
end

---Run a typed chat line the way the client does: split off `/name`, find its
---key and call the slash function with the rest of the line.
---@param line string
function LogKitTestEnv.RunSlash(line)
  local slash, rest = line:match("^(/%S+)%s*(.*)$")
  if slash == nil then
    error("LogKitTestEnv.RunSlash expects a line starting with /name", 2)
  end
  local key = findSlashKey(slash)
  if key == nil then
    error("LogKitTestEnv.RunSlash found no slash command " .. slash, 2)
  end
  getGlobal("SlashCmdList")[key](rest)
end

local sharedReset = LogKitTestEnv.Reset

---Clear everything the shared fixture clears, plus the modules loaded on top
---of the chain, the chat and slash globals and every saved variable.
function LogKitTestEnv.Reset()
  sharedReset()
  for index = 1, #EXTRA_MODULES do
    package.loaded[EXTRA_MODULES[index]] = nil
  end
  for index = 1, #OWNED_GLOBALS do
    setGlobal(OWNED_GLOBALS[index], nil)
  end
  for name in pairs(savedVariables) do
    setGlobal(name, nil)
  end
  savedVariables = {}
  local slashNames = {}
  -- selene: allow(global_usage)
  for name in pairs(_G) do
    if type(name) == "string" and name:find("^SLASH_") then
      slashNames[#slashNames + 1] = name
    end
  end
  for index = 1, #slashNames do
    setGlobal(slashNames[index], nil)
  end
  chatLines = {}
end

---Kilobytes allocated while `action` runs, with the collector stopped.
---
---`action` runs once beforehand so one-time costs (a stack that grows, a
---journal slot widened on first use) are not counted.
---@param action fun()
---@return number kilobytes
function LogKitTestEnv.AllocatedKilobytes(action)
  action()
  collectgarbage()
  collectgarbage("stop")
  local before = collectgarbage("count")
  action()
  local after = collectgarbage("count")
  collectgarbage("restart")
  return after - before
end

---Load the LogKit source again as a copy carrying `revision`, the way a
---newer embedded copy loads over an older one in the client.
---@param revision integer
---@return table LogKit
function LogKitTestEnv.LoadRevision(revision)
  -- Lua 5.1 has no `package.searchpath`, so walk the path templates the way
  -- `require` does.
  local path = nil
  for template in package.path:gmatch("[^;]+") do
    local candidate = template:gsub("%?", "LogKit")
    local file = io.open(candidate, "r")
    if file ~= nil then
      file:close()
      path = candidate
      break
    end
  end
  if path == nil then
    error("LogKitTestEnv.LoadRevision could not find LogKit.lua on package.path", 2)
  end

  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()

  local patched, replacements =
    text:gsub("local IMPLEMENTATION_REVISION = %d+", "local IMPLEMENTATION_REVISION = " .. revision)
  if replacements ~= 1 then
    error("LogKitTestEnv.LoadRevision could not find IMPLEMENTATION_REVISION", 2)
  end

  local chunk = assert(loadstring(patched, "@" .. path))
  return chunk()
end

return LogKitTestEnv
