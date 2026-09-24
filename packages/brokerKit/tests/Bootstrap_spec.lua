local TestEnv = require("BrokerKitTestEnv")

describe("BrokerKit bootstrap", function()
  after_each(TestEnv.Reset)

  it("returns the same facade on duplicate embedded load and keeps objects", function()
    local BrokerKit = TestEnv.NewPackage()
    local object = BrokerKit:New("Mine", { text = "Ready" })

    local reloaded = TestEnv.ReloadPackage()
    assert.are.equal(BrokerKit, reloaded)
    assert.are.equal(object, reloaded:Get("Mine"))
    assert.are.same({ "Mine" }, reloaded:Objects())
  end)

  it("publishes through Registry", function()
    local BrokerKit, Registry = TestEnv.NewPackage()
    local registered, revision = Registry:Get("brokerKit", 1)
    assert.are.equal(BrokerKit, registered)
    assert.are.equal(BrokerKit.REVISION, revision)
  end)

  it("does not reinterpret private state owned by a newer compatible revision", function()
    local BrokerKit, Registry = TestEnv.NewPackage()
    local shippedRevision = BrokerKit.REVISION
    local upgraded, previous = Registry:Register("brokerKit", 1, 99)
    assert.are.equal(BrokerKit, upgraded)
    assert.are.equal(shippedRevision, previous)

    rawset(BrokerKit, "REVISION", 99)
    rawset(BrokerKit, "_state", { schema = 999 })
    package.loaded["BrokerKit"] = nil

    local reloaded = require("BrokerKit")
    assert.are.equal(BrokerKit, reloaded)
    assert.are.equal(99, reloaded.REVISION)
  end)

  it(
    "upgrades in place and keeps objects, connections, the sorted cache and LibDataBroker links",
    function()
      local BrokerKit = TestEnv.NewPackage()
      local library = TestEnv.InstallLibDataBroker({
        objects = { Theirs = { type = "data source", text = "T" } },
      })
      local mine = BrokerKit:New("Mine", { text = "Ready" })
      local seen = {}
      local connection = mine:OnChange("text", function(_, _, value)
        seen[#seen + 1] = value
      end)
      local added = {}
      BrokerKit:OnObjectAdded(function(object)
        added[#added + 1] = object.name
      end)
      BrokerKit:AdoptFromLibDataBroker()
      BrokerKit:ExposeToLibDataBroker()
      local names = BrokerKit:Objects()

      local nextRevision = BrokerKit.REVISION + 1
      local upgraded = TestEnv.LoadRevision(nextRevision)
      assert.are.equal(BrokerKit, upgraded)
      assert.are.equal(nextRevision, upgraded.REVISION)

      -- Objects, their identity and the foreign flag are the same.
      assert.are.equal(mine, upgraded:Get("Mine"))
      assert.are.same(names, upgraded:Objects())
      assert.is_true(upgraded:IsForeign(upgraded:Get("Theirs")))

      -- The object runs the new methods and its field writes still fire
      -- the connection an older copy handed out and reach LibDataBroker.
      mine.text = "After"
      mine:Set("text", "Again")
      assert.are.same({ "After", "Again" }, seen)
      assert.is_true(connection:IsConnected())
      assert.are.equal("Again", library:GetDataObjectByName("Mine").text)

      -- Adoption keeps following without a second subscription, and
      -- exposing keeps following without a second exposure.
      library:NewDataObject("Later", { type = "launcher" })
      assert.are.equal("launcher", upgraded:Get("Later").type)
      library:GetDataObjectByName("Theirs").text = "Changed"
      assert.are.equal("Changed", upgraded:Get("Theirs").text)
      assert.are.equal(2, library.CallbackCount())
      assert.are.same({ false, "already" }, { upgraded:AdoptFromLibDataBroker() })
      assert.are.same({ false, "already" }, { upgraded:ExposeToLibDataBroker() })
      upgraded:New("Fresh")
      assert.is_not_nil(library:GetDataObjectByName("Fresh"))
      assert.are.same({ "Theirs", "Later", "Fresh" }, added)

      -- A foreign object is still read-only through the new code.
      TestEnv.expectErrorContaining("is foreign", function()
        upgraded:Get("Theirs").text = "Mine"
      end)
    end
  )

  it("takes over the previous revision's state in place", function()
    local shippedRevision = TestEnv.NewPackage().REVISION
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    require("Registry")
    require("SignalKit")
    local library = TestEnv.InstallLibDataBroker({
      objects = { Theirs = { type = "data source", text = "T" } },
    })
    local previous = TestEnv.LoadRevision(shippedRevision - 1)
    assert.are.equal(shippedRevision - 1, previous.REVISION)
    local state = previous._state
    local mine = previous:New("Mine", { text = "Ready" })
    local seen = {}
    mine:OnChange("text", function(_, _, value)
      seen[#seen + 1] = value
    end)
    previous:AdoptFromLibDataBroker()
    previous:SetLimits({ maxObjects = 300 })

    local BrokerKit = TestEnv.ReloadPackage()
    assert.are.equal(previous, BrokerKit)
    assert.are.equal(shippedRevision, BrokerKit.REVISION)
    assert.are.equal(state, BrokerKit._state)
    assert.are.equal(mine, BrokerKit:Get("Mine"))
    assert.are.equal(300, BrokerKit:GetLimits().maxObjects)
    mine.text = "After"
    assert.are.same({ "After" }, seen)

    -- The fix the shipped revision carries: a foreign change whose data
    -- object is not the adopted table is ignored before it is compared.
    library.Fire("LibDataBroker_AttributeChanged", "Theirs", "text", "Changed", "other")
    assert.are.equal("T", BrokerKit:Get("Theirs").text)
    library:GetDataObjectByName("Theirs").text = "Changed"
    assert.are.equal("Changed", BrokerKit:Get("Theirs").text)
  end)

  it("upgrades in place and keeps the set limits and the UNBOUNDED sentinel", function()
    local BrokerKit = TestEnv.NewPackage()
    local unbounded = BrokerKit.UNBOUNDED
    BrokerKit:SetLimits({ maxObjects = 4096, maxAttributes = unbounded })

    local upgraded = TestEnv.LoadRevision(BrokerKit.REVISION + 1)
    assert.are.equal(unbounded, upgraded.UNBOUNDED)
    assert.are.same({ maxObjects = 4096, maxAttributes = unbounded }, upgraded:GetLimits())
    assert.are.equal(unbounded, upgraded:GetLimits().maxAttributes)
  end)

  it("refuses shared state whose limits hold an invalid value", function()
    local BrokerKit = TestEnv.NewPackage()
    rawset(BrokerKit._state.limits, "maxObjects", 0)
    TestEnv.expectErrorContaining("package state is corrupted or incomplete", function()
      TestEnv.ReloadPackage()
    end)
  end)

  it("requires Registry", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    local ok, value = pcall(require, "BrokerKit")
    assert.is_false(ok)
    assert.is_true(tostring(value):find("Registry API 2", 1, true) ~= nil)
  end)

  it("requires SignalKit", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    require("Registry")
    local ok, value = pcall(TestEnv.requireAfterFailedLoad, "BrokerKit")
    assert.is_false(ok)
    assert.is_true(tostring(value):find("SignalKit API 1", 1, true) ~= nil)
  end)

  it("refuses an incomplete facade left by an earlier failed load", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    local Registry = require("Registry")
    require("SignalKit")
    Registry:Register("brokerKit", 1, 1)

    local ok, value = pcall(TestEnv.requireAfterFailedLoad, "BrokerKit")
    assert.is_false(ok)
    assert.is_true(tostring(value):find("MoltenCodes BrokerKit", 1, true) ~= nil)
  end)
end)
