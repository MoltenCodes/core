local Env = require("ProfileKitTestEnv")

---Return the report row for `name`, or nil.
---@param ProfileKit table
---@param name string
---@return table?
local function rowFor(ProfileKit, name)
    local rows = ProfileKit:Report()
    for index = 1, #rows do
        if rows[index].name == name then
            return rows[index]
        end
    end
    return nil
end

describe("ProfileKit", function()
    local ProfileKit

    before_each(function()
        ProfileKit = Env.NewPackage()
    end)
    after_each(function()
        Env.Reset()
    end)

    describe("Enable, Disable and IsEnabled", function()
        it("switches state idempotently", function()
            assert.is_true(ProfileKit:Enable())
            assert.is_true(ProfileKit:Enable())
            assert.is_true(ProfileKit:IsEnabled())
            ProfileKit:Disable()
            ProfileKit:Disable()
            assert.is_false(ProfileKit:IsEnabled())
        end)

        it("declines to enable without debugprofilestop and stays disabled", function()
            local withoutClock = Env.NewPackageWithoutProfilingClock()
            local enabled, reason = withoutClock:Enable()
            assert.is_false(enabled)
            assert.are.equal("unavailable", reason)
            assert.is_false(withoutClock:IsEnabled())

            local section = withoutClock:Section("still usable")
            assert.are.equal(0, select("#", section:Begin()))
            assert.are.equal(
                42,
                withoutClock:Measure("still usable", function()
                    return 42
                end)
            )
        end)
    end)

    describe("Section", function()
        it("returns the same section for the same name, enabled or not", function()
            local section = ProfileKit:Section("same")
            ProfileKit:Enable()
            assert.are.equal(section, ProfileKit:Section("same"))
            assert.are_not.equal(section, ProfileKit:Section("other"))
        end)

        it("shares one prototype, so enabling rebinds existing sections", function()
            local first = ProfileKit:Section("first")
            local second = ProfileKit:Section("second")
            local disabledBegin = first.Begin
            ProfileKit:Enable()
            assert.are_not.equal(disabledBegin, first.Begin)
            assert.are.equal(first.Begin, second.Begin)
        end)
    end)

    describe("measuring with the clock stub", function()
        it("records count, total, max and last in milliseconds", function()
            ProfileKit:Enable()
            local section = ProfileKit:Section("work")

            assert.is_true(section:Begin())
            Env.AdvanceProfileMs(2)
            assert.are.equal(2, section:End())

            section:Begin()
            Env.AdvanceProfileMs(3.5)
            section:End()

            local row = rowFor(ProfileKit, "work")
            assert.are.same({ name = "work", count = 2, total = 5.5, max = 3.5, last = 3.5 }, row)
        end)

        it("keeps the spike as max while last follows the latest sample", function()
            ProfileKit:Enable()
            local section = ProfileKit:Section("spiky")
            local samples = { 1, 9, 2 }
            for index = 1, #samples do
                section:Begin()
                Env.AdvanceProfileMs(samples[index])
                section:End()
            end

            local row = rowFor(ProfileKit, "spiky")
            assert.are.equal(3, row.count)
            assert.are.equal(12, row.total)
            assert.are.equal(9, row.max)
            assert.are.equal(2, row.last)
        end)

        it("does not charge wall-clock stalls to a section", function()
            ProfileKit:Enable()
            local section = ProfileKit:Section("cpu")
            section:Begin()
            Env.AdvanceWallMs(100)
            Env.AdvanceProfileMs(1)
            section:End()
            assert.are.equal(1, rowFor(ProfileKit, "cpu").total)
        end)

        it("measures nested different sections inclusively", function()
            ProfileKit:Enable()
            local outer = ProfileKit:Section("outer")
            local inner = ProfileKit:Section("inner")

            outer:Begin()
            Env.AdvanceProfileMs(1)
            inner:Begin()
            Env.AdvanceProfileMs(4)
            inner:End()
            Env.AdvanceProfileMs(2)
            outer:End()

            assert.are.equal(7, rowFor(ProfileKit, "outer").total)
            assert.are.equal(4, rowFor(ProfileKit, "inner").total)
        end)

        it("refuses a nested Begin on the same section with a reason", function()
            ProfileKit:Enable()
            local section = ProfileKit:Section("reentrant")

            assert.is_true(section:Begin())
            Env.AdvanceProfileMs(1)
            local begun, reason = section:Begin()
            assert.is_nil(begun)
            assert.are.equal("active", reason)
            Env.AdvanceProfileMs(1)
            -- The refused Begin did not move the start: the span is both steps.
            assert.are.equal(2, section:End())
            assert.are.equal(1, rowFor(ProfileKit, "reentrant").count)
        end)

        it("refuses an End without a Begin with a reason", function()
            ProfileKit:Enable()
            local elapsed, reason = ProfileKit:Section("idle"):End()
            assert.is_nil(elapsed)
            assert.are.equal("idle", reason)
            assert.are.equal(0, rowFor(ProfileKit, "idle").count)
        end)

        it("drops a sample whose clock went backwards", function()
            ProfileKit:Enable()
            local section = ProfileKit:Section("reset clock")
            Env.SetProfileMs(50)
            section:Begin()
            Env.SetProfileMs(3)
            local elapsed, reason = section:End()
            assert.is_nil(elapsed)
            assert.are.equal("clockReset", reason)
            assert.are.same(
                { name = "reset clock", count = 0, total = 0, max = 0, last = 0 },
                rowFor(ProfileKit, "reset clock")
            )
            -- The section is idle again and measures normally afterwards.
            assert.is_true(section:Begin())
        end)
    end)

    describe("Report", function()
        it("sorts by total descending, then by name, as fresh tables", function()
            ProfileKit:Enable()
            local totals = { alpha = 1, bravo = 5, charlie = 5, delta = 0 }
            for _, name in ipairs({ "delta", "alpha", "charlie", "bravo" }) do
                local section = ProfileKit:Section(name)
                section:Begin()
                Env.AdvanceProfileMs(totals[name])
                section:End()
            end

            local first = ProfileKit:Report()
            local names = {}
            for index = 1, #first do
                names[index] = first[index].name
            end
            assert.are.same({ "bravo", "charlie", "alpha", "delta" }, names)

            local second = ProfileKit:Report()
            assert.are_not.equal(first, second)
            assert.are_not.equal(first[1], second[1])
            assert.are.same(first, second)
        end)

        it("lists sections that were never measured with zero counts", function()
            ProfileKit:Section("unused")
            assert.are.same(
                { { name = "unused", count = 0, total = 0, max = 0, last = 0 } },
                ProfileKit:Report()
            )
        end)
    end)

    describe("Disable then Enable", function()
        it("keeps sections and statistics", function()
            ProfileKit:Enable()
            local section = ProfileKit:Section("kept")
            section:Begin()
            Env.AdvanceProfileMs(4)
            section:End()

            ProfileKit:Disable()
            ProfileKit:Enable()

            assert.are.equal(section, ProfileKit:Section("kept"))
            assert.are.same(
                { name = "kept", count = 1, total = 4, max = 4, last = 4 },
                rowFor(ProfileKit, "kept")
            )
        end)

        it("abandons a measurement that straddles Disable", function()
            ProfileKit:Enable()
            local section = ProfileKit:Section("straddled")
            section:Begin()
            ProfileKit:Disable()
            ProfileKit:Enable()
            Env.AdvanceProfileMs(10)

            local elapsed, reason = section:End()
            assert.is_nil(elapsed)
            assert.are.equal("idle", reason)
            assert.is_true(section:Begin())
        end)
    end)

    describe("Reset", function()
        it("zeroes statistics, keeps sections and abandons open measurements", function()
            ProfileKit:Enable()
            local section = ProfileKit:Section("reset")
            section:Begin()
            Env.AdvanceProfileMs(3)
            section:End()
            section:Begin()

            ProfileKit:Reset()

            assert.are.same(
                { { name = "reset", count = 0, total = 0, max = 0, last = 0 } },
                ProfileKit:Report()
            )
            assert.are.equal(section, ProfileKit:Section("reset"))
            local _, reason = section:End()
            assert.are.equal("idle", reason)
            assert.is_true(ProfileKit:IsEnabled())
        end)
    end)
end)
