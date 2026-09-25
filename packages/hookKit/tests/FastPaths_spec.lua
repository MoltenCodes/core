local TestEnv = require("HookKitTestEnv")

-- Revision 6 makes installing, removing and calling a hook cheaper without
-- changing what they do (docs/INTERNALS.md). These specs pin what each fast
-- path must keep:
--
--   * the secret check asks the host's `issecretvalue` directly when HookKit
--     loaded with one, and still asks ClientKit on a host that had none;
--   * an object's method table stays, empty, after its last hook goes, so a
--     re-hook allocates only its record and closure, and the table still goes
--     with the object;
--   * a replacement reads its record by plain indexing and still maps a missing
--     original to `nil`.

describe("HookKit fast paths", function()
  after_each(TestEnv.Reset)

  local function noop() end

  describe("secret check", function()
    ---Count the `Registry:Find("clientKit", ...)` lookups `workload` makes.
    ---@param Registry table
    ---@param workload fun()
    ---@return integer lookups
    local function countClientKitLookups(Registry, workload)
      local find = rawget(Registry, "Find")
      local lookups = 0
      rawset(Registry, "Find", function(self, packageName, api)
        if packageName == "clientKit" then
          lookups = lookups + 1
        end
        return find(self, packageName, api)
      end)
      local ok, failure = pcall(workload)
      rawset(Registry, "Find", find)
      if not ok then
        error(failure, 0)
      end
      return lookups
    end

    -- A secret name stands in as a string the probe reports, as a secret
    -- string passes the type check before the probe is asked.
    it("asks the host probe directly when HookKit loaded with one", function()
      local secret = "SecretName"
      TestEnv.Reset()
      TestEnv.InstallWowApi()
      TestEnv.InstallHookApi()
      local probes = 0
      TestEnv.SetGlobal("issecretvalue", function(value)
        probes = probes + 1
        return rawequal(value, secret)
      end)
      local Registry = require("Registry")
      require("ClientKit")
      local HookKit = require("HookKit")
      local scope = HookKit:CreateScope()
      local target = { Method = noop }

      local lookups = countClientKitLookups(Registry, function()
        assert.is_true(scope:Hook(target, "Method", noop))
        assert.is_true(scope:IsHooked(target, "Method"))
        assert.is_true(scope:Unhook(target, "Method"))
        local ok, failure = pcall(scope.Hook, scope, target, secret, noop)
        assert.is_false(ok)
        assert.is_truthy(tostring(failure):find("method must not be a secret value", 1, true))
      end)
      assert.are.equal(0, lookups)
      assert.is_true(probes > 0)
    end)

    it("asks ClientKit on a host that had no probe when HookKit loaded", function()
      local secret = "SecretName"
      TestEnv.Reset()
      TestEnv.InstallWowApi()
      TestEnv.InstallHookApi()
      TestEnv.SetGlobal("issecretvalue", nil)
      local Registry = require("Registry")
      local HookKit = require("HookKit")
      -- A probe that appears after HookKit loaded (a compatibility shim, say)
      -- reaches HookKit only through a ClientKit that loads after it.
      TestEnv.SetGlobal("issecretvalue", function(value)
        return rawequal(value, secret)
      end)
      require("ClientKit")
      local scope = HookKit:CreateScope()

      local lookups = countClientKitLookups(Registry, function()
        local ok, failure = pcall(scope.IsHooked, scope, secret)
        assert.is_false(ok)
        assert.is_truthy(tostring(failure):find("globalName must not be a secret value", 1, true))
      end)
      assert.is_true(lookups > 0)
    end)

    it("treats nothing as secret without a probe or ClientKit", function()
      TestEnv.Reset()
      TestEnv.InstallWowApi()
      TestEnv.InstallHookApi()
      TestEnv.SetGlobal("issecretvalue", nil)
      require("Registry")
      local HookKit = require("HookKit")
      local scope = HookKit:CreateScope()
      local target = { Method = noop }
      assert.is_true(scope:Hook(target, "Method", noop))
      assert.is_true(scope:Unhook(target, "Method"))
    end)
  end)

  describe("per-object method table", function()
    it("keeps re-hooking an object correct after its last hook went", function()
      local HookKit = TestEnv.NewPackage()
      local scope = HookKit:CreateScope()
      local target = {
        First = function()
          return "first"
        end,
        Second = function()
          return "second"
        end,
      }
      local first, second = target.First, target.Second

      for _ = 1, 3 do
        assert.is_true(scope:Hook(target, "First", noop))
        assert.is_true(scope:RawHook(target, "Second", function(original)
          return original() .. "!"
        end))
        assert.are.equal(2, scope:GetActiveCount())
        assert.are.equal("second!", target.Second())
        local rows = scope:Hooks()
        assert.are.equal("First", rows[1].method)
        assert.are.equal("Second", rows[2].method)

        assert.is_true(scope:Unhook(target, "Second"))
        assert.is_true(scope:Unhook(target, "First"))
        assert.are.equal(0, scope:GetActiveCount())
        assert.are.same({}, scope:Hooks())
        assert.is_false(scope:IsHooked(target, "First"))
        assert.is_nil(scope:Original(target, "Second"))
        assert.are.equal(first, rawget(target, "First"))
        assert.are.equal(second, rawget(target, "Second"))
      end
      assert.is_false(scope:Unhook(target, "First"))
    end)

    it("lets the method table go with its object", function()
      local HookKit = TestEnv.NewPackage()
      local scope = HookKit:CreateScope()
      local records = rawget(scope, "_records")
      do
        local target = { Method = noop }
        scope:Hook(target, "Method", noop)
        scope:Unhook(target, "Method")
        assert.is_not_nil(next(records))
      end
      collectgarbage()
      collectgarbage()
      assert.is_nil(next(records))
    end)
  end)

  describe("replacement call", function()
    it("passes nil for a script that had no handler", function()
      local HookKit = TestEnv.NewPackage()
      local scope = HookKit:CreateScope()
      local frame = TestEnv.NewFrame()
      local received = "unset"
      assert.is_true(scope:RawHookScript(frame, "OnShow", function(previous, self)
        received = previous
        return self
      end))
      TestEnv.RunScript(frame, "OnShow")
      assert.is_nil(received)
    end)

    it("returns every result of the handler, nils included", function()
      local HookKit = TestEnv.NewPackage()
      local scope = HookKit:CreateScope()
      local target = {
        Method = function(value)
          return value, nil, "third"
        end,
      }
      scope:RawHook(target, "Method", function(original, value)
        return original(value * 2)
      end)
      assert.are.equal(3, select("#", target.Method(1)))
      local first, missing, third = target.Method(4)
      assert.are.equal(8, first)
      assert.is_nil(missing)
      assert.are.equal("third", third)
    end)
  end)

  describe("allocation #allocation", function()
    it("allocates only the record and its closure to re-hook an object", function()
      local HookKit = TestEnv.NewPackage()
      local scope = HookKit:CreateScope({ maxHooks = HookKit.UNBOUNDED })
      local target = { Method = noop }
      local function cycle()
        scope:Hook(target, "Method", noop)
        scope:Unhook(target, "Method")
      end
      cycle()
      local iterations = 2000
      local allocated = TestEnv.AllocatedKilobytes(function()
        for _ = 1, iterations do
          cycle()
        end
      end)
      -- The eight-field record (376 bytes on a 64-bit Lua 5.1) and one closure
      -- with one upvalue; the per-object method table is no longer rebuilt.
      local bytesPerCycle = allocated * 1024 / iterations
      assert.is_true(bytesPerCycle > 0, "a hook allocated nothing, so the measurement is broken")
      assert.is_true(bytesPerCycle <= 480, "a hook cycle allocated " .. bytesPerCycle .. " bytes")
    end)
  end)
end)
