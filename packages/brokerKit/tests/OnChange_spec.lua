local TestEnv = require("BrokerKitTestEnv")

describe("BrokerKit.Object:OnChange", function()
    local BrokerKit
    local object
    before_each(function()
        BrokerKit = TestEnv.NewPackage()
        object = BrokerKit:New("MyAddon", { text = "Ready", value = 1 })
    end)
    after_each(TestEnv.Reset)

    it("fires for any attribute with the object, attribute, value and previous", function()
        local seen = {}
        object:OnChange(function(changed, attribute, value, previous)
            seen[#seen + 1] = { changed, attribute, value, previous }
        end)
        object.text = "Busy"
        object:Set("value", 2)
        object.custom = "new"
        assert.are.same({
            { object, "text", "Busy", "Ready" },
            { object, "value", 2, 1 },
            { object, "custom", "new", nil },
        }, seen)
    end)

    it("takes a nil attribute as the any-attribute form", function()
        local seen = {}
        object:OnChange(nil, function(_, attribute)
            seen[#seen + 1] = attribute
        end)
        object.text = "Busy"
        object.value = 2
        assert.are.same({ "text", "value" }, seen)
    end)

    it("fires a per-attribute subscription for that attribute only", function()
        local texts = {}
        object:OnChange("text", function(_, attribute, value)
            texts[#texts + 1] = attribute .. "=" .. value
        end)
        object.value = 5
        object.text = "One"
        object.text = "Two"
        assert.are.same({ "text=One", "text=Two" }, texts)
    end)

    it("fires the attribute list before the any list", function()
        local order = {}
        object:OnChange(function()
            order[#order + 1] = "any"
        end)
        object:OnChange("text", function()
            order[#order + 1] = "text"
        end)
        object.text = "Busy"
        assert.are.same({ "text", "any" }, order)
    end)

    it("does not fire for a write of the same value", function()
        local count = 0
        object:OnChange(function()
            count = count + 1
        end)
        object.text = "Ready"
        object:Set("value", 1)
        object.missing = nil
        assert.are.equal(0, count)
    end)

    it("fires for clearing and for the same table replaced by an equal one", function()
        local seen = {}
        object:OnChange(function(_, attribute, value, previous)
            seen[#seen + 1] = { attribute, value, previous }
        end)
        object.text = nil
        local coords = { 0, 1, 0, 1 }
        object.iconCoords = coords
        object.iconCoords = coords
        object.iconCoords = { 0, 1, 0, 1 }
        assert.are.equal(3, #seen)
        assert.are.same({ "text", nil, "Ready" }, seen[1])
        assert.are.equal(coords, seen[2][2])
    end)

    it("returns a SignalKit connection the caller owns", function()
        local count = 0
        local connection = object:OnChange("text", function()
            count = count + 1
        end)
        assert.is_true(connection:IsConnected())
        object.text = "One"
        connection:Disconnect()
        object.text = "Two"
        assert.are.equal(1, count)
        assert.is_false(connection:IsConnected())
    end)

    it("lets a listener read the new value from the object", function()
        local read
        object:OnChange("text", function(changed)
            read = changed.text
        end)
        object.text = "Visible"
        assert.are.equal("Visible", read)
    end)

    it("propagates a listener error after the value was stored", function()
        object:OnChange(function()
            error("listener failed", 0)
        end)
        local ok, message = pcall(function()
            object.text = "Stored"
        end)
        assert.is_false(ok)
        assert.are.equal("listener failed", message)
        assert.are.equal("Stored", object.text)
    end)

    it("refuses a missing callback and a bad attribute name", function()
        TestEnv.expectErrorContaining(
            "BrokerKit.Object:OnChange callback must be a function",
            function()
                object:OnChange("text")
            end
        )
        TestEnv.expectErrorContaining(
            "BrokerKit.Object:OnChange callback must be a function",
            function()
                object:OnChange(nil)
            end
        )
        TestEnv.expectErrorContaining(
            "BrokerKit.Object:OnChange attribute name must be a non-empty string",
            function()
                object:OnChange("", function() end)
            end
        )
        TestEnv.expectErrorContaining(
            'BrokerKit.Object:OnChange attribute "name" is reserved',
            function()
                object:OnChange("name", function() end)
            end
        )
    end)
end)
