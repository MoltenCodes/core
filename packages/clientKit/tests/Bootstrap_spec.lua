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
        assert.are.equal(1, ClientKit.REVISION)
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

        local upgraded = Env.LoadSourceAtRevision(2)

        assert.are.equal(ClientKit, upgraded)
        assert.are.equal(2, ClientKit.REVISION)
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
        Env.LoadSourceAtRevision(2)
        local selected = Env.ReloadPackage()
        assert.are.equal(ClientKit, selected)
        assert.are.equal(2, selected.REVISION)
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
        Env.expectErrorContaining(
            "MoltenCodes ClientKit package state is corrupted or incomplete",
            function()
                Env.LoadSourceAtRevision(2)
            end
        )
    end)

    it("rejects same-revision state with a capability that is not a boolean", function()
        local ClientKit = Env.NewPackageFor("mainline")
        rawset(ClientKit._state.capabilities, "C_Spell", "yes")
        assert.has_error(function()
            Env.ReloadPackage()
        end)
    end)
end)
