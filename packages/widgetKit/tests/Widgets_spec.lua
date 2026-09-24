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

            -- Hiding the dropdown's frame closes its list too, through the
            -- frame's own OnHide.
            first:Open()
            first:Hide()
            assert.is_false(first:IsOpen())
            assert.is_false(catcher:IsShown())
            first:Show()

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

    it("refuses a secret key in a Dropdown order before indexing the values with it", function()
        local secret = TestEnv.NewSecret()
        local dropdown = WidgetKit:Create("Dropdown") ---@cast dropdown -nil
        dropdown:SetList({ a = "A" })
        local ok, failure = pcall(function()
            dropdown:SetList({ a = "A" }, { "a", secret })
        end)
        assert.is_false(ok)
        assert.is_truthy(
            tostring(failure):find(
                "WidgetKit Dropdown:SetList key must not be a secret value",
                1,
                true
            )
        )
        assert.is_truthy(tostring(failure):find("Widgets_spec.lua", 1, true))
    end)

    it("stores a secret user-data value without comparing it", function()
        local secret = TestEnv.NewSecret()
        local label = WidgetKit:Create("Label") ---@cast label -nil
        label:SetUserData("value", secret)
        assert.are.equal(secret, label:GetUserData("value"))
    end)

    it("refuses a secret count before comparing it", function()
        local secret = TestEnv.NewSecret()
        local edit = WidgetKit:Create("EditBox")
        TestEnv.expectErrorContaining("letters must not be a secret value", function()
            edit:SetMaxLetters(secret)
        end)
        TestEnv.expectErrorContaining("lines must not be a secret value", function()
            edit:SetMultiLine(true, secret)
        end)
        local dropdown = WidgetKit:Create("Dropdown")
        TestEnv.expectErrorContaining("index must not be a secret value", function()
            dropdown:PickIndex(secret)
        end)
        TestEnv.expectErrorContaining("version must not be a secret value", function()
            WidgetKit:RegisterType("SpecSecretVersion", function() end, secret)
        end)
    end)

    it("refuses a secret before it is compared with a word, nil or a sentinel", function()
        local secret = TestEnv.NewSecret()
        local label = WidgetKit:Create("Label")
        TestEnv.expectErrorContaining(
            "WidgetKit Label:SetJustifyH justify must not be a secret value",
            function()
                label:SetJustifyH(secret)
            end
        )
        TestEnv.expectErrorContaining("SetUserData key must not be a secret value", function()
            label:SetUserData(secret, true)
        end)
        TestEnv.expectErrorContaining("GetUserData key must not be a secret value", function()
            label:GetUserData(secret)
        end)
        TestEnv.expectErrorContaining("fraction must not be a secret value", function()
            label:SetRelativeWidth(secret)
        end)
        TestEnv.expectErrorContaining("alpha must not be a secret value", function()
            label:SetColor(1, 1, 1, secret)
        end)
        local picker = WidgetKit:Create("ColorPicker")
        TestEnv.expectErrorContaining("alpha must not be a secret value", function()
            picker:SetColor(1, 1, 1, secret)
        end)
        local group = WidgetKit:Create("Group")
        TestEnv.expectErrorContaining("limit must not be a secret value", function()
            group:SetMaxChildren(secret)
        end)
        TestEnv.expectErrorContaining("options.maxCreated must not be a secret value", function()
            WidgetKit:RegisterType("SpecSecretCap", function() end, 1, { maxCreated = secret })
        end)
        TestEnv.expectErrorContaining("options.maxCallbacks must not be a secret value", function()
            WidgetKit:RegisterType("SpecSecretCallbacks", function() end, 1, {
                maxCallbacks = secret,
            })
        end)
        TestEnv.expectErrorContaining("maxCreatedCeiling must be an integer from", function()
            WidgetKit:SetLimits({ maxCreatedCeiling = secret })
        end)
        TestEnv.expectErrorContaining("maxDropdownEntries must be a positive integer", function()
            WidgetKit:SetLimits({ maxDropdownEntries = secret })
        end)
        assert.are.same(
            { maxCreatedCeiling = 4096, maxDropdownEntries = 1024 },
            WidgetKit:GetLimits()
        )
    end)
end)

describe("WidgetKit base widget setters", function()
    local WidgetKit
    before_each(function()
        WidgetKit = TestEnv.NewPackage()
        TestEnv.TakeReportedErrors()
    end)
    after_each(TestEnv.Reset)

    it("Frame, ScrollFrame and Spacer: the base SetDisabled only checks its argument", function()
        for _, typeName in ipairs({ "Frame", "ScrollFrame", "Spacer" }) do
            local widget = WidgetKit:Create(typeName)
            widget:SetDisabled(true)
            widget:SetDisabled(nil)
            assert.is_true(widget:IsShown(), typeName)
            TestEnv.expectErrorContaining(
                "WidgetKit.Widget:SetDisabled disabled must be a boolean",
                function()
                    widget:SetDisabled("yes")
                end
            )
        end
    end)

    it("Frame: SetMovable takes booleans only", function()
        local window = WidgetKit:Create("Frame")
        assert.is_true(window.frame:IsMovable())
        window:SetMovable(false)
        assert.is_false(window.frame:IsMovable())
        TestEnv.expectErrorContaining(
            "WidgetKit Frame:SetMovable movable must be a boolean",
            function()
                window:SetMovable(1)
            end
        )
        assert.is_false(window.frame:IsMovable())
    end)

    it(
        "Label: SetJustifyH takes the three justifications, SetFontObject a font or its name",
        function()
            local label = WidgetKit:Create("Label")
            for _, justify in ipairs({ "LEFT", "CENTER", "RIGHT" }) do
                label:SetJustifyH(justify)
                assert.are.equal(justify, label.text.justifyH)
            end
            TestEnv.expectErrorContaining(
                'WidgetKit Label:SetJustifyH justify must be "LEFT", "CENTER" or "RIGHT"',
                function()
                    label:SetJustifyH("MIDDLE")
                end
            )
            assert.are.equal("RIGHT", label.text.justifyH)
            TestEnv.expectErrorContaining(
                "WidgetKit Label:SetFontObject fontObject must be a font object or its name",
                function()
                    label:SetFontObject(12)
                end
            )
        end
    )

    it(
        "Button: key capture adds ALT and CTRL, and turning it off stops listening silently",
        function()
            local button = WidgetKit:Create("Button")
            local fired = recorder(button, { "OnKeyCaptured", "OnKeyCaptureCancelled" })
            button:SetKeyCapture(true)
            button.frame:Click()
            TestEnv.SetGlobal("IsAltKeyDown", function()
                return true
            end)
            TestEnv.SetGlobal("IsControlKeyDown", function()
                return true
            end)
            TestEnv.RunScript(button.frame, "OnKeyDown", "K")
            TestEnv.SetGlobal("IsAltKeyDown", nil)
            TestEnv.SetGlobal("IsControlKeyDown", nil)
            assert.are.same({ { "OnKeyCaptured", "ALT-CTRL-K" } }, fired)

            button.frame:Click()
            assert.is_true(button:IsCapturing())
            button:SetKeyCapture(false)
            assert.is_false(button:IsCapturing())
            assert.is_false(button.frame:IsKeyboardEnabled())
            assert.are.equal(1, #fired)
            TestEnv.expectErrorContaining(
                "WidgetKit Button:SetKeyCapture enabled must be a boolean",
                function()
                    button:SetKeyCapture("on")
                end
            )
        end
    )

    it("CheckBox: turning the third state off turns a third-state value into false", function()
        local box = WidgetKit:Create("CheckBox")
        box:SetTriState(true)
        box:SetValue(nil)
        assert.is_nil(box:GetValue())
        box:SetTriState(false)
        assert.is_false(box:GetValue())
        assert.is_false(box.indeterminate:IsShown())
        TestEnv.expectErrorContaining(
            "WidgetKit CheckBox:SetTriState enabled must be a boolean",
            function()
                box:SetTriState(nil)
            end
        )
    end)

    it("Slider: refuses a negative step and a non-boolean percent flag", function()
        local slider = WidgetKit:Create("Slider")
        slider:SetSliderValues(0, 10, 1)
        TestEnv.expectErrorContaining(
            "WidgetKit Slider:SetSliderValues step must not be negative",
            function()
                slider:SetSliderValues(0, 10, -1)
            end
        )
        TestEnv.expectErrorContaining(
            "WidgetKit Slider:SetIsPercent isPercent must be a boolean",
            function()
                slider:SetIsPercent("yes")
            end
        )
        -- A refused call changes nothing.
        slider:SetValue(3.4)
        assert.are.equal(3, slider:GetValue())
        assert.are.equal("3", slider.valueBox:GetText())
    end)

    it("EditBox: SetMaxLetters takes 0 for no limit or a positive integer", function()
        local edit = WidgetKit:Create("EditBox")
        edit:SetMaxLetters(12)
        assert.are.same({ 12, 12 }, { edit.singleBox.maxLetters, edit.multiBox.maxLetters })
        edit:SetMaxLetters(0)
        assert.are.same({ 0, 0 }, { edit.singleBox.maxLetters, edit.multiBox.maxLetters })
        TestEnv.expectErrorContaining("WidgetKit EditBox:SetMaxLetters letters", function()
            edit:SetMaxLetters(-3)
        end)
        TestEnv.expectErrorContaining("WidgetKit EditBox:SetMaxLetters letters", function()
            edit:SetMaxLetters(2.5)
        end)
        assert.are.equal(0, edit.singleBox.maxLetters)
        TestEnv.expectErrorContaining(
            "WidgetKit EditBox:SetMultiLine multiLine must be a boolean",
            function()
                edit:SetMultiLine(1)
            end
        )
        assert.is_false(edit:IsMultiLine())
    end)

    it("Dropdown: SetList refuses bad values, order and keys and keeps its entries", function()
        local dropdown = WidgetKit:Create("Dropdown")
        dropdown:SetList({ a = "Alpha" })
        TestEnv.expectErrorContaining(
            "WidgetKit Dropdown:SetList values must be a table",
            function()
                dropdown:SetList("Alpha")
            end
        )
        TestEnv.expectErrorContaining(
            "WidgetKit Dropdown:SetList order must be an array or nil",
            function()
                dropdown:SetList({ b = "Bravo" }, "b")
            end
        )
        TestEnv.expectErrorContaining(
            "WidgetKit Dropdown:SetList keys must be strings or numbers",
            function()
                dropdown:SetList({ [true] = "Yes" })
            end
        )
        assert.are.equal(1, dropdown:GetNumEntries())
        assert.is_true(dropdown:PickIndex(1))
        assert.are.equal("a", dropdown:GetValue())
    end)

    it("ColorPicker: SetHasAlpha takes booleans only", function()
        local picker = WidgetKit:Create("ColorPicker")
        TestEnv.expectErrorContaining(
            "WidgetKit ColorPicker:SetHasAlpha hasAlpha must be a boolean",
            function()
                picker:SetHasAlpha(0)
            end
        )
    end)

    it("refuses Fire, GetType, IsReleasing and Release on anything that is not a widget", function()
        local widget = WidgetKit:Create("Spacer")
        local notWidget = {}
        TestEnv.expectErrorContaining(
            "WidgetKit.Widget:Fire must be called on a WidgetKit widget",
            function()
                widget.Fire(notWidget, "OnClick")
            end
        )
        TestEnv.expectErrorContaining(
            "WidgetKit.Widget:GetType must be called on a WidgetKit widget",
            function()
                widget.GetType(notWidget)
            end
        )
        TestEnv.expectErrorContaining(
            "WidgetKit.Widget:IsReleasing must be called on a WidgetKit widget",
            function()
                widget.IsReleasing(notWidget)
            end
        )
        TestEnv.expectErrorContaining(
            "WidgetKit.Widget:Release must be called on a WidgetKit widget",
            function()
                widget.Release(notWidget)
            end
        )
    end)

    it("refuses re-release, new children and moving children out mid-release", function()
        local group = WidgetKit:Create("Group")
        local holder = WidgetKit:Create("Group")
        local child = WidgetKit:Create("Spacer")
        local outsider = WidgetKit:Create("Spacer")
        group:AddChild(child)
        local failures = {}
        local function record(callback)
            local ok, failure = pcall(callback)
            failures[#failures + 1] = ok and "no error" or tostring(failure)
        end
        group:SetCallback("OnRelease", function()
            record(function()
                group:Release()
            end)
            record(function()
                group:AddChild(outsider)
            end)
            record(function()
                group:AddChildren(outsider)
            end)
            record(function()
                holder:AddChild(group)
            end)
            record(function()
                holder:AddChild(child)
            end)
        end)
        assert.is_true(group:Release())
        local expected = {
            "WidgetKit.Widget:Release widget is already being released",
            "WidgetKit.Container:AddChild cannot add to a container that is being released",
            "WidgetKit.Container:AddChildren cannot add to a container that is being released",
            "WidgetKit.Container:AddChild child is being released",
            "WidgetKit.Container:AddChild child is being released",
        }
        assert.are.equal(#expected, #failures)
        for index = 1, #expected do
            assert.is_truthy(failures[index]:find(expected[index], 1, true), failures[index])
        end
        assert.are.equal(0, holder:GetNumChildren())
        assert.are.same({}, TestEnv.TakeReportedErrors())
    end)

    it("refuses a beforeWidget that is the child itself", function()
        local group = WidgetKit:Create("Group")
        local first = WidgetKit:Create("Spacer")
        group:AddChild(first)
        TestEnv.expectErrorContaining(
            "WidgetKit.Container:AddChild beforeWidget must not be the child itself",
            function()
                group:AddChild(first, first)
            end
        )
        assert.are.same({ first }, group:GetChildren())
    end)
end)
