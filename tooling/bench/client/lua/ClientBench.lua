--- Measurement core of the in-client benchmark.
---
--- The host runner measures with `Bench.MeasureCase` (`tooling/bench/lua/Bench.lua`)
--- in a fresh Lua process per case. In the game client a case runs in a fresh UI
--- session instead (the harness reloads between cases), and the clock and the
--- frame loop are the client's, so this module adapts the host protocol:
---
--- **Batch cases** (a shared workload's `Bench.Case`, or a client-only case
--- without `kind`) follow the host protocol step for step: `prepare()` once,
--- `warmup` untimed batches, `repetitions` timed batches each after a full
--- collection, and one allocation batch with the collector stopped. Two things
--- differ, both because the client is not a batch process:
---
---   - the clock is `debugprofilestop()`, the client's high-resolution timer in
---     milliseconds (the client has no `os.clock`); a batch runs synchronously
---     inside one frame, so nothing else runs while it is timed;
---   - every batch runs in a frame of its own (`environment.nextFrame` yields
---     between them), so the client keeps drawing and a long case never holds
---     one frame for the whole protocol.
---
--- **Frame cases** (`kind = "frames"`) cannot be measured in one synchronous
--- batch: timers fire, messages arrive and windows draw between frames. The
--- case gets `start()`, then `frame(secondsSinceStart)` once per frame until it
--- returns `true` or `maximumSeconds` pass, then `finish()`, which returns the
--- case's own measurements. Around it this module records, for every frame
--- case alike, the frame times (from `GetTimePreciseSec`, which no addon can
--- reset), the Lua time the case's `frame` took, the collection cycles that
--- completed and the heap before and after. Frame and work times go into
--- fixed-size histograms (percentiles exact to 1 %), so the runner itself
--- adds nothing to the heap while a case runs for minutes.
---
--- A case that needs something only the fake client has raises through
--- `ClientBench.Unsupported`; the harness records it as not run in the client,
--- with the reason, instead of as a failure.

local Bench = require("Bench")
local FrameStats = require("clientWorkloads.FrameStats")

local ClientBench = {}

--- Starts the message of an error raised by `Unsupported`, so the harness can
--- tell "this case cannot run in the client" from a real failure.
ClientBench.UNSUPPORTED_MARKER = "[MoltenCodesBench: not in the client] "

---A frame-driven case, as a client-only workload declares it.
---@class ClientBench.FrameCase
---@field name string stable identifier, the same on both sides for a comparable case
---@field operation string what the case does, in words, for the report
---@field kind "frames"
---@field equivalent boolean? `false` when the two sides do different work
---@field note string? a one-line caveat the report prints with the row
---@field prepare fun(): ClientBench.FrameSubject builds the subject; not measured

---What a frame case's `prepare` returns.
---@class ClientBench.FrameSubject
---@field maximumSeconds number the case ends after this long even when `frame` never returned `true`
---@field start fun()? runs once, in the first measured frame
---@field frame fun(seconds: number): boolean? runs once per frame; `true` ends the case
---@field finish fun(): table? runs once at the end; returns the case's own measurements

---What the harness gives the protocol: the clocks and the frame loop.
---@class ClientBench.Environment
---@field clock fun(): number milliseconds from `debugprofilestop`
---@field frameClock fun(): number seconds from `GetTimePreciseSec`, or the clock above in seconds
---@field nextFrame fun() returns in the next frame (the harness yields its coroutine)

---Raise the error that marks a case as not runnable in the client.
---@param what string what is missing, for example "the simulated clock (host.timers)"
function ClientBench.Unsupported(what)
  error(ClientBench.UNSUPPORTED_MARKER .. "needs " .. what, 0)
end

---The reason inside an `Unsupported` error message, or `nil` for any other error.
---@param message any an error value
---@return string|nil
function ClientBench.UnsupportedReason(message)
  if type(message) ~= "string" then
    return nil
  end
  local _, markerEnd = message:find(ClientBench.UNSUPPORTED_MARKER, 1, true)
  if markerEnd == nil then
    return nil
  end
  return message:sub(markerEnd + 1)
end

---Stop the collector, when the client allows it.
---@return boolean stopped
local function stopCollector()
  return (pcall(collectgarbage, "stop"))
end

---Run one batch with its untimed hooks around it.
---@param subject Bench.Subject
---@param iterations integer
---@param measured fun(run: fun(iterations: integer), iterations: integer): number?
---@return number?
local function runBatch(subject, iterations, measured)
  if subject.beforeBatch ~= nil then
    subject.beforeBatch(iterations)
  end
  local result = measured(subject.run, iterations)
  if subject.afterBatch ~= nil then
    subject.afterBatch(iterations)
  end
  return result
end

---Measure a batch case with the host protocol on the client's clock.
---@param case Bench.Case
---@param settings { warmup: integer, repetitions: integer }
---@param environment ClientBench.Environment
---@return table result the host result fields, plus `kind = "batch"`
function ClientBench.MeasureBatchCase(case, settings, environment)
  local clock = environment.clock
  local subject = case.prepare()
  local iterations = case.iterations
  environment.nextFrame()

  for _ = 1, settings.warmup do
    runBatch(subject, iterations, function(run, count)
      run(count)
    end)
    environment.nextFrame()
  end

  local samples = {}
  for repetition = 1, settings.repetitions do
    samples[repetition] = runBatch(subject, iterations, function(run, count)
      collectgarbage("collect")
      local started = clock()
      run(count)
      return (clock() - started) * 1e6 / count
    end)
    environment.nextFrame()
  end

  -- The allocation batch needs a stopped collector. A client that refuses
  -- `collectgarbage("stop")` gets no allocation figure rather than a wrong one.
  local allocation = runBatch(subject, iterations, function(run, count)
    collectgarbage("collect")
    if not stopCollector() then
      run(count)
      return nil
    end
    local before = collectgarbage("count")
    run(count)
    local after = collectgarbage("count")
    collectgarbage("restart")
    return (after - before) * 1024 / count
  end)

  local minimum = samples[1]
  for index = 2, #samples do
    if samples[index] < minimum then
      minimum = samples[index]
    end
  end

  return {
    kind = "batch",
    name = case.name,
    operation = case.operation,
    equivalent = case.equivalent ~= false,
    note = case.note,
    iterations = iterations,
    warmup = settings.warmup,
    repetitions = settings.repetitions,
    nanosecondsPerOperation = samples,
    medianNanoseconds = Bench.Median(samples),
    minimumNanoseconds = minimum,
    allocatedBytesPerOperation = allocation,
    metrics = subject.metrics ~= nil and subject.metrics() or nil,
  }
end

---Measure a frame case: the subject's own measurements plus frame times,
---the Lua time of its per-frame work, collection cycles and the heap.
---@param case ClientBench.FrameCase
---@param environment ClientBench.Environment
---@return table result
function ClientBench.MeasureFrameCase(case, environment)
  local subject = case.prepare()
  environment.nextFrame()

  -- Built before the heap is read: they allocate nothing per frame afterwards.
  local frames = FrameStats.NewHistogram()
  local work = FrameStats.NewHistogram()
  local cycles = FrameStats.NewCycleCounter()
  collectgarbage("collect")
  local heapStart = collectgarbage("count")

  if subject.start ~= nil then
    subject.start()
  end
  local started = environment.frameClock()
  local previous = started
  local finished = false
  local seconds = 0
  while true do
    environment.nextFrame()
    local now = environment.frameClock()
    frames.Add((now - previous) * 1000)
    previous = now
    cycles.Check()
    seconds = now - started
    local workStarted = environment.clock()
    finished = subject.frame(seconds) == true
    work.Add(environment.clock() - workStarted)
    if finished or seconds >= subject.maximumSeconds then
      break
    end
  end

  local metrics = subject.finish ~= nil and subject.finish() or {}
  local heapEnd = collectgarbage("count")
  metrics.frames = frames.Count()
  metrics.seconds = seconds
  metrics.framesPerSecond = seconds > 0 and frames.Count() / seconds or nil
  metrics.frameMillisecondsP50 = frames.Percentile(50)
  metrics.frameMillisecondsP95 = frames.Percentile(95)
  metrics.frameMillisecondsP99 = frames.Percentile(99)
  metrics.frameMillisecondsMax = frames.Maximum()
  metrics.caseMillisecondsPerFrameP50 = work.Percentile(50)
  metrics.caseMillisecondsPerFrameP95 = work.Percentile(95)
  metrics.caseMillisecondsPerFrameMax = work.Maximum()
  metrics.collectionCycles = cycles.Count()
  metrics.heapKilobytesStart = heapStart
  metrics.heapKilobytesEnd = heapEnd
  metrics.endedByTimeLimit = not finished

  return {
    kind = "frames",
    name = case.name,
    operation = case.operation,
    equivalent = case.equivalent ~= false,
    note = case.note,
    metrics = metrics,
  }
end

---Measure a case of either kind.
---@param case table a `Bench.Case` or a `ClientBench.FrameCase`
---@param settings { warmup: integer, repetitions: integer }
---@param environment ClientBench.Environment
---@return table result
function ClientBench.MeasureCase(case, settings, environment)
  if case.kind == "frames" then
    return ClientBench.MeasureFrameCase(case, environment)
  end
  return ClientBench.MeasureBatchCase(case, settings, environment)
end

return ClientBench
