-- The shared helper blocks ApiKit carries (tooling/shared/lua/), and the
-- in-place upgrade from revision 6, whose file is kept verbatim as a fixture.
local TestEnv = require("ApiKitTestEnv")

local FIXTURE_DIRECTORY = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "fixtures/"
local RETAIL = { projectId = 1, testBuild = false, betaBuild = false }

---Install a host `issecretvalue` that reports exactly `secret`.
---@param secret any
local function markSecret(secret)
  -- selene: allow(global_usage)
  rawset(_G, "issecretvalue", function(value)
    return rawequal(value, secret)
  end)
end

---Load the committed revision 6 file, the copy an addon embedded before the
---shared blocks, and return what it returns.
---@return table ApiKit
local function loadRevisionSix()
  local path = FIXTURE_DIRECTORY .. "ApiKit-revision6.lua"
  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()
  return assert(loadstring(text, "@" .. path))()
end

---Load Registry for a retail client, run `beforeLoad`, then load ApiKit
---through `loadKit`.
---@param beforeLoad fun()|nil
---@param loadKit fun(): table
---@return table ApiKit
local function loadWith(beforeLoad, loadKit)
  TestEnv.Reset()
  TestEnv.InstallWowApi()
  TestEnv.SetClient(RETAIL)
  require("Registry")
  if beforeLoad ~= nil then
    beforeLoad()
  end
  return loadKit()
end

local function requireCurrent()
  return TestEnv.requireAfterFailedLoad("ApiKit")
end

describe("ApiKit shared helpers", function()
  after_each(TestEnv.Reset)

  it("keeps the secret probe it found at load when the global is replaced", function()
    local ApiKit = loadWith(function()
      markSecret("retail")
    end, requireCurrent)
    markSecret(nil)
    TestEnv.expectErrorContaining(
      "ApiKit:GetMetadataBuild flavor must not be a secret value",
      function()
        ApiKit:GetMetadataBuild("retail")
      end
    )
  end)

  it("asks a probe installed after load when there was none at load", function()
    local ApiKit = loadWith(nil, requireCurrent)
    markSecret("retail")
    TestEnv.expectErrorContaining(
      "ApiKit:GetMetadataBuild flavor must not be a secret value",
      function()
        ApiKit:GetMetadataBuild("retail")
      end
    )
  end)

  it("names a secret key of a SUPPORTED_FLAVORS write <secret>", function()
    local ApiKit = loadWith(nil, requireCurrent)
    local key = "secretKey"
    markSecret(key)
    TestEnv.expectErrorContaining(
      'ApiKit.SUPPORTED_FLAVORS is read-only; index "<secret>" cannot be written',
      function()
        ApiKit.SUPPORTED_FLAVORS[key] = true
      end
    )
  end)

  it("upgrades in place over revision 6: registered flavours and the new probe rule", function()
    local older = loadWith(function()
      markSecret("classic-era")
    end, loadRevisionSix)
    assert.are.equal(6, older.REVISION)
    local state = older._state
    local runs = 0
    assert.is_true(older:RegisterFlavor("retail", function()
      runs = runs + 1
    end, { version = "12.1.0", build = 69933 }))

    local ApiKit = requireCurrent()
    assert.are.equal(older, ApiKit)
    assert.are.equal(7, ApiKit.REVISION)
    assert.are.equal(state, ApiKit._state)
    assert.are.same({ "12.1.0", 69933 }, { ApiKit:GetMetadataBuild("retail") })
    assert.is_false(ApiKit:RegisterFlavor("retail", function()
      runs = runs + 1
    end))
    assert.are.equal(1, runs)

    markSecret(nil)
    TestEnv.expectErrorContaining(
      "ApiKit:GetMetadataBuild flavor must not be a secret value",
      function()
        ApiKit:GetMetadataBuild("classic-era")
      end
    )
  end)
end)
