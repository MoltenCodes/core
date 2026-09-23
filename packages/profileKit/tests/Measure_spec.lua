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

describe("ProfileKit:Measure", function()
    local ProfileKit

    before_each(function()
        ProfileKit = Env.NewPackage()
        ProfileKit:Enable()
    end)
    after_each(function()
        Env.Reset()
    end)

    it("passes arguments in and every result out, trailing nils included", function()
        local function echo(...)
            return ...
        end

        assert.are.equal(0, select("#", ProfileKit:Measure("echo", echo)))
        assert.are.equal(3, select("#", ProfileKit:Measure("echo", echo, nil, nil, nil)))

        local results = { ProfileKit:Measure("echo", echo, 1, 2, 3, 4, 5, 6, 7) }
        assert.are.same({ 1, 2, 3, 4, 5, 6, 7 }, results)
        assert.are.equal(3, rowFor(ProfileKit, "echo").count)
    end)

    it("records the time fn took", function()
        local value = ProfileKit:Measure("timed", function(milliseconds)
            Env.AdvanceProfileMs(milliseconds)
            return "done"
        end, 6)

        assert.are.equal("done", value)
        assert.are.same(
            { name = "timed", count = 1, total = 6, max = 6, last = 6 },
            rowFor(ProfileKit, "timed")
        )
    end)

    it("re-raises a string error unchanged after recording the span", function()
        local line
        local ok, message = pcall(function()
            ProfileKit:Measure("failing", function()
                Env.AdvanceProfileMs(2)
                line = debug.getinfo(1, "l").currentline + 1
                error("boom")
            end)
        end)

        assert.is_false(ok)
        local source = debug.getinfo(1, "S").short_src
        assert.are.equal(source .. ":" .. line .. ": boom", message)
        assert.are.equal(2, rowFor(ProfileKit, "failing").total)

        -- The section is closed again after the failure.
        assert.is_true(ProfileKit:Section("failing"):Begin())
    end)

    it("re-raises a table error as the same table", function()
        local failure = { code = 7 }
        local ok, value = pcall(ProfileKit.Measure, ProfileKit, "table error", function()
            error(failure)
        end)

        assert.is_false(ok)
        assert.are.equal(failure, value)
        assert.are.equal(1, rowFor(ProfileKit, "table error").count)
    end)

    it("shares the section with ProfileKit:Section", function()
        local section = ProfileKit:Section("shared")
        ProfileKit:Measure("shared", function()
            Env.AdvanceProfileMs(1)
        end)
        section:Begin()
        Env.AdvanceProfileMs(2)
        section:End()

        assert.are.equal(2, rowFor(ProfileKit, "shared").count)
        assert.are.equal(3, rowFor(ProfileKit, "shared").total)
    end)

    it("measures a recursive call of the same name once, at the outermost level", function()
        local function recurse(depth)
            Env.AdvanceProfileMs(1)
            if depth > 1 then
                return ProfileKit:Measure("recursive", recurse, depth - 1)
            end
            return depth
        end

        assert.are.equal(1, ProfileKit:Measure("recursive", recurse, 3))
        assert.are.same(
            { name = "recursive", count = 1, total = 3, max = 3, last = 3 },
            rowFor(ProfileKit, "recursive")
        )
    end)

    it("records nothing when fn disables ProfileKit", function()
        local value = ProfileKit:Measure("switch off", function()
            Env.AdvanceProfileMs(5)
            ProfileKit:Disable()
            return "still returned"
        end)

        assert.are.equal("still returned", value)
        assert.are.equal(0, rowFor(ProfileKit, "switch off").count)
    end)

    it("runs unmeasured while a manual Begin of the same section is open", function()
        local section = ProfileKit:Section("shared")
        section:Begin()
        Env.AdvanceProfileMs(2)
        assert.are.equal(
            "inner",
            ProfileKit:Measure("shared", function()
                Env.AdvanceProfileMs(3)
                return "inner"
            end)
        )
        assert.are.equal(0, rowFor(ProfileKit, "shared").count)
        assert.are.equal(5, section:End())
        assert.are.equal(1, rowFor(ProfileKit, "shared").count)
    end)

    it("records the span once when fn ends the section itself", function()
        local section = ProfileKit:Section("self-ended")
        ProfileKit:Measure("self-ended", function()
            Env.AdvanceProfileMs(4)
            section:End()
            Env.AdvanceProfileMs(1)
        end)
        assert.are.same(
            { name = "self-ended", count = 1, total = 4, max = 4, last = 4 },
            rowFor(ProfileKit, "self-ended")
        )
    end)

    it("passes through unchanged while disabled", function()
        ProfileKit:Disable()
        local failure = { code = 1 }
        local ok, value = pcall(ProfileKit.Measure, ProfileKit, "off", function()
            error(failure)
        end)
        assert.is_false(ok)
        assert.are.equal(failure, value)
        assert.are.same({ 97, 98 }, { ProfileKit:Measure("off", string.byte, "ab", 1, 2) })
        assert.are.equal(0, #ProfileKit:Report())
    end)
end)
