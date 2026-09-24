--- Package-specific test environment for the TestKit suite.
---
--- The World of Warcraft stubs, the `package.loaded` bookkeeping and the error
--- capture live in the shared `FrameworkTestEnv` fixture at `tests/support/`.
--- What stays here is this package's own module load order and the helpers
--- only its specs describe: rendering frames (timers that are due, then one
--- `OnUpdate` pass), an addon moved through its phases, and an in-place
--- upgrade.
---
--- EventKit and TimerKit are not TestKit dependencies, but they are in the
--- closures of LifecycleKit and SchedulerKit, so every module below is already
--- on the `LUA_PATH` the test runner builds from the manifests.
local FrameworkTestEnv = require("FrameworkTestEnv")

local TestKitTestEnv = FrameworkTestEnv.New({
  modules = {
    "Registry",
    "SignalKit",
    "EventKit",
    "LifecycleKit",
    "TimerKit",
    "SchedulerKit",
    "TestKit",
  },
})

--- When each native timer is due, in wall-clock milliseconds, by creation
--- index. The shared fixture records a timer's delay but not when it was
--- created, so this file notes the clock the first time it sees each timer.
local timing = { seen = 0, dueAt = {} }

--- Globals a spec installed through `SetGlobal`, removed again by `Reset`.
local installedGlobals = {}

local resetFixture = TestKitTestEnv.Reset

---Reset the shared fixture, this file's timer bookkeeping and every global a
---spec installed through `SetGlobal`.
function TestKitTestEnv.Reset()
  resetFixture()
  timing.seen = 0
  timing.dueAt = {}
  for name in pairs(installedGlobals) do
    -- The fixture stands in for the World of Warcraft client, whose API only exists in the global table.
    -- selene: allow(global_usage)
    rawset(_G, name, nil)
  end
  installedGlobals = {}
end

---@return number milliseconds the fixture's wall clock
local function wallClockMs()
  -- The fixture installs the host clock as a global; reading it is how a helper sees the fake wall time.
  -- selene: allow(global_usage)
  return rawget(_G, "GetTimePreciseSec")() * 1000
end

---Note the due time of every native timer created since the last frame.
local function recordNewTimers()
  local natives = TestKitTestEnv.NativeTimers()
  local now = wallClockMs()
  for index = timing.seen + 1, #natives do
    timing.dueAt[index] = now + natives[index].seconds * 1000
  end
  timing.seen = #natives
end

---Render one frame of `milliseconds`: advance both clocks, fire every native
---timer that is due, then run every `OnUpdate` handler once. This is the order
---the client uses closely enough for the runner: a zero-delay timer created in
---one frame fires in the next.
---@param milliseconds number? defaults to 16
function TestKitTestEnv.Frame(milliseconds)
  milliseconds = milliseconds or 16
  recordNewTimers()
  TestKitTestEnv.AdvanceMs(milliseconds)

  local now = wallClockMs()
  local natives = TestKitTestEnv.NativeTimers()
  -- Snapshot the count: a timer created by a callback belongs to a later frame.
  local count = #natives
  for index = 1, count do
    local native = natives[index]
    local due = not native.cancelled
      and (native.repeating or not native.fired)
      and timing.dueAt[index] <= now
    if due then
      if native.repeating then
        timing.dueAt[index] = timing.dueAt[index] + native.seconds * 1000
      end
      TestKitTestEnv.FireNative(index)
    end
  end

  TestKitTestEnv.Tick(milliseconds / 1000)
end

---Render `count` frames of `milliseconds` each.
---@param count integer
---@param milliseconds number? defaults to 16
function TestKitTestEnv.RenderFrames(count, milliseconds)
  for _ = 1, count do
    TestKitTestEnv.Frame(milliseconds)
  end
end

---Render frames until `done()` answers true, at most `limit` of them.
---@param done fun(): boolean
---@param limit integer? defaults to 200
---@return boolean reached whether `done()` answered true
function TestKitTestEnv.FramesUntil(done, limit)
  for _ = 1, limit or 200 do
    if done() then
      return true
    end
    TestKitTestEnv.Frame()
  end
  return done()
end

---Load the module chain, then move `addonName` to `loaded` and the player to
---logged in, so a suite of that addon can run at once.
---@param addonName string
---@return table TestKit
---@return table Registry
function TestKitTestEnv.NewReadyPackage(addonName)
  local TestKit, Registry = TestKitTestEnv.NewPackage()
  TestKitTestEnv.LoadAddon(addonName)
  TestKitTestEnv.Login()
  return TestKit, Registry
end

--- Every report an `OnFinished` callback installed by `RunToEnd` received,
--- per TestKit facade. One callback per facade, so repeated runs do not spend
--- the facade's sixteen `OnFinished` slots.
local finishedReports = setmetatable({}, { __mode = "k" })

---Run `filter` and render frames until the run finishes. Returns the report
---the `OnFinished` callback received.
---@param TestKit table
---@param filter string?
---@param limit integer? most frames to render, defaults to 200
---@return table? report `nil` when the run did not finish in time
function TestKitTestEnv.RunToEnd(TestKit, filter, limit)
  local reports = finishedReports[TestKit]
  if reports == nil then
    reports = {}
    finishedReports[TestKit] = reports
    TestKit:OnFinished(function(report)
      reports[#reports + 1] = report
    end)
  end
  local before = #reports

  local queued, reason = TestKit:Run(filter)
  if queued == nil then
    error("TestKitTestEnv.RunToEnd: Run refused with " .. tostring(reason), 2)
  end
  TestKitTestEnv.FramesUntil(function()
    return #reports > before
  end, limit)
  return reports[before + 1]
end

---Run `body` as the only test of a fresh suite and return its result.
---@param TestKit table
---@param body fun(ctx: table)
---@return table result
function TestKitTestEnv.RunOne(TestKit, body)
  local count = (finishedReports[TestKit] and #finishedReports[TestKit] or 0) + 1
  local suiteName = "RunOne" .. count
  local suite = assert(TestKit:Suite(suiteName, { addonName = "MyAddon" }))
  suite:Test("body", body)
  local report = TestKitTestEnv.RunToEnd(TestKit, suiteName)
  if report == nil then
    error("TestKitTestEnv.RunOne: the run did not finish", 2)
  end
  return TestKitTestEnv.FindResult(report, suiteName, "body")
end

---Find one test's result in a report.
---@param report table
---@param suiteName string
---@param testName string
---@return table? result
function TestKitTestEnv.FindResult(report, suiteName, testName)
  for suiteIndex = 1, #report.suites do
    local suite = report.suites[suiteIndex]
    if suite.name == suiteName then
      for testIndex = 1, #suite.tests do
        if suite.tests[testIndex].name == testName then
          return suite.tests[testIndex]
        end
      end
    end
  end
  return nil
end

---Install a global the way the host would; `Reset` removes it again. Specs use
---it for `issecretvalue` and `issecurevariable`.
---@param name string
---@param value any
function TestKitTestEnv.SetGlobal(name, value)
  installedGlobals[name] = true
  -- The fixture stands in for the World of Warcraft client, whose API only exists in the global table.
  -- selene: allow(global_usage)
  rawset(_G, name, value)
end

---Load the TestKit source again as a copy carrying `revision`, the way a newer
---embedded copy loads over an older one in the client.
---@param revision integer
---@return table TestKit
function TestKitTestEnv.LoadRevision(revision)
  -- Lua 5.1 has no `package.searchpath`, so walk the path templates the way
  -- `require` does.
  local path = nil
  for template in package.path:gmatch("[^;]+") do
    local candidate = template:gsub("%?", "TestKit")
    local file = io.open(candidate, "r")
    if file ~= nil then
      file:close()
      path = candidate
      break
    end
  end
  if path == nil then
    error("TestKitTestEnv.LoadRevision could not find TestKit.lua on package.path", 2)
  end

  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()

  local patched, replacements =
    text:gsub("local IMPLEMENTATION_REVISION = %d+", "local IMPLEMENTATION_REVISION = " .. revision)
  if replacements ~= 1 then
    error("TestKitTestEnv.LoadRevision could not find IMPLEMENTATION_REVISION", 2)
  end

  local chunk = assert(loadstring(patched, "@" .. path))
  return chunk()
end

return TestKitTestEnv
