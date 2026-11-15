local TestEnv = require("OptionsKitTestEnv")

-- Revisions 14 and 15: the refusals and edge answers of the new fields,
-- method names, plugins, confirmations and part members, each at the
-- caller's line.

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

describe("OptionsKit refusals of the new fields", function()
  local OptionsKit

  before_each(function()
    OptionsKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  ---Expect `Define` of `spec` to raise a message containing `expected`.
  ---@param expected string
  ---@param spec any
  ---@param options table?
  local function assertRefused(expected, spec, options)
    TestEnv.expectErrorContaining(expected, function()
      OptionsKit:Define("Bad", spec, options)
    end)
    OptionsKit:Undefine("Bad")
  end

  it("refuses malformed fields of options and groups", function()
    -- A key that is not a string is the point of this case.
    -- selene: allow(mixed_table)
    assertRefused(
      "tree.args.option contains a field that is not a string",
      rootWith({ type = "header", name = "h", [1] = true })
    )
    -- An array with a named key in it is the point of this case.
    -- selene: allow(mixed_table)
    assertRefused(
      "iconCoords must be an array of 4 or 8 numbers",
      rootWith({ type = "header", name = "h", iconCoords = { 0, 1, 0, 1, extra = 1 } })
    )
    assertRefused(
      "iconCoords must be an array of 4 or 8 numbers",
      rootWith({ type = "header", name = "h", iconCoords = { [1] = 0, [2] = 1, [3] = 0, [5] = 1 } })
    )
    assertRefused(
      "get must be a function, a method name or false",
      rootWith({ type = "toggle", name = "t", get = 1, set = setter })
    )
    assertRefused(
      "set must be a function, a method name or false",
      rootWith({ type = "toggle", name = "t", get = getter, set = 1 })
    )
    assertRefused(
      "validate must be a function, a method name or false",
      rootWith({ type = "toggle", name = "t", get = getter, set = setter, validate = 1 })
    )
    assertRefused("func must be a function", rootWith({ type = "execute", name = "e", func = 1 }))
    assertRefused(
      "sorting must be an array",
      rootWith({
        type = "select",
        name = "s",
        values = { a = "A" },
        sorting = 1,
        get = getter,
        set = setter,
      })
    )
    assertRefused(
      "sorting entries must be strings or numbers",
      rootWith({
        type = "select",
        name = "s",
        values = { a = "A" },
        sorting = { true },
        get = getter,
        set = setter,
      })
    )
    assertRefused(
      "multiline must be a boolean or a positive integer",
      rootWith({ type = "input", name = "i", multiline = "4", get = getter, set = setter })
    )
    assertRefused("tree.plugins must be a table", { type = "group", args = {}, plugins = 1 })
    assertRefused("tree.plugins.Masque keys must be identifiers (letters, digits and _)", {
      type = "group",
      args = {},
      plugins = { Masque = { ["a.b"] = { type = "header", name = "h" } } },
    })
  end)

  it("resolves sorting given as a method name", function()
    local handler = {}
    function handler.Order()
      return { "b", "a" }
    end
    local tree = OptionsKit:Define("Addon", {
      type = "group",
      handler = handler,
      args = {
        pick = {
          type = "select",
          name = "Pick",
          values = { a = "A", b = "B" },
          sorting = "Order",
          get = getter,
          set = setter,
        },
      },
    })
    assert.are.same({ "b", "a" }, tree:DescribeOption("pick").sorting)
  end)

  it("refuses a namespace lookup that raises", function()
    local Registry = select(2, TestEnv.NewPackage())
    OptionsKit = Registry:Get("optionsKit", 1)
    TestEnv.InstallSettingsKitStub(Registry)
    local db = TestEnv.NewDatabase()
    function db.GetNamespace()
      error("broken")
    end
    assertRefused(
      'bind namespace "Bars" is not registered in options.db',
      rootWith({ type = "toggle", name = "t", bind = "ns:Bars.profile.t" }),
      { db = db }
    )
  end)

  it("names the replaced option itself in a refused Replace", function()
    local tree = OptionsKit:Define("Addon", rootWith({ type = "header", name = "h" }))
    TestEnv.expectErrorContaining(
      "OptionsKit.Tree:Replace option.name must be a string or a function",
      function()
        tree:Replace("option", { type = "header" })
      end
    )
    TestEnv.expectErrorContaining(
      "OptionsKit.Tree:Replace path must not be a secret value",
      function()
        local secret = TestEnv.NewSecretValue()
        -- selene: allow(global_usage)
        rawset(_G, "issecretvalue", function(value)
          return rawequal(value, secret)
        end)
        tree:Replace(secret, { type = "header", name = "h" })
      end
    )
  end)

  it("builds the default question from function names and descriptions", function()
    local tree = OptionsKit:Define("Addon", {
      type = "group",
      args = {
        named = {
          type = "execute",
          name = function()
            return "Named"
          end,
          desc = function()
            return "Described"
          end,
          func = setter,
          confirm = true,
        },
        unnamed = {
          type = "execute",
          name = function()
            return 1
          end,
          func = setter,
          confirm = true,
        },
      },
    })
    assert.are.equal("Named - Described", tree:GetConfirmation("named"))
    assert.are.equal("unnamed", tree:GetConfirmation("unnamed"))
  end)

  it("refuses a structure listener that is not a function", function()
    local tree = OptionsKit:Define("Addon", { type = "group", args = {} })
    TestEnv.expectErrorContaining(
      "OptionsKit.Tree:OnStructureChanged callback must be a function",
      function()
        tree:OnStructureChanged(1)
      end
    )
  end)

  it("raises for coordinates and names functions that answer the wrong thing", function()
    local answers = { "x", { 1, 2, 3 }, { 1, 2, "3", 4 } }
    for index = 1, #answers do
      local tree = OptionsKit:Define(
        "Addon" .. index,
        rootWith({
          type = "header",
          name = "h",
          iconCoords = function()
            return answers[index]
          end,
        })
      )
      TestEnv.expectErrorContaining(
        'iconCoords function of "option" returned no array of 4 or 8 numbers',
        function()
          tree:Describe()
        end
      )
    end
    local named = OptionsKit:Define(
      "Named",
      rootWith({
        type = "header",
        name = function()
          return 1
        end,
      })
    )
    TestEnv.expectErrorContaining('name function of "option" returned no string', function()
      named:Describe()
    end)
  end)

  it("sorts equal and secret function names by key in Describe", function()
    -- On the client a secret string is a string; this one stands in for it.
    local secret = "A secret name"
    -- selene: allow(global_usage)
    rawset(_G, "issecretvalue", function(value)
      return rawequal(value, secret)
    end)
    local tree = OptionsKit:Define("Addon", {
      type = "group",
      args = {
        b = {
          type = "header",
          name = function()
            return "Same"
          end,
        },
        a = {
          type = "header",
          name = function()
            return "Same"
          end,
        },
        c = {
          type = "header",
          name = function()
            return secret
          end,
        },
        d = { type = "header", name = "Same" },
      },
    })
    local keys = {}
    for _, child in ipairs(tree:Describe().children) do
      keys[#keys + 1] = child.key
    end
    assert.are.same({ "a", "b", "d", "c" }, keys)
  end)
end)
