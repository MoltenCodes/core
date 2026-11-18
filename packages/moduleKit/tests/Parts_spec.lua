-- ModuleKit's parts (docs/API.md, "Parts"): Injection, Implements and
-- RequiredAddons. Without a part its members stay as stubs that raise at the
-- caller's line naming the file to embed, the definition fields it serves are
-- refused the same way, and everything else of the core works. With it, the
-- part's members serve; a part loaded once serves every addon.

local TestEnv = require("ModuleKitTestEnv")
local expectCallerError = TestEnv.expectCallerError

---The stub message for `label`, a member or field of `partName`.
---@param label string
---@param partName string
---@return string
local function partMessage(label, partName)
  return label
    .. " is in ModuleKit's "
    .. partName
    .. " part, which is not loaded: add moduleKit\\parts\\ModuleKit-"
    .. partName
    .. ".lua to embeds.xml after moduleKit\\ModuleKit.lua"
end

describe("ModuleKit parts", function()
  after_each(TestEnv.Reset)

  it("answers HasPart for each part, loaded or not", function()
    local core = TestEnv.NewCore()
    assert.is_false(core:HasPart("Injection"))
    assert.is_false(core:HasPart("Implements"))
    assert.is_false(core:HasPart("RequiredAddons"))
    assert.is_false(core:HasPart("Graph"))

    local ModuleKit = TestEnv.NewPackage()
    assert.is_true(ModuleKit:HasPart("Injection"))
    assert.is_true(ModuleKit:HasPart("Implements"))
    assert.is_true(ModuleKit:HasPart("RequiredAddons"))
  end)

  it(
    "refuses a HasPart name that is not a string, and a foreign receiver, at the caller's line",
    function()
      local ModuleKit = TestEnv.NewCore()
      expectCallerError("ModuleKit:HasPart name must be a part name string", function()
        ModuleKit:HasPart(1)
      end)
      expectCallerError("ModuleKit:HasPart must be called on the ModuleKit facade", function()
        ModuleKit.HasPart("Injection")
      end)
    end
  )

  it("keeps every member of a missing part as a stub that raises at the caller's line", function()
    local ModuleKit = TestEnv.NewCore()
    local addon = ModuleKit:ForAddon("MyAddon")
    local module = addon:CreateModule("UI")
    local function factory()
      return {}
    end

    expectCallerError(partMessage("ModuleKit.Addon:ProvideValue", "Injection"), function()
      addon:ProvideValue("Settings", {})
    end)
    expectCallerError(partMessage("ModuleKit.Addon:ProvideSingleton", "Injection"), function()
      addon:ProvideSingleton("Database", factory)
    end)
    expectCallerError(partMessage("ModuleKit.Addon:ProvideModule", "Injection"), function()
      addon:ProvideModule("Logger", factory)
    end)
    expectCallerError(partMessage("ModuleKit.Addon:ProvideTransient", "Injection"), function()
      addon:ProvideTransient("Builder", factory)
    end)
    expectCallerError(partMessage("ModuleKit.Addon:Resolve", "Injection"), function()
      addon:Resolve("Settings")
    end)
    expectCallerError(partMessage("ModuleKit.Module:Resolve", "Injection"), function()
      module:Resolve("Settings")
    end)
    expectCallerError(partMessage("ModuleKit.Module:Inject", "Injection"), function()
      module:Inject("database", "Database")
    end)
  end)

  it("refuses each part's definition field at the caller's line and creates nothing", function()
    local ModuleKit = TestEnv.NewCore()
    local addon = ModuleKit:ForAddon("MyAddon")

    expectCallerError(
      partMessage('ModuleKit.Addon:CreateModule definition field "inject"', "Injection"),
      function()
        addon:CreateModule("Injected", { inject = { database = "Database" } })
      end
    )
    expectCallerError(
      partMessage('ModuleKit.Addon:CreateModule definition field "implements"', "Implements"),
      function()
        addon:CreateModule("Checked", { implements = { "OnEnable" } })
      end
    )
    expectCallerError(
      partMessage(
        'ModuleKit.Addon:CreateModule definition field "requiresAddons"',
        "RequiredAddons"
      ),
      function()
        addon:CreateModule("Needy", { requiresAddons = { "OtherAddon" } })
      end
    )
    assert.is_false(addon:HasModule("Injected"))
    assert.is_false(addon:HasModule("Checked"))
    assert.is_false(addon:HasModule("Needy"))
  end)

  it("refuses a provider's implements option without the Implements part", function()
    TestEnv.NewCore()
    local ModuleKit = TestEnv.LoadParts({ "Injection" })
    local addon = ModuleKit:ForAddon("MyAddon")

    expectCallerError(
      partMessage('ModuleKit.Addon:ProvideValue options field "implements"', "Implements"),
      function()
        addon:ProvideValue("Settings", {}, { implements = { "Save" } })
      end
    )
    addon:ProvideValue("Plain", { scale = 1 })
    assert.are.same({ scale = 1 }, addon:Resolve("Plain"))
  end)

  it("hands every hook an empty injection table of its own without the Injection part", function()
    local ModuleKit = TestEnv.NewCore()
    local addon = ModuleKit:ForAddon("MyAddon")
    local received = {}
    addon:CreateModule("First", {
      onInitialize = function(_, injections)
        received[#received + 1] = injections
      end,
    })
    addon:CreateModule("Second", {
      onInitialize = function(_, injections)
        received[#received + 1] = injections
      end,
    })

    TestEnv.LoadAddon("MyAddon")

    assert.are.equal(2, #received)
    assert.are.same({}, received[1])
    assert.are_not.equal(received[1], received[2])
    assert.are.same({}, addon:GetModule("First"):GetInjections())
    assert.are.same({}, TestEnv.ReportedErrors())
  end)

  it("takes every module down when the container's own addon halts, with no part loaded", function()
    local ModuleKit, _, _, _, LifecycleKit = TestEnv.NewCore()
    local addon = ModuleKit:ForAddon("MyAddon")
    local module = addon:CreateModule("UI", { onEnable = function() end })
    TestEnv.LoadAddon("MyAddon")
    TestEnv.Login()
    assert.is_true(module:IsEnabled())

    LifecycleKit:ForAddon("MyAddon"):Halt("broken")

    assert.are.same(
      { wanted = true, actual = false, blockedBy = "halted" },
      module:GetEnableState()
    )
  end)

  it(
    "keeps maxRequiredAddons and its LifecycleKit ceiling without the RequiredAddons part",
    function()
      local ModuleKit, _, _, _, LifecycleKit = TestEnv.NewCore()
      LifecycleKit:SetLimits({ maxDependencies = 8 })

      ModuleKit:SetLimits({ maxRequiredAddons = 8 })
      assert.are.equal(8, ModuleKit:GetLimits().maxRequiredAddons)
      expectCallerError(
        "ModuleKit:SetLimits limits.maxRequiredAddons must be an integer from 1 to 8, LifecycleKit's maxDependencies",
        function()
          ModuleKit:SetLimits({ maxRequiredAddons = 9 })
        end
      )
      expectCallerError("cannot be ModuleKit.UNBOUNDED: LifecycleKit accepts at most 8", function()
        ModuleKit:SetLimits({ maxRequiredAddons = ModuleKit.UNBOUNDED })
      end)
      assert.are.equal(8, ModuleKit:GetLimits().maxRequiredAddons)
    end
  )
end)

describe("ModuleKit part loading", function()
  after_each(TestEnv.Reset)

  it("refuses to load a part without ModuleKit's core, naming it", function()
    TestEnv.LoadDependencies()
    for _, partName in ipairs({ "Injection", "Implements", "RequiredAddons" }) do
      TestEnv.expectErrorContaining(
        "MoltenCodes ModuleKit part " .. partName .. " requires ModuleKit API 1 to be loaded first",
        function()
          require("ModuleKit-" .. partName)
        end
      )
      package.loaded["ModuleKit-" .. partName] = nil
    end
  end)

  it("refuses the RequiredAddons part when LifecycleKit says its Halt part is missing", function()
    local _, _, _, _, LifecycleKit = TestEnv.NewCore()
    rawset(LifecycleKit, "HasPart", function(_, name)
      return name ~= "Halt"
    end)

    TestEnv.expectErrorContaining("requires LifecycleKit's Halt part to be loaded first", function()
      require("ModuleKit-RequiredAddons")
    end)
    rawset(LifecycleKit, "HasPart", nil)
  end)

  it("keeps the installed part when the same revision loads again", function()
    local ModuleKit = TestEnv.NewPackage()
    local provideValue = rawget(ModuleKit.Addon, "ProvideValue")
    local record = rawget(rawget(rawget(ModuleKit, "_state"), "parts"), "Injection")

    package.loaded["ModuleKit-Injection"] = nil
    assert.are.equal(ModuleKit, require("ModuleKit-Injection"))

    assert.are.equal(provideValue, rawget(ModuleKit.Addon, "ProvideValue"))
    assert.are.equal(record, rawget(rawget(rawget(ModuleKit, "_state"), "parts"), "Injection"))
  end)

  it("keeps a loaded part's members and entries when a newer core takes over", function()
    local ModuleKit = TestEnv.NewPackage()
    local addon = ModuleKit:ForAddon("MyAddon")
    addon:ProvideValue("Settings", { scale = 1 })
    local resolveForHook = rawget(rawget(rawget(ModuleKit, "_state"), "dispatch"), "resolveForHook")

    local upgraded = TestEnv.LoadRevision(ModuleKit.REVISION + 1)

    assert.are.equal(ModuleKit, upgraded)
    assert.is_true(upgraded:HasPart("Injection"))
    assert.are.same({ scale = 1 }, addon:Resolve("Settings"))
    assert.are.equal(
      resolveForHook,
      rawget(rawget(rawget(ModuleKit, "_state"), "dispatch"), "resolveForHook")
    )
    local module = addon:CreateModule("UI", { inject = { settings = "Settings" } })
    TestEnv.LoadAddon("MyAddon")
    assert.are.same({ scale = 1 }, module:GetInjections().settings)
  end)

  it("serves modules made with a prototype through the part's members", function()
    TestEnv.NewCore()
    local ModuleKit = TestEnv.LoadParts({ "Injection" })
    local addon = ModuleKit:ForAddon("MyAddon")
    addon:ProvideValue("Settings", { scale = 1 })
    local module = addon:CreateModule("UI", { prototype = { kind = "shared" } })

    assert.are.same({ scale = 1 }, module:Resolve("Settings"))
  end)

  it("gives prototype modules the part's members when the part loads after them", function()
    local ModuleKit = TestEnv.NewCore()
    local addon = ModuleKit:ForAddon("MyAddon")
    local module = addon:CreateModule("UI", { prototype = { kind = "shared" } })

    TestEnv.LoadParts({ "Injection" })
    addon:ProvideValue("Settings", { scale = 1 })

    assert.are.same({ scale = 1 }, module:Resolve("Settings"))
  end)
end)
