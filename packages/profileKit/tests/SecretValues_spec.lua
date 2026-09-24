local Env = require("ProfileKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src

---Return the line number of the statement that called this helper.
---@return integer line
local function currentLine()
  return debug.getinfo(2, "l").currentline
end

describe("ProfileKit secret values", function()
  local ProfileKit
  local secret

  ---Load the module chain on a host whose `issecretvalue` reports `secret`.
  ---ProfileKit binds the probe once at load, so it is installed first.
  before_each(function()
    Env.Reset()
    Env.InstallWowApi()
    secret = Env.NewSecretValue()
    -- selene: allow(global_usage)
    rawset(_G, "issecretvalue", function(value)
      return rawequal(value, secret)
    end)
    require("Registry")
    ProfileKit = require("ProfileKit")
  end)
  after_each(function()
    Env.Reset()
  end)

  it("refuses a secret maxSections at the caller before comparing it", function()
    local line
    local ok, value = pcall(function()
      line = currentLine() + 1
      ProfileKit:SetLimits({ maxSections = secret })
    end)
    assert.is_false(ok)
    assert.are.equal(
      SOURCE
        .. ":"
        .. line
        .. ": ProfileKit:SetLimits limits.maxSections must be a positive integer or ProfileKit.UNBOUNDED",
      value
    )
    assert.are.equal(ProfileKit.DEFAULT_MAX_SECTIONS, ProfileKit:GetLimits().maxSections)
  end)

  it("still accepts a plain positive integer and UNBOUNDED", function()
    ProfileKit:SetLimits({ maxSections = 8 })
    assert.are.equal(8, ProfileKit:GetLimits().maxSections)
    ProfileKit:SetLimits({ maxSections = ProfileKit.UNBOUNDED })
    assert.are.equal(ProfileKit.UNBOUNDED, ProfileKit:GetLimits().maxSections)
  end)

  it("refuses a secret receiver as a non-facade receiver", function()
    local line
    local ok, value = pcall(function()
      line = currentLine() + 1
      ProfileKit.GetLimits(secret)
    end)
    assert.is_false(ok)
    assert.are.equal(
      SOURCE
        .. ":"
        .. line
        .. ": ProfileKit:GetLimits must be called on the ProfileKit facade; use ProfileKit:GetLimits(...)",
      value
    )
  end)
end)

describe("ProfileKit secret section names", function()
  -- A plain string stands in for a secret string: without the probe asked
  -- first, it would pass as a valid name, be compared with "" and be used as
  -- a key of the section index.
  local SECRET_NAME = "secret.name"
  local ProfileKit

  before_each(function()
    Env.Reset()
    Env.InstallWowApi()
    -- ProfileKit binds the probe once at load, so it is installed first.
    -- selene: allow(global_usage)
    rawset(_G, "issecretvalue", function(value)
      return rawequal(value, SECRET_NAME)
    end)
    require("Registry")
    ProfileKit = require("ProfileKit")
  end)
  after_each(function()
    Env.Reset()
  end)

  ---Assert that `action` raised `message` at `line` of this spec file.
  ---@param line integer
  ---@param message string
  ---@param ok boolean
  ---@param value any
  local function assertRefusedAt(line, message, ok, value)
    assert.is_false(ok)
    assert.are.equal(SOURCE .. ":" .. line .. ": " .. message, value)
  end

  it("refuses a secret name in Section at the caller, creating nothing", function()
    local line
    local ok, value = pcall(function()
      line = currentLine() + 1
      ProfileKit:Section(SECRET_NAME)
    end)
    assertRefusedAt(line, "ProfileKit:Section name must not be a secret value", ok, value)
    assert.are.same({}, ProfileKit:Report())
  end)

  it("refuses a secret name in the disabled Measure without calling fn", function()
    local calls = 0
    local line
    local ok, value = pcall(function()
      line = currentLine() + 1
      ProfileKit:Measure(SECRET_NAME, function()
        calls = calls + 1
      end)
    end)
    assertRefusedAt(line, "ProfileKit:Measure name must not be a secret value", ok, value)
    assert.are.equal(0, calls)
  end)

  it("refuses a secret name in the enabled Measure without calling fn", function()
    assert.is_true(ProfileKit:Enable())
    local calls = 0
    local line
    local ok, value = pcall(function()
      line = currentLine() + 1
      ProfileKit:Measure(SECRET_NAME, function()
        calls = calls + 1
      end)
    end)
    assertRefusedAt(line, "ProfileKit:Measure name must not be a secret value", ok, value)
    assert.are.equal(0, calls)
    assert.are.same({}, ProfileKit:Report())
  end)

  it("still refuses an empty name and accepts a plain one", function()
    Env.expectErrorContaining("ProfileKit:Section name must be a non-empty string", function()
      ProfileKit:Section("")
    end)
    assert.is_table(ProfileKit:Section("plain"))
    assert.are.same({ 1, 2 }, {
      ProfileKit:Measure("plain", function()
        return 1, 2
      end),
    })
  end)
end)
