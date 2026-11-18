-- MoltenCodes OptionsKit part Bind
--
-- `bind = "profile.path.to.value"` and `ns:` binds: an option read and
-- written through a SettingsKit database passed to `Define` as `options.db`,
-- or through one of its namespaces (`ns:<name>.<scope>...`). The path is
-- split once at `Define`; every read walks the database's views at call time,
-- so a profile switch is seen at once, and every write goes through
-- SettingsKit, which validates it. Without this part `Define` refuses `bind`
-- at the caller's line and names this file (ADR 0001, point 5).
--
-- The part adds nothing to the facade; it extends the core's field tables
-- and fills its `Bound` hooks in `bind`, which runs at load and again
-- whenever a newer core loads, since every core revision builds those tables
-- anew.
--
-- Contents
-- --------
--   Constants ........ identity, the scopes a bind may start with
--   Dependencies ..... OptionsKit's core, its state and the helpers it lends
--   Paths ............ parsing a bind, finding a namespace
--   Reads and writes . walking, validating, writing a bound value
--   Binding .......... the field tables and hooks this part fills
--   Commit ........... the part's revision

-- Constants ------------------------------------------------------------------

local PART_NAME = "Bind"
local PART_REVISION = 1
local REQUIRED_REGISTRY_API = 2
local CORE_PACKAGE, CORE_API = "optionsKit", 1
-- The first core revision with the hooks this part fills.
local REQUIRED_CORE_REVISION = 16

-- The SettingsKit scopes a `bind` path may start with: SettingsKit's ten,
-- AceDB's `race`, `factionrealm`, `factionrealmregion` and `locale` included;
-- `Define` still refuses a scope the database does not provide.
local BIND_SCOPES = {
  global = true,
  char = true,
  realm = true,
  class = true,
  faction = true,
  profile = true,
  race = true,
  factionrealm = true,
  factionrealmregion = true,
  locale = true,
}

-- Dependencies ---------------------------------------------------------------

-- The shared MoltenCodes namespace is the one documented global handoff point between independently embedded copies.
-- selene: allow(global_usage)
local namespace = rawget(_G, "MoltenCodes")
local generations = type(namespace) == "table" and rawget(namespace, "Registries") or nil
local Registry = type(generations) == "table" and rawget(generations, REQUIRED_REGISTRY_API) or nil
local OptionsKit = nil
if type(Registry) == "table" and type(rawget(Registry, "Get")) == "function" then
  OptionsKit = Registry:Get(CORE_PACKAGE, CORE_API)
end
local state = type(OptionsKit) == "table" and rawget(OptionsKit, "_state") or nil
if
  type(state) ~= "table"
  or type(rawget(state, "parts")) ~= "table"
  or type(rawget(state, "helpers")) ~= "table"
then
  error("MoltenCodes OptionsKit part Bind requires OptionsKit API 1 to be loaded first", 2)
end
---@cast OptionsKit table
if
  type(rawget(OptionsKit, "REVISION")) ~= "number" or OptionsKit.REVISION < REQUIRED_CORE_REVISION
then
  error(
    "MoltenCodes OptionsKit part Bind requires OptionsKit revision 16 or later to be loaded first",
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
  -- An equal or newer revision of this part already serves every addon.
  return OptionsKit
end

-- The core's helpers, taken again by `bind` whenever a newer core revision
-- loads, so this part always runs the newest helpers.
local helpers = rawget(state, "helpers")

-- Paths ----------------------------------------------------------------------

---Parse `bind` into its scope and keys, and the namespace a
---`ns:<name>.<scope>...` bind names (revision 14). Returns the scope name, an
---array of at least one key, and the namespace name or `nil`.
---@param bind any
---@param record table
---@param level integer
---@return string scope
---@return string[] keys
---@return string|nil namespaceName
local function parseBind(bind, record, level)
  if type(bind) ~= "string" then
    error(helpers.labelOf(record, "bind") .. " must be a string", level)
  end
  local path = bind
  local namespaceName = nil
  if string.sub(bind, 1, #helpers.Bound.NAMESPACE_PREFIX) == helpers.Bound.NAMESPACE_PREFIX then
    path = string.sub(bind, #helpers.Bound.NAMESPACE_PREFIX + 1)
  end
  local scope = nil
  local keys = {}
  for segment in (path .. "."):gmatch("([^.]*)%.") do
    if not segment:find(helpers.keyPattern) then
      error(
        helpers.labelOf(record, "bind") .. ' "' .. bind .. '" must be dot-separated identifiers',
        level
      )
    end
    if path ~= bind and namespaceName == nil then
      namespaceName = segment
    elseif scope == nil then
      scope = segment
    else
      keys[#keys + 1] = segment
    end
  end
  if scope == nil or BIND_SCOPES[scope] ~= true then
    error(
      helpers.labelOf(record, "bind")
        .. ' "'
        .. bind
        .. '" must start with global, char, realm, class, faction, profile, race, factionrealm, factionrealmregion or locale',
      level
    )
  end
  if #keys == 0 then
    error(
      helpers.labelOf(record, "bind") .. ' "' .. bind .. '" must name a value inside the scope',
      level
    )
  end
  return scope, keys, namespaceName
end

---Read `field` of a database through its metatable without letting a raise
---escape: SettingsKit revision 15 raises at the reading line for a member of
---a part that is not loaded (`GetNamespace` without its Namespaces part).
---@param db table
---@param field string
---@return any
local function readMember(db, field)
  return db[field]
end

---The namespace `namespaceName` of `db`, a SettingsKit revision 15 child
---database, for a `ns:` bind. Refused at the caller when the database has no
---namespaces or none of that name is registered.
---@param db table
---@param namespaceName string
---@param bind string
---@param record table
---@param level integer
---@return table child
local function findNamespace(db, namespaceName, bind, record, level)
  local found, getNamespace = pcall(readMember, db, "GetNamespace")
  if not found or type(getNamespace) ~= "function" then
    error(
      helpers.labelOf(record, "bind")
        .. ' "'
        .. bind
        .. '" needs options.db with namespaces (SettingsKit revision 15 or later)',
      level
    )
  end
  local asked, child = pcall(getNamespace, db, namespaceName, { missingOk = true })
  if
    not asked
    or type(child) ~= "table"
    or type(child.OnChange) ~= "function"
    or type(child.Validate) ~= "function"
  then
    error(
      helpers.labelOf(record, "bind")
        .. ' namespace "'
        .. namespaceName
        .. '" is not registered in options.db',
      level
    )
  end
  return child
end

-- Reads and writes ----------------------------------------------------------

---Store `value` at `container[key]`. A named function rather than a closure,
---so the protected call around a database write allocates nothing.
---@param container table
---@param key string
---@param value any
local function assignField(container, key, value)
  container[key] = value
end

---Walk a bound option's path through the database's views, reading the scope
---table at call time so a profile switch is seen at once.
---
---Returns the deepest table reached and the index of the key to use in it: the
---last key when every intermediate table exists, otherwise the first key whose
---table does not exist yet. SettingsKit reads a record without a default and
---without saved data as `nil`, so a missing intermediate is an unset value,
---not an error.
---@param tree OptionsKit.Tree
---@param record table
---@param methodName string
---@param level integer
---@return table container
---@return integer index
local function walkBound(tree, record, methodName, level)
  local scope = rawget(record, "_bindScope")
  local container = rawget(helpers.Bound.database(tree, record), scope)
  if type(container) ~= "table" then
    error(
      methodName .. ' bind scope "' .. scope .. '" is not an available scope of the database',
      level
    )
  end
  local keys = rawget(record, "_bindKeys")
  local count = #keys
  for index = 1, count - 1 do
    local nested = container[keys[index]]
    if type(nested) == "nil" then
      return container, index
    end
    if type(nested) ~= "table" then
      error(
        methodName .. ' bind path "' .. helpers.Bound.text(record) .. '" does not lead to a table',
        level
      )
    end
    container = nested
  end
  return container, count
end

---Ask the database whether writing `value` at a bound option's path would be
---accepted, without writing. The key array split at `Define` is passed as it
---is, which SettingsKit checks without allocating. Returns `true`, or `false`
---and SettingsKit's message: the text `Set` would raise after its prefix.
---@param tree OptionsKit.Tree
---@param record table
---@param value any
---@param methodName string
---@param level integer
---@return boolean accepted
---@return string|nil message
local function validateBound(tree, record, value, methodName, level)
  local db = helpers.Bound.database(tree, record)
  local scope = rawget(record, "_bindScope")
  if type(rawget(db, scope)) ~= "table" then
    error(
      methodName .. ' bind scope "' .. scope .. '" is not an available scope of the database',
      level
    )
  end
  local accepted, message = db:Validate(scope, rawget(record, "_bindKeys"), value)
  if not helpers.isSecret(accepted) and accepted == true then
    return true, nil
  end
  return false, helpers.withoutPosition(message)
end

---Write a bound value through the database's views. A missing intermediate
---record is written as a nested table holding the value, which SettingsKit
---validates like any other write; clearing a value whose record does not
---exist does nothing. A SettingsKit refusal is raised again at the caller's
---line with its message kept.
---
---The protected write also catches an error from one of SettingsKit's own
---`OnChange` listeners, which runs after the value was stored. Only on that
---failure path, `db:Validate` tells the two apart: it accepts the value when
---the write was not refused, and the listener's error is then re-raised
---unchanged rather than reported as a refusal.
---@param tree OptionsKit.Tree
---@param record table
---@param value any
---@param methodName string
---@param level integer
local function writeBound(tree, record, value, methodName, level)
  local container, index = walkBound(tree, record, methodName, level + 1)
  local keys = rawget(record, "_bindKeys")
  local count = #keys
  local stored = value
  if index < count then
    if type(value) == "nil" then
      return
    end
    for position = count, index + 1, -1 do
      stored = { [keys[position]] = stored }
    end
  end
  local written, failure = pcall(assignField, container, keys[index], stored)
  if not written then
    local db = helpers.Bound.database(tree, record)
    local accepted = db:Validate(rawget(record, "_bindScope"), keys, value)
    if not helpers.isSecret(accepted) and accepted == true then
      error(failure, 0)
    end
    error(
      methodName
        .. " "
        .. rawget(record, "_path")
        .. " refused by the database: "
        .. helpers.withoutPosition(failure),
      level
    )
  end
end

---Read a bound value through the database's views; an unset intermediate
---record reads as `nil`.
---@param tree OptionsKit.Tree
---@param record table
---@param methodName string
---@param level integer
---@return any
local function readBound(tree, record, methodName, level)
  local container, index = walkBound(tree, record, methodName, level + 1)
  local keys = rawget(record, "_bindKeys")
  local count = #keys
  if index < count then
    return nil
  end
  return container[keys[count]]
end

---Build the bound fields of a record from its spec's `bind`: the scope and
---keys, and the namespace a `ns:` bind names. The core calls this through
---`Bound.build` for a spec with `bind`.
---@param context table the build context
---@param record table
---@param spec table
---@param level integer
local function buildBound(context, record, spec, level)
  if type(spec.get) ~= "nil" or type(spec.set) ~= "nil" then
    error(helpers.labelOf(record) .. " must use either bind or get and set, not both", level)
  end
  local db = context.db
  if not db then
    error(
      helpers.labelOf(record, "bind") .. " needs a SettingsKit database passed as options.db",
      level
    )
  end
  local scope, keys, namespaceName = parseBind(spec.bind, record, level + 1)
  if namespaceName ~= nil then
    db = findNamespace(db, namespaceName, spec.bind, record, level + 1)
    -- Outside the array part: `#keys` and `db:Validate(scope, keys)` see
    -- the keys alone.
    keys[0] = { db = db, name = namespaceName }
  end
  -- `rawget`: SettingsKit raises at its own line when an undeclared or
  -- unavailable scope is read through the database's metatable.
  if type(rawget(db, scope)) ~= "table" then
    error(
      helpers.labelOf(record, "bind")
        .. ' scope "'
        .. scope
        .. '" is not an available scope of '
        .. (namespaceName and ('namespace "' .. namespaceName .. '" of options.db') or "options.db"),
      level
    )
  end
  -- The bind text and the key count are derived when needed
  -- (`bindTextOf`, `#keys`), so the record keeps to its 8 hash slots.
  rawset(record, "_bindScope", scope)
  rawset(record, "_bindKeys", keys)
end

-- Binding --------------------------------------------------------------------

---Extend the core's field tables and fill its `Bound` hooks. Called by this
---file and by every newer core, which builds those tables anew.
---@param coreHelpers table the core's `state.helpers`
local function bind(coreHelpers)
  helpers = coreHelpers
  coreHelpers.Fields.value.bind = true
  local Bound = coreHelpers.Bound
  Bound.build = buildBound
  Bound.read = readBound
  Bound.write = writeBound
  Bound.validate = validateBound
end

-- Commit ---------------------------------------------------------------------

bind(helpers)
rawset(parts, PART_NAME, {
  revision = PART_REVISION,
  bind = bind,
  members = {},
})
helpers.dropLegacyWhenComplete()

return OptionsKit
