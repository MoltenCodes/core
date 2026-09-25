--- Cases and correctness checks shared by the two dispatch workloads.
---
--- Game events (EventKit against AceEvent-3.0 events) and addon messages
--- (a SignalKit bus against AceEvent-3.0 messages) are measured with the same
--- cases and the same checks. Each side describes itself through an adapter,
--- so the cases below cannot drift apart between sides:
---
---   adapter.connect(callback) -> token    subscribe one listener
---   adapter.disconnect(token)             remove that listener
---   adapter.fire(...)                     deliver one event or message
---   adapter.hotFire() -> fire(...)        the cheapest faithful way to
---                                         deliver, resolved once, for timing
---
--- A listener receives the event or message name first and then the payload
--- on every side except the SignalKit bus, which passes the payload alone;
--- the listeners below ignore their arguments' positions, so that difference
--- costs nothing either way.

local Dispatch = {}

--- The listener counts every dispatch case is measured at.
Dispatch.LISTENER_COUNTS = { 1, 10, 100 }

--- Dispatches per timed batch, by listener count, so that each batch does
--- about the same number of listener calls.
local DISPATCH_ITERATIONS = { [1] = 200000, [10] = 50000, [100] = 5000 }

--- Connect-and-disconnect pairs per timed batch.
local CHURN_ITERATIONS = 20000

---Build the timing cases for one side.
---@param adapter table the side's adapter (see the top of this file)
---@param describe string what one dispatch delivers, for the report
---@return Bench.Case[]
function Dispatch.Cases(adapter, describe)
  local cases = {}

  for _, listenerCount in ipairs(Dispatch.LISTENER_COUNTS) do
    cases[#cases + 1] = {
      name = "dispatch-" .. listenerCount,
      iterations = DISPATCH_ITERATIONS[listenerCount],
      operation = describe .. " to " .. listenerCount .. " listener(s)",
      prepare = function()
        local calls, dispatches = 0, 0
        local function listener()
          calls = calls + 1
        end
        for _ = 1, listenerCount do
          adapter.connect(listener)
        end
        local fire = adapter.hotFire()
        return {
          run = function(iterations)
            for _ = 1, iterations do
              fire("player", "MANA")
            end
            dispatches = dispatches + iterations
          end,
          -- A sanity check on the measurement itself: every dispatch must
          -- have reached every listener.
          metrics = function()
            return { listenerCallsPerDispatch = calls / dispatches }
          end,
        }
      end,
    }
  end

  -- Connecting next to listeners that already exist: no host registration
  -- changes, only the library's own bookkeeping.
  cases[#cases + 1] = {
    name = "churn-warm",
    iterations = CHURN_ITERATIONS,
    operation = "connect and disconnect one listener beside 10 others",
    prepare = function()
      local function listener() end
      for _ = 1, 10 do
        adapter.connect(listener)
      end
      return {
        run = function(iterations)
          for _ = 1, iterations do
            adapter.disconnect(adapter.connect(listener))
          end
        end,
      }
    end,
  }

  -- The first listener and the last: for game events this registers and
  -- unregisters the event on the host frame every time.
  cases[#cases + 1] = {
    name = "churn-cold",
    iterations = CHURN_ITERATIONS,
    operation = "connect and disconnect the only listener",
    prepare = function()
      local function listener() end
      return {
        run = function(iterations)
          for _ = 1, iterations do
            adapter.disconnect(adapter.connect(listener))
          end
        end,
      }
    end,
  }

  return cases
end

---@param name string
---@param passed boolean
---@param detail string
---@param promised boolean? `false` when the library does not promise the behaviour
---@return table
local function check(name, passed, detail, promised)
  return { name = name, passed = passed, detail = detail, promised = promised ~= false }
end

---Run the reentrancy and isolation checks through an adapter.
---
---Every check builds its own listeners and removes them afterwards, so the
---checks are independent of each other's order.
---@param adapter table
---@param host table the benchmark host, for reported errors
---@param ordered boolean whether this side promises delivery in connection order
---@return table[]
function Dispatch.Checks(adapter, host, ordered)
  local results = {}

  -- A listener connected during a dispatch starts with the next dispatch.
  do
    local lateCalls, tokens, connected = 0, {}, false
    tokens[1] = adapter.connect(function()
      if not connected then
        connected = true
        tokens[2] = adapter.connect(function()
          lateCalls = lateCalls + 1
        end)
      end
    end)
    adapter.fire("player", "MANA")
    local duringFirst = lateCalls
    adapter.fire("player", "MANA")
    for index = 1, #tokens do
      adapter.disconnect(tokens[index])
    end
    results[#results + 1] = check(
      "connect-during-dispatch-waits",
      duringFirst == 0 and lateCalls == 1,
      "late listener calls: "
        .. duringFirst
        .. " in the dispatch that added it, "
        .. lateCalls
        .. " after the next"
    )
  end

  -- A listener disconnected by an earlier one in the same dispatch does not run.
  do
    local ran, tokens = 0, {}
    for index = 1, 3 do
      tokens[index] = adapter.connect(function()
        ran = ran + 1
        for other = 1, 3 do
          if tokens[other] ~= nil then
            adapter.disconnect(tokens[other])
            tokens[other] = nil
          end
        end
      end)
    end
    adapter.fire("player", "MANA")
    results[#results + 1] = check(
      "disconnect-during-dispatch-skips",
      ran == 1,
      "listeners that ran after the first removed all: " .. ran
    )
  end

  -- A dispatch started from a listener reaches every listener, and the outer
  -- dispatch then finishes.
  do
    local calls, nested, tokens = 0, false, {}
    for index = 1, 3 do
      tokens[index] = adapter.connect(function()
        calls = calls + 1
        if not nested then
          nested = true
          adapter.fire("player", "MANA")
        end
      end)
    end
    adapter.fire("player", "MANA")
    for index = 1, #tokens do
      adapter.disconnect(tokens[index])
    end
    results[#results + 1] = check(
      "nested-dispatch",
      calls == 6,
      "listener calls for one outer and one nested dispatch: " .. calls .. " of 6"
    )
  end

  -- A listener that raises does not stop the others, and the error is reported.
  do
    host.TakeReportedErrors()
    local after, tokens = 0, {}
    tokens[1] = adapter.connect(function()
      error("benchmark listener failure", 0)
    end)
    tokens[2] = adapter.connect(function()
      after = after + 1
    end)
    local ok = pcall(adapter.fire, "player", "MANA")
    local reported = #host.TakeReportedErrors()
    for index = 1, #tokens do
      adapter.disconnect(tokens[index])
    end
    results[#results + 1] = check(
      "error-isolated",
      ok and after == 1 and reported == 1,
      "dispatch returned normally: "
        .. tostring(ok)
        .. ", other listener ran: "
        .. after
        .. ", errors reported: "
        .. reported
    )
  end

  -- Delivery order equals connection order.
  do
    local order, tokens = {}, {}
    for index = 1, 8 do
      tokens[index] = adapter.connect(function()
        order[#order + 1] = index
      end)
    end
    adapter.fire("player", "MANA")
    for index = 1, #tokens do
      adapter.disconnect(tokens[index])
    end
    local inOrder = #order == 8
    for index = 1, #order do
      inOrder = inOrder and order[index] == index
    end
    results[#results + 1] = check(
      "connection-order",
      inOrder,
      "delivery order of 8 listeners: " .. table.concat(order, " "),
      ordered
    )
  end

  return results
end

return Dispatch
