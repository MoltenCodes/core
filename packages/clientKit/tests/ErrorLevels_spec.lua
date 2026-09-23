local Env = require("ClientKitTestEnv")

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

describe("ClientKit error levels", function()
    local ClientKit

    before_each(function()
        ClientKit = Env.NewPackageFor("mainline")
    end)
    after_each(function()
        Env.Reset()
    end)

    it("points IsAtLeast argument errors at the caller", function()
        local line
        local ok, value = pcall(function()
            line = currentLine() + 1
            ClientKit:IsAtLeast("120100")
        end)
        assertReportedAt(line, "ClientKit:IsAtLeast interfaceNumber must be a number", ok, value)
    end)

    it("points Has argument and unknown-name errors at the caller", function()
        local typeLine
        local typeOk, typeValue = pcall(function()
            typeLine = currentLine() + 1
            ClientKit:Has(1)
        end)
        assertReportedAt(typeLine, "ClientKit:Has capability must be a string", typeOk, typeValue)

        local nameLine
        local nameOk, nameValue = pcall(function()
            nameLine = currentLine() + 1
            ClientKit:Has("C_Foo")
        end)
        assertReportedAt(
            nameLine,
            'ClientKit:Has does not know capability "C_Foo"',
            nameOk,
            nameValue
        )
    end)

    it("points CanAccessFrame argument errors at the caller", function()
        local line
        local ok, value = pcall(function()
            line = currentLine() + 1
            ClientKit:CanAccessFrame(nil)
        end)
        assertReportedAt(line, "ClientKit:CanAccessFrame frame must be a frame table", ok, value)
    end)

    it("points IsEventValid argument errors at the caller", function()
        local line
        local ok, value = pcall(function()
            line = currentLine() + 1
            ClientKit:IsEventValid(nil)
        end)
        assertReportedAt(line, "ClientKit:IsEventValid eventName must be a string", ok, value)
    end)

    it("points shim argument errors at the caller", function()
        local metadataLine
        local metadataOk, metadataValue = pcall(function()
            metadataLine = currentLine() + 1
            ClientKit:GetAddOnMetadata("MyAddon", nil)
        end)
        assertReportedAt(
            metadataLine,
            "ClientKit:GetAddOnMetadata field must be a string",
            metadataOk,
            metadataValue
        )

        local loadedLine
        local loadedOk, loadedValue = pcall(function()
            loadedLine = currentLine() + 1
            ClientKit:IsAddOnLoaded(nil)
        end)
        assertReportedAt(
            loadedLine,
            "ClientKit:IsAddOnLoaded addon must be an addon name or index",
            loadedOk,
            loadedValue
        )

        local spellLine
        local spellOk, spellValue = pcall(function()
            spellLine = currentLine() + 1
            ClientKit:GetSpellInfo(nil)
        end)
        assertReportedAt(
            spellLine,
            "ClientKit:GetSpellInfo spell must be a spell ID or a spell name",
            spellOk,
            spellValue
        )

        local itemLine
        local itemOk, itemValue = pcall(function()
            itemLine = currentLine() + 1
            ClientKit:GetItemInfo(nil)
        end)
        assertReportedAt(
            itemLine,
            "ClientKit:GetItemInfo item must be an item ID, name or link",
            itemOk,
            itemValue
        )
    end)
end)
