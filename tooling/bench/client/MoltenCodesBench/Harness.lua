-- MoltenCodes Bench: Harness.lua
--
-- The in-client benchmark harness (docs/BENCHMARKS.md, "In-client runner").
--
-- The host runner measures every case in a fresh Lua process. The client's
-- equivalent of a fresh process is a fresh UI session, so this harness runs
-- exactly one item per session and reloads between items:
--
--   * `/mcb run <workload> <kits|ace3|both> [rounds]` queues the workload: first
--     one "checks" item per side (it runs the correctness checks and lists the
--     side's cases), then one item per case, side and round, the sides
--     interleaved and the first side alternating from case to case and round
--     to round, as the host runner orders its processes;
--   * each item loads exactly one side addon (MoltenCodesBench_Kits or
--     MoltenCodesBench_Ace3, both load-on-demand), so the two sides never share
--     a session, a heap or a memory figure, builds the workload through the
--     client host (`ClientHost`) and measures (`ClientBench`);
--   * the item's result is saved in `MoltenCodesBenchResults` with the client's
--     facts and the installation (commit, flavour folder), and a panel asks the
--     owner to reload for the next item; after the reload the harness waits
--     until the session has settled and runs the next item on its own;
--   * `/mcb report` prints what is saved; `python3 -m tooling.bench.client_report`
--     reads the saved variables into `tooling/bench/results/`.
--
-- Nothing runs at login unless a queue is waiting: a run loads a side and
-- freezes the client for the length of a batch, so it starts only when the
-- owner types `/mcb run`.
--
-- Load order (MoltenCodesBench.toc): Installation.lua (the installer's facts),
-- Loader.lua, the generated modules, then this file.

local ADDON_NAME, private = ...

--- The saved variable named by `## SavedVariables` in MoltenCodesBench.toc.
local SAVED_VARIABLES_NAME = "MoltenCodesBenchResults"

--- Layout version of `MoltenCodesBenchResults` and of each saved entry.
local RESULTS_SCHEMA = 1

--- The key of `/mcb` in `SlashCmdList`; the client reads `SLASH_<key>1`.
local SLASH_KEY = "MOLTENCODESBENCH"
local SLASH_COMMAND = "/mcb"

--- Printed before every chat line, so harness output is easy to find.
local CHAT_PREFIX = "|cffff9933MoltenCodes Bench|r: "

--- The protocol of a batch case, as the host runner's defaults per round.
local WARMUP_BATCHES = 2
local TIMED_BATCHES = 5

--- The most rounds one `/mcb run` accepts; each round is a session per case and side.
local MAX_ROUNDS = 5

--- Seconds after entering the world before an item starts, so login work,
--- the first garbage collections and CommKit's zoning throttle are over.
local SETTLE_SECONDS = 10

--- Starts the message of an error that refuses to load a side. A refusal is
--- about the session, not the measurement: the run stops and nothing is saved.
local REFUSAL_MARKER = "[MoltenCodesBench refused] "

--- The words `/mcb run` accepts for a side, and the side each stands for.
local SIDE_WORDS = { kits = "moltencodes", ace3 = "ace3" }

--- The side words in report order, and the word for each side.
local SIDE_ORDER = { "moltencodes", "ace3" }
local WORD_FOR_SIDE = { moltencodes = "kits", ace3 = "ace3" }

--- Addons that must not be loaded in a benchmark session: the standalone
--- framework and the real-client test harness would share Kits with the
--- measured side.
local CONFLICTING_ADDONS = { "MoltenCodes", "MoltenCodesTest" }

--- Libraries that must not be in LibStub before the Ace3 side loads: a newer
--- copy from another addon would make the pinned files no-ops.
local ACE3_LIBRARY_NAMES = {
  "CallbackHandler-1.0",
  "AceEvent-3.0",
  "AceTimer-3.0",
  "AceDB-3.0",
  "AceSerializer-3.0",
  "AceComm-3.0",
  "AceAddon-3.0",
  "AceHook-3.0",
  "AceConsole-3.0",
  "AceLocale-3.0",
  "AceBucket-3.0",
  "AceConfigRegistry-3.0",
  "AceConfigCmd-3.0",
  "AceDBOptions-3.0",
  "AceGUI-3.0",
}

--- Console variables that shape frame times, recorded with every entry.
local FRAME_RATE_VARIABLES =
  { "maxFPS", "maxFPSBk", "useMaxFPS", "useMaxFPSBk", "targetFPS", "useTargetFPS", "vsync" }

--- The operating-system probes some clients publish, in the order they are
--- asked, with the name the saved results record.
local OS_PROBES = {
  { functionName = "IsMacClient", name = "macOS" },
  { functionName = "IsWindowsClient", name = "Windows" },
  { functionName = "IsLinuxClient", name = "Linux" },
}

-- Client access ------------------------------------------------------------------

---Read a client global, or `nil`.
---@param name string
---@return any
local function readHost(name)
  -- The harness runs in the World of Warcraft client, whose API lives only in the global table.
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

---Write one of this addon's own globals (its saved variable, its slash command).
---@param name string
---@param value any
local function writeHost(name, value)
  -- A saved variable and a slash command are globals the client reads by name.
  -- selene: allow(global_usage)
  rawset(_G, name, value)
end

---Call a client function when it exists; `nil` otherwise.
---@param name string a global function, or `Namespace.Function`
---@return any
local function callHost(name, ...)
  local namespace, member = name:match("^([^.]+)%.(.+)$")
  local target
  if namespace ~= nil then
    local namespaceTable = readHost(namespace)
    target = type(namespaceTable) == "table" and namespaceTable[member] or nil
  else
    target = readHost(name)
  end
  if type(target) ~= "function" then
    return nil
  end
  return target(...)
end

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

-- Chat output ----------------------------------------------------------------------

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

-- What the installer recorded ---------------------------------------------------------

---@return table installation `{ commit, dirty, flavourDirectory, installedAt }`
local function installation()
  return type(private.installation) == "table" and private.installation or {}
end

---@param side string `"moltencodes"` or `"ace3"`
---@return table|nil info `{ addon, files, packages }`
local function sideInfo(side)
  return type(private.sides) == "table" and private.sides[side] or nil
end

---The catalogue entry of a workload, or `nil`.
---@param name string
---@return table|nil
local function findWorkload(name)
  for _, workload in ipairs(private.workloads or {}) do
    if workload.name == name then
      return workload
    end
  end
  return nil
end

-- Saved results ------------------------------------------------------------------------

---The saved-variables table, created when the client had none to restore.
---
---Read on every use: the client assigns the restored table just before this
---addon's `ADDON_LOADED`, after this file ran.
---@return table
local function saved()
  local results = readHost(SAVED_VARIABLES_NAME)
  if type(results) ~= "table" or results.schema ~= RESULTS_SCHEMA then
    results = { schema = RESULTS_SCHEMA, entries = {} }
    writeHost(SAVED_VARIABLES_NAME, results)
  end
  if type(results.entries) ~= "table" then
    results.entries = {}
  end
  return results
end

---The queue `/mcb run` saved, or `nil`.
---@return table|nil
local function queue()
  return saved().queue
end

-- Client facts ---------------------------------------------------------------------------

---The operating system the client reports, or `nil`.
---@return string|nil
local function clientOperatingSystem()
  for _, probe in ipairs(OS_PROBES) do
    if callHost(probe.functionName) == true then
      return probe.name
    end
  end
  return nil
end

---The facts of the client: build, project, operating system, locale, date.
---@return table
local function clientFacts()
  local facts = {}
  local version, build, buildDate, interface = callHost("GetBuildInfo")
  facts.version = plainValue(version)
  facts.build = plainValue(build)
  facts.buildDate = plainValue(buildDate)
  facts.interface = plainValue(interface)
  facts.projectId = plainValue(readHost("WOW_PROJECT_ID"))
  facts.os = clientOperatingSystem()
  facts.testBuild = plainValue(callHost("IsTestBuild"))
  facts.locale = plainValue(callHost("GetLocale"))
  -- `date` is the client's name for Lua's `os.date`; the client has no `os`.
  facts.date = plainValue(callHost("date", "%Y-%m-%d %H:%M:%S"))
  return facts
end

---The console variables that shape frame times, as the client reports them.
---@return table<string, string>
local function frameRateSettings()
  local settings = {}
  for _, name in ipairs(FRAME_RATE_VARIABLES) do
    settings[name] = plainValue(callHost("C_CVar.GetCVar", name))
  end
  return settings
end

---The names of every loaded addon, sorted.
---@return string[]
local function loadedAddons()
  local names = {}
  local count = callHost("C_AddOns.GetNumAddOns") or 0
  for index = 1, count do
    local name = callHost("C_AddOns.GetAddOnInfo", index)
    if type(name) == "string" and callHost("C_AddOns.IsAddOnLoaded", index) then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  return names
end

---Whether an addon is loaded.
---@param name string
---@return boolean
local function isLoaded(name)
  return callHost("C_AddOns.IsAddOnLoaded", name) == true
end

---An addon's memory in kilobytes after a fresh count, or `nil`.
---@param name string
---@return number|nil
local function addonKilobytes(name)
  callHost("UpdateAddOnMemoryUsage")
  return plainValue(callHost("GetAddOnMemoryUsage", name)) --[[@as number|nil]]
end

-- Session state ------------------------------------------------------------------------

--- What this UI session has done. It is never saved: a reload starts a new one.
local session = {
  --- The side whose addon this session loaded, or `nil`.
  loadedSide = nil,
  --- Whether an item already ran in this session.
  ran = false,
  --- `GetTime()` when the session entered the world, or `nil` before.
  enteredWorldAt = nil,
  --- The item running now, or `nil`.
  running = nil,
}

-- The reload panel ---------------------------------------------------------------------

local panel = nil

---Hide the panel, when it exists.
local function hidePanel()
  if panel ~= nil then
    panel:Hide()
  end
end

---Show the panel that asks for a reload, with `text` above its buttons.
---
---Reloading is the owner's click: a reload from a button is a hardware event,
---which the client always allows.
---@param text string
---@param onStop fun()
local function showPanel(text, onStop)
  if panel == nil then
    local createFrame = readHost("CreateFrame")
    panel = createFrame("Frame", nil, readHost("UIParent"))
    panel:SetSize(360, 110)
    panel:SetPoint("TOP", 0, -140)
    panel:SetFrameStrata("DIALOG")
    local background = panel:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints()
    background:SetColorTexture(0, 0, 0, 0.85)
    panel.text = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    panel.text:SetPoint("TOPLEFT", 12, -12)
    panel.text:SetPoint("TOPRIGHT", -12, -12)
    panel.text:SetJustifyH("LEFT")
    local reload = createFrame("Button", nil, panel, "UIPanelButtonTemplate")
    reload:SetSize(140, 24)
    reload:SetPoint("BOTTOMLEFT", 12, 12)
    reload:SetText("Reload and go on")
    reload:SetScript("OnClick", function()
      callHost("ReloadUI")
    end)
    panel.stop = createFrame("Button", nil, panel, "UIPanelButtonTemplate")
    panel.stop:SetSize(140, 24)
    panel.stop:SetPoint("BOTTOMRIGHT", -12, 12)
    panel.stop:SetText("Stop the run")
  end
  panel.stop:SetScript("OnClick", onStop)
  panel.text:SetText(text)
  panel:Show()
end

-- Planning ------------------------------------------------------------------------------

---Add the case items once every side's checks item listed its cases.
---
---The order is the host runner's: per round, per case, both sides one after
---the other, the first side alternating from case to case and round to round,
---so a change in the session's conditions falls on both sides alike.
---@param plan table the saved queue
local function planCases(plan)
  local names, seen = {}, {}
  for _, side in ipairs(plan.sides) do
    for _, name in ipairs(plan.listed[side] or {}) do
      if not seen[name] then
        seen[name] = true
        names[#names + 1] = name
      end
    end
  end
  local listedBySide = {}
  for _, side in ipairs(plan.sides) do
    listedBySide[side] = {}
    for _, name in ipairs(plan.listed[side] or {}) do
      listedBySide[side][name] = true
    end
  end
  for round = 1, plan.rounds do
    for index, name in ipairs(names) do
      local firstSideFirst = (index + round) % 2 == 0
      for position = 1, #plan.sides do
        local sidePosition = firstSideFirst and position or #plan.sides - position + 1
        local side = plan.sides[sidePosition]
        if listedBySide[side][name] then
          plan.items[#plan.items + 1] =
            { workload = plan.workload, side = side, step = "case", case = name, round = round }
        end
      end
    end
  end
  plan.total = plan.done + #plan.items
  plan.planned = true
end

-- Running one item ----------------------------------------------------------------------

---Collect every frame that exists now, so the client host can tell the
---side's frames from the ones that were there before it loaded.
---@return table<table, boolean>
local function snapshotFrames()
  local frames = setmetatable({}, { __mode = "k" })
  local enumerate = readHost("EnumerateFrames")
  if type(enumerate) ~= "function" then
    return frames
  end
  local frame = enumerate()
  while frame ~= nil do
    frames[frame] = true
    frame = enumerate(frame)
  end
  return frames
end

---The loaded addons that are not this benchmark's, for a refusal message.
---@return string[]
local function otherAddons()
  local others = {}
  for _, name in ipairs(loadedAddons()) do
    if name ~= ADDON_NAME and name:sub(1, #ADDON_NAME + 1) ~= ADDON_NAME .. "_" then
      others[#others + 1] = name
    end
  end
  return others
end

---Why the side cannot be loaded cleanly in this session, or `nil`.
---@param side string
---@return string|nil
local function refusal(side)
  if callHost("InCombatLockdown") == true then
    return "the player is in combat"
  end
  for _, name in ipairs(CONFLICTING_ADDONS) do
    if isLoaded(name) then
      return "the " .. name .. " addon is loaded; disable it for benchmark sessions"
    end
  end
  for _, otherSide in ipairs(SIDE_ORDER) do
    local info = sideInfo(otherSide)
    if otherSide ~= side and info ~= nil and isLoaded(info.addon) then
      return "the other side (" .. info.addon .. ") is loaded in this session; reload first"
    end
  end
  if side == "moltencodes" and readHost("MoltenCodes") ~= nil then
    return "another addon already loaded MoltenCodes Kits (loaded now: "
      .. table.concat(otherAddons(), ", ")
      .. "); disable it for benchmark sessions"
  end
  local libStub = readHost("LibStub")
  if side == "ace3" and type(libStub) == "table" and type(libStub.libs) == "table" then
    for _, name in ipairs(ACE3_LIBRARY_NAMES) do
      if libStub.libs[name] ~= nil then
        return "another addon already loaded "
          .. name
          .. " (loaded now: "
          .. table.concat(otherAddons(), ", ")
          .. "); disable it for benchmark sessions"
      end
    end
  end
  return nil
end

---Load the side addon once per session and record what that took.
---@param side string
---@param facts table the entry's session facts, filled in
local function loadSide(side, facts)
  local info = sideInfo(side)
  if info == nil then
    error("the installer recorded no " .. side .. " side; reinstall the benchmark", 0)
  end
  if session.loadedSide == side then
    return
  end
  local problem = refusal(side)
  if problem ~= nil then
    error(REFUSAL_MARKER .. problem, 0)
  end
  session.baselineFrames = snapshotFrames()
  local clock = readHost("debugprofilestop")
  local started = clock()
  local loaded, reason = callHost("C_AddOns.LoadAddOn", info.addon)
  if not loaded and reason == "DISABLED" then
    callHost("C_AddOns.EnableAddOn", info.addon)
    loaded, reason = callHost("C_AddOns.LoadAddOn", info.addon)
  end
  facts.sideLoadMilliseconds = clock() - started
  if not loaded then
    error("the " .. info.addon .. " addon did not load: " .. tostring(reason), 0)
  end
  session.loadedSide = side
  facts.sideKilobytesAfterLoad = addonKilobytes(info.addon)
end

---The session facts saved with every entry.
---@return table
local function sessionFacts()
  local startedAt = readHost("GetTime")()
  return {
    secondsSinceEnteringWorld = session.enteredWorldAt and startedAt - session.enteredWorldAt,
    framerate = plainValue(callHost("GetFramerate")),
    frameRateSettings = frameRateSettings(),
    harnessKilobytes = addonKilobytes(ADDON_NAME),
  }
end

---The body of one item, run as a coroutine: load the side, build the
---workload, run its checks or measure one case. Errors end the coroutine and
---are recorded by `finishItem`.
---@param item table the queue item
---@param entry table the entry being built; filled in as the item goes
local function runItem(item, entry)
  local ClientBench = private.Require("ClientBench")
  local ClientHost = private.Require("ClientHost")
  local catalogue = findWorkload(item.workload)
  if catalogue == nil then
    error("unknown workload " .. tostring(item.workload), 0)
  end

  loadSide(item.side, entry.session)
  -- Taken after the load, so the list shows the side addon beside everything else.
  entry.session.addonsLoaded = loadedAddons()
  coroutine.yield()

  local info = sideInfo(item.side)
  if info == nil then
    error("the installer recorded no " .. item.side .. " side; reinstall the benchmark", 0)
  end
  local host = ClientHost.New({
    side = item.side,
    sideAddon = info.addon,
    harnessAddon = ADDON_NAME,
    files = info.files or {},
    packages = info.packages or {},
    baselineFrames = session.baselineFrames or {},
  })
  entry.previousHandler = callHost("geterrorhandler")
  callHost("seterrorhandler", host.CaptureError)
  entry.session.errorsCaptured = callHost("geterrorhandler") == host.CaptureError

  local settings = { warmup = WARMUP_BATCHES, repetitions = TIMED_BATCHES, ace3 = "Ace3" }
  local suite = private.Require(catalogue.module).Build(item.side, host, settings)
  entry.suite = suite

  if item.step == "checks" then
    local names = {}
    for index, case in ipairs(suite.cases) do
      names[index] = case.name
    end
    entry.cases = names
    entry.checks = suite.checks()
  else
    local selected = nil
    for _, case in ipairs(suite.cases) do
      if case.name == item.case then
        selected = case
      end
    end
    if selected == nil then
      error("the " .. item.side .. " side has no case " .. tostring(item.case), 0)
    end
    local debugClock = readHost("debugprofilestop")
    local preciseTime = readHost("GetTimePreciseSec")
    entry.result = ClientBench.MeasureCase(selected, settings, {
      clock = debugClock,
      frameClock = type(preciseTime) == "function" and preciseTime or function()
        return debugClock() / 1000
      end,
      nextFrame = coroutine.yield,
    })
  end
  entry.errors = host.TakeReportedErrors()
end

---Save a finished item, advance the queue and ask for the next reload.
---@param item table
---@param entry table
---@param problem any the error that ended the item, or `nil`
local function finishItem(item, entry, problem)
  if entry.previousHandler ~= nil then
    callHost("seterrorhandler", entry.previousHandler)
  end
  if type(problem) == "string" and problem:sub(1, #REFUSAL_MARKER) == REFUSAL_MARKER then
    saved().queue = nil
    hidePanel()
    say(
      "the run stopped before measuring: "
        .. problem:sub(#REFUSAL_MARKER + 1)
        .. ". Fix it, reload and /mcb run again."
    )
    return
  end
  local suite = entry.suite
  local saving = {
    schema = RESULTS_SCHEMA,
    workload = item.workload,
    side = item.side,
    step = item.step,
    case = item.case,
    round = item.round,
    result = entry.result,
    checks = entry.checks,
    cases = entry.cases,
    errors = entry.errors,
    libraries = suite ~= nil and suite.libraries or nil,
    session = entry.session,
    client = clientFacts(),
    installation = installation(),
  }
  local label = item.workload
    .. " / "
    .. WORD_FOR_SIDE[item.side]
    .. " / "
    .. (item.case or "checks")
  if problem ~= nil then
    local ClientBench = private.Require("ClientBench")
    local reason = ClientBench.UnsupportedReason(problem)
    if reason ~= nil then
      saving.skipped = reason
      say(label .. ": not run in the client, it " .. reason)
    else
      saving.failed = tostring(problem)
      say(label .. ": |cffff3333failed|r: " .. tostring(problem))
    end
  else
    say(label .. ": done")
  end
  local results = saved()
  results.entries[#results.entries + 1] = saving
  -- What the installation carried (package versions, the Ace3 commit), once
  -- per installation rather than in every entry.
  local installedAt = installation().installedAt
  if installedAt ~= nil and type(private.installationDetails) == "table" then
    results.installationDetails = results.installationDetails or {}
    results.installationDetails[installedAt] = private.installationDetails
  end

  local plan = results.queue
  if plan == nil then
    return
  end
  plan.current = nil
  plan.done = plan.done + 1
  if item.step == "checks" then
    plan.listed[item.side] = entry.cases or {}
  end
  local checksLeft = false
  for _, queued in ipairs(plan.items) do
    if queued.step == "checks" then
      checksLeft = true
    end
  end
  if not checksLeft and not plan.planned then
    planCases(plan)
  end
  if #plan.items == 0 then
    results.queue = nil
    hidePanel()
    say(
      "the run of "
        .. plan.workload
        .. " is complete ("
        .. plan.done
        .. " sessions). /mcb report prints it; python3 -m tooling.bench.client_report saves it."
    )
    return
  end
  plan.awaitingReload = true
  showPanel(
    "MoltenCodes Bench: "
      .. plan.workload
      .. ", "
      .. plan.done
      .. " of "
      .. (plan.total or "?")
      .. " sessions done.\nEvery case runs in a fresh session: reload to run the next.",
    function()
      results.queue = nil
      hidePanel()
      say("the run was stopped; the saved entries are kept")
    end
  )
end

--- The frame whose `OnUpdate` drives the running item's coroutine.
local driver = nil

---Run the next queued item now.
local function startNextItem()
  local plan = queue()
  if plan == nil or #plan.items == 0 or session.running ~= nil then
    return
  end
  if session.ran then
    plan.awaitingReload = true
    say("this session already ran an item; reload (/mcb continue) to run the next")
    return
  end
  local item = table.remove(plan.items, 1)
  -- Saved until the item finishes, so a session that ends before then (a
  -- crash, a disconnect) is recorded as such after the next login.
  plan.current = item
  plan.awaitingReload = false
  session.ran = true
  hidePanel()
  say(
    "running "
      .. item.workload
      .. " / "
      .. WORD_FOR_SIDE[item.side]
      .. " / "
      .. (item.case or "checks")
      .. (item.round and (" (round " .. item.round .. ")") or "")
      .. "; the client may pause while a batch runs"
  )

  local entry = { session = sessionFacts() }
  local thread = coroutine.create(function()
    runItem(item, entry)
  end)
  session.running = { item = item, entry = entry, thread = thread }

  if driver == nil then
    driver = readHost("CreateFrame")("Frame")
  end
  driver:SetScript("OnUpdate", function()
    local running = session.running
    if running == nil then
      driver:SetScript("OnUpdate", nil)
      return
    end
    local ok, problem = coroutine.resume(running.thread)
    if not ok or coroutine.status(running.thread) == "dead" then
      session.running = nil
      driver:SetScript("OnUpdate", nil)
      finishItem(running.item, running.entry, not ok and problem or nil)
    end
  end)
end

---Start the next item once the session has settled and the player is out of combat.
local function startWhenSettled()
  local plan = queue()
  if plan == nil or session.running ~= nil then
    return
  end
  local now = readHost("GetTime")()
  local settledAt = (session.enteredWorldAt or now) + SETTLE_SECONDS
  local wait = settledAt - now
  if callHost("InCombatLockdown") == true then
    say("waiting for the end of combat before the next item")
    session.waitingForCombatEnd = true
    return
  end
  if wait <= 0 then
    startNextItem()
    return
  end
  say(string.format("the next item starts in %d s", math.ceil(wait)))
  readHost("C_Timer").After(wait, startNextItem)
end

-- Slash commands --------------------------------------------------------------------------

---Split a command line into words.
---@param line string
---@return string[]
local function words(line)
  local found = {}
  for word in line:gmatch("%S+") do
    found[#found + 1] = word
  end
  return found
end

---`/mcb list`
local function listWorkloads()
  say("workloads (/mcb run <workload> <kits|ace3|both> [rounds]):")
  for _, workload in ipairs(private.workloads or {}) do
    local origin = workload.origin == "shared" and "host workload" or "client only"
    say("  " .. workload.name .. " (" .. origin .. "): " .. workload.title)
  end
  for _, excluded in ipairs(private.notInClient or {}) do
    say("  |cff999999" .. excluded.name .. " is not run in the client: " .. excluded.reason .. "|r")
  end
end

---`/mcb run <workload> <side> [rounds]`
---@param arguments string[]
local function run(arguments)
  local workloadName, sideWord, roundsText = arguments[2], arguments[3], arguments[4]
  if workloadName == nil or findWorkload(workloadName) == nil then
    say("unknown workload " .. tostring(workloadName) .. "; /mcb list shows them")
    return
  end
  local sides
  if sideWord == "both" then
    sides = { "moltencodes", "ace3" }
  elseif SIDE_WORDS[sideWord or ""] ~= nil then
    sides = { SIDE_WORDS[sideWord] }
  else
    say("the side must be kits, ace3 or both")
    return
  end
  local rounds = tonumber(roundsText or "1")
  if rounds == nil or rounds < 1 or rounds > MAX_ROUNDS or rounds ~= math.floor(rounds) then
    say("rounds must be a whole number from 1 to " .. MAX_ROUNDS)
    return
  end
  if queue() ~= nil then
    say("a run is queued already; /mcb status shows it, /mcb stop drops it")
    return
  end
  for _, side in ipairs(sides) do
    if sideInfo(side) == nil then
      say("the " .. WORD_FOR_SIDE[side] .. " side is not installed; reinstall the benchmark")
      return
    end
  end

  local items = {}
  for _, side in ipairs(sides) do
    items[#items + 1] = { workload = workloadName, side = side, step = "checks" }
  end
  saved().queue = {
    workload = workloadName,
    sides = sides,
    rounds = rounds,
    items = items,
    listed = {},
    done = 0,
    planned = false,
  }
  if session.ran or session.loadedSide ~= nil then
    queue().awaitingReload = true
    showPanel(
      "MoltenCodes Bench: "
        .. workloadName
        .. " is queued.\nThis session already ran an item: reload to start.",
      function()
        saved().queue = nil
        hidePanel()
      end
    )
    return
  end
  startWhenSettled()
end

---`/mcb status`
local function status()
  local plan = queue()
  if plan == nil then
    say("nothing is queued")
    return
  end
  say(
    plan.workload
      .. ": "
      .. plan.done
      .. " sessions done, "
      .. #plan.items
      .. " queued"
      .. (plan.planned and "" or " before the cases are listed")
  )
end

---A short text for one saved case entry.
---@param entry table
---@return string
local function describeEntry(entry)
  if entry.skipped ~= nil then
    return "not in the client"
  end
  if entry.failed ~= nil then
    return "failed"
  end
  local result = entry.result or {}
  if result.kind == "frames" then
    local metrics = result.metrics or {}
    return string.format(
      "p95 %.1f ms, p99 %.1f ms",
      metrics.frameMillisecondsP95 or 0,
      metrics.frameMillisecondsP99 or 0
    )
  end
  if type(result.medianNanoseconds) == "number" then
    return string.format("%.1f ns/op", result.medianNanoseconds)
  end
  return "no data"
end

---`/mcb report`: the latest entry per workload, case and side of this installation.
local function report()
  local current = installation().installedAt
  local latest, order = {}, {}
  for _, entry in ipairs(saved().entries) do
    local installedAt = type(entry.installation) == "table" and entry.installation.installedAt
    if installedAt == current then
      local key = entry.workload .. " " .. (entry.case or "checks")
      if latest[key] == nil then
        latest[key] = {}
        order[#order + 1] = key
      end
      latest[key][entry.side] = entry
    end
  end
  if #order == 0 then
    say("no results saved for this installation yet")
    return
  end
  for _, key in ipairs(order) do
    local parts = {}
    for _, side in ipairs(SIDE_ORDER) do
      local entry = latest[key][side]
      if entry ~= nil then
        local text
        if entry.step == "checks" then
          local passed, total = 0, 0
          for _, check in ipairs(entry.checks or {}) do
            total = total + 1
            if check.passed then
              passed = passed + 1
            end
          end
          text = entry.failed and "failed" or (passed .. "/" .. total .. " checks")
        else
          text = describeEntry(entry)
        end
        parts[#parts + 1] = WORD_FOR_SIDE[side] .. " " .. text
      end
    end
    say(key .. ": " .. table.concat(parts, "; "))
  end
end

local HELP_LINES = {
  "/mcb list: the workloads, and the host workloads the client does not run",
  "/mcb run <workload> <kits|ace3|both> [rounds]: queue a run; one case per session",
  "/mcb continue: reload now to run the next queued item",
  "/mcb status: what is queued",
  "/mcb stop: drop the queue (saved results stay)",
  "/mcb report: print the saved results of this installation",
  "/mcb clear: delete every saved result",
}

---Handle one `/mcb` line.
---@param line string
local function handleCommand(line)
  local arguments = words(line or "")
  local command = arguments[1] or "help"
  if command == "list" then
    listWorkloads()
  elseif command == "run" then
    run(arguments)
  elseif command == "continue" then
    if queue() ~= nil then
      callHost("ReloadUI")
    else
      say("nothing is queued")
    end
  elseif command == "status" then
    status()
  elseif command == "stop" then
    saved().queue = nil
    hidePanel()
    say("the queue was dropped; the saved results stay")
  elseif command == "report" then
    report()
  elseif command == "clear" then
    if queue() ~= nil or session.running ~= nil then
      say("stop the run first (/mcb stop)")
      return
    end
    saved().entries = {}
    saved().installationDetails = nil
    say("every saved result was deleted")
  else
    for _, text in ipairs(HELP_LINES) do
      say(text)
    end
  end
end

-- Start-up ----------------------------------------------------------------------------

writeHost("SLASH_" .. SLASH_KEY .. "1", SLASH_COMMAND)
readHost("SlashCmdList")[SLASH_KEY] = handleCommand

local events = readHost("CreateFrame")("Frame")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:SetScript("OnEvent", function(_, eventName)
  if eventName == "PLAYER_ENTERING_WORLD" then
    if session.enteredWorldAt == nil then
      session.enteredWorldAt = readHost("GetTime")()
      local plan = queue()
      if plan ~= nil and plan.current ~= nil then
        finishItem(
          plan.current,
          { session = {} },
          "the session ended before the item finished (a crash, a disconnect or a reload)"
        )
      end
      if queue() ~= nil then
        startWhenSettled()
      end
    end
  elseif eventName == "PLAYER_REGEN_ENABLED" and session.waitingForCombatEnd then
    session.waitingForCombatEnd = false
    startWhenSettled()
  end
end)
