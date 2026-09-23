local Env = require("PoolKitTestEnv")

---Assert that `callback` fails with `expected` at a line of this spec file.
local function expectErrorAtThisSpec(expected, callback)
    local ok, message = pcall(callback)
    message = tostring(message)
    assert.is_false(ok)
    assert.is_not_nil(string.find(message, expected, 1, true))
    assert.is_not_nil(string.find(message, "packages/poolKit/tests/Deferred_spec.lua:", 1, true))
end

describe("PoolKit deferred release", function()
    local PoolKit
    local resets
    local destroyed
    local pool
    before_each(function()
        PoolKit = Env.NewPackage()
        resets, destroyed = 0, 0
        pool = PoolKit:New({
            create = function()
                return {}
            end,
            reset = function()
                resets = resets + 1
            end,
            destroy = function()
                destroyed = destroyed + 1
            end,
        })
    end)
    after_each(Env.Reset)

    it("parks the object until its animation finishes", function()
        local frame = pool:Acquire()
        local fadeOut = Env.NewAnimationGroup()

        assert.is_true(pool:ReleaseAfter(frame, fadeOut))

        assert.are.equal(0, resets)
        assert.is_true(pool:Owns(frame))
        assert.is_false(pool:IsActive(frame))
        assert.are.equal(0, pool:GetActiveCount())
        assert.are.equal(1, pool:GetParkedCount())

        fadeOut:Finish()

        assert.are.equal(1, resets)
        assert.are.equal(0, pool:GetParkedCount())
        assert.are.equal(1, pool:GetAvailableCount())
    end)

    it("hooks an animation group once however often it is reused", function()
        local frame = pool:Acquire()
        local fadeOut = Env.NewAnimationGroup()

        for _ = 1, 3 do
            fadeOut:Play()
            pool:ReleaseAfter(frame, fadeOut)
            fadeOut:Finish()
            frame = pool:Acquire()
        end

        assert.are.equal(1, #fadeOut.hooks)
        assert.are.equal(3, resets)
    end)

    it("releases at once when the animation is not playing", function()
        local frame = pool:Acquire()
        local idle = Env.NewAnimationGroup()
        idle.playing = false

        assert.is_false(pool:ReleaseAfter(frame, idle))

        assert.are.equal(1, resets)
        assert.are.equal(0, pool:GetParkedCount())
        assert.are.equal(0, #idle.hooks)
    end)

    it("completes early through Release, and the later finish changes nothing", function()
        local frame = pool:Acquire()
        local fadeOut = Env.NewAnimationGroup()
        pool:ReleaseAfter(frame, fadeOut)

        assert.is_true(pool:Release(frame))
        assert.are.equal(1, resets)

        local reborrowed = pool:Acquire()
        fadeOut:Finish()

        assert.are.equal(frame, reborrowed)
        assert.is_true(pool:IsActive(reborrowed))
        assert.are.equal(1, resets)
    end)

    it("completes parked releases when the pool closes", function()
        local frame = pool:Acquire()
        pool:ReleaseAfter(frame, Env.NewAnimationGroup())

        pool:Close()

        assert.are.equal(1, resets)
        assert.are.equal(1, destroyed)
        assert.is_false(pool:Owns(frame))
    end)

    it("counts a parked object against the live limit until it is released", function()
        local limited = PoolKit:New({
            create = function()
                return {}
            end,
            maxActive = 1,
            maxWaiting = 1,
        })
        local frame = limited:Acquire()
        local fadeOut = Env.NewAnimationGroup()
        limited:ReleaseAfter(frame, fadeOut)
        local delivered = nil

        assert.are.same({ nil, "waiting" }, {
            limited:Acquire(function(object)
                delivered = object
            end),
        })
        fadeOut:Finish()

        assert.are.equal(frame, delivered)
    end)

    it("releases attached children when the animation finishes, not before", function()
        local textures = PoolKit:NewTablePool()
        local frame, texture = pool:Acquire(), textures:Acquire()
        pool:AttachChild(frame, texture, textures)
        local fadeOut = Env.NewAnimationGroup()

        pool:ReleaseAfter(frame, fadeOut)
        assert.is_true(textures:IsActive(texture))

        fadeOut:Finish()
        assert.is_false(textures:IsActive(texture))
    end)

    it("retires a parked object a newer generation superseded", function()
        local frame = pool:Acquire()
        local fadeOut = Env.NewAnimationGroup()
        pool:ReleaseAfter(frame, fadeOut)

        pool:SetGeneration(pool:GetGeneration() + 1)
        fadeOut:Finish()

        assert.are.equal(1, destroyed)
        assert.are.equal(0, pool:GetAvailableCount())
    end)

    it("reports a failure it cannot raise to anyone", function()
        Env.InstallHostErrorHandler()
        local failing = PoolKit:New({
            create = function()
                return {}
            end,
            reset = function()
                error("reset failed during fade-out")
            end,
        })
        local frame = failing:Acquire()
        local fadeOut = Env.NewAnimationGroup()
        failing:ReleaseAfter(frame, fadeOut)

        fadeOut:Finish()

        local reported = Env.ReportedWarnings()
        assert.are.equal(1, #reported)
        assert.is_not_nil(
            string.find(tostring(reported[1]), "reset failed during fade-out", 1, true)
        )
        assert.is_true(failing:IsActive(frame))
    end)

    it("rejects misuse at the caller's line", function()
        local frame = pool:Acquire()
        local other = pool:Acquire()
        local fadeOut = Env.NewAnimationGroup()

        expectErrorAtThisSpec("animationGroup must be an animation group", function()
            pool:ReleaseAfter(frame, {})
        end)
        expectErrorAtThisSpec("object was not acquired from this pool", function()
            pool:ReleaseAfter({}, fadeOut)
        end)

        pool:ReleaseAfter(frame, fadeOut)
        expectErrorAtThisSpec("release is already pending for this object", function()
            pool:ReleaseAfter(frame, Env.NewAnimationGroup())
        end)
        expectErrorAtThisSpec("animationGroup already has a pending release", function()
            pool:ReleaseAfter(other, fadeOut)
        end)
    end)
end)
