local TestEnv = require("EventKitTestEnv")

---The implementation revision `src/EventKit.lua` carries; `Manifest_spec.lua`
---pins the same number against `package.manifest.json`.
local CURRENT_REVISION = 23

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
    Reopen = stub,
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
  EventKit.IsCombatLogAvailable = stub
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

describe("EventKit package bootstrap", function()
  after_each(TestEnv.Reset)

  it("requires Registry to load first", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    expectErrorContaining("requires Registry API 2", function()
      require("EventKit")
    end)
  end)

  it("loads and serves Connect with no SignalKit registered", function()
    local ok, EventKit = TestEnv.NewPackageWithout("SignalKit")
    assert.is_true(ok)
    local calls = 0
    EventKit:Connect("PLAYER_LOGIN", function()
      calls = calls + 1
    end)
    EventKit:ForAddon("MyAddon"):Connect("PLAYER_LOGIN", function()
      calls = calls + 1
    end)
    TestEnv.Emit("PLAYER_LOGIN")
    assert.are.equal(2, calls)
    assert.is_false(EventKit:HasPart("Coalescing"))
  end)

  it("refuses to upgrade a revision below the upgrade floor in place", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    require("Registry")
    TestEnv.LoadSourceAtRevision(21)
    expectErrorContaining("upgrades revision 22 or newer in place, not revision 21", function()
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
    -- A table limit key is named by its type, never by `__tostring`.
    local key = setmetatable({}, {
      __tostring = function()
        error("foreign __tostring ran", 0)
      end,
    })
    expectErrorContaining(
      "EventKit:SetLimits limits.<table> is not a recognised limit; it accepts maxUnitFrames",
      function()
        EventKit:SetLimits({ [key] = 1 })
      end
    )
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

  it("disconnects an unscoped handle, which has no scope slots", function()
    local EventKit = TestEnv.NewPackage()
    local calls = 0
    local connection = EventKit:Connect("PLAYER_LOGIN", function()
      calls = calls + 1
    end)

    -- Like a handle revisions before scopes made, it carries no scope link.
    assert.is_nil(rawget(connection, 5))
    assert.is_nil(rawget(connection, "_scope"))

    assert.is_true(connection:Disconnect())
    TestEnv.Emit("PLAYER_LOGIN")
    assert.are.equal(0, calls)
  end)

  it("refuses connection receivers that are not handles, at the caller's line", function()
    local EventKit = TestEnv.NewPackage()
    local connection = EventKit:Connect("BAG_UPDATE", function() end)
    local foreign = setmetatable({}, { __index = EventKit.Connection })
    for _, receiver in ipairs({ "text", 42, foreign, {} }) do
      local ok, message = pcall(function()
        connection.Disconnect(receiver)
      end)
      assert.is_false(ok)
      assert.is_not_nil(
        string.find(tostring(message), "EventKit:Disconnect must be called", 1, true)
      )
      assert.is_not_nil(string.find(tostring(message), "Bootstrap_spec.lua:", 1, true))
      ok, message = pcall(function()
        connection.IsConnected(receiver)
      end)
      assert.is_false(ok)
      assert.is_not_nil(
        string.find(tostring(message), "EventKit:IsConnected must be called", 1, true)
      )
    end
    assert.is_true(connection:IsConnected())
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
