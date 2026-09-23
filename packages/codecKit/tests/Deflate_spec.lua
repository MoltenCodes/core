local TestEnv = require("CodecKitTestEnv")

-- A raw DEFLATE stream produced by zlib 1.3 (`compressobj(9, DEFLATED, -15)`)
-- for the 288-byte Latin text below. Its first block is a dynamic Huffman
-- block, so inflating it checks the dynamic header against an implementation
-- other than this one.
local LATIN = string.rep("Lorem ipsum dolor sit amet, consectetur adipiscing elit. ", 2)
    .. "Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad"
    .. " minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea"
    .. " commodo consequat."
local LATIN_ZLIB = [[
9d8fd16dc4300c4357e100874c727f4507506de140c0b272b65474fc2acd06fd9300f2917cfa5203
cf9d86eec3173603621a0f349f5b5b68e482749edc8df3051d8c03cfff1a3fb49701cadce61da176
9699b3b1b3e70c6460c857e1a171a31526af2990c177ca81cf804e5ab161bc8eef7ac51e782737a6
ef58d9a13fba1a43823e91638835bfc997889b57d21f926789a152c5ad3af93da0a2e2f805
]]

describe("CodecKit DEFLATE", function()
    local CodecKit
    before_each(function()
        CodecKit = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    ---@return string compressed
    local function roundTrip(input, level)
        local ok, compressed = CodecKit:Compress(input, { level = level })
        assert.is_true(ok, tostring(compressed))
        local inflated, output = CodecKit:Decompress(compressed)
        assert.is_true(inflated, tostring(output))
        assert.are.equal(#input, #output)
        assert.is_true(input == output, "level " .. level .. " changed the input")
        return compressed
    end

    it("writes fixed Huffman blocks exactly as RFC 1951 3.2.6 lays them out", function()
        -- "" is one final fixed block holding only end-of-block: header bits
        -- 1 and 01, then the seven-bit code 0000000.
        assert.are.equal("0300", TestEnv.Hex(select(2, CodecKit:Compress(""))))
        -- "a" is literal 0x61, code 0x30 + 0x61 = 10010001 in eight bits.
        assert.are.equal("4b0400", TestEnv.Hex(select(2, CodecKit:Compress("a"))))
        assert.are.equal("4b4c4a0600", TestEnv.Hex(select(2, CodecKit:Compress("abc"))))
    end)

    it("inflates hand-built stored blocks", function()
        local ok, output = CodecKit:Decompress("\1\5\0\250\255hello")
        assert.is_true(ok)
        assert.are.equal("hello", output)
        ok, output = CodecKit:Decompress("\0\2\0\253\255hi" .. "\1\1\0\254\255!")
        assert.is_true(ok)
        assert.are.equal("hi!", output)
        ok, output = CodecKit:Decompress("\1\0\0\255\255")
        assert.is_true(ok)
        assert.are.equal("", output)
    end)

    it("inflates hand-built fixed blocks with and without back-references", function()
        local ok, output = CodecKit:Decompress(TestEnv.Unhex("4b4c4a0600"))
        assert.is_true(ok)
        assert.are.equal("abc", output)
        -- zlib's encoding of "abcabcabcabcabcabc": three literals, then one
        -- match of length 15 at distance 3 overlapping its own output.
        ok, output = CodecKit:Decompress(TestEnv.Unhex("4b4c4a4e444500"))
        assert.is_true(ok)
        assert.are.equal(string.rep("abc", 6), output)
        -- zlib's encoding of ten "a": two literals and a match of length 8.
        ok, output = CodecKit:Decompress(TestEnv.Unhex("4b4c840100"))
        assert.is_true(ok)
        assert.are.equal(string.rep("a", 10), output)
    end)

    it("inflates a dynamic Huffman stream made by zlib", function()
        local ok, output = CodecKit:Decompress(TestEnv.Unhex(LATIN_ZLIB))
        assert.is_true(ok, tostring(output))
        assert.are.equal(LATIN, output)
    end)

    it("round-trips text, binary, repetitive and random input at levels 1, 6 and 9", function()
        local random = TestEnv.NewRandom(1951)
        local inputs = {
            "",
            "x",
            LATIN,
            TestEnv.RandomText(random, 4000),
            TestEnv.RandomBytes(random, 6000),
            TestEnv.RandomBytes(random, 40000, 3),
            string.rep("ab", 30000),
            string.rep("\0", 70000),
            string.rep(TestEnv.RandomBytes(random, 300), 50),
        }
        for _, level in ipairs({ 1, 6, 9 }) do
            for index = 1, #inputs do
                roundTrip(inputs[index], level)
            end
        end
    end)

    it("round-trips at every level from 1 to 9", function()
        local text = TestEnv.RandomText(TestEnv.NewRandom(9), 1500)
        local previous = math.huge
        for level = 1, 9 do
            local size = #roundTrip(text, level)
            assert.is_true(size < #text / 2)
            if level == 1 or level == 9 then
                assert.is_true(size <= previous)
                previous = size
            end
        end
    end)

    it("shrinks text and bounds the growth of incompressible input", function()
        local random = TestEnv.NewRandom(4)
        local text = TestEnv.RandomText(random, 2000)
        assert.is_true(#roundTrip(text, 6) < #text / 3)
        local noise = TestEnv.RandomBytes(random, 100000)
        local compressed = roundTrip(noise, 6)
        -- Stored blocks cost five bytes per block of at most 32 KiB.
        assert.is_true(#compressed <= #noise + 5 * 4)
        assert.is_true(#roundTrip(string.rep("z", 100000), 9) < 300)
    end)

    it("refuses malformed streams with a reason and never raises", function()
        local cases = {
            { "", "truncated" },
            { "\7", "malformedDeflate" }, -- block type 3
            { "\1\5\0\0\0hello", "malformedDeflate" }, -- NLEN is not the complement
            { "\1\5\0\250\255hel", "truncated" },
            { "\1\5\0\250\255hello!", "trailingData" },
            { "\0\1\0\254\255a", "truncated" }, -- no final block
            { TestEnv.Unhex("4b4c4a06"), "truncated" },
            -- A match at distance 1 before any output.
            { TestEnv.Unhex("0302"), "malformedDeflate" },
            -- Dynamic block declaring 30 literal/length codes beyond 286.
            { TestEnv.Unhex("fd0000"), "malformedDeflate" },
        }
        for index = 1, #cases do
            local ok, reason = CodecKit:Decompress(cases[index][1])
            assert.is_false(ok, "case " .. index)
            assert.are.equal(cases[index][2], reason, "case " .. index)
        end
    end)

    it("refuses an over-subscribed code-length code", function()
        -- Dynamic block, HLIT 257, HDIST 1, HCLEN 4: four code-length codes of
        -- length 1 (16, 17, 18 and 0) are more than a prefix code can hold.
        local ok, reason = CodecKit:Decompress(TestEnv.Unhex("05009204"))
        assert.is_false(ok)
        assert.are.equal("malformedDeflate", reason)
    end)

    it("writes a short input as one literal or stored block", function()
        local ok, compressed = CodecKit:Compress(string.rep("\255", 63))
        assert.is_true(ok)
        assert.are.equal(1, compressed:byte(1)) -- final stored block: cheaper than 63 nine-bit codes
        assert.are.equal(63 + 5, #compressed)
        assert.are.equal(string.rep("\255", 63), select(2, CodecKit:Decompress(compressed)))
        ok, compressed = CodecKit:Compress(string.rep("\255", 64))
        assert.is_true(ok)
        assert.is_true(#compressed < 10) -- from 64 bytes the matcher runs
        roundTrip(string.rep("ab", 31), 6)
    end)

    it("keeps level 9 within a few times level 6 on low-entropy input", function()
        math.randomseed(9)
        local symbols = {}
        for index = 1, 40000 do
            symbols[index] = math.random(2) == 1 and "a" or "b"
        end
        local input = table.concat(symbols)
        local function seconds(level)
            local started = os.clock()
            roundTrip(input, level)
            return os.clock() - started
        end
        seconds(6)
        local level6 = seconds(6)
        local level9 = seconds(9)
        -- Measured about 2.7 times; before the chain cap it was 27 times.
        assert.is_true(
            level9 < 4.5 * level6 + 0.01,
            "level 9 took " .. level9 / level6 .. " times level 6"
        )
    end)

    it("stops inflating at maxOutputBytes", function()
        local _, compressed = CodecKit:Compress(string.rep("a", 5000))
        CodecKit:SetLimits({ maxOutputBytes = 4096 })
        local ok, reason = CodecKit:Decompress(compressed)
        assert.is_false(ok)
        assert.are.equal("maxOutputBytes", reason)
        ok, reason = CodecKit:Compress(string.rep("a", 5000))
        assert.is_false(ok)
        assert.are.equal("maxOutputBytes", reason)
    end)
end)
