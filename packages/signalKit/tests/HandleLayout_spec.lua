local TestEnv = require("SignalKitTestEnv")

local CURRENT_REVISION = 12

---Reduce the package state to the shape revisions 9 and 10 left behind:
---schema 5, no shared connection metatable.
---@param SignalKit table
local function toSchemaFive(SignalKit)
  local state = rawget(SignalKit, "_state")
  rawset(state, "schema", 5)
  rawset(state, "connectionMetatable", nil)
end

---The signal behind `topic` on `bus`.
---@param bus table
---@param topic string
---@return table
local function topicSignal(bus, topic)
  return rawget(rawget(rawget(bus, "_topics"), topic), "signal")
end

describe("SignalKit connection handle layout", function()
  local SignalKit

  before_each(function()
    SignalKit = TestEnv.NewPackage()
  end)

  after_each(TestEnv.Reset)

  it("keeps a new handle's fields in the array part, with the scope in the fifth slot", function()
    TestEnv.InstallHostErrorHandler()
    local signal = SignalKit:New()
    local function listener() end
    local connection = signal:Connect(listener)
    local bus = SignalKit:Bus("Layout", { openTopics = true })
    local scope = bus:CreateScope()
    local scoped = scope:Subscribe("Topic", listener)

    assert.are.equal(2, rawget(signal, "_layout"))
    assert.are.same(
      { listener, true, false, signal },
      { rawget(connection, 1), rawget(connection, 2), rawget(connection, 3), rawget(connection, 4) }
    )
    assert.is_nil(rawget(connection, "_connected"))
    assert.are.equal(scope, rawget(scoped, 5))
    assert.is_true(connection:Disconnect())
    assert.is_false(rawget(connection, 2))
    assert.is_nil(rawget(connection, 1))
    assert.is_nil(rawget(connection, 4))
    assert.is_true(scoped:Disconnect())
    assert.is_nil(rawget(scoped, 5))
  end)

  it("refuses connection methods on anything but a handle", function()
    local foreign = setmetatable({}, { __metatable = "locked" })
    for _, receiver in ipairs({ "text", 7, {}, foreign, { [2] = true } }) do
      TestEnv.expectErrorContaining(
        "SignalKit:Disconnect must be called on a connection handle",
        function()
          SignalKit.Connection.Disconnect(receiver)
        end
      )
      TestEnv.expectErrorContaining(
        "SignalKit:IsConnected must be called on a connection handle",
        function()
          SignalKit.Connection.IsConnected(receiver)
        end
      )
    end
  end)
end)

describe("SignalKit upgrade from named-field handles", function()
  after_each(TestEnv.Reset)

  ---Load the source as revision 10 and return it with a fresh bus.
  ---@return table SignalKit
  local function loadRevisionTen()
    TestEnv.Reset()
    TestEnv.InstallHostErrorHandler()
    require("Registry")
    return TestEnv.LoadRevision(CURRENT_REVISION - 1)
  end

  it("converts idle bus topic signals at load and keeps held handles working", function()
    local SignalKit = loadRevisionTen()
    local bus = SignalKit:Bus("Upgraded", { openTopics = true })
    local scope = bus:CreateScope()
    local order = {}
    local first = bus:Subscribe("Topic", function(value)
      order[#order + 1] = "first:" .. value
    end)
    local scoped = scope:Subscribe("Topic", function(value)
      order[#order + 1] = "scoped:" .. value
    end)
    local gone = bus:Subscribe("Topic", function() end)
    gone:Disconnect()
    local signal = topicSignal(bus, "Topic")
    TestEnv.ToNamedLayout(SignalKit, signal)
    -- The disconnected handle is no longer in the listener array.
    TestEnv.ToNamedLayout(SignalKit, { _listeners = { gone } })
    toSchemaFive(SignalKit)

    local upgraded = TestEnv.ReloadPackage()
    bus:Publish("Topic", "a")

    assert.are.equal(CURRENT_REVISION, upgraded.REVISION)
    assert.are.equal(6, rawget(rawget(upgraded, "_state"), "schema"))
    assert.are.equal(2, rawget(signal, "_layout"))
    assert.is_true(rawget(first, 2))
    assert.is_nil(rawget(first, "_connected"))
    assert.are.equal(scope, rawget(scoped, 5))
    assert.are.same({ "first:a", "scoped:a" }, order)
    assert.is_false(gone:IsConnected())
    assert.are.equal(1, scope:DisconnectAll())
    assert.is_false(scoped:IsConnected())
    assert.is_true(first:Disconnect())
    bus:Publish("Topic", "b")
    assert.are.same({ "first:a", "scoped:a" }, order)
  end)

  it("keeps a raw signal's named handles until an idle connect converts them in place", function()
    local SignalKit = loadRevisionTen()
    local signal = SignalKit:New()
    local order = {}
    local kept = signal:Connect(function()
      order[#order + 1] = "kept"
    end)
    local once = signal:Once(function()
      order[#order + 1] = "once"
    end)
    TestEnv.ToNamedLayout(SignalKit, signal)
    toSchemaFive(SignalKit)

    TestEnv.ReloadPackage()
    signal:Fire()
    assert.is_nil(rawget(signal, "_layout"))
    assert.is_false(once:IsConnected())
    assert.are.equal(false, rawget(once, "_connected"))

    local added = signal:Connect(function()
      order[#order + 1] = "added"
    end)
    signal:Fire()

    assert.are.equal(2, rawget(signal, "_layout"))
    assert.is_true(rawget(kept, 2))
    assert.are.equal(rawget(rawget(SignalKit, "_state"), "connectionMetatable"), getmetatable(kept))
    assert.are.same({ "kept", "once", "kept", "added" }, order)
    assert.is_true(kept:Disconnect())
    assert.is_true(added:Disconnect())
    assert.are.equal(0, #rawget(signal, "_listeners"))
  end)

  it("adds named handles to an older signal while a dispatch walks it, then converts", function()
    local SignalKit = loadRevisionTen()
    local signal = SignalKit:New()
    local order = {}
    local nested
    signal:Connect(function()
      order[#order + 1] = "outer"
      if nested == nil then
        nested = signal:Connect(function()
          order[#order + 1] = "nested"
        end)
      end
    end)
    TestEnv.ToNamedLayout(SignalKit, signal)
    toSchemaFive(SignalKit)
    TestEnv.ReloadPackage()

    signal:Fire()
    assert.is_nil(rawget(signal, "_layout"))
    assert.is_true(rawget(nested, "_connected"))
    signal:Fire()
    assert.are.same({ "outer", "outer", "nested" }, order)

    signal:Connect(function() end)
    assert.are.equal(2, rawget(signal, "_layout"))
    assert.is_true(rawget(nested, 2))
    assert.is_true(nested:Disconnect())
  end)

  it("never converts a signal from before revision 9, which has no depth", function()
    local SignalKit = loadRevisionTen()
    local signal = SignalKit:New()
    local calls = 0
    local held = signal:Connect(function()
      calls = calls + 1
    end)
    TestEnv.ToNamedLayout(SignalKit, signal)
    rawset(signal, "_firing", nil)
    toSchemaFive(SignalKit)
    TestEnv.ReloadPackage()

    local added = signal:Connect(function()
      calls = calls + 10
    end)
    signal:Fire()

    assert.is_nil(rawget(signal, "_layout"))
    assert.is_true(rawget(added, "_connected"))
    assert.are.equal(11, calls)
    assert.is_true(held:Disconnect())
    assert.are.equal(1, signal:DisconnectAll())
  end)
end)
