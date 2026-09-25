local TestEnv = require("OptionsKitTestEnv")

-- The saved variable the revision 2 upgrade spec opens with the real
-- SettingsKit, an optional dependency the runner puts on `LUA_PATH`.
local PROFILE_SAVED_VARIABLE = "OptionsKitBootstrapDB"

---A tree with one toggle over `store.enabled`.
local function toggleTree(store)
  return {
    type = "group",
    args = {
      enabled = {
        type = "toggle",
        name = "Enabled",
        get = function()
          return store.enabled
        end,
        set = function(_, value)
          store.enabled = value
        end,
      },
    },
  }
end

describe("OptionsKit bootstrap", function()
  after_each(function()
    package.loaded["SettingsKit"] = nil
    -- selene: allow(global_usage)
    rawset(_G, PROFILE_SAVED_VARIABLE, nil)
    TestEnv.Reset()
  end)

  it("returns the same facade and keeps trees on duplicate embedded load", function()
    local OptionsKit = TestEnv.NewPackage()
    local tree = OptionsKit:Define("Addon", toggleTree({}))

    local reloaded = TestEnv.ReloadPackage()
    assert.are.equal(OptionsKit, reloaded)
    assert.are.equal(tree, reloaded:Get("Addon"))
  end)

  it("publishes through Registry", function()
    local OptionsKit, Registry = TestEnv.NewPackage()
    local registered, revision = Registry:Get("optionsKit", 1)
    assert.are.equal(OptionsKit, registered)
    assert.are.equal(OptionsKit.REVISION, revision)
  end)

  it("does not reinterpret private state owned by a newer compatible revision", function()
    local OptionsKit, Registry = TestEnv.NewPackage()
    local shippedRevision = OptionsKit.REVISION
    local upgraded, previous = Registry:Register("optionsKit", 1, 99)
    assert.are.equal(OptionsKit, upgraded)
    assert.are.equal(shippedRevision, previous)

    rawset(OptionsKit, "REVISION", 99)
    rawset(OptionsKit, "_state", { schema = 999 })
    package.loaded["OptionsKit"] = nil

    local reloaded = require("OptionsKit")
    assert.are.equal(OptionsKit, reloaded)
    assert.are.equal(99, reloaded.REVISION)
  end)

  it("upgrades in place and keeps every tree and listener", function()
    local OptionsKit = TestEnv.NewPackage()
    local store = { enabled = false }
    local tree = OptionsKit:Define("Addon", toggleTree(store))
    local changes = 0
    local connection = tree:OnChange(function()
      changes = changes + 1
    end)

    local nextRevision = OptionsKit.REVISION + 1
    local upgraded = TestEnv.LoadRevision(nextRevision)
    assert.are.equal(OptionsKit, upgraded)
    assert.are.equal(nextRevision, upgraded.REVISION)
    assert.are.equal(tree, upgraded:Get("Addon"))

    -- The tree built by the older copy is served by the newer copy's methods.
    assert.are.equal(upgraded.Tree.Set, tree.Set)
    assert.is_true(tree:Set("enabled", true))
    assert.is_true(store.enabled)
    assert.are.equal(1, changes)
    assert.is_true(connection:IsConnected())
    assert.are.equal(1, tree:Walk(function() end))
  end)

  it("upgrades a revision 1 layout: the profile group map and each tree's link list", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    require("Registry")
    require("SignalKit")
    require("SchemaKit")
    local OptionsKit = TestEnv.LoadRevision(1)
    local tree = OptionsKit:Define("Addon", toggleTree({}))
    local state = rawget(OptionsKit, "_state")
    -- Strip what revision 1 never had.
    rawset(state, "profileGroups", nil)
    rawset(tree, "_profileLinks", nil)
    rawset(tree, "_schema", 1)

    -- The shipped file, at its own revision, loads over revision 1.
    local upgraded = require("OptionsKit")
    assert.are.equal(OptionsKit, upgraded)
    assert.is_true(upgraded.REVISION > 1)
    local groups = rawget(state, "profileGroups")
    assert.are.equal("table", type(groups))
    assert.are.equal("k", getmetatable(groups).__mode)
    assert.are.equal(2, rawget(tree, "_schema"))
    assert.are.same({}, rawget(tree, "_profileLinks"))
    assert.is_true(upgraded:Undefine("Addon"))
  end)

  it("upgrades a revision 2 state in place and keeps its profile groups attached", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    require("Registry")
    require("SignalKit")
    require("SchemaKit")
    local OptionsKit = TestEnv.LoadRevision(2)
    local SettingsKit = require("SettingsKit")
    local S = require("SchemaKit")
    local db = SettingsKit:Open(PROFILE_SAVED_VARIABLE, {
      profile = S.table({ fields = { scale = S.optional(S.number(), 1) } }),
    })
    local group = OptionsKit:ProfileOptions(db)
    local tree = OptionsKit:Define("Addon", { type = "group", args = { profiles = group } })

    local upgraded = require("OptionsKit")
    assert.are.equal(OptionsKit, upgraded)
    assert.is_true(upgraded.REVISION > 2)
    assert.are.equal(tree, upgraded:Get("Addon"))
    assert.are.equal(2, rawget(tree, "_schema"))

    -- The link made under revision 2 still reaches the tree.
    local changes = {}
    tree:OnChange(function(_, path, value)
      changes[#changes + 1] = { path, value }
    end)
    db:SetProfile("Raid")
    assert.are.same({ { "profiles.current", "Raid" } }, changes)

    -- Undefine under the new revision frees the group for another tree.
    assert.is_true(upgraded:Undefine("Addon"))
    local again = upgraded:Define("Again", { type = "group", args = { profiles = group } })
    assert.are.equal("Raid", again:Get("profiles.current"))
  end)

  it("upgrades a revision 3 state in place: same facade, state and trees", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    require("Registry")
    require("SignalKit")
    require("SchemaKit")
    local OptionsKit = TestEnv.LoadRevision(3)
    local state = rawget(OptionsKit, "_state")
    local store = { enabled = false }
    local tree = OptionsKit:Define("Addon", toggleTree(store))
    local changes = 0
    tree:OnChange(function()
      changes = changes + 1
    end)

    -- The shipped file, at its own revision, loads over revision 3.
    local upgraded = require("OptionsKit")
    assert.are.equal(OptionsKit, upgraded)
    assert.is_true(upgraded.REVISION > 3)
    assert.are.equal(state, rawget(upgraded, "_state"))
    assert.are.equal(tree, upgraded:Get("Addon"))
    assert.are.equal(2, rawget(tree, "_schema"))
    assert.is_true(tree:Set("enabled", true))
    assert.is_true(store.enabled)
    assert.are.equal(1, changes)
  end)

  it("upgrades a revision 4 state in place and answers its predicates secret-aware", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    require("Registry")
    require("SignalKit")
    require("SchemaKit")
    local OptionsKit = TestEnv.LoadRevision(4)
    local state = rawget(OptionsKit, "_state")
    local store = { enabled = false }
    local spec = toggleTree(store)
    local answer = {}
    spec.args.enabled.disabled = function()
      return answer
    end
    local tree = OptionsKit:Define("Addon", spec)

    -- The shipped file, at its own revision, loads over revision 4.
    local upgraded = require("OptionsKit")
    assert.are.equal(OptionsKit, upgraded)
    assert.is_true(upgraded.REVISION > 4)
    assert.are.equal(state, rawget(upgraded, "_state"))
    assert.are.equal(tree, upgraded:Get("Addon"))
    assert.is_true(tree:IsDisabled("enabled"))
    -- The predicate revision 4 recorded now answers through the shipped
    -- implementation, which counts a secret answer as "no".
    -- selene: allow(global_usage)
    rawset(_G, "issecretvalue", function(value)
      return rawequal(value, answer)
    end)
    assert.is_false(tree:IsDisabled("enabled"))
    -- selene: allow(global_usage)
    rawset(_G, "issecretvalue", nil)
    assert.is_true(tree:Set("enabled", true))
    assert.is_true(store.enabled)
  end)

  it("upgrades a revision 5 state in place and keeps its trees", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    require("Registry")
    require("SignalKit")
    require("SchemaKit")
    local OptionsKit = TestEnv.LoadRevision(5)
    local state = rawget(OptionsKit, "_state")
    local store = { enabled = false }
    local tree = OptionsKit:Define("Addon", toggleTree(store))

    -- The shipped file, at its own revision, loads over revision 5.
    local upgraded = require("OptionsKit")
    assert.are.equal(OptionsKit, upgraded)
    assert.is_true(upgraded.REVISION > 5)
    assert.are.equal(state, rawget(upgraded, "_state"))
    assert.are.equal(tree, upgraded:Get("Addon"))
    assert.is_true(tree:Set("enabled", true))
    assert.is_true(store.enabled)
  end)

  it("upgrades a revision 6 state in place and serves its record layout", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    require("Registry")
    require("SignalKit")
    require("SchemaKit")
    local OptionsKit = TestEnv.LoadRevision(6)
    local store = { enabled = false }
    local tree = OptionsKit:Define("Addon", toggleTree(store))
    -- Revision 6 built every record with its `info`, a prebuilt `Set`
    -- label, `false` for absent fields and hints of its own, and kept the
    -- tree on no record. The working file loaded as revision 6 builds the
    -- new layout, so the old one is laid over it here.
    local oldInfo = { path = "enabled", kind = "toggle", tree = tree }
    oldInfo[1] = "enabled"
    local record = rawget(rawget(tree, "_records"), "enabled")
    rawset(record, "_info", oldInfo)
    rawset(record, "_setArgument", "OptionsKit.Tree:Set enabled")
    rawset(record, "_validate", false)
    rawset(record, "_desc", false)
    rawset(record, "_disabled", false)
    rawset(record, "_hidden", false)
    rawset(record, "_hints", {})
    local root = rawget(tree, "_root")
    rawset(root, "_tree", nil)
    rawset(root, "_info", { path = "", kind = "group", tree = tree })

    -- The shipped file, at its own revision, loads over revision 6.
    local upgraded = require("OptionsKit")
    assert.are.equal(OptionsKit, upgraded)
    assert.is_true(upgraded.REVISION > 6)
    assert.are.equal(tree, upgraded:Get("Addon"))
    assert.is_true(tree:Set("enabled", true))
    assert.is_true(store.enabled)
    assert.is_false(tree:IsDisabled("enabled"))
    assert.are.same(tree:Describe().children[1], tree:DescribeOption("enabled"))
    assert.are.equal(oldInfo, rawget(record, "_info"))
    TestEnv.expectErrorContaining(
      "OptionsKit.Tree:Set enabled: expected boolean, found string",
      function()
        tree:Set("enabled", "yes")
      end
    )
  end)

  it("upgrades a revision 7 state: old groups keep working, new calls are cached", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    require("Registry")
    require("SignalKit")
    require("SchemaKit")
    local OptionsKit = TestEnv.LoadRevision(7)
    local SettingsKit = require("SettingsKit")
    local S = require("SchemaKit")
    local db = SettingsKit:Open(PROFILE_SAVED_VARIABLE, {
      profile = S.table({ fields = { scale = S.optional(S.number(), 1) } }),
    })
    local oldGroup = OptionsKit:ProfileOptions(db)
    local tree = OptionsKit:Define("Addon", { type = "group", args = { profiles = oldGroup } })
    local state = rawget(OptionsKit, "_state")
    -- Revision 7 had no group cache.
    rawset(state, "profileLinksByDatabase", nil)

    -- The shipped file, at its own revision, loads over revision 7.
    local upgraded = require("OptionsKit")
    assert.are.equal(OptionsKit, upgraded)
    assert.is_true(upgraded.REVISION > 7)
    assert.are.equal(state, rawget(upgraded, "_state"))
    local cache = rawget(state, "profileLinksByDatabase")
    assert.are.equal("table", type(cache))
    assert.are.equal("k", getmetatable(cache).__mode)

    -- The group revision 7 built still reaches its tree.
    local changes = {}
    tree:OnChange(function(_, path, value)
      changes[#changes + 1] = { path, value }
    end)
    db:SetProfile("Raid")
    assert.are.same({ { "profiles.current", "Raid" } }, changes)

    -- It is not in the cache: the first call after the upgrade builds the
    -- group every later call returns.
    local cached = upgraded:ProfileOptions(db)
    assert.are_not.equal(oldGroup, cached)
    assert.are.equal(cached, upgraded:ProfileOptions(db))
    assert.is_true(upgraded:Undefine("Addon"))
    local again = upgraded:Define("Again", { type = "group", args = { profiles = cached } })
    assert.are.equal("Raid", again:Get("profiles.current"))
  end)

  it("requires Registry", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    local ok, value = pcall(require, "OptionsKit")
    assert.is_false(ok)
    assert.is_truthy(tostring(value):find("requires Registry API 2", 1, true))
  end)

  it("requires SchemaKit", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    require("Registry")
    require("SignalKit")
    local ok, value = pcall(TestEnv.requireAfterFailedLoad, "OptionsKit")
    assert.is_false(ok)
    assert.is_truthy(tostring(value):find("requires SchemaKit API 1", 1, true))
  end)

  it("requires SignalKit", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    require("Registry")
    require("SchemaKit")
    local ok, value = pcall(TestEnv.requireAfterFailedLoad, "OptionsKit")
    assert.is_false(ok)
    assert.is_truthy(tostring(value):find("requires SignalKit API 1", 1, true))
  end)

  it("refuses an incomplete facade left by an earlier failed load", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    local Registry = require("Registry")
    require("SignalKit")
    require("SchemaKit")
    Registry:Register("optionsKit", 1, 1)

    local ok, value = pcall(TestEnv.requireAfterFailedLoad, "OptionsKit")
    assert.is_false(ok)
    assert.is_truthy(tostring(value):find("MoltenCodes OptionsKit", 1, true))
  end)
end)
