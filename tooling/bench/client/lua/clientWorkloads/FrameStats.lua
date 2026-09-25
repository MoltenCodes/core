--- Small statistics the in-client benchmark needs across frames.
---
--- A series of numbers with nearest-rank percentiles (frame times, round
--- trips), a counter of completed garbage-collection cycles, and a
--- least-squares slope (memory growth per minute). Plain Lua 5.1, so the same
--- code runs in the client and on the host.

local FrameStats = {}

---A growing list of numbers.
---@class FrameStats.Series
---@field Add fun(value: number) appends one value
---@field Count fun(): integer how many values were added
---@field Percentile fun(percent: number): number|nil the nearest-rank percentile, `nil` when empty
---@field Maximum fun(): number|nil the largest value, `nil` when empty
---@field Values fun(): number[] the values in the order they were added (the series' own array)

---Start an empty series.
---@return FrameStats.Series
function FrameStats.NewSeries()
  local values, count = {}, 0
  local sorted = nil
  local series = {}

  function series.Add(value)
    count = count + 1
    values[count] = value
    sorted = nil
  end

  function series.Count()
    return count
  end

  ---Nearest rank: the smallest value with at least `percent` % of the values
  ---at or below it. Sorting happens once per read after new values.
  function series.Percentile(percent)
    if count == 0 then
      return nil
    end
    if sorted == nil then
      sorted = {}
      for index = 1, count do
        sorted[index] = values[index]
      end
      table.sort(sorted)
    end
    local rank = math.ceil(percent / 100 * count)
    if rank < 1 then
      rank = 1
    end
    return sorted[rank]
  end

  function series.Maximum()
    if count == 0 then
      return nil
    end
    local largest = values[1]
    for index = 2, count do
      if values[index] > largest then
        largest = values[index]
      end
    end
    return largest
  end

  function series.Values()
    return values
  end

  return series
end

--- The histogram's relative precision: a bucket spans 1 % of its values.
local HISTOGRAM_GROWTH = 1.01

--- The histogram's smallest resolved value (milliseconds when it holds times);
--- anything at or below it counts in bucket 0.
local HISTOGRAM_FLOOR = 1e-4

--- Buckets from the floor up: 1.01 ^ 2400 is about 2.3e10, so values up to
--- 2e6 (over half an hour in milliseconds) are resolved; larger ones share the last.
local HISTOGRAM_BUCKETS = 2400

---Start an empty histogram: the same reads as a series, in fixed memory.
---
---A frame case runs for minutes; keeping every frame's time would grow the
---heap by the runner's own arrays while the case measures the heap. The
---histogram allocates its buckets once, here, and never again: a value falls
---into a bucket whose bounds differ by 1 %, so a percentile is exact to 1 %.
---`Maximum` and `Count` are exact.
---@return FrameStats.Series
function FrameStats.NewHistogram()
  local buckets = {}
  for index = 0, HISTOGRAM_BUCKETS do
    buckets[index] = 0
  end
  local logGrowth = math.log(HISTOGRAM_GROWTH)
  local count, largest = 0, nil
  local histogram = {}

  function histogram.Add(value)
    count = count + 1
    if largest == nil or value > largest then
      largest = value
    end
    local index = 0
    if value > HISTOGRAM_FLOOR then
      index = math.floor(math.log(value / HISTOGRAM_FLOOR) / logGrowth) + 1
      if index > HISTOGRAM_BUCKETS then
        index = HISTOGRAM_BUCKETS
      end
    end
    buckets[index] = buckets[index] + 1
  end

  function histogram.Count()
    return count
  end

  ---The upper bound of the bucket holding the nearest-rank percentile, never
  ---above the largest value seen.
  function histogram.Percentile(percent)
    if count == 0 then
      return nil
    end
    local rank = math.max(1, math.ceil(percent / 100 * count))
    local seen = 0
    for index = 0, HISTOGRAM_BUCKETS do
      seen = seen + buckets[index]
      if seen >= rank then
        local upper = HISTOGRAM_FLOOR * HISTOGRAM_GROWTH ^ index
        return math.min(upper, largest)
      end
    end
    return largest
  end

  function histogram.Maximum()
    return largest
  end

  function histogram.Values()
    error("FrameStats histogram keeps no values", 2)
  end

  return histogram
end

---Counts completed collection cycles.
---@class FrameStats.CycleCounter
---@field Check fun() looks once; call it every frame
---@field Count fun(): integer cycles seen so far

---Start counting collection cycles.
---
---Lua 5.1 has no call that reports a finished cycle, so the counter keeps one
---unreachable table as the only key of a weak-keyed table. The collector
---clears that entry in the atomic phase of the cycle that finds the key dead;
---when `Check` sees the entry gone, one cycle has completed and a fresh key is
---planted. A key planted during a cycle may survive that cycle, so the count
---can lag by one; checking every frame never misses a cycle unless two
---complete within one frame.
---@return FrameStats.CycleCounter
function FrameStats.NewCycleCounter()
  local sentinel = setmetatable({}, { __mode = "k" })
  sentinel[{}] = true
  local cycles = 0
  local counter = {}

  function counter.Check()
    if next(sentinel) == nil then
      cycles = cycles + 1
      sentinel[{}] = true
    end
  end

  function counter.Count()
    return cycles
  end

  return counter
end

---The least-squares slope of `ys` against `xs`, or `nil` with fewer than two
---distinct `xs`.
---@param xs number[]
---@param ys number[]
---@return number|nil
function FrameStats.Slope(xs, ys)
  local count = math.min(#xs, #ys)
  if count < 2 then
    return nil
  end
  local sumX, sumY = 0, 0
  for index = 1, count do
    sumX = sumX + xs[index]
    sumY = sumY + ys[index]
  end
  local meanX, meanY = sumX / count, sumY / count
  local covariance, variance = 0, 0
  for index = 1, count do
    local deltaX = xs[index] - meanX
    covariance = covariance + deltaX * (ys[index] - meanY)
    variance = variance + deltaX * deltaX
  end
  if variance == 0 then
    return nil
  end
  return covariance / variance
end

return FrameStats
