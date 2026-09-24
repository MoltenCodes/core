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

    it("points GetManifest argument errors at the caller", function()
        local line
        local ok, value = pcall(function()
            line = currentLine() + 1
            ClientKit:GetManifest(nil)
        end)
        assertReportedAt(line, "ClientKit:GetManifest addonName must be a string", ok, value)
    end)

    it("points manifest Get argument and receiver errors at the caller", function()
        Env.RegisterAddOn("MyAddon")
        Env.SetAddOnMetadata("MyAddon", "Title", "My Addon")
        local manifest = ClientKit:GetManifest("MyAddon")

        local fieldLine
        local fieldOk, fieldValue = pcall(function()
            fieldLine = currentLine() + 1
            manifest:Get(1)
        end)
        assertReportedAt(
            fieldLine,
            "ClientKit.Manifest:Get field must be a string",
            fieldOk,
            fieldValue
        )

        local receiverLine
        local receiverOk, receiverValue = pcall(function()
            receiverLine = currentLine() + 1
            manifest.Get({}, "Version")
        end)
        assertReportedAt(
            receiverLine,
            "ClientKit.Manifest:Get must be called on a manifest",
            receiverOk,
            receiverValue
        )
    end)

    it("points secret-value refusals of Has, GetManifest and Get at the caller", function()
        ClientKit = Env.NewPackageFor("mainline", { secretStrings = { "Hidden" } })
        Env.RegisterAddOn("MyAddon")
        Env.SetAddOnMetadata("MyAddon", "Title", "My Addon")
        local manifest = ClientKit:GetManifest("MyAddon")

        local capabilityLine
        local capabilityOk, capabilityValue = pcall(function()
            capabilityLine = currentLine() + 1
            ClientKit:Has("Hidden")
        end)
        assertReportedAt(
            capabilityLine,
            "ClientKit:Has capability must not be a secret value",
            capabilityOk,
            capabilityValue
        )

        local nameLine
        local nameOk, nameValue = pcall(function()
            nameLine = currentLine() + 1
            ClientKit:GetManifest("Hidden")
        end)
        assertReportedAt(
            nameLine,
            "ClientKit:GetManifest addonName must not be a secret value",
            nameOk,
            nameValue
        )

        local fieldLine
        local fieldOk, fieldValue = pcall(function()
            fieldLine = currentLine() + 1
            manifest:Get("Hidden")
        end)
        assertReportedAt(
            fieldLine,
            "ClientKit.Manifest:Get field must not be a secret value",
            fieldOk,
            fieldValue
        )
    end)

    it("refuses a receiver with a secret name as not a manifest, at the caller", function()
        ClientKit = Env.NewPackageFor("mainline", { secretStrings = { "Hidden" } })
        Env.RegisterAddOn("Hidden")
        Env.SetAddOnMetadata("Hidden", "Version", "1.0")
        local manifest = ClientKit:GetManifest("hidden")

        -- The receiver's name is asked of `issecretvalue` before it is tested,
        -- lowered or used as a key, so the refusal is the receiver one.
        local line
        local ok, value = pcall(function()
            line = currentLine() + 1
            manifest.Get({ name = "Hidden" }, "Version")
        end)
        assertReportedAt(line, "ClientKit.Manifest:Get must be called on a manifest", ok, value)
    end)

    it("points a write to a manifest at the line that wrote", function()
        Env.RegisterAddOn("MyAddon")
        Env.SetAddOnMetadata("MyAddon", "Title", "My Addon")
        local manifest = ClientKit:GetManifest("MyAddon")

        local line
        local ok, value = pcall(function()
            line = currentLine() + 1
            manifest.title = "Renamed"
        end)
        assertReportedAt(
            line,
            'ClientKit manifest for "MyAddon" is read-only; field "title" cannot be written',
            ok,
            value
        )
    end)
end)
