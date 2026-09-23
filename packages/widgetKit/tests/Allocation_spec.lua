local TestEnv = require("WidgetKitTestEnv")

-- Kilobytes a guarded workload may allocate: the collector's own accounting
-- noise, far below one table per iteration.
local BUDGET = 1

describe("WidgetKit allocation guards", function()
    local WidgetKit
    before_each(function()
        WidgetKit = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    it("allocates nothing on warm acquire and release cycles", function()
        for _, typeName in ipairs({ "Label", "Group", "Button", "CheckBox", "Heading", "Spacer" }) do
            -- Warm: build the widget and its lazily created tables once.
            local warm = WidgetKit:Create(typeName)
            warm:SetCallback("OnClick", function() end)
            warm:SetUserData("key", true)
            WidgetKit:Release(warm)

            local allocated = TestEnv.AllocatedKilobytes(function()
                for _ = 1, 200 do
                    local widget = WidgetKit:Create(typeName)
                    WidgetKit:Release(widget)
                end
            end)
            assert.is_true(
                allocated < BUDGET,
                typeName .. " acquire/release allocated " .. allocated .. " KB"
            )
        end
    end)

    it("allocates nothing when PerformLayout runs over unchanged children", function()
        local window = WidgetKit:Create("Frame")
        local group = WidgetKit:Create("Group")
        group:SetFullWidth(true)
        window:AddChild(group)
        for _ = 1, 10 do
            local label = WidgetKit:Create("Label")
            label:SetText("text")
            label:SetFullWidth(true)
            group:AddChild(label)
        end
        for _, layout in ipairs({ "List", "Flow", "Fill" }) do
            window:SetLayout(layout)
            group:SetLayout(layout)
            window:PerformLayout()
            local allocated = TestEnv.AllocatedKilobytes(function()
                for _ = 1, 100 do
                    window:PerformLayout()
                end
            end)
            assert.is_true(allocated < BUDGET, layout .. " layout allocated " .. allocated .. " KB")
        end
    end)

    it("allocates nothing to fire a callback", function()
        local button = WidgetKit:Create("Button")
        button:SetCallback("OnClick", function() end)
        local allocated = TestEnv.AllocatedKilobytes(function()
            for _ = 1, 500 do
                button:Fire("OnClick", "LeftButton")
            end
        end)
        assert.is_true(allocated < BUDGET, "Fire allocated " .. allocated .. " KB")
    end)
end)
