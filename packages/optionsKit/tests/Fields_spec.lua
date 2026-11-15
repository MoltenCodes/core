local TestEnv = require("OptionsKitTestEnv")

-- Revision 14: AceConfig's presentation fields, accepted, checked and
-- described; records of options that use none of them unchanged.

local function getter()
  return true
end

local function setter() end

---A root group holding `option` under the key `option`.
---@param option table
---@return table
local function rootWith(option)
  return { type = "group", args = { option = option } }
end

---`option` with a getter and a setter.
---@param option table
---@return table
local function valued(option)
  option.get = getter
  option.set = setter
  return option
end

---Count the fields of a table.
---@param value table
---@return integer
local function countFields(value)
  local count = 0
  for _ in next, value do
    count = count + 1
  end
  return count
end

describe("OptionsKit option fields", function()
  local OptionsKit

  before_each(function()
    OptionsKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  ---Expect `Define` of `spec` to raise a message containing `expected`.
  ---@param expected string
  ---@param spec any
  local function assertRefused(expected, spec)
    TestEnv.expectErrorContaining(expected, function()
      OptionsKit:Define("Bad", spec)
    end)
    OptionsKit:Undefine("Bad")
  end

  it("accepts every presentation field in each of its forms", function()
    local tree = OptionsKit:Define("Addon", {
      type = "group",
      handler = {},
      args = {
        intro = {
          type = "description",
          name = "Intro",
          image = "Interface\\Icons\\Spell",
          imageCoords = { 0.1, 0.9, 0.1, 0.9 },
          imageWidth = 24,
          imageHeight = 24,
          fontSize = function()
            return "large"
          end,
          width = "full",
          descStyle = "inline",
          tooltipHyperlink = "item:6948",
          icon = 136243,
          iconCoords = { 0, 1, 0, 1, 0, 1, 0, 1 },
        },
        pick = valued({
          type = "select",
          name = "Pick",
          values = { a = "A", b = "B" },
          style = "radio",
          itemControl = "DDI-Statusbar",
          dialogControl = "LSM30_Statusbar",
          control = "Dropdown",
          width = 1.5,
          relWidth = 0.5,
          confirm = function()
            return "Sure?"
          end,
          confirmText = "Really?",
          arg = { "any", "value" },
        }),
        many = valued({
          type = "multiselect",
          name = "Many",
          values = { a = "A" },
          tristate = true,
        }),
        text = valued({ type = "input", name = "Text", multiline = 6 }),
        flag = valued({ type = "toggle", name = "Flag", image = 1, imageCoords = { 0, 1, 0, 1 } }),
        group = {
          type = "group",
          name = "Group",
          guiInline = true,
          dialogInline = false,
          cmdInline = true,
          guiHidden = false,
          dialogHidden = function()
            return false
          end,
          cmdHidden = true,
          args = {},
        },
      },
    })
    assert.is_table(tree)
  end)

  it("refuses each presentation field with a wrong value at the caller", function()
    local function description(extra)
      local option = { type = "description", name = "d" }
      for key, value in pairs(extra) do
        option[key] = value
      end
      return rootWith(option)
    end
    assertRefused(
      'width must be "normal", "half", "double", "full", a positive number or a function',
      description({ width = "wide" })
    )
    assertRefused(
      'width must be "normal", "half", "double", "full", a positive number or a function',
      description({ width = 0 })
    )
    assertRefused("relWidth must be a number above 0 and at most 1", description({ relWidth = 2 }))
    assertRefused('descStyle must be "inline" or "tooltip"', description({ descStyle = "hidden" }))
    assertRefused("confirmText must be a string", description({ confirmText = 1 }))
    assertRefused("confirm must be a boolean, a string or a function", description({ confirm = 1 }))
    assertRefused("handler must be a table", description({ handler = "self" }))
    assertRefused(
      "icon must be a texture path, a file ID or a function",
      description({ icon = true })
    )
    assertRefused(
      "image must be a texture path, a file ID or a function",
      description({ image = {} })
    )
    assertRefused(
      "imageCoords must be an array of 4 or 8 numbers, a function or a method name",
      description({ imageCoords = { 0, 1, 0 } })
    )
    assertRefused(
      "iconCoords must be an array of 4 or 8 numbers, a function or a method name",
      description({ iconCoords = { 0, 1, 0, "1" } })
    )
    assertRefused("imageWidth must be greater than 0", description({ imageWidth = -1 }))
    assertRefused("dialogControl must be a non-empty string", description({ dialogControl = "" }))
    assertRefused(
      "tooltipHyperlink must be a string or a function",
      description({ tooltipHyperlink = 1 })
    )
    assertRefused(
      "guiHidden must be a boolean, a function or a method name",
      description({ guiHidden = 1 })
    )
    assertRefused(
      'style must be "dropdown" or "radio"',
      rootWith(valued({ type = "select", name = "s", values = { a = "A" }, style = "list" }))
    )
    assertRefused(
      "tristate must be a boolean",
      rootWith(valued({ type = "multiselect", name = "m", values = { a = "A" }, tristate = 1 }))
    )
    assertRefused(
      "guiInline must be a boolean",
      rootWith({ type = "group", name = "g", guiInline = 1, args = {} })
    )
    assertRefused("name must be a string or a function", rootWith({ type = "header", name = 1 }))
  end)

  it("refuses fields on kinds that do not take them", function()
    assertRefused(
      'contains unknown field "width" for type "group"',
      rootWith({ type = "group", name = "g", width = "full", args = {} })
    )
    assertRefused(
      'contains unknown field "image" for type "range"',
      rootWith(valued({ type = "range", name = "r", min = 0, max = 1, image = 1 }))
    )
    assertRefused(
      'contains unknown field "itemControl" for type "multiselect"',
      rootWith(
        valued({ type = "multiselect", name = "m", values = { a = "A" }, itemControl = "x" })
      )
    )
    assertRefused(
      'contains unknown field "dropdownHidden" for type "header"',
      rootWith({ type = "header", name = "h", dropdownHidden = true })
    )
    assertRefused(
      'contains unknown field "imageWidth" for type "toggle"',
      rootWith(valued({ type = "toggle", name = "t", imageWidth = 2 }))
    )
  end)

  it("refuses a secret field before comparing it", function()
    local secret = TestEnv.NewSecretValue()
    -- selene: allow(global_usage)
    rawset(_G, "issecretvalue", function(value)
      return rawequal(value, secret)
    end)
    assertRefused(
      "tree.args.option.width must not be a secret value",
      rootWith({ type = "header", name = "h", width = secret })
    )
  end)

  it("keeps records of options without new fields at today's size", function()
    local tree = OptionsKit:Define("Addon", {
      type = "group",
      args = {
        plain = valued({ type = "toggle", name = "Plain" }),
        described = valued({ type = "toggle", name = "Described", desc = "Help" }),
      },
    })
    local records = rawget(tree, "_records")
    assert.are.equal(7, countFields(records.plain))
    assert.is_nil(rawget(records.plain, "_hints"))
    assert.are.equal(8, countFields(records.described))
    assert.are.same({ desc = "Help" }, rawget(records.described, "_hints"))
  end)

  it("describes the fields, resolving functions and copying tables", function()
    local coordinates = { 0, 1, 0, 1 }
    local tree = OptionsKit:Define("Addon", {
      type = "group",
      args = {
        intro = {
          type = "description",
          name = function(info)
            return "Intro of " .. info.path
          end,
          image = function()
            return "Interface\\Icons\\Spell", 32, 16
          end,
          imageCoords = coordinates,
          width = function()
            return "double"
          end,
          fontSize = function()
            return "small"
          end,
          tooltipHyperlink = function()
            return "spell:1"
          end,
          icon = function()
            return 1
          end,
          iconCoords = function()
            return { 0.5, 1, 0.5, 1 }
          end,
          arg = "kept",
          confirm = true,
        },
        text = valued({ type = "input", name = "Text", multiline = 4, relWidth = 0.5 }),
        pick = valued({
          type = "select",
          name = "Pick",
          values = { a = "A", b = "B" },
          sorting = function()
            return { "b", "a" }
          end,
          style = "radio",
          confirm = function()
            return false
          end,
        }),
      },
    })
    coordinates[1] = 9
    local node = tree:DescribeOption("intro")
    assert.are.equal("Intro of intro", node.name)
    assert.are.equal("Interface\\Icons\\Spell", node.image)
    assert.are.equal(32, node.imageWidth)
    assert.are.equal(16, node.imageHeight)
    assert.are.same({ 0, 1, 0, 1 }, node.imageCoords)
    assert.are.equal("double", node.width)
    assert.are.equal("small", node.fontSize)
    assert.are.equal("spell:1", node.tooltipHyperlink)
    assert.are.equal(1, node.icon)
    assert.are.same({ 0.5, 1, 0.5, 1 }, node.iconCoords)
    assert.is_true(node.confirm)
    assert.is_nil(node.arg)
    local text = tree:DescribeOption("text")
    assert.are.equal(4, text.multiline)
    assert.are.equal(0.5, text.relWidth)
    local pick = tree:DescribeOption("pick")
    assert.are.same({ "b", "a" }, pick.sorting)
    assert.are.equal("radio", pick.style)
    -- A function `confirm` is described as `true`: `GetConfirmation` asks it.
    assert.is_true(pick.confirm)
    -- No function reaches a description.
    for _, child in ipairs(tree:Describe().children) do
      for _, value in pairs(child) do
        assert.are_not.equal("function", type(value))
      end
    end
  end)

  it("raises at the caller of Describe for a function's wrong result", function()
    local tree = OptionsKit:Define(
      "Addon",
      rootWith({
        type = "description",
        name = "d",
        width = function()
          return "wide"
        end,
      })
    )
    TestEnv.expectErrorContaining(
      'OptionsKit.Tree:Describe width function of "option" returned no string or number',
      function()
        tree:Describe()
      end
    )
    OptionsKit:Undefine("Addon")
    local sorted = OptionsKit:Define(
      "Sorted",
      rootWith(valued({
        type = "select",
        name = "s",
        values = { a = "A" },
        sorting = function()
          return { "z" }
        end,
      }))
    )
    TestEnv.expectErrorContaining("returned no array of keys of its values", function()
      sorted:DescribeOption("option")
    end)
  end)

  it("sorts function names and orders in Describe while Walk keeps the Define order", function()
    local tree = OptionsKit:Define("Addon", {
      type = "group",
      args = {
        a = { type = "header", name = "zulu" },
        b = {
          type = "header",
          name = function()
            return "Alpha"
          end,
        },
        c = {
          type = "header",
          name = "mike",
          order = function()
            return 1
          end,
        },
      },
    })
    local walked = {}
    tree:Walk(function(path)
      walked[#walked + 1] = path
    end)
    -- At Define a function name sorts by key and a function order as 100.
    assert.are.same({ "b", "c", "a" }, walked)
    local described = {}
    for _, child in ipairs(tree:Describe().children) do
      described[#described + 1] = child.key
    end
    assert.are.same({ "c", "b", "a" }, described)
  end)

  it("answers per interface in IsHidden and Describe", function()
    local tree = OptionsKit:Define("Addon", {
      type = "group",
      args = {
        dialogOnly = { type = "header", name = "d", cmdHidden = true },
        cmdOnly = {
          type = "header",
          name = "c",
          hidden = true,
          dialogHidden = true,
          cmdHidden = false,
        },
        legacy = { type = "header", name = "l", guiHidden = true },
        box = {
          type = "group",
          name = "Box",
          inline = false,
          dialogInline = true,
          cmdInline = false,
          cmdHidden = function()
            return true
          end,
          args = { inner = { type = "header", name = "i" } },
        },
      },
    })
    assert.is_false(tree:IsHidden("dialogOnly"))
    assert.is_false(tree:IsHidden("dialogOnly", "dialog"))
    assert.is_true(tree:IsHidden("dialogOnly", "cmd"))
    assert.is_true(tree:IsHidden("cmdOnly"))
    assert.is_true(tree:IsHidden("cmdOnly", "dialog"))
    assert.is_false(tree:IsHidden("cmdOnly", "cmd"))
    assert.is_true(tree:IsHidden("legacy", "dialog"))
    assert.is_false(tree:IsHidden("legacy", "cmd"))
    -- An ancestor's flag for the interface applies below it.
    assert.is_true(tree:IsHidden("box.inner", "cmd"))
    assert.is_false(tree:IsHidden("box.inner", "dialog"))
    local dialog = tree:DescribeOption("box", "dialog")
    assert.is_true(dialog.inline)
    assert.is_false(dialog.hidden)
    assert.is_nil(dialog.dialogInline)
    assert.is_nil(dialog.cmdHidden)
    local command = tree:DescribeOption("box", "cmd")
    assert.is_false(command.inline)
    assert.is_true(command.hidden)
    assert.is_false(tree:DescribeOption("box").inline)
    TestEnv.expectErrorContaining(
      'OptionsKit.Tree:IsHidden interface must be "dialog" or "cmd"',
      function()
        tree:IsHidden("box", "dropdown")
      end
    )
    TestEnv.expectErrorContaining(
      'OptionsKit.Tree:Describe interface must be "dialog" or "cmd"',
      function()
        tree:Describe(1)
      end
    )
  end)

  it("answers the question to ask before a change", function()
    local seen = nil
    local tree = OptionsKit:Define("Addon", {
      type = "group",
      args = {
        plain = valued({ type = "toggle", name = "Plain" }),
        asked = valued({ type = "toggle", name = "Asked", desc = "Changes much", confirm = true }),
        texted = valued({
          type = "toggle",
          name = "Texted",
          confirm = true,
          confirmText = "Do it?",
        }),
        question = valued({ type = "toggle", name = "Question", confirm = "Switch?" }),
        computed = valued({
          type = "toggle",
          name = "Computed",
          confirm = function(info, value)
            seen = { info.path, value }
            if value then
              return "Turn on?"
            end
            return false
          end,
        }),
        defaulted = valued({
          type = "toggle",
          name = "Defaulted",
          confirm = function()
            return true
          end,
        }),
        careful = {
          type = "group",
          name = "Careful",
          confirm = true,
          args = {
            inherited = valued({ type = "toggle", name = "Inherited" }),
            cleared = valued({ type = "toggle", name = "Cleared", confirm = false }),
          },
        },
      },
    })
    assert.is_nil(tree:GetConfirmation("plain", true))
    assert.are.equal("Asked - Changes much", tree:GetConfirmation("asked", true))
    assert.are.equal("Do it?", tree:GetConfirmation("texted", true))
    assert.are.equal("Switch?", tree:GetConfirmation("question", false))
    assert.are.equal("Turn on?", tree:GetConfirmation("computed", true))
    assert.are.same({ "computed", true }, seen)
    assert.is_nil(tree:GetConfirmation("computed", false))
    assert.are.equal("Defaulted", tree:GetConfirmation("defaulted", true))
    assert.are.equal("Inherited", tree:GetConfirmation("careful.inherited", true))
    assert.is_nil(tree:GetConfirmation("careful.cleared", true))
    assert.is_true(tree:DescribeOption("careful.inherited").confirm)
    -- `Set` never asks.
    assert.is_true(tree:Set("asked", false))
  end)

  it("answers a secret confirmation answer that is not a string as no question", function()
    local secret = TestEnv.NewSecretValue()
    -- selene: allow(global_usage)
    rawset(_G, "issecretvalue", function(value)
      return rawequal(value, secret)
    end)
    local tree = OptionsKit:Define(
      "Addon",
      rootWith(valued({
        type = "toggle",
        name = "t",
        confirm = function()
          return secret
        end,
      }))
    )
    assert.is_nil(tree:GetConfirmation("option", true))
  end)

  it("puts arg and the handler in force into info, and nothing for others", function()
    local handler = {}
    local infos = {}
    local function remember(info)
      infos[info.path] = info
      return true
    end
    local tree = OptionsKit:Define("Addon", {
      type = "group",
      args = {
        tagged = { type = "toggle", name = "Tagged", arg = 7, get = remember, set = setter },
        plain = { type = "toggle", name = "Plain", get = remember, set = setter },
        owned = {
          type = "group",
          name = "Owned",
          handler = handler,
          args = { inside = { type = "toggle", name = "Inside", get = remember, set = setter } },
        },
      },
    })
    tree:Get("tagged")
    tree:Get("plain")
    tree:Get("owned.inside")
    assert.are.equal(7, infos.tagged.arg)
    assert.is_nil(infos.tagged.handler)
    assert.is_nil(infos.plain.arg)
    assert.are.equal(handler, infos["owned.inside"].handler)
  end)

  it("merges plugins into a group's children and refuses collisions", function()
    local tree = OptionsKit:Define("Addon", {
      type = "group",
      args = { own = { type = "header", name = "Own" } },
      plugins = {
        Masque = { skin = { type = "header", name = "Skin" } },
        Other = { extra = { type = "header", name = "Extra" } },
      },
    })
    assert.are.equal("header", tree:DescribeOption("skin").kind)
    assert.are.equal("header", tree:DescribeOption("extra").kind)
    assert.are.equal(3, tree:Walk(function() end))
    assertRefused("tree.plugins.Masque.own collides with args.own", {
      type = "group",
      args = { own = { type = "header", name = "Own" } },
      plugins = { Masque = { own = { type = "header", name = "Again" } } },
    })
    TestEnv.expectErrorContaining("collides with plugins.", function()
      OptionsKit:Define("Twice", {
        type = "group",
        args = {},
        plugins = {
          One = { same = { type = "header", name = "A" } },
          Two = { same = { type = "header", name = "B" } },
        },
      })
    end)
    assertRefused("tree.plugins must map plugin names to tables of options", {
      type = "group",
      args = {},
      plugins = { Masque = true },
    })
  end)

  it("publishes every field a kind accepts, with its forms, in a fresh table", function()
    local fields = OptionsKit:GetFields("select")
    assert.is_true(fields.values.table)
    assert.is_true(fields.values["function"])
    assert.is_true(fields.values.method)
    assert.is_true(fields.style.string)
    assert.is_true(fields.itemControl.string)
    assert.is_true(fields.width.number)
    assert.is_true(fields.get.method)
    assert.is_true(fields.arg.any)
    assert.is_true(fields.name["function"])
    assert.is_nil(fields.image)
    local group = OptionsKit:GetFields("group")
    assert.is_nil(group.width)
    assert.is_true(group.plugins.table)
    assert.is_true(group.get["function"])
    assert.is_nil(group.bind)
    fields.style.string = nil
    assert.is_true(OptionsKit:GetFields("select").style.string)
    for _, kind in ipairs({ "toggle", "range", "multiselect", "input", "color", "keybinding" }) do
      assert.is_true(OptionsKit:GetFields(kind).bind.string)
    end
    assert.is_true(OptionsKit:GetFields("execute").image.number)
    assert.is_true(OptionsKit:GetFields("description").fontSize["function"])
    assert.is_true(OptionsKit:GetFields("header").name.string)
    TestEnv.expectErrorContaining("OptionsKit:GetFields kind must be an option type", function()
      OptionsKit:GetFields("slider")
    end)
  end)
end)
