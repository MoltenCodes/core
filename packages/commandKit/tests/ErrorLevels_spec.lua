local TestEnv = require("CommandKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src

---Run `action` and assert it failed with `message` reported at the line of this
---spec file that called into CommandKit. A wrong `error` level shows up either
---as a different line number or as a message with no `file:line` prefix.
---
---`action` receives a `mark` function; calling `mark()` records the line of the
---statement on the line after it, which must be the call into CommandKit.
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

describe("CommandKit error levels", function()
  local CommandKit, SchemaKit, OptionsKit
  before_each(function()
    local _
    CommandKit, _, _, SchemaKit, OptionsKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("points facade argument errors at the caller", function()
    assertReportedAtCaller(
      "CommandKit:ForAddon addonName must be a non-empty string",
      function(mark)
        mark()
        CommandKit:ForAddon("")
      end
    )
    assertReportedAtCaller(
      "CommandKit:CloseAddonScopes addonName must be a non-empty string",
      function(mark)
        mark()
        CommandKit:CloseAddonScopes(nil)
      end
    )
    assertReportedAtCaller("CommandKit:Parse text must be a string", function(mark)
      mark()
      CommandKit:Parse(1)
    end)
    assertReportedAtCaller("CommandKit:ParseInto array must be a table", function(mark)
      mark()
      CommandKit:ParseInto("a", "b")
    end)
    assertReportedAtCaller(
      "CommandKit:CaptureSink must be called on the CommandKit facade; use CommandKit:CaptureSink(...)",
      function(mark)
        mark()
        CommandKit.CaptureSink()
      end
    )
  end)

  it("points every scope method's receiver error at the caller", function()
    local scope = CommandKit:CreateScope()
    local methods = {
      "Register",
      "Unregister",
      "IsRegistered",
      "SetSink",
      "BindOptions",
      "EnableCompletion",
      "DisableCompletion",
      "Close",
      "IsClosed",
      "GetActiveCount",
      "GetAddonName",
    }
    for _, method in ipairs(methods) do
      assertReportedAtCaller(
        "CommandKit.Scope:" .. method .. " must be called on a CommandKit scope",
        function(mark)
          mark()
          scope[method]({}, "name", {})
        end
      )
    end
  end)

  it("points Register refusals at the caller, however deep the spec", function()
    local scope = CommandKit:CreateScope()
    assertReportedAtCaller(
      'CommandKit.Scope:Register name "1abc" must be letters, digits and underscores, starting with a letter, at most 32 long',
      function(mark)
        mark()
        scope:Register("1abc", { handler = noop })
      end
    )
    assertReportedAtCaller(
      'CommandKit.Scope:Register spec.subcommands.a.subcommands.b contains unknown field "handlr"',
      function(mark)
        mark()
        scope:Register("x", { subcommands = { a = { subcommands = { b = { handlr = noop } } } } })
      end
    )
    assertReportedAtCaller(
      "CommandKit.Scope:Register spec.subcommands.a.arguments must be a SchemaKit.array schema or a list of schemas",
      function(mark)
        mark()
        scope:Register("x", { subcommands = { a = { handler = noop, arguments = true } } })
      end
    )
    assertReportedAtCaller(
      "CommandKit.Scope:Register spec.arguments[2] must be a SchemaKit schema",
      function(mark)
        mark()
        scope:Register("x", { handler = noop, arguments = { SchemaKit.string(), {} } })
      end
    )
    scope:Register("once", { handler = noop })
    assertReportedAtCaller(
      'CommandKit.Scope:Register "once" is already registered in this scope; Unregister it first',
      function(mark)
        mark()
        scope:Register("once", { handler = noop })
      end
    )
    scope:Close()
    assertReportedAtCaller(
      "CommandKit.Scope:Register cannot be used on a closed scope",
      function(mark)
        mark()
        scope:Register("late", { handler = noop })
      end
    )
  end)

  it("points the other scope methods' argument errors at the caller", function()
    local scope = CommandKit:CreateScope()
    assertReportedAtCaller(
      "CommandKit.Scope:Unregister name must be a non-empty string",
      function(mark)
        mark()
        scope:Unregister(nil)
      end
    )
    assertReportedAtCaller(
      "CommandKit.Scope:SetSink sink must be a table with an AddMessage method",
      function(mark)
        mark()
        scope:SetSink(print)
      end
    )
    assertReportedAtCaller(
      "CommandKit.Scope:BindOptions tree must be an OptionsKit tree",
      function(mark)
        mark()
        scope:BindOptions({}, "opts")
      end
    )
    local tree = OptionsKit:Define("MyAddon", {
      type = "group",
      args = { shown = { type = "toggle", name = "Shown", get = noop, set = noop } },
    })
    assertReportedAtCaller(
      "CommandKit.Scope:BindOptions name must be a non-empty string",
      function(mark)
        mark()
        scope:BindOptions(tree, nil)
      end
    )
    assertReportedAtCaller(
      "CommandKit.Scope:BindOptions options.description must be a string",
      function(mark)
        mark()
        scope:BindOptions(tree, "opts", { description = 1 })
      end
    )
  end)

  it("points context errors at the handler's line", function()
    local scope = CommandKit:CreateScope()
    local kept
    scope:Register("ctx", {
      handler = function(context)
        kept = context
        assertReportedAtCaller("CommandKit.Context:Printf template must be a string", function(mark)
          mark()
          context:Printf(nil)
        end)
        assertReportedAtCaller(
          "CommandKit.Context:Fail reason must be a non-empty string",
          function(mark)
            mark()
            context:Fail("")
          end
        )
        assertReportedAtCaller(
          "CommandKit.Context:Print must be called on a CommandKit context",
          function(mark)
            mark()
            context.Print({})
          end
        )
      end,
    })
    TestEnv.RunSlash("/ctx")
    assert.are.same({}, TestEnv.ReportedErrors())
    for _, method in ipairs({
      "Print",
      "Printf",
      "Usage",
      "Fail",
      "GetCommandPath",
      "GetRawText",
    }) do
      assertReportedAtCaller(
        "CommandKit.Context:" .. method .. " cannot be used after its command returned",
        function(mark)
          mark()
          kept[method](kept, "x")
        end
      )
    end
  end)
end)
