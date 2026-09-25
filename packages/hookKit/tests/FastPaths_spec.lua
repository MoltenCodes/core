local TestEnv = require("HookKitTestEnv")

-- Revisions 6 and 7 make installing, removing and calling a hook cheaper
-- without changing what they do (docs/INTERNALS.md). These specs pin what each fast
-- path must keep:
--
--   * the secret check asks the host's `issecretvalue` alone, never ClientKit
--     (revision 7): the probe read at load when there was one, else the
--     global read again on each check, so nothing is secret without it and a
--     probe installed later is honoured;
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

    ---Hook, query and unhook a method, then try a hook under `secret` and
    ---expect the refusal when `refused`, or success otherwise.
    ---@param scope table
    ---@param secret string
    ---@param refused boolean
    local function exercise(scope, secret, refused)
      local target = { Method = noop, [secret] = noop }
      assert.is_true(scope:Hook(target, "Method", noop))
      assert.is_true(scope:IsHooked(target, "Method"))
      assert.is_true(scope:Unhook(target, "Method"))
      local ok, failure = pcall(scope.Hook, scope, target, secret, noop)
      if refused then
        assert.is_false(ok)
        assert.is_truthy(tostring(failure):find("method must not be a secret value", 1, true))
      else
        assert.is_true(ok)
        assert.is_true(scope:Unhook(target, secret))
      end
    end

    ---Load Registry and HookKit on a host with or without `issecretvalue`,
    ---with a ClientKit stand-in registered that calls every value secret.
    ---@param probe function|nil
    ---@return table HookKit
    ---@return table Registry
    ---@return table standInCalls
    local function load(probe)
      TestEnv.Reset()
      TestEnv.InstallWowApi()
      TestEnv.InstallHookApi()
      TestEnv.SetGlobal("issecretvalue", probe)
      local Registry = require("Registry")
      local standInCalls = TestEnv.RegisterClientKitStandIn(Registry)
      return require("HookKit"), Registry, standInCalls
    end

    -- A secret name stands in as a string the probe reports, as a secret
    -- string passes the type check before the probe is asked.
    it("asks the host probe alone when HookKit loaded with one", function()
      local secret = "SecretName"
      local probes = 0
      local HookKit, Registry, standInCalls = load(function(value)
        probes = probes + 1
        return rawequal(value, secret)
      end)
      local scope = HookKit:CreateScope()
      local lookups = countClientKitLookups(Registry, function()
        exercise(scope, secret, true)
      end)
      assert.are.equal(0, lookups)
      assert.are.equal(0, standInCalls.count)
      assert.is_true(probes > 0)
    end)

    it("treats nothing as secret without a probe, even with ClientKit registered", function()
      local HookKit, Registry, standInCalls = load(nil)
      local scope = HookKit:CreateScope()
      local lookups = countClientKitLookups(Registry, function()
        exercise(scope, "SecretName", false)
        assert.is_false((scope:IsHooked("SecretName")))
      end)
      assert.are.equal(0, lookups)
      assert.are.equal(0, standInCalls.count)
    end)

    it("honours a probe installed after HookKit loaded without one", function()
      local secret = "SecretName"
      local HookKit, Registry, standInCalls = load(nil)
      local scope = HookKit:CreateScope()
      exercise(scope, secret, false)
      -- A test environment or a shim may add the probe later; HookKit reads
      -- the global again on each check, so the next check uses it.
      TestEnv.SetGlobal("issecretvalue", function(value)
        return rawequal(value, secret)
      end)
      local lookups = countClientKitLookups(Registry, function()
        exercise(scope, secret, true)
        local ok, failure = pcall(scope.IsHooked, scope, secret)
        assert.is_false(ok)
        assert.is_truthy(tostring(failure):find("globalName must not be a secret value", 1, true))
      end)
      assert.are.equal(0, lookups)
      assert.are.equal(0, standInCalls.count)
      -- Removed again, nothing is secret again.
      TestEnv.SetGlobal("issecretvalue", nil)
      exercise(scope, secret, false)
    end)

    it("keeps using the probe read at load on a host that had one", function()
      local secret = "SecretName"
      local HookKit = load(function(value)
        return rawequal(value, secret)
      end)
      local scope = HookKit:CreateScope()
      -- The probe read at load stays in use: replacing or removing the
      -- global later does not change the answer.
      TestEnv.SetGlobal("issecretvalue", nil)
      exercise(scope, secret, true)
    end)

    it("uses the new check in scopes a revision 6 copy opened, after an upgrade", function()
      local secret = "SecretName"
      TestEnv.Reset()
      TestEnv.InstallWowApi()
      TestEnv.InstallHookApi()
      TestEnv.SetGlobal("issecretvalue", nil)
      local Registry = require("Registry")
      local standInCalls = TestEnv.RegisterClientKitStandIn(Registry)
      local previous = TestEnv.LoadRevision(6)
      local scope = previous:ForAddon("MyAddon")
      local target = { Method = noop }
      assert.is_true(scope:Hook(target, "Method", noop))

      local current = require("HookKit")
      assert.are.equal(previous, current)
      assert.is_true(current.REVISION > 6)
      local lookups = countClientKitLookups(Registry, function()
        exercise(scope, secret, false)
        assert.is_true(scope:Unhook(target, "Method"))
      end)
      assert.are.equal(0, lookups)
      assert.are.equal(0, standInCalls.count)
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
