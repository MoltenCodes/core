local TestEnv = require("SettingsKitTestEnv")

-- The Namespaces part (part revision 1, core revision 15).
describe("SettingsKit namespaces", function()
  local SettingsKit, S
  before_each(function()
    local _
    SettingsKit, _, _, _, S = TestEnv.NewPackage()
    TestEnv.LoadNamespaces()
  end)
  after_each(TestEnv.Reset)

  local function parentSchema()
    return { profile = S.table({ fields = { scale = S.optional(S.number(), 1) } }) }
  end

  local barsSchema = nil
  local function bars()
    barsSchema = barsSchema
      or {
        profile = S.table({
          fields = {
            shown = S.optional(S.boolean(), true),
            size = S.optional(S.number({ min = 1, max = 100 }), 36),
          },
        }),
        char = S.table({ fields = { seen = S.optional(S.number(), 0) } }),
      }
    return barsSchema
  end
  after_each(function()
    barsSchema = nil
  end)

  local function saved()
    return TestEnv.GetGlobal("MyAddonDB")
  end

  local function open(options)
    return SettingsKit:Open("MyAddonDB", parentSchema(), options)
  end

  describe("registration", function()
    it("returns a child database over namespaces[name] in AceDB's layout", function()
      local db = open()
      local child = db:RegisterNamespace("Bars", bars())
      assert.are.equal(true, child.profile.shown)
      child.profile.size = 40
      child.char.seen = 2
      assert.are.same({
        profiles = { Default = { size = 40 } },
        char = { ["Tester - Silvermoon"] = { seen = 2 } },
      }, saved().namespaces.Bars)
      assert.is_nil(saved().namespaces.Bars.profileKeys)
      assert.are.equal("Default", child:GetProfile())
      assert.are.equal("MyAddonDB", child:GetSavedVariable())
      assert.is_true(child:IsNewProfile())
    end)

    it("reads data saved before, as an importer would write it", function()
      TestEnv.SavedVariable("MyAddonDB", {
        namespaces = { Bars = { profiles = { Default = { size = 50 } } } },
      })
      local child = open():RegisterNamespace("Bars", bars())
      assert.are.equal(50, child.profile.size)
      assert.is_false(child:IsNewProfile())
    end)

    it("validates writes and fires the namespace's own OnChange", function()
      local db = open()
      local child = db:RegisterNamespace("Bars", bars())
      local heard = {}
      child:OnChange("profile", function(source, _, key, value)
        heard[#heard + 1] = { source, key, value }
      end)
      child.profile.size = 10
      assert.are.same({ { child, "size", 10 } }, heard)
      assert.has_error(function()
        child.profile.size = 500
      end)
      assert.are.equal(10, child.profile.size)
      assert.is_true(child:Validate("profile", "size", 20))
      assert.are.equal(10, child:Getter("profile", "size")())
    end)

    it("returns the same namespace for the same schema table and refuses another", function()
      local db = open()
      local child = db:RegisterNamespace("Bars", bars())
      assert.are.equal(child, db:RegisterNamespace("Bars", bars()))
      assert.has_error(
        function()
          db:RegisterNamespace("Bars", { profile = S.table({ fields = {} }) })
        end,
        "SettingsKit.Database:RegisterNamespace MyAddonDB namespace Bars is already registered with a different schema table"
      )
    end)

    it("refuses bad names, schemas, nesting and saved tables at the caller's line", function()
      local db = open()
      TestEnv.InstallSecretProbe()
      local cases = {
        { 5, bars(), "SettingsKit.Database:RegisterNamespace name must be a non-empty string" },
        {
          "  ",
          bars(),
          "SettingsKit.Database:RegisterNamespace name must contain a character other than whitespace",
        },
        {
          TestEnv.NewSecret(),
          bars(),
          "SettingsKit.Database:RegisterNamespace name must be a non-empty string",
        },
        {
          string.rep("x", 65),
          bars(),
          "SettingsKit.Database:RegisterNamespace name must be at most 64 bytes long",
        },
        {
          "Bars",
          "schema",
          "SettingsKit.Database:RegisterNamespace schema must be a table of scope schemas",
        },
        {
          "Bars",
          {},
          "SettingsKit.Database:RegisterNamespace schema must declare at least one scope",
        },
        {
          "Bars",
          { profile = S.table({ fields = { x = S.number() } }) },
          "SettingsKit.Database:RegisterNamespace schema.profile.x must be optional: a saved variable starts empty",
        },
      }
      for _, case in ipairs(cases) do
        assert.has_error(function()
          db:RegisterNamespace(case[1], case[2])
        end, case[3])
      end
      local child = db:RegisterNamespace("Bars", bars())
      assert.has_error(
        function()
          child:RegisterNamespace("Inner", bars())
        end,
        "SettingsKit.Database:RegisterNamespace cannot be called on a namespace: namespaces do not nest"
      )
      assert.has_error(function()
        db.RegisterNamespace({}, "Bars", bars())
      end, "SettingsKit.Database:RegisterNamespace must be called on a SettingsKit database")
    end)

    it("refuses a saved namespace or section that is not a table", function()
      TestEnv.SavedVariable("MyAddonDB", { namespaces = { Bars = 5, Other = { profiles = 5 } } })
      local db = open()
      assert.has_error(function()
        db:RegisterNamespace("Bars", bars())
      end, "SettingsKit.Database:RegisterNamespace MyAddonDB.namespaces.Bars must be a table")
      assert.has_error(
        function()
          db:RegisterNamespace("Other", bars())
        end,
        "SettingsKit.Database:RegisterNamespace MyAddonDB.namespaces.Other.profiles must be a table"
      )
    end)

    it("keeps to maxNamespaces, 256 by default, and lifts it with UNBOUNDED", function()
      local db = open({ maxNamespaces = 2 })
      db:RegisterNamespace("A", bars())
      db:RegisterNamespace("B", bars())
      assert.has_error(
        function()
          db:RegisterNamespace("C", bars())
        end,
        "SettingsKit.Database:RegisterNamespace cannot register more than 2 namespaces in MyAddonDB; raise options.maxNamespaces in SettingsKit:Open"
      )
      local unbounded =
        SettingsKit:Open("OtherDB", parentSchema(), { maxNamespaces = SettingsKit.UNBOUNDED })
      for index = 1, 300 do
        unbounded:RegisterNamespace("Module" .. index, bars())
      end
      local default = SettingsKit:Open("ThirdDB", parentSchema())
      for index = 1, 256 do
        default:RegisterNamespace("Module" .. index, bars())
      end
      assert.has_error(function()
        default:RegisterNamespace("Module257", bars())
      end)
    end)

    it("names a namespace that is not an identifier with quotes", function()
      local child = open():RegisterNamespace("Two words", { global = S.table({ fields = {} }) })
      assert.are.equal('MyAddonDB namespace ["Two words"]', rawget(child, "_name"))
    end)

    it("creates nothing in a read-only database and reads defaults or saved data", function()
      TestEnv.SavedVariable("MyAddonDB", {
        version = 3,
        namespaces = { Saved = { profiles = { Default = { size = 70 } } } },
      })
      local db = open({ version = 2 })
      local fresh = db:RegisterNamespace("Fresh", bars())
      local stored = db:RegisterNamespace("Saved", bars())
      assert.are.equal(36, fresh.profile.size)
      assert.are.equal(70, stored.profile.size)
      assert.is_nil(saved().namespaces.Fresh)
      assert.is_true(fresh:IsReadOnly())
      assert.has_error(function()
        fresh.profile.size = 2
      end)
    end)
  end)

  describe("GetNamespace", function()
    it("returns the registered namespace, raises for a missing one unless missingOk", function()
      local db = open()
      local child = db:RegisterNamespace("Bars", bars())
      assert.are.equal(child, db:GetNamespace("Bars"))
      assert.has_error(function()
        db:GetNamespace("Nowhere")
      end, "SettingsKit.Database:GetNamespace name names no registered namespace")
      assert.is_nil(db:GetNamespace("Nowhere", { missingOk = true }))
      assert.has_error(
        function()
          child:GetNamespace("Bars")
        end,
        "SettingsKit.Database:GetNamespace cannot be called on a namespace: namespaces do not nest"
      )
      assert.has_error(function()
        db:GetNamespace("Bars", { silent = true })
      end, 'SettingsKit.Database:GetNamespace options contains unknown field "silent"')
    end)
  end)

  describe("the namespace's own methods", function()
    it("refuses the profile methods its parent owns, naming the parent", function()
      local child = open():RegisterNamespace("Bars", bars())
      local calls = {
        SetProfile = { "Other" },
        CopyProfile = { "Other" },
        DeleteProfile = { "Other" },
        ResetDatabase = {},
        SetSpecProfile = { 1, "Other" },
        ApplySpecProfile = {},
      }
      for method, arguments in pairs(calls) do
        assert.has_error(
          function()
            child[method](child, unpack(arguments))
          end,
          "SettingsKit.Database:"
            .. method
            .. " cannot be called on MyAddonDB namespace Bars; call it on the database of MyAddonDB"
        )
      end
    end)

    it("answers its parent's profiles and spec assignments", function()
      TestEnv.SetSpecialization({ projectId = 1, specialization = 2, classCount = 3 })
      local db = open()
      db:SetProfile("Other")
      db:SetSpecProfile(1, "Healing")
      local child = db:RegisterNamespace("Bars", bars())
      assert.are.same({ "Default", "Other" }, child:GetProfiles())
      assert.are.equal("Healing", child:GetSpecProfile(1))
    end)

    it("ResetProfile empties only the namespace's current profile", function()
      local db = open()
      local child = db:RegisterNamespace("Bars", bars())
      db.profile.scale = 2
      child.profile.size = 10
      local heard = 0
      child:OnProfileReset(function()
        heard = heard + 1
      end)
      child:ResetProfile()
      assert.are.equal(36, child.profile.size)
      assert.are.equal(2, db.profile.scale)
      assert.are.equal(1, heard)
    end)

    it("Compact compacts the namespace only", function()
      local db = open()
      local child = db:RegisterNamespace("Bars", bars())
      db.profile.scale = 1
      child.profile.size = 36
      assert.are.equal(1, child:Compact())
      assert.are.equal(1, rawget(saved().profiles.Default, "scale"))
    end)

    it("Resync finds a saved table replaced by a direct edit", function()
      local db = open()
      local child = db:RegisterNamespace("Bars", bars())
      saved().namespaces.Bars = { profiles = { Default = { size = 12 } } }
      child:Resync()
      assert.are.equal(12, child.profile.size)
      saved().namespaces.Bars = { profiles = { Default = { size = 13 } } }
      db:Resync()
      assert.are.equal(13, child.profile.size)
    end)
  end)

  describe("cascading profile operations", function()
    ---Two namespaces whose every signal is logged, as `"<who> <signal> ..."`.
    local function setUp()
      local db = open()
      local first = db:RegisterNamespace("First", bars())
      local second = db:RegisterNamespace("Second", bars())
      local log = {}
      local function watch(target, who)
        target:OnProfileShutdown(function(_, name)
          log[#log + 1] = who .. " shutdown " .. name
        end)
        target:OnNewProfile(function(_, name)
          log[#log + 1] = who .. " new " .. name
        end)
        target:OnProfileChanged(function(_, name, previous)
          log[#log + 1] = who .. " changed " .. name .. " " .. previous
        end)
        target:OnProfileCopied(function(_, from, name)
          log[#log + 1] = who .. " copied " .. from .. " " .. name
        end)
        target:OnProfileReset(function(_, name)
          log[#log + 1] = who .. " reset " .. name
        end)
        target:OnProfileDeleted(function(_, name)
          log[#log + 1] = who .. " deleted " .. name
        end)
        target:OnDatabaseReset(function()
          log[#log + 1] = who .. " databaseReset"
        end)
      end
      watch(db, "parent")
      watch(first, "first")
      watch(second, "second")
      return db, first, second, log
    end

    it(
      "SetProfile switches every namespace; shutdowns parent first, reports signal by signal, parent last",
      function()
        local db, first, second, log = setUp()
        first.profile.size = 10
        db:SetProfile("Other")
        assert.are.same({
          "parent shutdown Default",
          "first shutdown Default",
          "second shutdown Default",
          "first new Other",
          "second new Other",
          "first changed Other Default",
          "second changed Other Default",
          "parent new Other",
          "parent changed Other Default",
        }, log)
        assert.are.equal("Other", first:GetProfile())
        assert.are.equal(36, first.profile.size)
        second.profile.size = 20
        db:SetProfile("Default")
        assert.are.equal(10, first.profile.size)
        assert.are.equal(36, second.profile.size)
        assert.are.same({ size = 20 }, saved().namespaces.Second.profiles.Other)
      end
    )

    it("a namespace's listener sees every namespace already switched", function()
      local db, first, second = setUp()
      local seen = nil
      first:OnProfileChanged(function()
        seen = second:GetProfile()
      end)
      db:SetProfile("Other")
      assert.are.equal("Other", seen)
    end)

    it("a raising namespace listener reaches the caller with every change made", function()
      local db, first, second = setUp()
      first:OnProfileChanged(function()
        error("listener failed", 0)
      end)
      assert.has_error(function()
        db:SetProfile("Other")
      end, "listener failed")
      assert.are.equal("Other", db:GetProfile())
      assert.are.equal("Other", second:GetProfile())
    end)

    it("spec switches cascade like any SetProfile", function()
      local client =
        TestEnv.SetSpecialization({ projectId = 1, specialization = 1, classCount = 3 })
      local db, first = setUp()
      db:SetSpecProfile(2, "Damage")
      client.specialization = 2
      db:ApplySpecProfile()
      assert.are.equal("Damage", first:GetProfile())
    end)

    it("CopyProfile copies every namespace's profile, an absent source as empty", function()
      local db, first, second, log = setUp()
      db:SetProfile("Source")
      first.profile.size = 11
      db:SetProfile("Default")
      second.profile.size = 22
      for index = #log, 1, -1 do
        log[index] = nil
      end
      db:CopyProfile("Source")
      assert.are.equal(11, first.profile.size)
      assert.are.equal(36, second.profile.size)
      assert.are.same({
        "first copied Source Default",
        "second copied Source Default",
        "parent copied Source Default",
      }, log)
    end)

    it("ResetProfile and DeleteProfile reach every namespace", function()
      local db, first, second, log = setUp()
      db:SetProfile("Gone")
      first.profile.size = 5
      db:SetProfile("Default")
      second.profile.size = 6
      for index = #log, 1, -1 do
        log[index] = nil
      end
      db:ResetProfile()
      assert.are.equal(36, second.profile.size)
      local kept = first.profile
      db:DeleteProfile("Gone")
      assert.is_nil(saved().namespaces.First.profiles.Gone)
      assert.are.same({
        "first reset Default",
        "second reset Default",
        "parent reset Default",
        "first deleted Gone",
        "second deleted Gone",
        "parent deleted Gone",
      }, log)
      assert.are.equal(36, kept.size)
    end)

    it("detaches a namespace's view of a deleted profile", function()
      local db, first = setUp()
      db:SetProfile("Gone")
      local view = first.profile
      view.size = 5
      db:SetProfile("Default")
      db:DeleteProfile("Gone")
      assert.are.equal(36, view.size)
      assert.has_error(function()
        view.size = 7
      end)
    end)

    it("ResetDatabase rebuilds every namespace and detaches its profile views", function()
      local db, first, _, log = setUp()
      db:SetProfile("Other")
      local old = first.profile
      first.profile.size = 9
      first.char.seen = 3
      for index = #log, 1, -1 do
        log[index] = nil
      end
      db:ResetDatabase()
      assert.are.same({ profiles = { Default = {} }, char = {} }, saved().namespaces.First)
      assert.are.equal("Default", first:GetProfile())
      assert.are.equal(36, first.profile.size)
      assert.are.equal(0, first.char.seen)
      assert.are_not.equal(old, first.profile)
      first.profile.size = 4
      assert.are.equal(4, saved().namespaces.First.profiles.Default.size)
      assert.are.same({
        "first databaseReset",
        "second databaseReset",
        "first new Default",
        "second new Default",
        "first reset Default",
        "second reset Default",
        "first changed Default Other",
        "second changed Default Other",
        "parent databaseReset",
        "parent new Default",
        "parent reset Default",
        "parent changed Default Other",
      }, log)
    end)

    it("reaches namespaces nobody registered this session, raw, as AceDB does", function()
      TestEnv.SavedVariable("MyAddonDB", {
        profiles = { Default = {}, Source = {}, Gone = {} },
        namespaces = {
          Idle = { profiles = { Source = { a = { 1 } }, Default = { b = 2 }, Gone = { c = 3 } } },
          Odd = 5,
        },
      })
      local db = open()
      db:RegisterNamespace("Bars", bars())
      db:CopyProfile("Source")
      local idle = saved().namespaces.Idle.profiles
      assert.are.same({ a = { 1 } }, idle.Default)
      assert.are_not.equal(idle.Source.a, idle.Default.a)
      db:DeleteProfile("Gone")
      assert.is_nil(idle.Gone)
      db:ResetProfile()
      assert.is_nil(idle.Default)
      assert.are.equal(5, saved().namespaces.Odd)
    end)

    it("refuses a copy too deep in a namespace before anything changes", function()
      local db = open()
      local child = db:RegisterNamespace("Bars", { profile = S.table({ fields = {} }) })
      local deep = {}
      local cursor = deep
      for _ = 1, 20 do
        cursor.next = {}
        cursor = cursor.next
      end
      db:SetProfile("Source")
      db:SetProfile("Default")
      db.profile.scale = 3
      saved().namespaces.Bars.profiles.Source = { deep = deep }
      assert.has_error(
        function()
          db:CopyProfile("Source")
        end,
        "SettingsKit.Database:CopyProfile from nests more than 16 tables in MyAddonDB namespace Bars"
      )
      assert.are.equal(3, db.profile.scale)
      assert.are.equal(child, db:GetNamespace("Bars"))
    end)

    it("the parent's Compact compacts every namespace", function()
      local db, first, second = setUp()
      db.profile.scale = 1
      first.profile.size = 36
      second.profile.size = 36
      assert.are.equal(3, db:Compact())
    end)
  end)

  describe("logout", function()
    it("fires shutdowns parent first, compacts, then removes empty namespaces", function()
      TestEnv.SavedVariable("MyAddonDB", {
        namespaces = {
          Idle = { profiles = { Default = {} }, char = {} },
          Kept = { global = { x = 1 } },
        },
      })
      local db = open()
      local child = db:RegisterNamespace("Bars", bars())
      local order = {}
      db:OnDatabaseShutdown(function()
        order[#order + 1] = "parent"
      end)
      child:OnDatabaseShutdown(function()
        order[#order + 1] = "child"
        child.profile.size = 36
      end)
      child.char.seen = 0
      TestEnv.Logout()
      assert.are.same({ "parent", "child" }, order)
      assert.is_nil(saved().namespaces.Bars)
      assert.is_nil(saved().namespaces.Idle)
      assert.are.same({ global = { x = 1 } }, saved().namespaces.Kept)
      assert.is_table(saved().profiles.Default)
    end)

    it("reports a raising namespace listener and keeps going", function()
      local db = open()
      local child = db:RegisterNamespace("Bars", bars())
      child:OnDatabaseShutdown(function()
        error("namespace listener failed", 0)
      end)
      child.profile.size = 50
      TestEnv.TakeReportedErrors()
      TestEnv.Logout()
      local reported = TestEnv.TakeReportedErrors()
      assert.are.equal(1, #reported)
      assert.are.equal("namespace listener failed", reported[1].value)
      assert.are.equal(50, saved().namespaces.Bars.profiles.Default.size)
    end)
  end)

  describe("the part", function()
    it("serves databases opened before it loaded", function()
      TestEnv.Reset()
      local _
      SettingsKit, _, _, _, S = TestEnv.NewPackage()
      local db = open()
      TestEnv.LoadNamespaces()
      local child = db:RegisterNamespace("Bars", bars())
      db:SetProfile("Other")
      assert.are.equal("Other", child:GetProfile())
    end)

    it("is named by the core when it is not loaded", function()
      TestEnv.Reset()
      local _
      SettingsKit, _, _, _, S = TestEnv.NewPackage()
      local db = open()
      assert.has_error(
        function()
          db:RegisterNamespace("Bars", bars())
        end,
        "SettingsKit.Database:RegisterNamespace is in SettingsKit's Namespaces part, which is not loaded: add settingsKit\\parts\\SettingsKit-Namespaces.lua"
      )
      assert.has_error(
        function()
          db:GetNamespace("Bars")
        end,
        "SettingsKit.Database:GetNamespace is in SettingsKit's Namespaces part, which is not loaded: add settingsKit\\parts\\SettingsKit-Namespaces.lua"
      )
    end)

    it("returns at once when an equal revision is already installed", function()
      local state = rawget(SettingsKit, "_state")
      local dispatchEntry = state.dispatch.namespaces
      assert.are.equal(SettingsKit, TestEnv.LoadNamespaces())
      assert.are.equal(dispatchEntry, state.dispatch.namespaces)
      assert.are.equal(1, state.parts.Namespaces.revision)
    end)

    it("refuses to load without its core", function()
      TestEnv.Reset()
      TestEnv.InstallWowApi()
      require("Registry")
      assert.has_error(function()
        TestEnv.LoadNamespaces()
      end, "MoltenCodes SettingsKit part Namespaces requires SettingsKit API 1 to be loaded first")
    end)

    it("keeps cascading after a later core revision upgrades in place", function()
      local db = open()
      local child = db:RegisterNamespace("Bars", bars())
      local upgraded = TestEnv.LoadRevision(16)
      assert.are.equal(SettingsKit, upgraded)
      assert.are.equal(16, upgraded.REVISION)
      db:SetProfile("Other")
      assert.are.equal("Other", child:GetProfile())
      child.profile.size = 3
      assert.are.equal(3, saved().namespaces.Bars.profiles.Other.size)
      assert.are.equal(child, db:GetNamespace("Bars"))
    end)

    it(
      "allocates nothing reading, writing, or switching between existing profiles #allocation",
      function()
        local db = open()
        local child = db:RegisterNamespace("Bars", bars())
        db:SetProfile("Other")
        db:SetProfile("Default")
        local _ = child.profile.size
        child.profile.size = 2
        db:SetProfile("Other")
        _ = child.profile.size
        db:SetProfile("Default")
        local kilobytes = TestEnv.AllocatedKilobytes(function()
          for _ = 1, 100 do
            local read = child.profile.size
            child.profile.size = read
            db:SetProfile("Other")
            db:SetProfile("Default")
          end
        end)
        assert.are.equal(0, kilobytes)
      end
    )
  end)
end)
