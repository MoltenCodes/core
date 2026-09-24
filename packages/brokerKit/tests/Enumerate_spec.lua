local TestEnv = require("BrokerKitTestEnv")

describe("BrokerKit enumeration", function()
    local BrokerKit
    before_each(function()
        BrokerKit = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    describe("Get", function()
        it("returns the object or nil", function()
            local object = BrokerKit:New("MyAddon")
            assert.are.equal(object, BrokerKit:Get("MyAddon"))
            assert.is_nil(BrokerKit:Get("Missing"))
        end)

        it("refuses an invalid name at the caller", function()
            TestEnv.expectErrorContaining(
                "BrokerKit:Get name must be a non-empty string",
                function()
                    BrokerKit:Get(nil)
                end
            )
        end)
    end)

    describe("Objects", function()
        it("returns the names sorted whatever the creation order", function()
            BrokerKit:New("Zeta")
            BrokerKit:New("alpha")
            BrokerKit:New("Beta")
            BrokerKit:New("Alpha 10")
            BrokerKit:New("Alpha 2")
            assert.are.same({ "Alpha 10", "Alpha 2", "Beta", "Zeta", "alpha" }, BrokerKit:Objects())
        end)

        it("returns a fresh table on every call", function()
            BrokerKit:New("One")
            local first = BrokerKit:Objects()
            first[1] = "Changed"
            assert.are_not.equal(first, BrokerKit:Objects())
            assert.are.same({ "One" }, BrokerKit:Objects())
        end)

        it("is empty before any object exists", function()
            assert.are.same({}, BrokerKit:Objects())
        end)
    end)

    describe("Iterate", function()
        it("visits every object as name, object in sorted order", function()
            local zeta = BrokerKit:New("Zeta")
            local alpha = BrokerKit:New("Alpha")
            local mid = BrokerKit:New("Mid")
            local names, seen = {}, {}
            for name, object in BrokerKit:Iterate() do
                names[#names + 1] = name
                seen[#seen + 1] = object
            end
            assert.are.same({ "Alpha", "Mid", "Zeta" }, names)
            assert.are.same({ alpha, mid, zeta }, seen)
        end)

        it("visits nothing when no object exists", function()
            local count = 0
            for _ in BrokerKit:Iterate() do
                count = count + 1
            end
            assert.are.equal(0, count)
        end)

        it("visits every name present at the start when objects are added mid-walk", function()
            BrokerKit:New("B")
            BrokerKit:New("D")
            BrokerKit:New("F")
            local visited = {}
            for name in BrokerKit:Iterate() do
                visited[#visited + 1] = name
                if name == "B" then
                    -- Sorts before and after the current name; rebuilds the cache.
                    BrokerKit:New("A")
                    BrokerKit:New("C")
                    assert.are.same({ "A", "B", "C", "D", "F" }, BrokerKit:Objects())
                end
            end
            assert.are.same({ "B", "D", "F" }, visited)
        end)

        it("visits every name when an OnObjectAdded listener enumerates mid-walk", function()
            BrokerKit:New("B")
            BrokerKit:New("D")
            local enumerated = {}
            local nested = 0
            BrokerKit:OnObjectAdded(function()
                enumerated = BrokerKit:Objects()
                -- A nested walk over the rebuilt cache.
                for _ in BrokerKit:Iterate() do
                    nested = nested + 1
                end
            end)
            local visited = {}
            for name in BrokerKit:Iterate() do
                visited[#visited + 1] = name
                if name == "B" then
                    BrokerKit:New("C")
                end
            end
            assert.are.same({ "B", "D" }, visited)
            assert.are.same({ "B", "C", "D" }, enumerated)
            assert.are.equal(3, nested)
        end)

        it("orders MoltenCodes and foreign objects together by name", function()
            TestEnv.InstallLibDataBroker({
                objects = { Theirs = { type = "data source" }, Alpha = { type = "launcher" } },
            })
            BrokerKit:New("Mine")
            BrokerKit:New("Zed")
            BrokerKit:AdoptFromLibDataBroker()
            assert.are.same({ "Alpha", "Mine", "Theirs", "Zed" }, BrokerKit:Objects())
            local names, foreign = {}, {}
            for name, object in BrokerKit:Iterate() do
                names[#names + 1] = name
                foreign[#foreign + 1] = BrokerKit:IsForeign(object)
            end
            assert.are.same({ "Alpha", "Mine", "Theirs", "Zed" }, names)
            assert.are.same({ true, false, true, false }, foreign)
        end)

        it("shares one iteration state between calls until an object is added", function()
            BrokerKit:New("One")
            local _, first = BrokerKit:Iterate()
            local _, second = BrokerKit:Iterate()
            assert.are.equal(first, second)
            BrokerKit:New("Two")
            local _, third = BrokerKit:Iterate()
            assert.are_not.equal(first, third)
            assert.are.same({ "One" }, first.names)
            assert.are.same({ "One", "Two" }, third.names)
        end)
    end)

    describe("OnObjectAdded", function()
        it("fires with each new object, after it is stored", function()
            local seen = {}
            BrokerKit:OnObjectAdded(function(object)
                seen[#seen + 1] = object
                assert.are.equal(object, BrokerKit:Get(object.name))
            end)
            local one = BrokerKit:New("One")
            local two = BrokerKit:New("Two")
            assert.are.same({ one, two }, seen)
        end)

        it("returns a SignalKit connection the caller owns", function()
            local count = 0
            local connection = BrokerKit:OnObjectAdded(function()
                count = count + 1
            end)
            BrokerKit:New("One")
            connection:Disconnect()
            BrokerKit:New("Two")
            assert.are.equal(1, count)
        end)

        it("refuses a missing callback at the caller", function()
            TestEnv.expectErrorContaining(
                "BrokerKit:OnObjectAdded callback must be a function",
                function()
                    BrokerKit:OnObjectAdded(nil)
                end
            )
        end)
    end)

    describe("IsForeign", function()
        it("is false for a MoltenCodes object", function()
            assert.is_false(BrokerKit:IsForeign(BrokerKit:New("Mine")))
        end)

        it("refuses anything that is not a broker object", function()
            TestEnv.expectErrorContaining(
                "BrokerKit:IsForeign object must be a broker object",
                function()
                    BrokerKit:IsForeign({})
                end
            )
            TestEnv.expectErrorContaining(
                "BrokerKit:IsForeign object must be a broker object",
                function()
                    BrokerKit:IsForeign(nil)
                end
            )
        end)
    end)

    it("refuses every facade method called without the facade", function()
        local methods = { "Get", "Objects", "Iterate", "OnObjectAdded", "IsForeign" }
        for _, method in ipairs(methods) do
            TestEnv.expectErrorContaining(
                "BrokerKit:"
                    .. method
                    .. " must be called on the BrokerKit facade; use BrokerKit:"
                    .. method
                    .. "(...)",
                function()
                    BrokerKit[method]({})
                end
            )
        end
    end)
end)
