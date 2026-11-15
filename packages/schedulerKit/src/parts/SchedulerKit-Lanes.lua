-- MoltenCodes SchedulerKit part Lanes
--
-- `SchedulerKit:Lane(name[, options])` and lane objects: a lane decides *how
-- much* of a scarce resource is used at once. At most `maxInFlight`
-- submissions run at once, two starts are at least `minIntervalSeconds`
-- apart, a submission that raises is retried with exponential backoff, and
-- at most `maxQueued` submissions wait. Debounce and Coalesce handles given
-- `options.lane` deliver through it.
--
-- Lanes are shared by name in package state and are not owned by a scope;
-- each submission's job is. The core tells this part when a lane job ends or
-- raises through the dispatch entries `laneJobFinished` and `retryLaneJob`.
-- The part needs SchedulerKit's core and its Coalescing part loaded first.
--
-- Contents
-- --------
--   Constants ............. identity, defaults, option names
--   Dependencies .......... SchedulerKit's core, its state, the Coalescing part
--   Lanes ................. admission, submission, retries, lane methods
--   Commit ................ the lane prototype, `Lane`, dispatch, the revision

-- Constants ------------------------------------------------------------------

local PART_NAME = "Lanes"
local PART_REVISION = 1
local REQUIRED_PART_INTERFACE = 1
local REQUIRED_REGISTRY_API = 2
local CORE_PACKAGE, CORE_API = "schedulerKit", 1
local PRIORITY_NORMAL = 2

local DEFAULT_LANE_MAX_IN_FLIGHT = 1
local DEFAULT_LANE_MAX_QUEUED = 64
local DEFAULT_RETRY_MULTIPLIER = 2
-- A timer that wakes this close to its due time counts as due.
local DUE_TOLERANCE_SECONDS = 0.001

local LANE_OPTION_KEYS = {
  maxInFlight = true,
  minIntervalSeconds = true,
  retry = true,
  maxQueued = true,
}
local RETRY_OPTION_KEYS = {
  attempts = true,
  backoffSeconds = true,
  multiplier = true,
  maxBackoffSeconds = true,
}
local SUBMIT_OPTION_KEYS = { priority = true, name = true, scope = true }

-- Dependencies ---------------------------------------------------------------

-- The shared MoltenCodes namespace is the one documented global handoff point between independently embedded copies.
-- selene: allow(global_usage)
local namespace = rawget(_G, "MoltenCodes")
local generations = type(namespace) == "table" and rawget(namespace, "Registries") or nil
local Registry = type(generations) == "table" and rawget(generations, REQUIRED_REGISTRY_API) or nil
local SchedulerKit = nil
if type(Registry) == "table" then
  local find = rawget(Registry, "Find")
  if type(find) ~= "function" then
    find = rawget(Registry, "Get")
  end
  if type(find) == "function" then
    SchedulerKit = find(Registry, CORE_PACKAGE, CORE_API)
  end
end
local state = type(SchedulerKit) == "table" and rawget(SchedulerKit, "_state") or nil
if
  type(state) ~= "table"
  or type(rawget(state, "parts")) ~= "table"
  or type(rawget(state, "helpers")) ~= "table"
  or type(rawget(state, "familyHelpers")) ~= "table"
  or type(rawget(state, "dispatch")) ~= "table"
  or type(rawget(state, "partInterface")) ~= "number"
  or rawget(state, "partInterface") < REQUIRED_PART_INTERFACE
then
  error(
    "MoltenCodes SchedulerKit part "
      .. PART_NAME
      .. " requires SchedulerKit API 1 to be loaded first",
    2
  )
end

local parts = rawget(state, "parts")
if type(rawget(parts, "Coalescing")) ~= "table" then
  error(
    "MoltenCodes SchedulerKit part "
      .. PART_NAME
      .. " requires SchedulerKit part Coalescing to be loaded first",
    2
  )
end
local installed = rawget(parts, PART_NAME)
if
  type(installed) == "table"
  and type(installed.revision) == "number"
  and installed.revision >= PART_REVISION
then
  -- An equal or newer revision of this part already serves every lane.
  return SchedulerKit
end

---@cast SchedulerKit table
-- Read at call time, never copied: an upgraded core or Coalescing part
-- serves this part.
local helpers = rawget(state, "helpers")
local family = rawget(state, "familyHelpers")
local sharedLimits = rawget(state, "limits")
local UNBOUNDED = rawget(state, "unbounded")
local SCOPE_METATABLE = rawget(state, "scopeMetatable")
local LANE_METATABLE = rawget(rawget(state, "familyMetatables"), "lane")
local FAMILY_PROTOTYPES = rawget(state, "familyPrototypes")

---@param value any
---@param label string argument description, used in the argument error
---@param level integer stack level the failure is reported at
local function validateCount(value, label, level)
  helpers.refuseSecretValue(value, label, level + 1)
  if
    type(value) ~= "number"
    or value ~= value
    or value == math.huge
    or value ~= math.floor(value)
    or value < 0
  then
    error(label .. " must be a finite integer greater than or equal to zero", level)
  end
end

-- Lanes -------------------------------------------------------------------
--
-- A lane rations one scarce resource: at most `maxInFlight` submissions run
-- at once, two starts are at least `minIntervalSeconds` apart, a submission
-- that raises is retried with exponential backoff, and at most `maxQueued`
-- submissions wait. A submission is an ordinary scheduler job created in the
-- "delayed" state and parked in the lane's FIFO; admission moves it to the
-- ready queues exactly as a delay expiring would. The job stays owned by its
-- scope, so closing the scope cancels it wherever it is, and `finishJob`
-- reports every terminal state back to the lane.

local admittedJobs

---Whether `job` is still waiting for admission and should be served.
---@param job any
---@return boolean
local function isWaitingLaneJob(job)
  return type(job) == "table"
    and rawget(job, "_laneAdmitted") == false
    and rawget(job, "_state") == "delayed"
end

---Drop stale entries from the lane FIFO so its backing array holds at most
---the live waiting submissions. Only runs when the array is full of entries
---some of which were cancelled in place, so it is bounded by `maxQueued`.
---@param lane SchedulerKit.Lane
local function compactLaneQueue(lane)
  local items = rawget(lane, "_items")
  local head = rawget(lane, "_head")
  local tail = rawget(lane, "_tail")
  local write = 0
  for read = head, tail do
    local job = items[read]
    items[read] = nil
    if isWaitingLaneJob(job) then
      write = write + 1
      items[write] = job
    end
  end
  rawset(lane, "_head", 1)
  rawset(lane, "_tail", write)
end

---Take the next waiting submission, discarding stale entries.
---@param lane SchedulerKit.Lane
---@return SchedulerKit.Job|nil
local function popLaneJob(lane)
  local items = rawget(lane, "_items")
  local head = rawget(lane, "_head")
  local tail = rawget(lane, "_tail")
  while head <= tail do
    local job = items[head]
    items[head] = nil
    head = head + 1
    if isWaitingLaneJob(job) then
      if head > tail then
        -- Drained: restart at the front so the indices do not
        -- climb for the lane's whole life.
        head, tail = 1, 0
        rawset(lane, "_tail", 0)
      end
      rawset(lane, "_head", head)
      return job
    end
  end
  rawset(lane, "_head", 1)
  rawset(lane, "_tail", 0)
  return nil
end

---Arm a lane's interval timer in the package-internal timer scope.
---@param lane SchedulerKit.Lane
---@param seconds number
local function armLaneTimer(lane, seconds)
  family.armOwnerTimer(lane, family.ensureFamilyTimerScope(), seconds)
end

---Return the set of the lane's admitted, unfinished jobs. A lane created by
---revision 7 has none; it is created on first use.
---@param lane SchedulerKit.Lane
---@return table<SchedulerKit.Job, boolean>
function admittedJobs(lane)
  local admitted = rawget(lane, "_admitted")
  if type(admitted) ~= "table" then
    admitted = {}
    rawset(lane, "_admitted", admitted)
  end
  return admitted
end

---Admit waiting submissions while the lane has room and its interval allows.
---
---Never raises: it is reached from `finishJob` and from a TimerKit callback,
---where nobody can observe a raise. A failure to arm the interval timer is
---reported, and the queue resumes on the next submission or completion.
---@param lane SchedulerKit.Lane
---@return boolean admitted whether a submission entered the ready queues
local function pumpLane(lane)
  local admitted = false
  while
    rawget(lane, "_closed") ~= true
    and rawget(lane, "_timer") == false
    and rawget(lane, "_inFlight") < rawget(lane, "_maxInFlight")
    and rawget(lane, "_queued") > 0
  do
    local minInterval = rawget(lane, "_minInterval")
    local lastStart = rawget(lane, "_lastStart")
    if minInterval > 0 and lastStart ~= false then
      local wait = lastStart + minInterval - family.nowSeconds()
      -- A clock that stepped backwards cannot stretch the wait
      -- past one interval.
      if wait > minInterval then
        wait = minInterval
      end
      if wait > DUE_TOLERANCE_SECONDS then
        local ok, value = pcall(armLaneTimer, lane, wait)
        if not ok then
          helpers.reportError(value)
        end
        return admitted
      end
    end

    local job = popLaneJob(lane)
    if job == nil then
      -- The count and the FIFO disagree; trust the FIFO.
      rawset(lane, "_queued", 0)
      return admitted
    end

    rawset(lane, "_queued", rawget(lane, "_queued") - 1)
    rawset(lane, "_inFlight", rawget(lane, "_inFlight") + 1)
    rawset(lane, "_lastStart", family.nowSeconds())
    rawset(job, "_laneAdmitted", true)
    rawset(job, "_state", "pending")
    admittedJobs(lane)[job] = true
    helpers.queuePush(job)
    admitted = true
  end
  return admitted
end

---Create one lane submission, or refuse it without allocating.
---@param lane SchedulerKit.Lane
---@param scope SchedulerKit.Scope open scope that owns the job
---@param callback SchedulerKit.Callback
---@param priority integer
---@param name string|nil
---@param owner table|false the Debounce or Coalesce member delivering through it
---@return SchedulerKit.Job|nil job
---@return string|nil reason `"full"` or `"closed"` when refused
local function submitToLane(lane, scope, callback, priority, name, owner)
  if rawget(lane, "_closed") == true then
    rawset(lane, "_refused", rawget(lane, "_refused") + 1)
    return nil, "closed"
  end
  local maxQueued = rawget(lane, "_maxQueued")
  if rawget(lane, "_queued") >= maxQueued then
    rawset(lane, "_refused", rawget(lane, "_refused") + 1)
    return nil, "full"
  end
  if rawget(lane, "_tail") - rawget(lane, "_head") + 1 >= maxQueued then
    compactLaneQueue(lane)
  end

  local job = helpers.newJob(scope, callback, priority, name, false)
  rawset(job, "_state", "delayed")
  rawset(job, "_lane", lane)
  rawset(job, "_laneAdmitted", false)
  rawset(job, "_attempt", 0)
  rawset(job, "_laneOwner", owner)

  local tail = rawget(lane, "_tail") + 1
  rawset(lane, "_tail", tail)
  rawget(lane, "_items")[tail] = job
  rawset(lane, "_queued", rawget(lane, "_queued") + 1)

  if pumpLane(lane) then
    local ok, value = pcall(helpers.updateDriver)
    if not ok then
      helpers.reportError(value)
    end
  end
  return job, nil
end

---Account for a lane job reaching a terminal state. Called from `finishJob`
---for every lane job, exactly once.
---@param job SchedulerKit.Job
---@param lane SchedulerKit.Lane
---@param terminalState "completed"|"cancelled"|"failed"
local function laneJobFinished(job, lane, terminalState)
  rawset(job, "_lane", false)
  if rawget(job, "_laneAdmitted") == true then
    admittedJobs(lane)[job] = nil
    rawset(lane, "_inFlight", rawget(lane, "_inFlight") - 1)
  else
    rawset(lane, "_queued", rawget(lane, "_queued") - 1)
  end

  if terminalState == "completed" then
    rawset(lane, "_completed", rawget(lane, "_completed") + 1)
  elseif terminalState == "failed" then
    rawset(lane, "_failed", rawget(lane, "_failed") + 1)
  else
    rawset(lane, "_cancelled", rawget(lane, "_cancelled") + 1)
  end

  local owner = rawget(job, "_laneOwner")
  if type(owner) == "table" then
    rawset(job, "_laneOwner", false)
    -- `finishJob` runs inside cancellation and the frame pass; a failing
    -- follow-up delivery must not escape into either.
    local ok, value = pcall(family.memberDeliveryFinished, owner, job, terminalState)
    if not ok then
      helpers.reportError(value)
    end
  end

  -- Whoever finished the job updates the driver afterwards: cancellation
  -- does, and so does the frame pass.
  pumpLane(lane)
end

---Re-arm a lane job whose attempt raised, if its lane still allows a retry.
---
---A retried attempt is not reported to the host error handler: the retry is
---the expected outcome. Only the attempt that exhausts the policy fails the
---job and is reported, with its traceback, like any other job failure. The job
---keeps its in-flight slot during the backoff, which is what backing off a
---resource means.
---@param job SchedulerKit.Job
---@param lane SchedulerKit.Lane
---@return boolean retried
local function retryLaneJob(job, lane)
  local attempt = rawget(job, "_attempt")
  if
    type(attempt) ~= "number"
    or attempt >= rawget(lane, "_attempts")
    or rawget(lane, "_closed") == true
  then
    -- A closed lane retries nothing: the attempt that raised fails.
    return false
  end

  rawset(job, "_attempt", attempt + 1)
  rawset(lane, "_retried", rawget(lane, "_retried") + 1)
  rawset(job, "_coroutine", false)
  rawset(job, "_generation", rawget(job, "_generation") + 1)

  local backoff = rawget(lane, "_backoff") * rawget(lane, "_multiplier") ^ attempt
  local maxBackoff = rawget(lane, "_maxBackoff")
  if maxBackoff ~= false and backoff > maxBackoff then
    backoff = maxBackoff
  end

  -- A retry is a start: it waits at least until the lane's minimum
  -- interval has passed since the last start. The start itself is
  -- recorded when the backoff expires (see `wakeDelayed`).
  local minInterval = rawget(lane, "_minInterval")
  local lastStart = rawget(lane, "_lastStart")
  if minInterval > 0 and lastStart ~= false then
    local wait = lastStart + minInterval - family.nowSeconds()
    if wait > minInterval then
      wait = minInterval
    end
    if wait > backoff then
      backoff = wait
    end
  end

  local ok, value = pcall(helpers.armDelay, job, backoff)
  if not ok then
    if rawget(job, "_state") ~= "failed" then
      helpers.markJobFailed(job, "SchedulerKit failed to arm a lane retry", false)
    end
    helpers.reportError(value)
  end
  return true
end

---Read and validate one lane's options into plain values.
---@param options any
---@param methodName string public method name, used in the argument errors
---@param level integer stack level the failures are reported at
---@return integer maxInFlight, number minInterval, integer attempts, number backoff, number multiplier, number|false maxBackoff, integer maxQueued
local function readLaneOptions(options, methodName, level)
  family.validateOptionTable(options, LANE_OPTION_KEYS, methodName, level + 1)
  local maxInFlight = DEFAULT_LANE_MAX_IN_FLIGHT
  local minInterval = 0
  local maxQueued = DEFAULT_LANE_MAX_QUEUED
  local attempts, backoff, multiplier, maxBackoff = 0, 0, DEFAULT_RETRY_MULTIPLIER, false
  if type(options) == "nil" then
    return maxInFlight, minInterval, attempts, backoff, multiplier, maxBackoff, maxQueued
  end

  if type(rawget(options, "maxInFlight")) ~= "nil" then
    maxInFlight = rawget(options, "maxInFlight")
    helpers.validatePositiveInteger(maxInFlight, methodName .. " maxInFlight", level + 1)
  end
  if type(rawget(options, "minIntervalSeconds")) ~= "nil" then
    minInterval = rawget(options, "minIntervalSeconds")
    helpers.validateFinitePositive(
      minInterval,
      methodName .. " minIntervalSeconds",
      true,
      level + 1
    )
  end
  if type(rawget(options, "maxQueued")) ~= "nil" then
    maxQueued = rawget(options, "maxQueued")
    helpers.validatePositiveInteger(maxQueued, methodName .. " maxQueued", level + 1)
  end

  local retry = rawget(options, "retry")
  if type(retry) ~= "nil" then
    family.validateOptionTable(retry, RETRY_OPTION_KEYS, methodName .. " retry", level + 1)
    if type(rawget(retry, "attempts")) ~= "nil" then
      attempts = rawget(retry, "attempts")
      validateCount(attempts, methodName .. " retry.attempts", level + 1)
    end
    if type(rawget(retry, "backoffSeconds")) ~= "nil" then
      backoff = rawget(retry, "backoffSeconds")
      helpers.validateFinitePositive(
        backoff,
        methodName .. " retry.backoffSeconds",
        true,
        level + 1
      )
    end
    if type(rawget(retry, "multiplier")) ~= "nil" then
      multiplier = rawget(retry, "multiplier")
      helpers.validateFinitePositive(
        multiplier,
        methodName .. " retry.multiplier",
        false,
        level + 1
      )
      if multiplier < 1 then
        error(methodName .. " retry.multiplier must be at least 1", level)
      end
    end
    if type(rawget(retry, "maxBackoffSeconds")) ~= "nil" then
      maxBackoff = rawget(retry, "maxBackoffSeconds")
      helpers.validateFinitePositive(
        maxBackoff,
        methodName .. " retry.maxBackoffSeconds",
        true,
        level + 1
      )
    end
  end
  return maxInFlight, minInterval, attempts, backoff, multiplier, maxBackoff, maxQueued
end

---Return the shared lane called `name`, creating it on first request.
---@param name any
---@param options any
---@param methodName string public method name, used in the argument errors
---@return SchedulerKit.Lane
local function getOrCreateLane(name, options, methodName)
  helpers.validateNonEmptyString(name, methodName .. " name", 4)
  local maxInFlight, minInterval, attempts, backoff, multiplier, maxBackoff, maxQueued =
    readLaneOptions(options, methodName, 4)

  local lanes = rawget(state, "lanes")
  local existing = rawget(lanes, name)
  if existing ~= nil then
    if
      type(options) ~= "nil"
      and (
        rawget(existing, "_maxInFlight") ~= maxInFlight
        or rawget(existing, "_minInterval") ~= minInterval
        or rawget(existing, "_attempts") ~= attempts
        or rawget(existing, "_backoff") ~= backoff
        or rawget(existing, "_multiplier") ~= multiplier
        or rawget(existing, "_maxBackoff") ~= maxBackoff
        or rawget(existing, "_maxQueued") ~= maxQueued
      )
    then
      error(methodName .. ' lane "' .. name .. '" already exists with different options', 3)
    end
    return existing
  end

  local maxLanes = rawget(sharedLimits, "maxLanes")
  if maxLanes ~= UNBOUNDED and rawget(state, "laneCount") >= maxLanes then
    error(
      methodName
        .. " refuses to create more than "
        .. maxLanes
        .. " open lanes; close unused lanes, share one by name, or raise"
        .. " SchedulerKit:SetLimits{ maxLanes }",
      3
    )
  end

  local lane = setmetatable({
    _kind = "lane",
    _name = name,
    _maxInFlight = maxInFlight,
    _minInterval = minInterval,
    _attempts = attempts,
    _backoff = backoff,
    _multiplier = multiplier,
    _maxBackoff = maxBackoff,
    _maxQueued = maxQueued,
    _items = {},
    _head = 1,
    _tail = 0,
    _queued = 0,
    _inFlight = 0,
    _completed = 0,
    _failed = 0,
    _retried = 0,
    _cancelled = 0,
    _refused = 0,
    _lastStart = false,
    _timer = false,
    _closed = false,
    _statsView = false,
  }, LANE_METATABLE)
  rawset(lanes, name, lane)
  rawset(state, "laneCount", rawget(state, "laneCount") + 1)
  return lane
end

---Submit `callback` to run as a job under this lane's limits.
---@param self SchedulerKit.Lane
---@param callback SchedulerKit.Callback
---@param options SchedulerKit.SubmitOptions?
---@return SchedulerKit.Job|nil job
---@return string|nil reason `"full"` or `"closed"` when refused
local function laneSubmit(self, callback, options)
  family.validateMember(self, LANE_METATABLE, "SchedulerKit.Lane:Submit", "lane")
  if type(callback) ~= "function" then
    error("SchedulerKit.Lane:Submit callback must be a function", 2)
  end
  family.validateOptionTable(options, SUBMIT_OPTION_KEYS, "SchedulerKit.Lane:Submit", 3)

  local priority, name, scope = PRIORITY_NORMAL, nil, nil
  if type(options) ~= "nil" then
    priority =
      helpers.validatePriority(rawget(options, "priority"), "SchedulerKit.Lane:Submit priority", 3)
    name = rawget(options, "name")
    if type(name) ~= "nil" then
      helpers.validateNonEmptyString(name, "SchedulerKit.Lane:Submit name", 3)
    end
    scope = rawget(options, "scope")
    if type(scope) ~= "nil" and getmetatable(scope) ~= SCOPE_METATABLE then
      error("SchedulerKit.Lane:Submit scope must be a SchedulerKit scope", 2)
    end
  end
  if type(scope) == "nil" then
    scope = helpers.getDefaultScope()
  elseif rawget(scope, "_closed") == true then
    error("SchedulerKit.Lane:Submit cannot schedule work in a closed scope", 2)
  end

  local job, reason = submitToLane(self, scope, callback, priority, name, false)
  return job, reason
end

---Return this lane's counters in a table reused by every call.
---@param self SchedulerKit.Lane
---@return SchedulerKit.LaneStats stats
local function laneGetStats(self)
  family.validateMember(self, LANE_METATABLE, "SchedulerKit.Lane:GetStats", "lane")
  local view = rawget(self, "_statsView")
  if view == false then
    view = {}
    rawset(self, "_statsView", view)
  end
  view.queued = rawget(self, "_queued")
  view.inFlight = rawget(self, "_inFlight")
  view.completed = rawget(self, "_completed")
  view.failed = rawget(self, "_failed")
  view.retried = rawget(self, "_retried")
  view.cancelled = rawget(self, "_cancelled")
  view.refused = rawget(self, "_refused")
  return view
end

---Return the name this lane is shared under.
---@param self SchedulerKit.Lane
---@return string name
local function laneGetName(self)
  family.validateMember(self, LANE_METATABLE, "SchedulerKit.Lane:GetName", "lane")
  return rawget(self, "_name")
end

---Whether this lane is closed.
---@param self SchedulerKit.Lane
---@return boolean closed
local function laneIsClosed(self)
  family.validateMember(self, LANE_METATABLE, "SchedulerKit.Lane:IsClosed", "lane")
  return rawget(self, "_closed") == true
end

---Close the lane: refuse new submissions, cancel every waiting submission,
---and let the admitted ones run to completion. The name is released at once,
---so a later `Lane(name)` creates a fresh lane.
---@param self SchedulerKit.Lane
---@return boolean closed `false` when the lane was already closed.
local function laneClose(self)
  family.validateMember(self, LANE_METATABLE, "SchedulerKit.Lane:Close", "lane")
  if rawget(self, "_closed") == true then
    return false
  end
  rawset(self, "_closed", true)

  local lanes = rawget(state, "lanes")
  if rawget(lanes, rawget(self, "_name")) == self then
    rawset(lanes, rawget(self, "_name"), nil)
    rawset(state, "laneCount", rawget(state, "laneCount") - 1)
  end

  local firstError = nil
  local ok, value = pcall(family.cancelOwnerTimer, self)
  if not ok then
    firstError = { value = value }
  end

  local items = rawget(self, "_items")
  for index = rawget(self, "_head"), rawget(self, "_tail") do
    local job = items[index]
    items[index] = nil
    if isWaitingLaneJob(job) then
      local cancelOk, cancelError = pcall(helpers.cancelJob, job)
      if not cancelOk and firstError == nil then
        firstError = { value = cancelError }
      end
    end
  end
  rawset(self, "_head", 1)
  rawset(self, "_tail", 0)

  -- An admitted job waiting out a retry backoff has not started its next
  -- attempt yet; it is cancelled. Running attempts finish, and one that
  -- raises now fails instead of retrying (see `retryLaneJob`).
  for job in next, admittedJobs(self) do
    if rawget(job, "_state") == "delayed" then
      local cancelOk, cancelError = pcall(helpers.cancelJob, job)
      if not cancelOk and firstError == nil then
        firstError = { value = cancelError }
      end
    end
  end

  if firstError ~= nil then
    error(firstError.value, 0)
  end
  return true
end

---A lane's interval timer expired: admit what the interval was holding back.
---@param lane SchedulerKit.Lane
local function laneWake(lane)
  if pumpLane(lane) then
    helpers.updateDriver()
  end
end

---Return the shared lane called `name`, creating it with `options` first.
---@param _ SchedulerKit
---@param name string
---@param options SchedulerKit.LaneOptions?
---@return SchedulerKit.Lane lane
local function packageLane(_, name, options)
  local lane = getOrCreateLane(name, options, "SchedulerKit:Lane")
  return lane
end

-- Commit ---------------------------------------------------------------------

local LANE_PROTOTYPE = rawget(FAMILY_PROTOTYPES, "lane")
rawset(LANE_PROTOTYPE, "Submit", laneSubmit)
rawset(LANE_PROTOTYPE, "GetStats", laneGetStats)
rawset(LANE_PROTOTYPE, "GetName", laneGetName)
rawset(LANE_PROTOTYPE, "Close", laneClose)
rawset(LANE_PROTOTYPE, "IsClosed", laneIsClosed)

rawset(SchedulerKit, "Lane", packageLane)

-- What the Coalescing part calls to deliver a member through a lane.
rawset(family, "submitToLane", submitToLane)
rawset(family, "laneWake", laneWake)

local dispatch = rawget(state, "dispatch")
rawset(dispatch, "laneJobFinished", laneJobFinished)
rawset(dispatch, "retryLaneJob", retryLaneJob)

rawset(parts, PART_NAME, { revision = PART_REVISION })

return SchedulerKit
