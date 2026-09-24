local Env = require("ProfileKitTestEnv")

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

describe("ProfileKit limits", function()
  local ProfileKit

  before_each(function()
    ProfileKit = Env.NewPackage()
  end)
  after_each(function()
    Env.Reset()
  end)

  ---Create `count` sections with distinct names.
  ---@param count integer
  local function createSections(count)
    for index = 1, count do
      assert.is_not_nil(ProfileKit:Section("section " .. index))
    end
  end

  it("reports the default maxSections through GetLimits", function()
    assert.are.same({ maxSections = 256 }, ProfileKit:GetLimits())
    assert.are.equal(ProfileKit.DEFAULT_MAX_SECTIONS, ProfileKit:GetLimits().maxSections)
  end)

  it("returns a fresh table from every GetLimits call", function()
    local first = ProfileKit:GetLimits()
    first.maxSections = 1
    assert.are_not.equal(first, ProfileKit:GetLimits())
    assert.are.equal(256, ProfileKit:GetLimits().maxSections)
  end)

  it("honours a larger maxSections set through SetLimits", function()
    ProfileKit:SetLimits({ maxSections = 300 })
    assert.are.same({ maxSections = 300 }, ProfileKit:GetLimits())
    createSections(300)
    local section, reason = ProfileKit:Section("section 301")
    assert.is_nil(section)
    assert.are.equal("capped", reason)
  end)

  it("honours a smaller maxSections without removing existing sections", function()
    createSections(3)
    ProfileKit:SetLimits({ maxSections = 2 })
    assert.is_not_nil(ProfileKit:Section("section 3"))
    local _, reason = ProfileKit:Section("new")
    assert.are.equal("capped", reason)
    assert.are.equal(3, #ProfileKit:Report())
  end)

  it("lifts the limit with UNBOUNDED and reports the sentinel back", function()
    ProfileKit:SetLimits({ maxSections = ProfileKit.UNBOUNDED })
    assert.are.equal(ProfileKit.UNBOUNDED, ProfileKit:GetLimits().maxSections)
    createSections(ProfileKit.DEFAULT_MAX_SECTIONS + 10)
    assert.are.equal(266, #ProfileKit:Report())
  end)

  it("restores a bound after UNBOUNDED", function()
    ProfileKit:SetLimits({ maxSections = ProfileKit.UNBOUNDED })
    ProfileKit:SetLimits({ maxSections = 1 })
    createSections(1)
    local _, reason = ProfileKit:Section("second")
    assert.are.equal("capped", reason)
  end)

  it("accepts an empty table and changes nothing", function()
    ProfileKit:SetLimits({})
    assert.are.same({ maxSections = 256 }, ProfileKit:GetLimits())
  end)

  local invalidValues = {
    { label = "zero", value = 0 },
    { label = "a negative number", value = -1 },
    { label = "a fraction", value = 2.5 },
    { label = "infinity", value = math.huge },
    { label = "nan", value = 0 / 0 },
    { label = "a string", value = "10" },
    { label = "a table other than UNBOUNDED", value = {} },
  }
  for _, case in ipairs(invalidValues) do
    it("refuses " .. case.label .. " at the caller and changes nothing", function()
      local line
      local ok, value = pcall(function()
        line = currentLine() + 1
        ProfileKit:SetLimits({ maxSections = case.value })
      end)
      assertReportedAt(
        line,
        "ProfileKit:SetLimits limits.maxSections must be a positive integer or ProfileKit.UNBOUNDED",
        ok,
        value
      )
      assert.are.same({ maxSections = 256 }, ProfileKit:GetLimits())
    end)
  end

  it("refuses an unknown limit at the caller before changing a valid one", function()
    local line
    local ok, value = pcall(function()
      line = currentLine() + 1
      ProfileKit:SetLimits({ maxSections = 10, maxReports = 5 })
    end)
    assertReportedAt(
      line,
      "ProfileKit:SetLimits limits.maxReports is not a recognised limit",
      ok,
      value
    )
    assert.are.same({ maxSections = 256 }, ProfileKit:GetLimits())
  end)

  it("refuses a non-string key at the caller", function()
    local line
    local ok, value = pcall(function()
      line = currentLine() + 1
      ProfileKit:SetLimits({ 5 })
    end)
    assertReportedAt(line, "ProfileKit:SetLimits limits.1 is not a recognised limit", ok, value)
  end)

  it("refuses a limits argument that is not a table at the caller", function()
    local line
    local ok, value = pcall(function()
      line = currentLine() + 1
      ProfileKit:SetLimits(256)
    end)
    assertReportedAt(line, "ProfileKit:SetLimits limits must be a table", ok, value)
  end)

  it("refuses SetLimits and GetLimits called without the facade", function()
    local line
    local ok, value = pcall(function()
      line = currentLine() + 1
      ProfileKit.SetLimits({ maxSections = 5 })
    end)
    assertReportedAt(
      line,
      "ProfileKit:SetLimits must be called on the ProfileKit facade; use ProfileKit:SetLimits(...)",
      ok,
      value
    )

    ok, value = pcall(function()
      line = currentLine() + 1
      ProfileKit.GetLimits()
    end)
    assertReportedAt(
      line,
      "ProfileKit:GetLimits must be called on the ProfileKit facade; use ProfileKit:GetLimits(...)",
      ok,
      value
    )
  end)
end)
