local TestEnv = require("RegistryTestEnv")

describe("Registry bootstrap", function()
    before_each(TestEnv.Reset)
    after_each(TestEnv.Reset)

    it("exposes its API generation and implementation revision", function()
        local Registry = require("Registry")

        assert.are.equal(2, Registry.API)
        assert.are.equal(4, Registry.REVISION)
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
        rawset(_G, TestEnv.NAMESPACE_KEY, { marker = marker })

        local Registry = require("Registry")
        local namespace = TestEnv.GetNamespace()

        assert.are.equal(marker, namespace.marker)
        assert.are.equal(Registry, namespace.Registry)
    end)

    it("rejects an incompatible owner of the MoltenCodes namespace", function()
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
        assert.are.equal(4, state.registryRevision)
        assert.are.equal(Registry, state.facade)
    end)

    it("rejects an incompatible Registry API generation in bootstrap state", function()
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

    it("rejects an incompatible Registry API generation in the public namespace", function()
        rawset(_G, TestEnv.NAMESPACE_KEY, {
            Registry = { API = 1 },
        })

        local ok, message = pcall(require, "Registry")

        assert.is_false(ok)
        assert.is_not_nil(string.find(tostring(message), "API generation conflict", 1, true))
    end)

    it("rejects a corrupted compatible facade instead of returning it", function()
        rawset(_G, TestEnv.STATE_KEY, {
            schema = 1,
            registryApi = 2,
            registryRevision = 4,
            entries = {},
            facade = {
                API = 2,
                REVISION = 4,
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

        rawset(_G, TestEnv.STATE_KEY, {
            schema = 1,
            registryApi = 2,
            registryRevision = 1,
            entries = {},
            facade = oldFacade,
        })

        local Registry = require("Registry")

        assert.are.equal(oldFacade, Registry)
        assert.are.equal(4, Registry.REVISION)
        assert.are_not.equal(oldRegister, Registry.Register)
        assert.are.equal(Registry, TestEnv.GetNamespace().Registry)
    end)

    it("does not downgrade a newer compatible Registry implementation revision", function()
        local register = function() end
        local get = function() end
        local getInfo = function() end
        local futureFacade = {
            API = 2,
            REVISION = 5,
            Register = register,
            Get = get,
            GetInfo = getInfo,
        }

        rawset(_G, TestEnv.STATE_KEY, {
            schema = 1,
            registryApi = 2,
            registryRevision = 5,
            entries = {},
            facade = futureFacade,
        })

        local Registry = require("Registry")

        assert.are.equal(futureFacade, Registry)
        assert.are.equal(register, Registry.Register)
        assert.are.equal(5, Registry.REVISION)
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
                REVISION = 5,
                Register = function() end,
                Get = function() end,
                GetInfo = function() end,
            },
        })

        rawset(_G, TestEnv.STATE_KEY, {
            schema = 1,
            registryApi = 2,
            registryRevision = 5,
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

        rawset(_G, TestEnv.STATE_KEY, {
            schema = 1,
            registryApi = 2,
            registryRevision = 2,
            entries = {},
            facade = oldFacade,
        })

        local Registry = require("Registry")

        assert.are.equal(oldFacade, Registry)
        assert.are.equal(4, rawget(Registry, "REVISION"))
        assert.are.equal(0, writes)
        assert.are.equal(Registry, TestEnv.GetNamespace().Registry)
    end)

    it("does not adopt retired API-1 bootstrap state", function()
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
        assert.is_not_nil(rawget(_G, TestEnv.LEGACY_STATE_KEY))
    end)
end)
