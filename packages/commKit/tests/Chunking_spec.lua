local TestEnv = require("CommKitTestEnv")

local PREFIX = "CKTest"

---Send `text` to the party, run the driver, and return the chunks it sent.
---@param CommKit table
---@param text string
---@return table[]
local function sendAndCollect(CommKit, text)
    local scope = CommKit:CreateScope()
    local handle = assert(scope:Send({ prefix = PREFIX, text = text, distribution = "PARTY" }))
    TestEnv.Advance(0)
    assert.are.equal("sent", handle:GetState())
    return TestEnv.TakeOutbox()
end

---The control byte, stream byte and two-digit number of a chunk.
---@param chunk string
---@return integer control, integer? stream, integer? number
local function header(chunk)
    local control, stream, high, low = string.byte(chunk, 1, 4)
    if control == 0x01 then
        return control
    end
    return control, stream - 0x80, (high - 0x80) * 128 + (low - 0x80)
end

describe("CommKit chunking", function()
    local CommKit
    before_each(function()
        CommKit = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    it("sends 254 bytes as one single chunk with a control byte", function()
        local text = TestEnv.Text(254)
        local chunks = sendAndCollect(CommKit, text)
        assert.are.equal(1, #chunks)
        assert.are.equal(255, #chunks[1].text)
        assert.are.equal("\001" .. text, chunks[1].text)
        assert.are.equal(PREFIX, chunks[1].prefix)
        assert.are.equal("PARTY", chunks[1].distribution)
    end)

    it("splits 255 bytes into a first and a last chunk", function()
        local text = TestEnv.Text(255)
        local chunks = sendAndCollect(CommKit, text)
        assert.are.equal(2, #chunks)
        local control, stream, number = header(chunks[1].text)
        assert.are.same({ 0x02, 0, 2 }, { control, stream, number })
        assert.are.equal(255, #chunks[1].text)
        control, stream, number = header(chunks[2].text)
        assert.are.same({ 0x04, 0, 2 }, { control, stream, number })
        assert.are.equal(4 + 4, #chunks[2].text)
        assert.are.equal(text, chunks[1].text:sub(5) .. chunks[2].text:sub(5))
    end)

    it("splits 256 bytes into two chunks", function()
        local text = TestEnv.Text(256)
        local chunks = sendAndCollect(CommKit, text)
        assert.are.equal(2, #chunks)
        assert.are.equal(4 + 5, #chunks[2].text)
        assert.are.equal(text, chunks[1].text:sub(5) .. chunks[2].text:sub(5))
    end)

    it("splits 502 bytes into two full chunks and 503 into three", function()
        local full = sendAndCollect(CommKit, TestEnv.Text(502))
        assert.are.equal(2, #full)
        assert.are.equal(255, #full[2].text)
        local over = sendAndCollect(CommKit, TestEnv.Text(503))
        assert.are.equal(3, #over)
        assert.are.equal(4 + 1, #over[3].text)
    end)

    it("splits 510 bytes into first, middle and last chunks", function()
        local text = TestEnv.Text(510)
        local chunks = sendAndCollect(CommKit, text)
        assert.are.equal(3, #chunks)
        local controls, numbers = {}, {}
        for index = 1, 3 do
            local control, stream, number = header(chunks[index].text)
            controls[index], numbers[index] = control, number
            assert.are.equal(0, stream)
        end
        assert.are.same({ 0x02, 0x03, 0x04 }, controls)
        assert.are.same({ 3, 2, 3 }, numbers)
        assert.are.equal(4 + 8, #chunks[3].text)
        local joined = chunks[1].text:sub(5) .. chunks[2].text:sub(5) .. chunks[3].text:sub(5)
        assert.are.equal(text, joined)
    end)

    it("gives consecutive multi-chunk messages consecutive stream ids", function()
        local first = sendAndCollect(CommKit, TestEnv.Text(300))
        local second = sendAndCollect(CommKit, TestEnv.Text(300))
        local single = sendAndCollect(CommKit, TestEnv.Text(10))
        local third = sendAndCollect(CommKit, TestEnv.Text(300))
        assert.are.equal(0, select(2, header(first[1].text)))
        assert.are.equal(1, select(2, header(second[1].text)))
        assert.are.equal(1, #single)
        assert.are.equal(2, select(2, header(third[1].text)))
    end)

    it("writes two-digit chunk numbers past 127", function()
        CommKit:SetLimits({ maxQueuedBytes = 65536, burst = 1000000, maxCps = 100000 })
        local text = TestEnv.Text(251 * 129 + 1)
        local scope = CommKit:CreateScope()
        local handle = assert(scope:Send({ prefix = PREFIX, text = text, distribution = "GUILD" }))
        for _ = 1, 20 do
            TestEnv.Advance(1)
        end
        assert.are.equal("sent", handle:GetState())
        local chunks = TestEnv.TakeOutbox()
        assert.are.equal(130, #chunks)
        local control, _, number = header(chunks[1].text)
        assert.are.same({ 0x02, 130 }, { control, number })
        assert.are.same({ 0x81, 0x82 }, { chunks[1].text:byte(3, 4) })
        control, _, number = header(chunks[130].text)
        assert.are.same({ 0x04, 130 }, { control, number })
        for index = 1, #chunks do
            assert.is_nil(chunks[index].text:find("[%z\n\r|]"))
        end
    end)
end)
