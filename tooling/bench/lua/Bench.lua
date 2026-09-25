--- Measurement core of the host benchmark: timing, allocation and JSON output.
---
--- A workload describes each case as a table (see `Bench.Case` below); this
--- module runs it with one fixed protocol, so every case of every workload,
--- on either side, is measured the same way:
---
--- 1. `prepare()` builds the subject once. Nothing in it is measured.
--- 2. Warm-up: `warmup` untimed batches, so first-call costs (table growth,
---    lazily created frames, interned strings) are paid before measuring.
--- 3. Timing: `repetitions` batches of `iterations` operations each, every
---    one preceded by a full collection and timed with `os.clock`, the
---    process CPU clock. The collector runs normally inside a timed batch, so
---    a case that allocates also pays for collecting what it allocated, as it
---    would in the client.
--- 4. Allocation: one more batch with the collector stopped, measured as the
---    `collectgarbage("count")` delta, the way the repository's `#allocation`
---    specs measure (`packages/*/tests/Allocation_spec.lua`). It is reported
---    in bytes per operation and kept apart from the time.
---
--- `beforeBatch` and `afterBatch`, when a case has them, run outside every
--- timed and measured region: they restore the state a batch consumed (fresh
--- saved variables, a drained timer queue) so that each batch measures the
--- same work.

local Bench = {}

---One benchmark case, as a workload declares it.
---@class Bench.Case
---@field name string stable identifier, the same on both sides for a comparable case
---@field iterations integer operations per batch
---@field operation string what one operation is, in words, for the report
---@field equivalent boolean? `false` when the two sides do different work (the report says so)
---@field note string? a one-line caveat the report prints with the row
---@field prepare fun(): Bench.Subject builds the subject; not measured

---What `prepare` returns.
---@class Bench.Subject
---@field run fun(iterations: integer) performs `iterations` operations
---@field beforeBatch fun(iterations: integer)? untimed set-up before each batch
---@field afterBatch fun(iterations: integer)? untimed clean-up after each batch
---@field metrics fun(): table? extra measurements, read once after the allocation batch

---Run one batch, with its untimed hooks around it.
---@param subject Bench.Subject
---@param iterations integer
---@param measured fun(run: fun(iterations: integer), iterations: integer): number?
---@return number? result whatever `measured` returned
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

---Time one batch in nanoseconds per operation.
---@param run fun(iterations: integer)
---@param iterations integer
---@return number
local function timeBatch(run, iterations)
  collectgarbage("collect")
  local started = os.clock()
  run(iterations)
  local elapsed = os.clock() - started
  return elapsed * 1e9 / iterations
end

---Measure one batch's allocation in bytes per operation, collector stopped.
---@param run fun(iterations: integer)
---@param iterations integer
---@return number
local function allocationBatch(run, iterations)
  collectgarbage("collect")
  collectgarbage("stop")
  local before = collectgarbage("count")
  run(iterations)
  local after = collectgarbage("count")
  collectgarbage("restart")
  return (after - before) * 1024 / iterations
end

---Return the median of a list of numbers without changing the list.
---@param values number[]
---@return number
function Bench.Median(values)
  local sorted = {}
  for index = 1, #values do
    sorted[index] = values[index]
  end
  table.sort(sorted)
  local count = #sorted
  if count % 2 == 1 then
    return sorted[(count + 1) / 2]
  end
  return (sorted[count / 2] + sorted[count / 2 + 1]) / 2
end

---Measure a case with the protocol described at the top of this file.
---@param case Bench.Case
---@param settings { warmup: integer, repetitions: integer }
---@return table result the case's raw result, ready for `Bench.EncodeJson`
function Bench.MeasureCase(case, settings)
  local subject = case.prepare()
  local iterations = case.iterations

  for _ = 1, settings.warmup do
    runBatch(subject, iterations, function(run, count)
      run(count)
    end)
  end

  local samples = {}
  for repetition = 1, settings.repetitions do
    samples[repetition] = runBatch(subject, iterations, timeBatch)
  end

  local allocation = runBatch(subject, iterations, allocationBatch)

  local minimum = samples[1]
  for index = 2, #samples do
    if samples[index] < minimum then
      minimum = samples[index]
    end
  end

  return {
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

---Bytes the Lua heap holds after a full collection.
---
---Used for "retained" measurements: build something, collect, and compare
---with a collected baseline. Two collections, because a finaliser or a weak
---table can free more on the second pass.
---@return number bytes
function Bench.RetainedBytes()
  collectgarbage("collect")
  collectgarbage("collect")
  return collectgarbage("count") * 1024
end

--- JSON encoding -------------------------------------------------------------

local escapes = {
  ['"'] = '\\"',
  ["\\"] = "\\\\",
  ["\b"] = "\\b",
  ["\f"] = "\\f",
  ["\n"] = "\\n",
  ["\r"] = "\\r",
  ["\t"] = "\\t",
}

---@param text string
---@return string
local function encodeString(text)
  return '"'
    .. text:gsub('[%c"\\]', function(character)
      return escapes[character] or string.format("\\u%04x", character:byte())
    end)
    .. '"'
end

---@param value number
---@return string
local function encodeNumber(value)
  -- NaN and the infinities have no JSON spelling; a measurement that
  -- produced one is reported as missing rather than as a wrong number.
  if value ~= value or value == math.huge or value == -math.huge then
    return "null"
  end
  if value == math.floor(value) and math.abs(value) < 2 ^ 53 then
    return string.format("%d", value)
  end
  return string.format("%.17g", value)
end

---Whether `value` is a non-empty sequence `1..n` with no other keys.
---@param value table
---@return boolean
local function isArray(value)
  local count = 0
  for _ in pairs(value) do
    count = count + 1
  end
  return count > 0 and count == #value
end

local encodeValue

---@param value table
---@param depth integer
---@return string
local function encodeTable(value, depth)
  if depth > 32 then
    error("Bench.EncodeJson: nesting deeper than 32 levels", 0)
  end
  local parts = {}
  if isArray(value) then
    for index = 1, #value do
      parts[index] = encodeValue(value[index], depth + 1)
    end
    return "[" .. table.concat(parts, ",") .. "]"
  end
  local keys = {}
  for key in pairs(value) do
    if type(key) ~= "string" then
      error("Bench.EncodeJson: object keys must be strings, found " .. type(key), 0)
    end
    keys[#keys + 1] = key
  end
  table.sort(keys)
  for index = 1, #keys do
    local key = keys[index]
    parts[index] = encodeString(key) .. ":" .. encodeValue(value[key], depth + 1)
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

---@param value any
---@param depth integer
---@return string
function encodeValue(value, depth)
  local kind = type(value)
  if kind == "nil" then
    return "null"
  elseif kind == "boolean" then
    return value and "true" or "false"
  elseif kind == "number" then
    return encodeNumber(value)
  elseif kind == "string" then
    return encodeString(value)
  elseif kind == "table" then
    return encodeTable(value, depth)
  end
  error("Bench.EncodeJson: cannot encode a " .. kind, 0)
end

---Encode a result as JSON: objects with sorted keys, so output is stable.
---An empty table encodes as an object (`{}`).
---@param value any
---@return string
function Bench.EncodeJson(value)
  return encodeValue(value, 0)
end

return Bench
