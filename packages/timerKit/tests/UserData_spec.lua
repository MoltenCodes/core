local TestEnv = require("TimerKitTestEnv")

describe("TimerKit timer user data", function()
  after_each(TestEnv.Reset)

  it("returns nil until a value is attached", function()
    local TimerKit = TestEnv.NewPackage()
    local timer = TimerKit:New({ delay = 1, callback = function() end })
    assert.is_nil(timer:GetUserData())
  end)

  it("stores one opaque value by reference and returns the timer for chaining", function()
    local TimerKit = TestEnv.NewPackage()
    local timer = TimerKit:New({ delay = 1, callback = function() end })
    local marker = {}

    assert.are.equal(timer, timer:SetUserData(marker))
    assert.are.equal(marker, timer:GetUserData())
  end)

  it("keeps user data across cancel and restart", function()
    local TimerKit = TestEnv.NewPackage()
    local timer = TimerKit:After(1, function() end)
    timer:SetUserData("owner state")

    timer:Cancel()
    assert.are.equal("owner state", timer:GetUserData())
    timer:Restart()
    assert.are.equal("owner state", timer:GetUserData())
  end)

  it("detaches the value when set to nil", function()
    local TimerKit = TestEnv.NewPackage()
    local timer = TimerKit:New({ delay = 1, callback = function() end })
    timer:SetUserData(42)
    timer:SetUserData(nil)
    assert.is_nil(timer:GetUserData())
  end)

  it("is reachable from the timer handle a callback receives", function()
    local TimerKit = TestEnv.NewPackage()
    local observed
    local timer = TimerKit:After(1, function(self)
      observed = self:GetUserData()
    end)
    timer:SetUserData("attached before the host fires")

    TestEnv.FireNative(1)
    assert.are.equal("attached before the host fires", observed)
  end)

  it("keeps user data private to each timer", function()
    local TimerKit = TestEnv.NewPackage()
    local first = TimerKit:New({ delay = 1, callback = function() end })
    local second = TimerKit:New({ delay = 1, callback = function() end })

    first:SetUserData("first")
    assert.is_nil(second:GetUserData())
    assert.are.equal("first", first:GetUserData())
  end)
end)
