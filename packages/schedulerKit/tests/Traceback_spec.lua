local TestEnv = require("SchedulerKitTestEnv")

-- SchedulerKit captures a failing job's stack from one of two sources,
-- resolved once when the package loads (docs/API.md, "Errors"):
--
--   a. `debug.traceback(thread, message)`, which standard Lua and Busted
--      publish;
--   b. the client's `debugstack(thread)`, the only source on the Retail
--      client, which publishes no `debug` global (measured on 12.1.0 build
--      69933, 2026-09-24). Its bare stack is prefixed with the rendered error
--      object and a `stack traceback:` header.
--
-- The client path is reproduced by loading the package with `debug.traceback`
-- removed and a `debugstack` stub installed. The global `debug` itself is not
-- removed: LuaCov's line hook indexes it while the package loads under the
-- coverage gate. It is replaced by a copy of the host's library without
-- `traceback`, which SchedulerKit resolves exactly as it resolves a missing
-- `debug` global (`rawget` of `traceback` gives `nil` either way). The real
-- library is put back as soon as the package has loaded, and again by
-- `after_each`, so Busted and every other spec keep it.

-- The host's own library, captured before any spec can replace it.
local HOST_DEBUG = debug

-- The host's library without `traceback`, standing in for the client, where
-- no `traceback` is published.
local DEBUG_WITHOUT_TRACEBACK = {}
for key, value in pairs(HOST_DEBUG) do
  if key ~= "traceback" then
    DEBUG_WITHOUT_TRACEBACK[key] = value
  end
end

---Publish `value` as the global `name`, or remove it with `nil`: the stand-in
---for what the host does or does not publish.
---@param name string
---@param value any
local function setGlobal(name, value)
  -- selene: allow(global_usage)
  rawset(_G, name, value)
end

---A `debugstack` stand-in built on the host's traceback, so the stack it
---returns names the coroutine's real frames. Every call is recorded.
---@param calls table[] receives `{ thread = ..., count = ... }` per call
---@return fun(thread: thread?): string
local function newDebugStackStub(calls)
  return function(...)
    local thread = ...
    calls[#calls + 1] = { thread = thread, count = select("#", ...) }
    -- `debug.traceback(thread, "")` is "\nstack traceback:\n" followed by
    -- the frames; the client's `debugstack` returns the frames alone.
    local traceback = HOST_DEBUG.traceback(thread, "")
    return (traceback:gsub("^\nstack traceback:\n", ""))
  end
end

---Load the module chain on a host without `debug.traceback`, the way the
---Retail client is, with `debugStack` published as the global `debugstack`
---(`nil` publishes none).
---@param debugStack any
---@return table SchedulerKit
local function loadWithoutDebugLibrary(debugStack)
  TestEnv.Reset()
  TestEnv.InstallWowApi()
  setGlobal("debugstack", debugStack)
  setGlobal("debug", DEBUG_WITHOUT_TRACEBACK)
  local ok, loaded = pcall(function()
    require("Registry")
    require("TimerKit")
    return require("SchedulerKit")
  end)
  setGlobal("debug", HOST_DEBUG)
  assert(ok, loaded)
  return loaded
end

---Schedule a job that fails with `errorObject` from a named inner function,
---and run it.
---@param SchedulerKit table
---@param errorObject any
---@return table job
local function runFailingJob(SchedulerKit, errorObject)
  local function inner()
    error(errorObject, 0)
  end
  local job = SchedulerKit:Schedule(function()
    inner()
  end)
  TestEnv.Tick()
  assert.are.equal("failed", job:GetState())
  return job
end

describe("SchedulerKit traceback sources", function()
  after_each(function()
    setGlobal("debug", HOST_DEBUG)
    setGlobal("debugstack", nil)
    TestEnv.Reset()
  end)

  describe("with debug.traceback (standard Lua, Busted)", function()
    it("returns debug.traceback's own text for the failing coroutine", function()
      local SchedulerKit = TestEnv.NewPackage()
      local job = runFailingJob(SchedulerKit, "host failure")

      local traceback = job:GetErrorTraceback()
      local header = "host failure\nstack traceback:\n"
      assert.are.equal(header, traceback:sub(1, #header))
      assert.is_not_nil(traceback:find("inner", 1, true))
      assert.are.equal(traceback, TestEnv.ReportedErrors()[1])
    end)

    it("prefers debug.traceback when the host also publishes debugstack", function()
      local calls = {}
      TestEnv.Reset()
      TestEnv.InstallWowApi()
      setGlobal("debugstack", newDebugStackStub(calls))
      require("Registry")
      require("TimerKit")
      local SchedulerKit = require("SchedulerKit")

      local job = runFailingJob(SchedulerKit, "both published")
      assert.is_not_nil(job:GetErrorTraceback():find("stack traceback:", 1, true))
      assert.are.equal(0, #calls)
    end)
  end)

  describe("with the client's debugstack and no debug.traceback", function()
    it("prefixes the error and a stack traceback header to debugstack(thread)", function()
      local calls = {}
      local SchedulerKit = loadWithoutDebugLibrary(newDebugStackStub(calls))
      local job = runFailingJob(SchedulerKit, "client failure")

      assert.are.equal(1, #calls)
      assert.are.equal("thread", type(calls[1].thread))
      assert.are.equal(1, calls[1].count)

      local traceback = job:GetErrorTraceback()
      local header = "client failure\nstack traceback:\n"
      assert.are.equal(header, traceback:sub(1, #header))
      -- The stack is the failing coroutine's own, so the raising frame
      -- is still named.
      assert.is_not_nil(traceback:find("inner", 1, true))
      assert.are.equal("client failure", job:GetError())
      assert.are.equal(traceback, TestEnv.ReportedErrors()[1])
    end)

    it("renders a non-string error object with tostring and keeps the object", function()
      local SchedulerKit = loadWithoutDebugLibrary(newDebugStackStub({}))
      local marker = setmetatable({}, {
        __tostring = function()
          return "marker object"
        end,
      })
      local job = runFailingJob(SchedulerKit, marker)

      local header = "marker object\nstack traceback:\n"
      assert.are.equal(header, job:GetErrorTraceback():sub(1, #header))
      assert.are.equal(marker, job:GetError())

      local nilJob = runFailingJob(SchedulerKit, nil)
      assert.are.equal("nil\nstack traceback:\n", nilJob:GetErrorTraceback():sub(1, 21))
      assert.is_nil(nilJob:GetError())
    end)

    it("resolves debugstack once at load", function()
      local calls = {}
      local SchedulerKit = loadWithoutDebugLibrary(newDebugStackStub(calls))
      local replacementCalls = {}
      setGlobal("debugstack", newDebugStackStub(replacementCalls))

      runFailingJob(SchedulerKit, "late replacement")
      assert.are.equal(1, #calls)
      assert.are.equal(0, #replacementCalls)
    end)

    it("has no traceback when debugstack raises or returns a non-string", function()
      local SchedulerKit = loadWithoutDebugLibrary(function()
        error("debugstack failed", 0)
      end)
      local job = runFailingJob(SchedulerKit, "raising source")
      assert.is_nil(job:GetErrorTraceback())
      assert.are.equal("raising source", TestEnv.ReportedErrors()[1])

      SchedulerKit = loadWithoutDebugLibrary(function()
        return {}
      end)
      job = runFailingJob(SchedulerKit, "table source")
      assert.is_nil(job:GetErrorTraceback())
      assert.are.equal("table source", TestEnv.ReportedErrors()[1])
    end)
  end)

  describe("with neither source", function()
    it("has no traceback and reports the bare error object", function()
      local SchedulerKit = loadWithoutDebugLibrary(nil)
      local job = runFailingJob(SchedulerKit, "no source")
      assert.is_nil(job:GetErrorTraceback())
      assert.are.equal("no source", job:GetError())
      assert.are.equal("no source", TestEnv.ReportedErrors()[1])
    end)

    it("treats a debugstack that is not a function as absent", function()
      local SchedulerKit = loadWithoutDebugLibrary("not a function")
      local job = runFailingJob(SchedulerKit, "string source")
      assert.is_nil(job:GetErrorTraceback())
      assert.are.equal("string source", TestEnv.ReportedErrors()[1])
    end)
  end)

  it(
    "upgrades a revision-14 copy in place on a host without debug.traceback and captures a carried job's failure with debugstack",
    function()
      local calls = {}
      TestEnv.Reset()
      TestEnv.InstallWowApi()
      setGlobal("debugstack", newDebugStackStub(calls))
      setGlobal("debug", DEBUG_WITHOUT_TRACEBACK)
      local loaded, old = pcall(function()
        require("Registry")
        require("TimerKit")
        return TestEnv.LoadRevision(14)
      end)
      setGlobal("debug", HOST_DEBUG)
      assert(loaded, old)

      local state = old._state
      local job = old:Schedule(function(context)
        context:Yield()
        error("after the upgrade", 0)
      end)
      TestEnv.Tick()
      assert.are.equal(14, old.REVISION)

      package.loaded["SchedulerKit"] = nil
      setGlobal("debug", DEBUG_WITHOUT_TRACEBACK)
      local upgradedOk, upgraded = pcall(require, "SchedulerKit")
      setGlobal("debug", HOST_DEBUG)
      assert(upgradedOk, upgraded)
      assert.are.equal(old, upgraded)
      assert.are.equal(state, upgraded._state)
      assert.is_true(upgraded.REVISION > 14)

      -- The coroutine the revision-14 copy started fails under the
      -- current revision.
      TestEnv.Tick()
      assert.are.equal("failed", job:GetState())
      local header = "after the upgrade\nstack traceback:\n"
      assert.are.equal(header, job:GetErrorTraceback():sub(1, #header))
      assert.are.equal(1, #calls)
    end
  )

  -- Debounce, Coalesce and Watch run their callbacks and predicates under
  -- `xpcall`, not in a job's coroutine. The handler captures the current
  -- stack, where the failing frames still are, skipping its own frame.
  describe("in the xpcall handler of Debounce, Coalesce and Watch", function()
    -- A fixed stack for the stub to return, so a report can be compared
    -- whole.
    local KNOWN_STACK = '[string "Stub"]:1: in function <stub>\n'

    ---A `debugstack` stand-in that records its arguments and returns
    ---`KNOWN_STACK`.
    ---@param calls table[] receives `{ count = ..., arguments = { ... } }` per call
    ---@return function
    local function newFixedDebugStack(calls)
      return function(...)
        calls[#calls + 1] = { count = select("#", ...), arguments = { ... } }
        return KNOWN_STACK
      end
    end

    ---Open a watch whose predicate raises `message`, and run its first tick.
    ---@param SchedulerKit table
    ---@param message string
    local function tickRaisingWatch(SchedulerKit, message)
      SchedulerKit:Watch(function()
        error(message, 0)
      end, 1, function() end)
      TestEnv.FireNative(#TestEnv.NativeTimers())
    end

    it("skips the handler's own frame in debug.traceback", function()
      local SchedulerKit = TestEnv.NewPackage()
      tickRaisingWatch(SchedulerKit, "host predicate failure")

      local report = TestEnv.ReportedErrors()[1]
      local header = "host predicate failure\nstack traceback:\n"
      assert.are.equal(header, report:sub(1, #header))
      -- The first frame is the raise itself, not the handler.
      assert.are.equal("\t[C]: in function 'error'\n", report:sub(#header + 1, #header + 26))
    end)

    it(
      "reports a raising Watch predicate with debugstack from the level after the handler",
      function()
        local calls = {}
        local SchedulerKit = loadWithoutDebugLibrary(newFixedDebugStack(calls))
        tickRaisingWatch(SchedulerKit, "predicate failure")

        assert.are.equal(1, #calls)
        -- Through `pcall`, level 1 is `pcall` and level 2 the handler.
        assert.are.equal(1, calls[1].count)
        assert.are.equal(3, calls[1].arguments[1])
        assert.are.same(
          { "predicate failure\nstack traceback:\n" .. KNOWN_STACK },
          TestEnv.ReportedErrors()
        )
      end
    )

    it("reports a raising Debounce and Coalesce callback with debugstack", function()
      local SchedulerKit = loadWithoutDebugLibrary(newFixedDebugStack({}))
      local debounced = SchedulerKit:Debounce(function()
        error("debounced failure", 0)
      end, 0)
      debounced()
      TestEnv.FireNative(#TestEnv.NativeTimers())

      local coalesced = SchedulerKit:Coalesce(function()
        error({ reason = "coalesced" })
      end, 0)
      coalesced("key")
      TestEnv.FireNative(#TestEnv.NativeTimers())

      local reported = TestEnv.ReportedErrors()
      assert.are.equal(2, #reported)
      assert.are.equal("debounced failure\nstack traceback:\n" .. KNOWN_STACK, reported[1])
      -- A non-string error object is rendered with `tostring`.
      local header = "table: "
      assert.are.equal(header, reported[2]:sub(1, #header))
      local suffix = "\nstack traceback:\n" .. KNOWN_STACK
      assert.are.equal(suffix, reported[2]:sub(-#suffix))
    end)

    it("captures a lane submission's failure from its coroutine with debugstack", function()
      local calls = {}
      local SchedulerKit = loadWithoutDebugLibrary(newFixedDebugStack(calls))
      local job = SchedulerKit:Lane("failing"):Submit(function()
        error("lane failure", 0)
      end)
      TestEnv.Tick()

      assert.are.equal("failed", job:GetState())
      assert.are.equal("thread", type(calls[1].arguments[1]))
      local traceback = "lane failure\nstack traceback:\n" .. KNOWN_STACK
      assert.are.equal(traceback, job:GetErrorTraceback())
      assert.are.same({ traceback }, TestEnv.ReportedErrors())
    end)

    it("reports the bare message when debugstack raises, or with neither source", function()
      local SchedulerKit = loadWithoutDebugLibrary(function()
        error("debugstack failed", 0)
      end)
      tickRaisingWatch(SchedulerKit, "raising source")
      assert.are.same({ "raising source" }, TestEnv.ReportedErrors())

      SchedulerKit = loadWithoutDebugLibrary(nil)
      tickRaisingWatch(SchedulerKit, "no source")
      assert.are.same({ "no source" }, TestEnv.ReportedErrors())
    end)
  end)
end)
