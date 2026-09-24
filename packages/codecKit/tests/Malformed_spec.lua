local TestEnv = require("CodecKitTestEnv")

-- The fixed failure vocabulary documented in docs/API.md.
local REASONS = {
  cycle = true,
  unsupportedType = true,
  maxDepth = true,
  maxValues = true,
  maxStringLength = true,
  maxOutputBytes = true,
  truncated = true,
  trailingData = true,
  unsupportedVersion = true,
  malformedHeader = true,
  channelMismatch = true,
  forbiddenByte = true,
  malformedEscape = true,
  malformedPrint = true,
  malformedDeflate = true,
  unknownType = true,
  malformedNumber = true,
  invalidKey = true,
  duplicateKey = true,
  nilValue = true,
  multipleValues = true,
}

describe("CodecKit malformed input", function()
  local CodecKit
  before_each(function()
    CodecKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  ---Call a decoding method under `pcall` and assert it returned `true` or a
  ---documented reason instead of raising.
  local function assertContained(method, input)
    local called, ok, reason = pcall(CodecKit[method], CodecKit, input)
    assert.is_true(called, method .. " raised: " .. tostring(ok))
    assert.is_boolean(ok)
    if not ok then
      assert.is_true(REASONS[reason] == true, method .. " returned " .. tostring(reason))
    end
    return ok, reason
  end

  it("refuses every malformed serialised shape with its reason", function()
    local cases = {
      { "", "truncated" },
      { "00", "unknownType" },
      { "0c", "unknownType" },
      { "ff", "unknownType" },
      { "04", "truncated" },
      { "0480", "truncated" },
      { "048000", "malformedNumber" }, -- overlong
      { "04808080808080808001", "malformedNumber" }, -- nine bytes
      { "04ffffffffffffff7f", "malformedNumber" }, -- above 2^53
      { "048180808080808010", "malformedNumber" }, -- 2^53 + 1
      { "0500", "malformedNumber" }, -- negative zero integer
      { "063ff8", "truncated" },
      { "0705686868", "truncated" },
      { "07", "truncated" },
      { "08ffffff0f", "truncated" },
      { "0801", "truncated" },
      { "080101", "nilValue" },
      { "0901070161", "truncated" },
      { "090107016101", "nilValue" },
      { "09010103", "invalidKey" },
      { "0901067ff800000000000003", "invalidKey" },
      { "09020701610307016102", "duplicateKey" },
      { "0a01040101040103", "duplicateKey" },
      { "0a010401", "truncated" },
      { "0303", "trailingData" },
      { "0b00", "multipleValues" },
    }
    for index = 1, #cases do
      local ok, reason = assertContained("Deserialize", TestEnv.Unhex(cases[index][1]))
      assert.is_false(ok, "case " .. index)
      assert.are.equal(cases[index][2], reason, "case " .. index)
    end
  end)

  it("accepts 2^53 exactly and the canonical maximum varint", function()
    local ok, value = CodecKit:Deserialize(TestEnv.Unhex("048080808080808010"))
    assert.is_true(ok)
    assert.are.equal(2 ^ 53, value)
  end)

  it("refuses every proper prefix of a valid frame in every combination", function()
    -- Mixed tables are the layout under test.
    -- selene: allow(mixed_table)
    local value = { "prefix", 1.25, { nested = { true, false } }, [99] = "sparse", "\0|\255" }
    for _, compress in ipairs({ "none", "deflate" }) do
      for _, channel in ipairs({ "none", "addon", "print" }) do
        local _, text = CodecKit:Encode(value, { compress = compress, channel = channel })
        for length = 0, #text - 1 do
          local ok = assertContained("Decode", text:sub(1, length))
          assert.is_false(ok, compress .. "/" .. channel .. " prefix " .. length)
        end
        assert.is_true((CodecKit:Decode(text)))
      end
    end
  end)

  it("never raises on 2000 random byte strings", function()
    local random = TestEnv.NewRandom(2000)
    local methods = {
      "Decode",
      "DecodeMany",
      "Deserialize",
      "Decompress",
      "DecodeForAddon",
      "DecodeForPrint",
    }
    local prefixes = { "", "\1\1", "\1\3", "\1\5", "\1\7", "!", "\8", "\9", "\10" }
    for round = 1, 2000 do
      local input = prefixes[round % #prefixes + 1] .. TestEnv.RandomBytes(random, random(48))
      for index = 1, #methods do
        assertContained(methods[index], input)
      end
    end
  end)

  it("never raises on valid frames with random bytes changed", function()
    local random = TestEnv.NewRandom(1996)
    local value = { list = { 1, 2, 3, 4.5 }, text = string.rep("mutation ", 20), flag = true }
    local frames = {}
    for _, compress in ipairs({ "none", "deflate" }) do
      for _, channel in ipairs({ "none", "addon", "print" }) do
        frames[#frames + 1] =
          select(2, CodecKit:Encode(value, { compress = compress, channel = channel }))
      end
    end
    for round = 1, 600 do
      local frame = frames[round % #frames + 1]
      local bytes = { frame:byte(1, -1) }
      for _ = 1, 1 + random(3) do
        bytes[random(#bytes) + 1] = random(256)
      end
      assertContained("Decode", string.char(unpack(bytes)))
    end
  end)

  it("never raises on random printable text", function()
    local random = TestEnv.NewRandom(85)
    local alphabet = CodecKit.PRINT_ALPHABET .. " \n"
    for _ = 1, 500 do
      local characters = {}
      for index = 1, random(60) do
        local position = random(#alphabet) + 1
        characters[index] = alphabet:sub(position, position)
      end
      assertContained("Decode", table.concat(characters))
    end
  end)
end)
