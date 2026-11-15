-- lua-language-server through the facade: the fixture addons check clean at
-- Warning level, and misspelt calls through `MC`, a Kit read from it and a
-- database it opened are flagged. Pending when lua-language-server is not
-- installed (docs/DEVELOPMENT.md lists it with the other gates).
--
-- Known limit, documented in the README: the addon object accepts any field
-- the author adds (`self.db = ...`), so a call chained straight through it,
-- `self.scope.Timers:After(...)`, is not checked; the same call through a
-- local (`local timers = self.scope.Timers`) is.
local TestEnv = require("AddonKitTestEnv")

local FIXTURES = "packages/addonKit/tests/fixtures"

-- Misspelt calls, one per line, and the line each must be flagged on.
local PROBE = [[
local MC = MoltenCodes:For(...)
local addon = MC:NewAddon()
MC:Databse("ProbeDB", {})
local timers = MC.TimerKit:ForAddon("Probe")
timers:Afterr(1, function() end)
local db = MC:Database("ProbeDB", {})
db:SetProfil("Other")
local scope = addon.scope
scope.Timers:Afterr(1, function() end)
]]
local PROBE_LINES = { 3, 5, 7, 9 }

---Run a shell command and return its whole output.
---@param command string
---@return string
local function capture(command)
  local pipe = assert(io.popen(command))
  local output = pipe:read("*a")
  pipe:close()
  return output
end

---Write `text` to `path`.
---@param path string
---@param text string
local function writeFile(path, text)
  local file = assert(io.open(path, "w"))
  file:write(text)
  file:close()
end

---A fresh workspace holding the fixture addons, with every package's source
---and the shared meta as its library, as an author's workspace would hold
---the bundle.
---@return string directory
local function newWorkspace()
  local directory = os.tmpname()
  os.remove(directory)
  assert.are.equal(0, os.execute("mkdir -p '" .. directory .. "/Locales'"))
  local root = string.gsub(capture("pwd"), "%s+$", "")
  local library = { '"' .. root .. '/meta"' }
  for name in string.gmatch(capture("ls packages"), "%S+") do
    local probe = io.open("packages/" .. name .. "/src", "r")
    if probe ~= nil then
      probe:close()
      library[#library + 1] = '"' .. root .. "/packages/" .. name .. '/src"'
    end
  end
  writeFile(
    directory .. "/.luarc.json",
    '{"runtime":{"version":"Lua 5.1"},"workspace":{"checkThirdParty":false,"library":['
      .. table.concat(library, ",")
      .. "]}}"
  )
  writeFile(directory .. "/Core.lua", TestEnv.ReadFile(FIXTURES .. "/TenTasks/Core.lua"))
  writeFile(
    directory .. "/Locales/enUS.lua",
    TestEnv.ReadFile(FIXTURES .. "/TenTasks/Locales/enUS.lua")
  )
  writeFile(
    directory .. "/Locales/deDE.lua",
    TestEnv.ReadFile(FIXTURES .. "/TenTasks/Locales/deDE.lua")
  )
  for _, step in ipairs({ "step1", "step2", "step3", "step4" }) do
    writeFile(
      directory .. "/First" .. step .. ".lua",
      TestEnv.ReadFile(FIXTURES .. "/FirstAddon/" .. step .. "/Core.lua")
    )
  end
  return directory
end

---Check `directory` and return the output with terminal colours removed.
---@param directory string
---@return string
local function check(directory)
  local output = capture(
    "cd '"
      .. directory
      .. "' && lua-language-server --check . --checklevel=Warning --logpath '"
      .. directory
      .. "/log' 2>&1"
  )
  return (string.gsub(output, "\27%[[%d;]*m", ""))
end

describe("AddonKit with lua-language-server", function()
  local installed = string.find(capture("command -v lua-language-server"), "%S") ~= nil
  local workspace = nil

  after_each(function()
    if workspace ~= nil then
      os.execute("rm -rf '" .. workspace .. "'")
      workspace = nil
    end
  end)

  it("checks the fixture addons with no diagnostic", function()
    if not installed then
      pending("lua-language-server is not installed")
      return
    end
    workspace = newWorkspace()
    local output = check(workspace)
    assert.is_truthy(string.find(output, "no problems found", 1, true), output)
  end)

  it("flags misspelt calls through the facade, a Kit and a database", function()
    if not installed then
      pending("lua-language-server is not installed")
      return
    end
    workspace = newWorkspace()
    writeFile(workspace .. "/Probe.lua", PROBE)
    local output = check(workspace)
    for _, line in ipairs(PROBE_LINES) do
      assert.is_truthy(string.find(output, "Probe.lua:" .. line .. ":", 1, true), output)
    end
    assert.is_truthy(string.find(output, "Found " .. #PROBE_LINES .. " problems", 1, true), output)
  end)
end)
