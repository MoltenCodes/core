local TestEnv = require("OptionsKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src

---Run `action` and assert it failed with `message` reported at the line of this
---spec file that called into OptionsKit. A wrong `error` level shows up either
---as a different line number or as a message with no `file:line` prefix.
---
---`action` receives a `mark` function; calling `mark()` records the line of the
---statement on the line after it, which must be the call into OptionsKit.
---@param message string
---@param action fun(mark: fun())
local function assertReportedAtCaller(message, action)
  local expectedLine = nil
  local function mark()
    expectedLine = debug.getinfo(2, "l").currentline + 1
  end
  local ok, value = pcall(action, mark)
  assert.is_false(ok)
  assert.are.equal(SOURCE .. ":" .. tostring(expectedLine) .. ": " .. message, value)
end

local function noop() end

describe("OptionsKit error levels", function()
  local OptionsKit
  local Registry
  local tree

  before_each(function()
    OptionsKit, Registry = TestEnv.NewPackage()
    tree = OptionsKit:Define("Addon", {
      type = "group",
      args = {
        size = { type = "range", name = "Size", min = 1, max = 10, get = noop, set = noop },
        note = { type = "header", name = "Note" },
        deep = {
          type = "group",
          name = "Deep",
          args = {
            own = { type = "toggle", name = "Own", get = noop, set = noop },
          },
        },
      },
    })
  end)
  after_each(TestEnv.Reset)

  it("points facade argument errors at the caller", function()
    assertReportedAtCaller("OptionsKit:Define addonName must be a non-empty string", function(mark)
      mark()
      OptionsKit:Define("", {})
    end)
    assertReportedAtCaller(
      'OptionsKit:Define "Addon" already has a tree; Undefine it first',
      function(mark)
        mark()
        OptionsKit:Define("Addon", {})
      end
    )
    assertReportedAtCaller("OptionsKit:Define options must be a table", function(mark)
      mark()
      OptionsKit:Define("Other", {}, 1)
    end)
    assertReportedAtCaller(
      "OptionsKit:Define options.db needs SettingsKit API 1 to be loaded",
      function(mark)
        mark()
        OptionsKit:Define("Other", {}, { db = {} })
      end
    )
    assertReportedAtCaller(
      "OptionsKit:ProfileOptions needs SettingsKit API 1 to be loaded",
      function(mark)
        mark()
        OptionsKit:ProfileOptions({})
      end
    )
    assertReportedAtCaller("OptionsKit:Get addonName must be a non-empty string", function(mark)
      mark()
      OptionsKit:Get(false)
    end)
    assertReportedAtCaller(
      "OptionsKit:Undefine addonName must be a non-empty string",
      function(mark)
        mark()
        OptionsKit:Undefine("")
      end
    )
  end)

  it("points tree definition errors at the caller, however deep they are", function()
    assertReportedAtCaller('OptionsKit:Define tree.type must be "group" at the root', function(mark)
      mark()
      OptionsKit:Define("Other", { type = "toggle" })
    end)
    local deep = {
      type = "group",
      args = {
        a = {
          type = "group",
          name = "A",
          args = {
            b = { type = "range", name = "B", min = 2, max = 1, get = noop, set = noop },
          },
        },
      },
    }
    assertReportedAtCaller(
      "OptionsKit:Define tree.args.a.args.b.min must not be greater than max",
      function(mark)
        mark()
        OptionsKit:Define("Other", deep)
      end
    )
    deep.args.a.args.b =
      { type = "range", name = "B", min = 1, max = 2, step = "x", get = noop, set = noop }
    assertReportedAtCaller(
      "OptionsKit:Define tree.args.a.args.b.step must be a number",
      function(mark)
        mark()
        OptionsKit:Define("Other", deep)
      end
    )
    deep.args.a.args.b = { type = "toggle", name = "B", bind = "profile.b" }
    assertReportedAtCaller(
      "OptionsKit:Define tree.args.a.args.b.bind needs a SettingsKit database passed as options.db",
      function(mark)
        mark()
        OptionsKit:Define("Other", deep)
      end
    )
    deep.args.a.args.b = { type = "input", name = "B", pattern = "%", get = noop, set = noop }
    assertReportedAtCaller(
      "OptionsKit:Define tree.args.a.args.b.pattern is not a valid Lua pattern",
      function(mark)
        mark()
        OptionsKit:Define("Other", deep)
      end
    )
    deep.args.a.args.b = { type = "select", name = "B", values = {}, get = noop, set = noop }
    assertReportedAtCaller(
      "OptionsKit:Define tree.args.a.args.b.values must not be empty",
      function(mark)
        mark()
        OptionsKit:Define("Other", deep)
      end
    )
    deep.args.a.args.b = { type = "header", name = "B", size = 1 }
    assertReportedAtCaller(
      'OptionsKit:Define tree.args.a.args.b contains unknown field "size" for type "header"',
      function(mark)
        mark()
        OptionsKit:Define("Other", deep)
      end
    )
  end)

  it("points bind definition errors at the caller", function()
    TestEnv.InstallSettingsKitStub(Registry)
    local db = TestEnv.NewDatabase()
    local function bound(bind)
      return { type = "group", args = { b = { type = "toggle", name = "B", bind = bind } } }
    end
    assertReportedAtCaller(
      'OptionsKit:Define tree.args.b.bind "profile" must name a value inside the scope',
      function(mark)
        mark()
        OptionsKit:Define("Other", bound("profile"), { db = db })
      end
    )
    assertReportedAtCaller(
      "OptionsKit:Define options.db must be a SettingsKit database",
      function(mark)
        mark()
        OptionsKit:Define("Other", bound("profile.b"), { db = {} })
      end
    )
  end)

  it("points every tree method's receiver error at the caller", function()
    local methods = {
      "Get",
      "Set",
      "Validate",
      "Reset",
      "Execute",
      "IsDisabled",
      "IsHidden",
      "Walk",
      "Describe",
      "OnChange",
    }
    for _, method in ipairs(methods) do
      assertReportedAtCaller(
        "OptionsKit.Tree:" .. method .. " must be called on an OptionsKit tree",
        function(mark)
          mark()
          tree[method]({}, "size", 1)
        end
      )
    end
    OptionsKit:Undefine("Addon")
    for _, method in ipairs(methods) do
      assertReportedAtCaller(
        "OptionsKit.Tree:" .. method .. " cannot be called on an undefined tree",
        function(mark)
          mark()
          tree[method](tree, "size", 1)
        end
      )
    end
  end)

  it("points path errors at the caller", function()
    assertReportedAtCaller('OptionsKit.Tree:Get unknown path "missing"', function(mark)
      mark()
      tree:Get("missing")
    end)
    assertReportedAtCaller('OptionsKit.Tree:Set unknown path "deep.missing"', function(mark)
      mark()
      tree:Set("deep.missing", true)
    end)
    assertReportedAtCaller("OptionsKit.Tree:Validate path must be a string", function(mark)
      mark()
      tree:Validate(1, 1)
    end)
    assertReportedAtCaller(
      'OptionsKit.Tree:Get path "note" is a header, not a value option',
      function(mark)
        mark()
        tree:Get("note")
      end
    )
    assertReportedAtCaller(
      'OptionsKit.Tree:Set path "deep" is a group, not a value option',
      function(mark)
        mark()
        tree:Set("deep", true)
      end
    )
    assertReportedAtCaller('OptionsKit.Tree:IsHidden unknown path "nope"', function(mark)
      mark()
      tree:IsHidden("nope")
    end)
    assertReportedAtCaller(
      'OptionsKit.Tree:Execute path "size" is not an execute option',
      function(mark)
        mark()
        tree:Execute("size")
      end
    )
    assertReportedAtCaller(
      'OptionsKit.Tree:Reset path "size" is not bound to a database and has no default',
      function(mark)
        mark()
        tree:Reset("size")
      end
    )
  end)

  it("points value refusals at the caller of Set", function()
    assertReportedAtCaller(
      "OptionsKit.Tree:Set size: expected number <= 10, found larger number",
      function(mark)
        mark()
        tree:Set("size", 11)
      end
    )
    assertReportedAtCaller(
      "OptionsKit.Tree:Set deep.own: expected boolean, found string",
      function(mark)
        mark()
        tree:Set("deep.own", "yes")
      end
    )
    local secret = TestEnv.NewSecretValue()
    -- selene: allow(global_usage)
    rawset(_G, "issecretvalue", function(value)
      return rawequal(value, secret)
    end)
    assertReportedAtCaller("OptionsKit.Tree:Set value must not be a secret value", function(mark)
      mark()
      tree:Set("size", secret)
    end)
    assertReportedAtCaller("OptionsKit.Tree:Get path must not be a secret value", function(mark)
      mark()
      tree:Get(secret)
    end)
  end)

  it("points bound read and write errors at the caller", function()
    OptionsKit:Undefine("Addon")
    TestEnv.InstallSettingsKitStub(Registry)
    local db = TestEnv.NewDatabase({ profile = { frame = { x = 1 } } })
    tree = OptionsKit:Define("Addon", {
      type = "group",
      args = {
        x = { type = "range", name = "X", min = 0, max = 5, bind = "profile.frame.x" },
      },
    }, { db = db })
    db.profile = { frame = 1 }
    assertReportedAtCaller(
      'OptionsKit.Tree:Get bind path "profile.frame.x" does not lead to a table',
      function(mark)
        mark()
        tree:Get("x")
      end
    )
    assertReportedAtCaller(
      'OptionsKit.Tree:Set bind path "profile.frame.x" does not lead to a table',
      function(mark)
        mark()
        tree:Set("x", 1)
      end
    )
    assertReportedAtCaller(
      'OptionsKit.Tree:Reset bind path "profile.frame.x" does not lead to a table',
      function(mark)
        mark()
        tree:Reset("x")
      end
    )
    assertReportedAtCaller(
      'OptionsKit.Tree:Describe bind path "profile.frame.x" does not lead to a table',
      function(mark)
        mark()
        tree:Describe()
      end
    )
  end)

  it("points callback argument errors at the caller", function()
    assertReportedAtCaller("OptionsKit.Tree:Walk visitor must be a function", function(mark)
      mark()
      tree:Walk(1)
    end)
    assertReportedAtCaller("OptionsKit.Tree:OnChange callback must be a function", function(mark)
      mark()
      tree:OnChange(nil)
    end)
  end)

  it("points a desc refusal and a failing desc function at the caller", function()
    assertReportedAtCaller(
      "OptionsKit:Define tree.args.note.desc must be a string or a function",
      function(mark)
        mark()
        OptionsKit:Define("Other", {
          type = "group",
          args = { note = { type = "header", name = "Note", desc = 1 } },
        })
      end
    )
    local other = OptionsKit:Define("Other", {
      type = "group",
      args = {
        deep = {
          type = "group",
          name = "Deep",
          args = {
            note = {
              type = "header",
              name = "Note",
              desc = function()
                return 1
              end,
            },
          },
        },
      },
    })
    assertReportedAtCaller(
      'OptionsKit.Tree:Describe desc function of "deep.note" returned no string',
      function(mark)
        mark()
        other:Describe()
      end
    )
  end)
end)
