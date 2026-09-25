-- MoltenCodes Test: CompatKitSuite.lua
--
-- Real-client suites for the `compatKit` package. The Busted specs under
-- packages/compatKit/tests/ prove CompatKit against a fake ClientKit, a fake
-- ApiKit surface and a stand-in secret; these prove, inside the game client
-- with the installed MoltenCodes addon, what those fixtures can only simulate:
--
--   * the installed facade and its committed revision, and that the optional
--     ClientKit and ApiKit of the bundle are found at call time: ClientKit's
--     flavour (`"mainline"` on Retail) and ApiKit's installed flavour file;
--   * shims applied once with the real ClientKit flavour: a shim for the
--     running flavour runs, one for every other flavour is filtered, the
--     newest version wins before `Apply` and is only recorded after it, and a
--     host skip holds before and after the registration;
--   * `context.hasApi` against the real installed ApiKit surface, checked
--     against this file's own walk of the flavour's `api` table (identity with
--     the host function): `C_Timer.NewTicker` answers `true`, the legacy
--     `GetAddOnMetadata` global the catalogue names (absent from the Retail
--     metadata) answers `false`, and `covers` records the same names missing;
--   * `context.hasGlobal` on real client globals and dotted paths, checked
--     against raw reads of the global table;
--   * every catalogue row whose `replacementApi` is set names a function the
--     running client has, and the FrameXML replacements the catalogue names
--     (`Menu`, `MenuUtil`, `Settings.OpenToCategory`, ...) and the legacy
--     subsystems themselves are logged as the client has them;
--   * a failing shim, a shim that calls `Apply`, a raising probe and a shim
--     raising a secret value, each reported through the handler
--     `seterrorhandler` installed, the positions naming this file;
--   * provider registries whose probes read real host facts
--     (`InCombatLockdown`, `IsLoggedIn`, the chat frame's visibility), a probe
--     answering a genuine secret counted as dead, and an allocation-free
--     `Resolve` on the client's own collector;
--   * argument errors, and secret values made by the client's `secretwrap`
--     refused at the calling line in this file as the client names it.
--
-- Nothing here needs combat, a group or an instance, nothing is drawn, and no
-- client setting is changed. The provider test with host facts is skipped in
-- combat, because a probe then reads a different answer.
--
-- Run with `/mct run compatKit`; tests/client/MoltenCodesTest_CompatKit/EXPECTED.md
-- lists what the chat frame should show.
--
-- What a run leaves behind. CompatKit has no way to remove a shim: a name
-- lives for the session (docs/API.md, "Shims"). Every run therefore registers
-- 14 new shims under unique names (`MoltenCodesTest.CompatKit.<serial>.<purpose>`,
-- the serial counting up for the session), and every one of them is a no-op
-- towards the client: it only reads the context it is handed and records
-- what it saw in a table of this file, or raises on purpose. Two of them are
-- skipped by the host and stay pending, so every later `Apply` in the session
-- counts them as skipped. With CompatKit's default `maxShims` of 64 and nothing
-- else registering shims, four runs fit in a session; in a fifth, every test
-- that no longer finds a free shim name is skipped with a reason naming
-- `/reload`, and a test never leaves a raising shim pending when a later
-- registration of its own is refused. The limits are never
-- changed: every `SetLimits` call here is a refusal the tests check. The four
-- provider kinds the tests use (`MoltenCodesTest.CompatKit.hostFacts`,
-- `...raisingProbe`, `...secretProbe`, `...allocation`) stay registered, as
-- every kind does, but the After hook of each suite unregisters every provider
-- a test added, whatever the outcome, and the client's error handler is put
-- back right after each call it was swapped for. Nothing is written to a global
-- or a saved variable.

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
local COMPAT_KIT_API = 1
local CLIENT_KIT_API = 1
local API_KIT_API = 1
local PACKAGE_ID = "compatKit"

--- The file name the client puts in front of every error raised at a line of
--- this file.
local THIS_FILE = "CompatKitSuite.lua"

--- The facade methods docs/API.md lists as the public surface, in its order.
local FACADE_METHODS = {
  "Shim",
  "SkipShim",
  "GetShims",
  "Apply",
  "Providers",
  "SetLimits",
  "GetLimits",
}

--- The provider registry methods docs/API.md lists.
local REGISTRY_METHODS = { "Register", "Unregister", "Resolve", "List" }

--- The limits docs/API.md ("Limits") documents, with their defaults.
local DEFAULT_LIMITS = { maxShims = 64, maxProviders = 32, maxProviderKinds = 32 }

--- Every ClientKit flavour docs/API.md of ClientKit names ("Flavour").
local CLIENT_KIT_FLAVOURS = { "mainline", "mists", "tbc", "classic" }

---One row of ClientKit's documented `WOW_PROJECT_ID` mapping.
---@class MoltenCodesTest.CompatKit.ProjectRow
---@field constant string the client's name for the project number
---@field flavour string what `ClientKit:GetFlavor()` answers for it

--- ClientKit's `WOW_PROJECT_ID` mapping, by value (docs/API.md of ClientKit,
--- "Flavour"), for the three clients the framework promises.
---@type table<integer, MoltenCodesTest.CompatKit.ProjectRow>
local PROJECT_FLAVOURS = {
  [1] = { constant = "WOW_PROJECT_MAINLINE", flavour = "mainline" },
  [2] = { constant = "WOW_PROJECT_CLASSIC", flavour = "classic" },
  [19] = { constant = "WOW_PROJECT_MISTS_CLASSIC", flavour = "mists" },
}

--- Where ApiKit keeps the `api` table of each of its flavour ids under
--- `MoltenCodes.wow` (packages/apiKit/src/ApiKit.lua, `FLAVORS`).
local API_KIT_FLAVOUR_PATHS = {
  retail = { "retail" },
  ptr = { "ptr" },
  beta = { "beta" },
  ["classic-era"] = { "classic", "era" },
  ["classic-mop"] = { "classic", "mop" },
}

--- The first column of the catalogue in docs/EMBEDDING.md ("Catalogue of
--- taint-hostile subsystems"), in its order. A difference means the installed
--- CompatKit is not the committed one.
local CATALOGUE_SUBSYSTEMS = {
  "UIDropDownMenu (UIDropDownMenu_*, EasyMenu)",
  "StaticPopup_Show dialogs",
  "ActionButton_ShowOverlayGlow / ActionButton_HideOverlayGlow",
  "Hidden tooltip scanning (GameTooltip:SetOwner/SetUnit, GameTooltipTextLeft<n>)",
  "GetAddOnMetadata (legacy global)",
  "ShowUIPanel / HideUIPanel on Blizzard panels",
  "InterfaceOptionsFrame_OpenToCategory",
  "SetOverrideBindingClick in combat",
  "CompactUnitFrame hooks that write frame fields",
}

--- The names the `hasApi` test asks about, with what the committed metadata
--- says: `documented` is `true` when packages/apiKit/metadata/retail/namespaces.json
--- documents the function, so the Retail flavour file binds it, and
--- `documentedOnClassic` the same for the classic-era and classic-mop files,
--- which agree on every name here.
local HAS_API_CASES = {
  {
    name = "C_Timer.NewTicker",
    documented = true,
    documentedOnClassic = true,
    why = "documented; a FrameXML function",
  },
  {
    name = "C_Timer.After",
    documented = true,
    documentedOnClassic = true,
    why = "documented; a host function",
  },
  {
    name = "GetMouseFoci",
    documented = true,
    documentedOnClassic = true,
    why = "a documented global",
  },
  {
    name = "C_AddOns.GetAddOnMetadata",
    documented = true,
    documentedOnClassic = true,
    why = "catalogue row 5",
  },
  {
    name = "C_TooltipInfo.GetUnit",
    documented = true,
    documentedOnClassic = false,
    why = "catalogue row 4; the Classic metadata documents C_TooltipInfo without GetUnit",
  },
  {
    name = "C_SettingsUtil.OpenSettingsPanel",
    documented = true,
    documentedOnClassic = true,
    why = "catalogue row 7",
  },
  {
    name = "C_UnitAuras.GetAuraDataByIndex",
    documented = true,
    documentedOnClassic = true,
    why = "catalogue row 9",
  },
  {
    name = "GetAddOnMetadata",
    documented = false,
    documentedOnClassic = false,
    why = "catalogue row 5's legacy global, absent from the metadata",
  },
  {
    name = "InterfaceOptionsFrame_OpenToCategory",
    documented = false,
    documentedOnClassic = false,
    why = "catalogue row 7's removed function",
  },
  {
    name = "hooksecurefunc",
    documented = false,
    documentedOnClassic = false,
    why = "on the host, not in the metadata",
  },
  {
    name = "C_Timer.MoltenCodesNoSuchFunction",
    documented = false,
    documentedOnClassic = false,
    why = "on no client",
  },
}

--- The `covers` of the `hasApi` shim: two names documented on Retail, then the
--- legacy global and an undocumented host function, which Apply must record
--- missing. The Classic metadata does not document `C_TooltipInfo.GetUnit`
--- either, so there Apply records three names missing.
local HAS_API_COVERS = {
  "C_Timer.NewTicker",
  "GetAddOnMetadata",
  "C_TooltipInfo.GetUnit",
  "hooksecurefunc",
}

--- What `covers` records missing, per apiKit flavour, in `covers` order.
local HAS_API_MISSING = {
  retail = { "GetAddOnMetadata", "hooksecurefunc" },
  ["classic-era"] = { "GetAddOnMetadata", "C_TooltipInfo.GetUnit", "hooksecurefunc" },
  ["classic-mop"] = { "GetAddOnMetadata", "C_TooltipInfo.GetUnit", "hooksecurefunc" },
}

--- The apiKit flavours whose metadata documents each catalogue
--- `replacementApi` (docs/EMBEDDING.md, "Catalogue of taint-hostile
--- subsystems", last column), in the sorted order CompatKit keeps.
local REPLACEMENT_FLAVOURS = {
  ["C_TooltipInfo.GetUnit"] = { "beta", "ptr", "retail" },
  ["C_AddOns.GetAddOnMetadata"] = { "beta", "classic-era", "classic-mop", "ptr", "retail" },
  ["C_SettingsUtil.OpenSettingsPanel"] = { "beta", "classic-era", "classic-mop", "ptr", "retail" },
  ["C_UnitAuras.GetAuraDataByIndex"] = { "beta", "classic-era", "classic-mop", "ptr", "retail" },
}

--- The paths the `hasGlobal` test asks about. `expected` is what raw reads of
--- the Retail 12.1 global table answer, or `nil` where only the log records
--- it: `UIParent.GetName` is `false` because a frame's methods live in its
--- metatable, which a raw read does not follow (docs/API.md, "The context").
local HAS_GLOBAL_CASES = {
  { name = "UIParent", expected = true },
  { name = "DEFAULT_CHAT_FRAME", expected = true },
  { name = "C_Timer.NewTicker", expected = true },
  { name = "C_Timer.MoltenCodesNoSuchFunction", expected = false },
  { name = "UIParent.GetName", expected = false },
  { name = "WOW_PROJECT_ID.MoltenCodesNoSuchField", expected = false },
  { name = "MoltenCodesTest_NoSuchGlobal", expected = false },
  { name = "GetAddOnMetadata" },
  { name = "Menu" },
  { name = "MenuUtil" },
  { name = "Settings.OpenToCategory" },
}

--- FrameXML globals the catalogue's replacements name, logged as the client has
--- them: the documented API tables do not describe these.
local FRAMEXML_REPLACEMENTS = {
  "Menu",
  "MenuUtil",
  "MenuUtil.CreateContextMenu",
  "Settings",
  "Settings.OpenToCategory",
  "TooltipDataProcessor",
  "TooltipDataProcessor.AddTooltipPostCall",
  "UISpecialFrames",
  "hooksecurefunc",
}

--- The legacy subsystems the catalogue warns about, logged as the client has
--- them; several were removed from Retail.
local LEGACY_SUBSYSTEMS = {
  "UIDropDownMenu_Initialize",
  "EasyMenu",
  "UIDROPDOWNMENU_OPEN_MENU",
  "StaticPopup_Show",
  "ActionButton_ShowOverlayGlow",
  "ActionButton_HideOverlayGlow",
  "GetAddOnMetadata",
  "ShowUIPanel",
  "HideUIPanel",
  "InterfaceOptionsFrame_OpenToCategory",
  "SetOverrideBindingClick",
  "CompactUnitFrame_UpdateAll",
}

--- The Blizzard addons whose load state the FrameXML log adds.
local FRAMEXML_ADDONS = { "Blizzard_Menu", "Blizzard_Settings", "Blizzard_Deprecated" }

--- The provider kinds the tests use. Kinds cannot be removed, so every run
--- reuses these four; the After hook unregisters the providers.
local KIND = {
  hostFacts = "MoltenCodesTest.CompatKit.hostFacts",
  raisingProbe = "MoltenCodesTest.CompatKit.raisingProbe",
  secretProbe = "MoltenCodesTest.CompatKit.secretProbe",
  allocation = "MoltenCodesTest.CompatKit.allocation",
}

--- The marker a deliberately failing shim or probe raises, so a report of
--- another addon reaching the swapped handler is not mistaken for it.
local SHIM_FAILURE = "MoltenCodesTest_CompatKit deliberate shim failure"
local PROBE_FAILURE = "MoltenCodesTest_CompatKit deliberate probe failure"

--- How many rounds the allocation guard runs, and the kilobytes it tolerates.
--- One table per call would cost well over a hundred kilobytes; the tolerance
--- absorbs a stray allocation by the client between the two readings.
local ALLOCATION_ROUNDS = 10000
local ALLOCATION_TOLERANCE_KB = 1

--- Why a shim test stops when CompatKit refuses a new shim name.
local SHIMS_FULL_REASON = "CompatKit's maxShims is reached: every run registers 14 shims that "
  .. "stay for the session (four runs fit in one); /reload before running again"

-- Resolving the client and the framework ---------------------------------------------

---Read a client global, or `nil`.
---@param name string
---@return any
local function readHost(name)
  -- The project constants, the secret-value functions, the error handler
  -- functions, UIParent, the chat frame and the C_* namespaces are World of
  -- Warcraft client globals, reachable only through the global table.
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

---Follow the dotted path `name` through the global table with raw reads, the
---way docs/API.md says `hasGlobal` does: the first segment is a global, every
---later one a raw field of the table before it, and a non-table step ends
---the walk with `nil`. This is the oracle the context tests compare with.
---@param name string
---@return any
local function readHostPath(name)
  local value = nil
  local first = true
  for segment in name:gmatch("[^%.]+") do
    if first then
      value = readHost(segment)
      first = false
    elseif type(value) ~= "table" then
      return nil
    else
      value = rawget(value, segment)
    end
  end
  return value
end

---@type Registry
local Registry = rawget(rawget(namespace, "Registries") or {}, REGISTRY_API)
if type(Registry) ~= "table" then
  error(addonName .. " requires the MoltenCodes addon (Registry API 2); reinstall it", 0)
end

-- CompatKit, ClientKit and ApiKit are not in the language-server workspace of
-- tests/client (its .luarc.json lists TestKit's dependency closure only), so
-- their facades are typed `any` here.

---@type any
local CompatKit = Registry:Get(PACKAGE_ID, COMPAT_KIT_API)
if type(CompatKit) == "nil" then
  error(addonName .. " requires CompatKit API 1 in the MoltenCodes addon; reinstall it", 0)
end

--- The optional Kits CompatKit finds at call time. The bundle carries both; a
--- test that needs one and does not find it fails with a reason.
---@type any
local ClientKit = Registry:Find("clientKit", CLIENT_KIT_API)
---@type any
local ApiKit = Registry:Find("apiKit", API_KIT_API)

--- Read once at load: the secrets suite registers its tests as skipped when
--- the client cannot make a secret value.
local isSecretValue = readHost("issecretvalue")
local secretWrap = readHost("secretwrap")
local SECRETS_AVAILABLE = type(isSecretValue) == "function" and type(secretWrap) == "function"

---Whether `value` is a secret, on a client that has secret values.
---@param value any
---@return boolean
local function isSecret(value)
  return SECRETS_AVAILABLE and isSecretValue(value) == true
end

---Describe a value for a log line without comparing or formatting a secret.
---@param value any
---@return string
local function describe(value)
  if isSecret(value) then
    return "<secret value>"
  end
  if type(value) == "string" then
    return string.format("%q", value)
  end
  return tostring(value)
end

---What the host holds at `name`, for a log line: its type, or `nil`.
---@param name string
---@return string
local function describeHost(name)
  local value = readHostPath(name)
  if isSecret(value) then
    return "<secret value>"
  end
  return type(value)
end

---The ApiKit flavour id of the running client, or `nil` without ApiKit.
---@return string|nil
local function apiKitFlavour()
  if type(ApiKit) == "nil" then
    return nil
  end
  local flavour = ApiKit:GetFlavor()
  if type(flavour) ~= "string" then
    return nil
  end
  return flavour
end

--- The row of `PROJECT_FLAVOURS` for the running client's `WOW_PROJECT_ID`, or
--- `nil` on a client the framework does not promise.
---@type MoltenCodesTest.CompatKit.ProjectRow|nil
local runningProject = nil
do
  local projectId = readHost("WOW_PROJECT_ID")
  if type(projectId) == "number" then
    runningProject = PROJECT_FLAVOURS[projectId]
  end
end

--- The project row the test names are written for: the running one, or
--- Retail's on a client the framework does not promise.
local NAMED_PROJECT = runningProject or PROJECT_FLAVOURS[1]

--- Whether the running ApiKit flavour is one of the two Classic flavours,
--- whose metadata the `hasApi` and catalogue tests hold their own names to.
local ON_CLASSIC_METADATA = apiKitFlavour() == "classic-era" or apiKitFlavour() == "classic-mop"

---Every function the running flavour's ApiKit `api` table binds, keyed by the
---function, and how many there are: this file's own walk, independent of
---CompatKit's, of `MoltenCodes.wow.<flavour path>.api.<namespace>.<binding>`.
---@return table<function, true> bound
---@return integer count
local function installedBindings()
  local bound = {}
  local count = 0
  local path = API_KIT_FLAVOUR_PATHS[apiKitFlavour() or ""]
  if type(path) == "nil" then
    return bound, count
  end
  local node = rawget(namespace, "wow")
  for _, segment in ipairs(path) do
    node = type(node) == "table" and rawget(node, segment) or nil
  end
  local api = type(node) == "table" and rawget(node, "api") or nil
  if type(api) ~= "table" then
    return bound, count
  end
  for _, namespaceTable in pairs(api) do
    if type(namespaceTable) == "table" then
      for _, binding in pairs(namespaceTable) do
        if type(binding) == "function" and not bound[binding] then
          bound[binding] = true
          count = count + 1
        end
      end
    end
  end
  return bound, count
end

-- Positions and errors ---------------------------------------------------------------

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

---Check that `message` is a string naming this file at `expectedLine` and
---containing `expected` (compared literally).
---@param ctx TestKit.Context
---@param message any
---@param expectedLine integer
---@param expected string
local function expectMessageAt(ctx, message, expectedLine, expected)
  ctx:Log("client message: " .. describe(message))
  ctx:Expect(type(message)):ToBe("string")
  if type(message) ~= "string" or isSecret(message) then
    return
  end
  local file, line = splitPosition(message)
  ctx:Expect((file or ""):sub(-#THIS_FILE)):ToBe(THIS_FILE)
  ctx:Expect(message:find(expected, 1, true) ~= nil):ToBe(true)
  ctx:Expect(line):ToBe(expectedLine)
end

---Call `raise`, which must store its start line in `lines.start` with
---`currentLine()` and raise on the next line, and check the message names this
---file at that line and contains `expected`.
---@param ctx TestKit.Context
---@param raise fun(lines: { start: integer }) Records its start line, then raises on the next line.
---@param expected string
local function expectErrorAtNextLine(ctx, raise, expected)
  local lines = { start = 0 }
  local succeeded, message = pcall(raise, lines)
  ctx:Expect(succeeded):ToBe(false)
  expectMessageAt(ctx, message, lines.start + 1, expected)
end

---Run `raise` like `expectErrorAtNextLine` does, but only record the outcome,
---for a check made later: inside a shim a failed expectation would become the
---shim's own failure instead of the test's.
---@param raise fun(lines: { start: integer })
---@return { succeeded: boolean, message: any, line: integer }
local function captureErrorAtNextLine(raise)
  local lines = { start = 0 }
  local succeeded, message = pcall(raise, lines)
  return { succeeded = succeeded, message = message, line = lines.start + 1 }
end

---Check an outcome `captureErrorAtNextLine` recorded.
---@param ctx TestKit.Context
---@param captured { succeeded: boolean, message: any, line: integer }|nil
---@param expected string
local function expectCapturedError(ctx, captured, expected)
  ctx:Expect(type(captured)):ToBe("table")
  if type(captured) == "nil" then
    return
  end
  ctx:Expect(captured.succeeded):ToBe(false)
  expectMessageAt(ctx, captured.message, captured.line, expected)
end

-- Error handler --------------------------------------------------------------------

---Run `action` with a collector installed as the client's error handler and
---return every value the collector received, in order.
---
---CompatKit hands a failing shim or probe to `geterrorhandler()`, which on the
---client reads the handler `seterrorhandler` installed. The handler is
---therefore swapped with `seterrorhandler`, never by replacing the global
---`geterrorhandler`, which Blizzard code calls too (tests/client/README.md,
---"Catching an error a Kit reports instead of raising"), and put back at once.
---When the swap does not hold (an error-capturing addon such as BugGrabber
---refuses it), `action` is not run, so no deliberate failure reaches the
---player's error display, and `observed` is `false`.
---@param ctx TestKit.Context
---@param action fun(reported: any[]) receives the list the collector fills, so it can count as it goes
---@return any[] reported
---@return boolean observed
local function collectReportedErrors(ctx, action)
  local reported = {}
  ---@param message any
  local function collector(message)
    reported[#reported + 1] = message
  end

  local setErrorHandler = readHost("seterrorhandler")
  local getErrorHandler = readHost("geterrorhandler")
  if type(setErrorHandler) ~= "function" then
    -- Outside the Retail client: the global is replaced for this test only,
    -- and TestKit puts it back.
    -- selene: allow(global_usage)
    ctx:Replace(_G, "geterrorhandler", function()
      return collector
    end)
    action(reported)
    return reported, true
  end

  local previous = getErrorHandler()
  setErrorHandler(collector)
  if getErrorHandler() ~= collector then
    setErrorHandler(previous)
    return reported, false
  end
  local succeeded, problem = pcall(action, reported)
  setErrorHandler(previous)
  if not succeeded then
    error(problem, 0)
  end
  return reported, true
end

---The reports that end with `marker`, the deliberate failure of one test.
---@param reported any[]
---@param marker string
---@return string[]
local function ownReports(reported, marker)
  local own = {}
  for _, message in ipairs(reported) do
    if type(message) == "string" and not isSecret(message) and message:sub(-#marker) == marker then
      own[#own + 1] = message
    end
  end
  return own
end

---Skip the running test when the error handler swap did not hold.
---@param ctx TestKit.Context
---@param observed boolean
local function requireObservedHandler(ctx, observed)
  if not observed then
    Harness:SkipTest(
      ctx,
      "the client's error handler could not be swapped (an error-capturing addon such as BugGrabber refused it); nothing was provoked"
    )
  end
end

-- Shims ----------------------------------------------------------------------------

--- Counts up for the session so every shim name is new: a name lives for the
--- session, and a second run must not meet the first run's shims.
local shimSerial = 0

---A fresh prefix for the shims of one test,
---`MoltenCodesTest.CompatKit.<serial>.`, zero-padded so name order is serial order.
---@return string
local function nextShimPrefix()
  shimSerial = shimSerial + 1
  return ("MoltenCodesTest.CompatKit.%04d."):format(shimSerial)
end

---Register a shim and return CompatKit's result word; skip the test when
---CompatKit refuses the new name because `maxShims` is reached.
---@param ctx TestKit.Context
---@param name string
---@param version integer
---@param implementation fun(context: any)
---@param options table|nil
---@return boolean accepted
---@return string result
local function registerShim(ctx, name, version, implementation, options)
  local accepted, result = CompatKit:Shim(name, version, implementation, options)
  if accepted == false and result == "full" then
    Harness:SkipTest(ctx, SHIMS_FULL_REASON)
  end
  return accepted, result
end

---The `GetShims` record of `name`, or `nil`.
---@param name string
---@return table|nil
local function findShim(name)
  for _, row in ipairs(CompatKit:GetShims()) do
    if row.name == name then
      return row
    end
  end
  return nil
end

---Call `Apply` and check its three counts against what `GetShims` says
---happened: every shim pending before the call that is now applied, failed or
---filtered, and every shim a skip keeps pending (a skipped shim stays pending
---and is counted on every call). Shims of other addons and of earlier runs
---are accounted for the same way, so the counts hold whatever the session
---holds.
---@param ctx TestKit.Context
---@return integer applied
---@return integer skipped
---@return integer failed
local function applyAccounted(ctx)
  local pendingBefore = {}
  for _, row in ipairs(CompatKit:GetShims()) do
    if row.status == "pending" then
      pendingBefore[row.name] = true
    end
  end

  local applied, skipped, failed = CompatKit:Apply()

  local expected = { applied = 0, skipped = 0, failed = 0 }
  for _, row in ipairs(CompatKit:GetShims()) do
    if row.status == "skipped" then
      expected.skipped = expected.skipped + 1
    elseif pendingBefore[row.name] then
      if row.status == "applied" then
        expected.applied = expected.applied + 1
      elseif row.status == "failed" then
        expected.failed = expected.failed + 1
      elseif row.status == "filtered" then
        expected.skipped = expected.skipped + 1
      end
    end
  end
  ctx:Log(("Apply returned applied %d, skipped %d, failed %d"):format(applied, skipped, failed))
  ctx:Expect(applied):ToBe(expected.applied)
  ctx:Expect(skipped):ToBe(expected.skipped)
  ctx:Expect(failed):ToBe(expected.failed)
  return applied, skipped, failed
end

---Fail the test with a reason when the bundle lacks ClientKit or ApiKit.
---@param ctx TestKit.Context
---@return boolean present
local function requireOptionalKits(ctx)
  if type(ClientKit) == "nil" or type(ApiKit) == "nil" then
    ctx:Fail("the MoltenCodes addon carries no ClientKit API 1 or no ApiKit API 1; reinstall it")
    return false
  end
  return true
end

-- Providers ------------------------------------------------------------------------

--- Every provider a test registered, as `{ registry, name }`, for the After hook.
---@type { registry: any, name: string }[]
local registeredProviders = {}

---Register a provider for the length of one test. A provider of the same name
---left by an interrupted earlier run is unregistered first.
---@param ctx TestKit.Context
---@param registry any
---@param name string
---@param implementation any
---@param probe (fun(): any)|nil
---@param priority integer|nil
local function addProvider(ctx, registry, name, implementation, probe, priority)
  registry:Unregister(name)
  local registered, reason = registry:Register(name, implementation, probe, priority)
  ctx:Expect(registered):ToBe(true)
  ctx:Expect(reason):ToBeNil()
  registeredProviders[#registeredProviders + 1] = { registry = registry, name = name }
end

---After hook: unregister every provider the test added.
local function cleanUp()
  for index = #registeredProviders, 1, -1 do
    local entry = registeredProviders[index]
    registeredProviders[index] = nil
    entry.registry:Unregister(entry.name)
  end
end

---Register a suite of this package whose tests all end with their providers removed.
---@param part string
---@return TestKit.Suite
local function newSuite(part)
  local suite = Harness:Suite(PACKAGE_ID, part, addonName)
  suite:After(cleanUp)
  return suite
end

---The names of `rows` (a `List` result), in order.
---@param rows { name: string }[]
---@return string[]
local function rowNames(rows)
  local names = {}
  for index, row in ipairs(rows) do
    names[index] = row.name
  end
  return names
end

-- compatKit.facade ------------------------------------------------------------------

local facade = newSuite("facade")

facade:Test(
  "Registry:Get('compatKit', 1) is the CompatKit facade with API 1, its seven methods, a nine-row CATALOGUE and UNBOUNDED; the session's limits and shims are logged",
  function(ctx)
    ctx:Expect(type(CompatKit)):ToBe("table")
    ctx:Expect(rawget(CompatKit, "API")):ToBe(COMPAT_KIT_API)
    for _, method in ipairs(FACADE_METHODS) do
      ctx:Expect(type(CompatKit[method])):ToBe("function")
    end
    ctx:Expect(type(CompatKit.CATALOGUE)):ToBe("table")
    ctx:Expect(CompatKit.CATALOGUE_COUNT):ToBe(#CATALOGUE_SUBSYSTEMS)
    ctx:Expect(type(CompatKit.UNBOUNDED)):ToBe("table")

    local limits = CompatKit:GetLimits()
    ctx:Log(
      ("limits: maxShims %s, maxProviders %s, maxProviderKinds %s"):format(
        describe(limits.maxShims),
        describe(limits.maxProviders),
        describe(limits.maxProviderKinds)
      )
    )
    for name, default in pairs(DEFAULT_LIMITS) do
      if limits[name] ~= default then
        ctx:Log(
          ("limit %s differs from its default %d: another addon changed it"):format(name, default)
        )
      end
    end

    local statuses = {}
    local shims = CompatKit:GetShims()
    for _, row in ipairs(shims) do
      statuses[row.status] = (statuses[row.status] or 0) + 1
    end
    ctx:Log(
      ("shims in the session: %d (pending %d, applied %d, failed %d, filtered %d, skipped %d)"):format(
        #shims,
        statuses.pending or 0,
        statuses.applied or 0,
        statuses.failed or 0,
        statuses.filtered or 0,
        statuses.skipped or 0
      )
    )

    local registry = CompatKit:Providers(KIND.hostFacts)
    for _, method in ipairs(REGISTRY_METHODS) do
      ctx:Expect(type(registry[method])):ToBe("function")
    end
    ctx:Expect(CompatKit:Providers(KIND.hostFacts)):ToBe(registry)
  end
)

facade:Test("the installed CompatKit carries the revision of the committed manifest", function(ctx)
  local expectedPackages = Harness:GetExpectedPackages()
  if type(expectedPackages) == "nil" then
    ctx:Fail("Expected.lua is missing; install with python3 -m tooling.client.install")
    return
  end
  for _, expected in ipairs(expectedPackages) do
    if expected.id == PACKAGE_ID then
      local _, revision = Registry:Get(PACKAGE_ID, COMPAT_KIT_API)
      ctx:Expect(revision):ToBe(expected.revision)
      ctx:Expect(rawget(CompatKit, "REVISION")):ToBe(expected.revision)
      return
    end
  end
  ctx:Fail("Expected.lua does not list compatKit")
end)

facade:Test(
  ("the bundle's ClientKit and ApiKit are found through Registry:Find: ClientKit answers '%s' on %s, and ApiKit's flavour file for the running client is installed (flavour, metadata build and binding count logged)"):format(
    NAMED_PROJECT.flavour,
    NAMED_PROJECT.constant
  ),
  function(ctx)
    if not requireOptionalKits(ctx) then
      return
    end
    local projectId = readHost("WOW_PROJECT_ID")
    local mainlineId = readHost("WOW_PROJECT_MAINLINE")
    local flavour = ClientKit:GetFlavor()
    ctx:Log(
      ("WOW_PROJECT_ID %s, WOW_PROJECT_MAINLINE %s, ClientKit flavour %s"):format(
        describe(projectId),
        describe(mainlineId),
        describe(flavour)
      )
    )
    ctx:Expect(type(flavour)):ToBe("string")
    -- ClientKit maps WOW_PROJECT_ID by value (docs/API.md of ClientKit).
    if type(runningProject) ~= "nil" then
      ctx:Expect(flavour):ToBe(runningProject.flavour)
    end

    local apiFlavour = apiKitFlavour()
    local version, build = ApiKit:GetMetadataBuild(apiFlavour or "retail")
    local _, bindingCount = installedBindings()
    ctx:Log(
      ("ApiKit flavour %s, metadata %s build %s, %d functions bound"):format(
        describe(apiFlavour),
        describe(version),
        describe(build),
        bindingCount
      )
    )
    ctx:Expect(type(API_KIT_FLAVOUR_PATHS[apiFlavour or ""])):ToBe("table")
    ctx:Expect(type(version)):ToBe("string")
    ctx:Expect(bindingCount > 0):ToBe(true)
  end
)

-- compatKit.shims -------------------------------------------------------------------

local shimsSuite = newSuite("shims")

shimsSuite:Test(
  ("Apply runs a shim for the running ClientKit flavour and one without flavours once each, filters one for every other flavour, and hands every shim context.flavour '%s'"):format(
    NAMED_PROJECT.flavour
  ),
  function(ctx)
    if not requireOptionalKits(ctx) then
      return
    end
    local current = ClientKit:GetFlavor()
    local others = {}
    for _, flavour in ipairs(CLIENT_KIT_FLAVOURS) do
      if flavour ~= current then
        others[#others + 1] = flavour
      end
    end
    local prefix = nextShimPrefix()
    local runs = { current = 0, other = 0, every = 0 }
    local seenFlavours = {}

    registerShim(ctx, prefix .. "a-current", 1, function(context)
      runs.current = runs.current + 1
      seenFlavours[#seenFlavours + 1] = context.flavour
    end, { description = "no-op; runs on the running flavour", flavours = { current } })
    registerShim(ctx, prefix .. "b-other", 1, function()
      runs.other = runs.other + 1
    end, { description = "no-op; filtered on the running flavour", flavours = others })
    registerShim(ctx, prefix .. "c-every", 1, function(context)
      runs.every = runs.every + 1
      seenFlavours[#seenFlavours + 1] = context.flavour
    end, { description = "no-op; no flavour filter" })

    applyAccounted(ctx)
    ctx:Log(
      ("ClientKit flavour %s; filtered flavours %s"):format(current, table.concat(others, ", "))
    )
    ctx:Expect(runs):ToEqual({ current = 1, other = 0, every = 1 })
    ctx:Expect(seenFlavours):ToEqual({ current, current })
    if type(runningProject) ~= "nil" then
      ctx:Expect(seenFlavours[1]):ToBe(runningProject.flavour)
    end

    local currentRow = findShim(prefix .. "a-current") or {}
    local otherRow = findShim(prefix .. "b-other") or {}
    local everyRow = findShim(prefix .. "c-every") or {}
    ctx:Expect(currentRow.status):ToBe("applied")
    ctx:Expect(currentRow.applied):ToBe(1)
    ctx:Expect(currentRow.flavours):ToEqual({ current })
    ctx:Expect(otherRow.status):ToBe("filtered")
    ctx:Expect(otherRow.applied):ToBe(false)
    ctx:Expect(everyRow.status):ToBe("applied")
    ctx:Expect(everyRow.flavours):ToBe(false)

    -- Applied once: a second Apply runs none of them again.
    applyAccounted(ctx)
    ctx:Expect(runs):ToEqual({ current = 1, other = 0, every = 1 })
  end
)

shimsSuite:Test(
  "the highest version registered before Apply is the one that runs; a higher version after Apply is recorded beside the applied one and never run",
  function(ctx)
    local name = nextShimPrefix() .. "versioned"
    local ran = {}
    ---@param version integer
    ---@return fun(context: any)
    local function versionShim(version)
      return function()
        ran[#ran + 1] = version
      end
    end

    local accepted, result = registerShim(ctx, name, 1, versionShim(1))
    ctx:Expect(accepted):ToBe(true)
    ctx:Expect(result):ToBe("pending")
    accepted, result = CompatKit:Shim(name, 2, versionShim(2))
    ctx:Expect(accepted):ToBe(true)
    ctx:Expect(result):ToBe("replaced")
    accepted, result = CompatKit:Shim(name, 1, versionShim(1))
    ctx:Expect(accepted):ToBe(false)
    ctx:Expect(result):ToBe("ignored")

    applyAccounted(ctx)
    ctx:Expect(ran):ToEqual({ 2 })

    accepted, result = CompatKit:Shim(name, 3, versionShim(3))
    ctx:Expect(accepted):ToBe(true)
    ctx:Expect(result):ToBe("recorded")
    applyAccounted(ctx)
    ctx:Expect(ran):ToEqual({ 2 })

    local row = findShim(name) or {}
    ctx:Expect(row.version):ToBe(3)
    ctx:Expect(row.applied):ToBe(2)
    ctx:Expect(row.status):ToBe("applied")
  end
)

shimsSuite:Test(
  "SkipShim before a shim is registered and after it is pending keeps both from running on every Apply, and both are counted as skipped",
  function(ctx)
    local prefix = nextShimPrefix()
    local early = prefix .. "skipped-before"
    local late = prefix .. "skipped-pending"
    local runs = 0
    local function counting()
      runs = runs + 1
    end

    local marked, reason = CompatKit:SkipShim(early)
    if marked == false and reason == "full" then
      Harness:SkipTest(ctx, SHIMS_FULL_REASON)
    end
    ctx:Expect(marked):ToBe(true)
    local accepted, result = registerShim(ctx, early, 1, counting)
    ctx:Expect(accepted):ToBe(true)
    ctx:Expect(result):ToBe("pending")
    registerShim(ctx, late, 1, counting)
    ctx:Expect(CompatKit:SkipShim(late)):ToBe(true)

    local _, firstSkipped = applyAccounted(ctx)
    local _, secondSkipped = applyAccounted(ctx)
    ctx:Expect(runs):ToBe(0)
    ctx:Expect(firstSkipped >= 2):ToBe(true)
    ctx:Expect(secondSkipped >= 2):ToBe(true)
    for _, name in ipairs({ early, late }) do
      local row = findShim(name) or {}
      ctx:Expect(row.status):ToBe("skipped")
      ctx:Expect(row.skipped):ToBe(true)
      ctx:Expect(row.applied):ToBe(false)
    end
  end
)

-- compatKit.context -----------------------------------------------------------------

local contextSuite = newSuite("context")

--- The name of the `hasApi` test, which states what the running flavour's
--- metadata documents.
local HAS_API_TEST = ON_CLASSIC_METADATA
    and "context.hasApi answers by identity with the installed ApiKit surface: C_Timer.NewTicker and the three catalogue replacements Classic documents true, C_TooltipInfo.GetUnit, the legacy GetAddOnMetadata global and undocumented hooksecurefunc false, and covers records those three missing"
  or "context.hasApi answers by identity with the installed ApiKit surface: C_Timer.NewTicker and the catalogue's replacements true, the legacy GetAddOnMetadata global and undocumented hooksecurefunc false, and covers records those two missing"

contextSuite:Test(HAS_API_TEST, function(ctx)
  if not requireOptionalKits(ctx) then
    return
  end
  local answers = {}
  local name = nextShimPrefix() .. "hasApi"
  registerShim(ctx, name, 1, function(context)
    for _, case in ipairs(HAS_API_CASES) do
      answers[case.name] = context.hasApi(case.name)
    end
  end, { description = "no-op; asks hasApi", covers = HAS_API_COVERS })
  applyAccounted(ctx)

  local bound = installedBindings()
  local flavour = apiKitFlavour()
  ---Whether this file's own walk finds the host function `apiName` bound.
  ---@param apiName string
  ---@return boolean
  local function boundByFlavourFile(apiName)
    local hostFunction = readHostPath(apiName)
    return type(hostFunction) == "function" and bound[hostFunction] == true
  end

  for _, case in ipairs(HAS_API_CASES) do
    local expectedByIdentity = boundByFlavourFile(case.name)
    ctx:Log(
      ("%s: hasApi %s; host %s; bound by the %s flavour file %s; documented on Retail %s, on Classic %s (%s)"):format(
        case.name,
        describe(answers[case.name]),
        describeHost(case.name),
        describe(flavour),
        tostring(expectedByIdentity),
        tostring(case.documented),
        tostring(case.documentedOnClassic),
        case.why
      )
    )
    ctx:Expect(answers[case.name]):ToBe(expectedByIdentity)
    if flavour == "retail" then
      ctx:Expect(answers[case.name]):ToBe(case.documented)
    elseif ON_CLASSIC_METADATA then
      ctx:Expect(answers[case.name]):ToBe(case.documentedOnClassic)
    end
  end

  -- The legacy global could be answered `true` by identity only if the
  -- client aliased it to the documented C_AddOns function; log whether it is.
  local legacy = readHost("GetAddOnMetadata")
  local addOns = readHost("C_AddOns")
  local modern = type(addOns) == "table" and rawget(addOns, "GetAddOnMetadata") or nil
  ctx:Log(
    ("legacy GetAddOnMetadata global: %s; the same function as C_AddOns.GetAddOnMetadata: %s"):format(
      describeHost("GetAddOnMetadata"),
      tostring(type(legacy) == "function" and rawequal(legacy, modern))
    )
  )

  -- The direct identity the answer rests on, read without CompatKit.
  local timerNamespace = readHost("C_Timer")
  local hostTicker = type(timerNamespace) == "table" and rawget(timerNamespace, "NewTicker") or nil
  local wowRoot = rawget(namespace, "wow")
  local retailApi = type(wowRoot) == "table"
      and type(rawget(wowRoot, "retail")) == "table"
      and rawget(rawget(wowRoot, "retail"), "api")
    or nil
  local timerBindings = type(retailApi) == "table" and rawget(retailApi, "timer") or nil
  local boundTicker = type(timerBindings) == "table" and rawget(timerBindings, "newTicker") or nil
  ctx:Log(
    ("MoltenCodes.wow.retail.api.timer.newTicker is C_Timer.NewTicker: %s"):format(
      tostring(type(hostTicker) == "function" and rawequal(boundTicker, hostTicker))
    )
  )
  if flavour == "retail" then
    ctx:Expect(rawequal(boundTicker, hostTicker)):ToBe(true)
  end

  local expectedMissing = {}
  for _, apiName in ipairs(HAS_API_COVERS) do
    if not boundByFlavourFile(apiName) then
      expectedMissing[#expectedMissing + 1] = apiName
    end
  end
  local row = findShim(name) or {}
  ctx:Log("missing: " .. table.concat(type(row.missing) == "table" and row.missing or {}, ", "))
  ctx:Expect(row.status):ToBe("applied")
  ctx:Expect(row.covers):ToEqual(HAS_API_COVERS)
  ctx:Expect(row.missing):ToEqual(expectedMissing)
  local documentedMissing = HAS_API_MISSING[flavour or ""]
  if type(documentedMissing) ~= "nil" then
    ctx:Expect(row.missing):ToEqual(documentedMissing)
  end
end)

contextSuite:Test(
  "context.hasGlobal answers what raw reads of the client's global table answer: UIParent and C_Timer.NewTicker present, UIParent.GetName absent (a metatable method), a path through a number absent; Menu, MenuUtil and Settings.OpenToCategory logged",
  function(ctx)
    local answers = {}
    registerShim(ctx, nextShimPrefix() .. "hasGlobal", 1, function(context)
      for _, case in ipairs(HAS_GLOBAL_CASES) do
        answers[case.name] = context.hasGlobal(case.name)
      end
    end, { description = "no-op; asks hasGlobal" })
    applyAccounted(ctx)

    for _, case in ipairs(HAS_GLOBAL_CASES) do
      local rawAnswer = type(readHostPath(case.name)) ~= "nil"
      ctx:Log(
        ("%s: hasGlobal %s; raw read %s"):format(
          case.name,
          describe(answers[case.name]),
          describeHost(case.name)
        )
      )
      ctx:Expect(answers[case.name]):ToBe(rawAnswer)
      if type(case.expected) ~= "nil" then
        ctx:Expect(answers[case.name]):ToBe(case.expected)
      end
    end

    -- UIParent.GetName is a method all the same, which a shim reaches through
    -- ordinary indexing rather than hasGlobal.
    local uiParent = readHost("UIParent")
    ctx:Log("UIParent.GetName through its metatable: " .. type(uiParent and uiParent.GetName))
  end
)

-- compatKit.catalogue ---------------------------------------------------------------

local catalogueSuite = newSuite("catalogue")

--- The name of the first catalogue test, which states which replacements the
--- running flavour's metadata documents.
local CATALOGUE_TEST = ON_CLASSIC_METADATA
    and "CATALOGUE holds docs/EMBEDDING.md's nine rows in order; every replacementApi whose flavours list the running ApiKit flavour (C_AddOns.GetAddOnMetadata, C_SettingsUtil.OpenSettingsPanel, C_UnitAuras.GetAuraDataByIndex) is a function of this client, and C_TooltipInfo.GetUnit's leave it out (each logged)"
  or "CATALOGUE holds docs/EMBEDDING.md's nine rows in order, and every replacementApi (C_TooltipInfo.GetUnit, C_AddOns.GetAddOnMetadata, C_SettingsUtil.OpenSettingsPanel, C_UnitAuras.GetAuraDataByIndex) is a function of this client with the running ApiKit flavour in its flavours (each logged)"

---Whether `list` holds `value`.
---@param list string[]
---@param value any
---@return boolean
local function listHolds(list, value)
  for _, entry in ipairs(list) do
    if entry == value then
      return true
    end
  end
  return false
end

catalogueSuite:Test(CATALOGUE_TEST, function(ctx)
  local catalogue = CompatKit.CATALOGUE
  local flavour = apiKitFlavour()
  ctx:Expect(CompatKit.CATALOGUE_COUNT):ToBe(#CATALOGUE_SUBSYSTEMS)
  local replacementCount = 0
  for index = 1, CompatKit.CATALOGUE_COUNT do
    local row = catalogue[index]
    ctx:Expect(row.subsystem):ToBe(CATALOGUE_SUBSYSTEMS[index])
    ctx:Expect(type(row.reason)):ToBe("string")
    ctx:Expect(type(row.replacement)):ToBe("string")

    local flavours = {}
    local listsRunningFlavour = false
    for position = 1, row.flavourCount do
      flavours[position] = row.flavours[position]
      if row.flavours[position] == flavour then
        listsRunningFlavour = true
      end
    end
    local api = row.replacementApi
    if api == false then
      ctx:Log(("row %d %s: FrameXML or own frames, no documented API"):format(index, row.subsystem))
      ctx:Expect(row.flavourCount):ToBe(0)
    else
      replacementCount = replacementCount + 1
      ctx:Log(
        ("row %d %s: %s is %s on this client; flavours %s"):format(
          index,
          row.subsystem,
          api,
          describeHost(api),
          table.concat(flavours, ", ")
        )
      )
      -- docs/EMBEDDING.md names the flavours whose metadata documents the
      -- replacement; only on those must the client have it. Elsewhere what
      -- the client holds is only logged.
      local documentedFlavours = REPLACEMENT_FLAVOURS[api] or {}
      local documentedHere = listHolds(documentedFlavours, flavour)
      ctx:Expect(flavours):ToEqual(documentedFlavours)
      ctx:Expect(listsRunningFlavour):ToBe(documentedHere)
      if documentedHere then
        ctx:Expect(type(readHostPath(api))):ToBe("function")
      end
    end
  end
  ctx:Expect(replacementCount):ToBe(4)
end)

catalogueSuite:Test(
  "the FrameXML replacements the catalogue names (Menu, MenuUtil, Settings.OpenToCategory, TooltipDataProcessor.AddTooltipPostCall, UISpecialFrames) and the legacy subsystems it warns about are logged as this client has them",
  function(ctx)
    for _, name in ipairs(FRAMEXML_REPLACEMENTS) do
      ctx:Log(("replacement %s: %s"):format(name, describeHost(name)))
    end
    for _, name in ipairs(LEGACY_SUBSYSTEMS) do
      ctx:Log(("legacy %s: %s"):format(name, describeHost(name)))
    end
    local addOns = readHost("C_AddOns")
    local isAddOnLoaded = type(addOns) == "table" and rawget(addOns, "IsAddOnLoaded") or nil
    for _, blizzardAddon in ipairs(FRAMEXML_ADDONS) do
      local loaded = "unknown"
      if type(isAddOnLoaded) == "function" then
        local succeeded, answer = pcall(isAddOnLoaded, blizzardAddon)
        loaded = succeeded and describe(answer) or "raised"
      end
      ctx:Log(("%s loaded: %s"):format(blizzardAddon, loaded))
    end
    -- Only the lookups are checked: what 12.1 has is the finding.
    ctx:Expect(type(describeHost("Menu"))):ToBe("string")
  end
)

-- compatKit.failures ----------------------------------------------------------------

local failures = newSuite("failures")

failures:Test(
  "a raising shim is reported once, unchanged, through the handler seterrorhandler installed, naming CompatKitSuite.lua at the raising line; the shim after it still runs, and the failed one is never retried",
  function(ctx)
    local prefix = nextShimPrefix()
    local failingName = prefix .. "a-fails"
    local order = {}
    local raiseLine = 0
    -- The no-op is registered first: Apply orders by name, not by
    -- registration, and a refused second registration then leaves no
    -- raising shim pending for somebody else's Apply.
    registerShim(ctx, prefix .. "b-runs", 1, function()
      order[#order + 1] = "runs"
    end, { description = "no-op; runs after the failing one" })
    registerShim(ctx, failingName, 1, function()
      order[#order + 1] = "fails"
      raiseLine = currentLine() + 1
      error(SHIM_FAILURE)
    end, { description = "raises on purpose; touches nothing" })

    local reported, observed = collectReportedErrors(ctx, function()
      applyAccounted(ctx)
    end)
    requireObservedHandler(ctx, observed)
    local own = ownReports(reported, SHIM_FAILURE)
    ctx:Log(("the collector received %d report(s), %d of them this test's"):format(#reported, #own))
    ctx:Expect(#own):ToBe(1)
    expectMessageAt(ctx, own[1], raiseLine, SHIM_FAILURE)
    ctx:Expect(order):ToEqual({ "fails", "runs" })

    local failedRow = findShim(failingName) or {}
    ctx:Expect(failedRow.status):ToBe("failed")
    ctx:Expect(failedRow.applied):ToBe(false)
    ctx:Expect(failedRow.failed):ToBe(own[1])
    ctx:Expect((findShim(prefix .. "b-runs") or {}).status):ToBe("applied")

    applyAccounted(ctx)
    ctx:Expect(order):ToEqual({ "fails", "runs" })
  end
)

failures:Test(
  "a shim that calls Apply fails with 'CompatKit:Apply cannot be called from inside a shim' at its own line in CompatKitSuite.lua, is reported, and the next Apply works",
  function(ctx)
    local name = nextShimPrefix() .. "reenters"
    local applyLine = 0
    registerShim(ctx, name, 1, function()
      applyLine = currentLine() + 1
      CompatKit:Apply()
    end, { description = "calls Apply on purpose; touches nothing" })

    local reported, observed = collectReportedErrors(ctx, function()
      applyAccounted(ctx)
    end)
    requireObservedHandler(ctx, observed)
    local own = ownReports(reported, "CompatKit:Apply cannot be called from inside a shim")
    ctx:Expect(#own):ToBe(1)
    local row = findShim(name) or {}
    ctx:Expect(row.status):ToBe("failed")
    expectMessageAt(
      ctx,
      row.failed,
      applyLine,
      "CompatKit:Apply cannot be called from inside a shim"
    )

    -- The guard was cleared: Apply is callable again.
    local succeeded = pcall(CompatKit.Apply, CompatKit)
    ctx:Expect(succeeded):ToBe(true)
  end
)

-- compatKit.providers ---------------------------------------------------------------

local providersSuite = newSuite("providers")

providersSuite:Test(
  "a registry whose probes read InCombatLockdown, IsLoggedIn and the chat frame's visibility resolves the highest-priority live provider, a live preferred one, and keeps its memo; List reports each probe's host answer",
  function(ctx)
    local inCombatLockdown = readHost("InCombatLockdown")
    local isLoggedIn = readHost("IsLoggedIn")
    local chatFrame = readHost("DEFAULT_CHAT_FRAME")
    if type(inCombatLockdown) ~= "function" or type(isLoggedIn) ~= "function" then
      ctx:Fail("the client has no InCombatLockdown or IsLoggedIn")
      return
    end
    if inCombatLockdown() == true then
      Harness:SkipTest(ctx, "the player is in combat; run it out of combat")
    end

    local probes = {
      inCombat = function()
        return inCombatLockdown()
      end,
      loggedIn = function()
        return isLoggedIn()
      end,
      chatShown = function()
        return type(chatFrame) == "table" and chatFrame:IsShown()
      end,
    }
    local priorities = { inCombat = 30, loggedIn = 20, chatShown = 10, fallback = 0 }
    local cascadeOrder = { "inCombat", "loggedIn", "chatShown", "fallback" }

    local registry = CompatKit:Providers(KIND.hostFacts)
    for _, name in ipairs(cascadeOrder) do
      addProvider(ctx, registry, name, "implementation:" .. name, probes[name], priorities[name])
    end

    -- The oracle: each probe's host answer, and only `true` counts as alive.
    local alive = { fallback = true }
    for name, probe in pairs(probes) do
      local answer = probe()
      alive[name] = not isSecret(answer) and answer == true
      ctx:Log(("probe %s answers %s"):format(name, describe(answer)))
    end
    local expectedName = nil
    for _, name in ipairs(cascadeOrder) do
      if alive[name] and type(expectedName) == "nil" then
        expectedName = name
      end
    end

    local implementation, resolvedName = registry:Resolve()
    ctx:Log("Resolve() answered " .. describe(resolvedName))
    ctx:Expect(resolvedName):ToBe(expectedName)
    ctx:Expect(implementation):ToBe("implementation:" .. tostring(expectedName))
    ctx:Expect(alive.inCombat):ToBe(false)
    ctx:Expect(alive.loggedIn):ToBe(true)

    local rows = registry:List()
    ctx:Expect(rowNames(rows)):ToEqual(cascadeOrder)
    for _, row in ipairs(rows) do
      ctx:Expect(row.alive):ToBe(alive[row.name])
      ctx:Expect(row.priority):ToBe(priorities[row.name])
    end

    local preferredImplementation, preferredName = registry:Resolve("chatShown")
    if alive.chatShown then
      ctx:Expect(preferredName):ToBe("chatShown")
      ctx:Expect(preferredImplementation):ToBe("implementation:chatShown")
    else
      ctx:Expect(preferredName):ToBe(expectedName)
    end
    -- A preferred lookup leaves the memo alone, and an unknown one falls
    -- through to it.
    ctx:Expect(select(2, registry:Resolve())):ToBe(expectedName)
    ctx:Expect(select(2, registry:Resolve("MoltenCodesTest_NoSuchProvider"))):ToBe(expectedName)

    -- Unregistering the memoised provider clears the memo.
    ctx:Expect(registry:Unregister("loggedIn")):ToBe(true)
    local afterRemoval = alive.chatShown and "chatShown" or "fallback"
    ctx:Expect(select(2, registry:Resolve())):ToBe(afterRemoval)
  end
)

providersSuite:Test(
  "a raising probe is reported through the handler seterrorhandler installed, naming CompatKitSuite.lua at the raising line, once per Resolve, and counts as dead; a memo hit asks it nothing",
  function(ctx)
    local registry = CompatKit:Providers(KIND.raisingProbe)
    local raiseLine = 0
    addProvider(ctx, registry, "raising", "implementation:raising", function()
      raiseLine = currentLine() + 1
      error(PROBE_FAILURE)
    end, 10)
    addProvider(ctx, registry, "steady", "implementation:steady", nil, 0)

    local resolvedName, rows, memoName, preferredName = nil, nil, nil, nil
    local counts = {}
    local reported, observed = collectReportedErrors(ctx, function(reportedSoFar)
      resolvedName = select(2, registry:Resolve())
      counts.afterResolve = #ownReports(reportedSoFar, PROBE_FAILURE)
      memoName = select(2, registry:Resolve())
      counts.afterMemoHit = #ownReports(reportedSoFar, PROBE_FAILURE)
      rows = registry:List()
      counts.afterList = #ownReports(reportedSoFar, PROBE_FAILURE)
      preferredName = select(2, registry:Resolve("raising"))
      counts.afterPreferred = #ownReports(reportedSoFar, PROBE_FAILURE)
    end)
    requireObservedHandler(ctx, observed)

    local own = ownReports(reported, PROBE_FAILURE)
    ctx:Log(
      ("reports after Resolve %d, memo hit %d, List %d, preferred %d"):format(
        counts.afterResolve,
        counts.afterMemoHit,
        counts.afterList,
        counts.afterPreferred
      )
    )
    ctx:Expect(resolvedName):ToBe("steady")
    ctx:Expect(memoName):ToBe("steady")
    ctx:Expect(preferredName):ToBe("steady")
    ctx
      :Expect(counts)
      :ToEqual({ afterResolve = 1, afterMemoHit = 1, afterList = 2, afterPreferred = 3 })
    ctx:Expect(rows and rows[1] and rows[1].alive):ToBe(false)
    expectMessageAt(ctx, own[1], raiseLine, PROBE_FAILURE)
  end
)

providersSuite:Test(
  "Resolve on a memo hit and with a live preferred provider, probed by the client's IsLoggedIn, allocates nothing over 10000 rounds (allocation guard)",
  function(ctx)
    local isLoggedIn = readHost("IsLoggedIn")
    if type(isLoggedIn) ~= "function" then
      ctx:Fail("the client has no IsLoggedIn")
      return
    end
    local registry = CompatKit:Providers(KIND.allocation)
    addProvider(ctx, registry, "loggedIn", "implementation:loggedIn", isLoggedIn, 10)
    addProvider(ctx, registry, "fallback", "implementation:fallback", nil, 0)
    local memoName = select(2, registry:Resolve())
    ctx:Log("memo: " .. describe(memoName))

    collectgarbage("collect")
    ctx:Yield()
    -- One unmeasured call after the collection: the first one may regrow the
    -- coroutine stack.
    registry:Resolve()
    registry:Resolve("fallback")

    local before = collectgarbage("count")
    for _ = 1, ALLOCATION_ROUNDS do
      registry:Resolve()
      registry:Resolve("fallback")
    end
    local grownKilobytes = collectgarbage("count") - before

    ctx:Log(
      ("memory delta over %d rounds of 2 Resolve calls: %.3f KB"):format(
        ALLOCATION_ROUNDS,
        grownKilobytes
      )
    )
    ctx:Expect(grownKilobytes <= ALLOCATION_TOLERANCE_KB):ToBe(true)
    ctx:Expect(select(2, registry:Resolve())):ToBe(memoName)
  end
)

-- compatKit.errors ------------------------------------------------------------------

local errors = newSuite("errors")

errors:Test(
  "Shim, Apply and a registry's Resolve called with a dot name CompatKitSuite.lua at the calling line",
  function(ctx)
    ---@type any
    local untypedCompatKit = CompatKit
    local registry = CompatKit:Providers(KIND.hostFacts)
    expectErrorAtNextLine(ctx, function(lines)
      lines.start = currentLine()
      untypedCompatKit.Shim("MoltenCodesTest.CompatKit.never", 1, function() end)
    end, "CompatKit:Shim must be called on the CompatKit facade; use CompatKit:Shim(...)")
    expectErrorAtNextLine(ctx, function(lines)
      lines.start = currentLine()
      untypedCompatKit.Apply()
    end, "CompatKit:Apply must be called on the CompatKit facade; use CompatKit:Apply(...)")
    expectErrorAtNextLine(
      ctx,
      function(lines)
        lines.start = currentLine()
        registry.Resolve()
      end,
      "CompatKit.ProviderRegistry:Resolve must be called on a provider registry; use registry:Resolve(...)"
    )
  end
)

errors:Test(
  "Shim refuses a zero version, an unknown option, an empty flavours array and an invalid covers name at the calling line, and registers nothing",
  function(ctx)
    local name = "MoltenCodesTest.CompatKit.neverRegistered"
    local countBefore = #CompatKit:GetShims()
    local function noOp() end
    expectErrorAtNextLine(ctx, function(lines)
      lines.start = currentLine()
      CompatKit:Shim(name, 0, noOp)
    end, "CompatKit:Shim version must be a positive integer")
    expectErrorAtNextLine(ctx, function(lines)
      lines.start = currentLine()
      CompatKit:Shim(name, 1, noOp, { flavour = { "mainline" } })
    end, 'CompatKit:Shim options contains unknown field "flavour"')
    expectErrorAtNextLine(ctx, function(lines)
      lines.start = currentLine()
      CompatKit:Shim(name, 1, noOp, { flavours = {} })
    end, "CompatKit:Shim options.flavours must be a non-empty array of flavour ids")
    expectErrorAtNextLine(ctx, function(lines)
      lines.start = currentLine()
      CompatKit:Shim(name, 1, noOp, { covers = { "C_Timer.New-Ticker" } })
    end, "CompatKit:Shim options.covers contains an invalid API name")
    ctx:Expect(#CompatKit:GetShims()):ToBe(countBefore)
    ctx:Expect(findShim(name)):ToBeNil()
  end
)

errors:Test(
  "Providers with an empty kind, Register with a probe that is not a function or a fractional priority, and SetLimits with an unknown limit are refused at the calling line, changing nothing",
  function(ctx)
    local registry = CompatKit:Providers(KIND.hostFacts)
    local limitsBefore = CompatKit:GetLimits()
    expectErrorAtNextLine(ctx, function(lines)
      lines.start = currentLine()
      CompatKit:Providers("")
    end, "CompatKit:Providers kind must be a non-empty string")
    expectErrorAtNextLine(ctx, function(lines)
      lines.start = currentLine()
      registry:Register("refused", "implementation", "not a function")
    end, "CompatKit.ProviderRegistry:Register probe must be a function or nil")
    expectErrorAtNextLine(ctx, function(lines)
      lines.start = currentLine()
      registry:Register("refused", "implementation", nil, 1.5)
    end, "CompatKit.ProviderRegistry:Register priority must be an integer")
    expectErrorAtNextLine(ctx, function(lines)
      lines.start = currentLine()
      CompatKit:SetLimits({ maxShim = 10 })
    end, "CompatKit:SetLimits limits.maxShim is not a recognised limit")
    ctx:Expect(registry:Unregister("refused")):ToBe(false)
    ctx:Expect(CompatKit:GetLimits()):ToEqual(limitsBefore)
  end
)

errors:Test(
  "writes into the catalogue, a row, a row's flavours and a shim's context, and hasApi or hasGlobal of an empty or non-string name, are refused at the writer's or caller's line",
  function(ctx)
    local catalogue = CompatKit.CATALOGUE
    expectErrorAtNextLine(ctx, function(lines)
      lines.start = currentLine()
      catalogue[1].subsystem = "rewritten"
    end, 'CompatKit.CATALOGUE[1] is read-only; field "subsystem" cannot be written')
    expectErrorAtNextLine(ctx, function(lines)
      lines.start = currentLine()
      catalogue[4].flavours[1] = "classic-era"
    end, "CompatKit.CATALOGUE[4].flavours is read-only; field <number> cannot be written")
    expectErrorAtNextLine(ctx, function(lines)
      lines.start = currentLine()
      catalogue[10] = {}
    end, "CompatKit.CATALOGUE is read-only; field <number> cannot be written")

    local captured = {}
    local name = nextShimPrefix() .. "contextRefusals"
    registerShim(ctx, name, 1, function(context)
      captured.write = captureErrorAtNextLine(function(lines)
        lines.start = currentLine()
        context.flavour = "classic"
      end)
      captured.hasApi = captureErrorAtNextLine(function(lines)
        lines.start = currentLine()
        context.hasApi("")
      end)
      captured.hasGlobal = captureErrorAtNextLine(function(lines)
        lines.start = currentLine()
        context.hasGlobal(42)
      end)
    end, { description = "no-op; provokes refusals it catches" })
    applyAccounted(ctx)

    ctx:Expect((findShim(name) or {}).status):ToBe("applied")
    expectCapturedError(
      ctx,
      captured.write,
      'CompatKit shim context is read-only; field "flavour" cannot be written'
    )
    expectCapturedError(
      ctx,
      captured.hasApi,
      "CompatKit.ShimContext.hasApi name must be a non-empty string"
    )
    expectCapturedError(
      ctx,
      captured.hasGlobal,
      "CompatKit.ShimContext.hasGlobal name must be a non-empty string"
    )
  end
)

-- compatKit.secrets -----------------------------------------------------------------

local secrets = newSuite("secrets")

--- Why the secrets tests are skipped on a client without the two functions.
local SECRETS_SKIP_REASON =
  "the client has no issecretvalue and secretwrap; the secret path was not exercised"

---Register `body` as a test when the client can make a secret value, and as a
---skipped test naming why otherwise: it lacks the two functions, or has them
---but makes no secret (`Harness:CanMakeSecrets`).
---@param name string
---@param body fun(ctx: TestKit.Context)
local function secretTest(name, body)
  if not SECRETS_AVAILABLE then
    secrets:Skip(name, SECRETS_SKIP_REASON)
  elseif not Harness:CanMakeSecrets() then
    -- The Classic clients document both functions too; whether the client
    -- applies secrets is measured once by the harness.
    secrets:Skip(name, Harness.NO_SECRETS_REASON)
  else
    secrets:Test(name, body)
  end
end

---A genuine secret value made by the client's `secretwrap`, or a failed test.
---
---`secretwrap` is documented in the client's own API documentation
---(`Blizzard_APIDocumentationGenerated`); it wraps a plain value into a secret
---without touching any game state, so calling it has no side effect. A secret
---is only ever checked with `issecretvalue` and `type`: comparing it with a
---value of its own type, or testing it as a boolean, raises.
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
  "Shim refuses a secret name, version, description and flavour, SkipShim a secret name, Providers a secret kind and Apply a secret receiver, each at the calling line, registering nothing",
  function(ctx)
    ---@type any
    local untypedCompatKit = CompatKit
    local countBefore = #CompatKit:GetShims()
    local plainName = "MoltenCodesTest.CompatKit.neverRegistered"
    local secretName = makeSecret(ctx, plainName)
    local secretVersion = makeSecret(ctx, 1)
    local secretText = makeSecret(ctx, "description")
    local secretFlavour = makeSecret(ctx, "mainline")
    local function noOp() end

    expectErrorAtNextLine(ctx, function(lines)
      lines.start = currentLine()
      CompatKit:Shim(secretName, 1, noOp)
    end, "CompatKit:Shim name must not be a secret value")
    expectErrorAtNextLine(ctx, function(lines)
      lines.start = currentLine()
      CompatKit:Shim(plainName, secretVersion, noOp)
    end, "CompatKit:Shim version must not be a secret value")
    expectErrorAtNextLine(ctx, function(lines)
      lines.start = currentLine()
      CompatKit:Shim(plainName, 1, noOp, { description = secretText })
    end, "CompatKit:Shim options.description must not be a secret value")
    expectErrorAtNextLine(ctx, function(lines)
      lines.start = currentLine()
      CompatKit:Shim(plainName, 1, noOp, { flavours = { "mainline", secretFlavour } })
    end, "CompatKit:Shim options.flavours must not contain a secret value")
    expectErrorAtNextLine(ctx, function(lines)
      lines.start = currentLine()
      CompatKit:SkipShim(secretName)
    end, "CompatKit:SkipShim name must not be a secret value")
    expectErrorAtNextLine(ctx, function(lines)
      lines.start = currentLine()
      CompatKit:Providers(secretName)
    end, "CompatKit:Providers kind must not be a secret value")
    expectErrorAtNextLine(ctx, function(lines)
      lines.start = currentLine()
      untypedCompatKit.Apply(secretVersion)
    end, "CompatKit:Apply must be called on the CompatKit facade; use CompatKit:Apply(...)")

    ctx:Expect(#CompatKit:GetShims()):ToBe(countBefore)
    ctx:Expect(findShim(plainName)):ToBeNil()
  end
)

secretTest(
  "Register refuses a secret implementation and priority, Unregister and Resolve a secret name, and SetLimits a secret limit, each at the calling line, changing nothing",
  function(ctx)
    local registry = CompatKit:Providers(KIND.secretProbe)
    local limitsBefore = CompatKit:GetLimits()
    local secretName = makeSecret(ctx, "steady")
    local secretNumber = makeSecret(ctx, 5)

    expectErrorAtNextLine(ctx, function(lines)
      lines.start = currentLine()
      registry:Register("refused", secretName)
    end, "CompatKit.ProviderRegistry:Register implementation must not be a secret value")
    expectErrorAtNextLine(ctx, function(lines)
      lines.start = currentLine()
      registry:Register("refused", "implementation", nil, secretNumber)
    end, "CompatKit.ProviderRegistry:Register priority must not be a secret value")
    expectErrorAtNextLine(ctx, function(lines)
      lines.start = currentLine()
      registry:Unregister(secretName)
    end, "CompatKit.ProviderRegistry:Unregister name must not be a secret value")
    expectErrorAtNextLine(ctx, function(lines)
      lines.start = currentLine()
      registry:Resolve(secretName)
    end, "CompatKit.ProviderRegistry:Resolve preferred must not be a secret value")
    expectErrorAtNextLine(ctx, function(lines)
      lines.start = currentLine()
      CompatKit:SetLimits({ maxShims = secretNumber })
    end, "CompatKit:SetLimits limits.maxShims must not be a secret value")

    ctx:Expect(registry:Unregister("refused")):ToBe(false)
    ctx:Expect(CompatKit:GetLimits()):ToEqual(limitsBefore)
  end
)

secretTest(
  "context.hasApi and context.hasGlobal refuse a secret name at the shim's line in CompatKitSuite.lua",
  function(ctx)
    local secretName = makeSecret(ctx, "C_Timer.NewTicker")
    local captured = {}
    local name = nextShimPrefix() .. "secretContext"
    registerShim(ctx, name, 1, function(context)
      captured.hasApi = captureErrorAtNextLine(function(lines)
        lines.start = currentLine()
        context.hasApi(secretName)
      end)
      captured.hasGlobal = captureErrorAtNextLine(function(lines)
        lines.start = currentLine()
        context.hasGlobal(secretName)
      end)
    end, { description = "no-op; provokes refusals it catches" })
    applyAccounted(ctx)

    ctx:Expect((findShim(name) or {}).status):ToBe("applied")
    expectCapturedError(
      ctx,
      captured.hasApi,
      "CompatKit.ShimContext.hasApi name must not be a secret value"
    )
    expectCapturedError(
      ctx,
      captured.hasGlobal,
      "CompatKit.ShimContext.hasGlobal name must not be a secret value"
    )
  end
)

secretTest(
  "a shim raising a secretwrap string hands the handler the secret unchanged, and GetShims keeps it as the failed value with status 'failed'",
  function(ctx)
    local secretFailure = makeSecret(ctx, SHIM_FAILURE)
    local name = nextShimPrefix() .. "secretFailure"
    registerShim(ctx, name, 1, function()
      error(secretFailure, 0)
    end, { description = "raises a secret on purpose; touches nothing" })

    local reported, observed = collectReportedErrors(ctx, function()
      applyAccounted(ctx)
    end)
    requireObservedHandler(ctx, observed)
    local secretReports = 0
    for _, message in ipairs(reported) do
      if isSecret(message) then
        secretReports = secretReports + 1
      end
    end
    ctx:Log(("the collector received %d report(s), %d secret"):format(#reported, secretReports))
    ctx:Expect(secretReports):ToBe(1)

    local row = findShim(name) or {}
    ctx:Expect(row.status):ToBe("failed")
    ctx:Expect(isSecret(row.failed)):ToBe(true)
    ctx:Expect(type(row.failed)):ToBe("string")
  end
)

secretTest(
  "a probe answering secretwrap(true) counts as dead in Resolve and List, is never compared, and reports nothing to the error handler",
  function(ctx)
    local secretTrue = makeSecret(ctx, true)
    local registry = CompatKit:Providers(KIND.secretProbe)
    addProvider(ctx, registry, "secretAnswer", "implementation:secretAnswer", function()
      return secretTrue
    end, 10)
    addProvider(ctx, registry, "steady", "implementation:steady", nil, 0)

    local resolvedName, preferredName, rows = nil, nil, nil
    local reported, observed = collectReportedErrors(ctx, function()
      resolvedName = select(2, registry:Resolve())
      preferredName = select(2, registry:Resolve("secretAnswer"))
      rows = registry:List()
    end)
    requireObservedHandler(ctx, observed)

    ctx:Log(("the collector received %d report(s)"):format(#reported))
    ctx:Expect(resolvedName):ToBe("steady")
    ctx:Expect(preferredName):ToBe("steady")
    ctx:Expect(rowNames(rows or {})):ToEqual({ "secretAnswer", "steady" })
    ctx:Expect(rows and rows[1] and rows[1].alive):ToBe(false)
    ctx:Expect(rows and rows[2] and rows[2].alive):ToBe(true)
    ctx:Expect(#reported):ToBe(0)
  end
)
