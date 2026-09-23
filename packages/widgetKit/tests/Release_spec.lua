local TestEnv = require("WidgetKitTestEnv")

describe("WidgetKit release", function()
    local WidgetKit
    before_each(function()
        WidgetKit = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    it("refuses a double release and a foreign widget", function()
        local label = WidgetKit:Create("Label")
        WidgetKit:Release(label)
        TestEnv.expectErrorContaining("widget was already released", function()
            WidgetKit:Release(label)
        end)
        TestEnv.expectErrorContaining("widget must be a WidgetKit widget", function()
            WidgetKit:Release({ frame = {} })
        end)
        TestEnv.expectErrorContaining("widget must be a WidgetKit widget", function()
            WidgetKit:Release(nil)
        end)
        TestEnv.expectErrorContaining("cannot be called on a released widget", function()
            label:SetText("late")
        end)
    end)

    it(
        "clears callbacks, user data, size requests and anchors, then hides and re-parents",
        function()
            local window = WidgetKit:Create("Frame")
            local label = WidgetKit:Create("Label")
            local fired = 0
            label:SetCallback("OnSomething", function()
                fired = fired + 1
            end)
            label:SetUserData("key", "value")
            label:SetFullWidth(true)
            label:SetFullHeight(true)
            window:AddChild(label)
            assert.is_true(label.frame:GetNumPoints() > 0)

            WidgetKit:Release(label)
            assert.are.equal(0, label.frame:GetNumPoints())
            assert.is_false(label.frame:IsShown())
            assert.are.equal(TestEnv.GetGlobal("UIParent"), label.frame:GetParent())
            assert.are.equal(0, window:GetNumChildren())

            local again = WidgetKit:Create("Label")
            assert.are.equal(label, again)
            assert.is_nil(again:GetUserData("key"))
            assert.is_false(again:IsFullWidth())
            assert.is_false(again:IsFullHeight())
            assert.is_false(again:Fire("OnSomething"))
            assert.are.equal(0, fired)
            assert.is_nil(again:GetParentContainer())
        end
    )

    it("re-parents to a hidden holder frame when the host has no UIParent", function()
        WidgetKit = TestEnv.NewPackageWithoutScreen()
        local label = WidgetKit:Create("Label")
        WidgetKit:Release(label)
        local holder = label.frame:GetParent()
        assert.is_not_nil(holder)
        assert.is_false(holder:IsShown())
    end)

    it("fires OnRelease, releases children last first, then runs the type hook", function()
        local order = {}
        WidgetKit:RegisterType("Tracked", function()
            local createFrame = TestEnv.GetGlobal("CreateFrame")
            local frame = createFrame("Frame")
            return {
                frame = frame,
                content = createFrame("Frame", nil, frame),
                OnRelease = function(widget)
                    order[#order + 1] = "hook:" .. widget:GetUserData("name")
                end,
            }
        end, 1)

        local function tracked(name)
            local widget = WidgetKit:Create("Tracked")
            widget:SetUserData("name", name)
            widget:SetCallback("OnRelease", function(self)
                order[#order + 1] = "callback:" .. self:GetUserData("name")
            end)
            return widget
        end

        local root = tracked("root")
        local first = tracked("first")
        local second = tracked("second")
        local nested = tracked("nested")
        root:AddChild(first)
        root:AddChild(second)
        second:AddChild(nested)

        WidgetKit:Release(root)
        assert.are.same({
            "callback:root",
            "callback:second",
            "callback:nested",
            "hook:nested",
            "hook:second",
            "callback:first",
            "hook:first",
            "hook:root",
        }, order)
        for _, widget in ipairs({ root, first, second, nested }) do
            assert.is_false(WidgetKit:IsWidget(widget))
        end
    end)

    it("reports IsReleasing through the whole ancestor chain", function()
        local seen = {}
        local root = WidgetKit:Create("Group")
        local middle = WidgetKit:Create("Group")
        local leaf = WidgetKit:Create("Label")
        root:AddChild(middle)
        middle:AddChild(leaf)
        leaf:SetCallback("OnRelease", function(widget)
            seen.leaf = widget:IsReleasing()
            seen.middle = middle:IsReleasing()
            seen.root = root:IsReleasing()
        end)
        assert.is_false(leaf:IsReleasing())

        WidgetKit:Release(root)
        assert.are.same({ leaf = true, middle = true, root = true }, seen)
        assert.is_false(leaf:IsReleasing())
    end)

    it("refuses to release a widget from inside its own release", function()
        local label = WidgetKit:Create("Label")
        local failure = nil
        label:SetCallback("OnRelease", function(widget)
            local ok, message = pcall(WidgetKit.Release, WidgetKit, widget)
            failure = not ok and message or nil
        end)
        WidgetKit:Release(label)
        assert.is_not_nil(failure)
        assert.is_true(failure:find("already being released", 1, true) ~= nil)
    end)

    it("reports a failing OnRelease hook and still completes the release", function()
        TestEnv.TakeReportedErrors()
        WidgetKit:RegisterType("Faulty", function()
            return {
                frame = TestEnv.GetGlobal("CreateFrame")("Frame"),
                OnRelease = function()
                    error("hook failed", 0)
                end,
            }
        end, 1)
        local widget = WidgetKit:Create("Faulty")
        WidgetKit:Release(widget)
        assert.is_false(WidgetKit:IsWidget(widget))
        local reported = TestEnv.TakeReportedErrors()
        assert.are.equal(1, #reported)
        assert.are.equal("hook failed", reported[1].value)
    end)

    it("offers Release on the widget itself", function()
        local label = WidgetKit:Create("Label")
        assert.is_true(label:Release())
        TestEnv.expectErrorContaining("already released", function()
            label:Release()
        end)
    end)

    it("clears the focus when the focused widget is released", function()
        local box = WidgetKit:Create("EditBox")
        box:SetFocus()
        assert.are.equal(box, WidgetKit:GetFocus())
        WidgetKit:Release(box)
        assert.is_nil(WidgetKit:GetFocus())
    end)
end)
