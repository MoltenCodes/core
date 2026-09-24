local TestEnv = require("SchedulerKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src

---Return the line number of the statement that called this helper.
---@return integer line
local function currentLine()
  return debug.getinfo(2, "l").currentline
end

---Assert that a call failed with `message` reported at `expectedLine` of this
---spec file.
---@param expectedLine integer
---@param message string
---@param ok boolean
---@param value any
local function assertReportedAt(expectedLine, message, ok, value)
  assert.is_false(ok)
  assert.are.equal(SOURCE .. ":" .. expectedLine .. ": " .. message, value)
end

local function noop() end

---Load the module chain on the `mainline` host, whose `issecretvalue` reports
---the values `NewSecretValue` returns.
---@return table SchedulerKit
local function loadOnSecretHost()
  TestEnv.Reset()
  TestEnv.SetWowProfile("mainline")
  TestEnv.InstallWowApi()
  require("Registry")
  require("TimerKit")
  return require("SchedulerKit")
end

describe("SchedulerKit and secret values", function()
  local SchedulerKit
  before_each(function()
    SchedulerKit = loadOnSecretHost()
  end)
  after_each(TestEnv.Reset)

  ---Each case calls one public method with a secret where a check would
  ---compare it, and names the message expected at the caller's line.
  local cases = {
    {
      label = "SchedulerKit:ForAddon addonName",
      call = function(secret, mark)
        mark()
        SchedulerKit:ForAddon(secret)
      end,
    },
    {
      label = "SchedulerKit:CloseAddonScopes addonName",
      call = function(secret, mark)
        mark()
        SchedulerKit:CloseAddonScopes(secret)
      end,
    },
    {
      label = "SchedulerKit:Schedule priority",
      call = function(secret, mark)
        mark()
        SchedulerKit:Schedule(noop, { priority = secret })
      end,
    },
    {
      label = "SchedulerKit:Schedule name",
      call = function(secret, mark)
        mark()
        SchedulerKit:Schedule(noop, { name = secret })
      end,
    },
    {
      label = "SchedulerKit:After delay",
      call = function(secret, mark)
        mark()
        SchedulerKit:After(secret, noop)
      end,
    },
    {
      label = "SchedulerKit:NextFrame priority",
      call = function(secret, mark)
        mark()
        SchedulerKit:NextFrame(noop, { priority = secret })
      end,
    },
    {
      label = "SchedulerKit:Every interval",
      call = function(secret, mark)
        mark()
        SchedulerKit:Every(secret, noop)
      end,
    },
    {
      label = "SchedulerKit.Scope:Schedule priority",
      call = function(secret, mark)
        local scope = SchedulerKit:CreateScope()
        mark()
        scope:Schedule(noop, { priority = secret })
      end,
    },
    {
      label = "SchedulerKit.Scope:NextFrame name",
      call = function(secret, mark)
        local scope = SchedulerKit:CreateScope()
        mark()
        scope:NextFrame(noop, { name = secret })
      end,
    },
    {
      label = "SchedulerKit.Scope:After delay",
      call = function(secret, mark)
        local scope = SchedulerKit:CreateScope()
        mark()
        scope:After(secret, noop)
      end,
    },
    {
      label = "SchedulerKit.Scope:Every interval",
      call = function(secret, mark)
        local scope = SchedulerKit:CreateScope()
        mark()
        scope:Every(secret, noop)
      end,
    },
    {
      label = "SchedulerKit:SetFrameBudget milliseconds",
      call = function(secret, mark)
        mark()
        SchedulerKit:SetFrameBudget(secret)
      end,
    },
    {
      label = "SchedulerKit:SetMaxResumesPerFrame count",
      call = function(secret, mark)
        mark()
        SchedulerKit:SetMaxResumesPerFrame(secret)
      end,
    },
    {
      label = "SchedulerKit:Lane name",
      call = function(secret, mark)
        mark()
        SchedulerKit:Lane(secret)
      end,
    },
    {
      label = "SchedulerKit:Lane maxInFlight",
      call = function(secret, mark)
        mark()
        SchedulerKit:Lane("secret-lane", { maxInFlight = secret })
      end,
    },
    {
      label = "SchedulerKit:Lane retry.attempts",
      call = function(secret, mark)
        mark()
        SchedulerKit:Lane("secret-lane", { retry = { attempts = secret } })
      end,
    },
    {
      label = "SchedulerKit:Debounce leading",
      call = function(secret, mark)
        mark()
        SchedulerKit:Debounce(noop, 1, { leading = secret })
      end,
    },
    {
      label = "SchedulerKit:Coalesce maxKeys",
      call = function(secret, mark)
        mark()
        SchedulerKit:Coalesce(noop, 1, { maxKeys = secret })
      end,
    },
    {
      label = "SchedulerKit:Watch intervalSeconds",
      call = function(secret, mark)
        mark()
        SchedulerKit:Watch(noop, secret, noop)
      end,
    },
    {
      label = "SchedulerKit:Schedule options field name",
      call = function(secret, mark)
        mark()
        SchedulerKit:Schedule(noop, { [secret] = true })
      end,
    },
    {
      label = "SchedulerKit:Lane options field name",
      call = function(secret, mark)
        mark()
        SchedulerKit:Lane("secret-lane", { [secret] = true })
      end,
    },
    {
      label = "SchedulerKit:Lane retry options field name",
      call = function(secret, mark)
        mark()
        SchedulerKit:Lane("secret-lane", { retry = { [secret] = true } })
      end,
    },
    {
      label = "SchedulerKit:Debounce options field name",
      call = function(secret, mark)
        mark()
        SchedulerKit:Debounce(noop, 1, { [secret] = true })
      end,
    },
    {
      label = "SchedulerKit.Lane:Submit options field name",
      call = function(secret, mark)
        local lane = SchedulerKit:Lane("secret-submit-lane")
        mark()
        lane:Submit(noop, { [secret] = true })
      end,
    },
    {
      label = "SchedulerKit:SetLimits limits.maxLanes",
      call = function(secret, mark)
        mark()
        SchedulerKit:SetLimits({ maxLanes = secret })
      end,
    },
  }

  for _, case in ipairs(cases) do
    local label, call = case.label, case.call
    it("refuses a secret " .. label .. " at the caller's line", function()
      local line
      ---Record the line after the caller's, where each case calls the method.
      local function mark()
        line = debug.getinfo(2, "l").currentline + 1
      end
      local ok, value = pcall(call, TestEnv.NewSecretValue(), mark)
      assertReportedAt(line, label .. " must not be a secret value", ok, value)
    end)
  end

  it("refuses a secret coalesce key at the caller's line and stores a secret value", function()
    local delivered
    local handle = SchedulerKit:Coalesce(function(set)
      delivered = set.key
    end, 1)

    local line
    local ok, value = pcall(function()
      line = currentLine() + 1
      handle(TestEnv.NewSecretValue())
    end)
    assertReportedAt(line, "SchedulerKit coalesce handle key must not be a secret value", ok, value)

    local secretValue = TestEnv.NewSecretValue()
    assert.is_true(handle("key", secretValue))
    TestEnv.FireNative(#TestEnv.NativeTimers())
    assert.are.equal(secretValue, delivered)
  end)

  it("refuses an option field name the host reports secret before looking it up", function()
    -- A plain string stands in for a secret string: without the probe asked
    -- first, it would be looked up and reported as an unknown field by name.
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    -- The package reads this host global at load time, so the spec installs it in the global table.
    -- selene: allow(global_usage)
    rawset(_G, "issecretvalue", function(value)
      return value == "hiddenField"
    end)
    require("Registry")
    require("TimerKit")
    local stubbed = require("SchedulerKit")

    local line
    local ok, value = pcall(function()
      line = currentLine() + 1
      stubbed:Schedule(noop, { hiddenField = 1 })
    end)
    assertReportedAt(
      line,
      "SchedulerKit:Schedule options field name must not be a secret value",
      ok,
      value
    )

    ok, value = pcall(function()
      line = currentLine() + 1
      stubbed:Watch(noop, 1, noop, { hiddenField = 1 })
    end)
    assertReportedAt(
      line,
      "SchedulerKit:Watch options field name must not be a secret value",
      ok,
      value
    )
  end)

  it("reports a secret facade-method argument at the caller's own line", function()
    local line
    local ok, value = pcall(function()
      line = currentLine() + 1
      SchedulerKit:ForAddon(TestEnv.NewSecretValue())
    end)
    assertReportedAt(line, "SchedulerKit:ForAddon addonName must not be a secret value", ok, value)
  end)

  it("still accepts ordinary arguments on a host with secret values", function()
    local scope = SchedulerKit:ForAddon("SecretHostAddon")
    local lane = SchedulerKit:Lane("ordinary", { maxInFlight = 2, retry = { attempts = 1 } })
    local ran = false
    scope:Schedule(function()
      ran = true
    end, { priority = SchedulerKit.Priority.HIGH, name = "ordinary" })
    SchedulerKit:SetLimits({ maxLanes = SchedulerKit.UNBOUNDED })
    TestEnv.Tick()
    assert.is_true(ran)
    assert.are.equal(lane, SchedulerKit:Lane("ordinary"))
  end)
end)
