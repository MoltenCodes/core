local TestEnv = require("ModuleKitTestEnv")

---The implementation revision the manifest declares, which the source under
---test must register as.
---@return integer revision
local function manifestRevision()
    local file = assert(io.open("packages/moduleKit/package.manifest.json", "r"))
    local text = file:read("*a")
    file:close()
    return assert(tonumber(text:match('"revision"%s*:%s*(%d+)')))
end

local CURRENT_REVISION = manifestRevision()

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
        assert.are.equal(upgraded.REVISION, rawget(rawget(upgraded, "_state"), "runtimeRevision"))
    end)
end)

-- An in-place upgrade re-installs lifecycle subscriptions on containers that
-- already exist. LifecycleKit replays a phase it has already reached to every
-- new subscriber, so an upgrade that subscribed blindly would dispatch `ready`
-- a second time and re-enable modules the addon had deliberately switched off.
describe("ModuleKit in-place upgrade", function()
    local function newDisabledModuleFixture()
        local ModuleKit = TestEnv.NewPackage()
        local addon = ModuleKit:ForAddon("MyAddon")
        local module = addon:CreateModule("UI")
        local hooks = {}

        module.OnInitialize = function()
            hooks[#hooks + 1] = "initialize"
        end
        module.OnEnable = function()
            hooks[#hooks + 1] = "enable"
        end
        module.OnDisable = function()
            hooks[#hooks + 1] = "disable"
        end

        TestEnv.LoadAddon("MyAddon")
        TestEnv.Login()
        module:Disable()

        return ModuleKit, addon, module, hooks
    end

    --- Make the shared state look like it was left by an earlier revision.
    local function markStateAsOlderRevision(ModuleKit)
        local state = rawget(ModuleKit, "_state")
        rawset(state, "runtimeRevision", ModuleKit.REVISION - 1)
    end

    after_each(TestEnv.Reset)

    it("keeps a deliberately disabled module disabled", function()
        local ModuleKit, addon, module, hooks = newDisabledModuleFixture()
        assert.are.same({ "initialize", "enable", "disable" }, hooks)

        markStateAsOlderRevision(ModuleKit)
        local upgraded = TestEnv.ReloadPackage()

        assert.are.equal(ModuleKit, upgraded)
        assert.are.equal(addon, upgraded:ForAddon("MyAddon"))
        assert.are.equal("disabled", module:GetState())
        assert.are.same({ "initialize", "enable", "disable" }, hooks)
    end)

    it("derives the dispatched phases of a container created by an older revision", function()
        local ModuleKit, addon, module, hooks = newDisabledModuleFixture()

        -- A container created before this revision carries no dispatched set.
        rawset(addon, "_dispatched", nil)
        markStateAsOlderRevision(ModuleKit)
        TestEnv.ReloadPackage()

        local dispatched = rawget(addon, "_dispatched")
        assert.is_true(rawget(dispatched, "loaded"))
        assert.is_true(rawget(dispatched, "ready"))
        assert.is_nil(rawget(dispatched, "shutdown"))
        assert.are.equal("disabled", module:GetState())
        assert.are.same({ "initialize", "enable", "disable" }, hooks)
    end)

    -- LifecycleKit replays a reached phase synchronously inside the subscribe
    -- call, before it hands back the handle. A module hook running in that
    -- replay can reach container shutdown, which the install loop used to test
    -- for exactly once, before the first subscription: it then went on to
    -- subscribe every remaining phase, leaving a container that believes it is
    -- shut down listening for `ready`.
    it("stops subscribing when a replayed phase shuts the container down", function()
        local ModuleKit = TestEnv.NewPackage()
        local addon = ModuleKit:ForAddon("ReplayAddon")
        local dispatch = rawget(rawget(ModuleKit, "_state"), "dispatch")

        local module = addon:CreateModule("UI")
        module.OnInitialize = function()
            -- A `PLAYER_LOGOUT` that arrives while the replay is running.
            dispatch.shutdown(addon)
        end

        local handles = {}
        local function newHandle(phase)
            local handle = { phase = phase, connected = true }
            handle.Disconnect = function(self)
                self.connected = false
            end
            handles[#handles + 1] = handle
            return handle
        end

        -- A lifecycle stub, which is the shape ModuleKit duck-types for. Its
        -- `OnLoaded` replays the phase the way LifecycleKit does: the callback
        -- runs first, the handle exists only afterwards.
        rawset(addon, "_lifecycle", {
            IsLoaded = function()
                return false
            end,
            IsReady = function()
                return false
            end,
            IsShutdown = function()
                return false
            end,
            OnLoaded = function(_, callback)
                callback()
                return newHandle("loaded")
            end,
            OnReady = function()
                return newHandle("ready")
            end,
            OnShutdown = function()
                return newHandle("shutdown")
            end,
        })
        rawset(addon, "_dispatched", {})
        markStateAsOlderRevision(ModuleKit)

        TestEnv.ReloadPackage()

        -- Only `loaded` was ever subscribed, and its handle — produced after the
        -- replay had already shut the container down — was disconnected rather
        -- than tracked. No live subscription survives on a shut-down container.
        assert.is_true(rawget(addon, "_shutdown"))
        assert.are.equal(1, #handles)
        assert.are.equal("loaded", handles[1].phase)
        assert.is_false(handles[1].connected)
        assert.is_nil(next(rawget(addon, "_subscriptions")))
    end)

    it("still dispatches a phase the container has not received yet", function()
        local ModuleKit, addon, module, hooks = newDisabledModuleFixture()
        rawset(addon, "_dispatched", nil)
        markStateAsOlderRevision(ModuleKit)
        TestEnv.ReloadPackage()

        -- `shutdown` was never reached, so the upgrade must keep listening for
        -- it: skipping every phase would leave the container without cleanup.
        module:Enable()
        TestEnv.Logout()

        assert.are.equal("disabled", module:GetState())
        assert.are.same({ "initialize", "enable", "disable", "enable", "disable" }, hooks)
        assert.is_true(rawget(rawget(addon, "_dispatched"), "shutdown"))
    end)
end)

describe("ModuleKit limits across an in-place upgrade", function()
    after_each(TestEnv.Reset)

    it("registers itself as ModuleKit API 1 at the manifest revision", function()
        local ModuleKit, Registry = TestEnv.NewPackage()
        local _, revision = Registry:Get("moduleKit", 1)

        assert.are.equal(CURRENT_REVISION, ModuleKit.REVISION)
        assert.are.equal(CURRENT_REVISION, revision)
    end)

    it("keeps set limits and the sentinel when a newer revision loads", function()
        local ModuleKit = TestEnv.NewPackage()
        local sentinel = ModuleKit.UNBOUNDED
        ModuleKit:SetLimits({ maxRequiredAddons = 5 })

        local nextRevision = ModuleKit.REVISION + 1
        local upgraded = TestEnv.LoadRevision(nextRevision)

        assert.are.equal(ModuleKit, upgraded)
        assert.are.equal(nextRevision, upgraded.REVISION)
        assert.are.equal(sentinel, upgraded.UNBOUNDED)
        assert.are.equal(5, upgraded:GetLimits().maxRequiredAddons)
    end)

    it("keeps ModuleKit.UNBOUNDED as a set limit when a newer revision loads", function()
        local ModuleKit, _, _, _, LifecycleKit = TestEnv.NewPackage()
        rawset(LifecycleKit, "GetLimits", nil)
        ModuleKit:SetLimits({ maxRequiredAddons = ModuleKit.UNBOUNDED })

        local upgraded = TestEnv.LoadRevision(ModuleKit.REVISION + 1)

        assert.are.equal(ModuleKit.UNBOUNDED, upgraded:GetLimits().maxRequiredAddons)
    end)

    it("leaves a newer revision's limits alone when an older copy loads after it", function()
        TestEnv.LoadDependencies()
        local newer = TestEnv.LoadRevision(17)
        newer:SetLimits({ maxRequiredAddons = 3 })

        local selected = TestEnv.LoadRevision(16)

        assert.are.equal(newer, selected)
        assert.are.equal(17, selected.REVISION)
        assert.are.equal(3, selected:GetLimits().maxRequiredAddons)
    end)

    it("creates the sentinel and the default limits over revision-13 state", function()
        TestEnv.LoadDependencies()
        local previous = TestEnv.LoadRevision(13)
        local addon = previous:ForAddon("MyAddon")
        -- Revision 13 kept neither the sentinel nor the limits.
        local state = rawget(previous, "_state")
        rawset(state, "unbounded", nil)
        rawset(state, "limits", nil)
        rawset(previous, "UNBOUNDED", nil)
        rawset(previous, "SetLimits", nil)
        rawset(previous, "GetLimits", nil)

        local upgraded = require("ModuleKit")

        assert.are.equal(previous, upgraded)
        assert.are.equal(CURRENT_REVISION, upgraded.REVISION)
        assert.are.equal(addon, upgraded:ForAddon("MyAddon"))
        assert.are.equal("table", type(upgraded.UNBOUNDED))
        assert.are.equal(rawget(state, "unbounded"), upgraded.UNBOUNDED)
        assert.are.same({ maxRequiredAddons = 16 }, upgraded:GetLimits())
        TestEnv.expectErrorContaining("requiresAddons must list at most 16 addons", function()
            local names = {}
            for index = 1, 17 do
                names[index] = "Required" .. index
            end
            addon:CreateModule("Seventeen", { requiresAddons = names })
        end)
    end)

    it("refuses to inherit corrupted limits", function()
        local ModuleKit = TestEnv.NewPackage()
        local state = rawget(ModuleKit, "_state")
        rawset(rawget(state, "limits"), "maxRequiredAddons", 0)
        rawset(state, "runtimeRevision", ModuleKit.REVISION - 1)

        TestEnv.expectErrorContaining("package state is corrupted or incomplete", function()
            TestEnv.requireAfterFailedLoad("ModuleKit")
        end)
    end)
end)

-- Revision 15 added `implements`. The contract lives on the provider record,
-- so nothing in package state changes: a record an older revision registered
-- carries none and resolves unchecked, and a record this revision registered
-- keeps its contract when a newer copy takes over.
describe("ModuleKit implements across an in-place upgrade", function()
    after_each(TestEnv.Reset)

    it("resolves a provider registered by revision 14 unchecked", function()
        TestEnv.LoadDependencies()
        local previous = TestEnv.LoadRevision(14)
        local addon = previous:ForAddon("MyAddon")
        -- Revision 14 accepted no options and stored no contract.
        addon:ProvideSingleton("Database", function()
            return {}
        end)
        local module = addon:CreateModule("UI", { onEnable = function() end })

        local upgraded = require("ModuleKit")

        assert.are.equal(previous, upgraded)
        assert.are.equal(CURRENT_REVISION, upgraded.REVISION)
        assert.are.equal(addon, upgraded:ForAddon("MyAddon"))
        assert.is_nil(rawget(rawget(rawget(addon, "_providers"), "Database"), "implements"))
        assert.is_table(addon:Resolve("Database"))
        assert.are.equal(module, addon:GetModule("UI"))
        TestEnv.expectErrorContaining('provider "Checked" must implement "Save"', function()
            addon:ProvideValue("Checked", {}, { implements = { "Save" } })
        end)
    end)

    it("keeps a provider's contract when a newer revision loads", function()
        local ModuleKit = TestEnv.NewPackage()
        local addon = ModuleKit:ForAddon("MyAddon")
        addon:ProvideSingleton("Database", function()
            return {}
        end, { implements = { "Save" } })

        local nextRevision = ModuleKit.REVISION + 1
        local upgraded = TestEnv.LoadRevision(nextRevision)

        assert.are.equal(ModuleKit, upgraded)
        assert.are.equal(nextRevision, upgraded.REVISION)
        TestEnv.expectErrorContaining('provider "Database" must implement "Save"', function()
            upgraded:ForAddon("MyAddon"):Resolve("Database")
        end)
    end)
end)

-- Revision 16 changed error levels and method labels only, so nothing in
-- package state, on a container, on a module or on a provider record changes:
-- what revision 15 created keeps working, and its argument errors now point at
-- the caller's line.
describe("ModuleKit upgrade from revision 15", function()
    after_each(TestEnv.Reset)

    it("keeps containers, modules and contracts and reports errors at the caller", function()
        TestEnv.LoadDependencies()
        local previous = TestEnv.LoadRevision(15)
        local addon = previous:ForAddon("MyAddon")
        local module = addon:CreateModule("UI")
        addon:ProvideSingleton("Database", function()
            return {}
        end, { implements = { "Save" } })

        local upgraded = require("ModuleKit")

        assert.are.equal(previous, upgraded)
        assert.are.equal(CURRENT_REVISION, upgraded.REVISION)
        assert.are.equal(addon, upgraded:ForAddon("MyAddon"))
        assert.are.equal(module, addon:GetModule("UI"))
        TestEnv.expectErrorContaining('provider "Database" must implement "Save"', function()
            addon:Resolve("Database")
        end)

        local line = debug.getinfo(1, "l").currentline + 2
        local ok, message = pcall(function()
            module:DependsOn("")
        end)
        assert.is_false(ok)
        assert.is_not_nil(
            string.find(message, "Bootstrap_spec.lua:" .. line .. ":", 1, true),
            message
        )
    end)
end)

-- Revisions 17 and 18 changed only how arguments are checked (the nil rule and
-- the secret checks), nothing in package state, on a container, on a module or
-- on a provider record, so what the previous revision created keeps working.
describe("ModuleKit upgrade from the previous revision", function()
    after_each(TestEnv.Reset)

    it("keeps the facade, the state, containers, modules and providers", function()
        TestEnv.LoadDependencies()
        local previous = TestEnv.LoadRevision(CURRENT_REVISION - 1)
        local state = rawget(previous, "_state")
        local addon = previous:ForAddon("MyAddon")
        local module = addon:CreateModule("UI")
        addon:ProvideValue("Settings", { scale = 1 })

        local upgraded = require("ModuleKit")

        assert.are.equal(previous, upgraded)
        assert.are.equal(state, rawget(upgraded, "_state"))
        assert.are.equal(CURRENT_REVISION, upgraded.REVISION)
        assert.are.equal(addon, upgraded:ForAddon("MyAddon"))
        assert.are.equal(module, addon:GetModule("UI"))
        assert.are.same({ scale = 1 }, addon:Resolve("Settings"))
    end)

    it("keeps the dependency policy and the limits the previous revision set", function()
        TestEnv.LoadDependencies()
        local previous = TestEnv.LoadRevision(CURRENT_REVISION - 1)
        local addon = previous:ForAddon("MyAddon")
        addon:SetDependencyPolicy("strict")
        previous:SetLimits({ maxRequiredAddons = 6 })

        local upgraded = require("ModuleKit")

        assert.are.equal(CURRENT_REVISION, upgraded.REVISION)
        assert.are.equal("strict", addon:GetDependencyPolicy())
        assert.are.equal(6, upgraded:GetLimits().maxRequiredAddons)
    end)
end)
