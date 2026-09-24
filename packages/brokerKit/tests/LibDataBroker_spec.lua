local TestEnv = require("BrokerKitTestEnv")

describe("BrokerKit and LibDataBroker", function()
  local BrokerKit
  before_each(function()
    BrokerKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  describe("without LibStub or LibDataBroker", function()
    it("reports absent from both directions", function()
      assert.are.same({ false, "absent" }, { BrokerKit:ExposeToLibDataBroker() })
      assert.are.same({ false, "absent" }, { BrokerKit:AdoptFromLibDataBroker() })
    end)

    it("reports absent when LibStub holds no LibDataBroker", function()
      TestEnv.InstallLibStub()
      assert.are.same({ false, "absent" }, { BrokerKit:ExposeToLibDataBroker() })
      assert.are.same({ false, "absent" }, { BrokerKit:AdoptFromLibDataBroker() })
    end)

    it("keeps working as a plain registry afterwards", function()
      BrokerKit:ExposeToLibDataBroker()
      BrokerKit:AdoptFromLibDataBroker()
      local object = BrokerKit:New("Mine", { text = "Ready" })
      object.text = "Busy"
      assert.are.equal("Busy", BrokerKit:Get("Mine").text)
    end)
  end)

  describe("exposing", function()
    it("registers existing objects so a display sees their creation and attributes", function()
      local library = TestEnv.InstallLibDataBroker()
      local display = TestEnv.WatchLibDataBroker(library)
      local click = function() end
      BrokerKit:New("Zeta", { text = "Z" })
      BrokerKit:New("Alpha", { type = "launcher", icon = 134400, OnClick = click })

      assert.is_true(BrokerKit:ExposeToLibDataBroker())
      assert.are.equal(2, #display.created)
      assert.are.equal("Alpha", display.created[1].name)
      assert.are.equal("Zeta", display.created[2].name)

      local alpha = library:GetDataObjectByName("Alpha")
      assert.are.equal("launcher", alpha.type)
      assert.are.equal(134400, alpha.icon)
      assert.are.equal(click, alpha.OnClick)
      assert.are.equal("data source", library:GetDataObjectByName("Zeta").type)
      assert.are.equal(0, #display.changed)
    end)

    it("mirrors every later change as one LibDataBroker write", function()
      local library = TestEnv.InstallLibDataBroker()
      local display = TestEnv.WatchLibDataBroker(library)
      local object = BrokerKit:New("Mine", { text = "Ready" })
      BrokerKit:ExposeToLibDataBroker()
      local writes = library.attributeWrites

      object.text = "Busy"
      object:Set("value", 3)
      object.text = "Busy"
      assert.are.equal(writes + 2, library.attributeWrites)
      assert.are.equal(2, #display.changed)
      assert.are.same({
        name = "Mine",
        attribute = "text",
        value = "Busy",
        dataObject = library:GetDataObjectByName("Mine"),
      }, display.changed[1])
      assert.are.equal(3, display.changed[2].value)
      assert.are.equal("Busy", library:GetDataObjectByName("Mine").text)

      object.text = nil
      assert.is_nil(library:GetDataObjectByName("Mine").text)
      assert.are.equal(3, #display.changed)
    end)

    it("exposes objects created later", function()
      local library = TestEnv.InstallLibDataBroker()
      local display = TestEnv.WatchLibDataBroker(library)
      BrokerKit:ExposeToLibDataBroker()
      local object = BrokerKit:New("Later", { text = "L" })
      assert.are.equal(1, #display.created)
      assert.are.equal("Later", display.created[1].name)
      object.text = "Changed"
      assert.are.equal("Changed", library:GetDataObjectByName("Later").text)
    end)

    it("reports already on a second call and creates nothing twice", function()
      local library = TestEnv.InstallLibDataBroker()
      BrokerKit:New("Mine")
      assert.is_true(BrokerKit:ExposeToLibDataBroker())
      local calls = library.newDataObjectCalls
      assert.are.same({ false, "already" }, { BrokerKit:ExposeToLibDataBroker() })
      assert.are.equal(calls, library.newDataObjectCalls)
    end)

    it("leaves a later object local when a foreign object holds its name", function()
      local library = TestEnv.InstallLibDataBroker({
        objects = { Clash = { type = "data source", text = "theirs" } },
      })
      assert.is_true(BrokerKit:ExposeToLibDataBroker())
      local calls = library.newDataObjectCalls
      local object = BrokerKit:New("Clash", { text = "ours" })
      assert.are.equal(calls + 1, library.newDataObjectCalls)
      assert.are.equal("theirs", library:GetDataObjectByName("Clash").text)
      object.text = "changed"
      assert.are.equal("theirs", library:GetDataObjectByName("Clash").text)
      assert.are.equal("changed", BrokerKit:Get("Clash").text)
      assert.is_false(BrokerKit:IsForeign(object))
    end)

    it("leaves an object local when a foreign object holds its name", function()
      local library = TestEnv.InstallLibDataBroker({
        objects = { Clash = { type = "data source", text = "theirs" } },
      })
      local object = BrokerKit:New("Clash", { text = "ours" })
      assert.is_true(BrokerKit:ExposeToLibDataBroker())
      assert.are.equal("theirs", library:GetDataObjectByName("Clash").text)
      object.text = "changed"
      assert.are.equal("theirs", library:GetDataObjectByName("Clash").text)
      assert.are.equal("changed", BrokerKit:Get("Clash").text)
    end)
  end)

  describe("adopting", function()
    it("wraps every existing object read-only, in sorted order", function()
      TestEnv.InstallLibDataBroker({
        objects = {
          Zeta = { type = "data source", text = "Z", value = 2 },
          Alpha = { type = "launcher", icon = 134400 },
        },
      })
      local added = {}
      BrokerKit:OnObjectAdded(function(object)
        added[#added + 1] = object.name
      end)
      assert.is_true(BrokerKit:AdoptFromLibDataBroker())
      assert.are.same({ "Alpha", "Zeta" }, added)
      assert.are.same({ "Alpha", "Zeta" }, BrokerKit:Objects())

      local zeta = BrokerKit:Get("Zeta")
      assert.are.equal("Z", zeta.text)
      assert.are.equal(2, zeta:Get("value"))
      assert.are.equal("launcher", BrokerKit:Get("Alpha").type)
      assert.is_true(BrokerKit:IsForeign(zeta))
    end)

    it("refuses writes to a foreign object at the caller, naming it foreign", function()
      TestEnv.InstallLibDataBroker({
        objects = { Theirs = { type = "data source", text = "T" } },
      })
      BrokerKit:AdoptFromLibDataBroker()
      local theirs = BrokerKit:Get("Theirs")
      local message =
        'BrokerKit.Object:Set object "Theirs" is foreign (adopted from LibDataBroker) and read-only'
      TestEnv.expectErrorContaining(message, function()
        theirs.text = "Mine"
      end)
      TestEnv.expectErrorContaining(message, function()
        theirs:Set("text", "Mine")
      end)
      assert.are.equal("T", theirs.text)
    end)

    it("forwards a foreign attribute change into OnChange", function()
      local library = TestEnv.InstallLibDataBroker({
        objects = { Theirs = { type = "data source", text = "T" } },
      })
      BrokerKit:AdoptFromLibDataBroker()
      local theirs = BrokerKit:Get("Theirs")
      local seen = {}
      theirs:OnChange(function(object, attribute, value, previous)
        seen[#seen + 1] = { object, attribute, value, previous }
      end)
      local texts = 0
      theirs:OnChange("text", function()
        texts = texts + 1
      end)

      local dataObject = library:GetDataObjectByName("Theirs")
      dataObject.text = "Changed"
      dataObject.value = 7
      dataObject.text = "Changed"
      assert.are.same({
        { theirs, "text", "Changed", "T" },
        { theirs, "value", 7, nil },
      }, seen)
      assert.are.equal(1, texts)
      assert.are.equal("Changed", theirs.text)
      assert.are.equal(7, theirs.value)
    end)

    it("adopts objects created later through the callback", function()
      local library = TestEnv.InstallLibDataBroker()
      BrokerKit:AdoptFromLibDataBroker()
      local added = {}
      BrokerKit:OnObjectAdded(function(object)
        added[#added + 1] = object
      end)
      local dataObject = library:NewDataObject("Later", { type = "launcher" })
      assert.are.equal(1, #added)
      assert.are.equal("Later", added[1].name)
      assert.are.equal("launcher", added[1].type)
      assert.is_true(BrokerKit:IsForeign(added[1]))
      dataObject.icon = 1
      assert.are.equal(1, added[1].icon)
    end)

    it("adopts an object nobody wrote to yet, with attributes arriving later", function()
      local library = TestEnv.InstallLibDataBroker()
      local dataObject = library:NewDataObject("Empty")
      assert.is_true(BrokerKit:AdoptFromLibDataBroker())
      local empty = BrokerKit:Get("Empty")
      assert.is_not_nil(empty)
      assert.is_nil(empty.type)
      dataObject.type = "data source"
      assert.are.equal("data source", empty.type)
    end)

    it("skips reserved and non-string foreign attribute names", function()
      local library = TestEnv.InstallLibDataBroker({
        objects = {
          Odd = { type = "data source", name = "Not Mine", Set = 1, [1] = "one" },
        },
      })
      BrokerKit:AdoptFromLibDataBroker()
      local odd = BrokerKit:Get("Odd")
      assert.are.equal("Odd", odd.name)
      assert.is_function(odd.Set)
      assert.is_nil(odd[1])
      library:GetDataObjectByName("Odd").name = "Still Not Mine"
      assert.are.equal("Odd", odd.name)
    end)

    it("reports already on a second call and subscribes once", function()
      local library = TestEnv.InstallLibDataBroker({ objects = { One = { type = "data source" } } })
      assert.is_true(BrokerKit:AdoptFromLibDataBroker())
      assert.are.same({ false, "already" }, { BrokerKit:AdoptFromLibDataBroker() })
      assert.are.equal(2, library.CallbackCount())
      assert.are.same({ "One" }, BrokerKit:Objects())
    end)

    it("keeps the MoltenCodes object when a foreign one has the same name", function()
      local library = TestEnv.InstallLibDataBroker({
        objects = { Clash = { type = "data source", text = "theirs" } },
      })
      local mine = BrokerKit:New("Clash", { text = "ours" })
      BrokerKit:AdoptFromLibDataBroker()
      assert.are.equal(mine, BrokerKit:Get("Clash"))
      assert.is_false(BrokerKit:IsForeign(mine))
      library:GetDataObjectByName("Clash").text = "changed"
      assert.are.equal("ours", mine.text)
    end)

    it("refuses New for a name a foreign object holds, saying so", function()
      TestEnv.InstallLibDataBroker({ objects = { Theirs = { type = "data source" } } })
      BrokerKit:AdoptFromLibDataBroker()
      TestEnv.expectErrorContaining(
        'BrokerKit:New name "Theirs" is already taken by a foreign LibDataBroker object',
        function()
          BrokerKit:New("Theirs")
        end
      )
    end)

    it("survives a raising OnChange listener on the foreign path as the client would", function()
      -- The real CallbackHandler runs each callback under xpcall, so an
      -- error in our listener reaches the client's error handler, not
      -- the addon that wrote the attribute.
      local library = TestEnv.InstallLibDataBroker({
        isolateErrors = true,
        objects = { Theirs = { type = "data source", text = "T" } },
      })
      BrokerKit:AdoptFromLibDataBroker()
      local theirs = BrokerKit:Get("Theirs")
      theirs:OnChange("text", function()
        error("listener failed", 0)
      end)
      local later = {}
      theirs:OnChange(function(_, attribute, value)
        later[#later + 1] = attribute .. "=" .. tostring(value)
      end)

      local dataObject = library:GetDataObjectByName("Theirs")
      dataObject.text = "Changed"
      assert.are.equal("Changed", theirs.text)
      assert.are.equal(1, #library.reportedErrors)
      assert.are.equal("listener failed", library.reportedErrors[1])
      -- The any list did not run: the error aborted that dispatch.
      assert.are.same({}, later)
      dataObject.value = 1
      assert.are.same({ "value=1" }, later)
    end)

    it("adopts once from a LibDataBroker without CallbackHandler", function()
      local library = TestEnv.InstallLibDataBroker({ withoutCallbacks = true })
      assert.is_true(BrokerKit:AdoptFromLibDataBroker())
      library:NewDataObject("Later", { type = "data source" })
      assert.is_nil(BrokerKit:Get("Later"))
    end)
  end)

  describe("both directions", function()
    it("never mirrors an adopted object back", function()
      local library = TestEnv.InstallLibDataBroker({
        objects = { Theirs = { type = "data source", text = "T" } },
      })
      BrokerKit:AdoptFromLibDataBroker()
      BrokerKit:ExposeToLibDataBroker()
      local calls = library.newDataObjectCalls
      library:NewDataObject("Later", { type = "data source" })
      assert.are.equal(calls + 1, library.newDataObjectCalls)
      assert.is_true(BrokerKit:IsForeign(BrokerKit:Get("Later")))
      assert.are.equal(2, #BrokerKit:Objects())
    end)

    it("does not adopt its own exposed object or echo its own changes", function()
      local library = TestEnv.InstallLibDataBroker()
      BrokerKit:AdoptFromLibDataBroker()
      BrokerKit:ExposeToLibDataBroker()
      local added = 0
      BrokerKit:OnObjectAdded(function()
        added = added + 1
      end)
      local mine = BrokerKit:New("Mine", { text = "Ready" })
      local changes = 0
      mine:OnChange(function()
        changes = changes + 1
      end)
      mine.text = "Busy"
      assert.are.equal(1, added)
      assert.are.equal(1, changes)
      assert.is_false(BrokerKit:IsForeign(mine))
      assert.are.equal("Busy", library:GetDataObjectByName("Mine").text)
      assert.are.same({ "Mine" }, BrokerKit:Objects())
    end)

    it("does not let a foreign write to our mirror reach our object", function()
      local library = TestEnv.InstallLibDataBroker()
      BrokerKit:AdoptFromLibDataBroker()
      BrokerKit:ExposeToLibDataBroker()
      local mine = BrokerKit:New("Mine", { text = "Ready" })
      -- A misbehaving display writing into a data object it does not own.
      library:GetDataObjectByName("Mine").text = "Hijacked"
      assert.are.equal("Ready", mine.text)
    end)
  end)
end)
