local TestEnv = require("RegistryTestEnv")

describe("Registry bootstrap", function()
    before_each(TestEnv.Reset)
    after_each(TestEnv.Reset)

    it("exposes its API generation and implementation revision", function()
        local Registry = require("Registry")

        assert.are.equal(2, Registry.API)
        assert.are.equal(7, Registry.REVISION)
    end)

    it("publishes the shared facade through the portable WoW global namespace", function()
        local Registry = require("Registry")
        local namespace = TestEnv.GetNamespace()

        assert.is_not_nil(namespace)
        assert.are.equal(Registry, namespace.Registry)
    end)

    it("can be loaded directly without require and remains publicly accessible", function()
        local chunk, loadError = loadfile("packages/registry/src/Registry.lua")
        if chunk == nil then
            error(loadError)
        end

        local Registry = chunk()

        assert.are.equal(Registry, TestEnv.GetNamespace().Registry)
    end)

    it("preserves unrelated fields in an existing MoltenCodes namespace", function()
        local marker = {}
        -- Registry's bootstrap handshake happens through the global table, so this spec sets it up there directly.
        -- selene: allow(global_usage)
        rawset(_G, TestEnv.NAMESPACE_KEY, { marker = marker })

        local Registry = require("Registry")
        local namespace = TestEnv.GetNamespace()

        assert.are.equal(marker, namespace.marker)
        assert.are.equal(Registry, namespace.Registry)
    end)

    it("rejects an incompatible owner of the MoltenCodes namespace", function()
        -- Registry's bootstrap handshake happens through the global table, so this spec sets it up there directly.
        -- selene: allow(global_usage)
        rawset(_G, TestEnv.NAMESPACE_KEY, "occupied")

        local ok, message = pcall(require, "Registry")

        assert.is_false(ok)
        assert.is_not_nil(string.find(tostring(message), "global namespace", 1, true))
    end)

    it("returns the same facade across embedded reloads", function()
        local first = require("Registry")
        local second = TestEnv.Reload()

        assert.are.equal(first, second)
    end)

    it("preserves registered state across embedded reloads", function()
        local first = require("Registry")
        local implementation = first:Register("exampleKit", 1, 4)
        implementation.marker = "preserved"

        local second = TestEnv.Reload()
        local selected, revision = second:Get("exampleKit", 1)

        assert.are.equal(implementation, selected)
        assert.are.equal("preserved", selected.marker)
        assert.are.equal(4, revision)
    end)

    it("uses one explicit global bootstrap state", function()
        local Registry = require("Registry")
        local state = TestEnv.GetState()

        assert.is_not_nil(Registry)
        assert.is_not_nil(state)
        assert.are.equal(1, state.schema)
        assert.are.equal(2, state.registryApi)
        assert.are.equal(7, state.registryRevision)
        assert.are.equal(Registry, state.facade)
    end)

    it("rejects an incompatible Registry API generation in bootstrap state", function()
        -- Registry's bootstrap handshake happens through the global table, so this spec sets it up there directly.
        -- selene: allow(global_usage)
        rawset(_G, TestEnv.STATE_KEY, {
            schema = 1,
            registryApi = 1,
            registryRevision = 1,
            entries = {},
            facade = {},
        })

        local ok, message = pcall(require, "Registry")

        assert.is_false(ok)
        assert.is_not_nil(string.find(tostring(message), "API generation is incompatible", 1, true))
    end)

    it("takes the public alias from an older Registry API generation", function()
        local legacyRegistry = { API = 1 }
        -- Registry's bootstrap handshake happens through the global table, so this spec sets it up there directly.
        -- selene: allow(global_usage)
        rawset(_G, TestEnv.NAMESPACE_KEY, {
            Registry = legacyRegistry,
        })

        local Registry = require("Registry")
        local namespace = TestEnv.GetNamespace()

        assert.are.equal(Registry, namespace.Registry)
        assert.are.equal(Registry, namespace.Registries[2])
        assert.are.equal(legacyRegistry, namespace.Registries[1])
    end)

    it("rejects a public alias that claims this generation but is not this facade", function()
        -- Registry's bootstrap handshake happens through the global table, so this spec sets it up there directly.
        -- selene: allow(global_usage)
        rawset(_G, TestEnv.NAMESPACE_KEY, {
            Registry = { API = 2 },
        })

        local ok, message = pcall(require, "Registry")

        assert.is_false(ok)
        assert.is_not_nil(string.find(tostring(message), "is not the shared facade", 1, true))
    end)

    it("rejects a corrupted compatible facade instead of returning it", function()
        -- Registry's bootstrap handshake happens through the global table, so this spec sets it up there directly.
        -- selene: allow(global_usage)
        rawset(_G, TestEnv.STATE_KEY, {
            schema = 1,
            registryApi = 2,
            registryRevision = 7,
            entries = {},
            facade = {
                API = 2,
                REVISION = 7,
            },
        })

        local ok, message = pcall(require, "Registry")

        assert.is_false(ok)
        assert.is_not_nil(string.find(tostring(message), "facade is corrupted", 1, true))
    end)

    it("upgrades an older compatible Registry facade in place", function()
        local oldRegister = function() end
        local oldGet = function() end
        local oldGetInfo = function() end
        local oldFacade = {
            API = 2,
            REVISION = 1,
            Register = oldRegister,
            Get = oldGet,
            GetInfo = oldGetInfo,
        }

        -- Registry's bootstrap handshake happens through the global table, so this spec sets it up there directly.
        -- selene: allow(global_usage)
        rawset(_G, TestEnv.STATE_KEY, {
            schema = 1,
            registryApi = 2,
            registryRevision = 1,
            entries = {},
            facade = oldFacade,
        })

        local Registry = require("Registry")

        assert.are.equal(oldFacade, Registry)
        assert.are.equal(7, Registry.REVISION)
        assert.are_not.equal(oldRegister, Registry.Register)
        assert.are.equal(Registry, TestEnv.GetNamespace().Registry)
    end)

    it("does not downgrade a newer compatible Registry implementation revision", function()
        local register = function() end
        local get = function() end
        local getInfo = function() end
        local bootstrapPackage = function() end
        local futureFacade = {
            API = 2,
            REVISION = 8,
            Register = register,
            Get = get,
            GetInfo = getInfo,
            Find = function() end,
            Packages = function() end,
            OnRetire = function() end,
            Bootstrap = bootstrapPackage,
        }

        -- Registry's bootstrap handshake happens through the global table, so this spec sets it up there directly.
        -- selene: allow(global_usage)
        rawset(_G, TestEnv.STATE_KEY, {
            schema = 1,
            registryApi = 2,
            registryRevision = 8,
            entries = {},
            facade = futureFacade,
        })

        local Registry = require("Registry")

        assert.are.equal(futureFacade, Registry)
        assert.are.equal(register, Registry.Register)
        assert.are.equal(8, Registry.REVISION)
        assert.are.equal(Registry, TestEnv.GetNamespace().Registry)
    end)

    it("rejects bootstrap fields supplied only through a metatable", function()
        local spoofedState = setmetatable({}, {
            __index = {
                schema = 1,
                registryApi = 2,
                registryRevision = 3,
                entries = {},
                facade = {},
            },
        })
        -- Registry's bootstrap handshake happens through the global table, so this spec sets it up there directly.
        -- selene: allow(global_usage)
        rawset(_G, TestEnv.STATE_KEY, spoofedState)

        local ok, message = pcall(require, "Registry")

        assert.is_false(ok)
        assert.is_not_nil(
            string.find(tostring(message), "bootstrap state is incompatible", 1, true)
        )
    end)

    it("rejects facade fields supplied only through a metatable", function()
        local facade = setmetatable({}, {
            __index = {
                API = 2,
                REVISION = 7,
                Register = function() end,
                Get = function() end,
                GetInfo = function() end,
            },
        })

        -- Registry's bootstrap handshake happens through the global table, so this spec sets it up there directly.
        -- selene: allow(global_usage)
        rawset(_G, TestEnv.STATE_KEY, {
            schema = 1,
            registryApi = 2,
            registryRevision = 7,
            entries = {},
            facade = facade,
        })

        local ok, message = pcall(require, "Registry")

        assert.is_false(ok)
        assert.is_not_nil(string.find(tostring(message), "facade is corrupted", 1, true))
    end)

    it("upgrades through a hostile facade __newindex without invoking it", function()
        local writes = 0
        local oldFacade = {
            API = 2,
            REVISION = 2,
        }
        setmetatable(oldFacade, {
            __newindex = function()
                writes = writes + 1
                error("facade __newindex must not run")
            end,
        })

        -- Registry's bootstrap handshake happens through the global table, so this spec sets it up there directly.
        -- selene: allow(global_usage)
        rawset(_G, TestEnv.STATE_KEY, {
            schema = 1,
            registryApi = 2,
            registryRevision = 2,
            entries = {},
            facade = oldFacade,
        })

        local Registry = require("Registry")

        assert.are.equal(oldFacade, Registry)
        assert.are.equal(7, rawget(Registry, "REVISION"))
        assert.are.equal(0, writes)
        assert.are.equal(Registry, TestEnv.GetNamespace().Registry)
    end)

    it("does not adopt retired API-1 bootstrap state", function()
        -- Registry's bootstrap handshake happens through the global table, so this spec sets it up there directly.
        -- selene: allow(global_usage)
        rawset(_G, TestEnv.LEGACY_STATE_KEY, {
            schema = 1,
            registryRevision = 1,
            entries = {
                legacyKit = {
                    [1] = {
                        revision = 99,
                        implementation = { marker = "legacy" },
                    },
                },
            },
            facade = {},
        })

        local Registry = require("Registry")

        assert.is_nil(Registry:Get("exampleKit", 1))
        assert.is_not_nil(TestEnv.GetState())
        -- Registry's bootstrap handshake happens through the global table, so this spec sets it up there directly.
        -- selene: allow(global_usage)
        assert.is_not_nil(rawget(_G, TestEnv.LEGACY_STATE_KEY))
    end)
end)
