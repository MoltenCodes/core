-- MoltenCodes WidgetKit part Renderer
--
-- `RenderOptions`: OptionsKit trees rendered into WidgetKit containers, with
-- `childGroups` pages, and the rendering handle's methods.
--
-- Needs the WidgetKit core and the parts Containers, Text, Button, CheckBox, Slider, EditBox, Dropdown and ColorPicker. See `docs/API.md`, "Parts", and
-- `docs/INTERNALS.md`, "Parts", for how a part joins the core.

-- Constants ------------------------------------------------------------------

local PART_NAME = "Renderer"
local PART_REVISION = 1
local REQUIRED_REGISTRY_API = 2
local CORE_PACKAGE, CORE_API = "widgetKit", 1
local OPTIONAL_OPTIONSKIT_API = 1
local OPTIONAL_SCHEDULERKIT_API = 1
local OPTIONAL_MEDIAKIT_API = 1

-- Accepted option fields, as a set, so option validation allocates nothing.
local RENDER_OPTION_KEYS = { allowSecret = true, media = true, confirmText = true }

-- Core -----------------------------------------------------------------------

-- The shared MoltenCodes namespace is the one documented global handoff point between independently embedded copies.
-- selene: allow(global_usage)
local namespace = rawget(_G, "MoltenCodes")
local generations = type(namespace) == "table" and rawget(namespace, "Registries") or nil
local Registry = type(generations) == "table" and rawget(generations, REQUIRED_REGISTRY_API) or nil
local WidgetKit = nil
if type(Registry) == "table" and type(rawget(Registry, "Get")) == "function" then
  WidgetKit = Registry:Get(CORE_PACKAGE, CORE_API)
end
local state = type(WidgetKit) == "table" and rawget(WidgetKit, "_state") or nil
if
  type(state) ~= "table"
  or type(rawget(state, "parts")) ~= "table"
  or type(rawget(state, "helpers")) ~= "table"
then
  error("MoltenCodes WidgetKit part Renderer requires WidgetKit API 1 to be loaded first", 2)
end
---@cast WidgetKit WidgetKit

local installed = rawget(rawget(state, "parts"), PART_NAME)
if
  type(installed) == "table"
  and type(installed.revision) == "number"
  and installed.revision >= PART_REVISION
then
  -- An equal or newer revision of this part already serves every widget.
  return WidgetKit
end

-- The core's helpers and shared tables, assigned by `bind` from
-- `state.helpers`. A newer core calls `bind` again, so this part runs its
-- helpers from then on (`docs/INTERNALS.md`, "Parts").
local RENDERING_METATABLE
local RenderingPrototype
local WEAK_KEYS
local WidgetBase
local findPackage
local isReleasingRecord
local isSecret
local performLayout
local records
local refuseSecret
local reportError
local validateFacade
local validateName
local validateOptionKeys
local parts

---Assign the core helpers this part uses.
---@param helpers table the core's `state.helpers`
local function bind(helpers)
  RENDERING_METATABLE = helpers.RENDERING_METATABLE
  RenderingPrototype = helpers.RenderingPrototype
  WEAK_KEYS = helpers.WEAK_KEYS
  WidgetBase = helpers.WidgetBase
  findPackage = helpers.findPackage
  isReleasingRecord = helpers.isReleasingRecord
  isSecret = helpers.isSecret
  performLayout = helpers.performLayout
  records = helpers.records
  refuseSecret = helpers.refuseSecret
  reportError = helpers.reportError
  validateFacade = helpers.validateFacade
  validateName = helpers.validateName
  validateOptionKeys = helpers.validateOptionKeys
  parts = helpers.parts
end

bind(rawget(state, "helpers"))

---A global string the client localises, or `fallback` outside the client.
---@param name string
---@param fallback string
---@return string
local function clientText(name, fallback)
  -- selene: allow(global_usage)
  local value = rawget(_G, name)
  if type(value) == "string" and not isSecret(value) then
    return value
  end
  return fallback
end

-- Extensions -----------------------------------------------------------------
--
-- Four registries a later part fills to add to the renderer without editing
-- it. They live in the core's state, so they outlive an upgrade of this part,
-- and each entry carries the revision of the part that registered it: a
-- registration replaces an entry only with an equal or higher revision.
--
--   kinds        option kind -> `{ type, configure, apply? }`: the widget type
--                drawing the kind, `configure(rendering, record, node)`
--                returning whether it succeeded, and `apply(record, value,
--                disabled)` showing a value the tree answered
--   decorators   name -> `{ decorate?, refresh? }`, called in registration
--                order after an option's widget is built
--                (`decorate(rendering, record, node)`) and after every
--                refresh (`refresh(rendering, record)`); a raising one is
--                reported, never raised
--   pageStyles   `childGroups` value -> `{ render }`: `render(rendering, node,
--                parent)` draws the group's children and returns whether it
--                succeeded, in place of the built-in pages
--   confirm      the one provider asked before a confirmed `execute` runs:
--                `{ ask }`, `ask(rendering, record, question, proceed)`;
--                without one the renderer asks inline ("click again")

---@type { kinds: table, decorators: table, decoratorOrder: string[], pageStyles: table, confirm: table|false }
local extensions = rawget(state, "rendererExtensions")
if type(extensions) ~= "table" then
  extensions =
    { kinds = {}, decorators = {}, decoratorOrder = {}, pageStyles = {}, confirm = false }
  rawset(state, "rendererExtensions", extensions)
end

local EXTENSION_REGISTRIES = { kinds = true, decorators = true, pageStyles = true, confirm = true }

---Register a renderer extension for a part; see "Extensions".
---@param registry string `"kinds"`, `"decorators"`, `"pageStyles"` or `"confirm"`
---@param key string? the kind, decorator name or `childGroups` value; ignored for `"confirm"`
---@param entry table the extension, with the registering part's `revision`
---@return boolean registered `false` when a higher revision holds the slot
local function registerExtension(registry, key, entry)
  if EXTENSION_REGISTRIES[registry] ~= true then
    error(
      "WidgetKit renderer extension registry must be kinds, decorators, pageStyles or confirm",
      2
    )
  end
  if type(entry) ~= "table" or type(entry.revision) ~= "number" then
    error("WidgetKit renderer extension must be a table with a revision", 2)
  end
  if registry == "confirm" then
    local current = extensions.confirm
    if current and current.revision > entry.revision then
      return false
    end
    extensions.confirm = entry
    return true
  end
  if type(key) ~= "string" or key == "" then
    error("WidgetKit renderer extension key must be a non-empty string", 2)
  end
  local slots = extensions[registry] ---@type table
  local current = slots[key]
  if current ~= nil and current.revision > entry.revision then
    return false
  end
  if registry == "decorators" and current == nil then
    local order = extensions.decoratorOrder
    order[#order + 1] = key
  end
  slots[key] = entry
  return true
end

---Call every decorator's `phase` function, reporting what raises.
---@param phase string `"decorate"` or `"refresh"`
---@param rendering table
---@param record table
---@param node table?
local function runDecorators(phase, rendering, record, node)
  local order = extensions.decoratorOrder
  for index = 1, #order do
    local decorator = extensions.decorators[order[index]]
    local run = decorator ~= nil and decorator[phase] or nil
    if type(run) == "function" then
      local ok, failure = pcall(run, rendering, record, node)
      if not ok then
        reportError(failure)
      end
    end
  end
end

-- Renderer -------------------------------------------------------------------

-- The renderer lives in its own block; only its entry point is visible below.
local renderOptions

do --
  -- `RenderOptions` walks `tree:Describe()` once and creates one widget per
  -- visible node in display order. Every read afterwards goes through
  -- `tree:Get`, `tree:IsDisabled` and `tree:IsHidden`, which allocate nothing;
  -- every write goes through `tree:Validate` then `tree:Set`. A refusal is shown
  -- in a Label inserted right below the widget. `tree:OnChange` refreshes the
  -- widgets in place, and rebuilds them only when a node was shown or hidden.

  -- Which widget type draws each option kind.
  local NODE_WIDGET_TYPES = {
    group = "Group",
    toggle = "CheckBox",
    range = "Slider",
    select = "Dropdown",
    multiselect = "Group",
    input = "EditBox",
    color = "ColorPicker",
    keybinding = "Button",
    execute = "Button",
    header = "Heading",
    description = "Label",
  }

  -- The option kinds that carry a value `tree:Get` reads.
  local VALUE_KINDS = {
    toggle = true,
    range = true,
    select = true,
    multiselect = true,
    input = true,
    color = true,
    keybinding = true,
  }

  -- What a widget shows instead of a secret value it was not allowed to show.
  local SECRET_PLACEHOLDER = "<secret value>"

  ---Whether a flag read from the tree or its description is exactly `true`.
  ---The tree is the consumer's (its `disabled` and `hidden` functions, its
  ---renderer hints), so a flag may be secret; a secret one is never compared
  ---and counts as not set.
  ---@param value any
  ---@return boolean
  local function isTrueFlag(value)
    return not isSecret(value) and value == true
  end

  -- Font objects for `description` options by `fontSize`.
  local DESCRIPTION_FONTS = {
    small = "GameFontHighlightSmall",
    medium = "GameFontHighlight",
    large = "GameFontHighlightLarge",
  }

  -- Seconds an armed `execute` confirmation waits for its second click.
  local CONFIRM_SECONDS = 5

  -- The question an `execute` option with `confirm = true` asks.
  local DEFAULT_CONFIRM_TEXT = "Click again to confirm."

  -- The colour of an inline refusal: red, green, blue. One table rather than
  -- three locals, because the file is at Lua's 200-local limit.
  local MESSAGE_COLOR = { 1, 0.3, 0.3 }

  ---@param rendering any
  ---@param methodName string qualified public method name, used in the argument error
  ---@param level integer stack level the failure is reported at
  local function validateRendering(rendering, methodName, level)
    if type(rendering) ~= "table" or getmetatable(rendering) ~= RENDERING_METATABLE then
      error(methodName .. " must be called on a WidgetKit rendering", level)
    end
  end

  ---Remember the acquire serial `widget` has now, so the rendering can tell
  ---its own use of the widget from a later one after the widget went back to
  ---its pool and was acquired by someone else.
  ---@param rendering table
  ---@param widget table
  local function stamp(rendering, widget)
    rendering._serials[widget] = records[widget].serial
  end

  ---Whether `widget` is still the active widget this rendering acquired (or,
  ---for the container, was given).
  ---@param rendering table
  ---@param widget table?
  ---@return boolean
  local function owns(rendering, widget)
    if widget == nil then
      return false
    end
    local record = records[widget]
    return record ~= nil and record.active == true and record.serial == rendering._serials[widget]
  end

  ---Create a widget for the renderer, remembering the first failure.
  ---@param rendering table
  ---@param typeName string
  ---@return table? widget
  local function renderCreate(rendering, typeName)
    local widget, reason = WidgetKit:Create(typeName)
    if widget == nil then
      if rendering._failure == nil then
        rendering._failure = "could not create a " .. typeName .. " widget: " .. tostring(reason)
      end
      return nil
    end
    stamp(rendering, widget)
    return widget
  end

  ---Whether the rendering may still act: not released, and its container still
  ---the one it was given. A rendering whose container went away is released
  ---on the spot, so it never touches widgets it no longer owns.
  ---@param rendering table
  ---@return boolean
  local function renderingAlive(rendering)
    if rendering._released then
      return false
    end
    if not owns(rendering, rendering._container) then
      RenderingPrototype.Release(rendering)
      return false
    end
    return true
  end

  ---Add a rendered widget to `parent`, remembering the ones added to the
  ---container the rendering was given, which it releases itself.
  ---@param rendering table
  ---@param parent table
  ---@param widget table
  ---@param beforeWidget table?
  ---@return boolean added
  local function renderAdd(rendering, parent, widget, beforeWidget)
    local added, reason = parent:AddChild(widget, beforeWidget)
    if not added then
      WidgetKit:Release(widget)
      if rendering._failure == nil then
        rendering._failure = "could not add a widget to its container: " .. tostring(reason)
      end
      return false
    end
    if parent == rendering._container then
      local widgets = rendering._widgets
      widgets[#widgets + 1] = widget
    end
    return true
  end

  ---Forget `widget` in the list of widgets the rendering added to its container.
  ---@param rendering table
  ---@param widget table
  local function renderForget(rendering, widget)
    local widgets = rendering._widgets
    for index = #widgets, 1, -1 do
      if widgets[index] == widget then
        table.remove(widgets, index)
        return
      end
    end
  end

  ---Text that can be shown for a message, which may be any error value.
  ---@param message any
  ---@return string|number
  local function messageText(message)
    if isSecret(message) then
      return SECRET_PLACEHOLDER
    end
    if type(message) == "string" or type(message) == "number" then
      return message
    end
    return tostring(message)
  end

  ---Show `message` in a Label right below the record's widget.
  ---@param rendering table
  ---@param record table
  ---@param message any
  local function showMessage(rendering, record, message)
    local text = messageText(message)
    local label = record.messageLabel ---@type any
    if owns(rendering, label) then
      label:SetText(text)
      local parent = record.parent
      if owns(rendering, parent) then
        parent:PerformLayout()
      end
      return
    end
    record.messageLabel = nil

    local parent = record.parent
    if not owns(rendering, parent) or not owns(rendering, record.widget) then
      return
    end
    label = WidgetKit:Create("Label") --[[@as WidgetKit.Label?]]
    if label == nil then
      -- Nowhere to show it: the user still learns through the error frame.
      reportError(message)
      return
    end
    stamp(rendering, label)
    label:SetFullWidth(true)
    label:SetColor(MESSAGE_COLOR[1], MESSAGE_COLOR[2], MESSAGE_COLOR[3])
    label:SetText(text)

    local siblings = parent:GetChildren()
    local beforeWidget = nil
    for index = 1, #siblings do
      if siblings[index] == record.widget then
        beforeWidget = siblings[index + 1]
        break
      end
    end
    if not renderAdd(rendering, parent, label, beforeWidget) then
      rendering._failure = nil
      reportError(message)
      return
    end
    record.messageLabel = label
  end

  ---Remove the record's inline message, if it has one.
  ---@param rendering table
  ---@param record table
  local function clearMessage(rendering, record)
    local label = record.messageLabel
    if label == nil then
      return
    end
    record.messageLabel = nil
    if owns(rendering, label) then
      renderForget(rendering, label)
      WidgetKit:Release(label)
      local parent = record.parent
      if owns(rendering, parent) then
        parent:PerformLayout()
      end
    end
  end

  ---Whether a value read back from the tree is a table that may be indexed.
  ---@param value any
  ---@return boolean
  local function isReadableTable(value)
    return type(value) == "table" and not isSecret(value)
  end

  ---Show `value` and the disabled state on the record's widgets.
  ---
  ---A secret value is never inspected or handed to a widget: every kind shows
  ---a placeholder or its default and is disabled, since the user cannot edit
  ---what cannot be read. An `input` option shows the placeholder whatever
  ---`allowSecret` says, because the client's edit box refuses a secret from
  ---addon code (measured on Retail 12.1.0 b69933).
  ---@param record table
  ---@param value any
  ---@param disabled boolean
  local function applyState(record, value, disabled)
    local kind = record.kind
    local widget = record.widget
    record.disabled = disabled

    if not VALUE_KINDS[kind] then
      widget:SetDisabled(disabled)
      return
    end

    local secret = isSecret(value)
    if kind == "multiselect" then
      widget:SetDisabled(disabled)
      local readable = not secret and isReadableTable(value)
      local keys, boxes = record.keys, record.checkBoxes
      for index = 1, #keys do
        local checked = false
        if readable then
          local entry = value[keys[index]]
          checked = not isSecret(entry) and entry == true
        end
        boxes[index]:SetValue(checked)
        boxes[index]:SetDisabled(disabled or secret)
      end
      return
    end

    if secret then
      if kind == "input" then
        widget:SetText(SECRET_PLACEHOLDER)
      elseif kind == "keybinding" then
        widget:SetText(record.name .. ": " .. SECRET_PLACEHOLDER)
      end
      widget:SetDisabled(true)
      return
    end

    if kind == "toggle" then
      if type(value) == "nil" and record.triState then
        widget:SetValue(nil)
      else
        widget:SetValue(value == true)
      end
    elseif kind == "range" then
      if type(value) == "number" and value == value then
        widget:SetValue(value)
      end
    elseif kind == "select" then
      if type(value) == "string" or type(value) == "number" then
        widget:SetValue(value)
      else
        widget:SetValue(nil)
      end
    elseif kind == "input" then
      if type(value) == "string" or type(value) == "number" then
        widget:SetText(value)
      else
        widget:SetText("")
      end
    elseif kind == "color" then
      if isReadableTable(value) then
        local red, green, blue, alpha = value.r, value.g, value.b, value.a
        if
          type(red) == "number"
          and type(green) == "number"
          and type(blue) == "number"
          and not isSecret(red)
          and not isSecret(green)
          and not isSecret(blue)
        then
          if type(alpha) ~= "number" or isSecret(alpha) then
            alpha = 1
          end
          widget:SetColor(red, green, blue, alpha)
        end
      end
    elseif kind == "keybinding" then
      local key = clientText("NOT_BOUND", "Not bound")
      if type(value) == "string" and value ~= "" then
        key = value
      end
      widget:SetText(record.name .. ": " .. key)
    end
    widget:SetDisabled(disabled)
  end

  ---Read one record's value and state back from the tree.
  ---@param rendering table
  ---@param record table
  local function refreshRecord(rendering, record)
    if not owns(rendering, record.widget) then
      return
    end
    local tree = rendering._tree
    local value = nil
    if VALUE_KINDS[record.kind] then
      value = tree:Get(record.path)
    end
    -- A secret `disabled` answer greys the option out: the user cannot be
    -- offered what the tree will not say is enabled.
    local disabled = tree:IsDisabled(record.path)
    disabled = isSecret(disabled) or disabled == true
    local extension = record.extension
    if extension ~= nil and type(extension.apply) == "function" then
      extension.apply(record, value, disabled)
    else
      applyState(record, value, disabled)
    end
    if #extensions.decoratorOrder > 0 then
      runDecorators("refresh", rendering, record, nil)
    end
  end

  ---Run a refresh that `OnChange` asked for while a write was in progress.
  ---@param rendering table
  local function runPendingRefresh(rendering)
    if rendering._pending and rendering._busy == 0 and not rendering._released then
      rendering._pending = false
      RenderingPrototype.Refresh(rendering)
    end
  end

  ---Write `value` through the tree: `Validate`, then `Set`. A refusal becomes an
  ---inline message and the widget shows the stored value again.
  ---@param rendering table
  ---@param record table
  ---@param value any
  local function writeValue(rendering, record, value)
    if not renderingAlive(rendering) or not owns(rendering, record.widget) then
      return
    end
    local tree = rendering._tree
    rendering._busy = rendering._busy + 1
    -- A raising Validate or Set is shown and reported, never raised into the
    -- widget's script, and never leaves the rendering busy.
    local validated, ok, message = pcall(tree.Validate, tree, record.path, value)
    if not validated then
      ok, message = false, ok
      reportError(message)
    end
    -- `isTrueFlag`: a secret answer from `Validate` or `Set` is a refusal,
    -- never compared. The verdict is taken once and kept as a plain boolean.
    local accepted = isTrueFlag(ok)
    if accepted then
      local called, result, setMessage = pcall(tree.Set, tree, record.path, value)
      if not called then
        accepted, message = false, result
        reportError(result)
      elseif not isTrueFlag(result) then
        accepted, message = false, setMessage
      end
    end
    rendering._busy = rendering._busy - 1

    if accepted then
      clearMessage(rendering, record)
    else
      -- Not `message or "refused"`: a secret message is shown as the
      -- placeholder by `showMessage`, never tested as a boolean.
      if not isSecret(message) and not message then
        message = "refused"
      end
      showMessage(rendering, record, message)
      refreshRecord(rendering, record)
    end
    runPendingRefresh(rendering)
  end

  ---Write a `multiselect` option after one of its boxes changed: a new map of
  ---the checked keys.
  ---@param rendering table
  ---@param record table
  ---@param key any
  ---@param checked boolean?
  local function writeMultiselect(rendering, record, key, checked)
    if not renderingAlive(rendering) or not owns(rendering, record.widget) then
      return
    end
    local current = rendering._tree:Get(record.path)
    local readable = isReadableTable(current)
    local map = {}
    local keys = record.keys
    for index = 1, #keys do
      local entryKey = keys[index]
      local on
      if entryKey == key then
        on = checked == true
      elseif readable then
        local entry = current[entryKey]
        on = not isSecret(entry) and entry == true
      else
        on = false
      end
      if on then
        map[entryKey] = true
      end
    end
    writeValue(rendering, record, map)
  end

  ---Disarm an armed `execute` confirmation: cancel its timer and remove the
  ---question.
  ---@param rendering table
  ---@param record table
  local function disarmRecord(rendering, record)
    local job = record.disarmJob
    record.disarmJob = nil
    if job ~= nil and type(job.Cancel) == "function" then
      pcall(job.Cancel, job)
    end
    if record.armed then
      record.armed = false
      clearMessage(rendering, record)
    end
  end

  local runExecute

  ---Run an `execute` option. With `confirm`, the first click arms it and shows
  ---the question below the button; the second click runs it. An armed
  ---confirmation disarms itself after `CONFIRM_SECONDS` through SchedulerKit
  ---when it is registered, otherwise at the next `Refresh`.
  ---@param rendering table
  ---@param record table
  local function executeRecord(rendering, record)
    if not renderingAlive(rendering) or not owns(rendering, record.widget) then
      return
    end
    local confirm = record.confirm
    local provider = extensions.confirm
    if type(confirm) ~= "nil" and confirm ~= false and provider then
      local question = type(confirm) == "string" and confirm or rendering._confirmText
      provider.ask(rendering, record, question, function()
        if renderingAlive(rendering) and owns(rendering, record.widget) then
          runExecute(rendering, record)
        end
      end)
      return
    end
    if type(confirm) ~= "nil" and confirm ~= false and not record.armed then
      record.armed = true
      local question = type(confirm) == "string" and confirm or rendering._confirmText
      showMessage(rendering, record, question)
      local SchedulerKit = findPackage(Registry, "schedulerKit", OPTIONAL_SCHEDULERKIT_API)
      if type(SchedulerKit) == "table" and type(SchedulerKit.After) == "function" then
        record.disarmJob = SchedulerKit:After(CONFIRM_SECONDS, function()
          record.disarmJob = nil
          if not rendering._released and record.armed then
            disarmRecord(rendering, record)
          end
        end)
      end
      return
    end
    disarmRecord(rendering, record)
    runExecute(rendering, record)
  end

  ---Run an `execute` option, showing and reporting what raises.
  ---@param rendering table
  ---@param record table
  function runExecute(rendering, record)
    local tree = rendering._tree
    rendering._busy = rendering._busy + 1
    local ok, failure = pcall(tree.Execute, tree, record.path)
    rendering._busy = rendering._busy - 1
    if not ok then
      reportError(failure)
      showMessage(rendering, record, failure)
    end
    runPendingRefresh(rendering)
  end

  ---The keys of a `select` or `multiselect` node in display order: `sorting`
  ---when it has one, otherwise by label, then key.
  ---@param node table
  ---@return any[]
  local function orderedKeys(node)
    local values = node.values
    if type(values) ~= "table" then
      return {}
    end
    local sorting = node.sorting
    local keys = {}
    if type(sorting) == "table" then
      for index = 1, #sorting do
        if type(values[sorting[index]]) ~= "nil" then
          keys[#keys + 1] = sorting[index]
        end
      end
      return keys
    end
    for key in next, values do
      keys[#keys + 1] = key
    end
    table.sort(keys, function(first, second)
      local firstLabel, secondLabel = tostring(values[first]), tostring(values[second])
      if firstLabel ~= secondLabel then
        return firstLabel < secondLabel
      end
      if type(first) ~= type(second) then
        return type(first) == "number"
      end
      return first < second
    end)
    return keys
  end

  local renderNodes
  -- Renders a group's children: with its `childGroups` layout when it has
  -- one, else as `renderNodes` does. Defined below.
  local renderGroupChildren

  ---Configure a freshly created widget for its node.
  ---@param rendering table
  ---@param record table
  ---@param node table
  ---@return boolean ok
  local function configureNode(rendering, record, node)
    local kind = record.kind
    local widget = record.widget

    if kind == "group" then
      widget:SetTitle(node.name)
      widget:PauseLayout()
      local ok = renderGroupChildren(rendering, node, widget)
      widget:ResumeLayout()
      return ok
    elseif kind == "toggle" then
      widget:SetLabel(node.name)
      widget:SetTriState(record.triState)
      widget:SetCallback("OnValueChanged", function(_, _, value)
        writeValue(rendering, record, value)
      end)
    elseif kind == "range" then
      widget:SetLabel(node.name)
      -- Not `node.step or 0`: a secret step reaches `SetSliderValues`,
      -- which refuses it, instead of raising in a boolean test here.
      local step = node.step
      if not isSecret(step) and not step then
        step = 0
      end
      widget:SetSliderValues(node.min, node.max, step)
      widget:SetIsPercent(isTrueFlag(node.isPercent))
      widget:SetCallback("OnValueChanged", function(_, _, value)
        writeValue(rendering, record, value)
      end)
    elseif kind == "select" then
      widget:SetLabel(node.name)
      local mediaType = rendering._media ~= nil and rendering._media[record.path] or nil
      local MediaKit = mediaType ~= nil and findPackage(Registry, "mediaKit", OPTIONAL_MEDIAKIT_API)
        or nil
      if
        mediaType == nil
        or type(MediaKit) ~= "table"
        or type(MediaKit.List) ~= "function"
        or not parts.Dropdown.fillMediaDropdown(MediaKit, widget, mediaType)
      then
        widget:SetList(type(node.values) == "table" and node.values or {}, node.sorting)
      end
      widget:SetCallback("OnValueChanged", function(_, _, value)
        writeValue(rendering, record, value)
      end)
    elseif kind == "multiselect" then
      widget:SetTitle(node.name)
      widget:PauseLayout()
      local keys = orderedKeys(node)
      record.keys = keys
      record.checkBoxes = {}
      for index = 1, #keys do
        local key = keys[index]
        local box = renderCreate(rendering, "CheckBox")
        if box == nil then
          widget:ResumeLayout()
          return false
        end
        box:SetFullWidth(true)
        box:SetLabel(node.values[key])
        if not renderAdd(rendering, widget, box) then
          widget:ResumeLayout()
          return false
        end
        box:SetCallback("OnValueChanged", function(_, _, checked)
          writeMultiselect(rendering, record, key, checked)
        end)
        record.checkBoxes[index] = box
      end
      widget:ResumeLayout()
    elseif kind == "input" then
      widget:SetLabel(node.name)
      widget:SetMultiLine(isTrueFlag(node.multiline))
      widget:SetCallback("OnEnterPressed", function(_, _, text)
        writeValue(rendering, record, text)
      end)
    elseif kind == "color" then
      widget:SetLabel(node.name)
      local hasAlpha = isTrueFlag(node.hasAlpha)
      widget:SetHasAlpha(hasAlpha)
      widget:SetCallback("OnValueChanged", function(_, _, red, green, blue, alpha)
        writeValue(rendering, record, {
          r = red,
          g = green,
          b = blue,
          a = hasAlpha and alpha or nil,
        })
      end)
    elseif kind == "keybinding" then
      widget:SetKeyCapture(true)
      widget:SetCallback("OnKeyCaptured", function(_, _, key)
        writeValue(rendering, record, key)
      end)
    elseif kind == "execute" then
      widget:SetText(node.name)
      widget:SetCallback("OnClick", function()
        executeRecord(rendering, record)
      end)
    elseif kind == "header" then
      widget:SetText(node.name)
    elseif kind == "description" then
      -- A secret size cannot index the table; it gets the default font.
      local fontSize = node.fontSize
      local font = not isSecret(fontSize) and DESCRIPTION_FONTS[fontSize] or nil
      widget:SetFontObject(font or DESCRIPTION_FONTS.medium)
      widget:SetText(node.name)
    end
    return true
  end

  ---Create, add and configure the widget for one visible node.
  ---@param rendering table
  ---@param node table
  ---@param parent table
  ---@return boolean ok
  local function renderNode(rendering, node, parent)
    local kind = node.kind
    local extension = extensions.kinds[kind]
    local typeName = extension ~= nil and extension.type or NODE_WIDGET_TYPES[kind]
    if typeName == nil then
      -- A kind this generation does not know is skipped, not refused.
      return true
    end

    local widget = renderCreate(rendering, typeName)
    if widget == nil then
      return false
    end
    widget:SetFullWidth(true)
    if not renderAdd(rendering, parent, widget) then
      return false
    end

    local record = {
      path = node.path,
      kind = kind,
      name = node.name,
      widget = widget,
      parent = parent,
      triState = isTrueFlag(node.tristate),
      -- A secret `confirm` cannot be read, so the option asks with the
      -- default question rather than run on a single click.
      confirm = isSecret(node.confirm) and true or node.confirm,
      armed = false,
      disabled = false,
      messageLabel = nil,
    }
    local recordList = rendering._records
    recordList[#recordList + 1] = record
    rendering._byPath[node.path] = record

    record.extension = extension
    local configured
    if extension ~= nil then
      configured = extension.configure(rendering, record, node) == true
    else
      configured = configureNode(rendering, record, node)
    end
    if not configured then
      return false
    end
    if #extensions.decoratorOrder > 0 then
      runDecorators("decorate", rendering, record, node)
    end
    -- The value is read with `Get`, not taken from the description:
    -- `Describe` hands out a copy of a table value, and a copy no longer
    -- answers `issecretvalue` as the original did.
    refreshRecord(rendering, record)
    return true
  end

  ---Render every node of `nodes` into `parent`, remembering each one's hidden
  ---state so a refresh can tell when one was shown or hidden.
  ---@param rendering table
  ---@param nodes any
  ---@param parent table
  ---@return boolean ok
  function renderNodes(rendering, nodes, parent)
    if type(nodes) ~= "table" then
      return true
    end
    local visited = rendering._nodes
    for index = 1, #nodes do
      local node = nodes[index]
      local hidden = isTrueFlag(node.hidden)
      visited[#visited + 1] = { path = node.path, hidden = hidden }
      if not hidden and not renderNode(rendering, node, parent) then
        return false
      end
    end
    return true
  end

  -- The `childGroups` renderer. A block of its own so its helpers do not
  -- count against the main chunk's 200 locals.
  do
    -- The `childGroups` layouts the renderer draws (OptionsKit revision 10).
    local PAGED_LAYOUTS = { tab = true, tree = true, select = true }

    ---The page of `node` shown now: the one chosen last while this rendering
    ---lives, else the first.
    ---@param rendering table
    ---@param node table
    ---@param pages table[]
    ---@return table page
    local function selectedPage(rendering, node, pages)
      local choices = rendering._selected
      if choices == nil then
        -- A rendering made by revision 10 or older has no selection table.
        choices = {}
        rendering._selected = choices
      end
      local chosen = choices[node.path]
      for index = 1, #pages do
        if pages[index].path == chosen then
          return pages[index]
        end
      end
      choices[node.path] = pages[1].path
      return pages[1]
    end

    ---Show the page at `pagePath` of the group at `groupPath`: remember it and
    ---build the rendering again.
    ---@param rendering table
    ---@param groupPath string
    ---@param pagePath any
    local function choosePage(rendering, groupPath, pagePath)
      if rendering._selected[groupPath] ~= pagePath then
        rendering._selected[groupPath] = pagePath
        RenderingPrototype.Rebuild(rendering)
      end
    end

    ---A button that shows `page` of the group at `groupPath`, disabled while
    ---that page is the one shown.
    ---@param rendering table
    ---@param groupPath string
    ---@param page table
    ---@param shown boolean
    ---@return table? button
    local function pageButton(rendering, groupPath, page, shown)
      local button = renderCreate(rendering, "Button")
      if button == nil then
        return nil
      end
      button:SetText(page.name)
      button:SetDisabled(shown)
      local pagePath = page.path
      button:SetCallback("OnClick", function()
        choosePage(rendering, groupPath, pagePath)
      end)
      return button
    end

    ---A group widget without a title, for a row, a list or a page column.
    ---@param rendering table
    ---@param parent table
    ---@param relativeWidth number? the share of the parent's width; full width without it
    ---@return table? group
    local function plainGroup(rendering, parent, relativeWidth)
      local group = renderCreate(rendering, "Group")
      if group == nil then
        return nil
      end
      group:SetTitle(nil)
      if relativeWidth then
        group:SetRelativeWidth(relativeWidth)
      else
        group:SetFullWidth(true)
      end
      if not renderAdd(rendering, parent, group) then
        return nil
      end
      return group
    end

    ---Render a group's children. Without a `childGroups` layout they render
    ---one after the other. With one, the options and inline groups render as
    ---usual, then the other child groups as pages, one shown at a time behind
    ---tabs, a list or a dropdown.
    ---@param rendering table
    ---@param node table a group node, or the description's root
    ---@param parent table
    ---@return boolean ok
    function renderGroupChildren(rendering, node, parent)
      local children = node.children
      local style = node.childGroups
      local pageStyle = not isSecret(style) and extensions.pageStyles[style] or nil
      if pageStyle ~= nil then
        return pageStyle.render(rendering, node, parent) == true
      end
      if not PAGED_LAYOUTS[style] then
        return renderNodes(rendering, children, parent)
      end
      if type(children) ~= "table" then
        return true
      end
      local visited = rendering._nodes
      local pages = {}
      for index = 1, #children do
        local child = children[index]
        local hidden = isTrueFlag(child.hidden)
        visited[#visited + 1] = { path = child.path, hidden = hidden }
        if not hidden then
          if child.kind == "group" and not isTrueFlag(child.inline) then
            pages[#pages + 1] = child
          elseif not renderNode(rendering, child, parent) then
            return false
          end
        end
      end
      if #pages == 0 then
        return true
      end

      local layout = node.childGroups
      local shown = selectedPage(rendering, node, pages)
      local groupPath = node.path
      local pageParent = parent
      if layout == "select" then
        local dropdown = renderCreate(rendering, "Dropdown")
        if dropdown == nil then
          return false
        end
        local labels, order = {}, {}
        for index = 1, #pages do
          labels[pages[index].path] = pages[index].name
          order[index] = pages[index].path
        end
        dropdown:SetFullWidth(true)
        dropdown:SetList(labels, order)
        dropdown:SetValue(shown.path)
        dropdown:SetCallback("OnValueChanged", function(_, _, value)
          choosePage(rendering, groupPath, value)
        end)
        if not renderAdd(rendering, parent, dropdown) then
          return false
        end
      else
        -- Tabs: a row of buttons above the page. Tree: a column of buttons
        -- beside the page, the two side by side in one row.
        local row = plainGroup(rendering, parent)
        if row == nil then
          return false
        end
        row:SetLayout("Flow")
        local list = row
        if layout == "tree" then
          local column = plainGroup(rendering, row, 0.3)
          local page = column and plainGroup(rendering, row, 0.7)
          if column == nil or page == nil then
            return false
          end
          list, pageParent = column, page
        end
        for index = 1, #pages do
          local page = pages[index]
          local button = pageButton(rendering, groupPath, page, page == shown)
          if button == nil or not renderAdd(rendering, list, button) then
            return false
          end
        end
      end
      return renderNode(rendering, shown, pageParent)
    end
  end

  ---Release everything the rendering created and forget it.
  ---@param rendering table
  local function releaseRendered(rendering)
    local recordList = rendering._records
    for index = #recordList, 1, -1 do
      local record = recordList[index]
      local job = record.disarmJob
      record.disarmJob = nil
      if job ~= nil and type(job.Cancel) == "function" then
        pcall(job.Cancel, job)
      end
      local label = record.messageLabel
      if owns(rendering, label) and not WidgetBase.IsReleasing(label) then
        renderForget(rendering, label)
        WidgetKit:Release(label)
      end
    end
    -- Only widgets this rendering still owns are released: a widget that went
    -- back to its pool and was acquired by someone else is left alone, and one
    -- whose container is being released goes with that container.
    local widgets = rendering._widgets
    for index = #widgets, 1, -1 do
      local widget = widgets[index]
      if owns(rendering, widget) and not WidgetBase.IsReleasing(widget) then
        WidgetKit:Release(widget)
      end
    end
    rendering._records = {}
    rendering._byPath = {}
    rendering._nodes = {}
    rendering._widgets = {}
  end

  ---Build the widgets from a fresh description and lay the container out once.
  ---@param rendering table
  ---@return boolean ok
  local function buildRendering(rendering)
    local container = rendering._container
    local containerRecord = records[container]
    local description = rendering._tree:Describe()

    local wasPaused = containerRecord.layoutPaused
    containerRecord.layoutPaused = true
    rendering._failure = nil
    -- The container's pause state is restored even when building raises.
    local called, ok = pcall(renderGroupChildren, rendering, description, container)
    containerRecord.layoutPaused = wasPaused
    if not called then
      rendering._failure = ok
      return false
    end
    if not ok then
      return false
    end
    if not wasPaused then
      performLayout(container, containerRecord)
    end
    return true
  end

  ---Render `tree` into `container`.
  ---@param tree table an OptionsKit tree
  ---@param container WidgetKit.Container
  ---@param options WidgetKit.RenderOptions?
  ---@return WidgetKit.Rendering
  function renderOptions(self, tree, container, options)
    validateFacade(self, "WidgetKit:RenderOptions", 3)
    local OptionsKit = findPackage(Registry, "optionsKit", OPTIONAL_OPTIONSKIT_API)
    if type(OptionsKit) ~= "table" then
      error("WidgetKit:RenderOptions requires OptionsKit API 1", 2)
    end
    if
      type(tree) ~= "table"
      or type(tree.Describe) ~= "function"
      or type(tree.Get) ~= "function"
      or type(tree.Set) ~= "function"
      or type(tree.Validate) ~= "function"
      or type(tree.Execute) ~= "function"
      or type(tree.IsDisabled) ~= "function"
      or type(tree.IsHidden) ~= "function"
      or type(tree.OnChange) ~= "function"
    then
      error("WidgetKit:RenderOptions tree must be an OptionsKit tree", 2)
    end
    local containerRecord = type(container) == "table" and records[container] or nil
    if containerRecord == nil or not containerRecord.active or not containerRecord.isContainer then
      error("WidgetKit:RenderOptions container must be an active WidgetKit container", 2)
    end

    local media, confirmText = nil, DEFAULT_CONFIRM_TEXT
    if type(options) ~= "nil" then
      validateOptionKeys(options, RENDER_OPTION_KEYS, "WidgetKit:RenderOptions options", 3)
      -- Still checked, though no kind shows a secret any more: see
      -- `applyState` and docs/API.md ("Secret values").
      refuseSecret(options.allowSecret, "WidgetKit:RenderOptions options.allowSecret", 3)
      if type(options.allowSecret) ~= "nil" and type(options.allowSecret) ~= "boolean" then
        error("WidgetKit:RenderOptions options.allowSecret must be a boolean", 2)
      end
      if type(options.confirmText) ~= "nil" then
        validateName(options.confirmText, "WidgetKit:RenderOptions options.confirmText", 3)
        confirmText = options.confirmText
      end
      if type(options.media) ~= "nil" then
        if type(options.media) ~= "table" then
          error("WidgetKit:RenderOptions options.media must be a table", 2)
        end
        media = {}
        for path, mediaType in next, options.media do
          if type(path) ~= "string" or type(mediaType) ~= "string" then
            error("WidgetKit:RenderOptions options.media must map option paths to media types", 2)
          end
          media[path] = mediaType
        end
      end
    end

    local rendering = setmetatable({
      _tree = tree,
      _container = container,
      _media = media,
      _confirmText = confirmText,
      -- Widget -> the acquire serial it had when this rendering took it.
      _serials = setmetatable({}, WEAK_KEYS),
      _records = {},
      _byPath = {},
      _nodes = {},
      _widgets = {},
      -- Group path -> the path of the `childGroups` page shown, kept across
      -- rebuilds for as long as the rendering lives.
      _selected = {},
      _busy = 0,
      _pending = false,
      _released = false,
      _failure = nil,
      _connection = nil,
    }, RENDERING_METATABLE)

    stamp(rendering, container)
    if not buildRendering(rendering) then
      local failure = rendering._failure
      releaseRendered(rendering)
      rendering._released = true
      error("WidgetKit:RenderOptions " .. tostring(failure), 2)
    end

    -- The container releases its renderings first when it is released.
    local renderings = containerRecord.renderings
    if renderings == nil then
      renderings = {}
      containerRecord.renderings = renderings
    end
    renderings[#renderings + 1] = rendering

    rendering._connection = tree:OnChange(function()
      rendering:Refresh()
    end)
    return rendering
  end

  ---Show the tree's current values and states. Rebuilds instead when a node was
  ---shown or hidden since the last build.
  ---@return boolean refreshed `false` once released or when a rebuild failed
  function RenderingPrototype:Refresh()
    validateRendering(self, "WidgetKit.Rendering:Refresh", 3)
    if not renderingAlive(self) then
      return false
    end
    if self._busy > 0 then
      -- A write is in progress; refresh once it is done.
      self._pending = true
      return true
    end

    local tree = self._tree
    local visited = self._nodes
    for index = 1, #visited do
      local entry = visited[index]
      if isTrueFlag(tree:IsHidden(entry.path)) ~= entry.hidden then
        return RenderingPrototype.Rebuild(self)
      end
    end

    local recordList = self._records
    local scheduled = findPackage(Registry, "schedulerKit", OPTIONAL_SCHEDULERKIT_API) ~= nil
    for index = 1, #recordList do
      local record = recordList[index]
      -- Without SchedulerKit an armed confirmation lasts until the next
      -- refresh.
      if record.armed and not scheduled then
        disarmRecord(self, record)
      end
      refreshRecord(self, record)
    end
    return true
  end

  ---Release every rendered widget and build them again from a fresh description.
  ---@return boolean rebuilt `false` once released, or when widgets ran out (reported)
  function RenderingPrototype:Rebuild()
    validateRendering(self, "WidgetKit.Rendering:Rebuild", 3)
    if not renderingAlive(self) then
      return false
    end
    releaseRendered(self)
    if not buildRendering(self) then
      reportError("WidgetKit.Rendering:Rebuild " .. tostring(self._failure))
      releaseRendered(self)
      return false
    end
    return true
  end

  ---Release every widget the rendering created, together, and stop listening.
  ---@return boolean released `false` when it was already released
  function RenderingPrototype:Release()
    validateRendering(self, "WidgetKit.Rendering:Release", 3)
    if self._released then
      return false
    end
    self._released = true
    local connection = self._connection
    if connection ~= nil then
      connection:Disconnect()
      self._connection = nil
    end
    releaseRendered(self)
    local container = self._container
    local containerRecord = records[container]
    if containerRecord ~= nil then
      local renderings = containerRecord.renderings
      if renderings ~= nil then
        for index = #renderings, 1, -1 do
          if renderings[index] == self then
            table.remove(renderings, index)
          end
        end
      end
    end
    if
      containerRecord ~= nil
      and owns(self, container)
      and not isReleasingRecord(containerRecord)
    then
      performLayout(container, containerRecord)
    end
    return true
  end

  ---@return boolean
  function RenderingPrototype:IsReleased()
    validateRendering(self, "WidgetKit.Rendering:IsReleased", 3)
    return self._released == true
  end

  ---The widget drawing the option at `path`, or `nil` when it is hidden or the
  ---rendering was released. A `multiselect` option is drawn by a Group.
  ---@param path string
  ---@return WidgetKit.Widget?
  function RenderingPrototype:GetWidget(path)
    validateRendering(self, "WidgetKit.Rendering:GetWidget", 3)
    validateName(path, "WidgetKit.Rendering:GetWidget path", 3)
    local record = self._byPath[path]
    if record == nil or not owns(self, record.widget) then
      return nil
    end
    return record.widget
  end

  ---The inline message shown below the option at `path`, or `nil`.
  ---@param path string
  ---@return any
  function RenderingPrototype:GetMessage(path)
    validateRendering(self, "WidgetKit.Rendering:GetMessage", 3)
    validateName(path, "WidgetKit.Rendering:GetMessage path", 3)
    local record = self._byPath[path]
    local label = record ~= nil and record.messageLabel or nil
    if label == nil or not owns(self, label) then
      return nil
    end
    return label.text:GetText()
  end
end

-- Commit ---------------------------------------------------------------------

rawset(WidgetKit, "RenderOptions", renderOptions)
rawset(rawget(state, "parts"), PART_NAME, {
  revision = PART_REVISION,
  bind = bind,
  -- A later part adds to the renderer through this; see "Extensions".
  registerExtension = registerExtension,
  extensions = extensions,
})

return WidgetKit
