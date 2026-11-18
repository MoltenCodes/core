local TestEnv = require("SignalKitTestEnv")
local Core = TestEnv.Core

local SOURCE = debug.getinfo(1, "S").short_src

-- Revision 13 makes SignalKit a raw-signal core with two new parts (ADR 0001):
-- Bus and Journal; the Coalescing part (revision 2) now needs the Bus part.
-- These specs pin the core without them, the parts' bootstrap, and the
-- upgrade from revision 12, the last file with buses and journals in the core
-- (`fixtures/SignalKit-revision12.lua`), with and without the parts.

---The text a member of `part` raises while the part is not loaded.
---@param member string
---@param part string
---@return string
local function missing(member, part)
  return member
    .. " is in SignalKit's "
    .. part
    .. " part, which is not loaded: add signalKit\\parts\\SignalKit-"
    .. part
    .. ".lua to embeds.xml after signalKit\\SignalKit.lua"
end

---Run `action` and assert it failed with `message` at the line after the one
---that called `mark()`.
---@param message string
---@param action fun(mark: fun())
local function assertReportedAtCaller(message, action)
  local expectedLine = nil
  local function mark()
    expectedLine = debug.getinfo(2, "l").currentline + 1
  end
  local ok, value = pcall(action, mark)
  assert.is_false(ok)
  assert.are.equal(SOURCE .. ":" .. tostring(expectedLine) .. ": " .. message, value)
end

---Load one part's source again with its `PART_REVISION` set to `revision`.
---@param part string
---@param revision integer
---@return table SignalKit
local function loadPartAtRevision(part, revision)
  local path = "packages/signalKit/src/parts/SignalKit-" .. part .. ".lua"
  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()
  local patched, count =
    text:gsub("local PART_REVISION = %d+", "local PART_REVISION = " .. revision, 1)
  assert.are.equal(1, count)
  return assert(loadstring(patched, "@" .. path))()
end

---Build, on the revision 12 file, a bus with a subscription, a scope with a
---subscription, an addon bus and a journal with one recorded firing.
---@return table scene
local function buildRevision12Scene()
  require("Registry")
  local previous = TestEnv.LoadRevision(12)
  assert.are.equal(12, previous.REVISION)
  local scene = { previous = previous, received = {} }
  scene.bus = previous:Bus("Shared", { openTopics = true })
  scene.subscription = scene.bus:Subscribe("Topic", function(value)
    scene.received[#scene.received + 1] = "bus:" .. tostring(value)
  end)
  scene.scope = scene.bus:CreateScope()
  scene.scoped = scene.scope:Subscribe("Topic", function(value)
    scene.received[#scene.received + 1] = "scope:" .. tostring(value)
  end)
  scene.addonBus = previous:ForAddon("MyAddon")
  scene.addonSubscription = scene.addonBus:Subscribe("Ping", function() end)
  scene.journal = previous:NewJournal(4)
  scene.journal:Fire("before")
  return scene
end

describe("SignalKit parts", function()
  after_each(function()
    TestEnv.Reset()
    Core.Reset()
  end)

  describe("without the parts", function()
    it("answers HasPart false for each part", function()
      local SignalKit = Core.NewPackage()
      assert.is_false(SignalKit:HasPart("Bus"))
      assert.is_false(SignalKit:HasPart("Journal"))
      assert.is_false(SignalKit:HasPart("Coalescing"))
    end)

    it("refuses a HasPart name that is not a string, at the caller", function()
      local SignalKit = Core.NewPackage()
      assertReportedAtCaller("SignalKit:HasPart name must be a string", function(mark)
        mark()
        SignalKit:HasPart(1)
      end)
    end)

    it(
      "keeps Bus, ForAddon and NewJournal on the facade, raising at the caller with the file to add",
      function()
        local SignalKit = Core.NewPackage()
        assertReportedAtCaller(missing("SignalKit:Bus", "Bus"), function(mark)
          mark()
          SignalKit:Bus("Anything")
        end)
        assertReportedAtCaller(missing("SignalKit:ForAddon", "Bus"), function(mark)
          mark()
          SignalKit:ForAddon("MyAddon")
        end)
        assertReportedAtCaller(missing("SignalKit:NewJournal", "Journal"), function(mark)
          mark()
          SignalKit:NewJournal(4)
        end)
      end
    )

    it("answers CloseAddonBus false after its argument checks", function()
      local SignalKit = Core.NewPackage()
      assert.is_false(SignalKit:CloseAddonBus("MyAddon"))
      assertReportedAtCaller(
        "SignalKit:CloseAddonBus addonName must be a non-empty string",
        function(mark)
          mark()
          SignalKit:CloseAddonBus("")
        end
      )
    end)

    it("serves raw signals and the package-wide limits", function()
      local SignalKit = Core.NewPackage()
      local signal = SignalKit:New()
      local seen = nil
      local connection = signal:Connect(function(value)
        seen = value
      end)
      signal:Fire(7)
      assert.are.equal(7, seen)
      assert.is_true(connection:Disconnect())
      assert.are.same(
        { maxBuses = 64, maxJournalCapacity = 1024, maxJournalArguments = 8 },
        SignalKit:GetLimits()
      )
      SignalKit:SetLimits({ maxBuses = 2 })
      assert.are.equal(2, SignalKit:GetLimits().maxBuses)
    end)

    it("creates no journal tables and no logout watcher in a fresh state", function()
      local SignalKit = Core.NewPackage()
      local state = rawget(SignalKit, "_state")
      assert.is_nil(rawget(state, "journalPrototype"))
      assert.is_nil(rawget(state, "logoutWatch"))
      assert.is_nil(rawget(state, "inheritedBuses"))
    end)
  end)

  describe("bootstrap", function()
    it("records each part with its revision and answers HasPart true", function()
      local SignalKit = TestEnv.NewPackage()
      assert.is_true(SignalKit:HasPart("Bus"))
      assert.is_true(SignalKit:HasPart("Journal"))
      assert.are.equal(1, SignalKit._state.parts.Bus.revision)
      assert.are.equal(1, SignalKit._state.parts.Journal.revision)
    end)

    it("loads the parts in either order", function()
      TestEnv.Reset()
      require("Registry")
      local SignalKit = require("SignalKit")
      require("SignalKit-Journal")
      require("SignalKit-Bus")
      local journal = SignalKit:NewJournal(2)
      journal:Fire("one")
      local bus = SignalKit:Bus("Either", { openTopics = true })
      local seen = nil
      bus:Subscribe("Topic", function(value)
        seen = value
      end)
      bus:Publish("Topic", "two")
      assert.are.equal("two", seen)
    end)

    it("refuses to load a part without its core", function()
      for _, part in ipairs({ "Bus", "Journal" }) do
        TestEnv.Reset()
        require("Registry")
        TestEnv.expectErrorContaining(
          "MoltenCodes SignalKit part " .. part .. " requires SignalKit API 1 to be loaded first",
          function()
            require("SignalKit-" .. part)
          end
        )
      end
    end)

    it("refuses to load the Coalescing part without the Bus part", function()
      TestEnv.Reset()
      require("Registry")
      require("SignalKit")
      TestEnv.expectErrorContaining(
        "MoltenCodes SignalKit part Coalescing requires SignalKit's Bus part to be loaded first",
        function()
          require("SignalKit-Coalescing")
        end
      )
      package.loaded["SignalKit-Coalescing"] = nil
    end)

    it("lets a part of an equal revision return without touching anything", function()
      local SignalKit = TestEnv.NewPackage()
      local record = SignalKit._state.parts.Journal
      local newJournal = SignalKit.NewJournal
      loadPartAtRevision("Journal", 1)
      assert.are.equal(record, SignalKit._state.parts.Journal)
      assert.are.equal(newJournal, SignalKit.NewJournal)
    end)

    it("upgrades a part in place to a higher revision, keeping its buses", function()
      local SignalKit = TestEnv.NewPackage()
      local bus = SignalKit:Bus("Kept", { openTopics = true })
      local seen = nil
      bus:Subscribe("Topic", function(value)
        seen = value
      end)
      local publish = rawget(SignalKit._state.busPrototype, "Publish")
      loadPartAtRevision("Bus", 2)
      assert.are.equal(2, SignalKit._state.parts.Bus.revision)
      assert.are_not.equal(publish, rawget(SignalKit._state.busPrototype, "Publish"))
      bus:Publish("Topic", "after")
      assert.are.equal("after", seen)
    end)

    it("keeps the parts serving when a later core revision loads over them", function()
      local SignalKit = TestEnv.NewPackage()
      local facadeBus = SignalKit.Bus
      local later = TestEnv.LoadSourceWithRevision("SignalKit", SignalKit.REVISION + 1)
      assert.are.equal(SignalKit, later)
      assert.are.equal(facadeBus, SignalKit.Bus)
      local journal = SignalKit:NewJournal(2)
      journal:Fire("served")
      local _, entry = journal:History()(journal, 0)
      assert.are.equal("served", entry[1])
    end)
  end)

  describe("the upgrade from revision 12", function()
    it("keeps every bus, scope, subscription and journal working when the parts load", function()
      TestEnv.Reset()
      local scene = buildRevision12Scene()
      local SignalKit = TestEnv.ReloadPackage()
      assert.are.equal(scene.previous, SignalKit)
      assert.are.equal(13, SignalKit.REVISION)

      scene.bus:Publish("Topic", 1)
      assert.are.same({ "bus:1", "scope:1" }, scene.received)
      assert.is_true(scene.scoped:IsConnected())
      assert.are.equal(1, scene.scope:DisconnectAll())
      assert.is_true(scene.subscription:Disconnect())

      scene.journal:Fire("after")
      local entries = {}
      for _, entry in scene.journal:History() do
        entries[#entries + 1] = entry[1]
      end
      assert.are.same({ "before", "after" }, entries)
      assert.is_true(SignalKit:CloseAddonBus("MyAddon"))
      assert.is_false(scene.addonSubscription:IsConnected())
    end)

    it("without the parts, raises naming the part and still closes an addon bus", function()
      TestEnv.Reset()
      local scene = buildRevision12Scene()
      package.loaded["SignalKit"] = nil
      local SignalKit = require("SignalKit")
      assert.are.equal(scene.previous, SignalKit)
      assert.is_true(rawget(SignalKit, "_state").inheritedBuses)

      assertReportedAtCaller(missing("SignalKit.Bus:Publish", "Bus"), function(mark)
        mark()
        scene.bus:Publish("Topic", 1)
      end)
      assertReportedAtCaller(missing("SignalKit.BusScope:Close", "Bus"), function(mark)
        mark()
        scene.scope:Close()
      end)
      assertReportedAtCaller(missing("SignalKit.Journal:Fire", "Journal"), function(mark)
        mark()
        scene.journal:Fire("after")
      end)

      -- The journal still fires as a signal; its subscription handles work.
      local seen = nil
      scene.journal:Connect(function(value)
        seen = value
      end)
      SignalKit.Fire(scene.journal, "as a signal")
      assert.are.equal("as a signal", seen)
      assert.is_true(scene.subscription:Disconnect())

      -- LifecycleKit's shutdown and the logout watcher still close an addon bus.
      assert.is_true(SignalKit:CloseAddonBus("MyAddon"))
      assert.is_false(scene.addonSubscription:IsConnected())
      assert.is_false(SignalKit:CloseAddonBus("MyAddon"))

      -- Loading the parts later adopts what is left.
      TestEnv.LoadParts()
      scene.bus:Publish("Topic", 2)
      assert.are.same({ "scope:2" }, scene.received)
    end)
  end)
end)
