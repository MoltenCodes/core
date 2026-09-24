local TestEnv = require("TimerKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src

---Return the line number of the statement that called this helper.
---@return integer line
local function currentLine()
  return debug.getinfo(2, "l").currentline
end

---Assert that `action` fails with `message` reported at `expectedLine` of this
---spec file. A wrong `error` level shows up either as a different line number
---or as a message with no `file:line` prefix at all.
---@param expectedLine integer
---@param message string
---@param ok boolean
---@param value any
local function assertReportedAt(expectedLine, message, ok, value)
  assert.is_false(ok)
  assert.are.equal(SOURCE .. ":" .. expectedLine .. ": " .. message, value)
end

describe("TimerKit error levels", function()
  after_each(TestEnv.Reset)

  it("points scope convenience-constructor errors at the caller", function()
    local TimerKit = TestEnv.NewPackage()
    local scope = TimerKit:CreateScope()

    local line
    local ok, value = pcall(function()
      line = currentLine() + 1
      scope:After(1, "nope")
    end)
    assertReportedAt(line, "TimerKit.Scope:After callback must be a function", ok, value)
  end)

  it("points package convenience-constructor errors at the caller", function()
    local TimerKit = TestEnv.NewPackage()

    local line
    local ok, value = pcall(function()
      line = currentLine() + 1
      TimerKit:After(1, "nope")
    end)
    assertReportedAt(line, "TimerKit:After callback must be a function", ok, value)

    local intervalLine
    local intervalOk, intervalValue = pcall(function()
      intervalLine = currentLine() + 1
      TimerKit:Every(0, function() end)
    end)
    assertReportedAt(
      intervalLine,
      "TimerKit:Every delay must be greater than zero for repeating timers",
      intervalOk,
      intervalValue
    )
  end)

  it("points option-table errors at the caller", function()
    local TimerKit = TestEnv.NewPackage()
    local scope = TimerKit:CreateScope()

    local unknownLine
    local unknownOk, unknownValue = pcall(function()
      unknownLine = currentLine() + 1
      scope:New({ delay = 1, callback = function() end, zzz = true, aaa = true })
    end)
    assertReportedAt(
      unknownLine,
      'TimerKit.Scope:New options contains unknown field "aaa"',
      unknownOk,
      unknownValue
    )

    local delayLine
    local delayOk, delayValue = pcall(function()
      delayLine = currentLine() + 1
      TimerKit:New({ delay = "soon", callback = function() end })
    end)
    assertReportedAt(delayLine, "TimerKit:New delay must be a finite number", delayOk, delayValue)
  end)

  it("points closed-scope errors at the caller", function()
    local TimerKit = TestEnv.NewPackage()
    local scope = TimerKit:CreateScope()
    local timer = scope:New({ delay = 1, callback = function() end })
    scope:Close()

    local createLine
    local createOk, createValue = pcall(function()
      createLine = currentLine() + 1
      scope:After(1, function() end)
    end)
    assertReportedAt(
      createLine,
      "TimerKit.Scope:After cannot create a timer in a closed scope",
      createOk,
      createValue
    )

    local startLine
    local startOk, startValue = pcall(function()
      startLine = currentLine() + 1
      timer:Start()
    end)
    assertReportedAt(
      startLine,
      "TimerKit.Timer:Start cannot start a timer in a closed scope",
      startOk,
      startValue
    )

    local restartLine
    local restartOk, restartValue = pcall(function()
      restartLine = currentLine() + 1
      timer:Restart()
    end)
    assertReportedAt(
      restartLine,
      "TimerKit.Timer:Restart cannot restart a timer in a closed scope",
      restartOk,
      restartValue
    )
  end)

  it("points receiver-type errors at the caller", function()
    local TimerKit = TestEnv.NewPackage()

    local timerLine
    local timerOk, timerValue = pcall(function()
      timerLine = currentLine() + 1
      TimerKit.Timer.GetState({})
    end)
    assertReportedAt(
      timerLine,
      "TimerKit.Timer:GetState must be called on a TimerKit timer",
      timerOk,
      timerValue
    )

    local cancelLine
    local cancelOk, cancelValue = pcall(function()
      cancelLine = currentLine() + 1
      TimerKit.Timer.Cancel({})
    end)
    assertReportedAt(
      cancelLine,
      "TimerKit.Timer:Cancel must be called on a TimerKit timer",
      cancelOk,
      cancelValue
    )

    local scopeLine
    local scopeOk, scopeValue = pcall(function()
      scopeLine = currentLine() + 1
      TimerKit.Scope.GetActiveCount({})
    end)
    assertReportedAt(
      scopeLine,
      "TimerKit.Scope:GetActiveCount must be called on a TimerKit scope",
      scopeOk,
      scopeValue
    )

    local cancelAllLine
    local cancelAllOk, cancelAllValue = pcall(function()
      cancelAllLine = currentLine() + 1
      TimerKit.Scope.CancelAll({})
    end)
    assertReportedAt(
      cancelAllLine,
      "TimerKit.Scope:CancelAll must be called on a TimerKit scope",
      cancelAllOk,
      cancelAllValue
    )
  end)

  it("points addon-scope name errors at the caller", function()
    local TimerKit = TestEnv.NewPackage()

    local line
    local ok, value = pcall(function()
      line = currentLine() + 1
      TimerKit:ForAddon("")
    end)
    assertReportedAt(line, "TimerKit:ForAddon addonName must be a non-empty string", ok, value)

    local closeLine
    local closeOk, closeValue = pcall(function()
      closeLine = currentLine() + 1
      TimerKit:CloseAddonScopes(42)
    end)
    assertReportedAt(
      closeLine,
      "TimerKit:CloseAddonScopes addonName must be a non-empty string",
      closeOk,
      closeValue
    )

    local facadeLine
    local facadeOk, facadeValue = pcall(function()
      facadeLine = currentLine() + 1
      TimerKit.CloseAddonScopes({}, "Example")
    end)
    assertReportedAt(
      facadeLine,
      "TimerKit:CloseAddonScopes must be called on the TimerKit facade; "
        .. "use TimerKit:CloseAddonScopes(addonName)",
      facadeOk,
      facadeValue
    )
  end)
end)
