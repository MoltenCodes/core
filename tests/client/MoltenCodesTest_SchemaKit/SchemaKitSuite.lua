-- MoltenCodes Test: SchemaKitSuite.lua
--
-- Real-client suites for the `schemaKit` package. SchemaKit is pure Lua, so
-- the Busted specs under packages/schemaKit/tests/ already prove its rules on
-- a stock Lua 5.1. What only the game client can show is how those rules meet
-- the client's own Lua and the values the client hands out:
--
--   * the installed facade and its committed revision, and the session's
--     shared limits;
--   * the client's Lua: the pattern rule agrees with the client's own
--     `string.find` on every subject tried, each malformed pattern the
--     client's matcher raises on (only when a subject reaches the broken part)
--     is refused when the node is built, the 32-capture ceiling is the
--     client's, bounds are printed by the client's `%.14g`, and string bounds
--     count the bytes of the client's UTF-8 text;
--   * real host values: `GetBuildInfo()`, `C_Spell.GetSpellInfo(6603)` (Auto
--     Attack), and a Frame (`UIParent`) with its userdata handle, which a
--     schema reads with `rawget` and describes by type, never by value;
--   * that the documented allocation-free paths (`Check` and `Assert` of a
--     valid value, and a `Check` failing at the root with a fixed phrase)
--     allocate nothing on the client's own collector;
--   * argument errors pointing at this file as the client names it;
--   * secret values made by the client's `secretwrap`: refused by every node
--     kind with rule `secret` before anything compares them, described as
--     `secret value`, never in a failure or an `Assert` message, and refused
--     by `SetLimits`, with no "attempt to compare" error escaping.
--
-- Nothing here needs combat, a group or an instance, nothing is visible, no
-- client setting changes, and no request goes to the server: the build facts
-- and the spell data come from the client's own data.
--
-- Run with `/mct run schemaKit`; tests/client/MoltenCodesTest_SchemaKit/EXPECTED.md
-- lists what the chat frame should show.
--
-- What a run leaves behind. Nodes and schemas are plain Lua tables that the
-- collector frees once a test drops them; SchemaKit's private weak tables let
-- it. The shared limits are never changed: every `SetLimits` call here is a
-- refusal the test checks, and each test compares `GetLimits` before and after.
-- Nothing is written to a global or a saved variable, and no Frame is created.

local addonName = ...

-- The harness is this addon's dependency and publishes one documented global.
-- selene: allow(global_usage)
local Harness = rawget(_G, "MoltenCodesTest")
-- The shared MoltenCodes namespace is the one documented global handoff point.
-- selene: allow(global_usage)
local namespace = rawget(_G, "MoltenCodes")
if type(Harness) ~= "table" or type(namespace) ~= "table" then
  error(addonName .. " requires the MoltenCodesTest harness and the MoltenCodes addon", 0)
end

local REGISTRY_API = 2
local SCHEMA_KIT_API = 1
local PACKAGE_ID = "schemaKit"

--- Auto Attack: a spell every character knows, answered from the client's own data.
local AUTO_ATTACK_SPELL_ID = 6603

--- The ceiling of `maxPatternCaptures` and the default: Lua 5.1's `LUA_MAXCAPTURES`.
local MAX_PATTERN_CAPTURES = 32

--- How many cycles each allocation guard runs. One table or string per cycle
--- would cost well over a hundred kilobytes at this count.
local ALLOCATION_CYCLES = 5000

--- Kilobytes an allocation guard tolerates. The tolerance absorbs a stray
--- allocation by the client between the two readings, not a per-cycle one.
local ALLOCATION_TOLERANCE_KB = 1

--- The text inside the secret string the secrets tests make. A failure or an
--- `Assert` message that contained the secret would contain this text.
local SECRET_TEXT = "MoltenCodesSecretText"

--- The number inside the secret numbers the secrets tests make; no bound or
--- phrase in this file contains its digits.
local SECRET_NUMBER = 4242

--- "Épée" in UTF-8: four characters in six bytes.
local UTF8_WORD = "\195\137p\195\169e"

-- Resolving the client and the framework ---------------------------------------------

---Read a client global, or `nil`.
---@param name string
---@return any
local function readHost(name)
  -- The build facts, spell data, UIParent and the secret-value functions
  -- are World of Warcraft client globals, reachable only through the global
  -- table.
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

---Read a function from a client namespace table such as `C_Spell`, or `nil`.
---@param namespaceName string
---@param functionName string
---@return function|nil
local function readHostFunction(namespaceName, functionName)
  local hostNamespace = readHost(namespaceName)
  if type(hostNamespace) ~= "table" then
    return nil
  end
  local candidate = hostNamespace[functionName]
  if type(candidate) ~= "function" then
    return nil
  end
  return candidate
end

---@type Registry
local Registry = rawget(rawget(namespace, "Registries") or {}, REGISTRY_API)
if type(Registry) ~= "table" then
  error(addonName .. " requires the MoltenCodes addon (Registry API 2); reinstall it", 0)
end

-- SchemaKit is not in the language-server workspace of tests/client (its
-- .luarc.json lists TestKit's dependency closure only), so its facade, nodes
-- and schemas are typed `any` here.

---@type any
local SchemaKit = Registry:Get(PACKAGE_ID, SCHEMA_KIT_API)
if type(SchemaKit) == "nil" then
  error(addonName .. " requires SchemaKit API 1 in the MoltenCodes addon; reinstall it", 0)
end
local S = SchemaKit

--- The Frame the host-value tests read. Retail, Classic Era and Mists Classic all have it.
local uiParent = readHost("UIParent")
if type(uiParent) ~= "table" then
  error(addonName .. " requires the client's UIParent", 0)
end

--- Read once at load: the secrets suite registers its tests as skipped when
--- the client cannot make a secret value.
local isSecretValue = readHost("issecretvalue")
local secretWrap = readHost("secretwrap")
local SECRETS_AVAILABLE = type(isSecretValue) == "function" and type(secretWrap) == "function"

---Whether `value` is a secret. `false` on a client without `issecretvalue`.
---@param value any
---@return boolean
local function isSecret(value)
  return SECRETS_AVAILABLE and isSecretValue(value) == true
end

---Register a suite of this package.
---@param part string
---@return TestKit.Suite
local function newSuite(part)
  return Harness:Suite(PACKAGE_ID, part, addonName)
end

-- Positions and errors ------------------------------------------------------------------------

---Split a `file:line: ` prefix into the file as the client names it and the line.
---@param position string
---@return string|nil file
---@return integer|nil line
local function splitPosition(position)
  local file, line = position:match("^(.-):(%d+): ")
  return file, tonumber(line)
end

---The line of the caller of this function, as the client numbers it.
---
---`error` with level 3, raised under `pcall`, names the caller of this
---function: level 1 is `pcall` itself, 2 is this function, 3 its caller. The
---client has no `debug` library, so this is how a test learns its own line.
---@return integer
local function currentLine()
  local _, position = pcall(error, "", 3)
  local _, line = splitPosition(position or "")
  return line or 0
end

---Check that `message` is a plain string naming this file, and return its line.
---@param ctx TestKit.Context
---@param message any
---@return integer|nil line
local function expectThisFile(ctx, message)
  ctx:Expect(isSecret(message)):ToBe(false)
  ctx:Expect(type(message)):ToBe("string")
  if type(message) ~= "string" or isSecret(message) then
    return nil
  end
  local file, line = splitPosition(message)
  ctx:Expect(type(file)):ToBe("string")
  ctx:Expect((file or ""):sub(-#"SchemaKitSuite.lua")):ToBe("SchemaKitSuite.lua")
  return line
end

---Call `raise`, which must record its start line with `currentLine()` and
---raise on the next line, and check that the message names this file at that
---next line and ends with `expected`. Returns the message.
---@param ctx TestKit.Context
---@param raise fun() Records its start line in `lineBox.start`, then raises on the next line.
---@param lineBox { start: integer }
---@param expected string The message after the position, compared literally.
---@return any message
local function expectErrorAtCallingLine(ctx, raise, lineBox, expected)
  local succeeded, message = pcall(raise)
  ctx:Expect(succeeded):ToBe(false)
  local line = expectThisFile(ctx, message)
  if type(line) ~= "nil" then
    ctx:Log("client message: " .. message)
    ctx:Expect(message:sub(-#expected)):ToBe(expected)
  end
  ctx:Expect(line):ToBe(lineBox.start + 1)
  return message
end

---Check a `Check` or `Apply` outcome: `false` and a failure with these fields.
---@param ctx TestKit.Context
---@param ok any
---@param failure any
---@param path string
---@param rule string
---@param expected string
---@param found string
local function expectFailure(ctx, ok, failure, path, rule, expected, found)
  ctx:Expect(ok):ToBe(false)
  ctx:Expect(type(failure)):ToBe("table")
  if type(failure) ~= "table" then
    return
  end
  ctx:Expect(failure.path):ToBe(path)
  ctx:Expect(failure.rule):ToBe(rule)
  ctx:Expect(failure.expected):ToBe(expected)
  ctx:Expect(failure.found):ToBe(found)
end

-- Allocation ----------------------------------------------------------------------------------

---Measure how many kilobytes `work` grows the Lua heap by.
---@param work fun()
---@return number grownKilobytes
local function measureAllocation(work)
  local before = collectgarbage("count")
  work()
  return collectgarbage("count") - before
end

---Run a full collection in a step of its own, so the measurement that follows
---starts far from the next collector cycle, which would otherwise shrink the
---count mid-measurement and hide an allocation.
---@param ctx TestKit.Context
local function collectBeforeMeasuring(ctx)
  collectgarbage("collect")
  ctx:Yield()
end

---Call `cycle` `count` times.
---@param cycle fun()
---@param count integer
local function runCycles(cycle, count)
  for _ = 1, count do
    cycle()
  end
end

---Collect in a step of its own, measure `ALLOCATION_CYCLES` calls of `cycle`,
---log the delta and hold it to the tolerance.
---
---One cycle runs unmeasured first, through the same calls as the measured
---ones. A full collection shrinks the Lua stack of the test's coroutine, and a
---nested check grows it again on its first run: that growth is the coroutine's
---own, once, not an allocation of the code under test, which would show once
---per cycle.
---@param ctx TestKit.Context
---@param label string what `cycle` does, for the log
---@param cycle fun()
local function expectNoAllocation(ctx, label, cycle)
  collectBeforeMeasuring(ctx)
  measureAllocation(function()
    runCycles(cycle, 1)
  end)
  local grownKilobytes = measureAllocation(function()
    runCycles(cycle, ALLOCATION_CYCLES)
  end)
  ctx:Log(("memory delta over %s: %.3f KB"):format(label, grownKilobytes))
  ctx:Expect(grownKilobytes <= ALLOCATION_TOLERANCE_KB):ToBe(true)
end

-- Client reads --------------------------------------------------------------------------------

---`C_Spell.GetSpellInfo(6603)`, or end the test as skipped when the client
---has no such function or no plain table to answer with.
---@param ctx TestKit.Context
---@return table info
local function readAutoAttackInfo(ctx)
  local getSpellInfo = readHostFunction("C_Spell", "GetSpellInfo")
  if type(getSpellInfo) == "nil" then
    Harness:SkipTest(ctx, "the client has no C_Spell.GetSpellInfo")
  end
  ---@cast getSpellInfo function
  local info = getSpellInfo(AUTO_ATTACK_SPELL_ID)
  if type(info) ~= "table" or isSecret(info) then
    Harness:SkipTest(ctx, "C_Spell.GetSpellInfo(6603) answered no plain table")
  end
  return info
end

---The field names of a plain table, sorted, joined with commas, for the log.
---@param value table
---@return string
local function describeFieldNames(value)
  local names = {}
  for key in pairs(value) do
    names[#names + 1] = type(key) == "string" and key or ("[" .. type(key) .. "]")
  end
  table.sort(names)
  return table.concat(names, ", ")
end

--- The documented shape of `C_Spell.GetSpellInfo`'s answer, open to fields a
--- later client adds. `name`, `iconID` and `spellID` are always present; the
--- others are optional so the schema holds on a client that drops one.
local SPELL_INFO_FIELDS = {
  name = S.string({ min = 1, max = 128 }),
  iconID = S.number({ integer = true, min = 1 }),
  spellID = S.enum({ AUTO_ATTACK_SPELL_ID }),
  originalIconID = S.optional(S.number({ integer = true, min = 1 })),
  castTime = S.optional(S.number({ min = 0 })),
  minRange = S.optional(S.number({ min = 0 })),
  maxRange = S.optional(S.number({ min = 0 })),
}

--- The spell info schema: the documented fields, open to the client's others.
local SpellInfo = SchemaKit:Seal(S.table({ fields = SPELL_INFO_FIELDS, open = true }))

-- schemaKit.facade ----------------------------------------------------------------------------

local facade = newSuite("facade")

facade:Test(
  "Registry:Get('schemaKit', 1) is the SchemaKit facade with API 1, its eleven builders, Seal, SetLimits, GetLimits, UNBOUNDED and the Schema prototype's four methods",
  function(ctx)
    ctx:Expect(type(SchemaKit)):ToBe("table")
    ctx:Expect(rawget(SchemaKit, "API")):ToBe(SCHEMA_KIT_API)
    for _, functionName in ipairs({
      "string",
      "number",
      "boolean",
      "enum",
      "table",
      "array",
      "map",
      "optional",
      "oneOf",
      "any",
      "custom",
      "Seal",
      "SetLimits",
      "GetLimits",
    }) do
      ctx:Expect(type(rawget(SchemaKit, functionName))):ToBe("function")
    end
    ctx:Expect(type(rawget(SchemaKit, "UNBOUNDED"))):ToBe("table")
    local prototype = rawget(SchemaKit, "Schema")
    ctx:Expect(type(prototype)):ToBe("table")
    for _, methodName in ipairs({ "Check", "Assert", "Apply", "Describe" }) do
      ctx:Expect(type(rawget(prototype, methodName))):ToBe("function")
    end
    local schema = SchemaKit:Seal(S.boolean())
    ctx:Expect(getmetatable(schema)):ToBe("SchemaKit.Schema")
    ctx:Expect(getmetatable(S.boolean())):ToBe("SchemaKit.Node")
  end
)

facade:Test("the installed SchemaKit carries the revision of the committed manifest", function(ctx)
  local expectedPackages = Harness:GetExpectedPackages()
  if type(expectedPackages) == "nil" then
    ctx:Fail("Expected.lua is missing; install with python3 -m tooling.client.install")
    return
  end
  for _, expected in ipairs(expectedPackages) do
    if expected.id == PACKAGE_ID then
      local _, revision = Registry:Get(PACKAGE_ID, SCHEMA_KIT_API)
      ctx:Expect(revision):ToBe(expected.revision)
      ctx:Expect(rawget(SchemaKit, "REVISION")):ToBe(expected.revision)
      return
    end
  end
  ctx:Fail("Expected.lua does not list schemaKit")
end)

facade:Test(
  "GetLimits answers a fresh table holding the session's four limits at their defaults, which MAX_DEPTH and DEFAULT_ARRAY_MAX publish",
  function(ctx)
    local first = SchemaKit:GetLimits()
    local second = SchemaKit:GetLimits()
    ctx:Expect(second).Not:ToBe(first)
    ctx:Log(
      ("limits in this session: maxDepth %s, maxPatternCaptures %s, pathKeyLimit %s, defaultArrayMax %s"):format(
        tostring(first.maxDepth),
        tostring(first.maxPatternCaptures),
        tostring(first.pathKeyLimit),
        tostring(first.defaultArrayMax)
      )
    )
    ctx:Expect(rawget(SchemaKit, "MAX_DEPTH")):ToBe(16)
    ctx:Expect(rawget(SchemaKit, "DEFAULT_ARRAY_MAX")):ToBe(1024)
    ctx:Expect(first.maxDepth):ToBe(16)
    ctx:Expect(first.maxPatternCaptures):ToBe(MAX_PATTERN_CAPTURES)
    ctx:Expect(first.pathKeyLimit):ToBe(32)
    ctx:Expect(first.defaultArrayMax):ToBe(1024)
  end
)

-- schemaKit.clientLua -------------------------------------------------------------------------

local clientLua = newSuite("clientLua")

--- Patterns SchemaKit accepts: anchors, classes, sets with `]` and `-` in
--- them, a frontier, a balance, a back-reference, lazy repetition, the `%z`
--- class of Lua 5.1, a colour escape, and two strings with no special
--- character, which `string.find` treats as plain text (`a)` among them).
local ACCEPTED_PATTERNS = {
  "^%d+%.%d+%.%d+$",
  "^[%w ]*$",
  "%f[%a]%a+",
  "%bxy",
  "[]]",
  "[^]]",
  "[a-]",
  "^(%a+) %1$",
  "a.-b",
  "[%a-z]",
  "%(",
  "a)",
  "^$",
  "^%s*(.-)%s*$",
  "%c",
  "|c%x%x%x%x%x%x%x%x",
  "Auto Attack",
}

--- Subjects every accepted pattern is tried on: empty, ASCII words, a
--- version, parentheses, a repeated word, a colour-escaped name, UTF-8 text
--- and control bytes.
local PATTERN_SUBJECTS = {
  "",
  "Auto Attack",
  "12.1.0",
  "Auto Attack (ab) 12.1 ab)",
  "xay",
  "]",
  "a-",
  "hit hit",
  "|cff33ccffMoltenCodes|r",
  UTF8_WORD,
  "tab\there",
}

clientLua:Test(
  "for 17 accepted patterns, the pattern rule agrees with the client's own string.find on 11 subjects each, and no Check raises",
  function(ctx)
    local mismatches = 0
    for _, pattern in ipairs(ACCEPTED_PATTERNS) do
      local built, schemaOrMessage = pcall(function()
        return SchemaKit:Seal(S.string({ pattern = pattern }))
      end)
      ctx:Expect(built):ToBe(true)
      if built then
        local answers = {}
        for _, subject in ipairs(PATTERN_SUBJECTS) do
          local clientAnswered, start = pcall(string.find, subject, pattern)
          local checked, accepted = pcall(schemaOrMessage.Check, schemaOrMessage, subject)
          ctx:Expect(clientAnswered):ToBe(true)
          ctx:Expect(checked):ToBe(true)
          local clientAccepts = clientAnswered and type(start) ~= "nil"
          if checked and accepted ~= clientAccepts then
            mismatches = mismatches + 1
          end
          answers[#answers + 1] = clientAccepts and "1" or "0"
        end
        ctx:Log(("%q: %s"):format(pattern, table.concat(answers)))
      end
    end
    ctx:Expect(mismatches):ToBe(0)
  end
)

--- Malformed patterns, each with a subject the client's matcher answers
--- without reaching the broken part and a subject that reaches it.
local MALFORMED_PATTERNS = {
  { pattern = "a[", quiet = "zzz", reaching = "a" },
  { pattern = "a(b", quiet = "zzz", reaching = "ab" },
  { pattern = "a%", quiet = "zzz", reaching = "a" },
  { pattern = "x%1", quiet = "zzz", reaching = "x" },
  { pattern = "%a)", quiet = "1", reaching = "a" },
  { pattern = "a%b", quiet = "zzz", reaching = "a" },
  { pattern = "1%f[a", quiet = "zzz", reaching = "1" },
}

clientLua:Test(
  "7 malformed patterns that the client's string.find answers on one subject but raises on another are each refused by SchemaKit.string at the calling line",
  function(ctx)
    local lines = { start = 0 }
    for _, case in ipairs(MALFORMED_PATTERNS) do
      local quietAnswered, quietStart = pcall(string.find, case.quiet, case.pattern)
      ctx:Expect(quietAnswered):ToBe(true)
      ctx:Expect(quietStart):ToBeNil()
      local reachingAnswered, clientMessage = pcall(string.find, case.reaching, case.pattern)
      ctx:Expect(reachingAnswered):ToBe(false)
      ctx:Log(("%q on %q: %s"):format(case.pattern, case.reaching, tostring(clientMessage)))
      expectErrorAtCallingLine(ctx, function()
        lines.start = currentLine()
        S.string({ pattern = case.pattern })
      end, lines, "SchemaKit.string pattern is not a valid Lua pattern")
    end
  end
)

clientLua:Test(
  "a pattern of 32 captures is accepted and checks without raising, and one of 33, which the client's string.find refuses with too many captures, is refused at the calling line",
  function(ctx)
    local widest = string.rep("(a)", MAX_PATTERN_CAPTURES)
    local schema = SchemaKit:Seal(S.string({ pattern = widest }))
    local checked, accepted = pcall(schema.Check, schema, string.rep("a", MAX_PATTERN_CAPTURES))
    ctx:Expect(checked):ToBe(true)
    ctx:Expect(accepted):ToBe(true)

    local tooWide = string.rep("(a)", MAX_PATTERN_CAPTURES + 1)
    local clientAnswered, clientMessage =
      pcall(string.find, string.rep("a", MAX_PATTERN_CAPTURES + 1), tooWide)
    ctx:Expect(clientAnswered):ToBe(false)
    ctx:Log("client's string.find with 33 captures: " .. tostring(clientMessage))
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      S.string({ pattern = tooWide })
    end, lines, "SchemaKit.string pattern is not a valid Lua pattern")
  end
)

--- Number bounds and the phrase the client's `%.14g` prints for each.
local NUMBER_BOUND_CASES = {
  { spec = { min = 0.1 }, value = 0, rule = "min", expected = "number >= 0.1" },
  { spec = { max = 1e15 }, value = 1e16, rule = "max", expected = "number <= 1e+15" },
  {
    spec = { max = 2 ^ 53 },
    value = 2 ^ 54,
    rule = "max",
    expected = "number <= 9.007199254741e+15",
  },
  { spec = { min = -0.5 }, value = -1, rule = "min", expected = "number >= -0.5" },
  { spec = { max = 1 / 3 }, value = 1, rule = "max", expected = "number <= 0.33333333333333" },
  {
    spec = { integer = true, max = 100 },
    value = 101,
    rule = "max",
    expected = "integer <= 100",
  },
}

clientLua:Test(
  "number bounds in failures are printed by the client's %.14g: 0.1, 1e+15, 9.007199254741e+15, -0.5, 0.33333333333333, and an integer bound reads integer <= 100",
  function(ctx)
    for _, case in ipairs(NUMBER_BOUND_CASES) do
      local schema = SchemaKit:Seal(S.number(case.spec))
      local ok, failure = schema:Check(case.value)
      local found = case.rule == "min" and "smaller number" or "larger number"
      expectFailure(ctx, ok, failure, "", case.rule, case.expected, found)
      local bound = case.spec.min or case.spec.max
      ctx:Log(("%%.14g of the bound: %s"):format(("%.14g"):format(bound)))
    end
  end
)

clientLua:Test(
  "string bounds count the bytes of the client's UTF-8 text, NaN is found as NaN and an infinite number as infinite, and an enum lists '|' doubled",
  function(ctx)
    ctx:Expect(#UTF8_WORD):ToBe(6)
    local short = SchemaKit:Seal(S.string({ max = 4 }))
    local ok, failure = short:Check(UTF8_WORD)
    expectFailure(
      ctx,
      ok,
      failure,
      "",
      "max",
      "string of at most 4 characters",
      "string of length 6"
    )
    ctx:Expect(SchemaKit:Seal(S.string({ min = 5 })):Check(UTF8_WORD)):ToBe(true)

    local notANumber = 0 / 0
    ok, failure = SchemaKit:Seal(S.number()):Check(notANumber)
    expectFailure(ctx, ok, failure, "", "type", "number", "NaN")
    ok, failure = SchemaKit:Seal(S.number({ integer = true })):Check(math.huge)
    expectFailure(ctx, ok, failure, "", "integer", "integer", "infinite number")

    ok, failure = SchemaKit:Seal(S.enum({ "TOP", "a|b", 3, true })):Check("BOTTOM")
    expectFailure(ctx, ok, failure, "", "enum", 'one of "TOP", "a||b", 3, true', "unlisted string")
  end
)

-- schemaKit.hostValues ------------------------------------------------------------------------

local hostValues = newSuite("hostValues")

--- The first four answers of `GetBuildInfo()`: version, build, date, interface.
local BuildInfo = SchemaKit:Seal(S.table({
  fields = {
    version = S.string({ max = 16, pattern = "^%d+%.%d+%.%d+$" }),
    build = S.string({ max = 10, pattern = "^%d+$" }),
    buildDate = S.string({ min = 1, max = 32 }),
    interface = S.number({ integer = true, min = 10000, max = 999999 }),
  },
}))

hostValues:Test(
  "GetBuildInfo's version, build, date and interface match a schema of their shapes, and a failing bound names rule and bound but not the interface number",
  function(ctx)
    local getBuildInfo = readHost("GetBuildInfo")
    if type(getBuildInfo) ~= "function" then
      Harness:SkipTest(ctx, "the client has no GetBuildInfo")
    end
    local version, build, buildDate, interface = getBuildInfo()
    ctx:Log(
      ("GetBuildInfo: %d answers; %s, %s, %s, %s"):format(
        select("#", getBuildInfo()),
        tostring(version),
        tostring(build),
        tostring(buildDate),
        tostring(interface)
      )
    )
    local facts = { version = version, build = build, buildDate = buildDate, interface = interface }
    local ok, failure = BuildInfo:Check(facts)
    if not ok then
      ctx:Log(
        ("failure: %s %s (%s, %s)"):format(
          failure.path,
          failure.rule,
          failure.expected,
          failure.found
        )
      )
    end
    ctx:Expect(ok):ToBe(true)
    ctx:Expect(BuildInfo:Assert(facts, "build facts")):ToBe(facts)

    -- Every promised client's interface number has five digits or more
    -- (Classic Era 11509, Mists Classic 50504, Retail 120100), so a
    -- four-digit ceiling fails on each of them.
    local FourDigitInterface = SchemaKit:Seal(S.number({ integer = true, max = 9999 }))
    ok, failure = FourDigitInterface:Check(interface)
    expectFailure(ctx, ok, failure, "", "max", "integer <= 9999", "larger number")
    local shown = tostring(interface)
    if type(failure) == "table" then
      for _, field in ipairs({ "path", "rule", "expected", "found" }) do
        ctx:Expect(tostring(failure[field]):find(shown, 1, true)):ToBeNil()
      end
    end
  end
)

hostValues:Test(
  "C_Spell.GetSpellInfo(6603) matches an open spell info schema, and a closed schema naming only name and spellID refuses one of the client's other fields by name",
  function(ctx)
    local info = readAutoAttackInfo(ctx)
    ctx:Log("C_Spell.GetSpellInfo(6603) fields: " .. describeFieldNames(info))
    local ok, failure = SpellInfo:Check(info)
    if not ok then
      ctx:Log(
        ("failure: %s %s (%s, %s)"):format(
          failure.path,
          failure.rule,
          failure.expected,
          failure.found
        )
      )
    end
    ctx:Expect(ok):ToBe(true)

    local NameOnly = SchemaKit:Seal(S.table({
      fields = { name = SPELL_INFO_FIELDS.name, spellID = SPELL_INFO_FIELDS.spellID },
    }))
    ok, failure = NameOnly:Check(info)
    ctx:Expect(ok):ToBe(false)
    ctx:Expect(failure.rule):ToBe("unknown")
    ctx:Expect(failure.expected):ToBe("only declared fields")
    ctx:Expect(failure.found):ToBe("undeclared field")
    ctx:Log("the closed schema refused the field " .. failure.path)
    ctx:Expect(failure.path).Not:ToBe("name")
    ctx:Expect(failure.path).Not:ToBe("spellID")
    ctx:Expect(rawget(info, failure.path)).Not:ToBeNil()
  end
)

hostValues:Test(
  "Apply copies C_Spell.GetSpellInfo(6603) into a new table with a default filled in, keeps the client's undeclared fields and leaves the client's table unchanged",
  function(ctx)
    local info = readAutoAttackInfo(ctx)
    local fields = {}
    for name, node in pairs(SPELL_INFO_FIELDS) do
      fields[name] = node
    end
    fields.note = S.optional(S.string({ max = 32 }), "none")
    local WithNote = SchemaKit:Seal(S.table({ fields = fields, open = true }))

    local applied, copy = WithNote:Apply(info)
    ctx:Expect(applied):ToBe(true)
    ctx:Expect(copy).Not:ToBe(info)
    ctx:Expect(copy.note):ToBe("none")
    ctx:Expect(rawget(info, "note")):ToBeNil()
    for key, value in pairs(info) do
      ctx:Expect(rawget(copy, key)):ToBe(value)
    end
  end
)

hostValues:Test(
  "a table schema reads UIParent with rawget, so GetName, which the Frame's metatable supplies, is missing and refused as required",
  function(ctx)
    ctx:Expect(type(uiParent.GetName)):ToBe("function")
    ctx:Expect(rawget(uiParent, "GetName")):ToBeNil()
    local Named = SchemaKit:Seal(S.table({ fields = { GetName = S.any() }, open = true }))
    local ok, failure = Named:Check(uiParent)
    expectFailure(ctx, ok, failure, "GetName", "required", "any value", "nil")
    ctx:Expect(SchemaKit:Seal(S.table({ fields = {}, open = true })):Check(uiParent)):ToBe(true)
    ctx:Expect(SchemaKit:Seal(S.any()):Check(uiParent)):ToBe(true)
  end
)

hostValues:Test(
  "UIParent's userdata handle is found as userdata, accepted by any and kept as it is by Apply, and a Frame or its handle used as a key shows in a path as [table] or [userdata]",
  function(ctx)
    local handle = rawget(uiParent, 0)
    ctx:Expect(type(handle)):ToBe("userdata")
    local ok, failure = SchemaKit:Seal(S.string()):Check(handle)
    expectFailure(ctx, ok, failure, "", "type", "string", "userdata")
    ctx:Expect(SchemaKit:Seal(S.any()):Check(handle)):ToBe(true)

    local Holder = SchemaKit:Seal(S.table({ fields = { handle = S.any() } }))
    local applied, copy = Holder:Apply({ handle = handle })
    ctx:Expect(applied):ToBe(true)
    ctx:Expect(rawequal(copy.handle, handle)):ToBe(true)

    local Closed = SchemaKit:Seal(S.table({ fields = {} }))
    ok, failure = Closed:Check({ [handle] = true })
    expectFailure(
      ctx,
      ok,
      failure,
      "[userdata]",
      "unknown",
      "only declared fields",
      "undeclared field"
    )
    ok, failure = Closed:Check({ [uiParent] = true })
    expectFailure(
      ctx,
      ok,
      failure,
      "[table]",
      "unknown",
      "only declared fields",
      "undeclared field"
    )
  end
)

hostValues:Test(
  "a custom check receives UIParent itself and accepts it, and refuses a plain table with found table",
  function(ctx)
    local received = {}
    local IsFrame = SchemaKit:Seal(S.custom(function(value)
      received[#received + 1] = value
      return type(value) == "table" and type(rawget(value, 0)) == "userdata"
    end, "a Frame"))
    ctx:Expect(IsFrame:Check(uiParent)):ToBe(true)
    ctx:Expect(received[1]):ToBe(uiParent)
    local ok, failure = IsFrame:Check({})
    expectFailure(ctx, ok, failure, "", "custom", "a Frame", "table")
    ctx:Expect(#received):ToBe(2)
  end
)

-- schemaKit.allocation ------------------------------------------------------------------------

local allocation = newSuite("allocation")

--- The cookbook's settings schema (docs/API.md, "A settings schema").
local Aura = S.table({
  fields = {
    shown = S.optional(S.boolean(), true),
    color = S.optional(
      S.array({ of = S.number({ min = 0, max = 1 }), min = 3, max = 4 }),
      { 1, 1, 1 }
    ),
    sound = S.optional(S.string({ max = 64 })),
  },
})
local Settings = SchemaKit:Seal(S.table({
  fields = {
    version = S.optional(S.number({ integer = true, min = 1 }), 1),
    scale = S.optional(S.number({ min = 0.5, max = 2 }), 1),
    anchor = S.optional(S.string({ oneOf = { "TOP", "CENTER", "BOTTOM" } }), "CENTER"),
    auras = S.optional(
      S.map({ keys = S.number({ integer = true }), values = S.optional(Aura, {}), max = 256 }),
      {}
    ),
  },
}))

allocation:Test(
  "Check and Assert of a valid nested settings table, the cookbook's, allocate nothing over 5000 cycles",
  function(ctx)
    local saved = {
      version = 2,
      scale = 1.5,
      anchor = "TOP",
      auras = {
        [AUTO_ATTACK_SPELL_ID] = { shown = true, color = { 1, 0.5, 0, 1 }, sound = "alert" },
        [1] = { shown = false },
      },
    }
    ctx:Expect(Settings:Check(saved)):ToBe(true)

    local accepted = 0
    expectNoAllocation(ctx, "5000 Check and Assert pairs of a settings table", function()
      if Settings:Check(saved) then
        accepted = accepted + 1
      end
      Settings:Assert(saved, "saved")
    end)
    ctx:Expect(accepted):ToBe(ALLOCATION_CYCLES + 1)
  end
)

allocation:Test(
  "Check of the client's C_Spell.GetSpellInfo(6603) table against the open spell info schema allocates nothing over 5000 cycles",
  function(ctx)
    local info = readAutoAttackInfo(ctx)
    ctx:Expect(SpellInfo:Check(info)):ToBe(true)
    local accepted = 0
    expectNoAllocation(ctx, "5000 checks of the spell info", function()
      if SpellInfo:Check(info) then
        accepted = accepted + 1
      end
    end)
    ctx:Expect(accepted):ToBe(ALLOCATION_CYCLES + 1)
  end
)

allocation:Test(
  "Check of strings against an anchored pattern with bounds, a oneOf list and an enum allocates nothing over 5000 cycles",
  function(ctx)
    local Label = SchemaKit:Seal(S.string({ min = 1, max = 24, pattern = "^[%w ]*$" }))
    local Anchor = SchemaKit:Seal(S.string({ oneOf = { "TOP", "CENTER", "BOTTOM" } }))
    local Outline = SchemaKit:Seal(S.enum({ "NONE", "OUTLINE", "THICKOUTLINE" }))
    local accepted = 0
    expectNoAllocation(ctx, "5000 string checks", function()
      if Label:Check("Auto Attack") and Anchor:Check("CENTER") and Outline:Check("OUTLINE") then
        accepted = accepted + 1
      end
    end)
    ctx:Expect(accepted):ToBe(ALLOCATION_CYCLES + 1)
  end
)

allocation:Test(
  "a Check failing at the root with a fixed phrase (larger number, wrong type) reuses its failure table and allocates nothing over 5000 cycles",
  function(ctx)
    local Scale = SchemaKit:Seal(S.number({ min = 0.5, max = 2 }))
    local Name = SchemaKit:Seal(S.string({ max = 32 }))
    local _, firstFailure = Scale:Check(5)
    local _, secondFailure = Scale:Check(0)
    ctx:Expect(secondFailure):ToBe(firstFailure)

    local refused = 0
    expectNoAllocation(ctx, "5000 failing root checks", function()
      if not Scale:Check(5) then
        refused = refused + 1
      end
      Name:Check(uiParent)
    end)
    ctx:Expect(refused):ToBe(ALLOCATION_CYCLES + 1)
    local ok, failure = Name:Check(uiParent)
    expectFailure(ctx, ok, failure, "", "type", "string", "table")
  end
)

-- schemaKit.errors ----------------------------------------------------------------------------

local errors = newSuite("errors")

errors:Test(
  "SchemaKit.number with min above max and SchemaKit.table with a field that is not a node name SchemaKitSuite.lua at the calling line",
  function(ctx)
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      S.number({ min = 2, max = 1 })
    end, lines, "SchemaKit.number min must not be greater than max")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      S.table({ fields = { frame = uiParent } })
    end, lines, "SchemaKit.table fields.frame must be a SchemaKit schema node or sealed schema")
  end
)

errors:Test(
  "a builder called with a colon and Seal called with a dot are refused at the calling line",
  function(ctx)
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      SchemaKit:string()
    end, lines, "SchemaKit.string is called with a dot, not a colon")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      SchemaKit.Seal(S.boolean())
    end, lines, "SchemaKit:Seal is called with a colon, not a dot")
  end
)

errors:Test(
  "Check called on UIParent instead of a schema, and a write to a sealed schema, are refused at the calling line",
  function(ctx)
    local schema = SchemaKit:Seal(S.boolean())
    local check = schema.Check
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      check(uiParent, true)
    end, lines, "SchemaKit.Schema:Check must be called on a sealed SchemaKit schema")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      schema.Check = nil
    end, lines, "SchemaKit schemas are sealed and cannot be modified")
    ctx:Expect(schema:Check(true)):ToBe(true)
  end
)

errors:Test(
  "Assert raises its failure at the calling line, and with level 2 at the line that called the validating function",
  function(ctx)
    local Scale = SchemaKit:Seal(S.number({ min = 0.5, max = 2 }))
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      Scale:Assert(5, "scale")
    end, lines, "scale: expected number <= 2, found larger number")

    local function configure(options)
      Scale:Assert(options.scale, "configure options.scale", 2)
    end
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      configure({ scale = 0 })
    end, lines, "configure options.scale: expected number >= 0.5, found smaller number")
  end
)

errors:Test(
  "an error raised by a custom check propagates unchanged from its own line in SchemaKitSuite.lua, through Check and Assert",
  function(ctx)
    local lines = { start = 0 }
    local Refusing = SchemaKit:Seal(S.custom(function()
      lines.start = currentLine()
      error("the custom check raised on purpose")
    end, "anything"))
    for _, method in ipairs({ "Check", "Assert" }) do
      local succeeded, message = pcall(Refusing[method], Refusing, "value")
      ctx:Expect(succeeded):ToBe(false)
      local line = expectThisFile(ctx, message)
      ctx:Expect(line):ToBe(lines.start + 1)
      ctx:Expect(tostring(message):match(": (.*)$")):ToBe("the custom check raised on purpose")
      ctx:Log(method .. ": " .. tostring(message))
    end
  end
)

errors:Test(
  "an optional default that fails its schema is refused at the calling line with the default's own failure",
  function(ctx)
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      S.optional(S.table({ fields = { size = S.number() } }), { size = "large" })
    end, lines, "SchemaKit.optional default.size: expected number, found string")
  end
)

errors:Test(
  "SetLimits with an unknown limit or a maxDepth above 64 is refused at the calling line and changes no limit",
  function(ctx)
    local before = SchemaKit:GetLimits()
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      SchemaKit:SetLimits({ maxDepth = 20, maxWidth = 1 })
    end, lines, "SchemaKit:SetLimits limits.maxWidth is not a recognised limit")
    expectErrorAtCallingLine(
      ctx,
      function()
        lines.start = currentLine()
        SchemaKit:SetLimits({ maxDepth = 65 })
      end,
      lines,
      "SchemaKit:SetLimits limits.maxDepth must be an integer from 1 to 64: checking, applying and default validation recurse once per nesting level of a value its sender shapes"
    )
    ctx:Expect(SchemaKit:GetLimits()):ToEqual(before)
  end
)

-- schemaKit.secrets ---------------------------------------------------------------------------

local secrets = newSuite("secrets")

--- Why the secrets tests are skipped on a client without the two functions.
local SECRETS_SKIP_REASON =
  "the client has no issecretvalue and secretwrap; the secret path was not exercised"

---Register `body` as a test when the client can make a secret value, and as a
---skipped test naming why otherwise.
---@param name string
---@param body fun(ctx: TestKit.Context)
local function secretTest(name, body)
  if not SECRETS_AVAILABLE then
    secrets:Skip(name, SECRETS_SKIP_REASON)
  elseif not Harness:CanMakeSecrets() then
    -- Classic Era and Mists Classic document both functions, but only the
    -- running client shows whether `secretwrap` makes a genuine secret.
    secrets:Skip(name, Harness.NO_SECRETS_REASON)
  else
    secrets:Test(name, body)
  end
end

---A genuine secret value made by the client's `secretwrap`, or a failed test.
---
---`secretwrap` is documented in the client's own API documentation
---(FrameScriptDocumentation, packages/apiKit/metadata/retail/namespaces.json)
---with no restriction and no side effect: it converts the values given to it.
---@param ctx TestKit.Context
---@param value any
---@return any secret
local function makeSecret(ctx, value)
  local succeeded, secret = pcall(secretWrap, value)
  if not succeeded then
    ctx:Fail("secretwrap raised, so the secret path was not exercised: " .. tostring(secret))
  end
  if isSecretValue(secret) ~= true then
    ctx:Fail("secretwrap returned a value issecretvalue does not report as secret")
  end
  return secret
end

---Describe a pcall outcome for the log without formatting a secret.
---@param succeeded boolean
---@param value any
---@return string
local function describeOutcome(succeeded, value)
  if isSecret(value) then
    return (succeeded and "returned" or "raised") .. " a secret " .. type(value)
  end
  if not succeeded then
    return "raised: " .. tostring(value)
  end
  return "returned " .. type(value) .. " " .. tostring(value)
end

---Check that no field of a failure is itself secret or contains the text of
---the secrets this suite makes.
---@param ctx TestKit.Context
---@param failure table
local function expectNoSecretText(ctx, failure)
  for _, field in ipairs({ "path", "rule", "expected", "found" }) do
    local text = failure[field]
    ctx:Expect(isSecret(text)):ToBe(false)
    ctx:Expect(type(text)):ToBe("string")
    if type(text) == "string" and not isSecret(text) then
      ctx:Expect(text:find(SECRET_TEXT, 1, true)):ToBeNil()
      ctx:Expect(text:find(tostring(SECRET_NUMBER), 1, true)):ToBeNil()
    end
  end
end

---Run `schema:Check(value)` under `pcall`, require that it returned (a raise
---here would be the client refusing a comparison SchemaKit made), and check
---the secret failure it reported.
---@param ctx TestKit.Context
---@param label string what is checked, for the log
---@param schema any
---@param value any
---@param path string
---@param expected string
local function expectSecretRefused(ctx, label, schema, value, path, expected)
  local returned, ok, failure = pcall(schema.Check, schema, value)
  if not returned then
    ctx:Log(label .. ": Check raised: " .. describeOutcome(false, ok))
  end
  ctx:Expect(returned):ToBe(true)
  if not returned then
    return
  end
  expectFailure(ctx, ok, failure, path, "secret", expected, "secret value")
  expectNoSecretText(ctx, failure)
end

secretTest(
  "the client raises when a secret number meets a number in < or == or is used as a key, and answers type and a comparison with nil: the hazards SchemaKit must refuse before",
  function(ctx)
    local secret = makeSecret(ctx, SECRET_NUMBER)
    local plainTable = {}
    local ordered, orderMessage = pcall(function()
      return secret < 100
    end)
    local equal, equalMessage = pcall(function()
      return secret == SECRET_NUMBER
    end)
    local indexed, indexMessage = pcall(function()
      return plainTable[secret]
    end)
    local comparedWithNil, withNil = pcall(function()
      return secret == nil
    end)
    ctx:Log("secret < 100: " .. describeOutcome(ordered, orderMessage))
    ctx:Log("secret == 4242: " .. describeOutcome(equal, equalMessage))
    ctx:Log("plainTable[secret]: " .. describeOutcome(indexed, indexMessage))
    ctx:Log("secret == nil: " .. describeOutcome(comparedWithNil, withNil))
    ctx:Expect(ordered):ToBe(false)
    ctx:Expect(equal):ToBe(false)
    ctx:Expect(indexed):ToBe(false)
    ctx:Expect(comparedWithNil):ToBe(true)
    ctx:Expect(withNil):ToBe(false)
    ctx:Expect(type(secret)):ToBe("number")
  end
)

secretTest(
  "a secret number checked against number schemas with min, max and integer fails with rule secret and found secret value, and no client compare error escapes",
  function(ctx)
    local secret = makeSecret(ctx, SECRET_NUMBER)
    expectSecretRefused(ctx, "number", SchemaKit:Seal(S.number()), secret, "", "number")
    expectSecretRefused(
      ctx,
      "number with min and max",
      SchemaKit:Seal(S.number({ min = 0, max = 100 })),
      secret,
      "",
      "number"
    )
    expectSecretRefused(
      ctx,
      "integer with min and max",
      SchemaKit:Seal(S.number({ integer = true, min = 1, max = 10000 })),
      secret,
      "",
      "integer"
    )
    expectSecretRefused(
      ctx,
      "number with a bound above the secret",
      SchemaKit:Seal(S.number({ max = 1e9 })),
      secret,
      "",
      "number"
    )
  end
)

secretTest(
  "a secret string, boolean and number are refused with rule secret by string with a pattern, bounds or a oneOf list, enum, boolean, any, oneOf and optional, each without raising",
  function(ctx)
    local secretString = makeSecret(ctx, SECRET_TEXT)
    local secretBoolean = makeSecret(ctx, true)
    local secretNumber = makeSecret(ctx, SECRET_NUMBER)
    local cases = {
      {
        label = "string with pattern and bounds",
        node = S.string({ min = 1, max = 64, pattern = "^%a+$" }),
        value = secretString,
        expected = "string",
      },
      {
        label = "string oneOf",
        node = S.string({ oneOf = { SECRET_TEXT, "other" } }),
        value = secretString,
        expected = 'one of "' .. SECRET_TEXT .. '", "other"',
      },
      {
        label = "enum listing the secret's own text",
        node = S.enum({ SECRET_TEXT, SECRET_NUMBER, true }),
        value = secretString,
        expected = 'one of "' .. SECRET_TEXT .. '", 4242, true',
      },
      {
        label = "enum of a number",
        node = S.enum({ 1, 2 }),
        value = secretNumber,
        expected = "one of 1, 2",
      },
      { label = "boolean", node = S.boolean(), value = secretBoolean, expected = "boolean" },
      { label = "any", node = S.any(), value = secretNumber, expected = "any value" },
      {
        label = "oneOf",
        node = S.oneOf({ S.string(), S.number() }),
        value = secretNumber,
        expected = "string or number",
      },
      {
        label = "optional with a default",
        node = S.optional(S.number({ max = 10 }), 5),
        value = secretNumber,
        expected = "number",
      },
    }
    for _, case in ipairs(cases) do
      local schema = SchemaKit:Seal(case.node)
      local returned, ok, failure = pcall(schema.Check, schema, case.value)
      ctx:Expect(returned):ToBe(true)
      if not returned then
        ctx:Log(case.label .. ": Check " .. describeOutcome(false, ok))
      else
        ctx:Expect(ok):ToBe(false)
        ctx:Expect(failure.rule):ToBe("secret")
        ctx:Expect(failure.found):ToBe("secret value")
        ctx:Expect(failure.path):ToBe("")
        ctx:Expect(failure.expected):ToBe(case.expected)
        -- A oneOf list's or an enum's expected phrase lists the
        -- schema's own constants, which here include the text the
        -- secret was made from; the found phrase never does.
        ctx:Expect(failure.found:find(SECRET_TEXT, 1, true)):ToBeNil()
      end
    end
  end
)

secretTest(
  "a custom check is never called with a secret, and the failure names rule secret",
  function(ctx)
    local calls = 0
    local Custom = SchemaKit:Seal(S.custom(function()
      calls = calls + 1
      return true
    end, "anything"))
    expectSecretRefused(ctx, "custom", Custom, makeSecret(ctx, SECRET_TEXT), "", "anything")
    expectSecretRefused(ctx, "custom", Custom, makeSecret(ctx, SECRET_NUMBER), "", "anything")
    ctx:Expect(calls):ToBe(0)
    ctx:Expect(Custom:Check("plain")):ToBe(true)
    ctx:Expect(calls):ToBe(1)
  end
)

secretTest(
  "a secret inside a table, an array and a map is refused at stats.health, [2] and byUnit.player without raising",
  function(ctx)
    local secret = makeSecret(ctx, SECRET_NUMBER)
    local Unit = SchemaKit:Seal(S.table({
      fields = { stats = S.table({ fields = { health = S.number({ min = 0 }) } }) },
    }))
    expectSecretRefused(
      ctx,
      "table",
      Unit,
      { stats = { health = secret } },
      "stats.health",
      "number"
    )

    local Values = SchemaKit:Seal(S.array({ of = S.number({ max = 100 }), max = 4 }))
    expectSecretRefused(ctx, "array", Values, { 1, secret, 3 }, "[2]", "number")

    local ByUnit = SchemaKit:Seal(S.table({
      fields = {
        byUnit = S.map({
          keys = S.string({ max = 16 }),
          values = S.number({ min = 0 }),
          max = 8,
        }),
      },
    }))
    expectSecretRefused(
      ctx,
      "map",
      ByUnit,
      { byUnit = { player = secret } },
      "byUnit.player",
      "number"
    )
  end
)

secretTest(
  "Assert with a secret raises at the calling line in SchemaKitSuite.lua with 'health: expected number, found secret value', a plain string without the secret's text",
  function(ctx)
    local Health = SchemaKit:Seal(S.number({ min = 0, max = 100 }))
    local Name = SchemaKit:Seal(S.string({ max = 64, pattern = "^%a+$" }))
    local secretNumber = makeSecret(ctx, SECRET_NUMBER)
    local secretString = makeSecret(ctx, SECRET_TEXT)
    local lines = { start = 0 }
    local numberMessage = expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      Health:Assert(secretNumber, "health")
    end, lines, "health: expected number, found secret value")
    local stringMessage = expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      Name:Assert(secretString, "name")
    end, lines, "name: expected string, found secret value")
    for _, message in ipairs({ numberMessage, stringMessage }) do
      if type(message) == "string" and not isSecret(message) then
        ctx:Expect(message:find(SECRET_TEXT, 1, true)):ToBeNil()
        ctx:Expect(message:find(tostring(SECRET_NUMBER), 1, true)):ToBeNil()
      end
    end
  end
)

secretTest(
  "Apply of a secret in a declared field fails with rule secret, while a secret in an undeclared field of an open table is kept, still secret, in the copy",
  function(ctx)
    local secret = makeSecret(ctx, SECRET_NUMBER)
    local Declared = SchemaKit:Seal(S.table({
      fields = { health = S.optional(S.number({ max = 100 }), 100) },
    }))
    local returned, applied, failure = pcall(Declared.Apply, Declared, { health = secret })
    ctx:Expect(returned):ToBe(true)
    if returned then
      expectFailure(ctx, applied, failure, "health", "secret", "number", "secret value")
      expectNoSecretText(ctx, failure)
    end

    local Open = SchemaKit:Seal(S.table({
      fields = { name = S.optional(S.string({ max = 16 }), "unit") },
      open = true,
    }))
    local original = { extra = secret }
    local copied, copy = Open:Apply(original)
    ctx:Expect(copied):ToBe(true)
    ctx:Expect(copy).Not:ToBe(original)
    ctx:Expect(copy.name):ToBe("unit")
    ctx:Expect(isSecretValue(rawget(copy, "extra"))):ToBe(true)
    ctx:Expect(type(rawget(copy, "extra"))):ToBe("number")
    ctx:Expect(rawget(original, "name")):ToBeNil()
  end
)

secretTest(
  "SetLimits refuses a secret maxDepth and a secret defaultArrayMax at the calling line with the messages any invalid value gets, and the limits stay as they were",
  function(ctx)
    local before = SchemaKit:GetLimits()
    local secret = makeSecret(ctx, 20)
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      SchemaKit:SetLimits({ maxDepth = secret })
    end, lines, "SchemaKit:SetLimits limits.maxDepth must be an integer from 1 to 64")
    expectErrorAtCallingLine(
      ctx,
      function()
        lines.start = currentLine()
        SchemaKit:SetLimits({ defaultArrayMax = secret })
      end,
      lines,
      "SchemaKit:SetLimits limits.defaultArrayMax must be a positive integer or SchemaKit.UNBOUNDED"
    )
    ctx:Expect(SchemaKit:GetLimits()):ToEqual(before)
  end
)

secretTest("a Check of a secret at the root allocates nothing over 5000 cycles", function(ctx)
  local secret = makeSecret(ctx, SECRET_NUMBER)
  local Health = SchemaKit:Seal(S.number({ min = 0, max = 100 }))
  local refused = 0
  expectNoAllocation(ctx, "5000 checks of a secret", function()
    if not Health:Check(secret) then
      refused = refused + 1
    end
  end)
  ctx:Expect(refused):ToBe(ALLOCATION_CYCLES + 1)
end)
