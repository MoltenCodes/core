local TestEnv = require("CommandKitTestEnv")

-- `RegisterCompletion`, AceTab-3.0's counterpart: providers that complete any
-- word of chat input whose preceding text matches their pattern
-- (docs/API.md, "Completion providers").

describe("CommandKit completion providers", function()
  local CommandKit, scope, sink

  before_each(function()
    CommandKit = TestEnv.NewPackage()
    TestEnv.InstallHostErrorHandler()
    scope = CommandKit:ForAddon("MyAddon")
    sink = CommandKit:CaptureSink()
    scope:SetSink(sink)
  end)

  after_each(TestEnv.Reset)

  local function press(text)
    local editBox = TestEnv.NewEditBox(text)
    local handled = TestEnv.PressTab(editBox)
    return handled, editBox.text
  end

  local function names()
    return { "Arthas", "Anduin", "Baine" }
  end

  it("completes a word when the text before it matches the pattern", function()
    local seen = {}
    assert.is_true(scope:RegisterCompletion("whisper", "^/w%s+$", function(partial, before, editBox)
      seen[#seen + 1] = { partial, before, type(editBox) }
      return names()
    end))

    assert.are.same({ true, "/w Baine " }, { press("/w b") })
    assert.are.same({ { "b", "/w ", "table" } }, seen)
    assert.are.same({ false, "hello b" }, { press("hello b") })
    assert.are.equal(1, TestEnv.OriginalTabCalls())
  end)

  it("matches anywhere with an empty pattern and fills the common prefix, then lists", function()
    scope:SetPrefix("> ")
    scope:RegisterCompletion("names", "", names)

    assert.are.same({ true, "hi a" }, { press("hi a") })
    assert.are.same({ "> Arthas  Anduin" }, sink:Messages())
    assert.are.same({ true, "hi Anduin " }, { press("hi an") })
  end)

  it("merges providers in registration order and keeps going after one raises", function()
    local other = CommandKit:CreateScope()
    scope:RegisterCompletion("broken", "", function()
      error("provider broke")
    end)
    scope:RegisterCompletion("first", "", function()
      return { "alpha", 7, "beta" }
    end)
    other:RegisterCompletion("second", "", function()
      return { "alpine" }
    end)

    assert.are.same({ true, "alp" }, { press("a") })
    assert.are.equal(1, #TestEnv.ReportedErrors())
    assert.is_not_nil(tostring(TestEnv.ReportedErrors()[1]):find("provider broke", 1, true))
  end)

  it("lets the scope's own command completion come first", function()
    scope:Register("tool", { subcommands = { reset = { handler = function() end } } })
    scope:EnableCompletion()
    scope:RegisterCompletion("names", "", function()
      return { "reroll" }
    end)

    assert.are.same({ true, "/tool reset " }, { press("/tool re") })
    assert.are.same({ true, "/other reroll " }, { press("/other re") })
  end)

  it("refuses a taken name and a full list, and releases providers with the scope", function()
    assert.is_true(scope:RegisterCompletion("names", "", names))
    assert.are.same({ nil, "taken" }, { scope:RegisterCompletion("names", "", names) })
    assert.is_true(scope:IsCompletionRegistered("names"))
    CommandKit:SetLimits({ maxCompletionProviders = 1 })
    assert.are.same({ nil, "full" }, { scope:RegisterCompletion("more", "", names) })

    assert.is_true(scope:UnregisterCompletion("names"))
    assert.is_false(scope:UnregisterCompletion("names"))
    assert.are.equal(TestEnv.OriginalTabPressed(), TestEnv.GetGlobal("ChatEdit_CustomTabPressed"))

    scope:RegisterCompletion("names", "", names)
    assert.are_not.equal(
      TestEnv.OriginalTabPressed(),
      TestEnv.GetGlobal("ChatEdit_CustomTabPressed")
    )
    scope:Close()
    assert.are.equal(TestEnv.OriginalTabPressed(), TestEnv.GetGlobal("ChatEdit_CustomTabPressed"))
    assert.are.same({ false, "a" }, { press("a") })
  end)

  it("leaves text whose cursor is not at its end to the client", function()
    scope:RegisterCompletion("names", "", names)
    local editBox = TestEnv.NewEditBox("a b")
    editBox.GetCursorPosition = function()
      return 1
    end

    assert.is_false(TestEnv.PressTab(editBox))
  end)

  it("answers unavailable on a host without the hook", function()
    TestEnv.SetGlobal("ChatEdit_CustomTabPressed", nil)

    assert.are.same({ nil, "unavailable" }, { scope:RegisterCompletion("names", "", names) })
  end)

  it("checks its arguments at the caller", function()
    TestEnv.expectErrorContaining("RegisterCompletion name must be a non-empty string", function()
      scope:RegisterCompletion("", "", names)
    end)
    TestEnv.expectErrorContaining("RegisterCompletion pattern must be a string", function()
      scope:RegisterCompletion("names", nil, names)
    end)
    TestEnv.expectErrorContaining(
      "RegisterCompletion pattern is not a valid Lua pattern",
      function()
        scope:RegisterCompletion("names", "[", names)
      end
    )
    TestEnv.expectErrorContaining("RegisterCompletion provider must be a function", function()
      scope:RegisterCompletion("names", "", {})
    end)
    TestEnv.expectErrorContaining(
      "maxCompletionProviders cannot be CommandKit.UNBOUNDED",
      function()
        CommandKit:SetLimits({ maxCompletionProviders = CommandKit.UNBOUNDED })
      end
    )
    scope:Close()
    TestEnv.expectErrorContaining("RegisterCompletion cannot be used on a closed scope", function()
      scope:RegisterCompletion("names", "", names)
    end)
  end)
end)
