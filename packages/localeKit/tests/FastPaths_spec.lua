local TestEnv = require("LocaleKitTestEnv")

-- Revision 3 makes registering, skipping an unneeded locale and the first read
-- of a missing key cheaper without changing what they do (docs/INTERNALS.md).
-- These specs pin what each fast path must keep:
--
--   * a known client locale code skips the pattern match, and every other code
--     is still accepted or refused by the pattern exactly as before;
--   * the write proxies check and store inline and still refuse what they
--     refused, at the assignment line;
--   * a record is built with eight fields (layout 2): the default limit and
--     the cap flag are implicit and `missing` is created at the first miss;
--   * records an older revision built (layout 1, ten fields) keep working.

describe("LocaleKit fast paths", function()
  after_each(TestEnv.Reset)

  ---The addon record LocaleKit keeps for `addonName`.
  ---@param LocaleKit table
  ---@param addonName string
  ---@return table record
  local function recordOf(LocaleKit, addonName)
    return rawget(rawget(LocaleKit, "_state"), "addons")[addonName]
  end

  describe("locale codes", function()
    it("accepts every code of the client shape, known to clients or not", function()
      local LocaleKit = TestEnv.NewPackage("enUS")
      for _, code in ipairs({ "deDE", "zhTW", "xxYY", "abCD" }) do
        assert.is_nil(LocaleKit:NewLocale("Codes", code))
      end
      assert.is_table(LocaleKit:NewLocale("Codes", "enGB", { isDefault = true }))
    end)

    it("refuses every code of another shape", function()
      local LocaleKit = TestEnv.NewPackage("enUS")
      for _, code in ipairs({ "dede", "DEDE", "de", "deDEx", "", 42, true }) do
        TestEnv.expectErrorContaining('must be a client locale code such as "deDE"', function()
          LocaleKit:NewLocale("Codes", code)
        end)
      end
    end)

    it("reads an unknown but well-formed client locale from GetLocale", function()
      local LocaleKit = TestEnv.NewPackage("xxYY")
      assert.is_table(LocaleKit:NewLocale("Codes", "xxYY"))
      assert.is_nil(LocaleKit:NewLocale("Other", "enUS"))
    end)

    it("falls back to enUS for a malformed GetLocale answer", function()
      local LocaleKit = TestEnv.NewPackage("english")
      assert.is_table(LocaleKit:NewLocale("Codes", "enUS"))
    end)

    it("falls back to enUS when GetLocale answers something other than a string", function()
      local LocaleKit = TestEnv.NewPackage("enUS")
      -- The stub stands in for a World of Warcraft client API that only exists in the global table.
      -- selene: allow(global_usage)
      rawset(_G, "GetLocale", function()
        return 42
      end)
      assert.is_table(LocaleKit:NewLocale("Codes", "enUS"))
      assert.is_nil(LocaleKit:NewLocale("Other", "deDE"))
    end)
  end)

  describe("write proxies", function()
    it("refuses an empty key, a non-string key and a non-text value", function()
      local LocaleKit = TestEnv.NewPackage("enUS")
      local default = LocaleKit:NewLocale("Writes", "enUS", { isDefault = true })
      local translated = LocaleKit:NewLocale("Writes", "enUS")
      for _, proxy in ipairs({ default, translated }) do
        TestEnv.expectErrorContaining("translation key must be a non-empty string", function()
          proxy[""] = true
        end)
        TestEnv.expectErrorContaining("translation key must be a non-empty string", function()
          proxy[1] = "one"
        end)
        TestEnv.expectErrorContaining('translation "Count" must be a string or true', function()
          proxy.Count = 5
        end)
      end
      assert.are.same({}, LocaleKit:MissingKeys("Writes"))
    end)

    it("stores the key as its own text for true in the client's locale", function()
      local LocaleKit = TestEnv.NewPackage("deDE")
      local german = LocaleKit:NewLocale("Own", "deDE")
      german.Hello = true
      german.Bye = "Bis bald"
      local L = LocaleKit:GetLocale("Own")
      assert.are.equal("Hello", L.Hello)
      assert.are.equal("Bis bald", L.Bye)
    end)

    it("lets a default define a key read while missing, and nothing else", function()
      local LocaleKit = TestEnv.NewPackage("deDE")
      local german = LocaleKit:NewLocale("Order", "deDE")
      german.Hello = "Hallo"
      local L = LocaleKit:GetLocale("Order", { missing = "silent" })
      assert.are.equal("Late", L.Late)
      assert.are.same({ "Late" }, LocaleKit:MissingKeys("Order"))

      local default = LocaleKit:NewLocale("Order", "enUS", { isDefault = true })
      default.Hello = "Hello"
      default.Late = "Arrived late"
      default.Fresh = true
      assert.are.equal("Hallo", L.Hello)
      assert.are.equal("Arrived late", L.Late)
      assert.are.equal("Fresh", L.Fresh)
      assert.are.same({}, LocaleKit:MissingKeys("Order"))

      local _ = L.Again
      german.Again = "Wieder"
      assert.are.equal("Wieder", L.Again)
      assert.are.same({}, LocaleKit:MissingKeys("Order"))
    end)
  end)

  describe("record layout 2", function()
    it("builds a record with eight fields and adds the rare ones on demand", function()
      local LocaleKit = TestEnv.NewPackage("enUS")
      LocaleKit:NewLocale("Layout", "enUS", { isDefault = true }).Hello = true
      local record = recordOf(LocaleKit, "Layout")
      local fields = 0
      for _ in next, record do
        fields = fields + 1
      end
      assert.are.equal(8, fields)
      assert.are.equal(2, record.schema)
      assert.is_false(record.missing)
      assert.is_nil(rawget(record, "maxMissingKeys"))
      assert.is_nil(rawget(record, "capReported"))

      -- Naming the default limit leaves it implicit, and a later call naming
      -- it again, or naming nothing, is accepted.
      local L = LocaleKit:GetLocale("Layout", { missing = "silent", maxMissingKeys = 1024 })
      assert.is_nil(rawget(record, "maxMissingKeys"))
      assert.are.equal(L, LocaleKit:GetLocale("Layout", { maxMissingKeys = 1024 }))
      TestEnv.expectErrorContaining("already uses options.maxMissingKeys 1024, not 5", function()
        LocaleKit:GetLocale("Layout", { maxMissingKeys = 5 })
      end)
      assert.are.same({}, LocaleKit:MissingKeys("Layout"))
      local _ = L.First
      assert.is_table(record.missing)
      assert.are.same({ "First" }, LocaleKit:MissingKeys("Layout"))
    end)

    it("reports the cap once on a layout-2 record", function()
      local LocaleKit = TestEnv.NewPackage("enUS")
      LocaleKit:NewLocale("Capped", "enUS", { isDefault = true }).Hello = true
      local L = LocaleKit:GetLocale("Capped", { maxMissingKeys = 2 })
      TestEnv.TakeReportedErrors()
      for index = 1, 5 do
        local _ = L["key" .. index]
      end
      local reports = TestEnv.TakeReportedErrors()
      assert.are.equal(3, #reports)
      assert.is_truthy(reports[3].value:find("more than 2 missing translations", 1, true))
      assert.are.equal(2, #LocaleKit:MissingKeys("Capped"))
      assert.is_true(recordOf(LocaleKit, "Capped").capReported)
    end)
  end)

  describe("layout-1 records from an older revision", function()
    ---Turn the record of `addonName` into the ten-field layout revision 2
    ---built, as an in-place upgrade inherits it.
    ---@param LocaleKit table
    ---@param addonName string
    ---@param limit integer|table
    local function makeLayoutOne(LocaleKit, addonName, limit)
      local record = recordOf(LocaleKit, addonName)
      record.schema = 1
      record.missing = {}
      record.capReported = false
      record.maxMissingKeys = limit
    end

    it("keeps recording, reporting, clearing and comparing limits", function()
      local working = TestEnv.NewPackage("deDE").REVISION
      TestEnv.Reset()
      TestEnv.InstallWowApi()
      TestEnv.SetClientLocale("deDE")
      require("Registry")
      local previous = TestEnv.LoadRevision(working - 1)
      local default = previous:NewLocale("Old", "enUS", { isDefault = true })
      default.Hello = true
      makeLayoutOne(previous, "Old", 2)
      local L = previous:GetLocale("Old")

      local current = require("LocaleKit")
      assert.are.equal(previous, current)
      assert.are.equal(working, current.REVISION)
      TestEnv.TakeReportedErrors()

      local _ = L.One
      _ = L.Two
      _ = L.Three
      _ = L.Four
      local reports = TestEnv.TakeReportedErrors()
      assert.are.equal(3, #reports)
      assert.is_truthy(reports[3].value:find("more than 2 missing translations", 1, true))
      assert.are.same({ "One", "Two" }, current:MissingKeys("Old"))

      default.One = "First"
      assert.are.equal("First", L.One)
      assert.are.same({ "Two" }, current:MissingKeys("Old"))
      assert.are.equal(L, current:GetLocale("Old", { maxMissingKeys = 2 }))
      TestEnv.expectErrorContaining("already uses options.maxMissingKeys 2, not 1024", function()
        current:GetLocale("Old", { maxMissingKeys = 1024 })
      end)
    end)

    it("keeps an UNBOUNDED layout-1 record unbounded", function()
      local LocaleKit = TestEnv.NewPackage("enUS")
      LocaleKit:NewLocale("Open", "enUS", { isDefault = true }).Hello = true
      makeLayoutOne(LocaleKit, "Open", LocaleKit.UNBOUNDED)
      local L = LocaleKit:GetLocale("Open", { missing = "silent" })
      for index = 1, 1100 do
        local _ = L["key" .. index]
      end
      assert.are.equal(1100, #LocaleKit:MissingKeys("Open"))
    end)
  end)

  describe("allocation #allocation", function()
    it("allocates nothing to refuse a locale the client does not need", function()
      local LocaleKit = TestEnv.NewPackage("enUS")
      LocaleKit:NewLocale("Skip", "enUS", { isDefault = true }).Hello = true
      LocaleKit:NewLocale("Skip", "frFR")
      local allocated = TestEnv.AllocatedKilobytes(function()
        for _ = 1, 2000 do
          LocaleKit:NewLocale("Skip", "frFR")
        end
      end)
      assert.is_true(allocated < 1, "an unneeded locale allocated " .. allocated .. " KiB")
    end)

    it("allocates an eight-field record for a new addon", function()
      local LocaleKit = TestEnv.NewPackage("enUS")
      local names = {}
      local count = 500
      for index = 1, count do
        names[index] = "Addon" .. index
      end
      local options = { isDefault = true }
      local proxies = {}
      -- The first registrations grow the state tables; measure after them.
      for index = 1, count do
        LocaleKit:NewLocale("Warm" .. index, "enUS", options)
      end
      local allocated = TestEnv.AllocatedKilobytes(function()
        for index = 1, count do
          proxies[index] = LocaleKit:NewLocale(names[index], "enUS", options)
        end
      end)
      -- The record (376 bytes on a 64-bit Lua 5.1), its empty read table
      -- and the proxy (56 bytes each), plus the addon's share of the three
      -- state tables' growth. A ten-field record alone was 696 bytes.
      local bytesPerAddon = allocated * 1024 / count
      assert.is_true(bytesPerAddon < 696, "a new addon allocated " .. bytesPerAddon .. " bytes")
      assert.are.equal(count, #proxies)
    end)
  end)
end)
