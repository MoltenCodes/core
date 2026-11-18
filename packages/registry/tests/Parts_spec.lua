local TestEnv = require("RegistryTestEnv")
local Core = TestEnv.Core

local SOURCE = debug.getinfo(1, "S").short_src

-- Revision 17 splits Registry into a core and two parts (ADR 0001): Handover
-- (`request.retire`, `request.migrations`, `request.sealFacade`, `OnRetire`)
-- and Diagnostics (`GetInfo`, `Packages`). These specs pin the core without
-- them, the parts' bootstrap, and the upgrade from revision 16, the last whole
-- file, kept verbatim as `fixtures/Registry-revision16.lua`.

local FIXTURE = "packages/registry/tests/fixtures/Registry-revision16.lua"

---The text a member of `part` raises while the part is not loaded.
---@param member string
---@param part string
---@return string
local function missing(member, part)
  return member
    .. " is in Registry's "
    .. part
    .. " part, which is not loaded: add registry\\parts\\Registry-"
    .. part
    .. ".lua to embeds.xml after registry\\Registry.lua"
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

---A `Bootstrap` request for `demoKit` API 1 at `revision`.
---@param revision integer
---@param extra table?
---@return table
local function newRequest(revision, extra)
  local request = {
    package = "demoKit",
    api = 1,
    revision = revision,
    label = "MoltenCodes DemoKit",
    validatePublicSurface = function(implementation)
      return rawget(implementation, "API") == 1
    end,
  }
  for key, value in pairs(extra or {}) do
    request[key] = value
  end
  return request
end

---Bootstrap `demoKit` at `revision` and commit its facade fields.
---@param Registry Registry
---@param revision integer
---@param extra table?
---@return table|nil implementation
---@return any state
local function loadCopy(Registry, revision, extra)
  local implementation, _, _, state = Registry:Bootstrap(newRequest(revision, extra))
  if implementation ~= nil then
    rawset(implementation, "API", 1)
    rawset(implementation, "REVISION", revision)
  end
  return implementation, state
end

---Load the revision 16 whole file, as an addon of that time embedded it.
---@return Registry
local function loadRevision16()
  return assert(loadfile(FIXTURE))()
end

---Load a part's source again with its `PART_REVISION` set to `revision`.
---@param part string
---@param revision integer
---@return Registry
local function loadPartAtRevision(part, revision)
  local path = "packages/registry/src/parts/Registry-" .. part .. ".lua"
  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()
  local patched, count =
    text:gsub("local PART_REVISION = %d+", "local PART_REVISION = " .. revision, 1)
  assert.are.equal(1, count)
  return assert(loadstring(patched, "@" .. path))()
end

describe("Registry parts", function()
  after_each(function()
    TestEnv.Reset()
    Core.Reset()
  end)

  describe("without the parts", function()
    it("answers HasPart false for both parts", function()
      local Registry = Core.NewPackage()
      assert.is_false(Registry:HasPart("Handover"))
      assert.is_false(Registry:HasPart("Diagnostics"))
      assert.is_false(Registry:HasPart("Unknown"))
    end)

    it("refuses a HasPart name that is not a string, at the caller", function()
      local Registry = Core.NewPackage()
      assertReportedAtCaller("Registry:HasPart name must be a string", function(mark)
        mark()
        Registry:HasPart(1)
      end)
    end)

    it(
      "keeps every moved member on the facade, raising at the caller with the file to add",
      function()
        local Registry = Core.NewPackage()
        assertReportedAtCaller(missing("Registry:GetInfo", "Diagnostics"), function(mark)
          mark()
          Registry:GetInfo("demoKit", 1)
        end)
        assertReportedAtCaller(missing("Registry:Packages", "Diagnostics"), function(mark)
          mark()
          Registry:Packages()
        end)
        assertReportedAtCaller(missing("Registry:OnRetire", "Handover"), function(mark)
          mark()
          Registry:OnRetire("demoKit", 1, function() end)
        end)
      end
    )

    it("refuses each hand-over request field at the package file's Bootstrap call", function()
      local Registry = Core.NewPackage()
      local fields = {
        retire = function() end,
        migrations = {},
        sealFacade = true,
      }
      for field, value in pairs(fields) do
        assertReportedAtCaller(
          missing("Registry:Bootstrap request." .. field, "Handover"),
          function(mark)
            mark()
            Registry:Bootstrap(newRequest(1, { [field] = value }))
          end
        )
      end
      assert.is_nil(Registry:Get("demoKit", 1))
    end)

    it("still type-checks the hand-over fields first", function()
      local Registry = Core.NewPackage()
      assertReportedAtCaller("Registry:Bootstrap request.retire must be a function", function(mark)
        mark()
        Registry:Bootstrap(newRequest(1, { retire = "hook" }))
      end)
    end)

    it("accepts sealFacade = false, which asks for no seal", function()
      local Registry = Core.NewPackage()
      local DemoKit = loadCopy(Registry, 1, { sealFacade = false })
      assert.are.equal(DemoKit, Registry:Get("demoKit", 1))
    end)

    it("upgrades a package in place and keeps its bookkeeping", function()
      local Registry = Core.NewPackage()
      local first = loadCopy(Registry, 1)
      local second, state = loadCopy(Registry, 2)
      assert.are.equal(first, second)
      assert.is_nil(state)
      local entry = TestEnv.GetState().entries.demoKit[1]
      assert.are.equal(2, entry.migratedThrough)
      assert.are.equal("active", entry.status)
      assert.are.equal(first, Registry:Find("demoKit", 1))
    end)
  end)

  describe("with the parts", function()
    it("answers HasPart true and records each part's revision", function()
      local Registry = TestEnv.NewRegistry()
      assert.is_true(Registry:HasPart("Handover"))
      assert.is_true(Registry:HasPart("Diagnostics"))
      assert.are.equal(1, TestEnv.GetState().parts.Handover.revision)
      assert.are.equal(1, TestEnv.GetState().parts.Diagnostics.revision)
    end)

    it("serves the moved members", function()
      local Registry = TestEnv.NewRegistry()
      local DemoKit = loadCopy(Registry, 1, { sealFacade = true })
      assert.are.equal(DemoKit, Registry:GetInfo("demoKit", 1).implementation)
      assert.are.equal("demoKit", Registry:Packages()[1].package)
      Registry:OnRetire("demoKit", 1, function() end)
      TestEnv.expectErrorContaining("facade is sealed", function()
        DemoKit.Extra = true
      end)
    end)

    it("loads in either order", function()
      TestEnv.Reset()
      local Registry = require("Registry")
      require("Registry-Diagnostics")
      require("Registry-Handover")
      assert.is_true(Registry:HasPart("Handover"))
      assert.is_true(Registry:HasPart("Diagnostics"))
      assert.are.same({}, Registry:Packages())
    end)

    it("keeps the parts serving when a later core revision loads over them", function()
      local Registry = TestEnv.NewRegistry()
      local getInfo = Registry.GetInfo
      local onRetire = Registry.OnRetire
      local later = TestEnv.LoadSourceWithRevision("Registry", Registry.REVISION + 1)
      assert.are.equal(Registry, later)
      assert.are.equal(Registry.REVISION, TestEnv.GetState().registryRevision)
      assert.are.equal(getInfo, Registry.GetInfo)
      assert.are.equal(onRetire, Registry.OnRetire)
      loadCopy(Registry, 1, { retire = function() end })
      assert.is_not_nil(Registry:GetInfo("demoKit", 1))
    end)

    it("refuses to load a part without its core", function()
      TestEnv.Reset()
      TestEnv.expectErrorContaining(
        "MoltenCodes Registry part Handover requires Registry API 2 to be loaded first",
        function()
          require("Registry-Handover")
        end
      )
      TestEnv.Reset()
      TestEnv.expectErrorContaining(
        "MoltenCodes Registry part Diagnostics requires Registry API 2 to be loaded first",
        function()
          require("Registry-Diagnostics")
        end
      )
    end)

    it("refuses to load a part over the revision 16 whole file, which has no parts", function()
      TestEnv.Reset()
      loadRevision16()
      TestEnv.expectErrorContaining(
        "MoltenCodes Registry part Diagnostics requires Registry API 2 to be loaded first",
        function()
          require("Registry-Diagnostics")
        end
      )
    end)

    it("lets a part of an equal or lower revision return without touching anything", function()
      local Registry = TestEnv.NewRegistry()
      local record = TestEnv.GetState().parts.Handover
      local onRetire = Registry.OnRetire
      assert.are.equal(Registry, loadPartAtRevision("Handover", 1))
      assert.are.equal(record, TestEnv.GetState().parts.Handover)
      assert.are.equal(onRetire, Registry.OnRetire)
    end)

    it("upgrades a part in place to a higher revision", function()
      local Registry = TestEnv.NewRegistry()
      local getInfo = Registry.GetInfo
      loadPartAtRevision("Diagnostics", 2)
      assert.are.equal(2, TestEnv.GetState().parts.Diagnostics.revision)
      assert.are_not.equal(getInfo, Registry.GetInfo)
    end)
  end)

  describe("the upgrade from revision 16", function()
    it("keeps every entry and the facade", function()
      TestEnv.Reset()
      local previous = loadRevision16()
      local DemoKit = loadCopy(previous, 1)
      local entries = TestEnv.GetState().entries

      local Registry = TestEnv.Reload()
      assert.are.equal(previous, Registry)
      assert.are.equal(17, Registry.REVISION)
      assert.are.equal(entries, TestEnv.GetState().entries)
      assert.are.equal(DemoKit, Registry:Get("demoKit", 1))
      assert.is_false(Registry:HasPart("Handover"))
      assertReportedAtCaller(missing("Registry:Packages", "Diagnostics"), function(mark)
        mark()
        Registry:Packages()
      end)
      local upgraded = loadCopy(Registry, 2)
      assert.are.equal(DemoKit, upgraded)
    end)

    it(
      "reports a pending retire hook once without the Handover part and leaves it unrun",
      function()
        TestEnv.Reset()
        TestEnv.InstallHostErrorHandler()
        local previous = loadRevision16()
        local retired = 0
        loadCopy(previous, 1, {
          retire = function()
            retired = retired + 1
          end,
        })

        local Registry = TestEnv.Reload()
        loadCopy(Registry, 2)
        loadCopy(Registry, 3)
        assert.are.equal(0, retired)
        local reported = TestEnv.TakeReportedErrors()
        assert.are.equal(1, #reported)
        local message = tostring(reported[1].value)
        assert.is_truthy(message:find(missing("running it", "Handover"), 1, true), message)
        assert.is_truthy(message:find("MoltenCodes DemoKit", 1, true), message)
      end
    )

    it("runs the pending retire hook when the Handover part is loaded", function()
      TestEnv.Reset()
      local previous = loadRevision16()
      loadCopy(previous, 1, {
        retire = function()
          return "handed over"
        end,
      })

      TestEnv.Reload()
      local Registry = require("Registry-Handover")
      local _, state = loadCopy(Registry, 2, { migrations = {} })
      assert.are.equal("handed over", state)
    end)
  end)
end)
