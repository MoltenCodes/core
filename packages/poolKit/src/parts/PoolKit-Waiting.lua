-- MoltenCodes PoolKit part Waiting
--
-- A live limit and a bounded waiting queue for pools of objects the host can
-- never free: `PoolKit:New` options `maxActive` (objects borrowed or parked at
-- the same time) and `maxWaiting` (requests `Acquire(onAvailable)` may queue),
-- and `pool:CancelWaiting`. Without this part those options are refused at
-- the caller with the file to embed, `GetWaitingCount` answers `0`, and
-- `Acquire(onAvailable)` at capacity answers `nil, "queueFull"`
-- (docs/API.md, "Objects the host can never free"; ADR 0001).
--
-- The core calls the hooks this part records in `_state.parts.Waiting`
-- (`configure`, `enqueue`, `drain`, `fail`) only for a pool that has a queue,
-- and the part reads the core's helpers from `_state.helpers` at call time,
-- so a core upgraded after this part loaded serves it.
--
-- The queue is a ring of `maxWaiting` slots filled with `false` when the pool
-- is built, so enqueueing and dequeueing only overwrite existing array slots:
-- no allocation, ever. A request past the ring's size is refused with
-- `"queueFull"` rather than growing it.
--
-- Contents
-- --------
--   Constants ............. identity and the part interface it needs
--   Core .................. PoolKit's core, its state and its prototype
--   Queue ................. the ring, draining and failing it
--   Methods ............... CancelWaiting
--   Commit ................ the part record and the prototype method

-- Constants ------------------------------------------------------------------

local PART_NAME = "Waiting"
local PART_REVISION = 1
local REQUIRED_REGISTRY_API = 2
local CORE_PACKAGE, CORE_API = "poolKit", 1
-- The `_state.helpers` entries and part-record hooks this part relies on; the
-- core publishes the interface it offers as `_state.partInterface`.
local REQUIRED_PART_INTERFACE = 1

-- Values of the pool layout every revision shares: per-object status in a
-- pool's `_active` map, and the reason a queued request fails with.
local REASON_CLOSED = "closed"

-- Core -----------------------------------------------------------------------

local type = type
local rawget = rawget
local rawset = rawset

-- The shared MoltenCodes namespace is the one documented global handoff point between independently embedded copies.
-- selene: allow(global_usage)
local namespace = rawget(_G, "MoltenCodes")
local generations = type(namespace) == "table" and rawget(namespace, "Registries") or nil
local Registry = type(generations) == "table" and rawget(generations, REQUIRED_REGISTRY_API) or nil
local PoolKit = nil
if type(Registry) == "table" and type(rawget(Registry, "Get")) == "function" then
  PoolKit = Registry:Get(CORE_PACKAGE, CORE_API)
end
local state = type(PoolKit) == "table" and rawget(PoolKit, "_state") or nil
local partInterface = type(state) == "table" and rawget(state, "partInterface") or nil
if
  type(state) ~= "table"
  or type(partInterface) ~= "number"
  or partInterface < REQUIRED_PART_INTERFACE
  or type(rawget(state, "parts")) ~= "table"
  or type(rawget(state, "helpers")) ~= "table"
then
  error("MoltenCodes PoolKit part Waiting requires PoolKit API 1 to be loaded first", 2)
end

local parts = rawget(state, "parts")
local installed = rawget(parts, PART_NAME)
if
  type(installed) == "table"
  and type(rawget(installed, "revision")) == "number"
  and rawget(installed, "revision") >= PART_REVISION
then
  -- An equal or newer revision of this part already serves every copy.
  return PoolKit
end

local Pool = rawget(PoolKit, "Pool")

-- Queue ----------------------------------------------------------------------

---Set up the live limit and the ring of a pool `PoolKit:New` is building.
---@param pool table
---@param maxActive integer|false
---@param maxWaiting integer
local function configure(pool, maxActive, maxWaiting)
  if maxActive then
    rawset(pool, "_maxActive", maxActive)
  end
  if maxWaiting > 0 then
    -- The ring is filled once here, so queue traffic only overwrites slots.
    local waiting = {}
    for slot = 1, maxWaiting do
      waiting[slot] = false
    end
    rawset(pool, "_maxWaiting", maxWaiting)
    rawset(pool, "_waiting", waiting)
    rawset(pool, "_waitingHead", 1)
    rawset(pool, "_waitingCount", 0)
  end
end

---Append a waiting request at the back of the ring. The core checked room.
---@param pool table
---@param callback PoolKit.WaitCallback
local function enqueueWaiter(pool, callback)
  local capacity = rawget(pool, "_maxWaiting")
  local count = rawget(pool, "_waitingCount")
  local slot = (rawget(pool, "_waitingHead") + count - 1) % capacity + 1
  rawset(rawget(pool, "_waiting"), slot, callback)
  rawset(pool, "_waitingCount", count + 1)
end

---Put a request back at the front of the ring after a hand-off failed.
---@param pool table
---@param callback PoolKit.WaitCallback
local function requeueFront(pool, callback)
  local capacity = rawget(pool, "_maxWaiting")
  local head = (rawget(pool, "_waitingHead") - 2) % capacity + 1
  rawset(rawget(pool, "_waiting"), head, callback)
  rawset(pool, "_waitingHead", head)
  rawset(pool, "_waitingCount", rawget(pool, "_waitingCount") + 1)
end

---Remove and return the oldest waiting request. The caller checked one exists.
---@param pool table
---@return PoolKit.WaitCallback callback
local function dequeueWaiter(pool)
  local waiting = rawget(pool, "_waiting")
  local head = rawget(pool, "_waitingHead")
  local callback = rawget(waiting, head)
  rawset(waiting, head, false)
  rawset(pool, "_waitingHead", head % rawget(pool, "_maxWaiting") + 1)
  rawset(pool, "_waitingCount", rawget(pool, "_waitingCount") - 1)
  return callback
end

---Remove the oldest waiting request equal to `callback`, keeping FIFO order.
---@param pool table
---@param callback function
---@return boolean removed
local function removeWaiter(pool, callback)
  local count = rawget(pool, "_waitingCount")
  local capacity = rawget(pool, "_maxWaiting")
  local head = rawget(pool, "_waitingHead")
  local waiting = rawget(pool, "_waiting")

  for offset = 0, count - 1 do
    if rawget(waiting, (head + offset - 1) % capacity + 1) == callback then
      -- Shift every request behind it one slot towards the head.
      for later = offset, count - 2 do
        local target = (head + later - 1) % capacity + 1
        local source = (head + later) % capacity + 1
        rawset(waiting, target, rawget(waiting, source))
      end
      rawset(waiting, (head + count - 2) % capacity + 1, false)
      rawset(pool, "_waitingCount", count - 1)
      return true
    end
  end
  return false
end

---Hand freed capacity to waiting requests, oldest first.
---
---A request's object is borrowed on its behalf before its callback runs, so
---the callback owns it exactly as an `Acquire` caller would. A callback that
---raises is reported through the host error handler and keeps the object. A
---factory that raises is reported the same way; the request goes back to the
---front of the queue and waits for the next release.
---@param pool table
local function drainWaiting(pool)
  local helpers = rawget(state, "helpers")
  local hasCapacity, takeObject, markActive =
    helpers.hasCapacity, helpers.takeObject, helpers.markActive
  local reportWarning = helpers.reportWarning
  while
    rawget(pool, "_waitingCount") > 0
    and rawget(pool, "_closed") ~= true
    and hasCapacity(pool)
  do
    local callback = dequeueWaiter(pool)
    local ok, object = pcall(takeObject, pool, "PoolKit.Pool:Acquire", 0)
    if not ok then
      requeueFront(pool, callback)
      reportWarning(object)
      return
    end

    markActive(pool, object)
    local delivered, callbackError = pcall(callback, object, pool)
    if not delivered then
      reportWarning(callbackError)
    end
  end
end

---Fail every waiting request because the pool closed. Errors are reported.
---@param pool table
local function failWaiting(pool)
  local helpers = rawget(state, "helpers")
  while rawget(pool, "_waitingCount") > 0 do
    local callback = dequeueWaiter(pool)
    local ok, callbackError = pcall(callback, nil, pool, REASON_CLOSED)
    if not ok then
      helpers.reportWarning(callbackError)
    end
  end
end

-- Methods --------------------------------------------------------------------

---Withdraw the oldest waiting request made with `callback`.
---@param self PoolKit.Pool
---@param callback PoolKit.WaitCallback
---@return boolean removed `false` when no such request was waiting.
local function poolCancelWaiting(self, callback)
  local helpers = rawget(state, "helpers")
  helpers.validatePool(self, "PoolKit.Pool:CancelWaiting", 3)
  helpers.ensureMutationAllowed(self, "PoolKit.Pool:CancelWaiting", 3)
  helpers.validateCallback(callback, "PoolKit.Pool:CancelWaiting callback", true, 3)
  local count = rawget(self, "_waitingCount")
  if not count or count == 0 then
    return false
  end
  return removeWaiter(self, callback)
end

-- Commit ---------------------------------------------------------------------

rawset(parts, PART_NAME, {
  revision = PART_REVISION,
  methods = { CancelWaiting = poolCancelWaiting },
  configure = configure,
  enqueue = enqueueWaiter,
  drain = drainWaiting,
  fail = failWaiting,
})
rawset(Pool, "CancelWaiting", poolCancelWaiting)

return PoolKit
