local TestEnv = require("CommandKitTestEnv")

-- The core and its two parts (ADR 0001): what the core says while a part is
-- missing, the load orders of core and part revisions, and the part's
-- refusal to load without its core. See docs/API.md, "Loading".

describe("CommandKit without its parts", function()
  local CommandKit

  before_each(function()
    CommandKit = TestEnv.NewPackageWithoutParts()
  end)

  after_each(TestEnv.Reset)

  it("raises at the caller with the file to embed for every part method", function()
    local scope = CommandKit:CreateScope()
    local options = { "BindOptions", "GetBoundTree" }
    local completion = {
      "EnableCompletion",
      "DisableCompletion",
      "RegisterCompletion",
      "UnregisterCompletion",
      "IsCompletionRegistered",
    }
    for _, methodName in ipairs(options) do
      TestEnv.expectErrorContaining(
        "CommandKit.Scope:"
          .. methodName
          .. " needs CommandKit's Options part, which is not loaded:"
          .. " add commandKit\\parts\\CommandKit-Options.lua to your embeds.xml",
        function()
          scope[methodName](scope)
        end
      )
    end
    for _, methodName in ipairs(completion) do
      TestEnv.expectErrorContaining(
        "add commandKit\\parts\\CommandKit-Completion.lua to your embeds.xml",
        function()
          scope[methodName](scope)
        end
      )
    end
    local ok, message = pcall(function()
      scope:BindOptions()
    end)
    assert.is_false(ok)
    assert.is_not_nil(tostring(message):find("Parts_spec.lua:", 1, true))
  end)

  it("still registers, dispatches and closes", function()
    local scope = CommandKit:ForAddon("MyAddon")
    local calls = 0
    scope:Register("plain", {
      handler = function()
        calls = calls + 1
      end,
    })
    TestEnv.RunSlash("/plain")

    assert.are.equal(1, calls)
    assert.is_true(scope:Close())
    assert.are.equal(TestEnv.OriginalTabPressed(), TestEnv.GetGlobal("ChatEdit_CustomTabPressed"))
  end)

  it("serves a part loaded after the core, and a core loaded again after the part", function()
    require("CommandKit-Completion")
    local scope = CommandKit:CreateScope()
    assert.is_true(scope:EnableCompletion())

    local upgraded = TestEnv.LoadRevision(CommandKit.REVISION + 1)

    assert.are.equal(CommandKit, upgraded)
    assert.is_true(scope:DisableCompletion())
    TestEnv.expectErrorContaining("needs CommandKit's Options part", function()
      scope:BindOptions()
    end)
  end)
end)

describe("CommandKit part revisions", function()
  after_each(TestEnv.Reset)

  it("lets a newer part revision replace the methods, and an older one change nothing", function()
    local CommandKit = TestEnv.NewPackage()
    local parts = rawget(rawget(CommandKit, "_state"), "parts")
    local first = rawget(CommandKit.Scope, "BindOptions")

    TestEnv.LoadPartRevision("Options", 1)
    assert.are.equal(first, rawget(CommandKit.Scope, "BindOptions"))
    assert.are.equal(2, parts.Options.revision)

    TestEnv.LoadPartRevision("Options", 3)
    assert.are.equal(3, parts.Options.revision)
    assert.are_not.equal(first, rawget(CommandKit.Scope, "BindOptions"))
    assert.are.equal(parts.Options.methods.BindOptions, rawget(CommandKit.Scope, "BindOptions"))
  end)

  it("refuses to load a part before its core", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    require("Registry")
    for _, partName in ipairs({ "Arguments", "Options", "Completion" }) do
      local ok, message = pcall(require, "CommandKit-" .. partName)
      assert.is_false(ok)
      assert.is_not_nil(
        tostring(message):find(
          "MoltenCodes CommandKit part "
            .. partName
            .. " requires CommandKit API 1 to be loaded first",
          1,
          true
        )
      )
      package.loaded["CommandKit-" .. partName] = nil
    end
  end)
end)

describe("CommandKit in-place upgrade from revision 10", function()
  after_each(TestEnv.Reset)

  it("keeps a bound command and enabled completion, and adds the part state", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    TestEnv.InstallChatApi()
    require("Registry")
    require("SignalKit")
    require("SchemaKit")
    local OptionsKit = require("OptionsKit")
    local previous = TestEnv.LoadRevision(10)
    require("CommandKit-Arguments")
    require("CommandKit-Options")
    require("CommandKit-Completion")
    local state = rawget(previous, "_state")
    local tree = OptionsKit:Define("MyAddon", {
      type = "group",
      args = {
        size = {
          type = "range",
          name = "Size",
          min = 1,
          max = 9,
          get = function()
            return 3
          end,
          set = function() end,
        },
      },
    })
    local scope = previous:ForAddon("MyAddon")
    local sink = previous:CaptureSink()
    scope:SetSink(sink)
    scope:BindOptions(tree, "cfg")
    scope:EnableCompletion()
    -- What revision 10 left: no part records, no helpers, no provider limit,
    -- and its own tab function behind the installed closure.
    local tabPressed = rawget(rawget(state, "dispatch"), "tabPressed")
    rawset(state, "parts", nil)
    rawset(state, "helpers", nil)
    rawset(rawget(state, "limits"), "maxCompletionProviders", nil)

    local upgraded = require("CommandKit")

    assert.are.equal(12, upgraded.REVISION)
    assert.are.same({}, rawget(state, "parts"))
    -- The addon that brought revision 12 embeds the Arguments part, which
    -- loads after its core and serves the records revision 10 compiled.
    TestEnv.LoadPartRevision("Arguments", 1)
    assert.are.equal(32, upgraded:GetLimits().maxCompletionProviders)
    assert.are.equal(tabPressed, rawget(rawget(state, "dispatch"), "tabPressed"))
    TestEnv.RunSlash("/cfg get size")
    assert.are.same({ "size = 3" }, sink:Messages())
    local editBox = TestEnv.NewEditBox("/cfg ge")
    assert.is_true(TestEnv.PressTab(editBox))
    assert.are.equal("/cfg get ", editBox.text)
    -- Without the parts, the methods name the files; closing still counts
    -- the scope's completion off.
    TestEnv.expectErrorContaining("needs CommandKit's Options part", function()
      scope:GetBoundTree("cfg")
    end)
    assert.is_true(scope:Close())
    assert.are.equal(0, rawget(state, "completion").enabledScopes)
  end)
end)
