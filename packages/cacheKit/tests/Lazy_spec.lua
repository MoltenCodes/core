local TestEnv = require("CacheKitTestEnv")

---Build a resolver that joins the path parts with "/" and counts its calls per
---joined path, so a spec can see exactly which paths were resolved.
---@return fun(...): string resolve
---@return table<string, integer> calls
local function newCountingResolver()
    local calls = {}
    local function resolve(...)
        local path = table.concat({ ... }, "/")
        calls[path] = (calls[path] or 0) + 1
        return path
    end
    return resolve, calls
end

describe("CacheKit lazy tree", function()
    local CacheKit
    before_each(function()
        CacheKit = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    it("resolves a path once and answers repeats from the tree", function()
        local resolve, calls = newCountingResolver()
        local tree = CacheKit:Lazy(resolve)

        assert.are.equal("a/b/c", tree:Get("a", "b", "c"))
        assert.are.equal("a/b/c", tree:Get("a", "b", "c"))
        assert.are.equal("a/b", tree:Get("a", "b"))
        assert.are.equal("a", tree:Get("a"))
        assert.are.equal(1, calls["a/b/c"])
        assert.are.equal(1, calls["a/b"])
        assert.are.equal(1, calls["a"])
        assert.are.equal(3, tree:GetCount())

        local stats = tree:GetStats()
        assert.are.equal(1, stats.hits)
        assert.are.equal(3, stats.misses)
        assert.are.equal(0, stats.evictions)
    end)

    it("passes the path parts to resolve unchanged and keeps numbers and strings apart", function()
        local seen = {}
        local tree = CacheKit:Lazy(function(...)
            seen[#seen + 1] = { ... }
            return select("#", ...)
        end)

        assert.are.equal(2, tree:Get(1, "x"))
        assert.are.equal(2, tree:Get("1", "x"))
        assert.are.same({ { 1, "x" }, { "1", "x" } }, seen)
        assert.are.equal(2, tree:GetCount())
    end)

    it("does not keep a nil result and resolves that path again", function()
        local answer = nil
        local calls = 0
        local tree = CacheKit:Lazy(function()
            calls = calls + 1
            return answer
        end)

        assert.is_nil(tree:Get("item", 1))
        assert.is_nil(tree:Get("item", 1))
        assert.are.equal(2, calls)
        assert.are.equal(0, tree:GetCount())
        assert.is_nil(tree:Peek("item", 1))

        answer = false
        assert.is_false(tree:Get("item", 1))
        assert.is_false(tree:Get("item", 1))
        assert.are.equal(3, calls)
        assert.are.equal(1, tree:GetCount())
    end)

    it("peeks without resolving or counting", function()
        local resolve, calls = newCountingResolver()
        local tree = CacheKit:Lazy(resolve)

        assert.is_nil(tree:Peek("a", "b"))
        assert.is_nil(calls["a/b"])
        tree:Get("a", "b")
        assert.are.equal("a/b", tree:Peek("a", "b"))
        -- The ancestor exists as structure but is not expanded.
        assert.is_nil(tree:Peek("a"))
        assert.are.equal(1, tree:GetStats().misses)
        assert.are.equal(0, tree:GetStats().hits)
    end)

    it("invalidates a node with its descendants and the values of its ancestors", function()
        local resolve, calls = newCountingResolver()
        local tree = CacheKit:Lazy(resolve)
        tree:Get("a")
        tree:Get("a", "b")
        tree:Get("a", "b", "c")
        tree:Get("a", "b", "d")
        tree:Get("a", "x")
        assert.are.equal(5, tree:GetCount())

        assert.are.equal(4, tree:Invalidate("a", "b"))
        assert.are.equal(1, tree:GetCount())

        -- The sibling survives with its value; everything else resolves again.
        assert.are.equal("a/x", tree:Peek("a", "x"))
        assert.is_nil(tree:Peek("a"))
        assert.is_nil(tree:Peek("a", "b"))
        assert.is_nil(tree:Peek("a", "b", "c"))
        tree:Get("a")
        tree:Get("a", "b", "c")
        tree:Get("a", "x")
        assert.are.equal(2, calls["a"])
        assert.are.equal(2, calls["a/b/c"])
        assert.are.equal(1, calls["a/x"])
    end)

    it("invalidates the ancestors of a path that was never expanded", function()
        local resolve = newCountingResolver()
        local tree = CacheKit:Lazy(resolve)
        tree:Get("a")
        tree:Get("a", "b")

        assert.are.equal(2, tree:Invalidate("a", "b", "never", "seen"))
        assert.is_nil(tree:Peek("a"))
        assert.is_nil(tree:Peek("a", "b"))
        assert.are.equal(0, tree:GetCount())
        -- Nothing is left in the tree: the root has no children.
        assert.is_false(tree._root.children ~= false and next(tree._root.children) ~= nil)
    end)

    it("returns zero from an invalidation that touches nothing expanded", function()
        local tree = CacheKit:Lazy(newCountingResolver())
        assert.are.equal(0, tree:Invalidate("nothing"))
        tree:Get("a", "b")
        assert.are.equal(0, tree:Invalidate("z"))
        assert.are.equal(1, tree:GetCount())
    end)

    it("clears every expanded node and keeps the statistics", function()
        local tree = CacheKit:Lazy(newCountingResolver())
        tree:Get("a", "b")
        tree:Get("c")
        tree:Get("c")

        assert.are.equal(2, tree:Clear())
        assert.are.equal(0, tree:GetCount())
        assert.is_nil(tree:Peek("c"))
        assert.are.equal(1, tree:GetStats().hits)
        assert.are.equal(0, tree:Clear())

        assert.are.equal("c", tree:Get("c"))
    end)

    it("is bounded by 128 expanded nodes unless told otherwise", function()
        local tree = CacheKit:Lazy(newCountingResolver())
        for index = 1, 200 do
            tree:Get("item", index)
        end
        assert.are.equal(128, tree:GetCount())
        assert.are.equal(72, tree:GetStats().evictions)

        local small = CacheKit:Lazy(newCountingResolver(), { maxEntries = 2 })
        small:Get("a")
        small:Get("b")
        small:Get("c")
        assert.are.equal(2, small:GetCount())
        assert.is_nil(small:Peek("a"))
    end)

    it("evicts the least recently read expanded node", function()
        local tree = CacheKit:Lazy(newCountingResolver(), { maxEntries = 3 })
        tree:Get("a")
        tree:Get("b")
        tree:Get("c")
        tree:Get("a")
        tree:Get("d")

        assert.is_nil(tree:Peek("b"))
        assert.are.equal("a", tree:Peek("a"))
        assert.are.equal("c", tree:Peek("c"))
        assert.are.equal("d", tree:Peek("d"))
        assert.are.equal(1, tree:GetStats().evictions)
    end)

    it("keeps an evicted node as structure while a descendant is expanded", function()
        local resolve, calls = newCountingResolver()
        local tree = CacheKit:Lazy(resolve, { maxEntries = 2 })
        tree:Get("a")
        tree:Get("a", "b")
        tree:Get("c")

        -- "a" was the least recently read; its value is gone, its child stays.
        assert.is_nil(tree:Peek("a"))
        assert.are.equal("a/b", tree:Peek("a", "b"))
        assert.are.equal(2, tree:GetCount())

        tree:Get("a")
        assert.are.equal(2, calls["a"])
    end)

    it("holds every expanded node when opened with UNBOUNDED", function()
        local tree = CacheKit:Lazy(newCountingResolver(), { maxEntries = CacheKit.UNBOUNDED })
        for index = 1, 3000 do
            tree:Get("item", index)
        end
        assert.are.equal(3000, tree:GetCount())
        assert.are.equal(0, tree:GetStats().evictions)
    end)

    it("keeps at most 1024 blank nodes on an unbounded tree's free list", function()
        local tree = CacheKit:Lazy(newCountingResolver(), { maxEntries = CacheKit.UNBOUNDED })
        for index = 1, 3000 do
            tree:Get(index)
        end
        assert.are.equal(3000, tree:Clear())
        assert.are.equal(1024, tree._freeCount)
    end)

    it("lets resolve read other paths of the same tree", function()
        local tree
        tree = CacheKit:Lazy(function(...)
            local partCount = select("#", ...)
            if partCount == 1 then
                -- A parent derived from its children.
                return tree:Get(..., "left") + tree:Get(..., "right")
            end
            return #select(partCount, ...)
        end, { maxEntries = 8 })

        assert.are.equal(9, tree:Get("sum"))
        assert.are.equal(3, tree:GetCount())
        assert.are.equal(4, tree:Peek("sum", "left"))

        -- Changing a child invalidates the derived parent.
        assert.are.equal(2, tree:Invalidate("sum", "left"))
        assert.is_nil(tree:Peek("sum"))
        assert.are.equal(5, tree:Peek("sum", "right"))
        assert.are.equal(9, tree:Get("sum"))
    end)

    it("does not keep a value when resolve closed the tree", function()
        local tree
        tree = CacheKit:Lazy(function()
            tree:Close()
            return "late"
        end)
        assert.are.equal("late", tree:Get("a"))
        assert.is_true(tree:IsClosed())
        assert.are.equal(0, tree:GetCount())
    end)

    it("propagates an error from resolve and keeps nothing", function()
        local tree = CacheKit:Lazy(function()
            error("boom", 0)
        end)
        local ok, message = pcall(tree.Get, tree, "a", "b")
        assert.is_false(ok)
        assert.are.equal("boom", message)
        assert.are.equal(0, tree:GetCount())
        assert.is_false(tree._root.children ~= false and next(tree._root.children) ~= nil)
    end)

    it("reads as empty once closed and refuses Get", function()
        local tree = CacheKit:Lazy(newCountingResolver())
        tree:Get("a")

        assert.is_false(tree:IsClosed())
        assert.is_true(tree:Close())
        assert.is_true(tree:IsClosed())
        assert.is_false(tree:Close())

        assert.is_nil(tree:Peek("a"))
        assert.are.equal(0, tree:Invalidate("a"))
        assert.are.equal(0, tree:Clear())
        assert.are.equal(0, tree:GetCount())
        TestEnv.expectErrorContaining(
            "CacheKit.LazyTree:Get cannot expand a closed tree",
            function()
                tree:Get("a")
            end
        )
    end)

    it("validates its constructor arguments", function()
        TestEnv.expectErrorContaining("CacheKit:Lazy resolve must be a function", function()
            CacheKit:Lazy({})
        end)
        TestEnv.expectErrorContaining("CacheKit:Lazy options must be a table", function()
            CacheKit:Lazy(function() end, 5)
        end)
        TestEnv.expectErrorContaining(
            'CacheKit:Lazy options contains unknown field "capacity"',
            function()
                CacheKit:Lazy(function() end, { capacity = 5 })
            end
        )
        TestEnv.expectErrorContaining(
            "CacheKit:Lazy maxEntries must be a positive integer or CacheKit.UNBOUNDED",
            function()
                CacheKit:Lazy(function() end, { maxEntries = 0 })
            end
        )
    end)

    it("validates paths on every path method", function()
        local tree = CacheKit:Lazy(newCountingResolver())
        TestEnv.expectErrorContaining(
            "CacheKit.LazyTree:Get needs at least one path part",
            function()
                tree:Get()
            end
        )
        TestEnv.expectErrorContaining(
            "CacheKit.LazyTree:Peek path part 2 must be a string or a number",
            function()
                tree:Peek("a", {})
            end
        )
        TestEnv.expectErrorContaining(
            "CacheKit.LazyTree:Invalidate path part 1 must be a string or a number",
            function()
                tree:Invalidate(nil, "b")
            end
        )
        TestEnv.expectErrorContaining(
            "CacheKit.LazyTree:Get path part 1 must not be NaN",
            function()
                tree:Get(0 / 0)
            end
        )
        TestEnv.expectErrorContaining(
            "CacheKit.LazyTree:GetCount must be called on a CacheKit lazy tree",
            function()
                tree.GetCount()
            end
        )
    end)

    it(
        "holds the structure invariant under a randomized workload with re-entrant resolvers",
        function()
            local maxEntries = 6
            local seed = 7
            local function nextRandom(limit)
                seed = (seed * 1103515245 + 12345) % 2147483648
                return seed % limit + 1
            end

            -- The resolver sometimes invalidates its own path or clears the whole
            -- tree before answering, so `Get` has to cope with a tree that changed
            -- under it and must still leave the invariant intact.
            local tree
            tree = CacheKit:Lazy(function(...)
                local behaviour = nextRandom(12)
                if behaviour == 1 then
                    tree:Invalidate(...)
                elseif behaviour == 2 then
                    tree:Clear()
                elseif behaviour == 3 then
                    return nil
                elseif behaviour == 4 and select("#", ...) > 1 then
                    tree:Get((...))
                end
                return table.concat({ ... }, "/")
            end, { maxEntries = maxEntries })

            ---Walk the tree and check, for every node, that `parent` and
            ---`childCount` agree with the `children` tables and that a node without
            ---a value has an expanded descendant. Returns the expanded count.
            ---@param node table
            ---@param parent table|false
            ---@return integer expanded
            ---@return boolean hasExpandedDescendant
            local function checkNode(node, parent)
                assert.are.equal(parent, node.parent)
                local expanded = 0
                local children = 0
                local hasExpandedDescendant = false
                if node.children ~= false then
                    for key, child in pairs(node.children) do
                        assert.are.equal(key, child.key)
                        children = children + 1
                        local below, expandedBelow = checkNode(child, node)
                        expanded = expanded + below
                        hasExpandedDescendant = hasExpandedDescendant or expandedBelow
                    end
                end
                assert.are.equal(children, node.childCount)
                if node.hasValue then
                    expanded = expanded + 1
                elseif node ~= tree._root then
                    assert.is_true(
                        hasExpandedDescendant,
                        "structural node without an expanded descendant"
                    )
                end
                return expanded, hasExpandedDescendant or node.hasValue
            end

            for _ = 1, 3000 do
                local first = nextRandom(4)
                local second = nextRandom(4)
                local third = nextRandom(3)
                local action = nextRandom(12)
                if action <= 5 then
                    tree:Get(first, second, third)
                elseif action <= 7 then
                    tree:Get(first, second)
                elseif action == 8 then
                    tree:Get(first)
                elseif action == 9 then
                    tree:Peek(first, second, third)
                elseif action == 10 then
                    tree:Invalidate(first, second)
                elseif action == 11 then
                    tree:Invalidate(first)
                else
                    tree:Clear()
                end

                local expanded = checkNode(tree._root, false)
                assert.are.equal(tree:GetCount(), expanded)
                assert.is_true(expanded <= maxEntries)
                assert.is_true(tree._freeCount <= maxEntries)
                -- The recency list holds exactly the expanded nodes.
                local listed = 0
                local node = tree._newest
                while node ~= false do
                    assert.is_true(node.hasValue)
                    listed = listed + 1
                    node = node.older
                end
                assert.are.equal(expanded, listed)
            end
        end
    )
end)
