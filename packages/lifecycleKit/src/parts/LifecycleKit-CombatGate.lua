-- MoltenCodes LifecycleKit part CombatGate
--
-- The combat gate (docs/API.md, "Combat gate"): one lockdown state every addon
-- shares, kept by a package-level pair of watchers on `PLAYER_REGEN_DISABLED`
-- and `PLAYER_REGEN_ENABLED`; a bounded per-addon queue of calls that wait for
-- the end of combat (`WhenOutOfCombat`, `DeferredCall`); and the combat notices
-- (`OnCombatStart`, `OnCombatEnd`).
--
-- The part needs LifecycleKit's core loaded first (docs/decisions/
-- 0001-kit-core-and-parts.md). It keeps its state inside the core's: the flag
-- in `state.inCombat`, its two watchers in `state.globalWatchers` beside the
-- core's (so the core's logout teardown releases them), and each addon's queue
-- in that addon's instance, created on first use. It calls the core through
-- `state.helpers`, read at call time, and fills the core's `state.dispatch`
-- entries, so a higher revision of this part takes over queues and watchers
-- in place, and a revision 18 instance's queue is served unchanged.
--
-- Contents
-- --------
--   Constants ........ identity, the compaction floor
--   Dependencies ..... LifecycleKit's core and its state
--   Combat queue ..... bounded FIFO of deferred calls, drain and close
--   Combat state ..... the shared lockdown flag and its announcements
--   Watchers ......... the two host watchers
--   Public API ....... IsInCombat, the instance methods, DeferredCall
--   Commit ........... members, dispatch entries and the part's revision

-- Constants ------------------------------------------------------------------

local PART_NAME = "CombatGate"
local PART_REVISION = 1
local REQUIRED_REGISTRY_API = 2
local CORE_PACKAGE, CORE_API = "lifecycleKit", 1
-- The core interface this part reads (`state.helpers`, `state.dispatch`).
local REQUIRED_PART_INTERFACE = 1

-- The combat queue of an `UNBOUNDED` addon is compacted once its array holds
-- this many slots and at least twice as many as are still pending, so
-- reclaiming cancelled slots stays amortised constant time per call.
local UNBOUNDED_COMPACTION_FLOOR = 64

-- Dependencies ---------------------------------------------------------------

-- The shared MoltenCodes namespace is the one documented global handoff point between independently embedded copies.
-- selene: allow(global_usage)
local namespace = rawget(_G, "MoltenCodes")
local generations = type(namespace) == "table" and rawget(namespace, "Registries") or nil
local Registry = type(generations) == "table" and rawget(generations, REQUIRED_REGISTRY_API) or nil
local LifecycleKit = nil
if type(Registry) == "table" and type(rawget(Registry, "Get")) == "function" then
  LifecycleKit = Registry:Get(CORE_PACKAGE, CORE_API)
end
local state = type(LifecycleKit) == "table" and rawget(LifecycleKit, "_state") or nil
local partInterface = type(state) == "table" and rawget(state, "partInterface") or nil
if
  type(state) ~= "table"
  or type(partInterface) ~= "number"
  or partInterface < REQUIRED_PART_INTERFACE
  or type(rawget(state, "parts")) ~= "table"
  or type(rawget(state, "helpers")) ~= "table"
  or type(rawget(state, "dispatch")) ~= "table"
then
  error(
    "MoltenCodes LifecycleKit part CombatGate requires LifecycleKit API 1 to be loaded first",
    2
  )
end

---@cast LifecycleKit table

local installed = state.parts[PART_NAME]
if
  type(installed) == "table"
  and type(installed.revision) == "number"
  and installed.revision >= PART_REVISION
then
  -- An equal or newer revision of this part already serves every addon.
  return LifecycleKit
end

-- Read at call time, never copied: an upgraded core's helpers serve this part.
local helpers = state.helpers
local dispatch = state.dispatch
local Instance = rawget(LifecycleKit, "Instance")
local DeferredCall = rawget(LifecycleKit, "DeferredCall")
local DEFERRED_CALL_METATABLE = { __index = DeferredCall }

---Report whether the host says combat lockdown is active.
---@return boolean
local function isHostInCombatLockdown()
  -- InCombatLockdown is a World of Warcraft client API reachable only through the global table.
  -- selene: allow(global_usage)
  local probe = rawget(_G, "InCombatLockdown")
  return type(probe) == "function" and probe() == true
end

-- The one lockdown state every addon shares. The host may load an addon
-- mid-combat, so it starts from the host's own answer; revision 18's state
-- already carries it.
if type(state.inCombat) ~= "boolean" then
  state.inCombat = isHostInCombatLockdown()
end

---Whether `value` is a positive integer or the `UNBOUNDED` sentinel.
---@param value any
---@return boolean
local function isLimitValue(value)
  if value == state.unbounded then
    return true
  end
  return type(value) == "number"
    and value >= 1
    and value ~= math.huge
    and math.floor(value) == value
end

-- Combat queue --------------------------------------------------------------
--
-- The queue is an array of deferred-call handles in the instance, reused
-- across combats and created by its first queued call. `_combatQueueLength` is
-- its end index, `_combatPending` the number of slots still waiting; cancelled
-- slots stay in place until the next compaction, so cancelling never
-- allocates or shifts. `_combatQueueLimit` is set when the instance is created
-- (from `defaultCombatQueueLimit` then), so a later change of the default
-- leaves existing addons as they were.

---Return the instance's queue limit; an instance made before this part loaded
---reads the current default.
---@param instance table
---@return integer|table
local function getLimit(instance)
  return instance._combatQueueLimit or state.limits.defaultCombatQueueLimit
end

---Pack the still-pending deferred calls to the front of the queue.
---@param instance table
local function compactCombatQueue(instance)
  local queue = instance._combatQueue
  local length = instance._combatQueueLength
  local written = 0

  for index = 1, length do
    local handle = queue[index]
    if handle ~= nil and handle._pending == true then
      written = written + 1
      queue[written] = handle
    end
  end
  for index = written + 1, length do
    queue[index] = nil
  end

  instance._combatQueueLength = written
end

---Take `handle` out of the pending set and return the callback it carried.
---@param instance table
---@param handle LifecycleKit.DeferredCall
---@return function callback
local function claimDeferredCall(instance, handle)
  local callback = handle._callback
  handle._pending = false
  handle._callback = nil
  handle._instance = nil
  instance._combatPending = instance._combatPending - 1
  return callback
end

---Deliver every pending deferred call of `instance`, oldest first.
---
---Each call runs protected; the first failure is returned once the rest have
---run, which is the phase machinery's first-error policy.
---
---`stopWhenInCombat` is a defensive guard. The client never delivers
---`PLAYER_REGEN_DISABLED` synchronously inside another handler, so a real
---drain is never interrupted. Should a host ever do so, the remaining calls
---stay queued for the next combat end rather than running protected work in
---combat.
---@param instance table
---@param ran boolean `true` for an out-of-combat run, `false` for a closed queue
---@param reason "shutdown"|"halted"|nil why a closed queue did not run the calls
---@param stopWhenInCombat boolean
---@return LifecycleKit.ErrorRecord|nil
local function drainCombatQueue(instance, ran, reason, stopWhenInCombat)
  local queue = instance._combatQueue
  if queue == nil or (instance._combatPending == 0 and instance._combatQueueLength == 0) then
    return nil
  end

  local firstError = nil
  local index = 1

  instance._draining = true
  while index <= instance._combatQueueLength do
    if stopWhenInCombat and state.inCombat == true then
      break
    end

    local handle = queue[index]
    queue[index] = nil
    if handle ~= nil and handle._pending == true then
      local callback = claimDeferredCall(instance, handle)
      local ok, message = pcall(callback, instance, ran, reason)
      if not ok and firstError == nil then
        firstError = helpers.newErrorRecord(message)
      end
    end
    index = index + 1
  end
  instance._draining = false

  compactCombatQueue(instance)
  return firstError
end

---Close the combat queue for good, telling each pending call why it never ran.
---@param instance table
---@param reason "shutdown"|"halted"
---@return LifecycleKit.ErrorRecord|nil
local function closeCombatQueue(instance, reason)
  return drainCombatQueue(instance, false, reason, false)
end

-- Combat state ----------------------------------------------------------------

---Whether `instance` receives `OnCombatStart` / `OnCombatEnd` notifications.
---
---Only an addon that has reached `loaded` is told. An addon's files run and its
---`ADDON_LOADED` follows in one synchronous load, so no `PLAYER_REGEN_*` event
---can arrive in between; the rule only keeps notices away from lifecycle
---instances created for addons that have not loaded yet.
---@param instance table
---@return boolean
local function receivesCombatNotices(instance)
  return instance._loaded == true and not helpers.isTerminal(instance)
end

---Deliver `OnCombatStart` to every eligible addon, in `state.instances` order.
---@return LifecycleKit.ErrorRecord|nil
local function announceCombatStart()
  local instances = state.instances
  local deliver = helpers.deliver
  local firstError = nil

  for index = 1, #instances do
    local instance = instances[index]
    if receivesCombatNotices(instance) then
      local noticeError = deliver(instance, "combatStart")
      if firstError == nil then
        firstError = noticeError
      end
    end
  end

  return firstError
end

---Drain every addon's combat queue and, after a real flip, announce the end.
---
---Per addon, in `state.instances` order: the queued calls run first, then its
---`OnCombatEnd` subscribers.
---@param announce boolean whether the shared state flipped and `OnCombatEnd` is due
---@return LifecycleKit.ErrorRecord|nil
local function finishCombat(announce)
  local instances = state.instances
  local deliver = helpers.deliver
  local isTerminal = helpers.isTerminal
  local firstError = nil

  for index = 1, #instances do
    local instance = instances[index]
    if not isTerminal(instance) then
      local queueError = drainCombatQueue(instance, true, nil, true)
      if firstError == nil then
        firstError = queueError
      end
      if announce and receivesCombatNotices(instance) then
        local noticeError = deliver(instance, "combatEnd")
        if firstError == nil then
          firstError = noticeError
        end
      end
    end
  end

  return firstError
end

---Move the shared combat flag to `inCombat` and run what the change implies.
---@param inCombat boolean
---@return LifecycleKit.ErrorRecord|nil
local function setCombatState(inCombat)
  local wasInCombat = state.inCombat == true
  state.inCombat = inCombat

  if inCombat then
    if wasInCombat then
      return nil
    end
    return announceCombatStart()
  end

  -- A queue can hold calls only while in combat, so a redundant end still
  -- drains safely; `OnCombatEnd` is announced only for a real flip.
  return finishCombat(wasInCombat)
end

---Bring the shared flag in line with the host after a moment it may have
---changed unobserved (a login, or combat watchers that were missing).
---@return LifecycleKit.ErrorRecord|nil
local function reconcileCombatState()
  local hostInCombat = isHostInCombatLockdown()
  if hostInCombat == (state.inCombat == true) then
    return nil
  end
  return setCombatState(hostInCombat)
end

-- Watchers --------------------------------------------------------------------

---`PLAYER_REGEN_DISABLED` handler: the player entered combat.
---
---The host raises this event just before lockdown begins, so the flag flips
---here, one step ahead of `InCombatLockdown()`: from this point protected work
---must be deferred.
local function onRegenDisabled()
  helpers.raisePhaseError(setCombatState(true))
end

---`PLAYER_REGEN_ENABLED` handler: combat ended and lockdown has lifted.
local function onRegenEnabled()
  helpers.raisePhaseError(setCombatState(false))
end

---Install the two combat watchers beside the core's, unless present.
---
---Called by the core whenever it ensures its own watchers (the first
---`ForAddon`, a bootstrap repair). When this call created a watcher, combat
---may have started or ended while nobody was watching, so the flag is
---reconciled and what that raises is returned for the caller to re-raise.
---A failure rolls back what this call created and raises.
---@return LifecycleKit.ErrorRecord|nil
local function ensureCombatWatchers()
  if state.shutdownSeen == true then
    return nil
  end
  local watchers = state.globalWatchers
  local created = {}
  local ok, message = pcall(function()
    local EventKit = Registry:Get("eventKit", 1)
    if watchers.combatStart == nil then
      watchers.combatStart = EventKit:Connect("PLAYER_REGEN_DISABLED", onRegenDisabled)
      created[#created + 1] = "combatStart"
    end
    if watchers.combatEnd == nil then
      watchers.combatEnd = EventKit:Connect("PLAYER_REGEN_ENABLED", onRegenEnabled)
      created[#created + 1] = "combatEnd"
    end
  end)
  if not ok then
    for index = #created, 1, -1 do
      local connection = watchers[created[index]]
      watchers[created[index]] = nil
      connection:Disconnect()
    end
    error(message, 0)
  end
  if #created == 0 then
    return nil
  end
  return reconcileCombatState()
end

-- Public API --------------------------------------------------------------------

---Report whether the player is in combat, by the one shared lockdown state.
---
---The state follows `PLAYER_REGEN_DISABLED` / `PLAYER_REGEN_ENABLED` once the
---watchers are installed (by the first `ForAddon`). Before that, and after
---logout, nothing watches the events, so the host is asked directly.
---@param _ LifecycleKit
---@return boolean
local function isInCombat(_)
  local watchers = state.globalWatchers
  if watchers.combatStart ~= nil and watchers.combatEnd ~= nil then
    return state.inCombat == true
  end
  return isHostInCombatLockdown()
end

-- A deferred call handed back when the callback already ran: it is never
-- pending, and sharing it keeps the out-of-combat path free of allocation.
local SPENT_DEFERRED_CALL = setmetatable({ _pending = false }, DEFERRED_CALL_METATABLE)

---Run `callback` now when out of combat, otherwise once combat ends.
---
---Out of combat the callback runs synchronously as `callback(instance, true)`
---and any error it raises leaves this call unchanged. In combat it is queued,
---first in first out, and runs on the next `PLAYER_REGEN_ENABLED`. Closing the
---queue (shutdown or halt) calls each pending callback with `(instance,
---false, reason)` instead.
---@param self LifecycleKit.Instance
---@param callback LifecycleKit.DeferredCallback
---@return LifecycleKit.DeferredCall|nil call a handle to cancel the call, or `nil` when refused
---@return string|nil reason `"full"`, `"halted"` or `"shutdown"` when refused
local function whenOutOfCombat(self, callback)
  if type(callback) ~= "function" then
    error("LifecycleKit.Instance:WhenOutOfCombat callback must be a function", 2)
  end
  if self._halted == true then
    return nil, "halted"
  end
  if self._shutdown == true then
    return nil, "shutdown"
  end

  if state.inCombat ~= true then
    callback(self, true)
    return SPENT_DEFERRED_CALL
  end

  local queue = self._combatQueue
  if queue == nil then
    queue = {}
    self._combatQueue = queue
    self._combatQueueLength = 0
    self._combatPending = 0
    self._draining = false
  end

  local limit = getLimit(self)
  local pending = self._combatPending
  local compactAt = limit
  if limit == state.unbounded then
    compactAt = math.max(UNBOUNDED_COMPACTION_FLOOR, 2 * pending)
  elseif pending >= limit then
    return nil, "full"
  end

  -- Cancelled slots are only reclaimed here, so outside a drain the array
  -- never grows past the limit (for an `UNBOUNDED` queue, past twice the
  -- pending count). A drain in progress owns the indices, so it is left
  -- alone; that only happens when a host enters combat inside a drain (see
  -- `drainCombatQueue`), and the drain compacts when it stops.
  if self._combatQueueLength >= compactAt and self._draining ~= true then
    compactCombatQueue(self)
  end

  local handle = setmetatable({
    _instance = self,
    _callback = callback,
    _pending = true,
  }, DEFERRED_CALL_METATABLE)

  local length = self._combatQueueLength + 1
  queue[length] = handle
  self._combatQueueLength = length
  self._combatPending = self._combatPending + 1
  return handle
end

---Subscribe to every combat start, delivered once the shared flag is `true`.
---@param self LifecycleKit.Instance
---@param callback LifecycleKit.CombatCallback
---@return LifecycleKit.Subscription subscription
local function onCombatStart(self, callback)
  if type(callback) ~= "function" then
    error("LifecycleKit.Instance:OnCombatStart callback must be a function", 2)
  end
  return helpers.subscribeRepeating(self, "combatStart", callback)
end

---Subscribe to every combat end, delivered after this addon's queue drained.
---@param self LifecycleKit.Instance
---@param callback LifecycleKit.CombatCallback
---@return LifecycleKit.Subscription subscription
local function onCombatEnd(self, callback)
  if type(callback) ~= "function" then
    error("LifecycleKit.Instance:OnCombatEnd callback must be a function", 2)
  end
  return helpers.subscribeRepeating(self, "combatEnd", callback)
end

---Set how many deferred calls this addon may have waiting at once.
---
---Lowering the limit below the number already waiting drops nothing; new calls
---are refused until the queue is below the new limit. `LifecycleKit.UNBOUNDED`
---lifts the limit: the queue holds only this addon's own callbacks.
---@param self LifecycleKit.Instance
---@param limit integer|table a positive integer or `LifecycleKit.UNBOUNDED`
local function setCombatQueueLimit(self, limit)
  helpers.refuseSecret(limit, "LifecycleKit.Instance:SetCombatQueueLimit limit", 3)
  if not isLimitValue(limit) then
    error(
      "LifecycleKit.Instance:SetCombatQueueLimit limit must be a positive integer"
        .. " or LifecycleKit.UNBOUNDED",
      2
    )
  end
  self._combatQueueLimit = limit
end

---Return how many deferred calls this addon may have waiting at once, or
---`LifecycleKit.UNBOUNDED`.
---@param self LifecycleKit.Instance
---@return integer|table limit
local function getCombatQueueLimit(self)
  return getLimit(self)
end

---Cancel a deferred call that is still waiting.
---
---Only flags the slot, so cancelling never allocates or shifts the queue.
---@param self LifecycleKit.DeferredCall
---@return boolean cancelled `true` only for the call that cancelled a pending call
local function cancelDeferredCall(self)
  if self._pending ~= true then
    return false
  end

  local instance = self._instance
  self._pending = false
  self._callback = nil
  self._instance = nil
  if instance ~= nil then
    instance._combatPending = instance._combatPending - 1
  end
  return true
end

---Report whether the deferred call is still waiting for combat to end.
---@param self LifecycleKit.DeferredCall
---@return boolean
local function isDeferredCallPending(self)
  return self._pending == true
end

-- Commit --------------------------------------------------------------------

rawset(LifecycleKit, "IsInCombat", isInCombat)
rawset(Instance, "WhenOutOfCombat", whenOutOfCombat)
rawset(Instance, "OnCombatStart", onCombatStart)
rawset(Instance, "OnCombatEnd", onCombatEnd)
rawset(Instance, "SetCombatQueueLimit", setCombatQueueLimit)
rawset(Instance, "GetCombatQueueLimit", getCombatQueueLimit)
rawset(DeferredCall, "Cancel", cancelDeferredCall)
rawset(DeferredCall, "IsPending", isDeferredCallPending)

dispatch.ensureCombatWatchers = ensureCombatWatchers
dispatch.reconcileCombat = reconcileCombatState
dispatch.closeCombatQueue = closeCombatQueue
dispatch.instanceCreated = function(instance)
  instance._combatQueueLimit = state.limits.defaultCombatQueueLimit
end

state.parts[PART_NAME] = { revision = PART_REVISION }

-- An older revision of this part installed watchers that call its own
-- handlers; they are replaced so the running handlers are this revision's.
if type(installed) == "table" then
  local watchers = state.globalWatchers
  for _, key in ipairs({ "combatStart", "combatEnd" }) do
    local connection = watchers[key]
    if connection ~= nil then
      watchers[key] = nil
      connection:Disconnect()
    end
  end
end

-- Addons that already have an instance (the part loaded after a `ForAddon`, or
-- over revision 18's state) get the watchers now, and the flag is brought in
-- line with the host.
if next(state.addons) ~= nil then
  helpers.raisePhaseError(ensureCombatWatchers())
end

return LifecycleKit
