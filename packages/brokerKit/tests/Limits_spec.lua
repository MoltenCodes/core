local TestEnv = require("BrokerKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src

---Return the line number of the statement that called this helper.
---@return integer line
local function currentLine()
    return debug.getinfo(2, "l").currentline
end

---Assert that `action` failed with `message` reported at `expectedLine` of
---this spec file, which proves the error level points at the caller.
---@param expectedLine integer
---@param message string
---@param ok boolean
---@param value any
local function assertReportedAt(expectedLine, message, ok, value)
    assert.is_false(ok)
    assert.are.equal(SOURCE .. ":" .. expectedLine .. ": " .. message, value)
end

local DEFAULT_LIMITS = { maxObjects = 256, maxAttributes = 32 }
local OBJECTS_MESSAGE =
    "BrokerKit:SetLimits limits.maxObjects must be a positive integer or BrokerKit.UNBOUNDED"
local ATTRIBUTES_MESSAGE =
    "BrokerKit:SetLimits limits.maxAttributes must be a positive integer or BrokerKit.UNBOUNDED"

describe("BrokerKit limits", function()
    local BrokerKit

    before_each(function()
        BrokerKit = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    ---Create `count` objects with distinct names.
    ---@param count integer
    local function createObjects(count)
        for index = 1, count do
            BrokerKit:New("Object " .. index)
        end
    end

    it("reports the defaults through GetLimits and the constants", function()
        assert.are.same(DEFAULT_LIMITS, BrokerKit:GetLimits())
        assert.are.equal(BrokerKit.MAX_OBJECTS, BrokerKit:GetLimits().maxObjects)
        assert.are.equal(BrokerKit.MAX_ATTRIBUTES, BrokerKit:GetLimits().maxAttributes)
    end)

    it("returns a fresh table from every GetLimits call", function()
        local first = BrokerKit:GetLimits()
        first.maxObjects = 1
        assert.are_not.equal(first, BrokerKit:GetLimits())
        assert.are.same(DEFAULT_LIMITS, BrokerKit:GetLimits())
    end)

    it("refuses the object past maxObjects at the caller, counting every origin", function()
        createObjects(256)
        TestEnv.expectErrorContaining("BrokerKit:New refuses more than 256 objects", function()
            BrokerKit:New("One Too Many")
        end)
        assert.is_nil(BrokerKit:Get("One Too Many"))
    end)

    it("honours a smaller maxObjects without removing objects", function()
        createObjects(3)
        BrokerKit:SetLimits({ maxObjects = 2 })
        assert.are.equal(3, #BrokerKit:Objects())
        TestEnv.expectErrorContaining("BrokerKit:New refuses more than 2 objects", function()
            BrokerKit:New("Refused")
        end)
    end)

    it("lifts maxObjects with UNBOUNDED and reports the sentinel back", function()
        BrokerKit:SetLimits({ maxObjects = BrokerKit.UNBOUNDED })
        assert.are.equal(BrokerKit.UNBOUNDED, BrokerKit:GetLimits().maxObjects)
        createObjects(300)
        assert.is_not_nil(BrokerKit:Get("Object 300"))
    end)

    it("stops adopting quietly at maxObjects", function()
        TestEnv.InstallLibDataBroker({
            objects = {
                A = { type = "data source" },
                B = { type = "data source" },
                C = { type = "data source" },
            },
        })
        BrokerKit:SetLimits({ maxObjects = 2 })
        assert.is_true(BrokerKit:AdoptFromLibDataBroker())
        assert.are.same({ "A", "B" }, BrokerKit:Objects())
    end)

    it("refuses the attribute past maxAttributes at the caller, keeping the object", function()
        BrokerKit:SetLimits({ maxAttributes = 3 })
        local object = BrokerKit:New("Mine", { text = "T", icon = 1 })
        local message = 'BrokerKit.Object:Set refuses more than 3 attributes on object "Mine"'
        TestEnv.expectErrorContaining(message, function()
            object.extra = 1
        end)
        TestEnv.expectErrorContaining(message, function()
            object:Set("extra", 1)
        end)
        -- Replacing and clearing stay possible; clearing frees a slot.
        object.text = "Changed"
        object.icon = nil
        object.extra = 1
        assert.are.equal(1, object.extra)
        assert.is_nil(object.icon)
    end)

    it("counts the default type in a definition against maxAttributes", function()
        BrokerKit:SetLimits({ maxAttributes = 2 })
        TestEnv.expectErrorContaining(
            "BrokerKit:New refuses more than 2 attributes on an object",
            function()
                BrokerKit:New("Mine", { text = "T", icon = 1 })
            end
        )
        assert.is_nil(BrokerKit:Get("Mine"))
        local object = BrokerKit:New("Mine", { type = "launcher", icon = 1 })
        assert.are.equal(1, object.icon)
    end)

    it("leaves foreign attributes past maxAttributes out quietly, custom ones first", function()
        local library = TestEnv.InstallLibDataBroker({
            objects = {
                Theirs = { type = "data source", text = "T", label = "L", a = 1, b = 2 },
            },
        })
        BrokerKit:SetLimits({ maxAttributes = 3 })
        BrokerKit:AdoptFromLibDataBroker()
        local theirs = BrokerKit:Get("Theirs")
        -- `type` first, then the known attributes sorted, then custom ones.
        assert.are.equal("data source", theirs.type)
        assert.are.equal("L", theirs.label)
        assert.are.equal("T", theirs.text)
        assert.is_nil(theirs.a)
        assert.is_nil(theirs.b)
        library:GetDataObjectByName("Theirs").c = 3
        assert.is_nil(theirs.c)
        library:GetDataObjectByName("Theirs").text = "Changed"
        assert.are.equal("Changed", theirs.text)
    end)

    it("lifts maxAttributes with UNBOUNDED", function()
        BrokerKit:SetLimits({ maxAttributes = BrokerKit.UNBOUNDED })
        local object = BrokerKit:New("Mine")
        for index = 1, 100 do
            object["attribute" .. index] = index
        end
        assert.are.equal(100, object.attribute100)
        assert.are.equal(BrokerKit.UNBOUNDED, BrokerKit:GetLimits().maxAttributes)
    end)

    local invalidValues = {
        { label = "zero", value = 0 },
        { label = "a negative number", value = -3 },
        { label = "a fraction", value = 1.5 },
        { label = "infinity", value = math.huge },
        { label = "nan", value = 0 / 0 },
        { label = "a string", value = "64" },
        { label = "a table other than UNBOUNDED", value = {} },
    }
    for _, case in ipairs(invalidValues) do
        it("refuses " .. case.label .. " for either limit at the caller", function()
            local line
            local ok, value = pcall(function()
                line = currentLine() + 1
                BrokerKit:SetLimits({ maxObjects = case.value })
            end)
            assertReportedAt(line, OBJECTS_MESSAGE, ok, value)

            ok, value = pcall(function()
                line = currentLine() + 1
                BrokerKit:SetLimits({ maxAttributes = case.value })
            end)
            assertReportedAt(line, ATTRIBUTES_MESSAGE, ok, value)
            assert.are.same(DEFAULT_LIMITS, BrokerKit:GetLimits())
        end)
    end

    it("changes nothing when one value of several is invalid", function()
        local ok = pcall(BrokerKit.SetLimits, BrokerKit, { maxObjects = 2000, maxAttributes = 0 })
        assert.is_false(ok)
        assert.are.same(DEFAULT_LIMITS, BrokerKit:GetLimits())
    end)

    it("refuses an unknown limit and a non-string key at the caller", function()
        local line
        local ok, value = pcall(function()
            line = currentLine() + 1
            BrokerKit:SetLimits({ maxEntries = 10 })
        end)
        assertReportedAt(
            line,
            "BrokerKit:SetLimits limits.maxEntries is not a recognised limit",
            ok,
            value
        )

        ok, value = pcall(function()
            line = currentLine() + 1
            BrokerKit:SetLimits({ 10 })
        end)
        assertReportedAt(line, "BrokerKit:SetLimits limits.1 is not a recognised limit", ok, value)
    end)

    it("refuses a limits argument that is not a table at the caller", function()
        local line
        local ok, value = pcall(function()
            line = currentLine() + 1
            BrokerKit:SetLimits(nil)
        end)
        assertReportedAt(line, "BrokerKit:SetLimits limits must be a table", ok, value)
    end)

    it("refuses SetLimits and GetLimits called without the facade", function()
        local line
        local ok, value = pcall(function()
            line = currentLine() + 1
            BrokerKit.SetLimits({ maxObjects = 5 })
        end)
        assertReportedAt(
            line,
            "BrokerKit:SetLimits must be called on the BrokerKit facade; use BrokerKit:SetLimits(...)",
            ok,
            value
        )

        ok, value = pcall(function()
            line = currentLine() + 1
            BrokerKit.GetLimits()
        end)
        assertReportedAt(
            line,
            "BrokerKit:GetLimits must be called on the BrokerKit facade; use BrokerKit:GetLimits(...)",
            ok,
            value
        )
    end)
end)
