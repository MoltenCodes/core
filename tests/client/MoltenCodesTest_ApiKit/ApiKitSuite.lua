-- MoltenCodes Test: ApiKitSuite.lua
--
-- Real-client suites for the `apiKit` package. The Busted specs under
-- packages/apiKit/tests/ prove ApiKit and every generated flavour file against
-- a stand-in host whose functions are made up; these prove, inside the game
-- client with the installed MoltenCodes addon (which loads all five flavour
-- files), what a stand-in host cannot:
--
--   * the installed facade and its committed revision;
--   * that the client's own facts (`WOW_PROJECT_ID`, and on Retail
--     `IsTestBuild()` and `IsBetaBuild()`) make `GetFlavor()` answer the
--     running flavour, that the committed metadata of that flavour names the
--     client's version, and how far its build is from the client's
--     `GetBuildInfo()` build (logged);
--   * that the short `wow` global is published, that only the running
--     flavour's `api` table (`MoltenCodes.wow.retail.api`,
--     `MoltenCodes.wow.classic.era.api` or `MoltenCodes.wow.classic.mop.api`)
--     is filled while the other four flavours' tables stay empty, and that
--     every flavour file registered its metadata;
--   * the direct-alias promise over the whole installed surface: every
--     bound function is the very host function the naming rules of
--     packages/apiKit/docs/NAMING.md derive for it (`api.timer.newTicker` is
--     `C_Timer.NewTicker`, `api.unit.name` is `UnitName`), or, for a function
--     the tables place outside its system's namespace, the host function
--     they place it at (`api.restrictedActions.inCombatLockdown` is the global
--     `InCombatLockdown`), each of whose host members must exist, with the
--     counts logged, and the host functions of a few important namespaces the
--     capture does not bind (client additions since the capture) logged;
--   * that `api.events` holds the event strings the client knows, and that
--     `api.enums` and `api.constants` are the client's own `Enum` and
--     `Constants` tables;
--   * that read-only getters called through the wrapper answer exactly what
--     the raw call answers;
--   * that looking up `api.*` tables and calling the facade's getters
--     allocates nothing, on the client's own collector;
--   * argument errors, and secret values made by the client's `secretwrap`
--     refused at the calling line in this file as the client names it.
--
-- Nothing here needs combat, a group or an instance, nothing is drawn and
-- nothing is sent. The getters called are read-only; `C_CVar.GetCVar` reads
-- one setting and changes none.
--
-- The suites run on Retail, Classic Era and Mists of Pandaria Classic. What
-- they expect of the running flavour (its metadata, its documented counts,
-- the samples and getters its committed metadata binds) is the flavour's row
-- of `FLAVOUR_EXPECTATIONS` below, chosen by `Harness:GetFlavour()`; the test
-- names that mention the flavour are built from that row.
--
-- Run with `/mct run apiKit`; tests/client/MoltenCodesTest_ApiKit/EXPECTED.md
-- lists what the chat frame should show on each flavour.
--
-- What a run leaves behind. The registration tests call `RegisterFlavor` for
-- the running flavour, which is already installed, and for flavours the client
-- does not run, passing the metadata those flavours already registered: every
-- such call is dropped and records nothing new, and no installer this file
-- hands over ever runs. Nothing is written to a global or a saved variable.

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
local API_KIT_API = 1
local PACKAGE_ID = "apiKit"

--- The file name the client puts in front of every error raised at a line of
--- this file.
local THIS_FILE = "ApiKitSuite.lua"

--- The flavour ids, in the order docs/API.md and `SUPPORTED_FLAVORS` give them.
local FLAVOR_IDS = { "retail", "classic-era", "classic-mop", "ptr", "beta" }

--- The metadata each committed flavour file registers (packages/apiKit/README.md,
--- "Flavours"; the last line of each `src/flavours/<Flavour>.lua`), and the
--- path of its `api` table under `MoltenCodes.wow`.
local COMMITTED_FLAVORS = {
  { id = "retail", version = "12.1.0", build = 69933, path = { "retail" } },
  { id = "classic-era", version = "1.15.9", build = 69722, path = { "classic", "era" } },
  { id = "classic-mop", version = "5.5.4", build = 69934, path = { "classic", "mop" } },
  { id = "ptr", version = "12.1.5", build = 69952, path = { "ptr" } },
  { id = "beta", version = "12.0.1", build = 66220, path = { "beta" } },
}

---The committed metadata row of `flavorId` in `COMMITTED_FLAVORS`.
---@param flavorId string
---@return table
local function committedFlavor(flavorId)
  for _, committed in ipairs(COMMITTED_FLAVORS) do
    if committed.id == flavorId then
      return committed
    end
  end
  error("ApiKitSuite.lua has no committed metadata row for " .. flavorId, 2)
end

--- What the suite expects of each flavour it runs on, keyed by the flavour id
--- `Harness:GetFlavour()` answers. Per flavour:
---
--- * `label` names the flavour in test names and logs, `apiPath` is the
---   dotted path of its `api` table under `MoltenCodes.wow`, `emptyPath` the
---   path of another flavour's `api` table, which stays empty on this client;
--- * `projectId` is the `WOW_PROJECT_ID` of its row in docs/API.md, "Flavour
---   detection", and `buildFactsApply` whether ApiKit consults `IsTestBuild()`
---   and `IsBetaBuild()` for it (Retail's project id alone);
--- * the counts are what the committed capture binds (packages/apiKit/README.md,
---   "Flavours", and the flavour's `metadata/<flavour>/*.json`): documented
---   namespaces, bound functions, events and enumerations. A client that lacks
---   a documented function leaves it unbound, so the installed counts may be
---   lower, never higher; the event table is written whole, so its count is
---   exact;
--- * `allocationGetters` are the two getters the second allocation test calls
---   through the wrapper; the second must answer `false` on this client.
---
--- The Classic Era and Mists of Pandaria Classic metadata do not document
--- `GetBuildInfo`, `GetTime`, `IsTestBuild`, `IsPublicBuild`,
--- `IsWindowsClient`, `IsMacClient`, `IsLoggedIn` or `UnitLevel`, so their
--- surfaces bind none of them (`RETAIL_ONLY_WRAPPERS`); every other sample
--- and getter below is documented by all three.
local FLAVOUR_EXPECTATIONS = {
  retail = {
    id = "retail",
    label = "Retail",
    path = { "retail" },
    emptyPath = { "classic", "era" },
    projectId = 1,
    buildFactsApply = true,
    namespaceCount = 312,
    functionCount = 4900,
    eventCount = 1782,
    enumCount = 844,
    allocationGetters = { { "systemTime", "getTime" }, { "build", "isTestBuild" } },
  },
  ["classic-era"] = {
    id = "classic-era",
    label = "Classic Era",
    path = { "classic", "era" },
    emptyPath = { "retail" },
    projectId = 2,
    buildFactsApply = false,
    namespaceCount = 261,
    functionCount = 3229,
    eventCount = 1483,
    enumCount = 740,
    allocationGetters = { { "locale", "getLocale" }, { "build", "isBetaBuild" } },
  },
  ["classic-mop"] = {
    id = "classic-mop",
    label = "Mists of Pandaria Classic",
    path = { "classic", "mop" },
    emptyPath = { "retail" },
    projectId = 19,
    buildFactsApply = false,
    namespaceCount = 261,
    functionCount = 3230,
    eventCount = 1483,
    enumCount = 740,
    allocationGetters = { { "locale", "getLocale" }, { "build", "isBetaBuild" } },
  },
}

--- The expectations of the running flavour. A client the harness does not
--- map to a promised flavour is held to Retail's, so every flavour-dependent
--- test fails there visibly instead of passing for the wrong reason.
local RUNNING = FLAVOUR_EXPECTATIONS[Harness:GetFlavour() or "retail"]
  or FLAVOUR_EXPECTATIONS.retail
RUNNING.committed = committedFlavor(RUNNING.id)
RUNNING.apiPath = table.concat(RUNNING.path, ".")

--- The wrapper paths only the Retail metadata documents (see
--- `FLAVOUR_EXPECTATIONS`): the samples and getters naming them are checked
--- on Retail only.
local RETAIL_ONLY_WRAPPERS = {
  ["build.getBuildInfo"] = true,
  ["build.isTestBuild"] = true,
  ["build.isPublicBuild"] = true,
  ["build.isWindowsClient"] = true,
  ["build.isMacClient"] = true,
  ["playerScript.isLoggedIn"] = true,
  ["systemTime.getTime"] = true,
  ["unit.level"] = true,
}

---Whether the running flavour's metadata documents the wrapper
---`namespaceName.functionName`, so its surface binds it where the client has it.
---@param namespaceName string
---@param functionName string
---@return boolean
local function documentedOnRunningFlavour(namespaceName, functionName)
  return RUNNING.id == "retail" or not RETAIL_ONLY_WRAPPERS[namespaceName .. "." .. functionName]
end

--- The three data tables of a flavour's surface; every other key of `api` is a
--- function namespace.
local DATA_TABLE_NAMES = { events = true, enums = true, constants = true }

--- The reviewed namespace aliases of tooling/api/naming.json: alias to the
--- systematic name whose table it shares (packages/apiKit/docs/NAMING.md, rule 7).
local NAMESPACE_ALIASES = { profiler = "addOnProfiler" }

--- The bindings the naming rules cannot derive: functions the client's
--- documentation tables place outside their system's namespace with their own
--- `Namespace` attribute (packages/apiKit/docs/NAMING.md, rule 3). Each is
--- wrapper namespace, wrapper function, host table (nil for a global) and host
--- function, exactly the `wrapper` and `binding` of
--- packages/apiKit/metadata/retail/namespaces.json;
--- tooling/tests/test_api_committed_flavours.py holds this list to that file.
--- The committed Classic Era and Mists of Pandaria Classic metadata relocate
--- the same seven functions to the same host paths.
--- The identity walk resolves these from here, and reports every one whose
--- host member is missing or whose wrapper is not bound.
local RELOCATED_BINDINGS = {
  {
    "localization",
    "getDefaultAbbreviationBreakpoints",
    "C_StringUtil",
    "GetDefaultAbbreviationBreakpoints",
  },
  { "restrictedActions", "inCombatLockdown", nil, "InCombatLockdown" },
  { "stringUtil", "trim", "string", "trim" },
  { "tableUtil", "count", "table", "count" },
  { "tableUtil", "create", "table", "create" },
  { "tableUtil", "freeze", "table", "freeze" },
  { "tableUtil", "isfrozen", "table", "isfrozen" },
}

--- Host namespaces whose unbound functions the additions test logs: the ones
--- addons reach for most, and the ones the framework's own Kits call.
local WATCHED_HOST_NAMESPACES = {
  "C_Timer",
  "C_AddOns",
  "C_Spell",
  "C_Item",
  "C_UnitAuras",
  "C_Map",
  "C_ChatInfo",
  "C_EncodingUtil",
  "C_CVar",
  "C_Container",
  "C_EventUtils",
  "C_DateAndTime",
}

--- TestKit keeps at most 256 bytes of a log line (packages/testKit/docs/API.md,
--- `ctx:Log`), so a list of names is spread over lines of at most this many
--- bytes, and one list takes at most `LOG_LIST_MAX_LINES` of the 64 lines a
--- test may log.
local LOG_LINE_BYTES = 240
local LOG_LIST_MAX_LINES = 4

--- How many lookups each allocation guard measures, and the kilobytes it
--- tolerates. One table per lookup would cost well over a hundred kilobytes;
--- the tolerance absorbs a stray allocation by the client between two readings.
local ALLOCATION_CALLS = 2000
local ALLOCATION_TOLERANCE_KB = 1

-- Resolving the client and the framework ---------------------------------------------

---Read a client global, or `nil`.
---@param name string
---@return any
local function readHost(name)
  -- WOW_PROJECT_ID, the build probes, the C_ namespaces, Enum, Constants and
  -- the secret-value functions are World of Warcraft client globals,
  -- reachable only through the global table.
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

---Read a global function of the client, or `nil`.
---@param name string
---@return function|nil
local function readHostFunction(name)
  local candidate = readHost(name)
  if type(candidate) ~= "function" then
    return nil
  end
  return candidate
end

---The client's global table, handed to the surface walk as the host.
---@return table
local function hostTable()
  -- The walk compares the installed surface with every client global.
  -- selene: allow(global_usage)
  return _G
end

---@type Registry
local Registry = rawget(rawget(namespace, "Registries") or {}, REGISTRY_API)
if type(Registry) ~= "table" then
  error(addonName .. " requires the MoltenCodes addon (Registry API 2); reinstall it", 0)
end

-- ApiKit is not in the language-server workspace of tests/client (its
-- .luarc.json lists TestKit's dependency closure only), so its facade is
-- typed `any` here.

---@type any
local ApiKit = Registry:Get(PACKAGE_ID, API_KIT_API)
if type(ApiKit) == "nil" then
  error(addonName .. " requires ApiKit API 1 in the MoltenCodes addon; reinstall it", 0)
end

--- Read once at load: the secrets suite registers its tests as skipped when
--- the client cannot make a secret value, because it lacks the two functions
--- or because it has them but `secretwrap` makes no secret (the Classic
--- clients document both; the harness measures whether they work).
local isSecretValue = readHost("issecretvalue")
local secretWrap = readHost("secretwrap")
local SECRET_FUNCTIONS_PRESENT = type(isSecretValue) == "function"
  and type(secretWrap) == "function"
local SECRETS_AVAILABLE = SECRET_FUNCTIONS_PRESENT and Harness:CanMakeSecrets()

---Whether `value` is a secret; `false` on a client without secret values.
---@param value any
---@return boolean
local function isSecret(value)
  return type(isSecretValue) == "function" and isSecretValue(value) == true
end

---The namespace root, `MoltenCodes.wow`.
---@return table|nil
local function namespaceRoot()
  local root = rawget(namespace, "wow")
  if type(root) ~= "table" then
    return nil
  end
  return root
end

---The `api` table of a flavour, reached through its path under the root, or
---`nil` when a segment is missing.
---@param path string[]
---@return table|nil
local function flavorApi(path)
  local node = namespaceRoot()
  for index = 1, #path do
    if type(node) ~= "table" then
      return nil
    end
    node = rawget(node, path[index])
  end
  if type(node) ~= "table" then
    return nil
  end
  local api = rawget(node, "api")
  if type(api) ~= "table" then
    return nil
  end
  return api
end

---The installed surface of the running flavour, `MoltenCodes.wow.retail.api`
---on Retail.
---@return table|nil
local function runningApi()
  return flavorApi(RUNNING.path)
end

--- The failure message of a test that finds no installed surface.
local NO_RUNNING_API = ("MoltenCodes.wow.%s.api is not a table"):format(RUNNING.apiPath)

-- Log helpers ------------------------------------------------------------------------------

---Sort `names` in place and join them, or `"none"`.
---@param names string[]
---@return string
local function joinNames(names)
  if #names == 0 then
    return "none"
  end
  table.sort(names)
  return table.concat(names, ", ")
end

---Log `heading` and the sorted `names` over as many lines as TestKit's line
---limit needs, at most `maxLines` (default `LOG_LIST_MAX_LINES`); the last
---line says how many names did not fit.
---@param ctx TestKit.Context
---@param heading string
---@param names string[]
---@param maxLines integer|nil
local function logNames(ctx, heading, names, maxLines)
  local lineLimit = maxLines or LOG_LIST_MAX_LINES
  if #names == 0 then
    ctx:Log(heading .. ": none")
    return
  end
  table.sort(names)
  local prefix = heading .. ": "
  local line = prefix
  local linesLogged = 0
  local index = 1
  while index <= #names do
    local name = names[index]
    local separator = line == prefix and "" or ", "
    if #line + #separator + #name > LOG_LINE_BYTES and line ~= prefix then
      if linesLogged + 1 == lineLimit then
        break
      end
      ctx:Log(line)
      linesLogged = linesLogged + 1
      prefix = heading .. " (continued): "
      line = prefix
    else
      line = line .. separator .. name
      index = index + 1
    end
  end
  if index <= #names then
    line = line .. (" (+%d more)"):format(#names - index + 1)
  end
  ctx:Log(line)
end

---How many keys `value` holds.
---@param value table
---@return integer
local function countKeys(value)
  local count = 0
  for _ in pairs(value) do
    count = count + 1
  end
  return count
end

-- Surface walking ---------------------------------------------------------------------------
--
-- The naming rules (packages/apiKit/docs/NAMING.md) only change the case of
-- a Blizzard name's words and drop underscores, the `C_` prefix of a
-- namespace, and, for a global function, its system's words at the front. So
-- a wrapper name and its Blizzard name agree once both are lowercased and
-- stripped of underscores: `newTicker` and `NewTicker`, `timer` and `C_Timer`,
-- `unit` + `name` and `UnitName`. The walk derives each binding's host path
-- from that, looks the path up in the live client and compares the two
-- functions by identity. The committed rules have no exceptions
-- (tooling/api/naming.json), so every binding must resolve. The one place the
-- host path is not derived from the names is `RELOCATED_BINDINGS`: a function
-- the tables place outside its system's namespace is looked up where they
-- place it, and the walk reports each of those whose host member is missing.

---The host path of a relocated binding, `table.count` or `InCombatLockdown`.
---@param relocated table one entry of `RELOCATED_BINDINGS`
---@return string
local function relocatedHostPath(relocated)
  if type(relocated[3]) == "nil" then
    return relocated[4]
  end
  return relocated[3] .. "." .. relocated[4]
end

---The host function a relocated binding names, or `nil` when the client lacks it.
---@param host table the client's global table
---@param relocated table one entry of `RELOCATED_BINDINGS`
---@return any
local function relocatedHostValue(host, relocated)
  if type(relocated[3]) == "nil" then
    return host[relocated[4]]
  end
  local holder = host[relocated[3]]
  if type(holder) ~= "table" then
    return nil
  end
  return holder[relocated[4]]
end

---`RELOCATED_BINDINGS` keyed by wrapper path, `restrictedActions.inCombatLockdown`.
---@return table<string, table>
local function indexRelocatedBindings()
  local index = {}
  for position = 1, #RELOCATED_BINDINGS do
    local relocated = RELOCATED_BINDINGS[position]
    index[relocated[1] .. "." .. relocated[2]] = relocated
  end
  return index
end

---A name lowercased with its underscores removed: the form in which a wrapper
---name and its Blizzard name are equal.
---@param name string
---@return string
local function foldName(name)
  return (name:gsub("_", "")):lower()
end

---Index the host once: its `C_` namespace tables by folded name without the
---prefix, and its global functions by folded name. Two globals that fold to
---the same name are kept as a list.
---@param host table the client's global table
---@return { namespaces: table<string, string>, globals: table<string, string|string[]> }
local function indexHost(host)
  local namespaces = {}
  local globals = {}
  for key, value in pairs(host) do
    if type(key) == "string" then
      local valueType = type(value)
      if valueType == "table" and key:sub(1, 2) == "C_" then
        namespaces[foldName(key:sub(3))] = key
      elseif valueType == "function" then
        local folded = foldName(key)
        local existing = globals[folded]
        if type(existing) == "nil" then
          globals[folded] = key
        elseif type(existing) == "string" then
          globals[folded] = { existing, key }
        else
          existing[#existing + 1] = key
        end
      end
    end
  end
  return { namespaces = namespaces, globals = globals }
end

---The functions of one host namespace table by folded name.
---@param hostNamespace table
---@return table<string, string>
local function indexNamespaceFunctions(hostNamespace)
  local functions = {}
  for key, value in pairs(hostNamespace) do
    if type(key) == "string" and type(value) == "function" then
      functions[foldName(key)] = key
    end
  end
  return functions
end

---Append every global name `folded` names in the index to `candidates`.
---@param index table the result of `indexHost`
---@param folded string
---@param candidates string[]
local function appendGlobalCandidates(index, folded, candidates)
  local names = index.globals[folded]
  if type(names) == "string" then
    candidates[#candidates + 1] = names
  elseif type(names) == "table" then
    for position = 1, #names do
      candidates[#candidates + 1] = names[position]
    end
  end
end

---Resolve one binding against the host by the naming rules: the function of
---the matching `C_` namespace first, then the global named by the system's
---words and the function's (rule 4, prefix dropped), then the global named by
---the function alone (rule 4, whole name kept).
---@param host table
---@param index table the result of `indexHost`
---@param namespaceFunctionIndexes table<string, table<string, string>> filled lazily per host namespace
---@param namespaceName string the wrapper namespace, `timer`
---@param functionName string the wrapper function, `newTicker`
---@param bound function what the wrapper holds
---@return "match"|"mismatch"|"unresolved" outcome
---@return string hostPath the host path that matched, or the candidates tried
local function resolveBinding(
  host,
  index,
  namespaceFunctionIndexes,
  namespaceName,
  functionName,
  bound
)
  local foldedNamespace = foldName(namespaceName)
  local foldedFunction = foldName(functionName)
  local tried = {}

  local hostNamespaceName = index.namespaces[foldedNamespace]
  if type(hostNamespaceName) == "string" then
    local functions = namespaceFunctionIndexes[hostNamespaceName]
    if type(functions) == "nil" then
      functions = indexNamespaceFunctions(host[hostNamespaceName])
      namespaceFunctionIndexes[hostNamespaceName] = functions
    end
    local hostFunctionName = functions[foldedFunction]
    if type(hostFunctionName) == "string" then
      local path = hostNamespaceName .. "." .. hostFunctionName
      if rawequal(host[hostNamespaceName][hostFunctionName], bound) then
        return "match", path
      end
      tried[#tried + 1] = path
    end
  end

  local candidates = {}
  appendGlobalCandidates(index, foldedNamespace .. foldedFunction, candidates)
  appendGlobalCandidates(index, foldedFunction, candidates)
  for position = 1, #candidates do
    local candidate = candidates[position]
    if rawequal(host[candidate], bound) then
      return "match", candidate
    end
    tried[#tried + 1] = candidate
  end

  if #tried == 0 then
    return "unresolved", "no host name folds to " .. namespaceName .. "." .. functionName
  end
  return "mismatch", table.concat(tried, " or ")
end

---Walk every function namespace of `api` and resolve each binding against
---`host`. An alias namespace (`profiler`) is skipped: it is the same table as
---its systematic namespace, which the walk visits.
---@param api table an installed flavour surface
---@param host table the client's global table
---@return table report counts, and the wrapper paths of every problem
local function walkSurface(api, host)
  local index = indexHost(host)
  local relocatedIndex = indexRelocatedBindings()
  local namespaceFunctionIndexes = {}
  local report = {
    namespaces = 0,
    functions = 0,
    fromNamespaces = 0,
    fromGlobals = 0,
    relocated = 0,
    bound = {},
    mismatches = {},
    unresolved = {},
    notFunctions = {},
    notTables = {},
    missingHostMembers = {},
    unboundRelocated = {},
  }
  for namespaceName, target in pairs(api) do
    if not DATA_TABLE_NAMES[namespaceName] and type(NAMESPACE_ALIASES[namespaceName]) == "nil" then
      if type(target) ~= "table" then
        report.notTables[#report.notTables + 1] = tostring(namespaceName)
      else
        report.namespaces = report.namespaces + 1
        for functionName, bound in pairs(target) do
          local wrapperPath = namespaceName .. "." .. tostring(functionName)
          if type(bound) ~= "function" then
            report.notFunctions[#report.notFunctions + 1] = wrapperPath
          else
            report.functions = report.functions + 1
            report.bound[bound] = wrapperPath
            local outcome, hostPath
            local relocated = relocatedIndex[wrapperPath]
            if type(relocated) ~= "nil" then
              hostPath = relocatedHostPath(relocated)
              outcome = rawequal(relocatedHostValue(host, relocated), bound) and "match"
                or "mismatch"
            else
              outcome, hostPath = resolveBinding(
                host,
                index,
                namespaceFunctionIndexes,
                namespaceName,
                functionName,
                bound
              )
            end
            if outcome == "match" then
              if hostPath:find(".", 1, true) then
                report.fromNamespaces = report.fromNamespaces + 1
              else
                report.fromGlobals = report.fromGlobals + 1
              end
            elseif outcome == "mismatch" then
              report.mismatches[#report.mismatches + 1] = wrapperPath .. " is not " .. hostPath
            else
              report.unresolved[#report.unresolved + 1] = wrapperPath .. " (" .. hostPath .. ")"
            end
          end
        end
      end
    end
  end
  -- A binding whose host member is missing leaves its wrapper unbound, which
  -- the walk above cannot see; for the relocated bindings the host path is
  -- known, so each is checked from the host's side too.
  for position = 1, #RELOCATED_BINDINGS do
    local relocated = RELOCATED_BINDINGS[position]
    local wrapperPath = relocated[1] .. "." .. relocated[2]
    local hostValue = relocatedHostValue(host, relocated)
    local target = api[relocated[1]]
    local bound = type(target) == "table" and target[relocated[2]] or nil
    if type(hostValue) ~= "function" then
      report.missingHostMembers[#report.missingHostMembers + 1] = wrapperPath
        .. " ("
        .. relocatedHostPath(relocated)
        .. " is "
        .. type(hostValue)
        .. ")"
    elseif type(bound) == "nil" then
      report.unboundRelocated[#report.unboundRelocated + 1] = wrapperPath
        .. " ("
        .. relocatedHostPath(relocated)
        .. " is a function)"
    else
      report.relocated = report.relocated + 1
    end
  end
  return report
end

---Every host path holding `bound`, searched over the globals and the `C_`
---namespaces, for a failure's log.
---@param host table
---@param bound function
---@return string[]
local function findHostPaths(host, bound)
  local paths = {}
  for key, value in pairs(host) do
    if type(key) == "string" then
      if rawequal(value, bound) then
        paths[#paths + 1] = key
      elseif type(value) == "table" and key:sub(1, 2) == "C_" then
        for member, memberValue in pairs(value) do
          if rawequal(memberValue, bound) then
            paths[#paths + 1] = key .. "." .. tostring(member)
          end
        end
      end
    end
  end
  return paths
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
  ctx:Expect((file or ""):sub(-#THIS_FILE)):ToBe(THIS_FILE)
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

-- Registration probes -------------------------------------------------------------------------

---An installer that only counts its calls; no test expects it to run.
---@return fun(api: table, host: table) installer
---@return fun(): integer calls
local function countingInstaller()
  local calls = 0
  return function()
    calls = calls + 1
  end, function()
    return calls
  end
end

---The `info` a registration of `flavor` may pass without changing what
---`GetMetadataBuild` reports: exactly what that flavour already registered,
---or `nil` when nothing did (a registration without `info` records none).
---@param flavor string
---@return table|nil
local function registeredInfo(flavor)
  local version, build = ApiKit:GetMetadataBuild(flavor)
  if type(version) == "nil" and type(build) == "nil" then
    return nil
  end
  return { version = version, build = build }
end

-- Allocation ----------------------------------------------------------------------------------

---Collect in a step of its own, so the measurement that follows starts far
---from the next collector cycle, run one unmeasured warm-up call (the first
---call after a full collection can regrow the coroutine stack), then run
---`operation` `ALLOCATION_CALLS` times, log how far the heap grew and hold it
---to the tolerance.
---@param ctx TestKit.Context
---@param label string what `operation` does, for the log
---@param operation fun()
local function expectNoAllocation(ctx, label, operation)
  collectgarbage("collect")
  ctx:Yield()
  operation()
  local before = collectgarbage("count")
  for _ = 1, ALLOCATION_CALLS do
    operation()
  end
  local grownKilobytes = collectgarbage("count") - before
  ctx:Log(
    ("memory delta over %d calls of %s: %.3f KB"):format(ALLOCATION_CALLS, label, grownKilobytes)
  )
  ctx:Expect(grownKilobytes <= ALLOCATION_TOLERANCE_KB):ToBe(true)
end

-- apiKit.facade ---------------------------------------------------------------------------------

local facade = Harness:Suite(PACKAGE_ID, "facade", addonName)

facade:Test(
  "Registry:Get('apiKit', 1) is the ApiKit facade with API 1, its four methods and the five SUPPORTED_FLAVORS in table order",
  function(ctx)
    ctx:Expect(type(ApiKit)):ToBe("table")
    ctx:Expect(rawget(ApiKit, "API")):ToBe(API_KIT_API)
    for _, methodName in ipairs({
      "GetFlavor",
      "GetGlobalStatus",
      "RegisterFlavor",
      "GetMetadataBuild",
    }) do
      ctx:Expect(type(ApiKit[methodName])):ToBe("function")
    end
    ctx:Expect(ApiKit.SUPPORTED_FLAVOR_COUNT):ToBe(#FLAVOR_IDS)
    local listed = {}
    for index = 1, ApiKit.SUPPORTED_FLAVOR_COUNT do
      listed[index] = ApiKit.SUPPORTED_FLAVORS[index]
    end
    ctx:Log("SUPPORTED_FLAVORS: " .. table.concat(listed, ", "))
    ctx:Expect(listed):ToEqual(FLAVOR_IDS)
  end
)

facade:Test("the installed ApiKit carries the revision of the committed manifest", function(ctx)
  local expectedPackages = Harness:GetExpectedPackages()
  if type(expectedPackages) == "nil" then
    ctx:Fail("Expected.lua is missing; install with python3 -m tooling.client.install")
    return
  end
  for _, expected in ipairs(expectedPackages) do
    if expected.id == PACKAGE_ID then
      local _, revision = Registry:Get(PACKAGE_ID, API_KIT_API)
      ctx:Expect(revision):ToBe(expected.revision)
      ctx:Expect(rawget(ApiKit, "REVISION")):ToBe(expected.revision)
      return
    end
  end
  ctx:Fail("Expected.lua does not list apiKit")
end)

-- apiKit.flavour --------------------------------------------------------------------------------

local flavour = Harness:Suite(PACKAGE_ID, "flavour", addonName)

---Call a boolean build probe of the client and describe the answer for the log.
---@param name string
---@return any answer what the probe returned, or `nil` when it is absent
---@return string description
local function probeBuild(name)
  local probe = readHostFunction(name)
  if type(probe) == "nil" then
    return nil, name .. "() absent"
  end
  local answer = probe()
  return answer, name .. "() " .. tostring(answer)
end

--- The name of the detection test: Retail's row needs both build probes to
--- answer `false`; a Classic project id maps without them (docs/API.md,
--- "Flavour detection").
local DETECTION_TEST_NAME = RUNNING.buildFactsApply
    and ("GetFlavor() is '%s' because the client reports WOW_PROJECT_ID %d and neither IsTestBuild() nor IsBetaBuild(); the facts are logged"):format(
      RUNNING.id,
      RUNNING.projectId
    )
  or ("GetFlavor() is '%s' because the client reports WOW_PROJECT_ID %d, which ApiKit maps without consulting IsTestBuild() or IsBetaBuild(); the facts are logged"):format(
    RUNNING.id,
    RUNNING.projectId
  )

flavour:Test(DETECTION_TEST_NAME, function(ctx)
  local projectId = readHost("WOW_PROJECT_ID")
  local testBuild, testDescription = probeBuild("IsTestBuild")
  local betaBuild, betaDescription = probeBuild("IsBetaBuild")
  local _, publicTestDescription = probeBuild("IsPublicTestClient")
  ctx:Log(
    ("WOW_PROJECT_ID %s, WOW_PROJECT_MAINLINE %s, %s, %s, %s"):format(
      tostring(projectId),
      tostring(readHost("WOW_PROJECT_MAINLINE")),
      testDescription,
      betaDescription,
      publicTestDescription
    )
  )
  ctx:Log("ApiKit:GetFlavor(): " .. tostring(ApiKit:GetFlavor()))
  ctx:Expect(projectId):ToBe(RUNNING.projectId)
  if RUNNING.buildFactsApply then
    ctx:Expect(testBuild == true):ToBe(false)
    ctx:Expect(betaBuild == true):ToBe(false)
  end
  ctx:Expect(ApiKit:GetFlavor()):ToBe(RUNNING.id)
end)

flavour:Test(
  ("GetMetadataBuild('%s') is %s build %d and names the client's own GetBuildInfo() version; the two builds are logged side by side"):format(
    RUNNING.id,
    RUNNING.committed.version,
    RUNNING.committed.build
  ),
  function(ctx)
    local version, build = ApiKit:GetMetadataBuild(RUNNING.id)
    local getBuildInfo = readHostFunction("GetBuildInfo")
    if type(getBuildInfo) == "nil" then
      ctx:Fail("the client has no GetBuildInfo")
      return
    end
    local clientVersion, clientBuild, clientDate, interfaceVersion = getBuildInfo()
    ctx:Log(("metadata: version %s, build %s"):format(tostring(version), tostring(build)))
    ctx:Log(
      ("GetBuildInfo(): version %s, build %s, date %s, interface %s"):format(
        tostring(clientVersion),
        tostring(clientBuild),
        tostring(clientDate),
        tostring(interfaceVersion)
      )
    )
    local clientBuildNumber = tonumber(clientBuild)
    if type(clientBuildNumber) == "number" and type(build) == "number" then
      if clientBuildNumber == build then
        ctx:Log(
          ("the client runs the build the %s metadata was captured from"):format(RUNNING.label)
        )
      else
        ctx:Log(
          ("the client build is %d builds %s the metadata build"):format(
            math.abs(clientBuildNumber - build),
            clientBuildNumber > build and "after" or "before"
          )
        )
      end
    end
    ctx:Expect(version):ToBe(RUNNING.committed.version)
    ctx:Expect(build):ToBe(RUNNING.committed.build)
    ctx:Expect(clientVersion):ToBe(version)
  end
)

flavour:Test(
  "all five flavour files of the bundle registered their metadata: GetMetadataBuild answers the committed version and build of every flavour, installed or not",
  function(ctx)
    for _, committed in ipairs(COMMITTED_FLAVORS) do
      local version, build = ApiKit:GetMetadataBuild(committed.id)
      ctx:Log(("%s: version %s, build %s"):format(committed.id, tostring(version), tostring(build)))
      ctx:Expect(version):ToBe(committed.version)
      ctx:Expect(build):ToBe(committed.build)
    end
  end
)

-- apiKit.namespaces ------------------------------------------------------------------------------

local namespaces = Harness:Suite(PACKAGE_ID, "namespaces", addonName)

namespaces:Test(
  "GetGlobalStatus() is 'published' and the wow global is MoltenCodes.wow itself",
  function(ctx)
    local root = namespaceRoot()
    local shortGlobal = readHost("wow")
    local status = ApiKit:GetGlobalStatus()
    ctx:Log(
      ("GetGlobalStatus(): %s; wow global: %s; MoltenCodes.wow: %s; the same table: %s"):format(
        tostring(status),
        type(shortGlobal),
        type(root),
        tostring(type(root) == "table" and rawequal(shortGlobal, root))
      )
    )
    ctx:Expect(type(root)):ToBe("table")
    ctx:Expect(status):ToBe("published")
    ctx:Expect(shortGlobal):ToBe(root)
  end
)

namespaces:Test(
  ("MoltenCodes.wow holds retail, classic.era, classic.mop, ptr and beta, and only %s.api is filled: the four other api tables are empty"):format(
    RUNNING.apiPath
  ),
  function(ctx)
    local root = namespaceRoot()
    if type(root) == "nil" then
      ctx:Fail("MoltenCodes.wow is not a table")
      return
    end
    local rootKeys = {}
    for key in pairs(root) do
      rootKeys[#rootKeys + 1] = tostring(key)
    end
    local rootKeyList = joinNames(rootKeys)
    ctx:Log("MoltenCodes.wow keys: " .. rootKeyList)
    ctx:Expect(rootKeyList):ToBe("beta, classic, ptr, retail")
    local classic = rawget(root, "classic")
    ctx:Expect(type(classic)):ToBe("table")
    local classicKeys = {}
    for key in pairs(classic or {}) do
      classicKeys[#classicKeys + 1] = tostring(key)
    end
    ctx:Expect(joinNames(classicKeys)):ToBe("era, mop")

    for _, committed in ipairs(COMMITTED_FLAVORS) do
      local api = flavorApi(committed.path)
      local keyCount = type(api) == "table" and countKeys(api) or -1
      ctx:Log(
        ("MoltenCodes.wow.%s.api: %s with %d keys"):format(
          table.concat(committed.path, "."),
          type(api),
          keyCount
        )
      )
      ctx:Expect(type(api)):ToBe("table")
      if committed.id == RUNNING.id then
        ctx:Expect(keyCount > 0):ToBe(true)
      else
        ctx:Expect(keyCount):ToBe(0)
      end
    end
  end
)

-- apiKit.bindings ---------------------------------------------------------------------------------

local bindings = Harness:Suite(PACKAGE_ID, "bindings", addonName)

bindings:Test(
  ("every function of the installed %s surface is the very host function the naming rules name: C_ namespace members and global functions compared by identity, every relocated binding's host member present, counts logged"):format(
    RUNNING.label
  ),
  function(ctx)
    local api = runningApi()
    if type(api) == "nil" then
      ctx:Fail(NO_RUNNING_API)
      return
    end
    local host = hostTable()
    local report = walkSurface(api, host)
    ctx:Log(
      ("installed: %d namespaces (documented %d), %d functions bound (documented %d): %d from C_ namespaces, %d global functions"):format(
        report.namespaces,
        RUNNING.namespaceCount,
        report.functions,
        RUNNING.functionCount,
        report.fromNamespaces,
        report.fromGlobals
      )
    )
    ctx:Log(
      ("documented functions this client lacks, so unbound: %d"):format(
        RUNNING.functionCount - report.functions
      )
    )
    ctx:Log(
      ("relocated bindings (their own Namespace attribute): %d of %d bound"):format(
        report.relocated,
        #RELOCATED_BINDINGS
      )
    )
    logNames(ctx, "bindings that are not the named host function", report.mismatches)
    logNames(ctx, "bindings no host name resolves", report.unresolved)
    logNames(ctx, "relocated bindings whose host member is missing", report.missingHostMembers)
    logNames(ctx, "relocated bindings the surface lacks", report.unboundRelocated)
    logNames(ctx, "namespace entries that are not tables", report.notTables)
    logNames(ctx, "namespace members that are not functions", report.notFunctions)
    for position = 1, math.min(#report.unresolved, 5) do
      local wrapperPath = report.unresolved[position]:match("^(%S+)")
      local namespaceName, functionName = wrapperPath:match("^([^.]+)%.(.+)$")
      local bound = api[namespaceName][functionName]
      logNames(ctx, wrapperPath .. " is found at", findHostPaths(host, bound), 1)
    end

    ctx:Expect(#report.mismatches):ToBe(0)
    ctx:Expect(#report.unresolved):ToBe(0)
    ctx:Expect(#report.notTables):ToBe(0)
    ctx:Expect(#report.notFunctions):ToBe(0)
    ctx:Expect(#report.missingHostMembers):ToBe(0)
    ctx:Expect(#report.unboundRelocated):ToBe(0)
    ctx:Expect(report.relocated):ToBe(#RELOCATED_BINDINGS)
    ctx:Expect(report.functions > 0):ToBe(true)
    ctx:Expect(report.functions <= RUNNING.functionCount):ToBe(true)
    ctx:Expect(report.namespaces <= RUNNING.namespaceCount):ToBe(true)
    ctx:Expect(report.fromNamespaces + report.fromGlobals):ToBe(report.functions)
  end
)

--- The name of the samples test: the Retail name cites api.build.getBuildInfo,
--- which the Classic metadata does not document, so a Classic client's name
--- cites api.locale.getLocale instead.
local SAMPLES_TEST_NAME = RUNNING.id == "retail"
    and "named samples are the host's own functions: api.timer.newTicker is C_Timer.NewTicker, api.unit.name is UnitName, api.build.getBuildInfo is GetBuildInfo, api.restrictedActions.inCombatLockdown is InCombatLockdown, and api.profiler is api.addOnProfiler"
  or "named samples are the host's own functions: api.timer.newTicker is C_Timer.NewTicker, api.unit.name is UnitName, api.locale.getLocale is GetLocale, api.restrictedActions.inCombatLockdown is InCombatLockdown, and api.profiler is api.addOnProfiler"

bindings:Test(SAMPLES_TEST_NAME, function(ctx)
  local api = runningApi()
  if type(api) == "nil" then
    ctx:Fail(NO_RUNNING_API)
    return
  end
  -- Each pair is a `wrapper` and `binding` of the Retail metadata
  -- (packages/apiKit/metadata/retail/namespaces.json); a Classic client
  -- checks the ten its metadata documents too (`RETAIL_ONLY_WRAPPERS`).
  -- api.restrictedActions.inCombatLockdown is the global InCombatLockdown:
  -- the tables document it in the C_RestrictedActions system with
  -- `Namespace = ""`, and the metadata binds it by that attribute
  -- (CHANGELOG 0.1.4; the run of 2026-09-25 found the wrapper nil).
  local samples = {
    { "timer", "newTicker", "C_Timer", "NewTicker" },
    { "timer", "after", "C_Timer", "After" },
    { "addOns", "getNumAddOns", "C_AddOns", "GetNumAddOns" },
    { "cvar", "getCVar", "C_CVar", "GetCVar" },
    { "eventUtils", "isEventValid", "C_EventUtils", "IsEventValid" },
    { "map", "getBestMapForUnit", "C_Map", "GetBestMapForUnit" },
    { "restrictedActions", "inCombatLockdown", nil, "InCombatLockdown" },
    { "unit", "name", nil, "UnitName" },
    { "unit", "class", nil, "UnitClass" },
    { "build", "getBuildInfo", nil, "GetBuildInfo" },
    { "systemTime", "getTime", nil, "GetTime" },
    { "locale", "getLocale", nil, "GetLocale" },
  }
  for _, sample in ipairs(samples) do
    local namespaceName, functionName, hostNamespaceName, hostName =
      sample[1], sample[2], sample[3], sample[4]
    if documentedOnRunningFlavour(namespaceName, functionName) then
      local bound = type(api[namespaceName]) == "table" and api[namespaceName][functionName] or nil
      local hostFunction
      local hostPath
      if type(hostNamespaceName) == "nil" then
        hostFunction = readHost(hostName)
        hostPath = hostName
      else
        local hostNamespace = readHost(hostNamespaceName)
        hostFunction = type(hostNamespace) == "table" and hostNamespace[hostName] or nil
        hostPath = hostNamespaceName .. "." .. hostName
      end
      ctx:Log(
        ("api.%s.%s is %s: %s"):format(
          namespaceName,
          functionName,
          hostPath,
          tostring(type(bound) == "function" and rawequal(bound, hostFunction))
        )
      )
      ctx:Expect(type(bound)):ToBe("function")
      ctx:Expect(bound):ToBe(hostFunction)
    end
  end
  ctx:Expect(type(api.profiler)):ToBe("table")
  ctx:Expect(api.profiler):ToBe(api.addOnProfiler)
end)

bindings:Test(
  "host functions of C_Timer, C_AddOns, C_Spell, C_Item and other watched namespaces that the capture does not bind are logged as client additions, and every C_ namespace the client has but the surface lacks is counted",
  function(ctx)
    local api = runningApi()
    if type(api) == "nil" then
      ctx:Fail(NO_RUNNING_API)
      return
    end
    local report = walkSurface(api, hostTable())
    for _, hostNamespaceName in ipairs(WATCHED_HOST_NAMESPACES) do
      local hostNamespace = readHost(hostNamespaceName)
      if type(hostNamespace) ~= "table" then
        ctx:Log(hostNamespaceName .. ": absent from the client")
      else
        local total = 0
        local unbound = {}
        for name, value in pairs(hostNamespace) do
          if type(value) == "function" then
            total = total + 1
            if type(report.bound[value]) == "nil" then
              unbound[#unbound + 1] = tostring(name)
            end
          end
        end
        logNames(
          ctx,
          ("%s: %d host functions, %d bound, not bound"):format(
            hostNamespaceName,
            total,
            total - #unbound
          ),
          unbound,
          2
        )
      end
    end

    local hostFunctionTotal = 0
    local hostFunctionsUnbound = 0
    local namespacesWithoutSurface = {}
    for key, value in pairs(hostTable()) do
      if type(key) == "string" and key:sub(1, 2) == "C_" and type(value) == "table" then
        local functionCount = 0
        local boundCount = 0
        for _, member in pairs(value) do
          if type(member) == "function" then
            functionCount = functionCount + 1
            if type(report.bound[member]) ~= "nil" then
              boundCount = boundCount + 1
            end
          end
        end
        hostFunctionTotal = hostFunctionTotal + functionCount
        hostFunctionsUnbound = hostFunctionsUnbound + functionCount - boundCount
        if boundCount == 0 and functionCount > 0 then
          namespacesWithoutSurface[#namespacesWithoutSurface + 1] = key
        end
      end
    end
    ctx:Log(
      ("all C_ namespaces of the client: %d functions, %d of them not bound"):format(
        hostFunctionTotal,
        hostFunctionsUnbound
      )
    )
    logNames(
      ctx,
      ("C_ namespaces with functions none of which is bound (%d)"):format(#namespacesWithoutSurface),
      namespacesWithoutSurface,
      6
    )
    local wrapperNamespaces = {}
    for namespaceName in pairs(api) do
      wrapperNamespaces[foldName(namespaceName)] = true
    end
    local watchedWithoutSurface = {}
    for _, hostNamespaceName in ipairs(WATCHED_HOST_NAMESPACES) do
      local folded = foldName(hostNamespaceName:sub(3))
      if
        type(readHost(hostNamespaceName)) == "table" and type(wrapperNamespaces[folded]) == "nil"
      then
        watchedWithoutSurface[#watchedWithoutSurface + 1] = hostNamespaceName
      end
    end
    logNames(ctx, "watched namespaces the surface lacks", watchedWithoutSurface)
    ctx:Expect(#watchedWithoutSurface):ToBe(0)
  end
)

-- apiKit.data ---------------------------------------------------------------------------------------

local data = Harness:Suite(PACKAGE_ID, "data", addonName)

data:Test(
  ("api.events holds %d event strings, each named by its own lowerCamelCase, api.events.playerLogin is 'PLAYER_LOGIN', and the client's C_EventUtils.IsEventValid is asked about every one"):format(
    RUNNING.eventCount
  ),
  function(ctx)
    local api = runningApi()
    local events = type(api) == "table" and api.events or nil
    if type(events) ~= "table" then
      ctx:Fail(("MoltenCodes.wow.%s.api.events is not a table"):format(RUNNING.apiPath))
      return
    end
    local count = 0
    local misnamed = {}
    for key, value in pairs(events) do
      count = count + 1
      if type(key) ~= "string" or type(value) ~= "string" or foldName(key) ~= foldName(value) then
        misnamed[#misnamed + 1] = tostring(key) .. " = " .. tostring(value)
      end
    end
    logNames(ctx, ("api.events: %d entries, %d misnamed"):format(count, #misnamed), misnamed)

    local isEventValid = type(readHost("C_EventUtils")) == "table"
        and readHost("C_EventUtils").IsEventValid
      or nil
    if type(isEventValid) == "function" then
      local unknown = {}
      for _, value in pairs(events) do
        if type(value) == "string" and isEventValid(value) ~= true then
          unknown[#unknown + 1] = value
        end
      end
      logNames(
        ctx,
        ("events C_EventUtils.IsEventValid does not know (%d)"):format(#unknown),
        unknown
      )
    else
      ctx:Log("C_EventUtils.IsEventValid is absent; event strings not checked against the client")
    end

    ctx:Expect(count):ToBe(RUNNING.eventCount)
    ctx:Expect(#misnamed):ToBe(0)
    ctx:Expect(events.playerLogin):ToBe("PLAYER_LOGIN")
    ctx:Expect(events.addonLoaded):ToBe("ADDON_LOADED")
    ctx:Expect(events.playerEnteringWorld):ToBe("PLAYER_ENTERING_WORLD")
  end
)

---Compare an aliasing data table of the surface (`api.enums`, `api.constants`)
---with the client's table it aliases entry by entry, logging what differs.
---@param ctx TestKit.Context
---@param label string `api.enums`, for the log
---@param aliases table the surface's table
---@param hostName string `Enum` or `Constants`
---@return integer present how many entries the surface holds
---@return integer mismatched how many of them are not the client's entry
local function compareAliasTable(ctx, label, aliases, hostName)
  local hostValues = readHost(hostName)
  if type(hostValues) ~= "table" then
    ctx:Log(hostName .. " is absent from the client")
    return 0, 0
  end
  local hostByFolded = {}
  for key in pairs(hostValues) do
    if type(key) == "string" then
      hostByFolded[foldName(key)] = key
    end
  end
  local present = 0
  local mismatched = {}
  local aliased = {}
  for key, value in pairs(aliases) do
    present = present + 1
    local hostKey = type(key) == "string" and hostByFolded[foldName(key)] or nil
    if type(hostKey) == "nil" or not rawequal(hostValues[hostKey], value) then
      mismatched[#mismatched + 1] = tostring(key)
    else
      aliased[hostKey] = true
    end
  end
  local additions = {}
  local hostCount = 0
  for key in pairs(hostValues) do
    hostCount = hostCount + 1
    if type(aliased[key]) == "nil" then
      additions[#additions + 1] = tostring(key)
    end
  end
  logNames(
    ctx,
    ("%s: %d entries, each %s.<Name>; %d are not"):format(label, present, hostName, #mismatched),
    mismatched
  )
  logNames(
    ctx,
    ("%s: %d entries, %d not in %s (client additions or undocumented)"):format(
      hostName,
      hostCount,
      #additions,
      label
    ),
    additions
  )
  return present, #mismatched
end

data:Test(
  "every api.enums entry is the client's Enum table of the same name, api.enums.itemQuality.Epic is Enum.ItemQuality.Epic, and Enum tables the capture lacks are logged",
  function(ctx)
    local api = runningApi()
    local enums = type(api) == "table" and api.enums or nil
    if type(enums) ~= "table" then
      ctx:Fail(("MoltenCodes.wow.%s.api.enums is not a table"):format(RUNNING.apiPath))
      return
    end
    local present, mismatched = compareAliasTable(ctx, "api.enums", enums, "Enum")
    local hostEnums = readHost("Enum")
    ctx:Expect(type(hostEnums)):ToBe("table")
    ctx:Expect(mismatched):ToBe(0)
    ctx:Expect(present > 0):ToBe(true)
    ctx:Expect(present <= RUNNING.enumCount):ToBe(true)
    ctx:Expect(enums.itemQuality):ToBe(hostEnums.ItemQuality)
    ctx:Expect(enums.itemQuality.Epic):ToBe(hostEnums.ItemQuality.Epic)
    ctx:Expect(enums.phaseReason):ToBe(hostEnums.PhaseReason)
    ctx:Log(
      ("api.enums.itemQuality.Epic %s, api.enums.phaseReason.Sharding %s"):format(
        tostring(enums.itemQuality.Epic),
        tostring(type(enums.phaseReason) == "table" and enums.phaseReason.Sharding or nil)
      )
    )
  end
)

data:Test(
  "every api.constants entry is the client's Constants table of the same name, api.constants.auctionConstants is Constants.AuctionConstants",
  function(ctx)
    local api = runningApi()
    local constants = type(api) == "table" and api.constants or nil
    if type(constants) ~= "table" then
      ctx:Fail(("MoltenCodes.wow.%s.api.constants is not a table"):format(RUNNING.apiPath))
      return
    end
    local present, mismatched = compareAliasTable(ctx, "api.constants", constants, "Constants")
    local hostConstants = readHost("Constants")
    ctx:Expect(type(hostConstants)):ToBe("table")
    ctx:Expect(mismatched):ToBe(0)
    ctx:Expect(present > 0):ToBe(true)
    ctx:Expect(constants.auctionConstants):ToBe(hostConstants.AuctionConstants)
  end
)

-- apiKit.calls ----------------------------------------------------------------------------------------

local calls = Harness:Suite(PACKAGE_ID, "calls", addonName)

---Every value a call returned, and how many there were (a trailing `nil`
---counts, so the count comes from `select("#")`, not from the list).
---@param ... any
---@return { count: integer, values: any[] }
local function pack(...)
  return { count = select("#", ...), values = { ... } }
end

---Compare what the wrapper and the raw call returned, value by value, never
---comparing a secret. Returns a log fragment and whether the two agree.
---@param wrapperResults { count: integer, values: any[] }
---@param hostResults { count: integer, values: any[] }
---@param logValues boolean whether the values may appear in the log
---@return string description
---@return boolean agree
local function compareResults(wrapperResults, hostResults, logValues)
  if wrapperResults.count ~= hostResults.count then
    return ("%d values through the wrapper, %d raw"):format(wrapperResults.count, hostResults.count),
      false
  end
  local shown = {}
  for index = 1, wrapperResults.count do
    local fromWrapper = wrapperResults.values[index]
    local fromHost = hostResults.values[index]
    if isSecret(fromWrapper) or isSecret(fromHost) then
      shown[index] = "<secret>"
    else
      if fromWrapper ~= fromHost then
        return ("value %d differs"):format(index), false
      end
      shown[index] = logValues and tostring(fromWrapper) or type(fromWrapper)
    end
  end
  return ("%d values: %s"):format(wrapperResults.count, table.concat(shown, ", ")), true
end

--- The name of the calls test: a Classic surface binds no `GetBuildInfo` and
--- only one build probe, `IsBetaBuild` (`RETAIL_ONLY_WRAPPERS`).
local CALLS_TEST_NAME = RUNNING.id == "retail"
    and "read-only getters called through the wrapper answer exactly what the raw calls answer: GetBuildInfo, the build probes, GetLocale, UnitName, UnitClass, C_AddOns, C_CVar.GetCVar, C_EventUtils.IsEventValid, C_Map.GetBestMapForUnit and others"
  or "read-only getters called through the wrapper answer exactly what the raw calls answer: IsBetaBuild, GetLocale, UnitName, UnitClass, C_AddOns, C_CVar.GetCVar, C_EventUtils.IsEventValid, C_Map.GetBestMapForUnit and others"

calls:Test(CALLS_TEST_NAME, function(ctx)
  local api = runningApi()
  if type(api) == "nil" then
    ctx:Fail(NO_RUNNING_API)
    return
  end
  -- wrapper namespace, wrapper function, host namespace (nil for a global),
  -- host function, arguments, whether the values may be logged (a player's
  -- name, realm and GUID are not). Each is a `wrapper` and `binding` of the
  -- Retail metadata that Retail 12.1.0 b69933 binds; a Classic client calls
  -- the sixteen its metadata documents too (`RETAIL_ONLY_WRAPPERS`).
  -- Both calls of a pair run in the same frame with the same arguments.
  local getters = {
    { "build", "getBuildInfo", nil, "GetBuildInfo", {}, true },
    { "build", "isTestBuild", nil, "IsTestBuild", {}, true },
    { "build", "isBetaBuild", nil, "IsBetaBuild", {}, true },
    { "build", "isPublicBuild", nil, "IsPublicBuild", {}, true },
    { "build", "isWindowsClient", nil, "IsWindowsClient", {}, true },
    { "build", "isMacClient", nil, "IsMacClient", {}, true },
    { "locale", "getLocale", nil, "GetLocale", {}, true },
    { "locale", "getCurrentRegion", nil, "GetCurrentRegion", {}, true },
    { "expansion", "getExpansionLevel", nil, "GetExpansionLevel", {}, true },
    { "playerScript", "isLoggedIn", nil, "IsLoggedIn", {}, true },
    { "restrictedActions", "inCombatLockdown", nil, "InCombatLockdown", {}, true },
    { "unit", "name", nil, "UnitName", { "player" }, false },
    { "unit", "class", nil, "UnitClass", { "player" }, true },
    { "unit", "level", nil, "UnitLevel", { "player" }, true },
    { "unit", "factionGroup", nil, "UnitFactionGroup", { "player" }, true },
    { "unit", "guid", nil, "UnitGUID", { "player" }, false },
    { "connectionScript", "getRealmName", nil, "GetRealmName", {}, false },
    { "addOns", "getNumAddOns", "C_AddOns", "GetNumAddOns", {}, true },
    { "addOns", "isAddOnLoaded", "C_AddOns", "IsAddOnLoaded", { "MoltenCodes" }, true },
    {
      "addOns",
      "getAddOnMetadata",
      "C_AddOns",
      "GetAddOnMetadata",
      { "MoltenCodes", "Title" },
      true,
    },
    { "cvar", "getCVar", "C_CVar", "GetCVar", { "scriptErrors" }, true },
    { "eventUtils", "isEventValid", "C_EventUtils", "IsEventValid", { "PLAYER_LOGIN" }, true },
    { "map", "getBestMapForUnit", "C_Map", "GetBestMapForUnit", { "player" }, true },
  }
  local disagreements = 0
  local called = 0
  for _, getter in ipairs(getters) do
    local namespaceName, functionName, hostNamespaceName, hostName, arguments, logValues =
      getter[1], getter[2], getter[3], getter[4], getter[5], getter[6]
    if documentedOnRunningFlavour(namespaceName, functionName) then
      called = called + 1
      local wrapperFunction = type(api[namespaceName]) == "table"
          and api[namespaceName][functionName]
        or nil
      local hostFunction
      local hostPath
      if type(hostNamespaceName) == "nil" then
        hostFunction = readHost(hostName)
        hostPath = hostName
      else
        local hostNamespace = readHost(hostNamespaceName)
        hostFunction = type(hostNamespace) == "table" and hostNamespace[hostName] or nil
        hostPath = hostNamespaceName .. "." .. hostName
      end
      if type(wrapperFunction) ~= "function" or type(hostFunction) ~= "function" then
        disagreements = disagreements + 1
        ctx:Log(
          ("api.%s.%s is %s and %s is %s"):format(
            namespaceName,
            functionName,
            type(wrapperFunction),
            hostPath,
            type(hostFunction)
          )
        )
      else
        local argumentCount = #arguments
        local wrapperResults = pack(wrapperFunction(unpack(arguments, 1, argumentCount)))
        local hostResults = pack(hostFunction(unpack(arguments, 1, argumentCount)))
        local description, agree = compareResults(wrapperResults, hostResults, logValues)
        if not agree then
          disagreements = disagreements + 1
        end
        ctx:Log(
          ("api.%s.%s and %s: %s%s"):format(
            namespaceName,
            functionName,
            hostPath,
            description,
            agree and "" or " (DISAGREE)"
          )
        )
      end
    end
  end
  ctx:Log(("%d getters compared, %d disagreements"):format(called, disagreements))
  ctx:Expect(disagreements):ToBe(0)
end)

-- apiKit.allocation -----------------------------------------------------------------------------------

local allocation = Harness:Suite(PACKAGE_ID, "allocation", addonName)

--- Where the lookups below leave what they read, so no lookup is optimised
--- away and none allocates a result.
local lookupSink

---The `api` table at `path` under the namespace root `root`, indexed the way
---an addon does (`wow.classic.era.api`); allocates nothing.
---@param root table
---@param path string[]
---@return any
local function lookUpApi(root, path)
  local node = root
  for index = 1, #path do
    node = node[path[index]]
  end
  return node.api
end

allocation:Test(
  ("looking up wow.%s.api, api.timer.newTicker, api.unit.name, api.events.playerLogin, api.enums.itemQuality and an empty flavour's table again allocates nothing over 2000 rounds"):format(
    RUNNING.apiPath
  ),
  function(ctx)
    if type(runningApi()) == "nil" or type(readHost("wow")) ~= "table" then
      ctx:Fail("the wow global or " .. NO_RUNNING_API)
      return
    end
    local runningPath = RUNNING.path
    local emptyPath = RUNNING.emptyPath
    expectNoAllocation(ctx, "api.* lookups", function()
      local wowGlobal = readHost("wow")
      local api = lookUpApi(wowGlobal, runningPath)
      lookupSink = api.timer.newTicker
      lookupSink = api.unit.name
      lookupSink = api.profiler
      lookupSink = api.events.playerLogin
      lookupSink = api.enums.itemQuality
      lookupSink = api.constants.auctionConstants
      lookupSink = lookUpApi(wowGlobal, emptyPath)
      lookupSink = rawget(namespace, "wow").ptr.api
    end)
    ctx:Expect(lookupSink):ToBe(flavorApi({ "ptr" }))
    lookupSink = nil
  end
)

allocation:Test(
  ("GetFlavor, GetGlobalStatus, GetMetadataBuild('%s') and a getter called through the wrapper allocate nothing over 2000 rounds"):format(
    RUNNING.id
  ),
  function(ctx)
    local api = runningApi()
    if type(api) == "nil" then
      ctx:Fail(NO_RUNNING_API)
      return
    end
    local runningId = RUNNING.id
    local firstGetter, secondGetter = RUNNING.allocationGetters[1], RUNNING.allocationGetters[2]
    local firstNamespace, firstFunction = firstGetter[1], firstGetter[2]
    local secondNamespace, secondFunction = secondGetter[1], secondGetter[2]
    local label = ("facade getters and api.%s.%s"):format(firstNamespace, firstFunction)
    expectNoAllocation(ctx, label, function()
      lookupSink = ApiKit:GetFlavor()
      lookupSink = ApiKit:GetGlobalStatus()
      lookupSink = ApiKit:GetMetadataBuild(runningId)
      lookupSink = api[firstNamespace][firstFunction]()
      lookupSink = api[secondNamespace][secondFunction]()
    end)
    ctx:Expect(lookupSink):ToBe(false)
    lookupSink = nil
  end
)

-- apiKit.errors ----------------------------------------------------------------------------------------

local errors = Harness:Suite(PACKAGE_ID, "errors", addonName)

errors:Test("GetFlavor called with a dot names ApiKitSuite.lua at the calling line", function(ctx)
  local lines = { start = 0 }
  expectErrorAtCallingLine(ctx, function()
    lines.start = currentLine()
    ApiKit.GetFlavor()
  end, lines, "ApiKit:GetFlavor must be called on the ApiKit facade")
  expectErrorAtCallingLine(ctx, function()
    lines.start = currentLine()
    ApiKit.GetGlobalStatus({})
  end, lines, "ApiKit:GetGlobalStatus must be called on the ApiKit facade")
end)

errors:Test(
  "RegisterFlavor with an unknown flavour, a non-function installer, an info that is not a table, a numeric info.version and a fractional info.build is refused at the calling line, runs nothing and leaves the metadata as it was",
  function(ctx)
    local installer, installerCalls = countingInstaller()
    local versionBefore, buildBefore = ApiKit:GetMetadataBuild("retail")
    local lines = { start = 0 }
    expectErrorAtCallingLine(
      ctx,
      function()
        lines.start = currentLine()
        ApiKit:RegisterFlavor("wotlk", installer)
      end,
      lines,
      "ApiKit:RegisterFlavor flavor must be one of retail, classic-era, classic-mop, ptr, beta"
    )
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      ApiKit:RegisterFlavor("retail", "not a function")
    end, lines, "ApiKit:RegisterFlavor install must be a function")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      ApiKit:RegisterFlavor("retail", installer, "12.1.0")
    end, lines, "ApiKit:RegisterFlavor info must be a table when given")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      ApiKit:RegisterFlavor("retail", installer, { version = 12 })
    end, lines, "ApiKit:RegisterFlavor info.version must be a string when given")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      ApiKit:RegisterFlavor("retail", installer, { build = 69933.5 })
    end, lines, "ApiKit:RegisterFlavor info.build must be an integer when given")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      ApiKit.RegisterFlavor({}, "retail", installer)
    end, lines, "ApiKit:RegisterFlavor must be called on the ApiKit facade")
    ctx:Expect(installerCalls()):ToBe(0)
    local versionAfter, buildAfter = ApiKit:GetMetadataBuild("retail")
    ctx:Expect(versionAfter):ToBe(versionBefore)
    ctx:Expect(buildAfter):ToBe(buildBefore)
    ctx:Expect(ApiKit:GetFlavor()):ToBe(RUNNING.id)
  end
)

errors:Test(
  "GetMetadataBuild with an unknown flavour and a write to SUPPORTED_FLAVORS are refused at the calling line",
  function(ctx)
    local lines = { start = 0 }
    expectErrorAtCallingLine(
      ctx,
      function()
        lines.start = currentLine()
        ApiKit:GetMetadataBuild("tbc")
      end,
      lines,
      "ApiKit:GetMetadataBuild flavor must be one of retail, classic-era, classic-mop, ptr, beta"
    )
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      ApiKit.SUPPORTED_FLAVORS[1] = "wotlk"
    end, lines, 'ApiKit.SUPPORTED_FLAVORS is read-only; index "1" cannot be written')
    ctx:Expect(ApiKit.SUPPORTED_FLAVORS[1]):ToBe("retail")
  end
)

errors:Test(
  "a second registration of the running flavour and a registration of the Public Test Realm on this client are dropped: both return false, neither installer runs, the surface and the metadata stay as they were",
  function(ctx)
    local api = runningApi()
    if type(api) == "nil" then
      ctx:Fail(NO_RUNNING_API)
      return
    end
    local keysBefore = countKeys(api)
    local timerBefore = api.timer
    local installer, installerCalls = countingInstaller()

    ctx:Expect(ApiKit:RegisterFlavor(RUNNING.id, installer, registeredInfo(RUNNING.id))):ToBe(false)
    ctx:Expect(ApiKit:RegisterFlavor("ptr", installer, registeredInfo("ptr"))):ToBe(false)

    ctx:Expect(installerCalls()):ToBe(0)
    ctx:Expect(countKeys(api)):ToBe(keysBefore)
    ctx:Expect(api.timer):ToBe(timerBefore)
    local ptrApi = flavorApi({ "ptr" })
    ctx:Expect(type(ptrApi)):ToBe("table")
    ctx:Expect(countKeys(ptrApi or {})):ToBe(0)
    local version, build = ApiKit:GetMetadataBuild(RUNNING.id)
    ctx:Expect(version):ToBe(RUNNING.committed.version)
    ctx:Expect(build):ToBe(RUNNING.committed.build)
  end
)

-- apiKit.secrets ----------------------------------------------------------------------------------------

local secrets = Harness:Suite(PACKAGE_ID, "secrets", addonName)

--- Why the secrets tests are skipped on a client without the two functions.
local SECRETS_SKIP_REASON =
  "the client has no issecretvalue and secretwrap; the secret path was not exercised"

---Register `body` as a test when the client can make a secret value, and as a
---skipped test naming why otherwise: the functions are missing, or the
---client has them but makes no secret (`Harness:CanMakeSecrets`).
---@param name string
---@param body fun(ctx: TestKit.Context)
local function secretTest(name, body)
  if SECRETS_AVAILABLE then
    secrets:Test(name, body)
  elseif not SECRET_FUNCTIONS_PRESENT then
    secrets:Skip(name, SECRETS_SKIP_REASON)
  else
    secrets:Skip(name, Harness.NO_SECRETS_REASON)
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

secretTest(
  "a secret flavour id handed to RegisterFlavor and to GetMetadataBuild is refused at the calling line before it is used as a key, and no installer runs",
  function(ctx)
    local secretFlavor = makeSecret(ctx, "retail")
    local installer, installerCalls = countingInstaller()
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      ApiKit:RegisterFlavor(secretFlavor, installer)
    end, lines, "ApiKit:RegisterFlavor flavor must not be a secret value")
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      ApiKit:GetMetadataBuild(secretFlavor)
    end, lines, "ApiKit:GetMetadataBuild flavor must not be a secret value")
    ctx:Expect(installerCalls()):ToBe(0)
  end
)

secretTest(
  "a secret info.build is refused at the calling line before its integer test, runs no installer and leaves the Retail metadata as it was",
  function(ctx)
    local secretBuild = makeSecret(ctx, 69933)
    local installer, installerCalls = countingInstaller()
    local lines = { start = 0 }
    expectErrorAtCallingLine(ctx, function()
      lines.start = currentLine()
      ApiKit:RegisterFlavor("retail", installer, { version = "12.1.0", build = secretBuild })
    end, lines, "ApiKit:RegisterFlavor info.build must not be a secret value")
    ctx:Expect(installerCalls()):ToBe(0)
    local version, build = ApiKit:GetMetadataBuild("retail")
    ctx:Expect(version):ToBe(COMMITTED_FLAVORS[1].version)
    ctx:Expect(build):ToBe(COMMITTED_FLAVORS[1].build)
  end
)

secretTest(
  ("a secret info.version is accepted, as docs/API.md says: the registration of the installed %s flavour returns false without raising and its metadata stays the committed one"):format(
    RUNNING.label
  ),
  function(ctx)
    local secretVersion = makeSecret(ctx, RUNNING.committed.version)
    local installer, installerCalls = countingInstaller()
    local succeeded, installed = pcall(ApiKit.RegisterFlavor, ApiKit, RUNNING.id, installer, {
      version = secretVersion,
      build = RUNNING.committed.build,
    })
    ctx:Log(
      ("RegisterFlavor with a secret info.version: %s, %s"):format(
        tostring(succeeded),
        tostring(installed)
      )
    )
    ctx:Expect(succeeded):ToBe(true)
    ctx:Expect(installed):ToBe(false)
    ctx:Expect(installerCalls()):ToBe(0)
    local version, build = ApiKit:GetMetadataBuild(RUNNING.id)
    ctx:Expect(isSecret(version)):ToBe(false)
    ctx:Expect(version):ToBe(RUNNING.committed.version)
    ctx:Expect(build):ToBe(RUNNING.committed.build)
  end
)
