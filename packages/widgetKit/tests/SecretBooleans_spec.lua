local TestEnv = require("WidgetKitTestEnv")

-- On the client, testing a secret as a boolean (`if`, `and`, `or`, `not`) or
-- comparing it with a value of its own type raises inside the code that does
-- it. These specs cover every place a value WidgetKit did not create decides a
-- branch: a secret flag argument is refused at the caller's line, and a
-- secret answer from the host, a layout or an OptionsKit tree takes the path
-- `docs/API.md` ("Secret booleans") documents. Plain Lua never raises on a
-- boolean test, so besides the table stand-in `NewSecret` returns, a spec can
-- mark a plain value (`true`, a number) as secret: the probe then reports it,
-- and an outcome that differs from the value's plain meaning shows the Kit
-- asked before it tested. A value marked `"once"` is reported a single time,
-- so a `true` a spec hands back as secret does not also turn the Kit's own
-- `true` arguments secret afterwards.

local SOURCE = debug.getinfo(1, "S").short_src

---Run `action` and assert it failed with `message` reported at the line after
---the one that called `mark()`.
---@param message string
---@param action fun(mark: fun())
local function assertReportedAtCaller(message, action)
    local expectedLine = nil
    local function mark()
        expectedLine = debug.getinfo(2, "l").currentline + 1
    end
    local ok, value = pcall(action, mark)
    assert.is_false(ok)
    assert.are.equal(SOURCE .. ":" .. tostring(expectedLine) .. ": " .. message, value)
end

---A stand-in for an OptionsKit tree that forwards every method to `tree`,
---except those in `overrides`, as a consumer's wrapper would.
---@param tree table
---@param overrides table<string, function>
---@return table
local function proxyTree(tree, overrides)
    local proxy = {}
    for _, name in ipairs({
        "Describe",
        "Get",
        "Set",
        "Validate",
        "Execute",
        "IsDisabled",
        "IsHidden",
        "OnChange",
    }) do
        proxy[name] = overrides[name]
            or function(_, ...)
                return tree[name](tree, ...)
            end
    end
    return proxy
end

---The node at `path` among the children of a description.
---@param description table
---@param path string
---@return table
local function findNode(description, path)
    for _, node in ipairs(description.children) do
        if node.path == path then
            return node
        end
    end
    error("no node " .. path)
end

describe("WidgetKit and secret booleans", function()
    local WidgetKit, OptionsKit, secret, marked
    before_each(function()
        local _
        WidgetKit, _, _, _, _, OptionsKit = TestEnv.NewPackage()
        TestEnv.InstallSecretProbe()
        local tableProbe = TestEnv.GetGlobal("issecretvalue")
        marked = {}
        TestEnv.SetGlobal("issecretvalue", function(value)
            local mark = type(value) ~= "nil" and marked[value] or nil
            if mark == "once" then
                marked[value] = nil
                return true
            end
            if mark then
                return true
            end
            return tableProbe(value)
        end)
        TestEnv.TakeReportedErrors()
        secret = TestEnv.NewSecret()
    end)
    after_each(TestEnv.Reset)

    it("refuses a secret flag argument at the caller's line", function()
        local cases = {
            { "Spacer", "SetDisabled", "WidgetKit.Widget:SetDisabled disabled" },
            { "Label", "SetDisabled", "WidgetKit Label:SetDisabled disabled" },
            { "Button", "SetDisabled", "WidgetKit Button:SetDisabled disabled" },
            { "Label", "SetFullWidth", "WidgetKit.Widget:SetFullWidth fullWidth" },
            { "Label", "SetFullHeight", "WidgetKit.Widget:SetFullHeight fullHeight" },
            { "Frame", "SetResizable", "WidgetKit Frame:SetResizable resizable" },
            { "Frame", "SetMovable", "WidgetKit Frame:SetMovable movable" },
            { "Button", "SetKeyCapture", "WidgetKit Button:SetKeyCapture enabled" },
            { "CheckBox", "SetTriState", "WidgetKit CheckBox:SetTriState enabled" },
            { "Slider", "SetIsPercent", "WidgetKit Slider:SetIsPercent isPercent" },
            { "EditBox", "SetMultiLine", "WidgetKit EditBox:SetMultiLine multiLine" },
            { "ColorPicker", "SetHasAlpha", "WidgetKit ColorPicker:SetHasAlpha hasAlpha" },
        }
        for _, case in ipairs(cases) do
            local widget = WidgetKit:Create(case[1])
            ---@cast widget -nil
            local method = widget[case[2]]
            assertReportedAtCaller(case[3] .. " must not be a secret value", function(mark)
                mark()
                method(widget, secret)
            end)
            WidgetKit:Release(widget)
        end

        -- A secret `true` is refused too, and the flag stays unset.
        marked[true] = true
        local label = WidgetKit:Create("Label") ---@cast label -nil
        assertReportedAtCaller(
            "WidgetKit.Widget:SetFullWidth fullWidth must not be a secret value",
            function(mark)
                mark()
                label:SetFullWidth(true)
            end
        )
        assert.is_false(label:IsFullWidth())
    end)

    it("refuses a secret allowSecret or restore option at the caller's line", function()
        local label = WidgetKit:Create("Label") --[[@as WidgetKit.Label]]
        assertReportedAtCaller(
            "WidgetKit Label:SetText options.allowSecret must not be a secret value",
            function(mark)
                mark()
                label:SetText("text", { allowSecret = secret })
            end
        )

        local window = WidgetKit:Create("Frame") ---@cast window -nil
        local tree = OptionsKit:Define("SecretOptionSpec", {
            type = "group",
            args = { intro = { type = "description", name = "Intro." } },
        })
        assertReportedAtCaller(
            "WidgetKit:RenderOptions options.allowSecret must not be a secret value",
            function(mark)
                mark()
                WidgetKit:RenderOptions(tree, window, { allowSecret = secret })
            end
        )

        assertReportedAtCaller(
            "WidgetKit:BindPosition options.restore must not be a secret value",
            function(mark)
                mark()
                WidgetKit:BindPosition(window.frame, {}, { restore = secret })
            end
        )
        assertReportedAtCaller(
            "WidgetKit Frame:BindPosition options.restore must not be a secret value",
            function(mark)
                mark()
                window:BindPosition({}, { restore = secret })
            end
        )
    end)

    it("refuses a secret anchor offset instead of defaulting it", function()
        local frame = TestEnv.GetGlobal("CreateFrame")("Frame", nil, TestEnv.GetGlobal("UIParent"))
        local parent = TestEnv.GetGlobal("UIParent")
        assertReportedAtCaller(
            "WidgetKit.Anchor.Normalize x must not be a secret value",
            function(mark)
                mark()
                WidgetKit.Anchor.Normalize(frame, "TOP", parent, "TOP", secret, 0)
            end
        )
        assertReportedAtCaller(
            "WidgetKit.Anchor.Normalize y must not be a secret value",
            function(mark)
                mark()
                WidgetKit.Anchor.Normalize(frame, "TOP", parent, "TOP", 0, secret)
            end
        )
        assertReportedAtCaller(
            "WidgetKit.Anchor.Apply anchor.x must not be a secret value",
            function(mark)
                mark()
                WidgetKit.Anchor.Apply(frame, { point = "TOP", x = secret })
            end
        )
        -- The documented defaults stay: a missing or false offset is 0.
        local anchor = WidgetKit.Anchor.Normalize(frame, "TOP", parent, "TOP")
        assert.are.equal(0, anchor.x)
        assert.are.equal(0, anchor.y)

        -- A saved anchor with a secret offset is reported, never applied.
        frame:SetSize(10, 10)
        frame:SetPoint("CENTER")
        local binding = WidgetKit:BindPosition(frame, { anchor = { point = "TOP", y = secret } })
        assert.are.equal("CENTER", (frame:GetPoint(1)))
        local reported = TestEnv.TakeReportedErrors()
        assert.are.equal(1, #reported)
        assert.is_truthy(
            tostring(reported[1].value):find("anchor.y must not be a secret value", 1, true)
        )
        binding:Release()
    end)

    it("answers nil or notPositioned when the host's geometry is secret", function()
        local frame = TestEnv.GetGlobal("CreateFrame")("Frame", nil, TestEnv.GetGlobal("UIParent"))
        frame:SetSize(10, 10)
        frame:SetPoint("CENTER")
        marked[7] = true
        function frame.GetPoint()
            return "CENTER", nil, "CENTER", 7, 7
        end
        assert.is_nil(WidgetKit.Anchor.Read(frame))

        local other = TestEnv.GetGlobal("CreateFrame")("Frame", nil, TestEnv.GetGlobal("UIParent"))
        other:SetSize(10, 10)
        other:SetPoint("CENTER")
        marked[11] = true
        function other.GetRect()
            return 11, 11, 11, 11
        end
        local storage = {}
        local binding = WidgetKit:BindPosition(other, storage, { restore = false })
        local anchor, reason = binding:Capture()
        assert.is_nil(anchor)
        assert.are.equal("notPositioned", reason)
        assert.is_nil(storage.anchor)
        binding:Release()
    end)

    it("ignores a secret size returned by a layout", function()
        local group = WidgetKit:Create("Group") --[[@as WidgetKit.Container]]
        marked[40] = true
        group:SetLayout(function()
            return 40, 40
        end)
        local done = group:PerformLayout()
        assert.is_true(done)
    end)

    describe("rendering a tree whose answers are secret", function()
        local window, store, tree
        before_each(function()
            window = WidgetKit:Create("Frame")
            store = { enabled = true, label = "main", runs = 0 }
            tree = OptionsKit:Define("SecretTreeSpec", {
                type = "group",
                args = {
                    intro = { type = "description", name = "Intro.", order = 1 },
                    enabled = {
                        type = "toggle",
                        name = "Enabled",
                        order = 2,
                        get = function()
                            return store.enabled
                        end,
                        set = function(_, value)
                            store.enabled = value
                        end,
                    },
                    label = {
                        type = "input",
                        name = "Label",
                        order = 3,
                        get = function()
                            return store.label
                        end,
                        set = function(_, value)
                            store.label = value
                        end,
                    },
                    run = {
                        type = "execute",
                        name = "Run",
                        order = 4,
                        func = function()
                            store.runs = store.runs + 1
                        end,
                    },
                },
            })
        end)

        it("disables an option whose IsDisabled answer is secret", function()
            local proxy = proxyTree(tree, {
                IsDisabled = function()
                    return secret
                end,
            })
            local rendering = WidgetKit:RenderOptions(proxy, window)
            assert.is_false(rendering:GetWidget("label").singleBox:IsEnabled())
            assert.is_true(rendering:Refresh())
            assert.is_false(rendering:GetWidget("enabled").button:IsEnabled())
        end)

        it("keeps an option whose hidden state is secret in view, without rebuilding", function()
            local proxy = proxyTree(tree, {
                Describe = function()
                    local description = tree:Describe()
                    findNode(description, "label").hidden = secret
                    return description
                end,
                IsHidden = function()
                    marked[true] = "once"
                    return true
                end,
            })
            local rendering = WidgetKit:RenderOptions(proxy, window)
            local label = rendering:GetWidget("label")
            assert.is_not_nil(label)
            assert.is_true(rendering:Refresh())
            assert.are.equal(label, rendering:GetWidget("label"))
        end)

        it("reads secret hints as unset, a secret confirm as a question", function()
            local proxy = proxyTree(tree, {
                Describe = function()
                    local description = tree:Describe()
                    findNode(description, "enabled").tristate = secret
                    findNode(description, "label").multiline = secret
                    findNode(description, "intro").fontSize = secret
                    findNode(description, "run").confirm = secret
                    return description
                end,
            })
            local rendering = WidgetKit:RenderOptions(proxy, window)
            assert.is_false(rendering:GetWidget("enabled")._triState)
            assert.is_false(rendering:GetWidget("label"):IsMultiLine())

            local run = rendering:GetWidget("run")
            run.frame:Click()
            assert.are.equal(0, store.runs)
            assert.are.equal("Click again to confirm.", rendering:GetMessage("run"))
            run.frame:Click()
            assert.are.equal(1, store.runs)
        end)

        it("treats a secret Validate or Set answer as a refusal", function()
            local proxy = proxyTree(tree, {
                Validate = function()
                    marked[true] = "once"
                    return true, secret
                end,
            })
            local rendering = WidgetKit:RenderOptions(proxy, window)
            local label = rendering:GetWidget("label")
            label.singleBox:SetText("next")
            TestEnv.RunScript(label.singleBox, "OnEnterPressed")
            assert.are.equal("main", store.label)
            assert.are.equal("<secret value>", rendering:GetMessage("label"))
            rendering:Release()

            proxy = proxyTree(tree, {
                Set = function()
                    return secret
                end,
            })
            rendering = WidgetKit:RenderOptions(proxy, window)
            label = rendering:GetWidget("label")
            label.singleBox:SetText("next")
            TestEnv.RunScript(label.singleBox, "OnEnterPressed")
            assert.are.equal("refused", rendering:GetMessage("label"))
            assert.are.same({}, TestEnv.TakeReportedErrors())
        end)
    end)
end)
