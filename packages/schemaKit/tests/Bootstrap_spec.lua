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

        local upgraded = TestEnv.LoadRevision(2)
        assert.are.equal(SchemaKit, upgraded)
        assert.are.equal(2, upgraded.REVISION)
        assert.are.equal(prototype, upgraded.Schema)

        -- A schema sealed by revision 1 checks, applies and describes through
        -- revision 2, and keeps its reused failure table.
        assert.is_true(schema:Check({ { x = 1 } }))
        local _, again = schema:Check({ { x = "a" } })
        assert.are.equal(failure, again)
        assert.are.equal("[1].x", again.path)
        local ok, applied = schema:Apply({ { x = 1 } })
        assert.is_true(ok)
        assert.are.same({ { x = 1, y = 0 } }, applied)
        assert.are.equal("array", schema:Describe().kind)

        -- A node built by revision 1 composes with revision 2 builders.
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
