local TestEnv = require("CommandKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src

---Run `action` and assert it failed with `message` reported at the line of this
---spec file that called into CommandKit. `action` receives a `mark` function;
---calling `mark()` records the line after it, which must be the call.
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

describe("CommandKit and secret values", function()
  local CommandKit, secret, sink, scope
  before_each(function()
    CommandKit = TestEnv.NewPackage()
    secret = TestEnv.NewSecretValue()
    TestEnv.SetGlobal("issecretvalue", function(value)
      return rawequal(value, secret) or value == "%s secret template"
    end)
    scope = CommandKit:CreateScope()
    sink = CommandKit:CaptureSink()
    scope:SetSink(sink)
  end)
  after_each(TestEnv.Reset)

  it("refuses a secret argument to Print and Printf at the handler's line", function()
    local failures = {}
    scope:Register("leak", {
      handler = function(context)
        failures[1] = select(2, pcall(context.Print, context, "name", secret))
        failures[2] = select(2, pcall(context.Printf, context, "%s", secret))
        failures[3] = select(2, pcall(context.Printf, context, "%s secret template", 1))
      end,
    })
    TestEnv.RunSlash("/leak")
    assert.is_truthy(
      failures[1]:find("CommandKit.Context:Print argument 2 must not be a secret value", 1, true)
    )
    assert.is_truthy(
      failures[2]:find("CommandKit.Context:Printf argument 2 must not be a secret value", 1, true)
    )
    assert.is_truthy(
      failures[3]:find("CommandKit.Context:Printf argument 1 must not be a secret value", 1, true)
    )
    assert.are.same({}, sink:Messages())
  end)

  it("refuses secret text and names", function()
    TestEnv.expectErrorContaining("CommandKit:Parse text must be a string", function()
      CommandKit:Parse(secret)
    end)
    TestEnv.SetGlobal("issecretvalue", function(value)
      return value == "hidden"
    end)
    TestEnv.expectErrorContaining("CommandKit:Parse text must not be a secret value", function()
      CommandKit:Parse("hidden")
    end)
    TestEnv.expectErrorContaining(
      "CommandKit.Scope:Register name must not be a secret value",
      function()
        scope:Register("hidden", { handler = function() end })
      end
    )
  end)

  it("asks ClientKit when it is registered", function()
    TestEnv.Reset()
    local WithClientKit, ClientKit = TestEnv.NewPackageWithClientKit()
    TestEnv.SetGlobal("issecretvalue", nil)
    rawset(ClientKit, "IsSecret", function(_, value)
      return value == "hidden"
    end)
    TestEnv.expectErrorContaining("CommandKit:Parse text must not be a secret value", function()
      WithClientKit:Parse("hidden")
    end)
  end)

  it("skips secret completion candidates and secret slash globals", function()
    scope:Register("pick", {
      handler = function() end,
      complete = function()
        return { "hidden", "shown" }
      end,
    })
    TestEnv.SetGlobal("issecretvalue", function(value)
      return value == "hidden" or value == "/secretemote"
    end)
    scope:EnableCompletion()
    local editBox = TestEnv.NewEditBox("/pick ")
    assert.is_true(TestEnv.PressTab(editBox))
    assert.are.equal("/pick shown ", editBox.text)

    TestEnv.SetGlobal("EMOTE3_CMD1", "/secretemote")
    TestEnv.SetGlobal("SLASH_SAY3", "/secretemote")
    assert.is_true(scope:Register("secretemote", { handler = function() end }))
  end)

  it("shows a secret option value as a placeholder", function()
    TestEnv.Reset()
    local Kit, _, _, _, OptionsKit = TestEnv.NewPackage()
    TestEnv.SetGlobal("issecretvalue", function(value)
      return rawequal(value, secret)
    end)
    local tree = OptionsKit:Define("MyAddon", {
      type = "group",
      args = {
        name = {
          type = "input",
          name = "Name",
          get = function()
            return secret
          end,
          set = function() end,
        },
      },
    })
    local bound = Kit:CreateScope()
    local capture = Kit:CaptureSink()
    bound:SetSink(capture)
    bound:BindOptions(tree, "opts")
    TestEnv.RunSlash("/opts get name")
    assert.are.same({ "name = (secret value)" }, capture:Messages())
  end)

  it("shows a secret desc text and secrets inside a table value as placeholders", function()
    TestEnv.Reset()
    local Kit, _, _, _, OptionsKit = TestEnv.NewPackage()
    TestEnv.SetGlobal("issecretvalue", function(value)
      return rawequal(value, secret) or value == "hidden help"
    end)
    local function constant(value)
      return function()
        return value
      end
    end
    local tree = OptionsKit:Define("MyAddon", {
      type = "group",
      args = {
        label = {
          type = "input",
          name = "Label",
          desc = constant("hidden help"),
          get = constant("shown"),
          set = function() end,
        },
        tint = {
          type = "color",
          name = "Tint",
          get = constant({ r = secret, g = 0, b = 0 }),
          set = function() end,
        },
        channels = {
          type = "multiselect",
          name = "Channels",
          values = { guild = "Guild" },
          get = constant({ guild = secret }),
          set = function() end,
        },
      },
    })
    local bound = Kit:CreateScope()
    local capture = Kit:CaptureSink()
    bound:SetSink(capture)
    bound:BindOptions(tree, "opts")
    TestEnv.RunSlash("/opts list label")
    TestEnv.RunSlash("/opts get tint")
    TestEnv.RunSlash("/opts get channels")
    assert.are.same({
      "label = shown - Label",
      "(secret value)",
      "tint = (secret value)",
      "channels = (secret value)",
    }, capture:Messages())
    assert.are.same({}, TestEnv.ReportedErrors())
  end)
  it("refuses a secret sub-command key at the caller before sorting the keys", function()
    TestEnv.SetGlobal("issecretvalue", function(value)
      return value == "hidden"
    end)
    assertReportedAtCaller(
      "CommandKit.Scope:Register spec.subcommands key must not be a secret value",
      function(mark)
        mark()
        scope:Register("tree", {
          subcommands = {
            alpha = { handler = function() end },
            hidden = { handler = function() end },
          },
        })
      end
    )
    assert.is_false(scope:IsRegistered("tree"))
  end)

  it("refuses a receiver whose __metatable is secret without comparing it", function()
    local impostor = setmetatable({}, { __metatable = secret })
    assertReportedAtCaller(
      "CommandKit.Scope:Register must be called on a CommandKit scope",
      function(mark)
        mark()
        CommandKit.Scope.Register(impostor, "name", { handler = function() end })
      end
    )
  end)

  it("refuses a tree whose __index is secret without comparing it", function()
    local impostor = setmetatable({}, { __index = secret })
    assertReportedAtCaller(
      "CommandKit.Scope:BindOptions tree must be an OptionsKit tree",
      function(mark)
        mark()
        scope:BindOptions(impostor, "opts")
      end
    )
  end)

  it("refuses a secret limit at the caller before comparing it", function()
    assertReportedAtCaller(
      "CommandKit:CreateScope options.maxCommands must be a positive integer or CommandKit.UNBOUNDED",
      function(mark)
        mark()
        CommandKit:CreateScope({ maxCommands = secret })
      end
    )
    assertReportedAtCaller(
      "CommandKit:ForAddon options.maxPositions must be a positive integer or CommandKit.UNBOUNDED",
      function(mark)
        mark()
        CommandKit:ForAddon("MyAddon", { maxPositions = secret })
      end
    )
    assertReportedAtCaller(
      "CommandKit:SetLimits limits.maxCaptured must be a positive integer or CommandKit.UNBOUNDED",
      function(mark)
        mark()
        CommandKit:SetLimits({ maxCaptured = secret })
      end
    )
    assertReportedAtCaller(
      "CommandKit:SetLimits limits.maxCompletions must be an integer from 1 to 256",
      function(mark)
        mark()
        CommandKit:SetLimits({ maxCompletions = secret })
      end
    )
    assert.are.same(
      { maxCaptured = 256, maxCompletions = 32, maxEmotes = 1024 },
      CommandKit:GetLimits()
    )
  end)

  it("answers a toggle of a secret current value with a message", function()
    TestEnv.Reset()
    local Kit, _, _, _, OptionsKit = TestEnv.NewPackage()
    TestEnv.SetGlobal("issecretvalue", function(value)
      return rawequal(value, secret)
    end)
    local writes = 0
    local function constant(value)
      return function()
        return value
      end
    end
    local function count()
      writes = writes + 1
    end
    local tree = OptionsKit:Define("MyAddon", {
      type = "group",
      args = {
        flag = { type = "toggle", name = "Flag", get = constant(secret), set = count },
        channels = {
          type = "multiselect",
          name = "Channels",
          values = { guild = "Guild" },
          get = constant({ guild = secret }),
          set = count,
        },
      },
    })
    local bound = Kit:CreateScope()
    local capture = Kit:CaptureSink()
    bound:SetSink(capture)
    bound:BindOptions(tree, "opts")
    TestEnv.RunSlash("/opts set flag toggle")
    TestEnv.RunSlash("/opts set channels guild toggle")
    assert.are.same({
      "/opts set: the current value is secret; use on or off",
      "/opts set: the current value is secret; use on or off",
    }, capture:Messages())
    assert.are.equal(0, writes)
    assert.are.same({}, TestEnv.ReportedErrors())
  end)

  it("leaves Tab to the client when the cursor position is secret", function()
    local secretCursor = 99
    TestEnv.SetGlobal("issecretvalue", function(value)
      return value == secretCursor
    end)
    scope:Register("pick", {
      handler = function() end,
      complete = function()
        return { "shown" }
      end,
    })
    scope:EnableCompletion()
    local editBox = TestEnv.NewEditBox("/pick ")
    function editBox:GetCursorPosition()
      return secretCursor
    end
    assert.is_false(TestEnv.PressTab(editBox))
    assert.are.equal("/pick ", editBox.text)
  end)

  describe("a boolean flag of a bound tree that is secret", function()
    local Kit, OptionsKit, capture, executed, secretFlags

    ---Bind `args` as `/opts`. The stand-in for a secret boolean is a plain
    ---boolean `issecretvalue` reports once `secretFlags` holds it: a secret
    ---keeps its type, so only the probe tells it apart. The flag turns
    ---secret after `Define`, which is OptionsKit's concern, not this one.
    ---@param args table
    local function bind(args)
      TestEnv.Reset()
      local loadedKit, _, _, _, loadedOptionsKit = TestEnv.NewPackage()
      Kit, OptionsKit = loadedKit, loadedOptionsKit
      secretFlags = {}
      TestEnv.SetGlobal("issecretvalue", function(value)
        return type(value) == "boolean" and secretFlags[value] == true
      end)
      executed = 0
      local tree = OptionsKit:Define("MyAddon", { type = "group", args = args })
      local bound = Kit:CreateScope()
      capture = Kit:CaptureSink()
      bound:SetSink(capture)
      bound:BindOptions(tree, "opts")
    end

    local function count()
      executed = executed + 1
    end

    it("asks for confirmation before running a button whose confirm is secret", function()
      bind({
        wipe = { type = "execute", name = "Wipe", confirm = false, func = count },
      })
      secretFlags[false] = true
      TestEnv.RunSlash("/opts exec wipe")
      assert.are.same({ "Type /opts exec wipe confirm to run it." }, capture:Messages())
      assert.are.equal(0, executed)
      TestEnv.RunSlash("/opts exec wipe confirm")
      assert.are.equal(1, executed)

      -- The same flag, not secret, runs the button at once.
      secretFlags[false] = nil
      capture:Clear()
      TestEnv.RunSlash("/opts exec wipe")
      assert.are.same({}, capture:Messages())
      assert.are.equal(2, executed)
      assert.are.same({}, TestEnv.ReportedErrors())
    end)

    it("does not offer default on a toggle whose tristate is secret", function()
      bind({
        flag = {
          type = "toggle",
          name = "Flag",
          tristate = true,
          get = function()
            return nil
          end,
          set = count,
        },
      })
      secretFlags[true] = true
      TestEnv.RunSlash("/opts set flag default")
      assert.are.same({ "/opts set: expected on, off or toggle" }, capture:Messages())
      assert.are.equal(0, executed)

      -- The same flag, not secret, accepts `default`.
      secretFlags[true] = nil
      capture:Clear()
      TestEnv.RunSlash("/opts set flag default")
      assert.are.equal(1, executed)
      assert.are.same({}, TestEnv.ReportedErrors())
    end)
  end)
end)
