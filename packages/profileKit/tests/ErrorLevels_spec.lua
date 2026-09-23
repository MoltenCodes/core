local Env = require("ProfileKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src

---Return the line number of the statement that called this helper.
---@return integer line
local function currentLine()
    return debug.getinfo(2, "l").currentline
end

---Assert that `action` fails with `message` reported at `expectedLine` of this
---spec file. A wrong `error` level shows up either as a different line number
---or as a message with no `file:line` prefix at all.
---@param expectedLine integer
---@param message string
---@param ok boolean
---@param value any
local function assertReportedAt(expectedLine, message, ok, value)
    assert.is_false(ok)
    assert.are.equal(SOURCE .. ":" .. expectedLine .. ": " .. message, value)
end

describe("ProfileKit error levels", function()
    local ProfileKit

    before_each(function()
        ProfileKit = Env.NewPackage()
    end)
    after_each(function()
        Env.Reset()
    end)

    it("points Section name errors at the caller", function()
        local line
        local ok, value = pcall(function()
            line = currentLine() + 1
            ProfileKit:Section("")
        end)
        assertReportedAt(line, "ProfileKit:Section name must be a non-empty string", ok, value)
    end)

    for _, enabled in ipairs({ false, true }) do
        local mode = enabled and "enabled" or "disabled"

        it("points Measure name errors at the caller while " .. mode, function()
            if enabled then
                ProfileKit:Enable()
            end
            local line
            local ok, value = pcall(function()
                line = currentLine() + 1
                ProfileKit:Measure(7, print)
            end)
            assertReportedAt(line, "ProfileKit:Measure name must be a non-empty string", ok, value)
        end)

        it("points Measure fn errors at the caller while " .. mode, function()
            if enabled then
                ProfileKit:Enable()
            end
            local line
            local ok, value = pcall(function()
                line = currentLine() + 1
                ProfileKit:Measure("name", "not a function")
            end)
            assertReportedAt(line, "ProfileKit:Measure fn must be a function", ok, value)
        end)
    end

    it("points enabled Begin and End receiver errors at the caller", function()
        ProfileKit:Enable()
        local section = ProfileKit:Section("receiver")

        local beginLine
        local beginOk, beginValue = pcall(function()
            beginLine = currentLine() + 1
            section.Begin({})
        end)
        assertReportedAt(
            beginLine,
            "ProfileKit.Section:Begin must be called on a ProfileKit section",
            beginOk,
            beginValue
        )

        local endLine
        local endOk, endValue = pcall(function()
            endLine = currentLine() + 1
            section.End()
        end)
        assertReportedAt(
            endLine,
            "ProfileKit.Section:End must be called on a ProfileKit section",
            endOk,
            endValue
        )
    end)
end)
