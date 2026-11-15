local TestEnv = require("CommandKitTestEnv")

-- Revision 11's core additions: the command lists, the prefix, printing
-- outside a handler, dispatch from code and reopening a manual scope.

local function noop() end

describe("CommandKit command lists", function()
  local CommandKit

  before_each(function()
    CommandKit = TestEnv.NewPackageWithoutParts()
  end)

  after_each(TestEnv.Reset)

  it("lists a scope's commands and every command, sorted and fresh", function()
    local first = CommandKit:ForAddon("First")
    local second = CommandKit:CreateScope()
    first:Register("zeta", { handler = noop })
    first:Register("Alpha", { handler = noop })
    second:Register("mid", { handler = noop })

    local mine = first:GetCommands()
    mine[1] = "changed"

    assert.are.same({ "alpha", "zeta" }, first:GetCommands())
    assert.are.same({ "alpha", "mid", "zeta" }, CommandKit:GetCommands())
    first:Unregister("zeta")
    assert.are.same({ "alpha", "mid" }, CommandKit:GetCommands())
    TestEnv.expectErrorContaining(
      "CommandKit:GetCommands must be called on the CommandKit facade",
      function()
        CommandKit.GetCommands({})
      end
    )
  end)
end)

describe("CommandKit prefix and printing", function()
  local CommandKit, scope, sink

  before_each(function()
    CommandKit = TestEnv.NewPackageWithoutParts()
    scope = CommandKit:ForAddon("MyAddon")
    sink = CommandKit:CaptureSink()
    scope:SetSink(sink)
  end)

  after_each(TestEnv.Reset)

  it("writes nothing extra by default and prefixes every line once set", function()
    scope:Register("tool", {
      subcommands = {
        run = {
          handler = function(context)
            context:Print("ran")
          end,
        },
      },
    })
    TestEnv.RunSlash("/tool run")
    assert.is_nil(scope:SetPrefix("|cff33ff99MyAddon|r: "))
    TestEnv.RunSlash("/tool run")
    TestEnv.RunSlash("/tool nope")
    scope:Print("loaded", 2)

    local lines = sink:Messages()
    assert.are.equal("ran", lines[1])
    assert.are.equal("|cff33ff99MyAddon|r: ran", lines[2])
    assert.are.equal('|cff33ff99MyAddon|r: /tool: unknown sub-command "nope"', lines[3])
    assert.are.equal("|cff33ff99MyAddon|r: loaded 2", lines[#lines])
    assert.are.equal("|cff33ff99MyAddon|r: ", scope:GetPrefix())
    assert.are.equal("|cff33ff99MyAddon|r: ", scope:SetPrefix(nil))
    scope:Printf("%s of %d", "one", 3)
    assert.are.equal("one of 3", sink:Messages()[#sink:Messages()])
  end)

  it("checks its arguments at the caller", function()
    TestEnv.expectErrorContaining("SetPrefix prefix must be a non-empty string", function()
      scope:SetPrefix("")
    end)
    TestEnv.expectErrorContaining("CommandKit.Scope:Printf template must be a string", function()
      scope:Printf(1)
    end)
    TestEnv.expectErrorContaining(
      "CommandKit.Scope:Print must be called on a CommandKit scope",
      function()
        scope.Print({})
      end
    )
  end)
end)

describe("CommandKit Dispatch", function()
  local CommandKit, scope, sink

  before_each(function()
    CommandKit = TestEnv.NewPackageWithoutParts()
    TestEnv.InstallHostErrorHandler()
    scope = CommandKit:ForAddon("MyAddon")
    sink = CommandKit:CaptureSink()
    scope:SetSink(sink)
  end)

  after_each(TestEnv.Reset)

  it("runs a command as a typed line would, and answers false for an unknown one", function()
    local received = {}
    scope:Register("tool", {
      subcommands = {
        say = {
          handler = function(_, word)
            received[#received + 1] = word
          end,
        },
      },
    })

    assert.is_true(scope:Dispatch("TOOL", 'say "two words"'))
    assert.is_false(scope:Dispatch("other", "say x"))
    assert.is_false(CommandKit:CreateScope():Dispatch("tool", "say y"))
    assert.are.same({ "two words" }, received)
  end)

  it("reports a raising handler instead of raising", function()
    scope:Register("boom", {
      handler = function()
        error("broken")
      end,
    })

    assert.is_true(scope:Dispatch("boom", ""))
    assert.are.equal(1, #TestEnv.ReportedErrors())
    assert.is_not_nil(sink:Messages()[1]:find("/boom failed", 1, true))
  end)

  it("refuses a closed scope and bad arguments at the caller", function()
    TestEnv.expectErrorContaining("CommandKit.Scope:Dispatch text must be a string", function()
      scope:Dispatch("tool", nil)
    end)
    TestEnv.expectErrorContaining(
      "CommandKit.Scope:Dispatch name must be a non-empty string",
      function()
        scope:Dispatch("", "")
      end
    )
    scope:Close()
    TestEnv.expectErrorContaining(
      "CommandKit.Scope:Dispatch cannot be used on a closed scope",
      function()
        scope:Dispatch("tool", "")
      end
    )
  end)
end)

describe("CommandKit Reopen", function()
  local CommandKit

  before_each(function()
    CommandKit = TestEnv.NewPackageWithoutParts()
  end)

  after_each(TestEnv.Reset)

  it("opens a closed manual scope again, empty, keeping its sink and prefix", function()
    local scope = CommandKit:CreateScope()
    local sink = CommandKit:CaptureSink()
    scope:SetSink(sink)
    scope:SetPrefix("> ")
    scope:Register("first", { handler = noop })

    assert.is_false(scope:Reopen())
    assert.is_true(scope:Close())
    assert.is_true(scope:Reopen())
    assert.is_false(scope:IsClosed())
    assert.are.equal(0, scope:GetActiveCount())
    assert.is_false(scope:IsRegistered("first"))
    assert.is_true(scope:Register("first", {
      handler = function(context)
        context:Print("again")
      end,
    }))
    TestEnv.RunSlash("/first")
    assert.are.same({ "> again" }, sink:Messages())
  end)

  it("refuses an addon scope", function()
    local scope = CommandKit:ForAddon("MyAddon")
    scope:Close()

    TestEnv.expectErrorContaining("CommandKit.Scope:Reopen cannot reopen an addon scope", function()
      scope:Reopen()
    end)
  end)
end)
