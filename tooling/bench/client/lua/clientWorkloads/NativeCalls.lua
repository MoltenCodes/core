--- Native calls: what `issecretvalue` and `securecallfunction` cost in the client.
---
--- On Retail 12.x the Kits ask `issecretvalue` about the values they handle and
--- isolate listeners with `securecallfunction`; CallbackHandler-1.0 isolates
--- with `securecallfunction` too. The host cannot price a native call (it has
--- only Lua stand-ins), so the host rows leave these costs out
--- (`docs/BENCHMARKS.md`). Here they are measured on their own, beside an empty
--- Lua call and `pcall` of the same empty function for scale.
---
--- Neither side's libraries are involved: both sides run exactly the same
--- calls, so the ratio of the two columns shows how much two sessions of the
--- same work differ — the noise floor of the in-client numbers.

local ClientBench = require("ClientBench")

local NativeCalls = {}

--- Calls per timed batch.
local ITERATIONS = 200000

local function empty() end

---@param first any
---@param second any
local function takesTwo(first, second)
  return first, second
end

---A client function, or the `Unsupported` error naming it.
---@param host table
---@param name string
---@return function
local function native(host, name)
  local found = host.Global(name)
  if type(found) ~= "function" then
    ClientBench.Unsupported(name .. ", which this client lacks")
  end
  return found
end

---A case that calls `call(argument)` `iterations` times and keeps the results observable.
---@param name string
---@param operation string
---@param build fun(): fun(): any the call to repeat, built in `prepare`
---@return Bench.Case
local function callCase(name, operation, build)
  return {
    name = name,
    iterations = ITERATIONS,
    operation = operation,
    prepare = function()
      local call = build()
      local truthy = 0
      return {
        run = function(iterations)
          for _ = 1, iterations do
            if call() then
              truthy = truthy + 1
            end
          end
        end,
        metrics = function()
          return { truthyResults = truthy }
        end,
      }
    end,
  }
end

---Build the workload; `side` changes nothing but which side addon is loaded.
---@param _ string
---@param host table the client host
---@return table suite `{ cases, checks, libraries }`
function NativeCalls.Build(_, host)
  local cases = {
    callCase("lua-call", "call an empty Lua function", function()
      return empty
    end),
    callCase("pcall", "pcall an empty Lua function", function()
      return function()
        return pcall(empty)
      end
    end),
    callCase("securecallfunction", "securecallfunction an empty Lua function", function()
      local secureCall = native(host, "securecallfunction")
      return function()
        return secureCall(empty)
      end
    end),
    callCase(
      "securecallfunction-arguments",
      "securecallfunction a Lua function with two arguments",
      function()
        local secureCall = native(host, "securecallfunction")
        return function()
          return secureCall(takesTwo, 1, "two")
        end
      end
    ),
    callCase("issecretvalue-number", "issecretvalue of a plain number", function()
      local isSecret = native(host, "issecretvalue")
      return function()
        return isSecret(42)
      end
    end),
    callCase("issecretvalue-string", "issecretvalue of a plain string", function()
      local isSecret = native(host, "issecretvalue")
      return function()
        return isSecret("Tester")
      end
    end),
    callCase("issecretvalue-table", "issecretvalue of a table", function()
      local isSecret = native(host, "issecretvalue")
      local value = {}
      return function()
        return isSecret(value)
      end
    end),
  }

  local function checks()
    local results = {}
    for _, name in ipairs({ "securecallfunction", "issecretvalue" }) do
      local present = type(host.Global(name)) == "function"
      results[#results + 1] = {
        name = name .. "-present",
        passed = present,
        detail = name .. (present and " is a client function" or " is absent on this client"),
        promised = false,
      }
    end
    return results
  end

  return { libraries = {}, cases = cases, checks = checks }
end

return NativeCalls
