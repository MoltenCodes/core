local Env = require("ClientKitTestEnv")

---Install one client global, as a spec that changes the host between loads does.
---@param name string
---@param value any
local function setGlobal(name, value)
    -- The spec stands in for a client whose API only exists in the global table.
    -- selene: allow(global_usage)
    rawset(_G, name, value)
end

describe("ClientKit bootstrap", function()
    after_each(function()
        Env.Reset()
    end)

    it("publishes the facade through Registry", function()
        local ClientKit, Registry = Env.NewPackageFor("mainline")
        assert.are.equal(ClientKit, Registry:Get("clientKit", 1))
        assert.are.equal(1, ClientKit.API)
        assert.are.equal(2, ClientKit.REVISION)
    end)

    it("reuses the shared facade and state on a duplicate load", function()
        local ClientKit = Env.NewPackageFor("mainline")
        local state = ClientKit._state
        local reloaded = Env.ReloadPackage()

        assert.are.equal(ClientKit, reloaded)
        assert.are.equal(state, reloaded._state)
        assert.are.equal("mainline", reloaded:GetFlavor())
    end)

    it("does not downgrade a newer compatible embedded revision", function()
        local ClientKit, Registry = Env.NewPackageFor("mainline")
        local shared = Registry:Register("clientKit", 1, 99)
        assert.are.equal(ClientKit, shared)
        rawset(shared, "REVISION", 99)

        local reloaded = Env.ReloadPackage()
        assert.are.equal(shared, reloaded)
        assert.are.equal(99, reloaded.REVISION)
    end)

    it("upgrades in place and re-reads the host", function()
        local ClientKit = Env.NewPackageFor("mists")
        local state = ClientKit._state
        local capabilities = state.capabilities
        local host = state.host
        local GetFlavor = ClientKit.GetFlavor
        assert.is_false(ClientKit:Has("secretValues"))

        -- The host gained a facility between the two copies loading, as it
        -- would when a newer embedded copy loads after a client patch.
        setGlobal("issecretvalue", function()
            return true
        end)

        local nextRevision = ClientKit.REVISION + 1
        local upgraded = Env.LoadSourceAtRevision(nextRevision)

        assert.are.equal(ClientKit, upgraded)
        assert.are.equal(nextRevision, ClientKit.REVISION)
        assert.are.equal(state, ClientKit._state)
        assert.are.equal(capabilities, ClientKit._state.capabilities)
        assert.are.equal(host, ClientKit._state.host)
        assert.are_not.equal(GetFlavor, ClientKit.GetFlavor)

        -- A reference taken before the upgrade reads the re-probed state.
        assert.is_true(ClientKit:Has("secretValues"))
        assert.is_true(ClientKit:IsSecret({}))
        assert.are.equal("mists", GetFlavor(ClientKit))
    end)

    it("keeps the newest copy when an older one loads after an upgrade", function()
        local ClientKit = Env.NewPackageFor("mainline")
        local nextRevision = ClientKit.REVISION + 1
        Env.LoadSourceAtRevision(nextRevision)
        local selected = Env.ReloadPackage()
        assert.are.equal(ClientKit, selected)
        assert.are.equal(nextRevision, selected.REVISION)
    end)

    it("upgrades a revision 1 layout in place and adds the manifest tables", function()
        Env.Reset()
        Env.SetWowProfile("mainline")
        Env.InstallWowApi()
        require("Registry")
        local ClientKit = Env.LoadSourceAtRevision(1)
        local state = ClientKit._state
        local host = state.host
        -- Strip what revision 1 never had: the locale, the manifest cache,
        -- the manifest prototype and the four host functions revision 2 binds.
        rawset(state, "locale", nil)
        rawset(state, "manifests", nil)
        rawset(state, "manifestPrototype", nil)
        for _, name in ipairs({
            "getLocale",
            "getAddOnInfo",
            "getAddOnDependencies",
            "getAddOnOptionalDependencies",
        }) do
            rawset(host, name, nil)
        end

        -- The host gained a locale between the two copies loading.
        setGlobal("GetLocale", function()
            return "deDE"
        end)
        Env.SetAddOnMetadata("MyAddon", "Title-deDE", "Mein Addon")

        local upgraded = Env.LoadSourceAtRevision(2)

        assert.are.equal(ClientKit, upgraded)
        assert.are.equal(2, ClientKit.REVISION)
        assert.are.equal(state, ClientKit._state)
        assert.are.equal(host, ClientKit._state.host)
        assert.is_table(state.manifests)
        assert.is_table(state.manifestPrototype)
        assert.are.equal("deDE", state.locale)
        assert.are.equal("Mein Addon", ClientKit:GetManifest("MyAddon").title)
    end)

    it("keeps cached manifests and their Get across an upgrade", function()
        local ClientKit = Env.NewPackageFor("mainline")
        Env.SetAddOnMetadata("MyAddon", "Title", "My Addon")
        Env.SetAddOnMetadata("MyAddon", "X-Website", "https://example.invalid")
        local manifest = ClientKit:GetManifest("MyAddon")
        local Get = manifest.Get

        local nextRevision = ClientKit.REVISION + 1
        Env.LoadSourceAtRevision(nextRevision)

        -- The same snapshot is handed out, and the method a caller kept from
        -- before the upgrade is the one the newer copy rewrote in place.
        assert.are.equal(manifest, ClientKit:GetManifest("MyAddon"))
        assert.are_not.equal(Get, manifest.Get)
        assert.are.equal("https://example.invalid", manifest:Get("X-Website"))
        assert.are.equal(1, Env.MetadataReads("MyAddon", "X-Website"))
    end)

    it("refuses to load before Registry", function()
        Env.Reset()
        Env.SetWowProfile("mainline")
        Env.InstallWowApi()
        Env.expectErrorContaining(
            "MoltenCodes ClientKit requires Registry API 2 to be loaded first",
            function()
                Env.requireAfterFailedLoad("ClientKit")
            end
        )
    end)

    it("refuses a Registry facade without Bootstrap", function()
        Env.Reset()
        setGlobal(Env.NAMESPACE_KEY, { Registries = { [2] = { API = 2 } } })
        Env.expectErrorContaining(
            "MoltenCodes ClientKit requires a valid Registry API 2 facade",
            function()
                Env.requireAfterFailedLoad("ClientKit")
            end
        )
    end)

    it("rejects same-revision state that lost its capability table", function()
        local ClientKit = Env.NewPackageFor("mainline")
        rawset(ClientKit._state, "capabilities", nil)
        assert.has_error(function()
            Env.ReloadPackage()
        end)
    end)

    it("refuses to upgrade over state that lost its host table", function()
        local ClientKit = Env.NewPackageFor("mainline")
        rawset(ClientKit._state, "host", nil)
        local nextRevision = ClientKit.REVISION + 1
        Env.expectErrorContaining(
            "MoltenCodes ClientKit package state is corrupted or incomplete",
            function()
                Env.LoadSourceAtRevision(nextRevision)
            end
        )
    end)

    it("rejects same-revision state that lost its manifest cache", function()
        local ClientKit = Env.NewPackageFor("mainline")
        rawset(ClientKit._state, "manifests", nil)
        assert.has_error(function()
            Env.ReloadPackage()
        end)
    end)

    it("rejects same-revision state whose locale is neither false nor a string", function()
        local ClientKit = Env.NewPackageFor("mainline")
        rawset(ClientKit._state, "locale", 1)
        assert.has_error(function()
            Env.ReloadPackage()
        end)
    end)

    it("rejects same-revision state with a capability that is not a boolean", function()
        local ClientKit = Env.NewPackageFor("mainline")
        rawset(ClientKit._state.capabilities, "C_Spell", "yes")
        assert.has_error(function()
            Env.ReloadPackage()
        end)
    end)
end)
