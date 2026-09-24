local TestEnv = require("BrokerKitTestEnv")

describe("BrokerKit:New", function()
    local BrokerKit
    before_each(function()
        BrokerKit = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    it("creates a data source by default with the given attributes", function()
        local object = BrokerKit:New("MyAddon", { text = "Ready", icon = 134400 })
        assert.are.equal("data source", object.type)
        assert.are.equal("Ready", object.text)
        assert.are.equal(134400, object.icon)
        assert.are.equal("MyAddon", object.name)
        assert.is_nil(object.label)
    end)

    it("accepts no definition at all", function()
        local object = BrokerKit:New("Bare")
        assert.are.equal("data source", object.type)
        assert.are.equal("Bare", object.name)
    end)

    it("keeps the type the definition gives", function()
        local object =
            BrokerKit:New("Launcher", { type = "launcher", icon = [[Interface\Icons\X]] })
        assert.are.equal("launcher", object.type)
    end)

    it("copies the definition rather than keeping it", function()
        local definition = { text = "One" }
        local object = BrokerKit:New("Copied", definition)
        definition.text = "Two"
        assert.are.equal("One", object.text)
        assert.is_nil(definition.type)
    end)

    it("accepts every known attribute with its type", function()
        local click = function() end
        local enter = function() end
        local leave = function() end
        local tooltip = function() end
        local coords = { 0.1, 0.9, 0.1, 0.9 }
        local object = BrokerKit:New("Full", {
            type = "launcher",
            text = "text",
            label = "label",
            icon = "icon",
            value = 12,
            suffix = "ms",
            tocname = "Full",
            iconCoords = coords,
            iconR = 1,
            iconG = 0.5,
            iconB = 0,
            OnClick = click,
            OnEnter = enter,
            OnLeave = leave,
            OnTooltipShow = tooltip,
        })
        assert.are.equal(click, object.OnClick)
        assert.are.equal(enter, object.OnEnter)
        assert.are.equal(leave, object.OnLeave)
        assert.are.equal(tooltip, object.OnTooltipShow)
        assert.are.equal(coords, object.iconCoords)
        assert.are.equal(12, object.value)
        assert.are.equal(0.5, object.iconG)
        assert.are.equal("Full", object.tocname)
    end)

    it("accepts custom attributes of any type", function()
        local marker = {}
        local object =
            BrokerKit:New("Custom", { mood = "happy", count = 3, marker = marker, on = true })
        assert.are.equal("happy", object.mood)
        assert.are.equal(3, object.count)
        assert.are.equal(marker, object.marker)
        assert.is_true(object.on)
    end)

    it("refuses a duplicate name at the caller", function()
        BrokerKit:New("Twice")
        TestEnv.expectErrorContaining('BrokerKit:New name "Twice" is already taken', function()
            BrokerKit:New("Twice")
        end)
    end)

    it("refuses an invalid name", function()
        TestEnv.expectErrorContaining("BrokerKit:New name must be a non-empty string", function()
            BrokerKit:New("")
        end)
        TestEnv.expectErrorContaining("BrokerKit:New name must be a non-empty string", function()
            BrokerKit:New(nil)
        end)
        TestEnv.expectErrorContaining("BrokerKit:New name must be a non-empty string", function()
            BrokerKit:New({})
        end)
    end)

    it("refuses a definition that is not a table", function()
        TestEnv.expectErrorContaining("BrokerKit:New definition must be a table", function()
            BrokerKit:New("Bad", "text")
        end)
    end)

    it("refuses a known attribute of the wrong type, creating nothing", function()
        local cases = {
            { { type = "macro" }, 'attribute "type" must be "data source" or "launcher"' },
            { { text = 1 }, 'attribute "text" must be a string' },
            { { label = {} }, 'attribute "label" must be a string' },
            { { icon = true }, 'attribute "icon" must be a string or a number' },
            { { value = {} }, 'attribute "value" must be a string or a number' },
            { { suffix = 1 }, 'attribute "suffix" must be a string' },
            { { tocname = 1 }, 'attribute "tocname" must be a string' },
            { { iconCoords = "0,1" }, 'attribute "iconCoords" must be a table' },
            { { iconR = "1" }, 'attribute "iconR" must be a number' },
            { { iconG = "1" }, 'attribute "iconG" must be a number' },
            { { iconB = "1" }, 'attribute "iconB" must be a number' },
            { { OnClick = "click" }, 'attribute "OnClick" must be a function' },
            { { OnEnter = 1 }, 'attribute "OnEnter" must be a function' },
            { { OnLeave = {} }, 'attribute "OnLeave" must be a function' },
            { { OnTooltipShow = true }, 'attribute "OnTooltipShow" must be a function' },
        }
        for _, case in ipairs(cases) do
            TestEnv.expectErrorContaining("BrokerKit:New " .. case[2], function()
                BrokerKit:New("Typed", case[1])
            end)
        end
        assert.is_nil(BrokerKit:Get("Typed"))
    end)

    it("refuses reserved and malformed attribute names", function()
        TestEnv.expectErrorContaining('BrokerKit:New attribute "name" is reserved', function()
            BrokerKit:New("Reserved", { name = "Other" })
        end)
        TestEnv.expectErrorContaining('BrokerKit:New attribute "Set" is reserved', function()
            BrokerKit:New("Reserved", { Set = function() end })
        end)
        TestEnv.expectErrorContaining('BrokerKit:New attribute "OnChange" is reserved', function()
            BrokerKit:New("Reserved", { OnChange = function() end })
        end)
        TestEnv.expectErrorContaining(
            "BrokerKit:New attribute name must be a non-empty string",
            function()
                BrokerKit:New("Reserved", { [1] = "positional" })
            end
        )
        TestEnv.expectErrorContaining(
            "BrokerKit:New attribute name must be a non-empty string",
            function()
                BrokerKit:New("Reserved", { [""] = "empty" })
            end
        )
        assert.is_nil(BrokerKit:Get("Reserved"))
    end)

    it("refuses the facade methods called without the facade", function()
        TestEnv.expectErrorContaining(
            "BrokerKit:New must be called on the BrokerKit facade; use BrokerKit:New(...)",
            function()
                BrokerKit.New("Loose")
            end
        )
    end)
end)
