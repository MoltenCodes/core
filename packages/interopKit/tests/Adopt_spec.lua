local Env = require("InteropKitTestEnv")

describe("InteropKit adoption", function()
    local InteropKit

    before_each(function()
        InteropKit = Env.NewPackage()
    end)
    after_each(function()
        Env.Reset()
    end)

    it("reports that LibStub is absent", function()
        local library, reason = InteropKit:AdoptFromLibStub("LibDataBroker-1.1")
        assert.is_nil(library)
        assert.are.equal("absent", reason)
        assert.are.same({}, InteropKit:Adopted())
    end)

    describe("with LibStub", function()
        local libStub

        before_each(function()
            libStub = Env.InstallLibStub()
        end)

        it("returns the library and its minor", function()
            local broker = libStub:NewLibrary("LibDataBroker-1.1", 4)
            local library, minor = InteropKit:AdoptFromLibStub("LibDataBroker-1.1")
            assert.are.equal(broker, library)
            assert.are.equal(4, minor)
        end)

        it("reads a minor LibStub coerced from a revision string", function()
            local media = libStub:NewLibrary("LibSharedMedia-3.0", "$Revision: 8020001 $")
            local library, minor = InteropKit:AdoptFromLibStub("LibSharedMedia-3.0")
            assert.are.equal(media, library)
            assert.are.equal(8020001, minor)
        end)

        it("reports an unknown major without raising", function()
            local library, reason = InteropKit:AdoptFromLibStub("LibNotLoaded-1.0")
            assert.is_nil(library)
            assert.are.equal("unknown", reason)
            assert.are.same({}, InteropKit:Adopted())
        end)

        it("makes the adopted library readable through Find", function()
            local broker = libStub:NewLibrary("LibDataBroker-1.1", 4)
            InteropKit:AdoptFromLibStub("LibDataBroker-1.1")

            local library, minor = InteropKit:Find("LibDataBroker-1.1")
            assert.are.equal(broker, library)
            assert.are.equal(4, minor)
        end)

        it("answers Find for a major that was never adopted with unknown", function()
            libStub:NewLibrary("LibDataBroker-1.1", 4)
            local library, reason = InteropKit:Find("LibDataBroker-1.1")
            assert.is_nil(library)
            assert.are.equal("unknown", reason)
        end)

        it("keeps answering Find after LibStub is gone", function()
            local broker = libStub:NewLibrary("LibDataBroker-1.1", 4)
            InteropKit:AdoptFromLibStub("LibDataBroker-1.1")
            Env.RemoveLibStub()
            assert.are.equal(broker, InteropKit:Find("LibDataBroker-1.1"))
        end)

        it("refreshes the recorded minor when adopted again", function()
            local broker = libStub:NewLibrary("LibDataBroker-1.1", 4)
            InteropKit:AdoptFromLibStub("LibDataBroker-1.1")
            assert.are.equal(broker, libStub:NewLibrary("LibDataBroker-1.1", 5))

            local _, staleMinor = InteropKit:Find("LibDataBroker-1.1")
            assert.are.equal(4, staleMinor)

            InteropKit:AdoptFromLibStub("LibDataBroker-1.1")
            local library, minor = InteropKit:Find("LibDataBroker-1.1")
            assert.are.equal(broker, library)
            assert.are.equal(5, minor)
            assert.are.equal(1, #InteropKit:Adopted())
        end)

        it("never writes into LibStub or the library", function()
            local broker = libStub:NewLibrary("LibDataBroker-1.1", 4)
            InteropKit:AdoptFromLibStub("LibDataBroker-1.1")

            assert.are.same({}, broker)
            assert.are.equal(4, libStub.minors["LibDataBroker-1.1"])
            local count = 0
            for _ in libStub:IterateLibraries() do
                count = count + 1
            end
            assert.are.equal(1, count)
        end)

        it("lists adopted libraries sorted by major", function()
            libStub:NewLibrary("LibSharedMedia-3.0", 3)
            libStub:NewLibrary("CallbackHandler-1.0", 8)
            libStub:NewLibrary("LibDataBroker-1.1", 4)
            InteropKit:AdoptFromLibStub("LibSharedMedia-3.0")
            InteropKit:AdoptFromLibStub("CallbackHandler-1.0")
            InteropKit:AdoptFromLibStub("LibDataBroker-1.1")

            assert.are.same({
                { major = "CallbackHandler-1.0", minor = 8 },
                { major = "LibDataBroker-1.1", minor = 4 },
                { major = "LibSharedMedia-3.0", minor = 3 },
            }, InteropKit:Adopted())
        end)

        it("returns a fresh listing on every call", function()
            libStub:NewLibrary("LibDataBroker-1.1", 4)
            InteropKit:AdoptFromLibStub("LibDataBroker-1.1")
            local first = InteropKit:Adopted()
            first[1].minor = 99
            assert.are_not.equal(first, InteropKit:Adopted())
            assert.are.equal(4, InteropKit:Adopted()[1].minor)
        end)

        it("answers Find without allocating", function()
            libStub:NewLibrary("LibDataBroker-1.1", 4)
            InteropKit:AdoptFromLibStub("LibDataBroker-1.1")
            InteropKit:Find("LibDataBroker-1.1")

            collectgarbage("collect")
            collectgarbage("stop")
            local before = collectgarbage("count")
            for _ = 1, 1000 do
                InteropKit:Find("LibDataBroker-1.1")
                InteropKit:Find("LibNeverAdopted-1.0")
            end
            local allocated = collectgarbage("count") - before
            collectgarbage("restart")
            assert.are.equal(0, allocated)
        end)

        it("adopts a Kit the bridge exposed", function()
            InteropKit:ExposeToLibStub("interopKit", 1)
            local library, minor = InteropKit:AdoptFromLibStub("MoltenCodes-InteropKit-1")
            assert.are.equal(InteropKit, library)
            assert.are.equal(1, minor)
        end)
    end)
end)
