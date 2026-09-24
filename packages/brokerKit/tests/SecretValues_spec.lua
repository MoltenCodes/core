local TestEnv = require("BrokerKitTestEnv")

describe("BrokerKit and secret values", function()
  local BrokerKit
  before_each(function()
    BrokerKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("refuses a secret name at the caller", function()
    local secret = "Secret Name"
    TestEnv.InstallSecretProbe(secret)
    TestEnv.expectErrorContaining("BrokerKit:New name must not be a secret value", function()
      BrokerKit:New(secret)
    end)
    TestEnv.expectErrorContaining("BrokerKit:Get name must not be a secret value", function()
      BrokerKit:Get(secret)
    end)
  end)

  it("refuses a secret attribute name everywhere", function()
    local secret = "secretAttribute"
    local object = BrokerKit:New("Mine")
    TestEnv.InstallSecretProbe(secret)
    TestEnv.expectErrorContaining(
      "BrokerKit.Object:Set attribute name must not be a secret value",
      function()
        object[secret] = 1
      end
    )
    TestEnv.expectErrorContaining(
      "BrokerKit.Object:Set attribute name must not be a secret value",
      function()
        object:Set(secret, 1)
      end
    )
    TestEnv.expectErrorContaining(
      "BrokerKit.Object:Get attribute name must not be a secret value",
      function()
        object:Get(secret)
      end
    )
    TestEnv.expectErrorContaining(
      "BrokerKit.Object:OnChange attribute name must not be a secret value",
      function()
        object:OnChange(secret, function() end)
      end
    )
    TestEnv.expectErrorContaining(
      "BrokerKit:New attribute name must not be a secret value",
      function()
        BrokerKit:New("Other", { [secret] = 1 })
      end
    )
  end)

  it("refuses a secret value for a known attribute at the caller", function()
    local secret = "Secret Text"
    local object = BrokerKit:New("Mine", { text = "Plain" })
    TestEnv.InstallSecretProbe(secret)
    TestEnv.expectErrorContaining(
      'BrokerKit.Object:Set attribute "text" must not be a secret value',
      function()
        object.text = secret
      end
    )
    TestEnv.expectErrorContaining(
      'BrokerKit:New attribute "text" must not be a secret value',
      function()
        BrokerKit:New("Other", { text = secret })
      end
    )
    assert.are.equal("Plain", object.text)
  end)

  it("stores a secret custom value without comparing it, and fires every time", function()
    local secret = "Secret Custom"
    local object = BrokerKit:New("Mine")
    TestEnv.InstallSecretProbe(secret)
    local count = 0
    object:OnChange("hidden", function()
      count = count + 1
    end)
    object.hidden = secret
    object.hidden = secret
    assert.are.equal(secret, object.hidden)
    assert.are.equal(2, count)
    object:Set("hidden", "plain")
    object.hidden = "plain"
    assert.are.equal("plain", object:Get("hidden"))
    assert.are.equal(3, count)
  end)

  it("never mirrors a secret value into LibDataBroker", function()
    local secret = "Secret Custom"
    local library = TestEnv.InstallLibDataBroker()
    local object = BrokerKit:New("Mine", { text = "Plain" })
    TestEnv.InstallSecretProbe(secret)
    object.hidden = secret
    BrokerKit:ExposeToLibDataBroker()
    local mirror = library:GetDataObjectByName("Mine")
    assert.are.equal("Plain", mirror.text)
    assert.is_nil(mirror.hidden)

    object.other = secret
    assert.is_nil(mirror.other)
    object.other = "shown"
    assert.are.equal("shown", mirror.other)
  end)

  it("skips secret foreign names and attribute names when adopting", function()
    local secretName = "Secret Object"
    local secretAttribute = "secretAttribute"
    local library = TestEnv.InstallLibDataBroker({
      objects = {
        [secretName] = { type = "data source" },
        Plain = { type = "data source", text = "T", [secretAttribute] = 1 },
      },
    })
    TestEnv.InstallSecretProbe(secretName)
    assert.is_true(BrokerKit:AdoptFromLibDataBroker())
    assert.are.same({ "Plain" }, BrokerKit:Objects())

    TestEnv.InstallSecretProbe(secretAttribute)
    library:NewDataObject("Later", { [secretAttribute] = 1, type = "launcher" })
    assert.are.equal("launcher", BrokerKit:Get("Later").type)
  end)

  it("keeps a secret foreign value without comparing it", function()
    local secret = "Secret Foreign"
    local library =
      TestEnv.InstallLibDataBroker({ objects = { Theirs = { type = "data source" } } })
    BrokerKit:AdoptFromLibDataBroker()
    local theirs = BrokerKit:Get("Theirs")
    local count = 0
    theirs:OnChange(function()
      count = count + 1
    end)
    TestEnv.InstallSecretProbe(secret)
    -- Delivered as LibDataBroker would deliver it, past its own comparison.
    library.Fire(
      "LibDataBroker_AttributeChanged",
      "Theirs",
      "text",
      secret,
      library:GetDataObjectByName("Theirs")
    )
    library.Fire(
      "LibDataBroker_AttributeChanged",
      "Theirs",
      "text",
      secret,
      library:GetDataObjectByName("Theirs")
    )
    assert.are.equal(secret, theirs.text)
    assert.are.equal(2, count)
  end)

  it("refuses a secret limit value at the caller", function()
    local secret = 64
    TestEnv.InstallSecretProbe(secret)
    TestEnv.expectErrorContaining(
      "BrokerKit:SetLimits limits.maxObjects must not be a secret value",
      function()
        BrokerKit:SetLimits({ maxObjects = secret })
      end
    )
  end)

  it("reports a secret receiver as a facade misuse at the caller's line", function()
    local secret = "Secret Receiver"
    TestEnv.InstallSecretProbe(secret)
    local action = function()
      BrokerKit.Get(secret, "Mine")
    end
    local ok, value = pcall(action)
    assert.is_false(ok)
    assert.are.equal(
      debug.getinfo(1, "S").short_src
        .. ":"
        .. debug.getinfo(action, "S").linedefined + 1
        .. ": BrokerKit:Get must be called on the BrokerKit facade; use BrokerKit:Get(...)",
      value
    )
  end)

  it("ignores a foreign change whose data object is secret", function()
    local secret = "Secret Data Object"
    local library =
      TestEnv.InstallLibDataBroker({ objects = { Theirs = { type = "data source" } } })
    BrokerKit:AdoptFromLibDataBroker()
    local theirs = BrokerKit:Get("Theirs")
    local count = 0
    theirs:OnChange(function()
      count = count + 1
    end)
    TestEnv.InstallSecretProbe(secret)
    library.Fire("LibDataBroker_AttributeChanged", "Theirs", "text", "Changed", secret)
    assert.is_nil(theirs.text)
    assert.are.equal(0, count)
  end)

  it("looks the probe up at call time", function()
    local object = BrokerKit:New("Mine", { text = "Late" })
    TestEnv.InstallSecretProbe("Late")
    TestEnv.expectErrorContaining("must not be a secret value", function()
      object.text = "Late"
    end)
  end)

  it("describes a secret SetLimits key with the placeholder at the caller", function()
    -- A plain string stands in for a secret key: the probe reports it
    -- secret, so it must neither index the limit table nor reach the
    -- message; the limits stay as they were.
    TestEnv.InstallSecretProbe("maxObjects")
    local source = debug.getinfo(1, "S").short_src
    local line = debug.getinfo(1, "l").currentline + 2
    local ok, value = pcall(function()
      BrokerKit:SetLimits({ maxObjects = 300 })
    end)
    assert.is_false(ok)
    assert.are.equal(
      source
        .. ":"
        .. line
        .. ": BrokerKit:SetLimits limits.<secret value> is not a recognised limit",
      value
    )
    assert.are.equal(256, BrokerKit:GetLimits().maxObjects)
  end)

  it("describes a table SetLimits key by its type without running __tostring", function()
    local ran = false
    local key = setmetatable({}, {
      __tostring = function()
        ran = true
        return "foreign"
      end,
    })
    TestEnv.expectErrorContaining(
      "BrokerKit:SetLimits limits.<table> is not a recognised limit",
      function()
        BrokerKit:SetLimits({ [key] = 1 })
      end
    )
    assert.is_false(ran)
  end)
end)
