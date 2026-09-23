local TestEnv = require("CodecKitTestEnv")

describe("CodecKit channel encodings", function()
    local CodecKit
    before_each(function()
        CodecKit = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    local everyByte = {}
    for value = 0, 255 do
        everyByte[#everyByte + 1] = string.char(value)
    end
    everyByte = table.concat(everyByte)

    describe("addon", function()
        it("escapes exactly the documented bytes", function()
            local cases = {
                { "\0", "\255" .. "0" },
                { "\10", "\255" .. "1" },
                { "\13", "\255" .. "2" },
                { "|", "\255" .. "3" },
                { "\255", "\255" .. "4" },
                { "a\1\9\11\12\254b", "a\1\9\11\12\254b" },
            }
            for index = 1, #cases do
                local ok, text = CodecKit:EncodeForAddon(cases[index][1])
                assert.is_true(ok)
                assert.are.equal(cases[index][2], text)
            end
        end)

        it("carries all 256 byte values without a zero byte, line break or pipe", function()
            local ok, text = CodecKit:EncodeForAddon(everyByte .. everyByte)
            assert.is_true(ok)
            assert.is_nil(text:find("[%z\n\r|]"))
            assert.are.equal(512 + 10, #text)
            local decoded, bytes = CodecKit:DecodeForAddon(text)
            assert.is_true(decoded)
            assert.are.equal(everyByte .. everyByte, bytes)
        end)

        it("keeps a whole Encode frame free of forbidden bytes", function()
            local value = { everyByte, 0, 124, 255, { [everyByte] = everyByte } }
            for _, compress in ipairs({ "none", "deflate" }) do
                local ok, text = CodecKit:Encode(value, { compress = compress, channel = "addon" })
                assert.is_true(ok)
                assert.is_nil(text:find("[%z\n\r|]"))
            end
        end)

        it("refuses forbidden bytes and broken escapes", function()
            local cases = {
                { "a\0b", "forbiddenByte" },
                { "a\nb", "forbiddenByte" },
                { "a\rb", "forbiddenByte" },
                { "a|b", "forbiddenByte" },
                { "a\255", "malformedEscape" },
                { "\255" .. "5", "malformedEscape" },
                { "\255\255" .. "0", "malformedEscape" },
            }
            for index = 1, #cases do
                local ok, reason = CodecKit:DecodeForAddon(cases[index][1])
                assert.is_false(ok)
                assert.are.equal(cases[index][2], reason)
            end
        end)
    end)

    describe("print", function()
        it("publishes an 85-character alphabet without quotes, pipes or whitespace", function()
            local alphabet = CodecKit.PRINT_ALPHABET
            assert.are.equal(85, #alphabet)
            assert.are.equal("!", alphabet:sub(1, 1))
            assert.are.equal("~", alphabet:sub(85, 85))
            assert.is_nil(alphabet:find("[%s\"'`\\|{}%%/]"))
            for index = 1, 85 do
                local character = alphabet:sub(index, index)
                assert.are.equal(index, alphabet:find(character, 1, true))
                assert.is_true(character:byte() > 32 and character:byte() < 127)
            end
        end)

        it("maps four bytes to five digits, most significant first", function()
            local alphabet = CodecKit.PRINT_ALPHABET
            local function digits(...)
                local parts = {}
                for index = 1, select("#", ...) do
                    local digit = select(index, ...)
                    parts[index] = alphabet:sub(digit + 1, digit + 1)
                end
                return table.concat(parts)
            end
            local cases = {
                { "", "" },
                { "\0\0\0\0", "!!!!!" },
                { "\255\255\255\255", digits(82, 23, 54, 12, 0) },
                { "\0", "!!" },
                { "\0\0\0", "!!!!" },
                { "\0\0\0\1", digits(0, 0, 0, 0, 1) },
            }
            for index = 1, #cases do
                local ok, text = CodecKit:EncodeForPrint(cases[index][1])
                assert.is_true(ok)
                assert.are.equal(cases[index][2], text, "case " .. index)
            end
        end)

        it("round-trips every length and all 256 byte values in printable characters", function()
            local random = TestEnv.NewRandom(85)
            local alphabetSet = {}
            for index = 1, 85 do
                alphabetSet[CodecKit.PRINT_ALPHABET:byte(index)] = true
            end
            for length = 0, 40 do
                local input = TestEnv.RandomBytes(random, length)
                local ok, text = CodecKit:EncodeForPrint(input)
                assert.is_true(ok)
                local remainder = length % 4
                local expected = math.floor(length / 4) * 5 + (remainder > 0 and remainder + 1 or 0)
                assert.are.equal(expected, #text)
                for position = 1, #text do
                    assert.is_true(alphabetSet[text:byte(position)] == true)
                end
                local decoded, bytes = CodecKit:DecodeForPrint(text)
                assert.is_true(decoded)
                assert.are.equal(input, bytes)
            end
            local ok, text = CodecKit:EncodeForPrint(everyByte)
            assert.is_true(ok)
            assert.are.equal(everyByte, select(2, CodecKit:DecodeForPrint(text)))
        end)

        it(
            "refuses characters outside the alphabet, dangling digits and overflowing groups",
            function()
                local cases = { "!!!!|", '!!"!!', "!!!!!!", "~~~~~", "~~", "!!!!!!!{" }
                for index = 1, #cases do
                    local ok, reason = CodecKit:DecodeForPrint(cases[index])
                    assert.is_false(ok)
                    assert.are.equal("malformedPrint", reason, "case " .. index)
                end
                local ok, bytes = CodecKit:DecodeForPrint(" !! !! !\n")
                assert.is_true(ok)
                assert.are.equal("\0\0\0\0", bytes)
            end
        )
    end)
end)
