local TestEnv = require("SignalKitTestEnv")

local SPEC_FILE = "packages/signalKit/tests/Hooks_spec.lua:"

---Assert that `callback` raises a message naming `expected` at this spec file's
---line rather than somewhere inside the package.
---@param expected string
---@param callback fun()
local function expectRefusalAtCaller(expected, callback)
  TestEnv.ExpectRefusalAtCaller(SPEC_FILE, expected, callback)
end

describe("SignalKit onFirst and onLast hooks", function()
  local SignalKit
  local log

  ---Create a signal whose hooks append to `log`, with the signal they got.
  ---@return table signal
  local function newObservedSignal()
    local signal
    signal = SignalKit:New({
      onFirst = function(observed)
        log[#log + 1] = "first"
        assert.are.equal(signal, observed)
      end,
      onLast = function(observed)
        log[#log + 1] = "last"
        assert.are.equal(signal, observed)
      end,
    })
    return signal
  end

  before_each(function()
    SignalKit = TestEnv.NewPackage()
    log = {}
  end)

  after_each(TestEnv.Reset)

  describe("options", function()
    it("accepts no options, an empty table and either hook alone", function()
      assert.is_not_nil(SignalKit:New())
      assert.is_not_nil(SignalKit.New())
      assert.is_not_nil(SignalKit:New({}))
      assert.is_not_nil(SignalKit:New({ onFirst = function() end }))
      assert.is_not_nil(SignalKit:New({ onLast = function() end }))
    end)

    it("refuses a non-table and a non-function hook at the caller", function()
      expectRefusalAtCaller("SignalKit:New options must be a table or nil", function()
        SignalKit:New("options")
      end)
      expectRefusalAtCaller("SignalKit:New options.onFirst must be a function or nil", function()
        SignalKit:New({ onFirst = true })
      end)
      expectRefusalAtCaller("SignalKit:New options.onLast must be a function or nil", function()
        SignalKit:New({ onLast = "hook" })
      end)
    end)

    it("refuses options passed with a dot call instead of ignoring them", function()
      expectRefusalAtCaller(
        "SignalKit:New options must be passed with a colon call: SignalKit:New(options)",
        function()
          SignalKit.New({ onFirst = function() end })
        end
      )
    end)

    it("does not mistake a signal receiver for misplaced options", function()
      local signal = SignalKit:New({ onFirst = function() end })
      assert.is_not_nil(signal:New())
    end)
  end)

  describe("transitions", function()
    it("runs onFirst on 0 to 1 and onLast on 1 to 0, never in between", function()
      local signal = newObservedSignal()

      local first = signal:Connect(function() end)
      assert.are.same({ "first" }, log)
      local second = signal:Connect(function() end)
      assert.are.same({ "first" }, log)

      first:Disconnect()
      assert.are.same({ "first" }, log)
      second:Disconnect()
      assert.are.same({ "first", "last" }, log)

      -- A repeated disconnect is not a transition.
      assert.is_false(second:Disconnect())
      assert.are.same({ "first", "last" }, log)
    end)

    it("runs again for every later cycle", function()
      local signal = newObservedSignal()
      for _ = 1, 3 do
        signal:Connect(function() end):Disconnect()
      end
      assert.are.same({ "first", "last", "first", "last", "first", "last" }, log)
    end)

    it("runs after the listener is in place and after it is released", function()
      local disconnectedInHook
      local signal
      signal = SignalKit:New({
        onFirst = function(observed)
          assert.are.equal(1, observed:DisconnectAll())
        end,
        onLast = function(observed)
          disconnectedInHook = observed:DisconnectAll()
        end,
      })

      local connection = signal:Connect(function() end)

      -- onFirst saw and disconnected the new listener, which made onLast
      -- run with nothing left to disconnect.
      assert.is_false(connection:IsConnected())
      assert.are.equal(0, disconnectedInHook)
    end)

    it("counts a Once listener until it disconnects, before its callback runs", function()
      local signal = newObservedSignal()
      local logAtCallback

      signal:Once(function()
        logAtCallback = #log
      end)
      assert.are.same({ "first" }, log)

      signal:Fire()

      assert.are.same({ "first", "last" }, log)
      assert.are.equal(2, logAtCallback)
    end)

    it("runs onLast once for DisconnectAll, and not for an empty signal", function()
      local signal = newObservedSignal()
      assert.are.equal(0, signal:DisconnectAll())
      assert.are.same({}, log)

      for _ = 1, 3 do
        signal:Connect(function() end)
      end
      assert.are.equal(3, signal:DisconnectAll())
      assert.are.same({ "first", "last" }, log)
    end)

    it("is not applied to bus topic signals", function()
      local bus = SignalKit:Bus("Plain", { openTopics = true })
      local connection = bus:Subscribe("Topic", function() end)
      connection:Disconnect()
      assert.are.same({}, log)
    end)
  end)

  describe("re-entrancy", function()
    it("lets onFirst connect another listener without running again", function()
      local signal
      signal = SignalKit:New({
        onFirst = function()
          log[#log + 1] = "first"
          signal:Connect(function()
            log[#log + 1] = "hook listener"
          end)
        end,
        onLast = function()
          log[#log + 1] = "last"
        end,
      })

      local connection = signal:Connect(function()
        log[#log + 1] = "listener"
      end)
      signal:Fire()
      connection:Disconnect()

      assert.are.same({ "first", "listener", "hook listener" }, log)
      assert.are.equal(1, signal:DisconnectAll())
      assert.are.same({ "first", "listener", "hook listener", "last" }, log)
    end)

    it("lets onLast connect again, which runs onFirst inside it", function()
      local signal
      local reconnected = false
      signal = SignalKit:New({
        onFirst = function()
          log[#log + 1] = "first"
        end,
        onLast = function()
          log[#log + 1] = "last"
          if not reconnected then
            reconnected = true
            signal:Connect(function() end)
          end
        end,
      })

      local connection = signal:Connect(function() end)
      assert.is_true(connection:Disconnect())

      assert.are.same({ "first", "last", "first" }, log)
      assert.are.equal(1, signal:DisconnectAll())
      assert.are.same({ "first", "last", "first", "last" }, log)
    end)

    it("lets the last Once callback reconnect during Fire", function()
      local signal = newObservedSignal()
      signal:Once(function()
        signal:Connect(function() end)
      end)

      signal:Fire()

      assert.are.same({ "first", "last", "first" }, log)
    end)

    it("does not run onLast while a listener remains live during a dispatch", function()
      local signal
      local calls = {}
      signal = SignalKit:New({
        onLast = function()
          log[#log + 1] = "last"
        end,
      })
      local second
      signal:Connect(function()
        calls[#calls + 1] = "first"
        second:Disconnect()
      end)
      second = signal:Connect(function()
        calls[#calls + 1] = "second"
      end)

      signal:Fire()

      assert.are.same({ "first" }, calls)
      assert.are.same({}, log)
      assert.are.equal(1, signal:DisconnectAll())
      assert.are.same({ "last" }, log)
    end)
  end)

  describe("errors", function()
    it(
      "propagates an onFirst error to the caller of Connect, leaving the listener connected",
      function()
        local signal = SignalKit:New({
          onFirst = function()
            error("cannot activate")
          end,
        })

        local ok, message = pcall(function()
          signal:Connect(function() end)
        end)

        assert.is_false(ok)
        assert.is_not_nil(string.find(tostring(message), "cannot activate", 1, true))
        assert.are.equal(1, signal:DisconnectAll())
      end
    )

    it(
      "propagates an onLast error to the caller of Disconnect after the disconnect took effect",
      function()
        local signal = SignalKit:New({
          onLast = function()
            error("cannot deactivate")
          end,
        })
        local connection = signal:Connect(function() end)

        local ok, message = pcall(function()
          connection:Disconnect()
        end)

        assert.is_false(ok)
        assert.is_not_nil(string.find(tostring(message), "cannot deactivate", 1, true))
        assert.is_false(connection:IsConnected())
        assert.are.equal(0, signal:DisconnectAll())
      end
    )

    it(
      "propagates an onLast error to the caller of Fire when a Once listener was the last",
      function()
        local signal = SignalKit:New({
          onLast = function()
            error("cannot deactivate")
          end,
        })
        local calls = 0
        signal:Once(function()
          calls = calls + 1
        end)

        local ok, message = pcall(function()
          signal:Fire()
        end)

        assert.is_false(ok)
        assert.is_not_nil(string.find(tostring(message), "cannot deactivate", 1, true))
        assert.are.equal(0, calls)
      end
    )

    it("aborts the dispatch when onLast raises inside Fire, after a journal recorded it", function()
      local journal = SignalKit:NewJournal(2, {
        onLast = function()
          error("cannot deactivate")
        end,
      })
      local calls = {}
      local earlier = journal:Connect(function()
        calls[#calls + 1] = "earlier"
      end)
      journal:Once(function()
        calls[#calls + 1] = "once"
      end)
      earlier:Disconnect()

      local ok, message = pcall(function()
        journal:Fire("recorded")
      end)

      assert.is_false(ok)
      assert.is_not_nil(string.find(tostring(message), "cannot deactivate", 1, true))
      -- The Once listener was the last live one: its callback did not run,
      -- nothing follows it, and the firing is recorded and counted.
      assert.are.same({}, calls)
      assert.are.equal(1, journal:GetGeneration())
      local recorded = {}
      for _, entry in journal:History() do
        recorded[#recorded + 1] = entry[1]
      end
      assert.are.same({ "recorded" }, recorded)
      assert.are.equal(0, journal:DisconnectAll())
    end)
  end)
end)
