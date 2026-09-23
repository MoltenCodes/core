-- The shared FrameStub fires `OnShow` / `OnHide` on a change of a frame's own
-- shown flag, moves the edit focus between edit boxes with their focus
-- scripts, and refuses an anchor to the region itself or one that closes an
-- anchor cycle, as the client does. These specs pin what WidgetKit's widgets
-- do under those rules without running any script by hand.
local TestEnv = require("WidgetKitTestEnv")

---Wrap `frame`'s `scriptName` handler so that every call is counted.
---@param frame table
---@param scriptName string
---@return table counter `{ calls = n }`
local function countScript(frame, scriptName)
    local counter = { calls = 0 }
    local handler = frame:GetScript(scriptName)
    frame:SetScript(scriptName, function(...)
        counter.calls = counter.calls + 1
        if handler ~= nil then
            return handler(...)
        end
    end)
    return counter
end

describe("WidgetKit under the client's frame scripts", function()
    local WidgetKit
    before_each(function()
        WidgetKit = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    it("closes an open dropdown list from OnHide, once per real hide", function()
        local dropdown = WidgetKit:Create("Dropdown")
        dropdown:SetList({ a = "A", b = "B" })
        local hides = countScript(dropdown.frame, "OnHide")
        local catcher

        assert.is_true(dropdown:Open())
        catcher = WidgetKit._state.dropdownCatcher
        dropdown:Hide()
        assert.are.equal(1, hides.calls)
        assert.is_false(dropdown:IsOpen())
        assert.is_false(catcher:IsShown())

        -- Hiding a hidden frame changes nothing and runs no script.
        dropdown:Hide()
        assert.are.equal(1, hides.calls)

        -- Release hides the frame through the same script, after the release
        -- hook already closed the list.
        dropdown:Show()
        assert.is_true(dropdown:Open())
        WidgetKit:Release(dropdown)
        assert.are.equal(2, hides.calls)
        assert.is_false(dropdown.list:IsShown())
        assert.is_false(catcher:IsShown())
        assert.is_false(WidgetKit._state.openDropdown)
    end)

    it("moves WidgetKit's focus with the edit focus between two edit boxes", function()
        local first = WidgetKit:Create("EditBox")
        local second = WidgetKit:Create("EditBox")

        first:SetFocus()
        assert.are.equal(first, WidgetKit:GetFocus())
        assert.is_true(first.singleBox:HasFocus())

        second:SetFocus()
        assert.are.equal(second, WidgetKit:GetFocus())
        assert.is_false(first.singleBox:HasFocus())
        assert.is_true(second.singleBox:HasFocus())

        -- A click into the first box: the client takes the focus from the
        -- second box (OnEditFocusLost), then gives it to the first
        -- (OnEditFocusGained), and WidgetKit follows.
        first.singleBox:SetFocus()
        assert.are.equal(first, WidgetKit:GetFocus())
        assert.is_false(second.singleBox:HasFocus())

        -- Escape clears the edit focus and, with it, WidgetKit's.
        TestEnv.RunScript(first.singleBox, "OnEscapePressed")
        assert.is_false(first.singleBox:HasFocus())
        assert.is_nil(WidgetKit:GetFocus())
    end)

    it("runs no focus-lost script for a box that did not have the focus", function()
        local edit = WidgetKit:Create("EditBox")
        local lost = countScript(edit.singleBox, "OnEditFocusLost")
        -- Focused through WidgetKit alone, the box itself never took the keyboard.
        WidgetKit:SetFocus(edit)
        edit.singleBox:ClearFocus()
        assert.are.equal(0, lost.calls)
        assert.are.equal(edit, WidgetKit:GetFocus())

        edit:SetFocus()
        edit.singleBox:ClearFocus()
        assert.are.equal(1, lost.calls)
        assert.is_nil(WidgetKit:GetFocus())

        -- Releasing a focused edit box clears both focuses once.
        edit:SetFocus()
        WidgetKit:Release(edit)
        assert.are.equal(2, lost.calls)
        assert.is_nil(WidgetKit:GetFocus())
    end)

    it("never anchors a frame to itself or into a cycle in any layout", function()
        local names = {
            "Group",
            "ScrollFrame",
            "Label",
            "Button",
            "CheckBox",
            "Slider",
            "EditBox",
            "Dropdown",
            "ColorPicker",
            "Heading",
            "Spacer",
            "Frame",
        }
        for _, layout in ipairs({ "List", "Fill", "Flow" }) do
            local window = WidgetKit:Create("Frame")
            window:SetLayout(layout)
            local outer = WidgetKit:Create("Group")
            outer:SetLayout(layout)
            outer:SetFullWidth(true)
            local scroll = WidgetKit:Create("ScrollFrame")
            scroll:SetLayout(layout)
            scroll:SetFullWidth(true)
            local inner = WidgetKit:Create("Group")
            inner:SetLayout(layout)
            inner:SetRelativeWidth(0.5)
            window:AddChild(outer)
            outer:AddChild(scroll)
            scroll:AddChild(inner)
            for _, name in ipairs(names) do
                local widget = WidgetKit:Create(name)
                widget:SetFullHeight(true)
                inner:AddChild(widget)
            end
            -- Every pass again, now that every size is known.
            assert.is_true(window:PerformLayout())
            local dropdown = inner:GetChildren()[8]
            dropdown:SetList({ a = "A" })
            assert.is_true(dropdown:Open())
            dropdown:Close()
            WidgetKit:Release(window)
        end
    end)

    it("passes the client's refusal of an anchor to the widget's own frame on", function()
        local group = WidgetKit:Create("Group")
        local child = WidgetKit:Create("Spacer")
        group:AddChild(child)
        TestEnv.expectErrorContaining("Cannot anchor to itself", function()
            group:SetPoint("CENTER", group.frame, "CENTER")
        end)
        TestEnv.expectErrorContaining("anchor family connection", function()
            group:SetPoint("CENTER", child.frame, "CENTER")
        end)
    end)
end)
