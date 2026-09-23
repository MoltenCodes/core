local Env = require("PoolKitTestEnv")

describe("PoolKit bootstrap", function()
    before_each(function()
        Env.Reset()
    end)
    after_each(function()
        Env.Reset()
    end)

    it("reuses the shared facade and existing pool identity on duplicate load", function()
        local PoolKit = Env.NewPackage()
        local pool = PoolKit:NewTablePool()
        local reloaded = Env.ReloadPackage()
        assert.are.equal(PoolKit, reloaded)
        assert.are.equal(pool:GetMaxRetained(), reloaded.DEFAULT_MAX_RETAINED)
        local object = pool:Acquire()
        pool:Release(object)
        assert.are.equal(1, pool:GetAvailableCount())
    end)

    it("does not downgrade a newer compatible embedded revision", function()
        local PoolKit, Registry = Env.NewPackage()
        local shared = Registry:Register("poolKit", 1, 99)
        assert.are.equal(PoolKit, shared)
        rawset(shared, "REVISION", 99)
        package.loaded["PoolKit"] = nil
        local reloaded = require("PoolKit")
        assert.are.equal(shared, reloaded)
        assert.are.equal(99, reloaded.REVISION)
    end)
    it("upgrades revision-3 state and pools in place, then retires their objects", function()
        local Registry = require("Registry")

        -- What a revision-3 copy left behind: schema-1 state, and a pool with
        -- one retained and one borrowed object but none of revision 4's fields.
        local legacy = Registry:Register("poolKit", 1, 3)
        local prototype = {}
        local metatable = { __index = prototype }
        local unbounded = {}
        rawset(legacy, "API", 1)
        rawset(legacy, "REVISION", 3)
        rawset(legacy, "Pool", prototype)
        rawset(legacy, "UNBOUNDED", unbounded)
        rawset(legacy, "DEFAULT_MAX_RETAINED", 128)
        rawset(legacy, "_state", { schema = 1, poolMetatable = metatable, unbounded = unbounded })

        local destroyed = {}
        local retainedObject, borrowedObject = {}, {}
        local legacyPool = setmetatable({
            _create = function()
                return {}
            end,
            _reset = false,
            _destroy = function(object)
                destroyed[#destroyed + 1] = object
            end,
            _maxRetained = 128,
            _strict = true,
            _available = { retainedObject },
            _availableCount = 1,
            _active = { [borrowedObject] = 1 },
            _activeCount = 1,
            _maxActiveWarning = false,
            _activeWarned = false,
            _retained = { [retainedObject] = true },
            _released = setmetatable({}, { __mode = "k" }),
            _createdCount = 2,
            _discardedCount = 0,
            _closed = false,
            _callbackPhase = false,
            _callbackDepth = 0,
            _trustedCallbacks = false,
        }, metatable)

        local PoolKit = Env.ReloadPackage()

        assert.are.equal(legacy, PoolKit)
        assert.are.equal(6, PoolKit.REVISION)
        assert.are.equal(prototype, PoolKit.Pool)
        assert.are.equal(2, PoolKit._state.schema)

        -- A legacy pool takes the fixed default generation.
        assert.are.equal(1, legacyPool:GetGeneration())
        assert.are.equal(0, legacyPool:GetWaitingCount())

        assert.are.equal(1, legacyPool:SetGeneration(2))
        assert.are.same({ retainedObject }, destroyed)

        legacyPool:Release(borrowedObject)
        assert.are.same({ retainedObject, borrowedObject }, destroyed)

        local fresh = legacyPool:Acquire()
        legacyPool:Release(fresh)
        assert.are.equal(1, legacyPool:GetAvailableCount())
        assert.are.equal(fresh, legacyPool:Acquire())
    end)

    it("upgrades a revision-1 pool, which predates the re-entrancy counter", function()
        local Registry = require("Registry")

        -- What a revision-1 copy left behind: schema-1 state, and a pool with a
        -- boolean-style `_callbackPhase` and no `_callbackDepth`,
        -- `_maxActiveWarning` or `_activeWarned`, which revision 2 added.
        local legacy = Registry:Register("poolKit", 1, 1)
        local prototype = {}
        local metatable = { __index = prototype }
        local unbounded = {}
        rawset(legacy, "API", 1)
        rawset(legacy, "REVISION", 1)
        rawset(legacy, "Pool", prototype)
        rawset(legacy, "UNBOUNDED", unbounded)
        rawset(legacy, "DEFAULT_MAX_RETAINED", 128)
        rawset(legacy, "_state", { schema = 1, poolMetatable = metatable, unbounded = unbounded })

        local legacyPool
        legacyPool = setmetatable({
            _create = function()
                return {}
            end,
            _reset = function()
                legacyPool:Trim()
            end,
            _destroy = false,
            _maxRetained = 128,
            _strict = true,
            _available = {},
            _availableCount = 0,
            _active = {},
            _activeCount = 0,
            _retained = {},
            _released = setmetatable({}, { __mode = "k" }),
            _createdCount = 0,
            _discardedCount = 0,
            _closed = false,
            _callbackPhase = false,
            _trustedCallbacks = false,
        }, metatable)

        local PoolKit = Env.ReloadPackage()
        assert.are.equal(legacy, PoolKit)

        -- The reset re-enters its own pool, so the release is refused by the
        -- guard revision 2 introduced, and rolled back.
        local object = legacyPool:Acquire()
        local ok, message = pcall(legacyPool.Release, legacyPool, object)
        assert.is_false(ok)
        assert.is_not_nil(string.find(tostring(message), "during its reset callback", 1, true))
        assert.is_true(legacyPool:IsActive(object))
        assert.are.equal(0, rawget(legacyPool, "_callbackDepth"))
        assert.is_false(rawget(legacyPool, "_maxActiveWarning"))
        assert.are.equal(1, legacyPool:GetGeneration())
    end)

    it("upgrades revision-5 pools with their queue, children and parking", function()
        require("Registry")
        local previous = Env.LoadRevision(5)
        assert.are.equal(5, previous.REVISION)

        local frames = previous:New({
            create = function()
                return {}
            end,
            maxCreated = 1,
            maxWaiting = 1,
        })
        local textures = previous:NewTablePool()
        local fading = previous:NewTablePool()
        local frame, texture = frames:Acquire(), textures:Acquire()
        frames:AttachChild(frame, texture, textures)
        local served = nil
        assert.are.same({ nil, "waiting" }, {
            frames:Acquire(function(object)
                served = object
            end),
        })
        local group = Env.NewAnimationGroup()
        local parked = fading:Acquire()
        assert.is_true(fading:ReleaseAfter(parked, group))

        local PoolKit = Env.ReloadPackage()
        assert.are.equal(previous, PoolKit)
        assert.are.equal(6, PoolKit.REVISION)

        -- The hook revision 5 installed now runs revision 6's completion.
        group:Finish()
        assert.are.equal(0, fading:GetParkedCount())
        assert.are.equal(1, fading:GetAvailableCount())

        frames:Release(frame)
        assert.is_false(textures:IsActive(texture))
        assert.are.equal(frame, served)
        assert.are.equal(0, frames:GetWaitingCount())
    end)

    it("rejects same-revision UNBOUNDED sentinel drift", function()
        local PoolKit = Env.NewPackage()
        rawset(PoolKit, "UNBOUNDED", {})
        package.loaded["PoolKit"] = nil
        assert.has_error(function()
            require("PoolKit")
        end)
    end)
end)
