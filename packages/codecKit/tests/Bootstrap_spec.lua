local TestEnv = require("CodecKitTestEnv")

describe("CodecKit bootstrap", function()
  after_each(TestEnv.Reset)

  it("returns the same facade on duplicate embedded load", function()
    local CodecKit = TestEnv.NewPackage()
    CodecKit:SetLimits({ maxDepth = 5 })
    local reloaded = TestEnv.ReloadPackage()
    assert.are.equal(CodecKit, reloaded)
    assert.are.equal(5, reloaded:GetLimits().maxDepth)
  end)

  it("publishes through Registry with the format version and alphabet", function()
    local CodecKit, Registry = TestEnv.NewPackage()
    local registered, revision = Registry:Get("codecKit", 1)
    assert.are.equal(CodecKit, registered)
    assert.are.equal(CodecKit.REVISION, revision)
    assert.are.equal(1, CodecKit.FORMAT_VERSION)
    assert.are.equal(85, #CodecKit.PRINT_ALPHABET)
  end)

  it("does not reinterpret private state owned by a newer compatible revision", function()
    local CodecKit, Registry = TestEnv.NewPackage()
    local shippedRevision = CodecKit.REVISION
    local upgraded, previous = Registry:Register("codecKit", 1, 99)
    assert.are.equal(CodecKit, upgraded)
    assert.are.equal(shippedRevision, previous)

    rawset(CodecKit, "REVISION", 99)
    rawset(CodecKit, "_state", { schema = 999 })
    package.loaded["CodecKit"] = nil

    local reloaded = require("CodecKit")
    assert.are.equal(CodecKit, reloaded)
    assert.are.equal(99, reloaded.REVISION)
  end)

  it("upgrades in place and keeps the limits, the pool and the wire format", function()
    local CodecKit = TestEnv.NewPackage()
    local sentinel = CodecKit.UNBOUNDED
    CodecKit:SetLimits({
      maxValues = 1000,
      maxStringLength = sentinel,
      maxListValues = 6000,
    })
    local pool = CodecKit._state.pool
    local value = { "upgrade", 2 ^ 60, { nested = true } }
    local _, before = CodecKit:Encode(value, { compress = "deflate", channel = "print" })

    local nextRevision = CodecKit.REVISION + 1
    local upgraded = TestEnv.LoadRevision(nextRevision)
    assert.are.equal(CodecKit, upgraded)
    assert.are.equal(nextRevision, upgraded.REVISION)
    assert.are.equal(nextRevision, upgraded._state.runtimeRevision)
    assert.are.equal(pool, upgraded._state.pool)
    assert.are.equal(sentinel, upgraded.UNBOUNDED)
    assert.are.equal(sentinel, upgraded._state.unbounded)
    local limits = upgraded:GetLimits()
    assert.are.equal(1000, limits.maxValues)
    assert.are.equal(sentinel, limits.maxStringLength)
    assert.are.equal(6000, limits.maxListValues)
    assert.is_true((upgraded:Serialize(string.rep("x", 70000))))

    local ok, decoded = upgraded:Decode(before)
    assert.is_true(ok)
    assert.are.same(value, decoded)
    local _, after = upgraded:Encode(value, { compress = "deflate", channel = "print" })
    assert.are.equal(before, after)
    assert.are.equal(0, pool:GetActiveCount())
  end)

  it("upgrades a revision 1 copy in place and refuses secret options afterwards", function()
    TestEnv.Reset()
    require("Registry")
    require("PoolKit")
    local older = TestEnv.LoadRevision(1)
    assert.are.equal(1, older.REVISION)
    older:SetLimits({ maxValues = older.UNBOUNDED, maxDepth = 9 })
    local pool = older._state.pool
    local _, frame = older:Encode({ "kept" }, { channel = "addon" })

    package.loaded["CodecKit"] = nil
    local CodecKit = require("CodecKit")
    assert.are.equal(older, CodecKit)
    assert.is_true(CodecKit.REVISION > 1)
    assert.are.equal(CodecKit.REVISION, CodecKit._state.runtimeRevision)
    assert.are.equal(pool, CodecKit._state.pool)
    local limits = CodecKit:GetLimits()
    assert.are.equal(CodecKit.UNBOUNDED, limits.maxValues)
    assert.are.equal(9, limits.maxDepth)
    local ok, decoded = CodecKit:Decode(frame)
    assert.is_true(ok)
    assert.are.same({ "kept" }, decoded)

    TestEnv.InstallSecretProbe({ [3] = true })
    TestEnv.expectErrorContaining(
      "CodecKit:Encode options.level must not be a secret value",
      function()
        CodecKit:Encode(1, { level = 3 })
      end
    )
  end)

  it("upgrades a revision 2 copy in place and still accepts absent options", function()
    TestEnv.Reset()
    require("Registry")
    require("PoolKit")
    local older = TestEnv.LoadRevision(2)
    assert.are.equal(2, older.REVISION)
    older:SetLimits({ maxStringLength = older.UNBOUNDED, maxDepth = 12 })
    local state = older._state
    local pool = state.pool
    local _, frame = older:Encode({ "kept" }, { compress = "deflate" })

    package.loaded["CodecKit"] = nil
    local CodecKit = require("CodecKit")
    assert.are.equal(older, CodecKit)
    assert.is_true(CodecKit.REVISION > 2)
    assert.are.equal(state, CodecKit._state)
    assert.are.equal(CodecKit.REVISION, CodecKit._state.runtimeRevision)
    assert.are.equal(pool, CodecKit._state.pool)
    local limits = CodecKit:GetLimits()
    assert.are.equal(CodecKit.UNBOUNDED, limits.maxStringLength)
    assert.are.equal(12, limits.maxDepth)

    local ok, decoded = CodecKit:Decode(frame, nil)
    assert.is_true(ok)
    assert.are.same({ "kept" }, decoded)
    assert.is_true((CodecKit:Compress("bytes", nil)))
    CodecKit:SetLimits({ maxDepth = 10, maxValues = nil })
    assert.are.equal(10, CodecKit:GetLimits().maxDepth)
    assert.are.equal(0, pool:GetActiveCount())
  end)

  it("requires Registry", function()
    TestEnv.Reset()
    local ok, value = pcall(require, "CodecKit")
    assert.is_false(ok)
    assert.is_true(tostring(value):find("Registry API 2", 1, true) ~= nil)
  end)

  it("requires PoolKit", function()
    TestEnv.Reset()
    require("Registry")
    local ok, value = pcall(TestEnv.requireAfterFailedLoad, "CodecKit")
    assert.is_false(ok)
    assert.is_true(
      tostring(value):find("MoltenCodes CodecKit requires PoolKit API 1", 1, true) ~= nil
    )
  end)

  it("refuses an incomplete facade left by an earlier failed load", function()
    TestEnv.Reset()
    local Registry = require("Registry")
    require("PoolKit")
    Registry:Register("codecKit", 1, 1)

    local ok, value = pcall(TestEnv.requireAfterFailedLoad, "CodecKit")
    assert.is_false(ok)
    assert.is_true(tostring(value):find("MoltenCodes CodecKit", 1, true) ~= nil)
  end)
end)
