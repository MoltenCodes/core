local TestEnv = require("ApiKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src

---Return the line number of the statement that called this helper.
---@return integer line
local function currentLine()
  return debug.getinfo(2, "l").currentline
end

---Make the host's `issecretvalue` report exactly `secret`. A plain string or
---number stands in for a secret one: the facade has to ask the probe before
---it compares the value, does arithmetic on it or uses it as a key, because
---without the probe the stand-in would pass as a valid argument.
---@param secret any
local function markSecret(secret)
  -- The facade reads this host global at call time, so the spec installs it in the global table.
  -- selene: allow(global_usage)
  rawset(_G, "issecretvalue", function(value)
    return rawequal(value, secret)
  end)
end

describe("ApiKit and secret values", function()
  after_each(TestEnv.Reset)

  it("refuses a secret flavour id before it is used as a key", function()
    local ApiKit = TestEnv.NewPackageFor("retail")
    markSecret("retail")
    local runs = 0
    local line
    local ok, value = pcall(function()
      line = currentLine() + 1
      ApiKit:RegisterFlavor("retail", function()
        runs = runs + 1
      end)
    end)
    assert.is_false(ok)
    assert.are.equal(
      SOURCE .. ":" .. line .. ": ApiKit:RegisterFlavor flavor must not be a secret value",
      value
    )
    assert.are.equal(0, runs)

    ok, value = pcall(function()
      line = currentLine() + 1
      ApiKit:GetMetadataBuild("retail")
    end)
    assert.is_false(ok)
    assert.are.equal(
      SOURCE .. ":" .. line .. ": ApiKit:GetMetadataBuild flavor must not be a secret value",
      value
    )
  end)

  it("refuses a secret info.build before the integer test", function()
    local ApiKit = TestEnv.NewPackageFor("retail")
    markSecret(69933)
    local runs = 0
    local line
    local ok, value = pcall(function()
      line = currentLine() + 1
      ApiKit:RegisterFlavor("retail", function()
        runs = runs + 1
      end, { version = "12.1.0", build = 69933 })
    end)
    assert.is_false(ok)
    assert.are.equal(
      SOURCE .. ":" .. line .. ": ApiKit:RegisterFlavor info.build must not be a secret value",
      value
    )
    assert.are.equal(0, runs)
    assert.are.same({}, { ApiKit:GetMetadataBuild("retail") })
  end)

  it("stores a secret info.version, which is only handed back", function()
    local ApiKit = TestEnv.NewPackageFor("retail")
    markSecret("12.1.0")
    assert.is_true(
      ApiKit:RegisterFlavor("retail", function() end, { version = "12.1.0", build = 1 })
    )
    assert.are.same({ "12.1.0", 1 }, { ApiKit:GetMetadataBuild("retail") })
  end)

  it("accepts every argument when the host has no issecretvalue", function()
    local ApiKit = TestEnv.NewPackageFor("retail")
    -- selene: allow(global_usage)
    rawset(_G, "issecretvalue", nil)
    assert.is_true(ApiKit:RegisterFlavor("retail", function() end, { build = 69933 }))
    assert.are.same({ nil, 69933 }, { ApiKit:GetMetadataBuild("retail") })
  end)
end)
