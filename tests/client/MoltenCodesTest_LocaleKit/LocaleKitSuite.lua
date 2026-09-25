-- MoltenCodes Test: LocaleKitSuite.lua
--
-- Real-client suites for the `localeKit` package. The Busted specs under
-- packages/localeKit/tests/ prove LocaleKit on a stock Lua 5.1 with a stubbed
-- `GetLocale`, a fake error handler and a string that stands in for a secret.
-- These prove, inside the game client with the installed MoltenCodes addon,
-- what that fixture can only simulate:
--
--   * the installed facade and its committed revision;
--   * that the client's own `GetLocale()` (with `enGB` folded to `enUS`)
--     decides which translation file is needed and which text the read table
--     holds, with the default locale as the fallback;
--   * `SetLocaleOverride` to another locale and back to the client's, with the
--     override put back by the suite's After hook whatever the outcome;
--   * the three missing-key modes, the report through the client's real error
--     handler, the coverage report and the `maxMissingKeys` cap;
--   * `Format` on the client's own `string.format` and `string.gsub`: indexed
--     specifiers, flags, width and precision, and what the client's
--     `string.format` itself does with an indexed specifier (LocaleKit never
--     hands it one: it rewrites `%2$s` to `%s` and picks the argument itself);
--   * argument, assignment and template errors pointing at this file as the
--     client names it, including the template errors raised through the
--     client's C `string.gsub`;
--   * that reading the read table and repeating a `Format` allocate nothing on
--     the client's own collector;
--   * the refusal of genuine secret values made by `secretwrap`, where
--     docs/API.md promises one, and the client's own refusal of a secret key
--     at the read table's index, before LocaleKit's `__index` runs.
--
-- UTF-8 text in the client's font strings is out of scope: LocaleKit stores
-- and returns bytes, and docs/API.md promises nothing about rendering.
--
-- Nothing here needs combat, a group or an instance, and nothing is visible.
--
-- Run with `/mct run localeKit`; tests/client/MoltenCodesTest_LocaleKit/EXPECTED.md
-- lists what the chat frame should show.
--
-- What a run leaves behind. LocaleKit keeps every addon it registered for the
-- session and has no way to forget one (docs/API.md, "Embedded copies and
-- upgrades": nothing survives `/reload`, and nothing is freed before it). Each
-- test therefore registers its own probe addon under a fresh name
-- (`mctLocaleKit<Label><n>`, with `n` counting up per run), so a second run in
-- the same session meets none of the first run's records; each run leaves a
-- few dozen small probe records until `/reload`. The locale override is
-- cleared again by the After hook of the suite that sets it. The client's
-- error handler is replaced only for the length of one synchronous call and
-- put back at once. Nothing is written to a global, a saved variable or a
-- CVar.

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
local LOCALE_KIT_API = 1
local PACKAGE_ID = "localeKit"

--- The file name every error position must end with.
local SUITE_FILE = "LocaleKitSuite.lua"

--- Every method docs/API.md of localeKit lists on the facade, in its order.
local FACADE_METHODS = {
  "NewLocale",
  "GetLocale",
  "MissingKeys",
  "Format",
  "SetLocaleOverride",
}

--- The client locales LocaleKit folds, as docs/API.md ("The client locale") lists them.
local FOLDED_LOCALES = { enGB = "enUS" }

--- The locale a client without a usable `GetLocale` answer is treated as.
local FALLBACK_LOCALE = "enUS"

--- Shape of a client locale code, as LocaleKit accepts one.
local LOCALE_CODE_PATTERN = "^%l%l%u%u$"

--- Locales a test may pick as "another locale than the client's": the first
--- one that differs from the client's is used.
local OTHER_LOCALE_CANDIDATES = { "deDE", "frFR" }

--- How many reads or calls each allocation guard makes. One table or closure
--- per call would cost hundreds of kilobytes at this count.
local GUARD_ITERATIONS = 10000

--- Kilobytes an allocation guard tolerates. The tolerance absorbs a stray
--- allocation by the client between the two readings, not a per-call one.
local ALLOCATION_TOLERANCE_KB = 1

---Read a client global, or `nil`.
---@param name string
---@return any
local function readHost(name)
  -- GetLocale, the error-handler functions, string functions of the client
  -- and the secret-value functions are World of Warcraft client globals,
  -- reachable only through the global table.
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

---@type Registry
local Registry = rawget(rawget(namespace, "Registries") or {}, REGISTRY_API)
if type(Registry) ~= "table" then
  error(addonName .. " requires the MoltenCodes addon (Registry API 2); reinstall it", 0)
end

-- LocaleKit is not in the language-server workspace of tests/client (its
-- .luarc.json lists TestKit's dependency closure only), so its facade and the
-- tables it returns are typed `any` here.

---@type any
local LocaleKit = Registry:Get(PACKAGE_ID, LOCALE_KIT_API)
if type(LocaleKit) == "nil" then
  error(addonName .. " requires LocaleKit API 1 in the MoltenCodes addon; reinstall it", 0)
end

--- The client's `string.format`, read once: the format suite compares
--- LocaleKit's result with what the client's own function answers.
local clientStringFormat = string.format

--- The two client functions the secrets suite needs, read once at load: the
--- suite registers its tests as skipped when either is missing.
local isSecretValue = readHost("issecretvalue")
local secretWrap = readHost("secretwrap")
local SECRETS_AVAILABLE = type(isSecretValue) == "function" and type(secretWrap) == "function"

-- Helpers ---------------------------------------------------------------------------

--- Counts the probe addon names handed out in this session.
local probeSequence = 0

---A probe addon name no earlier test or run of this session has registered.
---@param label string what the probe is for, part of the name
---@return string
local function freshAddonName(label)
  probeSequence = probeSequence + 1
  return "mctLocaleKit" .. label .. probeSequence
end

---The client's own `GetLocale()` answer, and the locale LocaleKit should
---derive from it: folded (`enGB` to `enUS`), or `enUS` when the answer is not
---a locale code.
---@return string clientLocale the locale LocaleKit should register addons under
---@return any rawAnswer what `GetLocale()` returned, for the log
local function readClientLocale()
  local getLocale = readHost("GetLocale")
  if type(getLocale) ~= "function" then
    return FALLBACK_LOCALE, nil
  end
  local answer = getLocale()
  if type(answer) ~= "string" or type(answer:match(LOCALE_CODE_PATTERN)) == "nil" then
    return FALLBACK_LOCALE, answer
  end
  return FOLDED_LOCALES[answer] or answer, answer
end

---A locale code that is not `locale`.
---@param locale string
---@return string
local function otherLocaleThan(locale)
  for _, candidate in ipairs(OTHER_LOCALE_CANDIDATES) do
    if candidate ~= locale then
      return candidate
    end
  end
  return OTHER_LOCALE_CANDIDATES[1]
end

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
---client has no `debug` library, so this is how a line number is read.
---@return integer
local function currentLine()
  local _, position = pcall(error, "", 3)
  local _, line = splitPosition(position or "")
  return line or 0
end

---Check that `message` is a string naming this file, and return its line.
---@param ctx TestKit.Context
---@param message any
---@return integer|nil line
local function expectThisFile(ctx, message)
  ctx:Expect(type(message)):ToBe("string")
  if type(message) ~= "string" then
    return nil
  end
  local file, line = splitPosition(message)
  ctx:Expect(type(file)):ToBe("string")
  ctx:Expect((file or ""):sub(-#SUITE_FILE)):ToBe(SUITE_FILE)
  return line
end

---Call `raise`, which must record its start line with `currentLine()` and
---raise on the next line, and check the message names this file at that next
---line and ends with `expected`.
---@param ctx TestKit.Context
---@param raise fun() Records its start line in `lineHolder.start`, then raises on the next line.
---@param lineHolder { start: integer }
---@param expected string The message after the position, compared literally.
local function expectErrorAtNextLine(ctx, raise, lineHolder, expected)
  local succeeded, message = pcall(raise)
  ctx:Expect(succeeded):ToBe(false)
  ctx:Log("client message: " .. tostring(message))

  local line = expectThisFile(ctx, message)
  ctx:Expect(line):ToBe(lineHolder.start + 1)
  ctx:Expect(tostring(message):sub(-#expected)):ToBe(expected)
end

---Run `action`, which must not yield, with the client's error handler
---replaced by a collector, and put the previous handler back before returning.
---
---LocaleKit reports a missing key by calling `geterrorhandler()` and then the
---handler it returns. On the client `geterrorhandler` only reads the handler
---`seterrorhandler` installed, and replacing the global would taint a function
---Blizzard code calls, so the handler itself is swapped for the call. A host
---without `seterrorhandler` (the Busted fixture) gets the global replaced for
---the test instead; TestKit puts it back.
---@param ctx TestKit.Context
---@param action fun()
---@return any[] reported every value the collector received, in order
---@return boolean observed whether the collector was the handler LocaleKit would find
local function collectReports(ctx, action)
  local reported = {}
  ---@param message any
  local function collector(message)
    reported[#reported + 1] = message
  end

  local restore = nil
  local observed = false
  local setErrorHandler = readHost("seterrorhandler")
  local getErrorHandler = readHost("geterrorhandler")
  if type(setErrorHandler) == "function" and type(getErrorHandler) == "function" then
    local previous = getErrorHandler()
    setErrorHandler(collector)
    -- An error-capturing addon (BugGrabber) may refuse the swap.
    observed = getErrorHandler() == collector
    restore = function()
      setErrorHandler(previous)
    end
  else
    -- The global is replaced for this test only; TestKit puts it back.
    -- selene: allow(global_usage)
    ctx:Replace(_G, "geterrorhandler", function()
      return collector
    end)
    observed = true
  end

  local succeeded, problem = pcall(action)
  if restore ~= nil then
    restore()
  end
  if not succeeded then
    error(problem, 0)
  end
  return reported, observed
end

---Fail the test when the error handler could not be replaced, naming why.
---@param ctx TestKit.Context
---@param observed boolean
local function requireObservedHandler(ctx, observed)
  if not observed then
    ctx:Fail(
      "the client's error handler could not be replaced (an error-capturing addon such as BugGrabber keeps it); the reports went to that addon"
    )
  end
end

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

---Register a fresh probe addon with an English default file of `keys`, each
---its own text, and return its name.
---@param label string
---@param keys string[]
---@return string probeName
local function probeWithDefaults(label, keys)
  local probeName = freshAddonName(label)
  local default = LocaleKit:NewLocale(probeName, FALLBACK_LOCALE, { isDefault = true })
  for _, key in ipairs(keys) do
    default[key] = true
  end
  return probeName
end

---Register a suite of this package.
---@param part string
---@return TestKit.Suite
local function newSuite(part)
  return Harness:Suite(PACKAGE_ID, part, addonName)
end

-- localeKit.facade ----------------------------------------------------------------------

local facade = newSuite("facade")

facade:Test(
  "Registry:Get('localeKit', 1) is the LocaleKit facade with API 1, every documented method and UNBOUNDED",
  function(ctx)
    ctx:Expect(type(LocaleKit)):ToBe("table")
    ctx:Expect(rawget(LocaleKit, "API")):ToBe(LOCALE_KIT_API)
    for _, method in ipairs(FACADE_METHODS) do
      ctx:Expect(type(LocaleKit[method])):ToBe("function")
    end
    ctx:Expect(type(LocaleKit.UNBOUNDED)):ToBe("table")
  end
)

facade:Test("the installed LocaleKit carries the revision of the committed manifest", function(ctx)
  local expectedPackages = Harness:GetExpectedPackages()
  if type(expectedPackages) == "nil" then
    ctx:Fail("Expected.lua is missing; install with python3 -m tooling.client.install")
    return
  end
  for _, expected in ipairs(expectedPackages) do
    if expected.id == PACKAGE_ID then
      local _, revision = Registry:Get(PACKAGE_ID, LOCALE_KIT_API)
      ctx:Expect(revision):ToBe(expected.revision)
      ctx:Expect(rawget(LocaleKit, "REVISION")):ToBe(expected.revision)
      return
    end
  end
  ctx:Fail("Expected.lua does not list localeKit")
end)

-- localeKit.clientLocale ------------------------------------------------------------------

local clientLocaleSuite = newSuite("clientLocale")

--- Whether a test of this suite set a locale override that the After hook
--- must clear.
local overrideSetByTest = false

clientLocaleSuite:After(function()
  if overrideSetByTest then
    overrideSetByTest = false
    LocaleKit:SetLocaleOverride(nil)
  end
end)

---Set the locale override for the running test, remembering that the After
---hook must clear it.
---@param locale string
local function setTestOverride(locale)
  overrideSetByTest = true
  LocaleKit:SetLocaleOverride(locale)
end

---Whether LocaleKit registers a fresh addon under `clientLocale`, which is
---true when no other addon of the session set an override (or set it to the
---client's own locale, which behaves the same).
---@param clientLocale string
---@return boolean
local function registersUnderClientLocale(clientLocale)
  return type(LocaleKit:NewLocale(freshAddonName("OverrideProbe"), clientLocale)) ~= "nil"
end

clientLocaleSuite:Test(
  "NewLocale needs the locale the client's own GetLocale() names (enGB folded to enUS) and returns nil for any other, enGB included",
  function(ctx)
    local clientLocale, rawAnswer = readClientLocale()
    ctx:Log(
      "GetLocale() answered "
        .. tostring(rawAnswer)
        .. "; LocaleKit should register under "
        .. clientLocale
    )
    ctx:Expect(type(rawAnswer)):ToBe("string")
    if not registersUnderClientLocale(clientLocale) then
      Harness:SkipTest(ctx, "another addon set a LocaleKit locale override in this session")
      return
    end

    local probeName = freshAddonName("Needed")
    local otherLocale = otherLocaleThan(clientLocale)
    ctx:Expect(LocaleKit:NewLocale(probeName, otherLocale)):ToBeNil()
    ctx:Expect(type(LocaleKit:NewLocale(probeName, clientLocale))):ToBe("table")
    ctx:Expect(LocaleKit:NewLocale(probeName, "enGB")):ToBeNil()
    -- A default is needed on every client, whatever its locale.
    local default = LocaleKit:NewLocale(probeName, otherLocale, { isDefault = true })
    ctx:Expect(type(default)):ToBe("table")
  end
)

clientLocaleSuite:Test(
  "the read table holds the client locale's text over the default, the default's text for the rest, and nothing from another locale",
  function(ctx)
    local clientLocale = readClientLocale()
    if not registersUnderClientLocale(clientLocale) then
      Harness:SkipTest(ctx, "another addon set a LocaleKit locale override in this session")
      return
    end
    local probeName = probeWithDefaults("Fallback", { "Greeting", "Farewell" })

    local translation = LocaleKit:NewLocale(probeName, clientLocale)
    translation["Greeting"] = "client greeting"
    local other = LocaleKit:NewLocale(probeName, otherLocaleThan(clientLocale))
    ctx:Expect(other):ToBeNil()

    local strings = LocaleKit:GetLocale(probeName, { missing = "silent" })
    ctx:Expect(strings["Greeting"]):ToBe("client greeting")
    ctx:Expect(strings["Farewell"]):ToBe("Farewell")
  end
)

clientLocaleSuite:Test(
  "a default file for the client's own locale keeps a translation that loaded first, and a later client-locale file still overwrites",
  function(ctx)
    local clientLocale = readClientLocale()
    if not registersUnderClientLocale(clientLocale) then
      Harness:SkipTest(ctx, "another addon set a LocaleKit locale override in this session")
      return
    end
    local probeName = freshAddonName("SameLocale")

    local translation = LocaleKit:NewLocale(probeName, clientLocale)
    translation["Title"] = "translated first"
    local default = LocaleKit:NewLocale(probeName, clientLocale, { isDefault = true })
    default["Title"] = true
    default["Only default"] = true
    -- Reading through a proxy returns what is stored so far and never reports.
    ctx:Expect(default["Title"]):ToBe("translated first")

    local later = LocaleKit:NewLocale(probeName, clientLocale)
    later["Only default"] = "overwritten by a later file"

    local strings = LocaleKit:GetLocale(probeName, { missing = "raw" })
    ctx:Expect(strings["Title"]):ToBe("translated first")
    ctx:Expect(strings["Only default"]):ToBe("overwritten by a later file")
  end
)

clientLocaleSuite:Test(
  "SetLocaleOverride to another locale registers new addons under it, keeps earlier addons on theirs, and nil restores the client's locale",
  function(ctx)
    local clientLocale = readClientLocale()
    if not registersUnderClientLocale(clientLocale) then
      Harness:SkipTest(
        ctx,
        "another addon set a LocaleKit locale override in this session; this test would clear it"
      )
      return
    end
    local otherLocale = otherLocaleThan(clientLocale)
    local registeredBefore = freshAddonName("BeforeOverride")
    ctx:Expect(type(LocaleKit:NewLocale(registeredBefore, clientLocale))):ToBe("table")

    -- Everything from here to the restore runs without yielding, so no
    -- other addon's file can register while the override is set.
    setTestOverride(otherLocale)
    local registeredDuring = freshAddonName("DuringOverride")
    ctx:Expect(type(LocaleKit:NewLocale(registeredDuring, otherLocale))):ToBe("table")
    ctx:Expect(LocaleKit:NewLocale(registeredDuring, clientLocale)):ToBeNil()
    -- An addon registered before the override keeps the client's locale.
    ctx:Expect(type(LocaleKit:NewLocale(registeredBefore, clientLocale))):ToBe("table")
    ctx:Expect(LocaleKit:NewLocale(registeredBefore, otherLocale)):ToBeNil()

    LocaleKit:SetLocaleOverride(nil)
    overrideSetByTest = false
    local registeredAfter = freshAddonName("AfterOverride")
    ctx:Expect(type(LocaleKit:NewLocale(registeredAfter, clientLocale))):ToBe("table")
    ctx:Expect(LocaleKit:NewLocale(registeredAfter, otherLocale)):ToBeNil()
    -- The addon registered during the override stays on the override's locale.
    ctx:Expect(type(LocaleKit:NewLocale(registeredDuring, otherLocale))):ToBe("table")
  end
)

clientLocaleSuite:Test(
  "SetLocaleOverride('enGB') registers new addons under enUS, so an enGB file is never needed",
  function(ctx)
    local clientLocale = readClientLocale()
    if not registersUnderClientLocale(clientLocale) then
      Harness:SkipTest(
        ctx,
        "another addon set a LocaleKit locale override in this session; this test would clear it"
      )
      return
    end

    setTestOverride("enGB")
    local probeName = freshAddonName("FoldedOverride")
    ctx:Expect(LocaleKit:NewLocale(probeName, "enGB")):ToBeNil()
    ctx:Expect(type(LocaleKit:NewLocale(probeName, "enUS"))):ToBe("table")
    LocaleKit:SetLocaleOverride(nil)
    overrideSetByTest = false
  end
)

-- localeKit.missing -----------------------------------------------------------------------

local missing = newSuite("missing")

missing:Test(
  "report mode returns a missing key as itself and reports it once through the client's error handler, naming the client locale",
  function(ctx)
    local clientLocale = readClientLocale()
    if not registersUnderClientLocale(clientLocale) then
      Harness:SkipTest(ctx, "another addon set a LocaleKit locale override in this session")
      return
    end
    local probeName = probeWithDefaults("Report", { "Defined" })
    local strings = LocaleKit:GetLocale(probeName)

    local firstRead, secondRead, definedRead
    local reported, observed = collectReports(ctx, function()
      firstRead = strings["Untranslated key"]
      secondRead = strings["Untranslated key"]
      definedRead = strings["Defined"]
    end)
    requireObservedHandler(ctx, observed)

    ctx:Expect(firstRead):ToBe("Untranslated key")
    ctx:Expect(secondRead):ToBe("Untranslated key")
    ctx:Expect(definedRead):ToBe("Defined")
    ctx:Expect(#reported):ToBe(1)
    ctx:Log("reported: " .. tostring(reported[1]))
    ctx:Expect(reported[1]):ToBe(
      'LocaleKit: missing translation "Untranslated key" for '
        .. probeName
        .. " ("
        .. clientLocale
        .. ")"
    )
  end
)

missing:Test(
  "silent mode returns a missing key as itself without a report, and raw mode returns nil and records nothing",
  function(ctx)
    local silentName = probeWithDefaults("Silent", { "Defined" })
    local rawName = probeWithDefaults("Raw", { "Defined" })
    local silentStrings = LocaleKit:GetLocale(silentName, { missing = "silent" })
    local rawStrings = LocaleKit:GetLocale(rawName, { missing = "raw" })

    local silentRead, rawRead, rawDefined
    local reported, observed = collectReports(ctx, function()
      silentRead = silentStrings["Not here"]
      rawRead = rawStrings["Not here"]
      rawDefined = rawStrings["Defined"]
    end)
    requireObservedHandler(ctx, observed)

    ctx:Expect(silentRead):ToBe("Not here")
    ctx:Expect(rawRead):ToBeNil()
    ctx:Expect(rawDefined):ToBe("Defined")
    ctx:Expect(#reported):ToBe(0)
    ctx:Expect(LocaleKit:MissingKeys(silentName)):ToEqual({ "Not here" })
    ctx:Expect(LocaleKit:MissingKeys(rawName)):ToEqual({})
  end
)

missing:Test(
  "MissingKeys lists the keys read but never defined, sorted, and drops a key once a later file defines it",
  function(ctx)
    local clientLocale = readClientLocale()
    local probeName = probeWithDefaults("Coverage", { "Defined" })
    local strings = LocaleKit:GetLocale(probeName, { missing = "silent" })

    local _ = strings["zeta"]
    _ = strings["Alpha"]
    _ = strings["beta"]
    _ = strings["Defined"]
    ctx:Expect(LocaleKit:MissingKeys(probeName)):ToEqual({ "Alpha", "beta", "zeta" })

    -- A translation file that loads after the read defines the key.
    local translation = LocaleKit:NewLocale(probeName, clientLocale)
    if type(translation) == "nil" then
      Harness:SkipTest(ctx, "another addon set a LocaleKit locale override in this session")
      return
    end
    translation["beta"] = "translated late"
    ctx:Expect(strings["beta"]):ToBe("translated late")
    ctx:Expect(LocaleKit:MissingKeys(probeName)):ToEqual({ "Alpha", "zeta" })
  end
)

missing:Test(
  "past maxMissingKeys a missing key still reads as itself, is not recorded, and the cap is reported once",
  function(ctx)
    local probeName = probeWithDefaults("Cap", { "Defined" })
    local strings = LocaleKit:GetLocale(probeName, { maxMissingKeys = 2 })

    local reads = {}
    local reported, observed = collectReports(ctx, function()
      for _, key in ipairs({ "First", "Second", "Third", "Fourth", "Third" }) do
        reads[#reads + 1] = strings[key]
      end
    end)
    requireObservedHandler(ctx, observed)

    ctx:Expect(reads):ToEqual({ "First", "Second", "Third", "Fourth", "Third" })
    ctx:Expect(LocaleKit:MissingKeys(probeName)):ToEqual({ "First", "Second" })
    ctx:Expect(rawget(strings, "Third")):ToBeNil()
    ctx:Expect(#reported):ToBe(3)
    ctx:Expect(reported[3]):ToBe(
      "LocaleKit: "
        .. probeName
        .. " has more than 2 missing translations; further ones are neither recorded nor reported (raise options.maxMissingKeys to record more)"
    )
  end
)

-- localeKit.format ------------------------------------------------------------------------

local formatSuite = newSuite("format")

formatSuite:Test(
  "Format reorders, repeats and mixes indexed and sequential specifiers on the client's string library",
  function(ctx)
    ctx:Expect(LocaleKit:Format("%s has %d items", "Alice", 3)):ToBe("Alice has 3 items")
    ctx
      :Expect(LocaleKit:Format("%2$d items belong to %1$s", "Alice", 3))
      :ToBe("3 items belong to Alice")
    ctx:Expect(LocaleKit:Format("%1$s, %1$s!", "Bob")):ToBe("Bob, Bob!")
    ctx:Expect(LocaleKit:Format("%s %2$s %1$s", "a", "b")):ToBe("a b a")
    ctx:Expect(LocaleKit:Format("%.2f%%", 12.5)):ToBe("12.50%")
    ctx:Expect(LocaleKit:Format("%2$.1f / %1$05d", 42, 2.5)):ToBe("2.5 / 00042")
    -- Unused arguments are ignored.
    ctx:Expect(LocaleKit:Format("%2$s", "unused", "used", "unused")):ToBe("used")
  end
)

formatSuite:Test(
  "Format applies flags, width and precision exactly as the client's own string.format does",
  function(ctx)
    local template = "[%-6s|%5s|%05d|%+d|%.3f|%8.2f|% d]"
    local values = { "ab", "cd", 42, 7, 3.14159, 2.5, 9 }
    local expected = clientStringFormat(template, unpack(values, 1, #values))
    ctx:Log("client string.format: " .. expected)
    ctx:Expect(LocaleKit:Format(template, unpack(values, 1, #values))):ToBe(expected)
  end
)

formatSuite:Test(
  "Format gives the text the client's own string.format gives for fully indexed templates, where the client accepts them",
  function(ctx)
    local cases = {
      { template = "%2$s %1$s", values = { "first", "second" } },
      { template = "%2$d items belong to %1$s", values = { "Alice", 3 } },
      { template = "%1$s, %1$s!", values = { "Bob" } },
      { template = "%3$.2f %1$s %2$05d", values = { "x", 42, 1.5 } },
    }
    local compared = 0
    for _, case in ipairs(cases) do
      local count = #case.values
      local accepted, native =
        pcall(clientStringFormat, case.template, unpack(case.values, 1, count))
      ctx:Log(
        "client string.format("
          .. case.template
          .. "): "
          .. (accepted and "accepted, " or "refused, ")
          .. tostring(native)
      )
      if accepted then
        compared = compared + 1
        ctx:Expect(LocaleKit:Format(case.template, unpack(case.values, 1, count))):ToBe(native)
      end
    end
    if compared == 0 then
      Harness:SkipTest(
        ctx,
        "the client's string.format refuses indexed specifiers, so there is nothing to compare; LocaleKit:Format does not need them"
      )
    end
  end
)

formatSuite:Test(
  "a width over two digits is refused as an invalid specifier at LocaleKitSuite.lua's calling line, because the client's string.format refuses it",
  function(ctx)
    local accepted, native = pcall(clientStringFormat, "%100s", "x")
    ctx:Log(
      "client string.format('%100s'): "
        .. (accepted and "accepted, " or "refused, ")
        .. tostring(accepted and #native or native)
    )
    local lineHolder = { start = 0 }
    expectErrorAtNextLine(ctx, function()
      lineHolder.start = currentLine()
      LocaleKit:Format("%100s", "x")
    end, lineHolder, 'LocaleKit:Format template has an invalid specifier "%100s"')
  end
)

-- localeKit.errors ------------------------------------------------------------------------

local errors = newSuite("errors")

errors:Test(
  "NewLocale with a locale that is not a client locale code names LocaleKitSuite.lua at the calling line",
  function(ctx)
    local lineHolder = { start = 0 }
    expectErrorAtNextLine(ctx, function()
      lineHolder.start = currentLine()
      LocaleKit:NewLocale(freshAddonName("BadLocale"), "dede")
    end, lineHolder, 'LocaleKit:NewLocale locale must be a client locale code such as "deDE"')
  end
)

errors:Test(
  "assigning a number through a write proxy names LocaleKitSuite.lua at the assignment line",
  function(ctx)
    local default =
      LocaleKit:NewLocale(freshAddonName("BadValue"), FALLBACK_LOCALE, { isDefault = true })
    -- The wrong value type is the point of the test.
    ---@type any
    local notText = 42
    local lineHolder = { start = 0 }
    expectErrorAtNextLine(ctx, function()
      lineHolder.start = currentLine()
      default["Key"] = notText
    end, lineHolder, 'LocaleKit translation "Key" must be a string or true')
  end
)

errors:Test(
  "GetLocale for an addon that registered nothing names LocaleKitSuite.lua at the calling line",
  function(ctx)
    local probeName = freshAddonName("Unregistered")
    local lineHolder = { start = 0 }
    expectErrorAtNextLine(
      ctx,
      function()
        lineHolder.start = currentLine()
        LocaleKit:GetLocale(probeName)
      end,
      lineHolder,
      "LocaleKit:GetLocale found no locale registered for "
        .. probeName
        .. "; load its translation files first"
    )
  end
)

errors:Test(
  "a later GetLocale naming another missing mode names LocaleKitSuite.lua at the calling line and keeps the first mode",
  function(ctx)
    local probeName = probeWithDefaults("ModeFixed", { "Defined" })
    local strings = LocaleKit:GetLocale(probeName, { missing = "silent" })
    local lineHolder = { start = 0 }
    expectErrorAtNextLine(
      ctx,
      function()
        lineHolder.start = currentLine()
        LocaleKit:GetLocale(probeName, { missing = "report" })
      end,
      lineHolder,
      "LocaleKit:GetLocale " .. probeName .. ' already uses missing mode "silent", not "report"'
    )
    ctx:Expect(LocaleKit:GetLocale(probeName)):ToBe(strings)
    ctx:Expect(strings["Still silent"]):ToBe("Still silent")
  end
)

errors:Test(
  "a Format template needing a missing argument names LocaleKitSuite.lua through the client's string.gsub",
  function(ctx)
    local lineHolder = { start = 0 }
    expectErrorAtNextLine(ctx, function()
      lineHolder.start = currentLine()
      LocaleKit:Format("%s %s %3$s", "a", "b")
    end, lineHolder, "LocaleKit:Format template needs argument 3 but 2 were given")
  end
)

errors:Test(
  "a Format template with an unsupported specifier names LocaleKitSuite.lua through the client's string.gsub",
  function(ctx)
    local lineHolder = { start = 0 }
    expectErrorAtNextLine(ctx, function()
      lineHolder.start = currentLine()
      LocaleKit:Format("%x", 255)
    end, lineHolder, 'LocaleKit:Format template has an unsupported specifier "%x"')
    -- The staged arguments were cleared: the next call formats normally.
    ctx:Expect(LocaleKit:Format("%s", "after")):ToBe("after")
  end
)

-- localeKit.allocation --------------------------------------------------------------------

local allocation = newSuite("allocation")

allocation:Test(
  "reading a defined key 10000 times allocates nothing (allocation guard)",
  function(ctx)
    local probeName = probeWithDefaults("ReadDefined", { "Hello" })
    local strings = LocaleKit:GetLocale(probeName, { missing = "silent" })
    collectBeforeMeasuring(ctx)

    local mismatches = 0
    local grownKilobytes = measureAllocation(function()
      for _ = 1, GUARD_ITERATIONS do
        if strings["Hello"] ~= "Hello" then
          mismatches = mismatches + 1
        end
      end
    end)

    ctx:Log(("memory delta over %d reads: %.3f KB"):format(GUARD_ITERATIONS, grownKilobytes))
    ctx:Expect(mismatches):ToBe(0)
    ctx:Expect(grownKilobytes <= ALLOCATION_TOLERANCE_KB):ToBe(true)
  end
)

allocation:Test(
  "reading a missing key 10000 times after its first read allocates nothing (allocation guard)",
  function(ctx)
    local probeName = probeWithDefaults("ReadMissing", { "Hello" })
    local strings = LocaleKit:GetLocale(probeName, { missing = "silent" })
    local _ = strings["Never translated"]
    collectBeforeMeasuring(ctx)

    local grownKilobytes = measureAllocation(function()
      for _ = 1, GUARD_ITERATIONS do
        _ = strings["Never translated"]
      end
    end)

    ctx:Log(("memory delta over %d reads: %.3f KB"):format(GUARD_ITERATIONS, grownKilobytes))
    ctx:Expect(grownKilobytes <= ALLOCATION_TOLERANCE_KB):ToBe(true)
  end
)

allocation:Test(
  "reading a key past maxMissingKeys 10000 times allocates nothing, though each read runs __index (allocation guard)",
  function(ctx)
    local probeName = probeWithDefaults("ReadPastCap", { "Hello" })
    local strings = LocaleKit:GetLocale(probeName, { missing = "silent", maxMissingKeys = 1 })
    local _ = strings["Recorded"]
    _ = strings["Past the cap"]
    collectBeforeMeasuring(ctx)

    local mismatches = 0
    local grownKilobytes = measureAllocation(function()
      for _ = 1, GUARD_ITERATIONS do
        if strings["Past the cap"] ~= "Past the cap" then
          mismatches = mismatches + 1
        end
      end
    end)

    ctx:Log(("memory delta over %d reads: %.3f KB"):format(GUARD_ITERATIONS, grownKilobytes))
    ctx:Expect(mismatches):ToBe(0)
    ctx:Expect(rawget(strings, "Past the cap")):ToBeNil()
    ctx:Expect(grownKilobytes <= ALLOCATION_TOLERANCE_KB):ToBe(true)
  end
)

allocation:Test(
  "repeating one indexed Format 10000 times allocates no table or closure (allocation guard)",
  function(ctx)
    local template = "%2$s: %1$d / %3$.2f"
    local expected = "Alice: 3 / 1.50"
    ctx:Expect(LocaleKit:Format(template, 3, "Alice", 1.5)):ToBe(expected)
    collectBeforeMeasuring(ctx)

    local mismatches = 0
    local grownKilobytes = measureAllocation(function()
      for _ = 1, GUARD_ITERATIONS do
        if LocaleKit:Format(template, 3, "Alice", 1.5) ~= expected then
          mismatches = mismatches + 1
        end
      end
    end)

    ctx:Log(("memory delta over %d calls: %.3f KB"):format(GUARD_ITERATIONS, grownKilobytes))
    ctx:Expect(mismatches):ToBe(0)
    ctx:Expect(grownKilobytes <= ALLOCATION_TOLERANCE_KB):ToBe(true)
  end
)

-- localeKit.secrets -----------------------------------------------------------------------

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
---A secret is only ever checked with `issecretvalue` and `type`: comparing it
---with a value of its own type raises on the client.
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
  "Format refuses a genuine secret argument at LocaleKitSuite.lua's calling line",
  function(ctx)
    local secretName = makeSecret(ctx, "Alice")
    local lineHolder = { start = 0 }
    expectErrorAtNextLine(ctx, function()
      lineHolder.start = currentLine()
      LocaleKit:Format("%s has %d items", secretName, 3)
    end, lineHolder, "LocaleKit:Format argument 1 must not be a secret value")
    -- The staged arguments were never touched: the next call formats normally.
    ctx:Expect(LocaleKit:Format("%s", "after")):ToBe("after")
  end
)

secretTest(
  "Format refuses a genuine secret template at LocaleKitSuite.lua's calling line before string.gsub sees it",
  function(ctx)
    local secretTemplate = makeSecret(ctx, "%s is here")
    local lineHolder = { start = 0 }
    expectErrorAtNextLine(ctx, function()
      lineHolder.start = currentLine()
      LocaleKit:Format(secretTemplate, "Alice")
    end, lineHolder, "LocaleKit:Format template must not be a secret value")
  end
)

secretTest(
  "GetLocale refuses a genuine secret maxMissingKeys at LocaleKitSuite.lua's calling line and fixes neither the limit nor the mode",
  function(ctx)
    local probeName = probeWithDefaults("SecretLimit", { "Defined" })
    local secretLimit = makeSecret(ctx, 5)
    local lineHolder = { start = 0 }
    expectErrorAtNextLine(
      ctx,
      function()
        lineHolder.start = currentLine()
        LocaleKit:GetLocale(probeName, { missing = "raw", maxMissingKeys = secretLimit })
      end,
      lineHolder,
      "LocaleKit:GetLocale options.maxMissingKeys must be a positive integer or LocaleKit.UNBOUNDED"
    )

    -- The refused call named "raw"; had it fixed that mode, this call
    -- naming "silent" would raise. It fixes the default limit, 1024.
    local strings = LocaleKit:GetLocale(probeName, { missing = "silent" })
    ctx:Expect(strings["Missing"]):ToBe("Missing")
    local refusedLimit, message = pcall(LocaleKit.GetLocale, LocaleKit, probeName, {
      maxMissingKeys = 2,
    })
    ctx:Expect(refusedLimit):ToBe(false)
    local expected = "LocaleKit:GetLocale "
      .. probeName
      .. " already uses options.maxMissingKeys 1024, not 2"
    ctx:Expect(tostring(message):sub(-#expected)):ToBe(expected)
  end
)

--- The client's refusal of a secret key, measured on Retail 12.1.0 b69933. It
--- is raised at the index itself, before the read table's `__index` runs.
local SECRET_KEY_REFUSAL = "attempted to index a table that cannot be indexed with secret keys"

secretTest(
  "a read table indexed with a genuine secret key raises the client's refusal at LocaleKitSuite.lua's calling line, before __index runs, and stores, records and reports nothing",
  function(ctx)
    local probeName = probeWithDefaults("SecretKey", { "Defined" })
    local strings = LocaleKit:GetLocale(probeName)
    local secretKey = makeSecret(ctx, "Some Unit Name")

    local startLine = 0
    local readSucceeded, readProblem = true, nil
    local reported, observed = collectReports(ctx, function()
      readSucceeded, readProblem = pcall(function()
        startLine = currentLine()
        return strings[secretKey]
      end)
    end)
    requireObservedHandler(ctx, observed)
    ctx:Log("client message: " .. tostring(readProblem))

    ctx:Expect(readSucceeded):ToBe(false)
    ctx:Expect(expectThisFile(ctx, readProblem)):ToBe(startLine + 1)
    local refusalAt = string.find(tostring(readProblem), SECRET_KEY_REFUSAL, 1, true)
    ctx:Expect(type(refusalAt)):ToBe("number")
    ctx:Expect(#reported):ToBe(0)
    ctx:Expect(LocaleKit:MissingKeys(probeName)):ToEqual({})
    ctx:Expect(strings["Defined"]):ToBe("Defined")
  end
)

-- localeKit.session ------------------------------------------------------------------------

local session = newSuite("session")

session:Skip(
  "nothing LocaleKit holds survives /reload, and translation files register again",
  "a /reload ends the run; the Busted upgrade and bootstrap specs cover a fresh load"
)

session:Skip(
  "without the client's geterrorhandler a missing-key report is printed",
  "the client always has geterrorhandler, and replacing that global would taint it for Blizzard code"
)

session:Skip(
  "a newer LocaleKit embedded by another addon upgrades read tables, modes, missing keys and the override in place",
  "needs a second LocaleKit copy loaded by another addon; the Busted upgrade specs cover it"
)
