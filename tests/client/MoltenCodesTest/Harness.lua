-- MoltenCodes Test: Harness.lua
--
-- The real-client test harness. The framework's Busted specs prove behaviour
-- against a fake client; this addon runs TestKit suites inside the game client
-- itself, one framework package at a time, so the owner of a real installation
-- can prove what the fake client can only simulate. See tests/client/README.md.
--
-- What it does:
--
--   * publishes `MoltenCodesTest`, the small API a package test addon
--     (`MoltenCodesTest_<Facade>`) registers its TestKit suites through, keyed
--     by the package they test;
--   * answers `/mct` (`run [package] [combat]`, `list`, `report`, `clear`,
--     `help`);
--   * prints one line per test and one totals line per package to the default
--     chat frame when a run finishes;
--   * writes each package's full TestKit report, with the facts of the client it
--     ran on and the commit the installer installed, into the saved variable
--     `MoltenCodesTestResults`, keyed by package ID, so it can be read from
--     `WTF/Account/<ACCOUNT>/SavedVariables/` after a `/reload` or a logout, and
--     turned into the result matrix by `python3 -m tooling.client.report`;
--   * runs the combat suites of a package on request (`/mct run <package>
--     combat`): it waits a bounded time for the player to enter combat, for
--     example by attacking a training dummy, then runs only those suites.
--
-- Nothing runs on its own. The only thing that happens at login is one chat
-- line naming the packages whose suites are loaded and how to run them: a run
-- creates probe packages in the session's Registry and measures memory, so it
-- starts only when the owner types `/mct run` (tests/client/README.md,
-- "Why nothing runs automatically").
--
-- Load order (MoltenCodesTest.toc): the MoltenCodes addon first, through
-- `## Dependencies`, then TestKit.lua and Expected.lua, both written by
-- `python3 -m tooling.client.install`, then this file.

-- WoW passes every addon file its folder name and the addon's private table.
-- Expected.lua, loaded just before this file, leaves the installed packages
-- and the facts of the installation (commit, flavour folder) in that table.
local ADDON_NAME, private = ...

local REGISTRY_API = 2
local TEST_KIT_API = 1
local LIFECYCLE_KIT_API = 1
local EVENT_KIT_API = 1
local TIMER_KIT_API = 1

--- The global the harness publishes for package test addons.
local PUBLIC_NAME = "MoltenCodesTest"

--- The saved variable named by `## SavedVariables` in MoltenCodesTest.toc.
local SAVED_VARIABLES_NAME = "MoltenCodesTestResults"

--- The key of `/mct` in `SlashCmdList`; the client reads `SLASH_<key>1`.
local SLASH_KEY = "MOLTENCODESTEST"
local SLASH_COMMAND = "/mct"

--- Layout version of one package entry in `MoltenCodesTestResults`. Schema 2
--- added `mode`, `installation`, `client.flavour`, `client.os` and
--- `client.testBuild`; readers accept schema 1 entries, which have none of them.
local RESULTS_SCHEMA = 2

--- The two kinds of run. A default run queues every suite of a package; a
--- combat run queues only the suites registered with `combat = true`, once the
--- player is in combat.
local DEFAULT_MODE = "default"
local COMBAT_MODE = "combat"

--- The key of a combat run's entry in `MoltenCodesTestResults` is the package
--- ID followed by this suffix, so a combat run never replaces the package's
--- default run.
local COMBAT_RESULTS_SUFFIX = ":combat"

--- Seconds `/mct run <package> combat` waits for the player to enter combat
--- before it gives up and runs nothing.
local COMBAT_WAIT_SECONDS = 60

--- The apiKit flavour ID (tooling/api/flavours.json) of each `WOW_PROJECT_ID`
--- the framework promises to run on. Another client (the Burning Crusade
--- Classic Anniversary one, say) has no flavour here; its runs are still saved
--- with their `projectId`.
local FLAVOURS_BY_PROJECT_ID = {
  [1] = "retail",
  [2] = "classic-era",
  [19] = "classic-mop",
}

--- The operating-system probes some clients publish, in the order they are
--- asked, with the name the saved results record. Retail documents all three;
--- a client without them leaves `client.os` absent.
local OS_PROBES = {
  { functionName = "IsMacClient", name = "macOS" },
  { functionName = "IsWindowsClient", name = "Windows" },
  { functionName = "IsLinuxClient", name = "Linux" },
}

--- The installation facts Expected.lua may carry and the harness copies into
--- every saved entry; any other field is ignored.
local INSTALLATION_FIELDS = { "commit", "dirty", "flavourDirectory", "installedAt" }

--- Printed before every chat line, so harness output is easy to find.
local CHAT_PREFIX = "|cff33ccffMoltenCodes Test|r: "

--- A package ID and a suite part share the manifest naming rule.
local IDENTIFIER_PATTERN = "^[a-z][A-Za-z0-9]*$"

--- Starts the message `Harness:SkipTest` fails a test with. TestKit has no way
--- to skip a test once it runs, so the harness reports a failure that carries
--- this marker as skipped, with the text after the marker as the reason.
local RUNTIME_SKIP_MARKER = "[MoltenCodesTest: skipped at run time] "

--- The suite options `Harness:Suite` accepts.
local SUITE_OPTION_NAMES = { timeoutSeconds = true, combat = true, prepare = true }

--- How each TestKit status is printed, coloured so a failure stands out.
local STATUS_LABELS = {
  passed = "|cff00ff00PASS|r",
  failed = "|cffff3333FAIL|r",
  skipped = "|cffffff00SKIP|r",
  timeout = "|cffff9900TIMEOUT|r",
}

-- Public types ----------------------------------------------------------------

---One package the installed bundle (or this harness) carries, as Expected.lua
---lists it from the committed package manifests.
---@class MoltenCodesTest.ExpectedPackage
---@field id string The package ID, for example `"signalKit"`.
---@field api integer The API generation the manifest declares.
---@field revision integer The implementation revision the manifest declares.
---@field version string The manifest version.
---@field bundled boolean `true` when the MoltenCodes bundle carries it; `false` for TestKit, which the harness loads.

---What the installer recorded about the installation, as Expected.lua lists it.
---@class MoltenCodesTest.Installation
---@field commit string|nil The commit `git rev-parse HEAD` named when the installer ran; absent outside a git checkout.
---@field dirty boolean|nil `true` when the working tree had changes the commit does not hold.
---@field flavourDirectory string|nil The client folder the installer wrote to, for example `"_retail_"`.
---@field installedAt string|nil When the installer ran, in UTC (`YYYY-MM-DDTHH:MM:SSZ`).

-- Resolving the framework -------------------------------------------------------

---Read a client global, or `nil`.
---@param name string
---@return any
local function readHost(name)
  -- Chat, slash commands, build facts and saved variables are World of
  -- Warcraft client globals, reachable only through the global table.
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

---Return Registry API 2, raising a load error that names the fix when absent.
---@return Registry
local function resolveRegistry()
  local namespace = readHost("MoltenCodes")
  local generations = type(namespace) == "table" and rawget(namespace, "Registries") or nil
  local registry = type(generations) == "table" and rawget(generations, REGISTRY_API) or nil
  if type(registry) ~= "table" or rawget(registry, "API") ~= REGISTRY_API then
    error(ADDON_NAME .. " requires the MoltenCodes addon (Registry API 2); reinstall it", 0)
  end
  return registry
end

local Registry = resolveRegistry()

---@type TestKit|nil
local TestKit = Registry:Get("testKit", TEST_KIT_API)
---@type LifecycleKit|nil
local LifecycleKit = Registry:Get("lifecycleKit", LIFECYCLE_KIT_API)
if type(TestKit) == "nil" or type(LifecycleKit) == "nil" then
  error(ADDON_NAME .. " requires TestKit API 1 and LifecycleKit API 1; reinstall it", 0)
end

--- EventKit and TimerKit are needed only by a combat run, which waits for
--- PLAYER_REGEN_DISABLED with a bounded timer; the bundle carries both.
---@type EventKit|nil
local EventKit = Registry:Get("eventKit", EVENT_KIT_API)
---@type TimerKit|nil
local TimerKit = Registry:Get("timerKit", TIMER_KIT_API)

--- TestKit keeps at most 64 suites per session by default. Every package test
--- addon registers several suites, so installing many of them passes that bound
--- (eight addons already register 68). The harness is the one development tool
--- that owns TestKit in this session, so it raises the bound for itself; the
--- value stays finite so a runaway registration loop is still caught.
local MAX_SUITES = 1024
TestKit:SetLimits({ maxSuites = MAX_SUITES })

---@type SchedulerKit|nil
local SchedulerKit = Registry:Get("schedulerKit", 1)

--- SchedulerKit's runaway threshold while `/mct run` is in progress. Test steps
--- such as allocation guards run a full garbage collection and thousands of
--- calls in one slice; under the 8 ms default SchedulerKit would demote the
--- TestKit runner and report each slice through the error handler, which is
--- the documented contract but only noise during a test run. The previous
--- value is restored when the run finishes.
local RUN_RUNAWAY_THRESHOLD_MS = 500

-- State -----------------------------------------------------------------------

--- Package IDs in the order their first suite was registered.
---@type string[]
local packageIds = {}

--- Suite names per package ID, in registration order.
---@type table<string, string[]>
local suiteNamesByPackage = {}

--- The package ID each suite name belongs to.
---@type table<string, string>
local packageBySuiteName = {}

--- Combat suite names per package ID, in registration order: the suites a
--- combat run queues. A default run queues them too, like every other suite.
---@type table<string, string[]>
local combatSuiteNamesByPackage = {}

--- The `prepare` functions of each package's combat suites, called when a
--- combat run is requested out of combat, before the harness waits.
---@type table<string, fun()[]>
local combatPreparationsByPackage = {}

--- The run `/mct run` started and has not seen finish, or `nil`. TestKit is
--- shared by every development addon in the session, so a finished run that the
--- harness did not start is ignored rather than recorded.
---@type { packageIds: string[], mode: string, client: table, installation: table, previousRunawayThreshold: number|false }|nil
local activeRun = nil

--- The combat run `/mct run <package> combat` is waiting to start, or `nil`:
--- the packages, the PLAYER_REGEN_DISABLED connection and the timeout timer.
---@type { packageIds: string[], connection: EventKit.Connection|nil, timer: TimerKit.Timer|nil }|nil
local pendingCombatRun = nil

---Raise SchedulerKit's runaway threshold for the run and return the value it
---replaced, or `false` when SchedulerKit is not loaded.
---@return number|false previous
local function relaxRunawayThreshold()
  if type(SchedulerKit) == "nil" then
    return false
  end
  local previous = SchedulerKit:GetRunawayThreshold()
  SchedulerKit:SetRunawayThreshold(RUN_RUNAWAY_THRESHOLD_MS)
  return previous
end

---Put back the threshold `relaxRunawayThreshold` replaced.
---@param previous number|false
local function restoreRunawayThreshold(previous)
  if previous ~= false and type(SchedulerKit) ~= "nil" then
    SchedulerKit:SetRunawayThreshold(previous)
  end
end

-- Chat output -------------------------------------------------------------------

---Print one line to the default chat frame, falling back to `print`.
---@param text string
local function say(text)
  local chatFrame = readHost("DEFAULT_CHAT_FRAME")
  if type(chatFrame) == "table" and type(chatFrame.AddMessage) == "function" then
    chatFrame:AddMessage(CHAT_PREFIX .. text)
  else
    print(CHAT_PREFIX .. text)
  end
end

---Join a list of strings with commas.
---@param names string[]
---@return string
local function joinNames(names)
  return table.concat(names, ", ")
end

-- Expected packages ---------------------------------------------------------------

---The packages Expected.lua lists, or `nil` when the file was not installed.
---@return MoltenCodesTest.ExpectedPackage[]|nil
local function expectedPackages()
  local packages = type(private) == "table" and private.expectedPackages or nil
  if type(packages) ~= "table" then
    return nil
  end
  return packages
end

-- Client facts --------------------------------------------------------------------

---Keep a host value only when it is plain data a saved variable can hold.
---@param value any
---@return string|number|boolean|nil
local function plainValue(value)
  local valueType = type(value)
  if valueType == "string" or valueType == "number" or valueType == "boolean" then
    return value
  end
  return nil
end

---Every Registry entry with the `REVISION` its live facade publishes.
---
---Each row is what `Registry:Packages()` reports plus `facadeRevision`, the
---`REVISION` constant of the table Registry hands out, and `expectedRevision`
---from Expected.lua, so a reader of the saved file can spot a newer copy that
---another addon embeds without running anything.
---@return table[]
local function describeLoadedPackages()
  local expectedById = {}
  for _, expected in ipairs(expectedPackages() or {}) do
    expectedById[expected.id] = expected.revision
  end

  local rows = {}
  for _, row in ipairs(Registry:Packages()) do
    local implementation = Registry:Find(row.package, row.api)
    local facadeRevision = nil
    if type(implementation) == "table" then
      facadeRevision = plainValue(rawget(implementation, "REVISION"))
    end
    rows[#rows + 1] = {
      package = row.package,
      api = row.api,
      revision = row.revision,
      status = row.status,
      facadeRevision = facadeRevision,
      expectedRevision = expectedById[row.package],
    }
  end
  return rows
end

---The apiKit flavour ID of the client, from `WOW_PROJECT_ID`, or `nil` for a
---project the framework does not promise.
---@return string|nil
local function clientFlavour()
  local projectId = readHost("WOW_PROJECT_ID")
  if type(projectId) ~= "number" then
    return nil
  end
  return FLAVOURS_BY_PROJECT_ID[projectId]
end

---The operating system the client reports, or `nil` when it has none of the
---probes or none of them answers `true`.
---@return string|nil
local function clientOperatingSystem()
  for _, probe in ipairs(OS_PROBES) do
    local answer = readHost(probe.functionName)
    if type(answer) == "function" and answer() == true then
      return probe.name
    end
  end
  return nil
end

---The installation facts Expected.lua carries, copied as plain values, or an
---empty table when the file is missing or older than the facts.
---@return table
local function installationFacts()
  local installation = type(private) == "table" and private.installation or nil
  local facts = {}
  if type(installation) ~= "table" then
    return facts
  end
  for _, field in ipairs(INSTALLATION_FIELDS) do
    facts[field] = plainValue(installation[field])
  end
  return facts
end

---The facts of the client a run happened on: build, flavour, operating system,
---locale, date and the MoltenCodes packages loaded, taken when the run starts.
---@return table
local function collectClientFacts()
  local facts = {}

  local getBuildInfo = readHost("GetBuildInfo")
  if type(getBuildInfo) == "function" then
    local version, build, buildDate, interface = getBuildInfo()
    facts.version = plainValue(version)
    facts.build = plainValue(build)
    facts.buildDate = plainValue(buildDate)
    facts.interface = plainValue(interface)
  end

  facts.projectId = plainValue(readHost("WOW_PROJECT_ID"))
  facts.flavour = clientFlavour()
  facts.os = clientOperatingSystem()

  -- A test realm reports the project of its live flavour; the report tool
  -- keeps its runs out of the matrix by this answer.
  local isTestBuild = readHost("IsTestBuild")
  if type(isTestBuild) == "function" then
    facts.testBuild = plainValue(isTestBuild())
  end

  local getLocale = readHost("GetLocale")
  if type(getLocale) == "function" then
    facts.locale = plainValue(getLocale())
  end

  -- `date` is the client's name for Lua's `os.date`; the client has no `os`.
  local formatDate = readHost("date")
  if type(formatDate) == "function" then
    facts.date = plainValue(formatDate("%Y-%m-%d %H:%M:%S"))
  end

  facts.registryRevision = plainValue(rawget(Registry, "REVISION"))
  facts.expectedInstalled = expectedPackages() ~= nil
  facts.packages = describeLoadedPackages()
  return facts
end

-- Saved results ---------------------------------------------------------------------

---The saved-variables table, created when the client had none to restore.
---
---It is read on every use rather than once: the client assigns the restored
---table just before this addon's `ADDON_LOADED`, after this file ran.
---@return table
local function savedResults()
  local saved = readHost(SAVED_VARIABLES_NAME)
  if type(saved) ~= "table" then
    saved = {}
    -- The saved variable is this addon's own global, named in its .toc.
    -- selene: allow(global_usage)
    rawset(_G, SAVED_VARIABLES_NAME, saved)
  end
  return saved
end

---Package IDs with saved results, sorted.
---@return string[]
local function savedPackageIds()
  local ids = {}
  for packageId in pairs(savedResults()) do
    if type(packageId) == "string" then
      ids[#ids + 1] = packageId
    end
  end
  table.sort(ids)
  return ids
end

-- Reporting a finished run ------------------------------------------------------------

---Add one test result to a totals table shaped like `TestKit.Totals`.
---@param totals table
---@param status string
local function countResult(totals, status)
  totals.tests = totals.tests + 1
  if type(totals[status]) == "number" then
    totals[status] = totals[status] + 1
  end
end

---Turn a failure `Harness:SkipTest` raised into the skip it stands for: the
---status becomes `"skipped"` and the message the reason after the marker.
---The report is TestKit's fresh copy, so changing it in place is safe.
---@param test table one test of a `TestKit.Report` suite
local function reclassifyRuntimeSkip(test)
  if test.status ~= "failed" or type(test.message) ~= "string" then
    return
  end
  local _, markerEnd = test.message:find(RUNTIME_SKIP_MARKER, 1, true)
  if type(markerEnd) == "nil" then
    return
  end
  test.status = "skipped"
  test.message = test.message:sub(markerEnd + 1)
end

---Split a TestKit report into one report per package, each shaped like the
---whole: `{ suites = { ... }, totals = { ... } }`. A test ended with
---`Harness:SkipTest` is counted as skipped.
---@param report TestKit.Report
---@return table<string, table>
local function reportsByPackage(report)
  local byPackage = {}
  for _, suite in ipairs(report.suites) do
    local packageId = packageBySuiteName[suite.name]
    if packageId ~= nil then
      local packageReport = byPackage[packageId]
      if packageReport == nil then
        packageReport = {
          suites = {},
          totals = {
            suites = 0,
            tests = 0,
            passed = 0,
            failed = 0,
            skipped = 0,
            timeout = 0,
          },
        }
        byPackage[packageId] = packageReport
      end
      packageReport.suites[#packageReport.suites + 1] = suite
      packageReport.totals.suites = packageReport.totals.suites + 1
      for _, test in ipairs(suite.tests) do
        reclassifyRuntimeSkip(test)
        countResult(packageReport.totals, test.status)
      end
    end
  end
  return byPackage
end

---Print one line per test of a package report.
---@param packageReport table
local function printTestLines(packageReport)
  for _, suite in ipairs(packageReport.suites) do
    for _, test in ipairs(suite.tests) do
      local line = (STATUS_LABELS[test.status] or test.status)
        .. " "
        .. suite.name
        .. ": "
        .. test.name
      if type(test.message) == "string" then
        line = line .. " -- " .. test.message
      end
      say(line)
    end
  end
end

---Print the totals line of one package, or of one entry of the saved results
---(a combat run's key carries `:combat`).
---@param label string
---@param totals table
local function printTotalsLine(label, totals)
  say(
    ("%s: %d passed, %d failed, %d skipped, %d timed out (%d tests)"):format(
      label,
      totals.passed,
      totals.failed,
      totals.skipped,
      totals.timeout,
      totals.tests
    )
  )
end

---The key of a package's entry in the saved results for a run mode.
---@param packageId string
---@param mode string
---@return string
local function resultsKey(packageId, mode)
  if mode == COMBAT_MODE then
    return packageId .. COMBAT_RESULTS_SUFFIX
  end
  return packageId
end

---Print and save the results of the run `/mct run` started.
---@param report TestKit.Report
local function recordFinishedRun(report)
  local run = activeRun
  if run == nil then
    return
  end
  activeRun = nil
  restoreRunawayThreshold(run.previousRunawayThreshold)

  local byPackage = reportsByPackage(report)
  local saved = savedResults()
  for _, packageId in ipairs(run.packageIds) do
    local packageReport = byPackage[packageId]
      or {
        suites = {},
        totals = { suites = 0, tests = 0, passed = 0, failed = 0, skipped = 0, timeout = 0 },
      }
    local key = resultsKey(packageId, run.mode)
    printTestLines(packageReport)
    printTotalsLine(key, packageReport.totals)
    saved[key] = {
      schema = RESULTS_SCHEMA,
      package = packageId,
      mode = run.mode,
      installation = run.installation,
      client = run.client,
      report = packageReport,
    }
  end
  say("results saved in " .. SAVED_VARIABLES_NAME .. "; /reload or log out to write them to disk.")
end

-- Commands ----------------------------------------------------------------------------

---Whether `packageId` has at least one registered suite.
---@param packageId string
---@return boolean
local function hasSuites(packageId)
  return suiteNamesByPackage[packageId] ~= nil
end

---Whether a run is started or waiting for combat; says so when it is.
---@return boolean
local function refuseWhileBusy()
  if activeRun ~= nil then
    say(
      "a run is still in progress ("
        .. joinNames(activeRun.packageIds)
        .. "); wait for its totals line."
    )
    return true
  end
  if pendingCombatRun ~= nil then
    say(
      "a combat run of "
        .. joinNames(pendingCombatRun.packageIds)
        .. " is waiting for combat; enter combat or wait for it to give up."
    )
    return true
  end
  return false
end

---The suites a run of `packageId` queues in `mode`.
---@param packageId string
---@param mode string
---@return string[]
local function suitesForMode(packageId, mode)
  if mode == COMBAT_MODE then
    return combatSuiteNamesByPackage[packageId] or {}
  end
  return suiteNamesByPackage[packageId]
end

---Queue the suites of the given packages that `mode` runs and remember the run.
---@param selectedIds string[]
---@param mode string `DEFAULT_MODE` or `COMBAT_MODE`
local function startRun(selectedIds, mode)
  if refuseWhileBusy() then
    return
  end

  -- Earlier results would otherwise be part of the next report.
  TestKit:Reset()
  activeRun = {
    packageIds = selectedIds,
    mode = mode,
    client = collectClientFacts(),
    installation = installationFacts(),
    previousRunawayThreshold = relaxRunawayThreshold(),
  }

  local suiteCount = 0
  for _, packageId in ipairs(selectedIds) do
    for _, suiteName in ipairs(suitesForMode(packageId, mode)) do
      local queued = TestKit:Run(suiteName)
      if type(queued) == "number" then
        suiteCount = suiteCount + queued
      end
    end
  end

  if suiteCount == 0 then
    restoreRunawayThreshold(activeRun.previousRunawayThreshold)
    activeRun = nil
    say("nothing was queued for " .. joinNames(selectedIds) .. ".")
    return
  end
  say(
    ("running %s%s: %d suites. Results follow when every test has finished."):format(
      joinNames(selectedIds),
      mode == COMBAT_MODE and " (combat suites)" or "",
      suiteCount
    )
  )
end

---Whether the client reports combat lockdown right now.
---@return boolean
local function inCombatLockdown()
  local probe = readHost("InCombatLockdown")
  return type(probe) == "function" and probe() == true
end

---Stop waiting for combat: disconnect the event and cancel the timer.
local function cancelPendingCombatRun()
  local pending = pendingCombatRun
  pendingCombatRun = nil
  if pending == nil then
    return
  end
  if pending.connection ~= nil then
    pending.connection:Disconnect()
  end
  if pending.timer ~= nil then
    pending.timer:Cancel()
  end
end

---Call the `prepare` functions of the packages' combat suites, out of combat.
---Returns `false` and says why when one raised; nothing is run then.
---@param selectedIds string[]
---@return boolean
local function prepareCombatSuites(selectedIds)
  for _, packageId in ipairs(selectedIds) do
    for _, prepare in ipairs(combatPreparationsByPackage[packageId] or {}) do
      local succeeded, problem = pcall(prepare)
      if not succeeded then
        say(
          ("the combat preparation of %s raised, so nothing was run: %s"):format(
            packageId,
            tostring(problem)
          )
        )
        return false
      end
    end
  end
  return true
end

---Start the combat suites of `selectedIds` now when the player is in combat,
---otherwise prepare them and wait at most `COMBAT_WAIT_SECONDS` for
---PLAYER_REGEN_DISABLED. The client raises that event before it applies the
---lockdown; the suites run in later frames, when `InCombatLockdown()` answers
---`true`. A wait that times out runs and saves nothing.
---@param selectedIds string[]
local function startCombatRun(selectedIds)
  if refuseWhileBusy() then
    return
  end
  if inCombatLockdown() then
    startRun(selectedIds, COMBAT_MODE)
    return
  end
  if type(EventKit) == "nil" or type(TimerKit) == "nil" then
    say(
      "a combat run needs EventKit API 1 and TimerKit API 1 in the MoltenCodes addon; reinstall it."
    )
    return
  end
  if not prepareCombatSuites(selectedIds) then
    return
  end

  local pending = { packageIds = selectedIds }
  pendingCombatRun = pending
  pending.connection = EventKit:Once("PLAYER_REGEN_DISABLED", function()
    if pendingCombatRun ~= pending then
      return
    end
    cancelPendingCombatRun()
    startRun(selectedIds, COMBAT_MODE)
  end)
  pending.timer = TimerKit:After(COMBAT_WAIT_SECONDS, function()
    if pendingCombatRun ~= pending then
      return
    end
    cancelPendingCombatRun()
    say(
      ("combat did not start within %d seconds; nothing was run or saved for %s."):format(
        COMBAT_WAIT_SECONDS,
        joinNames(selectedIds)
      )
    )
  end)
  say(
    ("waiting up to %d seconds for combat: attack a training dummy now. The combat suites of %s start when combat begins."):format(
      COMBAT_WAIT_SECONDS,
      joinNames(selectedIds)
    )
  )
end

---The packages among `candidates` that registered at least one combat suite.
---@param candidates string[]
---@return string[]
local function packagesWithCombatSuites(candidates)
  local selected = {}
  for _, packageId in ipairs(candidates) do
    if combatSuiteNamesByPackage[packageId] ~= nil then
      selected[#selected + 1] = packageId
    end
  end
  return selected
end

---`/mct run combat` and `/mct run <package> combat`.
---@param packageId string|nil `nil` for every loaded package.
local function commandRunCombat(packageId)
  local candidates = packageIds
  if packageId ~= nil then
    candidates = { packageId }
  end
  local selected = packagesWithCombatSuites(candidates)
  if #selected == 0 then
    local withCombat = packagesWithCombatSuites(packageIds)
    say(
      ("no combat suites for %s; loaded packages with combat suites: %s."):format(
        packageId or "any loaded package",
        #withCombat > 0 and joinNames(withCombat) or "none"
      )
    )
    return
  end
  startCombatRun(selected)
end

---`/mct run [package] [combat]`.
---@param argument string
local function commandRun(argument)
  if #packageIds == 0 then
    say("no package test addon is loaded, so there is nothing to run.")
    return
  end
  local first, second = argument:match("^(%S*)%s*(%S*)")
  if first == COMBAT_MODE and second == "" then
    commandRunCombat(nil)
    return
  end
  if first == "" then
    startRun(packageIds, DEFAULT_MODE)
    return
  end
  if not hasSuites(first) then
    say(('no test suites for package "%s"; loaded: %s.'):format(first, joinNames(packageIds)))
    return
  end
  if second == COMBAT_MODE then
    commandRunCombat(first)
    return
  end
  if second ~= "" then
    say(('unknown run mode "%s"; the only mode is %s.'):format(second, COMBAT_MODE))
    return
  end
  startRun({ first }, DEFAULT_MODE)
end

---`/mct list`.
local function commandList()
  if #packageIds == 0 then
    say("no package test addon is loaded.")
  end
  for _, packageId in ipairs(packageIds) do
    local line = packageId .. ": " .. joinNames(suiteNamesByPackage[packageId])
    local combatSuites = combatSuiteNamesByPackage[packageId]
    if combatSuites ~= nil then
      line = line .. "; combat suites: " .. joinNames(combatSuites)
    end
    say(line)
  end
  if expectedPackages() == nil then
    say("Expected.lua is missing; install with python3 -m tooling.client.install.")
  end
end

---`/mct report`: the totals and failures kept in the saved variable.
local function commandReport()
  local ids = savedPackageIds()
  if #ids == 0 then
    say("no saved results; run /mct run first.")
    return
  end
  local saved = savedResults()
  for _, packageId in ipairs(ids) do
    local entry = saved[packageId]
    local report = type(entry) == "table" and entry.report or nil
    if type(report) == "table" and type(report.totals) == "table" then
      printTotalsLine(packageId, report.totals)
      for _, suite in ipairs(report.suites or {}) do
        for _, test in ipairs(suite.tests or {}) do
          if test.status ~= "passed" then
            local label = STATUS_LABELS[test.status] or tostring(test.status)
            say("  " .. label .. " " .. tostring(suite.name) .. ": " .. tostring(test.name))
          end
        end
      end
    end
  end
end

---`/mct clear`: forget every saved result.
local function commandClear()
  -- The saved variable is this addon's own global, named in its .toc.
  -- selene: allow(global_usage)
  rawset(_G, SAVED_VARIABLES_NAME, {})
  say("saved results cleared; /reload or log out to write the empty table to disk.")
end

---`/mct help`.
local function commandHelp()
  say(SLASH_COMMAND .. " run -- run every loaded package's suites")
  say(
    SLASH_COMMAND
      .. " run <package> -- run one package's suites, for example "
      .. SLASH_COMMAND
      .. " run registry"
  )
  say(
    SLASH_COMMAND
      .. " run <package> combat -- wait up to "
      .. COMBAT_WAIT_SECONDS
      .. " seconds for combat, then run the package's combat suites"
  )
  say(SLASH_COMMAND .. " run combat -- the same for every loaded package with combat suites")
  say(SLASH_COMMAND .. " list -- the loaded packages and their suites")
  say(SLASH_COMMAND .. " report -- the saved totals and every test that did not pass")
  say(SLASH_COMMAND .. " clear -- forget every saved result")
  say(SLASH_COMMAND .. " help -- this list")
end

--- `/mct` subcommands by name.
---@type table<string, fun(argument: string)>
local COMMANDS = {
  run = commandRun,
  list = commandList,
  report = commandReport,
  clear = commandClear,
  help = commandHelp,
}

---Dispatch one `/mct` line.
---@param input string
local function handleSlashCommand(input)
  local text = type(input) == "string" and input or ""
  local name, argument = text:match("^%s*(%S*)%s*(.-)%s*$")
  local command = COMMANDS[(name or ""):lower()]
  if command == nil then
    commandHelp()
    return
  end
  command(argument or "")
end

-- Public API for package test addons ------------------------------------------------------

---The API a package test addon uses. Reach it through the `MoltenCodesTest`
---global after listing `## Dependencies: MoltenCodesTest` in its `.toc`.
---@class MoltenCodesTest.Harness
---@field RESULTS_SCHEMA integer Layout version of the saved results.
---@field NO_SECRETS_REASON string The skip reason of a test that needs a secret value on a client that makes none.
local Harness = {
  RESULTS_SCHEMA = RESULTS_SCHEMA,
  NO_SECRETS_REASON = "the client makes no secret values (issecretvalue does not report what secretwrap returns as secret)",
}

---Options a test addon may pass to `Harness:Suite`.
---@class MoltenCodesTest.SuiteOptions
---@field timeoutSeconds number|nil How long one test may take, forwarded to TestKit (10 seconds by default).
---@field combat boolean|nil `true` for a combat suite: `/mct run <package> combat` runs it once the player is in combat; a default run runs it too.
---@field prepare fun()|nil Only with `combat = true`: called out of combat when a combat run is requested, before the harness waits, for set-up the client allows only out of combat.

---Check the harness's own options, `combat` and `prepare`, raising at the test
---addon's line when they are malformed.
---@param options MoltenCodesTest.SuiteOptions
local function checkCombatOptions(options)
  local combat = options.combat
  if type(combat) ~= "nil" and type(combat) ~= "boolean" then
    error("MoltenCodesTest:Suite options.combat must be a boolean or nil", 4)
  end
  local prepare = options.prepare
  if type(prepare) ~= "nil" then
    if type(prepare) ~= "function" then
      error("MoltenCodesTest:Suite options.prepare must be a function or nil", 4)
    end
    if combat ~= true then
      error("MoltenCodesTest:Suite options.prepare needs options.combat = true", 4)
    end
  end
end

---Check the optional `options` of `Harness:Suite` and return the TestKit suite
---options they add up to, raising at the test addon's line otherwise.
---@param addonName string
---@param options MoltenCodesTest.SuiteOptions|nil
---@return table testKitOptions
local function suiteOptions(addonName, options)
  local testKitOptions = { phase = "ready", addonName = addonName }
  if type(options) == "nil" then
    return testKitOptions
  end
  if type(options) ~= "table" then
    error("MoltenCodesTest:Suite options must be a table or nil", 3)
  end
  for name in pairs(options) do
    if not SUITE_OPTION_NAMES[name] then
      error("MoltenCodesTest:Suite options." .. tostring(name) .. " is not an option", 3)
    end
  end
  checkCombatOptions(options)
  local timeoutSeconds = options.timeoutSeconds
  if type(timeoutSeconds) ~= "nil" then
    if
      type(timeoutSeconds) ~= "number"
      or not (timeoutSeconds > 0 and timeoutSeconds < math.huge)
    then
      error("MoltenCodesTest:Suite options.timeoutSeconds must be a finite number above 0", 3)
    end
    testKitOptions.timeoutSeconds = timeoutSeconds
  end
  return testKitOptions
end

---Register a TestKit suite that tests `packageId`.
---
---The suite is named `<packageId>.<part>` and waits for the `ready` phase of
---`addonName`, the calling test addon (`local addonName = ...`). `/mct run
---<packageId>` runs every suite registered for that package. `options` is
---optional; `timeoutSeconds` lengthens TestKit's 10-second limit per test for
---a suite whose test waits for the player, and `combat = true` (with an
---optional `prepare`) makes it a combat suite (see tests/client/README.md,
---"Combat runs").
---@param packageId string The framework package the suite tests, for example `"registry"`.
---@param part string What part of it, for example `"lookup"`.
---@param addonName string The test addon's folder name.
---@param options MoltenCodesTest.SuiteOptions|nil
---@return TestKit.Suite
function Harness:Suite(packageId, part, addonName, options)
  if self ~= Harness then
    error("MoltenCodesTest:Suite must be called on the MoltenCodesTest harness", 2)
  end
  if type(packageId) ~= "string" or not packageId:match(IDENTIFIER_PATTERN) then
    error("MoltenCodesTest:Suite packageId must match " .. IDENTIFIER_PATTERN, 2)
  end
  if type(part) ~= "string" or not part:match(IDENTIFIER_PATTERN) then
    error("MoltenCodesTest:Suite part must match " .. IDENTIFIER_PATTERN, 2)
  end
  if type(addonName) ~= "string" or addonName == "" then
    error("MoltenCodesTest:Suite addonName must be the test addon's folder name", 2)
  end

  local testKitOptions = suiteOptions(addonName, options)

  local suiteName = packageId .. "." .. part
  local suite, problem = TestKit:Suite(suiteName, testKitOptions)
  if type(suite) == "nil" then
    error(
      ('MoltenCodesTest:Suite could not register "%s" (%s)'):format(suiteName, tostring(problem)),
      2
    )
  end

  if suiteNamesByPackage[packageId] == nil then
    suiteNamesByPackage[packageId] = {}
    packageIds[#packageIds + 1] = packageId
  end
  local names = suiteNamesByPackage[packageId]
  names[#names + 1] = suiteName
  packageBySuiteName[suiteName] = packageId

  if type(options) == "table" and options.combat == true then
    local combatNames = combatSuiteNamesByPackage[packageId] or {}
    combatSuiteNamesByPackage[packageId] = combatNames
    combatNames[#combatNames + 1] = suiteName
    if type(options.prepare) == "function" then
      local preparations = combatPreparationsByPackage[packageId] or {}
      combatPreparationsByPackage[packageId] = preparations
      preparations[#preparations + 1] = options.prepare
    end
  end
  return suite
end

---End the running test as skipped, naming why: for a test whose precondition
---only the moment of the run can tell, such as the player being in combat.
---
---TestKit decides a skip when a test is registered, not while it runs, so
---this fails the test with `reason` behind a marker, and the harness reports
---that failure as `SKIP` with `reason`, in the chat and in the saved results.
---Nothing after the call runs; the suite's After hooks still do. Keep `reason`
---under about 150 bytes: TestKit cuts a failure message at 256.
---@param ctx TestKit.Context The context of the running test.
---@param reason string Why the test was not exercised.
function Harness:SkipTest(ctx, reason)
  if self ~= Harness then
    error("MoltenCodesTest:SkipTest must be called on the MoltenCodesTest harness", 2)
  end
  if type(reason) ~= "string" or reason == "" then
    error("MoltenCodesTest:SkipTest reason must be a non-empty string", 2)
  end
  ctx:Fail(RUNTIME_SKIP_MARKER .. reason)
end

---The apiKit flavour ID of the running client, from `WOW_PROJECT_ID`:
---`"retail"`, `"classic-era"` or `"classic-mop"`, or `nil` for a client the
---framework does not promise. A test that skips on a flavour names the missing
---capability in its reason; this is for the rare test whose expected value
---differs by flavour.
---@return string|nil
function Harness:GetFlavour()
  if self ~= Harness then
    error("MoltenCodesTest:GetFlavour must be called on the MoltenCodesTest harness", 2)
  end
  return clientFlavour()
end

--- The answer of `Harness:CanMakeSecrets`, measured once, or `nil` before.
---@type boolean|nil
local canMakeSecretsAnswer = nil

--- The plain value the secret probe wraps.
local SECRET_PROBE_VALUE = true

---Whether this client can make a secret value: it has `issecretvalue` and
---`secretwrap`, and `issecretvalue` reports what `secretwrap` returns as
---secret. Classic Era and Mists Classic document both functions too, so their
---presence alone does not prove the client applies secrets; a suite that needs
---a secret skips with `Harness.NO_SECRETS_REASON` when this answers `false`.
---Measured on the first call and remembered for the session.
---@return boolean
function Harness:CanMakeSecrets()
  if self ~= Harness then
    error("MoltenCodesTest:CanMakeSecrets must be called on the MoltenCodesTest harness", 2)
  end
  if canMakeSecretsAnswer == nil then
    local isSecretValue = readHost("issecretvalue")
    local secretWrap = readHost("secretwrap")
    local answer = false
    if type(isSecretValue) == "function" and type(secretWrap) == "function" then
      local succeeded, wrapped = pcall(secretWrap, SECRET_PROBE_VALUE)
      -- issecretvalue answers a plain boolean for any value, secret or not.
      answer = succeeded and isSecretValue(wrapped) == true
    end
    canMakeSecretsAnswer = answer
  end
  return canMakeSecretsAnswer
end

---Whether the running `/mct run` is a combat run.
---@return boolean
function Harness:IsCombatRun()
  if self ~= Harness then
    error("MoltenCodesTest:IsCombatRun must be called on the MoltenCodesTest harness", 2)
  end
  return activeRun ~= nil and activeRun.mode == COMBAT_MODE
end

---The packages Expected.lua lists, or `nil` when it was not installed. The
---array is shared: read it, do not change it.
---@return MoltenCodesTest.ExpectedPackage[]|nil
function Harness:GetExpectedPackages()
  return expectedPackages()
end

---The names of every global the harness itself publishes, so a test of the
---framework's globals can tell the harness's apart.
---@return string[]
function Harness:GetOwnGlobalNames()
  return { PUBLIC_NAME, SAVED_VARIABLES_NAME, "SLASH_" .. SLASH_KEY .. "1" }
end

-- Wiring ------------------------------------------------------------------------------------

if type(readHost(PUBLIC_NAME)) ~= "nil" then
  error(
    ADDON_NAME
      .. ": the global "
      .. PUBLIC_NAME
      .. " is already taken; is the harness installed twice?",
    0
  )
end
-- Package test addons reach the harness through this one documented global.
-- selene: allow(global_usage)
rawset(_G, PUBLIC_NAME, Harness)

-- The client finds slash commands through these two globals.
-- selene: allow(global_usage)
rawset(_G, "SLASH_" .. SLASH_KEY .. "1", SLASH_COMMAND)
local slashCommandList = readHost("SlashCmdList")
if type(slashCommandList) == "table" then
  slashCommandList[SLASH_KEY] = handleSlashCommand
end

TestKit:OnFinished(recordFinishedRun)

-- Package test addons depend on this addon, so they load after it and before
-- the login: by the ready phase every suite is registered.
LifecycleKit:ForAddon(ADDON_NAME):OnReady(function()
  if #packageIds == 0 then
    say(
      "no package test addon is loaded; install one with python3 -m tooling.client.install --package <id>."
    )
    return
  end
  say(
    ("test suites loaded for %s. Type %s run %s to run them; %s help lists every command."):format(
      joinNames(packageIds),
      SLASH_COMMAND,
      #packageIds == 1 and packageIds[1] or "<package>",
      SLASH_COMMAND
    )
  )
  if expectedPackages() == nil then
    say("Expected.lua is missing; install with python3 -m tooling.client.install.")
  end
end)
