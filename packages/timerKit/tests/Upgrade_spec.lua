local TestEnv = require("TimerKitTestEnv")

-- The in-place upgrade from revision 14, the upgrade floor (docs/API.md,
-- "Upgrading in place"). `LoadRevision14` runs a byte copy of the revision 14
-- file, as an addon embedding it would; `require("TimerKit")` then loads the
-- working revision over it.

local function noop() end

---Load Registry and the revision 14 fixture on a fresh host.
---@return table TimerKit the revision 14 facade
local function loadRevision14()
  TestEnv.Reset()
  TestEnv.InstallWowApi()
  require("Registry")
  local old = TestEnv.LoadRevision14()
  assert.are.equal(14, old.REVISION)
  return old
end

describe("TimerKit upgraded from revision 14", function()
  after_each(TestEnv.Reset)

  it("keeps running one-shot and repeating timers firing through the new dispatch", function()
    local old = loadRevision14()
    local state = rawget(old, "_state")
    local scope = old:ForAddon("Upgraded")
    local calls = { oneShot = 0, ticker = 0 }
    local oneShot = scope:After(1, function()
      calls.oneShot = calls.oneShot + 1
    end)
    local ticker = old:Every(1, function()
      calls.ticker = calls.ticker + 1
    end)
    ticker:SetUserData("payload")

    local upgraded = require("TimerKit")

    assert.are.equal(old, upgraded)
    assert.are.equal(15, upgraded.REVISION)
    assert.are.equal(state, rawget(upgraded, "_state"))
    assert.is_nil(rawget(state.dispatch, "fire"))
    assert.is_nil(rawget(state.dispatch, "closeScope"))
    TestEnv.FireNative(1)
    TestEnv.FireNative(2)
    TestEnv.FireNative(2)
    assert.are.equal(1, calls.oneShot)
    assert.are.equal(2, calls.ticker)
    assert.are.equal("completed", oneShot:GetState())
    assert.are.equal("payload", ticker:GetUserData())
    assert.is_true(ticker:Cancel())
    assert.are.equal(0, scope:GetActiveCount())
  end)

  it("keeps a timer revision 14 paused, without the part, paused until cancelled", function()
    local old = loadRevision14()
    local timer = old:After(2, noop)
    TestEnv.AdvanceMs(500)
    assert.is_true(timer:Pause())

    local upgraded = require("TimerKit")

    assert.is_false(upgraded:HasPart("Pausing"))
    assert.are.equal("paused", timer:GetState())
    assert.are.equal(1.5, timer:GetRemaining())
    local ok, message = pcall(timer.Resume, timer)
    assert.is_false(ok)
    assert.is_truthy(
      tostring(message):find("TimerKit.Timer:Resume is in TimerKit's Pausing part", 1, true)
    )
    assert.are.equal("paused", timer:GetState())
    assert.is_true(timer:Cancel())
  end)

  it("resumes a timer revision 14 paused once the part is loaded", function()
    local old = loadRevision14()
    local fired = 0
    local timer = old:Every(2, function()
      fired = fired + 1
    end)
    TestEnv.AdvanceMs(500)
    assert.is_true(timer:Pause())

    require("TimerKit")
    TestEnv.LoadPausing()

    assert.is_true(timer:Resume())
    assert.are.equal(1.5, TestEnv.NativeTimers()[2].seconds)
    TestEnv.AdvanceMs(1500)
    TestEnv.FireNative(2)
    assert.are.equal(1, fired)
    assert.is_true(TestEnv.NativeTimers()[3].repeating)
    TestEnv.FireNative(3)
    assert.are.equal(2, fired)
  end)

  it("serves a resume revision 14 armed, with and without the part", function()
    for _, withPart in ipairs({ false, true }) do
      local old = loadRevision14()
      local fired = 0
      local timer = old:Every(2, function()
        fired = fired + 1
      end)
      assert.is_true(timer:Pause())
      assert.is_true(timer:Resume())

      require("TimerKit")
      if withPart then
        TestEnv.LoadPausing()
      end

      -- The resume one-shot, then the ticker it arms on the interval.
      TestEnv.FireNative(2)
      assert.are.equal(1, fired)
      assert.are.equal("running", timer:GetState())
      assert.is_true(TestEnv.NativeTimers()[3].repeating)
      TestEnv.FireNative(3)
      assert.are.equal(2, fired)
      assert.is_true(timer:Cancel())
      TestEnv.Reset()
    end
  end)
end)
