local Env = require("PoolKitTestEnv")

---Assert that `callback` fails with `expected` at a line of this spec file.
local function expectErrorAtThisSpec(expected, callback)
    local ok, message = pcall(callback)
    message = tostring(message)
    assert.is_false(ok)
    assert.is_not_nil(string.find(message, expected, 1, true))
    assert.is_not_nil(string.find(message, "packages/poolKit/tests/Children_spec.lua:", 1, true))
end

---A pool whose resets are appended to `log` as `<label>:<object.name>`.
local function newLoggingPool(PoolKit, label, log)
    local pool = PoolKit:New({
        create = function()
            return {}
        end,
        reset = function(object)
            log[#log + 1] = label .. ":" .. tostring(object.name)
        end,
    })
    return pool
end

describe("PoolKit cascading release", function()
    local PoolKit
    before_each(function()
        PoolKit = Env.NewPackage()
    end)
    after_each(Env.Reset)

    it("releases a parent's children first, most recently attached first", function()
        local log = {}
        local frames = newLoggingPool(PoolKit, "frame", log)
        local textures = newLoggingPool(PoolKit, "texture", log)
        local frame = frames:Acquire()
        frame.name = "bar"
        local background, border = textures:Acquire(), textures:Acquire()
        background.name, border.name = "background", "border"

        frames:AttachChild(frame, background, textures)
        frames:AttachChild(frame, border, textures)
        frames:Release(frame)

        assert.are.same({ "texture:border", "texture:background", "frame:bar" }, log)
        assert.are.equal(0, textures:GetActiveCount())
        assert.are.equal(2, textures:GetAvailableCount())
    end)

    it("reaches grandchildren", function()
        local log = {}
        local pool = newLoggingPool(PoolKit, "object", log)
        local parent, child, grandchild = pool:Acquire(), pool:Acquire(), pool:Acquire()
        parent.name, child.name, grandchild.name = "parent", "child", "grandchild"

        pool:AttachChild(parent, child, pool)
        pool:AttachChild(child, grandchild, pool)
        pool:Release(parent)

        assert.are.same({ "object:grandchild", "object:child", "object:parent" }, log)
        assert.are.equal(0, pool:GetActiveCount())
    end)

    it("detaches a child released on its own, so a later owner keeps it", function()
        local log = {}
        local frames = newLoggingPool(PoolKit, "frame", log)
        local textures = newLoggingPool(PoolKit, "texture", log)
        local frame, texture = frames:Acquire(), textures:Acquire()
        frames:AttachChild(frame, texture, textures)

        textures:Release(texture)
        local reborrowed = textures:Acquire()
        assert.are.equal(texture, reborrowed)
        frames:Release(frame)

        assert.is_true(textures:IsActive(reborrowed))
    end)

    it("detaches explicitly without releasing either object", function()
        local pool = newLoggingPool(PoolKit, "object", {})
        local parent, child = pool:Acquire(), pool:Acquire()
        pool:AttachChild(parent, child, pool)

        assert.is_true(pool:DetachChild(child))
        assert.is_false(pool:DetachChild(child))
        pool:Release(parent)

        assert.is_true(pool:IsActive(child))
    end)

    it("terminates on a cycle of attachments", function()
        local pool = newLoggingPool(PoolKit, "object", {})
        local first, second = pool:Acquire(), pool:Acquire()
        pool:AttachChild(first, second, pool)
        pool:AttachChild(second, first, pool)

        assert.is_true(pool:Release(first))
        assert.are.equal(0, pool:GetActiveCount())
    end)

    it("releases the parent even when a child's reset fails, then re-raises", function()
        local frames = newLoggingPool(PoolKit, "frame", {})
        local failure = { reason = "texture reset failed" }
        local textures = PoolKit:New({
            create = function()
                return {}
            end,
            reset = function()
                error(failure, 0)
            end,
        })
        local frame, texture = frames:Acquire(), textures:Acquire()
        frames:AttachChild(frame, texture, textures)

        local ok, raised = pcall(frames.Release, frames, frame)

        assert.is_false(ok)
        assert.are.equal(failure, raised)
        assert.is_false(frames:IsActive(frame))
        assert.are.equal(1, frames:GetAvailableCount())
        -- A failed reset rolls the child back to borrowed, as a direct release would.
        assert.is_true(textures:IsActive(texture))
    end)

    it("re-raises the first child error even when the parent's reset also fails", function()
        local childFailure = { reason = "child reset failed" }
        local parentFailure = { reason = "parent reset failed" }
        local frames = PoolKit:New({
            create = function()
                return {}
            end,
            reset = function()
                error(parentFailure, 0)
            end,
        })
        local textures = PoolKit:New({
            create = function()
                return {}
            end,
            reset = function()
                error(childFailure, 0)
            end,
        })
        local frame, texture = frames:Acquire(), textures:Acquire()
        frames:AttachChild(frame, texture, textures)

        local ok, raised = pcall(frames.Release, frames, frame)

        assert.is_false(ok)
        assert.are.equal(childFailure, raised)
        -- The parent's failed reset still rolls it back to borrowed.
        assert.is_true(frames:IsActive(frame))
    end)

    it("rejects invalid attachments at the caller's line", function()
        local pool = newLoggingPool(PoolKit, "object", {})
        local other = newLoggingPool(PoolKit, "other", {})
        local parent, child = pool:Acquire(), pool:Acquire()
        local foreign = other:Acquire()

        expectErrorAtThisSpec("childPool must be a PoolKit pool", function()
            pool:AttachChild(parent, child, {})
        end)
        expectErrorAtThisSpec("parent must be borrowed from this pool", function()
            pool:AttachChild(foreign, child, pool)
        end)
        expectErrorAtThisSpec("child must be borrowed from childPool", function()
            pool:AttachChild(parent, foreign, pool)
        end)
        expectErrorAtThisSpec("cannot attach an object to itself", function()
            pool:AttachChild(parent, parent, pool)
        end)

        pool:AttachChild(parent, child, pool)
        local secondParent = pool:Acquire()
        expectErrorAtThisSpec("child is already attached to a parent", function()
            pool:AttachChild(secondParent, child, pool)
        end)
        expectErrorAtThisSpec(
            "PoolKit.Pool:DetachChild child must be a table or userdata",
            function()
                pool:DetachChild(42)
            end
        )
    end)
    it("refuses a child's reset releasing the parent whose release is running", function()
        local frames = newLoggingPool(PoolKit, "frame", {})
        local frame = frames:Acquire()
        local refusal = nil
        local textures = PoolKit:New({
            create = function()
                return {}
            end,
            reset = function()
                local ok, message = pcall(frames.Release, frames, frame)
                assert.is_false(ok)
                refusal = tostring(message)
            end,
        })
        local texture = textures:Acquire()
        frames:AttachChild(frame, texture, textures)

        frames:Release(frame)

        assert.is_not_nil(
            string.find(
                refusal,
                "PoolKit.Pool:Release release is already in progress for this object",
                1,
                true
            )
        )
        assert.is_false(frames:IsActive(frame))
        assert.is_false(textures:IsActive(texture))
    end)
end)
