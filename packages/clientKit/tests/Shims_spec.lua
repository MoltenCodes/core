local Env = require("ClientKitTestEnv")

local SPELL_FIELDS = { "name", "iconID", "castTime", "minRange", "maxRange", "spellID" }

---Assert that `info` carries the documented Frostbolt record.
---@param info table?
local function assertFrostbolt(info)
    assert.is_table(info)
    assert.are.equal("Frostbolt", info.name)
    assert.are.equal(135846, info.iconID)
    assert.are.equal(2500, info.castTime)
    assert.are.equal(0, info.minRange)
    assert.are.equal(40, info.maxRange)
    assert.are.equal(116, info.spellID)
end

describe("ClientKit:GetSpellInfo", function()
    after_each(function()
        Env.Reset()
    end)

    for _, profileName in ipairs({ "mainline", "mists", "tbc", "classic" }) do
        it("returns the documented table on the " .. profileName .. " host", function()
            local ClientKit = Env.NewPackageFor(profileName)
            assertFrostbolt(ClientKit:GetSpellInfo(116))
            assertFrostbolt(ClientKit:GetSpellInfo("Frostbolt"))
            assert.is_nil(ClientKit:GetSpellInfo(999999))
            assert.is_nil(ClientKit:GetSpellInfo("Not A Spell"))
        end)
    end

    it("passes the host's table through on a client with C_Spell", function()
        local ClientKit = Env.NewPackageFor("mainline")
        local info = ClientKit:GetSpellInfo(116)
        -- The stubbed host table carries a field the contract does not name.
        assert.are.equal(135846, info.originalIconID)
    end)

    it("builds exactly the documented fields from the legacy returns", function()
        local ClientKit = Env.NewPackageFor("classic")
        local info = ClientKit:GetSpellInfo(116)
        local count = 0
        for _ in pairs(info) do
            count = count + 1
        end
        assert.are.equal(#SPELL_FIELDS, count)
    end)

    it("hands out a fresh table on every call", function()
        local ClientKit = Env.NewPackageFor("classic")
        assert.are_not.equal(ClientKit:GetSpellInfo(116), ClientKit:GetSpellInfo(116))
    end)

    it("returns nil on a host with neither spell call", function()
        local ClientKit = Env.NewPackageFor("noProjectId")
        assert.is_nil(ClientKit:GetSpellInfo(116))
    end)

    it("rejects a spell that is neither an ID nor a name", function()
        local ClientKit = Env.NewPackageFor("mainline")
        Env.expectErrorContaining(
            "ClientKit:GetSpellInfo spell must be a spell ID or a spell name",
            function()
                ClientKit:GetSpellInfo({})
            end
        )
    end)
end)

describe("ClientKit:GetItemInfo", function()
    after_each(function()
        Env.Reset()
    end)

    for _, profileName in ipairs({ "mainline", "mists", "tbc", "classic" }) do
        it("returns the host's item list on the " .. profileName .. " host", function()
            local ClientKit = Env.NewPackageFor(profileName)
            local name, link, quality, _, _, itemType, _, stackCount, _, texture, _, classID =
                ClientKit:GetItemInfo(6948)

            assert.are.equal("Hearthstone", name)
            assert.is_string(link)
            assert.are.equal(1, quality)
            assert.are.equal("Miscellaneous", itemType)
            assert.are.equal(1, stackCount)
            assert.are.equal(134414, texture)
            assert.are.equal(15, classID)
            assert.are.equal("Hearthstone", (ClientKit:GetItemInfo("Hearthstone")))
            assert.is_nil(ClientKit:GetItemInfo(1))
        end)
    end

    it("returns nil on a host with neither item call", function()
        local ClientKit = Env.NewPackageFor("noProjectId")
        assert.is_nil(ClientKit:GetItemInfo(6948))
    end)

    it("rejects an item that is neither an ID nor a name", function()
        local ClientKit = Env.NewPackageFor("mainline")
        Env.expectErrorContaining(
            "ClientKit:GetItemInfo item must be an item ID, name or link",
            function()
                ClientKit:GetItemInfo(true)
            end
        )
    end)
end)

describe("ClientKit:GetAddOnMetadata", function()
    after_each(function()
        Env.Reset()
    end)

    for _, profileName in ipairs({ "mainline", "mists", "tbc", "classic" }) do
        it("reads a .toc field on the " .. profileName .. " host", function()
            local ClientKit = Env.NewPackageFor(profileName)
            Env.SetAddOnMetadata("MyAddon", "Version", "1.2.3")
            Env.SetAddOnMetadata("MyAddon", "X-Website", "")

            assert.are.equal("1.2.3", ClientKit:GetAddOnMetadata("MyAddon", "Version"))
            assert.is_nil(ClientKit:GetAddOnMetadata("MyAddon", "X-Website"))
            assert.is_nil(ClientKit:GetAddOnMetadata("MyAddon", "Title"))
            assert.is_nil(ClientKit:GetAddOnMetadata("OtherAddon", "Version"))
        end)
    end

    it("returns nil on a host with neither metadata call", function()
        local ClientKit = Env.NewPackageFor("noProjectId")
        Env.SetAddOnMetadata("MyAddon", "Version", "1.2.3")
        assert.is_nil(ClientKit:GetAddOnMetadata("MyAddon", "Version"))
    end)

    it("rejects a field that is not a string", function()
        local ClientKit = Env.NewPackageFor("mainline")
        Env.expectErrorContaining("ClientKit:GetAddOnMetadata field must be a string", function()
            ClientKit:GetAddOnMetadata("MyAddon", 1)
        end)
        Env.expectErrorContaining(
            "ClientKit:GetAddOnMetadata addon must be an addon name or index",
            function()
                ClientKit:GetAddOnMetadata(nil, "Version")
            end
        )
    end)
end)

describe("ClientKit:IsAddOnLoaded", function()
    after_each(function()
        Env.Reset()
    end)

    for _, profileName in ipairs({ "mainline", "mists", "tbc", "classic" }) do
        it("answers two booleans on the " .. profileName .. " host", function()
            local ClientKit = Env.NewPackageFor(profileName)

            local loaded, finished = ClientKit:IsAddOnLoaded("MyAddon")
            assert.is_false(loaded)
            assert.is_false(finished)

            Env.MarkAddonLoading("MyAddon")
            loaded, finished = ClientKit:IsAddOnLoaded("MyAddon")
            assert.is_true(loaded)
            assert.is_false(finished)

            Env.MarkAddonLoaded("MyAddon")
            loaded, finished = ClientKit:IsAddOnLoaded("MyAddon")
            assert.is_true(loaded)
            assert.is_true(finished)
        end)
    end

    it("uses the legacy global on a client without C_AddOns", function()
        local ClientKit = Env.NewPackageFor("classic")
        -- The spec reads the client global the classic profile publishes.
        -- selene: allow(global_usage)
        assert.is_nil(rawget(_G, "C_AddOns"))
        Env.MarkAddonLoaded("MyAddon")
        assert.is_true((ClientKit:IsAddOnLoaded("MyAddon")))
    end)

    it("answers false, false on a host with neither call", function()
        Env.Reset()
        require("Registry")
        local ClientKit = require("ClientKit")
        local loaded, finished = ClientKit:IsAddOnLoaded("MyAddon")
        assert.is_false(loaded)
        assert.is_false(finished)
    end)

    it("rejects an addon that is neither a name nor an index", function()
        local ClientKit = Env.NewPackageFor("mainline")
        Env.expectErrorContaining(
            "ClientKit:IsAddOnLoaded addon must be an addon name or index",
            function()
                ClientKit:IsAddOnLoaded({})
            end
        )
    end)
end)
