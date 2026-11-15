local TestEnv = require("SettingsKitTestEnv")

-- Revision 15: AceDB-3.0's other four scopes, keyed as AceDB-3.0 keys them.
describe("SettingsKit race, factionrealm, factionrealmregion and locale scopes", function()
  local SettingsKit, S
  local function load()
    local _
    SettingsKit, _, _, _, S = TestEnv.NewPackage()
  end
  before_each(load)
  after_each(TestEnv.Reset)

  local function record()
    return S.table({ fields = { seen = S.optional(S.number(), 0) } })
  end

  local function allFour()
    return {
      race = record(),
      factionrealm = record(),
      factionrealmregion = record(),
      locale = record(),
    }
  end

  local function saved()
    return TestEnv.GetGlobal("MyAddonDB")
  end

  it("keys each scope as AceDB-3.0 does and stores it in its own section", function()
    local db = SettingsKit:Open("MyAddonDB", allFour())
    db.race.seen = 1
    db.factionrealm.seen = 2
    db.factionrealmregion.seen = 3
    db.locale.seen = 4
    assert.are.same({ Scourge = { seen = 1 } }, saved().race)
    assert.are.same({ ["Alliance - Silvermoon"] = { seen = 2 } }, saved().factionrealm)
    assert.are.same({ ["Alliance - Silvermoon - EU"] = { seen = 3 } }, saved().factionrealmregion)
    assert.are.same({ enus = { seen = 4 } }, saved().locale)
  end)

  it("reads defaults, fires OnChange and compacts like the other keyed scopes", function()
    local db = SettingsKit:Open("MyAddonDB", allFour())
    assert.are.equal(0, db.race.seen)
    local heard = {}
    db:OnChange("locale", function(_, scope, key, value)
      heard[#heard + 1] = { scope, key, value }
    end)
    db.locale.seen = 5
    assert.are.same({ { "locale", "seen", 5 } }, heard)
    db.race.seen = 0
    db:Compact()
    assert.is_nil(rawget(saved().race, "Scourge"))
    assert.are.equal(5, db:Getter("locale", "seen")())
    assert.is_true(db:Validate("factionrealm", "seen", 1))
  end)

  describe("the region of factionrealmregion", function()
    local function regionKey()
      local db = SettingsKit:Open("MyAddonDB", { factionrealmregion = record() })
      db.factionrealmregion.seen = 1
      return next(saved().factionrealmregion)
    end

    it("names GetCurrentRegion()'s number from AceDB-3.0's table", function()
      TestEnv.SetPlayer({ region = 1, regionName = "XX" })
      assert.are.equal("Alliance - Silvermoon - US", regionKey())
    end)

    it("falls back to GetCurrentRegionName() outside the table", function()
      TestEnv.SetPlayer({ region = 72, regionName = "Test" })
      assert.are.equal("Alliance - Silvermoon - Test", regionKey())
    end)

    it("falls back to GetCurrentRegionName() without GetCurrentRegion", function()
      TestEnv.SetPlayer({ region = false, regionName = "Test" })
      assert.are.equal("Alliance - Silvermoon - Test", regionKey())
    end)

    it("falls back to TR when the name is empty, absent or secret", function()
      TestEnv.SetPlayer({ region = 72, regionName = "" })
      assert.are.equal("Alliance - Silvermoon - TR", regionKey())
      TestEnv.Reset()
      load()
      TestEnv.SetPlayer({ region = 72, regionName = false })
      assert.are.equal("Alliance - Silvermoon - TR", regionKey())
      TestEnv.Reset()
      load()
      TestEnv.InstallSecretProbe()
      TestEnv.SetPlayer({ region = TestEnv.NewSecret(), regionName = TestEnv.NewSecret() })
      assert.are.equal("Alliance - Silvermoon - TR", regionKey())
    end)
  end)

  it("makes a scope unavailable when its host answer is absent, empty or secret", function()
    TestEnv.InstallSecretProbe()
    TestEnv.SetPlayer({ race = TestEnv.NewSecret(), locale = "", faction = false })
    local db = SettingsKit:Open("MyAddonDB", allFour())
    assert.has_error(
      function()
        local _ = db.race
      end,
      'SettingsKit (MyAddonDB) db.race is unavailable: UnitRace("player") returned no race when the database was opened'
    )
    assert.has_error(
      function()
        local _ = db.locale
      end,
      "SettingsKit (MyAddonDB) db.locale is unavailable: GetLocale() returned no locale when the database was opened"
    )
    assert.has_error(
      function()
        local _ = db.factionrealmregion
      end,
      'SettingsKit (MyAddonDB) db.factionrealmregion is unavailable: UnitFactionGroup("player") or GetRealmName() returned no faction or realm when the database was opened'
    )
    assert.has_error(
      function()
        local _ = db.factionrealm
      end,
      'SettingsKit (MyAddonDB) db.factionrealm is unavailable: UnitFactionGroup("player") or GetRealmName() returned no faction or realm when the database was opened'
    )
  end)

  it("names an undeclared new scope like any other", function()
    local db = SettingsKit:Open("MyAddonDB", { profile = record() })
    assert.has_error(function()
      local _ = db.race
    end, "SettingsKit (MyAddonDB) db.race is not declared; pass schema.race to SettingsKit:Open")
  end)

  it("asks the client nothing for a new scope the schema does not declare", function()
    local asked = 0
    for _, name in ipairs({ "UnitRace", "GetLocale", "GetCurrentRegion", "GetCurrentRegionName" }) do
      TestEnv.SetGlobal(name, function()
        asked = asked + 1
        return nil
      end)
    end
    SettingsKit:Open("MyAddonDB", { profile = record(), char = record() })
    assert.are.equal(0, asked)
  end)

  it("creates the new sections only when declared", function()
    SettingsKit:Open("MyAddonDB", { profile = record(), race = record() })
    assert.are.same({}, saved().race)
    assert.is_nil(saved().locale)
    assert.is_nil(saved().factionrealm)
    assert.is_nil(saved().factionrealmregion)
  end)

  it("recreates a declared new section after ResetDatabase", function()
    local db = SettingsKit:Open("MyAddonDB", { profile = record(), locale = record() })
    db.locale.seen = 2
    db:ResetDatabase()
    assert.are.same({}, saved().locale)
    assert.are.equal(0, db.locale.seen)
  end)

  it("refuses a new section that is not a table only when the scope is declared", function()
    TestEnv.SavedVariable("MyAddonDB", { race = 5 })
    assert.has_error(function()
      SettingsKit:Open("MyAddonDB", { race = record() })
    end, "SettingsKit:Open MyAddonDB.race must be a table")
    TestEnv.SavedVariable("OtherDB", { race = 5 })
    local db = SettingsKit:Open("OtherDB", { profile = record() })
    assert.are.equal(5, rawget(TestEnv.GetGlobal("OtherDB"), "race"))
    assert.are.equal("Default", db:GetProfile())
  end)

  it("refuses a last migration that leaves a declared new section not a table", function()
    TestEnv.SavedVariable("MyAddonDB", { version = 1, global = {} })
    assert.has_error(function()
      SettingsKit:Open("MyAddonDB", { locale = record() }, {
        version = 2,
        migrations = {
          [2] = function(raw)
            raw.locale = "enus"
          end,
        },
      })
    end, "SettingsKit:Open migration 2 of MyAddonDB failed: MyAddonDB.locale must be a table")
    assert.are.equal(1, TestEnv.GetGlobal("MyAddonDB").version)
  end)

  it("keeps the character key and GetCharacterKey to the four original calls", function()
    local asked = 0
    TestEnv.SetGlobal("UnitRace", function()
      asked = asked + 1
    end)
    assert.are.equal("Tester - Silvermoon", SettingsKit:GetCharacterKey())
    assert.are.equal(0, asked)
  end)
end)
