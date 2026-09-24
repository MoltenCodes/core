local TestEnv = require("RegistryTestEnv")

-- A stand-in for a Registry API generation that does not exist yet. Only the
-- fields Registry API 2 inspects when it decides who owns the public alias are
-- modelled; the rest of a real generation's contract is deliberately not
-- guessed at here.
local function newForeignGeneration(api)
  return {
    API = api,
    REVISION = 1,
    Register = function() end,
    Get = function() end,
    GetInfo = function() end,
  }
end

describe("Registry API-generation coexistence", function()
  before_each(TestEnv.Reset)
  after_each(TestEnv.Reset)

  it("publishes itself under its own generation key and as the alias", function()
    local Registry = require("Registry")
    local namespace = TestEnv.GetNamespace()

    assert.are.equal(Registry, namespace.Registries[2])
    assert.are.equal(Registry, namespace.Registry)
  end)

  it("loads beside a newer generation without claiming the alias", function()
    local newer = newForeignGeneration(3)
    -- Registry's bootstrap handshake happens through the global table, so this spec sets it up there directly.
    -- selene: allow(global_usage)
    rawset(_G, TestEnv.NAMESPACE_KEY, {
      Registry = newer,
      Registries = { [3] = newer },
    })

    local Registry = require("Registry")
    local namespace = TestEnv.GetNamespace()

    assert.are.equal(newer, namespace.Registry)
    assert.are.equal(newer, namespace.Registries[3])
    assert.are.equal(Registry, namespace.Registries[2])
    assert.are.equal(2, Registry.API)
  end)

  it("stays fully usable while a newer generation owns the alias", function()
    local newer = newForeignGeneration(3)
    -- Registry's bootstrap handshake happens through the global table, so this spec sets it up there directly.
    -- selene: allow(global_usage)
    rawset(_G, TestEnv.NAMESPACE_KEY, {
      Registry = newer,
      Registries = { [3] = newer },
    })

    local Registry = require("Registry")
    local implementation = Registry:Register("exampleKit", 1, 3)
    implementation.marker = "api2"

    local selected, revision = Registry:Get("exampleKit", 1)

    assert.are.equal(implementation, selected)
    assert.are.equal(3, revision)
    assert.are.equal("api2", selected.marker)
  end)

  it("claims the alias from an older generation and keeps it reachable", function()
    local older = newForeignGeneration(1)
    -- Registry's bootstrap handshake happens through the global table, so this spec sets it up there directly.
    -- selene: allow(global_usage)
    rawset(_G, TestEnv.NAMESPACE_KEY, { Registry = older })

    local Registry = require("Registry")
    local namespace = TestEnv.GetNamespace()

    assert.are.equal(Registry, namespace.Registry)
    assert.are.equal(Registry, namespace.Registries[2])
    assert.are.equal(older, namespace.Registries[1])
  end)

  it("does not overwrite an older generation that already published itself", function()
    local older = newForeignGeneration(1)
    local olderReplacement = newForeignGeneration(1)
    -- Registry's bootstrap handshake happens through the global table, so this spec sets it up there directly.
    -- selene: allow(global_usage)
    rawset(_G, TestEnv.NAMESPACE_KEY, {
      Registry = olderReplacement,
      Registries = { [1] = older },
    })

    local Registry = require("Registry")
    local namespace = TestEnv.GetNamespace()

    assert.are.equal(Registry, namespace.Registry)
    assert.are.equal(older, namespace.Registries[1])
  end)

  it("resolves the same way whichever generation loads first", function()
    local newer = newForeignGeneration(3)

    -- Newer generation first.
    TestEnv.Reset()
    -- Registry's bootstrap handshake happens through the global table, so this spec sets it up there directly.
    -- selene: allow(global_usage)
    rawset(_G, TestEnv.NAMESPACE_KEY, {
      Registry = newer,
      Registries = { [3] = newer },
    })
    local newerFirst = require("Registry")
    local newerFirstNamespace = TestEnv.GetNamespace()
    local newerFirstAlias = newerFirstNamespace.Registry
    local newerFirstApi2 = newerFirstNamespace.Registries[2]
    local newerFirstApi3 = newerFirstNamespace.Registries[3]

    -- This generation first, newer generation published afterwards exactly
    -- as its own bootstrap would: own key first, then the alias.
    TestEnv.Reset()
    local thisFirst = require("Registry")
    local thisFirstNamespace = TestEnv.GetNamespace()
    rawset(thisFirstNamespace.Registries, 3, newer)
    rawset(thisFirstNamespace, "Registry", newer)

    assert.are.equal(newer, newerFirstAlias)
    assert.are.equal(newer, thisFirstNamespace.Registry)
    assert.are.equal(newerFirstApi2, newerFirst)
    assert.are.equal(thisFirstNamespace.Registries[2], thisFirst)
    assert.are.equal(newer, newerFirstApi3)
    assert.are.equal(newer, thisFirstNamespace.Registries[3])
  end)

  it("keeps bootstrap state private to each generation", function()
    local foreignStateKey = "__MOLTENCODES_REGISTRY_STATE_V3"
    local foreignState = { schema = 1, registryApi = 3 }
    -- Registry's bootstrap handshake happens through the global table, so this spec sets it up there directly.
    -- selene: allow(global_usage)
    rawset(_G, foreignStateKey, foreignState)

    local Registry = require("Registry")

    -- Registry's bootstrap handshake happens through the global table, so this spec sets it up there directly.
    -- selene: allow(global_usage)
    assert.are.equal(foreignState, rawget(_G, foreignStateKey))
    assert.are.equal(2, rawget(TestEnv.GetState(), "registryApi"))
    assert.are.equal(Registry, rawget(TestEnv.GetState(), "facade"))

    -- Registry's bootstrap handshake happens through the global table, so this spec sets it up there directly.
    -- selene: allow(global_usage)
    rawset(_G, foreignStateKey, nil)
  end)

  it("rejects an incompatible owner of the generation table", function()
    -- Registry's bootstrap handshake happens through the global table, so this spec sets it up there directly.
    -- selene: allow(global_usage)
    rawset(_G, TestEnv.NAMESPACE_KEY, { Registries = "occupied" })

    local ok, message = pcall(require, "Registry")

    assert.is_false(ok)
    assert.is_not_nil(string.find(tostring(message), "MoltenCodes.Registries is owned", 1, true))
  end)

  it("rejects a foreign facade already parked under this generation key", function()
    -- Registry's bootstrap handshake happens through the global table, so this spec sets it up there directly.
    -- selene: allow(global_usage)
    rawset(_G, TestEnv.NAMESPACE_KEY, {
      Registries = { [2] = newForeignGeneration(2) },
    })

    local ok, message = pcall(require, "Registry")

    assert.is_false(ok)
    assert.is_not_nil(
      string.find(tostring(message), "MoltenCodes.Registries[2] is not this facade", 1, true)
    )
  end)
end)

describe("Registry load-time failures", function()
  before_each(TestEnv.Reset)
  after_each(TestEnv.Reset)

  it("name the package and carry no misleading source position", function()
    -- Registry's bootstrap handshake happens through the global table, so this spec sets it up there directly.
    -- selene: allow(global_usage)
    rawset(_G, TestEnv.NAMESPACE_KEY, "occupied")

    local ok, message = pcall(require, "Registry")
    message = tostring(message)

    assert.is_false(ok)
    assert.are.equal(
      "Registry: MoltenCodes global namespace is owned by an incompatible value",
      message
    )
  end)

  it("report incompatible bootstrap state without a source position", function()
    -- Registry's bootstrap handshake happens through the global table, so this spec sets it up there directly.
    -- selene: allow(global_usage)
    rawset(_G, TestEnv.STATE_KEY, {
      schema = 1,
      registryApi = 1,
      registryRevision = 1,
      entries = {},
      facade = {},
    })

    local ok, message = pcall(require, "Registry")

    assert.is_false(ok)
    assert.are.equal("Registry: API generation is incompatible", tostring(message))
  end)
end)
