-- BridgeKit's AceConfig-3.0 adapter: the conversion of each kind and field
-- (docs/BRIDGE_KIT_DESIGN.md, sections 6.2 and 6.3) with its report entry,
-- inheritance resolved as AceConfigDialog resolves it, Ace callbacks called
-- with an Ace `info` in Ace's shape, keys renamed deterministically, `bind`,
-- `replace`, `strict`, the limits, the argument errors, and a converted tree
-- defined in OptionsKit and driven through it.
local Env = require("BridgeKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src

---The report entries of `report` for `path` (and `field`, when given).
---@return table[]
local function entriesFor(report, path, field)
  local found = {}
  for _, entry in ipairs(report.entries) do
    if entry.path == path and (field == nil or entry.field == field) then
      found[#found + 1] = entry
    end
  end
  return found
end

---The one entry for `path` and `field`, as `action (reason)`.
---@return string|nil
local function noted(report, path, field)
  local found = entriesFor(report, path, field)
  if #found == 0 then
    return nil
  end
  return found[1].action .. " (" .. found[1].reason .. ")"
end

---A value option backed by one stored value, for the specs that only need an
---option to exist.
local function stored(kind, extra)
  local option = {
    type = kind,
    name = kind,
    get = function()
      return nil
    end,
    set = function() end,
  }
  for key, value in pairs(extra or {}) do
    option[key] = value
  end
  return option
end

---A root group around `args`.
local function root(args, extra)
  local group = { type = "group", args = args }
  for key, value in pairs(extra or {}) do
    group[key] = value
  end
  return group
end

describe("BridgeKit ConvertAceConfig", function()
  local BridgeKit
  before_each(function()
    BridgeKit = Env.NewPackage()
  end)
  after_each(Env.Reset)

  describe("kinds", function()
    it("converts every kind OptionsKit has", function()
      local conversion = BridgeKit:ConvertAceConfig(
        "MyAddon",
        root({
          general = {
            type = "group",
            name = "General",
            inline = true,
            args = {
              enabled = stored("toggle", { tristate = true }),
              scale = stored(
                "range",
                { min = 0.5, max = 2, softMin = 0.75, bigStep = 0.25, isPercent = false }
              ),
              mode = stored("select", { values = { a = "A", b = "B" }, sorting = { "b", "a" } }),
              parts = stored("multiselect", { values = { x = "X" } }),
              label = stored("input", { pattern = "^%w+$", usage = "<word>", multiline = true }),
              tint = stored("color", { hasAlpha = true }),
              key = stored("keybinding"),
              heading = { type = "header", name = "Heading" },
              text = { type = "description", name = "Some text.", fontSize = "large" },
              run = {
                type = "execute",
                name = "Run",
                func = function() end,
                confirm = true,
                confirmText = "Sure?",
              },
            },
          },
        })
      )
      local general = conversion.tree.args.general
      assert.are.equal("group", conversion.tree.type)
      assert.are.equal("General", general.name)
      assert.is_true(general.inline)
      local args = general.args
      assert.are.same({ "toggle", true }, { args.enabled.type, args.enabled.tristate })
      assert.are.same({ 0.5, 2, 0.75, 0.25, false }, {
        args.scale.min,
        args.scale.max,
        args.scale.softMin,
        args.scale.bigStep,
        args.scale.isPercent,
      })
      assert.are.same({ a = "A", b = "B" }, args.mode.values)
      assert.are.same({ "b", "a" }, args.mode.sorting)
      assert.are.equal("multiselect", args.parts.type)
      assert.are.same(
        { "^%w+$", "<word>", true },
        { args.label.pattern, args.label.usage, args.label.multiline }
      )
      assert.is_true(args.tint.hasAlpha)
      assert.are.equal("keybinding", args.key.type)
      assert.are.equal("header", args.heading.type)
      assert.are.same({ "description", "large" }, { args.text.type, args.text.fontSize })
      assert.are.same({ "execute", "Sure?" }, { args.run.type, args.run.confirm })
      assert.are.equal(11, conversion.optionCount)
      assert.are.equal(11, conversion.report.counts.converted)
      assert.are.equal(2, conversion.maxDepth)
      assert.are.same({ "general", "scale" }, conversion.paths["general.scale"])
    end)

    it("never modifies the source and copies the values table", function()
      local values = { a = "A" }
      local source = root({ mode = stored("select", { values = values }) })
      local conversion = BridgeKit:ConvertAceConfig("MyAddon", source)
      assert.are_not.equal(values, conversion.tree.args.mode.values)
      assert.are.same({ a = "A" }, values)
      assert.are.equal("select", source.args.mode.type)
      assert.is_nil(rawget(source.args.mode, "get") == nil and true or nil)
    end)

    it("leaves out an unknown kind, and tristate, which no dialog draws", function()
      local conversion = BridgeKit:ConvertAceConfig(
        "MyAddon",
        root({
          odd = { type = "sparkle", name = "Odd" },
          three = { type = "tristate", name = "Three" },
          broken = "not an option",
        })
      )
      assert.is_nil(conversion.tree.args.odd)
      assert.is_nil(conversion.tree.args.three)
      assert.are.equal("unsupported (unknownType)", noted(conversion.report, "odd", "type"))
      assert.are.equal("unsupported (unknownType)", noted(conversion.report, "three", "type"))
      assert.are.equal("unsupported (unknownType)", noted(conversion.report, "broken"))
    end)
  end)

  describe("fields and their report entries", function()
    it("calls name and order functions once, with the option's Ace info", function()
      local seen
      local conversion = BridgeKit:ConvertAceConfig(
        "MyAddon",
        root({
          scale = stored("range", {
            min = 0,
            max = 1,
            name = function(info)
              seen = info
              return "Scale"
            end,
            order = function()
              return 5
            end,
          }),
        })
      )
      local option = conversion.tree.args.scale
      assert.are.same({ "Scale", 5 }, { option.name, option.order })
      assert.are.equal("scale", seen[1])
      assert.are.equal("changed (evaluatedOnce)", noted(conversion.report, "scale", "name"))
      assert.are.equal("changed (evaluatedOnce)", noted(conversion.report, "scale", "order"))
    end)

    it("names an option by its key when its name function gives no string", function()
      local conversion = BridgeKit:ConvertAceConfig(
        "MyAddon",
        root({
          scale = stored("toggle", {
            name = function()
              return 42
            end,
          }),
        })
      )
      assert.are.equal("scale", conversion.tree.args.scale.name)
    end)

    it("keeps a desc function live, and gives a string when it returns none", function()
      local text = "first"
      local conversion = BridgeKit:ConvertAceConfig(
        "MyAddon",
        root({
          a = stored("toggle", {
            desc = function()
              return text
            end,
          }),
          b = stored("toggle", {
            desc = function()
              return nil
            end,
          }),
        })
      )
      local desc = conversion.tree.args.a.desc
      assert.are.equal("first", desc())
      text = "second"
      assert.are.equal("second", desc())
      assert.are.equal("", conversion.tree.args.b.desc())
    end)

    it("drops presentation fields and custom controls", function()
      local conversion = BridgeKit:ConvertAceConfig(
        "MyAddon",
        root({
          a = stored("toggle", {
            width = "full",
            descStyle = "inline",
            icon = 1,
            dialogControl = "MyWidget",
            image = "x",
          }),
          b = stored("select", { values = { x = "X" }, style = "radio" }),
          g = { type = "group", name = "G", childGroups = "tab", args = {} },
        })
      )
      assert.are.equal("dropped (presentation)", noted(conversion.report, "a", "width"))
      assert.are.equal("dropped (presentation)", noted(conversion.report, "a", "descStyle"))
      assert.are.equal("dropped (presentation)", noted(conversion.report, "a", "icon"))
      assert.are.equal("dropped (presentation)", noted(conversion.report, "a", "image"))
      assert.are.equal("dropped (customControl)", noted(conversion.report, "a", "dialogControl"))
      assert.are.equal("dropped (presentation)", noted(conversion.report, "b", "style"))
      assert.are.equal("dropped (presentation)", noted(conversion.report, "g", "childGroups"))
      assert.is_nil(conversion.tree.args.a.width)
    end)

    it("reports a field no kind knows", function()
      local conversion =
        BridgeKit:ConvertAceConfig("MyAddon", root({ a = stored("toggle", { witdh = 1 }) }))
      assert.are.equal("dropped (unknownField)", noted(conversion.report, "a", "witdh"))
    end)

    it("folds the hidden and inline flags of the interface and drops the rest", function()
      local source = root({
        a = stored("toggle", { dialogHidden = true, cmdHidden = false }),
        g = { type = "group", name = "G", guiInline = true, cmdInline = true, args = {} },
      })
      local dialog = BridgeKit:ConvertAceConfig("MyAddon", source)
      assert.is_true(dialog.tree.args.a.hidden)
      assert.is_true(dialog.tree.args.g.inline)
      assert.are.equal("changed (perInterfaceFlag)", noted(dialog.report, "a", "dialogHidden"))
      assert.are.equal("dropped (perInterfaceFlag)", noted(dialog.report, "a", "cmdHidden"))
      assert.are.equal("dropped (perInterfaceFlag)", noted(dialog.report, "g", "cmdInline"))

      local cmd = BridgeKit:ConvertAceConfig("MyAddon", source, { uiType = "cmd" })
      assert.is_false(cmd.tree.args.a.hidden)
      assert.are.equal("changed (perInterfaceFlag)", noted(cmd.report, "a", "cmdHidden"))
      assert.is_true(cmd.tree.args.g.inline)
    end)

    it("combines a hidden predicate with a folded flag predicate", function()
      local hidden, dialogHidden = false, false
      local conversion = BridgeKit:ConvertAceConfig(
        "MyAddon",
        root({
          a = stored("toggle", {
            hidden = function()
              return hidden
            end,
            dialogHidden = function()
              return dialogHidden
            end,
          }),
        })
      )
      local predicate = conversion.tree.args.a.hidden
      assert.is_false(predicate({}))
      dialogHidden = true
      assert.is_true(predicate({}))
      dialogHidden, hidden = false, true
      assert.is_true(predicate({}))
    end)

    it("reports confirmation on a value option and a confirm function on execute", function()
      local conversion = BridgeKit:ConvertAceConfig(
        "MyAddon",
        root({
          a = stored("toggle", { confirm = true }),
          run = {
            type = "execute",
            name = "Run",
            func = function() end,
            confirm = function()
              return "Really?"
            end,
          },
        })
      )
      assert.are.equal("dropped (confirmOnValue)", noted(conversion.report, "a", "confirm"))
      assert.are.equal("changed (dynamicConfirm)", noted(conversion.report, "run", "confirm"))
      assert.is_true(conversion.tree.args.run.confirm)
    end)

    it("reports an option that clears a flag its group sets", function()
      local conversion = BridgeKit:ConvertAceConfig(
        "MyAddon",
        root({
          g = {
            type = "group",
            name = "G",
            disabled = true,
            args = { a = stored("toggle", { disabled = false }) },
          },
        })
      )
      assert.are.equal(
        "changed (cannotOverrideAncestor)",
        noted(conversion.report, "g.a", "disabled")
      )
    end)

    it("gives a range without bounds the dialog's own, and reports step", function()
      local conversion = BridgeKit:ConvertAceConfig(
        "MyAddon",
        root({
          plain = stored("range", { step = 1 }),
          soft = stored("range", { softMin = 1, softMax = 5 }),
        })
      )
      local plain, soft = conversion.tree.args.plain, conversion.tree.args.soft
      assert.are.same({ 0, 100 }, { plain.min, plain.max })
      assert.are.same({ -math.huge, math.huge }, { soft.min, soft.max })
      assert.are.equal("changed (defaultBound)", noted(conversion.report, "plain", "min"))
      assert.are.equal("changed (stepNotEnforced)", noted(conversion.report, "plain", "step"))
    end)

    it("turns a line count into multiline", function()
      local conversion =
        BridgeKit:ConvertAceConfig("MyAddon", root({ a = stored("input", { multiline = 5 }) }))
      assert.is_true(conversion.tree.args.a.multiline)
      assert.are.equal("changed (lineCount)", noted(conversion.report, "a", "multiline"))
    end)

    it("keeps values with string and number keys and string labels", function()
      local conversion = BridgeKit:ConvertAceConfig(
        "MyAddon",
        root({
          a = stored("select", { values = { x = "X", [2] = "Two", [true] = "bad", y = 5 } }),
          empty = stored("select", { values = {} }),
        })
      )
      assert.are.same({ x = "X", [2] = "Two" }, conversion.tree.args.a.values)
      assert.are.equal("dropped (valueKey)", noted(conversion.report, "a", "values"))
      assert.is_nil(conversion.tree.args.empty)
      assert.are.equal("unsupported (emptyValues)", noted(conversion.report, "empty", "values"))
    end)

    it("wraps a values function and drops bad entries at call time, reported once", function()
      local conversion = BridgeKit:ConvertAceConfig(
        "MyAddon",
        root({
          a = stored("select", {
            values = function()
              return { x = "X", [false] = "no" }
            end,
          }),
        })
      )
      local values = conversion.tree.args.a.values
      assert.are.same({ x = "X" }, values({}))
      assert.are.same({ x = "X" }, values({}))
      assert.are.equal(1, #entriesFor(conversion.report, "a", "values"))
    end)

    it("keeps sorting that names keys of a values table, and drops any other", function()
      local conversion = BridgeKit:ConvertAceConfig(
        "MyAddon",
        root({
          good = stored("select", { values = { a = "A", b = "B" }, sorting = { "a", "b" } }),
          bad = stored("select", { values = { a = "A" }, sorting = { "a", "zzz" } }),
          dynamic = stored("select", {
            values = function()
              return { a = "A" }
            end,
            sorting = { "a" },
          }),
          computed = stored("select", {
            values = { a = "A" },
            sorting = function()
              return { "a" }
            end,
          }),
        })
      )
      local args = conversion.tree.args
      assert.are.same({ "a", "b" }, args.good.sorting)
      assert.is_nil(args.bad.sorting)
      assert.is_nil(args.dynamic.sorting)
      assert.are.same({ "a" }, args.computed.sorting)
      assert.are.equal("dropped (sortingKey)", noted(conversion.report, "bad", "sorting"))
      assert.are.equal("dropped (sortingKey)", noted(conversion.report, "dynamic", "sorting"))
      assert.are.equal("changed (evaluatedOnce)", noted(conversion.report, "computed", "sorting"))
    end)

    it("reports a multiselect tristate, a hasAlpha function and an unknown fontSize", function()
      local conversion = BridgeKit:ConvertAceConfig(
        "MyAddon",
        root({
          parts = stored("multiselect", { values = { x = "X" }, tristate = true }),
          tint = stored("color", {
            hasAlpha = function()
              return true
            end,
          }),
          text = { type = "description", name = "T", fontSize = "huge" },
        })
      )
      assert.are.equal(
        "changed (multiselectTristate)",
        noted(conversion.report, "parts", "tristate")
      )
      assert.are.equal("changed (evaluatedOnce)", noted(conversion.report, "tint", "hasAlpha"))
      assert.is_true(conversion.tree.args.tint.hasAlpha)
      assert.are.equal("dropped (fontSize)", noted(conversion.report, "text", "fontSize"))
    end)

    it("merges plugins into args, a plugin winning a collision", function()
      local conversion = BridgeKit:ConvertAceConfig(
        "MyAddon",
        root({ a = stored("toggle", { name = "From args" }) }, {
          plugins = {
            profiles = { a = stored("toggle", { name = "From plugin" }), extra = stored("toggle") },
          },
        })
      )
      assert.are.equal("From plugin", conversion.tree.args.a.name)
      assert.is_not_nil(conversion.tree.args.extra)
      assert.are.equal("dropped (pluginShadowed)", noted(conversion.report, "", "plugins"))
    end)
  end)

  describe("inheritance and callbacks", function()
    it("gives an option the get, set and handler its ancestors define", function()
      local store = {}
      local outer = {
        Get = function(self, info)
          return store[info[#info]], self
        end,
        Set = function(_, info, value)
          store[info[#info]] = value
        end,
      }
      local conversion = BridgeKit:ConvertAceConfig(
        "MyAddon",
        root({
          g = {
            type = "group",
            name = "G",
            handler = outer,
            get = "Get",
            set = "Set",
            args = { scale = { type = "range", name = "Scale", min = 0, max = 10 } },
          },
        })
      )
      local scale = conversion.tree.args.g.args.scale
      scale.set({}, 4)
      assert.are.equal(4, store.scale)
      assert.are.equal(4, scale.get({}))
    end)

    it("switches handler half way down and stops at a get of false", function()
      local first = {
        Read = function()
          return "first"
        end,
        Write = function() end,
      }
      local second = {
        Read = function()
          return "second"
        end,
        Write = function() end,
      }
      local conversion = BridgeKit:ConvertAceConfig(
        "MyAddon",
        root({
          g = {
            type = "group",
            name = "G",
            handler = first,
            get = "Read",
            set = "Write",
            args = {
              a = { type = "input", name = "A" },
              inner = {
                type = "group",
                name = "Inner",
                handler = second,
                args = { b = { type = "input", name = "B" } },
              },
              none = { type = "input", name = "None", get = false },
            },
          },
        })
      )
      local args = conversion.tree.args.g.args
      assert.are.equal("first", args.a.get({}))
      assert.are.equal("second", args.inner.args.b.get({}))
      assert.is_nil(args.none)
      assert.are.equal("unsupported (noAccessor)", noted(conversion.report, "g.none"))
    end)

    it("looks a method up at call time, and raises Ace's message when it is gone", function()
      local handler = {
        Read = function()
          return "before"
        end,
        Write = function() end,
      }
      local conversion = BridgeKit:ConvertAceConfig(
        "MyAddon",
        root(
          { a = { type = "input", name = "A" } },
          { handler = handler, get = "Read", set = "Write" }
        )
      )
      local option = conversion.tree.args.a
      handler.Read = function()
        return "after"
      end
      assert.are.equal("after", option.get({}))
      handler.Read = nil
      local ok, failure = pcall(option.get, {})
      assert.is_false(ok)
      assert.is_truthy(
        tostring(failure):find("Method Read doesn't exist in handler for type get", 1, true)
      )
    end)

    it("reports a method missing at conversion", function()
      local conversion = BridgeKit:ConvertAceConfig(
        "MyAddon",
        root(
          { a = { type = "input", name = "A" } },
          { handler = {}, get = "Missing", set = "AlsoMissing" }
        )
      )
      assert.are.equal("changed (missingMethod)", noted(conversion.report, "a", "get"))
      assert.are.equal("changed (missingMethod)", noted(conversion.report, "a", "set"))
    end)

    it("hands every callback the option's Ace info, the same table each call", function()
      local seen = {}
      local handler = {}
      local source
      source = root({
        g = {
          type = "group",
          name = "G",
          args = {
            ["my key"] = {
              type = "toggle",
              name = "Key",
              arg = "extra",
              handler = handler,
              get = function(info)
                seen[#seen + 1] = info
              end,
              set = function() end,
            },
          },
        },
      })
      local conversion =
        BridgeKit:ConvertAceConfig("MyAddon", source, { uiType = "dropdown", uiName = "Mine-2" })
      local option = conversion.tree.args.g.args.my_key
      option.get({})
      option.get({})
      local info = seen[1]
      assert.are.equal(seen[1], seen[2])
      assert.are.same({ "g", "my key" }, { info[1], info[2] })
      assert.are.same({ "MyAddon", "MyAddon" }, { info[0], info.appName })
      assert.are.equal(source, info.options)
      assert.are.equal(source.args.g.args["my key"], info.option)
      assert.are.same(
        { "extra", "toggle", "dropdown", "Mine-2" },
        { info.arg, info.type, info.uiType, info.uiName }
      )
      assert.are.equal(handler, info.handler)
    end)

    it("reads and writes a color as four numbers", function()
      local color = { 0.1, 0.2, 0.3, 0.4 }
      local conversion = BridgeKit:ConvertAceConfig(
        "MyAddon",
        root({
          tint = {
            type = "color",
            name = "Tint",
            hasAlpha = true,
            get = function()
              return unpack(color)
            end,
            set = function(_, r, g, b, a)
              color = { r, g, b, a }
            end,
          },
          plain = {
            type = "color",
            name = "Plain",
            get = function()
              return nil
            end,
            set = function() end,
          },
        })
      )
      local tint = conversion.tree.args.tint
      assert.are.same({ r = 0.1, g = 0.2, b = 0.3, a = 0.4 }, tint.get({}))
      tint.set({}, { r = 1, g = 0, b = 0.5, a = 1 })
      assert.are.same({ 1, 0, 0.5, 1 }, color)
      assert.is_nil(conversion.tree.args.plain.get({}))
    end)

    it("reads a multiselect key by key and writes only the keys that change", function()
      local states = { a = true, b = false }
      local writes = {}
      local conversion = BridgeKit:ConvertAceConfig(
        "MyAddon",
        root({
          parts = {
            type = "multiselect",
            name = "Parts",
            values = { a = "A", b = "B" },
            get = function(_, key)
              return states[key]
            end,
            set = function(_, key, state)
              writes[#writes + 1] = key
              states[key] = state
            end,
          },
        })
      )
      local parts = conversion.tree.args.parts
      assert.are.same({ a = true, b = false }, parts.get({}))
      parts.set({}, { a = true, b = true })
      assert.are.same({ "b" }, writes)
      assert.are.same({ a = true, b = true }, states)
    end)

    it("turns Ace validate answers into OptionsKit's", function()
      local answer
      local conversion = BridgeKit:ConvertAceConfig(
        "MyAddon",
        root({
          a = stored("input", {
            usage = "<word>",
            validate = function()
              return answer
            end,
          }),
          b = stored("input", {
            validate = function()
              return answer
            end,
          }),
        })
      )
      local validateA, validateB = conversion.tree.args.a.validate, conversion.tree.args.b.validate
      answer = true
      assert.are.same({ true }, { validateA({}, "x") })
      answer = "That name is taken"
      assert.are.same({ false, "That name is taken" }, { validateA({}, "x") })
      answer = false
      assert.are.same({ false, "<word>" }, { validateA({}, "x") })
      assert.are.same({ false, "invalid value" }, { validateB({}, "x") })
      answer = {}
      Env.MarkSecret(answer)
      assert.are.same({ false, "<word>" }, { validateA({}, "x") })
    end)

    it("validates a multiselect per changed key and a color as four numbers", function()
      local asked = {}
      local conversion = BridgeKit:ConvertAceConfig(
        "MyAddon",
        root({
          parts = {
            type = "multiselect",
            name = "Parts",
            values = { a = "A", b = "B" },
            get = function(_, key)
              return key == "a"
            end,
            set = function() end,
            validate = function(_, key, state)
              asked[#asked + 1] = key
              return state ~= true or "no b"
            end,
          },
          tint = {
            type = "color",
            name = "Tint",
            get = function() end,
            set = function() end,
            validate = function(_, r)
              return r <= 0.5
            end,
          },
        })
      )
      assert.are.same(
        { false, "no b" },
        { conversion.tree.args.parts.validate({}, { a = true, b = true }) }
      )
      assert.are.same({ "b" }, asked)
      assert.are.same(
        { true },
        { conversion.tree.args.tint.validate({}, { r = 0.25, g = 0, b = 0 }) }
      )
    end)
  end)

  describe("keys", function()
    it("renames keys that are not identifiers, deterministically", function()
      local conversion = BridgeKit:ConvertAceConfig(
        "MyAddon",
        root({
          ["a b"] = stored("toggle"),
          ["a-b"] = stored("toggle"),
          a_b = stored("toggle"),
          ["1st"] = stored("toggle"),
          [""] = stored("toggle"),
        })
      )
      local args = conversion.tree.args
      assert.is_not_nil(args.a_b)
      assert.is_not_nil(args.a_b_2)
      assert.is_not_nil(args.a_b_3)
      assert.is_not_nil(args._1st)
      assert.is_not_nil(args._)
      assert.are.same({ "a b" }, conversion.paths.a_b_2)
      assert.are.same({ "a-b" }, conversion.paths.a_b_3)
      assert.are.equal("renamed (identifier)", noted(conversion.report, "a_b_2"))
      assert.is_nil(noted(conversion.report, "a_b"))
    end)
  end)

  describe("options", function()
    it("binds an option to the database instead of its Ace accessors", function()
      local conversion = BridgeKit:ConvertAceConfig(
        "MyAddon",
        root({ scale = stored("range", { min = 0, max = 2 }) }),
        { bind = { scale = "profile.scale" } }
      )
      local scale = conversion.tree.args.scale
      assert.are.equal("profile.scale", scale.bind)
      assert.is_nil(scale.get)
      assert.are.equal("changed (boundToDatabase)", noted(conversion.report, "scale"))
    end)

    it("replaces an option or group with the table given", function()
      local replacement = { type = "header", name = "Profiles" }
      local conversion = BridgeKit:ConvertAceConfig(
        "MyAddon",
        root({ profiles = { type = "group", name = "AceDBOptions", args = {} } }),
        { replace = { profiles = replacement } }
      )
      assert.are.equal(replacement, conversion.tree.args.profiles)
      assert.are.equal("changed (replaced)", noted(conversion.report, "profiles"))
    end)

    it("refuses a bind or replace path that names no option", function()
      local ok, failure = pcall(function()
        BridgeKit:ConvertAceConfig("MyAddon", root({}), { bind = { missing = "profile.x" } })
      end)
      assert.is_false(ok)
      assert.is_truthy(
        tostring(failure):find("options.bind names no converted option: missing", 1, true)
      )
    end)

    it("raises for strict when anything was dropped or changed", function()
      local line
      local ok, failure = pcall(function()
        line = debug.getinfo(1, "l").currentline + 1
        BridgeKit:ConvertAceConfig(
          "MyAddon",
          root({ a = stored("range", { step = 1 }) }),
          { strict = true }
        )
      end)
      assert.is_false(ok)
      assert.are.equal(
        SOURCE
          .. ":"
          .. line
          .. ": BridgeKit:ConvertAceConfig strict: 3 fields changed or dropped; first: a min (defaultBound)",
        failure
      )
      assert.is_not_nil(
        BridgeKit:ConvertAceConfig(
          "MyAddon",
          root({ ["a b"] = stored("toggle") }),
          { strict = true }
        )
      )
    end)

    it("refuses more options than maxOptions and a path deeper than maxDepth", function()
      local ok, failure = pcall(function()
        BridgeKit:ConvertAceConfig(
          "MyAddon",
          root({ a = stored("toggle"), b = stored("toggle") }),
          { maxOptions = 1 }
        )
      end)
      assert.is_false(ok)
      assert.is_truthy(tostring(failure):find("more than options.maxOptions (1) options", 1, true))
      local deep = root({ g = { type = "group", name = "G", args = { a = stored("toggle") } } })
      ok, failure = pcall(function()
        BridgeKit:ConvertAceConfig("MyAddon", deep, { maxDepth = 1 })
      end)
      assert.is_false(ok)
      assert.is_truthy(
        tostring(failure):find("source.args.g.args.a is deeper than options.maxDepth (1)", 1, true)
      )
      assert.is_not_nil(
        BridgeKit:ConvertAceConfig("MyAddon", deep, { maxOptions = BridgeKit.UNBOUNDED })
      )
    end)

    it("stops a cyclic table at maxDepth", function()
      local group = { type = "group", name = "Loop", args = {} }
      group.args.again = group
      local ok, failure = pcall(function()
        BridgeKit:ConvertAceConfig("MyAddon", root({ loop = group }))
      end)
      assert.is_false(ok)
      assert.is_truthy(tostring(failure):find("deeper than options.maxDepth (8)", 1, true))
    end)

    it("refuses options it does not know or cannot use", function()
      local cases = {
        { "x", "options must be a table or nil" },
        { { uiType = "web" }, 'options.uiType must be "dialog", "dropdown" or "cmd"' },
        { { uiName = "bad" }, 'options.uiName must be a string like "MyAddon-1"' },
        { { bind = { a = 5 } }, "options.bind must map option paths to strings" },
        { { replace = { a = "x" } }, "options.replace must map option paths to tables" },
        { { strict = "yes" }, "options.strict must be a boolean" },
        {
          { maxOptions = 0 },
          "options.maxOptions must be a positive integer or BridgeKit.UNBOUNDED",
        },
        { { maxDepth = 33 }, "options.maxDepth must be an integer from 1 to 32" },
        { { db = {} }, "options has no field named db" },
      }
      for _, case in ipairs(cases) do
        local ok, failure =
          pcall(BridgeKit.ConvertAceConfig, BridgeKit, "MyAddon", root({}), case[1])
        assert.is_false(ok)
        assert.is_truthy(
          tostring(failure):find("BridgeKit:ConvertAceConfig " .. case[2], 1, true),
          case[2]
        )
      end
    end)
  end)

  describe("sources and errors", function()
    it("calls a source function once with the interface and app name", function()
      local calls = {}
      local conversion = BridgeKit:ConvertAceConfig("MyAddon", function(uiType, uiName, appName)
        calls[#calls + 1] = { uiType, uiName, appName }
        return root({ a = stored("toggle") })
      end)
      assert.are.same({ { "dialog", "BridgeKit-1", "MyAddon" } }, calls)
      assert.is_not_nil(conversion.tree.args.a)
      assert.are.equal("changed (sourceFunction)", noted(conversion.report, ""))
    end)

    it("raises at the caller for a bad source, root, app name or a dot call", function()
      local function failureOf(...)
        local ok, failure = pcall(BridgeKit.ConvertAceConfig, ...)
        assert.is_false(ok)
        return tostring(failure)
      end
      assert.is_truthy(
        failureOf(BridgeKit, "", root({})):find("appName must be a non-empty string", 1, true)
      )
      assert.is_truthy(
        failureOf(BridgeKit, "MyAddon", 5):find("source must be a table or a function", 1, true)
      )
      assert.is_truthy(
        failureOf(BridgeKit, "MyAddon", { type = "toggle" }):find(
          'source.type must be "group"',
          1,
          true
        )
      )
      assert.is_truthy(failureOf(BridgeKit, "MyAddon", function()
        return 5
      end):find("source function did not return a table", 1, true))
      assert.is_truthy(
        failureOf("MyAddon", root({})):find("must be called on the BridgeKit facade", 1, true)
      )
    end)

    it("raises at the caller's line for a secret field, naming its path", function()
      local secret = {}
      Env.MarkSecret(secret)
      local line
      local ok, failure = pcall(function()
        line = debug.getinfo(1, "l").currentline + 1
        BridgeKit:ConvertAceConfig(
          "MyAddon",
          root({ general = stored("toggle", { disabled = secret }) })
        )
      end)
      assert.is_false(ok)
      assert.are.equal(
        SOURCE
          .. ":"
          .. line
          .. ": BridgeKit:ConvertAceConfig source.args.general.disabled must not be a secret value",
        failure
      )
    end)

    it("lets an error a name function raises propagate unchanged", function()
      local ok, failure = pcall(function()
        BridgeKit:ConvertAceConfig(
          "MyAddon",
          root({
            a = stored("toggle", {
              name = function()
                error("addon bug")
              end,
            }),
          })
        )
      end)
      assert.is_false(ok)
      assert.is_truthy(tostring(failure):find("addon bug", 1, true))
      assert.is_nil(tostring(failure):find("BridgeKit:", 1, true))
    end)
  end)

  describe("reports", function()
    it("holds every action, keeps no value and truncates at maxReportEntries", function()
      BridgeKit:SetLimits({ maxReportEntries = 2 })
      local conversion = BridgeKit:ConvertAceConfig(
        "MyAddon",
        root({
          a = stored("toggle", { width = 1, icon = 2, descStyle = 3 }),
        })
      )
      local report = conversion.report
      assert.are.equal("aceConfig", report.kind)
      assert.are.equal(2, #report.entries)
      assert.are.equal(1, report.truncated)
      assert.are.same(
        { converted = 1, dropped = 3, changed = 0, renamed = 0, unsupported = 0 },
        report.counts
      )
      for _, entry in ipairs(report.entries) do
        assert.are.same(
          { "path", "field", "action", "reason" },
          (function()
            local keys = {}
            for key in pairs(entry) do
              keys[#keys + 1] = key
            end
            table.sort(keys, function(left, right)
              local order = { path = 1, field = 2, action = 3, reason = 4 }
              return order[left] < order[right]
            end)
            return keys
          end)()
        )
      end
    end)

    it("formats lines and a summary", function()
      local conversion = BridgeKit:ConvertAceConfig(
        "MyAddon",
        root({
          a = stored("toggle", { width = 1 }),
          ["b c"] = stored("toggle"),
        })
      )
      local lines = BridgeKit:FormatReport(conversion.report)
      assert.are.same({
        "a width: dropped (presentation)",
        "b_c: renamed (identifier)",
        "2 converted, 1 dropped, 1 renamed",
      }, lines)
      local short = BridgeKit:FormatReport(conversion.report, 1)
      assert.are.same(
        { "a width: dropped (presentation)", "2 converted, 1 dropped, 1 renamed, 1 more not shown" },
        short
      )
      assert.is_false((pcall(BridgeKit.FormatReport, BridgeKit, {})))
      assert.is_false((pcall(BridgeKit.FormatReport, BridgeKit, conversion.report, 0)))
    end)
  end)
end)

describe("BridgeKit DefineAceConfig", function()
  after_each(Env.Reset)

  it("defines the converted tree in OptionsKit, driven through Ace's callbacks", function()
    local BridgeKit, OptionsKit = Env.NewPackageWithOptionsKit()
    local store = { scale = 1, mode = "a", parts = { x = true } }
    local ran = 0
    local handler = {
      Get = function(_, info, key)
        local value = store[info[#info]]
        if key ~= nil then
          return value[key]
        end
        return value
      end,
      Set = function(_, info, keyOrValue, state)
        if state ~= nil then
          store[info[#info]][keyOrValue] = state
        else
          store[info[#info]] = keyOrValue
        end
      end,
    }
    local tree, report = BridgeKit:DefineAceConfig("MyAddon", {
      type = "group",
      handler = handler,
      get = "Get",
      set = "Set",
      args = {
        scale = {
          type = "range",
          name = "Scale",
          min = 0.5,
          max = 2,
          validate = function(_, value)
            return value ~= 1.5 or "not 1.5"
          end,
        },
        mode = { type = "select", name = "Mode", values = { a = "A", b = "B" } },
        parts = { type = "multiselect", name = "Parts", values = { x = "X", y = "Y" } },
        run = {
          type = "execute",
          name = "Run",
          func = function()
            ran = ran + 1
          end,
        },
      },
    })
    assert.are.equal(0, report.counts.unsupported)
    assert.are.equal(1, tree:Get("scale"))
    assert.is_true(tree:Set("scale", 2))
    assert.are.equal(2, store.scale)
    assert.are.same({ false, "not 1.5" }, { tree:Validate("scale", 1.5) })
    assert.is_true(tree:Set("mode", "b"))
    assert.are.equal("b", store.mode)
    assert.is_true(tree:Set("parts", { x = true, y = true }))
    assert.are.same({ x = true, y = true }, store.parts)
    tree:Execute("run")
    assert.are.equal(1, ran)
    local description = tree:Describe()
    assert.are.equal("MyAddon", description.addonName)
    assert.are.equal(4, #description.children)
    OptionsKit:Undefine("MyAddon")
  end)

  it("passes OptionsKit's refusal on at the caller's line", function()
    local BridgeKit = Env.NewPackageWithOptionsKit()
    local line
    local ok, failure = pcall(function()
      line = debug.getinfo(1, "l").currentline + 1
      BridgeKit:DefineAceConfig("MyAddon", root({ scale = stored("range", { min = 5, max = 1 }) }))
    end)
    assert.is_false(ok)
    assert.is_truthy(
      failure:find(
        "^"
          .. SOURCE:gsub("%p", "%%%0")
          .. ":"
          .. line
          .. ": BridgeKit:DefineAceConfig OptionsKit:Define"
      )
    )
    assert.is_truthy(failure:find("min must not be greater than max", 1, true))
  end)

  it("raises at the caller without OptionsKit", function()
    local BridgeKit = Env.NewPackage()
    local ok, failure = pcall(function()
      BridgeKit:DefineAceConfig("MyAddon", root({}))
    end)
    assert.is_false(ok)
    assert.is_truthy(
      tostring(failure):find("requires OptionsKit API 1, which is not loaded (absent)", 1, true)
    )
  end)
end)
