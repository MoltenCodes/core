-- MoltenCodes SchedulerKit part Coalescing
--
-- `Debounce` and `Coalesce`: callable handles that decide *when* a burst of
-- calls is over, on the facade and on every scope, with their handle methods.
-- The part also holds the machinery the other two parts of the coalescing
-- family share: the one clock, scope member links, the family timer scope
-- and protected delivery. `SchedulerKit-Lanes` and `SchedulerKit-Watch` need
-- this part loaded first.
--
-- The family is one design, documented in docs/API.md under "Coalescing and
-- lanes":
--
--   * Debounce and Coalesce timers are TimerKit timers in the owning scope's
--     TimerKit scope, and every due time is computed on one clock,
--     `GetTimePreciseSec`, the clock TimerKit's deadlines use.
--   * Debounce and Coalesce fire into a lane when one is given (the Lanes
--     part), so the whole family shares one throttling vocabulary.
--   * Handles are "members" of a SchedulerKit scope: they sit on a second
--     intrusive list beside the scope's jobs, so `CancelAll` and `Close`
--     release them exactly like jobs. The core reaches them through the
--     dispatch entries `cancelFamilyMembers` and `closeFamilyMembers`.
--
-- Handles are validated by metatable identity. Their metatables and method
-- tables live in the core's shared state (`familyMetatables`,
-- `familyPrototypes`), and TimerKit callbacks resolve behaviour through
-- `_state.dispatch`, so a later revision of this part upgrades live handles.
-- Core functions are read through `_state.helpers` at every call, so an
-- upgraded core serves this part; functions the family's parts share are
-- published in `_state.familyHelpers`. See docs/INTERNALS.md, "Parts".
--
-- Contents
-- --------
--   Constants ............. identity, defaults, option names
--   Dependencies .......... SchedulerKit's core, its state, TimerKit
--   Shared machinery ...... clock, option checks, member links, timers,
--                           protected invocation
--   Debounce .............. the quiet-period handle
--   Coalesce .............. the key-collecting handle
--   Creation .............. building handles in a scope
--   Member release ........ closing, the core's scope hooks, wake routing
--   Handle methods ........ the methods a handle owner calls
--   Family methods ........ Debounce and Coalesce on scopes and the facade
--   Commit ................ prototypes, facade, dispatch, the part's revision

-- Constants ------------------------------------------------------------------

local PART_NAME = "Coalescing"
local PART_REVISION = 1
local REQUIRED_PART_INTERFACE = 1
local REQUIRED_REGISTRY_API = 2
local CORE_PACKAGE, CORE_API = "schedulerKit", 1
local REQUIRED_TIMER_API = 1
local PRIORITY_NORMAL = 2

-- A debounce handle keeps the arguments of its last call in a reused slot, so
-- recording a call never allocates. Up to this many values are staged without
-- a table; `SetLimits{ maxDebounceArguments }` allows more (docs/API.md).
local FAST_DEBOUNCE_ARGUMENTS = 8
local DEFAULT_COALESCE_MAX_KEYS = 256
-- A timer that wakes this close to its due time counts as due, so host timer
-- rounding cannot turn one wake into a chain of near-zero re-arms.
local DUE_TOLERANCE_SECONDS = 0.001

local DEBOUNCE_OPTION_KEYS = { leading = true, maxWaitSeconds = true, lane = true }
local COALESCE_OPTION_KEYS = { maxKeys = true, lane = true }

-- Dependencies ---------------------------------------------------------------

-- The shared MoltenCodes namespace is the one documented global handoff point between independently embedded copies.
-- selene: allow(global_usage)
local namespace = rawget(_G, "MoltenCodes")
local generations = type(namespace) == "table" and rawget(namespace, "Registries") or nil
local Registry = type(generations) == "table" and rawget(generations, REQUIRED_REGISTRY_API) or nil

---Find a package through `Registry:Find`, or `Get` on a Registry without it.
---@param packageName string
---@param api integer
---@return table|nil
local function findPackage(packageName, api)
  if type(Registry) ~= "table" then
    return nil
  end
  local find = rawget(Registry, "Find")
  if type(find) ~= "function" then
    find = rawget(Registry, "Get")
  end
  if type(find) ~= "function" then
    return nil
  end
  local found = find(Registry, packageName, api)
  return type(found) == "table" and found or nil
end

local SchedulerKit = findPackage(CORE_PACKAGE, CORE_API)
local state = SchedulerKit ~= nil and rawget(SchedulerKit, "_state") or nil
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
local installed = rawget(parts, PART_NAME)
if
  type(installed) == "table"
  and type(installed.revision) == "number"
  and installed.revision >= PART_REVISION
then
  -- An equal or newer revision of this part already serves every scope.
  return SchedulerKit
end

-- Read at call time, never copied: an upgraded core's helpers serve this part.
local helpers = rawget(state, "helpers")
-- The family's shared functions, written by this part and read by the others.
local family = rawget(state, "familyHelpers")
local TimerKit = findPackage("timerKit", REQUIRED_TIMER_API)
if type(TimerKit) ~= "table" then
  error(
    "MoltenCodes SchedulerKit part " .. PART_NAME .. " requires TimerKit API 1 to be loaded first",
    2
  )
end

---@cast SchedulerKit table
local Scope = rawget(SchedulerKit, "Scope")
local sharedLimits = rawget(state, "limits")
local FAMILY_METATABLES = rawget(state, "familyMetatables")
local FAMILY_PROTOTYPES = rawget(state, "familyPrototypes")
local DEBOUNCE_METATABLE = rawget(FAMILY_METATABLES, "debounce")
local COALESCE_METATABLE = rawget(FAMILY_METATABLES, "coalesce")
local LANE_METATABLE = rawget(FAMILY_METATABLES, "lane")
-- Values the core resolved when it loaded; constant for the session.
local nativeTraceback = rawget(helpers, "nativeTraceback") or nil
local loadedIsSecretValue = rawget(helpers, "loadedIsSecretValue") or nil

-- Shared machinery -----------------------------------------------------------

---Current monotonic wall-clock seconds, the one clock every due time of the
---family is computed on.
---@return number seconds
local function nowSeconds()
  return helpers.nowFromPreciseClock() / 1000
end

---Resolve one entry of the shared dispatch table, failing loudly when the
---shared state was damaged.
---@param key string
---@return function
local function dispatchEntry(key)
  local entry = state.dispatch[key]
  if type(entry) ~= "function" then
    error("MoltenCodes SchedulerKit runtime dispatch is corrupted", 0)
  end
  return entry
end

---Reject an option table that is not a table or names an unknown field. The
---alphabetically first unknown field is named, as for scheduling options.
---@param options any
---@param allowed table<string, boolean>
---@param methodName string public method name, used in the argument errors
---@param level integer stack level the failure is reported at
local function validateOptionTable(options, allowed, methodName, level)
  if type(options) == "nil" then
    return
  end
  if type(options) ~= "table" then
    error(methodName .. " options must be a table", level)
  end

  local unknown = nil
  for key in pairs(options) do
    -- A secret key would raise at the table read below with no useful
    -- line; it is refused first, at the caller's.
    helpers.refuseSecretValue(key, methodName .. " options field name", level + 1)
    if allowed[key] ~= true then
      local display = helpers.describeKey(key)
      if unknown == nil or display < unknown then
        unknown = display
      end
    end
  end
  if unknown ~= nil then
    error(methodName .. ' options contains unknown field "' .. unknown .. '"', level)
  end
end

---@param value any
---@param label string argument description, used in the argument error
---@param level integer stack level the failure is reported at
local function validateOptionalBoolean(value, label, level)
  helpers.refuseSecretValue(value, label, level + 1)
  if type(value) ~= "nil" and type(value) ~= "boolean" then
    error(label .. " must be a boolean", level)
  end
end

---@param member any receiver the public method was called on
---@param metatable table the metatable every handle of the expected kind carries
---@param methodName string public method name, used in the argument error
---@param noun string what the receiver should have been, for the message
local function validateMember(member, metatable, methodName, noun)
  if getmetatable(member) ~= metatable then
    error(methodName .. " must be called on a SchedulerKit " .. noun, 3)
  end
end

---Refuse a `lane` option that is not a SchedulerKit lane. A lane comes from
---the Lanes part, so without it any `lane` is refused with the file to embed.
---@param lane any
---@param label string argument description, used in the argument error
---@param level integer stack level the failure is reported at
local function validateOptionalLane(lane, label, level)
  if type(lane) == "nil" then
    return
  end
  if type(rawget(parts, "Lanes")) ~= "table" then
    error(
      label
        .. " is in SchedulerKit's Lanes part, which is not loaded: add"
        .. " schedulerKit\\parts\\SchedulerKit-Lanes.lua to embeds.xml after"
        .. " schedulerKit\\parts\\SchedulerKit-Coalescing.lua",
      level
    )
  end
  if getmetatable(lane) ~= LANE_METATABLE then
    error(label .. " must be a SchedulerKit lane", level)
  end
end

---Close nothing; the closer when no watcher can exist.
---@return boolean closed always `false`
local function closeNothing()
  return false
end

---The function that closes a watcher: the Watch part's, or the core's
---generic retirement when that part is not loaded (a watcher an older whole
---revision made, before the hand-over closed it).
---@return fun(member: table): boolean
local function watchCloser()
  local cancelWatcher = rawget(family, "cancelWatcher")
  if type(cancelWatcher) == "function" then
    return cancelWatcher
  end
  local retire = rawget(helpers, "retireMember")
  if type(retire) == "function" then
    return retire
  end
  -- Neither: no watcher can exist, so there is nothing to close.
  return closeNothing
end

---Empty a reused table in place, keeping its allocated slots for next time.
---Assigning `nil` to a field already visited is legal during `next` traversal.
---@param set table
local function wipe(set)
  for key in next, set do
    set[key] = nil
  end
end

-- Scope membership ----------------------------------------------------------

---Append `member` to `scope`'s intrusive member list. Scopes created by a
---revision before 7 carry no member links; `nil` reads as an empty list.
---@param scope table a scope (its private member links)
---@param member table
local function linkMember(scope, member)
  local tail = scope._familyTail or false
  member._familyPrev = tail
  member._familyNext = false
  if tail ~= false then
    tail._familyNext = member
  else
    scope._familyHead = member
  end
  scope._familyTail = member
  member._linked = true
end

---Remove `member` from its scope's member list, once. Never raises.
---@param member table
local function unlinkMember(member)
  if member._linked ~= true then
    return
  end
  local scope = member._scope
  local previous = member._familyPrev
  local following = member._familyNext
  if previous ~= false then
    previous._familyNext = following
  else
    scope._familyHead = following
  end
  if following ~= false then
    following._familyPrev = previous
  else
    scope._familyTail = previous
  end
  member._familyPrev = false
  member._familyNext = false
  member._linked = false
end

-- Timers ----------------------------------------------------------------------

---Return the package-internal TimerKit scope behind watch tickers and lane
---timers, creating it on first use. It is never closed: what it holds is
---released when its watch group or lane goes away.
---@return TimerKit.Scope
local function ensureFamilyTimerScope()
  local timerScope = rawget(state, "familyTimerScope")
  if timerScope ~= false then
    return timerScope
  end
  timerScope = TimerKit:CreateScope()
  if type(timerScope) ~= "table" then
    error("MoltenCodes SchedulerKit TimerKit returned an invalid scope", 0)
  end
  rawset(state, "familyTimerScope", timerScope)
  return timerScope
end

-- One shared wake callback serves every Debounce, Coalesce and lane timer, so
-- arming allocates no closure. The owner travels on the TimerKit handle as
-- public user data, exactly as a delayed job does.
---Shared TimerKit callback that wakes whichever member or lane armed it.
---@param timerHandle TimerKit.Timer
---@return boolean woken
local function familyWakeCallback(timerHandle)
  if type(timerHandle) ~= "table" then
    return false
  end
  local owner = timerHandle:GetUserData()
  if type(owner) ~= "table" then
    return false
  end
  timerHandle:SetUserData(nil)
  -- A cancelled or re-armed owner no longer points at this handle.
  if owner._timer ~= timerHandle then
    return false
  end
  owner._timer = false

  -- A TimerKit callback has no caller to raise to, so a failure inside the
  -- wake is reported rather than escaping into the host timer.
  local ok, value = pcall(dispatchEntry("familyWake"), owner)
  if not ok then
    helpers.reportError(value)
    return false
  end
  return true
end

---Arm `owner`'s one timer for `seconds` in `timerScope`.
---@param owner table a member or a lane
---@param timerScope TimerKit.Scope
---@param seconds number
local function armOwnerTimer(owner, timerScope, seconds)
  local timerHandle = timerScope:After(seconds, familyWakeCallback)
  if type(timerHandle) ~= "table" then
    error("MoltenCodes SchedulerKit TimerKit returned an invalid timer handle", 0)
  end
  -- TimerKit never fires synchronously from `After`, so both halves of the
  -- link are in place before the handle can wake.
  owner._timer = timerHandle
  timerHandle:SetUserData(owner)
end

---Arm a member's timer in its owning scope's TimerKit scope.
---@param member table
---@param seconds number
local function armMemberTimer(member, seconds)
  armOwnerTimer(member, helpers.ensureTimerScope(member._scope), seconds)
end

---Cancel `owner`'s timer if one is armed. May re-raise a host failure after
---the owner has already let go of the handle.
---@param owner table a member or a lane
local function cancelOwnerTimer(owner)
  local timerHandle = owner._timer --[[@as TimerKit.Timer|false|nil]]
  if timerHandle == false or timerHandle == nil then
    return
  end
  owner._timer = false
  timerHandle:SetUserData(nil)
  timerHandle:Cancel()
end

-- Protected invocation ----------------------------------------------------
--
-- A Debounce or Coalesce fire without a lane runs its callback synchronously
-- inside the TimerKit callback. It is protected with `xpcall`, which in Lua 5.1
-- takes no arguments, so the callback and up to eight arguments are staged in
-- reusable upvalues and forwarded by one trampoline: a fire allocates nothing.
-- The trampoline copies the staged values into locals before calling, so a
-- callback that fires another handle cannot corrupt its own arguments.

---@type function|false
local stagedCallback = false
local stagedCount = 0
local staged1, staged2, staged3, staged4, staged5, staged6, staged7, staged8

---Call `callback` with exactly `count` of the eight values.
---@param callback function
---@param count integer
---@return any ...
local function callWithCount(callback, count, a1, a2, a3, a4, a5, a6, a7, a8)
  if count == 0 then
    return callback()
  elseif count == 1 then
    return callback(a1)
  elseif count == 2 then
    return callback(a1, a2)
  elseif count == 3 then
    return callback(a1, a2, a3)
  elseif count == 4 then
    return callback(a1, a2, a3, a4)
  elseif count == 5 then
    return callback(a1, a2, a3, a4, a5)
  elseif count == 6 then
    return callback(a1, a2, a3, a4, a5, a6)
  elseif count == 7 then
    return callback(a1, a2, a3, a4, a5, a6, a7)
  end
  return callback(a1, a2, a3, a4, a5, a6, a7, a8)
end

---Reusable `xpcall` trampoline for the staged callback.
---@return any ...
local function invokeStaged()
  -- Only ever invoked right after `callProtected` staged a function.
  local callback = stagedCallback --[[@as function]]
  local count = stagedCount
  local a1, a2, a3, a4 = staged1, staged2, staged3, staged4
  local a5, a6, a7, a8 = staged5, staged6, staged7, staged8
  stagedCallback, stagedCount = false, 0
  staged1, staged2, staged3, staged4 = nil, nil, nil, nil
  staged5, staged6, staged7, staged8 = nil, nil, nil, nil
  return callWithCount(callback, count, a1, a2, a3, a4, a5, a6, a7, a8)
end

-- The client's `debugstack`, read once at load: the Retail client publishes
-- no `debug` global, so it is `captureFailure`'s only stack source there, as
-- it is `captureTraceback`'s. The installer runs once per load, and its
-- locals do not count against the main chunk's limit.
-- selene: allow(global_usage)
local nativeDebugStack = rawget(_G, "debugstack")
if type(nativeDebugStack) ~= "function" then
  nativeDebugStack = false
end

-- The stack level both sources start from. Inside an `xpcall` handler the
-- failing frames are still on the current stack; called through `pcall`,
-- level 1 is `pcall` itself and level 2 this handler, so level 3 is the
-- first frame of the failure (`[C]: in function 'error'` for a raise).
local FAILURE_STACK_LEVEL = 3

---`xpcall` handler: capture the stack while the failing frame still exists.
---
---`debug.traceback` is used when the host has it, otherwise the client's
---`debugstack`, whose bare stack is prefixed with the rendered message and a
---`stack traceback:` header so both give the same shape as `captureTraceback`.
---With neither, or when the source fails, the original message is returned.
---@param message any
---@return any report
local function captureFailure(message)
  if nativeTraceback ~= nil then
    local ok, traceback = pcall(nativeTraceback, tostring(message), FAILURE_STACK_LEVEL)
    if ok and type(traceback) == "string" then
      return traceback
    end
    return message
  end
  if nativeDebugStack == false then
    return message
  end
  local ok, stack = pcall(nativeDebugStack, FAILURE_STACK_LEVEL)
  if not ok or type(stack) ~= "string" then
    return message
  end
  return tostring(message) .. "\nstack traceback:\n" .. stack
end

---Run `callback` with `count` arguments, reporting a raise to the host error
---handler instead of propagating it.
---@param callback function
---@param count integer
local function callProtected(callback, count, a1, a2, a3, a4, a5, a6, a7, a8)
  stagedCallback, stagedCount = callback, count
  staged1, staged2, staged3, staged4 = a1, a2, a3, a4
  staged5, staged6, staged7, staged8 = a5, a6, a7, a8
  local ok, failure = xpcall(invokeStaged, captureFailure)
  if not ok then
    helpers.reportError(failure)
  end
end

-- Debounce ----------------------------------------------------------------
--
-- State machine, per handle:
--
--   idle ──call──> waiting (timer armed for `delay`; leading fires now)
--   waiting ──call──> waiting (arguments replaced, trailing fire owed)
--   waiting ──timer──> quiet long enough, or `maxWait` reached?
--                        yes: idle, and the owed trailing fire runs
--                        no:  re-arm for the remainder
--
-- A call inside the window only records its arguments and a clock reading:
-- the timer is not re-armed per call, it re-arms once when it wakes early.

---Build the job callback a member hands to its lane. One closure per member,
---made once; it resolves the delivery through shared dispatch.
---@param member table
---@return SchedulerKit.Callback
local function newDeliveryCallback(member)
  return function()
    return dispatchEntry("runDelivery")(member)
  end
end

---Clear the argument slot `args`: the eight staged positions, and every
---wider position a call past eight arguments wrote (`width`).
---@param args table
local function clearArguments(args)
  local width = rawget(args, "width")
  if type(width) ~= "number" or width < FAST_DEBOUNCE_ARGUMENTS then
    width = FAST_DEBOUNCE_ARGUMENTS
  end
  for index = 1, width do
    args[index] = nil
  end
  rawset(args, "width", 0)
end

---Build the reused argument slot, pre-sized so recording up to eight
---arguments never grows it. A wider call grows it once; `width` records the
---highest position written so clearing stays bounded.
---@return table
local function newArgumentSlot()
  local slot = { false, false, false, false, false, false, false, false }
  -- `width` is the one named field: the highest position a wide call
  -- wrote, read only by `clearArguments`.
  rawset(slot, "width", 0)
  return slot
end

---Record `count` (more than eight) arguments into `args`.
---@param args table
---@param count integer
---@param ... any
local function recordWideArguments(args, count, ...)
  for index = 1, count do
    args[index] = (select(index, ...))
  end
  if count > (rawget(args, "width") or 0) then
    rawset(args, "width", count)
  end
end

---Fire a debounce handle synchronously with its recorded arguments.
---@param member SchedulerKit.DebounceHandle
local function fireDebounceDirect(member)
  local args = rawget(member, "_args")
  local count = rawget(member, "_argCount")
  if count > FAST_DEBOUNCE_ARGUMENTS then
    -- A wide call cannot be staged in upvalues. Its values are copied
    -- out before the slot is cleared, which allocates one table and one
    -- closure per fire; calls of eight arguments or fewer never do.
    local values = { unpack(args, 1, count) }
    local callback = rawget(member, "_callback")
    clearArguments(args)
    rawset(member, "_argCount", 0)
    rawset(member, "_trailing", false)
    rawset(member, "_firing", true)
    local ok, failure = xpcall(function()
      return callback(unpack(values, 1, count))
    end, captureFailure)
    rawset(member, "_firing", false)
    if not ok then
      helpers.reportError(failure)
    end
    return
  end
  local a1, a2, a3, a4 = args[1], args[2], args[3], args[4]
  local a5, a6, a7, a8 = args[5], args[6], args[7], args[8]
  clearArguments(args)
  rawset(member, "_argCount", 0)
  rawset(member, "_trailing", false)

  rawset(member, "_firing", true)
  callProtected(rawget(member, "_callback"), count, a1, a2, a3, a4, a5, a6, a7, a8)
  rawset(member, "_firing", false)
end

---Arm a member's timer, or report the failure and leave the member idle
---with its owed fire intact, so the next call or `Flush` recovers it.
---@param member table
---@param seconds number
---@return boolean armed
local function armMemberTimerOrReport(member, seconds)
  local ok, value = pcall(armMemberTimer, member, seconds)
  if not ok then
    rawset(member, "_waiting", false)
    helpers.reportError(value)
    return false
  end
  return true
end

---Hand the delivery slot to the lane as one job.
---@param member SchedulerKit.DebounceHandle
---@return "delivered"|"deferred"|"dropped" status
local function submitDebounceDelivery(member)
  local lane = rawget(member, "_lane")
  local job, reason = family.submitToLane(
    lane,
    rawget(member, "_scope"),
    rawget(member, "_laneCallback"),
    PRIORITY_NORMAL,
    nil,
    member
  )
  if job ~= nil then
    rawset(member, "_deliveryJob", job)
    return "delivered"
  end

  if reason == "full" and rawget(member, "_closed") ~= true then
    -- A full lane defers a debounce fire; it never drops it.
    if rawget(member, "_trailing") == true then
      -- A newer burst is already owed. Its arguments supersede the
      -- ones the lane refused, which are discarded.
      clearArguments(rawget(member, "_deliveryArgs"))
      rawset(member, "_deliveryCount", 0)
    else
      -- Take the arguments back as the owed call.
      local args = rawget(member, "_args")
      rawset(member, "_args", rawget(member, "_deliveryArgs"))
      rawset(member, "_deliveryArgs", args)
      rawset(member, "_argCount", rawget(member, "_deliveryCount"))
      rawset(member, "_deliveryCount", 0)
      rawset(member, "_trailing", true)
      rawset(member, "_lastCall", nowSeconds())
      rawset(member, "_burstStart", rawget(member, "_lastCall"))
    end
    -- Try again one delay later.
    rawset(member, "_waiting", true)
    if rawget(member, "_timer") == false then
      armMemberTimerOrReport(member, rawget(member, "_delay"))
    end
    return "deferred"
  end

  clearArguments(rawget(member, "_deliveryArgs"))
  rawset(member, "_deliveryCount", 0)
  helpers.reportError(
    'SchedulerKit debounce fire dropped: lane "' .. rawget(lane, "_name") .. '" is closed'
  )
  return "dropped"
end

---Deliver the owed call: synchronously, or through the lane.
---@param member SchedulerKit.DebounceHandle
---@return "delivered"|"deferred"|"dropped" status
local function deliverDebounce(member)
  if rawget(member, "_lane") == false then
    fireDebounceDirect(member)
    return "delivered"
  end

  -- Swap the owed arguments into the delivery slot. Arguments a delivery
  -- still waiting in the lane carried are superseded: the last call wins.
  local args = rawget(member, "_args")
  local delivery = rawget(member, "_deliveryArgs")
  clearArguments(delivery)
  rawset(member, "_args", delivery)
  rawset(member, "_deliveryArgs", args)
  rawset(member, "_deliveryCount", rawget(member, "_argCount"))
  rawset(member, "_argCount", 0)
  rawset(member, "_trailing", false)

  if rawget(member, "_deliveryJob") ~= false then
    -- The job reads the delivery slot when it starts; if it has already
    -- started, `_deliveryDirty` makes it deliver once more afterwards.
    rawset(member, "_deliveryDirty", true)
    return "delivered"
  end
  local status = submitDebounceDelivery(member)
  return status
end

---The debounce timer woke: fire if the burst is over, else re-arm.
---@param member SchedulerKit.DebounceHandle
local function debounceWake(member)
  if rawget(member, "_closed") == true or rawget(member, "_waiting") ~= true then
    return
  end

  local due = rawget(member, "_lastCall") + rawget(member, "_delay")
  local maxWait = rawget(member, "_maxWait")
  if maxWait ~= false and rawget(member, "_trailing") == true then
    local cap = rawget(member, "_burstStart") + maxWait
    if cap < due then
      due = cap
    end
  end

  local remaining = due - nowSeconds()
  -- A clock that stepped backwards cannot stretch the wait past one delay.
  if remaining > rawget(member, "_delay") then
    remaining = rawget(member, "_delay")
  end
  if remaining > DUE_TOLERANCE_SECONDS then
    armMemberTimerOrReport(member, remaining)
    return
  end

  rawset(member, "_waiting", false)
  if rawget(member, "_trailing") == true then
    deliverDebounce(member)
  end
end

---Record one call on a debounce handle. This is the handle's `__call`.
---@param member SchedulerKit.DebounceHandle
---@param ... any at most `maxDebounceArguments` arguments (8 by default)
---@return boolean accepted `false` once the handle is closed.
local function debounceCall(member, ...)
  if rawget(member, "_closed") == true then
    return false
  end
  local count = select("#", ...)
  local maxArguments = rawget(sharedLimits, "maxDebounceArguments")
  if count > maxArguments then
    error(
      "SchedulerKit debounce handle accepts at most "
        .. maxArguments
        .. " arguments; received "
        .. count,
      2
    )
  end

  local args = rawget(member, "_args")
  if count > FAST_DEBOUNCE_ARGUMENTS then
    recordWideArguments(args, count, ...)
  else
    if (rawget(args, "width") or 0) > FAST_DEBOUNCE_ARGUMENTS then
      -- A previous wide call left values past eight.
      clearArguments(args)
    end
    args[1], args[2], args[3], args[4], args[5], args[6], args[7], args[8] = ...
  end
  rawset(member, "_argCount", count)
  local reading = nowSeconds()
  rawset(member, "_lastCall", reading)

  if rawget(member, "_waiting") == true and rawget(member, "_timer") ~= false then
    rawset(member, "_trailing", true)
    return true
  end

  -- First call of a burst: open the window before any fire, so a callback
  -- that calls the handle again finds it waiting.
  rawset(member, "_waiting", true)
  rawset(member, "_burstStart", reading)
  local leading = rawget(member, "_leading") == true and rawget(member, "_firing") ~= true
  rawset(member, "_trailing", not leading)

  local ok, value = pcall(armMemberTimer, member, rawget(member, "_delay"))
  if not ok then
    rawset(member, "_waiting", false)
    rawset(member, "_trailing", false)
    clearArguments(args)
    rawset(member, "_argCount", 0)
    error(value, 0)
  end

  if leading then
    deliverDebounce(member)
  end
  return true
end

---Run a lane delivery of a debounce handle. Raises propagate to the job, so
---the lane's retry policy applies to the callback.
---@param member SchedulerKit.DebounceHandle
---@return any ...
local function runDebounceDelivery(member)
  rawset(member, "_deliveryDirty", false)
  local args = rawget(member, "_deliveryArgs")
  local count = rawget(member, "_deliveryCount")
  if count > FAST_DEBOUNCE_ARGUMENTS then
    return rawget(member, "_callback")(unpack(args, 1, count))
  end
  return callWithCount(
    rawget(member, "_callback"),
    count,
    args[1],
    args[2],
    args[3],
    args[4],
    args[5],
    args[6],
    args[7],
    args[8]
  )
end

---Drop the owed call and any open window; the handle stays usable.
---@param member SchedulerKit.DebounceHandle
---@return boolean dropped whether a fire was owed
local function cancelDebounce(member)
  local owed = rawget(member, "_trailing") == true
  rawset(member, "_waiting", false)
  rawset(member, "_trailing", false)
  clearArguments(rawget(member, "_args"))
  rawset(member, "_argCount", 0)
  cancelOwnerTimer(member)
  return owed
end

-- Coalesce ----------------------------------------------------------------
--
-- The first key of a burst arms one timer for the interval; every key
-- recorded before it expires lands in the same set, and the callback runs
-- once at the end of the interval with everything collected. The set is one
-- of two reused tables: the pair is swapped at delivery, so keys recorded by
-- the callback itself go into the other table and nothing is allocated.

---Deliver the collected set synchronously, then wipe it for reuse.
---@param member table a coalesce handle (its private fields)
local function fireCoalesceDirect(member)
  local set = member._set
  member._set = member._spare
  member._spare = set
  member._keyCount = 0
  member._delivered = member._delivered + 1

  member._firing = true
  callProtected(member._callback, 1, set)
  member._firing = false
  wipe(set)
end

---Deliver the collected set: synchronously, or through the lane.
---@param member table a coalesce handle (its private fields)
---@return "delivered"|"deferred"|"dropped" status
local function deliverCoalesce(member)
  local lane = member._lane
  if lane == false then
    fireCoalesceDirect(member)
    return "delivered"
  end

  local pendingJob = member._deliveryJob
  if pendingJob ~= nil and pendingJob ~= false then
    -- The previous set is still in the lane. Keep collecting into the
    -- current one and try again one interval later.
    member._deferred = (member._deferred or 0) + 1
    if member._timer == false then
      armMemberTimer(member, member._interval)
    end
    return "deferred"
  end

  local set = member._set --[[@as table]]
  local count = member._keyCount
  member._deliverySet = set
  member._set = member._spare
  member._spare = false
  member._keyCount = 0

  local job, reason =
    family.submitToLane(lane, member._scope, member._laneCallback, PRIORITY_NORMAL, nil, member)
  if job ~= nil then
    member._deliveryJob = job
    member._delivered = member._delivered + 1
    return "delivered"
  end

  -- Refused: the set goes back to collecting.
  member._spare = member._set
  member._set = set
  member._deliverySet = false
  member._keyCount = count
  if reason == "full" then
    member._deferred = (member._deferred or 0) + 1
    if member._timer == false then
      armMemberTimer(member, member._interval)
    end
    return "deferred"
  end

  wipe(set)
  member._keyCount = 0
  member._dropped = (member._dropped or 0) + 1
  helpers.reportError(
    'SchedulerKit coalesce delivery dropped: lane "' .. rawget(lane, "_name") .. '" is closed'
  )
  return "dropped"
end

---The coalesce timer woke: deliver whatever the interval collected.
---@param member table a coalesce handle (its private fields)
local function coalesceWake(member)
  if member._closed == true or member._keyCount == 0 then
    return
  end
  deliverCoalesce(member)
end

---Record one key on a coalesce handle. This is the handle's `__call`.
---@param member table a coalesce handle (its private fields)
---@param key any any value but `nil` or NaN
---@param value any stored for `key`; `true` when omitted
---@return boolean accepted `false` when the key was refused or the handle is closed.
local function coalesceCall(member, key, value)
  -- One pass over the key: the probe, `nil` and NaN in one condition, so a
  -- valid key costs no helper call and builds no message. The probe runs
  -- first, because `key ~= key` raises on a secret. Only a refused key
  -- reaches the statements that raise, each at the same level as before.
  -- With no probe resolved at load (a test host), `isSecretValue` reads
  -- the global as it stands, as every other check does.
  local probe = loadedIsSecretValue
  if
    (probe ~= nil and probe(key) == true)
    or (probe == nil and helpers.isSecretValue(key))
    or type(key) == "nil"
    or key ~= key
  then
    helpers.refuseSecretValue(key, "SchedulerKit coalesce handle key", 3)
    error("SchedulerKit coalesce handle key must not be nil or NaN", 2)
  end
  if member._closed == true then
    return false
  end
  -- The value is stored, never compared, so a secret one is accepted.
  if type(value) == "nil" then
    value = true
  end

  local set = member._set
  if set[key] == nil then
    local count = member._keyCount
    if count >= member._maxKeys then
      member._refused = (member._refused or 0) + 1
      return false
    end
    member._keyCount = count + 1
  end
  set[key] = value

  if member._timer == false then
    armMemberTimer(member, member._interval)
  end
  return true
end

---Run a lane delivery of a coalesce handle. Raises propagate to the job.
---@param member table a coalesce handle (its private fields)
---@return any ...
local function runCoalesceDelivery(member)
  return rawget(member, "_callback")(rawget(member, "_deliverySet"))
end

---Drop the collected keys; the handle stays usable.
---@param member table a coalesce handle (its private fields)
---@return boolean dropped whether any key was collected
local function cancelCoalesce(member)
  local had = member._keyCount > 0
  wipe(member._set)
  member._keyCount = 0
  cancelOwnerTimer(member)
  return had
end

---A member's lane delivery reached a terminal state.
---@param member table
---@param job SchedulerKit.Job
---@param terminalState "completed"|"cancelled"|"failed"
local function memberDeliveryFinished(member, job, terminalState)
  if rawget(member, "_deliveryJob") ~= job then
    return
  end
  rawset(member, "_deliveryJob", false)

  if rawget(member, "_kind") == "debounce" then
    if
      rawget(member, "_deliveryDirty") == true
      and terminalState ~= "cancelled"
      and rawget(member, "_closed") ~= true
    then
      -- A newer call arrived after the job had read its arguments.
      rawset(member, "_deliveryDirty", false)
      submitDebounceDelivery(member)
      return
    end
    rawset(member, "_deliveryDirty", false)
    clearArguments(rawget(member, "_deliveryArgs"))
    rawset(member, "_deliveryCount", 0)
    return
  end

  local set = rawget(member, "_deliverySet")
  rawset(member, "_deliverySet", false)
  if type(set) == "table" then
    wipe(set)
    rawset(member, "_spare", set)
  end
end

-- Creation ----------------------------------------------------------------
--
-- Public methods call these without a tail call, so each one's frame stays on
-- the stack: `level` 4 inside a validator called from here is the line that
-- called the public method.

---@param scope SchedulerKit.Scope
---@param methodName string public method name, used in the argument errors
local function ensureScopeOpen(scope, methodName)
  if rawget(scope, "_closed") == true then
    error(methodName .. " cannot schedule work in a closed scope", 4)
  end
end

---Build a debounce handle in `scope`.
---@param scope SchedulerKit.Scope
---@param callback any
---@param delay any
---@param options any
---@param methodName string public method name, used in the argument errors
---@return SchedulerKit.DebounceHandle
local function createDebounce(scope, callback, delay, options, methodName)
  ensureScopeOpen(scope, methodName)
  if type(callback) ~= "function" then
    error(methodName .. " callback must be a function", 3)
  end
  helpers.validateFinitePositive(delay, methodName .. " delaySeconds", true, 4)
  validateOptionTable(options, DEBOUNCE_OPTION_KEYS, methodName, 4)

  local leading, maxWait, lane = false, false, false
  if type(options) ~= "nil" then
    validateOptionalBoolean(rawget(options, "leading"), methodName .. " leading", 4)
    leading = rawget(options, "leading") == true
    if type(rawget(options, "maxWaitSeconds")) ~= "nil" then
      maxWait = rawget(options, "maxWaitSeconds")
      helpers.validateFinitePositive(maxWait, methodName .. " maxWaitSeconds", false, 4)
      if maxWait < delay then
        error(methodName .. " maxWaitSeconds must be at least delaySeconds", 3)
      end
    end
    validateOptionalLane(rawget(options, "lane"), methodName .. " lane", 4)
    lane = rawget(options, "lane") or false
  end

  local member = setmetatable({
    _kind = "debounce",
    _scope = scope,
    _linked = false,
    _familyPrev = false,
    _familyNext = false,
    _closed = false,
    _callback = callback,
    _delay = delay,
    _maxWait = maxWait,
    _leading = leading,
    _lane = lane,
    _args = newArgumentSlot(),
    _argCount = 0,
    _waiting = false,
    _trailing = false,
    _firing = false,
    _timer = false,
    _lastCall = 0,
    _burstStart = 0,
    _deliveryArgs = false,
    _deliveryCount = 0,
    _deliveryJob = false,
    _deliveryDirty = false,
    _laneCallback = false,
  }, DEBOUNCE_METATABLE)
  clearArguments(rawget(member, "_args"))
  if lane ~= false then
    local deliveryArgs = newArgumentSlot()
    clearArguments(deliveryArgs)
    rawset(member, "_deliveryArgs", deliveryArgs)
    rawset(member, "_laneCallback", newDeliveryCallback(member))
  end
  linkMember(scope, member)
  return member
end

---Build a coalesce handle in `scope`.
---@param scope SchedulerKit.Scope
---@param callback any
---@param interval any
---@param options any
---@param methodName string public method name, used in the argument errors
---@return SchedulerKit.CoalesceHandle
local function createCoalesce(scope, callback, interval, options, methodName)
  ensureScopeOpen(scope, methodName)
  if type(callback) ~= "function" then
    error(methodName .. " callback must be a function", 3)
  end
  -- The label is built only for a value the validator will refuse.
  if
    type(interval) ~= "number"
    or helpers.isSecretValue(interval)
    or interval ~= interval
    or interval == math.huge
    or interval < 0
  then
    helpers.validateFinitePositive(interval, methodName .. " intervalSeconds", true, 4)
  end
  validateOptionTable(options, COALESCE_OPTION_KEYS, methodName, 4)

  local maxKeys, lane = DEFAULT_COALESCE_MAX_KEYS, false
  if type(options) ~= "nil" then
    if type(rawget(options, "maxKeys")) ~= "nil" then
      maxKeys = rawget(options, "maxKeys")
      helpers.validatePositiveInteger(maxKeys, methodName .. " maxKeys", 4)
    end
    validateOptionalLane(rawget(options, "lane"), methodName .. " lane", 4)
    lane = rawget(options, "lane") or false
  end

  -- Sixteen fields, so the handle's hash part is 16 slots rather than 32.
  -- The lane-only fields (`_laneCallback`, `_deliveryJob`, `_deliverySet`),
  -- the rare counters (`_refused`, `_deferred`, `_dropped`) and the reused
  -- `GetStats` view are written when first needed; an absent one reads as
  -- `false` or `0` wherever it is read.
  local member = setmetatable({
    _kind = "coalesce",
    _scope = scope,
    _linked = false,
    _familyPrev = false,
    _familyNext = false,
    _closed = false,
    _callback = callback,
    _interval = interval,
    _maxKeys = maxKeys,
    _lane = lane,
    _set = {},
    _spare = {},
    _keyCount = 0,
    _firing = false,
    _timer = false,
    _delivered = 0,
  }, COALESCE_METATABLE)
  if lane ~= false then
    rawset(member, "_laneCallback", newDeliveryCallback(member))
  end
  linkMember(scope, member)
  return member
end
-- Member release ----------------------------------------------------------

---Close one Debounce or Coalesce member: drop what it owes, cancel a lane
---delivery still waiting for admission, and leave its scope. A delivery the
---lane already admitted finishes, as the lane's own `Close` lets admitted
---work drain. Terminal and idempotent.
---@param member table
---@return boolean closed `false` when it was already closed.
local function closeTimedMember(member)
  if member._closed == true then
    return false
  end
  member._closed = true
  unlinkMember(member)

  local firstError = nil
  local cancel = member._kind == "debounce" and cancelDebounce or cancelCoalesce
  local ok, value = pcall(cancel, member)
  if not ok then
    firstError = { value = value }
  end

  local deliveryJob = member._deliveryJob
  if
    deliveryJob ~= nil
    and deliveryJob ~= false
    and rawget(deliveryJob, "_laneAdmitted") ~= true
  then
    local cancelOk, cancelError = pcall(helpers.cancelJob, deliveryJob)
    if not cancelOk and firstError == nil then
      firstError = { value = cancelError }
    end
  end

  if firstError ~= nil then
    error(firstError.value, 0)
  end
  return true
end

---Cancel what every member of `scope` owes, keeping Debounce and Coalesce
---handles usable. A watcher has nothing owed but its polling, so it is
---cancelled. Best effort; the first failure is returned, not raised.
---@param scope SchedulerKit.Scope
---@return SchedulerKit.ErrorRecord|nil firstError
local function cancelFamilyMembers(scope)
  local firstError = nil
  local member = rawget(scope, "_familyHead") or false
  while member ~= false do
    local following = rawget(member, "_familyNext")
    local kind = rawget(member, "_kind")
    local ok, value
    if kind == "debounce" then
      ok, value = pcall(cancelDebounce, member)
    elseif kind == "coalesce" then
      ok, value = pcall(cancelCoalesce, member)
    else
      ok, value = pcall(watchCloser(), member)
    end
    if not ok and firstError == nil then
      firstError = { value = value }
    end
    member = following
  end
  return firstError
end

---Close every member of `scope`. Best effort; the first failure is returned.
---@param scope SchedulerKit.Scope
---@return SchedulerKit.ErrorRecord|nil firstError
local function closeFamilyMembers(scope)
  local firstError = nil
  local member = rawget(scope, "_familyHead") or false
  while member ~= false do
    local close = rawget(member, "_kind") == "watch" and watchCloser() or closeTimedMember
    local ok, value = pcall(close, member)
    if not ok and firstError == nil then
      firstError = { value = value }
    end
    -- Every close unlinks before anything that can raise; a member that
    -- somehow stayed linked is unlinked here so the loop terminates.
    if rawget(member, "_linked") == true then
      unlinkMember(member)
    end
    member = rawget(scope, "_familyHead") or false
  end
  return firstError
end

---Route a TimerKit wake to the member or lane that armed the timer.
---@param owner table
local function familyWake(owner)
  local kind = owner._kind
  if kind == "debounce" then
    debounceWake(owner)
  elseif kind == "coalesce" then
    coalesceWake(owner)
  elseif kind == "lane" then
    family.laneWake(owner)
  end
end

---Route a lane delivery job to its member.
---@param member table
---@return any ...
local function runDelivery(member)
  if rawget(member, "_kind") == "debounce" then
    return runDebounceDelivery(member)
  end
  return runCoalesceDelivery(member)
end

-- Member public methods ----------------------------------------------------

---Drop the owed fire, if any; the handle stays usable.
---@param self SchedulerKit.DebounceHandle
---@return boolean dropped whether a fire was owed
local function debounceHandleCancel(self)
  validateMember(self, DEBOUNCE_METATABLE, "SchedulerKit.DebounceHandle:Cancel", "debounce handle")
  return cancelDebounce(self)
end

---Fire now if a fire is owed, ending the burst.
---@param self SchedulerKit.DebounceHandle
---@return boolean fired `false` when nothing was owed, during the handle's own fire, or when the lane deferred or dropped it.
---@return "deferred"|"dropped"|nil reason why a lane did not take the fire
local function debounceHandleFlush(self)
  validateMember(self, DEBOUNCE_METATABLE, "SchedulerKit.DebounceHandle:Flush", "debounce handle")
  if rawget(self, "_firing") == true then
    return false, nil
  end
  if rawget(self, "_waiting") == true then
    cancelOwnerTimer(self)
    rawset(self, "_waiting", false)
  end
  -- An owed fire is flushed even when no window is open, which is how a
  -- handle whose timer could not be armed is recovered by hand.
  if rawget(self, "_trailing") ~= true then
    return false, nil
  end
  local status = deliverDebounce(self)
  if status ~= "delivered" then
    -- Narrowed by the test above.
    return false, status --[[@as "deferred"|"dropped"]]
  end
  return true, nil
end

---Whether a fire is owed and has not been handed off yet.
---@param self SchedulerKit.DebounceHandle
---@return boolean pending
local function debounceHandleIsPending(self)
  validateMember(
    self,
    DEBOUNCE_METATABLE,
    "SchedulerKit.DebounceHandle:IsPending",
    "debounce handle"
  )
  return rawget(self, "_trailing") == true
end

---Close the handle: drop what it owes and release it from its scope.
---@param self SchedulerKit.DebounceHandle
---@return boolean closed `false` when it was already closed.
local function debounceHandleClose(self)
  validateMember(self, DEBOUNCE_METATABLE, "SchedulerKit.DebounceHandle:Close", "debounce handle")
  return closeTimedMember(self)
end

---Whether the handle is closed.
---@param self SchedulerKit.DebounceHandle
---@return boolean closed
local function debounceHandleIsClosed(self)
  validateMember(
    self,
    DEBOUNCE_METATABLE,
    "SchedulerKit.DebounceHandle:IsClosed",
    "debounce handle"
  )
  return rawget(self, "_closed") == true
end

---Drop the collected keys; the handle stays usable.
---@param self SchedulerKit.CoalesceHandle
---@return boolean dropped whether any key was collected
local function coalesceHandleCancel(self)
  validateMember(self, COALESCE_METATABLE, "SchedulerKit.CoalesceHandle:Cancel", "coalesce handle")
  return cancelCoalesce(self)
end

---Deliver the collected keys now instead of at the end of the interval.
---@param self SchedulerKit.CoalesceHandle
---@return boolean delivered `false` when nothing was collected, during the handle's own delivery, or when the lane deferred or dropped it.
---@return "deferred"|"dropped"|nil reason why a lane did not take the delivery
local function coalesceHandleFlush(self)
  validateMember(self, COALESCE_METATABLE, "SchedulerKit.CoalesceHandle:Flush", "coalesce handle")
  if rawget(self, "_keyCount") == 0 or rawget(self, "_firing") == true then
    return false, nil
  end
  local pendingJob = rawget(self, "_deliveryJob")
  if pendingJob ~= nil and pendingJob ~= false then
    -- The previous set is still in the lane; the interval timer keeps
    -- running and delivers once that set is done.
    return false, "deferred"
  end
  cancelOwnerTimer(self)
  local status = deliverCoalesce(self)
  if status ~= "delivered" then
    -- Narrowed by the test above.
    return false, status --[[@as "deferred"|"dropped"]]
  end
  return true, nil
end

---Whether keys are collected and waiting for delivery.
---@param self SchedulerKit.CoalesceHandle
---@return boolean pending
local function coalesceHandleIsPending(self)
  validateMember(
    self,
    COALESCE_METATABLE,
    "SchedulerKit.CoalesceHandle:IsPending",
    "coalesce handle"
  )
  return rawget(self, "_keyCount") > 0
end

---Return this handle's counters in a table reused by every call.
---@param self SchedulerKit.CoalesceHandle
---@return SchedulerKit.CoalesceStats stats
local function coalesceHandleGetStats(self)
  validateMember(
    self,
    COALESCE_METATABLE,
    "SchedulerKit.CoalesceHandle:GetStats",
    "coalesce handle"
  )
  local view = rawget(self, "_statsView")
  if type(view) ~= "table" then
    view = {}
    rawset(self, "_statsView", view)
  end
  view.keys = rawget(self, "_keyCount")
  view.refused = rawget(self, "_refused") or 0
  view.delivered = rawget(self, "_delivered")
  view.deferred = rawget(self, "_deferred") or 0
  view.dropped = rawget(self, "_dropped") or 0
  return view
end

---Close the handle: drop the collected keys and release it from its scope.
---@param self SchedulerKit.CoalesceHandle
---@return boolean closed `false` when it was already closed.
local function coalesceHandleClose(self)
  validateMember(self, COALESCE_METATABLE, "SchedulerKit.CoalesceHandle:Close", "coalesce handle")
  return closeTimedMember(self)
end

---Whether the handle is closed.
---@param self SchedulerKit.CoalesceHandle
---@return boolean closed
local function coalesceHandleIsClosed(self)
  validateMember(
    self,
    COALESCE_METATABLE,
    "SchedulerKit.CoalesceHandle:IsClosed",
    "coalesce handle"
  )
  return rawget(self, "_closed") == true
end

-- Family public methods ------------------------------------------------------

---Debounce `callback` in this scope.
---@param self SchedulerKit.Scope
---@param callback function
---@param delaySeconds number Finite seconds greater than or equal to zero.
---@param options SchedulerKit.DebounceOptions?
---@return SchedulerKit.DebounceHandle handle
local function scopeDebounce(self, callback, delaySeconds, options)
  helpers.validateScope(self, "SchedulerKit.Scope:Debounce")
  local handle =
    createDebounce(self, callback, delaySeconds, options, "SchedulerKit.Scope:Debounce")
  return handle
end

---Coalesce keys for `callback` in this scope.
---@param self SchedulerKit.Scope
---@param callback SchedulerKit.CoalesceCallback
---@param intervalSeconds number Finite seconds greater than or equal to zero.
---@param options SchedulerKit.CoalesceOptions?
---@return SchedulerKit.CoalesceHandle handle
local function scopeCoalesce(self, callback, intervalSeconds, options)
  helpers.validateScope(self, "SchedulerKit.Scope:Coalesce")
  local handle =
    createCoalesce(self, callback, intervalSeconds, options, "SchedulerKit.Scope:Coalesce")
  return handle
end

---Debounce `callback` in SchedulerKit's package-level scope.
---@param _ SchedulerKit
---@param callback function
---@param delaySeconds number Finite seconds greater than or equal to zero.
---@param options SchedulerKit.DebounceOptions?
---@return SchedulerKit.DebounceHandle handle
local function packageDebounce(_, callback, delaySeconds, options)
  local handle = createDebounce(
    helpers.getDefaultScope(),
    callback,
    delaySeconds,
    options,
    "SchedulerKit:Debounce"
  )
  return handle
end

---Coalesce keys for `callback` in SchedulerKit's package-level scope.
---@param _ SchedulerKit
---@param callback SchedulerKit.CoalesceCallback
---@param intervalSeconds number Finite seconds greater than or equal to zero.
---@param options SchedulerKit.CoalesceOptions?
---@return SchedulerKit.CoalesceHandle handle
local function packageCoalesce(_, callback, intervalSeconds, options)
  local handle = createCoalesce(
    helpers.getDefaultScope(),
    callback,
    intervalSeconds,
    options,
    "SchedulerKit:Coalesce"
  )
  return handle
end

-- Commit ---------------------------------------------------------------------

rawset(Scope, "Debounce", scopeDebounce)
rawset(Scope, "Coalesce", scopeCoalesce)

local DEBOUNCE_PROTOTYPE = rawget(FAMILY_PROTOTYPES, "debounce")
rawset(DEBOUNCE_PROTOTYPE, "Cancel", debounceHandleCancel)
rawset(DEBOUNCE_PROTOTYPE, "Flush", debounceHandleFlush)
rawset(DEBOUNCE_PROTOTYPE, "IsPending", debounceHandleIsPending)
rawset(DEBOUNCE_PROTOTYPE, "Close", debounceHandleClose)
rawset(DEBOUNCE_PROTOTYPE, "IsClosed", debounceHandleIsClosed)
rawset(DEBOUNCE_METATABLE, "__call", debounceCall)

local COALESCE_PROTOTYPE = rawget(FAMILY_PROTOTYPES, "coalesce")
rawset(COALESCE_PROTOTYPE, "Cancel", coalesceHandleCancel)
rawset(COALESCE_PROTOTYPE, "Flush", coalesceHandleFlush)
rawset(COALESCE_PROTOTYPE, "IsPending", coalesceHandleIsPending)
rawset(COALESCE_PROTOTYPE, "GetStats", coalesceHandleGetStats)
rawset(COALESCE_PROTOTYPE, "Close", coalesceHandleClose)
rawset(COALESCE_PROTOTYPE, "IsClosed", coalesceHandleIsClosed)
rawset(COALESCE_METATABLE, "__call", coalesceCall)

rawset(SchedulerKit, "Debounce", packageDebounce)
rawset(SchedulerKit, "Coalesce", packageCoalesce)

-- What the Lanes and Watch parts call. They read these at every call, so a
-- newer revision of this part serves parts loaded before it.
rawset(family, "nowSeconds", nowSeconds)
rawset(family, "dispatchEntry", dispatchEntry)
rawset(family, "validateOptionTable", validateOptionTable)
rawset(family, "validateOptionalBoolean", validateOptionalBoolean)
rawset(family, "validateMember", validateMember)
rawset(family, "linkMember", linkMember)
rawset(family, "unlinkMember", unlinkMember)
rawset(family, "ensureFamilyTimerScope", ensureFamilyTimerScope)
rawset(family, "armOwnerTimer", armOwnerTimer)
rawset(family, "cancelOwnerTimer", cancelOwnerTimer)
rawset(family, "callProtected", callProtected)
rawset(family, "captureFailure", captureFailure)
rawset(family, "ensureScopeOpen", ensureScopeOpen)
rawset(family, "memberDeliveryFinished", memberDeliveryFinished)

local dispatch = rawget(state, "dispatch")
rawset(dispatch, "familyWake", familyWake)
rawset(dispatch, "runDelivery", runDelivery)
rawset(dispatch, "cancelFamilyMembers", cancelFamilyMembers)
rawset(dispatch, "closeFamilyMembers", closeFamilyMembers)

rawset(parts, PART_NAME, { revision = PART_REVISION })

return SchedulerKit
