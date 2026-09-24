local Env = require("InteropKitTestEnv")

---Install one global, as a spec that replaces the published namespace does.
---@param name string
---@param value any
local function setGlobal(name, value)
    -- selene: allow(global_usage)
    rawset(_G, name, value)
end

describe("InteropKit bootstrap", function()
    after_each(function()
        Env.Reset()
    end)

    it("publishes the facade through Registry", function()
        local InteropKit, Registry = Env.NewPackage()
        assert.are.equal(InteropKit, Registry:Get("interopKit", 1))
        assert.are.equal(1, InteropKit.API)
        assert.are.equal(2, InteropKit.REVISION)
    end)

    it("reuses the shared facade and state on a duplicate load", function()
        local InteropKit = Env.NewPackage()
        local state = InteropKit._state
        local reloaded = Env.ReloadPackage()

        assert.are.equal(InteropKit, reloaded)
        assert.are.equal(state, reloaded._state)
    end)

    it("does not downgrade a newer compatible embedded revision", function()
        local InteropKit, Registry = Env.NewPackage()
        local shared = Registry:Register("interopKit", 1, 99)
        assert.are.equal(InteropKit, shared)
        rawset(shared, "REVISION", 99)

        local reloaded = Env.ReloadPackage()
        assert.are.equal(shared, reloaded)
        assert.are.equal(99, reloaded.REVISION)
    end)

    it("upgrades in place and keeps its adoptions", function()
        local InteropKit = Env.NewPackage()
        local libStub = Env.InstallLibStub()
        local broker = libStub:NewLibrary("LibDataBroker-1.1", 4)
        assert.are.equal(broker, InteropKit:AdoptFromLibStub("LibDataBroker-1.1"))

        local state = InteropKit._state
        local adopted = state.adopted
        local Find = InteropKit.Find

        local nextRevision = InteropKit.REVISION + 1
        local upgraded = Env.LoadSourceAtRevision(nextRevision)

        assert.are.equal(InteropKit, upgraded)
        assert.are.equal(nextRevision, InteropKit.REVISION)
        assert.are.equal(state, InteropKit._state)
        assert.are.equal(adopted, InteropKit._state.adopted)
        assert.are_not.equal(Find, InteropKit.Find)

        local library, minor = InteropKit:Find("LibDataBroker-1.1")
        assert.are.equal(broker, library)
        assert.are.equal(4, minor)
    end)

    it("keeps the newest copy when an older one loads after an upgrade", function()
        local InteropKit = Env.NewPackage()
        local nextRevision = InteropKit.REVISION + 1
        Env.LoadSourceAtRevision(nextRevision)
        local selected = Env.ReloadPackage()
        assert.are.equal(InteropKit, selected)
        assert.are.equal(nextRevision, selected.REVISION)
    end)

    it("upgrades a revision 1 copy in place with the current file", function()
        Env.Reset()
        Env.InstallWowApi()
        require("Registry")
        local old = Env.LoadSourceAtRevision(1)
        local libStub = Env.InstallLibStub()
        local broker = libStub:NewLibrary("LibDataBroker-1.1", 4)
        assert.are.equal(broker, old:AdoptFromLibStub("LibDataBroker-1.1"))
        local state = old._state

        local upgraded = Env.requireAfterFailedLoad("InteropKit")

        assert.are.equal(old, upgraded)
        assert.is_true(upgraded.REVISION > 1)
        assert.are.equal(state, upgraded._state)
        local library, minor = upgraded:Find("LibDataBroker-1.1")
        assert.are.equal(broker, library)
        assert.are.equal(4, minor)
    end)

    it("refuses to load before Registry", function()
        Env.Reset()
        Env.InstallWowApi()
        Env.expectErrorContaining(
            "MoltenCodes InteropKit requires Registry API 2 to be loaded first",
            function()
                Env.requireAfterFailedLoad("InteropKit")
            end
        )
    end)

    it("refuses a Registry facade without Bootstrap, Find or Packages", function()
        Env.Reset()
        setGlobal(Env.NAMESPACE_KEY, { Registries = { [2] = { API = 2 } } })
        Env.expectErrorContaining(
            "MoltenCodes InteropKit requires a valid Registry API 2 facade",
            function()
                Env.requireAfterFailedLoad("InteropKit")
            end
        )
    end)

    it("rejects same-revision state that lost its adoption table", function()
        local InteropKit = Env.NewPackage()
        rawset(InteropKit._state, "adopted", nil)
        assert.has_error(function()
            Env.ReloadPackage()
        end)
    end)

    it("rejects an upgrade over state with an unknown schema", function()
        local InteropKit = Env.NewPackage()
        rawset(InteropKit._state, "schema", 99)
        Env.expectErrorContaining(
            "MoltenCodes InteropKit package state is corrupted or incomplete",
            function()
                Env.LoadSourceAtRevision(InteropKit.REVISION + 1)
            end
        )
    end)
end)
