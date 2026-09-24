local TestEnv = require("ReadinessKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src

---Return the line number of the statement that called this helper.
---@return integer line
local function currentLine()
  return debug.getinfo(2, "l").currentline
end

---Assert that `action` failed with `message` reported at `expectedLine` of this
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

local function probe()
  return false
end

describe("ReadinessKit error levels", function()
  local ReadinessKit
  before_each(function()
    ReadinessKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("points Gate argument errors at the caller", function()
    local nameLine
    local nameOk, nameValue = pcall(function()
      nameLine = currentLine() + 1
      ReadinessKit:Gate("", probe)
    end)
    assertReportedAt(
      nameLine,
      "ReadinessKit:Gate name must be a non-empty string",
      nameOk,
      nameValue
    )

    local probeLine
    local probeOk, probeValue = pcall(function()
      probeLine = currentLine() + 1
      ReadinessKit:Gate("a", true)
    end)
    assertReportedAt(probeLine, "ReadinessKit:Gate probe must be a function", probeOk, probeValue)

    local unknownLine
    local unknownOk, unknownValue = pcall(function()
      unknownLine = currentLine() + 1
      ReadinessKit:Gate("a", probe, { zzz = 1, aaa = 1 })
    end)
    assertReportedAt(
      unknownLine,
      'ReadinessKit:Gate options contains unknown field "aaa"',
      unknownOk,
      unknownValue
    )

    local intervalLine
    local intervalOk, intervalValue = pcall(function()
      intervalLine = currentLine() + 1
      ReadinessKit:Gate("a", probe, { intervalSeconds = math.huge })
    end)
    assertReportedAt(
      intervalLine,
      "ReadinessKit:Gate intervalSeconds must be a finite number greater than zero",
      intervalOk,
      intervalValue
    )

    local timeoutLine
    local timeoutOk, timeoutValue = pcall(function()
      timeoutLine = currentLine() + 1
      ReadinessKit:Gate("a", probe, { timeoutSeconds = -1 })
    end)
    assertReportedAt(
      timeoutLine,
      "ReadinessKit:Gate timeoutSeconds must be false or a finite number greater than zero",
      timeoutOk,
      timeoutValue
    )

    local waitersLine
    local waitersOk, waitersValue = pcall(function()
      waitersLine = currentLine() + 1
      ReadinessKit:Gate("a", probe, { maxWaiters = 0 })
    end)
    assertReportedAt(
      waitersLine,
      "ReadinessKit:Gate maxWaiters must be a positive integer or ReadinessKit.UNBOUNDED",
      waitersOk,
      waitersValue
    )

    local optionsLine
    local optionsOk, optionsValue = pcall(function()
      optionsLine = currentLine() + 1
      ReadinessKit:Gate("a", probe, "fast")
    end)
    assertReportedAt(
      optionsLine,
      "ReadinessKit:Gate options must be a table",
      optionsOk,
      optionsValue
    )

    local getLine
    local getOk, getValue = pcall(function()
      getLine = currentLine() + 1
      ReadinessKit:Get(42)
    end)
    assertReportedAt(getLine, "ReadinessKit:Get name must be a non-empty string", getOk, getValue)
  end)

  it("points gate method errors at the caller", function()
    local gate = ReadinessKit:Gate("a", probe)

    local awaitLine
    local awaitOk, awaitValue = pcall(function()
      awaitLine = currentLine() + 1
      gate:Await("nope")
    end)
    assertReportedAt(
      awaitLine,
      "ReadinessKit.Gate:Await callback must be a function",
      awaitOk,
      awaitValue
    )

    local eventLine
    local eventOk, eventValue = pcall(function()
      eventLine = currentLine() + 1
      gate:ReprobeOn("")
    end)
    assertReportedAt(
      eventLine,
      "ReadinessKit.Gate:ReprobeOn eventName must be a non-empty string",
      eventOk,
      eventValue
    )
  end)

  it("points closed-gate errors at the caller", function()
    local gate = ReadinessKit:Gate("a", probe)
    gate:Close()

    local awaitLine
    local awaitOk, awaitValue = pcall(function()
      awaitLine = currentLine() + 1
      gate:Await(probe)
    end)
    assertReportedAt(
      awaitLine,
      "ReadinessKit.Gate:Await cannot wait on a closed gate",
      awaitOk,
      awaitValue
    )

    local probeLine
    local probeOk, probeValue = pcall(function()
      probeLine = currentLine() + 1
      gate:Probe()
    end)
    assertReportedAt(
      probeLine,
      "ReadinessKit.Gate:Probe cannot probe a closed gate",
      probeOk,
      probeValue
    )

    local invalidateLine
    local invalidateOk, invalidateValue = pcall(function()
      invalidateLine = currentLine() + 1
      gate:Invalidate()
    end)
    assertReportedAt(
      invalidateLine,
      "ReadinessKit.Gate:Invalidate cannot invalidate a closed gate",
      invalidateOk,
      invalidateValue
    )

    local reprobeLine
    local reprobeOk, reprobeValue = pcall(function()
      reprobeLine = currentLine() + 1
      gate:ReprobeOn("SPELLS_CHANGED")
    end)
    assertReportedAt(
      reprobeLine,
      "ReadinessKit.Gate:ReprobeOn cannot subscribe a closed gate",
      reprobeOk,
      reprobeValue
    )
  end)

  it("points receiver-type errors at the caller", function()
    local gate = ReadinessKit:Gate("a", probe)
    local waiter = gate:Await(probe)

    local gateLine
    local gateOk, gateValue = pcall(function()
      gateLine = currentLine() + 1
      gate.IsReady({})
    end)
    assertReportedAt(
      gateLine,
      "ReadinessKit.Gate:IsReady must be called on a ReadinessKit gate",
      gateOk,
      gateValue
    )

    local waiterLine
    local waiterOk, waiterValue = pcall(function()
      waiterLine = currentLine() + 1
      waiter.Cancel(gate)
    end)
    assertReportedAt(
      waiterLine,
      "ReadinessKit.Waiter:Cancel must be called on a ReadinessKit waiter",
      waiterOk,
      waiterValue
    )
  end)

  it("points WhenAll errors at the caller", function()
    local listLine
    local listOk, listValue = pcall(function()
      listLine = currentLine() + 1
      ReadinessKit:WhenAll(nil, probe)
    end)
    assertReportedAt(
      listLine,
      "ReadinessKit:WhenAll gates must be an array of ReadinessKit gates",
      listOk,
      listValue
    )

    local gate = ReadinessKit:Gate("a", probe)
    local callbackLine
    local callbackOk, callbackValue = pcall(function()
      callbackLine = currentLine() + 1
      ReadinessKit:WhenAll({ gate }, 5)
    end)
    assertReportedAt(
      callbackLine,
      "ReadinessKit:WhenAll callback must be a function",
      callbackOk,
      callbackValue
    )

    gate:Close()
    local closedLine
    local closedOk, closedValue = pcall(function()
      closedLine = currentLine() + 1
      ReadinessKit:WhenAll({ gate }, probe)
    end)
    assertReportedAt(
      closedLine,
      "ReadinessKit:WhenAll cannot wait on a closed gate",
      closedOk,
      closedValue
    )
  end)

  it("points the absent-EventKit error at the caller", function()
    local Bare = TestEnv.NewPackageWithoutEventKit()
    local gate = Bare:Gate("a", probe)
    local absentLine
    local absentOk, absentValue = pcall(function()
      absentLine = currentLine() + 1
      gate:ReprobeOn("SPELLS_CHANGED")
    end)
    assertReportedAt(
      absentLine,
      "ReadinessKit.Gate:ReprobeOn requires EventKit API 1, which is not loaded (absent)",
      absentOk,
      absentValue
    )
  end)

  it("points a refused ReprobeOn registration at the caller", function()
    local gate = ReadinessKit:Gate("a", probe)
    TestEnv.FailNextRegisterEvent()
    local line
    local ok, value = pcall(function()
      line = currentLine() + 1
      gate:ReprobeOn("SPELLS_CHANGED")
    end)
    assertReportedAt(
      line,
      "ReadinessKit.Gate:ReprobeOn could not connect SPELLS_CHANGED: "
        .. "EventKit.Scope:Connect could not register event SPELLS_CHANGED",
      ok,
      value
    )
  end)
end)
