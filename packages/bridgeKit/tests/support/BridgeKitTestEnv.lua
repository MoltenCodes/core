--- Package-specific test environment for the BridgeKit suite.
---
--- The World of Warcraft stubs, the `package.loaded` bookkeeping and the error
--- capture live in the shared `FrameworkTestEnv` fixture at `tests/support/`.
--- What stays here is this package's module load order and the loader of the
--- AceSerializer fixtures recorded from Ace3 (`tests/fixtures/`).
local FrameworkTestEnv = require("FrameworkTestEnv")

local BridgeKitTestEnv = FrameworkTestEnv.New({
  modules = { "Registry", "BridgeKit" },
})

--- Where the recorded fixtures live, relative to the repository root, which is
--- the directory the test runner starts Busted in.
local FIXTURE_PATH = "packages/bridgeKit/tests/fixtures/AceSerializerFixtures.lua"

---The AceSerializer-3.0 fixtures recorded from Ace3 by
---`python3 -m tooling.fixtures.ace_serializer`.
---@return table fixtures `{ provenance, encode, decode }`
function BridgeKitTestEnv.AceSerializerFixtures()
  return dofile(FIXTURE_PATH)
end

---Make `issecretvalue` report exactly the given values as secret.
---@param ... any
function BridgeKitTestEnv.MarkSecret(...)
  local secrets = {}
  for index = 1, select("#", ...) do
    secrets[select(index, ...)] = true
  end
  -- selene: allow(global_usage)
  rawset(_G, "issecretvalue", function(value)
    return secrets[value] == true
  end)
end

---Load the BridgeKit source again as a copy carrying `revision`, the way a
---newer embedded copy loads over an older one in the client. `edits` maps
---plain source fragments to their replacements, for a copy that differs in
---more than its revision.
---@param revision integer
---@param edits table<string, string>?
---@return table BridgeKit
function BridgeKitTestEnv.LoadRevision(revision, edits)
  local path = "packages/bridgeKit/src/BridgeKit.lua"
  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()
  local patched, replacements =
    text:gsub("local IMPLEMENTATION_REVISION = %d+", "local IMPLEMENTATION_REVISION = " .. revision)
  assert(replacements == 1, "BridgeKitTestEnv.LoadRevision could not find IMPLEMENTATION_REVISION")
  for fragment, replacement in pairs(edits or {}) do
    local first, last = patched:find(fragment, 1, true)
    assert(first ~= nil, "BridgeKitTestEnv.LoadRevision could not find " .. fragment)
    patched = patched:sub(1, first - 1) .. replacement .. patched:sub(last + 1)
  end
  return assert(loadstring(patched, "@" .. path))()
end

return BridgeKitTestEnv
