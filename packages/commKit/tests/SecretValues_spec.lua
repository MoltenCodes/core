local TestEnv = require("CommKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src
local PREFIX = "CKTest"

---Make `issecretvalue` report exactly the values in `secrets` as secret.
---
---Each secret is a fresh table, so a comparison with anything else is `false`
---in these specs; what they check is the outcome CommKit documents for a
---value it may not compare.
---@param ... any
local function markSecret(...)
    local secrets = {}
    for index = 1, select("#", ...) do
        secrets[select(index, ...)] = true
    end
    -- selene: allow(global_usage)
    rawset(_G, "issecretvalue", function(value)
        return type(value) == "table" and secrets[value] == true
    end)
end

describe("CommKit and secret values from outside", function()
    after_each(TestEnv.Reset)

    it("refuses a secret facade receiver at the caller before comparing it", function()
        local CommKit = TestEnv.NewPackage()
        local secret = {}
        markSecret(secret)
        local line
        local ok, failure = pcall(function()
            line = debug.getinfo(1, "l").currentline + 1
            CommKit.GetQueueDepth(secret)
        end)
        assert.is_false(ok)
        assert.are.equal(
            SOURCE
                .. ":"
                .. line
                .. ": CommKit:GetQueueDepth must be called on the CommKit facade;"
                .. " use CommKit:GetQueueDepth(...)",
            failure
        )
    end)

    it("treats a secret send result as a throttle and sends again later", function()
        local CommKit = TestEnv.NewPackage()
        local scope = CommKit:CreateScope()
        local secret = {}
        markSecret(secret)
        TestEnv.QueueSendResults(secret)
        local handle = scope:Send({ prefix = PREFIX, text = "hello", distribution = "PARTY" })
        TestEnv.Advance(0)
        assert.are.equal("queued", handle:GetState())
        assert.are.equal(1, CommKit:GetStatistics().throttled)
        TestEnv.Advance(1)
        assert.are.equal("sent", handle:GetState())
        assert.are.same({}, TestEnv.TakeReportedErrors())
    end)

    it("uses the fallback for a secret entry of the client's result enum", function()
        local CommKit = TestEnv.NewPackage()
        local scope = CommKit:CreateScope()
        local secret = {}
        markSecret(secret)
        local results = {}
        for name, value in pairs(TestEnv.SEND_RESULT) do
            results[name] = value
        end
        results.Success = secret
        -- selene: allow(global_usage)
        rawget(_G, "Enum").SendAddonMessageResult = results
        local handle = scope:Send({ prefix = PREFIX, text = "hello", distribution = "PARTY" })
        TestEnv.Advance(0)
        assert.are.equal("sent", handle:GetState())
    end)

    it("refuses a prefix whose registration result is secret as unknownResult", function()
        local CommKit = TestEnv.NewPackage()
        local scope = CommKit:CreateScope()
        local secret = {}
        markSecret(secret)
        TestEnv.QueueRegisterResult(secret)
        assert.are.same({ nil, "unknownResult" }, { scope:Register("Odd", function() end) })
    end)

    it("registers a prefix when the client's registered check answers a secret", function()
        local CommKit = TestEnv.NewPackage()
        local scope = CommKit:CreateScope()
        local secret = {}
        markSecret(secret)
        -- selene: allow(global_usage)
        rawget(_G, "C_ChatInfo").IsAddonMessagePrefixRegistered = function()
            return secret
        end
        assert.is_not_nil(scope:Register(PREFIX, function() end))
        assert.are.same({ PREFIX }, TestEnv.Chat().registerCalls)
    end)

    it("does not take a secret schema verdict for an acceptance", function()
        local CommKit, loaded = TestEnv.Load({ schemaKit = true })
        local SchemaKit = loaded.SchemaKit
        local schema = SchemaKit:Seal(SchemaKit.any())
        local secret = {}
        rawset(schema, "Check", function()
            return secret
        end)
        markSecret(secret)
        local sync = assert(CommKit:CreateScope():SyncSet(PREFIX, {
            fields = { "level" },
            schema = { level = schema },
        }))
        assert.are.same({ nil, "schema" }, { sync:Set("level", 42) })
        assert.is_nil(sync:Get("level"))
    end)

    it("does not read a secret CLOSES_ADDON_SCOPES entry as a hand-over", function()
        local secret = {}
        local CommKit = TestEnv.Load({ lifecycleKit = { commKit = secret } })
        markSecret(secret)
        local scope = CommKit:ForAddon("MyAddon")
        assert.are.equal("onShutdown", rawget(scope, "_logoutCloser"))
        assert.is_true(CommKit:CloseAddonScopes("MyAddon"))
    end)
end)
