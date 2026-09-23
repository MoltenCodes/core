local TestEnv = require("WidgetKitTestEnv")

---A minimal widget constructor counting how often it ran.
---@param counter table `{ built = 0 }`, incremented per construction
---@param extra table? fields copied onto every widget it builds
local function countingConstructor(counter, extra)
    return function()
        counter.built = counter.built + 1
        local createFrame = TestEnv.GetGlobal("CreateFrame")
        local widget = { frame = createFrame("Frame"), builtBy = counter.name }
        for key, value in pairs(extra or {}) do
            widget[key] = value
        end
        return widget
    end
end

describe("WidgetKit type registry", function()
    local WidgetKit
    before_each(function()
        WidgetKit = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    it("registers the twelve base widget types at version 1", function()
        for _, name in ipairs({
            "Frame",
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
        }) do
            assert.are.equal(1, WidgetKit:GetTypeVersion(name))
        end
        assert.is_nil(WidgetKit:GetTypeVersion("Unknown"))
    end)

    it("registers a type, ignores a lower version and reports an equal one", function()
        local counter = { built = 0, name = "first" }
        assert.is_true(WidgetKit:RegisterType("Counter", countingConstructor(counter), 3))
        assert.are.equal(3, WidgetKit:GetTypeVersion("Counter"))

        local older = { built = 0, name = "older" }
        local registered, reason = WidgetKit:RegisterType("Counter", countingConstructor(older), 2)
        assert.is_false(registered)
        assert.are.equal("older", reason)
        registered, reason = WidgetKit:RegisterType("Counter", countingConstructor(older), 3)
        assert.is_false(registered)
        assert.are.equal("current", reason)

        local widget = WidgetKit:Create("Counter")
        assert.are.equal("first", widget.builtBy)
        assert.are.equal(0, older.built)
        assert.are.equal("Counter", widget:GetType())
    end)

    it("answers an unknown type with a reason", function()
        local widget, reason = WidgetKit:Create("Nope")
        assert.is_nil(widget)
        assert.are.equal("unknownType", reason)
    end)

    it("round-trips acquire and release, and reuses the pooled widget", function()
        local counter = { built = 0 }
        WidgetKit:RegisterType("Counter", countingConstructor(counter), 1)

        local first = WidgetKit:Create("Counter")
        assert.is_true(WidgetKit:IsWidget(first))
        assert.is_true(first:IsShown())
        assert.is_true(WidgetKit:Release(first))
        assert.is_false(WidgetKit:IsWidget(first))
        assert.is_false(first.frame:IsShown())

        local second = WidgetKit:Create("Counter")
        assert.are.equal(first, second)
        assert.are.equal(1, counter.built)

        local third = WidgetKit:Create("Counter")
        assert.are_not.equal(second, third)
        assert.are.equal(2, counter.built)

        local statistics = WidgetKit:GetStatistics()
        assert.are.equal(2, statistics.byType.Counter.created)
        assert.are.equal(2, statistics.byType.Counter.active)
        assert.are.equal(0, statistics.byType.Counter.available)
        WidgetKit:Release(second)
        WidgetKit:Release(third)
        statistics = WidgetKit:GetStatistics()
        assert.are.equal(0, statistics.byType.Counter.active)
        assert.are.equal(2, statistics.byType.Counter.available)
        assert.are.equal(13, statistics.types)
    end)

    it("calls OnAcquire on every acquire and OnRelease on every release", function()
        local calls = {}
        WidgetKit:RegisterType("Hooks", function()
            return {
                frame = TestEnv.GetGlobal("CreateFrame")("Frame"),
                OnAcquire = function(widget)
                    calls[#calls + 1] = "acquire"
                    widget:SetUserData("seen", true)
                end,
                OnRelease = function(widget)
                    calls[#calls + 1] = "release:" .. tostring(widget:GetUserData("seen"))
                end,
            }
        end, 1)

        local widget = WidgetKit:Create("Hooks")
        WidgetKit:Release(widget)
        WidgetKit:Create("Hooks")
        assert.are.same({ "acquire", "release:true", "acquire" }, calls)
    end)

    it("discards pooled widgets built by an older version after an upgrade", function()
        local old = { built = 0, name = "old" }
        local new = { built = 0, name = "new" }
        WidgetKit:RegisterType("Counter", countingConstructor(old), 1)

        local pooled = WidgetKit:Create("Counter")
        local borrowed = WidgetKit:Create("Counter")
        WidgetKit:Release(pooled)

        assert.is_true(WidgetKit:RegisterType("Counter", countingConstructor(new), 2))
        assert.are.equal(2, WidgetKit:GetTypeVersion("Counter"))

        local fresh = WidgetKit:Create("Counter")
        assert.are_not.equal(pooled, fresh)
        assert.are.equal("new", fresh.builtBy)
        assert.is_false(pooled.frame:IsShown())

        -- A borrowed stale widget is still released, then retired rather
        -- than handed out again.
        WidgetKit:Release(borrowed)
        local another = WidgetKit:Create("Counter")
        assert.are_not.equal(borrowed, another)
        assert.are.equal("new", another.builtBy)
        assert.is_false(WidgetKit:IsWidget(borrowed))

        local statistics = WidgetKit:GetStatistics().byType.Counter
        assert.are.equal(2, statistics.version)
        assert.are.equal(2, statistics.discarded)
        -- The cap grew by the two frames the upgrade retired.
        assert.are.equal(WidgetKit.MAX_CREATED + 2, statistics.maxCreated)
    end)

    it("caps the frames a type ever builds with a named refusal", function()
        local counter = { built = 0 }
        WidgetKit:RegisterType("Capped", countingConstructor(counter), 1, { maxCreated = 2 })
        local first = WidgetKit:Create("Capped")
        local second = WidgetKit:Create("Capped")
        local third, reason = WidgetKit:Create("Capped")
        assert.is_nil(third)
        assert.are.equal("exhausted", reason)
        assert.are.equal(2, counter.built)

        WidgetKit:Release(first)
        assert.are.equal(first, WidgetKit:Create("Capped"))
        assert.is_not_nil(second)
        assert.are.equal(256, WidgetKit.MAX_CREATED)
    end)

    it("refuses a constructor result that breaks the author contract at the caller", function()
        local cases = {
            {
                name = "NotTable",
                build = function()
                    return 1
                end,
                message = "must return a table",
            },
            {
                name = "NoFrame",
                build = function()
                    return {}
                end,
                message = "frame field is a frame",
            },
            {
                name = "Metatable",
                build = function()
                    return setmetatable({ frame = {} }, {})
                end,
                message = "without a metatable",
            },
            {
                name = "BadHook",
                build = function()
                    return { frame = TestEnv.GetGlobal("CreateFrame")("Frame"), OnAcquire = 1 }
                end,
                message = "OnAcquire field",
            },
        }
        for _, case in ipairs(cases) do
            WidgetKit:RegisterType(case.name, case.build, 1)
            TestEnv.expectErrorContaining(case.message, function()
                WidgetKit:Create(case.name)
            end)
        end
    end)

    it("passes a constructor's own error through unchanged", function()
        WidgetKit:RegisterType("Broken", function()
            error({ reason = "constructor bug" })
        end, 1)
        local ok, failure = pcall(WidgetKit.Create, WidgetKit, "Broken")
        assert.is_false(ok)
        assert.are.same({ reason = "constructor bug" }, failure)
    end)

    it("releases a widget whose OnAcquire raised and passes the error on", function()
        WidgetKit:RegisterType("BadAcquire", function()
            return {
                frame = TestEnv.GetGlobal("CreateFrame")("Frame"),
                OnAcquire = function()
                    error("acquire failed", 0)
                end,
            }
        end, 1)
        local ok, failure = pcall(WidgetKit.Create, WidgetKit, "BadAcquire")
        assert.is_false(ok)
        assert.are.equal("acquire failed", failure)
        assert.are.equal(0, WidgetKit:GetStatistics().byType.BadAcquire.active)
    end)

    it("validates registration arguments", function()
        TestEnv.expectErrorContaining("name must be a non-empty string", function()
            WidgetKit:RegisterType("", function() end, 1)
        end)
        TestEnv.expectErrorContaining("constructor must be a function", function()
            WidgetKit:RegisterType("X", nil, 1)
        end)
        TestEnv.expectErrorContaining("version must be a positive integer", function()
            WidgetKit:RegisterType("X", function() end, 1.5)
        end)
        TestEnv.expectErrorContaining('unknown field "cap"', function()
            WidgetKit:RegisterType("X", function() end, 1, { cap = 1 })
        end)
        TestEnv.expectErrorContaining("maxCreated must be at most 4096", function()
            WidgetKit:RegisterType("X", function() end, 1, { maxCreated = 5000 })
        end)
    end)
end)
