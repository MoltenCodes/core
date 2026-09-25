local TestEnv = require("RegistryTestEnv")

-- The lookup fast path (revision 14): `Register`, `Get` and `Find` look the
-- `(packageName, api)` pair up before running the full argument checks, and a
-- hit skips the name pattern. These specs pin that a hit answers exactly what
-- the full path answers, that every malformed argument, secret and corrupted
-- entry is still refused with the same message at the caller's line, that the
-- miss reasons are unchanged, that the fast paths allocate nothing, and that
-- entries written by every older Registry revision the suite models are served
-- after an in-place upgrade.

local SOURCE_PATH = "packages/registry/src/Registry.lua"
local SPEC_SOURCE = debug.getinfo(1, "S").short_src

---Assert that `callback` fails with exactly `expected`, raised at a line of
---this spec file rather than inside Registry.
---@param expected string the full message after the `source:line: ` prefix
---@param callback fun()
local function expectErrorAtCaller(expected, callback)
  local ok, message = pcall(callback)
  message = tostring(message)

  assert.is_false(ok)
  assert.are.equal(1, string.find(message, SPEC_SOURCE .. ":", 1, true), message)
  assert.are.equal(expected, string.sub(message, -#expected), message)
end

---Install an `issecretvalue` probe that reports exactly the listed values as
---secret and records every value it is asked about. `TestEnv.Reset` clears it.
---@param ... any values the probe reports as secret
---@return any[] asked every value the probe was asked about, in order
local function installSecretProbe(...)
  local secrets = {}
  for index = 1, select("#", ...) do
    secrets[select(index, ...)] = true
  end
  local asked = {}
  -- issecretvalue is a World of Warcraft client global; the fixture owns and clears it.
  -- selene: allow(global_usage)
  rawset(_G, "issecretvalue", function(value)
    asked[#asked + 1] = value
    return secrets[value] == true
  end)
  return asked
end

---Publish Registry bootstrap state as an older embedded copy left it.
---@param revision integer the Registry revision that copy carried
---@param entries table the package entries, in that revision's layout
---@return table facade the older copy's facade
local function installOlderRegistry(revision, entries)
  TestEnv.Reset()
  local facade = {
    API = 2,
    REVISION = revision,
    Register = function() end,
    Get = function() end,
    GetInfo = function() end,
  }
  -- Registry's bootstrap handshake happens through the global table, so this spec sets it up there directly.
  -- selene: allow(global_usage)
  rawset(_G, TestEnv.STATE_KEY, {
    schema = 1,
    registryApi = 2,
    registryRevision = revision,
    entries = entries,
    facade = facade,
  })
  return facade
end

---Load the Registry source again as an embedded copy carrying `revision`.
---@param revision integer
---@return Registry
local function loadCopyAtRevision(revision)
  local file = assert(io.open(SOURCE_PATH, "r"))
  local source = file:read("*a")
  file:close()
  local patched, count = string.gsub(
    source,
    "local IMPLEMENTATION_REVISION = %d+",
    "local IMPLEMENTATION_REVISION = " .. revision
  )
  assert.are.equal(1, count)
  local chunk = assert(loadstring(patched, "@" .. SOURCE_PATH))
  return chunk()
end

---Assert that `Get`, `Find` and `Register` serve one existing entry and still
---refuse malformed arguments at the caller.
---@param Registry Registry
---@param packageName string
---@param implementation table
---@param revision integer
local function expectServed(Registry, packageName, implementation, revision)
  assert.are.same({ implementation, revision }, { Registry:Get(packageName, 1) })
  assert.are.same({ implementation, revision }, { Registry:Find(packageName, 1) })
  assert.is_nil(Registry:Register(packageName, 1, revision))
  assert.are.same({ implementation, revision }, { Registry:Register(packageName, 1, revision + 1) })
  assert.are.same({ implementation, revision + 1 }, { Registry:Get(packageName, 1) })
  assert.are.same({ nil, "generation_mismatch" }, { Registry:Find(packageName, 2) })
  expectErrorAtCaller("Registry:Get api must be a positive integer up to 2^53", function()
    Registry:Get(packageName, 0)
  end)
end

describe("Registry lookup fast path", function()
  local Registry

  before_each(function()
    Registry = TestEnv.NewRegistry()
  end)

  after_each(TestEnv.Reset)

  describe("on a hit", function()
    it("answers what the full path answers from Get, Find and Register", function()
      local implementation = Registry:Register("demoKit", 1, 3)

      assert.are.same({ implementation, 3 }, { Registry:Get("demoKit", 1) })
      assert.are.same({ implementation, 3 }, { Registry:Find("demoKit", 1) })
      assert.are.same({ implementation, 3 }, { Registry:Get("demoKit", 1.0) })
      assert.is_nil(Registry:Register("demoKit", 1, 2))
      assert.is_nil(Registry:Register("demoKit", 1, 3))
      assert.are.same({ implementation, 3 }, { Registry:Register("demoKit", 1, 4) })
      assert.are.same({ implementation, 4 }, { Registry:Get("demoKit", 1) })
      assert.are.equal(4, Registry:GetInfo("demoKit", 1).revision)
    end)

    it("drops the retire hook of the revision a Register upgrade replaces", function()
      Registry:Register("demoKit", 1, 1)
      Registry:OnRetire("demoKit", 1, function() end)
      local entry = TestEnv.GetState().entries.demoKit[1]
      assert.is_function(entry.retire)

      Registry:Register("demoKit", 1, 2)

      assert.is_nil(entry.retire)
    end)

    it("still reports a retired entry as retired", function()
      Registry:Register("demoKit", 1, 1)
      rawset(TestEnv.GetState().entries.demoKit[1], "status", "retired")

      assert.are.same({ nil, "retired" }, { Registry:Find("demoKit", 1) })
      assert.is_table((Registry:Get("demoKit", 1)))
    end)
  end)

  describe("on a miss", function()
    it("keeps every reason Find gives", function()
      Registry:Register("demoKit", 1, 1)
      rawset(TestEnv.GetState().entries, "emptyKit", {})

      assert.are.same({ nil, "absent" }, { Registry:Find("missingKit", 1) })
      assert.are.same({ nil, "absent" }, { Registry:Find("emptyKit", 1) })
      assert.are.same({ nil, "generation_mismatch" }, { Registry:Find("demoKit", 2) })
      assert.is_nil(Registry:Get("missingKit", 1))
      assert.is_nil(Registry:Get("demoKit", 2))
    end)

    it("registers a new name and a new API generation", function()
      local first = Registry:Register("demoKit", 1, 1)
      local second, previous = Registry:Register("demoKit", 2, 1)

      assert.is_table(second)
      assert.is_nil(previous)
      assert.are_not.equal(first, second)
      assert.are.equal(second, Registry:Get("demoKit", 2))
    end)
  end)

  describe("argument checks", function()
    it("refuses a malformed name at the caller even when a key could match", function()
      Registry:Register("demoKit", 1, 1)
      local nameErrors = {
        { "", "packageName must be a non-empty string" },
        { 1, "packageName must be a non-empty string" },
        { false, "packageName must be a non-empty string" },
        { "DemoKit", "packageName must match ^[a-z][A-Za-z0-9]*$" },
        { "demo-kit", "packageName must match ^[a-z][A-Za-z0-9]*$" },
      }

      for index = 1, #nameErrors do
        local packageName, problem = nameErrors[index][1], nameErrors[index][2]
        expectErrorAtCaller("Registry:Get " .. problem, function()
          Registry:Get(packageName, 1)
        end)
        expectErrorAtCaller("Registry:Find " .. problem, function()
          Registry:Find(packageName, 1)
        end)
        expectErrorAtCaller("Registry:Register " .. problem, function()
          Registry:Register(packageName, 1, 2)
        end)
      end
      expectErrorAtCaller("Registry:Get packageName must be a non-empty string", function()
        Registry:Get(nil, 1)
      end)
    end)

    it("refuses a malformed API of a registered name at the caller", function()
      Registry:Register("demoKit", 1, 1)
      local malformed = { 0, -1, 1.5, 0 / 0, math.huge, 2 ^ 53 + 2, "1", true, {} }

      for index = 1, #malformed do
        local api = malformed[index]
        expectErrorAtCaller("Registry:Get api must be a positive integer up to 2^53", function()
          Registry:Get("demoKit", api)
        end)
        expectErrorAtCaller("Registry:Find api must be a positive integer up to 2^53", function()
          Registry:Find("demoKit", api)
        end)
        expectErrorAtCaller(
          "Registry:Register api must be a positive integer up to 2^53",
          function()
            Registry:Register("demoKit", api, 2)
          end
        )
      end
    end)

    it("refuses a malformed revision for a registered pair at the caller", function()
      Registry:Register("demoKit", 1, 1)
      local malformed = { 0, 1.5, 0 / 0, math.huge, 2 ^ 53 + 2, "2", nil }

      for index = 1, 7 do
        local revision = malformed[index]
        expectErrorAtCaller(
          "Registry:Register revision must be a positive integer up to 2^53",
          function()
            Registry:Register("demoKit", 1, revision)
          end
        )
      end
      assert.are.equal(1, select(2, Registry:Get("demoKit", 1)))
    end)

    it("refuses an implementation argument before looking anything up", function()
      Registry:Register("demoKit", 1, 1)

      expectErrorAtCaller(
        "Registry:Register does not accept an implementation argument; "
          .. "initialize the returned shared package table instead",
        function()
          Registry:Register("demoKit", 1, 2, {})
        end
      )
      assert.are.equal(1, select(2, Registry:Get("demoKit", 1)))
    end)
  end)

  describe("secret values", function()
    it("asks the probe about the name and the API of a hit before using them", function()
      Registry:Register("demoKit", 1, 1)
      local asked = installSecretProbe()

      Registry:Get("demoKit", 1)

      assert.are.equal("demoKit", asked[1])
      assert.are.equal(1, asked[2])
    end)

    it("refuses a secret name even when it names a registered package", function()
      Registry:Register("demoKit", 1, 1)
      installSecretProbe("demoKit")

      expectErrorAtCaller("Registry:Get packageName must be a non-empty string", function()
        Registry:Get("demoKit", 1)
      end)
      expectErrorAtCaller("Registry:Find packageName must be a non-empty string", function()
        Registry:Find("demoKit", 1)
      end)
      expectErrorAtCaller("Registry:Register packageName must be a non-empty string", function()
        Registry:Register("demoKit", 1, 2)
      end)
    end)

    it("refuses a secret API or revision even for a registered pair", function()
      Registry:Register("demoKit", 1, 1)
      installSecretProbe(1, 2)

      expectErrorAtCaller("Registry:Get api must be a positive integer up to 2^53", function()
        Registry:Get("demoKit", 1)
      end)
      expectErrorAtCaller("Registry:Find api must be a positive integer up to 2^53", function()
        Registry:Find("demoKit", 1)
      end)
      expectErrorAtCaller("Registry:Register api must be a positive integer up to 2^53", function()
        Registry:Register("demoKit", 1, 2)
      end)
    end)

    it("refuses a secret revision argument for a registered pair", function()
      Registry:Register("demoKit", 1, 1)
      installSecretProbe(2)

      expectErrorAtCaller(
        "Registry:Register revision must be a positive integer up to 2^53",
        function()
          Registry:Register("demoKit", 1, 2)
        end
      )
    end)

    it("treats a secret revision in the state as corruption", function()
      Registry:Register("demoKit", 1, 1)
      rawset(TestEnv.GetState().entries.demoKit[1], "revision", 5)
      installSecretProbe(5)

      expectErrorAtCaller("Registry: package state is corrupted", function()
        Registry:Get("demoKit", 1)
      end)
      expectErrorAtCaller("Registry: package state is corrupted", function()
        Registry:Find("demoKit", 1)
      end)
    end)
  end)

  describe("corrupted entries", function()
    it("leaves a malformed entry to the full path, which raises at the caller", function()
      local malformed = {
        { revision = 1.5, implementation = {} },
        { revision = 0 / 0, implementation = {} },
        { revision = 2 ^ 53 + 2, implementation = {} },
        { revision = "1", implementation = {} },
        { revision = 1, implementation = "corrupted" },
        { implementation = {} },
        true,
      }

      for index = 1, #malformed do
        rawset(TestEnv.GetState().entries, "demoKit", { [1] = malformed[index] })
        expectErrorAtCaller("Registry: package state is corrupted", function()
          Registry:Get("demoKit", 1)
        end)
        expectErrorAtCaller("Registry: package state is corrupted", function()
          Registry:Find("demoKit", 1)
        end)
        expectErrorAtCaller("Registry: package state is corrupted", function()
          Registry:Register("demoKit", 1, 2)
        end)
      end
    end)
  end)

  it("allocates nothing for a hit, a miss, a stale copy or an upgrade #allocation", function()
    Registry:Register("demoKit", 1, 1)
    Registry:Register("retiredKit", 1, 1)
    rawset(TestEnv.GetState().entries.retiredKit[1], "status", "retired")
    local revision = 1
    local function exercise()
      Registry:Get("demoKit", 1)
      Registry:Find("demoKit", 1)
      Registry:Find("demoKit", 2)
      Registry:Find("missingKit", 1)
      Registry:Find("retiredKit", 1)
      Registry:Get("missingKit", 1)
      Registry:Register("demoKit", 1, 1)
      revision = revision + 1
      Registry:Register("demoKit", 1, revision)
    end
    exercise()

    collectgarbage()
    collectgarbage("stop")
    local before = collectgarbage("count")
    for _ = 1, 200 do
      exercise()
    end
    local after = collectgarbage("count")
    collectgarbage("restart")

    assert.are.equal(0, after - before)
  end)

  describe("in-place upgrades", function()
    it("serves entries a revision 1 copy registered", function()
      local legacy = { marker = "revision 1" }
      local facade = installOlderRegistry(1, {
        legacyKit = { [1] = { revision = 4, implementation = legacy } },
      })

      local upgraded = TestEnv.requireAfterFailedLoad("Registry")

      assert.are.equal(facade, upgraded)
      assert.are.equal(TestEnv.GetState().registryRevision, upgraded.REVISION)
      expectServed(upgraded, "legacyKit", legacy, 4)
    end)

    it("serves entries a revision 2 copy registered", function()
      local legacy = { marker = "revision 2" }
      local facade = installOlderRegistry(2, {
        legacyKit = { [1] = { revision = 9, implementation = legacy } },
        otherKit = { [3] = { revision = 1, implementation = {} } },
      })

      local upgraded = TestEnv.requireAfterFailedLoad("Registry")

      assert.are.equal(facade, upgraded)
      expectServed(upgraded, "legacyKit", legacy, 9)
      assert.are.same({ nil, "generation_mismatch" }, { upgraded:Find("otherKit", 1) })
    end)

    it("serves entries, statuses and retire hooks the previous revision left", function()
      local Current = Registry
      local currentRevision = Current.REVISION
      local active = Current:Register("activeKit", 1, 2)
      Current:Register("retiredKit", 1, 1)
      rawset(TestEnv.GetState().entries.retiredKit[1], "status", "retired")
      local hook = function() end
      Current:OnRetire("activeKit", 1, hook)

      -- Make the installed Registry look like the previous revision.
      local previousGet = function() end
      rawset(TestEnv.GetState(), "registryRevision", currentRevision - 1)
      rawset(Current, "REVISION", currentRevision - 1)
      rawset(Current, "Get", previousGet)

      local upgraded = TestEnv.Reload()

      assert.are.equal(Current, upgraded)
      assert.are.equal(currentRevision, upgraded.REVISION)
      assert.are_not.equal(previousGet, upgraded.Get)
      assert.are.same({ nil, "retired" }, { upgraded:Find("retiredKit", 1) })
      assert.are.equal(hook, TestEnv.GetState().entries.activeKit[1].retire)
      expectServed(upgraded, "activeKit", active, 2)
      assert.is_nil(TestEnv.GetState().entries.activeKit[1].retire)
    end)

    it("keeps the fast path when an older copy loads afterwards", function()
      local implementation = Registry:Register("demoKit", 1, 1)
      local get, find, register = Registry.Get, Registry.Find, Registry.Register

      local selected = loadCopyAtRevision(Registry.REVISION - 1)

      assert.are.equal(Registry, selected)
      assert.are.equal(get, Registry.Get)
      assert.are.equal(find, Registry.Find)
      assert.are.equal(register, Registry.Register)
      expectServed(Registry, "demoKit", implementation, 1)
    end)

    it("serves the current entries after a newer copy replaces the methods", function()
      local implementation = Registry:Register("demoKit", 1, 1)
      local get = Registry.Get

      local selected = loadCopyAtRevision(Registry.REVISION + 1)

      assert.are.equal(Registry, selected)
      assert.are_not.equal(get, Registry.Get)
      expectServed(Registry, "demoKit", implementation, 1)
    end)
  end)
end)
