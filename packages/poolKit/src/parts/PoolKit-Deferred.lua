-- MoltenCodes PoolKit part Deferred
--
-- Release deferred until an animation finishes: `pool:ReleaseAfter(object,
-- animationGroup)` parks a borrowed object (still owned, no longer borrowed,
-- still counted against `maxActive`) and releases it when the group's
-- `OnFinished` fires. Without this part `ReleaseAfter` raises at the caller
-- with the file to embed and `GetParkedCount` answers `0` (docs/API.md,
-- "Deferred release"; ADR 0001).
--
-- PoolKit hooks a group's `OnFinished` once per group ever (`HookScript`
-- cannot be undone), through a hook that reads its behaviour from the shared
-- `_state.dispatch`, so a hook an older revision installed runs this part's
-- completion. The core calls the hooks this part records in
-- `_state.parts.Deferred` (`finalizeParked`, `finalizeAllParked`) only for a
-- parked object, and the part reads the core's helpers from `_state.helpers`
-- at call time.
--
-- Contents
-- --------
--   Constants ............. identity and the part interface it needs
--   Core .................. PoolKit's core, its state and its prototype
--   Parking ............... park, unpark and completing a release
--   Animation hooks ....... the shared OnFinished hook and its dispatch
--   Methods ............... ReleaseAfter
--   Commit ................ the part record, the dispatch and the method

-- Constants ------------------------------------------------------------------

local PART_NAME = "Deferred"
local PART_REVISION = 1
local REQUIRED_REGISTRY_API = 2
local CORE_PACKAGE, CORE_API = "poolKit", 1
-- The `_state.helpers` entries and part-record hooks this part relies on; the
-- core publishes the interface it offers as `_state.partInterface`.
local REQUIRED_PART_INTERFACE = 1

-- Values of the pool layout every revision shares: per-object status in a
-- pool's `_active` map, and the reason a queued request fails with.
local ACTIVE = 1
local PARKED = 3

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
  error("MoltenCodes PoolKit part Deferred requires PoolKit API 1 to be loaded first", 2)
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

-- Parking --------------------------------------------------------------------

---Park a borrowed object until `group` finishes.
---@param pool table
---@param object table|userdata
---@param group PoolKit.AnimationGroup
local function park(pool, object, group)
  local parked = rawget(pool, "_parked")
  if not parked then
    parked = {}
    rawset(pool, "_parked", parked)
  end
  rawset(parked, object, group)
  rawset(rawget(state, "deferredPool"), group, pool)
  rawset(rawget(state, "deferredObject"), group, object)

  rawset(rawget(pool, "_active"), object, PARKED)
  rawset(pool, "_activeCount", rawget(pool, "_activeCount") - 1)
  rawset(pool, "_parkedCount", (rawget(pool, "_parkedCount") or 0) + 1)
end

---Move a parked object back to plain borrowed state and forget its animation.
---@param pool table
---@param object table|userdata
local function unpark(pool, object)
  local parked = rawget(pool, "_parked")
  local group = rawget(parked, object)
  rawset(parked, object, nil)
  if group ~= nil then
    rawset(rawget(state, "deferredPool"), group, nil)
    rawset(rawget(state, "deferredObject"), group, nil)
  end

  rawset(rawget(pool, "_active"), object, ACTIVE)
  rawset(pool, "_parkedCount", rawget(pool, "_parkedCount") - 1)
  rawset(pool, "_activeCount", rawget(pool, "_activeCount") + 1)
end

---Complete a deferred release now.
---@param pool table
---@param object table|userdata
---@return boolean released
local function finalizeParked(pool, object)
  unpark(pool, object)
  return rawget(state, "helpers").releaseActive(pool, object)
end

---Complete every parked release of a closing pool, best effort.
---@param pool table
---@return table|nil firstError
local function finalizeAllParked(pool)
  local parked = rawget(pool, "_parked")
  if not parked then
    return nil
  end

  local captureFirstError = rawget(state, "helpers").captureFirstError
  local firstError = nil
  local object = next(parked)
  while object ~= nil do
    local ok, value = pcall(finalizeParked, pool, object)
    firstError = captureFirstError(firstError, ok, value)
    -- `unpark` removes the entry before anything can raise; this only
    -- guarantees the loop advances if that ever stops being true.
    rawset(parked, object, nil)
    object = next(parked)
  end
  return firstError
end

-- Animation hooks ------------------------------------------------------------

---`OnFinished` hook shared by every animation group PoolKit ever hooked.
---
---Reads its behaviour from shared state, so a hook an older revision installed
---runs the newest accepted revision's completion.
---@param group PoolKit.AnimationGroup
local function onAnimationFinished(group)
  local finish = rawget(rawget(state, "dispatch"), "animationFinished")
  return finish(group)
end

---Complete the deferred release waiting on `group`, if any. Called by the host.
---
---Failures cannot reach a caller here, so they are reported through the host
---error handler. A pool that is inside one of its own lifecycle callbacks when
---the animation ends keeps the object parked; `Release` or `Close` completes it.
---@param group PoolKit.AnimationGroup
local function completeDeferredRelease(group)
  local pool = rawget(rawget(state, "deferredPool"), group)
  if pool == nil then
    return
  end
  local object = rawget(rawget(state, "deferredObject"), group)
  local reportWarning = rawget(state, "helpers").reportWarning

  if rawget(pool, "_callbackDepth") > 0 then
    reportWarning(
      "PoolKit could not complete a deferred release because its pool was inside a "
        .. tostring(rawget(pool, "_callbackPhase"))
        .. " callback; release the object explicitly"
    )
    return
  end

  local ok, value = pcall(finalizeParked, pool, object)
  if not ok then
    reportWarning(value)
  end
end

---Whether `value` has the shape of an animation group: `HookScript`,
---`IsPlaying`, `Play` and `Stop` methods.
---
---`HookScript` alone is not enough: every Frame has it, and a Frame passed by
---mistake would get past the check and fail later inside the client's own
---`OnFinished` handling instead of at the caller. A Frame has none of the other
---three. Only `HookScript` and `IsPlaying` are ever called; `Play` and `Stop`
---are read, never called. Run under `pcall`, because indexing a userdata
---without an `__index` raises.
---@param value table|userdata
---@return boolean
local function hasAnimationGroupShape(value)
  return type(value.HookScript) == "function"
    and type(value.IsPlaying) == "function"
    and type(value.Play) == "function"
    and type(value.Stop) == "function"
end

---Install PoolKit's `OnFinished` hook on `group`, once per group ever.
---
---`HookScript` cannot be undone, so hooking per release would stack one more
---permanent hook on a pooled Frame's animation every time it is reused.
---@param group PoolKit.AnimationGroup
local function hookAnimationGroup(group)
  local hooked = rawget(state, "hookedGroups")
  if rawget(hooked, group) == true then
    return
  end
  group:HookScript("OnFinished", onAnimationFinished)
  rawset(hooked, group, true)
end

-- Methods --------------------------------------------------------------------

---Release `object` once `animationGroup` finishes playing.
---
---The object is parked: still owned by the pool (`Owns` is `true`), no longer
---borrowed (`IsActive` is `false`), and still counted against `maxActive`
---because it is still on screen. PoolKit hooks the group's `OnFinished` once per
---group. A group that is not playing would never finish, so the object is
---released at once instead. `Release(object)` completes a parked release early.
---@param self PoolKit.Pool
---@param object table|userdata an object borrowed from this pool
---@param animationGroup PoolKit.AnimationGroup the fade-out or other animation
---@return boolean deferred `false` when the object was released immediately.
local function poolReleaseAfter(self, object, animationGroup)
  local helpers = rawget(state, "helpers")
  helpers.validatePool(self, "PoolKit.Pool:ReleaseAfter", 3)
  helpers.ensureMutationAllowed(self, "PoolKit.Pool:ReleaseAfter", 3)
  helpers.validatePoolObject(object, "PoolKit.Pool:ReleaseAfter object", 3)

  local groupType = type(animationGroup)
  local isGroup = false
  if groupType == "table" or groupType == "userdata" then
    local readable, shaped = pcall(hasAnimationGroupShape, animationGroup)
    isGroup = readable and shaped
  end
  if not isGroup then
    error("PoolKit.Pool:ReleaseAfter animationGroup must be an animation group", 2)
  end
  -- The shape check above is what makes it one, whatever its Lua type.
  ---@cast animationGroup PoolKit.AnimationGroup

  local status = rawget(rawget(self, "_active"), object)
  if status ~= ACTIVE then
    helpers.raiseNotReleasable(self, object, status, "PoolKit.Pool:ReleaseAfter", 3)
  end
  if rawget(rawget(state, "deferredPool"), animationGroup) ~= nil then
    error("PoolKit.Pool:ReleaseAfter animationGroup already has a pending release", 2)
  end

  if not animationGroup:IsPlaying() then
    helpers.releaseActive(self, object)
    return false
  end

  hookAnimationGroup(animationGroup)
  park(self, object, animationGroup)
  return true
end

-- Commit ---------------------------------------------------------------------

rawset(parts, PART_NAME, {
  revision = PART_REVISION,
  methods = { ReleaseAfter = poolReleaseAfter },
  finalizeParked = finalizeParked,
  finalizeAllParked = finalizeAllParked,
  animationFinished = completeDeferredRelease,
})
rawset(rawget(state, "dispatch"), "animationFinished", completeDeferredRelease)
rawset(Pool, "ReleaseAfter", poolReleaseAfter)

return PoolKit
