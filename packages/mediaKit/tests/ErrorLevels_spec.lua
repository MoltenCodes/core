local TestEnv = require("MediaKitTestEnv")

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

local TYPE_MESSAGE =
    'type must be one of "background", "border", "font", "icon", "sound", "statusbar", "texture"'

describe("MediaKit error levels", function()
    local MediaKit
    before_each(function()
        MediaKit = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    it("points Register argument errors at the caller", function()
        local cases = {
            {
                function()
                    MediaKit:Register("bar", "Name", "path")
                end,
                "MediaKit:Register " .. TYPE_MESSAGE,
            },
            {
                function()
                    MediaKit:Register("statusbar", "", "path")
                end,
                "MediaKit:Register name must be a non-empty string",
            },
            {
                function()
                    MediaKit:Register("statusbar", "Name", 0)
                end,
                "MediaKit:Register data must be a non-empty file path or a FileDataID (a positive integer)",
            },
            {
                function()
                    MediaKit:Register("statusbar", "Name", "path", 1)
                end,
                "MediaKit:Register options must be a table",
            },
            {
                function()
                    MediaKit:Register("statusbar", "Name", "path", { zzz = 1, aaa = 2 })
                end,
                'MediaKit:Register options contains unknown field "aaa"',
            },
            {
                function()
                    MediaKit:Register("statusbar", "Name", "path", { scripts = { "latin" } })
                end,
                "MediaKit:Register scripts applies to fonts only",
            },
            {
                function()
                    MediaKit:Register("font", "Name", "path", { scripts = {} })
                end,
                "MediaKit:Register scripts must be a non-empty array of script names",
            },
            {
                function()
                    MediaKit:Register("font", "Name", "path", { scripts = { "runic" } })
                end,
                'MediaKit:Register scripts contains unknown script "runic"',
            },
        }
        for _, case in ipairs(cases) do
            local action = case[1]
            local line = debug.getinfo(action, "S").linedefined + 1
            local ok, value = pcall(action)
            assertReportedAt(line, case[2], ok, value)
        end
    end)

    it("points Fetch, Has and List errors at the caller", function()
        local fetchLine
        local fetchOk, fetchValue = pcall(function()
            fetchLine = currentLine() + 1
            MediaKit:Fetch("fonts", "Name")
        end)
        assertReportedAt(fetchLine, "MediaKit:Fetch " .. TYPE_MESSAGE, fetchOk, fetchValue)

        local optionsLine
        local optionsOk, optionsValue = pcall(function()
            optionsLine = currentLine() + 1
            MediaKit:Fetch("font", "Name", { anyScript = "yes" })
        end)
        assertReportedAt(
            optionsLine,
            "MediaKit:Fetch anyScript must be a boolean",
            optionsOk,
            optionsValue
        )

        local unknownLine
        local unknownOk, unknownValue = pcall(function()
            unknownLine = currentLine() + 1
            MediaKit:Has("font", "Name", { other = true })
        end)
        assertReportedAt(
            unknownLine,
            'MediaKit:Has options contains unknown field "other"',
            unknownOk,
            unknownValue
        )

        local nameLine
        local nameOk, nameValue = pcall(function()
            nameLine = currentLine() + 1
            MediaKit:Has("font", {})
        end)
        assertReportedAt(
            nameLine,
            "MediaKit:Has name must be a non-empty string",
            nameOk,
            nameValue
        )

        local listLine
        local listOk, listValue = pcall(function()
            listLine = currentLine() + 1
            MediaKit:List("fonts")
        end)
        assertReportedAt(listLine, "MediaKit:List " .. TYPE_MESSAGE, listOk, listValue)
    end)

    it("points OnRegistered and Defaults errors at the caller", function()
        local callbackLine
        local callbackOk, callbackValue = pcall(function()
            callbackLine = currentLine() + 1
            MediaKit:OnRegistered("sound", nil)
        end)
        assertReportedAt(
            callbackLine,
            "MediaKit:OnRegistered callback must be a function",
            callbackOk,
            callbackValue
        )

        local consumerLine
        local consumerOk, consumerValue = pcall(function()
            consumerLine = currentLine() + 1
            MediaKit:Defaults(nil)
        end)
        assertReportedAt(
            consumerLine,
            "MediaKit:Defaults consumerName must be a non-empty string",
            consumerOk,
            consumerValue
        )

        local defaults = MediaKit:Defaults("MyAddon")
        local setLine
        local setOk, setValue = pcall(function()
            setLine = currentLine() + 1
            defaults:Set("sound", "")
        end)
        assertReportedAt(
            setLine,
            "MediaKit.Defaults:Set name must be a non-empty string",
            setOk,
            setValue
        )

        local getLine
        local getOk, getValue = pcall(function()
            getLine = currentLine() + 1
            defaults:Get("music")
        end)
        assertReportedAt(getLine, "MediaKit.Defaults:Get " .. TYPE_MESSAGE, getOk, getValue)

        local receiverLine
        local receiverOk, receiverValue = pcall(function()
            receiverLine = currentLine() + 1
            defaults.Set({}, "sound", "None")
        end)
        assertReportedAt(
            receiverLine,
            "MediaKit.Defaults:Set must be called on a defaults object; use defaults:Set(...)",
            receiverOk,
            receiverValue
        )
    end)

    it("points secret-value refusals at the caller", function()
        TestEnv.InstallSecretProbe("Secret")
        local line
        local ok, value = pcall(function()
            line = currentLine() + 1
            MediaKit:Register("sound", "Secret", 1)
        end)
        assertReportedAt(line, "MediaKit:Register name must not be a secret value", ok, value)
    end)
end)
