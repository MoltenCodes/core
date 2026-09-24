local TestEnv = require("EventKitTestEnv")

---The implementation revision `src/EventKit.lua` carries; `Manifest_spec.lua`
---pins the same number against `package.manifest.json`.
local CURRENT_REVISION = 14

local function expectErrorContaining(expected, callback)
    local ok, message = pcall(callback)
    assert.is_false(ok)
    assert.is_not_nil(string.find(tostring(message), expected, 1, true))
end

local function installFutureEventsFacade(Registry)
    local EventKit = Registry:Register("eventKit", 1, CURRENT_REVISION + 1)
    local function stub() end
    EventKit.API = 1
    EventKit.REVISION = CURRENT_REVISION + 1
    EventKit.Connection = { Disconnect = stub, IsConnected = stub }
    EventKit.Scope = {
        Connect = stub,
        Once = stub,
        ConnectUnit = stub,
        OnceUnit = stub,
        ConnectCombatLog = stub,
        DisconnectAll = stub,
        Close = stub,
        IsClosed = stub,
        GetAddonName = stub,
        GetActiveCount = stub,
        Coalesce = stub,
        Derive = stub,
    }
    EventKit.Connect = stub
    EventKit.Once = stub
    EventKit.ConnectUnit = stub
    EventKit.OnceUnit = stub
    EventKit.ConnectCombatLog = stub
    EventKit.CreateScope = stub
    EventKit.Coalesce = stub
    EventKit.Derive = stub
    EventKit.ForAddon = stub
    EventKit.CloseAddonScopes = stub
    EventKit.UNBOUNDED = {}
    EventKit.SetLimits = stub
    EventKit.GetLimits = stub
    return EventKit
end

---Strip what revision 10 added, so a copy loaded at an older revision leaves
---the schema-5 state and facade that revisions 7 to 9 left behind.
---@param legacy table
local function emulateSchemaFiveCopy(legacy)
    local legacyState = rawget(legacy, "_state")
    rawset(legacyState, "schema", 5)
    rawset(legacyState, "unbounded", nil)
    rawset(legacyState, "limits", nil)
    rawset(legacy, "UNBOUNDED", nil)
    rawset(legacy, "SetLimits", nil)
    rawset(legacy, "GetLimits", nil)
end

---Strip what revision 12 added, so a copy loaded at revision 11 leaves the
---schema-7 state and facade revision 11 left behind.
---@param legacy table
local function emulateSchemaSevenCopy(legacy)
    local legacyState = rawget(legacy, "_state")
    rawset(legacyState, "schema", 7)
    rawset(legacyState, "combatLog", nil)
    rawset(legacyState, "dispatchCombatLog", nil)
    rawset(legacy, "ConnectCombatLog", nil)
    rawset(rawget(legacy, "Scope"), "ConnectCombatLog", nil)
end

describe("EventKit package bootstrap", function()
    after_each(TestEnv.Reset)

    it("requires Registry to load first", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        expectErrorContaining("requires Registry API 2", function()
            require("EventKit")
        end)
    end)

    it("requires SignalKit to load first", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        require("Registry")
        expectErrorContaining("requires SignalKit API 1", function()
            require("EventKit")
        end)
    end)

    it("rejects an incomplete SignalKit facade", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        require("Registry")
        local SignalKit = require("SignalKit")
        SignalKit.Fire = nil
        expectErrorContaining("valid SignalKit API 1 facade", function()
            require("EventKit")
        end)
    end)

    it("registers EventKit API 1 at the current revision", function()
        local EventKit, Registry = TestEnv.NewPackage()
        local selected, revision = Registry:Get("eventKit", 1)
        assert.are.equal(EventKit, selected)
        assert.are.equal(CURRENT_REVISION, revision)
        assert.are.equal(1, EventKit.API)
        assert.are.equal(CURRENT_REVISION, EventKit.REVISION)
    end)

    it("reuses the package facade across duplicate embedding", function()
        local first = TestEnv.NewPackage()
        local second = TestEnv.ReloadPackage()
        assert.are.equal(first, second)
    end)

    it("preserves active listeners across duplicate embedding", function()
        local first = TestEnv.NewPackage()
        local calls = 0
        first:Connect("PLAYER_LOGIN", function()
            calls = calls + 1
        end)
        local second = TestEnv.ReloadPackage()
        TestEnv.Emit("PLAYER_LOGIN")
        assert.are.equal(first, second)
        assert.are.equal(1, calls)
    end)

    it("keeps the connection method table stable across duplicate embedding", function()
        local first = TestEnv.NewPackage()
        local methods = first.Connection
        local second = TestEnv.ReloadPackage()
        assert.are.equal(methods, second.Connection)
    end)

    it("rejects corrupted current-revision state", function()
        local EventKit = TestEnv.NewPackage()
        EventKit._state = nil
        package.loaded["EventKit"] = nil
        expectErrorContaining("corrupted or incomplete", function()
            require("EventKit")
        end)
    end)

    it("upgrades revision-1 package state in place", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        local Registry = require("Registry")
        require("SignalKit")

        -- A revision-1 copy loaded first and already created a unit-filter Frame.
        -- Revision 1 kept no free list, no creation counter, no dispatch slots
        -- and no group key, so the upgrade has to supply all of them without
        -- replacing the package table or the Frame.
        local legacyFrame = { scripts = {} }
        function legacyFrame:SetScript(scriptName, callback)
            self.scripts[scriptName] = callback
        end

        local legacyGroup = { units = { "player" }, channels = {}, frame = legacyFrame }
        local legacy = Registry:Register("eventKit", 1, 1)
        legacy.API = 1
        legacy.REVISION = 1
        legacy.Connection = { Disconnect = function() end, IsConnected = function() end }
        legacy.Connect = function() end
        legacy.Once = function() end
        legacy.ConnectUnit = function() end
        legacy.OnceUnit = function() end
        legacy._state = {
            schema = 1,
            regularFrame = nil,
            regularChannels = {},
            unitGroups = { ["6:player"] = legacyGroup },
        }
        local legacyConnectionMethods = legacy.Connection

        local EventKit = require("EventKit")
        local state = EventKit._state

        assert.are.equal(legacy, EventKit)
        assert.are.equal(CURRENT_REVISION, EventKit.REVISION)
        assert.are.equal(legacyConnectionMethods, EventKit.Connection)
        assert.are.equal(8, state.schema)
        assert.are.equal(legacyGroup, state.unitGroups["6:player"])
        assert.are.equal("6:player", legacyGroup.key)
        assert.are.equal(1, state.unitFrameCount)
        assert.are.equal(0, #state.unitFrames)
        assert.are.equal("function", type(state.dispatchRegular))
        assert.are.equal("function", type(state.isolate))
        assert.are.equal("table", type(state.addonScopes))
        assert.are.equal("table", type(EventKit.Scope))
    end)

    it("upgrades revision-4 package state in place", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        local Registry = require("Registry")
        require("SignalKit")

        -- Revision 4 left schema-2 state behind: no scope prototype, no addon
        -- scopes and no shared scope metatable.
        local function stub() end
        local legacy = Registry:Register("eventKit", 1, 4)
        legacy.API = 1
        legacy.REVISION = 4
        legacy.Connection = { Disconnect = stub, IsConnected = stub }
        legacy.Connect = stub
        legacy.Once = stub
        legacy.ConnectUnit = stub
        legacy.OnceUnit = stub
        legacy._state = {
            schema = 2,
            regularFrame = nil,
            regularChannels = {},
            unitGroups = {},
            unitFrames = {},
            unitFrameCount = 0,
            dispatchRegular = stub,
            dispatchUnit = stub,
            isolate = stub,
        }
        local legacyConnectionMethods = legacy.Connection

        local EventKit = require("EventKit")
        local state = EventKit._state

        assert.are.equal(legacy, EventKit)
        assert.are.equal(CURRENT_REVISION, EventKit.REVISION)
        assert.are.equal(legacyConnectionMethods, EventKit.Connection)
        assert.are.equal(8, state.schema)
        assert.are.equal("table", type(state.addonScopes))
        assert.are.equal("table", type(EventKit.Scope))

        local scope = EventKit:CreateScope()
        scope:Connect("PLAYER_LOGIN", stub)
        assert.are.equal(1, scope:GetActiveCount())
    end)

    it("upgrades revision-5 package state in place", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        local Registry = require("Registry")
        require("SignalKit")

        -- Revision 5 left schema-3 state behind: scopes, but no dispatch
        -- accounting, so a scope closed mid-dispatch was swept at once.
        local function stub() end
        local legacyScopePrototype = {}
        local legacyAddonScope = setmetatable({
            _addonName = "MyAddon",
            _head = false,
            _tail = false,
            _activeCount = 0,
            _closed = false,
        }, { __index = legacyScopePrototype })
        local legacyScopeMetatable = getmetatable(legacyAddonScope)
        local legacy = Registry:Register("eventKit", 1, 5)
        legacy.API = 1
        legacy.REVISION = 5
        legacy.Connection = { Disconnect = stub, IsConnected = stub }
        legacy.Scope = legacyScopePrototype
        legacy._state = {
            schema = 3,
            regularFrame = nil,
            regularChannels = {},
            unitGroups = {},
            unitFrames = {},
            unitFrameCount = 0,
            dispatchRegular = stub,
            dispatchUnit = stub,
            isolate = stub,
            addonScopes = { MyAddon = legacyAddonScope },
            scopeMetatable = legacyScopeMetatable,
        }

        local EventKit = require("EventKit")
        local state = EventKit._state

        assert.are.equal(CURRENT_REVISION, EventKit.REVISION)
        assert.are.equal(legacyScopePrototype, EventKit.Scope)
        assert.are.equal(8, state.schema)
        assert.are.equal(0, state.dispatchDepth)
        assert.are.equal(0, state.pendingScopeCount)

        -- The scope revision 5 created keeps working, now with deferred close.
        assert.are.equal(legacyAddonScope, EventKit:ForAddon("MyAddon"))
        -- The closing listener runs first, as LifecycleKit's watcher does.
        EventKit:Once("PLAYER_LOGOUT", function()
            EventKit:CloseAddonScopes("MyAddon")
        end)
        local calls = 0
        legacyAddonScope:Connect("PLAYER_LOGOUT", function()
            calls = calls + 1
        end)
        TestEnv.Emit("PLAYER_LOGOUT")
        assert.are.equal(1, calls)
        assert.are.equal(0, legacyAddonScope:GetActiveCount())
    end)

    it("upgrades revision-6 package state in place", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        local Registry = require("Registry")
        require("SignalKit")

        -- Revision 6 left schema-4 state behind: no Coalesce or Derive
        -- dispatch, and no handle metatables for them.
        local function stub() end
        local legacyScopePrototype = {}
        local legacyScope = setmetatable({
            _addonName = "MyAddon",
            _head = false,
            _tail = false,
            _activeCount = 0,
            _closed = false,
        }, { __index = legacyScopePrototype })
        local legacy = Registry:Register("eventKit", 1, 6)
        legacy.API = 1
        legacy.REVISION = 6
        legacy.Connection = { Disconnect = stub, IsConnected = stub }
        legacy.Scope = legacyScopePrototype
        legacy._state = {
            schema = 4,
            regularFrame = nil,
            regularChannels = {},
            unitGroups = {},
            unitFrames = {},
            unitFrameCount = 0,
            dispatchRegular = stub,
            dispatchUnit = stub,
            isolate = stub,
            addonScopes = { MyAddon = legacyScope },
            scopeMetatable = getmetatable(legacyScope),
            dispatchDepth = 0,
            pendingScopes = {},
            pendingScopeCount = 0,
        }

        local EventKit = require("EventKit")
        local state = EventKit._state
        assert.are.equal(CURRENT_REVISION, EventKit.REVISION)
        assert.are.equal(8, state.schema)
        assert.is_function(state.composites.onEvent)
        assert.is_table(state.compositeMetatables.coalesce)
        assert.is_table(state.compositeMetatables.derive)

        -- The scope revision 6 created can own a Derive and sweep it.
        local derived = legacyScope:Derive("CUSTOM_EVENT", function()
            return 1
        end)
        assert.are.equal(1, legacyScope:GetActiveCount())
        EventKit:CloseAddonScopes("MyAddon")
        assert.is_true(derived:IsClosed())
        assert.are.equal(0, legacyScope:GetActiveCount())
    end)

    it("upgrades revision-8 package state in place", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        local Registry = require("Registry")
        require("SignalKit")

        -- Revision 8 left schema-5 state behind; the newer copy adopts it,
        -- adds the sentinel and the limits, and replaces the behaviour its
        -- live handles resolve through.
        local legacy = TestEnv.LoadSourceAtRevision(8)
        emulateSchemaFiveCopy(legacy)
        assert.are.equal(8, legacy.REVISION)
        local scope = legacy:ForAddon("MyAddon")
        local derived = scope:Derive("CUSTOM_EVENT", function()
            return 1
        end)
        local listener = derived:OnChange(function() end)

        local EventKit = require("EventKit")
        local _, revision = Registry:Get("eventKit", 1)
        assert.are.equal(legacy, EventKit)
        assert.are.equal(CURRENT_REVISION, revision)
        assert.are.equal(8, EventKit._state.schema)

        -- Closing a handle revision 8 created now disconnects its listeners.
        EventKit:CloseAddonScopes("MyAddon")
        assert.is_true(derived:IsClosed())
        assert.is_false(listener:IsConnected())
        assert.are.equal(0, scope:GetActiveCount())
    end)

    it("upgrades revision-9 package state in place, adding the sentinel and limits", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        local Registry = require("Registry")
        require("SignalKit")

        local legacy = TestEnv.LoadSourceAtRevision(9)
        local connection = legacy:ConnectUnit("UNIT_HEALTH", function() end, "player")
        emulateSchemaFiveCopy(legacy)

        local EventKit = require("EventKit")
        local _, revision = Registry:Get("eventKit", 1)
        local state = EventKit._state
        assert.are.equal(legacy, EventKit)
        assert.are.equal(CURRENT_REVISION, revision)
        assert.are.equal(8, state.schema)
        assert.are.equal("table", type(EventKit.UNBOUNDED))
        assert.are.equal(state.unbounded, EventKit.UNBOUNDED)
        assert.are.same({ maxUnitFrames = 64 }, EventKit:GetLimits())
        -- The Frame revision 9 created stays counted against the limit.
        assert.are.equal(1, state.unitFrameCount)
        assert.is_true(connection:IsConnected())
    end)

    it("upgrades revision-11 package state in place, adding combat-log routing", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        local Registry = require("Registry")
        require("SignalKit")

        -- Revision 11 left schema-7 state behind: no combat-log router. A
        -- plain listener it connected to the combat-log event keeps its
        -- channel, which the router then shares.
        local legacy = TestEnv.LoadSourceAtRevision(11)
        local plainCalls = 0
        local plain = legacy:Connect("COMBAT_LOG_EVENT_UNFILTERED", function()
            plainCalls = plainCalls + 1
        end)
        local scope = legacy:ForAddon("MyAddon")
        emulateSchemaSevenCopy(legacy)
        assert.is_nil(legacy.ConnectCombatLog)

        local EventKit = require("EventKit")
        local _, revision = Registry:Get("eventKit", 1)
        local state = EventKit._state
        assert.are.equal(legacy, EventKit)
        assert.are.equal(CURRENT_REVISION, revision)
        assert.are.equal(8, state.schema)
        assert.is_table(state.combatLog)
        assert.is_function(state.dispatchCombatLog)
        assert.is_function(EventKit.ConnectCombatLog)
        assert.is_function(EventKit.Scope.ConnectCombatLog)

        -- The scope revision 11 created can route the combat log, and the
        -- router shares the registration the older copy already holds.
        local routedCalls = 0
        scope:ConnectCombatLog("SPELL_DAMAGE", function(_, subEvent)
            routedCalls = routedCalls + 1
            assert.are.equal("SPELL_DAMAGE", subEvent)
        end)
        -- The Frame also holds the PLAYER_LOGOUT one-shot `ForAddon` connected;
        -- the combat-log event itself was registered exactly once.
        local frame = TestEnv.Frames()[1]
        local combatLogRegistrations = 0
        for index = 1, #frame.registerEventCalls do
            if frame.registerEventCalls[index] == "COMBAT_LOG_EVENT_UNFILTERED" then
                combatLogRegistrations = combatLogRegistrations + 1
            end
        end
        assert.are.equal(1, combatLogRegistrations)

        TestEnv.EmitCombatLogEvent(1, "SPELL_DAMAGE")
        assert.are.equal(1, plainCalls)
        assert.are.equal(1, routedCalls)

        -- The older copy's connection releases through the newer code and
        -- leaves the registration to the router.
        assert.is_true(plain:Disconnect())
        assert.are.equal(0, #frame.unregisterEventCalls)
        EventKit:CloseAddonScopes("MyAddon")
        assert.are.same({ "COMBAT_LOG_EVENT_UNFILTERED" }, frame.unregisterEventCalls)
    end)

    it("upgrades revision-12 package state in place, keeping live combat-log routes", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        local Registry = require("Registry")
        require("SignalKit")

        -- Revision 12 left schema-8 state behind, the schema this revision
        -- keeps. Its router, routes and listeners carry over unchanged.
        local legacy = TestEnv.LoadSourceAtRevision(12)
        local calls = 0
        local connection = legacy:ConnectCombatLog("SPELL_DAMAGE", function()
            calls = calls + 1
        end)

        local EventKit = require("EventKit")
        local _, revision = Registry:Get("eventKit", 1)
        assert.are.equal(legacy, EventKit)
        assert.are.equal(CURRENT_REVISION, revision)
        assert.are.equal(8, EventKit._state.schema)

        TestEnv.EmitCombatLogEvent(1, "SPELL_DAMAGE")
        assert.are.equal(1, calls)
        assert.are.equal(1, TestEnv.CombatLogEventInfoReads())

        -- The older copy's connection releases through the newer code and
        -- detaches the router with the registration.
        assert.is_true(connection:Disconnect())
        assert.is_false(EventKit._state.combatLog.channel)
        assert.are.same({ "COMBAT_LOG_EVENT_UNFILTERED" }, TestEnv.Frames()[1].unregisterEventCalls)
    end)

    it("upgrades the previous revision in place, keeping facade, state and listeners", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        local Registry = require("Registry")
        require("SignalKit")

        local legacy = TestEnv.LoadSourceAtRevision(CURRENT_REVISION - 1)
        local legacyState = legacy._state
        legacy:SetLimits({ maxUnitFrames = 100 })
        local calls = 0
        local connection = legacy:ForAddon("MyAddon"):Connect("CUSTOM_EVENT", function()
            calls = calls + 1
        end)

        local EventKit = require("EventKit")
        local _, revision = Registry:Get("eventKit", 1)
        assert.are.equal(legacy, EventKit)
        assert.are.equal(CURRENT_REVISION, revision)
        assert.are.equal(legacyState, EventKit._state)
        assert.are.equal(100, EventKit:GetLimits().maxUnitFrames)

        TestEnv.Emit("CUSTOM_EVENT")
        assert.are.equal(1, calls)
        EventKit:CloseAddonScopes("MyAddon")
        assert.is_false(connection:IsConnected())
    end)

    it("carries set limits and the sentinel to a newer revision", function()
        local EventKit, Registry = TestEnv.NewPackage()
        local sentinel = EventKit.UNBOUNDED
        EventKit:SetLimits({ maxUnitFrames = 200 })

        local newer = TestEnv.LoadSourceAtRevision(CURRENT_REVISION + 1)
        local _, revision = Registry:Get("eventKit", 1)
        assert.are.equal(EventKit, newer)
        assert.are.equal(CURRENT_REVISION + 1, revision)
        assert.are.equal(sentinel, newer.UNBOUNDED)
        assert.are.equal(200, newer:GetLimits().maxUnitFrames)
    end)

    it("rejects state whose sentinel no longer matches the facade", function()
        local EventKit = TestEnv.NewPackage()
        EventKit.UNBOUNDED = {}
        package.loaded["EventKit"] = nil
        expectErrorContaining("corrupted or incomplete", function()
            require("EventKit")
        end)
    end)

    it("rejects state whose limits are out of range", function()
        local EventKit = TestEnv.NewPackage()
        EventKit._state.limits.maxUnitFrames = 0
        package.loaded["EventKit"] = nil
        expectErrorContaining("corrupted or incomplete", function()
            require("EventKit")
        end)
    end)

    it("disconnects a handle shaped by a revision before scopes existed", function()
        local EventKit = TestEnv.NewPackage()
        local calls = 0
        local connection = EventKit:Connect("PLAYER_LOGIN", function()
            calls = calls + 1
        end)

        -- A revision-4 handle carries no scope link fields at all.
        rawset(connection, "_scope", nil)
        rawset(connection, "_scopePrevious", nil)
        rawset(connection, "_scopeNext", nil)

        assert.is_true(connection:Disconnect())
        TestEnv.Emit("PLAYER_LOGIN")
        assert.are.equal(0, calls)
    end)

    it("keeps serving revision-1 Frames after an in-place upgrade", function()
        -- Revision-1 Frame handlers call `EventKit._DispatchRegular`. Emulate one
        -- and prove it still reaches listeners connected by revision 2.
        local EventKit = TestEnv.NewPackage()
        local calls = 0
        EventKit:Connect("CUSTOM_EVENT", function()
            calls = calls + 1
        end)

        local function revisionOneFrameHandler(_, eventName, ...)
            local dispatcher = rawget(EventKit, "_DispatchRegular")
            dispatcher(EventKit, eventName, ...)
        end

        revisionOneFrameHandler(nil, "CUSTOM_EVENT")

        assert.are.equal(1, calls)
    end)

    it("does not downgrade a newer compatible embedded revision", function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        local Registry = require("Registry")
        require("SignalKit")
        local future = installFutureEventsFacade(Registry)
        local loaded = require("EventKit")
        local selected, revision = Registry:Get("eventKit", 1)
        assert.are.equal(future, loaded)
        assert.are.equal(future, selected)
        assert.are.equal(CURRENT_REVISION + 1, revision)
    end)
end)
