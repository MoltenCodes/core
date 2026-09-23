local Env = require("InteropKitTestEnv")

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

describe("InteropKit error levels", function()
    local InteropKit

    before_each(function()
        InteropKit = Env.NewPackage()
        Env.InstallLibStub()
    end)
    after_each(function()
        Env.Reset()
    end)

    it("points ExposeToLibStub argument errors at the caller", function()
        local cases = {
            { "InteropKit:ExposeToLibStub packageName must be a non-empty string", nil, 1 },
            { "InteropKit:ExposeToLibStub packageName must be a non-empty string", "", 1 },
            { "InteropKit:ExposeToLibStub packageName must match ^[a-z][A-Za-z0-9]*$", "Bad", 1 },
            { "InteropKit:ExposeToLibStub api must be a positive integer", "eventKit", 0 },
            { "InteropKit:ExposeToLibStub api must be a positive integer", "eventKit", 1.5 },
            { "InteropKit:ExposeToLibStub api must be a positive integer", "eventKit", "1" },
        }
        for index = 1, #cases do
            local case = cases[index]
            local line
            local ok, value = pcall(function()
                line = currentLine() + 1
                InteropKit:ExposeToLibStub(case[2], case[3])
            end)
            assertReportedAt(line, case[1], ok, value)
        end

        local majorLine
        local majorOk, majorValue = pcall(function()
            majorLine = currentLine() + 1
            InteropKit:ExposeToLibStub("eventKit", 1, "")
        end)
        assertReportedAt(
            majorLine,
            "InteropKit:ExposeToLibStub major must be a non-empty string",
            majorOk,
            majorValue
        )
    end)

    it("points ExposeAll option errors at the caller", function()
        local optionsLine
        local optionsOk, optionsValue = pcall(function()
            optionsLine = currentLine() + 1
            InteropKit:ExposeAll("all")
        end)
        assertReportedAt(
            optionsLine,
            "InteropKit:ExposeAll options must be a table or nil",
            optionsOk,
            optionsValue
        )

        local exceptLine
        local exceptOk, exceptValue = pcall(function()
            exceptLine = currentLine() + 1
            InteropKit:ExposeAll({ except = "hookKit" })
        end)
        assertReportedAt(
            exceptLine,
            "InteropKit:ExposeAll options.except must be an array of package names",
            exceptOk,
            exceptValue
        )

        local nameLine
        local nameOk, nameValue = pcall(function()
            nameLine = currentLine() + 1
            InteropKit:ExposeAll({ except = { 42 } })
        end)
        assertReportedAt(
            nameLine,
            "InteropKit:ExposeAll packageName must be a non-empty string",
            nameOk,
            nameValue
        )

        local patternLine
        local patternOk, patternValue = pcall(function()
            patternLine = currentLine() + 1
            InteropKit:ExposeAll({ except = { "Hook-Kit" } })
        end)
        assertReportedAt(
            patternLine,
            "InteropKit:ExposeAll packageName must match ^[a-z][A-Za-z0-9]*$",
            patternOk,
            patternValue
        )
    end)

    it("points AdoptFromLibStub and Find argument errors at the caller", function()
        local adoptLine
        local adoptOk, adoptValue = pcall(function()
            adoptLine = currentLine() + 1
            InteropKit:AdoptFromLibStub(nil)
        end)
        assertReportedAt(
            adoptLine,
            "InteropKit:AdoptFromLibStub major must be a non-empty string",
            adoptOk,
            adoptValue
        )

        local findLine
        local findOk, findValue = pcall(function()
            findLine = currentLine() + 1
            InteropKit:Find("")
        end)
        assertReportedAt(
            findLine,
            "InteropKit:Find major must be a non-empty string",
            findOk,
            findValue
        )
    end)

    it("points a secret major at the caller", function()
        local secret = {}
        Env.InstallSecretProbe(function(value)
            return rawequal(value, secret)
        end)

        local line
        local ok, value = pcall(function()
            line = currentLine() + 1
            InteropKit:AdoptFromLibStub(secret)
        end)
        assertReportedAt(
            line,
            "InteropKit:AdoptFromLibStub major must not be a secret value",
            ok,
            value
        )
    end)
end)
