local Env = require("InteropKitTestEnv")

describe("InteropKit:ExposeToLibStub", function()
    local InteropKit, Registry

    before_each(function()
        InteropKit, Registry = Env.NewPackage()
    end)
    after_each(function()
        Env.Reset()
    end)

    describe("without LibStub", function()
        it("reports that LibStub is absent", function()
            assert.is_false(InteropKit:IsLibStubPresent())
            local ok, reason = InteropKit:ExposeToLibStub("interopKit", 1)
            assert.is_false(ok)
            assert.are.equal("absent", reason)
        end)

        it("does not treat a LibStub without its methods as present", function()
            Env.InstallLibStub({ libs = {}, minors = {} })
            assert.is_false(InteropKit:IsLibStubPresent())
            local ok, reason = InteropKit:ExposeToLibStub("interopKit", 1)
            assert.is_false(ok)
            assert.are.equal("absent", reason)
        end)
    end)

    describe("with LibStub", function()
        local libStub

        before_each(function()
            libStub = Env.InstallLibStub()
        end)

        it("reports that LibStub is present", function()
            assert.is_true(InteropKit:IsLibStubPresent())
        end)

        it("exposes the facade under the default major", function()
            local ok, major = InteropKit:ExposeToLibStub("interopKit", 1)
            assert.is_true(ok)
            assert.are.equal("MoltenCodes-InteropKit-1", major)
            assert.are.equal(InteropKit, libStub("MoltenCodes-InteropKit-1"))
            assert.are.equal(InteropKit, libStub:GetLibrary("MoltenCodes-InteropKit-1"))
        end)

        it("derives the minor from the implementation revision", function()
            InteropKit:ExposeToLibStub("interopKit", 1)
            local _, minor = libStub:GetLibrary("MoltenCodes-InteropKit-1")
            assert.are.equal(InteropKit.REVISION, minor)
        end)

        it("lists the exposed facade in LibStub's own iteration", function()
            InteropKit:ExposeToLibStub("interopKit", 1)
            local found = nil
            for major, library in libStub:IterateLibraries() do
                if major == "MoltenCodes-InteropKit-1" then
                    found = library
                end
            end
            assert.are.equal(InteropKit, found)
        end)

        it("exposes under an explicit major", function()
            local ok, major = InteropKit:ExposeToLibStub("interopKit", 1, "MyAddon-Interop-1.0")
            assert.is_true(ok)
            assert.are.equal("MyAddon-Interop-1.0", major)
            assert.are.equal(InteropKit, libStub("MyAddon-Interop-1.0"))
            assert.is_nil(libStub:GetLibrary("MoltenCodes-InteropKit-1", true))
        end)

        it("is idempotent", function()
            assert.is_true(InteropKit:ExposeToLibStub("interopKit", 1))
            local ok, major = InteropKit:ExposeToLibStub("interopKit", 1)
            assert.is_true(ok)
            assert.are.equal("MoltenCodes-InteropKit-1", major)
            assert.are.equal(InteropKit, libStub("MoltenCodes-InteropKit-1"))
            assert.are.equal(1, libStub.minors["MoltenCodes-InteropKit-1"])
        end)

        it("makes LibStub refuse an older or equal copy of the same major", function()
            InteropKit:ExposeToLibStub("interopKit", 1)
            assert.is_nil(libStub:NewLibrary("MoltenCodes-InteropKit-1", 1))
            assert.are.equal(InteropKit, libStub("MoltenCodes-InteropKit-1"))
        end)

        it("re-exposes with a higher minor after an in-place upgrade", function()
            InteropKit:ExposeToLibStub("interopKit", 1)
            Env.LoadSourceAtRevision(2)

            assert.is_true(InteropKit:ExposeToLibStub("interopKit", 1))
            local library, minor = libStub:GetLibrary("MoltenCodes-InteropKit-1")
            assert.are.equal(InteropKit, library)
            assert.are.equal(2, minor)
        end)

        it("refuses a major a foreign library holds, without touching it", function()
            local foreign, _ = libStub:NewLibrary("MoltenCodes-InteropKit-1", 7)
            foreign.marker = true

            local ok, reason = InteropKit:ExposeToLibStub("interopKit", 1)
            assert.is_false(ok)
            assert.are.equal("taken", reason)
            assert.are.equal(foreign, libStub("MoltenCodes-InteropKit-1"))
            assert.are.equal(7, libStub.minors["MoltenCodes-InteropKit-1"])
            assert.is_nil(rawget(InteropKit, "marker"))
        end)

        it("refuses a foreign major even when its minor is lower", function()
            local foreign = libStub:NewLibrary("Shared-Name-1.0", 0)

            local ok, reason = InteropKit:ExposeToLibStub("interopKit", 1, "Shared-Name-1.0")
            assert.is_false(ok)
            assert.are.equal("taken", reason)
            assert.are.equal(foreign, libStub("Shared-Name-1.0"))
            assert.are.equal(0, libStub.minors["Shared-Name-1.0"])
        end)

        it("reports an unknown package with Registry's reason", function()
            local ok, reason, registryReason = InteropKit:ExposeToLibStub("missingKit", 1)
            assert.is_false(ok)
            assert.are.equal("unknown", reason)
            assert.are.equal("absent", registryReason)
            assert.is_nil(libStub:GetLibrary("MoltenCodes-MissingKit-1", true))
        end)

        it("reports an unknown generation with Registry's reason", function()
            local ok, reason, registryReason = InteropKit:ExposeToLibStub("interopKit", 2)
            assert.is_false(ok)
            assert.are.equal("unknown", reason)
            assert.are.equal("generation_mismatch", registryReason)
        end)

        it("exposes Registry itself through its generation", function()
            local ok, major = InteropKit:ExposeToLibStub("registry", 2)
            assert.is_true(ok)
            assert.are.equal("MoltenCodes-Registry-2", major)
            assert.are.equal(Registry, libStub("MoltenCodes-Registry-2"))
            assert.are.equal(Registry.REVISION, libStub.minors["MoltenCodes-Registry-2"])
        end)

        it("reports a Registry generation that is not loaded", function()
            local ok, reason, registryReason = InteropKit:ExposeToLibStub("registry", 9)
            assert.is_false(ok)
            assert.are.equal("unknown", reason)
            assert.are.equal("generation_mismatch", registryReason)
        end)
    end)

    describe("with a LibStub that does not keep libs and minors", function()
        it("refuses as unsupported and writes nothing", function()
            local called = false
            local libStub = Env.InstallLibStub({
                NewLibrary = function()
                    called = true
                    return {}
                end,
                GetLibrary = function()
                    return nil
                end,
            })

            assert.is_true(InteropKit:IsLibStubPresent())
            local ok, reason = InteropKit:ExposeToLibStub("interopKit", 1)
            assert.is_false(ok)
            assert.are.equal("unsupported", reason)
            assert.is_false(called)
            assert.is_nil(rawget(libStub, "libs"))
        end)

        it("refuses a minor recorded without a library", function()
            local libStub = Env.InstallLibStub()
            libStub.minors["MoltenCodes-InteropKit-1"] = 3

            local ok, reason = InteropKit:ExposeToLibStub("interopKit", 1)
            assert.is_false(ok)
            assert.are.equal("unsupported", reason)
            assert.are.equal(3, libStub.minors["MoltenCodes-InteropKit-1"])
        end)

        it("refuses when NewLibrary does not record the table it returns", function()
            local libStub = Env.InstallLibStub()
            rawset(libStub, "NewLibrary", function()
                return {}
            end)

            local ok, reason = InteropKit:ExposeToLibStub("interopKit", 1)
            assert.is_false(ok)
            assert.are.equal("unsupported", reason)
            assert.is_nil(libStub.libs["MoltenCodes-InteropKit-1"])
        end)
    end)
end)
