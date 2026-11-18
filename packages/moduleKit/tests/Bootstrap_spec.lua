local TestEnv = require("ModuleKitTestEnv")

---The implementation revision the manifest declares, which the source under
---test must register as.
---@return integer revision
local function manifestRevision()
  local file = assert(io.open("packages/moduleKit/package.manifest.json", "r"))
  local text = file:read("*a")
  file:close()
  return assert(tonumber(text:match('"revision"%s*:%s*(%d+)')))
end

local CURRENT_REVISION = manifestRevision()

describe("ModuleKit bootstrap", function()
  after_each(TestEnv.Reset)

  it("reuses the shared facade on duplicate load", function()
    local ModuleKit = TestEnv.NewPackage()
    local addon = ModuleKit:ForAddon("MyAddon")
    local reloaded = TestEnv.ReloadPackage()

    assert.are.equal(ModuleKit, reloaded)
    assert.are.equal(addon, reloaded:ForAddon("MyAddon"))
  end)

  it("publishes through Registry under moduleKit API 1", function()
    local ModuleKit, Registry = TestEnv.NewPackage()
    local registered, revision = Registry:Get("moduleKit", 1)

    assert.are.equal(ModuleKit, registered)
    assert.are.equal(ModuleKit.REVISION, revision)
  end)

  it("requires LifecycleKit", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    require("Registry")

    assert.has_error(function()
      require("ModuleKit")
    end)
  end)

  it("routes existing lifecycle subscriptions through shared runtime dispatch", function()
    local ModuleKit = TestEnv.NewPackage()
    ModuleKit:ForAddon("MyAddon")
    local state = rawget(ModuleKit, "_state")
    local dispatch = rawget(state, "dispatch")
    local original = rawget(dispatch, "initializeAll")
    local calls = 0

    rawset(dispatch, "initializeAll", function(addon)
      calls = calls + 1
      return addon
    end)

    TestEnv.LoadAddon("MyAddon")
    rawset(dispatch, "initializeAll", original)

    assert.are.equal(1, calls)
  end)

  it("repairs shared runtime dispatch on a same-revision reload", function()
    local ModuleKit = TestEnv.NewPackage()
    local state = rawget(ModuleKit, "_state")
    local dispatch = rawget(state, "dispatch")
    rawset(dispatch, "shutdown", nil)

    local reloaded = TestEnv.ReloadPackage()

    assert.are.equal(ModuleKit, reloaded)
    assert.is_true(type(rawget(rawget(state, "dispatch"), "shutdown")) == "function")
  end)

  -- The upgrade floor: no revision was ever published, so only the state
  -- revision 23 left is taken over. An older copy's state is refused whole
  -- rather than half-converted.
  it("refuses to take over the state of a revision older than 23", function()
    TestEnv.LoadDependencies()
    local Registry = require("Registry")
    local previous = assert(Registry:Register("moduleKit", 1, 13))
    rawset(previous, "API", 1)
    rawset(previous, "REVISION", 13)
    rawset(previous, "Addon", {})
    rawset(previous, "Module", {})
    rawset(previous, "_state", { schema = 1, addons = {}, dispatch = {}, runtimeRevision = 13 })

    package.loaded["ModuleKit"] = nil
    TestEnv.expectErrorContaining(
      "cannot take over the state of revision 13 in place; revision 23 is the oldest it upgrades",
      function()
        require("ModuleKit")
      end
    )
  end)
end)

-- An in-place upgrade keeps the lifecycle subscriptions of containers that
-- already exist: they reach the shared dispatch, so the new revision serves
-- them. Subscribing again would replay `ready` and re-enable modules the
-- addon had deliberately switched off.
describe("ModuleKit in-place upgrade", function()
  local function newDisabledModuleFixture()
    local ModuleKit = TestEnv.NewPackage()
    local addon = ModuleKit:ForAddon("MyAddon")
    local module = addon:CreateModule("UI")
    local hooks = {}

    module.OnInitialize = function()
      hooks[#hooks + 1] = "initialize"
    end
    module.OnEnable = function()
      hooks[#hooks + 1] = "enable"
    end
    module.OnDisable = function()
      hooks[#hooks + 1] = "disable"
    end

    TestEnv.LoadAddon("MyAddon")
    TestEnv.Login()
    module:Disable()

    return ModuleKit, addon, module, hooks
  end

  --- Make the shared state look like it was left by an earlier revision.
  local function markStateAsOlderRevision(ModuleKit)
    local state = rawget(ModuleKit, "_state")
    rawset(state, "runtimeRevision", ModuleKit.REVISION - 1)
  end

  after_each(TestEnv.Reset)

  it("keeps a deliberately disabled module disabled", function()
    local ModuleKit, addon, module, hooks = newDisabledModuleFixture()
    assert.are.same({ "initialize", "enable", "disable" }, hooks)

    markStateAsOlderRevision(ModuleKit)
    local upgraded = TestEnv.ReloadPackage()

    assert.are.equal(ModuleKit, upgraded)
    assert.are.equal(addon, upgraded:ForAddon("MyAddon"))
    assert.are.equal("disabled", module:GetState())
    assert.are.same({ "initialize", "enable", "disable" }, hooks)
  end)
end)

describe("ModuleKit limits across an in-place upgrade", function()
  after_each(TestEnv.Reset)

  it("registers itself as ModuleKit API 1 at the manifest revision", function()
    local ModuleKit, Registry = TestEnv.NewPackage()
    local _, revision = Registry:Get("moduleKit", 1)

    assert.are.equal(CURRENT_REVISION, ModuleKit.REVISION)
    assert.are.equal(CURRENT_REVISION, revision)
  end)

  it("keeps set limits and the sentinel when a newer revision loads", function()
    local ModuleKit = TestEnv.NewPackage()
    local sentinel = ModuleKit.UNBOUNDED
    ModuleKit:SetLimits({ maxRequiredAddons = 5 })

    local nextRevision = ModuleKit.REVISION + 1
    local upgraded = TestEnv.LoadRevision(nextRevision)

    assert.are.equal(ModuleKit, upgraded)
    assert.are.equal(nextRevision, upgraded.REVISION)
    assert.are.equal(sentinel, upgraded.UNBOUNDED)
    assert.are.equal(5, upgraded:GetLimits().maxRequiredAddons)
  end)

  it("keeps ModuleKit.UNBOUNDED as a set limit when a newer revision loads", function()
    local ModuleKit, _, _, _, LifecycleKit = TestEnv.NewPackage()
    rawset(LifecycleKit, "GetLimits", nil)
    ModuleKit:SetLimits({ maxRequiredAddons = ModuleKit.UNBOUNDED })

    local upgraded = TestEnv.LoadRevision(ModuleKit.REVISION + 1)

    assert.are.equal(ModuleKit.UNBOUNDED, upgraded:GetLimits().maxRequiredAddons)
  end)

  it("leaves a newer revision's limits alone when an older copy loads after it", function()
    TestEnv.LoadDependencies()
    local newer = TestEnv.LoadRevision(17)
    newer:SetLimits({ maxRequiredAddons = 3 })

    local selected = TestEnv.LoadRevision(16)

    assert.are.equal(newer, selected)
    assert.are.equal(17, selected.REVISION)
    assert.are.equal(3, selected:GetLimits().maxRequiredAddons)
  end)

  it("refuses to inherit corrupted limits", function()
    local ModuleKit = TestEnv.NewPackage()
    local state = rawget(ModuleKit, "_state")
    rawset(rawget(state, "limits"), "maxRequiredAddons", 0)
    rawset(state, "runtimeRevision", ModuleKit.REVISION - 1)

    TestEnv.expectErrorContaining("package state is corrupted or incomplete", function()
      TestEnv.requireAfterFailedLoad("ModuleKit")
    end)
  end)
end)

-- The contract lives on the provider record, so a record this revision
-- registered keeps its contract when a newer copy takes over.
describe("ModuleKit implements across an in-place upgrade", function()
  after_each(TestEnv.Reset)

  it("keeps a provider's contract when a newer revision loads", function()
    local ModuleKit = TestEnv.NewPackage()
    local addon = ModuleKit:ForAddon("MyAddon")
    addon:ProvideSingleton("Database", function()
      return {}
    end, { implements = { "Save" } })

    local nextRevision = ModuleKit.REVISION + 1
    local upgraded = TestEnv.LoadRevision(nextRevision)

    assert.are.equal(ModuleKit, upgraded)
    assert.are.equal(nextRevision, upgraded.REVISION)
    TestEnv.expectErrorContaining('provider "Database" must implement "Save"', function()
      upgraded:ForAddon("MyAddon"):Resolve("Database")
    end)
  end)
end)

-- Revision 24 split injection, implements contracts and required addons into
-- parts. What revision 23 made lives in containers and modules, so the parts
-- take it over in place; with a part absent its members raise the stub
-- message, and state it would serve is left in place and reported once.
describe("ModuleKit upgrade from revision 23", function()
  after_each(TestEnv.Reset)

  ---Load revision 23's file over the dependencies and make a container with
  ---a resolved singleton, a contract, a module that injects and one that
  ---requires another addon.
  local function seedRevision23()
    TestEnv.LoadDependencies()
    local previous = TestEnv.LoadRevision23()
    assert.are.equal(23, previous.REVISION)
    local addon = previous:ForAddon("MyAddon")
    local created = 0
    addon:ProvideSingleton("Database", function()
      created = created + 1
      return { Save = function() end }
    end, { implements = { "Save" } })
    addon:ProvideValue("Settings", { scale = 1 })
    assert.is_table(addon:Resolve("Database"))
    local consumer = addon:CreateModule("Consumer", { inject = { database = "Database" } })
    local needy = addon:CreateModule("Needy", { requiresAddons = { "OtherAddon" } })
    addon:SetDependencyPolicy("strict")
    previous:SetLimits({ maxRequiredAddons = 6 })
    return previous, addon, consumer, needy, function()
      return created
    end
  end

  it(
    "keeps the facade, the state, containers, providers and limits with the parts loaded",
    function()
      local previous, addon, consumer, needy, createdCount = seedRevision23()
      local state = rawget(previous, "_state")

      local upgraded = require("ModuleKit")
      TestEnv.LoadParts()

      assert.are.equal(previous, upgraded)
      assert.are.equal(state, rawget(upgraded, "_state"))
      assert.are.equal(CURRENT_REVISION, upgraded.REVISION)
      assert.are.equal(addon, upgraded:ForAddon("MyAddon"))
      assert.are.equal(consumer, addon:GetModule("Consumer"))
      assert.are.equal("strict", addon:GetDependencyPolicy())
      assert.are.equal(6, upgraded:GetLimits().maxRequiredAddons)
      -- The singleton revision 23 resolved is served from its record.
      assert.are.equal(addon:Resolve("Database"), addon:Resolve("Database"))
      assert.are.equal(1, createdCount())
      assert.are.same({ scale = 1 }, addon:Resolve("Settings"))

      TestEnv.LoadAddon("MyAddon")
      assert.are.equal(addon:Resolve("Database"), consumer:GetInjections().database)

      -- The required addon's halt reaches the module through the part.
      TestEnv.Login()
      addon:SetDependencyPolicy("automatic")
      needy:Enable()
      assert.is_true(needy:IsEnabled())
      local LifecycleKit = require("LifecycleKit")
      LifecycleKit:ForAddon("OtherAddon"):Halt("broken")
      assert.is_false(needy:IsEnabled())
      assert.are.equal("OtherAddon", needy:GetEnableState().blockedBy)
    end
  )

  it("checks a contract revision 23 compiled when the parts are loaded", function()
    TestEnv.LoadDependencies()
    local previous = TestEnv.LoadRevision23()
    local addon = previous:ForAddon("MyAddon")
    addon:ProvideSingleton("Broken", function()
      return {}
    end, { implements = { "Save" } })

    require("ModuleKit")
    TestEnv.LoadParts()

    TestEnv.expectErrorContaining('provider "Broken" must implement "Save"', function()
      addon:Resolve("Broken")
    end)
  end)

  it("raises the stub message for a part's members when the part is absent", function()
    seedRevision23()

    local upgraded = require("ModuleKit")

    assert.is_false(upgraded:HasPart("Injection"))
    TestEnv.expectCallerError(
      "ModuleKit.Addon:Resolve is in ModuleKit's Injection part, which is not loaded: "
        .. "add moduleKit\\parts\\ModuleKit-Injection.lua to embeds.xml after moduleKit\\ModuleKit.lua",
      function()
        upgraded:ForAddon("MyAddon"):Resolve("Settings")
      end
    )
  end)

  it("leaves unserved state in place and reports it once when a part is absent", function()
    local _, addon, consumer, needy = seedRevision23()

    require("ModuleKit")
    TestEnv.LoadAddon("MyAddon")
    TestEnv.Login()
    addon:SetDependencyPolicy("automatic")

    -- Initialized without the Injection part: an empty table, the aliases kept.
    assert.are.same({}, consumer:GetInjections())
    assert.is_table(rawget(consumer, "_injectSpec"))
    -- Enabled without the RequiredAddons part: the list kept, nothing blocks.
    needy:Enable()
    needy:Disable()
    needy:Enable()
    assert.is_true(needy:IsEnabled())
    assert.are.same({ "OtherAddon" }, rawget(needy, "_requiredAddons"))

    local reports = TestEnv.ReportedErrors()
    local injection, required = 0, 0
    for index = 1, #reports do
      local text = tostring(reports[index])
      if text:find("ModuleKit-Injection.lua", 1, true) then
        injection = injection + 1
      elseif text:find("ModuleKit-RequiredAddons.lua", 1, true) then
        required = required + 1
      end
    end
    assert.are.equal(1, injection)
    assert.are.equal(1, required)
  end)
end)
