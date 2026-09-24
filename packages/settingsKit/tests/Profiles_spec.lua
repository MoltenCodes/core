local TestEnv = require("SettingsKitTestEnv")

describe("SettingsKit profiles", function()
  local SettingsKit, S
  before_each(function()
    local _
    SettingsKit, _, _, _, S = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  local function schema()
    return {
      profile = S.table({
        fields = {
          scale = S.optional(S.number(), 1),
          frame = S.optional(S.table({ fields = { x = S.optional(S.number(), 0) } }), {}),
        },
      }),
    }
  end

  local function saved()
    return TestEnv.GetGlobal("MyAddonDB")
  end

  it("starts on the shared Default profile", function()
    local db = SettingsKit:Open("MyAddonDB", schema())
    assert.are.equal("Default", db:GetProfile())
    assert.are.equal("Default", SettingsKit.DEFAULT_PROFILE)
    assert.are.same({ "Default" }, db:GetProfiles())
    assert.are.same({}, saved().profiles.Default)
  end)

  it('starts on a per-character profile with defaultProfile = "char"', function()
    local db = SettingsKit:Open("MyAddonDB", schema(), { defaultProfile = "char" })
    assert.are.equal("Tester - Silvermoon", db:GetProfile())
  end)

  it(
    'falls back to Default for defaultProfile = "char" when the character key is unavailable',
    function()
      TestEnv.SetPlayer({ realm = false })
      local db = SettingsKit:Open("MyAddonDB", schema(), { defaultProfile = "char" })
      assert.are.equal("Default", db:GetProfile())
    end
  )

  it("accepts any other profile name as the default", function()
    local db = SettingsKit:Open("MyAddonDB", schema(), { defaultProfile = "Shared" })
    assert.are.equal("Shared", db:GetProfile())
  end)

  it("switches profile, creates it, records it per character and fires OnProfileChanged", function()
    local db = SettingsKit:Open("MyAddonDB", schema())
    local before = db.profile
    db.profile.scale = 2

    local calls = {}
    db:OnProfileChanged(function(...)
      calls[#calls + 1] = { ... }
    end)

    assert.is_true(db:SetProfile("Raid"))
    assert.are.equal("Raid", db:GetProfile())
    assert.are_not.equal(before, db.profile)
    assert.are.equal(1, db.profile.scale)
    assert.are.same({}, saved().profiles.Raid)
    assert.are.equal("Raid", saved().profileKeys["Tester - Silvermoon"])
    assert.are.same({ { db, "Raid", "Default" } }, calls)

    assert.is_false(db:SetProfile("Raid"))
    assert.are.equal(1, #calls)

    -- The earlier view keeps reading the profile it was made for.
    assert.are.equal(2, before.scale)
  end)

  it("reopens on the profile a character chose in an earlier session", function()
    local db = SettingsKit:Open("MyAddonDB", schema())
    db:SetProfile("Raid")
    db.profile.scale = 1.5
    local raw = saved()

    local reloaded = { TestEnv.NewPackage() }
    SettingsKit, S = reloaded[1], reloaded[5]
    TestEnv.SavedVariable("MyAddonDB", raw)
    local reopened = SettingsKit:Open("MyAddonDB", schema())
    assert.are.equal("Raid", reopened:GetProfile())
    assert.are.equal(1.5, reopened.profile.scale)
  end)

  it("lists profiles sorted", function()
    TestEnv.SavedVariable(
      "MyAddonDB",
      { profiles = { zeta = {}, Alpha = {}, beta = {}, [3] = {} } }
    )
    local db = SettingsKit:Open("MyAddonDB", schema())
    local names = db:GetProfiles()
    assert.are.same({ "Alpha", "Default", "beta", "zeta" }, names)
    assert.are_not.equal(names, db:GetProfiles())
  end)

  it("copies another profile over the current one and fires OnProfileCopied", function()
    local db = SettingsKit:Open("MyAddonDB", schema())
    db:SetProfile("Source")
    db.profile.frame.x = 4
    db.profile.scale = 2
    db:SetProfile("Target")
    db.profile.scale = 1.5
    local view = db.profile

    local calls = {}
    db:OnProfileCopied(function(...)
      calls[#calls + 1] = { ... }
    end)
    db:CopyProfile("Source")

    assert.are.equal(view, db.profile)
    assert.are.equal(2, db.profile.scale)
    assert.are.equal(4, db.profile.frame.x)
    assert.are_not.equal(saved().profiles.Source.frame, saved().profiles.Target.frame)
    assert.are.same({ { db, "Source", "Target" } }, calls)
  end)

  it("refuses to copy the current profile or a missing one", function()
    local db = SettingsKit:Open("MyAddonDB", schema())
    TestEnv.expectErrorContaining("cannot copy the current profile onto itself", function()
      db:CopyProfile("Default")
    end)
    TestEnv.expectErrorContaining("names a profile that does not exist", function()
      db:CopyProfile("Nope")
    end)
  end)

  it("resets the current profile in place and fires OnProfileReset", function()
    local db = SettingsKit:Open("MyAddonDB", schema())
    db.profile.scale = 2
    local profileTable = saved().profiles.Default
    local calls = {}
    db:OnProfileReset(function(...)
      calls[#calls + 1] = { ... }
    end)

    db:ResetProfile()
    assert.are.equal(1, db.profile.scale)
    assert.are.equal(profileTable, saved().profiles.Default)
    assert.are.same({}, profileTable)
    assert.are.same({ { db, "Default" } }, calls)
  end)

  it("deletes another profile, forgets characters that used it, and detaches its views", function()
    local db = SettingsKit:Open("MyAddonDB", schema())
    db:SetProfile("Old")
    db.profile.scale = 2
    local oldView = db.profile
    db:SetProfile("Default")
    saved().profileKeys["Alt - Silvermoon"] = "Old"

    local calls = {}
    db:OnProfileDeleted(function(...)
      calls[#calls + 1] = { ... }
    end)
    db:DeleteProfile("Old")

    assert.is_nil(saved().profiles.Old)
    assert.is_nil(saved().profileKeys["Alt - Silvermoon"])
    assert.are.same({ "Default" }, db:GetProfiles())
    assert.are.same({ { db, "Old" } }, calls)
    assert.are.equal(1, oldView.scale)
    TestEnv.expectErrorContaining("belongs to a profile that was deleted", function()
      oldView.scale = 3
    end)
    assert.is_nil(saved().profiles.Old)
  end)

  it("refuses to delete the current profile or a missing one", function()
    local db = SettingsKit:Open("MyAddonDB", schema())
    TestEnv.expectErrorContaining("cannot delete the current profile", function()
      db:DeleteProfile("Default")
    end)
    TestEnv.expectErrorContaining("names a profile that does not exist", function()
      db:DeleteProfile("Nope")
    end)
  end)

  it("validates profile names", function()
    local db = SettingsKit:Open("MyAddonDB", schema())
    TestEnv.expectErrorContaining("SetProfile name must be a non-empty string", function()
      db:SetProfile(1)
    end)
    TestEnv.expectErrorContaining("must contain a character other than whitespace", function()
      db:SetProfile("   ")
    end)
    TestEnv.expectErrorContaining("must be at most 64 bytes long", function()
      db:SetProfile(string.rep("x", 65))
    end)
  end)

  it("ignores a corrupted stored profile key", function()
    TestEnv.SavedVariable("MyAddonDB", { profileKeys = { ["Tester - Silvermoon"] = 42 } })
    local db = SettingsKit:Open("MyAddonDB", schema())
    assert.are.equal("Default", db:GetProfile())
  end)

  it("resets the whole database to an empty layout", function()
    local db = SettingsKit:Open("MyAddonDB", schema(), { version = 3 })
    db:SetProfile("Raid")
    db.profile.scale = 2
    local raidView = db.profile
    local raw = saved()
    raw.extra = true

    local changed, reset = {}, {}
    db:OnProfileChanged(function(...)
      changed[#changed + 1] = { ... }
    end)
    db:OnProfileReset(function(...)
      reset[#reset + 1] = { ... }
    end)
    db:ResetDatabase()

    assert.are.equal(raw, saved())
    assert.is_nil(raw.extra)
    assert.are.equal(3, raw.version)
    assert.are.same({ Default = {} }, raw.profiles)
    assert.are.same({}, raw.profileKeys)
    assert.are.same({}, raw.namespaces)
    assert.are.equal("Default", db:GetProfile())
    assert.are.equal(1, db.profile.scale)
    assert.are.same({ { db, "Default" } }, reset)
    assert.are.same({ { db, "Default", "Raid" } }, changed)
    TestEnv.expectErrorContaining("belongs to a profile that was deleted or reset away", function()
      raidView.scale = 1
    end)
  end)

  it("keeps profile methods working when no profile schema is declared", function()
    local db = SettingsKit:Open("MyAddonDB", { global = S.table({ fields = {} }) })
    db:SetProfile("Other")
    assert.are.same({ "Default", "Other" }, db:GetProfiles())
    TestEnv.expectErrorContaining("db.profile is not declared", function()
      return db.profile
    end)
  end)
end)
