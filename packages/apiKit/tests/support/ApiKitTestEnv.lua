--- Package-specific test environment for the ApiKit suite.
---
--- The World of Warcraft stubs, the `package.loaded` bookkeeping and the error
--- capture live in the shared `FrameworkTestEnv` fixture at `tests/support/`.
--- What stays here is this package's own module load order and the client
--- identity ApiKit reads: `WOW_PROJECT_ID`, `IsTestBuild` and `IsBetaBuild`,
--- plus the short `wow` global the package may publish.
---
--- ApiKit requires Registry and nothing else, so the chain is two modules.
local FrameworkTestEnv = require("FrameworkTestEnv")

local ApiKitTestEnv = FrameworkTestEnv.New({
  modules = { "Registry", "ApiKit" },
})

--- The globals this environment writes on top of the shared fixture's.
local OWNED_GLOBALS = { "WOW_PROJECT_ID", "IsTestBuild", "IsBetaBuild", "wow" }

local resetFixture = ApiKitTestEnv.Reset

---Reset the shared fixture and clear the client identity and the short global.
function ApiKitTestEnv.Reset()
  resetFixture()
  for index = 1, #OWNED_GLOBALS do
    -- The fixture stands in for the client, whose globals only exist in the global table.
    -- selene: allow(global_usage)
    rawset(_G, OWNED_GLOBALS[index], nil)
  end
end

---Describe the running client before `NewPackage` or `ReloadPackage` loads
---ApiKit: the project id (or `nil` for a client without one) and whether the
---two build probes answer `true`. A probe named `false` here is installed as
---a function returning `false`; `nil` leaves the probe absent, as a client
---that predates it would.
---@param client { projectId: integer?, testBuild: boolean?, betaBuild: boolean? }
function ApiKitTestEnv.SetClient(client)
  -- selene: allow(global_usage)
  rawset(_G, "WOW_PROJECT_ID", client.projectId)
  for _, probe in ipairs({
    { "IsTestBuild", client.testBuild },
    { "IsBetaBuild", client.betaBuild },
  }) do
    local name, answer = probe[1], probe[2]
    local implementation = nil
    if answer ~= nil then
      implementation = function()
        return answer
      end
    end
    -- selene: allow(global_usage)
    rawset(_G, name, implementation)
  end
end

---Load the chain for a client of `flavor`, described the way the flavour table does.
---@param flavor "retail"|"classic-era"|"classic-mop"|"ptr"|"beta"|"tbc"|"none"
---@return table ApiKit
---@return table Registry
function ApiKitTestEnv.NewPackageFor(flavor)
  local clients = {
    retail = { projectId = 1, testBuild = false, betaBuild = false },
    ["classic-era"] = { projectId = 2, testBuild = false, betaBuild = false },
    ["classic-mop"] = { projectId = 19, testBuild = false, betaBuild = false },
    ptr = { projectId = 1, testBuild = true, betaBuild = false },
    beta = { projectId = 1, testBuild = true, betaBuild = true },
    tbc = { projectId = 5, testBuild = false, betaBuild = false },
    none = {},
  }
  local client = clients[flavor]
  if client == nil then
    error("ApiKitTestEnv.NewPackageFor knows no client called " .. tostring(flavor), 2)
  end
  ApiKitTestEnv.Reset()
  ApiKitTestEnv.InstallWowApi()
  ApiKitTestEnv.SetClient(client)
  local Registry = require("Registry")
  local ApiKit = require("ApiKit")
  return ApiKit, Registry
end

---Load the ApiKit source again as a copy carrying `revision`, the way a copy
---of another revision embedded by another addon loads in the client.
---@param revision integer
---@return table ApiKit
function ApiKitTestEnv.LoadRevision(revision)
  -- Lua 5.1 has no `package.searchpath`, so walk the path templates the way
  -- `require` does.
  local path = nil
  for template in package.path:gmatch("[^;]+") do
    local candidate = template:gsub("%?", "ApiKit")
    local file = io.open(candidate, "r")
    if file ~= nil then
      file:close()
      path = candidate
      break
    end
  end
  if path == nil then
    error("ApiKitTestEnv.LoadRevision could not find ApiKit.lua on package.path", 2)
  end

  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()

  local patched, replacements =
    text:gsub("local IMPLEMENTATION_REVISION = %d+", "local IMPLEMENTATION_REVISION = " .. revision)
  if replacements ~= 1 then
    error("ApiKitTestEnv.LoadRevision could not find IMPLEMENTATION_REVISION", 2)
  end

  local chunk = assert(loadstring(patched, "@" .. path))
  return chunk()
end

return ApiKitTestEnv
