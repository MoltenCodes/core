local TestEnv = require("CommandKitTestEnv")

describe("CommandKit sinks", function()
  local CommandKit, scope
  before_each(function()
    CommandKit = TestEnv.NewPackage()
    scope = CommandKit:CreateScope()
    scope:Register("hello", {
      handler = function(context, name)
        context:Print("hello", name)
      end,
    })
  end)
  after_each(TestEnv.Reset)

  it("writes to DEFAULT_CHAT_FRAME by default", function()
    TestEnv.RunSlash("/hello world")
    assert.are.same({ "hello world" }, TestEnv.ChatLines())
  end)

  it("writes to the scope's sink, and back to the chat frame after SetSink(nil)", function()
    local lines = {}
    scope:SetSink({
      AddMessage = function(_, text)
        lines[#lines + 1] = text
      end,
    })
    TestEnv.RunSlash("/hello sink")
    scope:SetSink(nil)
    TestEnv.RunSlash("/hello chat")
    assert.are.same({ "hello sink" }, lines)
    assert.are.same({ "hello chat" }, TestEnv.ChatLines())
  end)

  it("falls back to print without a chat frame", function()
    TestEnv.SetGlobal("DEFAULT_CHAT_FRAME", nil)
    local printed = {}
    local originalPrint = print
    -- selene: allow(global_usage)
    _G.print = function(text)
      printed[#printed + 1] = text
    end
    local ok, failure = pcall(TestEnv.RunSlash, "/hello print")
    -- selene: allow(global_usage)
    _G.print = originalPrint
    assert.is_true(ok, failure)
    assert.are.same({ "hello print" }, printed)
  end)

  it("captures, copies, clears and bounds with CaptureSink", function()
    local capture = CommandKit:CaptureSink()
    scope:SetSink(capture)
    TestEnv.RunSlash("/hello one")
    local messages = capture:Messages()
    messages[1] = "edited"
    assert.are.same({ "hello one" }, capture:Messages())
    capture:Clear()
    assert.are.same({}, capture:Messages())
    for index = 1, 300 do
      capture:AddMessage("line " .. index)
    end
    local kept = capture:Messages()
    assert.are.equal(256, #kept)
    assert.are.equal("line 45", kept[1])
    assert.are.equal("line 300", kept[256])
  end)

  it("refuses a sink without AddMessage", function()
    TestEnv.expectErrorContaining("sink must be a table with an AddMessage method", function()
      scope:SetSink({})
    end)
  end)
end)
