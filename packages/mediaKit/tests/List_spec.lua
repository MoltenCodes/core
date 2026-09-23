local TestEnv = require("MediaKitTestEnv")

local PACK = {
    { "Zebra", "Interface\\Pack\\Zebra" },
    { "alpha", "Interface\\Pack\\alpha" },
    { "Alpha", "Interface\\Pack\\Alpha" },
    { "Minimal", 1001 },
    { "Bar 10", "Interface\\Pack\\Bar10" },
    { "Bar 2", "Interface\\Pack\\Bar2" },
    { "Glossy", 1002 },
}

---Register `PACK` in the order `order` names, on a fresh package.
---@param order integer[]
---@return string[] list
local function listAfterRegistering(order)
    local MediaKit = TestEnv.NewPackage()
    for _, index in ipairs(order) do
        local entry = PACK[index]
        assert.is_true(MediaKit:Register("statusbar", entry[1], entry[2]))
    end
    local copy = {}
    for index, name in ipairs(MediaKit:List("statusbar")) do
        copy[index] = name
    end
    return copy
end

describe("MediaKit:List", function()
    after_each(TestEnv.Reset)

    it("sorts names byte-wise, built-ins included", function()
        local list = listAfterRegistering({ 1, 2, 3, 4, 5, 6, 7 })
        assert.are.same({
            "Alpha",
            "Bar 10",
            "Bar 2",
            "Blizzard",
            "Glossy",
            "Minimal",
            "Solid",
            "Zebra",
            "alpha",
        }, list)
    end)

    it("gives the same list whatever the registration order", function()
        local expected = listAfterRegistering({ 1, 2, 3, 4, 5, 6, 7 })
        assert.are.same(expected, listAfterRegistering({ 7, 6, 5, 4, 3, 2, 1 }))
        assert.are.same(expected, listAfterRegistering({ 4, 1, 7, 2, 6, 3, 5 }))
        assert.are.same(expected, listAfterRegistering({ 2, 5, 3, 7, 1, 4, 6 }))
    end)

    it("returns the cached array until a registration of that type", function()
        local MediaKit = TestEnv.NewPackage()
        local first = MediaKit:List("statusbar")
        assert.are.equal(first, MediaKit:List("statusbar"))

        MediaKit:Register("background", "Elsewhere", "Interface\\Pack\\Elsewhere")
        assert.are.equal(first, MediaKit:List("statusbar"))

        MediaKit:Register("statusbar", "New", "Interface\\Pack\\New")
        local second = MediaKit:List("statusbar")
        assert.are_not.equal(first, second)
        assert.are.same({ "Blizzard", "New", "Solid" }, second)
        -- The array handed out earlier is left as it was.
        assert.are.same({ "Blizzard", "Solid" }, first)
    end)

    it("does not rebuild after a refused or identical registration", function()
        local MediaKit = TestEnv.NewPackage()
        MediaKit:Register("statusbar", "New", "Interface\\Pack\\New")
        local list = MediaKit:List("statusbar")
        MediaKit:Register("statusbar", "New", "Interface\\Pack\\New")
        MediaKit:Register("statusbar", "New", "Interface\\Pack\\Other")
        assert.are.equal(list, MediaKit:List("statusbar"))
    end)

    it("lists every type, each with its own built-ins", function()
        local MediaKit = TestEnv.NewPackage()
        assert.are.same(
            { "Blizzard Dialog Background", "Blizzard Tooltip", "Solid" },
            MediaKit:List("background")
        )
        assert.are.same({ "Blizzard Dialog", "Blizzard Tooltip", "None" }, MediaKit:List("border"))
        assert.are.same({ "Question Mark" }, MediaKit:List("icon"))
        assert.are.same({ "None" }, MediaKit:List("sound"))
        assert.are.same({ "Solid" }, MediaKit:List("texture"))
    end)

    it("refuses an unknown type and bad options at the caller", function()
        local MediaKit = TestEnv.NewPackage()
        TestEnv.expectErrorContaining("MediaKit:List type must be one of", function()
            MediaKit:List("textures")
        end)
        TestEnv.expectErrorContaining("MediaKit:List anyScript must be a boolean", function()
            MediaKit:List("font", { anyScript = "yes" })
        end)
    end)
end)
