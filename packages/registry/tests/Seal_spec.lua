local TestEnv = require("RegistryTestEnv")

---Bootstrap `demoKit` API 1 at `revision` and commit its surface via `rawset`.
---@param Registry Registry
---@param revision integer
---@param sealFacade boolean|nil
---@return table|nil implementation
local function loadCopy(Registry, revision, sealFacade)
  local implementation = Registry:Bootstrap({
    package = "demoKit",
    api = 1,
    revision = revision,
    label = "MoltenCodes DemoKit",
    validatePublicSurface = function(candidate)
      return rawget(candidate, "API") == 1
    end,
    sealFacade = sealFacade,
  })
  if implementation ~= nil then
    rawset(implementation, "API", 1)
    rawset(implementation, "REVISION", revision)
    rawset(implementation, "Run", function()
      return revision
    end)
  end
  return implementation
end

-- Revision 16 is the last whole file, sealing included; it is kept verbatim.
local WHOLE_REVISION = 16

---Load the Registry source again, as an embedded copy carrying `revision`: the
---whole-file fixture up to revision 16, the core in `src/` after it.
---@param revision integer
---@return Registry
local function loadRegistryAtRevision(revision)
  local path = revision <= WHOLE_REVISION
      and "packages/registry/tests/fixtures/Registry-revision16.lua"
    or "packages/registry/src/Registry.lua"
  local file = assert(io.open(path, "r"))
  local source = file:read("*a")
  file:close()
  local patched, count = string.gsub(
    source,
    "local IMPLEMENTATION_REVISION = %d+",
    "local IMPLEMENTATION_REVISION = " .. revision
  )
  assert.are.equal(1, count)
  return assert(loadstring(patched, "@" .. path))()
end

---A table key whose `__tostring` records that it ran, then answers `answer`
---or, when `answer` is `nil`, raises.
---@param answer string|nil
---@return table key
---@return fun(): boolean ran
local function recordingKey(answer)
  local ran = false
  local key = setmetatable({}, {
    __tostring = function()
      ran = true
      if answer == nil then
        error("a caller's __tostring ran inside Registry", 0)
      end
      return answer
    end,
  })
  return key, function()
    return ran
  end
end

describe("Registry sealed facades", function()
  after_each(TestEnv.Reset)

  it("refuses a new field written from outside the package, at the writer's line", function()
    local Registry = TestEnv.NewRegistry()
    local DemoKit = loadCopy(Registry, 1, true)

    local source = debug.getinfo(1, "S").short_src
    local line
    local ok, message = pcall(function()
      line = debug.getinfo(1, "l").currentline + 1
      DemoKit.Extra = true
    end)

    assert.is_false(ok)
    assert.are.equal(
      source
        .. ":"
        .. line
        .. ': MoltenCodes DemoKit facade is sealed; field "Extra" cannot be added from outside the package',
      message
    )
    assert.is_nil(rawget(DemoKit, "Extra"))
  end)

  it("names a table field by its type without running its __tostring", function()
    local Registry = TestEnv.NewRegistry()
    local DemoKit = loadCopy(Registry, 1, true)
    local key, ran = recordingKey(nil)

    local source = debug.getinfo(1, "S").short_src
    local line
    local ok, message = pcall(function()
      line = debug.getinfo(1, "l").currentline + 1
      DemoKit[key] = true
    end)

    assert.is_false(ok)
    assert.are.equal(
      source
        .. ":"
        .. line
        .. ': MoltenCodes DemoKit facade is sealed; field "<table>" cannot be added from outside the package',
      message
    )
    assert.is_false(ran())
  end)

  it("names a secret field by a placeholder without formatting it", function()
    local Registry = TestEnv.NewRegistry()
    local DemoKit = loadCopy(Registry, 1, true)
    local key, ran = recordingKey(nil)
    -- selene: allow(global_usage)
    rawset(_G, "issecretvalue", function(value)
      return rawequal(value, key)
    end)

    TestEnv.expectErrorContaining('facade is sealed; field "<secret>" cannot be added', function()
      DemoKit[key] = true
    end)
    assert.is_false(ran())
  end)

  it("seals with the new message once the previous Registry revision is upgraded", function()
    local workingRevision = TestEnv.NewRegistry().REVISION
    TestEnv.Reset()
    local previous = loadRegistryAtRevision(workingRevision - 1)
    assert.are.equal(workingRevision - 1, previous.REVISION)
    local DemoKit = loadCopy(previous, 1, true)
    local entries = TestEnv.GetState().entries

    local Registry = TestEnv.Reload()
    require("Registry-Handover")
    assert.are.equal(previous, Registry)
    assert.are.equal(workingRevision, Registry.REVISION)
    assert.are.equal(entries, TestEnv.GetState().entries)
    assert.are.equal(DemoKit, Registry:Get("demoKit", 1))

    -- The seal is the closure of the Registry that installed it, so the
    -- Kit's next copy reseals through the upgraded Registry.
    assert.are.equal(DemoKit, loadCopy(Registry, 2, true))
    local key, ran = recordingKey("converted")
    TestEnv.expectErrorContaining('facade is sealed; field "<table>" cannot be added', function()
      DemoKit[key] = true
    end)
    assert.is_false(ran())
  end)

  it("still lets an upgrading revision mutate the facade through rawset", function()
    local Registry = TestEnv.NewRegistry()
    local DemoKit = loadCopy(Registry, 1, true)

    local upgraded = loadCopy(Registry, 2, true)

    assert.are.equal(DemoKit, upgraded)
    assert.are.equal(2, DemoKit.Run())
    assert.are.equal(2, DemoKit.REVISION)
    assert.has_error(function()
      DemoKit.Extra = true
    end)
  end)

  it("leaves pairs over the facade unchanged", function()
    local Registry = TestEnv.NewRegistry()
    local DemoKit = loadCopy(Registry, 1, true)

    local keys = {}
    for key in pairs(DemoKit) do
      keys[#keys + 1] = key
    end
    table.sort(keys)

    assert.are.same({ "API", "REVISION", "Run" }, keys)
  end)

  it("installs nothing when the option is absent", function()
    local Registry = TestEnv.NewRegistry()
    local DemoKit = loadCopy(Registry, 1)

    DemoKit.Extra = true

    assert.is_nil(getmetatable(DemoKit))
    assert.is_true(DemoKit.Extra)
  end)

  it("names the revision that sealed the facade most recently", function()
    local Registry = TestEnv.NewRegistry()
    local DemoKit = loadCopy(Registry, 1, true)
    Registry:Bootstrap({
      package = "demoKit",
      api = 1,
      revision = 2,
      label = "MoltenCodes DemoKit r2",
      validatePublicSurface = function()
        return true
      end,
      sealFacade = true,
    })

    TestEnv.expectErrorContaining("MoltenCodes DemoKit r2 facade is sealed", function()
      DemoKit.Extra = true
    end)
  end)

  it("is removed by a newer revision that does not ask for it", function()
    local Registry = TestEnv.NewRegistry()
    local DemoKit = loadCopy(Registry, 1, true)

    loadCopy(Registry, 2)

    assert.is_nil(getmetatable(DemoKit))
  end)

  it("refuses to replace a metatable Registry did not install", function()
    local Registry = TestEnv.NewRegistry()
    local DemoKit = loadCopy(Registry, 1)
    setmetatable(DemoKit, {})

    TestEnv.expectErrorContaining(
      "MoltenCodes DemoKit cannot seal a facade that already carries a metatable",
      function()
        loadCopy(Registry, 2, true)
      end
    )
  end)
end)
