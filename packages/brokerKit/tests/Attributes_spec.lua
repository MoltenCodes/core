local TestEnv = require("BrokerKitTestEnv")

describe("BrokerKit object attributes", function()
  local BrokerKit
  local object
  before_each(function()
    BrokerKit = TestEnv.NewPackage()
    object = BrokerKit:New("MyAddon", { text = "Ready" })
  end)
  after_each(TestEnv.Reset)

  it("reads attributes as plain fields and through Get", function()
    assert.are.equal("Ready", object.text)
    assert.are.equal("Ready", object:Get("text"))
    assert.is_nil(object.icon)
    assert.is_nil(object:Get("icon"))
  end)

  it("writes attributes as plain fields, as LibDataBroker does", function()
    object.text = "Busy"
    object.icon = 134400
    object.OnClick = function() end
    assert.are.equal("Busy", object.text)
    assert.are.equal(134400, object.icon)
    assert.is_function(object.OnClick)
  end)

  it("writes attributes through Set", function()
    object:Set("text", "Busy")
    object:Set("custom", { 1, 2 })
    assert.are.equal("Busy", object.text)
    assert.are.same({ 1, 2 }, object.custom)
  end)

  it("clears an attribute with nil, both ways", function()
    object.text = nil
    assert.is_nil(object.text)
    object:Set("text", "Back")
    object:Set("text", nil)
    assert.is_nil(object:Get("text"))
  end)

  it("keeps the proxy itself empty so every write goes through the object", function()
    object.text = "Busy"
    object.custom = 1
    assert.is_nil(rawget(object, "text"))
    assert.is_nil(rawget(object, "custom"))
    assert.is_nil(next(object))
  end)

  it("hides its metatable", function()
    assert.are.equal("BrokerKit.Object", getmetatable(object))
    assert.has_error(function()
      setmetatable(object, {})
    end)
  end)

  it("keeps name read-only", function()
    TestEnv.expectErrorContaining('BrokerKit.Object:Set attribute "name" is reserved', function()
      object.name = "Other"
    end)
    TestEnv.expectErrorContaining('BrokerKit.Object:Set attribute "name" is reserved', function()
      object:Set("name", "Other")
    end)
    TestEnv.expectErrorContaining('BrokerKit.Object:Get attribute "name" is reserved', function()
      object:Get("name")
    end)
    assert.are.equal("MyAddon", object.name)
  end)

  it("refuses the method names as attributes", function()
    TestEnv.expectErrorContaining('BrokerKit.Object:Set attribute "Set" is reserved', function()
      object.Set = 1
    end)
    TestEnv.expectErrorContaining('BrokerKit.Object:Set attribute "Get" is reserved', function()
      object:Set("Get", 1)
    end)
    assert.is_function(object.Set)
    assert.is_function(object.Get)
  end)

  it("type-checks known attributes on write and keeps the old value", function()
    TestEnv.expectErrorContaining(
      'BrokerKit.Object:Set attribute "text" must be a string',
      function()
        object.text = 42
      end
    )
    TestEnv.expectErrorContaining(
      'BrokerKit.Object:Set attribute "OnClick" must be a function',
      function()
        object:Set("OnClick", "click")
      end
    )
    TestEnv.expectErrorContaining(
      'BrokerKit.Object:Set attribute "type" must be "data source" or "launcher"',
      function()
        object.type = "widget"
      end
    )
    assert.are.equal("Ready", object.text)
    assert.are.equal("data source", object.type)
  end)

  it("never clears type", function()
    TestEnv.expectErrorContaining(
      'BrokerKit.Object:Set attribute "type" must be "data source" or "launcher"',
      function()
        object.type = nil
      end
    )
    object.type = "launcher"
    assert.are.equal("launcher", object.type)
  end)

  it("refuses malformed attribute names on write and read", function()
    TestEnv.expectErrorContaining(
      "BrokerKit.Object:Set attribute name must be a non-empty string",
      function()
        object[1] = "one"
      end
    )
    TestEnv.expectErrorContaining(
      "BrokerKit.Object:Set attribute name must be a non-empty string",
      function()
        object:Set("", "empty")
      end
    )
    TestEnv.expectErrorContaining(
      "BrokerKit.Object:Get attribute name must be a non-empty string",
      function()
        object:Get(nil)
      end
    )
  end)

  it("refuses the methods called without an object", function()
    TestEnv.expectErrorContaining(
      "BrokerKit.Object:Set must be called on a broker object; use object:Set(...)",
      function()
        object.Set("text", "Loose")
      end
    )
    TestEnv.expectErrorContaining(
      "BrokerKit.Object:Get must be called on a broker object; use object:Get(...)",
      function()
        object.Get({}, "text")
      end
    )
    TestEnv.expectErrorContaining(
      "BrokerKit.Object:OnChange must be called on a broker object; use object:OnChange(...)",
      function()
        object.OnChange(nil, function() end)
      end
    )
  end)

  it("shares the methods between objects and keeps identities apart", function()
    local other = BrokerKit:New("Other", { text = "Elsewhere" })
    assert.are.equal(object.Set, other.Set)
    assert.are.equal("Other", other.name)
    assert.are.equal("MyAddon", object.name)
    other.text = "Changed"
    assert.are.equal("Ready", object.text)
  end)
end)
