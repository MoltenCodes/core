local TestEnv = require("MediaKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src

---Return the line number of the statement that called this helper.
---@return integer line
local function currentLine()
  return debug.getinfo(2, "l").currentline
end

---Assert that `action` failed with `message` reported at `expectedLine` of
---this spec file, which proves the error level points at the caller.
---@param expectedLine integer
---@param message string
---@param ok boolean
---@param value any
local function assertReportedAt(expectedLine, message, ok, value)
  assert.is_false(ok)
  assert.are.equal(SOURCE .. ":" .. expectedLine .. ": " .. message, value)
end

local DEFAULT_LIMITS = { maxEntriesPerType = 1024, maxConsumers = 1024 }
local ENTRIES_MESSAGE =
  "MediaKit:SetLimits limits.maxEntriesPerType must be an integer from 1 to 16384"
local CONSUMERS_MESSAGE =
  "MediaKit:SetLimits limits.maxConsumers must be a positive integer or MediaKit.UNBOUNDED"

describe("MediaKit limits", function()
  local MediaKit

  before_each(function()
    MediaKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  ---Register statusbars until the type holds `total` entries, built-ins included.
  ---@param total integer
  local function fillStatusbars(total)
    local builtins = #MediaKit:List("statusbar")
    for index = 1, total - builtins do
      assert.is_true(MediaKit:Register("statusbar", "Bar " .. index, "Interface\\Bars\\" .. index))
    end
  end

  ---Create `count` defaults objects with distinct consumer names.
  ---@param count integer
  local function createConsumers(count)
    for index = 1, count do
      MediaKit:Defaults("Consumer " .. index)
    end
  end

  it("reports the defaults through GetLimits", function()
    assert.are.same(DEFAULT_LIMITS, MediaKit:GetLimits())
    assert.are.equal(MediaKit.MAX_ENTRIES_PER_TYPE, MediaKit:GetLimits().maxEntriesPerType)
  end)

  it("returns a fresh table from every GetLimits call", function()
    local first = MediaKit:GetLimits()
    first.maxConsumers = 1
    assert.are_not.equal(first, MediaKit:GetLimits())
    assert.are.same(DEFAULT_LIMITS, MediaKit:GetLimits())
  end)

  it("honours a larger maxEntriesPerType up to the ceiling", function()
    MediaKit:SetLimits({ maxEntriesPerType = 1100 })
    fillStatusbars(1100)
    local registered, reason = MediaKit:Register("statusbar", "One Too Many", "Interface\\Bars\\X")
    assert.is_nil(registered)
    assert.are.equal("full", reason)

    MediaKit:SetLimits({ maxEntriesPerType = 16384 })
    assert.are.equal(16384, MediaKit:GetLimits().maxEntriesPerType)
  end)

  it("honours a smaller maxEntriesPerType without removing entries", function()
    MediaKit:Register("statusbar", "Kept", "Interface\\Bars\\Kept")
    MediaKit:SetLimits({ maxEntriesPerType = 1 })
    assert.are.equal("Interface\\Bars\\Kept", MediaKit:Fetch("statusbar", "Kept"))
    local _, reason = MediaKit:Register("statusbar", "Refused", "Interface\\Bars\\Refused")
    assert.are.equal("full", reason)
    -- An identical re-registration is still accepted: it adds nothing.
    assert.is_true(MediaKit:Register("statusbar", "Kept", "Interface\\Bars\\Kept"))
  end)

  it("refuses UNBOUNDED for maxEntriesPerType at the caller, with the reason", function()
    local line
    local ok, value = pcall(function()
      line = currentLine() + 1
      MediaKit:SetLimits({ maxEntriesPerType = MediaKit.UNBOUNDED })
    end)
    assertReportedAt(
      line,
      "MediaKit:SetLimits limits.maxEntriesPerType cannot be MediaKit.UNBOUNDED:"
        .. " entries are never removed and are mirrored into LibSharedMedia",
      ok,
      value
    )
    assert.are.same(DEFAULT_LIMITS, MediaKit:GetLimits())
  end)

  it("refuses maxEntriesPerType above the ceiling at the caller", function()
    local line
    local ok, value = pcall(function()
      line = currentLine() + 1
      MediaKit:SetLimits({ maxEntriesPerType = 16385 })
    end)
    assertReportedAt(line, ENTRIES_MESSAGE, ok, value)
  end)

  it("honours a smaller maxConsumers", function()
    MediaKit:SetLimits({ maxConsumers = 2 })
    createConsumers(2)
    assert.is_not_nil(MediaKit:Defaults("Consumer 1"))
    TestEnv.expectErrorContaining("MediaKit:Defaults refuses more than 2 consumers", function()
      MediaKit:Defaults("Consumer 3")
    end)
  end)

  it("lifts maxConsumers with UNBOUNDED and reports the sentinel back", function()
    MediaKit:SetLimits({ maxConsumers = MediaKit.UNBOUNDED })
    assert.are.equal(MediaKit.UNBOUNDED, MediaKit:GetLimits().maxConsumers)
    createConsumers(1030)
    assert.is_not_nil(MediaKit:Defaults("Consumer 1030"))
  end)

  local invalidValues = {
    { label = "zero", value = 0 },
    { label = "a negative number", value = -3 },
    { label = "a fraction", value = 1.5 },
    { label = "infinity", value = math.huge },
    { label = "nan", value = 0 / 0 },
    { label = "a string", value = "64" },
    { label = "a table other than UNBOUNDED", value = {} },
  }
  for _, case in ipairs(invalidValues) do
    it("refuses " .. case.label .. " for either limit at the caller", function()
      local line
      local ok, value = pcall(function()
        line = currentLine() + 1
        MediaKit:SetLimits({ maxEntriesPerType = case.value })
      end)
      assertReportedAt(line, ENTRIES_MESSAGE, ok, value)

      ok, value = pcall(function()
        line = currentLine() + 1
        MediaKit:SetLimits({ maxConsumers = case.value })
      end)
      assertReportedAt(line, CONSUMERS_MESSAGE, ok, value)
      assert.are.same(DEFAULT_LIMITS, MediaKit:GetLimits())
    end)
  end

  it("changes nothing when one value of several is invalid", function()
    local ok = pcall(MediaKit.SetLimits, MediaKit, { maxEntriesPerType = 2000, maxConsumers = 0 })
    assert.is_false(ok)
    assert.are.same(DEFAULT_LIMITS, MediaKit:GetLimits())
  end)

  it("refuses an unknown limit and a non-string key at the caller", function()
    local line
    local ok, value = pcall(function()
      line = currentLine() + 1
      MediaKit:SetLimits({ maxEntries = 10 })
    end)
    assertReportedAt(
      line,
      "MediaKit:SetLimits limits.maxEntries is not a recognised limit",
      ok,
      value
    )

    ok, value = pcall(function()
      line = currentLine() + 1
      MediaKit:SetLimits({ 10 })
    end)
    assertReportedAt(line, "MediaKit:SetLimits limits.1 is not a recognised limit", ok, value)
  end)

  it("names a table key by its type without running its __tostring", function()
    local ran = false
    local key = setmetatable({}, {
      __tostring = function()
        ran = true
        return "caller text"
      end,
    })
    local line
    local ok, value = pcall(function()
      line = currentLine() + 1
      MediaKit:SetLimits({ [key] = 10 })
    end)
    assertReportedAt(line, "MediaKit:SetLimits limits.<table> is not a recognised limit", ok, value)
    assert.is_false(ran)
    assert.are.same(DEFAULT_LIMITS, MediaKit:GetLimits())
  end)

  it("refuses a limits argument that is not a table at the caller", function()
    local line
    local ok, value = pcall(function()
      line = currentLine() + 1
      MediaKit:SetLimits(nil)
    end)
    assertReportedAt(line, "MediaKit:SetLimits limits must be a table", ok, value)
  end)

  it("refuses a secret limit value at the caller", function()
    local secret = 64
    TestEnv.InstallSecretProbe(secret)
    local line
    local ok, value = pcall(function()
      line = currentLine() + 1
      MediaKit:SetLimits({ maxConsumers = secret })
    end)
    assertReportedAt(
      line,
      "MediaKit:SetLimits limits.maxConsumers must not be a secret value",
      ok,
      value
    )
  end)

  it("refuses SetLimits and GetLimits called without the facade", function()
    local line
    local ok, value = pcall(function()
      line = currentLine() + 1
      MediaKit.SetLimits({ maxConsumers = 5 })
    end)
    assertReportedAt(
      line,
      "MediaKit:SetLimits must be called on the MediaKit facade; use MediaKit:SetLimits(...)",
      ok,
      value
    )

    ok, value = pcall(function()
      line = currentLine() + 1
      MediaKit.GetLimits()
    end)
    assertReportedAt(
      line,
      "MediaKit:GetLimits must be called on the MediaKit facade; use MediaKit:GetLimits(...)",
      ok,
      value
    )
  end)
end)
