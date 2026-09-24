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

local function callback() end

---Load Registry and TimerKit on the `mainline` host, whose `issecretvalue`
---reports the values `NewSecretValue` returns.
---@return table TimerKit
local function loadOnSecretHost()
  TestEnv.Reset()
  TestEnv.SetWowProfile("mainline")
  TestEnv.InstallWowApi()
  require("Registry")
  return require("TimerKit")
end

describe("TimerKit and secret values", function()
  local TimerKit
  before_each(function()
    TimerKit = loadOnSecretHost()
  end)
  after_each(TestEnv.Reset)

  it("refuses a secret delay at the caller's line and creates no timer", function()
    local scope = TimerKit:CreateScope()
    local secret = TestEnv.NewSecretValue()

    local afterLine
    local afterOk, afterValue = pcall(function()
      afterLine = currentLine() + 1
      scope:After(secret, callback)
    end)
    assertReportedAt(
      afterLine,
      "TimerKit.Scope:After delay must not be a secret value",
      afterOk,
      afterValue
    )

    local everyLine
    local everyOk, everyValue = pcall(function()
      everyLine = currentLine() + 1
      TimerKit:Every(secret, callback)
    end)
    assertReportedAt(
      everyLine,
      "TimerKit:Every delay must not be a secret value",
      everyOk,
      everyValue
    )
    assert.are.equal(0, scope:GetActiveCount())
  end)

  it("refuses secret New options at the caller's line", function()
    local delayLine
    local delayOk, delayValue = pcall(function()
      delayLine = currentLine() + 1
      TimerKit:New({ delay = TestEnv.NewSecretValue(), callback = callback })
    end)
    assertReportedAt(
      delayLine,
      "TimerKit:New delay must not be a secret value",
      delayOk,
      delayValue
    )

    local repeatingLine
    local repeatingOk, repeatingValue = pcall(function()
      repeatingLine = currentLine() + 1
      TimerKit:New({ delay = 1, callback = callback, repeating = TestEnv.NewSecretValue() })
    end)
    assertReportedAt(
      repeatingLine,
      "TimerKit:New repeating must not be a secret value",
      repeatingOk,
      repeatingValue
    )
  end)

  it("refuses a secret addon name and a secret receiver at the caller's line", function()
    local secret = TestEnv.NewSecretValue()

    local forAddonLine
    local forAddonOk, forAddonValue = pcall(function()
      forAddonLine = currentLine() + 1
      TimerKit:ForAddon(secret)
    end)
    assertReportedAt(
      forAddonLine,
      "TimerKit:ForAddon addonName must not be a secret value",
      forAddonOk,
      forAddonValue
    )

    local closeLine
    local closeOk, closeValue = pcall(function()
      closeLine = currentLine() + 1
      TimerKit:CloseAddonScopes(secret)
    end)
    assertReportedAt(
      closeLine,
      "TimerKit:CloseAddonScopes addonName must not be a secret value",
      closeOk,
      closeValue
    )

    local receiverLine
    local receiverOk, receiverValue = pcall(function()
      receiverLine = currentLine() + 1
      TimerKit.CloseAddonScopes(secret, "MyAddon")
    end)
    assertReportedAt(
      receiverLine,
      "TimerKit:CloseAddonScopes must be called on the TimerKit facade; "
        .. "use TimerKit:CloseAddonScopes(addonName)",
      receiverOk,
      receiverValue
    )
  end)

  it("stores a secret user value without comparing it", function()
    local secret = TestEnv.NewSecretValue()
    local timer = TimerKit:After(1, callback)
    assert.are.equal(timer, timer:SetUserData(secret))
    assert.are.equal(secret, timer:GetUserData())
  end)

  it("still accepts ordinary arguments on a host with secret values", function()
    local timer = TimerKit:New({ delay = 1, callback = callback, repeating = true })
    assert.is_true(timer:IsRepeating())
    assert.is_false(TimerKit:CloseAddonScopes("MyAddon"))
    assert.are.equal("MyAddon", TimerKit:ForAddon("MyAddon"):GetAddonName())
  end)
end)
