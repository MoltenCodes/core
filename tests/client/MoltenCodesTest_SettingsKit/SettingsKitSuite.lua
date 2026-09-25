-- MoltenCodes Test: SettingsKitSuite.lua
--
-- Real-client suites for the `settingsKit` package. The Busted specs under
-- packages/settingsKit/tests/ prove SettingsKit against a fake client whose
-- saved variables are plain tables that never leave the process. What only
-- the game client can show is how SettingsKit meets real saved variables:
--
--   * the installed facade and its committed revision, and the session's
--     shared limits;
--   * two real saved variables declared by this addon's .toc,
--     `MoltenCodesTest_SettingsKitDB` (account-wide) and
--     `MoltenCodesTest_SettingsKitCharDB` (per character), opened after the
--     client restored them at this addon's ADDON_LOADED;
--   * the scope keys read from the live `UnitName("player")`,
--     `GetRealmName()`, `UnitClass("player")` and `UnitFactionGroup("player")`,
--     the current profile being the real character key `"<name> - <realm>"`;
--   * defaults read through views and never written back, checked by reading
--     the raw saved table; writes validated by SchemaKit at this file's line;
--     profiles copied, reset and deleted; migrations run by version, each
--     step atomic; a newer stored version opened read-only unless
--     `allowNewerData`; a scalar under a declared record read as absent;
--     Compact;
--   * persistence across /reload, in two runs: the first run writes known
--     values and a marker, the owner types /reload, and the next run reads
--     them back from the tables the client wrote to disk and restored, and
--     checks that the PLAYER_LOGOUT compaction ran before the client wrote;
--   * that view reads, a validated write of an existing key and Validate
--     allocate nothing on the client's own collector;
--   * argument errors pointing at this file as the client names it;
--   * secret values made by the client's `secretwrap`: a secret already in
--     the saved table reads back through a view still secret, a secret value
--     or key is refused, and every secret argument is refused before it is
--     compared.
--
-- Nothing here needs combat, a group or an instance, nothing is visible, no
-- client setting changes and no request goes to the server.
--
-- Run with `/mct run settingsKit`; tests/client/MoltenCodesTest_SettingsKit/EXPECTED.md
-- lists what the chat frame should show, run by run.
--
-- What a run leaves behind. Nothing opens at login: the two databases are
-- opened by the first test that needs them, after the loaded phase, and stay
-- open for the session (SettingsKit keeps one database per saved variable).
-- Every After hook takes out what its tests wrote to the two saved tables,
-- except what the persistence suite writes on purpose: `profile.scale`,
-- `profile.anchor`, `char.note` and `global.persistence` of the account table
-- and `global.note` of the per-character table. The final
-- `settingsKit.cleanup` test empties both saved variables once the second
-- persistence step has passed, so the files hold no data after the next
-- /reload. The migration tests open databases over scratch globals named
-- `MoltenCodesTest_SettingsKitScratch...`, which are not saved variables; the
-- globals are removed afterwards, but SettingsKit keeps each database in its
-- package state for the session (a few small tables per test).

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
local SETTINGS_KIT_API = 1
local SCHEMA_KIT_API = 1
local LIFECYCLE_KIT_API = 1
local EVENT_KIT_API = 1
local PACKAGE_ID = "settingsKit"

--- The account-wide saved variable, named by `## SavedVariables` in the .toc.
local ACCOUNT_DB_NAME = "MoltenCodesTest_SettingsKitDB"

--- The per-character saved variable, named by `## SavedVariablesPerCharacter`.
local CHARACTER_DB_NAME = "MoltenCodesTest_SettingsKitCharDB"

--- The version the account database is opened with; a new table is stamped with it.
local ACCOUNT_DB_VERSION = 2

--- The version the per-character database is opened with.
local CHARACTER_DB_VERSION = 1

--- Every refusal of the account database starts with this.
local ACCOUNT_PREFIX = "SettingsKit (" .. ACCOUNT_DB_NAME .. ") "

--- The sections `Open` creates in every saved table (docs/INTERNALS.md).
local LAYOUT_SECTIONS =
  { "global", "profiles", "profileKeys", "char", "realm", "class", "faction", "namespaces" }

--- The value the first persistence step writes to `profile.scale`; not the default (1).
local PERSISTED_SCALE = 1.25

--- `profile.anchor`'s default. The first persistence step writes it, so the
--- saved table holds a value equal to its default until the logout compaction.
local DEFAULT_ANCHOR = "CENTER"

--- The profile fields the non-persistence tests write; the After hooks remove
--- exactly these from the character profile, never the persisted ones.
local SCRATCH_PROFILE_FIELDS = { "frame", "color", "auras", "label" }

--- The field the scope tests write in the char, realm, class and faction entries.
local SCRATCH_SCOPE_FIELD = "touched"

--- Scratch profiles start with this, so the After hooks can find and delete them.
local SCRATCH_PROFILE_PREFIX = "MoltenCodesTest scratch "

--- Scratch globals for the migration tests start with this; none is a saved variable.
local SCRATCH_GLOBAL_PREFIX = "MoltenCodesTest_SettingsKitScratch"

--- A keyed-section key the tests read and write: Polymorph's spell ID.
local AURA_SPELL_ID = 118

--- The bound of the `auras` keyed section, small so the bound test stays short.
local AURAS_MAX = 4

--- How many cycles each allocation guard runs.
local ALLOCATION_CYCLES = 5000

--- Kilobytes an allocation guard tolerates: a stray allocation by the client
--- between the two readings, not a per-cycle one.
local ALLOCATION_TOLERANCE_KB = 1

--- The text inside the secret strings the secrets tests make.
local SECRET_TEXT = "MoltenCodesSecretText"

--- The number inside the secret numbers the secrets tests make.
local SECRET_NUMBER = 4242

--- Why every test that needs the two databases stops once the cleanup test ran.
local CLEANED_SKIP_REASON =
  "the cleanup test emptied both saved variables in this session; /reload to test again"

--- Why the second persistence step stops on the first run.
local NO_MARKER_SKIP_REASON =
  "run again after /reload: no marker from an earlier session yet (step one wrote it now)"

--- Why the second persistence step stops when step one did not write a marker.
local NO_MARKER_AT_ALL_SKIP_REASON =
  "run again after /reload: no marker from an earlier session yet, and step one wrote none"

-- Resolving the client and the framework ---------------------------------------------

---Read a client global, or `nil`.
---@param name string
---@return any
local function readHost(name)
  -- The identity functions, `date`, the secret-value functions and the two
  -- saved variables are World of Warcraft client globals, reachable only
  -- through the global table.
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

---Set or remove a global this file owns: one of its two saved variables or a
---scratch global of the migration tests.
---@param name string
---@param value any
local function writeOwnGlobal(name, value)
  -- The saved variables are this addon's own globals, named in its .toc; the
  -- scratch globals are created and removed by this file.
  -- selene: allow(global_usage)
  rawset(_G, name, value)
end

---@type Registry
local Registry = rawget(rawget(namespace, "Registries") or {}, REGISTRY_API)
if type(Registry) ~= "table" then
  error(addonName .. " requires the MoltenCodes addon (Registry API 2); reinstall it", 0)
end

-- SettingsKit and SchemaKit are not in the language-server workspace of
-- tests/client (its .luarc.json lists TestKit's dependency closure only), so
-- their facades, databases, views and schemas are typed `any` here.

---@type any
local SettingsKit = Registry:Get(PACKAGE_ID, SETTINGS_KIT_API)
---@type any
local SchemaKit = Registry:Get("schemaKit", SCHEMA_KIT_API)
---@type LifecycleKit|nil
local LifecycleKit = Registry:Get("lifecycleKit", LIFECYCLE_KIT_API)
if type(SettingsKit) == "nil" or type(SchemaKit) == "nil" or type(LifecycleKit) == "nil" then
  error(
    addonName .. " requires SettingsKit, SchemaKit and LifecycleKit in the MoltenCodes addon",
    0
  )
end
local S = SchemaKit

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

-- The schemas ----------------------------------------------------------------------------

--- The account database: every scope, every field optional (a saved variable
--- starts empty). `global.persistence` has no default, so it reads `nil`
--- until the first persistence step writes it.
local ACCOUNT_SCHEMA = {
  global = S.table({
    fields = {
      counter = S.optional(S.number({ integer = true, min = 0 }), 0),
      persistence = S.optional(S.table({
        fields = {
          token = S.optional(S.string({ min = 1, max = 64 })),
          writtenAt = S.optional(S.string({ max = 32 })),
          character = S.optional(S.string({ max = 160 })),
          verifiedAt = S.optional(S.string({ max = 32 })),
        },
      })),
    },
  }),
  char = S.table({
    fields = {
      note = S.optional(S.string({ max = 64 })),
      touched = S.optional(S.boolean(), false),
    },
  }),
  realm = S.table({ fields = { touched = S.optional(S.boolean(), false) } }),
  class = S.table({ fields = { touched = S.optional(S.boolean(), false) } }),
  faction = S.table({ fields = { touched = S.optional(S.boolean(), false) } }),
  profile = S.table({
    fields = {
      scale = S.optional(S.number({ min = 0.5, max = 2 }), 1),
      anchor = S.optional(S.enum({ "TOP", "CENTER", "BOTTOM" }), DEFAULT_ANCHOR),
      label = S.optional(S.string({ max = 32 })),
      frame = S.optional(
        S.table({ fields = { x = S.optional(S.number(), 0), y = S.optional(S.number(), 0) } }),
        {}
      ),
      color = S.optional(
        S.array({ of = S.number({ min = 0, max = 1 }), min = 3, max = 4 }),
        { 1, 1, 1 }
      ),
      auras = S.optional(
        S.map({
          keys = S.number({ integer = true, min = 1 }),
          values = S.optional(S.table({ fields = { shown = S.optional(S.boolean(), true) } }), {}),
          max = AURAS_MAX,
        }),
        {}
      ),
    },
  }),
}

--- The per-character database: the saved variable is per character already,
--- so its `global` scope is this character's.
local CHARACTER_SCHEMA = {
  global = S.table({
    fields = {
      note = S.optional(S.string({ max = 64 })),
      probe = S.optional(S.number(), 0),
    },
  }),
}

--- The schema of the migration tests' scratch databases.
local SCRATCH_SCHEMA = {
  profile = S.table({ fields = { scale = S.optional(S.number(), 1) } }),
}

--- A scratch schema with a record field, for the corrupted-data test: a
--- saved scalar where `frame` is declared must read as absent.
local SCRATCH_RECORD_SCHEMA = {
  profile = S.table({
    fields = {
      frame = S.optional(S.table({ fields = { x = S.optional(S.number(), 0) } }), {}),
    },
  }),
}

--- The version a scratch table a newer addon version "wrote" carries, and
--- the older version the read-only tests open it with.
local NEWER_STORED_VERSION = 5
local OLDER_OPEN_VERSION = 2

---The reason every read-only refusal of the scratch tables ends with.
---@return string
local function readOnlyReason()
  return "the saved table has version "
    .. NEWER_STORED_VERSION
    .. ", newer than options.version "
    .. OLDER_OPEN_VERSION
    .. "; pass options.allowNewerData = true to SettingsKit:Open to write it"
end

-- Reading the saved tables ----------------------------------------------------------------

---`container[key]` when `container` is a table and the value is one, or `nil`.
---@param container any
---@param key any
---@return table|nil
local function rawTableField(container, key)
  if type(container) ~= "table" then
    return nil
  end
  local value = rawget(container, key)
  if type(value) ~= "table" then
    return nil
  end
  return value
end

---`container[key]` when `container` is a table, or `nil`.
---@param container any
---@param key any
---@return any
local function rawField(container, key)
  if type(container) ~= "table" then
    return nil
  end
  return rawget(container, key)
end

---The string keys of a table, sorted; other keys appear as `[<type>]`.
---@param container table|nil
---@return string[]
local function sortedKeys(container)
  local names = {}
  if type(container) ~= "table" then
    return names
  end
  for key in pairs(container) do
    names[#names + 1] = type(key) == "string" and key or ("[" .. type(key) .. "]")
  end
  table.sort(names)
  return names
end

---A copy of a plain saved table, for a snapshot. The saved tables hold only
---strings, numbers, booleans and tables; `depth` stops a cycle.
---@param value any
---@param depth integer
---@return any
local function copySaved(value, depth)
  if type(value) ~= "table" or depth > 16 then
    return value
  end
  local copy = {}
  for key, inner in pairs(value) do
    copy[key] = copySaved(inner, depth + 1)
  end
  return copy
end

-- The client's saved-variable timing --------------------------------------------------------

--- What the two saved-variable globals held when this file ran: the client
--- restores saved variables only after every file of the addon has run.
local typesAtFileScope = {
  account = type(readHost(ACCOUNT_DB_NAME)),
  character = type(readHost(CHARACTER_DB_NAME)),
}

--- Copies of the two tables the client restored, taken in this addon's loaded
--- phase before any code of this session could write to them, or `nil` until
--- that phase. Reading at the loaded phase changes nothing, so it does not
--- break the rule that nothing runs at login.
---@type { accountType: string, characterType: string, account: table|nil, character: table|nil }|nil
local restoredAtLoad = nil

LifecycleKit:ForAddon(addonName):OnLoaded(function()
  local account = readHost(ACCOUNT_DB_NAME)
  local character = readHost(CHARACTER_DB_NAME)
  restoredAtLoad = {
    accountType = type(account),
    characterType = type(character),
    account = type(account) == "table" and copySaved(account, 1) or nil,
    character = type(character) == "table" and copySaved(character, 1) or nil,
  }
end)

-- The two databases -----------------------------------------------------------------------

--- The databases, once the first test opened them.
---@type { account: any, character: any, profileAtOpen: string, profileChoiceAtOpen: any }|nil
local openedDatabases = nil

--- `true` once the cleanup test emptied both saved variables in this session.
local cleanedThisSession = false

--- `true` once the first persistence step wrote its marker in this session.
local markerWrittenThisSession = false

---Call a client function by name, or return nothing without it.
---@param name string
---@param ... any
---@return any ...
local function callHost(name, ...)
  local host = readHost(name)
  if type(host) ~= "function" then
    return nil
  end
  return host(...)
end

---A plain, non-empty string from the client, or `nil`. The secret question
---comes before the comparison with `""`, which would raise on a secret.
---@param value any
---@return string|nil
local function plainName(value)
  if type(value) ~= "string" or isSecret(value) then
    return nil
  end
  if value == "" then
    return nil
  end
  return value
end

---The character key `"<name> - <realm>"` from the live client, or `nil`.
---@return string|nil
local function liveCharacterKey()
  local playerName = plainName((callHost("UnitName", "player")))
  local realm = plainName((callHost("GetRealmName")))
  if type(playerName) == "nil" or type(realm) == "nil" then
    return nil
  end
  return playerName .. " - " .. realm
end

---The client's `date` as `%Y-%m-%d %H:%M:%S`, or a fixed text without it.
---@return string
local function timestamp()
  local formatDate = readHost("date")
  if type(formatDate) ~= "function" then
    return "unknown time"
  end
  return formatDate("%Y-%m-%d %H:%M:%S")
end

---Open both databases over the real saved variables, once per session.
---
---Called by the tests, never at load: by the time a suite runs, the addon's
---loaded phase has passed and the client has restored both tables. A test
---ends as skipped once the cleanup test emptied them in this session.
---@param ctx TestKit.Context
---@return any accountDb
---@return any characterDb
local function openDatabases(ctx)
  if cleanedThisSession then
    Harness:SkipTest(ctx, CLEANED_SKIP_REASON)
  end
  if openedDatabases == nil then
    local account = SettingsKit:Open(ACCOUNT_DB_NAME, ACCOUNT_SCHEMA, {
      defaultProfile = "char",
      version = ACCOUNT_DB_VERSION,
    })
    local character = SettingsKit:Open(CHARACTER_DB_NAME, CHARACTER_SCHEMA, {
      version = CHARACTER_DB_VERSION,
    })
    local characterKey = liveCharacterKey()
    local profileChoice = nil
    if type(characterKey) == "string" then
      profileChoice =
        rawField(rawTableField(readHost(ACCOUNT_DB_NAME), "profileKeys"), characterKey)
    end
    openedDatabases = {
      account = account,
      character = character,
      profileAtOpen = account:GetProfile(),
      profileChoiceAtOpen = profileChoice,
    }
  end
  return openedDatabases.account, openedDatabases.character
end

---The character key, or end the test as failed: every Retail client answers
---`UnitName("player")` and `GetRealmName()` once the player is in the world.
---@param ctx TestKit.Context
---@return string
local function requireCharacterKey(ctx)
  local characterKey = liveCharacterKey()
  if type(characterKey) == "nil" then
    ctx:Fail('UnitName("player") or GetRealmName() answered no plain name')
  end
  ---@cast characterKey string
  return characterKey
end

---The raw saved table of a profile of the account database, or `nil`.
---@param profileName string
---@return table|nil
local function rawProfile(profileName)
  return rawTableField(rawTableField(readHost(ACCOUNT_DB_NAME), "profiles"), profileName)
end

---The raw entry of a keyed section (`char`, `realm`, ...) of the account database, or `nil`.
---@param sectionName string
---@param key string
---@return table|nil
local function rawScopeEntry(sectionName, key)
  return rawTableField(rawTableField(readHost(ACCOUNT_DB_NAME), sectionName), key)
end

-- Releasing what the tests wrote ------------------------------------------------------------

--- Signal connections the running test made, disconnected by the After hooks.
---@type table[]
local connections = {}

--- Scratch globals the running test created, removed by the After hooks.
---@type string[]
local scratchGlobals = {}

--- Numbers scratch global names, so a second run in the session opens new ones.
local scratchSerial = 0

---Keep a SignalKit connection for the After hook and return it.
---@param connection table
---@return table
local function track(connection)
  connections[#connections + 1] = connection
  return connection
end

---A scratch global name no global uses yet, removed by the After hook.
---@param purpose string an identifier naming the test's use of it
---@return string
local function newScratchGlobal(purpose)
  scratchSerial = scratchSerial + 1
  local name = SCRATCH_GLOBAL_PREFIX .. "_" .. purpose .. "_" .. scratchSerial
  while type(readHost(name)) ~= "nil" do
    scratchSerial = scratchSerial + 1
    name = SCRATCH_GLOBAL_PREFIX .. "_" .. purpose .. "_" .. scratchSerial
  end
  scratchGlobals[#scratchGlobals + 1] = name
  return name
end

---Remove the scope tests' field from a scope entry of the account table, and
---the entry when that leaves it empty.
---@param sectionName string
---@param key string|nil
local function removeScopeField(sectionName, key)
  if type(key) == "nil" then
    return
  end
  local section = rawTableField(readHost(ACCOUNT_DB_NAME), sectionName)
  local entry = rawTableField(section, key)
  if section == nil or entry == nil then
    return
  end
  rawset(entry, SCRATCH_SCOPE_FIELD, nil)
  if next(entry) == nil then
    rawset(section, key, nil)
  end
end

---Put the two saved tables back the way the persistence suite expects them:
---the profile at open is current again with its recorded choice, every
---scratch profile is deleted, and only the fields the tests wrote are removed.
local function restoreDatabases()
  if openedDatabases == nil or cleanedThisSession then
    return
  end
  local db = openedDatabases.account
  if db:GetProfile() ~= openedDatabases.profileAtOpen then
    db:SetProfile(openedDatabases.profileAtOpen)
  end
  for _, name in ipairs(db:GetProfiles()) do
    local isScratch = name:sub(1, #SCRATCH_PROFILE_PREFIX) == SCRATCH_PROFILE_PREFIX
    if isScratch and name ~= db:GetProfile() then
      db:DeleteProfile(name)
    end
  end

  local raw = readHost(ACCOUNT_DB_NAME)
  local characterKey = liveCharacterKey()
  local profileKeys = rawTableField(raw, "profileKeys")
  if profileKeys ~= nil and type(characterKey) == "string" then
    rawset(profileKeys, characterKey, openedDatabases.profileChoiceAtOpen)
  end

  local profile = rawProfile(openedDatabases.profileAtOpen)
  if profile ~= nil then
    for _, field in ipairs(SCRATCH_PROFILE_FIELDS) do
      rawset(profile, field, nil)
    end
  end

  local _, classFile = callHost("UnitClass", "player")
  removeScopeField("char", characterKey)
  removeScopeField("realm", plainName((callHost("GetRealmName"))))
  removeScopeField("class", plainName(classFile))
  removeScopeField("faction", plainName((callHost("UnitFactionGroup", "player"))))

  rawset(rawTableField(readHost(CHARACTER_DB_NAME), "global") or {}, "probe", nil)
end

---The After hook of every suite: disconnect, remove scratch globals, restore.
local function cleanUp()
  for index = #connections, 1, -1 do
    connections[index]:Disconnect()
    connections[index] = nil
  end
  for index = #scratchGlobals, 1, -1 do
    writeOwnGlobal(scratchGlobals[index], nil)
    scratchGlobals[index] = nil
  end
  restoreDatabases()
end

---Register a suite of this package with the shared After hook.
---@param part string
---@return TestKit.Suite
local function newSuite(part)
  local suite = Harness:Suite(PACKAGE_ID, part, addonName)
  suite:After(cleanUp)
  return suite
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
  ctx:Expect((file or ""):sub(-#"SettingsKitSuite.lua")):ToBe("SettingsKitSuite.lua")
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
---@param cycle fun(index: integer)
---@param count integer
local function runCycles(cycle, count)
  for index = 1, count do
    cycle(index)
  end
end

---Collect in a step of its own, run one unmeasured cycle, measure
---`ALLOCATION_CYCLES` calls of `cycle`, log the delta and hold it to the
---tolerance.
---
---The full collection runs in its own step (`ctx:Yield()` after it), so the
---measurement starts far from the next collector cycle. The unmeasured cycle
---lets the test's coroutine grow its Lua stack back once, which is not an
---allocation of the code under test.
---@param ctx TestKit.Context
---@param label string what `cycle` does, for the log
---@param cycle fun(index: integer)
local function expectNoAllocation(ctx, label, cycle)
  collectgarbage("collect")
  ctx:Yield()
  measureAllocation(function()
    runCycles(cycle, 1)
  end)
  local grownKilobytes = measureAllocation(function()
    runCycles(cycle, ALLOCATION_CYCLES)
  end)
  ctx:Log(("memory delta over %s: %.3f KB"):format(label, grownKilobytes))
  ctx:Expect(grownKilobytes <= ALLOCATION_TOLERANCE_KB):ToBe(true)
end

-- settingsKit.facade ----------------------------------------------------------------------------

local facade = newSuite("facade")

facade:Test(
  "Registry:Get('settingsKit', 1) is the SettingsKit facade with API 1, Open, SetLimits, GetLimits, UNBOUNDED, DEFAULT_PROFILE 'Default', MAX_PROFILE_NAME_LENGTH 64 and the Database prototype's seventeen methods",
  function(ctx)
    ctx:Expect(type(SettingsKit)):ToBe("table")
    ctx:Expect(rawget(SettingsKit, "API")):ToBe(SETTINGS_KIT_API)
    for _, functionName in ipairs({ "Open", "SetLimits", "GetLimits" }) do
      ctx:Expect(type(rawget(SettingsKit, functionName))):ToBe("function")
    end
    ctx:Expect(type(rawget(SettingsKit, "UNBOUNDED"))):ToBe("table")
    ctx:Expect(rawget(SettingsKit, "DEFAULT_PROFILE")):ToBe("Default")
    ctx:Expect(rawget(SettingsKit, "MAX_PROFILE_NAME_LENGTH")):ToBe(64)
    local prototype = rawget(SettingsKit, "Database")
    ctx:Expect(type(prototype)):ToBe("table")
    for _, methodName in ipairs({
      "GetProfile",
      "SetProfile",
      "GetProfiles",
      "CopyProfile",
      "ResetProfile",
      "DeleteProfile",
      "ResetDatabase",
      "OnChange",
      "OnProfileChanged",
      "OnProfileCopied",
      "OnProfileReset",
      "OnProfileDeleted",
      "Compact",
      "GetSavedVariable",
      "Pairs",
      "Validate",
      "IsReadOnly",
    }) do
      ctx:Expect(type(rawget(prototype, methodName))):ToBe("function")
    end
  end
)

facade:Test(
  "the installed SettingsKit carries the revision of the committed manifest",
  function(ctx)
    local expectedPackages = Harness:GetExpectedPackages()
    if type(expectedPackages) == "nil" then
      ctx:Fail("Expected.lua is missing; install with python3 -m tooling.client.install")
      return
    end
    for _, expected in ipairs(expectedPackages) do
      if expected.id == PACKAGE_ID then
        local _, revision = Registry:Get(PACKAGE_ID, SETTINGS_KIT_API)
        ctx:Expect(revision):ToBe(expected.revision)
        ctx:Expect(rawget(SettingsKit, "REVISION")):ToBe(expected.revision)
        return
      end
    end
    ctx:Fail("Expected.lua does not list settingsKit")
  end
)

facade:Test(
  "GetLimits answers a fresh table holding the session's shared limits at their defaults: maxProfileNameLength 64 and pathKeyLimit 32",
  function(ctx)
    local first = SettingsKit:GetLimits()
    local second = SettingsKit:GetLimits()
    ctx:Expect(second).Not:ToBe(first)
    ctx:Log(
      ("limits in this session: maxProfileNameLength %s, pathKeyLimit %s"):format(
        tostring(first.maxProfileNameLength),
        tostring(first.pathKeyLimit)
      )
    )
    ctx:Expect(first):ToEqual({ maxProfileNameLength = 64, pathKeyLimit = 32 })
  end
)

-- settingsKit.savedVariables ---------------------------------------------------------------------

local savedVariables = newSuite("savedVariables")

savedVariables:Test(
  "Open over the two saved variables of the toc, after the loaded phase, uses each global as the raw table, stamps its version, creates every layout section, and a second Open returns the same database",
  function(ctx)
    local db, characterDb = openDatabases(ctx)
    local raw = readHost(ACCOUNT_DB_NAME)
    local characterRaw = readHost(CHARACTER_DB_NAME)
    ctx:Log(
      ("restored at the loaded phase: account %s, per character %s"):format(
        restoredAtLoad and restoredAtLoad.accountType or "not seen",
        restoredAtLoad and restoredAtLoad.characterType or "not seen"
      )
    )
    ctx:Expect(type(raw)):ToBe("table")
    ctx:Expect(type(characterRaw)):ToBe("table")
    ctx:Expect(characterRaw).Not:ToBe(raw)
    ctx:Expect(rawget(raw, "version")):ToBe(ACCOUNT_DB_VERSION)
    ctx:Expect(rawget(characterRaw, "version")):ToBe(CHARACTER_DB_VERSION)
    for _, sectionName in ipairs(LAYOUT_SECTIONS) do
      ctx:Expect(type(rawget(raw, sectionName))):ToBe("table")
      ctx:Expect(type(rawget(characterRaw, sectionName))):ToBe("table")
    end
    ctx:Expect(db:GetSavedVariable()):ToBe(ACCOUNT_DB_NAME)
    ctx:Expect(characterDb:GetSavedVariable()):ToBe(CHARACTER_DB_NAME)
    ctx:Expect(SettingsKit:Open(ACCOUNT_DB_NAME)):ToBe(db)
    ctx:Expect(SettingsKit:Open(ACCOUNT_DB_NAME, ACCOUNT_SCHEMA)):ToBe(db)
    ctx:Expect(SettingsKit:Open(CHARACTER_DB_NAME)):ToBe(characterDb)
    ctx:Expect(getmetatable(db.profile)):ToBe("SettingsKit.View")
    ctx:Expect(getmetatable(characterDb.global)):ToBe("SettingsKit.View")
  end
)

savedVariables:Test(
  "the current profile and the char scope are keyed '<name> - <realm>' from the live UnitName('player') and GetRealmName(), and a write through db.char lands under that key",
  function(ctx)
    local db = openDatabases(ctx)
    local characterKey = requireCharacterKey(ctx)
    ctx:Log("character key: " .. characterKey)
    ctx:Expect(db:GetProfile()):ToBe(characterKey)
    ctx:Expect(type(rawProfile(characterKey))):ToBe("table")

    db.char.touched = true
    ctx:Expect(rawField(rawScopeEntry("char", characterKey), "touched")):ToBe(true)
    ctx:Expect(db.char.touched):ToBe(true)
  end
)

savedVariables:Test(
  "the realm, class and faction scopes are keyed by the live GetRealmName(), UnitClass('player')'s class file and UnitFactionGroup('player'), and a write through each lands under its key",
  function(ctx)
    local db = openDatabases(ctx)
    local realm = plainName((callHost("GetRealmName")))
    local _, classFile = callHost("UnitClass", "player")
    classFile = plainName(classFile)
    local faction = plainName((callHost("UnitFactionGroup", "player")))
    ctx:Log(
      ("scope keys: realm %s, class %s, faction %s"):format(
        tostring(realm),
        tostring(classFile),
        tostring(faction)
      )
    )
    ctx:Expect(type(realm)):ToBe("string")
    ctx:Expect(type(classFile)):ToBe("string")
    ctx:Expect(type(faction)):ToBe("string")
    ---@cast realm string
    ---@cast classFile string
    ---@cast faction string

    db.realm.touched = true
    db.class.touched = true
    db.faction.touched = true
    ctx:Expect(rawField(rawScopeEntry("realm", realm), "touched")):ToBe(true)
    ctx:Expect(rawField(rawScopeEntry("class", classFile), "touched")):ToBe(true)
    ctx:Expect(rawField(rawScopeEntry("faction", faction), "touched")):ToBe(true)
  end
)

savedVariables:Test(
  "reading defaults writes nothing: frame.x, frame.y, auras[118].shown, label, global.counter and char.touched read their defaults and the raw profile, global and char tables gain no key",
  function(ctx)
    local db = openDatabases(ctx)
    local characterKey = requireCharacterKey(ctx)
    local raw = readHost(ACCOUNT_DB_NAME)
    local profileKeysBefore = sortedKeys(rawProfile(characterKey))
    local globalKeysBefore = sortedKeys(rawTableField(raw, "global"))
    local charKeysBefore = sortedKeys(rawScopeEntry("char", characterKey))
    ctx:Log("saved profile keys: " .. table.concat(profileKeysBefore, ", "))

    ctx:Expect(db.profile.frame.x):ToBe(0)
    ctx:Expect(db.profile.frame.y):ToBe(0)
    ctx:Expect(db.profile.auras[AURA_SPELL_ID].shown):ToBe(true)
    ctx:Expect(db.profile.auras[AURA_SPELL_ID + 1].shown):ToBe(true)
    ctx:Expect(db.profile.label):ToBeNil()
    ctx:Expect(db.global.counter):ToBe(0)
    ctx:Expect(db.char.touched):ToBe(false)

    ctx:Expect(sortedKeys(rawProfile(characterKey))):ToEqual(profileKeysBefore)
    ctx:Expect(sortedKeys(rawTableField(raw, "global"))):ToEqual(globalKeysBefore)
    ctx:Expect(sortedKeys(rawScopeEntry("char", characterKey))):ToEqual(charKeysBefore)
    ctx:Expect(rawField(rawProfile(characterKey), "frame")):ToBeNil()
    ctx:Expect(rawField(rawProfile(characterKey), "auras")):ToBeNil()
  end
)

savedVariables:Test(
  "an array default is copied into the raw saved table on its first read, as documented, and Compact removes the unchanged copy",
  function(ctx)
    local db = openDatabases(ctx)
    local characterKey = requireCharacterKey(ctx)
    ctx:Expect(rawField(rawProfile(characterKey), "color")):ToBeNil()

    local color = db.profile.color
    ctx:Expect(color):ToEqual({ 1, 1, 1 })
    ctx:Expect(rawField(rawProfile(characterKey), "color")):ToBe(color)

    local removed = db:Compact()
    ctx:Log("Compact removed " .. tostring(removed))
    ctx:Expect(type(removed)):ToBe("number")
    ctx:Expect(removed >= 1):ToBe(true)
    ctx:Expect(rawField(rawProfile(characterKey), "color")):ToBeNil()
  end
)

savedVariables:Test(
  "a validated write stores only the written path in the raw saved table, OnChange reports db, scope, key, value and path, and writing nil brings the default back",
  function(ctx)
    local db = openDatabases(ctx)
    local characterKey = requireCharacterKey(ctx)
    local calls = {}
    track(db:OnChange("profile", function(changedDb, scope, key, value, path)
      calls[#calls + 1] = { db = changedDb, scope = scope, key = key, value = value, path = path }
    end))

    db.profile.frame.x = 120
    ctx:Expect(rawField(rawProfile(characterKey), "frame")):ToEqual({ x = 120 })
    ctx:Expect(#calls):ToBe(1)
    ctx:Expect(calls[1].db):ToBe(db)
    ctx:Expect(calls[1].scope):ToBe("profile")
    ctx:Expect(calls[1].key):ToBe("x")
    ctx:Expect(calls[1].value):ToBe(120)
    ctx:Expect(calls[1].path):ToBe("frame")

    db.profile.auras[AURA_SPELL_ID].shown = false
    ctx:Expect(rawField(rawProfile(characterKey), "auras")):ToEqual({
      [AURA_SPELL_ID] = { shown = false },
    })
    ctx:Expect(calls[2].path):ToBe("auras[118]")

    db.profile.frame.x = nil
    ctx:Expect(db.profile.frame.x):ToBe(0)
    ctx:Expect(calls[3].value):ToBeNil()
    ctx:Expect(rawField(rawTableField(rawProfile(characterKey), "frame"), "x")):ToBeNil()
  end
)

savedVariables:Test(
  "the per-character saved variable is a database of its own: a write to its global scope lands in MoltenCodesTest_SettingsKitCharDB and not in the account table",
  function(ctx)
    local db, characterDb = openDatabases(ctx)
    characterDb.global.probe = 7
    ctx:Expect(rawField(rawTableField(readHost(CHARACTER_DB_NAME), "global"), "probe")):ToBe(7)
    ctx:Expect(rawField(rawTableField(readHost(ACCOUNT_DB_NAME), "global"), "probe")):ToBeNil()
    ctx:Expect(db.global.probe):ToBeNil()
  end
)

-- settingsKit.writes --------------------------------------------------------------------------

local writes = newSuite("writes")

writes:Test(
  "writes the schema refuses raise at the writing line in SettingsKitSuite.lua with SchemaKit's text and store nothing: scale 7, anchor LEFT, frame.x a string",
  function(ctx)
    local db = openDatabases(ctx)
    local characterKey = requireCharacterKey(ctx)
    local scaleBefore = rawField(rawProfile(characterKey), "scale")
    local anchorBefore = rawField(rawProfile(characterKey), "anchor")
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      db.profile.scale = 7
    end, lines, ACCOUNT_PREFIX .. "profile.scale: expected number <= 2, found larger number")
    expectErrorAtCallingLine(
      ctx,
      function()
        lines.start = currentLine()
        db.profile.anchor = "LEFT"
      end,
      lines,
      ACCOUNT_PREFIX
        .. 'profile.anchor: expected one of "TOP", "CENTER", "BOTTOM", found unlisted string'
    )
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      db.profile.frame.x = "wide"
    end, lines, ACCOUNT_PREFIX .. "profile.frame.x: expected number, found string")
    ctx:Expect(rawField(rawProfile(characterKey), "scale")):ToBe(scaleBefore)
    ctx:Expect(rawField(rawProfile(characterKey), "anchor")):ToBe(anchorBefore)
    ctx:Expect(rawField(rawProfile(characterKey), "frame")):ToBeNil()
  end
)

writes:Test(
  "an undeclared field of the closed profile record and a fifth aura past max 4 are refused at the writing line, and the section keeps its four entries",
  function(ctx)
    local db = openDatabases(ctx)
    local characterKey = requireCharacterKey(ctx)
    local lines = { start = 0 }
    expectErrorAtCallingLine(
      ctx,
      function()
        lines.start = currentLine()
        db.profile.width = 1
      end,
      lines,
      ACCOUNT_PREFIX .. "profile.width: expected only declared fields, found undeclared field"
    )

    for spellId = 1, AURAS_MAX do
      db.profile.auras[spellId].shown = false
    end
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      db.profile.auras[AURAS_MAX + 1].shown = false
    end, lines, ACCOUNT_PREFIX .. "profile.auras: expected at most 4 entries")
    ctx:Expect(#sortedKeys(rawField(rawProfile(characterKey), "auras"))):ToBe(AURAS_MAX)
    ctx:Expect(rawField(rawTableField(rawProfile(characterKey), "auras"), AURAS_MAX + 1)):ToBeNil()
  end
)

writes:Test(
  "Open, OnChange, SetProfile, DeleteProfile and a write to the database object are refused at the calling line in SettingsKitSuite.lua",
  function(ctx)
    local db = openDatabases(ctx)
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      SettingsKit:Open(12)
    end, lines, "SettingsKit:Open savedVariable must be the name of a saved variable")
    expectErrorAtCallingLine(
      ctx,
      function()
        lines.start = currentLine()
        SettingsKit:Open(ACCOUNT_DB_NAME, {})
      end,
      lines,
      "SettingsKit:Open " .. ACCOUNT_DB_NAME .. " is already open with a different schema table"
    )
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      db:OnChange("nowhere", function() end)
    end, lines, "SettingsKit.Database:OnChange scope must name a declared, available scope")
    expectErrorAtCallingLine(
      ctx,
      function()
        lines.start = currentLine()
        db:SetProfile("   ")
      end,
      lines,
      "SettingsKit.Database:SetProfile name must contain a character other than whitespace"
    )
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      db:DeleteProfile(db:GetProfile())
    end, lines, "SettingsKit.Database:DeleteProfile cannot delete the current profile")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      db.settings = {}
    end, lines, "SettingsKit databases are read-only; write through db.<scope> instead")
  end
)

writes:Test(
  "Validate answers false with exactly the text the refused write raises and true for a valid value, and writes nothing to the raw saved table",
  function(ctx)
    local db = openDatabases(ctx)
    local characterKey = requireCharacterKey(ctx)
    local ok, message = db:Validate("profile", "scale", 7)
    ctx:Expect(ok):ToBe(false)
    ctx
      :Expect(message)
      :ToBe(ACCOUNT_PREFIX .. "profile.scale: expected number <= 2, found larger number")
    ok, message = db:Validate("profile", { "auras", AURA_SPELL_ID, "shown" }, false)
    ctx:Expect(ok):ToBe(true)
    ctx:Expect(message):ToBeNil()
    ok = db:Validate("profile", "frame.x", 120)
    ctx:Expect(ok):ToBe(true)
    ctx:Expect(rawField(rawProfile(characterKey), "auras")):ToBeNil()
    ctx:Expect(rawField(rawProfile(characterKey), "frame")):ToBeNil()
  end
)

-- settingsKit.profiles ----------------------------------------------------------------------------

local profiles = newSuite("profiles")

--- The two scratch profiles the profile tests switch between.
local SCRATCH_PROFILE_A = SCRATCH_PROFILE_PREFIX .. "A"
local SCRATCH_PROFILE_B = SCRATCH_PROFILE_PREFIX .. "B"

profiles:Test(
  "SetProfile to a new profile creates it in the raw saved table, records it under the character key in profileKeys and fires OnProfileChanged; switching back returns to the character profile",
  function(ctx)
    local db = openDatabases(ctx)
    local characterKey = requireCharacterKey(ctx)
    local changes = {}
    track(db:OnProfileChanged(function(_, name, previous)
      changes[#changes + 1] = { name = name, previous = previous }
    end))
    local characterView = db.profile

    ctx:Expect(db:SetProfile(SCRATCH_PROFILE_A)):ToBe(true)
    ctx:Expect(db:GetProfile()):ToBe(SCRATCH_PROFILE_A)
    ctx:Expect(rawProfile(SCRATCH_PROFILE_A)):ToEqual({})
    ctx
      :Expect(rawField(rawTableField(readHost(ACCOUNT_DB_NAME), "profileKeys"), characterKey))
      :ToBe(SCRATCH_PROFILE_A)
    ctx:Expect(changes[1]):ToEqual({ name = SCRATCH_PROFILE_A, previous = characterKey })
    ctx:Expect(db.profile).Not:ToBe(characterView)
    ctx:Expect(db:SetProfile(SCRATCH_PROFILE_A)):ToBe(false)
    ctx:Expect(#changes):ToBe(1)

    ctx:Expect(db:SetProfile(characterKey)):ToBe(true)
    ctx:Expect(db.profile):ToBe(characterView)
    ctx:Expect(changes[2]):ToEqual({ name = characterKey, previous = SCRATCH_PROFILE_A })
  end
)

profiles:Test(
  "CopyProfile replaces the current profile with a deep copy of another's saved values, fires OnProfileCopied and keeps db.profile the same view",
  function(ctx)
    local db = openDatabases(ctx)
    local copies = {}
    track(db:OnProfileCopied(function(_, from, name)
      copies[#copies + 1] = { from = from, name = name }
    end))
    db:SetProfile(SCRATCH_PROFILE_A)
    db.profile.label = "copied"
    db.profile.frame.x = 5
    db:SetProfile(SCRATCH_PROFILE_B)
    db.profile.frame.y = 9
    local view = db.profile

    db:CopyProfile(SCRATCH_PROFILE_A)
    ctx:Expect(db.profile):ToBe(view)
    ctx:Expect(db.profile.label):ToBe("copied")
    ctx:Expect(db.profile.frame.x):ToBe(5)
    ctx:Expect(db.profile.frame.y):ToBe(0)
    ctx:Expect(rawProfile(SCRATCH_PROFILE_B)):ToEqual({ label = "copied", frame = { x = 5 } })
    ctx
      :Expect(rawField(rawProfile(SCRATCH_PROFILE_B), "frame")).Not
      :ToBe(rawField(rawProfile(SCRATCH_PROFILE_A), "frame"))
    ctx:Expect(copies[1]):ToEqual({ from = SCRATCH_PROFILE_A, name = SCRATCH_PROFILE_B })
  end
)

profiles:Test(
  "ResetProfile empties the current profile's raw table in place, so every field reads its default, and fires OnProfileReset",
  function(ctx)
    local db = openDatabases(ctx)
    local resets = {}
    track(db:OnProfileReset(function(_, name)
      resets[#resets + 1] = name
    end))
    db:SetProfile(SCRATCH_PROFILE_A)
    db.profile.label = "reset me"
    db.profile.scale = 1.5
    local rawBefore = rawProfile(SCRATCH_PROFILE_A)

    db:ResetProfile()
    ctx:Expect(rawProfile(SCRATCH_PROFILE_A)):ToBe(rawBefore)
    ctx:Expect(rawBefore):ToEqual({})
    ctx:Expect(db.profile.label):ToBeNil()
    ctx:Expect(db.profile.scale):ToBe(1)
    ctx:Expect(resets):ToEqual({ SCRATCH_PROFILE_A })
  end
)

profiles:Test(
  "DeleteProfile removes a profile from the raw saved table and from GetProfiles, fires OnProfileDeleted, and a view kept from it reads defaults and refuses writes at the writing line",
  function(ctx)
    local db = openDatabases(ctx)
    local characterKey = requireCharacterKey(ctx)
    local deletions = {}
    track(db:OnProfileDeleted(function(_, name)
      deletions[#deletions + 1] = name
    end))
    db:SetProfile(SCRATCH_PROFILE_A)
    db.profile.label = "doomed"
    local keptView = db.profile
    db:SetProfile(characterKey)

    db:DeleteProfile(SCRATCH_PROFILE_A)
    ctx:Expect(rawProfile(SCRATCH_PROFILE_A)):ToBeNil()
    for _, name in ipairs(db:GetProfiles()) do
      ctx:Expect(name).Not:ToBe(SCRATCH_PROFILE_A)
    end
    ctx:Expect(deletions):ToEqual({ SCRATCH_PROFILE_A })
    ctx:Expect(keptView.label):ToBeNil()
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      keptView.label = "back"
    end, lines, ACCOUNT_PREFIX .. "profile belongs to a profile that was deleted or reset away")
    ctx:Expect(rawProfile(SCRATCH_PROFILE_A)):ToBeNil()
  end
)

profiles:Test(
  "GetProfiles answers a fresh array sorted with <, always holding the character profile",
  function(ctx)
    local db = openDatabases(ctx)
    local characterKey = requireCharacterKey(ctx)
    db:SetProfile(SCRATCH_PROFILE_B)
    db:SetProfile(SCRATCH_PROFILE_A)
    db:SetProfile(characterKey)
    local first = db:GetProfiles()
    ctx:Expect(db:GetProfiles()).Not:ToBe(first)
    ctx:Log("profiles: " .. table.concat(first, ", "))
    local sorted = {}
    local hasCharacter = false
    for index, name in ipairs(first) do
      sorted[index] = name
      hasCharacter = hasCharacter or name == characterKey
    end
    table.sort(sorted)
    ctx:Expect(first):ToEqual(sorted)
    ctx:Expect(hasCharacter):ToBe(true)
  end
)

-- settingsKit.migrations -----------------------------------------------------------------------

local migrations = newSuite("migrations")

migrations:Test(
  "a table written by an older version runs migrations 2 and 3 once each, in ascending order, on the raw table, and stores version 3",
  function(ctx)
    local name = newScratchGlobal("older")
    local calls = {}
    writeOwnGlobal(name, { version = 1, scale = 1.5 })
    local db = SettingsKit:Open(name, SCRATCH_SCHEMA, {
      version = 3,
      migrations = {
        [2] = function(raw)
          calls[#calls + 1] = 2
          raw.profiles = { Default = { scale = raw.scale } }
          raw.scale = nil
        end,
        [3] = function(raw)
          calls[#calls + 1] = 3
          raw.profiles.Default.scale = raw.profiles.Default.scale * 2
        end,
      },
    })
    ctx:Expect(calls):ToEqual({ 2, 3 })
    ctx:Expect(rawget(readHost(name), "version")):ToBe(3)
    ctx:Expect(rawget(readHost(name), "scale")):ToBeNil()
    ctx:Expect(db:GetProfile()):ToBe("Default")
    ctx:Expect(db.profile.scale):ToBe(3)
  end
)

migrations:Test(
  "a new, empty saved table is stamped with the version and no migration runs",
  function(ctx)
    local name = newScratchGlobal("fresh")
    local calls = 0
    SettingsKit:Open(name, SCRATCH_SCHEMA, {
      version = 2,
      migrations = {
        [1] = function()
          calls = calls + 1
        end,
        [2] = function()
          calls = calls + 1
        end,
      },
    })
    ctx:Expect(calls):ToBe(0)
    ctx:Expect(rawget(readHost(name), "version")):ToBe(2)
  end
)

migrations:Test(
  "a migration that raises stops Open at the calling line naming the step, keeps the finished step, and the next Open retries from the failing step only",
  function(ctx)
    local name = newScratchGlobal("failing")
    writeOwnGlobal(name, { version = 1, legacy = true })
    local calls = {}
    local failStep3 = true
    local steps = {
      [2] = function()
        calls[#calls + 1] = 2
      end,
      [3] = function()
        calls[#calls + 1] = 3
        if failStep3 then
          error("step three is not ready", 0)
        end
      end,
    }
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      SettingsKit:Open(name, SCRATCH_SCHEMA, { version = 3, migrations = steps })
    end, lines, "SettingsKit:Open migration 3 of " .. name .. " failed: step three is not ready")
    ctx:Expect(rawget(readHost(name), "version")):ToBe(2)

    failStep3 = false
    SettingsKit:Open(name, SCRATCH_SCHEMA, { version = 3, migrations = steps })
    ctx:Expect(calls):ToEqual({ 2, 3, 3 })
    ctx:Expect(rawget(readHost(name), "version")):ToBe(3)
  end
)

migrations:Test(
  "a stored version above options.version is left alone and no migration runs",
  function(ctx)
    local name = newScratchGlobal("downgrade")
    writeOwnGlobal(name, { version = 5 })
    local calls = 0
    SettingsKit:Open(name, SCRATCH_SCHEMA, {
      version = 2,
      migrations = {
        [2] = function()
          calls = calls + 1
        end,
      },
    })
    ctx:Expect(calls):ToBe(0)
    ctx:Expect(rawget(readHost(name), "version")):ToBe(5)
  end
)

migrations:Test(
  "a stored version above options.version opens read-only: IsReadOnly is true, reads work, a view write and SetProfile are refused at the calling line with the exact message, and the saved table and its version stay unchanged",
  function(ctx)
    local name = newScratchGlobal("readOnly")
    writeOwnGlobal(
      name,
      { version = NEWER_STORED_VERSION, profiles = { Default = { scale = 1.5 } } }
    )
    local db = SettingsKit:Open(name, SCRATCH_SCHEMA, { version = OLDER_OPEN_VERSION })
    ctx:Expect(db:IsReadOnly()):ToBe(true)
    ctx:Expect(db.profile.scale):ToBe(1.5)
    ctx:Expect(db:GetProfile()):ToBe("Default")

    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      db.profile.scale = 1
    end, lines, "SettingsKit (" .. name .. ") profile is read-only: " .. readOnlyReason())
    expectErrorAtCallingLine(
      ctx,
      function()
        lines.start = currentLine()
        db:SetProfile("Other")
      end,
      lines,
      "SettingsKit.Database:SetProfile cannot change "
        .. name
        .. ", which is read-only: "
        .. readOnlyReason()
    )
    ctx:Expect(copySaved(readHost(name), 1)):ToEqual({
      version = NEWER_STORED_VERSION,
      profiles = { Default = { scale = 1.5 } },
    })
  end
)

migrations:Test(
  "allowNewerData opens a stored version above options.version writable, and neither a write nor ResetDatabase lowers the stored version",
  function(ctx)
    local name = newScratchGlobal("allowNewer")
    writeOwnGlobal(
      name,
      { version = NEWER_STORED_VERSION, profiles = { Default = { scale = 1.5 } } }
    )
    local db = SettingsKit:Open(
      name,
      SCRATCH_SCHEMA,
      { version = OLDER_OPEN_VERSION, allowNewerData = true }
    )
    ctx:Expect(db:IsReadOnly()):ToBe(false)
    db.profile.scale = 2
    ctx
      :Expect(
        rawField(rawTableField(rawTableField(readHost(name), "profiles"), "Default"), "scale")
      )
      :ToBe(2)
    ctx:Expect(rawget(readHost(name), "version")):ToBe(NEWER_STORED_VERSION)
    db:ResetDatabase()
    ctx:Expect(rawget(readHost(name), "version")):ToBe(NEWER_STORED_VERSION)
    ctx:Expect(db.profile.scale):ToBe(1)
  end
)

migrations:Test(
  "a migration step that writes and then raises leaves the saved table untouched, and the retry applies the step once: scale 1 becomes 2, not 4",
  function(ctx)
    local name = newScratchGlobal("atomic")
    writeOwnGlobal(name, { version = 1, profiles = { Default = { scale = 1 } } })
    local failStep2 = true
    local steps = {
      [2] = function(raw)
        raw.profiles.Default.scale = raw.profiles.Default.scale * 2
        if failStep2 then
          error("interrupted after writing", 0)
        end
      end,
    }
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      SettingsKit:Open(name, SCRATCH_SCHEMA, { version = 2, migrations = steps })
    end, lines, "SettingsKit:Open migration 2 of " .. name .. " failed: interrupted after writing")
    ctx:Expect(copySaved(readHost(name), 1)):ToEqual({
      version = 1,
      profiles = { Default = { scale = 1 } },
    })

    failStep2 = false
    local db = SettingsKit:Open(name, SCRATCH_SCHEMA, { version = 2, migrations = steps })
    ctx:Expect(db.profile.scale):ToBe(2)
    ctx:Expect(rawget(readHost(name), "version")):ToBe(2)
  end
)

migrations:Test(
  "a scalar stored where the schema declares a record reads as absent: the default view answers frame.x 0, and the next write replaces the scalar",
  function(ctx)
    local name = newScratchGlobal("corrupted")
    writeOwnGlobal(name, { profiles = { Default = { frame = 5 } } })
    local db = SettingsKit:Open(name, SCRATCH_RECORD_SCHEMA)
    ctx:Expect(getmetatable(db.profile.frame)):ToBe("SettingsKit.View")
    ctx:Expect(db.profile.frame.x):ToBe(0)
    ctx
      :Expect(
        rawField(rawTableField(rawTableField(readHost(name), "profiles"), "Default"), "frame")
      )
      :ToBe(5)
    db.profile.frame.x = 3
    ctx
      :Expect(copySaved(rawTableField(rawTableField(readHost(name), "profiles"), "Default"), 1))
      :ToEqual({ frame = { x = 3 } })
  end
)

-- settingsKit.allocation ------------------------------------------------------------------------

local allocation = newSuite("allocation")

allocation:Test(
  "reads through views of the real saved variable (scale, frame.x, a held auras entry's shown, char.touched, global.counter) allocate nothing over 5000 cycles",
  function(ctx)
    local db = openDatabases(ctx)
    local heldEntry = db.profile.auras[AURA_SPELL_ID]
    local profile = db.profile
    expectNoAllocation(ctx, "view reads", function()
      local _ = profile.scale
      _ = profile.frame.x
      _ = heldEntry.shown
      _ = profile.auras[AURA_SPELL_ID].shown
      _ = db.char.touched
      _ = db.global.counter
    end)
  end
)

allocation:Test(
  "a validated write of an existing key with a plain value allocates nothing over 5000 cycles",
  function(ctx)
    local db = openDatabases(ctx)
    local frame = db.profile.frame
    expectNoAllocation(ctx, "validated writes of frame.y", function(index)
      frame.y = index % 2
    end)
    ctx:Expect(type(db.profile.frame.y)):ToBe("number")
  end
)

--- The path the Validate allocation guard checks, built once.
local FRAME_X_PATH = { "frame", "x" }

allocation:Test(
  "Validate of a plain value with an array path allocates nothing over 5000 cycles",
  function(ctx)
    local db = openDatabases(ctx)
    local accepted = true
    expectNoAllocation(ctx, "Validate('profile', { 'frame', 'x' }, n)", function(index)
      local ok = db:Validate("profile", FRAME_X_PATH, index)
      accepted = accepted and ok
    end)
    ctx:Expect(accepted):ToBe(true)
  end
)

-- settingsKit.secrets ---------------------------------------------------------------------------

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

---Check that `received` is still secret and of the secret's type. Identity
---cannot be checked: comparing a secret with a value of its own type raises,
---`rawequal(secret, secret)` included (measured on Retail 12.1.0 b69933).
---@param ctx TestKit.Context
---@param received any
---@param expectedType string
local function expectSecretOfType(ctx, received, expectedType)
  ctx:Expect(isSecretValue(received)):ToBe(true)
  ctx:Expect(type(received)):ToBe(expectedType)
end

secretTest(
  "a secret string and a secret number stored in the raw saved table behind profile.label and profile.frame.x read back through the views still secret, of their types, without raising",
  function(ctx)
    local db = openDatabases(ctx)
    local characterKey = requireCharacterKey(ctx)
    local profile = rawProfile(characterKey)
    ctx:Expect(type(profile)):ToBe("table")
    ---@cast profile table
    rawset(profile, "label", makeSecret(ctx, SECRET_TEXT))
    rawset(profile, "frame", { x = makeSecret(ctx, SECRET_NUMBER) })

    local readLabel, label = pcall(function()
      return db.profile.label
    end)
    local readX, x = pcall(function()
      return db.profile.frame.x
    end)
    ctx:Expect(readLabel):ToBe(true)
    ctx:Expect(readX):ToBe(true)
    expectSecretOfType(ctx, label, "string")
    expectSecretOfType(ctx, x, "number")
    local ok, message = db:Validate("profile", "label", "plain")
    ctx:Expect(ok):ToBe(true)
    ctx:Expect(message):ToBeNil()
  end
)

secretTest(
  "Compact walks a profile holding a secret without raising and leaves the secret in place",
  function(ctx)
    local db = openDatabases(ctx)
    local characterKey = requireCharacterKey(ctx)
    local profile = rawProfile(characterKey)
    ctx:Expect(type(profile)):ToBe("table")
    ---@cast profile table
    rawset(profile, "frame", { x = makeSecret(ctx, 0) })
    local compacted, removed = pcall(db.Compact, db)
    ctx:Log("Compact: " .. (compacted and "returned " or "raised ") .. tostring(removed))
    ctx:Expect(compacted):ToBe(true)
    expectSecretOfType(ctx, rawField(rawTableField(profile, "frame"), "x"), "number")
  end
)

secretTest(
  "writing a secret value, or a table holding one, through a view raises at the writing line with 'refused a secret value' and the raw saved table is unchanged",
  function(ctx)
    local db = openDatabases(ctx)
    local characterKey = requireCharacterKey(ctx)
    local secretText = makeSecret(ctx, SECRET_TEXT)
    local secretNumber = makeSecret(ctx, SECRET_NUMBER)
    local refusal = " refused a secret value: saved variables never hold secret values"
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      db.profile.label = secretText
    end, lines, ACCOUNT_PREFIX .. "profile.label" .. refusal)
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      db.profile.frame = { x = secretNumber }
    end, lines, ACCOUNT_PREFIX .. "profile.frame" .. refusal)
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      db.char.note = secretText
    end, lines, ACCOUNT_PREFIX .. "char.note" .. refusal)
    ctx:Expect(rawField(rawProfile(characterKey), "label")):ToBeNil()
    ctx:Expect(rawField(rawProfile(characterKey), "frame")):ToBeNil()
    local ok, message = db:Validate("profile", "label", secretText)
    ctx:Expect(ok):ToBe(false)
    ctx:Expect(message):ToBe(ACCOUNT_PREFIX .. "profile.label" .. refusal)
  end
)

secretTest(
  "Validate refuses a secret key on the path with 'refused a secret key' and stores nothing",
  function(ctx)
    local db = openDatabases(ctx)
    local characterKey = requireCharacterKey(ctx)
    local secretKey = makeSecret(ctx, "label")
    local ok, message = db:Validate("profile", { secretKey }, "plain")
    ctx:Expect(ok):ToBe(false)
    ctx:Expect(message):ToBe(
      ACCOUNT_PREFIX .. "profile refused a secret key: saved variables never hold secret values"
    )
    ctx:Expect(rawField(rawProfile(characterKey), "label")):ToBeNil()
  end
)

secretTest(
  "a secret key never reads or stores: db.profile[secret], db.profile.auras[secret], db[secret] and db.profile[secret] = 1 each raise at this file's line, and the raw profile gains no key",
  function(ctx)
    local db = openDatabases(ctx)
    local characterKey = requireCharacterKey(ctx)
    local secretText = makeSecret(ctx, "label")
    local secretNumber = makeSecret(ctx, AURA_SPELL_ID)
    local keysBefore = sortedKeys(rawProfile(characterKey))
    -- SettingsKit's own refusal, or the client's, when the client refuses the
    -- key before any metamethod runs; the log says which.
    local clientRefusal = "cannot be indexed with secret keys"
    local cases = {
      {
        label = "db.profile[secret]",
        read = function()
          return db.profile[secretText]
        end,
        expected = ACCOUNT_PREFIX .. "profile cannot be read with a secret key",
      },
      {
        label = "db.profile.auras[secret]",
        read = function()
          return db.profile.auras[secretNumber]
        end,
        expected = ACCOUNT_PREFIX .. "profile.auras cannot be read with a secret key",
      },
      {
        label = "db[secret]",
        read = function()
          return db[secretText]
        end,
        expected = "SettingsKit databases cannot be read with a secret key",
      },
      {
        label = "db.profile[secret] = 1",
        read = function()
          db.profile[secretText] = 1
        end,
        expected = ACCOUNT_PREFIX
          .. "profile refused a secret key: saved variables never hold secret values",
      },
    }
    for _, case in ipairs(cases) do
      local succeeded, message = pcall(case.read)
      ctx:Expect(succeeded):ToBe(false)
      expectThisFile(ctx, message)
      if type(message) == "string" and not isSecret(message) then
        local bySettingsKit = message:sub(-#case.expected) == case.expected
        local byClient = message:find(clientRefusal, 1, true) ~= nil
        ctx:Log(
          ("%s refused by %s: %s"):format(
            case.label,
            bySettingsKit and "SettingsKit" or (byClient and "the client" or "neither"),
            message
          )
        )
        ctx:Expect(bySettingsKit or byClient):ToBe(true)
      end
    end
    ctx:Expect(sortedKeys(rawProfile(characterKey))):ToEqual(keysBefore)
  end
)

secretTest(
  "OnChange and Validate refuse a secret scope, Open a secret version and SetLimits a secret value, each at the calling line before comparing it, and the limits stay as they were",
  function(ctx)
    local db = openDatabases(ctx)
    local secretScope = makeSecret(ctx, "profile")
    local secretNumber = makeSecret(ctx, 3)
    local limitsBefore = SettingsKit:GetLimits()
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      db:OnChange(secretScope, function() end)
    end, lines, "SettingsKit.Database:OnChange scope must not be a secret value")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      db:Validate(secretScope, "scale", 1)
    end, lines, "SettingsKit.Database:Validate scope must not be a secret value")
    local name = newScratchGlobal("secretVersion")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      SettingsKit:Open(name, SCRATCH_SCHEMA, { version = secretNumber })
    end, lines, "SettingsKit:Open options.version must not be a secret value")
    ctx:Expect(readHost(name)):ToBeNil()
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      SettingsKit:SetLimits({ pathKeyLimit = secretNumber })
    end, lines, "SettingsKit:SetLimits limits.pathKeyLimit must not be a secret value")
    ctx:Expect(SettingsKit:GetLimits()):ToEqual(limitsBefore)
  end
)

-- settingsKit.persistence --------------------------------------------------------------------------
--
-- Two runs with a /reload between them. Step one writes known values and a
-- marker through the views; /reload makes the client fire PLAYER_LOGOUT (the
-- databases compact themselves), write both saved variables to disk and
-- restore them before this addon's ADDON_LOADED. Step two then reads the
-- values back. Which run this is follows from the loaded-phase copy: a marker
-- the client restored came from an earlier session.

local persistence = newSuite("persistence")

---The marker the client restored at the loaded phase, or `nil` on a first run.
---@return table|nil
local function restoredMarker()
  if restoredAtLoad == nil then
    return nil
  end
  local marker = rawTableField(rawTableField(restoredAtLoad.account, "global"), "persistence")
  if marker == nil or type(rawget(marker, "token")) ~= "string" then
    return nil
  end
  return marker
end

---End the test as skipped unless the client restored a marker from an earlier
---session, and unless that marker was written by this character.
---@param ctx TestKit.Context
---@param characterKey string
---@return table marker
local function requireRestoredMarker(ctx, characterKey)
  local marker = restoredMarker()
  if marker == nil and markerWrittenThisSession then
    Harness:SkipTest(ctx, NO_MARKER_SKIP_REASON)
  end
  if marker == nil then
    Harness:SkipTest(ctx, NO_MARKER_AT_ALL_SKIP_REASON)
  end
  ---@cast marker table
  if marker.character ~= characterKey then
    Harness:SkipTest(
      ctx,
      "the marker was written by another character; log in with it and run again"
    )
  end
  return marker
end

persistence:Test(
  "persistence step one: profile.scale 1.25, profile.anchor at its default, char.note, the per-character global.note and a marker are written through the views and stored in both raw saved tables",
  function(ctx)
    local db, characterDb = openDatabases(ctx)
    local characterKey = requireCharacterKey(ctx)
    if restoredMarker() ~= nil then
      Harness:SkipTest(
        ctx,
        "a marker from an earlier session is present; step two reads it, so nothing is rewritten"
      )
    end
    local writtenAt = timestamp()
    local token = ("%s #%06d"):format(writtenAt, math.random(0, 999999))

    db.profile.scale = PERSISTED_SCALE
    db.profile.anchor = DEFAULT_ANCHOR
    db.char.note = token
    characterDb.global.note = token
    db.global.persistence = { token = token, writtenAt = writtenAt, character = characterKey }
    markerWrittenThisSession = true
    ctx:Log("marker written: " .. token .. "; now /reload and run /mct run settingsKit again")

    ctx:Expect(db:GetProfile()):ToBe(characterKey)
    ctx:Expect(rawField(rawProfile(characterKey), "scale")):ToBe(PERSISTED_SCALE)
    ctx:Expect(rawField(rawProfile(characterKey), "anchor")):ToBe(DEFAULT_ANCHOR)
    ctx:Expect(rawField(rawScopeEntry("char", characterKey), "note")):ToBe(token)
    ctx:Expect(rawField(rawTableField(readHost(CHARACTER_DB_NAME), "global"), "note")):ToBe(token)
    ctx
      :Expect(rawTableField(rawTableField(readHost(ACCOUNT_DB_NAME), "global"), "persistence"))
      :ToEqual({
        token = token,
        writtenAt = writtenAt,
        character = characterKey,
      })
  end
)

persistence:Test(
  "persistence step two: after /reload the client restored both saved tables after this file ran (nil at file scope) and before the loaded phase, and the views read back the marker, scale 1.25, char.note and the per-character note",
  function(ctx)
    local db, characterDb = openDatabases(ctx)
    local characterKey = requireCharacterKey(ctx)
    local marker = requireRestoredMarker(ctx, characterKey)
    ---@cast restoredAtLoad table
    ctx:Log("marker restored by the client: " .. tostring(marker.token))
    ctx:Expect(typesAtFileScope.account):ToBe("nil")
    ctx:Expect(typesAtFileScope.character):ToBe("nil")
    ctx:Expect(restoredAtLoad.accountType):ToBe("table")
    ctx:Expect(restoredAtLoad.characterType):ToBe("table")
    ctx:Expect(rawget(restoredAtLoad.account, "version")):ToBe(ACCOUNT_DB_VERSION)
    ctx:Expect(rawget(restoredAtLoad.character, "version")):ToBe(CHARACTER_DB_VERSION)

    ctx:Expect(db:GetProfile()):ToBe(characterKey)
    ctx:Expect(db.global.persistence.token):ToBe(marker.token)
    ctx:Expect(db.profile.scale):ToBe(PERSISTED_SCALE)
    ctx:Expect(db.char.note):ToBe(marker.token)
    ctx:Expect(characterDb.global.note):ToBe(marker.token)

    db.global.persistence.verifiedAt = timestamp()
    ctx:Log(
      "verified at "
        .. db.global.persistence.verifiedAt
        .. "; the cleanup test may now empty both tables"
    )
  end
)

persistence:Test(
  "persistence step two: the PLAYER_LOGOUT compaction removed profile.anchor, written equal to its default in step one, before the client wrote the file, and kept scale",
  function(ctx)
    openDatabases(ctx)
    local characterKey = requireCharacterKey(ctx)
    requireRestoredMarker(ctx, characterKey)
    if type(Registry:Find("eventKit", EVENT_KIT_API)) == "nil" then
      Harness:SkipTest(ctx, "EventKit is not loaded, so SettingsKit compacts only when asked")
    end
    ---@cast restoredAtLoad table
    local profile = rawTableField(rawTableField(restoredAtLoad.account, "profiles"), characterKey)
    ctx:Log("restored profile keys: " .. table.concat(sortedKeys(profile), ", "))
    ctx:Expect(rawField(profile, "scale")):ToBe(PERSISTED_SCALE)
    ctx:Expect(rawField(profile, "anchor")):ToBeNil()
  end
)

-- settingsKit.cleanup ------------------------------------------------------------------------------
--
-- Registered last, so it runs after every other settingsKit test of the run.

local cleanup = newSuite("cleanup")

cleanup:Test(
  "cleanup: once persistence step two passed, both saved variables are emptied so the files hold no data after the next /reload",
  function(ctx)
    if cleanedThisSession then
      Harness:SkipTest(ctx, "already emptied in this session; /reload writes the empty files")
    end
    local marker = rawTableField(rawTableField(readHost(ACCOUNT_DB_NAME), "global"), "persistence")
    if type(rawField(marker, "verifiedAt")) ~= "string" then
      Harness:SkipTest(
        ctx,
        "persistence step two has not passed yet; the saved tables are kept for the run after /reload"
      )
    end
    -- The databases stay open for the session over the tables they hold, but
    -- the globals the client writes at logout are gone.
    writeOwnGlobal(ACCOUNT_DB_NAME, nil)
    writeOwnGlobal(CHARACTER_DB_NAME, nil)
    cleanedThisSession = true
    ctx:Expect(readHost(ACCOUNT_DB_NAME)):ToBeNil()
    ctx:Expect(readHost(CHARACTER_DB_NAME)):ToBeNil()
    ctx:Log("both saved variables are empty; /reload or log out to write the empty files")
  end
)
