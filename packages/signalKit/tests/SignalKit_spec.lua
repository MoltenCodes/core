local TestEnv = require("SignalKitTestEnv")

describe("SignalKit", function()
  local SignalKit

  before_each(function()
    SignalKit = TestEnv.NewPackage()
  end)

  after_each(TestEnv.Reset)

  it("creates independent signal instances", function()
    local first = SignalKit:New()
    local second = SignalKit:New()

    assert.are_not.equal(first, second)
  end)

  it("supports both colon and dot construction", function()
    local colon = SignalKit:New()
    local dot = SignalKit.New()

    assert.is_not_nil(colon)
    assert.is_not_nil(dot)
    assert.are_not.equal(colon, dot)
  end)

  it("fires connected listeners in connection order", function()
    local signal = SignalKit:New()
    local calls = {}

    signal:Connect(function()
      calls[#calls + 1] = "first"
    end)
    signal:Connect(function()
      calls[#calls + 1] = "second"
    end)
    signal:Connect(function()
      calls[#calls + 1] = "third"
    end)

    signal:Fire()

    assert.are.equal("first", calls[1])
    assert.are.equal("second", calls[2])
    assert.are.equal("third", calls[3])
    assert.are.equal(3, #calls)
  end)

  it("forwards every argument including nil values", function()
    local signal = SignalKit:New()
    local count
    local first
    local second
    local third

    signal:Connect(function(...)
      count = select("#", ...)
      first, second, third = ...
    end)

    signal:Fire("player", nil, 42)

    assert.are.equal(3, count)
    assert.are.equal("player", first)
    assert.is_nil(second)
    assert.are.equal(42, third)
  end)

  it("allows the same callback to be connected more than once", function()
    local signal = SignalKit:New()
    local calls = 0
    local callback = function()
      calls = calls + 1
    end

    signal:Connect(callback)
    signal:Connect(callback)
    signal:Fire()

    assert.are.equal(2, calls)
  end)

  it("ignores callback return values", function()
    local signal = SignalKit:New()
    local calls = 0

    signal:Connect(function()
      calls = calls + 1
      return "ignored"
    end)

    local result = signal:Fire()

    assert.is_nil(result)
    assert.are.equal(1, calls)
  end)

  it("keeps separate signals isolated", function()
    local first = SignalKit:New()
    local second = SignalKit:New()
    local firstCalls = 0
    local secondCalls = 0

    first:Connect(function()
      firstCalls = firstCalls + 1
    end)
    second:Connect(function()
      secondCalls = secondCalls + 1
    end)

    first:Fire()

    assert.are.equal(1, firstCalls)
    assert.are.equal(0, secondCalls)
  end)
end)
