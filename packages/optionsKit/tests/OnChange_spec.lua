local TestEnv = require("OptionsKitTestEnv")

describe("OptionsKit tree OnChange", function()
    local OptionsKit
    local value
    local tree

    before_each(function()
        OptionsKit = TestEnv.NewPackage()
        value = false
        tree = OptionsKit:Define("Addon", {
            type = "group",
            args = {
                enabled = {
                    type = "toggle",
                    name = "Enabled",
                    get = function()
                        return value
                    end,
                    set = function(_, newValue)
                        value = newValue
                    end,
                },
            },
        })
    end)
    after_each(TestEnv.Reset)

    it("calls every listener with the tree, the path and the value", function()
        local received = {}
        tree:OnChange(function(...)
            received[#received + 1] = { ... }
        end)
        tree:Set("enabled", true)
        assert.are.same({ { tree, "enabled", true } }, received)
    end)

    it("returns a SignalKit connection that disconnects", function()
        local count = 0
        local connection = tree:OnChange(function()
            count = count + 1
        end)
        tree:Set("enabled", true)
        assert.is_true(connection:IsConnected())
        assert.is_true(connection:Disconnect())
        tree:Set("enabled", false)
        assert.are.equal(1, count)
    end)

    it("sees the new value when a listener reads it back", function()
        local seen
        tree:OnChange(function(changedTree, path)
            seen = changedTree:Get(path)
        end)
        tree:Set("enabled", true)
        assert.is_true(seen)
    end)

    it("lets a listener error reach the caller of Set after the write", function()
        tree:OnChange(function()
            error("listener failed")
        end)
        TestEnv.expectErrorContaining("listener failed", function()
            tree:Set("enabled", true)
        end)
        assert.is_true(value)
    end)

    it("disconnects every listener when the tree is undefined", function()
        local connection = tree:OnChange(function() end)
        OptionsKit:Undefine("Addon")
        assert.is_false(connection:IsConnected())
    end)

    it("refuses a callback that is not a function", function()
        TestEnv.expectErrorContaining(
            "OptionsKit.Tree:OnChange callback must be a function",
            function()
                tree:OnChange("changed")
            end
        )
    end)
end)
