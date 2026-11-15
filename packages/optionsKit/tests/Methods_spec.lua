local TestEnv = require("OptionsKitTestEnv")

-- Revision 14: method names of a handler (ADR 0003), checked at `Define` and
-- looked up per call, and AceConfig's inheritance of `get`, `set`,
-- `validate` and `func`, resolved at `Define`.

---A handler with a value store and the methods every spec below names.
---@return table handler
local function newHandler()
  local handler = { store = { scale = 1, mode = "a", flag = false }, calls = {} }
  function handler:Get(info)
    return self.store[info[#info]]
  end
  function handler:Set(info, value)
    self.store[info[#info]] = value
  end
  function handler:Check(_, value)
    if value == "bad" or value == "c" then
      return false, "no bad values"
    end
    return true
  end
  function handler:Run(info)
    self.calls[#self.calls + 1] = info.path
  end
  function handler:Hide()
    return self.hidden == true
  end
  function handler:Values()
    return { a = "A", b = "B", c = "C" }
  end
  function handler:Order()
    return 1
  end
  return handler
end

describe("OptionsKit method names and inheritance", function()
  local OptionsKit
  local handler

  before_each(function()
    OptionsKit = TestEnv.NewPackage()
    handler = newHandler()
  end)
  after_each(TestEnv.Reset)

  it("calls handler methods named by every field that takes one", function()
    local tree = OptionsKit:Define("Addon", {
      type = "group",
      handler = handler,
      args = {
        scale = { type = "range", name = "Scale", min = 0, max = 2, get = "Get", set = "Set" },
        mode = {
          type = "select",
          name = "Mode",
          values = "Values",
          get = "Get",
          set = "Set",
          validate = "Check",
          hidden = "Hide",
          order = "Order",
        },
        run = { type = "execute", name = "Run", func = "Run", disabled = "Hide" },
      },
    })
    assert.are.equal(1, tree:Get("scale"))
    assert.is_true(tree:Set("scale", 1.5))
    assert.are.equal(1.5, handler.store.scale)
    assert.are.same({ false, "no bad values" }, { tree:Validate("mode", "c") })
    assert.is_true(tree:Set("mode", "b"))
    assert.are.same({ a = "A", b = "B", c = "C" }, tree:DescribeOption("mode").values)
    assert.are.equal(1, tree:DescribeOption("mode").order)
    assert.is_false(tree:IsHidden("mode"))
    handler.hidden = true
    assert.is_true(tree:IsHidden("mode"))
    assert.is_true(tree:IsDisabled("run"))
    tree:Execute("run")
    assert.are.same({ "run" }, handler.calls)
  end)

  it("binds late: a method replaced after Define is the one called", function()
    local tree = OptionsKit:Define("Addon", {
      type = "group",
      handler = handler,
      args = { flag = { type = "toggle", name = "Flag", get = "Get", set = "Set" } },
    })
    function handler:Get()
      return "replaced"
    end
    assert.are.equal("replaced", tree:Get("flag"))
    handler.Get = nil
    TestEnv.expectErrorContaining(
      'OptionsKit (Addon) flag: handler method "Get" is missing',
      function()
        tree:Get("flag")
      end
    )
  end)

  it("refuses a missing method, and a method name without a handler, at Define", function()
    TestEnv.expectErrorContaining(
      'OptionsKit:Define tree.args.flag.get names method "Read", which the handler in force does not have',
      function()
        OptionsKit:Define("Addon", {
          type = "group",
          handler = handler,
          args = { flag = { type = "toggle", name = "Flag", get = "Read", set = "Set" } },
        })
      end
    )
    TestEnv.expectErrorContaining(
      'OptionsKit:Define tree.args.flag.get is a method name ("Get"), but no handler is in force',
      function()
        OptionsKit:Define("Other", {
          type = "group",
          args = { flag = { type = "toggle", name = "Flag", get = "Get", set = "Set" } },
        })
      end
    )
  end)

  it("never reads a string as a method name where the string is the value", function()
    local tree = OptionsKit:Define("Addon", {
      type = "group",
      handler = handler,
      args = {
        intro = {
          type = "description",
          name = "Get",
          desc = "Set",
          width = "full",
          image = "Run",
          fontSize = "small",
          confirm = "Check",
        },
      },
    })
    local node = tree:DescribeOption("intro")
    assert.are.equal("Get", node.name)
    assert.are.equal("Set", node.desc)
    assert.are.equal("Run", node.image)
    assert.are.equal("Check", tree:GetConfirmation("intro"))
  end)

  it("shares one caller per handler and method name within a Define", function()
    local tree = OptionsKit:Define("Addon", {
      type = "group",
      handler = handler,
      args = {
        one = { type = "toggle", name = "One", get = "Get", set = "Set" },
        two = { type = "toggle", name = "Two", get = "Get", set = "Set" },
      },
    })
    local records = rawget(tree, "_records")
    assert.are.equal(rawget(records.one, "_get"), rawget(records.two, "_get"))
    assert.are_not.equal(rawget(records.one, "_get"), rawget(records.one, "_set"))
  end)

  it("inherits get, set, validate and func from the nearest group", function()
    local outer = { value = "outer" }
    local tree = OptionsKit:Define("Addon", {
      type = "group",
      handler = handler,
      get = "Get",
      set = "Set",
      validate = "Check",
      func = "Run",
      args = {
        mode = { type = "input", name = "Mode" },
        run = { type = "execute", name = "Run" },
        own = {
          type = "group",
          name = "Own",
          get = function()
            return outer.value
          end,
          validate = false,
          args = { inner = { type = "input", name = "Inner" } },
        },
      },
    })
    assert.are.equal("a", tree:Get("mode"))
    assert.are.same({ false, "no bad values" }, { tree:Validate("mode", "bad") })
    -- The nearest group's getter, the outer setter, and no validate.
    assert.are.equal("outer", tree:Get("own.inner"))
    assert.is_true(tree:Validate("own.inner", "bad"))
    assert.is_true(tree:Set("own.inner", "x"))
    assert.are.equal("x", handler.store.inner)
    tree:Execute("run")
    assert.are.same({ "run" }, handler.calls)
  end)

  it("resolves an inherited method name against each option's handler", function()
    local other = newHandler()
    other.store.flag = "from other"
    local tree = OptionsKit:Define("Addon", {
      type = "group",
      handler = handler,
      get = "Get",
      set = "Set",
      args = {
        flag = { type = "toggle", name = "Flag" },
        moved = {
          type = "group",
          name = "Moved",
          handler = other,
          args = { flag = { type = "input", name = "Flag" } },
        },
      },
    })
    assert.is_false(tree:Get("flag"))
    assert.are.equal("from other", tree:Get("moved.flag"))
  end)

  it("lets an own bind win over inherited accessors and refuses an option left without", function()
    local Registry = select(2, TestEnv.NewPackage())
    OptionsKit = Registry:Get("optionsKit", 1)
    TestEnv.InstallSettingsKitStub(Registry)
    local db = TestEnv.NewDatabase({ profile = { scale = 2 } })
    local tree = OptionsKit:Define("Addon", {
      type = "group",
      handler = handler,
      get = "Get",
      set = "Set",
      args = {
        scale = { type = "range", name = "Scale", min = 0, max = 3, bind = "profile.scale" },
      },
    }, { db = db })
    assert.are.equal(2, tree:Get("scale"))
    TestEnv.expectErrorContaining(
      "args.stop.args.blocked needs get and set functions, or bind",
      function()
        OptionsKit:Define("Other", {
          type = "group",
          handler = handler,
          get = "Get",
          set = "Set",
          args = {
            stop = {
              type = "group",
              name = "Stop",
              get = false,
              args = { blocked = { type = "toggle", name = "Blocked" } },
            },
          },
        })
      end
    )
  end)

  it("refuses a group accessor of the wrong type", function()
    TestEnv.expectErrorContaining("tree.get must be a function, a method name or false", function()
      OptionsKit:Define("Addon", { type = "group", get = 1, args = {} })
    end)
  end)
end)
