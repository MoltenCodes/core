local TestEnv = require("CodecKitTestEnv")

-- The native compression path: `C_EncodingUtil.CompressString` with
-- `Enum.CompressionMethod.Deflate` where the client has it. The stand-in in
-- `CodecKitTestEnv` writes stored blocks, an encoder independent of
-- CodecKit's, so its bytes differ from the Lua compressor's and the specs can
-- tell which path ran.

-- 523 bytes of addon-like prose, compressible enough that every encoder makes
-- Huffman blocks of it.
local TEXT = string.rep("Raid frames refresh when a member joins, leaves or changes role; ", 3)
  .. string.rep(
    "the profile export keeps every aura, cooldown and spell setting the addon stores. ",
    4
  )

-- What revision 6, which had no native path, wrote for `TEXT` at levels 1, 6
-- and 9 (levels 6 and 9 agree on this input).
local REVISION_6_LEVEL_1 = [[
e590d10dc230104357f100150bb0051b1c8ddb04925c74175ad89e9425f8e8aff5fc24fb2629603129
741817a347ec911582c272a7e1a1a9fa844cd906a386394a5d0f5c33aff8bfa047a2992e29137c37b5
8e27d91cdc681fc8cb64c2ac9a83ee63570df0c69ce1ec3dd515475f42d00aef3a0eb8fc92f319bf
]]
local REVISION_6_LEVEL_6 = [[
e5cdd115c2201044d156a6801c1bb00b3b58c310506039bb9868f7a24df8e1ff9b3b17c901d1a4d261
8c464f38121b0495f54ac34d73f30585b2cf460d6b92b67d722d3ce3f7c04844378db9107c76b5813b
d91ddc692fc8c364c1aa5a821e536d01de590a9c63e4b67df7128236f8d0797ffa53f10d
]]

-- What zlib 1.3 (`compressobj(level, DEFLATED, -15)`) writes for `TEXT`: the
-- kind of stream a client built on zlib returns. Levels 6 and 9 agree.
local ZLIB_LEVEL_1 = [[
e590d10dc230104357f100150bb04537381aa70924b9e82eb4b03d2d4bf0c1aff5fc247b961c104d
2a1dc668f4843db14150596f34dc35379f5028dbc1a86149d2d613d7c22be69f0b4622ba69cc85e0
abab0d3cc8eee0467b439e261316d512743f76b500ef2c05ce31725b71f625046df0a1c701976ff2
7fc60f
]]
local ZLIB_LEVEL_6 = [[
e5cdd115c2201044d156a6801c1bb08b74b086216080e5ec62a2dd1b6dc20fffdfdc99250744934a
87311a3de1486c1054d61b0d77cdcd2714ca7e366a5892b4f5936be115f3cf8191886e1a7321f8ec
6a031bd91ddc692fc8c364c2a25a821ea7da02bcb31438c7c86dfdee25046df0a1e7fde54fc537
]]

-- zlib's level 6 stream for `TEXT` serialised as a string value: the body
-- of the frame `Encode(TEXT, { compress = "deflate" })` on a zlib client.
local ZLIB_SERIALIZED_LEVEL_6 = [[
e5cdc111c2301043d10b33b4a1023234401774b0c44a6c70bc9e5d93400d691a43131cb87f3d1df7
c34552c064b2d0619c8c1eb1451608162e571a6e9a8a0fc894b5376a18a394f9936be619bf075a24
aae99432c167556bb893d5c195f6823c4c068caa39e8d6d512e09539c3d95a2af3772f21688137ed
f7a73f15df
]]

-- The client's three levels as `EncodingUtilDocumentation.lua` numbers them.
local SPEED, DEFAULT, SIZE = 1, 0, 2

describe("CodecKit native compression", function()
  local CodecKit
  before_each(function()
    CodecKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("compresses as revision 6 did without C_EncodingUtil", function()
    assert.are.equal(
      TestEnv.Hex(TestEnv.Unhex(REVISION_6_LEVEL_1)),
      TestEnv.Hex(select(2, CodecKit:Compress(TEXT, { level = 1 })))
    )
    assert.are.equal(
      TestEnv.Hex(TestEnv.Unhex(REVISION_6_LEVEL_6)),
      TestEnv.Hex(select(2, CodecKit:Compress(TEXT)))
    )
    assert.are.equal(
      TestEnv.Hex(TestEnv.Unhex(REVISION_6_LEVEL_6)),
      TestEnv.Hex(select(2, CodecKit:Compress(TEXT, { level = 9 })))
    )
  end)

  it("compresses in Lua when C_EncodingUtil has no CompressString function", function()
    local _, expected = CodecKit:Compress(TEXT)
    TestEnv.InstallEncodingUtil({ withoutCompress = true })
    assert.are.equal(expected, select(2, CodecKit:Compress(TEXT)))
    TestEnv.InstallEncodingUtil({ compressValue = "not a function" })
    assert.are.equal(expected, select(2, CodecKit:Compress(TEXT)))
    TestEnv.SetEncodingGlobal("C_EncodingUtil", "not a table")
    assert.are.equal(expected, select(2, CodecKit:Compress(TEXT)))
  end)

  it(
    "hands an input of 64 bytes or more to CompressString, with the documented Deflate method",
    function()
      local record = TestEnv.InstallEncodingUtil()
      local input = string.rep("x", 64)
      local ok, compressed = CodecKit:Compress(input)
      assert.is_true(ok)
      assert.are.equal(TestEnv.StoredDeflate(input), compressed)
      assert.are.equal(1, #record.compressCalls)
      assert.are.equal(input, record.compressCalls[1].source)
      assert.are.equal(0, record.compressCalls[1].method)
      assert.are.equal(DEFAULT, record.compressCalls[1].level)
    end
  )

  it("keeps an input under 64 bytes on the Lua compressor", function()
    local input = string.rep("x", 63)
    local _, expected = CodecKit:Compress(input)
    local record = TestEnv.InstallEncodingUtil()
    assert.are.equal(expected, select(2, CodecKit:Compress(input)))
    assert.are.equal(0, #record.compressCalls)
    assert.are.equal("4b0400", TestEnv.Hex(select(2, CodecKit:Compress("a"))))
  end)

  it("maps levels 1 to 3, 4 to 6 and 7 to 9 onto speed, default and size", function()
    local record = TestEnv.InstallEncodingUtil()
    local expected = { SPEED, SPEED, SPEED, DEFAULT, DEFAULT, DEFAULT, SIZE, SIZE, SIZE }
    for level = 1, 9 do
      assert.is_true((CodecKit:Compress(TEXT, { level = level })))
      assert.are.equal(expected[level], record.compressCalls[level].level, "level " .. level)
    end
    CodecKit:Encode(TEXT, { compress = "deflate", level = 2 })
    assert.are.equal(SPEED, record.compressCalls[10].level)
  end)

  it("reads the method and levels from the client's Enum when it has them", function()
    local record = TestEnv.InstallEncodingUtil({
      enum = {
        CompressionMethod = { Deflate = 10, Zlib = 11, Gzip = 12 },
        CompressionLevel = { Default = 20, OptimizeForSpeed = 21, OptimizeForSize = 22 },
      },
    })
    CodecKit:Compress(TEXT, { level = 1 })
    CodecKit:Compress(TEXT, { level = 5 })
    CodecKit:Compress(TEXT, { level = 9 })
    assert.are.equal(10, record.compressCalls[1].method)
    assert.are.same({ 21, 20, 22 }, {
      record.compressCalls[1].level,
      record.compressCalls[2].level,
      record.compressCalls[3].level,
    })
  end)

  it("uses the documented numbers when Enum lacks a table or a field", function()
    local record = TestEnv.InstallEncodingUtil({
      enum = { CompressionMethod = { Zlib = 11 }, CompressionLevel = "not a table" },
    })
    CodecKit:Compress(TEXT, { level = 9 })
    assert.are.equal(0, record.compressCalls[1].method)
    assert.are.equal(SIZE, record.compressCalls[1].level)
    TestEnv.SetEncodingGlobal("Enum", "not a table")
    CodecKit:Compress(TEXT, { level = 1 })
    assert.are.equal(0, record.compressCalls[2].method)
    assert.are.equal(SPEED, record.compressCalls[2].level)
  end)

  it("writes native frames that a client without C_EncodingUtil decodes", function()
    local value = { note = TEXT, list = { 1, 2.5, "three" }, flag = true }
    TestEnv.InstallEncodingUtil()
    local frames = {}
    for _, channel in ipairs({ "none", "addon", "print" }) do
      local ok, frame = CodecKit:Encode(value, { compress = "deflate", channel = channel })
      assert.is_true(ok, tostring(frame))
      frames[channel] = frame
    end
    local okMany, many = CodecKit:EncodeMany({ compress = "deflate" }, TEXT, nil, 3)
    assert.is_true(okMany)

    TestEnv.RemoveEncodingUtil()
    for channel, frame in pairs(frames) do
      local ok, decoded = CodecKit:Decode(frame, { channel = channel })
      assert.is_true(ok, channel .. ": " .. tostring(decoded))
      assert.is_true(TestEnv.Same(value, decoded), channel)
      local _, luaFrame = CodecKit:Encode(value, { compress = "deflate", channel = channel })
      assert.are_not.equal(luaFrame, frame)
    end
    local results = { CodecKit:DecodeMany(many) }
    assert.is_true(results[1])
    assert.are.equal(TEXT, results[2])
    assert.is_nil(results[3])
    assert.are.equal(3, results[4])
  end)

  it(
    "decodes Lua-compressed frames with C_EncodingUtil present, and never inflates natively",
    function()
      local value = { note = TEXT, count = 7 }
      local _, luaFrame = CodecKit:Encode(value, { compress = "deflate", channel = "addon" })
      local _, luaBytes = CodecKit:Compress(TEXT)
      local record = TestEnv.InstallEncodingUtil()
      local ok, decoded = CodecKit:Decode(luaFrame, { channel = "addon" })
      assert.is_true(ok)
      assert.is_true(TestEnv.Same(value, decoded))
      local inflated, output = CodecKit:Decompress(luaBytes)
      assert.is_true(inflated)
      assert.are.equal(TEXT, output)
      local _, nativeBytes = CodecKit:Compress(TEXT)
      assert.are.equal(TEXT, select(2, CodecKit:Decompress(nativeBytes)))
      assert.are.equal(0, record.decompressCalls)
    end
  )

  it("decodes zlib streams the client could return at every level", function()
    -- The stand-in answers with zlib's own stream for the two sources the
    -- spec compresses: `TEXT` itself, and `TEXT` serialised as a string value
    -- (type byte 07 and the varint 523, 8b 04), the body of an Encode frame.
    local serialized = "\7\139\4" .. TEXT
    TestEnv.InstallEncodingUtil({
      compress = function(source, _, level)
        if source == serialized then
          return TestEnv.Unhex(ZLIB_SERIALIZED_LEVEL_6)
        end
        return TestEnv.Unhex(level == SPEED and ZLIB_LEVEL_1 or ZLIB_LEVEL_6)
      end,
    })
    local streams = { ZLIB_LEVEL_1, ZLIB_LEVEL_6, ZLIB_LEVEL_6 }
    local compressedAt = {}
    for index, level in ipairs({ 1, 6, 9 }) do
      local ok, compressed = CodecKit:Compress(TEXT, { level = level })
      assert.is_true(ok)
      assert.are.equal(TestEnv.Hex(TestEnv.Unhex(streams[index])), TestEnv.Hex(compressed))
      compressedAt[level] = compressed
    end
    local frameOk, frame = CodecKit:Encode(TEXT, { compress = "deflate" })
    assert.is_true(frameOk)
    assert.are.equal(
      "0103" .. TestEnv.Hex(TestEnv.Unhex(ZLIB_SERIALIZED_LEVEL_6)),
      TestEnv.Hex(frame)
    )

    TestEnv.RemoveEncodingUtil()
    for level, compressed in pairs(compressedAt) do
      assert.are.equal(TEXT, select(2, CodecKit:Decompress(compressed)), "level " .. level)
    end
    assert.are.same({ true, TEXT }, { CodecKit:Decode(frame) })
  end)

  it("falls back to the Lua compressor on every answer it cannot trust", function()
    local _, expected = CodecKit:Compress(TEXT)
    local _, expectedFrame = CodecKit:Encode(TEXT, { compress = "deflate", channel = "print" })
    for _, mode in ipairs({ "raise", "nothing", "number", "empty", "table", "oversized" }) do
      CodecKit:SetLimits({ maxOutputBytes = #TEXT + 64 })
      local record = TestEnv.InstallEncodingUtil({ mode = mode })
      local ok, compressed = CodecKit:Compress(TEXT)
      assert.is_true(ok, mode)
      assert.are.equal(expected, compressed, mode)
      local frameOk, frame = CodecKit:Encode(TEXT, { compress = "deflate", channel = "print" })
      assert.is_true(frameOk, mode)
      assert.are.equal(expectedFrame, frame, mode)
      assert.are.equal(2, #record.compressCalls, mode)
      CodecKit:SetLimits({ maxOutputBytes = 1048576 })
    end
    assert.are.equal(0, CodecKit._state.pool:GetActiveCount())
  end)

  it("refuses exactly as the Lua compressor does when the output limit is too small", function()
    local random = TestEnv.NewRandom(64)
    local incompressible = TestEnv.RandomBytes(random, 200)
    CodecKit:SetLimits({ maxOutputBytes = 200 })
    local expectedOk, expectedReason = CodecKit:Compress(incompressible)
    assert.is_false(expectedOk)
    local record = TestEnv.InstallEncodingUtil()
    local ok, reason = CodecKit:Compress(incompressible)
    assert.is_false(ok)
    assert.are.equal(expectedReason, reason)
    assert.are.equal("maxOutputBytes", reason)
    assert.are.equal(1, #record.compressCalls)
    CodecKit:SetLimits({ maxOutputBytes = 199 })
    assert.are.same({ false, "maxOutputBytes" }, { CodecKit:Compress(incompressible) })
    assert.are.equal(1, #record.compressCalls)
  end)

  it("refuses a secret string before the client's function sees it", function()
    local record = TestEnv.InstallEncodingUtil()
    local secret = string.rep("s", 100)
    TestEnv.InstallSecretProbe({ [secret] = true })
    TestEnv.expectErrorContaining("CodecKit:Compress bytes must not be a secret value", function()
      CodecKit:Compress(secret)
    end)
    assert.are.equal(0, #record.compressCalls)
  end)

  it(
    "allocates nothing to compress a short message again with C_EncodingUtil present #allocation",
    function()
      local record = TestEnv.InstallEncodingUtil()
      local message = string.rep("m", 32)
      CodecKit:Compress(message)
      local kilobytes = TestEnv.AllocatedKilobytes(function()
        for _ = 1, 200 do
          CodecKit:Compress(message)
        end
      end)
      assert.is_true(kilobytes < 0.5, tostring(kilobytes))
      assert.are.equal(0, #record.compressCalls)
    end
  )
end)

describe("CodecKit native compression in the asynchronous variants", function()
  local Async = TestEnv.Async
  after_each(Async.Reset)

  ---Run `EncodeAsync` to its callback and return its two arguments.
  local function encodeAsync(CodecKit, SchedulerKit, value, options)
    local scope = SchedulerKit:CreateScope()
    local result = {}
    CodecKit:EncodeAsync(value, options, scope, function(ok, text)
      result.ok, result.text = ok, text
    end)
    Async.TickUntil(function()
      return result.ok ~= nil
    end, 100000)
    scope:Close()
    return result.ok, result.text
  end

  it("compresses natively up to 256 KiB of stage input and in Lua above it", function()
    local CodecKit, SchedulerKit = Async.NewPackageWithTickingClock(0.01)
    local record = TestEnv.InstallEncodingUtil()
    local options = { compress = "deflate" }
    CodecKit:SetLimits({ maxStringLength = CodecKit.UNBOUNDED })

    -- A string value serialises to its bytes behind a type byte and a
    -- varint length: 1 + 3 bytes here.
    local atLimit = string.rep("a", 262144 - 4)
    local ok, text = encodeAsync(CodecKit, SchedulerKit, atLimit, options)
    assert.is_true(ok, tostring(text))
    assert.are.equal(1, #record.compressCalls)
    assert.are.equal(262144, #record.compressCalls[1].source)
    -- The synchronous Encode has no size threshold: the second native call.
    assert.are.equal(select(2, CodecKit:Encode(atLimit, options)), text)
    assert.are.equal(2, #record.compressCalls)

    local overLimit = string.rep("a", 262144 - 3)
    ok, text = encodeAsync(CodecKit, SchedulerKit, overLimit, options)
    assert.is_true(ok, tostring(text))
    assert.are.equal(
      2,
      #record.compressCalls,
      "the asynchronous call over the threshold stayed in Lua"
    )
    TestEnv.RemoveEncodingUtil()
    assert.are.equal(select(2, CodecKit:Encode(overLimit, options)), text)
    local decoded, value = CodecKit:Decode(text)
    assert.is_true(decoded)
    assert.are.equal(overLimit, value)
  end)

  it("hands the callback the synchronous native frame, which DecodeAsync reads", function()
    local CodecKit, SchedulerKit = Async.NewPackageWithTickingClock(0.01)
    TestEnv.InstallEncodingUtil()
    local value = { note = TEXT, numbers = { 1, 2, 3 } }
    local options = { compress = "deflate", channel = "print" }
    local ok, text = encodeAsync(CodecKit, SchedulerKit, value, options)
    assert.is_true(ok)
    assert.are.equal(select(2, CodecKit:Encode(value, options)), text)

    local scope = SchedulerKit:CreateScope()
    local result = {}
    CodecKit:DecodeAsync(text, nil, scope, function(decodedOk, decoded)
      result.ok, result.value = decodedOk, decoded
    end)
    Async.TickUntil(function()
      return result.ok ~= nil
    end, 100000)
    assert.is_true(result.ok)
    assert.is_true(TestEnv.Same(value, result.value))
    scope:Close()
  end)
end)
