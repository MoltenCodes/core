local TestEnv = require("CommKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src

---Run `action` and assert it failed with `message` reported at the line of this
---spec file that called into CommKit. A wrong `error` level shows up either as
---a different line number or as a message with no `file:line` prefix at all.
---
---`action` receives a `mark` function; calling `mark()` records the line of the
---statement on the line after it, which must be the call into CommKit.
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

local function noop() end

describe("CommKit error levels", function()
    local CommKit, scope
    before_each(function()
        CommKit = TestEnv.Load({ schemaKit = true })
        scope = CommKit:CreateScope()
    end)
    after_each(TestEnv.Reset)

    it("points facade receiver and argument errors at the caller", function()
        for _, method in ipairs({
            "CreateScope",
            "ForAddon",
            "CloseAddonScopes",
            "GetQueueDepth",
            "GetBudget",
            "SetLimits",
            "GetLimits",
            "GetStatistics",
        }) do
            assertReportedAtCaller(
                "CommKit:"
                    .. method
                    .. " must be called on the CommKit facade; use CommKit:"
                    .. method
                    .. "(...)",
                function(mark)
                    mark()
                    CommKit[method]({})
                end
            )
        end
        assertReportedAtCaller(
            "CommKit:ForAddon addonName must be a non-empty string",
            function(mark)
                mark()
                CommKit:ForAddon("")
            end
        )
        assertReportedAtCaller(
            "CommKit:CloseAddonScopes addonName must be a non-empty string",
            function(mark)
                mark()
                CommKit:CloseAddonScopes(nil)
            end
        )
        assertReportedAtCaller(
            "CommKit:GetQueueDepth priority must be CommKit.Priority.ALERT, NORMAL, BULK or nil",
            function(mark)
                mark()
                CommKit:GetQueueDepth("URGENT")
            end
        )
    end)

    it("points limit errors at the caller", function()
        assertReportedAtCaller("CommKit:SetLimits limits must be a table", function(mark)
            mark()
            CommKit:SetLimits(5)
        end)
        assertReportedAtCaller(
            'CommKit:SetLimits limits contains unknown field "maxBytes"',
            function(mark)
                mark()
                CommKit:SetLimits({ maxBytes = 5 })
            end
        )
        assertReportedAtCaller(
            "CommKit:SetLimits limits.maxCps must be an integer from 1 to 100000",
            function(mark)
                mark()
                CommKit:SetLimits({ maxCps = 1.5 })
            end
        )
        assertReportedAtCaller(
            "CommKit:SetLimits limits.reassemblyTimeout must be a number from 1 to 600",
            function(mark)
                mark()
                CommKit:SetLimits({ reassemblyTimeout = 0 })
            end
        )
    end)

    it("points every prototype's receiver error at the caller", function()
        local prototypes = {
            ["CommKit.Scope"] = { "CommKit scope", CommKit.Scope },
            ["CommKit.Connection"] = { "CommKit connection", CommKit.Connection },
            ["CommKit.SendHandle"] = { "CommKit send handle", CommKit.SendHandle },
            ["CommKit.SyncSet"] = { "CommKit SyncSet", CommKit.SyncSet },
        }
        for label, entry in pairs(prototypes) do
            for name, method in pairs(entry[2]) do
                assertReportedAtCaller(
                    label .. ":" .. name .. " must be called on a " .. entry[1],
                    function(mark)
                        mark()
                        method({}, "x", noop)
                    end
                )
            end
        end
    end)

    it("points Register argument errors at the caller", function()
        assertReportedAtCaller(
            "CommKit.Scope:Register prefix must be a string of 1 to 16 bytes",
            function(mark)
                mark()
                scope:Register(string.rep("p", 17), noop)
            end
        )
        assertReportedAtCaller("CommKit.Scope:Register callback must be a function", function(mark)
            mark()
            scope:Register("CKTest", "noop")
        end)
    end)

    it("points Send request errors at the caller", function()
        local cases = {
            { "CommKit.Scope:Send request must be a table", "request" },
            {
                'CommKit.Scope:Send request contains unknown field "channel"',
                { prefix = "P", text = "t", distribution = "PARTY", channel = 1 },
            },
            {
                "CommKit.Scope:Send request.prefix must be a string of 1 to 16 bytes",
                { prefix = "", text = "t", distribution = "PARTY" },
            },
            {
                "CommKit.Scope:Send request.text must be a string",
                { prefix = "P", text = 5, distribution = "PARTY" },
            },
            {
                "CommKit.Scope:Send request.distribution must be a string",
                { prefix = "P", text = "t" },
            },
            {
                "CommKit.Scope:Send request.target must be a string, a number or nil",
                { prefix = "P", text = "t", distribution = "WHISPER", target = {} },
            },
            {
                "CommKit.Scope:Send request.priority must be CommKit.Priority.ALERT, NORMAL or BULK",
                { prefix = "P", text = "t", distribution = "PARTY", priority = "HIGH" },
            },
            {
                "CommKit.Scope:Send request.constraints must be a table or nil",
                { prefix = "P", text = "t", distribution = "PARTY", constraints = true },
            },
            {
                'CommKit.Scope:Send request.constraints contains unknown field "safe"',
                { prefix = "P", text = "t", distribution = "PARTY", constraints = { safe = true } },
            },
            {
                "CommKit.Scope:Send request.constraints.logged must be a boolean or nil",
                { prefix = "P", text = "t", distribution = "PARTY", constraints = { logged = 1 } },
            },
            {
                "CommKit.Scope:Send request.constraints.battleNet must be a boolean or nil",
                {
                    prefix = "P",
                    text = "t",
                    distribution = "PARTY",
                    constraints = { battleNet = "yes" },
                },
            },
            {
                "CommKit.Scope:Send request.onProgress must be a function or nil",
                { prefix = "P", text = "t", distribution = "PARTY", onProgress = 1 },
            },
            {
                "CommKit.Scope:Send request.onComplete must be a function or nil",
                { prefix = "P", text = "t", distribution = "PARTY", onComplete = 1 },
            },
        }
        for _, case in ipairs(cases) do
            assertReportedAtCaller(case[1], function(mark)
                mark()
                scope:Send(case[2])
            end)
        end
    end)

    it("points SyncSet construction errors at the caller", function()
        local cases = {
            {
                "CommKit.Scope:SyncSet prefix must be a string of 1 to 16 bytes",
                "",
                { fields = { "a" } },
            },
            { "CommKit.Scope:SyncSet options must be a table", "CKSync", nil },
            {
                'CommKit.Scope:SyncSet options contains unknown field "field"',
                "CKSync",
                { field = { "a" } },
            },
            {
                "CommKit.Scope:SyncSet options.fields must be an array of 1 to 32 field names",
                "CKSync",
                { fields = {} },
            },
            {
                "CommKit.Scope:SyncSet options.fields entry must be a string of 1 to 64 bytes",
                "CKSync",
                { fields = { 5 } },
            },
            {
                "CommKit.Scope:SyncSet options.fields must not name a field twice",
                "CKSync",
                { fields = { "a", "a" } },
            },
            {
                "CommKit.Scope:SyncSet options.schema must be a table of sealed SchemaKit schemas or nil",
                "CKSync",
                { fields = { "a" }, schema = 5 },
            },
            {
                "CommKit.Scope:SyncSet options.schema names a field that is not declared",
                "CKSync",
                { fields = { "a" }, schema = { b = {} } },
            },
            {
                "CommKit.Scope:SyncSet options.schema.a must be a sealed SchemaKit schema",
                "CKSync",
                { fields = { "a" }, schema = { a = {} } },
            },
        }
        for _, case in ipairs(cases) do
            assertReportedAtCaller(case[1], function(mark)
                mark()
                scope:SyncSet(case[2], case[3])
            end)
        end
    end)

    it("points SyncSet method errors at the caller", function()
        local sync = assert(scope:SyncSet("CKSync", { fields = { "a" } }))
        assertReportedAtCaller(
            "CommKit.SyncSet:Set field is not declared in this SyncSet",
            function(mark)
                mark()
                sync:Set("b", 1)
            end
        )
        assertReportedAtCaller(
            "CommKit.SyncSet:Get field must be a string of 1 to 64 bytes",
            function(mark)
                mark()
                sync:Get(nil)
            end
        )
        assertReportedAtCaller(
            "CommKit.SyncSet:GetRemote sender must be a string of 1 to 255 bytes",
            function(mark)
                mark()
                sync:GetRemote(1, "a")
            end
        )
        assertReportedAtCaller(
            "CommKit.SyncSet:Request target must be a string of 1 to 255 bytes",
            function(mark)
                mark()
                sync:Request("")
            end
        )
        assertReportedAtCaller(
            "CommKit.SyncSet:OnChanged callback must be a function",
            function(mark)
                mark()
                sync:OnChanged(nil)
            end
        )
    end)

    it("points secret-value refusals at the caller", function()
        local secret = "secret text"
        -- selene: allow(global_usage)
        rawset(_G, "issecretvalue", function(value)
            return value == secret
        end)
        local sync = assert(scope:SyncSet("CKSync", { fields = { "a" } }))
        assertReportedAtCaller(
            "CommKit.Scope:Send request.text must not be a secret value",
            function(mark)
                mark()
                scope:Send({ prefix = "P", text = secret, distribution = "PARTY" })
            end
        )
        assertReportedAtCaller(
            "CommKit.SyncSet:Set value must not be a secret value",
            function(mark)
                mark()
                sync:Set("a", secret)
            end
        )
        assertReportedAtCaller(
            "CommKit.SyncSet:Set value must not contain a secret value",
            function(mark)
                mark()
                sync:Set("a", { secret })
            end
        )
        assertReportedAtCaller(
            "CommKit.Scope:Register prefix must not be a secret value",
            function(mark)
                mark()
                scope:Register(secret, noop)
            end
        )
    end)

    it("refuses a secret constraint or limit at the caller before comparing it", function()
        -- A secret boolean and a secret number: neither may be compared.
        -- selene: allow(global_usage)
        rawset(_G, "issecretvalue", function(value)
            return value == true or value == 17
        end)
        assertReportedAtCaller(
            "CommKit.Scope:Send request.constraints must not hold a secret value",
            function(mark)
                mark()
                scope:Send({
                    prefix = "P",
                    text = "x",
                    distribution = "PARTY",
                    constraints = { logged = true },
                })
            end
        )
        assertReportedAtCaller(
            "CommKit:SetLimits limits.maxQueuedMessages must not be a secret value",
            function(mark)
                mark()
                CommKit:SetLimits({ maxQueuedMessages = 17 })
            end
        )
        assert.are.equal(256, CommKit:GetLimits().maxQueuedMessages)
    end)

    it(
        "refuses a secret limit of any type, and a secret object bound, before comparing it",
        function()
            -- A secret string and a secret number. The string limit is refused as
            -- a secret, not as a non-number: it is asked before the comparison
            -- with `CommKit.UNBOUNDED`, which would raise on a secret.
            -- selene: allow(global_usage)
            rawset(_G, "issecretvalue", function(value)
                return value == "hidden" or value == 17
            end)
            assertReportedAtCaller(
                "CommKit:SetLimits limits.burst must not be a secret value",
                function(mark)
                    mark()
                    CommKit:SetLimits({ burst = "hidden" })
                end
            )
            assertReportedAtCaller(
                "CommKit:CreateScope options.maxRegistrations must not be a secret value",
                function(mark)
                    mark()
                    CommKit:CreateScope({ maxRegistrations = 17 })
                end
            )
            assertReportedAtCaller(
                "CommKit:ForAddon options.maxRegistrations must not be a secret value",
                function(mark)
                    mark()
                    CommKit:ForAddon("MyAddon", { maxRegistrations = 17 })
                end
            )
            assertReportedAtCaller(
                "CommKit.Scope:SyncSet options.maxListeners must not be a secret value",
                function(mark)
                    mark()
                    scope:SyncSet("CKSync", { fields = { "a" }, maxListeners = 17 })
                end
            )
            assert.are.equal(4000, CommKit:GetLimits().burst)
        end
    )
end)
