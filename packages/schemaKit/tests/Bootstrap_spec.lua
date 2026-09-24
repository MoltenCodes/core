local TestEnv = require("SchemaKitTestEnv")

describe("SchemaKit bootstrap", function()
    after_each(TestEnv.Reset)

    it("returns the same facade on duplicate embedded load", function()
        local SchemaKit = TestEnv.NewPackage()
        local schema = SchemaKit:Seal(SchemaKit.number())

        local reloaded = TestEnv.ReloadPackage()
        assert.are.equal(SchemaKit, reloaded)
        assert.is_true(schema:Check(1))
    end)

    it("publishes through Registry", function()
        local SchemaKit, Registry = TestEnv.NewPackage()
        local registered, revision = Registry:Get("schemaKit", 1)
        assert.are.equal(SchemaKit, registered)
        assert.are.equal(SchemaKit.REVISION, revision)
    end)

    it("does not reinterpret private state owned by a newer compatible revision", function()
        local SchemaKit, Registry = TestEnv.NewPackage()
        local shippedRevision = SchemaKit.REVISION
        local upgraded, previous = Registry:Register("schemaKit", 1, 99)
        assert.are.equal(SchemaKit, upgraded)
        assert.are.equal(shippedRevision, previous)

        rawset(SchemaKit, "REVISION", 99)
        rawset(SchemaKit, "_state", { schema = 999 })
        package.loaded["SchemaKit"] = nil

        local reloaded = require("SchemaKit")
        assert.are.equal(SchemaKit, reloaded)
        assert.are.equal(99, reloaded.REVISION)
    end)

    it("upgrades in place and keeps every node, schema and failure table", function()
        local SchemaKit = TestEnv.NewPackage()
        local prototype = SchemaKit.Schema
        local point = SchemaKit.table({
            fields = { x = SchemaKit.number(), y = SchemaKit.optional(SchemaKit.number(), 0) },
        })
        local schema = SchemaKit:Seal(SchemaKit.array({ of = point, max = 4 }))
        local _, failure = schema:Check({ { x = "a" } })

        local nextRevision = SchemaKit.REVISION + 1
        local upgraded = TestEnv.LoadRevision(nextRevision)
        assert.are.equal(SchemaKit, upgraded)
        assert.are.equal(nextRevision, upgraded.REVISION)
        assert.are.equal(prototype, upgraded.Schema)

        -- A schema sealed by the older copy checks, applies and describes
        -- through the newer one, and keeps its reused failure table.
        assert.is_true(schema:Check({ { x = 1 } }))
        local _, again = schema:Check({ { x = "a" } })
        assert.are.equal(failure, again)
        assert.are.equal("[1].x", again.path)
        local ok, applied = schema:Apply({ { x = 1 } })
        assert.is_true(ok)
        assert.are.same({ { x = 1, y = 0 } }, applied)
        assert.are.equal("array", schema:Describe().kind)

        -- A node built by the older copy composes with the newer builders.
        local line = upgraded:Seal(upgraded.table({ fields = { from = point, to = point } }))
        assert.is_true(line:Check({ from = { x = 1 }, to = { x = 2, y = 3 } }))

        -- Sealed objects stay sealed.
        TestEnv.expectErrorContaining(
            "SchemaKit schemas are sealed and cannot be modified",
            function()
                schema.extra = true
            end
        )
    end)

    ---Load `previousRevision` in place, build a schema on it, then load the
    ---working file over it and prove the schema, its failure table, the
    ---limits and the state survived.
    ---@param previousRevision integer
    local function assertUpgradesFrom(previousRevision)
        local workingRevision = TestEnv.NewPackage().REVISION
        TestEnv.Reset()
        require("Registry")
        local previous = TestEnv.LoadRevision(previousRevision)
        previous:SetLimits({ maxDepth = 20 })
        local schema = previous:Seal(previous.table({ fields = { x = previous.number() } }))
        local _, failure = schema:Check({ x = "a" })
        local state = previous._state

        local current = require("SchemaKit")
        assert.are.equal(previous, current)
        assert.are.equal(workingRevision, current.REVISION)
        assert.are.equal(state, current._state)
        assert.are.equal(20, current:GetLimits().maxDepth)
        assert.is_true(schema:Check({ x = 1 }))
        local _, again = schema:Check({ x = "a" })
        assert.are.equal(failure, again)
    end

    it("upgrades a revision 1 package in place to the working file", function()
        assertUpgradesFrom(1)
    end)

    it("upgrades the previous revision in place to the working file", function()
        assertUpgradesFrom(TestEnv.NewPackage().REVISION - 1)
    end)

    it("requires Registry", function()
        TestEnv.Reset()
        local ok, value = pcall(require, "SchemaKit")
        assert.is_false(ok)
        assert.is_true(tostring(value):find("Registry API 2", 1, true) ~= nil)
    end)

    it("refuses an incomplete facade left by an earlier failed load", function()
        TestEnv.Reset()
        local Registry = require("Registry")
        Registry:Register("schemaKit", 1, 1)

        local ok, value = pcall(TestEnv.requireAfterFailedLoad, "SchemaKit")
        assert.is_false(ok)
        assert.is_true(tostring(value):find("MoltenCodes SchemaKit", 1, true) ~= nil)
    end)
end)
