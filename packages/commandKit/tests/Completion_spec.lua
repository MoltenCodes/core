local TestEnv = require("CommandKitTestEnv")

local function noop() end

describe("CommandKit tab completion", function()
  local CommandKit, OptionsKit, scope, sink
  before_each(function()
    local _
    CommandKit, _, _, _, OptionsKit = TestEnv.NewPackage()
    scope = CommandKit:ForAddon("MyAddon")
    sink = CommandKit:CaptureSink()
    scope:SetSink(sink)
    scope:Register("tool", {
      subcommands = {
        config = { handler = noop },
        connect = { handler = noop },
        reset = { handler = noop },
        show = {
          handler = noop,
          complete = function(context, text, position)
            assert.are.equal("/tool show", context:GetCommandPath())
            if position == 1 then
              return { "player", "party", "target", 42 }
            end
            return { "second", "position " .. position .. " after " .. text }
          end,
        },
      },
    })
  end)
  after_each(TestEnv.Reset)

  local function press(text)
    local editBox = TestEnv.NewEditBox(text)
    local handled = TestEnv.PressTab(editBox)
    return handled, editBox.text
  end

  it("is off until EnableCompletion and leaves the client's function in place", function()
    assert.are.equal(TestEnv.OriginalTabPressed(), TestEnv.GetGlobal("ChatEdit_CustomTabPressed"))
    assert.are.same({ false, "/tool re" }, { press("/tool re") })
    assert.are.equal(1, TestEnv.OriginalTabCalls())
  end)

  it("completes a unique sub-command name", function()
    assert.is_true(scope:EnableCompletion())
    assert.are_not.equal(
      TestEnv.OriginalTabPressed(),
      TestEnv.GetGlobal("ChatEdit_CustomTabPressed")
    )
    assert.are.same({ true, "/tool reset " }, { press("/tool re") })
    assert.are.same({ true, "/TOOL show " }, { press("/TOOL SH") })
    assert.are.equal(0, TestEnv.OriginalTabCalls())
  end)

  it("fills the common prefix, then lists the candidates", function()
    scope:EnableCompletion()
    assert.are.same({ true, "/tool con" }, { press("/tool c") })
    assert.are.same({ true, "/tool con" }, { press("/tool con") })
    assert.are.same({ "config  connect" }, sink:Messages())
  end)

  it("offers what a custom complete function returns, filtered by prefix", function()
    scope:EnableCompletion()
    assert.are.same({ true, "/tool show target " }, { press("/tool show t") })
    assert.are.same({ true, "/tool show party " }, { press("/tool show pa") })
    assert.are.same({ true, "/tool show p" }, { press("/tool show p") })
    assert.are.same({ "player  party" }, sink:Messages())
    assert.are.same({ true, "/tool show party second " }, { press("/tool show party sec") })
  end)

  it("completes option paths of a bound command", function()
    OptionsKit:Define("MyAddon", {
      type = "group",
      args = {
        scale = { type = "range", name = "Scale", min = 0, max = 1, get = noop, set = noop },
        shown = { type = "toggle", name = "Shown", get = noop, set = noop },
        secret = { type = "toggle", name = "Secret", hidden = true, get = noop, set = noop },
        run = { type = "execute", name = "Run", func = noop },
      },
    })
    scope:BindOptions(OptionsKit:Get("MyAddon"), "opts")
    scope:EnableCompletion()
    assert.are.same({ true, "/opts set shown " }, { press("/opts set sho") })
    assert.are.same({ true, "/opts set s" }, { press("/opts set s") })
    assert.are.same({ "scale  shown" }, sink:Messages())
    assert.are.same({ true, "/opts exec run " }, { press("/opts exec ") })
    assert.are.same({ true, "/opts list " }, { press("/opts li") })
  end)

  it("forwards text that is not one of its commands to the previous function", function()
    scope:EnableCompletion()
    assert.are.same({ false, "/who x" }, { press("/who x") })
    assert.are.same({ false, "/tool" }, { press("/tool") })
    assert.are.same({ false, "hello" }, { press("hello") })
    assert.are.equal(3, TestEnv.OriginalTabCalls())
  end)

  it("uses ChatEdit_GetActiveWindow when the client passes no edit box", function()
    scope:EnableCompletion()
    local editBox = TestEnv.NewEditBox("/tool re")
    TestEnv.SetActiveEditBox(editBox)
    assert.is_true(TestEnv.PressTab(nil))
    assert.are.equal("/tool reset ", editBox.text)
  end)

  it("restores the previous function when the last scope disables completion", function()
    local other = CommandKit:CreateScope()
    scope:EnableCompletion()
    other:EnableCompletion()
    assert.is_true(scope:DisableCompletion())
    assert.is_false(scope:DisableCompletion())
    assert.are_not.equal(
      TestEnv.OriginalTabPressed(),
      TestEnv.GetGlobal("ChatEdit_CustomTabPressed")
    )
    other:Close()
    assert.are.equal(TestEnv.OriginalTabPressed(), TestEnv.GetGlobal("ChatEdit_CustomTabPressed"))
  end)

  it("stays in the chain, forwarding, when another addon replaced it since", function()
    scope:EnableCompletion()
    local ours = TestEnv.GetGlobal("ChatEdit_CustomTabPressed")
    local foreignCalls = 0
    TestEnv.SetGlobal("ChatEdit_CustomTabPressed", function(editBox)
      foreignCalls = foreignCalls + 1
      return ours(editBox)
    end)
    scope:DisableCompletion()
    assert.are_not.equal(
      TestEnv.OriginalTabPressed(),
      TestEnv.GetGlobal("ChatEdit_CustomTabPressed")
    )
    assert.are.same({ false, "/tool re" }, { press("/tool re") })
    assert.are.equal(1, foreignCalls)
    assert.are.equal(1, TestEnv.OriginalTabCalls())
    -- Enabling again reuses the closure still in the chain.
    scope:EnableCompletion()
    assert.are.same({ true, "/tool reset " }, { press("/tool re") })
  end)

  it("reports a failing complete function and falls back to the previous function", function()
    scope:Register("bad", {
      handler = noop,
      complete = function()
        error("no candidates", 0)
      end,
    })
    scope:EnableCompletion()
    assert.are.same({ false, "/bad x" }, { press("/bad x") })
    assert.are.same({ "no candidates" }, TestEnv.ReportedErrors())
    assert.are.equal(1, TestEnv.OriginalTabCalls())
  end)

  it("returns false from EnableCompletion without ChatEdit_CustomTabPressed", function()
    TestEnv.SetGlobal("ChatEdit_CustomTabPressed", nil)
    assert.is_false(scope:EnableCompletion())
    assert.is_nil(TestEnv.GetGlobal("ChatEdit_CustomTabPressed"))
  end)
end)
