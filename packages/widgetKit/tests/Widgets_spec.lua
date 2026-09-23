local TestEnv = require("WidgetKitTestEnv")

---Record every `(name, ...)` a widget fires under `names`.
local function recorder(widget, names)
    local fired = {}
    for _, name in ipairs(names) do
        widget:SetCallback(name, function(_, firedName, ...)
            fired[#fired + 1] = { firedName, ... }
        end)
    end
    return fired
end

describe("WidgetKit base widgets", function()
    local WidgetKit
    before_each(function()
        WidgetKit = TestEnv.NewPackage()
        TestEnv.TakeReportedErrors()
    end)
    after_each(TestEnv.Reset)

    it("Frame: a titled window that closes, resizes and lays out on resize", function()
        local window = WidgetKit:Create("Frame")
        window:SetTitle("Options")
        assert.are.equal("Options", window:GetTitle())
        assert.are.equal(700, window:GetWidth())
        assert.are.equal("CENTER", (window.frame:GetPoint(1)))
        local fired = recorder(window, { "OnClose", "OnResize" })

        TestEnv.RunScript(window.sizer, "OnMouseDown")
        assert.are.equal("BOTTOMRIGHT", window.frame.sizing)
        window.frame:SetSize(800, 600)
        local child = WidgetKit:Create("Spacer")
        child:SetFullWidth(true)
        window:PauseLayout()
        window:AddChild(child)
        window:ResumeLayout()
        TestEnv.RunScript(window.sizer, "OnMouseUp")
        assert.are.equal(800 - 24, child:GetWidth())

        TestEnv.RunScript(window.closeButton, "OnClick")
        assert.is_false(window:IsShown())
        assert.are.same({ { "OnResize", 800, 600 }, { "OnClose" } }, fired)

        window:SetResizable(false)
        assert.is_false(window.sizer:IsShown())
    end)

    it("Group: a titled inline container that grows to its content", function()
        local group = WidgetKit:Create("Group")
        group:SetTitle("General")
        assert.are.equal("General", group:GetTitle())
        local content = group:GetContent()
        local _, _, _, x, y = content:GetPoint(1)
        assert.are.same({ 8, -26 }, { x, y })
        group:SetTitle(nil)
        _, _, _, x, y = content:GetPoint(1)
        assert.are.same({ 8, -8 }, { x, y })
    end)

    it("ScrollFrame: reports its content height and scrolls within range", function()
        local scroll = WidgetKit:Create("ScrollFrame")
        scroll:SetPoint("TOPLEFT", TestEnv.GetGlobal("UIParent"), "TOPLEFT", 0, 0)
        for _ = 1, 5 do
            local spacer = WidgetKit:Create("Spacer")
            spacer:SetHeight(100)
            spacer:SetFullWidth(true)
            scroll:AddChild(spacer)
        end
        assert.are.equal(500, scroll:GetContentHeight())
        assert.are.equal(300, scroll:GetScrollRange())
        assert.is_true(scroll.scrollbar:IsShown())
        assert.are.equal(300 - 20, scroll:GetContent():GetWidth())

        scroll:SetScroll(1000)
        assert.are.equal(300, scroll:GetScroll())
        TestEnv.RunScript(scroll.scroll, "OnMouseWheel", 1)
        assert.are.equal(260, scroll:GetScroll())

        scroll:ReleaseChildren()
        scroll:PerformLayout()
        assert.are.equal(0, scroll:GetScrollRange())
        assert.are.equal(0, scroll:GetScroll())
        assert.is_false(scroll.scrollbar:IsShown())
    end)

    it("Label: text sets its height, disabled greys it", function()
        local label = WidgetKit:Create("Label")
        label:SetText("one\ntwo")
        assert.are.equal("one\ntwo", label:GetText())
        assert.are.equal(24, label:GetHeight())
        label:SetText(42)
        assert.are.equal(42, label:GetText())
        label:SetColor(1, 0, 0)
        label:SetDisabled(true)
        assert.are.equal(0.5, (label.text:GetTextColor()))
        label:SetDisabled(false)
        assert.are.equal(1, (label.text:GetTextColor()))
        assert.are.equal(0, select(2, label.text:GetTextColor()))
        TestEnv.expectErrorContaining("text must be a string, a number or nil", function()
            label:SetText({})
        end)
        TestEnv.expectErrorContaining('unknown field "secret"', function()
            label:SetText("x", { secret = true })
        end)
    end)

    it("Button: fires OnClick, and captures a key when asked", function()
        local button = WidgetKit:Create("Button")
        button:SetText("Run")
        local fired = recorder(button, { "OnClick", "OnKeyCaptured", "OnKeyCaptureCancelled" })
        button.frame:Click()
        assert.are.same({ { "OnClick", "LeftButton" } }, fired)

        button:SetDisabled(true)
        button.frame:Click()
        assert.are.equal(1, #fired)
        button:SetDisabled(false)

        button:SetKeyCapture(true)
        button.frame:Click()
        assert.is_true(button:IsCapturing())
        assert.is_true(button.frame:IsKeyboardEnabled())
        TestEnv.RunScript(button.frame, "OnKeyDown", "LSHIFT")
        assert.is_true(button:IsCapturing())
        TestEnv.SetGlobal("IsShiftKeyDown", function()
            return true
        end)
        TestEnv.RunScript(button.frame, "OnKeyDown", "K")
        TestEnv.SetGlobal("IsShiftKeyDown", nil)
        assert.is_false(button:IsCapturing())
        assert.is_false(button.frame:IsKeyboardEnabled())

        button.frame:Click()
        TestEnv.RunScript(button.frame, "OnKeyDown", "ESCAPE")
        button.frame:Click("RightButton")
        assert.are.same({
            { "OnClick", "LeftButton" },
            { "OnKeyCaptured", "SHIFT-K" },
            { "OnKeyCaptureCancelled" },
            { "OnKeyCaptured", "" },
        }, fired)
    end)

    it("CheckBox: cycles two or three states and fires each change", function()
        local box = WidgetKit:Create("CheckBox")
        box:SetLabel("Enabled")
        assert.are.equal("Enabled", box:GetLabel())
        local fired = recorder(box, { "OnValueChanged" })
        box.button:Click()
        box.button:Click()
        assert.are.same({ { "OnValueChanged", true }, { "OnValueChanged", false } }, fired)

        box:SetTriState(true)
        box:SetValue(true)
        box.button:Click()
        assert.is_nil(box:GetValue())
        assert.is_true(box.indeterminate:IsShown())
        box.button:Click()
        assert.is_false(box:GetValue())
        assert.is_false(box.indeterminate:IsShown())

        box:SetTriState(false)
        box:SetValue(nil)
        assert.is_false(box:GetValue())
        box:SetDisabled(true)
        box.button:Click()
        assert.is_false(box:GetValue())
        TestEnv.expectErrorContaining("value must be a boolean or nil", function()
            box:SetValue("yes")
        end)
    end)

    it("Slider: snaps to its step, clamps, and accepts typed values", function()
        local slider = WidgetKit:Create("Slider")
        slider:SetSliderValues(0, 2, 0.25)
        local fired = recorder(slider, { "OnValueChanged" })
        slider:SetValue(1.1)
        assert.are.equal(1, slider:GetValue())
        assert.are.equal(0, #fired)

        slider.slider:SetValue(1.4)
        assert.are.equal(1.5, slider:GetValue())
        assert.are.equal("1.5", slider.valueBox:GetText())

        slider.valueBox:SetText("9")
        TestEnv.RunScript(slider.valueBox, "OnEnterPressed")
        assert.are.equal(2, slider:GetValue())

        slider:SetIsPercent(true)
        assert.are.equal("200%", slider.valueBox:GetText())
        slider.valueBox:SetText("50%")
        TestEnv.RunScript(slider.valueBox, "OnEnterPressed")
        assert.are.equal(0.5, slider:GetValue())

        slider.valueBox:SetText("abc")
        TestEnv.RunScript(slider.valueBox, "OnEnterPressed")
        assert.are.equal("50%", slider.valueBox:GetText())
        assert.are.same(
            { { "OnValueChanged", 1.5 }, { "OnValueChanged", 2 }, { "OnValueChanged", 0.5 } },
            fired
        )
        TestEnv.expectErrorContaining("minimum must not be greater than maximum", function()
            slider:SetSliderValues(3, 1)
        end)
    end)

    it("EditBox: single and multi-line entry with OnEnterPressed", function()
        local edit = WidgetKit:Create("EditBox")
        local fired = recorder(edit, { "OnEnterPressed", "OnTextChanged" })
        edit:SetText("hello")
        assert.are.equal("hello", edit:GetText())
        assert.are.equal(44, edit:GetHeight())
        TestEnv.RunScript(edit.singleBox, "OnTextChanged", true)
        TestEnv.RunScript(edit.singleBox, "OnEnterPressed")

        edit:SetMultiLine(true, 3)
        assert.is_true(edit:IsMultiLine())
        assert.are.equal("hello", edit:GetText())
        assert.are.equal(18 + 3 * 14 + 8 + 28, edit:GetHeight())
        assert.is_true(edit.acceptButton:IsShown())
        edit.multiBox:SetText("line one\nline two")
        edit.acceptButton:Click()
        assert.are.same({
            { "OnTextChanged", "hello" },
            { "OnEnterPressed", "hello" },
            { "OnEnterPressed", "line one\nline two" },
        }, fired)
    end)

    it("Dropdown: a keyboard-free list of buttons", function()
        local dropdown = WidgetKit:Create("Dropdown")
        dropdown:SetList({ b = "Bravo", a = "Alpha", c = "Charlie" })
        assert.are.equal(3, dropdown:GetNumEntries())
        dropdown:SetValue("b")
        assert.are.equal("Bravo", dropdown.button:GetText())
        local fired = recorder(dropdown, { "OnValueChanged" })

        dropdown.button:Click()
        assert.is_true(dropdown:IsOpen())
        assert.are.equal("Alpha", dropdown._rows[1]:GetText())
        assert.is_false(dropdown._rows[4]:IsShown())
        assert.is_nil(dropdown.frame:IsKeyboardEnabled() or nil)
        dropdown._rows[3]:Click()
        assert.is_false(dropdown:IsOpen())
        assert.are.equal("c", dropdown:GetValue())
        assert.are.same({ { "OnValueChanged", "c" } }, fired)

        dropdown:SetList({ x = "X", y = "Y" }, { "y", "x" })
        assert.is_true(dropdown:PickIndex(1))
        assert.are.equal("y", dropdown:GetValue())
        dropdown:SetDisabled(true)
        assert.is_false(dropdown:Open())
    end)

    it("Dropdown: scrolls a long list with the wheel", function()
        local dropdown = WidgetKit:Create("Dropdown")
        local values, order = {}, {}
        for index = 1, 20 do
            values[index] = "Entry " .. index
            order[index] = index
        end
        dropdown:SetList(values, order)
        dropdown:Open()
        TestEnv.RunScript(dropdown.list, "OnMouseWheel", -10)
        assert.are.equal("Entry 5", dropdown._rows[1]:GetText())
        dropdown._rows[16]:Click()
        assert.are.equal(20, dropdown:GetValue())
    end)

    it("ColorPicker: a swatch firing its colour without the client picker", function()
        local picker = WidgetKit:Create("ColorPicker")
        picker:SetColor(0.1, 0.2, 0.3, 0.4)
        assert.are.same({ 0.1, 0.2, 0.3, 0.4 }, { picker:GetColor() })
        local fired = recorder(picker, { "OnValueChanged" })
        picker.button:Click()
        assert.are.same({ { "OnValueChanged", 0.1, 0.2, 0.3, 0.4 } }, fired)
    end)

    it("ColorPicker: opens the client ColorPickerFrame and follows it", function()
        local shown = nil
        local current = { 0.5, 0.6, 0.7 }
        local clientPicker = {
            SetupColorPickerAndShow = function(_, info)
                shown = info
            end,
            GetColorRGB = function()
                return current[1], current[2], current[3]
            end,
            GetColorAlpha = function()
                return 0.9
            end,
        }
        TestEnv.SetGlobal("ColorPickerFrame", clientPicker)
        local picker = WidgetKit:Create("ColorPicker")
        picker:SetHasAlpha(true)
        picker:SetColor(1, 0, 0, 1)
        local fired = recorder(picker, { "OnValueChanged" })

        assert.is_true(picker:OpenPicker())
        assert.are.same({ 1, 0, 0, 1, true }, {
            shown.r,
            shown.g,
            shown.b,
            shown.opacity,
            shown.hasOpacity,
        })
        shown.swatchFunc()
        assert.are.same({ 0.5, 0.6, 0.7, 0.9 }, { picker:GetColor() })
        shown.cancelFunc()
        assert.are.same({ 1, 0, 0, 1 }, { picker:GetColor() })
        assert.are.same(
            { { "OnValueChanged", 0.5, 0.6, 0.7, 0.9 }, { "OnValueChanged", 1, 0, 0, 1 } },
            fired
        )
        -- WidgetKit wrote no field onto the client's frame.
        local fields = 0
        for _ in pairs(clientPicker) do
            fields = fields + 1
        end
        assert.are.equal(3, fields)
        TestEnv.SetGlobal("ColorPickerFrame", nil)
    end)

    it("ColorPicker: client picker callbacks never reach a later use of the widget", function()
        local shown = nil
        TestEnv.SetGlobal("ColorPickerFrame", {
            SetupColorPickerAndShow = function(_, info)
                shown = info
            end,
            GetColorRGB = function()
                return 0, 1, 0
            end,
            GetColorAlpha = function()
                return 0.2
            end,
        })
        local picker = WidgetKit:Create("ColorPicker")
        picker:SetColor(1, 0, 0, 0.5)
        picker:OpenPicker()
        -- Without alpha the stored alpha is kept.
        shown.swatchFunc()
        assert.are.same({ 0, 1, 0, 0.5 }, { picker:GetColor() })

        WidgetKit:Release(picker)
        local again = WidgetKit:Create("ColorPicker")
        assert.are.equal(picker, again)
        local fired = recorder(again, { "OnValueChanged" })
        shown.swatchFunc()
        shown.cancelFunc()
        assert.are.same({}, fired)
        assert.are.same({ 1, 1, 1, 1 }, { again:GetColor() })
        TestEnv.SetGlobal("ColorPickerFrame", nil)
    end)

    it("Dropdown: a refused list leaves the entries as they were", function()
        local dropdown = WidgetKit:Create("Dropdown")
        dropdown:SetList({ a = "Alpha" })
        dropdown:SetValue("a")
        TestEnv.expectErrorContaining("labels must be strings", function()
            dropdown:SetList({ b = "Bravo", c = 3 })
        end)
        assert.are.equal(1, dropdown:GetNumEntries())
        assert.are.equal("a", dropdown._keys[1])
        assert.are.equal("Alpha", dropdown._labels[1])
        assert.is_nil(dropdown._keys[2])
        assert.are.equal("Alpha", dropdown.button:GetText())
    end)

    it(
        "Dropdown: the list sits on UIParent above everything and closes on an outside click",
        function()
            local uiParent = TestEnv.GetGlobal("UIParent")
            local scroll = WidgetKit:Create("ScrollFrame")
            local first = WidgetKit:Create("Dropdown")
            local second = WidgetKit:Create("Dropdown")
            scroll:AddChildren(first, second)
            first:SetList({ a = "A" })
            second:SetList({ b = "B" })
            assert.are.equal(uiParent, first.list:GetParent())
            assert.are.equal("FULLSCREEN_DIALOG", first.list:GetFrameStrata())

            assert.is_true(first:Open())
            local catcher = WidgetKit._state.dropdownCatcher
            assert.is_true(catcher:IsShown())
            assert.are.equal("FULLSCREEN", catcher:GetFrameStrata())
            assert.is_true(catcher:IsMouseEnabled())
            assert.are.equal(uiParent:GetWidth(), catcher:GetWidth())

            -- Opening another dropdown closes the first.
            second:Open()
            assert.is_false(first:IsOpen())
            assert.is_true(second:IsOpen())

            -- A click anywhere else lands on the catcher and closes the list.
            TestEnv.RunScript(catcher, "OnMouseDown", "LeftButton")
            assert.is_false(second:IsOpen())
            assert.is_false(catcher:IsShown())

            -- Hiding the dropdown's frame closes its list too.
            first:Open()
            TestEnv.RunScript(first.frame, "OnHide")
            assert.is_false(first:IsOpen())
            assert.is_false(catcher:IsShown())

            -- Releasing an open dropdown closes it and hides the catcher.
            second:Open()
            WidgetKit:Release(second)
            assert.is_false(catcher:IsShown())
            assert.are.equal(catcher, WidgetKit._state.dropdownCatcher)
        end
    )

    it("Heading and Spacer: full-width title and empty space", function()
        local heading = WidgetKit:Create("Heading")
        assert.is_true(heading:IsFullWidth())
        heading:SetText("Layout")
        assert.are.equal("Layout", heading:GetText())
        assert.are.equal(heading.text, select(2, heading.leftLine:GetPoint(2)))

        local spacer = WidgetKit:Create("Spacer")
        assert.are.equal(8, spacer:GetHeight())
    end)
end)

describe("WidgetKit secret values", function()
    local WidgetKit
    before_each(function()
        WidgetKit = TestEnv.NewPackage()
        TestEnv.InstallSecretProbe()
    end)
    after_each(TestEnv.Reset)

    it("refuses a secret in Label and EditBox text unless the caller allows it", function()
        local secret = TestEnv.NewSecret()
        local label = WidgetKit:Create("Label")
        local edit = WidgetKit:Create("EditBox")
        TestEnv.expectErrorContaining(
            "WidgetKit Label:SetText text must not be a secret value unless options.allowSecret is true",
            function()
                label:SetText(secret)
            end
        )
        TestEnv.expectErrorContaining(
            "WidgetKit EditBox:SetText text must not be a secret value",
            function()
                edit:SetText(secret)
            end
        )

        label:SetText(secret, { allowSecret = true })
        assert.are.equal(secret, label:GetText())
        -- A secret text is never measured.
        assert.are.equal(12, label:GetHeight())
        edit:SetText(secret, { allowSecret = true })
        assert.are.equal(secret, edit:GetText())
    end)

    it("clears a secret from pooled text on release", function()
        local secret = TestEnv.NewSecret()
        local label = WidgetKit:Create("Label")
        label:SetText(secret, { allowSecret = true })
        local edit = WidgetKit:Create("EditBox")
        edit:SetText(secret, { allowSecret = true })
        WidgetKit:Release(label)
        WidgetKit:Release(edit)
        assert.are.equal("", label.text:GetText())
        assert.are.equal("", edit.singleBox:GetText())
    end)

    it("refuses a secret where a widget would compare it", function()
        local secret = TestEnv.NewSecret()
        local box = WidgetKit:Create("CheckBox")
        TestEnv.expectErrorContaining("value must not be a secret value", function()
            box:SetValue(secret)
        end)
        local dropdown = WidgetKit:Create("Dropdown")
        TestEnv.expectErrorContaining("label must not be a secret value", function()
            dropdown:SetList({ a = secret })
        end)
        TestEnv.expectErrorContaining("name must not be a secret value", function()
            WidgetKit:Create(secret)
        end)
    end)
end)
