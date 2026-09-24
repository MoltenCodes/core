local Env = require("CompatKitTestEnv")

describe("CompatKit shims", function()
    local CompatKit

    before_each(function()
        CompatKit = Env.NewPackage()
    end)
    after_each(Env.Reset)

    ---The record of the shim `name`, or `nil`.
    ---@param name string
    ---@return table?
    local function recordOf(name)
        local rows = CompatKit:GetShims()
        for index = 1, #rows do
            if rows[index].name == name then
                return rows[index]
            end
        end
        return nil
    end

    describe("registration", function()
        it("records a new shim as pending", function()
            assert.are.same({ true, "pending" }, { CompatKit:Shim("fix", 3, function() end) })
            local record = recordOf("fix")
            assert.are.equal(3, record.version)
            assert.is_false(record.applied)
            assert.is_false(record.skipped)
            assert.is_false(record.failed)
            assert.are.equal("pending", record.status)
            assert.is_false(record.description)
            assert.is_false(record.flavours)
            assert.is_false(record.covers)
            assert.is_false(record.missing)
        end)

        it("keeps the newest version before Apply and ignores equal or lower ones", function()
            local ran = {}
            CompatKit:Shim("fix", 1, function()
                ran[#ran + 1] = 1
            end)
            assert.are.same({ true, "replaced" }, {
                CompatKit:Shim("fix", 3, function()
                    ran[#ran + 1] = 3
                end),
            })
            assert.are.same({ false, "ignored" }, {
                CompatKit:Shim("fix", 2, function()
                    ran[#ran + 1] = 2
                end),
            })
            assert.are.same({ false, "ignored" }, {
                CompatKit:Shim("fix", 3, function()
                    ran[#ran + 1] = 33
                end),
            })
            assert.are.equal(3, recordOf("fix").version)
            CompatKit:Apply()
            assert.are.same({ 3 }, ran)
            assert.are.equal(3, recordOf("fix").applied)
        end)

        it("converges on the newest version across two embedded copies", function()
            local ran = {}
            -- The older copy registers its version first.
            CompatKit:Shim("fix", 1, function()
                ran[#ran + 1] = "older copy"
            end, { description = "old" })
            -- A newer copy of the same addon loads over it and registers again.
            local newer = Env.LoadSourceAtRevision(2)
            assert.are.equal(CompatKit, newer)
            assert.are.same({ true, "replaced" }, {
                newer:Shim("fix", 2, function()
                    ran[#ran + 1] = "newer copy"
                end, { description = "new" }),
            })
            -- And a third addon still ships the older version.
            assert.are.same({ false, "ignored" }, {
                newer:Shim("fix", 1, function()
                    ran[#ran + 1] = "third copy"
                end),
            })

            assert.are.same({ 1, 0, 0 }, { newer:Apply() })
            assert.are.same({ "newer copy" }, ran)
            local record = recordOf("fix")
            assert.are.equal(2, record.version)
            assert.are.equal(2, record.applied)
            assert.are.equal("new", record.description)
        end)

        it("records but does not run a higher version registered after Apply", function()
            local ran = {}
            CompatKit:Shim("fix", 1, function()
                ran[#ran + 1] = 1
            end)
            CompatKit:Apply()
            assert.are.same({ true, "recorded" }, {
                CompatKit:Shim("fix", 2, function()
                    ran[#ran + 1] = 2
                end),
            })
            assert.are.same({ 0, 0, 0 }, { CompatKit:Apply() })
            assert.are.same({ 1 }, ran)
            local record = recordOf("fix")
            assert.are.equal(2, record.version)
            assert.are.equal(1, record.applied)
            assert.are.equal("applied", record.status)
        end)

        it("keeps the options of the newest version", function()
            CompatKit:Shim("fix", 1, function() end, { description = "first" })
            CompatKit:Shim("fix", 2, function() end, {
                description = "second",
                flavours = { "mainline", "mists" },
                covers = { "C_TooltipInfo.GetUnit", "GetMouseFoci" },
            })
            local record = recordOf("fix")
            assert.are.equal("second", record.description)
            assert.are.same({ "mainline", "mists" }, record.flavours)
            assert.are.same({ "C_TooltipInfo.GetUnit", "GetMouseFoci" }, record.covers)
        end)
    end)

    describe("SkipShim", function()
        it("is honoured when called before the registration", function()
            local ran = false
            CompatKit:SkipShim("fix")
            CompatKit:Shim("fix", 1, function()
                ran = true
            end)
            assert.is_true(recordOf("fix").skipped)
            assert.are.equal("skipped", recordOf("fix").status)
            assert.are.same({ 0, 1, 0 }, { CompatKit:Apply() })
            assert.is_false(ran)
            assert.is_false(recordOf("fix").applied)
        end)

        it("is honoured when called after the registration", function()
            local ran = false
            CompatKit:Shim("fix", 1, function()
                ran = true
            end)
            CompatKit:SkipShim("fix")
            assert.are.same({ 0, 1, 0 }, { CompatKit:Apply() })
            assert.is_false(ran)
            assert.are.equal("skipped", recordOf("fix").status)
        end)

        it("keeps a skipped shim in the listing and counts it on every Apply", function()
            CompatKit:Shim("fix", 1, function() end)
            CompatKit:SkipShim("fix")
            CompatKit:Apply()
            assert.are.same({ 0, 1, 0 }, { CompatKit:Apply() })
            assert.are.equal(1, #CompatKit:GetShims())
        end)

        it("only marks a shim that already ran", function()
            CompatKit:Shim("fix", 1, function() end)
            CompatKit:Apply()
            CompatKit:SkipShim("fix")
            local record = recordOf("fix")
            assert.is_true(record.skipped)
            assert.are.equal(1, record.applied)
            assert.are.equal("applied", record.status)
        end)

        it(
            "drops the implementation of a skipped shim, however the skip and shim are ordered",
            function()
                local implementation = function() end
                CompatKit:Shim("after", 1, implementation)
                CompatKit:SkipShim("after")
                assert.is_false(CompatKit._state.shims["after"].implementation)

                CompatKit:SkipShim("before")
                CompatKit:Shim("before", 1, implementation)
                assert.is_false(CompatKit._state.shims["before"].implementation)
                assert.are.same(
                    { true, "replaced" },
                    { CompatKit:Shim("before", 2, implementation) }
                )
                assert.is_false(CompatKit._state.shims["before"].implementation)
                assert.are.equal(2, recordOf("before").version)

                assert.are.same({ 0, 2, 0 }, { CompatKit:Apply() })
            end
        )

        it("does not list a skipped name nothing registered", function()
            CompatKit:SkipShim("never")
            assert.are.same({}, CompatKit:GetShims())
        end)
    end)

    describe("GetShims", function()
        it("returns a fresh array of fresh rows sorted by name", function()
            CompatKit:Shim("b", 1, function() end)
            CompatKit:Shim("a", 2, function() end)
            CompatKit:Shim("C", 1, function() end)
            local first = CompatKit:GetShims()
            assert.are.same({ "C", "a", "b" }, { first[1].name, first[2].name, first[3].name })
            first[1].version = 99
            first[4] = "extra"
            local second = CompatKit:GetShims()
            assert.are_not.equal(first, second)
            assert.are.equal(3, #second)
            assert.are.equal(1, second[1].version)
        end)

        it("copies flavours and covers so a caller cannot change them", function()
            CompatKit:Shim("fix", 1, function() end, { flavours = { "mainline" } })
            local row = recordOf("fix")
            row.flavours[1] = "classic"
            assert.are.same({ "mainline" }, recordOf("fix").flavours)
        end)
    end)
end)
