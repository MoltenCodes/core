-- Behaviour of the shared helpers of tooling/shared/lua/ on host Lua 5.1.
--
-- Run by tooling/tests/test_shared_sync.py as `lua behaviour.lua <sources dir>`.
-- Each source is loaded the way a Kit carries it: its body with `__FACADE__`
-- replaced, after stand-ins for the blocks it requires, so what is tested is
-- the copied text and not the stand-ins. A failed check raises, and the
-- process exits non-zero with the message; success prints "ok".

local sourcesDirectory = assert(arg[1], "usage: lua behaviour.lua <tooling/shared/lua>")

---The body of one source, between `-- shared:body` and `-- shared:exports`.
---@param name string
---@return string
local function body(name)
  local file = assert(io.open(sourcesDirectory .. "/" .. name .. ".lua", "r"))
  local text = file:read("*a")
  file:close()
  local start = assert(text:find("-- shared:body\n", 1, true), name .. ": no body marker")
  local finish = assert(text:find("-- shared:exports\n", 1, true), name .. ": no exports marker")
  return text:sub(start + #"-- shared:body\n", finish - 1)
end

---Load `names` in order as one chunk (as a Kit's file holds them) and return
---the helpers the last one defines, plus whatever `prelude` declares.
---@param names string[]
---@param prelude string Lua declaring what the Kit declares before the blocks
---@param exports string a Lua table constructor naming the locals to hand back
---@return table
local function load(names, prelude, exports)
  local parts = { prelude }
  for _, name in ipairs(names) do
    parts[#parts + 1] = (body(name):gsub("__FACADE__", "TestKit"))
  end
  parts[#parts + 1] = "return " .. exports
  local chunk = assert(loadstring(table.concat(parts, "\n"), "=Shared"))
  return chunk()
end

---Raise unless `callback` raises with a message containing `expected`, and
---report where the error was attributed.
---@param expected string
---@param callback function
---@return string message
local function expectError(expected, callback)
  local ok, message = pcall(callback)
  assert(not ok, "expected an error containing: " .. expected)
  assert(
    tostring(message):find(expected, 1, true),
    "expected '" .. expected .. "' in: " .. tostring(message)
  )
  return message
end

-- selene: allow(global_usage)
local globals = _G

-- isSecret: the probe rule ------------------------------------------------------

do
  local secret = {}
  rawset(globals, "issecretvalue", function(value)
    return value == secret
  end)
  local helpers = load({ "isSecret" }, "", "{ isSecret = isSecret }")
  assert(helpers.isSecret(secret) == true, "a probe present at load answers")
  assert(helpers.isSecret({}) == false, "a plain value is not secret")
  rawset(globals, "issecretvalue", nil)
  assert(helpers.isSecret(secret) == true, "the probe resolved at load is kept")
end

do
  rawset(globals, "issecretvalue", nil)
  local helpers = load({ "isSecret" }, "", "{ isSecret = isSecret }")
  assert(helpers.isSecret("x") == false, "no probe: nothing is secret")
  rawset(globals, "issecretvalue", "not a function")
  assert(helpers.isSecret("x") == false, "a probe that is not a function is ignored")
  rawset(globals, "issecretvalue", function()
    return 1
  end)
  assert(helpers.isSecret("x") == false, "only a true answer counts: a strict boolean")
  rawset(globals, "issecretvalue", function()
    return true
  end)
  assert(helpers.isSecret("x") == true, "a probe installed after load is honoured")
  rawset(globals, "issecretvalue", nil)
end

-- reportError ----------------------------------------------------------------------

do
  local helpers = load({ "reportError" }, "", "{ reportError = reportError }")
  local handled = nil
  rawset(globals, "geterrorhandler", function()
    return function(failure)
      handled = failure
    end
  end)
  helpers.reportError("boom")
  assert(handled == "boom", "the host handler receives the failure unchanged")

  local printed = nil
  local originalPrint = print
  rawset(globals, "print", function(value)
    printed = value
  end)
  rawset(globals, "geterrorhandler", function()
    return function()
      error("the handler itself fails")
    end
  end)
  helpers.reportError("second")
  assert(printed == "second", "a raising handler falls back to print")
  printed = nil
  rawset(globals, "geterrorhandler", nil)
  helpers.reportError("third")
  assert(printed == "third", "no handler: printed")
  rawset(globals, "print", originalPrint)
end

-- describeKey ----------------------------------------------------------------------

do
  local secret = {}
  rawset(globals, "issecretvalue", function(value)
    return value == secret
  end)
  local helpers =
    load({ "isSecret", "describeKey" }, "", "{ describeKey = describeKey, isSecret = isSecret }")
  assert(helpers.describeKey("name") == "name", "a string as written")
  assert(helpers.describeKey(3) == "3", "a number through tostring")
  assert(helpers.describeKey(true) == "true", "a boolean through tostring")
  assert(helpers.describeKey(secret) == "<secret>", "a secret is never shown")
  local ran = false
  local hostile = setmetatable({}, {
    __tostring = function()
      ran = true
      error("caller code")
    end,
  })
  assert(helpers.describeKey(hostile) == "<table>", "a table by its type")
  assert(not ran, "a key's __tostring never runs")
  assert(helpers.describeKey(print) == "<function>", "a function by its type")
  rawset(globals, "issecretvalue", nil)
end

-- validateFacade ---------------------------------------------------------------------

do
  local helpers = load(
    { "validateFacade" },
    "local TestKit = {}",
    "{ validateFacade = validateFacade, TestKit = TestKit }"
  )
  helpers.validateFacade(helpers.TestKit, "TestKit:Do", 2)
  local function callWith(receiver)
    helpers.validateFacade(receiver, "TestKit:Do", 3)
  end
  local message = expectError(
    "TestKit:Do must be called on the TestKit facade; use TestKit:Do(...)",
    function()
      callWith({}) -- the line the error names
    end
  )
  assert(message:find("behaviour.lua:", 1, true), "attributed to the caller: " .. message)
  expectError("must be called on the TestKit facade", function()
    callWith("TestKit")
  end)
end

-- limits ---------------------------------------------------------------------------------

do
  local secret = {}
  rawset(globals, "issecretvalue", function(value)
    return value == secret
  end)
  local prelude = table.concat({
    "local UNBOUNDED = setmetatable({}, { __tostring = function() return 'UNBOUNDED' end })",
    "local crossChecks = 0",
    "local LIMIT_RULES = {",
    "  { name = 'maxItems', ceiling = 10 },",
    "  { name = 'ttl', ceiling = 60, minimum = 0.5, integer = false },",
    "  { name = 'maxOpen', ceiling = 100, unbounded = true },",
    "  { name = 'ring', ceiling = 8, unboundedReason = 'it is allocated',",
    "    check = function(value, level)",
    "      crossChecks = crossChecks + 1",
    "      if value == 7 then error('ring cannot be 7', level) end",
    "    end },",
    "}",
  }, "\n")
  local helpers = load(
    { "isSecret", "describeKey", "limits" },
    prelude,
    "{ validate = validateLimitUpdate, apply = applyLimitUpdate, copy = copyLimits,"
      .. " UNBOUNDED = UNBOUNDED, crossChecks = function() return crossChecks end }"
  )
  local function set(update)
    helpers.validate(update, 3)
  end

  set({ maxItems = 1, ttl = 0.5, maxOpen = helpers.UNBOUNDED, ring = 8 })
  set({ maxItems = 10, ttl = 60, maxOpen = 100 })
  assert(helpers.crossChecks() == 1, "a rule's own check runs")

  expectError("TestKit:SetLimits limits must be a table", function()
    set("nope")
  end)
  expectError("TestKit:SetLimits limits must be a table", function()
    set(secret)
  end)
  expectError(
    "limits.other is not a recognised limit; it accepts maxItems, ttl, maxOpen, ring",
    function()
      set({ other = 1 })
    end
  )
  local ran = false
  local hostile = setmetatable({}, {
    __tostring = function()
      ran = true
      return "x"
    end,
  })
  expectError("limits.<table> is not a recognised limit", function()
    set({ [hostile] = 1 })
  end)
  assert(not ran, "a key's __tostring never runs")
  expectError("limits.1.5 is not a recognised limit", function()
    set({ [1.5] = 1 })
  end)
  expectError("limits.maxItems must not be a secret value", function()
    set({ maxItems = secret })
  end)
  expectError("limits.maxItems must be an integer from 1 to 10", function()
    set({ maxItems = 11 })
  end)
  expectError("limits.maxItems must be an integer from 1 to 10", function()
    set({ maxItems = 0 })
  end)
  expectError("limits.maxItems must be an integer from 1 to 10", function()
    set({ maxItems = 2.5 })
  end)
  expectError("limits.maxItems must be an integer from 1 to 10", function()
    set({ maxItems = 0 / 0 })
  end)
  expectError("limits.maxItems must be an integer from 1 to 10", function()
    set({ maxItems = "3" })
  end)
  expectError("limits.ttl must be a number from 0.5 to 60", function()
    set({ ttl = 0.25 })
  end)
  expectError("limits.maxItems cannot be TestKit.UNBOUNDED", function()
    set({ maxItems = helpers.UNBOUNDED })
  end)
  expectError("limits.ring cannot be TestKit.UNBOUNDED: it is allocated", function()
    set({ ring = helpers.UNBOUNDED })
  end)
  local message = expectError("ring cannot be 7", function()
    set({ ring = 7 })
  end)
  assert(
    message:find("behaviour.lua:", 1, true),
    "a rule's check raises at the caller: " .. message
  )
  message = expectError("must be an integer", function()
    set({ maxItems = 99 })
  end)
  assert(message:find("behaviour.lua:", 1, true), "attributed to the caller: " .. message)

  local shared = { maxItems = 5, ttl = 30, maxOpen = 10, ring = 4 }
  helpers.apply(shared, { maxItems = 2 })
  assert(shared.maxItems == 2 and shared.ttl == 30, "only the given names are written")
  local first, second = helpers.copy(shared), helpers.copy(shared)
  assert(first ~= second, "a fresh table every call")
  assert(first.maxItems == 2 and first.ring == 4, "the copy holds every limit")
  rawset(globals, "issecretvalue", nil)
end

print("ok")
