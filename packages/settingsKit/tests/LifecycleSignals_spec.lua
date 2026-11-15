local TestEnv = require("SettingsKitTestEnv")

-- Revision 15: OnNewProfile, OnProfileShutdown, OnDatabaseShutdown,
-- OnDatabaseReset and IsNewProfile.
describe("SettingsKit profile lifecycle signals", function()
  local SettingsKit, S
  before_each(function()
    local _
    SettingsKit, _, _, _, S = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  local function schema()
    return {
      profile = S.table({ fields = { scale = S.optional(S.number(), 1) } }),
    }
  end

  ---Record every lifecycle signal of `db` in `log`, as `"<signal> <args>"`.
  local function record(db, log)
    db:OnProfileShutdown(function(source, name)
      log[#log + 1] = "shutdown " .. name .. " " .. source.profile.scale
    end)
    db:OnNewProfile(function(_, name)
      log[#log + 1] = "new " .. name
    end)
    db:OnProfileChanged(function(_, name, previous)
      log[#log + 1] = "changed " .. name .. " " .. previous
    end)
    db:OnProfileReset(function(_, name)
      log[#log + 1] = "reset " .. name
    end)
    db:OnProfileCopied(function(_, from, name)
      log[#log + 1] = "copied " .. from .. " " .. name
    end)
    db:OnDatabaseReset(function()
      log[#log + 1] = "databaseReset"
    end)
  end

  it("fires OnProfileShutdown before a switch, then OnNewProfile, then OnProfileChanged", function()
    local db = SettingsKit:Open("MyAddonDB", schema())
    db.profile.scale = 3
    local log = {}
    record(db, log)
    assert.is_true(db:SetProfile("Other"))
    -- The shutdown listener still read the old profile.
    assert.are.same({ "shutdown Default 3", "new Other", "changed Other Default" }, log)
  end)

  it(
    "fires no OnNewProfile when switching to an existing profile, nothing for the current one",
    function()
      local db = SettingsKit:Open("MyAddonDB", schema())
      db:SetProfile("Other")
      local log = {}
      record(db, log)
      db:SetProfile("Default")
      assert.are.same({ "shutdown Other 1", "changed Default Other" }, log)
      for index = #log, 1, -1 do
        log[index] = nil
      end
      assert.is_false(db:SetProfile("Default"))
      assert.are.same({}, log)
    end
  )

  it("leaves the profile unswitched when an OnProfileShutdown listener raises", function()
    local db = SettingsKit:Open("MyAddonDB", schema())
    db:OnProfileShutdown(function()
      error("not now", 0)
    end)
    assert.has_error(function()
      db:SetProfile("Other")
    end, "not now")
    assert.are.equal("Default", db:GetProfile())
    assert.is_nil(TestEnv.GetGlobal("MyAddonDB").profiles.Other)
  end)

  it("fires OnNewProfile from a spec switch, which goes through SetProfile", function()
    TestEnv.SetSpecialization({ projectId = 1, specialization = 1, classCount = 3 })
    local db = SettingsKit:Open("MyAddonDB", schema())
    local log = {}
    record(db, log)
    db:SetSpecProfile(1, "Healing")
    assert.are.same({ "shutdown Default 1", "new Healing", "changed Healing Default" }, log)
  end)

  it("fires OnDatabaseReset first in ResetDatabase, then OnNewProfile and the rest", function()
    local db = SettingsKit:Open("MyAddonDB", schema())
    db:SetProfile("Other")
    local log = {}
    record(db, log)
    db:ResetDatabase()
    assert.are.same(
      { "databaseReset", "new Default", "reset Default", "changed Default Other" },
      log
    )
  end)

  it(
    "fires OnNewProfile from CopyProfile and ResetProfile when the current profile's table was missing",
    function()
      local db = SettingsKit:Open("MyAddonDB", schema())
      db:SetProfile("Other")
      local saved = TestEnv.GetGlobal("MyAddonDB")
      local log = {}
      record(db, log)
      saved.profiles.Other = nil
      db:Resync()
      db:ResetProfile()
      assert.are.same({ "new Other", "reset Other" }, log)
      for index = #log, 1, -1 do
        log[index] = nil
      end
      saved.profiles.Other = nil
      db:Resync()
      db:CopyProfile("Default")
      assert.are.same({ "new Other", "copied Default Other" }, log)
      for index = #log, 1, -1 do
        log[index] = nil
      end
      db:ResetProfile()
      assert.are.same({ "reset Other" }, log)
    end
  )

  describe("IsNewProfile", function()
    it("is true after Open created a new character's first profile", function()
      local db = SettingsKit:Open("MyAddonDB", schema())
      assert.is_true(db:IsNewProfile())
    end)

    it("is false after Open of a profile already saved", function()
      TestEnv.SavedVariable("MyAddonDB", { profiles = { Default = { scale = 2 } } })
      local db = SettingsKit:Open("MyAddonDB", schema())
      assert.is_false(db:IsNewProfile())
      db:SetProfile("Other")
      assert.is_true(db:IsNewProfile())
      db:SetProfile("Default")
      assert.is_false(db:IsNewProfile())
    end)

    it("is false on a read-only database, which creates nothing", function()
      TestEnv.SavedVariable("MyAddonDB", { version = 3 })
      local db = SettingsKit:Open("MyAddonDB", schema(), { version = 2 })
      assert.is_true(db:IsReadOnly())
      assert.is_false(db:IsNewProfile())
    end)

    it("refuses a receiver that is not a database", function()
      local db = SettingsKit:Open("MyAddonDB", schema())
      assert.has_error(function()
        db.IsNewProfile({})
      end, "SettingsKit.Database:IsNewProfile must be called on a SettingsKit database")
    end)
  end)

  describe("OnDatabaseShutdown", function()
    local function logout()
      TestEnv.Logout()
    end

    it("fires at logout before compaction, so a final write is compacted too", function()
      local db = SettingsKit:Open("MyAddonDB", schema())
      local heard = 0
      db:OnDatabaseShutdown(function(source)
        assert.are.equal(db, source)
        heard = heard + 1
        db.profile.scale = 1
      end)
      db.profile.scale = 5
      logout()
      assert.are.equal(1, heard)
      assert.is_nil(rawget(TestEnv.GetGlobal("MyAddonDB").profiles.Default, "scale"))
    end)

    it("fires for a read-only database, which is then not compacted", function()
      TestEnv.SavedVariable("MyAddonDB", { version = 3, profiles = { Default = { scale = 1 } } })
      local db = SettingsKit:Open("MyAddonDB", schema(), { version = 2 })
      local heard = 0
      db:OnDatabaseShutdown(function()
        heard = heard + 1
      end)
      logout()
      assert.are.equal(1, heard)
      assert.are.equal(1, rawget(TestEnv.GetGlobal("MyAddonDB").profiles.Default, "scale"))
    end)

    it("reports a raising listener and still shuts down and compacts the next database", function()
      local first = SettingsKit:Open("FirstDB", schema())
      local second = SettingsKit:Open("SecondDB", schema())
      first:OnDatabaseShutdown(function()
        error("broken listener", 0)
      end)
      local heard = 0
      second:OnDatabaseShutdown(function()
        heard = heard + 1
      end)
      second.profile.scale = 1
      rawset(TestEnv.GetGlobal("SecondDB").profiles.Default, "scale", 1)
      TestEnv.TakeReportedErrors()
      logout()
      local reported = TestEnv.TakeReportedErrors()
      assert.are.equal(1, #reported)
      assert.are.equal("broken listener", reported[1].value)
      assert.are.equal(1, heard)
      assert.is_nil(rawget(TestEnv.GetGlobal("SecondDB").profiles.Default, "scale"))
    end)

    it("needs EventKit: without it nothing fires", function()
      TestEnv.Reset()
      local Kit, _, Schema = TestEnv.NewPackageWithoutEventKit()
      local db = Kit:Open("MyAddonDB", {
        profile = Schema.table({ fields = { scale = Schema.optional(Schema.number(), 1) } }),
      })
      local heard = 0
      db:OnDatabaseShutdown(function()
        heard = heard + 1
      end)
      logout()
      assert.are.equal(0, heard)
    end)
  end)

  it("refuses a callback that is not a function, at the caller's line", function()
    local db = SettingsKit:Open("MyAddonDB", schema())
    for _, method in ipairs({
      "OnNewProfile",
      "OnProfileShutdown",
      "OnDatabaseShutdown",
      "OnDatabaseReset",
    }) do
      assert.has_error(function()
        db[method](db, "not a function")
      end, "SettingsKit.Database:" .. method .. " callback must be a function")
    end
  end)

  it("allocates no signal until a listener connects", function()
    local db = SettingsKit:Open("MyAddonDB", schema())
    db:SetProfile("Other")
    db:ResetDatabase()
    assert.is_nil(rawget(db, "_signals"))
  end)
end)

describe("SettingsKit missingOk", function()
  local SettingsKit, S
  before_each(function()
    local _
    SettingsKit, _, _, _, S = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  local function open()
    return SettingsKit:Open("MyAddonDB", {
      profile = S.table({ fields = { scale = S.optional(S.number(), 1) } }),
    })
  end

  it("answers false instead of raising for a missing profile", function()
    local db = open()
    assert.is_false(db:CopyProfile("Nowhere", { missingOk = true }))
    assert.is_false(db:DeleteProfile("Nowhere", { missingOk = true }))
  end)

  it("answers true when the work was done", function()
    local db = open()
    db:SetProfile("Other")
    db.profile.scale = 2
    db:SetProfile("Default")
    assert.is_true(db:CopyProfile("Other"))
    assert.are.equal(2, db.profile.scale)
    assert.is_true(db:DeleteProfile("Other", { missingOk = true }))
  end)

  it("still raises without missingOk and keeps every other refusal", function()
    local db = open()
    assert.has_error(function()
      db:DeleteProfile("Nowhere", { missingOk = false })
    end, "SettingsKit.Database:DeleteProfile name names a profile that does not exist")
    assert.has_error(function()
      db:DeleteProfile("Default", { missingOk = true })
    end, "SettingsKit.Database:DeleteProfile cannot delete the current profile")
    assert.has_error(function()
      db:CopyProfile("Default", { missingOk = true })
    end, "SettingsKit.Database:CopyProfile cannot copy the current profile onto itself")
  end)

  it("refuses bad options at the caller's line", function()
    local db = open()
    TestEnv.InstallSecretProbe()
    local cases = {
      { "not a table", "SettingsKit.Database:CopyProfile options must be a table" },
      {
        { silent = true },
        'SettingsKit.Database:CopyProfile options contains unknown field "silent"',
      },
      {
        { missingOk = "yes" },
        "SettingsKit.Database:CopyProfile options.missingOk must be a boolean",
      },
      {
        { missingOk = TestEnv.NewSecret() },
        "SettingsKit.Database:CopyProfile options.missingOk must not be a secret value",
      },
    }
    for _, case in ipairs(cases) do
      assert.has_error(function()
        db:CopyProfile("Nowhere", case[1])
      end, case[2])
    end
  end)

  it("validates Open's maxNamespaces", function()
    TestEnv.InstallSecretProbe()
    assert.has_error(
      function()
        SettingsKit:Open("BadDB", { global = S.table({ fields = {} }) }, { maxNamespaces = 0 })
      end,
      "SettingsKit:Open options.maxNamespaces must be a positive integer or SettingsKit.UNBOUNDED"
    )
    assert.has_error(function()
      SettingsKit:Open(
        "BadDB",
        { global = S.table({ fields = {} }) },
        { maxNamespaces = TestEnv.NewSecret() }
      )
    end, "SettingsKit:Open options.maxNamespaces must not be a secret value")
    local db = SettingsKit:Open(
      "GoodDB",
      { global = S.table({ fields = {} }) },
      { maxNamespaces = SettingsKit.UNBOUNDED }
    )
    assert.are.equal(math.huge, rawget(db, "_maxNamespaces"))
    assert.is_nil(rawget(open(), "_maxNamespaces"))
  end)
end)
