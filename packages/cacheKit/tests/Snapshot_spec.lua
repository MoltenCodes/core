local TestEnv = require("CacheKitTestEnv")

---Sort a copy of `keys` so a spec does not depend on hash iteration order.
---@param keys any[]
---@return any[]
local function sorted(keys)
    local copy = {}
    for index = 1, #keys do
        copy[index] = keys[index]
    end
    table.sort(copy)
    return copy
end

---Build a reader that reports every pair of `source` through `fill`.
---@param source table
---@return fun(fill: fun(key: any, value: any))
local function readerOf(source)
    return function(fill)
        for key, value in pairs(source) do
            fill(key, value)
        end
    end
end

describe("CacheKit snapshot", function()
    local CacheKit
    before_each(function()
        CacheKit = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    it("reports every key as added on the first refresh", function()
        local snapshot = CacheKit:NewSnapshot(readerOf({ a = 1, b = 2 }))
        assert.are.equal(0, snapshot:GetCount())

        local added, removed, changed = snapshot:Refresh()
        assert.are.same({ "a", "b" }, sorted(added))
        assert.are.same({}, removed)
        assert.are.same({}, changed)
        assert.are.equal(2, snapshot:GetCount())
        assert.are.equal(1, snapshot:Get("a"))
    end)

    it("reports added, removed and changed keys between refreshes", function()
        local source = { a = 1, b = 2, c = 3 }
        local snapshot = CacheKit:NewSnapshot(readerOf(source))
        snapshot:Refresh()

        source.a = nil
        source.b = 20
        source.d = 4
        local added, removed, changed = snapshot:Refresh()

        assert.are.same({ "d" }, added)
        assert.are.same({ "a" }, removed)
        assert.are.same({ "b" }, changed)
        assert.are.equal(3, snapshot:GetCount())
        assert.is_nil(snapshot:Get("a"))
        assert.are.equal(20, snapshot:Get("b"))
    end)

    it("reuses the same three arrays and clears what the last refresh left", function()
        local source = { a = 1, b = 2 }
        local snapshot = CacheKit:NewSnapshot(readerOf(source))
        local added = snapshot:Refresh()
        assert.are.equal(2, #added)

        local nextAdded, removed, changed = snapshot:Refresh()
        assert.are.equal(added, nextAdded)
        assert.are.equal(0, #nextAdded)
        assert.are.equal(0, #removed)
        assert.are.equal(0, #changed)
    end)

    it("compares values by identity, so a new table is a change", function()
        local shared = {}
        local source = { same = shared, fresh = {} }
        local snapshot = CacheKit:NewSnapshot(readerOf(source))
        snapshot:Refresh()

        source.fresh = {}
        local _, _, changed = snapshot:Refresh()
        assert.are.same({ "fresh" }, changed)
    end)

    it("iterates the recorded pairs", function()
        local snapshot = CacheKit:NewSnapshot(readerOf({ a = 1, b = 2 }))
        snapshot:Refresh()
        local seen = {}
        for key, value in snapshot:Pairs() do
            seen[key] = value
        end
        assert.are.same({ a = 1, b = 2 }, seen)
    end)

    it("keeps filled values and removes nothing when the reader raises", function()
        local failing = false
        local snapshot = CacheKit:NewSnapshot(function(fill)
            fill("a", failing and 10 or 1)
            if failing then
                error("read failed", 0)
            end
            fill("b", 2)
        end)
        snapshot:Refresh()

        failing = true
        local ok, message = pcall(snapshot.Refresh, snapshot)
        assert.is_false(ok)
        assert.are.equal("read failed", message)
        assert.are.equal(10, snapshot:Get("a"))
        assert.are.equal(2, snapshot:Get("b"))
        assert.are.equal(2, snapshot:GetCount())

        failing = false
        local added, removed, changed = snapshot:Refresh()
        assert.are.same({}, added)
        assert.are.same({}, removed)
        assert.are.same({ "a" }, changed)
    end)

    it("refuses a key filled twice in one refresh", function()
        local snapshot = CacheKit:NewSnapshot(function(fill)
            fill("a", 1)
            fill("a", 2)
        end)
        TestEnv.expectErrorContaining('received key "a" twice in one refresh', function()
            snapshot:Refresh()
        end)
    end)

    it("refuses more keys than maxEntries", function()
        local source = { a = 1, b = 2, c = 3 }
        local snapshot = CacheKit:NewSnapshot(readerOf(source), { maxEntries = 2 })
        TestEnv.expectErrorContaining("fill exceeded maxEntries (2)", function()
            snapshot:Refresh()
        end)

        source.c = nil
        snapshot:Refresh()
        assert.are.equal(2, snapshot:GetCount())
    end)

    it("counts the final key set against maxEntries, not the transition", function()
        local source = { a = 1, b = 2 }
        local snapshot = CacheKit:NewSnapshot(readerOf(source), { maxEntries = 2 })
        snapshot:Refresh()

        source.a, source.b, source.c, source.d = nil, nil, 3, 4
        local added, removed = snapshot:Refresh()
        assert.are.same({ "c", "d" }, sorted(added))
        assert.are.same({ "a", "b" }, sorted(removed))
    end)

    it("refuses fill outside a refresh and refresh inside its own read", function()
        local captured
        local snapshot
        snapshot = CacheKit:NewSnapshot(function(fill)
            captured = fill
            snapshot:Refresh()
        end)
        TestEnv.expectErrorContaining("cannot run inside its own read", function()
            snapshot:Refresh()
        end)
        TestEnv.expectErrorContaining("can only be called while its Refresh is running", function()
            captured("a", 1)
        end)
    end)

    it("refuses nil values and nil keys from the reader", function()
        local snapshot = CacheKit:NewSnapshot(function(fill)
            fill("a", nil)
        end)
        TestEnv.expectErrorContaining("fill value must not be nil", function()
            snapshot:Refresh()
        end)

        local keyless = CacheKit:NewSnapshot(function(fill)
            fill(nil, 1)
        end)
        TestEnv.expectErrorContaining("fill key must not be nil", function()
            keyless:Refresh()
        end)
    end)

    it("drops everything on Close and refuses to refresh afterwards", function()
        local snapshot = CacheKit:NewSnapshot(readerOf({ a = 1 }))
        local added = snapshot:Refresh()

        assert.is_true(snapshot:Close())
        assert.is_false(snapshot:Close())
        assert.is_true(snapshot:IsClosed())
        assert.are.equal(0, #added)
        assert.is_nil(snapshot:Get("a"))
        assert.are.equal(0, snapshot:GetCount())
        for _ in snapshot:Pairs() do
            error("a closed snapshot has nothing to iterate")
        end
        TestEnv.expectErrorContaining("cannot refresh a closed snapshot", function()
            snapshot:Refresh()
        end)
    end)

    it("refuses to close from inside its own read", function()
        local snapshot
        snapshot = CacheKit:NewSnapshot(function()
            snapshot:Close()
        end)
        TestEnv.expectErrorContaining("cannot close a snapshot inside its own read", function()
            snapshot:Refresh()
        end)
        assert.is_false(snapshot:IsClosed())
    end)
end)
