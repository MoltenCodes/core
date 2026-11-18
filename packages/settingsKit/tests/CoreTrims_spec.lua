local TestEnv = require("SettingsKitTestEnv")

---Count the keys of a table.
---@param container table
---@return integer
local function countKeys(container)
  local count = 0
  for _ in pairs(container) do
    count = count + 1
  end
  return count
end

-- Revision 16 trims the core: sparse plans (layout 3), no depth probes for
-- an older SchemaKit, and the shared helper blocks.
describe("SettingsKit core trims", function()
  local SettingsKit, S

  before_each(function()
    local loaded = { TestEnv.NewPackage() }
    SettingsKit, S = loaded[1], loaded[5]
  end)

  after_each(TestEnv.Reset)

  local function schema()
    return {
      profile = S.table({
        fields = {
          scale = S.optional(S.number({ min = 0.5, max = 2 }), 1),
          name = S.optional(S.string()),
          frame = S.optional(
            S.table({ fields = { x = S.optional(S.number({ integer = true }), 0) } }),
            {}
          ),
          auras = S.optional(S.map({ keys = S.number(), values = S.boolean(), max = 4 }), {}),
        },
      }),
    }
  end

  describe("sparse plans", function()
    it("holds only the fields a plan uses and the bounds a field declares", function()
      local db = SettingsKit:Open("MyAddonDB", schema())
      local plan = rawget(db, "_scopes").profile.plan
      assert.are.equal(3, plan.layout)
      local scalePlan = plan.fields.scale
      assert.is_true(countKeys(scalePlan) <= 4)
      assert.is_nil(scalePlan.fieldNames)
      assert.is_nil(scalePlan.values)
      assert.is_nil(scalePlan.keyKind)
      assert.is_false(scalePlan.proxied)

      local scaleCheck = plan.fastChecks.scale
      assert.is_true(countKeys(scaleCheck) <= 4)
      assert.are.same({ kind = "number", min = 0.5, max = 2 }, scaleCheck)
      assert.are.same({ kind = "string" }, plan.fastChecks.name)

      local auras = plan.fields.auras
      assert.are.equal("map", auras.proxied)
      assert.is_nil(auras.fieldNames)
      assert.are.equal("number", auras.keyKind)
    end)

    it("reads and writes layout 2 plans revision 15 compiled, after the upgrade", function()
      TestEnv.Reset()
      TestEnv.InstallWowApi()
      require("Registry")
      require("SignalKit")
      require("EventKit")
      S = require("SchemaKit")
      require("SchemaKit-Rules")
      local previous = TestEnv.LoadRevision(15)
      TestEnv.SetPlayer()
      local db = previous:Open("MyAddonDB", schema())
      local plan = rawget(db, "_scopes").profile.plan
      assert.are.equal(2, plan.layout)
      assert.is_false(plan.fields.scale.fieldNames)

      local current = TestEnv.ReloadPackage()
      assert.are.equal(16, current.REVISION)
      assert.are.equal(plan, rawget(db, "_scopes").profile.plan)
      db.profile.scale = 1.5
      db.profile.frame.x = 3
      db.profile.auras[7] = true
      local ok = pcall(function()
        db.profile.scale = 5
      end)
      assert.is_false(ok)
      ok = pcall(function()
        db.profile.frame.x = 1.5
      end)
      assert.is_false(ok)
      assert.are.equal(1.5, db.profile.scale)
      db.profile.frame.x = 0
      db:Compact()
      local saved = TestEnv.GetGlobal("MyAddonDB").profiles.Default
      assert.is_nil(saved.frame)
      assert.are.equal(1.5, saved.scale)
    end)
  end)

  describe("the depth rule", function()
    it("refuses a write deeper than SchemaKit's maxDepth through GetLimit", function()
      local db = SettingsKit:Open("MyAddonDB", schema())
      local frame = db.profile.frame
      frame.x = 1
      S:SetLimits({ maxDepth = 1 })
      local ok, message = pcall(function()
        frame.x = 2
      end)
      assert.is_false(ok)
      assert.is_truthy(tostring(message):find("nested tables", 1, true))
      S:SetLimits({ maxDepth = 16 })
    end)

    it("leaves the depth to SchemaKit's full check when SchemaKit has no GetLimit", function()
      local db = SettingsKit:Open("MyAddonDB", schema())
      local frame = db.profile.frame
      frame.x = 1
      local getLimit = S.GetLimit
      rawset(S, "GetLimit", nil)
      S:SetLimits({ maxDepth = 1 })
      local ok, message = pcall(function()
        frame.x = 2
      end)
      assert.is_false(ok)
      assert.is_truthy(tostring(message):find("nested tables", 1, true))
      S:SetLimits({ maxDepth = 16 })
      frame.x = 3
      assert.are.equal(3, frame.x)
      rawset(S, "GetLimit", getLimit)
    end)

    it("holds no depth probes any more", function()
      local db = SettingsKit:Open("MyAddonDB", schema())
      db.profile.frame.x = 1
      assert.is_nil(rawget(SettingsKit._state, "depthProbes"))
    end)
  end)

  describe("shared helper blocks", function()
    it("prints a logout failure when the host error handler raises", function()
      local db = SettingsKit:Open("MyAddonDB", schema())
      db.profile.scale = 1
      TestEnv.SetGlobal("geterrorhandler", function()
        return function()
          error("the error display failed", 0)
        end
      end)
      local printed = {}
      local originalPrint = TestEnv.GetGlobal("print")
      TestEnv.SetGlobal("print", function(value)
        printed[#printed + 1] = value
      end)
      TestEnv.SetGlobal("issecretvalue", function()
        error("probe failed", 0)
      end)
      local ok = pcall(TestEnv.Logout)
      TestEnv.SetGlobal("print", originalPrint)
      assert.is_true(ok)
      assert.are.equal(1, #printed)
      assert.is_truthy(tostring(printed[1]):find("probe failed", 1, true))
    end)

    it("names the limits it accepts when a name is unknown", function()
      local ok, message = pcall(SettingsKit.SetLimits, SettingsKit, { maxDepth = 8 })
      assert.is_false(ok)
      assert.is_truthy(
        tostring(message):find(
          "SettingsKit:SetLimits limits.maxDepth is not a recognised limit;"
            .. " it accepts maxProfileNameLength, pathKeyLimit",
          1,
          true
        )
      )
      ok, message =
        pcall(SettingsKit.SetLimits, SettingsKit, { pathKeyLimit = SettingsKit.UNBOUNDED })
      assert.is_false(ok)
      assert.is_truthy(
        tostring(message):find(
          "SettingsKit:SetLimits limits.pathKeyLimit cannot be SettingsKit.UNBOUNDED: paths show keys",
          1,
          true
        )
      )
    end)

    it("names a dot call with the usage hint", function()
      local ok, message = pcall(SettingsKit.GetLimits, {})
      assert.is_false(ok)
      assert.is_truthy(
        tostring(message):find(
          "SettingsKit:GetLimits must be called on the SettingsKit facade; use SettingsKit:GetLimits(...)",
          1,
          true
        )
      )
    end)
  end)
end)
