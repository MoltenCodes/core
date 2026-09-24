local TestEnv = require("WidgetKitTestEnv")

---An options tree with one option of every kind, stored in `store`.
---@param OptionsKit table
---@param store table
---@return table tree
local function defineTree(OptionsKit, store)
    local function accessors(key)
        return function()
            return store[key]
        end, function(_, value)
            store[key] = value
        end
    end
    local function option(definition, key)
        definition.get, definition.set = accessors(key)
        return definition
    end

    return OptionsKit:Define("RendererSpec", {
        type = "group",
        args = {
            intro = { type = "description", name = "Settings.", fontSize = "large", order = 0 },
            enabled = option({ type = "toggle", name = "Enabled", order = 1 }, "enabled"),
            frame = {
                type = "group",
                name = "Frame",
                order = 2,
                disabled = function(info)
                    return not info.tree:Get("enabled")
                end,
                args = {
                    layout = { type = "header", name = "Layout", order = 1 },
                    scale = option({
                        type = "range",
                        name = "Scale",
                        order = 2,
                        min = 0.5,
                        max = 2,
                        step = 0.25,
                        isPercent = true,
                    }, "scale"),
                    anchor = option({
                        type = "select",
                        name = "Anchor",
                        order = 3,
                        values = { TOP = "Top", CENTER = "Centre", BOTTOM = "Bottom" },
                        sorting = { "TOP", "CENTER", "BOTTOM" },
                    }, "anchor"),
                    color = option(
                        { type = "color", name = "Border", order = 4, hasAlpha = true },
                        "color"
                    ),
                },
            },
            channels = option({
                type = "multiselect",
                name = "Announce in",
                order = 3,
                values = { SAY = "Say", PARTY = "Party", RAID = "Raid" },
            }, "channels"),
            label = option({
                type = "input",
                name = "Label",
                order = 4,
                validate = function(_, value)
                    if value == "taken" then
                        return false, "that label is taken"
                    end
                    return true
                end,
            }, "label"),
            toggleKey = option(
                { type = "keybinding", name = "Toggle key", order = 5 },
                "toggleKey"
            ),
            reset = {
                type = "execute",
                name = "Reset",
                order = 6,
                confirm = "Reset everything?",
                func = function()
                    store.resets = (store.resets or 0) + 1
                end,
            },
            debug = option({
                type = "toggle",
                name = "Debug",
                order = 7,
                tristate = true,
                hidden = function()
                    return not store.developer
                end,
            }, "debug"),
        },
    })
end

local function newStore()
    return {
        enabled = true,
        scale = 1,
        anchor = "CENTER",
        color = { r = 1, g = 0, b = 0, a = 1 },
        channels = { SAY = true },
        label = "main",
        toggleKey = "",
        developer = false,
    }
end

describe("WidgetKit options renderer", function()
    local WidgetKit, OptionsKit, window, store, tree, rendering
    before_each(function()
        local _
        WidgetKit, _, _, _, _, OptionsKit = TestEnv.NewPackage()
        TestEnv.TakeReportedErrors()
        store = newStore()
        tree = defineTree(OptionsKit, store)
        window = WidgetKit:Create("Frame")
        rendering = WidgetKit:RenderOptions(tree, window)
    end)
    after_each(TestEnv.Reset)

    it("draws each kind with its widget, in order, skipping hidden options", function()
        local expected = {
            intro = "Label",
            enabled = "CheckBox",
            frame = "Group",
            ["frame.layout"] = "Heading",
            ["frame.scale"] = "Slider",
            ["frame.anchor"] = "Dropdown",
            ["frame.color"] = "ColorPicker",
            channels = "Group",
            label = "EditBox",
            toggleKey = "Button",
            reset = "Button",
        }
        for path, typeName in pairs(expected) do
            local widget = rendering:GetWidget(path)
            assert.is_not_nil(widget, path)
            assert.are.equal(typeName, widget:GetType(), path)
        end
        assert.is_nil(rendering:GetWidget("debug"))

        local top = window:GetChildren()
        assert.are.same({
            rendering:GetWidget("intro"),
            rendering:GetWidget("enabled"),
            rendering:GetWidget("frame"),
            rendering:GetWidget("channels"),
            rendering:GetWidget("label"),
            rendering:GetWidget("toggleKey"),
            rendering:GetWidget("reset"),
        }, top)
        assert.are.equal(3, rendering:GetWidget("channels"):GetNumChildren())
        assert.are.equal(
            rendering:GetWidget("frame"),
            rendering:GetWidget("frame.scale"):GetParentContainer()
        )
    end)

    it("shows the current values and the hints", function()
        assert.is_true(rendering:GetWidget("enabled"):GetValue())
        local scale = rendering:GetWidget("frame.scale")
        assert.are.equal(1, scale:GetValue())
        assert.are.equal("100%", scale.valueBox:GetText())
        local anchor = rendering:GetWidget("frame.anchor")
        assert.are.equal("CENTER", anchor:GetValue())
        assert.are.equal("Top", anchor._labels[1])
        assert.are.same({ 1, 0, 0, 1 }, { rendering:GetWidget("frame.color"):GetColor() })
        local boxes = rendering:GetWidget("channels"):GetChildren()
        assert.are.same({ "Party", "Raid", "Say" }, {
            boxes[1]:GetLabel(),
            boxes[2]:GetLabel(),
            boxes[3]:GetLabel(),
        })
        assert.are.same({ false, false, true }, {
            boxes[1]:GetValue(),
            boxes[2]:GetValue(),
            boxes[3]:GetValue(),
        })
        assert.are.equal("main", rendering:GetWidget("label"):GetText())
        assert.are.equal("Toggle key: Not bound", rendering:GetWidget("toggleKey"):GetText())
        assert.are.equal("Settings.", rendering:GetWidget("intro"):GetText())
        assert.are.equal(
            "GameFontHighlightLarge",
            rendering:GetWidget("intro").text:GetFontObject()
        )
    end)

    it("writes through the tree for every value kind", function()
        rendering:GetWidget("enabled").button:Click()
        assert.is_false(store.enabled)
        store.enabled = true

        rendering:GetWidget("frame.scale").slider:SetValue(1.6)
        assert.are.equal(1.5, store.scale)

        rendering:GetWidget("frame.anchor"):PickIndex(1)
        assert.are.equal("TOP", store.anchor)

        local picker = rendering:GetWidget("frame.color")
        picker:SetColor(0, 0.5, 1, 0.25)
        picker.button:Click()
        assert.are.same({ r = 0, g = 0.5, b = 1, a = 0.25 }, store.color)

        rendering:GetWidget("channels"):GetChildren()[2].button:Click()
        assert.are.same({ SAY = true, RAID = true }, store.channels)

        local label = rendering:GetWidget("label")
        label.singleBox:SetText("alerts")
        TestEnv.RunScript(label.singleBox, "OnEnterPressed")
        assert.are.equal("alerts", store.label)

        local key = rendering:GetWidget("toggleKey")
        key.frame:Click()
        TestEnv.RunScript(key.frame, "OnKeyDown", "F5")
        assert.are.equal("F5", store.toggleKey)
        assert.are.equal("Toggle key: F5", key:GetText())
    end)

    it("shows a validate refusal inline below the widget and clears it on success", function()
        local label = rendering:GetWidget("label")
        label.singleBox:SetText("taken")
        TestEnv.RunScript(label.singleBox, "OnEnterPressed")
        assert.are.equal("main", store.label)
        assert.are.equal("that label is taken", rendering:GetMessage("label"))
        assert.are.equal("main", label:GetText())

        local children = window:GetChildren()
        local message = nil
        for index, child in ipairs(children) do
            if child == label then
                message = children[index + 1]
            end
        end
        assert.are.equal("Label", message:GetType())
        assert.are.equal("that label is taken", message:GetText())
        -- The message is laid out right below the edit box.
        local _, _, _, _, labelY = label.frame:GetPoint(1)
        local _, _, _, _, messageY = message.frame:GetPoint(1)
        assert.are.equal(labelY - label:GetHeight(), messageY)

        label.singleBox:SetText("fine")
        TestEnv.RunScript(label.singleBox, "OnEnterPressed")
        assert.is_nil(rendering:GetMessage("label"))
        assert.is_false(WidgetKit:IsWidget(message))
        assert.are.equal("fine", store.label)
    end)

    it("shows a schema refusal inline instead of raising", function()
        local anchor = rendering:GetWidget("frame.anchor")
        anchor:SetList({ LEFT = "Left" })
        anchor:PickIndex(1)
        assert.are.equal("CENTER", store.anchor)
        assert.is_not_nil(rendering:GetMessage("frame.anchor"))
    end)

    it("disables options below a disabled group, and refreshes on OnChange", function()
        local scale = rendering:GetWidget("frame.scale")
        assert.is_true(scale.slider:IsEnabled())
        tree:Set("enabled", false)
        assert.is_false(scale.slider:IsEnabled())
        assert.is_false(rendering:GetWidget("enabled"):GetValue())

        store.scale = 2
        tree:Set("label", "renamed")
        assert.are.equal(2, scale:GetValue())
        assert.are.equal("renamed", rendering:GetWidget("label"):GetText())
    end)

    it("rebuilds when an option is shown or hidden", function()
        store.developer = true
        tree:Set("enabled", true)
        local debug = rendering:GetWidget("debug")
        assert.is_not_nil(debug)
        assert.are.equal("CheckBox", debug:GetType())
        -- Three states: unset, then unchecked, checked, and unset again.
        assert.is_nil(debug:GetValue())
        debug.button:Click()
        assert.is_false(store.debug)
        debug.button:Click()
        assert.is_true(store.debug)
        debug.button:Click()
        assert.is_nil(store.debug)

        store.developer = false
        rendering:Refresh()
        assert.is_nil(rendering:GetWidget("debug"))
        assert.is_false(WidgetKit:IsWidget(debug))
    end)

    it("asks before running an execute option with confirm", function()
        local reset = rendering:GetWidget("reset")
        reset.frame:Click()
        assert.is_nil(store.resets)
        assert.are.equal("Reset everything?", rendering:GetMessage("reset"))
        reset.frame:Click()
        assert.are.equal(1, store.resets)
        assert.is_nil(rendering:GetMessage("reset"))
    end)

    it("releases every widget together and stops listening", function()
        local widgets = {}
        for _, path in ipairs({ "intro", "frame", "frame.scale", "channels", "label" }) do
            widgets[#widgets + 1] = rendering:GetWidget(path)
        end
        local label = rendering:GetWidget("label")
        label.singleBox:SetText("taken")
        TestEnv.RunScript(label.singleBox, "OnEnterPressed")

        assert.is_true(rendering:Release())
        assert.is_false(rendering:Release())
        assert.is_true(rendering:IsReleased())
        for _, widget in ipairs(widgets) do
            assert.is_false(WidgetKit:IsWidget(widget))
        end
        assert.are.equal(0, window:GetNumChildren())
        assert.is_true(WidgetKit:IsWidget(window))
        assert.are.equal(1, WidgetKit:GetStatistics().active)

        tree:Set("label", "after release")
        assert.is_false(rendering:Refresh())
        assert.is_nil(rendering:GetWidget("label"))
    end)

    it("hides a secret value unless the caller allows it", function()
        TestEnv.InstallSecretProbe()
        rendering:Release()
        local secret = TestEnv.NewSecret()
        store.label = secret
        store.anchor = secret

        rendering = WidgetKit:RenderOptions(tree, window)
        local label = rendering:GetWidget("label")
        assert.are.equal("<secret value>", label:GetText())
        assert.is_false(label.singleBox:IsEnabled())
        assert.is_false(rendering:GetWidget("frame.anchor").button:IsEnabled())
        rendering:Release()

        rendering = WidgetKit:RenderOptions(tree, window, { allowSecret = true })
        assert.are.equal(secret, rendering:GetWidget("label"):GetText())
        assert.is_true(rendering:GetWidget("label").singleBox:IsEnabled())
    end)

    it("lays the tree out in the container once, top-down", function()
        local frameGroup = rendering:GetWidget("frame")
        local total = 0
        for _, child in ipairs(frameGroup:GetChildren()) do
            total = total + child:GetHeight()
        end
        assert.are.equal(total + 26 + 8, frameGroup:GetHeight())
        assert.are.equal(window:GetContent():GetWidth(), frameGroup:GetWidth())
    end)

    it("refuses a container that is not a container and unknown options", function()
        TestEnv.expectErrorContaining("container must be an active WidgetKit container", function()
            WidgetKit:RenderOptions(tree, WidgetKit:Create("Label"))
        end)
        TestEnv.expectErrorContaining("tree must be an OptionsKit tree", function()
            WidgetKit:RenderOptions({}, window)
        end)
        TestEnv.expectErrorContaining('unknown field "secret"', function()
            WidgetKit:RenderOptions(tree, window, { secret = true })
        end)
    end)

    it("raises at the caller when widgets run out, releasing what it made", function()
        rendering:Release()
        local held = {}
        while true do
            local box = WidgetKit:Create("CheckBox")
            if box == nil then
                break
            end
            held[#held + 1] = box
        end
        assert.are.equal(WidgetKit.MAX_CREATED, #held)
        local before = WidgetKit:GetStatistics().active
        TestEnv.expectErrorContaining("could not create a CheckBox widget: exhausted", function()
            WidgetKit:RenderOptions(tree, window)
        end)
        assert.are.equal(before, WidgetKit:GetStatistics().active)
        assert.are.equal(0, window:GetNumChildren())
        for _, box in ipairs(held) do
            WidgetKit:Release(box)
        end
    end)

    it("refuses malformed allowSecret and media options at the caller", function()
        local other = WidgetKit:Create("Frame")
        TestEnv.expectErrorContaining(
            "WidgetKit:RenderOptions options.allowSecret must be a boolean",
            function()
                WidgetKit:RenderOptions(tree, other, { allowSecret = "yes" })
            end
        )
        TestEnv.expectErrorContaining(
            "WidgetKit:RenderOptions options.media must be a table",
            function()
                WidgetKit:RenderOptions(tree, other, { media = "font" })
            end
        )
        TestEnv.expectErrorContaining(
            "WidgetKit:RenderOptions options.media must map option paths to media types",
            function()
                WidgetKit:RenderOptions(tree, other, { media = { "font" } })
            end
        )
        -- Nothing was drawn into the container by a refused call.
        assert.are.equal(0, other:GetNumChildren())
    end)
end)

describe("WidgetKit options renderer without OptionsKit", function()
    after_each(TestEnv.Reset)

    it("raises at the caller", function()
        local WidgetKit = TestEnv.NewPackageWithoutOptionsKit()
        local window = WidgetKit:Create("Frame")
        TestEnv.expectErrorContaining(
            "WidgetKit:RenderOptions requires OptionsKit API 1",
            function()
                WidgetKit:RenderOptions({}, window)
            end
        )
    end)
end)
