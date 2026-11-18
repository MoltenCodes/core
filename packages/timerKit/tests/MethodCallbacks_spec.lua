local TestEnv = require("TimerKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src

---Return the line number of the statement that called this helper.
---@return integer line
local function currentLine()
  return debug.getinfo(2, "l").currentline
end

---Assert that `action` failed with `message` reported at `expectedLine` of this
---spec file.
---@param expectedLine integer
---@param message string
---@param ok boolean
---@param value any
local function assertReportedAt(expectedLine, message, ok, value)
  assert.is_false(ok)
  assert.are.equal(SOURCE .. ":" .. expectedLine .. ": " .. message, value)
end

---A receiver whose methods record every call.
---@return table receiver
local function newReceiver()
  local receiver = { calls = {} }
  function receiver:Tick(timer)
    self.calls[#self.calls + 1] = { self = self, timer = timer, method = "Tick" }
  end
  return receiver
end

describe("TimerKit method-name callbacks", function()
  after_each(TestEnv.Reset)

  it("calls receiver[methodName](receiver, timer) for scope After and Every", function()
    local TimerKit = TestEnv.NewPackage()
    local scope = TimerKit:CreateScope()
    local receiver = newReceiver()

    local once = scope:After(1, receiver, "Tick")
    local ticker = scope:Every(2, receiver, "Tick")
    TestEnv.FireNative(1)
    TestEnv.FireNative(2)
    TestEnv.FireNative(2)

    assert.are.equal(3, #receiver.calls)
    assert.are.equal(receiver, receiver.calls[1].self)
    assert.are.equal(once, receiver.calls[1].timer)
    assert.are.equal(ticker, receiver.calls[2].timer)
    assert.are.equal(ticker, receiver.calls[3].timer)
    assert.are.equal("completed", once:GetState())
    assert.is_true(ticker:IsPending())
  end)

  it("offers the same form on the package-level After and Every", function()
    local TimerKit = TestEnv.NewPackage()
    local receiver = newReceiver()

    local once = TimerKit:After(1, receiver, "Tick")
    local ticker = TimerKit:Every(1, receiver, "Tick")
    TestEnv.FireNative(1)
    TestEnv.FireNative(2)

    assert.are.equal(once, receiver.calls[1].timer)
    assert.are.equal(ticker, receiver.calls[2].timer)
    assert.is_true(ticker:Cancel())
  end)

  it("finds the method through the receiver's own metatable", function()
    local TimerKit = TestEnv.NewPackage()
    local calls = 0
    local prototype = {
      Refresh = function()
        calls = calls + 1
      end,
    }
    local receiver = setmetatable({}, { __index = prototype })

    TimerKit:After(1, receiver, "Refresh")
    TestEnv.FireNative(1)

    assert.are.equal(1, calls)
  end)

  it("looks the method up at every fire, so a later replacement runs", function()
    local TimerKit = TestEnv.NewPackage()
    local scope = TimerKit:CreateScope()
    local seen = {}
    local receiver = {}
    function receiver.Poll()
      seen[#seen + 1] = "first"
    end

    local ticker = scope:Every(1, receiver, "Poll")
    TestEnv.FireNative(1)
    function receiver.Poll()
      seen[#seen + 1] = "second"
    end
    TestEnv.FireNative(1)

    assert.are.same({ "first", "second" }, seen)
    assert.is_true(ticker:Restart())
    TestEnv.FireNative(2)
    assert.are.equal("second", seen[3])
  end)

  it("raises from the callback when the method is gone at fire time", function()
    local TimerKit = TestEnv.NewPackage()
    local scope = TimerKit:CreateScope()
    local receiver = newReceiver()
    local ticker = scope:Every(1, receiver, "Tick")

    receiver.Tick = nil
    local ok, message = pcall(TestEnv.FireNative, 1)

    assert.is_false(ok)
    assert.is_truthy(string.find(message, 'TimerKit timer receiver has no method "Tick"', 1, true))
    -- The failure is the callback's, as for a closure that raises: the timer
    -- keeps its state.
    assert.is_true(ticker:IsPending())
    receiver.Tick = function() end
    TestEnv.FireNative(1)
    assert.is_true(ticker:Cancel())
  end)

  it("refuses a missing or non-function method at the caller's line", function()
    local TimerKit = TestEnv.NewPackage()
    local scope = TimerKit:CreateScope()
    local receiver = { NotAFunction = 1 }

    local missingLine
    local missingOk, missingValue = pcall(function()
      missingLine = currentLine() + 1
      scope:After(1, receiver, "Missing")
    end)
    assertReportedAt(
      missingLine,
      'TimerKit.Scope:After receiver has no method "Missing"',
      missingOk,
      missingValue
    )

    local fieldLine
    local fieldOk, fieldValue = pcall(function()
      fieldLine = currentLine() + 1
      TimerKit:Every(1, receiver, "NotAFunction")
    end)
    assertReportedAt(
      fieldLine,
      'TimerKit:Every receiver has no method "NotAFunction"',
      fieldOk,
      fieldValue
    )
    assert.are.equal(0, scope:GetActiveCount())
    assert.are.equal(0, #TestEnv.NativeTimers())
  end)

  it("refuses a missing, empty or non-string method name at the caller's line", function()
    local TimerKit = TestEnv.NewPackage()
    local scope = TimerKit:CreateScope()
    local receiver = newReceiver()

    for _, methodName in ipairs({ false, "", 7 }) do
      local line
      local ok, value = pcall(function()
        line = currentLine() + 1
        scope:Every(1, receiver, methodName)
      end)
      assertReportedAt(
        line,
        "TimerKit.Scope:Every methodName must be a non-empty string",
        ok,
        value
      )
    end

    local nilLine
    local nilOk, nilValue = pcall(function()
      nilLine = currentLine() + 1
      scope:After(1, receiver)
    end)
    assertReportedAt(
      nilLine,
      "TimerKit.Scope:After methodName must be a non-empty string",
      nilOk,
      nilValue
    )
  end)

  it("checks the receiver, the closed scope and the delay as for a closure", function()
    local TimerKit = TestEnv.NewPackage()
    local scope = TimerKit:CreateScope()
    local receiver = newReceiver()

    local delayLine
    local delayOk, delayValue = pcall(function()
      delayLine = currentLine() + 1
      scope:After(-1, receiver, "Tick")
    end)
    assertReportedAt(
      delayLine,
      "TimerKit.Scope:After delay must be zero or greater",
      delayOk,
      delayValue
    )

    scope:Close()
    local closedLine
    local closedOk, closedValue = pcall(function()
      closedLine = currentLine() + 1
      scope:After(1, receiver, "Tick")
    end)
    assertReportedAt(
      closedLine,
      "TimerKit.Scope:After cannot create a timer in a closed scope",
      closedOk,
      closedValue
    )
  end)

  it("refuses a secret method name at the caller's line", function()
    TestEnv.Reset()
    TestEnv.SetWowProfile("mainline")
    TestEnv.InstallWowApi()
    require("Registry")
    local TimerKit = require("TimerKit")
    local secret = TestEnv.NewSecretValue()

    local line
    local ok, value = pcall(function()
      line = currentLine() + 1
      TimerKit:After(1, newReceiver(), secret)
    end)
    assertReportedAt(line, "TimerKit:After methodName must not be a secret value", ok, value)
  end)

  it("keeps the method-name callback across Restart, Pause and Resume", function()
    local TimerKit = TestEnv.NewPackage()
    TestEnv.LoadPausing()
    local receiver = newReceiver()
    local timer = TimerKit:After(2, receiver, "Tick")

    assert.is_true(timer:Pause())
    assert.is_true(timer:Resume())
    TestEnv.FireNative(2)
    assert.are.equal(1, #receiver.calls)
    assert.is_true(timer:Restart())
    TestEnv.FireNative(3)
    assert.are.equal(2, #receiver.calls)
    assert.are.equal(timer, receiver.calls[2].timer)
  end)
end)
