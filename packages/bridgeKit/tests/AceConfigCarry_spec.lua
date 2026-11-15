-- BridgeKit revision 8: AceConfig fields carried over to an OptionsKit that
-- publishes `GetFields` (revision 14 and later), and converted trees rebuilt
-- through OptionsKit's Dynamic part. `AceConfig_spec.lua` keeps the older
-- behaviour, without OptionsKit loaded.
local Env = require("BridgeKitTestEnv")

---The one entry for `path` and `field`, as `action (reason)`, or `nil`.
---@return string|nil
local function noted(report, path, field)
  for _, entry in ipairs(report.entries) do
    if entry.path == path and (field == nil or entry.field == field) then
      return entry.action .. " (" .. entry.reason .. ")"
    end
  end
  return nil
end

---A value option over `store[key]`.
local function stored(kind, key, store, extra)
  local option = {
    type = kind,
    name = key,
    get = function(_, ...)
      if select("#", ...) > 0 then
        return store[key .. tostring((...))]
      end
      return store[key]
    end,
    set = function(_, value, state)
      if state ~= nil then
        store[key .. tostring(value)] = state
      else
        store[key] = value
      end
    end,
  }
  for field, value in pairs(extra or {}) do
    option[field] = value
  end
  return option
end

describe("BridgeKit carries AceConfig fields over to OptionsKit", function()
  local BridgeKit, OptionsKit
  local store

  before_each(function()
    BridgeKit, OptionsKit = Env.NewPackageWithOptionsKit()
    store = {}
  end)
  after_each(function()
    package.loaded["OptionsKit-Dynamic"] = nil
    Env.Reset()
  end)

  it("carries presentation fields and controls, and reports none of them", function()
    local conversion = BridgeKit:ConvertAceConfig("MyAddon", {
      type = "group",
      args = {
        a = stored("toggle", "a", store, {
          width = "full",
          relWidth = 0.5,
          descStyle = "inline",
          icon = 1,
          iconCoords = { 0, 1, 0, 1 },
          tooltipHyperlink = "item:1",
          dialogControl = "MyWidget",
          control = "CheckBox",
          image = "x",
          imageCoords = { 0, 1, 0, 1 },
        }),
        b = stored(
          "select",
          "b",
          store,
          { values = { x = "X" }, style = "radio", itemControl = "DDI" }
        ),
        c = stored("input", "c", store, { multiline = 6 }),
        d = stored("multiselect", "d", store, { values = { x = "X" }, tristate = true }),
        e = { type = "description", name = "e", image = "y", imageWidth = 16, imageHeight = 8 },
        f = stored("toggle", "f", store, { dropdownControl = "Nothing", width = "wide" }),
      },
    })
    local args = conversion.tree.args
    assert.are.equal("full", args.a.width)
    assert.are.equal(0.5, args.a.relWidth)
    assert.are.equal("inline", args.a.descStyle)
    assert.are.equal(1, args.a.icon)
    assert.are.same({ 0, 1, 0, 1 }, args.a.iconCoords)
    assert.are.equal("item:1", args.a.tooltipHyperlink)
    assert.are.equal("MyWidget", args.a.dialogControl)
    assert.are.equal("CheckBox", args.a.control)
    assert.are.equal("x", args.a.image)
    assert.are.equal("radio", args.b.style)
    assert.are.equal("DDI", args.b.itemControl)
    assert.are.equal(6, args.c.multiline)
    assert.is_true(args.d.tristate)
    assert.are.equal(16, args.e.imageWidth)
    assert.is_nil(noted(conversion.report, "a"))
    assert.is_nil(noted(conversion.report, "b"))
    assert.is_nil(noted(conversion.report, "c"))
    assert.is_nil(noted(conversion.report, "d"))
    -- `dropdownControl` goes without a word; a width Ace would not draw is
    -- malformed.
    assert.is_nil(noted(conversion.report, "f", "dropdownControl"))
    assert.are.equal("dropped (malformedField)", noted(conversion.report, "f", "width"))
    local tree = OptionsKit:Define("MyAddon", conversion.tree)
    assert.are.equal("full", tree:DescribeOption("a").width)
  end)

  it("calls image, coordinate and sorting callbacks live, and refuses bad values", function()
    local handler = {
      Coordinates = function()
        return { 0.25, 0.75, 0.25, 0.75 }
      end,
    }
    local image = "Interface\\Icons\\A"
    local conversion = BridgeKit:ConvertAceConfig("MyAddon", {
      type = "group",
      handler = handler,
      args = {
        e = {
          type = "execute",
          name = "e",
          func = function() end,
          image = function()
            return image, 20, 10
          end,
          imageCoords = "Coordinates",
          icon = function()
            return {}
          end,
          iconCoords = { 0, 1, 0 },
          dialogControl = "",
        },
        s = stored("select", "s", store, {
          values = function()
            return { a = "A", b = "B" }
          end,
          sorting = function()
            return { "b", "gone", "a" }
          end,
        }),
        g = { type = "group", name = "g", guiInline = "yes", dialogControl = "Box", args = {} },
      },
    })
    -- A group takes no control: reported as before.
    assert.are.equal("dropped (customControl)", noted(conversion.report, "g", "dialogControl"))
    assert.are.equal("dropped (malformedField)", noted(conversion.report, "e", "iconCoords"))
    assert.are.equal("dropped (malformedField)", noted(conversion.report, "e", "dialogControl"))
    assert.are.equal("dropped (malformedField)", noted(conversion.report, "g", "guiInline"))
    local tree = OptionsKit:Define("MyAddon", conversion.tree)
    local node = tree:DescribeOption("e")
    assert.are.equal(image, node.image)
    assert.are.equal(20, node.imageWidth)
    assert.are.same({ 0.25, 0.75, 0.25, 0.75 }, node.imageCoords)
    -- A callback answering what OptionsKit would refuse answers the default.
    assert.are.equal("", node.icon)
    image = {}
    assert.are.equal("", tree:DescribeOption("e").image)
    assert.are.same({ "b", "a" }, tree:DescribeOption("s").sorting)
  end)

  it("keeps the third state of a multiselect carried with tristate", function()
    store.dy = true
    store.dz = false
    local conversion = BridgeKit:ConvertAceConfig("MyAddon", {
      type = "group",
      args = {
        d = stored(
          "multiselect",
          "d",
          store,
          { values = { x = "X", y = "Y", z = "Z" }, tristate = true }
        ),
      },
    })
    local tree = OptionsKit:Define("MyAddon", conversion.tree)
    assert.are.same({ y = true, z = false }, tree:Get("d"))
  end)

  it("carries the per-interface flags as they are, folding nothing", function()
    local conversion = BridgeKit:ConvertAceConfig("MyAddon", {
      type = "group",
      args = {
        a = stored("toggle", "a", store, { cmdHidden = true, dropdownHidden = true }),
        g = {
          type = "group",
          name = "g",
          dialogInline = true,
          cmdInline = false,
          dropdownInline = true,
          args = {},
        },
      },
    }, { uiType = "cmd" })
    local args = conversion.tree.args
    assert.is_true(args.a.cmdHidden)
    assert.is_nil(args.a.hidden)
    assert.is_true(args.g.dialogInline)
    assert.is_false(args.g.cmdInline)
    assert.is_nil(noted(conversion.report, "a"))
    assert.is_nil(noted(conversion.report, "g"))
    local tree = OptionsKit:Define("MyAddon", conversion.tree)
    assert.is_true(tree:IsHidden("a", "cmd"))
    assert.is_false(tree:IsHidden("a", "dialog"))
    -- `uiType = "dropdown"` still folds the dropdown flags.
    local dropdown = BridgeKit:ConvertAceConfig("Other", {
      type = "group",
      args = { a = stored("toggle", "a", store, { dropdownHidden = true }) },
    }, { uiType = "dropdown" })
    assert.are.equal("changed (perInterfaceFlag)", noted(dropdown.report, "a", "dropdownHidden"))
  end)

  it("calls name, order and fontSize callbacks live", function()
    local label = "first"
    local handler = {
      Order = function()
        return 5
      end,
    }
    local conversion = BridgeKit:ConvertAceConfig("MyAddon", {
      type = "group",
      handler = handler,
      args = {
        a = stored("toggle", "a", store, {
          name = function()
            return label
          end,
          order = "Order",
        }),
        d = {
          type = "description",
          name = "d",
          fontSize = function()
            return label == "first" and "large" or "huge"
          end,
        },
      },
    })
    assert.is_nil(noted(conversion.report, "a", "name"))
    local tree = OptionsKit:Define("MyAddon", conversion.tree)
    assert.are.equal("first", tree:DescribeOption("a").name)
    assert.are.equal(5, tree:DescribeOption("a").order)
    assert.are.equal("large", tree:DescribeOption("d").fontSize)
    label = "second"
    assert.are.equal("second", tree:DescribeOption("a").name)
    assert.are.equal("medium", tree:DescribeOption("d").fontSize)
  end)

  it("carries confirm on every kind with Ace's answers", function()
    local seen = {}
    local handler = {
      Ask = function(_, _, value)
        seen[#seen + 1] = value
        return value and "Turn on?" or false
      end,
    }
    local conversion = BridgeKit:ConvertAceConfig("MyAddon", {
      type = "group",
      handler = handler,
      args = {
        t = stored("toggle", "t", store, { confirm = "Ask" }),
        plain = stored("toggle", "plain", store, { confirm = true, confirmText = "Sure?" }),
        c = stored("color", "c", store, {
          confirm = function(_, r, g, b)
            return ("%s %s %s"):format(r, g, b)
          end,
        }),
        m = stored("multiselect", "m", store, {
          values = { x = "X", y = "Y" },
          confirm = function(_, key, state)
            return key .. "=" .. tostring(state)
          end,
        }),
        run = {
          type = "execute",
          name = "run",
          func = function() end,
          confirm = function()
            return true
          end,
        },
      },
    })
    assert.is_nil(noted(conversion.report, "t", "confirm"))
    assert.is_nil(noted(conversion.report, "run", "confirm"))
    local tree = OptionsKit:Define("MyAddon", conversion.tree)
    assert.are.equal("Turn on?", tree:GetConfirmation("t", true))
    assert.is_nil(tree:GetConfirmation("t", false))
    assert.are.same({ true, false }, seen)
    assert.are.equal("Sure?", tree:GetConfirmation("plain", true))
    assert.are.equal("1 0 0.5", tree:GetConfirmation("c", { r = 1, g = 0, b = 0.5 }))
    assert.are.equal("y=true", tree:GetConfirmation("m", { x = false, y = true }))
    assert.are.equal("run", tree:GetConfirmation("run"))
  end)

  it("rebuilds a converted tree after NotifyChange with the Dynamic part", function()
    require("OptionsKit-Dynamic")
    local source = { type = "group", args = { a = stored("toggle", "a", store) } }
    local tree, report = BridgeKit:DefineAceConfig("MyAddon", source)
    assert.are.equal(0, report.counts.changed)
    source.args.b = stored("toggle", "b", store)
    tree:NotifyChange()
    assert.are.equal("toggle", tree:DescribeOption("b").kind)
    OptionsKit:Undefine("MyAddon")
    -- A source function no longer counts as a snapshot.
    local count = 1
    local built, functionReport = BridgeKit:DefineAceConfig("Other", function()
      local args = { ["two words"] = stored("toggle", "renamed", store) }
      for index = 1, count do
        args["o" .. index] = stored("toggle", "o" .. index, store)
      end
      return { type = "group", args = args }
    end)
    assert.is_nil(noted(functionReport, "", nil))
    assert.are.equal("renamed (identifier)", noted(functionReport, "two_words"))
    count = 2
    built:NotifyChange()
    assert.are.equal(3, built:Walk(function() end))
  end)

  it("keeps the tree when a strict rebuild would report", function()
    require("OptionsKit-Dynamic")
    local reports = {}
    -- selene: allow(global_usage)
    rawset(_G, "geterrorhandler", function()
      return function(message)
        reports[#reports + 1] = message
      end
    end)
    local source = { type = "group", args = { a = stored("toggle", "a", store) } }
    local tree = BridgeKit:DefineAceConfig("MyAddon", source, { strict = true })
    source.args.b = stored("toggle", "b", store, { width = 0 })
    tree:NotifyChange()
    assert.are.equal(1, tree:Walk(function() end))
    assert.are.equal(1, #reports)
    -- selene: allow(global_usage)
    rawset(_G, "geterrorhandler", nil)
  end)

  it("stays a snapshot without the Dynamic part", function()
    local tree, report = BridgeKit:DefineAceConfig("MyAddon", function()
      return { type = "group", args = {} }
    end)
    assert.are.equal("changed (sourceFunction)", noted(report, ""))
    assert.is_nil(rawget(tree, "_builder"))
  end)
end)
