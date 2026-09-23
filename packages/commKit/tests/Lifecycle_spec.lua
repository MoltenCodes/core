local TestEnv = require("CommKitTestEnv")

local PREFIX = "CKTest"

describe("CommKit send handles", function()
    local CommKit, scope, outcomes, progress
    before_each(function()
        CommKit = TestEnv.NewPackage()
        scope = CommKit:CreateScope()
        outcomes, progress = {}, {}
    end)
    after_each(TestEnv.Reset)

    ---A request that records progress and completion.
    ---@param text string
    ---@return table
    local function tracked(text)
        return {
            prefix = PREFIX,
            text = text,
            distribution = "PARTY",
            onProgress = function(_, sent, total)
                progress[#progress + 1] = { sent, total }
            end,
            onComplete = function(handle, state, reason)
                outcomes[#outcomes + 1] = { handle, state, reason }
            end,
        }
    end

    it("reports progress per chunk, then completion once", function()
        local handle = assert(scope:Send(tracked(TestEnv.Text(600))))
        assert.are.same({ "queued", 0, 600 }, {
            handle:GetState(),
            handle:GetBytesSent(),
            handle:GetBytesTotal(),
        })
        TestEnv.Advance(0)
        assert.are.same({ { 251, 600 }, { 502, 600 }, { 600, 600 } }, progress)
        assert.are.same({ { handle, "sent" } }, outcomes)
        assert.are.equal(600, handle:GetBytesSent())
        assert.is_false(handle:Cancel())
    end)

    it("cancels a queued message before any chunk leaves", function()
        local handle = assert(scope:Send(tracked("queued")))
        assert.is_true(handle:Cancel())
        assert.is_false(handle:Cancel())
        assert.are.same({ { handle, "cancelled", "cancelled" } }, outcomes)
        TestEnv.Advance(0)
        assert.are.equal(0, #TestEnv.TakeOutbox())
        assert.are.equal("cancelled", handle:GetState())
        assert.are.same({ 0, 0 }, { CommKit:GetQueueDepth() })
        assert.are.equal(0, scope:GetPendingCount())
    end)

    it("cancels a message mid-send and sends nothing more of it", function()
        CommKit:SetLimits({ burst = 400, maxCps = 100 })
        local handle = assert(scope:Send(tracked(TestEnv.Text(600))))
        TestEnv.Advance(0)
        assert.are.equal(1, #TestEnv.TakeOutbox())
        assert.are.same({ "sending", 251 }, { handle:GetState(), handle:GetBytesSent() })
        assert.is_true(handle:Cancel())
        TestEnv.Advance(30)
        assert.are.equal(0, #TestEnv.TakeOutbox())
        assert.are.same({ "cancelled", 251, 600 }, {
            handle:GetState(),
            handle:GetBytesSent(),
            handle:GetBytesTotal(),
        })
    end)

    it("cancels from inside its own progress callback", function()
        local handle
        local request = tracked(TestEnv.Text(600))
        request.onProgress = function(own)
            own:Cancel()
        end
        handle = assert(scope:Send(request))
        TestEnv.Advance(0)
        assert.are.equal(1, #TestEnv.TakeOutbox())
        assert.are.same({ { handle, "cancelled", "cancelled" } }, outcomes)
    end)

    it("isolates a failing completion callback", function()
        TestEnv.TakeReportedErrors()
        scope:Send({
            prefix = PREFIX,
            text = "a",
            distribution = "PARTY",
            onComplete = function()
                error("callback failed", 0)
            end,
        })
        local after = assert(scope:Send(tracked("b")))
        TestEnv.Advance(0)
        assert.are.same({ { value = "callback failed" } }, TestEnv.TakeReportedErrors())
        assert.are.equal("sent", after:GetState())
    end)

    it("cancels only the sends pending when CancelAll began", function()
        local resent = 0
        scope:Send({
            prefix = PREFIX,
            text = "a",
            distribution = "PARTY",
            onComplete = function()
                resent = resent + 1
                scope:Send(tracked("again"))
            end,
        })
        assert.are.equal(1, scope:CancelAll())
        assert.are.equal(1, resent)
        assert.are.equal(1, scope:GetPendingCount())
    end)

    it("cancels every pending send with CancelAll and stays usable", function()
        scope:Send(tracked("a"))
        scope:Send(tracked("b"))
        assert.are.equal(2, scope:CancelAll())
        assert.are.equal(2, #outcomes)
        assert.is_truthy(scope:Send(tracked("c")))
        TestEnv.Advance(0)
        assert.are.equal(1, #TestEnv.TakeOutbox())
    end)
end)

describe("CommKit scopes", function()
    local CommKit
    before_each(function()
        CommKit = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    it("closes mid-send: cancels its sends, drops its registrations, refuses new ones", function()
        CommKit:SetLimits({ burst = 400, maxCps = 100 })
        local scope = CommKit:CreateScope()
        local other = CommKit:CreateScope()
        local reasons = {}
        local handle = scope:Send({
            prefix = PREFIX,
            text = TestEnv.Text(600),
            distribution = "PARTY",
            onComplete = function(_, state, reason)
                reasons[#reasons + 1] = state .. ":" .. reason
            end,
        })
        local survivor = other:Send({ prefix = PREFIX, text = "other", distribution = "PARTY" })
        local connection = scope:Register(PREFIX, function() end)
        TestEnv.Advance(0)
        assert.are.equal("sending", handle:GetState())

        assert.is_true(scope:Close())
        assert.is_false(scope:Close())
        assert.is_true(scope:IsClosed())
        assert.are.same({ "cancelled:closed" }, reasons)
        assert.is_false(connection:IsConnected())
        assert.are.same({ nil, "closed" }, { scope:Register(PREFIX, function() end) })
        assert.are.same(
            { nil, "closed" },
            { scope:Send({ prefix = PREFIX, text = "x", distribution = "PARTY" }) }
        )
        TestEnv.Advance(10)
        assert.are.equal("sent", survivor:GetState())
    end)

    it("closes an addon scope at shutdown, mid-send", function()
        CommKit:SetLimits({ burst = 400, maxCps = 100 })
        local scope = CommKit:ForAddon("MyAddon")
        assert.are.equal(scope, CommKit:ForAddon("MyAddon"))
        assert.are.equal("MyAddon", scope:GetAddonName())
        TestEnv.LoadAddon("MyAddon")
        TestEnv.Login()
        local reasons = {}
        local handle = scope:Send({
            prefix = PREFIX,
            text = TestEnv.Text(600),
            distribution = "PARTY",
            onComplete = function(_, state, reason)
                reasons[#reasons + 1] = state .. ":" .. reason
            end,
        })
        TestEnv.Advance(0)
        assert.are.equal("sending", handle:GetState())
        TestEnv.Logout()
        assert.is_true(scope:IsClosed())
        assert.are.same({ "cancelled:shutdown" }, reasons)
        assert.are.equal(scope, CommKit:ForAddon("MyAddon"))
        assert.is_true(CommKit:ForAddon("MyAddon"):IsClosed())
    end)

    it("returns an addon scope already closed after the addon shut down", function()
        local loaded
        CommKit, loaded = TestEnv.Load()
        loaded.LifecycleKit:ForAddon("Late")
        TestEnv.LoadAddon("Late")
        TestEnv.Logout()
        local scope = CommKit:ForAddon("Late")
        assert.is_true(scope:IsClosed())
        assert.are.same(
            { nil, "closed" },
            { scope:Send({ prefix = PREFIX, text = "x", distribution = "PARTY" }) }
        )
    end)

    it("closes an addon's scope through CloseAddonScopes", function()
        local scope = CommKit:ForAddon("Other")
        assert.is_true(CommKit:CloseAddonScopes("Other"))
        assert.is_false(CommKit:CloseAddonScopes("Other"))
        assert.is_false(CommKit:CloseAddonScopes("Unknown"))
        assert.is_true(scope:IsClosed())
    end)

    it("reports nil for the addon name of a manual scope", function()
        assert.is_nil(CommKit:CreateScope():GetAddonName())
    end)
end)

describe("CommKit registrations", function()
    local CommKit, scope
    before_each(function()
        CommKit = TestEnv.NewPackage()
        scope = CommKit:CreateScope()
    end)
    after_each(TestEnv.Reset)

    ---Whether any fixture frame is registered for `eventName`.
    ---@param eventName string
    ---@return boolean
    local function listening(eventName)
        for _, frame in ipairs(TestEnv.Frames()) do
            if frame.registrations[eventName] ~= nil then
                return true
            end
        end
        return false
    end

    it("registers the prefix with the client once", function()
        assert.is_truthy(scope:Register(PREFIX, function() end))
        assert.is_truthy(scope:Register(PREFIX, function() end))
        assert.is_truthy(CommKit:CreateScope():Register(PREFIX, function() end))
        assert.are.same({ PREFIX }, TestEnv.Chat().registerCalls)
    end)

    it("does not register a prefix the client already holds", function()
        TestEnv.Chat().registered.Taken = true
        assert.is_truthy(scope:Register("Taken", function() end))
        assert.are.same({}, TestEnv.Chat().registerCalls)
    end)

    it("accepts DuplicatePrefix and surfaces every other refusal", function()
        TestEnv.QueueRegisterResult(TestEnv.REGISTER_RESULT.DuplicatePrefix)
        assert.is_truthy(scope:Register("Dup", function() end))
        TestEnv.QueueRegisterResult(TestEnv.REGISTER_RESULT.InvalidPrefix)
        assert.are.same({ nil, "invalidPrefix" }, { scope:Register("Bad", function() end) })
        TestEnv.QueueRegisterResult(TestEnv.REGISTER_RESULT.MaxPrefixes)
        assert.are.same({ nil, "maxPrefixes" }, { scope:Register("Many", function() end) })
        TestEnv.QueueRegisterResult(77)
        assert.are.same({ nil, "unknownResult" }, { scope:Register("Odd", function() end) })
        assert.are.equal(1, scope:GetRegistrationCount())
    end)

    it("holds at most 32 registrations per scope", function()
        local connections = {}
        for index = 1, CommKit.MAX_REGISTRATIONS do
            connections[index] = assert(scope:Register("P" .. index, function() end))
        end
        assert.are.same({ nil, "full" }, { scope:Register("One", function() end) })
        assert.is_true(connections[1]:Disconnect())
        assert.is_truthy(scope:Register("One", function() end))
        assert.are.equal(32, scope:GetRegistrationCount())
    end)

    it("stops delivering to a disconnected registration", function()
        local count = 0
        local connection = scope:Register(PREFIX, function()
            count = count + 1
        end)
        assert.are.equal(PREFIX, connection:GetPrefix())
        TestEnv.Deliver(PREFIX, "\001a", "PARTY", "Friend-Realm")
        assert.is_true(connection:Disconnect())
        assert.is_false(connection:Disconnect())
        assert.is_false(connection:IsConnected())
        TestEnv.Deliver(PREFIX, "\001b", "PARTY", "Friend-Realm")
        assert.are.equal(1, count)
    end)

    it("listens for addon messages only while something is registered", function()
        assert.is_false(listening("CHAT_MSG_ADDON"))
        local first = scope:Register(PREFIX, function() end)
        local second = CommKit:CreateScope():Register("Else", function() end)
        assert.is_true(listening("CHAT_MSG_ADDON"))
        assert.is_true(listening("CHAT_MSG_ADDON_LOGGED"))
        assert.is_true(listening("GROUP_ROSTER_UPDATE"))
        first:Disconnect()
        assert.is_true(listening("CHAT_MSG_ADDON"))
        second:Disconnect()
        assert.is_false(listening("CHAT_MSG_ADDON"))
        assert.is_false(listening("GROUP_ROSTER_UPDATE"))
    end)

    it("disconnects everything with UnregisterAll and stays usable", function()
        scope:Register(PREFIX, function() end)
        scope:Register("Else", function() end)
        assert.are.equal(2, scope:UnregisterAll())
        assert.are.equal(0, scope:GetRegistrationCount())
        assert.is_truthy(scope:Register(PREFIX, function() end))
    end)
end)
