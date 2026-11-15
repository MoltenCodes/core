local TestEnv = require("SettingsKitTestEnv")

-- Spec profiles (revision 11): a profile assigned per specialization on
-- Retail and Mists of Pandaria Classic, per talent group elsewhere, switched
-- to on the spec events while EventKit is embedded.
describe("SettingsKit spec profiles", function()
  local SettingsKit, S

  before_each(function()
    local loaded = { TestEnv.NewPackage() }
    SettingsKit, S = loaded[1], loaded[5]
  end)

  after_each(TestEnv.Reset)

  local function schemaFor()
    return { profile = S.table({ fields = { scale = S.optional(S.number(), 1) } }) }
  end

  local function saved()
    return TestEnv.GetGlobal("MyAddonDB")
  end

  local function retail(specialization)
    return TestEnv.SetSpecialization({
      projectId = 1,
      specialization = specialization,
      classCount = 3,
    })
  end

  local function classicEra(talentGroup)
    return TestEnv.SetSpecialization({ projectId = 2, talentGroup = talentGroup, talentGroups = 2 })
  end

  local function specEvent()
    TestEnv.Emit("PLAYER_SPECIALIZATION_CHANGED", "player")
  end

  describe("GetSpecIndex", function()
    it("answers the specialization on Retail and Mists of Pandaria Classic", function()
      retail(2)
      assert.are.same({ 2, 3, "specialization" }, { SettingsKit:GetSpecIndex() })
      TestEnv.SetSpecialization({ projectId = 19, specialization = 4, classCount = 4 })
      assert.are.same({ 4, 4, "specialization" }, { SettingsKit:GetSpecIndex() })
    end)

    it("answers the talent group elsewhere and without a project id", function()
      classicEra(2)
      assert.are.same({ 2, 2, "talentGroup" }, { SettingsKit:GetSpecIndex() })
      TestEnv.SetSpecialization({ talentGroup = 1, talentGroups = 1 })
      assert.are.same({ 1, 1, "talentGroup" }, { SettingsKit:GetSpecIndex() })
    end)

    it("counts the active talent group when GetNumTalentGroups is missing or lower", function()
      TestEnv.SetSpecialization({ projectId = 2, talentGroup = 2, talentGroups = false })
      assert.are.same({ 2, 2, "talentGroup" }, { SettingsKit:GetSpecIndex() })
      TestEnv.SetSpecialization({ projectId = 2, talentGroup = 2, talentGroups = 1 })
      assert.are.same({ 2, 2, "talentGroup" }, { SettingsKit:GetSpecIndex() })
    end)

    it("answers no index for the starter specialization and before the data is ready", function()
      local client = retail(5)
      assert.are.same({ nil, 3, "specialization" }, { SettingsKit:GetSpecIndex() })
      client.specialization = nil
      assert.are.same({ nil, 3, "specialization" }, { SettingsKit:GetSpecIndex() })
      client.specialization = 1
      client.initialized = false
      assert.are.same({ nil, 0, "specialization" }, { SettingsKit:GetSpecIndex() })
    end)

    it("answers no index without the client surface", function()
      TestEnv.SetGlobal("WOW_PROJECT_ID", 1)
      assert.are.same({ nil, 0, "specialization" }, { SettingsKit:GetSpecIndex() })
      TestEnv.SetGlobal("C_SpecializationInfo", {})
      assert.are.same({ nil, 0, "specialization" }, { SettingsKit:GetSpecIndex() })
      TestEnv.SetGlobal("WOW_PROJECT_ID", 2)
      assert.are.same({ nil, 0, "talentGroup" }, { SettingsKit:GetSpecIndex() })
      TestEnv.SetGlobal("WOW_PROJECT_ID", 1)
      TestEnv.SetGlobal("UnitClass", nil)
      TestEnv.SetGlobal("C_SpecializationInfo", {
        GetSpecialization = function()
          return 1
        end,
      })
      assert.are.same({ nil, 0, "specialization" }, { SettingsKit:GetSpecIndex() })
    end)

    it("answers no index for a talent group above the highest assignable index", function()
      TestEnv.SetSpecialization({ projectId = 2, talentGroup = 9, talentGroups = 9 })
      assert.are.same({ nil, 9, "talentGroup" }, { SettingsKit:GetSpecIndex() })
    end)

    it("treats secret client answers as unknown", function()
      TestEnv.InstallSecretProbe()
      local secret = TestEnv.NewSecret()
      local client = retail(secret)
      assert.are.same({ nil, 3, "specialization" }, { SettingsKit:GetSpecIndex() })
      client.specialization = 1
      client.classCount = secret
      assert.are.same({ nil, 0, "specialization" }, { SettingsKit:GetSpecIndex() })
      client.classCount = 3
      client.initialized = secret
      assert.are.same({ nil, 0, "specialization" }, { SettingsKit:GetSpecIndex() })
      TestEnv.SetGlobal("UnitClass", function()
        return "Mage", "MAGE", secret
      end)
      client.initialized = true
      assert.are.same({ nil, 0, "specialization" }, { SettingsKit:GetSpecIndex() })
      local era =
        TestEnv.SetSpecialization({ projectId = 2, talentGroup = 1, talentGroups = secret })
      assert.are.same({ 1, 1, "talentGroup" }, { SettingsKit:GetSpecIndex() })
      era.talentGroup = secret
      assert.are.same({ nil, 0, "talentGroup" }, { SettingsKit:GetSpecIndex() })
    end)

    it("refuses a receiver other than the facade at the caller's line", function()
      TestEnv.expectErrorContaining("SpecProfiles_spec.lua", function()
        SettingsKit.GetSpecIndex({})
      end)
    end)
  end)

  describe("assignments", function()
    it("records an assignment per character and reads it back", function()
      retail(nil)
      local db = SettingsKit:Open("MyAddonDB", schemaFor())
      assert.is_nil(db:GetSpecProfile(1))
      assert.is_true(db:SetSpecProfile(1, "Healing"))
      assert.is_true(db:SetSpecProfile(2, "Damage"))
      assert.are.equal("Healing", db:GetSpecProfile(1))
      assert.are.same({ ["Tester - Silvermoon"] = { "Healing", "Damage" } }, saved().specProfiles)
      assert.are.equal("Default", db:GetProfile())
    end)

    it("applies an assignment at once when it names the current index", function()
      retail(2)
      local db = SettingsKit:Open("MyAddonDB", schemaFor())
      local changes = {}
      db:OnProfileChanged(function(_, name, previous)
        changes[#changes + 1] = previous .. ">" .. name
      end)
      db:SetSpecProfile(1, "Healing")
      assert.are.equal("Default", db:GetProfile())
      db:SetSpecProfile(2, "Damage")
      assert.are.equal("Damage", db:GetProfile())
      assert.are.same({ "Default>Damage" }, changes)
      assert.is_table(saved().profiles.Damage)
    end)

    it("clears an assignment, and the character's entry with its last one", function()
      retail(nil)
      local db = SettingsKit:Open("MyAddonDB", schemaFor())
      assert.is_true(db:SetSpecProfile(3, nil))
      db:SetSpecProfile(1, "Healing")
      db:SetSpecProfile(2, "Damage")
      db:SetSpecProfile(1, nil)
      assert.is_nil(db:GetSpecProfile(1))
      assert.are.same({ [2] = "Damage" }, saved().specProfiles["Tester - Silvermoon"])
      db:SetSpecProfile(2)
      assert.is_nil(saved().specProfiles["Tester - Silvermoon"])
    end)

    it("keeps other characters' assignments apart", function()
      retail(nil)
      TestEnv.SavedVariable("MyAddonDB", {
        specProfiles = { ["Other - Silvermoon"] = { "Theirs" } },
      })
      local db = SettingsKit:Open("MyAddonDB", schemaFor())
      assert.is_nil(db:GetSpecProfile(1))
      db:SetSpecProfile(1, "Mine")
      assert.are.equal("Theirs", saved().specProfiles["Other - Silvermoon"][1])
    end)

    it("answers false without a character key", function()
      retail(1)
      TestEnv.SetPlayer({ name = false })
      local db = SettingsKit:Open("MyAddonDB", schemaFor())
      assert.is_false(db:SetSpecProfile(1, "Healing"))
      assert.is_nil(db:GetSpecProfile(1))
      assert.are.equal("Default", db:GetProfile())
    end)

    it("ignores corrupted entries and stored names, and replaces an entry on write", function()
      retail(nil)
      TestEnv.SavedVariable("MyAddonDB", {
        specProfiles = { ["Tester - Silvermoon"] = "broken" },
      })
      local db = SettingsKit:Open("MyAddonDB", schemaFor())
      assert.is_nil(db:GetSpecProfile(1))
      assert.is_true(db:SetSpecProfile(1, nil))
      assert.are.equal("broken", saved().specProfiles["Tester - Silvermoon"])
      db:SetSpecProfile(2, "Damage")
      local entry = saved().specProfiles["Tester - Silvermoon"]
      entry[1] = "   "
      entry[3] = 7
      assert.is_nil(db:GetSpecProfile(1))
      assert.is_nil(db:GetSpecProfile(3))
      assert.are.equal("Damage", db:GetSpecProfile(2))
    end)

    it("refuses a section that is not a table at Open", function()
      TestEnv.SavedVariable("MyAddonDB", { specProfiles = 5 })
      TestEnv.expectErrorContaining("MyAddonDB.specProfiles must be a table", function()
        SettingsKit:Open("MyAddonDB", schemaFor())
      end)
    end)

    it("refuses a section replaced by something other than a table after Open", function()
      local db = SettingsKit:Open("MyAddonDB", schemaFor())
      saved().specProfiles = 5
      TestEnv.expectErrorContaining("MyAddonDB.specProfiles must be a table", function()
        db:SetSpecProfile(1, "Healing")
      end)
      saved().specProfiles = nil
      assert.is_nil(db:GetSpecProfile(1))
      assert.is_true(db:SetSpecProfile(1, "Healing"))
      assert.are.equal("Healing", saved().specProfiles["Tester - Silvermoon"][1])
    end)

    it("forgets assignments naming a deleted profile, for every character", function()
      retail(nil)
      TestEnv.SavedVariable("MyAddonDB", {
        specProfiles = {
          ["Other - Silvermoon"] = { "Doomed" },
          ["Third - Silvermoon"] = { "Doomed", "Kept" },
          ["Broken - Silvermoon"] = "x",
        },
        profiles = { Doomed = {} },
      })
      local db = SettingsKit:Open("MyAddonDB", schemaFor())
      db:SetSpecProfile(2, "Doomed")
      db:DeleteProfile("Doomed")
      assert.are.same({
        ["Third - Silvermoon"] = { [2] = "Kept" },
        ["Broken - Silvermoon"] = "x",
      }, saved().specProfiles)
    end)

    it("skips a secret stored assignment when forgetting", function()
      TestEnv.InstallSecretProbe()
      local secret = TestEnv.NewSecret()
      TestEnv.SavedVariable("MyAddonDB", {
        specProfiles = { ["Other - Silvermoon"] = { secret } },
        profiles = { Doomed = {} },
      })
      local db = SettingsKit:Open("MyAddonDB", schemaFor())
      db:DeleteProfile("Doomed")
      assert.are.equal(secret, saved().specProfiles["Other - Silvermoon"][1])
    end)

    it("forgets nothing when the section was removed", function()
      TestEnv.SavedVariable("MyAddonDB", { profiles = { Doomed = {} } })
      local db = SettingsKit:Open("MyAddonDB", schemaFor())
      saved().specProfiles = nil
      db:DeleteProfile("Doomed")
      assert.is_nil(saved().specProfiles)
    end)

    it("empties the section with ResetDatabase", function()
      retail(nil)
      local db = SettingsKit:Open("MyAddonDB", schemaFor())
      db:SetSpecProfile(1, "Healing")
      db:ResetDatabase()
      assert.are.same({}, saved().specProfiles)
      assert.is_nil(db:GetSpecProfile(1))
    end)

    it("refuses SetSpecProfile on a read-only database and never switches it", function()
      retail(1)
      TestEnv.SavedVariable("MyAddonDB", {
        version = 5,
        specProfiles = { ["Tester - Silvermoon"] = { "Healing" } },
        profiles = { Healing = {} },
      })
      local db = SettingsKit:Open("MyAddonDB", schemaFor(), { version = 1 })
      assert.is_true(db:IsReadOnly())
      assert.are.equal("Default", db:GetProfile())
      assert.are.equal("Healing", db:GetSpecProfile(1))
      TestEnv.expectErrorContaining("read-only", function()
        db:SetSpecProfile(1, "Other")
      end)
      assert.is_false(db:ApplySpecProfile())
      specEvent()
      assert.are.equal("Default", db:GetProfile())
    end)

    it("refuses bad arguments at the caller's line", function()
      TestEnv.InstallSecretProbe()
      local db = SettingsKit:Open("MyAddonDB", schemaFor())
      local refusals = {
        { "index must be an integer from 1 to 8", { 0, "A" } },
        { "index must be an integer from 1 to 8", { 9, "A" } },
        { "index must be an integer from 1 to 8", { 1.5, "A" } },
        { "index must be an integer from 1 to 8", { "1", "A" } },
        { "index must not be a secret value", { TestEnv.NewSecret(), "A" } },
        { "name must be a non-empty string", { 1, 5 } },
        { "name must contain a character other than whitespace", { 1, "  " } },
      }
      for _, case in ipairs(refusals) do
        TestEnv.expectErrorContaining("SpecProfiles_spec.lua", function()
          db:SetSpecProfile(case[2][1], case[2][2])
        end)
        TestEnv.expectErrorContaining(case[1], function()
          db:SetSpecProfile(case[2][1], case[2][2])
        end)
      end
      TestEnv.expectErrorContaining("SpecProfiles_spec.lua", function()
        db:GetSpecProfile(0)
      end)
      TestEnv.expectErrorContaining("must be called on a SettingsKit database", function()
        db.SetSpecProfile({}, 1, "A")
      end)
      TestEnv.expectErrorContaining("must be called on a SettingsKit database", function()
        db.GetSpecProfile({}, 1)
      end)
      TestEnv.expectErrorContaining("SpecProfiles_spec.lua", function()
        db.ApplySpecProfile({})
      end)
    end)
  end)

  describe("switching", function()
    it("switches on each spec event, and only when the index changed", function()
      local client = retail(1)
      local db = SettingsKit:Open("MyAddonDB", schemaFor())
      db:SetSpecProfile(1, "Healing")
      db:SetSpecProfile(2, "Damage")
      assert.are.equal("Healing", db:GetProfile())

      client.specialization = 2
      specEvent()
      assert.are.equal("Damage", db:GetProfile())

      -- A manual choice survives events that change nothing.
      db:SetProfile("Manual")
      TestEnv.Emit("PLAYER_ENTERING_WORLD", false, false)
      TestEnv.Emit("PLAYER_LEVEL_CHANGED", 70, 71)
      assert.are.equal("Manual", db:GetProfile())

      client.specialization = 1
      TestEnv.Emit("ACTIVE_TALENT_GROUP_CHANGED", 1, 2)
      assert.are.equal("Healing", db:GetProfile())

      client.specialization = 3
      specEvent()
      assert.are.equal("Healing", db:GetProfile())
      client.specialization = 2
      TestEnv.Emit("PLAYER_LEVEL_CHANGED", 9, 10)
      assert.are.equal("Damage", db:GetProfile())
    end)

    it("ignores another unit's specialization change", function()
      local client = retail(1)
      local db = SettingsKit:Open("MyAddonDB", schemaFor())
      db:SetSpecProfile(2, "Damage")
      client.specialization = 2
      TestEnv.Emit("PLAYER_SPECIALIZATION_CHANGED", "party1")
      assert.are.equal("Default", db:GetProfile())
    end)

    it("switches by talent group on Classic Era", function()
      local client = classicEra(1)
      local db = SettingsKit:Open("MyAddonDB", schemaFor())
      db:SetSpecProfile(2, "Secondary")
      client.talentGroup = 2
      TestEnv.Emit("ACTIVE_TALENT_GROUP_CHANGED", 2, 1)
      assert.are.equal("Secondary", db:GetProfile())
    end)

    it(
      "does nothing while the index is unknown, and catches up at PLAYER_ENTERING_WORLD",
      function()
        local client = retail(1)
        client.initialized = false
        TestEnv.SavedVariable("MyAddonDB", {
          specProfiles = { ["Tester - Silvermoon"] = { "Healing" } },
        })
        local db = SettingsKit:Open("MyAddonDB", schemaFor())
        assert.are.equal("Default", db:GetProfile())
        specEvent()
        assert.are.equal("Default", db:GetProfile())
        client.initialized = true
        TestEnv.Emit("PLAYER_ENTERING_WORLD", true, false)
        assert.are.equal("Healing", db:GetProfile())
      end
    )

    it("applies a stored assignment at Open", function()
      retail(1)
      TestEnv.SavedVariable("MyAddonDB", {
        specProfiles = { ["Tester - Silvermoon"] = { "Healing" } },
      })
      local db = SettingsKit:Open("MyAddonDB", schemaFor())
      assert.are.equal("Healing", db:GetProfile())
      assert.are.equal("Healing", saved().profileKeys["Tester - Silvermoon"])
    end)

    it("switches every open database with an assignment", function()
      local client = retail(1)
      local first = SettingsKit:Open("FirstDB", schemaFor())
      local second = SettingsKit:Open("SecondDB", schemaFor())
      local untouched = SettingsKit:Open("ThirdDB", schemaFor())
      first:SetSpecProfile(2, "One")
      second:SetSpecProfile(2, "Two")
      client.specialization = 2
      specEvent()
      assert.are.equal("One", first:GetProfile())
      assert.are.equal("Two", second:GetProfile())
      assert.are.equal("Default", untouched:GetProfile())
    end)

    it("keeps the profile when the current index has no assignment", function()
      local client = retail(1)
      local db = SettingsKit:Open("MyAddonDB", schemaFor())
      db:SetSpecProfile(1, "Healing")
      client.specialization = 3
      specEvent()
      assert.are.equal("Healing", db:GetProfile())
      assert.is_false(db:ApplySpecProfile())
    end)

    it("connects the shared listener once, and only when an assignment exists", function()
      local client = retail(1)
      local db = SettingsKit:Open("MyAddonDB", schemaFor())
      local state = rawget(SettingsKit, "_state")
      assert.is_false(state.specListenerConnected)
      db:SetSpecProfile(1, "Healing")
      assert.is_true(state.specListenerConnected)
      local other = SettingsKit:Open("OtherDB", schemaFor())
      other:SetSpecProfile(2, "Two")
      db:SetSpecProfile(2, "Damage")
      local changes = 0
      db:OnProfileChanged(function()
        changes = changes + 1
      end)
      client.specialization = 2
      specEvent()
      assert.are.equal(1, changes)
    end)
    it("follows the index while a character has no assignment, and applies a later one", function()
      local client = retail(1)
      local db = SettingsKit:Open("MyAddonDB", schemaFor())
      db:SetSpecProfile(1, "Healing")
      assert.are.equal("Healing", db:GetProfile())
      db:SetSpecProfile(1, nil)
      -- No assignment now: the change to index 2 switches nothing, but the
      -- database must not keep believing it applied index 1.
      client.specialization = 2
      specEvent()
      db:SetProfile("Manual")
      db:SetSpecProfile(1, "Healing")
      assert.are.equal("Manual", db:GetProfile())
      client.specialization = 1
      specEvent()
      assert.are.equal("Healing", db:GetProfile())
    end)
  end)

  describe("databases opened during a spec event", function()
    it("switches every database when a listener opens enough databases to rehash", function()
      local client = retail(1)
      local names = {}
      local switched = {}
      local opened = false
      for index = 1, 6 do
        local name = "SpecDB" .. index
        names[index] = name
        local db = SettingsKit:Open(name, schemaFor())
        db:SetSpecProfile(2, "Two")
        db:OnProfileChanged(function()
          switched[name] = (switched[name] or 0) + 1
          -- The first switch of the event, whichever database the
          -- traversal reaches first, opens enough databases to make the
          -- database table grow, each with an assignment for the index.
          if not opened then
            opened = true
            for extra = 1, 100 do
              local extraDb = SettingsKit:Open("OpenedDB" .. extra, schemaFor())
              extraDb:SetSpecProfile(2, "Two")
            end
          end
        end)
      end
      client.specialization = 2
      specEvent()
      for index = 1, #names do
        assert.are.equal("Two", SettingsKit:Open(names[index]):GetProfile())
        assert.are.equal(1, switched[names[index]])
      end
      for extra = 1, 100 do
        assert.are.equal("Two", SettingsKit:Open("OpenedDB" .. extra):GetProfile())
      end
    end)
  end)

  describe("without EventKit", function()
    it("switches only through ApplySpecProfile", function()
      local Kit, _, SchemaKit = TestEnv.NewPackageWithoutEventKit()
      S = SchemaKit
      local client = retail(1)
      local db = Kit:Open("MyAddonDB", schemaFor())
      db:SetSpecProfile(1, "Healing")
      assert.are.equal("Healing", db:GetProfile())
      assert.is_false(rawget(Kit, "_state").specListenerConnected)
      db:SetSpecProfile(2, "Damage")
      client.specialization = 2
      specEvent()
      assert.are.equal("Healing", db:GetProfile())
      assert.is_true(db:ApplySpecProfile())
      assert.are.equal("Damage", db:GetProfile())
      assert.is_false(db:ApplySpecProfile())
    end)

    it("does not connect when Registry has no Find", function()
      local Kit, Registry, SchemaKit = TestEnv.NewPackageWithoutEventKit()
      S = SchemaKit
      retail(1)
      local find = rawget(Registry, "Find")
      rawset(Registry, "Find", nil)
      local db = Kit:Open("MyAddonDB", schemaFor())
      db:SetSpecProfile(1, "Healing")
      rawset(Registry, "Find", find)
      assert.is_false(rawget(Kit, "_state").specListenerConnected)
      assert.are.equal("Healing", db:GetProfile())
    end)
  end)

  describe("in-place upgrade from revision 11", function()
    it("keeps a manual choice over an assignment the database already applied", function()
      local client = retail(1)
      local db = SettingsKit:Open("MyAddonDB", schemaFor())
      db:SetSpecProfile(1, "Healing")
      db:SetProfile("Manual")
      local changes = 0
      db:OnProfileChanged(function()
        changes = changes + 1
      end)
      local upgraded = TestEnv.LoadRevision(SettingsKit.REVISION + 1)
      assert.are.equal(SettingsKit, upgraded)
      assert.are.equal("Manual", db:GetProfile())
      assert.are.equal(0, changes)
      -- The next change of index still applies the assignments.
      db:SetSpecProfile(2, "Damage")
      client.specialization = 2
      specEvent()
      assert.are.equal("Damage", db:GetProfile())
      client.specialization = 1
      specEvent()
      assert.are.equal("Healing", db:GetProfile())
    end)
  end)

  describe("in-place upgrade from revision 10", function()
    it("gives databases revision 10 opened the methods and the switching", function()
      TestEnv.Reset()
      TestEnv.InstallWowApi()
      require("Registry")
      require("SignalKit")
      require("EventKit")
      local SchemaKit = require("SchemaKit")
      S = SchemaKit
      local previous = TestEnv.LoadRevision(10)
      TestEnv.SetPlayer()
      local client = retail(1)
      local state = rawget(previous, "_state")
      local db = previous:Open("MyAddonDB", schemaFor())
      local other = previous:Open("OtherDB", schemaFor())

      -- What revision 10 left: no spec methods, dispatch entries, flag or
      -- section, and an assignment a newer copy wrote in an earlier session.
      rawset(previous, "GetSpecIndex", nil)
      for _, name in ipairs({ "SetSpecProfile", "GetSpecProfile", "ApplySpecProfile" }) do
        rawset(previous.Database, name, nil)
      end
      for _, name in ipairs({ "onSpecEvent", "onDatabaseOpened", "forgetSpecProfiles" }) do
        rawset(state.dispatch, name, nil)
      end
      state.specListenerConnected = nil
      TestEnv.GetGlobal("MyAddonDB").specProfiles = nil
      TestEnv.GetGlobal("OtherDB").specProfiles = { ["Tester - Silvermoon"] = { "Healing" } }

      local upgraded = TestEnv.ReloadPackage()
      assert.are.equal(previous, upgraded)
      assert.are.equal(12, upgraded.REVISION)
      assert.are.equal(db, upgraded:Open("MyAddonDB"))
      assert.are.equal("Healing", other:GetProfile())
      assert.is_true(state.specListenerConnected)

      assert.is_nil(db:GetSpecProfile(2))
      db:SetSpecProfile(2, "Damage")
      assert.are.equal(
        "Damage",
        TestEnv.GetGlobal("MyAddonDB").specProfiles["Tester - Silvermoon"][2]
      )
      client.specialization = 2
      specEvent()
      assert.are.equal("Damage", db:GetProfile())
      assert.are.same({ 2, 3, "specialization" }, { upgraded:GetSpecIndex() })
    end)

    it("keeps the shared listener across a later upgrade", function()
      local client = retail(1)
      local db = SettingsKit:Open("MyAddonDB", schemaFor())
      db:SetSpecProfile(2, "Damage")
      local upgraded = TestEnv.LoadRevision(SettingsKit.REVISION + 1)
      assert.are.equal(SettingsKit, upgraded)
      client.specialization = 2
      specEvent()
      assert.are.equal("Damage", db:GetProfile())
    end)
  end)
end)
