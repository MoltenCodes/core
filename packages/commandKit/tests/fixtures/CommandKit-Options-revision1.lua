-- MoltenCodes CommandKit part Options
--
-- Drives an OptionsKit tree from a slash command:
--
--   scope:BindOptions(tree, name, options?)   register `/name` over the tree,
--       with the `get`, `set`, `reset`, `list` and `exec` verbs and, with
--       `options.syntax = "path"`, AceConfigCmd-3.0's `/name group option value`
--   scope:GetBoundTree(name)                  the tree `/name` was bound to
--
-- Every bound sub-command describes the one option (or group) its path names,
-- once, to see it as it is now (value, labels, hidden and disabled flags):
-- `tree:DescribeOption(path)` on OptionsKit revision 7 and later, so only that
-- option's callbacks run; the whole `tree:Describe()` on an older revision.
-- Allocating by design, because a values function may answer differently each
-- time. The path syntax finds the path first in an index of the tree's paths
-- kept per binding, so a typed line still describes one option only.
--
-- Contents
-- --------
--   Constants ........ identity, option fields, value kinds
--   Dependencies ..... CommandKit's core, its state and helpers
--   Describing ....... finding an option, formatting and parsing values
--   Handlers ......... get, set, reset, list and exec
--   Path syntax ...... resolving `group option` words, the path handler
--   Completion ....... candidates for the verbs and the path syntax
--   Scope methods .... BindOptions, GetBoundTree
--   Commit ........... the part's record and methods

-- Constants ------------------------------------------------------------------

local PART_NAME = "Options"
local PART_REVISION = 1
local REQUIRED_REGISTRY_API = 2
local CORE_PACKAGE, CORE_API = "commandKit", 1
local OPTIONSKIT_API = 1

-- The fields `BindOptions` accepts in its option table.
local BIND_OPTION_FIELDS = { description = true, syntax = true, onEmpty = true }

-- The command-line syntaxes `BindOptions` offers.
local SYNTAXES = { verbs = true, path = true }

-- Dependencies ---------------------------------------------------------------

-- The shared MoltenCodes namespace is the one documented global handoff point between independently embedded copies.
-- selene: allow(global_usage)
local namespace = rawget(_G, "MoltenCodes")
local generations = type(namespace) == "table" and rawget(namespace, "Registries") or nil
local Registry = type(generations) == "table" and rawget(generations, REQUIRED_REGISTRY_API) or nil
local CommandKit = nil
if type(Registry) == "table" and type(rawget(Registry, "Get")) == "function" then
  CommandKit = Registry:Get(CORE_PACKAGE, CORE_API)
end
local state = type(CommandKit) == "table" and rawget(CommandKit, "_state") or nil
if
  type(state) ~= "table"
  or type(rawget(state, "parts")) ~= "table"
  or type(rawget(state, "helpers")) ~= "table"
then
  error("MoltenCodes CommandKit part Options requires CommandKit API 1 to be loaded first", 2)
end

local parts = rawget(state, "parts")
local installed = rawget(parts, PART_NAME)
if
  type(installed) == "table"
  and type(installed.revision) == "number"
  and installed.revision >= PART_REVISION
then
  -- An equal or newer revision of this part already serves every scope.
  return CommandKit
end

-- Read at call time, never copied: an upgraded core's helpers serve this part.
local helpers = rawget(state, "helpers")

-- Describing -----------------------------------------------------------------

-- Option kinds that carry a value.
local VALUE_KINDS = {
  toggle = true,
  range = true,
  select = true,
  multiselect = true,
  input = true,
  color = true,
  keybinding = true,
}

---Index a description by path.
---@param node table
---@param index table<string, table>
local function indexDescription(node, index)
  index[node.path] = node
  local children = node.children
  if type(children) == "table" then
    for position = 1, #children do
      indexDescription(children[position], index)
    end
  end
end

---The description node at `path`, or `nil` after telling the user.
---@param context CommandKit.Context
---@param tree table
---@param path string|nil
---@param allowRoot boolean whether `nil` or `""` names the root group
---@return table|nil node
local function findOption(context, tree, path, allowRoot)
  if path == nil or path == "" then
    if not allowRoot then
      helpers.contextFail(context, "expected an option path")
      helpers.contextUsage(context)
      return nil
    end
    path = ""
  end
  local node
  -- OptionsKit revision 7 describes one option; an older revision only the
  -- whole tree, which is then indexed by path.
  if type(tree.DescribeOption) == "function" then
    node = tree:DescribeOption(path)
  else
    local index = {}
    indexDescription(tree:Describe(), index)
    node = index[path]
  end
  if node == nil or node.hidden == true then
    helpers.contextFail(context, 'unknown option "' .. path .. '"')
    return nil
  end
  return node
end

---The sorted keys of a values table.
---@param node table
---@return any[]
local function valueKeys(node)
  local keys = {}
  local sorting = node.sorting
  if type(sorting) == "table" then
    for index = 1, #sorting do
      keys[index] = sorting[index]
    end
    return keys
  end
  for key in next, node.values or {} do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(left, right)
    return tostring(left) < tostring(right)
  end)
  return keys
end

---A value as the command line shows it. A secret, at the top or inside a
---`multiselect` or `color` table (OptionsKit's `Describe` passes nested
---secrets through), is shown as `(secret value)` before anything compares or
---formats it.
---@param node table
---@param value any
---@return string
local function formatValue(node, value)
  if helpers.isSecret(value) then
    return "(secret value)"
  end
  local kind = node.kind
  if type(value) == "nil" then
    if kind == "toggle" then
      return "default"
    end
    return "(none)"
  end
  if kind == "toggle" and type(value) == "boolean" then
    return value and "on" or "off"
  end
  if kind == "select" then
    local label = type(node.values) == "table" and node.values[value] or nil
    if helpers.isSecret(label) then
      return tostring(value)
    end
    if type(label) ~= "nil" and tostring(label) ~= tostring(value) then
      return tostring(value) .. " (" .. tostring(label) .. ")"
    end
    return tostring(value)
  end
  if kind == "multiselect" and type(value) == "table" then
    local chosen = {}
    local keys = valueKeys(node)
    for index = 1, #keys do
      local entry = value[keys[index]]
      if helpers.isSecret(entry) then
        return "(secret value)"
      end
      if entry == true then
        chosen[#chosen + 1] = tostring(keys[index])
      end
    end
    if #chosen == 0 then
      return "(none)"
    end
    return table.concat(chosen, ", ")
  end
  if kind == "color" and type(value) == "table" then
    if
      helpers.isSecret(value.r)
      or helpers.isSecret(value.g)
      or helpers.isSecret(value.b)
      or helpers.isSecret(value.a)
    then
      return "(secret value)"
    end
    local text = string.format("%.2f %.2f %.2f", value.r or 0, value.g or 0, value.b or 0)
    if type(value.a) ~= "nil" then
      text = text .. string.format(" %.2f", value.a)
    end
    return text
  end
  if kind == "keybinding" and value == "" then
    return "(unbound)"
  end
  return tostring(value)
end

---Read a boolean flag of the addon's tree that `Describe` passes through as
---the addon wrote it (`tristate`, `confirm`). OptionsKit checks only its type,
---so the flag may be a secret boolean, which cannot be tested for truth or
---compared with `true` inside CommandKit. A secret flag answers `whenSecret`,
---chosen per flag as the safe reading; anything but a boolean answers `false`.
---@param value any
---@param whenSecret boolean
---@return boolean
local function readTreeFlag(value, whenSecret)
  if type(value) ~= "boolean" then
    return false
  end
  if helpers.isSecret(value) then
    return whenSecret
  end
  return value
end

---Find a `select` or `multiselect` key from what the user typed: the key
---itself (as text or as a number), else a label, ignoring case.
---@param node table
---@param word string
---@return any key
local function matchValueKey(node, word)
  local values = node.values or {}
  for key in next, values do
    if tostring(key) == word then
      return key
    end
  end
  local lowerWord = word:lower()
  for key, label in next, values do
    if not helpers.isSecret(label) and tostring(label):lower() == lowerWord then
      return key
    end
  end
  return nil
end

---The "expected one of" message of a `select` or `multiselect`.
---@param node table
---@return string
local function expectedKeys(node)
  return "expected one of: " .. helpers.joinValues(valueKeys(node), ", ")
end

---Parse a colour typed as `r g b [a]` in 0..1 or as `#rrggbb[aa]`.
---@param node table
---@param ... string
---@return table|nil colour
---@return string|nil problem
local function parseColour(node, ...)
  local first = ...
  local components
  -- The `#` is required, as `docs/API.md` documents: without it a word of
  -- six digits would be read as hex.
  local hex = type(first) == "string" and first:match("^#(%x+)$") or nil
  if hex ~= nil and select("#", ...) == 1 and (#hex == 6 or #hex == 8) then
    components = {}
    for index = 1, #hex / 2 do
      components[index] = tonumber(hex:sub(index * 2 - 1, index * 2), 16) / 255
    end
  else
    components = {}
    for index = 1, select("#", ...) do
      local number = tonumber((select(index, ...)))
      if number == nil then
        return nil, "expected r g b [a] between 0 and 1, or #rrggbb[aa]"
      end
      components[index] = number
    end
    if #components < 3 or #components > 4 then
      return nil, "expected r g b [a] between 0 and 1, or #rrggbb[aa]"
    end
  end
  local colour = { r = components[1], g = components[2], b = components[3] }
  if node.hasAlpha then
    colour.a = components[4] or 1
  elseif components[4] ~= nil then
    return nil, "this colour has no alpha"
  end
  return colour
end

-- What `set <path> toggle` answers when the current value (a `toggle`, or the
-- chosen key of a `multiselect`) is secret: flipping it would test the secret.
local SECRET_TOGGLE_PROBLEM = "the current value is secret; use on or off"

---Parse the words after `set <path>` into a value of the option's kind.
---@param node table
---@param ... string
---@return any value
---@return string|nil problem
local function parseValue(node, ...)
  local kind = node.kind
  local word = ...
  local wordCount = select("#", ...)
  if kind == "input" or kind == "keybinding" then
    local text = table.concat({ ... }, " ")
    if kind == "keybinding" and (text:lower() == "none" or text:lower() == "unbound") then
      return ""
    end
    return text
  end
  if kind == "color" then
    return parseColour(node, ...)
  end
  if word == nil then
    if kind == "toggle" then
      return nil, "expected on, off or toggle"
    end
    if kind == "range" then
      return nil, "expected a number"
    end
    return nil, expectedKeys(node)
  end
  if kind == "toggle" then
    local lowerWord = word:lower()
    if wordCount > 1 then
      return nil, "expected on, off or toggle"
    end
    if lowerWord == "toggle" then
      if helpers.isSecret(node.value) then
        return nil, SECRET_TOGGLE_PROBLEM
      end
      return not node.value
    end
    -- A secret `tristate` reads as absent: `default` is not offered.
    if readTreeFlag(node.tristate, false) and lowerWord == "default" then
      return nil
    end
    local value = helpers.BOOLEAN_WORDS[lowerWord]
    if value == nil then
      return nil, "expected on, off or toggle"
    end
    return value
  end
  if kind == "range" then
    local number = tonumber(word)
    if number == nil or wordCount > 1 then
      return nil, "expected a number"
    end
    return number
  end
  if kind == "select" then
    local key = matchValueKey(node, table.concat({ ... }, " "))
    if key == nil then
      return nil, expectedKeys(node)
    end
    return key
  end
  -- multiselect: `<key> on|off|toggle`
  local key = matchValueKey(node, word)
  if key == nil then
    return nil, expectedKeys(node)
  end
  local stateWord = select(2, ...)
  local current = type(node.value) == "table" and node.value or {}
  local enabled
  if type(stateWord) == "string" and stateWord:lower() == "toggle" then
    local chosen = current[key]
    if helpers.isSecret(chosen) then
      return nil, SECRET_TOGGLE_PROBLEM
    end
    enabled = chosen ~= true
  elseif type(stateWord) == "string" then
    enabled = helpers.BOOLEAN_WORDS[stateWord:lower()]
  end
  if enabled == nil or wordCount > 2 then
    return nil, "expected <key> on|off|toggle"
  end
  local value = {}
  for existingKey, isChosen in next, current do
    value[existingKey] = isChosen
  end
  value[key] = enabled
  return value
end

---One `list` line for a child node.
---@param node table
---@return string|nil
local function listLine(node)
  local kind = node.kind
  local line
  if kind == "group" then
    line = node.path .. " - " .. tostring(node.name) .. " (group)"
  elseif kind == "execute" then
    line = node.path .. " - " .. tostring(node.name) .. " (exec)"
  elseif VALUE_KINDS[kind] == true then
    line = node.path .. " = " .. formatValue(node, node.value) .. " - " .. tostring(node.name)
  else
    return nil
  end
  if node.disabled == true then
    line = line .. " (disabled)"
  end
  return line
end

---Refuse a node that is not a value option, or is disabled.
---@param context CommandKit.Context
---@param node table
---@return boolean usable
local function ensureValueOption(context, node)
  if node.kind == "execute" then
    helpers.contextFail(context, '"' .. node.path .. '" is a button; use exec')
    return false
  end
  if VALUE_KINDS[node.kind] ~= true then
    helpers.contextFail(context, '"' .. node.path .. '" has no value')
    return false
  end
  return true
end

-- Handlers -------------------------------------------------------------------

---Build the sub-command handlers of a bound command.
---@param tree table
---@return table handlers
local function newOptionHandlers(tree)
  local handlers = {}

  ---Print a refusal the tree returned. `validate` may answer with anything:
  ---a message that is secret, or empty once converted with `tostring`, is
  ---replaced by `fallback` rather than making `Fail` raise inside this
  ---handler.
  ---@param context CommandKit.Context
  ---@param message any
  ---@param fallback string
  local function failWithRefusal(context, message, fallback)
    if helpers.isSecret(message) then
      message = fallback
    else
      message = tostring(message)
      if message == "" then
        message = fallback
      end
    end
    helpers.contextFail(context, message)
  end

  function handlers.get(context, path)
    local node = findOption(context, tree, path, false)
    if node == nil or not ensureValueOption(context, node) then
      return
    end
    helpers.contextPrint(context, node.path .. " = " .. formatValue(node, node.value))
  end

  function handlers.set(context, path, ...)
    local node = findOption(context, tree, path, false)
    if node == nil or not ensureValueOption(context, node) then
      return
    end
    if node.disabled == true then
      helpers.contextFail(context, '"' .. node.path .. '" is disabled')
      return
    end
    local value, problem = parseValue(node, ...)
    if problem ~= nil then
      helpers.contextFail(context, problem)
      return
    end
    local valid, message = tree:Validate(node.path, value)
    if not valid then
      failWithRefusal(context, message, "refused by validate")
      return
    end
    local written, refusal = tree:Set(node.path, value)
    if not written then
      failWithRefusal(context, refusal, "refused by validate")
      return
    end
    helpers.contextPrint(context, node.path .. " = " .. formatValue(node, tree:Get(node.path)))
  end

  function handlers.reset(context, path)
    local node = findOption(context, tree, path, false)
    if node == nil or not ensureValueOption(context, node) then
      return
    end
    if node.disabled == true then
      helpers.contextFail(context, '"' .. node.path .. '" is disabled')
      return
    end
    if type(node.bind) == "nil" then
      helpers.contextFail(context, '"' .. node.path .. '" has no default to reset to')
      return
    end
    local value = tree:Reset(node.path)
    helpers.contextPrint(context, node.path .. " = " .. formatValue(node, value))
  end

  function handlers.list(context, path)
    local node = findOption(context, tree, path, true)
    if node == nil then
      return
    end
    if node.kind ~= "group" then
      local line = listLine(node)
      if line ~= nil then
        helpers.contextPrint(context, line)
      end
      -- `Describe` has called a `desc` function already; its string may
      -- be secret, and `Print` would refuse it.
      local desc = node.desc
      if type(desc) == "string" then
        if helpers.isSecret(desc) then
          helpers.contextPrint(context, "(secret value)")
        else
          helpers.contextPrint(context, desc)
        end
      end
      if node.kind == "select" or node.kind == "multiselect" then
        helpers.contextPrint(context, "values: " .. helpers.joinValues(valueKeys(node), ", "))
      end
      return
    end
    local printed = 0
    local children = node.children or {}
    for index = 1, #children do
      local child = children[index]
      if child.hidden ~= true then
        local line = listLine(child)
        if line ~= nil then
          helpers.contextPrint(context, line)
          printed = printed + 1
        end
      end
    end
    if printed == 0 then
      helpers.contextPrint(context, "(no options)")
    end
  end

  function handlers.exec(context, path, confirmation)
    local node = findOption(context, tree, path, false)
    if node == nil then
      return
    end
    if node.kind ~= "execute" then
      helpers.contextFail(context, '"' .. node.path .. '" is not a button')
      return
    end
    if node.disabled == true then
      helpers.contextFail(context, '"' .. node.path .. '" is disabled')
      return
    end
    local confirm = node.confirm
    -- A secret boolean `confirm` asks: running a button the addon may
    -- have marked for confirmation is the surprise to avoid.
    local asks = type(confirm) == "string" or readTreeFlag(confirm, true)
    if asks and confirmation ~= "confirm" then
      if type(confirm) == "string" and not helpers.isSecret(confirm) then
        helpers.contextPrint(context, confirm)
      end
      helpers.contextPrint(
        context,
        "Type "
          .. helpers.contextGetCommandPath(context)
          .. " "
          .. node.path
          .. " confirm to run it."
      )
      return
    end
    tree:Execute(node.path)
  end

  return handlers
end

-- Completion -----------------------------------------------------------------

---A completion function offering the option paths `accepts` admits.
---@param tree table
---@param accepts fun(kind: string): boolean
---@return function
local function newPathCompleter(tree, accepts)
  return function(_, _, position)
    if position ~= 1 then
      return nil
    end
    local paths = {}
    tree:Walk(function(path, kind)
      if accepts(kind) and not tree:IsHidden(path) then
        paths[#paths + 1] = path
      end
    end)
    return paths
  end
end

---@param kind string
---@return boolean
local function acceptsValue(kind)
  return VALUE_KINDS[kind] == true
end

---@param kind string
---@return boolean
local function acceptsListable(kind)
  return kind == "group" or kind == "execute" or VALUE_KINDS[kind] == true
end

---@param kind string
---@return boolean
local function acceptsExecute(kind)
  return kind == "execute"
end

-- Path syntax ----------------------------------------------------------------
--
-- AceConfigCmd-3.0's command line: `/cmd group option value`. Each word
-- selects a child of the current group by key, without case, until a
-- non-group is reached; the rest of the line is the value. (AceConfigCmd also
-- lets `_` stand for a space in a key; OptionsKit keys are identifiers, so
-- they never hold one.) A word holding a dot is also accepted as a whole
-- path (`/cmd frame.scale 1.2`), which is how the messages the verbs print
-- name an option.

---A resolver for one bound tree: a function that maps lower-cased words to
---the option they name. It looks each step up in an index of the tree's paths
---by their lower-case spelling, built with one `tree:Walk` on the first line
---typed and kept with the binding, so a typed line costs a table read per
---word. A tree that can change shape (OptionsKit's `OnStructureChanged`)
---drops the index when it does, and the next line builds it again. Two keys
---that differ only in case resolve to the first in display order.
---@param tree table
---@return fun(words: string[], count: integer): integer, string|nil, string|nil resolve matched word count, path and kind
local function newPathResolver(tree)
  -- `paths` maps a lower-case path to the tree's own; `kinds` a path to its kind.
  ---@type { paths: table<string, string>|false, kinds: table<string, string>|false, watched: boolean }
  local index = { paths = false, kinds = false, watched = false }

  ---Forget the index; the next line builds it again.
  local function forget()
    index.paths = false
    index.kinds = false
  end

  ---Build the index, and watch the tree's shape once when it can change.
  ---@return table<string, string> paths
  ---@return table<string, string> kinds
  local function build()
    local paths, kinds = {}, {}
    tree:Walk(function(path, kind)
      local lower = path:lower()
      if paths[lower] == nil then
        paths[lower] = path
      end
      kinds[path] = kind
    end)
    index.paths = paths
    index.kinds = kinds
    if not index.watched and type(tree.OnStructureChanged) == "function" then
      index.watched = pcall(tree.OnStructureChanged, tree, forget)
    end
    return paths, kinds
  end

  return function(words, count)
    local paths, kinds = index.paths, index.kinds
    if not paths or not kinds then
      paths, kinds = build()
    end
    local matched, path, kind = 0, nil, nil
    local lowerPath = nil
    for position = 1, count do
      local candidate = words[position]
      if lowerPath ~= nil then
        candidate = lowerPath .. "." .. candidate
      end
      local found = paths[candidate]
      if found == nil then
        break
      end
      matched, path, kind, lowerPath = position, found, kinds[found], candidate
      if kind ~= "group" then
        break
      end
    end
    return matched, path, kind
  end
end

---Fill `words` with the lower-cased `...`, clearing what an earlier line left.
---@param words string[]
---@param ... string
---@return integer count
local function fillWords(words, ...)
  local count = select("#", ...)
  for index = 1, count do
    words[index] = string.lower((select(index, ...)))
  end
  for index = count + 1, #words do
    words[index] = nil
  end
  return count
end

---The root handler of a command bound with the path syntax.
---@param handlers table the verb handlers of the binding
---@param resolve function the binding's resolver
---@param words string[] the binding's word buffer
---@param onEmpty function|nil run for an empty line instead of listing the root
---@return function handler
local function newPathHandler(handlers, resolve, words, onEmpty)
  return function(context, ...)
    local count = fillWords(words, ...)
    if count == 0 then
      if onEmpty ~= nil then
        onEmpty(context)
      else
        handlers.list(context, nil)
      end
      return
    end
    local matched, path, kind = resolve(words, count)
    if matched == 0 then
      helpers.contextFail(context, 'unknown option "' .. (select(1, ...)) .. '"')
      helpers.contextUsage(context)
      return
    end
    if kind == "group" then
      if matched < count then
        helpers.contextFail(
          context,
          'unknown option "' .. (select(matched + 1, ...)) .. '" in "' .. path .. '"'
        )
        return
      end
      handlers.list(context, path)
      return
    end
    if kind == "execute" then
      handlers.exec(context, path, (select(matched + 1, ...)))
      return
    end
    if matched == count then
      if kind == "toggle" then
        handlers.set(context, path, "toggle")
      else
        handlers.get(context, path)
      end
      return
    end
    handlers.set(context, path, select(matched + 1, ...))
  end
end

---The root handler of a command bound with the verbs and an `onEmpty`: the
---empty line runs `onEmpty`, any other first word is an unknown verb.
---@param onEmpty function
---@return function handler
local function newEmptyLineHandler(onEmpty)
  return function(context, ...)
    if select("#", ...) == 0 then
      onEmpty(context)
      return
    end
    helpers.contextFail(context, 'unknown sub-command "' .. (select(1, ...)) .. '"')
    helpers.contextUsage(context)
  end
end

---The keys of the visible children of the group at `path` (the root for
---`nil`), as the path syntax accepts them.
---@param tree table
---@param path string|nil
---@return string[]
local function childKeys(tree, path)
  local keys = {}
  local prefix = path ~= nil and (path .. ".") or ""
  tree:Walk(function(childPath)
    if childPath:sub(1, #prefix) ~= prefix then
      return
    end
    local key = childPath:sub(#prefix + 1)
    if key:find(".", 1, true) == nil and not tree:IsHidden(childPath) then
      keys[#keys + 1] = key
    end
  end)
  return keys
end

---The completion function of a command bound with the path syntax: the keys
---of the group the earlier words reached, or the values of the option they
---named.
---@param tree table
---@param resolve function
---@param words string[]
---@return function complete
local function newPathSyntaxCompleter(tree, resolve, words)
  return function(context, partial)
    local raw = context:GetRawText()
    local before = raw:sub(1, #raw - #partial)
    local count = 0
    for word in before:gmatch("%S+") do
      count = count + 1
      words[count] = word:lower()
    end
    for index = count + 1, #words do
      words[index] = nil
    end
    local matched, path, kind = resolve(words, count)
    if matched ~= count then
      return nil
    end
    if count == 0 or kind == "group" then
      return childKeys(tree, path)
    end
    if kind == "toggle" then
      return { "on", "off" }
    end
    if kind == "select" or kind == "multiselect" then
      local node = tree:DescribeOption(path)
      if node ~= nil then
        return valueKeys(node)
      end
    end
    return nil
  end
end

---Build the command spec `BindOptions` registers.
---@param tree table
---@param settings table `description`, `syntax` and `onEmpty`, already checked
---@return CommandKit.CommandSpec
local function newOptionsSpec(tree, settings)
  local S = helpers.SchemaKit
  local handlers = newOptionHandlers(tree)
  local valuePaths = newPathCompleter(tree, acceptsValue)
  local spec = {
    description = settings.description,
    subcommands = {
      get = {
        handler = handlers.get,
        arguments = { S.string() },
        usage = "<path>",
        description = "Print an option's value.",
        complete = valuePaths,
      },
      set = {
        handler = handlers.set,
        usage = "<path> <value...>",
        description = "Change an option.",
        complete = valuePaths,
      },
      reset = {
        handler = handlers.reset,
        arguments = { S.string() },
        usage = "<path>",
        description = "Restore an option's default.",
        complete = valuePaths,
      },
      list = {
        handler = handlers.list,
        arguments = { S.optional(S.string()) },
        usage = "[path]",
        description = "List the options of a group, or describe one option.",
        complete = newPathCompleter(tree, acceptsListable),
      },
      exec = {
        handler = handlers.exec,
        arguments = { S.string(), S.optional(S.string({ oneOf = { "confirm" } })) },
        usage = "<path> [confirm]",
        description = "Run a button.",
        complete = newPathCompleter(tree, acceptsExecute),
      },
    },
  }
  if settings.syntax == "path" then
    local resolve = newPathResolver(tree)
    local words = {}
    spec.handler = newPathHandler(handlers, resolve, words, settings.onEmpty)
    spec.usage = "[group...] [option] [value...]"
    spec.complete = newPathSyntaxCompleter(tree, resolve, words)
  elseif settings.onEmpty ~= nil then
    spec.handler = newEmptyLineHandler(settings.onEmpty)
  end
  return spec
end

-- Scope methods --------------------------------------------------------------

---Check `BindOptions`' option table, raising at the caller.
---@param options any
---@param methodName string
---@return table settings
local function readBindOptions(options, methodName)
  local settings = { description = nil, syntax = "verbs", onEmpty = nil }
  if type(options) == "nil" then
    return settings
  end
  if type(options) ~= "table" then
    error(methodName .. " options must be a table", 3)
  end
  helpers.refuseUnknownFields(options, BIND_OPTION_FIELDS, methodName .. " options", 4)
  local description = rawget(options, "description")
  helpers.validateOptionalString(description, methodName .. " options.description", 4)
  settings.description = description
  local syntax = rawget(options, "syntax")
  if syntax ~= nil then
    if helpers.isSecret(syntax) or type(syntax) ~= "string" or not SYNTAXES[syntax] then
      error(methodName .. ' options.syntax must be "verbs" or "path"', 3)
    end
    settings.syntax = syntax
  end
  local onEmpty = rawget(options, "onEmpty")
  if onEmpty ~= nil and type(onEmpty) ~= "function" then
    error(methodName .. " options.onEmpty must be a function", 3)
  end
  settings.onEmpty = onEmpty
  return settings
end

---Register `/commandName` with `get`, `set`, `reset`, `list` and `exec`
---sub-commands over an OptionsKit tree, and with `options.syntax = "path"`
---the `/commandName group option value` line too.
---@param self CommandKit.Scope
---@param tree table an OptionsKit tree handle
---@param commandName string
---@param options CommandKit.BindOptions?
---@return true|nil registered
---@return "taken"|"emote"|"full"|nil reason
local function scopeBindOptions(self, tree, commandName, options)
  local methodName = "CommandKit.Scope:BindOptions"
  helpers.validateScope(self, methodName, 3)
  helpers.ensureOpen(self, methodName, 3)
  local OptionsKit = helpers.findOptional("optionsKit", OPTIONSKIT_API)
  if OptionsKit == nil then
    error(methodName .. " requires OptionsKit API 1", 2)
  end
  local metatable = helpers.readMetatable(tree)
  local treeIndex = nil
  if type(metatable) == "table" then
    treeIndex = rawget(metatable, "__index")
  end
  if type(treeIndex) ~= "table" or treeIndex ~= rawget(OptionsKit, "Tree") then
    error(methodName .. " tree must be an OptionsKit tree", 2)
  end
  local settings = readBindOptions(options, methodName)
  local registered, reason =
    helpers.registerCommand(self, commandName, newOptionsSpec(tree, settings), methodName, 3)
  if registered then
    local bound = rawget(self, "_bound")
    if bound == nil then
      bound = {}
      rawset(self, "_bound", bound)
    end
    rawset(bound, commandName:lower(), tree)
  end
  return registered, reason
end

---The tree `/name` was bound to with `BindOptions`, or `nil`.
---@param self CommandKit.Scope
---@param name string
---@return table|nil tree
local function scopeGetBoundTree(self, name)
  helpers.validateScope(self, "CommandKit.Scope:GetBoundTree", 3)
  helpers.validateString(name, "CommandKit.Scope:GetBoundTree name", 3)
  local bound = rawget(self, "_bound")
  if bound == nil then
    return nil
  end
  return rawget(bound, name:lower())
end

-- Commit ---------------------------------------------------------------------

rawset(parts, PART_NAME, {
  revision = PART_REVISION,
  methods = {
    BindOptions = scopeBindOptions,
    GetBoundTree = scopeGetBoundTree,
  },
})
helpers.installPartMethods()

return CommandKit
