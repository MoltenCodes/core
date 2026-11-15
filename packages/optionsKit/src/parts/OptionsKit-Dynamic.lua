-- MoltenCodes OptionsKit part Dynamic
--
-- Options trees that change shape after `Define`, as AceConfig addons build
-- theirs: `OptionsKit:Define(addonName, builder)` with a function that
-- returns the tree, `tree:NotifyChange()` to read the tree again (the
-- builder, or the table passed to `Define` while the addon holds it), and
-- `tree:Replace(path, option)` and `tree:Remove(path)` to change one subtree.
-- `docs/API.md`, *Dynamic trees*, is the contract, the rules renderers follow
-- included.
--
-- `NotifyChange` only marks the tree dirty; the core's tree check (the
-- `_defined` field every method already tests) calls this part's rebuild at
-- the next method that reads the structure, so calls before it coalesce into
-- one rebuild and a clean tree pays nothing. A refused rebuild keeps the
-- previous structure and is reported through the client's error handler, so
-- the method that triggered it runs on.
--
-- The part needs OptionsKit's core loaded first (revision 15 or later) and
-- calls no client function except `geterrorhandler`.
--
-- Contents
-- --------
--   Constants ........ identity, labels
--   Dependencies ..... OptionsKit's core, its state and the helpers it lends
--   Paths ............ the checks of a `Replace` or `Remove` path
--   Rebuild .......... reading the source again and swapping the structure
--   Methods .......... NotifyChange, Replace, Remove
--   Commit ........... the members and the part's revision

-- Constants ------------------------------------------------------------------

local PART_NAME = "Dynamic"
local PART_REVISION = 1
local REQUIRED_REGISTRY_API = 2
local CORE_PACKAGE, CORE_API = "optionsKit", 1

-- The labels the checks of a rebuild and of a `Replace` name fields from.
local NOTIFY_LABEL = "OptionsKit.Tree:NotifyChange tree"
local REPLACE_LABEL = "OptionsKit.Tree:Replace option"

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
  error("MoltenCodes OptionsKit part Dynamic requires OptionsKit API 1 to be loaded first", 2)
end
---@cast OptionsKit table

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

local treeMetatable = rawget(state, "treeMetatable")

-- The core's helpers, assigned by `bind` below: at load, and again whenever a
-- newer core revision loads, so this part always runs the newest helpers with
-- no lookup per call.
local isSecret, validateTree, newBuildContext, buildStructure, buildOption
local flatten, compareRecords, depthOf, attachLinks, detachProfileLink
local withoutPosition, handlerInForce, labelBase, defineLabel, keyPattern, dirty, treeSources

---Take the core's helpers. Called by this file and by every newer core.
---@param helpers table the core's `state.helpers`
local function bind(helpers)
  isSecret = helpers.isSecret
  validateTree = helpers.validateTree
  newBuildContext = helpers.newBuildContext
  buildStructure = helpers.buildStructure
  buildOption = helpers.buildOption
  flatten = helpers.flatten
  compareRecords = helpers.compareRecords
  depthOf = helpers.depthOf
  attachLinks = helpers.attachLinks
  detachProfileLink = helpers.detachProfileLink
  withoutPosition = helpers.withoutPosition
  handlerInForce = helpers.handlerInForce
  labelBase = helpers.labelBase
  defineLabel = helpers.defineLabel
  keyPattern = helpers.keyPattern
  dirty = helpers.dirty
  treeSources = helpers.treeSources
end

-- Paths ----------------------------------------------------------------------

---Refuse a path that is secret, not a string, empty, or not dotted
---identifiers. Returns the parent's path (`""` for the root) and the key.
---@param path any
---@param methodName string
---@param level integer
---@return string parentPath
---@return string key
local function splitPath(path, methodName, level)
  if isSecret(path) then
    error(methodName .. " path must not be a secret value", level)
  end
  if type(path) ~= "string" or path == "" then
    error(methodName .. " path must be a non-empty string", level)
  end
  for segment in (path .. "."):gmatch("([^.]*)%.") do
    if not segment:find(keyPattern) then
      error(methodName .. ' path "' .. path .. '" must be dot-separated identifiers', level)
    end
  end
  local parentPath, key = path:match("^(.*)%.([^.]+)$")
  if parentPath == nil then
    return "", path
  end
  return parentPath, key
end

---Whether `path` is `root` or lies below it.
---@param path any
---@param root string
---@return boolean
local function isWithin(path, root)
  return type(path) == "string" and (path == root or string.sub(path, 1, #root + 1) == root .. ".")
end

---Remove `record` and everything below it from the path index. Returns how
---many records it removed.
---@param records table<string, table>
---@param record table
---@return integer
local function removeSubtree(records, record)
  rawset(records, rawget(record, "_path"), nil)
  local removed = 1
  local children = rawget(record, "_children")
  if children ~= nil then
    for index = 1, #children do
      removed = removed + removeSubtree(records, children[index])
    end
  end
  return removed
end

---Detach the profile groups below `path` (a link records where its group
---sits since revision 15), except those in `keep`, and return the tree's
---links without the detached ones.
---@param tree OptionsKit.Tree
---@param path string
---@param keep table<table, true>|nil links a replacement placed again
---@return table[] kept
local function detachLinksWithin(tree, path, keep)
  local kept = {}
  local links = rawget(tree, "_profileLinks")
  for index = 1, #links do
    local link = links[index]
    if keep ~= nil and keep[link] then
      -- Placed again by the replacement, which lists it itself.
      kept[#kept + 1] = false
    elseif isWithin(link.path, path) then
      detachProfileLink(link)
    else
      kept[#kept + 1] = link
    end
  end
  local compact = {}
  for index = 1, #kept do
    if kept[index] then
      compact[#compact + 1] = kept[index]
    end
  end
  return compact
end

---Rebuild the walk array from the root.
---@param tree OptionsKit.Tree
local function rewalk(tree)
  local walk = {}
  flatten(rawget(tree, "_root"), walk)
  rawset(tree, "_walk", walk)
end

---Fire the tree's structure signal, when anyone listens.
---@param tree OptionsKit.Tree
---@param path string
local function announce(tree, path)
  local signal = rawget(tree, "_structureChanged")
  if signal ~= nil then
    signal:Fire(tree, path)
  end
end

---A build context for `tree` under the limits it was defined with.
---@param tree OptionsKit.Tree
---@param label string
---@return table context
local function contextFor(tree, label)
  local context = newBuildContext(rawget(tree, "_addonName"), tree, rawget(tree, "_db"), label)
  context.maxOptions = rawget(tree, "_maxOptions")
  context.maxDepth = rawget(tree, "_maxDepth")
  context.maxDynamicEntries = rawget(tree, "_maxDynamicEntries")
  context.rebuilding = tree
  return context
end

-- Rebuild --------------------------------------------------------------------

---Report a refused rebuild through the client's error handler
---(`Blizzard_SharedXMLBase/ErrorUtil.lua` calls `geterrorhandler()` on every
---flavour). Without one, the report is dropped; the structure is kept either
---way.
---@param tree OptionsKit.Tree
---@param message string
local function report(tree, message)
  -- geterrorhandler is a World of Warcraft client API reachable only through the global table.
  -- selene: allow(global_usage)
  local getErrorHandler = rawget(_G, "geterrorhandler")
  if type(getErrorHandler) ~= "function" then
    return
  end
  local handler = getErrorHandler()
  if type(handler) == "function" then
    handler("OptionsKit (" .. rawget(tree, "_addonName") .. ") NotifyChange: " .. message)
  end
end

---The tree's source: the builder's answer, or the table passed to `Define`.
---Returns `nil` and the reason when there is none.
---@param tree OptionsKit.Tree
---@return table|nil spec
---@return string|nil failure
local function readSource(tree)
  local builder = rawget(tree, "_builder")
  if builder ~= nil then
    local built, spec = pcall(builder, rawget(tree, "_addonName"))
    if not built then
      -- The builder's own message and position: it is the addon's code.
      return nil, tostring(spec)
    end
    if type(spec) ~= "table" then
      return nil, "the tree function returned no table"
    end
    return spec, nil
  end
  local spec = rawget(treeSources, tree)
  if spec == nil then
    return nil, "the table passed to Define is no longer held by the addon"
  end
  return spec, nil
end

---Give each record that survives with the same kind, `arg` and handler the
---`info` table its predecessor had, so a consumer that compared them sees
---the same table.
---@param oldRecords table<string, table>
---@param newRecords table<string, table>
local function transferInfos(oldRecords, newRecords)
  for path, record in pairs(newRecords) do
    local previous = rawget(oldRecords, path)
    local info = previous ~= nil and rawget(previous, "_info") or nil
    if info ~= nil and rawget(previous, "_kind") == rawget(record, "_kind") then
      local hints = rawget(record, "_hints")
      local arg = hints and hints.arg
      if rawequal(info.arg, arg) and rawequal(info.handler, handlerInForce(record)) then
        rawset(record, "_info", info)
      end
    end
  end
end

---Read the source of a dirty tree again, check it as `Define` does and swap
---the structure in. Never raises: a refusal keeps the structure and is
---reported. Called by the core's tree check.
---@param tree OptionsKit.Tree
local function rebuild(tree)
  -- Clean while the builder runs, so it may read the tree as it is; a
  -- `NotifyChange` it makes marks the tree dirty again.
  rawset(tree, "_defined", true)
  local spec, failure = readSource(tree)
  if spec == nil then
    report(tree, failure --[[@as string]])
    return
  end
  local context = contextFor(tree, NOTIFY_LABEL)
  labelBase.prefix, labelBase.path = NOTIFY_LABEL, ""
  local built, root, walk = pcall(buildStructure, context, spec, 1)
  labelBase.prefix, labelBase.path = defineLabel, ""
  if not built then
    report(tree, withoutPosition(root))
    return
  end
  -- An `Undefine` made by the builder ends the rebuild.
  if rawget(tree, "_defined") == false then
    return
  end
  local attached, attachFailure =
    pcall(attachLinks, context.profileLinks, context.profilePaths, tree)
  if not attached then
    report(tree, withoutPosition(attachFailure))
    return
  end
  local kept = {}
  for index = 1, #context.profileLinks do
    kept[context.profileLinks[index]] = true
  end
  local previousLinks = rawget(tree, "_profileLinks")
  for index = 1, #previousLinks do
    if not kept[previousLinks[index]] then
      detachProfileLink(previousLinks[index])
    end
  end
  local previousRoot = rawget(tree, "_root")
  transferInfos(rawget(tree, "_records"), context.records)
  local rootInfo = rawget(previousRoot, "_info")
  if rootInfo ~= nil and rawequal(rootInfo.handler, handlerInForce(root)) then
    rawset(root, "_info", rootInfo)
  end
  rawset(tree, "_root", root)
  rawset(tree, "_records", context.records)
  rawset(tree, "_walk", walk)
  rawset(tree, "_profileLinks", context.profileLinks)
  rawset(tree, "_groupConfirm", context.groupConfirm or nil)
end

-- Methods --------------------------------------------------------------------

---Ask for the tree to be read again from its source at the next method that
---reads the structure. Only marks the tree: calls before that rebuild
---coalesce into it, and the structure signal fires once, when a clean tree
---becomes dirty.
---@param self OptionsKit.Tree
local function notifyChange(self)
  if type(self) ~= "table" or getmetatable(self) ~= treeMetatable then
    error("OptionsKit.Tree:NotifyChange must be called on an OptionsKit tree", 2)
  end
  local defined = rawget(self, "_defined")
  if defined ~= true and defined ~= dirty then
    error("OptionsKit.Tree:NotifyChange cannot be called on an undefined tree", 2)
  end
  if rawget(self, "_builder") == nil and rawget(treeSources, self) == nil then
    error(
      "OptionsKit.Tree:NotifyChange has no source to read again: keep the table passed to Define, or define the tree with a builder",
      2
    )
  end
  if defined == true then
    rawset(self, "_defined", dirty)
    announce(self, "")
  end
end

---Check `option` and put it at `path`, replacing the option there or adding
---it under the group `path`'s parent names. Only the subtree is checked,
---against the tree's limits; a refusal changes nothing.
---@param self OptionsKit.Tree
---@param path string
---@param option OptionsKit.Option
local function replace(self, path, option)
  validateTree(self, "OptionsKit.Tree:Replace", 3)
  local parentPath, key = splitPath(path, "OptionsKit.Tree:Replace", 3)
  local records = rawget(self, "_records")
  local parent = parentPath == "" and rawget(self, "_root") or rawget(records, parentPath)
  if parent == nil or rawget(parent, "_kind") ~= "group" then
    error(
      'OptionsKit.Tree:Replace path "' .. path .. '" needs a group at "' .. parentPath .. '"',
      2
    )
  end
  local previous = rawget(records, path)
  local previousCount = 0
  if previous ~= nil then
    previousCount = removeSubtree({}, previous)
  end
  local context = contextFor(self, REPLACE_LABEL)
  context.count = #rawget(self, "_walk") - previousCount
  -- The groups above `path` were built before: let the new subtree look for
  -- accessors they declare.
  context.inheritsAccessors = true
  labelBase.prefix, labelBase.path = REPLACE_LABEL, path
  local built, record = pcall(buildOption, context, option, parent, key, depthOf(parent) + 1, 1)
  labelBase.prefix, labelBase.path = defineLabel, ""
  if not built then
    error(withoutPosition(record), 2)
  end
  local attached, failure = pcall(attachLinks, context.profileLinks, context.profilePaths, self)
  if not attached then
    error(withoutPosition(failure), 2)
  end

  local placed = {}
  for index = 1, #context.profileLinks do
    placed[context.profileLinks[index]] = true
  end
  local links = detachLinksWithin(self, path, placed)
  for index = 1, #context.profileLinks do
    links[#links + 1] = context.profileLinks[index]
  end
  rawset(self, "_profileLinks", links)
  if context.groupConfirm then
    rawset(self, "_groupConfirm", true)
  end
  if previous ~= nil then
    removeSubtree(records, previous)
  end
  for recordPath, newRecord in pairs(context.records) do
    rawset(records, recordPath, newRecord)
  end
  local children = rawget(parent, "_children")
  local position = #children + 1
  for index = 1, #children do
    if children[index] == previous then
      position = index
      break
    end
  end
  children[position] = record
  table.sort(children, compareRecords)
  rewalk(self)
  announce(self, path)
end

---Remove the option at `path` and everything below it. `true` when there was
---one, `false` when the tree has no such path.
---@param self OptionsKit.Tree
---@param path string
---@return boolean removed
local function remove(self, path)
  validateTree(self, "OptionsKit.Tree:Remove", 3)
  splitPath(path, "OptionsKit.Tree:Remove", 3)
  local records = rawget(self, "_records")
  local record = rawget(records, path)
  if record == nil then
    return false
  end
  rawset(self, "_profileLinks", detachLinksWithin(self, path))
  removeSubtree(records, record)
  local children = rawget(rawget(record, "_parent"), "_children")
  for index = 1, #children do
    if children[index] == record then
      table.remove(children, index)
      break
    end
  end
  rewalk(self)
  announce(self, path)
  return true
end

-- Commit ---------------------------------------------------------------------

bind(rawget(state, "helpers"))
rawset(parts, PART_NAME, {
  revision = PART_REVISION,
  bind = bind,
  rebuild = rebuild,
  members = { NotifyChange = notifyChange, Replace = replace, Remove = remove },
})
local Tree = rawget(OptionsKit, "Tree")
rawset(Tree, "NotifyChange", notifyChange)
rawset(Tree, "Replace", replace)
rawset(Tree, "Remove", remove)

return OptionsKit
