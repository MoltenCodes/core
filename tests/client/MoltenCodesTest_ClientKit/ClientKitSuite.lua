-- MoltenCodes Test: ClientKitSuite.lua
--
-- Real-client suites for the `clientKit` package. ClientKit is almost entirely
-- host probing, and the Busted specs under packages/clientKit/tests/ can only
-- probe a host the fixture invents. These prove, inside the game client with
-- the installed MoltenCodes addon, that every answer ClientKit gives is the
-- answer the running client gives when asked directly:
--
--   * the installed facade and its committed revision;
--   * the flavour against `WOW_PROJECT_ID` and the client's own
--     `WOW_PROJECT_*` constants, and the build facts against `GetBuildInfo()`;
--   * every flag of the capability table against a direct probe of the
--     namespace, global or `UIParent` method it stands for, with the whole
--     table logged;
--   * `IsSecret` with a plain value and with a genuine secret made by the
--     client's `secretwrap`, `CanAccessFrame` on `UIParent`, and
--     `IsEventValid` against `C_EventUtils.IsEventValid`;
--   * the shims against the `C_AddOns`, `C_Spell` and `C_Item` calls they
--     wrap, on this addon's own `.toc`, on Regrowth (spell 8936) and on the
--     Hearthstone (item 6948), waiting through the client's item cache;
--   * `GetManifest` of this addon and of the harness: localised title and
--     notes, version, author, an `X-` field, the dependency list, the fields
--     the client does not export, case-insensitive names, an unknown addon and
--     the read-only snapshot;
--   * that the probes and a cached manifest allocate nothing on the client's
--     own collector;
--   * argument errors, and the refusal of genuine secret values made by
--     `secretwrap`, pointing at this file as the client names it.
--
-- Nothing here needs combat, a group or an instance, and nothing is visible or
-- changed: every call only reads the client. The one wait is for the item
-- cache, at most five seconds.
--
-- Run with `/mct run clientKit`; tests/client/MoltenCodesTest_ClientKit/EXPECTED.md
-- lists what the chat frame should show.
--
-- What a run leaves behind. ClientKit caches a manifest for every addon it is
-- asked about and the client lists, for the session, by design (docs/API.md,
-- "Manifests"): after a run it holds the manifests of this addon and of
-- `MoltenCodesTest`, and nothing for the unknown name the tests ask for. The
-- client may have loaded the Hearthstone into its item cache. Nothing is
-- written to a global, a saved variable, a CVar or the error handler.

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
local CLIENT_KIT_API = 1
local PACKAGE_ID = "clientKit"

--- The folder name of the harness, the one dependency of this addon.
local HARNESS_ADDON = "MoltenCodesTest"

--- An addon folder no client lists.
local UNKNOWN_ADDON = "MoltenCodesTest_NoSuchAddon"

--- The methods docs/API.md lists as the public surface, in its order.
local PUBLIC_METHODS = {
  "GetFlavor",
  "GetBuild",
  "GetInterfaceNumber",
  "IsAtLeast",
  "Has",
  "IsSecret",
  "CanAccessFrame",
  "IsEventValid",
  "GetAddOnMetadata",
  "IsAddOnLoaded",
  "GetSpellInfo",
  "GetItemInfo",
  "GetManifest",
}

--- The capability table of docs/API.md, in its order.
local CAPABILITY_NAMES = {
  "C_AddOns",
  "C_Spell",
  "C_Item",
  "C_Timer",
  "spellbookApi",
  "eventValidity",
  "secretValues",
  "forbiddenFrames",
  "restrictedFrames",
  "secureCall",
  "profilingClock",
  "preciseClock",
}

--- The documented flavour map (docs/API.md, "Flavour"), keyed by the
--- `WOW_PROJECT_*` constant that names each project id on the client.
local FLAVOR_BY_PROJECT_CONSTANT = {
  { constant = "WOW_PROJECT_MAINLINE", projectId = 1, flavor = "mainline" },
  { constant = "WOW_PROJECT_CLASSIC", projectId = 2, flavor = "classic" },
  { constant = "WOW_PROJECT_BURNING_CRUSADE_CLASSIC", projectId = 5, flavor = "tbc" },
  { constant = "WOW_PROJECT_MISTS_CLASSIC", projectId = 19, flavor = "mists" },
}

--- What an unmapped or absent project id answers.
local FALLBACK_FLAVOR = "classic"

--- The `.toc` values of this addon (MoltenCodesTest_ClientKit.toc) the tests
--- read back. Keep them in step with that file.
local TOC_TITLE = "MoltenCodes Test: ClientKit"
local TOC_TITLE_DE = "MoltenCodes Test: ClientKit (deDE)"
local TOC_VERSION = "1.0.0"
local TOC_AUTHOR = "MoltenCodes"
local TOC_PROBE_FIELD = "X-MoltenCodes-Probe"
local TOC_PROBE_VALUE = "yes"

--- An `X-` field this addon's `.toc` does not have.
local ABSENT_FIELD = "X-MoltenCodes-Absent"

--- `.toc` fields docs/API.md says the real clients' metadata call does not
--- export, and the manifest field each one fills.
local UNEXPORTED_FIELDS = {
  { key = "interface", field = "Interface" },
  { key = "category", field = "Category" },
  { key = "loadOnDemand", field = "LoadOnDemand" },
  { key = "defaultState", field = "DefaultState" },
}

--- Shape of a locale code, as ClientKit accepts one.
local LOCALE_CODE_PATTERN = "^%l%l%u%u$"

--- Regrowth: a spell every Retail client knows, whether or not the player can cast it.
local KNOWN_SPELL_ID = 8936

--- A spell ID no client defines.
local UNKNOWN_SPELL_ID = 9999999

--- The Hearthstone: an item every Retail client knows.
local KNOWN_ITEM_ID = 6948

--- How long the item test waits for a cold item cache to fill.
local ITEM_WAIT_SECONDS = 5

--- The item list docs/API.md names, with the Lua type each position must
--- have on Retail 12.x; `optional` allows `nil` too.
local ITEM_FIELDS = {
  { name = "itemName", kind = "string" },
  { name = "itemLink", kind = "string" },
  { name = "itemQuality", kind = "number" },
  { name = "itemLevel", kind = "number" },
  { name = "itemMinLevel", kind = "number" },
  { name = "itemType", kind = "string" },
  { name = "itemSubType", kind = "string" },
  { name = "itemStackCount", kind = "number" },
  { name = "itemEquipLoc", kind = "string" },
  { name = "itemTexture", kind = "number" },
  { name = "sellPrice", kind = "number" },
  { name = "classID", kind = "number" },
  { name = "subclassID", kind = "number" },
  { name = "bindType", kind = "number" },
  { name = "expansionID", kind = "number" },
  { name = "setID", kind = "number", optional = true },
  { name = "isCraftingReagent", kind = "boolean", optional = true },
  { name = "itemDescription", kind = "string", optional = true },
}

--- The six contract fields of `ClientKit.SpellInfo`, with their Lua types.
local SPELL_FIELDS = {
  { name = "name", kind = "string" },
  { name = "iconID", kind = "number" },
  { name = "castTime", kind = "number" },
  { name = "minRange", kind = "number" },
  { name = "maxRange", kind = "number" },
  { name = "spellID", kind = "number" },
}

--- Events whose validity the IsEventValid test compares: two every client
--- has, one Retail replaced in 11.0, and one no client defines.
local PROBED_EVENTS = {
  "PLAYER_LOGIN",
  "PLAYER_TARGET_CHANGED",
  "LEARNED_SPELL_IN_TAB",
  "MCT_CLIENTKIT_NO_SUCH_EVENT",
}

--- How many rounds each allocation guard runs. One table or closure per
--- round would cost well over a hundred kilobytes at this count.
local ALLOCATION_ROUNDS = 5000

--- Kilobytes an allocation guard tolerates. The tolerance absorbs a stray
--- allocation by the client between the two readings, not a per-round one.
local ALLOCATION_TOLERANCE_KB = 1

-- Resolving the client and the framework ---------------------------------------------

---Read a client global, or `nil`.
---@param name string
---@return any
local function readHost(name)
  -- The build facts, the project constants, the C_* namespaces, UIParent
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

-- ClientKit is not in the language-server workspace of tests/client (its
-- .luarc.json lists TestKit's dependency closure only), so its facade and its
-- manifests are typed `any` here.

---@type any
local ClientKit = Registry:Get(PACKAGE_ID, CLIENT_KIT_API)
if type(ClientKit) == "nil" then
  error(addonName .. " requires ClientKit API 1 in the MoltenCodes addon; reinstall it", 0)
end

---@type any
local uiParent = readHost("UIParent")
if type(uiParent) ~= "table" then
  error(addonName .. " requires the client's UIParent", 0)
end

--- Read once at load: the secrets suite registers its tests as skipped when
--- the client cannot make a secret value.
local isSecretValue = readHost("issecretvalue")
local secretWrap = readHost("secretwrap")
local SECRETS_AVAILABLE = type(isSecretValue) == "function" and type(secretWrap) == "function"

-- Asking the client directly -------------------------------------------------------------

---The function `namespaceName.functionName`, read with ordinary indexing, or
---`nil`. This is the direct probe the capability and shim tests compare
---ClientKit with.
---@param namespaceName string
---@param functionName string
---@return function|nil
local function hostFunction(namespaceName, functionName)
  local namespaceTable = readHost(namespaceName)
  if type(namespaceTable) ~= "table" then
    return nil
  end
  local value = namespaceTable[functionName]
  if type(value) ~= "function" then
    return nil
  end
  return value
end

---The global function `name`, or `nil`.
---@param name string
---@return function|nil
local function hostGlobalFunction(name)
  local value = readHost(name)
  if type(value) ~= "function" then
    return nil
  end
  return value
end

---The client's `.toc` metadata call, preferring `C_AddOns` as ClientKit does.
---@return function|nil
local function hostMetadataCall()
  return hostFunction("C_AddOns", "GetAddOnMetadata") or hostGlobalFunction("GetAddOnMetadata")
end

---One `.toc` field as the client reads it, normalised as the manifest
---normalises it: `nil` when absent, empty, not exported (the call raised) or
---when the client has no metadata call.
---@param addon string
---@param field string
---@return string|nil
local function hostTocField(addon, field)
  local getAddOnMetadata = hostMetadataCall()
  if type(getAddOnMetadata) == "nil" then
    return nil
  end
  local succeeded, value = pcall(getAddOnMetadata, addon, field)
  if not succeeded or type(value) ~= "string" or value == "" then
    return nil
  end
  return value
end

---The client locale when it is a locale code, else `nil`.
---@return string|nil
local function clientLocale()
  local getLocale = hostGlobalFunction("GetLocale")
  local locale = getLocale and getLocale() or nil
  if type(locale) ~= "string" or type(locale:match(LOCALE_CODE_PATTERN)) == "nil" then
    return nil
  end
  return locale
end

---A localised `.toc` field as the documented fallback reads it: the
---`<field>-<locale>` spelling first, then the plain one.
---@param addon string
---@param field string `"Title"` or `"Notes"`
---@return string|nil value
---@return string source which spelling answered, for the log
local function hostLocalisedField(addon, field)
  local locale = clientLocale()
  if type(locale) ~= "nil" then
    local localised = hostTocField(addon, field .. "-" .. locale)
    if type(localised) ~= "nil" then
      return localised, field .. "-" .. locale
    end
  end
  return hostTocField(addon, field), field
end

---Describe a value for a log line without comparing or formatting a secret.
---@param value any
---@return string
local function describe(value)
  if SECRETS_AVAILABLE and isSecretValue(value) then
    return "<secret value>"
  end
  if type(value) == "string" then
    return string.format("%q", value)
  end
  return tostring(value)
end

---Whether `value` is a secret, on a client that has secret values.
---@param value any
---@return boolean
local function isSecret(value)
  return SECRETS_AVAILABLE and isSecretValue(value) == true
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
---function: level 1 is `pcall` itself, 2 is this function, 3 its caller.
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
  ctx:Expect((file or ""):sub(-#"ClientKitSuite.lua")):ToBe("ClientKitSuite.lua")
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
  ctx:Log("client message: " .. tostring(message))

  local line = expectThisFile(ctx, message)
  ctx:Expect(tostring(message):sub(-#expected)):ToBe(expected)
  ctx:Expect(line):ToBe(lineBox.start + 1)
end

---Strip a leading `file:line: ` position from an error message, so a host
---error raised through a shim and the same error raised directly compare
---equal whoever called.
---@param message any
---@return string
local function withoutPosition(message)
  local text = tostring(message)
  local _, positionEnd = text:find("^.-:%d+: ")
  if type(positionEnd) == "nil" then
    return text
  end
  return text:sub(positionEnd + 1)
end

-- Measuring -------------------------------------------------------------------------------

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

-- Suites ---------------------------------------------------------------------------------------

---Register a suite of this package. ClientKit owns nothing that needs
---releasing and no test changes the client, so the suites have no hooks.
---@param part string
---@return TestKit.Suite
local function newSuite(part)
  return Harness:Suite(PACKAGE_ID, part, addonName)
end

-- clientKit.facade ----------------------------------------------------------------------------

local facade = newSuite("facade")

facade:Test(
  "Registry:Get('clientKit', 1) is the ClientKit facade with API 1 and the thirteen documented methods",
  function(ctx)
    ctx:Expect(type(ClientKit)):ToBe("table")
    ctx:Expect(rawget(ClientKit, "API")):ToBe(CLIENT_KIT_API)
    ctx:Expect(type(rawget(ClientKit, "REVISION"))):ToBe("number")
    local missing = {}
    for _, methodName in ipairs(PUBLIC_METHODS) do
      if type(rawget(ClientKit, methodName)) ~= "function" then
        missing[#missing + 1] = methodName
      end
    end
    ctx:Expect(missing):ToEqual({})
  end
)

facade:Test("the installed ClientKit carries the revision of the committed manifest", function(ctx)
  local expectedPackages = Harness:GetExpectedPackages()
  if type(expectedPackages) == "nil" then
    ctx:Fail("Expected.lua is missing; install with python3 -m tooling.client.install")
    return
  end
  for _, expected in ipairs(expectedPackages) do
    if expected.id == PACKAGE_ID then
      local _, revision = Registry:Get(PACKAGE_ID, CLIENT_KIT_API)
      ctx:Expect(revision):ToBe(expected.revision)
      ctx:Expect(rawget(ClientKit, "REVISION")):ToBe(expected.revision)
      return
    end
  end
  ctx:Fail("Expected.lua does not list clientKit")
end)

-- clientKit.identity --------------------------------------------------------------------------

local identity = newSuite("identity")

identity:Test(
  "GetFlavor maps the client's WOW_PROJECT_ID by the documented table, mainline for Retail's 1",
  function(ctx)
    local projectId = readHost("WOW_PROJECT_ID")
    ctx:Log("WOW_PROJECT_ID is " .. describe(projectId))
    ctx:Log("GetFlavor() is " .. describe(ClientKit:GetFlavor()))

    local expected = FALLBACK_FLAVOR
    if type(projectId) == "number" then
      for _, row in ipairs(FLAVOR_BY_PROJECT_CONSTANT) do
        if row.projectId == projectId then
          expected = row.flavor
        end
      end
    end
    ctx:Expect(ClientKit:GetFlavor()):ToBe(expected)
    if projectId == 1 then
      ctx:Expect(ClientKit:GetFlavor()):ToBe("mainline")
    end
  end
)

identity:Test(
  "every WOW_PROJECT_* constant the client defines has the number ClientKit's literal flavour map uses",
  function(ctx)
    local mismatched = {}
    for _, row in ipairs(FLAVOR_BY_PROJECT_CONSTANT) do
      local value = readHost(row.constant)
      ctx:Log(
        row.constant .. " is " .. describe(value) .. " (the map uses " .. row.projectId .. ")"
      )
      if type(value) ~= "nil" and value ~= row.projectId then
        mismatched[#mismatched + 1] = row.constant
      end
    end
    ctx:Expect(mismatched):ToEqual({})
  end
)

identity:Test(
  "GetBuild returns GetBuildInfo's version and build date, and its build string as an integer",
  function(ctx)
    local getBuildInfo = hostGlobalFunction("GetBuildInfo")
    if type(getBuildInfo) == "nil" then
      ctx:Fail("the client has no GetBuildInfo")
      return
    end
    local hostVersion, hostBuild, hostBuildDate, hostInterface = getBuildInfo()
    ctx:Log(
      ("GetBuildInfo() is %s, %s, %s, %s"):format(
        describe(hostVersion),
        describe(hostBuild),
        describe(hostBuildDate),
        describe(hostInterface)
      )
    )

    local version, build, buildDate = ClientKit:GetBuild()
    ctx:Log(
      ("GetBuild() is %s, %s, %s"):format(describe(version), describe(build), describe(buildDate))
    )
    ctx:Expect(version):ToBe(hostVersion)
    ctx:Expect(buildDate):ToBe(hostBuildDate)
    ctx:Expect(type(build)):ToBe("number")
    ctx:Expect(build):ToBe(tonumber(hostBuild))
    ctx:Expect(build == math.floor(build or 0)):ToBe(true)
  end
)

identity:Test("GetInterfaceNumber is the fourth value of GetBuildInfo", function(ctx)
  local getBuildInfo = hostGlobalFunction("GetBuildInfo")
  if type(getBuildInfo) == "nil" then
    ctx:Fail("the client has no GetBuildInfo")
    return
  end
  local _, _, _, hostInterface = getBuildInfo()
  ctx:Log("GetInterfaceNumber() is " .. describe(ClientKit:GetInterfaceNumber()))
  ctx:Expect(type(hostInterface)):ToBe("number")
  ctx:Expect(ClientKit:GetInterfaceNumber()):ToBe(hostInterface)
end)

identity:Test(
  "IsAtLeast is true at and below the client's interface number and false one above it",
  function(ctx)
    local interfaceNumber = ClientKit:GetInterfaceNumber()
    ctx:Expect(interfaceNumber > 0):ToBe(true)
    ctx:Expect(ClientKit:IsAtLeast(interfaceNumber)):ToBe(true)
    ctx:Expect(ClientKit:IsAtLeast(interfaceNumber - 1)):ToBe(true)
    ctx:Expect(ClientKit:IsAtLeast(0)):ToBe(true)
    ctx:Expect(ClientKit:IsAtLeast(interfaceNumber + 1)):ToBe(false)
    ctx:Expect(ClientKit:IsAtLeast(math.huge)):ToBe(false)
  end
)

-- clientKit.capabilities ----------------------------------------------------------------------

local capabilities = newSuite("capabilities")

---What a direct probe of the client answers for each capability, following
---the definitions in docs/API.md ("Capabilities").
---@type table<string, fun(): boolean>
local DIRECT_PROBES = {
  C_AddOns = function()
    return type(readHost("C_AddOns")) == "table"
  end,
  C_Spell = function()
    return type(readHost("C_Spell")) == "table"
  end,
  C_Item = function()
    return type(readHost("C_Item")) == "table"
  end,
  C_Timer = function()
    return type(readHost("C_Timer")) == "table"
  end,
  spellbookApi = function()
    return type(hostFunction("C_SpellBook", "GetSpellBookItemInfo")) == "function"
  end,
  eventValidity = function()
    return type(hostFunction("C_EventUtils", "IsEventValid")) == "function"
  end,
  secretValues = function()
    return type(hostGlobalFunction("issecretvalue")) == "function"
  end,
  forbiddenFrames = function()
    return type(uiParent.IsForbidden) == "function"
  end,
  restrictedFrames = function()
    return type(uiParent.CanBeAccessedInContext) == "function"
  end,
  secureCall = function()
    return type(hostGlobalFunction("securecallfunction")) == "function"
  end,
  profilingClock = function()
    return type(hostGlobalFunction("debugprofilestop")) == "function"
  end,
  preciseClock = function()
    return type(hostGlobalFunction("GetTimePreciseSec")) == "function"
  end,
}

capabilities:Test(
  "Has answers each of the twelve documented capabilities exactly as a direct probe of the client does",
  function(ctx)
    local disagreements = {}
    for _, capability in ipairs(CAPABILITY_NAMES) do
      local answer = ClientKit:Has(capability)
      local direct = DIRECT_PROBES[capability]()
      ctx:Log(
        ("%s: ClientKit %s, client %s"):format(capability, tostring(answer), tostring(direct))
      )
      if answer ~= direct then
        disagreements[#disagreements + 1] = capability
      end
    end
    ctx:Expect(disagreements):ToEqual({})
  end
)

-- clientKit.taint -----------------------------------------------------------------------------

local taint = newSuite("taint")

taint:Test(
  "IsSecret answers false for a plain string, a number, nil, a table and UIParent",
  function(ctx)
    ctx:Expect(ClientKit:IsSecret("plain")):ToBe(false)
    ctx:Expect(ClientKit:IsSecret(42)):ToBe(false)
    ctx:Expect(ClientKit:IsSecret(nil)):ToBe(false)
    ctx:Expect(ClientKit:IsSecret({})):ToBe(false)
    ctx:Expect(ClientKit:IsSecret(uiParent)):ToBe(false)
  end
)

taint:Test(
  "CanAccessFrame(UIParent) is true and agrees with UIParent's own IsForbidden and CanBeAccessedInContext",
  function(ctx)
    local forbidden = nil
    if type(uiParent.IsForbidden) == "function" then
      forbidden = uiParent:IsForbidden()
    end
    ctx:Log("UIParent:IsForbidden() is " .. describe(forbidden))

    -- ClientKit calls CanBeAccessedInContext with no argument, as
    -- docs/API.md describes it. The direct call is protected so that a
    -- client wanting an argument is reported as that, not as a crash.
    local accessible = nil
    if type(uiParent.CanBeAccessedInContext) == "function" then
      local succeeded, answer = pcall(uiParent.CanBeAccessedInContext, uiParent)
      if not succeeded then
        ctx:Fail(
          "UIParent:CanBeAccessedInContext() raised without an argument, as ClientKit calls it: "
            .. tostring(answer)
        )
        return
      end
      accessible = answer
    end
    ctx:Log("UIParent:CanBeAccessedInContext() is " .. describe(accessible))

    local expected = not forbidden and accessible ~= false
    ctx:Expect(ClientKit:CanAccessFrame(uiParent)):ToBe(expected)
    ctx:Expect(ClientKit:CanAccessFrame(uiParent)):ToBe(true)
  end
)

taint:Skip(
  "CanAccessFrame answers false for a forbidden frame",
  "docs/API.md names no forbidden frame an addon can reach out of combat; UIParent's answers are logged by the test above"
)

taint:Test(
  "IsEventValid agrees with C_EventUtils.IsEventValid for known, replaced and made-up events, as booleans",
  function(ctx)
    local isEventValid = hostFunction("C_EventUtils", "IsEventValid")
    local disagreements = {}
    for _, eventName in ipairs(PROBED_EVENTS) do
      local answer = ClientKit:IsEventValid(eventName)
      local direct = nil
      if type(isEventValid) ~= "nil" then
        direct = isEventValid(eventName) and true or false
      end
      ctx:Log(("%s: ClientKit %s, client %s"):format(eventName, describe(answer), describe(direct)))
      if answer ~= direct then
        disagreements[#disagreements + 1] = eventName
      end
    end
    ctx:Expect(disagreements):ToEqual({})
    if type(isEventValid) ~= "nil" then
      ctx:Expect(ClientKit:IsEventValid("PLAYER_LOGIN")):ToBe(true)
      ctx:Expect(ClientKit:IsEventValid("MCT_CLIENTKIT_NO_SUCH_EVENT")):ToBe(false)
    end
  end
)

-- clientKit.shims -----------------------------------------------------------------------------

local shims = newSuite("shims")

shims:Test(
  "GetAddOnMetadata reads this addon's Version, Author, Notes and X-MoltenCodes-Probe exactly as the client's metadata call does",
  function(ctx)
    local getAddOnMetadata = hostMetadataCall()
    if type(getAddOnMetadata) == "nil" then
      ctx:Fail("the client has no GetAddOnMetadata")
      return
    end
    for _, field in ipairs({ "Version", "Author", "Notes", "Title", TOC_PROBE_FIELD }) do
      local answer = ClientKit:GetAddOnMetadata(addonName, field)
      ctx:Log(field .. ": " .. describe(answer))
      ctx:Expect(answer):ToBe(getAddOnMetadata(addonName, field))
    end
    ctx:Expect(ClientKit:GetAddOnMetadata(addonName, "Version")):ToBe(TOC_VERSION)
    ctx:Expect(ClientKit:GetAddOnMetadata(addonName, "Author")):ToBe(TOC_AUTHOR)
    ctx:Expect(ClientKit:GetAddOnMetadata(addonName, TOC_PROBE_FIELD)):ToBe(TOC_PROBE_VALUE)
  end
)

shims:Test(
  "GetAddOnMetadata answers nil for an X- field this addon's .toc does not have",
  function(ctx)
    local getAddOnMetadata = hostMetadataCall()
    if type(getAddOnMetadata) == "nil" then
      ctx:Fail("the client has no GetAddOnMetadata")
      return
    end
    ctx:Log("the client answers " .. describe(getAddOnMetadata(addonName, ABSENT_FIELD)))
    ctx:Expect(ClientKit:GetAddOnMetadata(addonName, ABSENT_FIELD)):ToBeNil()
  end
)

shims:Test(
  "GetAddOnMetadata of a field the client does not export answers or raises exactly as the client's call does",
  function(ctx)
    local getAddOnMetadata = hostMetadataCall()
    if type(getAddOnMetadata) == "nil" then
      ctx:Fail("the client has no GetAddOnMetadata")
      return
    end
    for _, row in ipairs(UNEXPORTED_FIELDS) do
      local hostSucceeded, hostAnswer = pcall(getAddOnMetadata, addonName, row.field)
      local shimSucceeded, shimAnswer =
        pcall(ClientKit.GetAddOnMetadata, ClientKit, addonName, row.field)
      ctx:Log(
        ("%s: client %s %s; shim %s %s"):format(
          row.field,
          hostSucceeded and "answered" or "raised",
          describe(hostAnswer),
          shimSucceeded and "answered" or "raised",
          describe(shimAnswer)
        )
      )
      ctx:Expect(shimSucceeded):ToBe(hostSucceeded)
      if hostSucceeded then
        if hostAnswer == "" then
          hostAnswer = nil
        end
        ctx:Expect(shimAnswer):ToBe(hostAnswer)
      else
        ctx:Expect(withoutPosition(shimAnswer)):ToBe(withoutPosition(hostAnswer))
      end
    end
  end
)

shims:Test(
  "IsAddOnLoaded answers true, true for this addon and the harness, and false, false for an addon that is not installed",
  function(ctx)
    local loaded, finished = ClientKit:IsAddOnLoaded(addonName)
    ctx:Expect(loaded):ToBe(true)
    ctx:Expect(finished):ToBe(true)
    loaded, finished = ClientKit:IsAddOnLoaded(HARNESS_ADDON)
    ctx:Expect(loaded):ToBe(true)
    ctx:Expect(finished):ToBe(true)
    loaded, finished = ClientKit:IsAddOnLoaded(UNKNOWN_ADDON)
    ctx:Expect(loaded):ToBe(false)
    ctx:Expect(finished):ToBe(false)

    local isAddOnLoaded = hostFunction("C_AddOns", "IsAddOnLoaded")
      or hostGlobalFunction("IsAddOnLoaded")
    if type(isAddOnLoaded) ~= "nil" then
      local hostLoaded, hostFinished = isAddOnLoaded(UNKNOWN_ADDON)
      ctx:Log(
        "the client answers "
          .. describe(hostLoaded)
          .. ", "
          .. describe(hostFinished)
          .. " for an addon that is not installed"
      )
    end
  end
)

---The spell-info call ClientKit binds: `C_Spell.GetSpellInfo`, else `nil`.
---@return function|nil
local function hostSpellTableCall()
  return hostFunction("C_Spell", "GetSpellInfo")
end

shims:Test(
  "GetSpellInfo(8936) returns a fresh table with the six documented fields, holding what the client's own call gives",
  function(ctx)
    local info = ClientKit:GetSpellInfo(KNOWN_SPELL_ID)
    ctx:Expect(type(info)):ToBe("table")
    if type(info) ~= "table" then
      return
    end
    for _, field in ipairs(SPELL_FIELDS) do
      ctx:Log(field.name .. ": " .. describe(info[field.name]))
    end
    for _, field in ipairs(SPELL_FIELDS) do
      if isSecret(info[field.name]) then
        Harness:SkipTest(
          ctx,
          "spell field "
            .. field.name
            .. " was a secret value (restrictions applied); run out of combat"
        )
      end
    end

    for _, field in ipairs(SPELL_FIELDS) do
      ctx:Expect(type(info[field.name])):ToBe(field.kind)
    end
    ctx:Expect(info.spellID):ToBe(KNOWN_SPELL_ID)
    ctx:Expect(info.castTime == math.floor(info.castTime)):ToBe(true)
    ctx:Expect(info.castTime >= 0):ToBe(true)
    ctx:Expect(info.minRange <= info.maxRange):ToBe(true)

    local second = ClientKit:GetSpellInfo(KNOWN_SPELL_ID)
    ctx:Expect(rawequal(info, second)):ToBe(false)

    local getSpellInfo = hostSpellTableCall()
    if type(getSpellInfo) ~= "nil" then
      local direct = getSpellInfo(KNOWN_SPELL_ID)
      ctx:Expect(rawequal(info, direct)):ToBe(false)
      for _, field in ipairs(SPELL_FIELDS) do
        ctx:Expect(info[field.name]):ToBe(direct[field.name])
      end
      local extra = {}
      for key in pairs(direct) do
        extra[#extra + 1] = tostring(key)
      end
      table.sort(extra)
      ctx:Log("C_Spell.GetSpellInfo fields: " .. table.concat(extra, ", "))
    end
  end
)

shims:Test(
  "GetSpellInfo answers nil for a spell ID the client does not know, as the client's own call does",
  function(ctx)
    local getSpellInfo = hostSpellTableCall()
    if type(getSpellInfo) ~= "nil" then
      ctx:Expect(getSpellInfo(UNKNOWN_SPELL_ID)):ToBeNil()
    end
    ctx:Expect(ClientKit:GetSpellInfo(UNKNOWN_SPELL_ID)):ToBeNil()
  end
)

---The item-info call ClientKit binds: `C_Item.GetItemInfo`, else the global.
---@return function|nil
local function hostItemCall()
  return hostFunction("C_Item", "GetItemInfo") or hostGlobalFunction("GetItemInfo")
end

---Pack a call's returns with their count.
---@param ... any
---@return { n: integer, [integer]: any }
local function pack(...)
  ---@type { n: integer, [integer]: any }
  local packed = { ... }
  packed.n = select("#", ...)
  return packed
end

shims:Test(
  "GetItemInfo(6948) returns the Hearthstone as the documented list the client's call gives, after the item cache fills when cold",
  function(ctx)
    local getItemInfo = hostItemCall()
    if type(getItemInfo) == "nil" then
      ctx:Fail("the client has neither C_Item.GetItemInfo nor GetItemInfo")
      return
    end

    local firstName = ClientKit:GetItemInfo(KNOWN_ITEM_ID)
    if type(firstName) == "nil" then
      ctx:Log("the Hearthstone was not in the item cache; waiting for the client to fill it")
      local ready = ctx:WaitUntil(function()
        return type((ClientKit:GetItemInfo(KNOWN_ITEM_ID))) ~= "nil"
      end, ITEM_WAIT_SECONDS)
      if not ready then
        ctx:Fail("the client did not fill the item cache for 6948 within five seconds")
        return
      end
    else
      ctx:Log("the Hearthstone was already in the item cache")
    end

    local values = pack(ClientKit:GetItemInfo(KNOWN_ITEM_ID))
    local direct = pack(getItemInfo(KNOWN_ITEM_ID))
    ctx:Log(("ClientKit returned %d values, the client's call %d"):format(values.n, direct.n))
    for index, field in ipairs(ITEM_FIELDS) do
      ctx:Log(("%d %s: %s"):format(index, field.name, describe(values[index])))
    end

    ctx:Expect(values.n):ToBe(direct.n)
    for index, field in ipairs(ITEM_FIELDS) do
      local value = values[index]
      ctx:Expect(value):ToBe(direct[index])
      if not (field.optional and type(value) == "nil") then
        ctx:Expect(type(value)):ToBe(field.kind)
      end
    end
    ctx:Expect((values[2] or ""):find("item:6948", 1, true) ~= nil):ToBe(true)
    if clientLocale() == "enUS" then
      ctx:Expect(values[1]):ToBe("Hearthstone")
    end
  end
)

-- clientKit.manifest --------------------------------------------------------------------------

local manifest = newSuite("manifest")

manifest:Test(
  "GetManifest of this addon has the title, notes, version and author the client reads, localised title and notes first",
  function(ctx)
    local snapshot, reason = ClientKit:GetManifest(addonName)
    ctx:Expect(reason):ToBeNil()
    ctx:Expect(type(snapshot)):ToBe("table")
    if type(snapshot) ~= "table" then
      return
    end

    local expectedTitle, titleSource = hostLocalisedField(addonName, "Title")
    local expectedNotes, notesSource = hostLocalisedField(addonName, "Notes")
    ctx:Log("client locale: " .. describe(clientLocale()))
    ctx:Log("title " .. describe(snapshot.title) .. " (the client answered " .. titleSource .. ")")
    ctx:Log("notes " .. describe(snapshot.notes) .. " (the client answered " .. notesSource .. ")")
    ctx:Log("Notes-enUS reads " .. describe(hostTocField(addonName, "Notes-enUS")))
    ctx:Log("Title-deDE reads " .. describe(hostTocField(addonName, "Title-deDE")))

    ctx:Expect(snapshot.name):ToBe(addonName)
    ctx:Expect(snapshot.title):ToBe(expectedTitle)
    ctx:Expect(snapshot.notes):ToBe(expectedNotes)
    ctx:Expect(snapshot.version):ToBe(TOC_VERSION)
    ctx:Expect(snapshot.author):ToBe(TOC_AUTHOR)
    if clientLocale() == "deDE" then
      ctx:Expect(snapshot.title):ToBe(TOC_TITLE_DE)
    else
      ctx:Expect(snapshot.title):ToBe(TOC_TITLE)
    end
    ctx:Expect(snapshot:Get("Title")):ToBe(hostTocField(addonName, "Title"))
  end
)

manifest:Test(
  "manifest:Get reads X-MoltenCodes-Probe as yes and answers nil for an X- field the .toc lacks",
  function(ctx)
    local snapshot = ClientKit:GetManifest(addonName)
    ctx:Expect(type(snapshot)):ToBe("table")
    if type(snapshot) ~= "table" then
      return
    end
    ctx:Expect(snapshot:Get(TOC_PROBE_FIELD)):ToBe(TOC_PROBE_VALUE)
    ctx:Expect(snapshot:Get(TOC_PROBE_FIELD)):ToBe(TOC_PROBE_VALUE)
    ctx:Expect(snapshot:Get("X-License")):ToBe("MIT")
    ctx:Expect(snapshot:Get(ABSENT_FIELD)):ToBeNil()
    ctx:Expect(snapshot:Get("Version")):ToBe(TOC_VERSION)
  end
)

manifest:Test(
  "the manifest's dependencies array lists MoltenCodesTest, the harness this addon depends on",
  function(ctx)
    local snapshot = ClientKit:GetManifest(addonName)
    ctx:Expect(type(snapshot)):ToBe("table")
    if type(snapshot) ~= "table" then
      return
    end
    ctx:Log("dependencies: " .. table.concat(snapshot.dependencies, ", "))
    ctx:Log("optionalDependencies: " .. table.concat(snapshot.optionalDependencies, ", "))
    ctx:Log("raw Dependencies field: " .. describe(snapshot:Get("Dependencies")))
    local listed = false
    for _, name in ipairs(snapshot.dependencies) do
      if name == HARNESS_ADDON then
        listed = true
      end
    end
    ctx:Expect(listed):ToBe(true)
    ctx:Expect(type(snapshot.optionalDependencies)):ToBe("table")
    ctx:Expect(type(snapshot.savedVariables)):ToBe("table")
    ctx:Expect(type(snapshot.savedVariablesPerCharacter)):ToBe("table")
  end
)

manifest:Test(
  "manifest fields the client's metadata call does not export read as the client answers them, without raising",
  function(ctx)
    local snapshot = ClientKit:GetManifest(addonName)
    ctx:Expect(type(snapshot)):ToBe("table")
    if type(snapshot) ~= "table" then
      return
    end
    for _, row in ipairs(UNEXPORTED_FIELDS) do
      ctx:Log(row.key .. ": " .. describe(snapshot[row.key]))
      ctx:Expect(snapshot[row.key]):ToBe(hostTocField(addonName, row.field))
    end
  end
)

manifest:Test(
  "GetManifest answers the same table for every spelling of this addon's name, carrying the client's spelling",
  function(ctx)
    local snapshot = ClientKit:GetManifest(addonName)
    ctx:Expect(type(snapshot)):ToBe("table")
    ctx:Expect(ClientKit:GetManifest(addonName)):ToBe(snapshot)
    ctx:Expect(ClientKit:GetManifest(string.lower(addonName))):ToBe(snapshot)
    ctx:Expect(ClientKit:GetManifest(string.upper(addonName))):ToBe(snapshot)
    ctx:Expect(snapshot.name):ToBe(addonName)
  end
)

manifest:Test(
  "GetManifest of an addon the client does not list answers nil and unknown, every time",
  function(ctx)
    local first, firstReason = ClientKit:GetManifest(UNKNOWN_ADDON)
    local second, secondReason = ClientKit:GetManifest(UNKNOWN_ADDON)
    ctx:Expect(first):ToBeNil()
    ctx:Expect(firstReason):ToBe("unknown")
    ctx:Expect(second):ToBeNil()
    ctx:Expect(secondReason):ToBe("unknown")
  end
)

manifest:Test(
  "writing a manifest field is refused at the calling line, and the manifest has no raw keys and no metatable",
  function(ctx)
    local snapshot = ClientKit:GetManifest(addonName)
    ctx:Expect(type(snapshot)):ToBe("table")
    if type(snapshot) ~= "table" then
      return
    end
    local lines = { start = 0 }
    expectErrorAtCallingLine(
      ctx,
      function()
        lines.start = currentLine()
        snapshot.version = "2.0.0"
      end,
      lines,
      ('ClientKit manifest for "%s" is read-only; field "version" cannot be written'):format(
        addonName
      )
    )
    ctx:Expect(snapshot.version):ToBe(TOC_VERSION)
    ctx:Expect(rawget(snapshot, "version")):ToBeNil()
    ctx:Expect(getmetatable(snapshot)):ToBe(false)
  end
)

manifest:Test(
  "the harness's manifest reads its title through the same path and lists its saved variables as the client exports them",
  function(ctx)
    local snapshot = ClientKit:GetManifest(HARNESS_ADDON)
    ctx:Expect(type(snapshot)):ToBe("table")
    if type(snapshot) ~= "table" then
      return
    end
    local expectedTitle = hostLocalisedField(HARNESS_ADDON, "Title")
    ctx:Log("title: " .. describe(snapshot.title))
    ctx:Log("savedVariables: {" .. table.concat(snapshot.savedVariables, ", ") .. "}")
    ctx:Log("raw SavedVariables field: " .. describe(snapshot:Get("SavedVariables")))
    ctx:Expect(snapshot.title):ToBe(expectedTitle)
    ctx:Expect(snapshot.name):ToBe(HARNESS_ADDON)
    ctx:Expect(type(snapshot.savedVariables)):ToBe("table")
  end
)

-- clientKit.allocation ------------------------------------------------------------------------

local allocation = newSuite("allocation")

---One round of every identity, capability and taint probe, and the
---IsAddOnLoaded shim, which docs/API.md says are table reads plus one host
---call each.
local function probeEverything()
  ClientKit:GetFlavor()
  ClientKit:GetBuild()
  ClientKit:IsAtLeast(ClientKit:GetInterfaceNumber())
  for index = 1, #CAPABILITY_NAMES do
    ClientKit:Has(CAPABILITY_NAMES[index])
  end
  ClientKit:IsSecret(addonName)
  ClientKit:CanAccessFrame(uiParent)
  ClientKit:IsEventValid("PLAYER_LOGIN")
  ClientKit:IsAddOnLoaded(addonName)
end

allocation:Test(
  "5000 rounds of every identity, capability and taint probe and IsAddOnLoaded allocate nothing",
  function(ctx)
    probeEverything()
    collectBeforeMeasuring(ctx)

    local grownKilobytes = measureAllocation(function()
      for _ = 1, ALLOCATION_ROUNDS do
        probeEverything()
      end
    end)

    ctx:Log(("memory delta over %d rounds: %.3f KB"):format(ALLOCATION_ROUNDS, grownKilobytes))
    ctx:Expect(grownKilobytes <= ALLOCATION_TOLERANCE_KB):ToBe(true)
  end
)

allocation:Test(
  "5000 rounds of a cached GetManifest in two spellings and remembered Get reads allocate nothing",
  function(ctx)
    local upperName = string.upper(addonName)
    local snapshot = ClientKit:GetManifest(addonName)
    ctx:Expect(type(snapshot)):ToBe("table")
    if type(snapshot) ~= "table" then
      return
    end
    -- Read each field once, so it is remembered before the measurement.
    snapshot:Get(TOC_PROBE_FIELD)
    snapshot:Get("Version")
    ClientKit:GetManifest(upperName)
    collectBeforeMeasuring(ctx)

    local grownKilobytes = measureAllocation(function()
      for _ = 1, ALLOCATION_ROUNDS do
        local cached = ClientKit:GetManifest(addonName)
        ClientKit:GetManifest(upperName)
        cached:Get(TOC_PROBE_FIELD)
        cached:Get("Version")
        local _ = cached.title
      end
    end)

    ctx:Log(("memory delta over %d rounds: %.3f KB"):format(ALLOCATION_ROUNDS, grownKilobytes))
    ctx:Expect(grownKilobytes <= ALLOCATION_TOLERANCE_KB):ToBe(true)
  end
)

-- clientKit.errors ----------------------------------------------------------------------------

local errors = newSuite("errors")

errors:Test(
  "IsAtLeast with a string or NaN names ClientKitSuite.lua at the calling line",
  function(ctx)
    -- The wrong argument types are the point of the test.
    ---@type any
    local notNumber = "120100"
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      ClientKit:IsAtLeast(notNumber)
    end, lines, "ClientKit:IsAtLeast interfaceNumber must be a number")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      ClientKit:IsAtLeast(0 / 0)
    end, lines, "ClientKit:IsAtLeast interfaceNumber must be a number")
  end
)

errors:Test(
  "Has of an unknown capability raises at the calling line, naming it, instead of answering false",
  function(ctx)
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      ClientKit:Has("C_Foo")
    end, lines, 'ClientKit:Has does not know capability "C_Foo"')
  end
)

errors:Test("Has with a number names ClientKitSuite.lua at the calling line", function(ctx)
  local lines = { start = 0 }
  expectErrorAtCallingLine(ctx, function()
    lines.start = currentLine()
    ClientKit:Has(42)
  end, lines, "ClientKit:Has capability must be a string")
end)

errors:Test(
  "CanAccessFrame with a frame's name instead of the frame names ClientKitSuite.lua at the calling line",
  function(ctx)
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      ClientKit:CanAccessFrame("UIParent")
    end, lines, "ClientKit:CanAccessFrame frame must be a frame table")
  end
)

errors:Test("IsEventValid with nil names ClientKitSuite.lua at the calling line", function(ctx)
  local lines = { start = 0 }
  expectErrorAtCallingLine(ctx, function()
    lines.start = currentLine()
    ClientKit:IsEventValid(nil)
  end, lines, "ClientKit:IsEventValid eventName must be a string")
end)

errors:Test(
  "the four shims refuse an argument of the wrong type at the calling line before asking the client",
  function(ctx)
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      ClientKit:GetAddOnMetadata(true, "Version")
    end, lines, "ClientKit:GetAddOnMetadata addon must be an addon name or index")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      ClientKit:GetAddOnMetadata(addonName, 1)
    end, lines, "ClientKit:GetAddOnMetadata field must be a string")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      ClientKit:IsAddOnLoaded({})
    end, lines, "ClientKit:IsAddOnLoaded addon must be an addon name or index")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      ClientKit:GetSpellInfo(nil)
    end, lines, "ClientKit:GetSpellInfo spell must be a spell ID or a spell name")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      ClientKit:GetItemInfo(false)
    end, lines, "ClientKit:GetItemInfo item must be an item ID, name or link")
  end
)

errors:Test(
  "GetManifest with an addon index names ClientKitSuite.lua at the calling line",
  function(ctx)
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      ClientKit:GetManifest(1)
    end, lines, "ClientKit:GetManifest addonName must be a string")
  end
)

errors:Test(
  "manifest:Get refuses a number field, and a forged table carrying the manifest's name, at the calling line",
  function(ctx)
    local snapshot = ClientKit:GetManifest(addonName)
    ctx:Expect(type(snapshot)):ToBe("table")
    if type(snapshot) ~= "table" then
      return
    end
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      snapshot:Get(7)
    end, lines, "ClientKit.Manifest:Get field must be a string")
    local forged = { name = addonName }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      snapshot.Get(forged, "Version")
    end, lines, "ClientKit.Manifest:Get must be called on a manifest")
  end
)

-- clientKit.secrets ---------------------------------------------------------------------------

local secrets = newSuite("secrets")

--- Why the secrets tests are skipped on a client without the two functions.
local SECRETS_SKIP_REASON =
  "the client has no issecretvalue and secretwrap; the secret path was not exercised"

---Register `body` as a test when the client can make a secret value, and as a
---skipped test otherwise.
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
---(`FrameScriptDocumentation`) with no restriction; it only converts the
---values handed to it.
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
  -- ClientKit checks the type before the secrecy, so a secret string must
  -- still be a string to reach the secret refusal; the log says what it is.
  ctx:Log("type() of the secret is " .. type(secret))
  return secret
end

secretTest("IsSecret answers true for a genuine secret made by secretwrap", function(ctx)
  local secret = makeSecret(ctx, "plain")
  ctx:Expect(ClientKit:IsSecret(secret)):ToBe(true)
end)

secretTest("a secret capability name is refused by Has at the calling line", function(ctx)
  local secret = makeSecret(ctx, "C_Timer")
  local lines = { start = 0 }
  expectErrorAtCallingLine(ctx, function()
    lines.start = currentLine()
    ClientKit:Has(secret)
  end, lines, "ClientKit:Has capability must not be a secret value")
end)

secretTest("a secret addon name is refused by GetManifest at the calling line", function(ctx)
  local secret = makeSecret(ctx, addonName)
  local lines = { start = 0 }
  expectErrorAtCallingLine(ctx, function()
    lines.start = currentLine()
    ClientKit:GetManifest(secret)
  end, lines, "ClientKit:GetManifest addonName must not be a secret value")
end)

secretTest("a secret field name is refused by manifest:Get at the calling line", function(ctx)
  local snapshot = ClientKit:GetManifest(addonName)
  ctx:Expect(type(snapshot)):ToBe("table")
  if type(snapshot) ~= "table" then
    return
  end
  local secret = makeSecret(ctx, TOC_PROBE_FIELD)
  local lines = { start = 0 }
  expectErrorAtCallingLine(ctx, function()
    lines.start = currentLine()
    snapshot:Get(secret)
  end, lines, "ClientKit.Manifest:Get field must not be a secret value")
end)
