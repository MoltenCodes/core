local TestEnv = require("CodecKitTestEnv")

-- Each workload repeats its operation many times, so a single allocation per
-- call would show up as tens of kilobytes. The threshold leaves room for the
-- few bytes the measurement itself can cost.
local ITERATIONS = 2000
local THRESHOLD_KILOBYTES = 1

describe("CodecKit allocation #allocation", function()
  local CodecKit
  before_each(function()
    CodecKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  local small = { id = 7, name = "bar", flags = { true, false }, scale = 1.5, [2 ^ 60] = -0.25 }

  ---Run `operation` twice to warm the pool and intern its strings, then
  ---measure `ITERATIONS` more calls.
  local function measure(operation)
    operation()
    operation()
    return TestEnv.AllocatedKilobytes(function()
      for _ = 1, ITERATIONS do
        operation()
      end
    end)
  end

  it("allocates nothing to encode a small table again, on every channel", function()
    for _, channel in ipairs({ "none", "addon", "print" }) do
      local options = { channel = channel }
      local allocated = measure(function()
        CodecKit:Encode(small, options)
      end)
      assert.is_true(
        allocated < THRESHOLD_KILOBYTES,
        channel .. " allocated " .. allocated .. " KiB"
      )
    end
  end)

  it("allocates nothing to decode a scalar frame again", function()
    local frames = {}
    for _, value in ipairs({ true, 42, -1.5, "name" }) do
      frames[#frames + 1] = select(2, CodecKit:Encode(value, { channel = "addon" }))
    end
    local allocated = measure(function()
      for index = 1, #frames do
        CodecKit:Decode(frames[index])
      end
    end)
    assert.is_true(allocated < THRESHOLD_KILOBYTES, "Decode allocated " .. allocated .. " KiB")
  end)

  it("allocates only the decoded tables on a small round trip", function()
    local options = { channel = "addon" }
    local allocated = measure(function()
      local _, text = CodecKit:Encode(small, options)
      CodecKit:Decode(text)
    end)
    -- Two tables per round trip, a few hundred bytes at most.
    assert.is_true(allocated / ITERATIONS < 0.5, "round trip allocated " .. allocated .. " KiB")
  end)

  it("allocates little beyond its output to encode a larger payload", function()
    -- The writer builds the frame straight from one reused buffer: besides
    -- the frame itself only `table.concat`'s own working buffer is left,
    -- where revision 4 also built the unescaped body, the escaped body and
    -- every byte run as separate strings (about 3.6 times the output).
    local records = {}
    for index = 1, 50 do
      records[index] =
        { spell = 100000 + index, rank = index, name = "Spell " .. index, cooldown = 1.5 * index }
    end
    local options = { channel = "addon" }
    local serial = 0
    local function encodeChanged()
      serial = serial + 1
      records[1].rank = serial
      return select(2, CodecKit:Encode(records, options))
    end
    local length = #encodeChanged()
    encodeChanged()
    local calls = 200
    local allocated = TestEnv.AllocatedKilobytes(function()
      for _ = 1, calls do
        encodeChanged()
      end
    end)
    local perCall = allocated * 1024 / calls
    assert.is_true(
      perCall < length * 1.5 + 128,
      "encoding a " .. length .. "-byte frame allocated " .. perCall .. " bytes"
    )
  end)

  it("decodes an addon frame with nothing to unescape without copying it", function()
    -- Only each decoded 20000-byte string is new: the body is read in place.
    -- The frames differ, so no decoded string can be an interned copy of an
    -- earlier one.
    local calls = 50
    local frames = {}
    for index = 1, calls do
      local payload = string.format("%05d", index) .. string.rep("abcd", 4999)
      frames[index] = select(2, CodecKit:Encode(payload, { channel = "addon" }))
      assert.is_nil(frames[index]:find("[%z\n\r|\255]", 3))
    end
    CodecKit:Decode(frames[1])
    local allocated = TestEnv.AllocatedKilobytes(function()
      for index = 1, calls do
        CodecKit:Decode(frames[index])
      end
    end)
    local perCall = allocated * 1024 / calls
    assert.is_true(perCall < 20001 * 1.2, "Decode allocated " .. perCall .. " bytes per call")
  end)

  it("allocates nothing to serialise or deserialise a scalar again", function()
    local bytes = select(2, CodecKit:Serialize(12345.5))
    local allocated = measure(function()
      CodecKit:Serialize(12345.5)
      CodecKit:Serialize("name")
      CodecKit:Deserialize(bytes)
    end)
    assert.is_true(allocated < THRESHOLD_KILOBYTES, "allocated " .. allocated .. " KiB")
  end)

  it("allocates nothing again after a call raised mid-way or an upgrade", function()
    -- A probe that raises leaves the idle work record taken; the next call
    -- builds a fresh one and keeps it.
    -- selene: allow(global_usage)
    rawset(_G, "issecretvalue", function(value)
      if value == "boom" then
        error("probe failed", 0)
      end
      return false
    end)
    assert.is_false((pcall(CodecKit.Encode, CodecKit, { "a", "boom" })))
    -- selene: allow(global_usage)
    rawset(_G, "issecretvalue", nil)
    local options = { channel = "addon" }
    local allocated = measure(function()
      CodecKit:Encode(small, options)
    end)
    assert.is_true(allocated < THRESHOLD_KILOBYTES, "after a failure " .. allocated .. " KiB")

    -- An in-place upgrade from revision 4 builds the newer revision's record.
    TestEnv.Reset()
    require("Registry")
    require("PoolKit")
    TestEnv.LoadRevision(4)
    package.loaded["CodecKit"] = nil
    local upgraded = require("CodecKit")
    allocated = measure(function()
      upgraded:Encode(small, options)
    end)
    assert.is_true(allocated < THRESHOLD_KILOBYTES, "after the upgrade " .. allocated .. " KiB")
  end)

  it("allocates nothing to compress a short message again", function()
    local message = string.rep("sync:42;", 4) -- 32 bytes
    local allocated = measure(function()
      CodecKit:Compress(message)
    end)
    assert.is_true(allocated < THRESHOLD_KILOBYTES, "Compress allocated " .. allocated .. " KiB")
  end)

  it("returns every leased table and retains a bounded number", function()
    local pool = CodecKit._state.pool
    local big = {}
    for index = 1, 5000 do
      big[index] = { index, tostring(index) }
    end
    for _ = 1, 3 do
      local _, text = CodecKit:Encode(big, { compress = "deflate", channel = "print" })
      assert.is_true((CodecKit:Decode(text)))
      CodecKit:Decode("\1\1\8\5")
      CodecKit:Encode({ print })
    end
    assert.are.equal(0, pool:GetActiveCount())
    assert.is_true(pool:GetAvailableCount() <= 16)
  end)
end)
