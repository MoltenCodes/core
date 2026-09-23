local TestEnv = require("CommKitTestEnv")

local PREFIX = "CKSync"
local PEER = "Peer-Realm"

describe("CommKit SyncSet", function()
    local CommKit, CodecKit, scope, sync, changes
    before_each(function()
        local loaded
        CommKit, loaded = TestEnv.Load()
        CodecKit = loaded.CodecKit
        scope = CommKit:CreateScope()
        sync = assert(scope:SyncSet(PREFIX, { fields = { "name", "level", "gear" } }))
        changes = {}
        assert(sync:OnChanged(function(sender, field, value)
            changes[#changes + 1] = { sender, field, value }
        end))
    end)
    after_each(TestEnv.Reset)

    ---Deliver a SyncSet message from `sender` as the client would.
    ---@param message table
    ---@param sender string?
    local function receive(message, sender)
        local ok, text = CodecKit:Encode(message, { channel = "addon" })
        assert.is_true(ok)
        assert.is_true(#text < 254)
        TestEnv.Deliver(PREFIX, "\001" .. text, "WHISPER", sender or PEER)
    end

    ---Run the driver and decode every SyncSet message it sent.
    ---@return table[] messages each `{ target, decoded }`
    local function sent()
        TestEnv.Advance(0)
        local messages = {}
        for index, entry in ipairs(TestEnv.TakeOutbox()) do
            assert.are.equal(PREFIX, entry.prefix)
            assert.are.equal("WHISPER", entry.distribution)
            local ok, decoded = CodecKit:Decode(entry.text:sub(2), { channel = "addon" })
            assert.is_true(ok)
            messages[index] = { entry.target, decoded }
        end
        return messages
    end

    it("hashes the canonical encoding with 32-bit FNV-1a", function()
        assert.are.same({ true, true }, { sync:Set("name", "a") })
        assert.are.equal(3539962124, sync:GetHash("name"))
        sync:Set("level", 1)
        assert.are.equal(2020387990, sync:GetHash("level"))
        sync:Set("gear", true)
        assert.are.equal(101473970, sync:GetHash("gear"))
        sync:Set("gear", { b = 2, a = 1 })
        assert.are.equal(1171038798, sync:GetHash("gear"))
        sync:Set("gear", { a = "y", [1] = "x", [false] = true })
        assert.are.equal(1141967622, sync:GetHash("gear"))
    end)

    it("gives equal tables the same hash whatever their insertion order", function()
        local first = {}
        for index = 1, 40 do
            first["key" .. index] = index
        end
        local second = {}
        for index = 40, 1, -1 do
            second["key" .. index] = index
        end
        sync:Set("gear", first)
        local hash = sync:GetHash("gear")
        assert.are.same({ true, false }, { sync:Set("gear", second) })
        assert.are.equal(hash, sync:GetHash("gear"))
    end)

    it("refuses a value CodecKit cannot serialise or a table key", function()
        local cycle = {}
        cycle.self = cycle
        assert.are.same({ nil, "cycle" }, { sync:Set("gear", cycle) })
        assert.are.same({ nil, "unsupportedType" }, { sync:Set("gear", print) })
        assert.are.same({ nil, "tableKey" }, { sync:Set("gear", { [{}] = 1 }) })
        assert.is_nil(sync:Get("gear"))
    end)

    it("clears a field with nil", function()
        sync:Set("name", "Bob")
        assert.are.equal("Bob", sync:Get("name"))
        assert.are.same({ true, true }, { sync:Set("name", nil) })
        assert.are.same({ true, false }, { sync:Set("name", nil) })
        assert.is_nil(sync:GetHash("name"))
    end)

    it("answers a request with only the fields whose hash differs", function()
        sync:Set("name", "Bob")
        sync:Set("level", 70)
        receive({ 1, {} })
        local first = sent()
        assert.are.equal(1, #first)
        assert.are.equal(PEER, first[1][1])
        assert.are.same({ 3, { name = "Bob", level = 70 }, {} }, first[1][2])

        TestEnv.Advance(2)
        sync:Set("level", 71)
        receive({ 1, { name = sync:GetHash("name"), level = 12345 } })
        assert.are.same({ { PEER, { 3, { level = 71 }, {} } } }, sent())
    end)

    it("answers with an ack when every hash matches", function()
        sync:Set("name", "Bob")
        receive({ 1, { name = sync:GetHash("name") } })
        assert.are.same({ { PEER, { 2 } } }, sent())
    end)

    it("tells the requester about a field it holds and this client cleared", function()
        receive({ 1, { gear = 99 } })
        assert.are.same({ { PEER, { 3, {}, { "gear" } } } }, sent())
    end)

    it("replies to one peer at most once a second", function()
        receive({ 1, {} })
        receive({ 1, {} })
        assert.are.equal(1, #sent())
        TestEnv.Advance(1)
        receive({ 1, {} })
        assert.are.equal(1, #sent())
    end)

    it("stores a delivery, calls OnChanged once per change, and forgets a removal", function()
        receive({ 3, { name = "Ann", level = 60 }, {} })
        assert.are.same({ { PEER, "name", "Ann" }, { PEER, "level", 60 } }, changes)
        assert.are.equal("Ann", sync:GetRemote(PEER, "name"))
        receive({ 3, { name = "Ann" }, {} })
        assert.are.equal(2, #changes)
        receive({ 3, {}, { "name", "unknown", 7 } })
        assert.are.same({ PEER, "name" }, { changes[3][1], changes[3][2] })
        assert.is_nil(changes[3][3])
        assert.is_nil(sync:GetRemote(PEER, "name"))
        assert.are.equal(60, sync:GetRemote(PEER, "level"))
    end)

    it("requests with the hashes it holds for the target", function()
        receive({ 3, { name = "Ann" }, {} })
        assert.is_truthy(sync:Request(PEER))
        local messages = sent()
        assert.are.equal(1, #messages)
        assert.are.equal(1, messages[1][2][1])
        sync:Set("name", "Ann")
        assert.are.equal(sync:GetHash("name"), messages[1][2][2].name)
        assert.is_truthy(sync:Request("Stranger-Realm"))
        assert.are.same({ { "Stranger-Realm", { 1, {} } } }, sent())
    end)

    it("round-trips a delta between two SyncSets through the wire protocol", function()
        local other = assert(CommKit:CreateScope():SyncSet("CKSync2", { fields = { "name" } }))
        local seen = {}
        other:OnChanged(function(sender, field, value)
            seen[#seen + 1] = { sender, field, value }
        end)
        -- Both SyncSets live in one session here, so the request is sent on
        -- the second prefix and answered on the first by rewriting prefixes.
        sync:Set("name", string.rep("long name ", 40))
        assert.is_truthy(other:Request(PEER))
        TestEnv.Advance(0)
        for _, entry in ipairs(TestEnv.TakeOutbox()) do
            TestEnv.Deliver(PREFIX, entry.text, "WHISPER", "Asker-Realm")
        end
        TestEnv.Advance(0)
        local replies = TestEnv.TakeOutbox()
        assert.is_true(#replies > 1)
        for _, entry in ipairs(replies) do
            TestEnv.Deliver("CKSync2", entry.text, "WHISPER", PEER)
        end
        assert.are.same({ { PEER, "name", string.rep("long name ", 40) } }, seen)
    end)

    it("counts malformed SyncSet messages and ignores them", function()
        TestEnv.Deliver(PREFIX, "\001not a frame", "WHISPER", PEER)
        receive({ 9 })
        receive({ 1, "hashes" })
        receive({ 3, "values", {} })
        receive("text")
        assert.are.equal(5, CommKit:GetStatistics().syncRejected)
        assert.are.equal(0, #sent())
        assert.are.equal(0, #changes)
    end)

    it("ignores delivered fields it does not declare", function()
        receive({ 3, { other = 1, name = "Ann" }, {} })
        assert.are.same({ { PEER, "name", "Ann" } }, changes)
    end)

    it("evicts the least recently seen peer past 64", function()
        for index = 1, 65 do
            receive({ 3, { level = index }, {} }, "Peer" .. index)
        end
        assert.is_nil(sync:GetRemote("Peer1", "level"))
        assert.are.equal(2, sync:GetRemote("Peer2", "level"))
        assert.are.equal(65, sync:GetRemote("Peer65", "level"))
    end)

    it("holds at most 16 listeners and closes cleanly", function()
        for _ = 2, 16 do
            assert.is_truthy(sync:OnChanged(function() end))
        end
        assert.are.same({ nil, "full" }, { sync:OnChanged(function() end) })
        assert.are.equal(1, scope:GetRegistrationCount())
        assert.is_true(sync:Close())
        assert.is_false(sync:Close())
        assert.is_true(sync:IsClosed())
        assert.are.equal(0, scope:GetRegistrationCount())
        assert.are.same({ nil, "closed" }, { sync:Set("name", "x") })
        assert.are.same({ nil, "closed" }, { sync:Request(PEER) })
        assert.are.same({ nil, "closed" }, { sync:OnChanged(function() end) })
        receive({ 3, { name = "Ann" }, {} })
        assert.are.equal(0, #changes)
    end)

    it("closes with its scope", function()
        scope:Close()
        assert.is_true(sync:IsClosed())
    end)
end)

describe("CommKit SyncSet with SchemaKit", function()
    local CommKit, CodecKit, SchemaKit, scope
    before_each(function()
        local loaded
        CommKit, loaded = TestEnv.Load({ schemaKit = true })
        CodecKit, SchemaKit = loaded.CodecKit, loaded.SchemaKit
        scope = CommKit:CreateScope()
    end)
    after_each(TestEnv.Reset)

    it("refuses received and local values that fail the field's schema", function()
        local Level = SchemaKit:Seal(SchemaKit.number({ integer = true, min = 1, max = 80 }))
        local sync = assert(scope:SyncSet(PREFIX, {
            fields = { "name", "level" },
            schema = { level = Level },
        }))
        local changes = {}
        sync:OnChanged(function(_, field, value)
            changes[#changes + 1] = { field, value }
        end)
        local ok, text = CodecKit:Encode(
            { 3, { level = 999, name = "Ann" }, {} },
            { channel = "addon" }
        )
        assert.is_true(ok)
        TestEnv.Deliver(PREFIX, "\001" .. text, "WHISPER", PEER)
        assert.are.same({ { "name", "Ann" } }, changes)
        assert.are.equal(1, CommKit:GetStatistics().syncRejected)
        assert.are.same({ nil, "schema" }, { sync:Set("level", 0) })
        assert.are.same({ true, true }, { sync:Set("level", 42) })
    end)

    it("refuses a schema that is not a sealed SchemaKit schema", function()
        assert.has_error(function()
            scope:SyncSet(PREFIX, { fields = { "level" }, schema = { level = {} } })
        end)
        assert.has_error(function()
            scope:SyncSet(PREFIX, {
                fields = { "level" },
                schema = { other = SchemaKit:Seal(SchemaKit.any()) },
            })
        end)
    end)
end)

describe("CommKit SyncSet without its optional packages", function()
    after_each(TestEnv.Reset)

    it("requires CodecKit", function()
        local CommKit = TestEnv.Load({ codecKit = false })
        TestEnv.expectErrorContaining("requires CodecKit API 1, which is not loaded", function()
            CommKit:CreateScope():SyncSet(PREFIX, { fields = { "a" } })
        end)
    end)

    it("requires SchemaKit for a schema", function()
        local CommKit = TestEnv.Load()
        TestEnv.expectErrorContaining("requires SchemaKit API 1, which is not loaded", function()
            CommKit:CreateScope():SyncSet(PREFIX, { fields = { "a" }, schema = { a = {} } })
        end)
    end)
end)
