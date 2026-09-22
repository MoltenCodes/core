local TestEnv = require("ModuleKitTestEnv")

describe("ModuleKit bootstrap", function()
    after_each(TestEnv.Reset)

    it("reuses the shared facade on duplicate load", function()
        local ModuleKit = TestEnv.NewPackage()
        local addon = ModuleKit:ForAddon("MyAddon")
        local reloaded = TestEnv.ReloadPackage()

        assert.are.equal(ModuleKit, reloaded)
        assert.are.equal(addon, reloaded:ForAddon("MyAddon"))
    end)

    it("publishes through Registry under moduleKit API 1", function()
        local ModuleKit, Registry = TestEnv.NewPackage()
        local registered, revision = Registry:Get("moduleKit", 1)

        assert.are.equal(ModuleKit, registered)
        assert.are.equal(ModuleKit.REVISION, revision)
    end)

    it("requires LifecycleKit", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        require("Registry")

        assert.has_error(function()
            require("ModuleKit")
        end)
    end)

    it("routes existing lifecycle subscriptions through shared runtime dispatch", function()
        local ModuleKit = TestEnv.NewPackage()
        ModuleKit:ForAddon("MyAddon")
        local state = rawget(ModuleKit, "_state")
        local dispatch = rawget(state, "dispatch")
        local original = rawget(dispatch, "initializeAll")
        local calls = 0

        rawset(dispatch, "initializeAll", function(addon)
            calls = calls + 1
            return addon
        end)

        TestEnv.LoadAddon("MyAddon")
        rawset(dispatch, "initializeAll", original)

        assert.are.equal(1, calls)
    end)

    it("repairs shared runtime dispatch on a same-revision reload", function()
        local ModuleKit = TestEnv.NewPackage()
        local state = rawget(ModuleKit, "_state")
        local dispatch = rawget(state, "dispatch")
        rawset(dispatch, "shutdown", nil)

        local reloaded = TestEnv.ReloadPackage()

        assert.are.equal(ModuleKit, reloaded)
        assert.is_true(type(rawget(rawget(state, "dispatch"), "shutdown")) == "function")
    end)

    it("migrates revision-1 lifecycle subscriptions without replacing addon identity", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()

        local Registry = require("Registry")
        require("SignalKit")
        require("EventKit")
        local LifecycleKit = require("LifecycleKit")

        local previous = assert(Registry:Register("moduleKit", 1, 1))
        local Addon = {}
        local Module = {}
        local noop = function() end
        local addonMethods = {
            "GetAddonName",
            "GetDependencyPolicy",
            "SetDependencyPolicy",
            "CreateModule",
            "GetModule",
            "HasModule",
            "GetModules",
            "GetActivationOrder",
            "ValidateGraph",
            "InitializeAll",
            "EnableAll",
            "DisableAll",
            "ProvideValue",
            "ProvideSingleton",
            "ProvideModule",
            "ProvideTransient",
            "Resolve",
        }
        local moduleMethods = {
            "GetName",
            "GetAddon",
            "GetState",
            "IsInitialized",
            "IsEnabled",
            "GetLastError",
            "HasLastError",
            "GetBlockedBy",
            "GetInjections",
            "DependsOn",
            "OptionalDependency",
            "Before",
            "After",
            "Inject",
            "Initialize",
            "Enable",
            "Disable",
            "Activate",
            "Resolve",
        }
        for index = 1, #addonMethods do
            Addon[addonMethods[index]] = noop
        end
        for index = 1, #moduleMethods do
            Module[moduleMethods[index]] = noop
        end

        local lifecycle = LifecycleKit:ForAddon("UpgradeAddon")
        local oldLoaded = lifecycle:OnLoaded(noop)
        local oldReady = lifecycle:OnReady(noop)
        local oldShutdown = lifecycle:OnShutdown(noop)
        local addon = setmetatable({
            _name = "UpgradeAddon",
            _lifecycle = lifecycle,
            _dependencyPolicy = "automatic",
            _modules = {},
            _moduleOrder = {},
            _providers = {},
            _resolutionStack = {},
            _shutdown = false,
            _subscriptions = {
                loaded = oldLoaded,
                ready = oldReady,
                shutdown = oldShutdown,
            },
        }, { __index = Addon })

        rawset(previous, "API", 1)
        rawset(previous, "REVISION", 1)
        rawset(previous, "Addon", Addon)
        rawset(previous, "Module", Module)
        rawset(previous, "ForAddon", noop)
        rawset(previous, "_state", {
            schema = 1,
            addons = { UpgradeAddon = addon },
        })

        package.loaded["ModuleKit"] = nil
        local upgraded = require("ModuleKit")

        assert.are.equal(previous, upgraded)
        assert.are.equal(addon, upgraded:ForAddon("UpgradeAddon"))
        assert.is_false(oldLoaded:IsConnected())
        assert.is_false(oldReady:IsConnected())
        assert.is_false(oldShutdown:IsConnected())
        assert.are.equal(2, rawget(rawget(upgraded, "_state"), "runtimeRevision"))
    end)
end)
