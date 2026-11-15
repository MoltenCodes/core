local TestEnv = require("TimerKitTestEnv")

---Return the bytes `build` allocates per call, averaged over `count` kept
---results, with the collector stopped.
---@param count integer
---@param build fun(): any
---@return number bytes
local function bytesPer(count, build)
  local kept = {}
  for index = 1, count do
    kept[index] = false
  end
  build()
  local kilobytes = TestEnv.AllocatedKilobytes(function()
    for index = 1, count do
      kept[index] = build()
    end
  end)
  return kilobytes * 1024 / count
end

describe("TimerKit timer records", function()
  after_each(TestEnv.Reset)

  it("stores one-shot and repeating timers in the same small array record #allocation", function()
    local TimerKit = TestEnv.NewPackage()
    local scope = TimerKit:CreateScope()
    local function callback() end
    local oneShot = { delay = 1, callback = callback }
    local repeating = { delay = 1, callback = callback, repeating = true }

    local oneShotBytes = bytesPer(200, function()
      return scope:New(oneShot)
    end)
    local repeatingBytes = bytesPer(200, function()
      return scope:New(repeating)
    end)

    -- Nine array slots: 200 bytes on 64-bit Lua 5.1, against 384 (one-shot)
    -- and 704 (repeating) for the named fields revision 13 used.
    assert.is_true(oneShotBytes <= 224, "one-shot record " .. oneShotBytes .. " B")
    assert.is_true(repeatingBytes <= 224, "repeating record " .. repeatingBytes .. " B")
    assert.is_true(TestEnv.HasRecordLayout(TimerKit, scope:New(oneShot)))
  end)

  it("attaches user data without growing the record #allocation", function()
    local TimerKit = TestEnv.NewPackage()
    local ticker = TimerKit:Every(1, function() end)
    local timer = TimerKit:New({ delay = 1, callback = function() end })
    local payload = {}

    local kilobytes = TestEnv.AllocatedKilobytes(function()
      ticker:SetUserData(payload)
      timer:SetUserData(payload)
    end)

    assert.are.equal(0, kilobytes)
    assert.are.equal(payload, ticker:GetUserData())
  end)

  describe("built by an older revision", function()
    it("converts a running timer of a manual scope when its host callback fires", function()
      local TimerKit = TestEnv.NewPackage()
      local scope = TimerKit:CreateScope()
      local fired = 0
      local timer = TestEnv.ToLegacyLayout(
        TimerKit,
        scope:After(1, function()
          fired = fired + 1
        end)
      )
      assert.is_false(TestEnv.HasRecordLayout(TimerKit, timer))

      TestEnv.FireNative(1)

      assert.are.equal(1, fired)
      assert.is_true(TestEnv.HasRecordLayout(TimerKit, timer))
      assert.are.equal("completed", timer:GetState())
      assert.are.equal(0, scope:GetActiveCount())
    end)

    it("converts a held idle, completed or cancelled timer on its next method call", function()
      local TimerKit = TestEnv.NewPackage()
      local scope = TimerKit:CreateScope()
      local calls = 0
      local idle = scope:New({
        delay = 2,
        callback = function()
          calls = calls + 1
        end,
      })
      idle:SetUserData("kept")
      local cancelled = scope:After(1, function() end)
      cancelled:Cancel()
      TestEnv.ToLegacyLayout(TimerKit, idle)
      TestEnv.ToLegacyLayout(TimerKit, cancelled)

      assert.are.equal("cancelled", cancelled:GetState())
      assert.is_true(TestEnv.HasRecordLayout(TimerKit, cancelled))
      assert.are.equal("kept", idle:GetUserData())
      assert.are.equal(2, idle:GetDelay())
      assert.are.equal(scope, idle:GetScope())
      assert.is_true(idle:Start())
      TestEnv.FireNative(2)
      assert.are.equal(1, calls)
    end)

    it("converts a running timer on Cancel and makes its callback stale", function()
      local TimerKit = TestEnv.NewPackage()
      local scope = TimerKit:CreateScope()
      local fired = false
      local timer = TestEnv.ToLegacyLayout(
        TimerKit,
        scope:After(1, function()
          fired = true
        end)
      )

      assert.is_true(timer:Cancel())
      TestEnv.InvokeRaw(1)

      assert.is_false(fired)
      assert.is_true(TestEnv.HasRecordLayout(TimerKit, timer))
      assert.are.equal(0, scope:GetActiveCount())
    end)

    it("converts the timers a bulk cancel or a close meets", function()
      local TimerKit = TestEnv.NewPackage()
      local scope = TimerKit:CreateScope()
      local first = TestEnv.ToLegacyLayout(TimerKit, scope:After(1, function() end))
      local second = TestEnv.ToLegacyLayout(TimerKit, scope:Every(1, function() end))
      local third = scope:After(1, function() end)

      assert.are.equal(3, scope:CancelAll())
      assert.is_true(TestEnv.HasRecordLayout(TimerKit, first))
      assert.is_true(TestEnv.HasRecordLayout(TimerKit, second))
      assert.is_true(third:IsCancelled())

      local closing = TimerKit:CreateScope()
      local held = TestEnv.ToLegacyLayout(TimerKit, closing:Every(1, function() end))
      assert.is_true(closing:Close())
      assert.is_true(held:IsCancelled())
    end)

    it("converts the running timers of addon and package scopes when it loads", function()
      local current = TestEnv.NewPackage().REVISION
      TestEnv.Reset()
      TestEnv.InstallWowApi()
      require("Registry")
      local old = TestEnv.LoadRevision(current - 1)
      local ticks, fires = 0, 0
      local addonTimer = TestEnv.ToLegacyLayout(
        old,
        old:ForAddon("Upgraded"):Every(1, function()
          ticks = ticks + 1
        end)
      )
      local packageTimer = TestEnv.ToLegacyLayout(
        old,
        old:After(1, function()
          fires = fires + 1
        end)
      )
      local paused = old:ForAddon("Upgraded"):After(4, function() end)
      paused:Pause()
      TestEnv.ToLegacyLayout(old, paused)
      paused:SetUserData(nil)

      local upgraded = require("TimerKit")

      assert.are.equal(current, upgraded.REVISION)
      for _, timer in ipairs({ addonTimer, packageTimer, paused }) do
        assert.is_true(TestEnv.HasRecordLayout(upgraded, timer))
      end
      assert.is_true(paused:IsPaused())
      assert.is_true(paused:Resume())
      assert.is_true(addonTimer:IsRepeating())
      assert.is_false(packageTimer:IsRepeating())
      -- Their host callbacks, created before the upgrade, fire the converted
      -- timers through the current revision.
      TestEnv.FireNative(1)
      TestEnv.FireNative(1)
      TestEnv.FireNative(2)
      assert.are.equal(2, ticks)
      assert.are.equal(1, fires)
      assert.are.equal("completed", packageTimer:GetState())
    end)

    it("keeps the generation of a revision 9 timer as a named field", function()
      local TimerKit = TestEnv.NewPackage()
      local scope = TimerKit:CreateScope()
      local timer =
        TestEnv.ToLegacyLayout(TimerKit, scope:New({ delay = 1, callback = function() end }))
      rawset(timer, "_generation", 3)

      assert.is_true(timer:Start())

      assert.is_true(TestEnv.HasRecordLayout(TimerKit, timer))
      assert.are.equal(4, rawget(timer, "_generation"))
    end)
  end)
end)
