local TestEnv = require("MediaKitTestEnv")

describe("MediaKit:OnRegistered", function()
  local MediaKit
  before_each(function()
    MediaKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("fires with the type, name and data of each new entry of its type", function()
    local seen = {}
    MediaKit:OnRegistered("sound", function(mediaType, name, data)
      seen[#seen + 1] = { mediaType, name, data }
    end)
    MediaKit:Register("sound", "Ding", 554003)
    MediaKit:Register("statusbar", "Other Type", "Interface\\Pack\\Bar")
    MediaKit:Register("sound", "Dong", "Interface\\Pack\\Dong.ogg")
    assert.are.same({
      { "sound", "Ding", 554003 },
      { "sound", "Dong", "Interface\\Pack\\Dong.ogg" },
    }, seen)
  end)

  it("does not fire for a refused or identical registration", function()
    local count = 0
    MediaKit:OnRegistered("sound", function()
      count = count + 1
    end)
    MediaKit:Register("sound", "None", "Interface\\Other.ogg")
    MediaKit:Register("sound", "None", [[Interface\Quiet.ogg]])
    assert.are.equal(0, count)
  end)

  it("returns a SignalKit connection the caller owns", function()
    local count = 0
    local connection = MediaKit:OnRegistered("sound", function()
      count = count + 1
    end)
    assert.is_true(connection:IsConnected())
    MediaKit:Register("sound", "One", 1)
    assert.is_true(connection:Disconnect())
    MediaKit:Register("sound", "Two", 2)
    assert.are.equal(1, count)
  end)

  it("lets a listener see the new entry in Fetch and List", function()
    local listed
    MediaKit:OnRegistered("statusbar", function(mediaType, name)
      listed = MediaKit:List(mediaType)
      assert.are.equal("Interface\\Pack\\Bar", MediaKit:Fetch(mediaType, name))
    end)
    MediaKit:Register("statusbar", "Pack Bar", "Interface\\Pack\\Bar")
    assert.are.same({ "Blizzard", "Pack Bar", "Solid" }, listed)
  end)

  it("propagates a listener error to the registering caller after the entry is stored", function()
    MediaKit:OnRegistered("sound", function()
      error("listener failed", 0)
    end)
    local ok, failure = pcall(MediaKit.Register, MediaKit, "sound", "Ding", 1)
    assert.is_false(ok)
    assert.are.equal("listener failed", failure)
    assert.are.equal(1, MediaKit:Fetch("sound", "Ding"))
  end)

  it("refuses an unknown type and a callback that is not a function", function()
    TestEnv.expectErrorContaining("MediaKit:OnRegistered type must be one of", function()
      MediaKit:OnRegistered("music", function() end)
    end)
    TestEnv.expectErrorContaining("MediaKit:OnRegistered callback must be a function", function()
      MediaKit:OnRegistered("sound", "handler")
    end)
  end)
end)
