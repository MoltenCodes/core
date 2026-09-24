local Env = require("CompatKitTestEnv")

local EMBEDDING_PATH = "docs/EMBEDDING.md"
local CATALOGUE_HEADING = "### Catalogue of taint-hostile subsystems"

--- The table of flavours apiKit is generated from; the ids a row may name.
local FLAVOURS_PATH = "tooling/api/flavours.json"

--- The subsystems the roadmap record requires the catalogue to cover, as
--- substrings of the `subsystem` field.
local REQUIRED_SUBSYSTEMS = {
    "UIDropDownMenu",
    "StaticPopup",
    "ActionButton_ShowOverlayGlow",
    "tooltip scanning",
    "GetAddOnMetadata",
    "ShowUIPanel",
    "InterfaceOptionsFrame_OpenToCategory",
    "SetOverrideBindingClick",
    "CompactUnitFrame",
}

describe("CompatKit catalogue", function()
    local CompatKit

    before_each(function()
        CompatKit = Env.NewPackage()
    end)
    after_each(Env.Reset)

    ---Read the flavour ids from `tooling/api/flavours.json`, as a set.
    ---@return table<string, true> ids
    local function apiKitFlavours()
        local ids = {}
        for id in Env.ReadFile(FLAVOURS_PATH):gmatch('"id"%s*:%s*"([^"]+)"') do
            ids[id] = true
        end
        assert.is_true(next(ids) ~= nil, "flavours.json names no flavour")
        return ids
    end

    ---Collect the rows into a plain array.
    ---@return table[] rows
    local function rows()
        local collected = {}
        for index = 1, CompatKit.CATALOGUE_COUNT do
            collected[index] = CompatKit.CATALOGUE[index]
        end
        return collected
    end

    it("publishes at least the nine required rows, each with every field", function()
        assert.is_true(CompatKit.CATALOGUE_COUNT >= 9)
        local all = rows()
        for _, required in ipairs(REQUIRED_SUBSYSTEMS) do
            local found = false
            for _, row in ipairs(all) do
                if row.subsystem:find(required, 1, true) then
                    found = true
                end
            end
            assert.is_true(found, "no catalogue row for " .. required)
        end
        for _, row in ipairs(all) do
            assert.is_string(row.subsystem)
            assert.is_string(row.reason)
            assert.is_string(row.replacement)
            assert.is_true(row.replacementApi == false or type(row.replacementApi) == "string")
            assert.is_table(row.flavours)
            assert.is_number(row.flavourCount)
        end
        assert.is_nil(CompatKit.CATALOGUE[CompatKit.CATALOGUE_COUNT + 1])
    end)

    it("names flavours only for rows that name a documented replacement API", function()
        local known = apiKitFlavours()
        for _, row in ipairs(rows()) do
            if row.replacementApi == false then
                assert.are.equal(0, row.flavourCount, row.subsystem)
            else
                assert.is_truthy(
                    row.replacementApi:match("^[%a_][%w_]*%.?[%a_]*[%w_]*$"),
                    row.replacementApi
                )
                assert.is_true(row.flavourCount >= 1, row.subsystem .. " names no flavour")
            end
            local previous = nil
            for index = 1, row.flavourCount do
                local flavour = row.flavours[index]
                assert.is_true(
                    known[flavour] == true,
                    "unknown apiKit flavour " .. tostring(flavour)
                )
                if previous ~= nil then
                    assert.is_true(previous < flavour, "flavours are sorted")
                end
                previous = flavour
            end
            assert.is_nil(row.flavours[row.flavourCount + 1])
        end
    end)

    it("keeps subsystems distinct", function()
        local seen = {}
        for _, row in ipairs(rows()) do
            assert.is_nil(seen[row.subsystem], "duplicate row " .. row.subsystem)
            seen[row.subsystem] = true
        end
    end)

    it("is read-only down to the flavour lists", function()
        Env.expectErrorContaining("CompatKit.CATALOGUE is read-only", function()
            CompatKit.CATALOGUE[1] = nil
        end)
        Env.expectErrorContaining("CompatKit.CATALOGUE[1] is read-only", function()
            CompatKit.CATALOGUE[1].replacement = "anything"
        end)
        Env.expectErrorContaining("CompatKit.CATALOGUE[1].flavours is read-only", function()
            CompatKit.CATALOGUE[1].flavours[1] = "retail"
        end)
        assert.is_false(getmetatable(CompatKit.CATALOGUE))
    end)

    it("mirrors the table in docs/EMBEDDING.md row for row", function()
        local text = Env.ReadFile(EMBEDDING_PATH)
        local start = text:find(CATALOGUE_HEADING, 1, true)
        assert.is_truthy(start, "EMBEDDING.md has no catalogue section")
        local section = text:sub(start)
        local nextHeading = section:find("\n## ", #CATALOGUE_HEADING + 1, true)
        if nextHeading then
            section = section:sub(1, nextHeading)
        end

        local documented = {}
        for line in section:gmatch("[^\n]+") do
            local first = line:match("^|%s*`?([^|`]-)`?%s*|")
            if first ~= nil and first ~= "Subsystem" and not first:match("^%-+$") then
                documented[#documented + 1] = first
            end
        end

        local all = rows()
        assert.are.equal(#all, #documented, "row counts differ")
        for index, row in ipairs(all) do
            assert.are.equal(row.subsystem, documented[index], "row " .. index)
            if row.replacementApi ~= false then
                assert.is_truthy(
                    section:find(row.replacementApi, 1, true),
                    row.replacementApi .. " is not in the document"
                )
            end
        end
    end)
end)
