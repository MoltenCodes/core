-- MoltenCodes Test: OptionsKitSuite.lua
--
-- Real-client suites for the `optionsKit` package. The Busted specs under
-- packages/optionsKit/tests/ prove OptionsKit on a stock Lua 5.1, with a
-- stand-in database of the documented SettingsKit shape and no client. These
-- prove, inside the game client with the installed MoltenCodes addon, what
-- that fixture can only simulate:
--
--   * the installed facade and its committed revision, and the host
--     facilities it finds at call time: SettingsKit API 1 through
--     `Registry:Find`, `UnitName("player")`, `GetRealmName()` and
--     `issecretvalue`;
--   * getters and setters that call the client: a toggle over the cosmetic
--     `chatBubbles` CVar, whose `Set` changes the CVar before it returns and
--     fires `OnChange` while `C_CVar.GetCVar` already answers the new value; a
--     `validate` refusal and a schema refusal that never reach
--     `C_CVar.SetCVar`; and a `disabled` predicate and a `desc` function that
--     read the CVar, which `IsDisabled` and `Describe` follow;
--   * options bound to the real SettingsKit (not the specs' stand-in): the
--     schema default read through the database's views, writes that land in
--     the database's in-memory table, a `char` bind stored under the key the
--     client's name and realm make, and a SettingsKit field narrower than the
--     option refused by `Validate` and `Set` alike;
--   * `ProfileOptions` over that database: the per-character choice built
--     from the real `UnitName` and `GetRealmName`, which must equal the key
--     SettingsKit records the choice under, switching, creating, copying and
--     deleting profiles, the `desc` functions naming the current profile, and
--     the database's own switches reaching the tree's `OnChange`;
--   * validation through SchemaKit on the client's Lua: an input pattern
--     judged exactly as the client's `string.find` judges it, and the phrases
--     `Validate` answers as the client's `%.14g` prints them;
--   * that the documented allocation-free paths (`Get` and `Set` of getter
--     options and of a bound option, `Validate`, `Walk`, `IsDisabled` and
--     `IsHidden`) allocate nothing on the client's own collector;
--   * argument errors pointing at this file as the client names it;
--   * secret values made by the client's `secretwrap`: refused by `Set`,
--     `Validate`, paths, addon names, `Define` fields and limits and
--     `ProfileOptions` options where docs/API.md promises a refusal, passed
--     through `Get` and `Describe` untouched, and counted as "no" when a
--     predicate or `validate` answers with one.
--
-- Nothing here needs combat, a group or an instance, and nothing is visible
-- beyond the chat bubbles setting, which the CVar tests flip and the After
-- hook puts back. No request goes to the server.
--
-- Run with `/mct run optionsKit`; tests/client/MoltenCodesTest_OptionsKit/EXPECTED.md
-- lists what the chat frame should show.
--
-- What a run leaves behind. Every tree a test defines is undefined by the
-- After hook of its suite, which disconnects its `OnChange` listeners and the
-- database connections of its profile group. The database is the one thing
-- that stays: SettingsKit has no way to close a database, so the first test
-- that needs it opens `OptionsKitClientTestDB` once for the session. That
-- global is not a saved variable of any addon (this addon declares none), so
-- the client never writes it to disk; it is an in-memory table that the After
-- hook empties with `db:ResetDatabase()` after every test. Its name does not
-- start with "MoltenCodes", so the Registry suite's check of the framework's
-- globals does not count it. Nothing else is written to a global or a saved
-- variable.

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
local OPTIONS_KIT_API = 1
local SCHEMA_KIT_API = 1
local SETTINGS_KIT_API = 1
local PACKAGE_ID = "optionsKit"

--- The addon name every test defines its tree under. One tree exists per
--- name, and the After hook undefines it.
local TREE_NAME = addonName

--- The global SettingsKit opens the test database over. It is not in any
--- `## SavedVariables` line, so the client never saves it: the database lives
--- in memory for the session. It does not start with "MoltenCodes", which the
--- Registry suite reserves for the framework's own globals.
local DATABASE_NAME = "OptionsKitClientTestDB"

--- The CVar the getter tests read and write. It is cosmetic (whether chat
--- bubbles are drawn), always present on Retail, not read-only and not
--- secure, so `C_CVar.SetCVar` accepts it from addon code; every change is put
--- back by the After hook.
local PROBE_CVAR = "chatBubbles"

--- How many cycles each allocation guard runs. One table or closure per cycle
--- would cost well over a hundred kilobytes at this count.
local ALLOCATION_CYCLES = 5000

--- Kilobytes an allocation guard tolerates. The tolerance absorbs a stray
--- allocation by the client between the two readings, not a per-cycle one.
local ALLOCATION_TOLERANCE_KB = 1

--- "Épée" in UTF-8: four characters in six bytes.
local UTF8_WORD = "\195\137p\195\169e"

--- The profiles the profile tests create. No character's own profile is
--- named like this, because a character profile is "<name> - <realm>".
local CREATED_PROFILE = "OptionsKit Client Test"
local DIRECT_PROFILE = "OptionsKit Direct Switch"

-- Resolving the client and the framework ---------------------------------------------

---Read a client global, or `nil`.
---@param name string
---@return any
local function readHost(name)
  -- CVars, the player's name and realm, UIParent, the secret-value functions
  -- and the test database's in-memory table are globals of the World of
  -- Warcraft client, reachable only through the global table.
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

---Read a function from a client namespace table such as `C_CVar`, or `nil`.
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

-- OptionsKit, SchemaKit and SettingsKit are not in the language-server
-- workspace of tests/client (its .luarc.json lists TestKit's dependency
-- closure only), so their facades and objects are typed `any` here.

---@type any
local OptionsKit = Registry:Get(PACKAGE_ID, OPTIONS_KIT_API)
---@type any
local SchemaKit = Registry:Get("schemaKit", SCHEMA_KIT_API)
if type(OptionsKit) == "nil" or type(SchemaKit) == "nil" then
  error(addonName .. " requires OptionsKit API 1 and SchemaKit API 1; reinstall MoltenCodes", 0)
end
local S = SchemaKit

--- SettingsKit is an optional dependency of OptionsKit, found the way
--- OptionsKit finds it. The bundle ships it; a test that needs it fails with
--- a clear message when it is missing rather than the addon refusing to load.
---@type any
local SettingsKit = Registry:Find("settingsKit", SETTINGS_KIT_API)

--- The Frame the receiver-check test hands a tree method. Every Retail client has it.
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

-- The test database -------------------------------------------------------------------------

--- What the test database stores. Every field is optional, as SettingsKit
--- requires; `chat` has a default so its fields' defaults read before the
--- first write. `chat.width` is narrower (0 to 3) than the option bound to it
--- (0 to 10), which the database tests rely on.
local DATABASE_SCHEMA = {
  profile = S.table({
    fields = {
      chat = S.optional(
        S.table({
          fields = {
            scale = S.optional(S.number({ min = 0.5, max = 2 }), 1),
            width = S.optional(S.number({ min = 0, max = 3 })),
          },
        }),
        {}
      ),
    },
  }),
  char = S.table({
    fields = {
      note = S.optional(S.string({ max = 32 }), ""),
    },
  }),
}

--- The database, once a test opened it; `nil` before.
---@type any
local openedDatabase = nil

---The test database, emptied, so every test starts from a new install.
---
---SettingsKit returns the same database for every `Open` of one name, so it
---is opened once per session, by the first test that needs it, after login:
---the player's name and realm, which the `char` scope and the profile choice
---need, are known by then. Fails the test when SettingsKit is missing.
---@param ctx TestKit.Context
---@return any db
local function freshDatabase(ctx)
  if type(SettingsKit) == "nil" then
    ctx:Fail("Registry:Find('settingsKit', 1) found nothing: the bundle ships SettingsKit")
  end
  if type(openedDatabase) == "nil" then
    openedDatabase = SettingsKit:Open(DATABASE_NAME, DATABASE_SCHEMA)
  end
  openedDatabase:ResetDatabase()
  return openedDatabase
end

---The in-memory table the test database was opened over.
---@return table
local function databaseTable()
  return readHost(DATABASE_NAME)
end

-- The player -----------------------------------------------------------------------------------

---`"<name> - <realm>"` from the client's `UnitName("player")` and
---`GetRealmName()`, built as OptionsKit and SettingsKit document it, or `nil`
---when the client does not answer both with a plain non-empty string.
---@return string|nil
local function readCharacterKey()
  local unitName = readHost("UnitName")
  local getRealmName = readHost("GetRealmName")
  if type(unitName) ~= "function" or type(getRealmName) ~= "function" then
    return nil
  end
  local name = unitName("player")
  local realm = getRealmName()
  if isSecret(name) or isSecret(realm) or type(name) ~= "string" or type(realm) ~= "string" then
    return nil
  end
  if name == "" or realm == "" then
    return nil
  end
  return name .. " - " .. realm
end

---The character key, or end the test as skipped when the client does not
---know the player.
---@param ctx TestKit.Context
---@return string
local function requireCharacterKey(ctx)
  local characterKey = readCharacterKey()
  if type(characterKey) == "nil" then
    Harness:SkipTest(ctx, "UnitName('player') or GetRealmName() answered no plain name")
  end
  ---@cast characterKey string
  return characterKey
end

-- Objects of the running test ------------------------------------------------------------

--- Tree names the running test defined; the After hook undefines them.
---@type string[]
local definedTreeNames = {}

--- Client settings to put back after the trees are gone, newest last.
---@type fun()[]
local pendingRestores = {}

---Undefine every tree the running test defined, empty the test database,
---then put back every client setting the test changed. The After hook of
---every suite. Undefining first disconnects the profile groups, so emptying
---the database reaches no tree.
local function cleanUp()
  for index = #definedTreeNames, 1, -1 do
    local name = definedTreeNames[index]
    definedTreeNames[index] = nil
    pcall(OptionsKit.Undefine, OptionsKit, name)
  end
  if type(openedDatabase) ~= "nil" then
    pcall(openedDatabase.ResetDatabase, openedDatabase)
  end
  for index = #pendingRestores, 1, -1 do
    local restore = pendingRestores[index]
    pendingRestores[index] = nil
    pcall(restore)
  end
end

---Register a suite of this package whose tests all end with every tree
---undefined, the database empty and every setting put back.
---@param part string
---@return TestKit.Suite
local function newSuite(part)
  local suite = Harness:Suite(PACKAGE_ID, part, addonName)
  suite:After(cleanUp)
  return suite
end

---Remember that the After hook must undefine the tree of `name`. Called
---before `Define`, so a `Define` expected to raise that succeeds is still
---undefined.
---@param name string
local function trackTreeName(name)
  definedTreeNames[#definedTreeNames + 1] = name
end

---Define a tree under `TREE_NAME` for the running test.
---@param spec table the root group
---@param options table|nil the `Define` options
---@return any tree
local function defineTree(spec, options)
  trackTreeName(TREE_NAME)
  return OptionsKit:Define(TREE_NAME, spec, options)
end

---Connect a listener that records every `OnChange` of `tree`, in order.
---`Undefine` disconnects it.
---@param tree any
---@return { path: string, value: any }[] changes
local function recordChanges(tree)
  local changes = {}
  tree:OnChange(function(_, path, value)
    changes[#changes + 1] = { path = path, value = value }
  end)
  return changes
end

---Check the change recorded at `index`.
---@param ctx TestKit.Context
---@param changes { path: string, value: any }[]
---@param index integer
---@param path string
---@param value any
local function expectChange(ctx, changes, index, path, value)
  local change = changes[index]
  ctx:Expect(type(change)):ToBe("table")
  if type(change) ~= "table" then
    return
  end
  ctx:Expect(change.path):ToBe(path)
  ctx:Expect(change.value):ToBe(value)
end

---The node of a `Describe` result at `path`, or `nil`.
---@param node table
---@param path string
---@return table|nil
local function findNode(node, path)
  if node.path == path then
    return node
  end
  for _, child in ipairs(node.children or {}) do
    local found = findNode(child, path)
    if type(found) ~= "nil" then
      return found
    end
  end
  return nil
end

---The node at `path`, or a failed test.
---@param ctx TestKit.Context
---@param description table
---@param path string
---@return table
local function requireNode(ctx, description, path)
  local node = findNode(description, path)
  if type(node) == "nil" then
    ctx:Fail("Describe has no node at " .. path)
  end
  ---@cast node table
  return node
end

---Whether `names` holds `wanted`.
---@param names string[]
---@param wanted string
---@return boolean
local function listContains(names, wanted)
  for _, name in ipairs(names) do
    if name == wanted then
      return true
    end
  end
  return false
end

-- The probe CVar ------------------------------------------------------------------------------

---The probe CVar's value through `C_CVar.GetCVar`, or `nil`.
---@return string|nil
local function currentProbeValue()
  local getCVar = readHostFunction("C_CVar", "GetCVar")
  if type(getCVar) == "nil" then
    return nil
  end
  local value = getCVar(PROBE_CVAR)
  if type(value) ~= "string" or isSecret(value) then
    return nil
  end
  return value
end

---Set the probe CVar through `C_CVar.SetCVar`.
---@param value string
local function writeProbeCVar(value)
  local setCVar = readHostFunction("C_CVar", "SetCVar")
  if type(setCVar) == "nil" then
    error("the client has no C_CVar.SetCVar", 2)
  end
  ---@cast setCVar function
  setCVar(PROBE_CVAR, value)
end

---The probe CVar's value before the test changes it, or a failed test. The
---first call of a test schedules that value's restore for the After hook.
---@param ctx TestKit.Context
---@return string original
local function requireProbeValue(ctx)
  local original = currentProbeValue()
  if type(original) == "nil" then
    ctx:Fail("C_CVar.GetCVar is missing or does not know the CVar " .. PROBE_CVAR)
  end
  ---@cast original string
  if #pendingRestores == 0 then
    pendingRestores[#pendingRestores + 1] = function()
      if currentProbeValue() ~= original then
        writeProbeCVar(original)
      end
    end
  end
  return original
end

---A toggle over the probe CVar: `get` asks `C_CVar.GetCVar`, `set` calls
---`C_CVar.SetCVar` and counts its calls in `setCount.calls`.
---@param setCount { calls: integer }
---@return table option
local function newChatBubblesOption(setCount)
  return {
    type = "toggle",
    name = "Chat bubbles",
    get = function()
      return currentProbeValue() == "1"
    end,
    set = function(_, shown)
      setCount.calls = setCount.calls + 1
      writeProbeCVar(shown and "1" or "0")
    end,
  }
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
  ctx:Expect((file or ""):sub(-#"OptionsKitSuite.lua")):ToBe("OptionsKitSuite.lua")
  return line
end

---Call `raise`, which must record its start line with `currentLine()` and
---raise on the next line, and check that the message names this file at that
---next line and ends with `expected`.
---@param ctx TestKit.Context
---@param raise fun() Records its start line in `lineBox.start`, then raises on the next line.
---@param lineBox { start: integer }
---@param expected string The message after the position, compared literally.
local function expectErrorAtCallingLine(ctx, raise, lineBox, expected)
  local succeeded, message = pcall(raise)
  ctx:Expect(succeeded):ToBe(false)
  local line = expectThisFile(ctx, message)
  if type(line) ~= "nil" then
    ctx:Log("client message: " .. message)
    ctx:Expect(message:sub(-#expected)):ToBe(expected)
  end
  ctx:Expect(line):ToBe(lineBox.start + 1)
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
---The full collection runs in a step of its own, so the measurement starts
---far from the next collector cycle, which would otherwise shrink the count
---mid-measurement and hide an allocation. One cycle then runs unmeasured: a
---full collection shrinks the test coroutine's Lua stack, and the first call
---grows it again, once, which is the coroutine's cost, not OptionsKit's.
---@param ctx TestKit.Context
---@param label string what `cycle` does, for the log
---@param cycle fun()
local function expectNoAllocation(ctx, label, cycle)
  collectgarbage("collect")
  ctx:Yield()
  runCycles(cycle, 1)
  local grownKilobytes = measureAllocation(function()
    runCycles(cycle, ALLOCATION_CYCLES)
  end)
  ctx:Log(("memory delta over %s: %.3f KB"):format(label, grownKilobytes))
  ctx:Expect(grownKilobytes <= ALLOCATION_TOLERANCE_KB):ToBe(true)
end

-- optionsKit.facade ---------------------------------------------------------------------------

local facade = newSuite("facade")

facade:Test(
  "Registry:Get('optionsKit', 1) is the OptionsKit facade with API 1, Define, Get, Undefine, ProfileOptions, MAX_OPTIONS 1024, MAX_DEPTH 8, UNBOUNDED and a Tree prototype with its ten methods",
  function(ctx)
    ctx:Expect(type(OptionsKit)):ToBe("table")
    ctx:Expect(rawget(OptionsKit, "API")):ToBe(OPTIONS_KIT_API)
    for _, functionName in ipairs({ "Define", "Get", "Undefine", "ProfileOptions" }) do
      ctx:Expect(type(rawget(OptionsKit, functionName))):ToBe("function")
    end
    ctx:Expect(rawget(OptionsKit, "MAX_OPTIONS")):ToBe(1024)
    ctx:Expect(rawget(OptionsKit, "MAX_DEPTH")):ToBe(8)
    ctx:Expect(type(rawget(OptionsKit, "UNBOUNDED"))):ToBe("table")
    local prototype = rawget(OptionsKit, "Tree")
    ctx:Expect(type(prototype)):ToBe("table")
    for _, methodName in ipairs({
      "Get",
      "Set",
      "Validate",
      "Reset",
      "Execute",
      "IsDisabled",
      "IsHidden",
      "Walk",
      "Describe",
      "OnChange",
    }) do
      ctx:Expect(type(rawget(prototype, methodName))):ToBe("function")
    end
  end
)

facade:Test("the installed OptionsKit carries the revision of the committed manifest", function(ctx)
  local expectedPackages = Harness:GetExpectedPackages()
  if type(expectedPackages) == "nil" then
    ctx:Fail("Expected.lua is missing; install with python3 -m tooling.client.install")
    return
  end
  for _, expected in ipairs(expectedPackages) do
    if expected.id == PACKAGE_ID then
      local _, revision = Registry:Get(PACKAGE_ID, OPTIONS_KIT_API)
      ctx:Expect(revision):ToBe(expected.revision)
      ctx:Expect(rawget(OptionsKit, "REVISION")):ToBe(expected.revision)
      return
    end
  end
  ctx:Fail("Expected.lua does not list optionsKit")
end)

facade:Test(
  "the host facilities OptionsKit finds at call time are present: SettingsKit API 1 through Registry:Find, and UnitName('player') and GetRealmName() as plain non-empty strings",
  function(ctx)
    local found, revisionOrReason = Registry:Find("settingsKit", SETTINGS_KIT_API)
    ctx:Log("Registry:Find('settingsKit', 1) revision or reason: " .. tostring(revisionOrReason))
    ctx:Expect(type(found)):ToBe("table")
    ctx:Expect(found):ToBe(SettingsKit)
    local characterKey = readCharacterKey()
    ctx:Log("character profile from the client: " .. tostring(characterKey))
    ctx:Expect(type(characterKey)):ToBe("string")
    ctx:Log("issecretvalue: " .. type(isSecretValue) .. ", secretwrap: " .. type(secretWrap))
  end
)

-- optionsKit.cvar -----------------------------------------------------------------------------

local cvar = newSuite("cvar")

cvar:Test(
  "a toggle whose get and set call C_CVar on chatBubbles reads the client's value, and each Set changes the CVar before it returns and fires OnChange while GetCVar already answers the new value",
  function(ctx)
    local original = requireProbeValue(ctx)
    local setCount = { calls = 0 }
    local tree = defineTree({ type = "group", args = { bubbles = newChatBubblesOption(setCount) } })
    local seen = {}
    tree:OnChange(function(_, path, value)
      seen[#seen + 1] = { path = path, value = value, probe = currentProbeValue() }
    end)
    ctx:Log("chatBubbles before the test: " .. original)
    ctx:Expect(tree:Get("bubbles")):ToBe(original == "1")

    local target = original ~= "1"
    for step, value in ipairs({ target, not target }) do
      local written, message = tree:Set("bubbles", value)
      ctx:Expect(written):ToBe(true)
      ctx:Expect(message):ToBeNil()
      ctx:Expect(currentProbeValue()):ToBe(value and "1" or "0")
      ctx:Expect(tree:Get("bubbles")):ToBe(value)
      ctx:Expect(#seen):ToBe(step)
      local change = seen[step] or {}
      ctx:Expect(change.path):ToBe("bubbles")
      ctx:Expect(change.value):ToBe(value)
      ctx:Expect(change.probe):ToBe(value and "1" or "0")
    end
    ctx:Expect(setCount.calls):ToBe(2)
    ctx:Expect(currentProbeValue()):ToBe(original)
  end
)

cvar:Test(
  "a validate refusal returns false with its message and a string '1' raises at OptionsKitSuite.lua:<line> as expected boolean, and neither reaches C_CVar.SetCVar",
  function(ctx)
    local original = requireProbeValue(ctx)
    local setCount = { calls = 0 }
    local option = newChatBubblesOption(setCount)
    option.validate = function()
      return false, "chat bubbles are locked for this test"
    end
    local tree = defineTree({ type = "group", args = { bubbles = option } })
    local changes = recordChanges(tree)

    local written, message = tree:Set("bubbles", original ~= "1")
    ctx:Expect(written):ToBe(false)
    ctx:Expect(message):ToBe("chat bubbles are locked for this test")
    ctx:Expect(tree:Validate("bubbles", "1")):ToBe(false)
    ctx:Expect(select(2, tree:Validate("bubbles", "1"))):ToBe("expected boolean, found string")

    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      tree:Set("bubbles", "1")
    end, lines, "OptionsKit.Tree:Set bubbles: expected boolean, found string")

    ctx:Expect(setCount.calls):ToBe(0)
    ctx:Expect(#changes):ToBe(0)
    ctx:Expect(currentProbeValue()):ToBe(original)
  end
)

cvar:Test(
  "a disabled predicate and a desc function that read chatBubbles follow a change made through the tree: IsDisabled flips and Describe rewrites the description",
  function(ctx)
    local original = requireProbeValue(ctx)
    local size = 1
    local tree = defineTree({
      type = "group",
      args = {
        bubbles = newChatBubblesOption({ calls = 0 }),
        size = {
          type = "range",
          name = "Bubble size",
          min = 0.5,
          max = 2,
          disabled = function()
            return currentProbeValue() ~= "1"
          end,
          desc = function(info)
            local state = currentProbeValue() == "1" and "shown" or "hidden"
            return info.path .. " follows chat bubbles, now " .. state
          end,
          get = function()
            return size
          end,
          set = function(_, value)
            size = value
          end,
        },
      },
    })

    for _, shown in ipairs({ original ~= "1", original == "1" }) do
      ctx:Expect(tree:Set("bubbles", shown)):ToBe(true)
      ctx:Expect(tree:IsDisabled("size")):ToBe(not shown)
      ctx:Expect(tree:IsHidden("size")):ToBe(false)
      local description = tree:Describe()
      local node = requireNode(ctx, description, "size")
      local expectedDesc = "size follows chat bubbles, now " .. (shown and "shown" or "hidden")
      ctx:Expect(node.desc):ToBe(expectedDesc)
      ctx:Expect(node.disabled):ToBe(not shown)
      ctx:Expect(requireNode(ctx, description, "bubbles").value):ToBe(shown)
      ctx:Log("described with chatBubbles " .. tostring(currentProbeValue()) .. ": " .. node.desc)
    end
    ctx:Expect(currentProbeValue()):ToBe(original)
  end
)

-- optionsKit.database -------------------------------------------------------------------------

local database = newSuite("database")

database:Test(
  "a range bound to profile.chat.scale in a real SettingsKit database reads its default 1, Set stores 1.25 in the in-memory table's default profile, and Reset clears it and answers 1 again, each with OnChange",
  function(ctx)
    local db = freshDatabase(ctx)
    local defaultProfile = rawget(SettingsKit, "DEFAULT_PROFILE")
    local tree = defineTree({
      type = "group",
      args = {
        scale = { type = "range", name = "Scale", min = 0.5, max = 2, bind = "profile.chat.scale" },
      },
    }, { db = db })
    local changes = recordChanges(tree)

    ctx:Expect(db:GetProfile()):ToBe(defaultProfile)
    ctx:Expect(tree:Get("scale")):ToBe(1)
    ctx:Expect(tree:Set("scale", 1.25)):ToBe(true)
    ctx:Expect(tree:Get("scale")):ToBe(1.25)
    ctx:Expect(db.profile.chat.scale):ToBe(1.25)
    local stored = databaseTable().profiles[defaultProfile]
    ctx:Expect(type(stored)):ToBe("table")
    ctx:Expect(type(stored.chat)):ToBe("table")
    ctx:Expect((stored.chat or {}).scale):ToBe(1.25)

    local node = requireNode(ctx, tree:Describe(), "scale")
    ctx:Expect(node.value):ToBe(1.25)
    ctx:Expect(node.bind):ToBe("profile.chat.scale")

    ctx:Expect(tree:Reset("scale")):ToBe(1)
    ctx:Expect(tree:Get("scale")):ToBe(1)
    ctx:Expect((stored.chat or {}).scale):ToBeNil()
    ctx:Expect(#changes):ToBe(2)
    expectChange(ctx, changes, 1, "scale", 1.25)
    expectChange(ctx, changes, 2, "scale", 1)
  end
)

database:Test(
  "an input bound to char.note stores its text under the key '<UnitName> - <GetRealmName>' the client answers, and Reset brings back the default empty text",
  function(ctx)
    local characterKey = requireCharacterKey(ctx)
    local db = freshDatabase(ctx)
    local tree = defineTree({
      type = "group",
      args = { note = { type = "input", name = "Note", bind = "char.note" } },
    }, { db = db })

    ctx:Expect(tree:Get("note")):ToBe("")
    ctx:Expect(tree:Set("note", "stored for this character")):ToBe(true)
    local characters = databaseTable().char
    ctx:Expect(type(characters)):ToBe("table")
    local entry = (characters or {})[characterKey]
    ctx:Log("char scope key: " .. characterKey)
    ctx:Expect(type(entry)):ToBe("table")
    ctx:Expect((entry or {}).note):ToBe("stored for this character")
    ctx:Expect(tree:Get("note")):ToBe("stored for this character")
    ctx:Expect(tree:Reset("note")):ToBe("")
  end
)

database:Test(
  "with a SettingsKit field narrower than the option, Validate answers SettingsKit's own message and Set raises it at OptionsKitSuite.lua:<line> after 'refused by the database', storing nothing",
  function(ctx)
    local db = freshDatabase(ctx)
    local tree = defineTree({
      type = "group",
      args = {
        width = { type = "range", name = "Width", min = 0, max = 10, bind = "profile.chat.width" },
      },
    }, { db = db })
    local changes = recordChanges(tree)
    local refusal = "SettingsKit ("
      .. DATABASE_NAME
      .. ") profile.chat.width: expected number <= 3, found larger number"

    local accepted, message = tree:Validate("width", 5)
    ctx:Expect(accepted):ToBe(false)
    ctx:Expect(message):ToBe(refusal)

    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      tree:Set("width", 5)
    end, lines, "OptionsKit.Tree:Set width refused by the database: " .. refusal)

    ctx:Expect(tree:Get("width")):ToBeNil()
    ctx:Expect(#changes):ToBe(0)
    ctx:Expect(tree:Validate("width", 2)):ToBe(true)
    ctx:Expect(tree:Set("width", 2)):ToBe(true)
    ctx:Expect(tree:Get("width")):ToBe(2)
  end
)

-- optionsKit.profiles -------------------------------------------------------------------------

local profiles = newSuite("profiles")

---Define a tree holding a bound `scale` option and the profile group over
---`db`, at `profiles`.
---@param db any
---@return any tree
local function defineProfileTree(db)
  return defineTree({
    type = "group",
    args = {
      scale = { type = "range", name = "Scale", min = 0.5, max = 2, bind = "profile.chat.scale" },
      profiles = OptionsKit:ProfileOptions(db, { order = 90 }),
    },
  }, { db = db })
end

---A profile string with the current profile's name in quotes, as the group
---fills its `%s`.
---@param template string
---@param profileName string
---@return string
local function withProfileName(template, profileName)
  return (template:gsub("%%s", function()
    return '"' .. profileName .. '"'
  end))
end

profiles:Test(
  "ProfileOptions offers the character profile '<UnitName> - <GetRealmName>' beside the database's default profile, and Describe fills the group's and the options' desc functions with the current profile's name",
  function(ctx)
    local characterKey = requireCharacterKey(ctx)
    local db = freshDatabase(ctx)
    local defaultProfile = rawget(SettingsKit, "DEFAULT_PROFILE")
    local tree = defineProfileTree(db)
    ctx:Log("character profile offered: " .. characterKey)

    local description = tree:Describe()
    local group = requireNode(ctx, description, "profiles")
    ctx:Expect(group.name):ToBe("Profiles")
    ctx
      :Expect(group.desc)
      :ToBe(withProfileName("This character uses the profile %s.", defaultProfile))

    local current = requireNode(ctx, description, "profiles.current")
    ctx:Expect(current.value):ToBe(defaultProfile)
    ctx:Expect(type(current.values)):ToBe("table")
    local values = current.values or {}
    ctx:Expect(values[characterKey]):ToBe(characterKey)
    ctx:Expect(values[defaultProfile]):ToBe(defaultProfile)
    ctx:Expect(current.desc):ToBe(
      withProfileName(
        "The profile this character uses, now %s. Choosing a name that has no profile yet creates an empty one.",
        defaultProfile
      )
    )
    ctx
      :Expect(requireNode(ctx, description, "profiles.reset").desc)
      :ToBe(withProfileName("Return every setting of %s to its default.", defaultProfile))
    ctx:Expect(requireNode(ctx, description, "profiles.new").value):ToBe("")
    ctx:Expect(requireNode(ctx, description, "profiles.new").usage):ToBe("<profile name>")
    ctx:Expect(next(requireNode(ctx, description, "profiles.copySource").values or {})):ToBeNil()
    ctx:Expect(requireNode(ctx, description, "profiles.copy").disabled):ToBe(true)
    ctx:Expect(requireNode(ctx, description, "profiles.delete").disabled):ToBe(true)
  end
)

profiles:Test(
  "Set of profiles.current to the character profile switches the database, which records the choice under the same key, fires OnChange once, and a bound option reads the new profile at once",
  function(ctx)
    local characterKey = requireCharacterKey(ctx)
    local db = freshDatabase(ctx)
    local tree = defineProfileTree(db)
    ctx:Expect(tree:Set("scale", 1.5)):ToBe(true)
    local changes = recordChanges(tree)

    ctx:Expect(tree:Set("profiles.current", characterKey)):ToBe(true)
    ctx:Expect(db:GetProfile()):ToBe(characterKey)
    ctx:Expect(tree:Get("profiles.current")):ToBe(characterKey)
    ctx:Expect(#changes):ToBe(1)
    expectChange(ctx, changes, 1, "profiles.current", characterKey)

    local profileKeys = databaseTable().profileKeys
    ctx:Expect(type(profileKeys)):ToBe("table")
    ctx:Expect((profileKeys or {})[characterKey]):ToBe(characterKey)

    ctx:Expect(tree:Get("scale")):ToBe(1)
    ctx
      :Expect(requireNode(ctx, tree:Describe(), "profiles").desc)
      :ToBe(withProfileName("This character uses the profile %s.", characterKey))
  end
)

profiles:Test(
  "profiles.new creates and switches to a typed profile with OnChange for profiles.current then profiles.new, and answers a blank or an over-long name with a message instead of raising",
  function(ctx)
    local db = freshDatabase(ctx)
    local defaultProfile = rawget(SettingsKit, "DEFAULT_PROFILE")
    local tree = defineProfileTree(db)
    local changes = recordChanges(tree)

    ctx:Expect(tree:Set("profiles.new", CREATED_PROFILE)):ToBe(true)
    ctx:Expect(db:GetProfile()):ToBe(CREATED_PROFILE)
    ctx:Expect(listContains(db:GetProfiles(), CREATED_PROFILE)):ToBe(true)
    ctx:Expect(tree:Get("profiles.new")):ToBe("")
    ctx:Expect(#changes):ToBe(2)
    expectChange(ctx, changes, 1, "profiles.current", CREATED_PROFILE)
    expectChange(ctx, changes, 2, "profiles.new", CREATED_PROFILE)

    local blankMessage = "a profile name needs a character other than whitespace"
    local accepted, message = tree:Validate("profiles.new", "   ")
    ctx:Expect(accepted):ToBe(false)
    ctx:Expect(message):ToBe(blankMessage)
    accepted, message = tree:Set("profiles.new", "   ")
    ctx:Expect(accepted):ToBe(false)
    ctx:Expect(message):ToBe(blankMessage)

    local maxLength = SettingsKit:GetLimits().maxProfileNameLength
    ctx:Log("maxProfileNameLength in this session: " .. tostring(maxLength))
    accepted, message = tree:Validate("profiles.new", string.rep("a", maxLength + 1))
    ctx:Expect(accepted):ToBe(false)
    ctx:Expect(message):ToBe(("a profile name has at most %d bytes"):format(maxLength))
    ctx:Expect(tree:Validate("profiles.new", string.rep("a", maxLength))):ToBe(true)

    ctx:Expect(db:GetProfile()):ToBe(CREATED_PROFILE)
    ctx:Expect(#changes):ToBe(2)
    ctx:Expect(listContains(db:GetProfiles(), defaultProfile)):ToBe(true)
  end
)

profiles:Test(
  "copy and delete stay disabled until their select names another profile, Execute of copy before that raises at OptionsKitSuite.lua:<line>, copying brings the other profile's bound value and deleting removes the profile",
  function(ctx)
    local db = freshDatabase(ctx)
    local defaultProfile = rawget(SettingsKit, "DEFAULT_PROFILE")
    local tree = defineProfileTree(db)
    ctx:Expect(tree:Set("scale", 1.75)):ToBe(true)
    ctx:Expect(tree:Set("profiles.new", CREATED_PROFILE)):ToBe(true)
    ctx:Expect(tree:Get("scale")):ToBe(1)
    ctx:Expect(tree:IsDisabled("profiles.copy")):ToBe(true)

    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      tree:Execute("profiles.copy")
    end, lines, 'OptionsKit.Tree:Execute profiles.copy needs "profiles.copySource" to be set first')

    ctx:Expect(tree:Set("profiles.copySource", defaultProfile)):ToBe(true)
    ctx:Expect(tree:IsDisabled("profiles.copy")):ToBe(false)
    local changes = recordChanges(tree)
    tree:Execute("profiles.copy")
    ctx:Expect(tree:Get("scale")):ToBe(1.75)
    ctx:Expect(#changes):ToBe(1)
    expectChange(ctx, changes, 1, "profiles.current", CREATED_PROFILE)

    ctx:Expect(tree:Set("profiles.current", defaultProfile)):ToBe(true)
    ctx:Expect(tree:IsDisabled("profiles.delete")):ToBe(true)
    ctx:Expect(tree:Set("profiles.deleteTarget", CREATED_PROFILE)):ToBe(true)
    ctx:Expect(tree:IsDisabled("profiles.delete")):ToBe(false)
    local before = #changes
    tree:Execute("profiles.delete")
    ctx:Expect(listContains(db:GetProfiles(), CREATED_PROFILE)):ToBe(false)
    ctx:Expect(tree:Get("profiles.deleteTarget")):ToBeNil()
    ctx:Expect(tree:IsDisabled("profiles.delete")):ToBe(true)
    ctx:Expect(#changes - before):ToBe(1)
    expectChange(ctx, changes, #changes, "profiles.current", defaultProfile)
  end
)

profiles:Test(
  "a switch made directly on the database reaches the tree's OnChange as profiles.current with the new name, and after Undefine the database's switches reach the tree no more",
  function(ctx)
    local db = freshDatabase(ctx)
    local defaultProfile = rawget(SettingsKit, "DEFAULT_PROFILE")
    local tree = defineProfileTree(db)
    local changes = recordChanges(tree)

    ctx:Expect(db:SetProfile(DIRECT_PROFILE)):ToBe(true)
    ctx:Expect(#changes):ToBe(1)
    expectChange(ctx, changes, 1, "profiles.current", DIRECT_PROFILE)

    ctx:Expect(OptionsKit:Undefine(TREE_NAME)):ToBe(true)
    ctx:Expect(db:SetProfile(defaultProfile)):ToBe(true)
    ctx:Expect(#changes):ToBe(1)
  end
)

-- optionsKit.clientLua ------------------------------------------------------------------------

local clientLua = newSuite("clientLua")

--- Input patterns the agreement test defines, each on an option of its own.
local INPUT_PATTERNS = {
  words = "^[%w ]*$",
  letters = "^%a+$",
  noEscape = "^[^|]*$",
}

--- Subjects each input pattern is tried on: empty, ASCII words, UTF-8 text,
--- a colour-escaped name and a control byte.
local INPUT_SUBJECTS = {
  "",
  "Raid alerts",
  UTF8_WORD,
  "|cff33ccffMoltenCodes|r",
  "tab\there",
}

clientLua:Test(
  "Validate of three inputs with a pattern agrees with the client's own string.find on empty, ASCII, UTF-8, colour-escaped and control-byte text",
  function(ctx)
    local args = {}
    for key, pattern in pairs(INPUT_PATTERNS) do
      local text = ""
      args[key] = {
        type = "input",
        name = key,
        pattern = pattern,
        get = function()
          return text
        end,
        set = function(_, value)
          text = value
        end,
      }
    end
    local tree = defineTree({ type = "group", args = args })

    local mismatches = 0
    for key, pattern in pairs(INPUT_PATTERNS) do
      local answers = {}
      for _, subject in ipairs(INPUT_SUBJECTS) do
        local clientAccepts = type(string.find(subject, pattern)) ~= "nil"
        local accepted = tree:Validate(key, subject)
        if accepted ~= clientAccepts then
          mismatches = mismatches + 1
        end
        answers[#answers + 1] = clientAccepts and "1" or "0"
      end
      ctx:Log(("%q: %s"):format(pattern, table.concat(answers)))
    end
    ctx:Expect(mismatches):ToBe(0)
  end
)

clientLua:Test(
  "Validate answers SchemaKit's phrases as the client prints them: range bounds 2 and 0.33333333333333, a select's sorted keys, a multiselect key, a colour's nested field and a toggle's type",
  function(ctx)
    local store = {}
    ---A get/set pair over `store[key]`.
    ---@param key string
    ---@return fun(): any get
    ---@return fun(info: any, value: any) set
    local function accessors(key)
      return function()
        return store[key]
      end, function(_, value)
        store[key] = value
      end
    end
    local getScale, setScale = accessors("scale")
    local getAnchor, setAnchor = accessors("anchor")
    local getChannels, setChannels = accessors("channels")
    local getTint, setTint = accessors("tint")
    local getShown, setShown = accessors("shown")
    local tree = defineTree({
      type = "group",
      args = {
        scale = {
          type = "range",
          name = "Scale",
          min = 1 / 3,
          max = 2,
          get = getScale,
          set = setScale,
        },
        anchor = {
          type = "select",
          name = "Anchor",
          values = { TOP = "Top", CENTER = "Centre", BOTTOM = "Bottom" },
          get = getAnchor,
          set = setAnchor,
        },
        channels = {
          type = "multiselect",
          name = "Channels",
          values = { SAY = "Say", PARTY = "Party" },
          get = getChannels,
          set = setChannels,
        },
        tint = { type = "color", name = "Tint", get = getTint, set = setTint },
        shown = { type = "toggle", name = "Shown", get = getShown, set = setShown },
      },
    })

    local cases = {
      { path = "scale", value = 3, message = "expected number <= 2, found larger number" },
      {
        path = "scale",
        value = 0,
        message = "expected number >= 0.33333333333333, found smaller number",
      },
      {
        path = "anchor",
        value = "LEFT",
        message = 'expected one of "BOTTOM", "CENTER", "TOP", found unlisted string',
      },
      {
        path = "channels",
        value = { YELL = true },
        message = 'YELL: expected key one of "PARTY", "SAY", found unlisted string',
      },
      {
        path = "tint",
        value = { r = 2, g = 0, b = 0 },
        message = "r: expected number <= 1, found larger number",
      },
      { path = "shown", value = 1, message = "expected boolean, found number" },
    }
    for _, case in ipairs(cases) do
      local accepted, message = tree:Validate(case.path, case.value)
      ctx:Log(case.path .. ": " .. tostring(message))
      ctx:Expect(accepted):ToBe(false)
      ctx:Expect(message):ToBe(case.message)
    end
    ctx:Expect(tree:Validate("scale", 1 / 3)):ToBe(true)
    ctx:Expect(tree:Validate("channels", { SAY = true, PARTY = false })):ToBe(true)
    ctx:Expect(next(store)):ToBeNil()
  end
)

-- optionsKit.allocation -----------------------------------------------------------------------

local allocation = newSuite("allocation")

---Define the tree the allocation guards measure: getter options over plain
---Lua values, with `validate`, predicates and an `OnChange` listener, as the
---Busted allocation spec does, plus `extraArgs` when given.
---@param store table the values the getters read
---@param extraArgs table|nil more options for the root group
---@param options table|nil the `Define` options
---@return any tree
local function defineMeasuredTree(store, extraArgs, options)
  local args = {
    general = {
      type = "group",
      name = "General",
      hidden = function()
        return store.hideGeneral
      end,
      args = {
        scale = {
          type = "range",
          name = "Scale",
          min = 0.5,
          max = 2,
          disabled = function()
            return store.locked
          end,
          validate = function()
            return true
          end,
          get = function()
            return store.scale
          end,
          set = function(_, value)
            store.scale = value
          end,
        },
        enabled = {
          type = "toggle",
          name = "Enabled",
          get = function()
            return store.enabled
          end,
          set = function(_, value)
            store.enabled = value
          end,
        },
        mode = {
          type = "select",
          name = "Mode",
          values = { a = "A", b = "B" },
          get = function()
            return store.mode
          end,
          set = function(_, value)
            store.mode = value
          end,
        },
        tint = {
          type = "color",
          name = "Tint",
          get = function()
            return store.tint
          end,
          set = function(_, value)
            store.tint = value
          end,
        },
      },
    },
  }
  for key, option in pairs(extraArgs or {}) do
    args[key] = option
  end
  local tree = defineTree({ type = "group", args = args }, options)
  tree:OnChange(function() end)
  return tree
end

---Fresh values for `defineMeasuredTree`.
---@return table
local function newMeasuredStore()
  return {
    hideGeneral = false,
    locked = false,
    scale = 1,
    enabled = true,
    mode = "a",
    tint = { r = 1, g = 1, b = 1 },
  }
end

allocation:Test(
  "Get and Set of a range with validate, a toggle, a select and a colour through getters, with an OnChange listener connected, allocate nothing over 5000 cycles",
  function(ctx)
    local store = newMeasuredStore()
    local tree = defineMeasuredTree(store, nil, nil)
    local tint = { r = 0.5, g = 0.5, b = 0.5 }
    expectNoAllocation(ctx, "Get and Set of four getter options", function()
      tree:Get("general.scale")
      tree:Set("general.scale", 1.5)
      tree:Get("general.enabled")
      tree:Set("general.enabled", false)
      tree:Get("general.mode")
      tree:Set("general.mode", "b")
      tree:Get("general.tint")
      tree:Set("general.tint", tint)
    end)
    ctx:Expect(store.scale):ToBe(1.5)
    ctx:Expect(store.tint):ToBe(tint)
  end
)

allocation:Test(
  "Get and Set of a range bound to the real SettingsKit database, after its first write, allocate nothing over 5000 cycles",
  function(ctx)
    local db = freshDatabase(ctx)
    local store = newMeasuredStore()
    local tree = defineMeasuredTree(store, {
      bound = { type = "range", name = "Bound", min = 0.5, max = 2, bind = "profile.chat.scale" },
    }, { db = db })
    ctx:Expect(tree:Set("bound", 1.25)):ToBe(true)
    expectNoAllocation(ctx, "Get and Set of a bound range", function()
      tree:Get("bound")
      tree:Set("bound", 1.25)
    end)
    ctx:Expect(db.profile.chat.scale):ToBe(1.25)
  end
)

allocation:Test(
  "Walk, Validate of a valid value, IsDisabled and IsHidden with predicates on the option and its group allocate nothing over 5000 cycles",
  function(ctx)
    local store = newMeasuredStore()
    local tree = defineMeasuredTree(store, nil, nil)
    local visited = 0
    local function visitor()
      visited = visited + 1
    end
    ctx:Expect(tree:Walk(visitor)):ToBe(5)
    expectNoAllocation(ctx, "Walk", function()
      tree:Walk(visitor)
    end)
    expectNoAllocation(ctx, "Validate, IsDisabled and IsHidden", function()
      tree:Validate("general.scale", 1)
      tree:IsDisabled("general.scale")
      tree:IsHidden("general.scale")
    end)
    ctx:Expect(visited):ToBe(5 * (ALLOCATION_CYCLES + 2))
  end
)

-- optionsKit.errors ---------------------------------------------------------------------------

local errors = newSuite("errors")

---A range option over a local number, for the error tests.
---@param extraFields table|nil fields to add or replace
---@return table option
local function newRangeOption(extraFields)
  local value = 1
  local option = {
    type = "range",
    name = "Size",
    min = 0.5,
    max = 2,
    get = function()
      return value
    end,
    set = function(_, newValue)
      value = newValue
    end,
  }
  for field, fieldValue in pairs(extraFields or {}) do
    option[field] = fieldValue
  end
  return option
end

errors:Test(
  "Define refuses a misspelt field, a min above max, a root that is not a group and a bind without a database at OptionsKitSuite.lua:<line>, naming the field by its path, and registers nothing",
  function(ctx)
    local cases = {
      {
        spec = { type = "group", args = { size = newRangeOption({ witdh = 2 }) } },
        message = 'OptionsKit:Define tree.args.size contains unknown field "witdh" for type "range"',
      },
      {
        spec = { type = "group", args = { size = newRangeOption({ min = 2, max = 1 }) } },
        message = "OptionsKit:Define tree.args.size.min must not be greater than max",
      },
      {
        spec = newRangeOption(nil),
        message = 'OptionsKit:Define tree.type must be "group" at the root',
      },
      {
        spec = {
          type = "group",
          args = {
            size = { type = "range", name = "Size", min = 0, max = 1, bind = "profile.size" },
          },
        },
        message = "OptionsKit:Define tree.args.size.bind needs a SettingsKit database passed as options.db",
      },
    }
    trackTreeName(TREE_NAME)
    for _, case in ipairs(cases) do
      local lines = { start = 0 }
      expectErrorAtCallingLine(ctx, function()
        lines.start = currentLine()
        OptionsKit:Define(TREE_NAME, case.spec)
      end, lines, case.message)
      ctx:Expect(OptionsKit:Get(TREE_NAME)):ToBeNil()
    end
  end
)

errors:Test(
  "tree methods refuse an unknown path, a group as a value, a value out of range, Reset of an option without a database, Execute of a range and UIParent as the tree at OptionsKitSuite.lua:<line>",
  function(ctx)
    local tree = defineTree({
      type = "group",
      args = { group = { type = "group", name = "Group", args = { size = newRangeOption(nil) } } },
    })
    -- Each case records its own line just before the call that must raise,
    -- because the error names the line of that call, inside the case.
    local cases = {
      {
        call = function(lineBox)
          lineBox.start = currentLine()
          tree:Get("nothing")
        end,
        message = 'OptionsKit.Tree:Get unknown path "nothing"',
      },
      {
        call = function(lineBox)
          lineBox.start = currentLine()
          tree:Set("group", true)
        end,
        message = 'OptionsKit.Tree:Set path "group" is a group, not a value option',
      },
      {
        call = function(lineBox)
          lineBox.start = currentLine()
          tree:Set("group.size", 3)
        end,
        message = "OptionsKit.Tree:Set group.size: expected number <= 2, found larger number",
      },
      {
        call = function(lineBox)
          lineBox.start = currentLine()
          tree:Reset("group.size")
        end,
        message = 'OptionsKit.Tree:Reset path "group.size" is not bound to a database and has no default',
      },
      {
        call = function(lineBox)
          lineBox.start = currentLine()
          tree:Execute("group.size")
        end,
        message = 'OptionsKit.Tree:Execute path "group.size" is not an execute option',
      },
      {
        call = function(lineBox)
          lineBox.start = currentLine()
          rawget(OptionsKit, "Tree").Get(uiParent, "group.size")
        end,
        message = "OptionsKit.Tree:Get must be called on an OptionsKit tree",
      },
    }
    for _, case in ipairs(cases) do
      local lines = { start = 0 }
      expectErrorAtCallingLine(ctx, function()
        case.call(lines)
      end, lines, case.message)
    end
    ctx:Expect(tree:Get("group.size")):ToBe(1)
  end
)

errors:Test(
  "Describe raises at OptionsKitSuite.lua:<line> when a desc function returns no string, and an error raised by a getter reaches the caller of Get unchanged, from the getter's own line",
  function(ctx)
    local lines = { start = 0, getter = 0 }
    local failing = false
    local tree = defineTree({
      type = "group",
      args = {
        size = newRangeOption({
          desc = function()
            return nil
          end,
        }),
        broken = {
          type = "toggle",
          name = "Broken",
          get = function()
            lines.getter = currentLine() + 2
            if failing then
              error("getter failed on purpose")
            end
            return true
          end,
          set = function() end,
        },
      },
    })
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      tree:Describe()
    end, lines, 'OptionsKit.Tree:Describe desc function of "size" returned no string')

    failing = true
    local succeeded, message = pcall(tree.Get, tree, "broken")
    ctx:Expect(succeeded):ToBe(false)
    local line = expectThisFile(ctx, message)
    ctx:Expect(line):ToBe(lines.getter)
    ctx:Expect(tostring(message):sub(-#"getter failed on purpose")):ToBe("getter failed on purpose")
  end
)

errors:Test(
  "a second Define of one addon name raises at OptionsKitSuite.lua:<line>, Undefine answers true then false, and the old handle refuses every method as an undefined tree",
  function(ctx)
    local spec = { type = "group", args = { size = newRangeOption(nil) } }
    local tree = defineTree(spec, nil)
    ctx:Expect(OptionsKit:Get(TREE_NAME)):ToBe(tree)
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      OptionsKit:Define(TREE_NAME, spec)
    end, lines, 'OptionsKit:Define "' .. TREE_NAME .. '" already has a tree; Undefine it first')

    ctx:Expect(OptionsKit:Undefine(TREE_NAME)):ToBe(true)
    ctx:Expect(OptionsKit:Undefine(TREE_NAME)):ToBe(false)
    ctx:Expect(OptionsKit:Get(TREE_NAME)):ToBeNil()
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      tree:Get("size")
    end, lines, "OptionsKit.Tree:Get cannot be called on an undefined tree")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      tree:Walk(function() end)
    end, lines, "OptionsKit.Tree:Walk cannot be called on an undefined tree")
  end
)

-- optionsKit.secrets --------------------------------------------------------------------------

local secrets = newSuite("secrets")

--- Why the secrets tests are skipped on a client without the two functions.
local SECRETS_SKIP_REASON =
  "the client has no issecretvalue and secretwrap; the secret path was not exercised"

---Register `body` as a test when the client can make a secret value, and as a
---skipped test naming why otherwise.
---@param name string
---@param body fun(ctx: TestKit.Context)
local function secretTest(name, body)
  if SECRETS_AVAILABLE then
    secrets:Test(name, body)
  else
    secrets:Skip(name, SECRETS_SKIP_REASON)
  end
end

---A genuine secret value made by the client's `secretwrap`, or a failed test.
---
---`secretwrap` is documented in the client's own API documentation
---(FrameScriptDocumentation, packages/apiKit/metadata/retail/namespaces.json)
---with no restriction and no side effect: it converts the values given to it.
---A secret is only ever checked here with `issecretvalue` and `type`: the
---client raises when a secret is compared with a value of its own type or
---tested for truth.
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

secretTest(
  "Set of a secret true on the chatBubbles toggle raises at OptionsKitSuite.lua:<line> before the setter runs, Validate answers secret value, and the CVar is unchanged",
  function(ctx)
    local original = requireProbeValue(ctx)
    local secretTrue = makeSecret(ctx, true)
    local setCount = { calls = 0 }
    local tree = defineTree({ type = "group", args = { bubbles = newChatBubblesOption(setCount) } })
    local changes = recordChanges(tree)

    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      tree:Set("bubbles", secretTrue)
    end, lines, "OptionsKit.Tree:Set value must not be a secret value")
    local accepted, message = tree:Validate("bubbles", secretTrue)
    ctx:Expect(accepted):ToBe(false)
    ctx:Expect(message):ToBe("secret value")

    ctx:Expect(setCount.calls):ToBe(0)
    ctx:Expect(#changes):ToBe(0)
    ctx:Expect(currentProbeValue()):ToBe(original)
  end
)

secretTest(
  "a secret path to Get and Set, and a secret addon name to Get and Define, are refused at OptionsKitSuite.lua:<line> before they index anything",
  function(ctx)
    local secretPath = makeSecret(ctx, "size")
    local secretName = makeSecret(ctx, TREE_NAME)
    local tree = defineTree({ type = "group", args = { size = newRangeOption(nil) } })
    local cases = {
      {
        call = function(lineBox)
          lineBox.start = currentLine()
          tree:Get(secretPath)
        end,
        message = "OptionsKit.Tree:Get path must not be a secret value",
      },
      {
        call = function(lineBox)
          lineBox.start = currentLine()
          tree:Set(secretPath, 1)
        end,
        message = "OptionsKit.Tree:Set path must not be a secret value",
      },
      {
        call = function(lineBox)
          lineBox.start = currentLine()
          OptionsKit:Get(secretName)
        end,
        message = "OptionsKit:Get addonName must not be a secret value",
      },
      {
        call = function(lineBox)
          lineBox.start = currentLine()
          OptionsKit:Define(secretName, { type = "group", args = {} })
        end,
        message = "OptionsKit:Define addonName must not be a secret value",
      },
    }
    for _, case in ipairs(cases) do
      local lines = { start = 0 }
      expectErrorAtCallingLine(ctx, function()
        case.call(lines)
      end, lines, case.message)
    end
    ctx:Expect(tree:Get("size")):ToBe(1)
  end
)

secretTest(
  "Get and Describe pass a getter's secret through untouched, at the top and inside a colour table, and a desc function's secret string becomes the description",
  function(ctx)
    local secretTrue = makeSecret(ctx, true)
    local secretRed = makeSecret(ctx, 0.5)
    local secretText = makeSecret(ctx, "a secret description")
    local tint = { r = secretRed, g = 0, b = 0 }
    local tree = defineTree({
      type = "group",
      args = {
        flag = {
          type = "toggle",
          name = "Flag",
          desc = function()
            return secretText
          end,
          get = function()
            return secretTrue
          end,
          set = function() end,
        },
        tint = {
          type = "color",
          name = "Tint",
          get = function()
            return tint
          end,
          set = function() end,
        },
      },
    })

    local read = tree:Get("flag")
    ctx:Expect(isSecret(read)):ToBe(true)
    ctx:Expect(type(read)):ToBe("boolean")

    local description = tree:Describe()
    local flag = requireNode(ctx, description, "flag")
    ctx:Expect(isSecret(flag.value)):ToBe(true)
    ctx:Expect(type(flag.value)):ToBe("boolean")
    ctx:Expect(isSecret(flag.desc)):ToBe(true)
    ctx:Expect(type(flag.desc)):ToBe("string")

    local tintNode = requireNode(ctx, description, "tint")
    ctx:Expect(type(tintNode.value)):ToBe("table")
    ctx:Expect(tintNode.value).Not:ToBe(tint)
    local copied = tintNode.value or {}
    ctx:Expect(isSecret(copied.r)):ToBe(true)
    ctx:Expect(type(copied.r)):ToBe("number")
    ctx:Expect(copied.g):ToBe(0)
  end
)

secretTest(
  "a secret true from disabled and hidden predicates counts as false in IsDisabled, IsHidden and Describe, and a secret true from validate refuses the value as refused by validate",
  function(ctx)
    local secretTrue = makeSecret(ctx, true)
    local setCount = { calls = 0 }
    local tree = defineTree({
      type = "group",
      args = {
        group = {
          type = "group",
          name = "Group",
          hidden = function()
            return secretTrue
          end,
          args = {
            size = newRangeOption({
              disabled = function()
                return secretTrue
              end,
              validate = function()
                return secretTrue
              end,
              set = function()
                setCount.calls = setCount.calls + 1
              end,
            }),
          },
        },
      },
    })

    ctx:Expect(tree:IsDisabled("group.size")):ToBe(false)
    ctx:Expect(tree:IsHidden("group.size")):ToBe(false)
    ctx:Expect(tree:IsHidden("group")):ToBe(false)
    local description = tree:Describe()
    ctx:Expect(requireNode(ctx, description, "group").hidden):ToBe(false)
    ctx:Expect(requireNode(ctx, description, "group.size").disabled):ToBe(false)
    ctx:Expect(requireNode(ctx, description, "group.size").hidden):ToBe(false)

    local written, message = tree:Set("group.size", 1.5)
    ctx:Expect(written):ToBe(false)
    ctx:Expect(message):ToBe("refused by validate")
    local accepted, validateMessage = tree:Validate("group.size", 1.5)
    ctx:Expect(accepted):ToBe(false)
    ctx:Expect(validateMessage):ToBe("refused by validate")
    ctx:Expect(setCount.calls):ToBe(0)
  end
)

secretTest(
  "Define refuses a secret disabled field and a secret maxDepth, and ProfileOptions a secret options.name, at OptionsKitSuite.lua:<line>",
  function(ctx)
    local db = freshDatabase(ctx)
    local secretTrue = makeSecret(ctx, true)
    local secretDepth = makeSecret(ctx, 8)
    local secretName = makeSecret(ctx, "Profiles")
    trackTreeName(TREE_NAME)
    local cases = {
      {
        call = function(lineBox)
          lineBox.start = currentLine()
          OptionsKit:Define(TREE_NAME, {
            type = "group",
            args = { flag = newRangeOption({ disabled = secretTrue }) },
          })
        end,
        message = "OptionsKit:Define tree.args.flag.disabled must not be a secret value",
      },
      {
        call = function(lineBox)
          lineBox.start = currentLine()
          OptionsKit:Define(TREE_NAME, { type = "group", args = {} }, { maxDepth = secretDepth })
        end,
        message = "OptionsKit:Define options.maxDepth must not be a secret value",
      },
      {
        call = function(lineBox)
          lineBox.start = currentLine()
          OptionsKit:ProfileOptions(db, { name = secretName })
        end,
        message = "OptionsKit:ProfileOptions options.name must not be a secret value",
      },
    }
    for _, case in ipairs(cases) do
      local lines = { start = 0 }
      expectErrorAtCallingLine(ctx, function()
        case.call(lines)
      end, lines, case.message)
    end
    ctx:Expect(OptionsKit:Get(TREE_NAME)):ToBeNil()
  end
)

secretTest(
  "a colour holding a secret red is refused by the schema: Set raises tint.r expected number, found secret value at OptionsKitSuite.lua:<line> and Validate answers the same without the prefix",
  function(ctx)
    local secretRed = makeSecret(ctx, 0.5)
    local setCount = { calls = 0 }
    local tree = defineTree({
      type = "group",
      args = {
        tint = {
          type = "color",
          name = "Tint",
          get = function()
            return nil
          end,
          set = function()
            setCount.calls = setCount.calls + 1
          end,
        },
      },
    })
    local value = { r = secretRed, g = 0, b = 0 }

    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      tree:Set("tint", value)
    end, lines, "OptionsKit.Tree:Set tint.r: expected number, found secret value")
    local accepted, message = tree:Validate("tint", value)
    ctx:Expect(accepted):ToBe(false)
    ctx:Expect(message):ToBe("r: expected number, found secret value")
    ctx:Expect(setCount.calls):ToBe(0)
  end
)
