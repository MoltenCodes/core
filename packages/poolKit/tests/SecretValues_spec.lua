local Env = require("PoolKitTestEnv")

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

local function create()
  return {}
end

---Load Registry and PoolKit on the `mainline` host, whose `issecretvalue`
---reports the values `NewSecretValue` returns.
---@return table PoolKit
local function loadOnSecretHost()
  Env.Reset()
  Env.SetWowProfile("mainline")
  Env.InstallWowApi()
  require("Registry")
  return require("PoolKit")
end

describe("PoolKit and secret values", function()
  local PoolKit
  before_each(function()
    PoolKit = loadOnSecretHost()
  end)
  after_each(Env.Reset)

  it("refuses every secret constructor option at the caller's line", function()
    local fields = {
      "maxRetained",
      "strict",
      "prewarm",
      "maxActiveWarning",
      "generation",
      "maxCreated",
      "maxActive",
      "maxWaiting",
      "strictReset",
    }
    for _, field in ipairs(fields) do
      local line
      local ok, value = pcall(function()
        line = currentLine() + 1
        PoolKit:New({ create = create, [field] = Env.NewSecretValue() })
      end)
      assertReportedAt(line, "PoolKit:New " .. field .. " must not be a secret value", ok, value)
    end

    local tableLine
    local tableOk, tableValue = pcall(function()
      tableLine = currentLine() + 1
      PoolKit:NewTablePool({ maxRetained = Env.NewSecretValue() })
    end)
    assertReportedAt(
      tableLine,
      "PoolKit:NewTablePool maxRetained must not be a secret value",
      tableOk,
      tableValue
    )
  end)

  it("refuses secret pool-method arguments at the caller's line", function()
    local pool = PoolKit:New({ create = create, maxCreated = 4 })
    local secret = Env.NewSecretValue()
    local calls = {
      { "Prewarm", "PoolKit.Pool:Prewarm count" },
      { "Trim", "PoolKit.Pool:Trim retainCount" },
      { "SetMaxRetained", "PoolKit.Pool:SetMaxRetained maxRetained" },
      { "SetGeneration", "PoolKit.Pool:SetGeneration generation" },
      { "SetMaxCreated", "PoolKit.Pool:SetMaxCreated maxCreated" },
    }
    for _, call in ipairs(calls) do
      local method = pool[call[1]]
      local line
      local ok, value = pcall(function()
        line = currentLine() + 1
        method(pool, secret)
      end)
      assertReportedAt(line, call[2] .. " must not be a secret value", ok, value)
    end
    assert.are.equal(0, pool:GetAvailableCount())
  end)

  it("still accepts ordinary options and absent ones on a host with secret values", function()
    local pool = PoolKit:New({
      create = create,
      reset = function() end,
      strictReset = true,
      maxRetained = PoolKit.UNBOUNDED,
      prewarm = 1,
    })
    assert.are.equal(1, pool:GetAvailableCount())
    local object = pool:Acquire()
    pool:Release(object)
    assert.are.equal(1, pool:Trim())
    assert.are.equal(
      PoolKit.UNBOUNDED,
      PoolKit:NewTablePool():SetMaxRetained(PoolKit.UNBOUNDED):GetMaxRetained()
    )
  end)
end)
