-- MoltenCodes PoolKit part Children
--
-- Cascading release: `pool:AttachChild(parent, child, childPool)` ties an
-- object borrowed from another pool (or the same one) to a parent, and
-- releasing the parent releases its children first, most recently attached
-- first, through their own pools; `pool:DetachChild(child)` unties one.
-- Without this part both raise at the caller with the file to embed
-- (docs/API.md, "Cascading release"; ADR 0001).
--
-- A parent's children form an intrusive doubly linked list kept in side
-- tables owned by the parent's pool, keyed by the child. The child's own pool
-- records which pool it is attached in, so a child released on its own leaves
-- its parent's list in constant time. The tables are created on a pool's
-- first `AttachChild`, so pools that never use children carry no field.
--
-- The core calls the hooks this part records in `_state.parts.Children`
-- (`releaseChildren`, `detachFromParent`) only for a pool that has children
-- or is attached, and the part reads the core's helpers from
-- `_state.helpers` at call time.
--
-- Contents
-- --------
--   Constants ............. identity and the part interface it needs
--   Core .................. PoolKit's core, its state and its prototype
--   Links ................. the side tables and the list operations
--   Cascade ............... releasing a parent's children
--   Methods ............... AttachChild and DetachChild
--   Commit ................ the part record and the prototype methods

-- Constants ------------------------------------------------------------------

local PART_NAME = "Children"
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
  error("MoltenCodes PoolKit part Children requires PoolKit API 1 to be loaded first", 2)
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

-- Links ----------------------------------------------------------------------

---Return the parent-side link tables of `pool`, creating them once.
---@param pool table
---@return table links
local function ensureChildLinks(pool)
  local links = rawget(pool, "_children")
  if not links then
    links = {
      first = {},
      nextSibling = {},
      previousSibling = {},
      childPool = {},
      parent = {},
    }
    rawset(pool, "_children", links)
  end
  return links
end

---Return the child-side attachment table of `pool`, creating it once.
---@param pool table
---@return table attachedTo child -> the pool its parent belongs to
local function ensureAttachments(pool)
  local attachedTo = rawget(pool, "_attachedTo")
  if not attachedTo then
    attachedTo = {}
    rawset(pool, "_attachedTo", attachedTo)
  end
  return attachedTo
end

---Put `child` at the front of `parent`'s child list.
---@param parentPool table
---@param parent table|userdata
---@param child table|userdata
---@param childPool table
local function linkChild(parentPool, parent, child, childPool)
  local links = ensureChildLinks(parentPool)
  local first = rawget(links.first, parent)
  rawset(links.nextSibling, child, first or false)
  rawset(links.previousSibling, child, false)
  if first ~= nil then
    rawset(links.previousSibling, first, child)
  end
  rawset(links.first, parent, child)
  rawset(links.childPool, child, childPool)
  rawset(links.parent, child, parent)
  rawset(ensureAttachments(childPool), child, parentPool)
end

---Take `child` out of its parent's list. Never raises.
---@param parentPool table
---@param child table|userdata
local function unlinkChild(parentPool, child)
  local links = rawget(parentPool, "_children")
  local parent = rawget(links.parent, child)
  local childPool = rawget(links.childPool, child)
  local previous = rawget(links.previousSibling, child)
  local following = rawget(links.nextSibling, child)

  if previous == false then
    rawset(links.first, parent, following or nil)
  else
    rawset(links.nextSibling, previous, following)
  end
  if following ~= false then
    rawset(links.previousSibling, following, previous)
  end

  rawset(links.nextSibling, child, nil)
  rawset(links.previousSibling, child, nil)
  rawset(links.childPool, child, nil)
  rawset(links.parent, child, nil)
  rawset(rawget(childPool, "_attachedTo"), child, nil)
end

---Leave the parent `object` is attached to, if any.
---@param pool table pool `object` belongs to
---@param object table|userdata
local function detachFromParent(pool, object)
  local attachedTo = rawget(pool, "_attachedTo")
  if not attachedTo then
    return
  end
  local parentPool = rawget(attachedTo, object)
  if parentPool ~= nil then
    unlinkChild(parentPool, object)
  end
end

-- Cascade --------------------------------------------------------------------

---Release one attached child as part of its parent's release.
---@param childPool table
---@param child table|userdata
local function releaseCascadedChild(childPool, child)
  local helpers = rawget(state, "helpers")
  local status = rawget(rawget(childPool, "_active"), child)
  if status ~= ACTIVE and status ~= PARKED then
    -- `RELEASING` is a cycle back to an object already being released;
    -- anything else is no longer borrowed. Either way there is nothing to do.
    return
  end

  helpers.ensureMutationAllowed(childPool, "PoolKit.Pool:Release", 0)
  if status == PARKED then
    helpers.finalizeParked(childPool, child)
  else
    helpers.releaseActive(childPool, child)
  end
end

---Release every child attached to `parent`, most recently attached first.
---@param pool table
---@param parent table|userdata
---@return table|nil firstError
local function releaseChildren(pool, parent)
  local links = rawget(pool, "_children")
  if not links then
    return nil
  end

  local captureFirstError = rawget(state, "helpers").captureFirstError
  local firstError = nil
  local child = rawget(links.first, parent)
  while child ~= nil do
    local childPool = rawget(links.childPool, child)
    -- Unlink first so the child's own release does not look for a parent,
    -- and so the loop always advances whatever the release does.
    unlinkChild(pool, child)
    local ok, value = pcall(releaseCascadedChild, childPool, child)
    firstError = captureFirstError(firstError, ok, value)
    child = rawget(links.first, parent)
  end
  return firstError
end

-- Methods --------------------------------------------------------------------

---Attach `child`, borrowed from `childPool`, to `parent`, borrowed from this
---pool. Releasing `parent` releases its children first, most recently attached
---first, through their own pools; a child released on its own is detached.
---@param self PoolKit.Pool
---@param parent table|userdata an object borrowed from this pool
---@param child table|userdata an object borrowed from `childPool`
---@param childPool PoolKit.Pool the pool `child` belongs to; may be this pool
---@return PoolKit.Pool self
local function poolAttachChild(self, parent, child, childPool)
  local helpers = rawget(state, "helpers")
  helpers.validatePool(self, "PoolKit.Pool:AttachChild", 3)
  helpers.ensureMutationAllowed(self, "PoolKit.Pool:AttachChild", 3)
  helpers.validatePoolObject(parent, "PoolKit.Pool:AttachChild parent", 3)
  helpers.validatePoolObject(child, "PoolKit.Pool:AttachChild child", 3)
  if type(childPool) ~= "table" or getmetatable(childPool) ~= rawget(state, "poolMetatable") then
    error("PoolKit.Pool:AttachChild childPool must be a PoolKit pool", 2)
  end
  helpers.upgradeIfOld(childPool)

  if rawget(rawget(self, "_active"), parent) ~= ACTIVE then
    error("PoolKit.Pool:AttachChild parent must be borrowed from this pool", 2)
  end
  if rawget(rawget(childPool, "_active"), child) ~= ACTIVE then
    error("PoolKit.Pool:AttachChild child must be borrowed from childPool", 2)
  end
  if parent == child then
    error("PoolKit.Pool:AttachChild cannot attach an object to itself", 2)
  end
  local attachedTo = rawget(childPool, "_attachedTo")
  if attachedTo and rawget(attachedTo, child) ~= nil then
    error("PoolKit.Pool:AttachChild child is already attached to a parent", 2)
  end

  linkChild(self, parent, child, childPool)
  return self
end

---Detach `child` from its parent in this pool without releasing either.
---@param self PoolKit.Pool
---@param child table|userdata
---@return boolean detached `false` when `child` had no parent in this pool.
local function poolDetachChild(self, child)
  local helpers = rawget(state, "helpers")
  helpers.validatePool(self, "PoolKit.Pool:DetachChild", 3)
  helpers.ensureMutationAllowed(self, "PoolKit.Pool:DetachChild", 3)
  helpers.validatePoolObject(child, "PoolKit.Pool:DetachChild child", 3)

  local links = rawget(self, "_children")
  if not links or rawget(links.parent, child) == nil then
    return false
  end
  unlinkChild(self, child)
  return true
end

-- Commit ---------------------------------------------------------------------

rawset(parts, PART_NAME, {
  revision = PART_REVISION,
  methods = { AttachChild = poolAttachChild, DetachChild = poolDetachChild },
  releaseChildren = releaseChildren,
  detachFromParent = detachFromParent,
})
rawset(Pool, "AttachChild", poolAttachChild)
rawset(Pool, "DetachChild", poolDetachChild)

return PoolKit
