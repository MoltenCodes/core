-- BridgeKit's AceDB-3.0 importer (docs/BRIDGE_KIT_DESIGN.md, section 7):
-- every section landing where SettingsKit reads it, every value checked
-- against the addon's schema, AceDB defaults that differ written as values,
-- profiles and characters renamed or dropped, the scopes and namespaces
-- SettingsKit lacks, the three methods, the backup, the limits and the plan
-- errors; and a round trip through SettingsKit itself, reading every field as
-- AceDB read it.
local Env = require("BridgeKitTestEnv")

local CHARACTER = "Tester - Silvermoon"

---Every entry of `report` for `path`, as `action (reason)` strings.
local function notedAt(report, path)
  local found = {}
  for _, entry in ipairs(report.entries) do
    if entry.path == path then
      found[#found + 1] = entry.action .. " (" .. entry.reason .. ")"
    end
  end
  return found
end

---Whether `report` has an entry for `path` with `reason`.
local function hasEntry(report, path, reason)
  for _, entry in ipairs(report.entries) do
    if entry.path == path and entry.reason == reason then
      return true
    end
  end
  return false
end

describe("BridgeKit AceDB importer", function()
  local BridgeKit, SettingsKit, S
  local schema

  before_each(function()
    BridgeKit, SettingsKit, S = Env.NewPackageWithSettingsKit()
    -- The globals the specs import into, cleared again by `Env.Reset`.
    for _, name in ipairs({ "MyAddonDB", "MyAddonSettings", "MyAddonDB_Backup", "Taken" }) do
      Env.SavedVariable(name, nil)
    end
    schema = {
      profile = S.table({
        fields = {
          scale = S.optional(S.number({ min = 0.5, max = 2 }), 1),
          shown = S.optional(S.boolean(), true),
          frame = S.optional(S.table({
            fields = {
              x = S.optional(S.number(), 0),
              y = S.optional(S.number(), 0),
            },
          })),
          auras = S.optional(S.map({
            keys = S.number(),
            values = S.optional(
              S.table({ fields = { shown = S.optional(S.boolean(), true) } }),
              {}
            ),
            max = 3,
          })),
          tags = S.optional(S.array({ of = S.string() })),
        },
      }),
      global = S.table({
        fields = {
          version = S.optional(S.number()),
          byRace = S.optional(S.map({
            keys = S.string(),
            values = S.optional(S.table({ fields = {}, open = true })),
            max = 16,
          })),
          bars = S.optional(S.table({ fields = {}, open = true })),
        },
      }),
      char = S.table({
        fields = {
          level = S.optional(S.number(), 1),
          bars = S.optional(S.table({ fields = {}, open = true })),
        },
      }),
      realm = S.table({ fields = { gold = S.optional(S.number(), 0) } }),
      class = S.table({ fields = { spec = S.optional(S.string(), "none") } }),
      faction = S.table({ fields = { banner = S.optional(S.string()) } }),
    }
  end)
  after_each(Env.Reset)

  ---The AceDB saved variable most specs import.
  local function aceTable()
    return {
      profileKeys = { [CHARACTER] = "Default", ["Alt - Silvermoon"] = "Raid" },
      profiles = {
        Default = {
          scale = 1.5,
          frame = { x = 10 },
          auras = { [118] = { shown = false } },
          tags = { "a", "b" },
        },
        Raid = { shown = false },
      },
      char = { [CHARACTER] = { level = 60 } },
      realm = { Silvermoon = { gold = 100 } },
      class = { MAGE = { spec = "fire" } },
      faction = { Alliance = { banner = "lion" } },
      global = { version = 3 },
    }
  end

  describe("sections", function()
    it("land where SettingsKit reads them", function()
      local report = BridgeKit:ImportAceDB(
        aceTable(),
        "MyAddonSettings",
        { schema = schema, aceDefaults = {}, version = 1 }
      )
      assert.is_table(report)
      local target = Env.Global("MyAddonSettings")
      assert.are.same({
        scale = 1.5,
        frame = { x = 10 },
        auras = { [118] = { shown = false } },
        tags = { "a", "b" },
      }, target.profiles.Default)
      assert.are.same({ shown = false }, target.profiles.Raid)
      assert.are.same(
        { [CHARACTER] = "Default", ["Alt - Silvermoon"] = "Raid" },
        target.profileKeys
      )
      assert.are.same({ [CHARACTER] = { level = 60 } }, target.char)
      assert.are.same({ Silvermoon = { gold = 100 } }, target.realm)
      assert.are.same({ MAGE = { spec = "fire" } }, target.class)
      assert.are.same({ Alliance = { banner = "lion" } }, target.faction)
      assert.are.same({ version = 3 }, target.global)
      assert.are.same({}, target.namespaces)
      assert.are.equal(1, target.version)
    end)

    it("read in SettingsKit what they read in AceDB, also after compaction", function()
      BridgeKit:ImportAceDB(
        aceTable(),
        "MyAddonSettings",
        { schema = schema, aceDefaults = {}, version = 1 }
      )
      local db = SettingsKit:Open("MyAddonSettings", schema, { version = 1 })
      local function reads()
        return {
          db.profile.scale,
          db.profile.shown,
          db.profile.frame.x,
          db.profile.auras[118].shown,
          db.char.level,
          db.realm.gold,
          db.class.spec,
          db.faction.banner,
          db.global.version,
        }
      end
      local before = reads()
      assert.are.same({ 1.5, true, 10, false, 60, 100, "fire", "lion", 3 }, before)
      db:Compact()
      assert.are.same(before, reads())
      db:SetProfile("Raid")
      assert.is_false(db.profile.shown)
    end)

    it("drop scopes the schema does not declare and keys AceDB does not write", function()
      local source = aceTable()
      source.mystery = { 1 }
      local partial = { profile = schema.profile }
      local report = BridgeKit:PreviewAceDB(source, { schema = partial, aceDefaults = {} })
      assert.is_true(hasEntry(report, "char", "undeclaredScope"))
      assert.is_true(hasEntry(report, "global", "undeclaredScope"))
      assert.is_true(hasEntry(report, "mystery", "unknownTopLevelKey"))
    end)
  end)

  describe("defaults", function()
    it("materialise an AceDB default that differs from SettingsKit's", function()
      local report = BridgeKit:ImportAceDB({ profiles = { Default = {} } }, "MyAddonSettings", {
        schema = schema,
        aceDefaults = { profile = { scale = 1.25, shown = true, frame = { x = 5 } } },
      })
      local profile = Env.Global("MyAddonSettings").profiles.Default
      assert.are.same({ scale = 1.25, frame = { x = 5 } }, profile)
      assert.are.same(
        { "materialised (defaultDiffers)" },
        notedAt(report, "profiles.Default.scale")
      )
      assert.are.same(
        { "materialised (defaultDiffers)" },
        notedAt(report, "profiles.Default.frame.x")
      )
      assert.are.same({}, notedAt(report, "profiles.Default.shown"))
      assert.are.equal(2, report.counts.materialised)
    end)

    it("drop a differing default the schema refuses, and say so", function()
      local report = BridgeKit:PreviewAceDB({ profiles = { Default = {} } }, {
        schema = schema,
        aceDefaults = { profile = { scale = 9 } },
      })
      assert.are.same({ "dropped (schemaRefused)" }, notedAt(report, "profiles.Default.scale"))
      for _, entry in ipairs(report.entries) do
        if entry.path == "profiles.Default.scale" then
          assert.is_truthy(entry.detail:find("max", 1, true))
        end
      end
    end)

    it(
      "apply AceDB wildcards to the keys a map holds and note a differing wildcard once",
      function()
        local report = BridgeKit:ImportAceDB(
          { profiles = { Default = { auras = { [1] = {}, [2] = { shown = true } } } } },
          "MyAddonSettings",
          {
            schema = schema,
            aceDefaults = { profile = { auras = { ["*"] = { shown = false } } } },
          }
        )
        local auras = Env.Global("MyAddonSettings").profiles.Default.auras
        assert.are.same({ [1] = { shown = false }, [2] = { shown = true } }, auras)
        assert.are.same(
          { "changed (wildcardDefaultDiffers)" },
          notedAt(report, "profiles.Default.auras")
        )
      end
    )

    it("merge an explicit AceDB default over `**`", function()
      BridgeKit:ImportAceDB({ char = { [CHARACTER] = {} } }, "MyAddonSettings", {
        schema = schema,
        aceDefaults = { char = { ["**"] = { level = 9 } } },
      })
      -- `**` reaches every key of each character's table: the open record
      -- `bars` reads `{ level = 9 }` under AceDB, so it is written.
      assert.are.same(
        { [CHARACTER] = { bars = { level = 9 } } },
        Env.Global("MyAddonSettings").char
      )
      local report = BridgeKit:PreviewAceDB({ profiles = { Default = { auras = { [5] = {} } } } }, {
        schema = schema,
        aceDefaults = { profile = { auras = { ["**"] = { shown = false }, [5] = {} } } },
      })
      assert.are.same(
        { "materialised (defaultDiffers)" },
        notedAt(report, "profiles.Default.auras[5].shown")
      )
    end)

    it("note, once per field, a scope default that differs for entries the source lacks", function()
      local report = BridgeKit:PreviewAceDB(
        {},
        { schema = schema, aceDefaults = { char = { level = 5 } } }
      )
      assert.are.same({ "changed (defaultDiffers)" }, notedAt(report, "char.level"))
    end)

    it("note once when the AceDB defaults are unknown, and materialise nothing", function()
      local report = BridgeKit:PreviewAceDB({ profiles = { Default = {} } }, { schema = schema })
      assert.are.same({ "changed (aceDefaultsUnknown)" }, notedAt(report, ""))
      assert.are.equal(0, report.counts.materialised)
    end)
  end)

  describe("validation", function()
    it(
      "drop values the schema refuses, with SchemaKit's path and rule but never the value",
      function()
        local report = BridgeKit:PreviewAceDB(
          { profiles = { Default = { scale = "huge", frame = 5, extra = 1 } } },
          {
            schema = schema,
            aceDefaults = {},
          }
        )
        assert.are.same({ "dropped (schemaRefused)" }, notedAt(report, "profiles.Default.scale"))
        assert.are.same({ "dropped (schemaRefused)" }, notedAt(report, "profiles.Default.frame"))
        assert.are.same({ "dropped (schemaRefused)" }, notedAt(report, "profiles.Default.extra"))
        for _, entry in ipairs(report.entries) do
          assert.is_nil(entry.detail and entry.detail:find("huge", 1, true))
        end
      end
    )

    it("keep undeclared fields of an open record", function()
      BridgeKit:ImportAceDB(
        { global = { bars = { anything = { 1, 2 } } } },
        "MyAddonSettings",
        { schema = schema, aceDefaults = {} }
      )
      assert.are.same({ anything = { 1, 2 } }, Env.Global("MyAddonSettings").global.bars)
    end)

    it("drop what a saved variable can never hold", function()
      local secret = {}
      Env.MarkSecret(secret)
      local report = BridgeKit:PreviewAceDB({
        global = { bars = { fn = print, meta = setmetatable({}, {}), hidden = secret } },
      }, { schema = schema, aceDefaults = {} })
      assert.are.same({ "dropped (notStorable)" }, notedAt(report, "global.bars.fn"))
      assert.are.same({ "dropped (notStorable)" }, notedAt(report, "global.bars.meta"))
      assert.are.same({ "dropped (secretValue)" }, notedAt(report, "global.bars.hidden"))
    end)

    it("keep a full map's first keys in sorted order", function()
      local auras = { [5] = {}, [1] = {}, [4] = {}, [2] = {} }
      local report = BridgeKit:ImportAceDB(
        { profiles = { Default = { auras = auras } } },
        "MyAddonSettings",
        {
          schema = schema,
          aceDefaults = { profile = { auras = { ["*"] = { shown = false } } } },
        }
      )
      local imported = Env.Global("MyAddonSettings").profiles.Default.auras
      assert.are.same(
        { 1, 2, 4 },
        (function()
          local keys = {}
          for key in pairs(imported) do
            keys[#keys + 1] = key
          end
          table.sort(keys)
          return keys
        end)()
      )
      assert.is_true(hasEntry(report, "profiles.Default.auras", "mapFull"))
    end)

    it("stop at SchemaKit's depth and refuse a source past maxImportEntries", function()
      local deep = {}
      local cursor = deep
      for _ = 1, 40 do
        cursor.next = {}
        cursor = cursor.next
      end
      local report = BridgeKit:PreviewAceDB(
        { global = { bars = deep } },
        { schema = schema, aceDefaults = {} }
      )
      assert.is_true(hasEntry(report, "global.bars.next", "tooDeep"))

      BridgeKit:SetLimits({ maxImportEntries = 5 })
      local preview, reason =
        BridgeKit:PreviewAceDB(aceTable(), { schema = schema, aceDefaults = {} })
      assert.are.equal("maxImportEntries", reason)
      assert.is_table(preview)
      local imported, refusal, partial =
        BridgeKit:ImportAceDB(aceTable(), "MyAddonSettings", { schema = schema, aceDefaults = {} })
      assert.is_nil(imported)
      assert.are.equal("maxImportEntries", refusal)
      assert.is_table(partial)
      assert.is_nil(Env.Global("MyAddonSettings"))
    end)
  end)

  describe("profiles and characters", function()
    it("drop a profile name SettingsKit refuses, and choices that name it", function()
      local report = BridgeKit:ImportAceDB({
        profileKeys = { [CHARACTER] = string.rep("x", 70), Other = "   " },
        profiles = { [string.rep("x", 70)] = {}, ["   "] = {}, Kept = {} },
      }, "MyAddonSettings", { schema = schema, aceDefaults = {} })
      assert.are.same({ Kept = {} }, Env.Global("MyAddonSettings").profiles)
      assert.are.same({}, Env.Global("MyAddonSettings").profileKeys)
      assert.is_true(
        hasEntry(report, 'profiles["' .. string.rep("x", 32) .. '..."]', "profileNameTooLong")
      )
      assert.is_true(hasEntry(report, 'profiles["   "]', "profileNameBlank"))
      assert.is_true(hasEntry(report, 'profileKeys["' .. CHARACTER .. '"]', "danglingProfileKey"))
    end)

    it("rename profiles and characters through the plan, and drop what it refuses", function()
      local report = BridgeKit:ImportAceDB(
        {
          profileKeys = { [CHARACTER] = "Old", ["Gone - Realm"] = "Old" },
          profiles = { Old = { scale = 2 }, Drop = {}, Twin = {} },
          char = { [CHARACTER] = { level = 2 }, ["Gone - Realm"] = { level = 3 } },
        },
        "MyAddonSettings",
        {
          schema = schema,
          aceDefaults = {},
          renameProfile = function(name)
            if name == "Drop" then
              return nil
            end
            return name == "Old" and "New" or "New"
          end,
          renameCharacter = function(key)
            return key ~= "Gone - Realm" and key or nil
          end,
        }
      )
      local target = Env.Global("MyAddonSettings")
      assert.are.same({ New = { scale = 2 } }, target.profiles)
      assert.are.same({ [CHARACTER] = "New" }, target.profileKeys)
      assert.are.same({ [CHARACTER] = { level = 2 } }, target.char)
      assert.is_true(hasEntry(report, "profiles.Old", "renamedProfile"))
      assert.is_true(hasEntry(report, "profiles.Drop", "renamedProfile"))
      assert.is_true(hasEntry(report, "profiles.Twin", "keyCollision"))
      assert.is_true(hasEntry(report, 'char["Gone - Realm"]', "renamedCharacter"))
    end)

    it("report the current character missing under the key SettingsKit uses", function()
      local report = BridgeKit:PreviewAceDB(
        { char = { ["Someone - Silvermoon"] = { level = 2 } } },
        { schema = schema, aceDefaults = {} }
      )
      assert.is_true(hasEntry(report, 'char["' .. CHARACTER .. '"]', "currentCharacterMissing"))
    end)

    it("key the current character by its unmodified name, as AceDB and SettingsKit do", function()
      -- UnitName answers "Tester" (a name-changing effect, say); the unmodified
      -- name is the key AceDB saved and the key SettingsKit opens.
      Env.SetPlayer("Tèster")
      local report = BridgeKit:PreviewAceDB(
        { char = { ["Tèster - Silvermoon"] = { level = 2 } } },
        { schema = schema, aceDefaults = {} }
      )
      assert.is_false(hasEntry(report, 'char["Tèster - Silvermoon"]', "currentCharacterMissing"))
      assert.is_false(hasEntry(report, 'char["Tèster - Silvermoon"]', "characterKeyMismatch"))
      assert.is_false(hasEntry(report, 'char["' .. CHARACTER .. '"]', "currentCharacterMissing"))
    end)

    it("fall back to UnitName when the unmodified name is unusable", function()
      Env.SetPlayer("")
      local report = BridgeKit:PreviewAceDB(
        { char = { ["Someone - Silvermoon"] = { level = 2 } } },
        { schema = schema, aceDefaults = {} }
      )
      assert.is_true(hasEntry(report, 'char["' .. CHARACTER .. '"]', "currentCharacterMissing"))
    end)

    it("ask SettingsKit:GetCharacterKey when the loaded SettingsKit has it", function()
      Env.SetPlayer("Tèster")
      local asked = 0
      rawset(SettingsKit, "GetCharacterKey", function()
        asked = asked + 1
        return "Chosen - Realm"
      end)
      local report = BridgeKit:PreviewAceDB(
        { char = { ["Tèster - Silvermoon"] = { level = 2 } } },
        { schema = schema, aceDefaults = {} }
      )
      rawset(SettingsKit, "GetCharacterKey", nil)
      assert.are.equal(1, asked)
      assert.is_true(hasEntry(report, 'char["Chosen - Realm"]', "currentCharacterMissing"))
    end)
  end)

  describe("scopes and namespaces SettingsKit lacks", function()
    it("map an AceDB scope into a global map field, or drop it", function()
      -- The plan's mappings, as a SettingsKit before revision 15 takes them.
      rawset(SettingsKit, "REVISION", 14)
      local source = { race = { Human = { a = 1 }, Orc = { b = 2 } }, locale = { enus = {} } }
      local report = BridgeKit:ImportAceDB(source, "MyAddonSettings", {
        schema = schema,
        aceDefaults = {},
        scopes = { race = { into = "global", field = "byRace" } },
      })
      assert.are.same(
        { Human = { a = 1 }, Orc = { b = 2 } },
        Env.Global("MyAddonSettings").global.byRace
      )
      assert.is_true(hasEntry(report, "locale", "unsupportedScope"))
    end)

    it("put a namespace's sections under a field of the same sections, or drop it", function()
      -- The plan's mappings, as a SettingsKit before revision 15 takes them.
      rawset(SettingsKit, "REVISION", 14)
      local source = aceTable()
      source.namespaces = {
        Bars = {
          profiles = { Default = { count = 4 } },
          char = { [CHARACTER] = { slot = 1 } },
          global = { seen = true },
        },
        Unmapped = { global = {} },
      }
      local profileSchema =
        S.table({ fields = { bars = S.optional(S.table({ fields = {}, open = true })) } })
      local plan = {
        schema = { profile = profileSchema, char = schema.char, global = schema.global },
        aceDefaults = {},
        namespaces = { Bars = { field = "bars" } },
      }
      local report = BridgeKit:ImportAceDB(source, "MyAddonSettings", plan)
      local target = Env.Global("MyAddonSettings")
      assert.are.same({ count = 4 }, target.profiles.Default.bars)
      assert.are.same({ slot = 1 }, target.char[CHARACTER].bars)
      assert.are.same({ seen = true }, target.global.bars)
      assert.is_true(hasEntry(report, "namespaces.Unmapped", "unmappedNamespace"))
    end)
  end)

  describe("namespaces and scopes with SettingsKit revision 15", function()
    it(
      "copies every namespace in AceDB's layout and reports a plan entry it no longer needs",
      function()
        local source = aceTable()
        source.namespaces = {
          Bars = {
            profiles = { Default = { size = 4 }, Raid = { size = 6 } },
            char = { [CHARACTER] = { shown = true } },
            global = { seen = 3 },
            race = { Human = { a = 1 } },
            unknown = { dropped = true },
          },
        }
        local profileSchema =
          S.table({ fields = { bars = S.optional(S.table({ fields = {}, open = true })) } })
        local report = BridgeKit:ImportAceDB(source, "MyAddonSettings", {
          schema = { profile = profileSchema, char = schema.char, global = schema.global },
          aceDefaults = {},
          namespaces = { Bars = { field = "bars" } },
        })
        local saved = Env.Global("MyAddonSettings").namespaces.Bars
        assert.are.same({ Default = { size = 4 }, Raid = { size = 6 } }, saved.profiles)
        assert.are.same({ [CHARACTER] = { shown = true } }, saved.char)
        assert.are.same({ seen = 3 }, saved.global)
        assert.are.same({ Human = { a = 1 } }, saved.race)
        assert.is_nil(saved.unknown)
        assert.is_true(hasEntry(report, "namespaces.Bars", "nativeNamespace"))
        assert.is_false(hasEntry(report, "namespaces.Bars", "unmappedNamespace"))
        -- SettingsKit's own namespace reads what was imported.
        require("SettingsKit-Namespaces")
        local db = SettingsKit:Open("MyAddonSettings", {
          profile = profileSchema,
          char = schema.char,
          global = schema.global,
        })
        local bars = db:RegisterNamespace("Bars", {
          profile = S.table({ fields = { size = S.optional(S.number(), 1) } }),
        })
        assert.are.equal(4, bars.profile.size)
        package.loaded["SettingsKit-Namespaces"] = nil
      end
    )

    it("renames namespace profiles and characters as the main sections are", function()
      local source = aceTable()
      source.namespaces = {
        Bars = {
          profiles = { Default = { size = 4 } },
          char = { ["Old - Realm"] = { shown = true }, ["Gone - Realm"] = { shown = false } },
        },
      }
      BridgeKit:ImportAceDB(source, "MyAddonSettings", {
        schema = schema,
        aceDefaults = {},
        renameProfile = function(name)
          return name == "Default" and "Main" or name
        end,
        renameCharacter = function(key)
          if key == "Gone - Realm" then
            return nil
          end
          return key == "Old - Realm" and "New - Realm" or key
        end,
      })
      local saved = Env.Global("MyAddonSettings").namespaces.Bars
      assert.are.same({ Main = { size = 4 } }, saved.profiles)
      assert.are.same({ ["New - Realm"] = { shown = true } }, saved.char)
    end)

    it("drops what cannot be stored and stops at the depth bound", function()
      local deep = {}
      local node = deep
      for _ = 1, 40 do
        node.next = {}
        node = node.next
      end
      local source = aceTable()
      source.namespaces = {
        Bars = { global = { fn = function() end }, realm = { deep = deep } },
        [1] = { global = {} },
      }
      local report =
        BridgeKit:ImportAceDB(source, "MyAddonSettings", { schema = schema, aceDefaults = {} })
      local saved = Env.Global("MyAddonSettings").namespaces.Bars
      assert.is_nil(saved.global)
      assert.is_nil(saved.realm)
      assert.is_true(hasEntry(report, "namespaces.Bars.global", "notStorable"))
      assert.is_true(hasEntry(report, "namespaces.Bars.realm", "tooDeep"))
    end)

    it("drops namespace entries that are not tables and sections of the wrong type", function()
      local source = aceTable()
      source.namespaces = {
        Bars = { profiles = { Default = 4 }, char = "wrong" },
      }
      local report =
        BridgeKit:ImportAceDB(source, "MyAddonSettings", { schema = schema, aceDefaults = {} })
      local saved = Env.Global("MyAddonSettings").namespaces.Bars
      assert.are.same({}, saved.profiles)
      assert.is_nil(saved.char)
      assert.is_true(hasEntry(report, "namespaces.Bars.profiles.Default", "notStorable"))
      assert.is_true(hasEntry(report, "namespaces.Bars.char", "notStorable"))
    end)

    it("copies the four scopes into sections of their own", function()
      local source = {
        race = { Human = { a = 1 } },
        factionrealm = { ["Alliance - Silvermoon"] = { b = 2 } },
        factionrealmregion = { ["Alliance - Silvermoon - EU"] = { c = 3 } },
        locale = { enus = { d = 4 } },
      }
      local report = BridgeKit:ImportAceDB(source, "MyAddonSettings", {
        schema = schema,
        aceDefaults = {},
        scopes = { race = { into = "global", field = "byRace" } },
      })
      local saved = Env.Global("MyAddonSettings")
      assert.are.same({ Human = { a = 1 } }, saved.race)
      assert.are.same({ ["Alliance - Silvermoon"] = { b = 2 } }, saved.factionrealm)
      assert.are.same({ ["Alliance - Silvermoon - EU"] = { c = 3 } }, saved.factionrealmregion)
      assert.are.same({ enus = { d = 4 } }, saved.locale)
      assert.is_true(hasEntry(report, "race", "nativeScope"))
      assert.is_false(hasEntry(report, "locale", "unsupportedScope"))
    end)
  end)

  describe("the three methods", function()
    it("preview writes nothing anywhere", function()
      local source = aceTable()
      local before = Env.Snapshot(source)
      local report = BridgeKit:PreviewAceDB(source, {
        schema = schema,
        aceDefaults = {},
        renameProfile = function(n)
          return n
        end,
      })
      assert.are.equal("aceDB", report.kind)
      assert.are.same(before, source)
      assert.is_nil(Env.Global("MyAddonSettings"))
    end)

    it(
      "import never writes the source, refuses a full target or backup, and writes the backup",
      function()
        Env.SavedVariable("MyAddonDB", aceTable())
        local before = Env.Snapshot(Env.Global("MyAddonDB"))
        Env.SavedVariable("Taken", { x = 1 })
        assert.are.same(
          { nil, "targetNotEmpty" },
          { BridgeKit:ImportAceDB("MyAddonDB", "Taken", { schema = schema }) }
        )
        Env.SavedVariable("MyAddonDB_Backup", { old = true })
        assert.are.same({ nil, "backupTaken" }, {
          BridgeKit:ImportAceDB(
            "MyAddonDB",
            "MyAddonSettings",
            { schema = schema, backup = "MyAddonDB_Backup" }
          ),
        })
        local report = BridgeKit:ImportAceDB("MyAddonDB", "MyAddonSettings", {
          schema = schema,
          aceDefaults = {},
          backup = "MyAddonDB_Backup",
          replaceBackup = true,
        })
        assert.is_table(report)
        assert.are.same(before, Env.Global("MyAddonDB"))
        local backup = Env.Global("MyAddonDB_Backup")
        assert.are.same(
          { BridgeKit.REVISION, "MyAddonDB", BridgeKit.ACE_BASELINE.commit },
          { backup.bridgeKit, backup.source, backup.commit }
        )
        assert.are.same(before, backup.data)
        assert.are_not.equal(Env.Global("MyAddonDB"), backup.data)
      end
    )

    it("fills an empty target table in place", function()
      local target = {}
      Env.SavedVariable("MyAddonSettings", target)
      BridgeKit:ImportAceDB(aceTable(), "MyAddonSettings", { schema = schema, aceDefaults = {} })
      assert.are.equal(target, Env.Global("MyAddonSettings"))
      assert.is_table(target.profiles)
    end)

    it(
      "migrates the same saved variable inside SettingsKit:Open and moves the old data to the backup",
      function()
        Env.SavedVariable("MyAddonDB", aceTable())
        local reported
        local db = SettingsKit:Open("MyAddonDB", schema, {
          version = 1,
          migrations = {
            [1] = BridgeKit:AceDBMigration({
              schema = schema,
              aceDefaults = {},
              backup = "MyAddonDB_Backup",
              onReport = function(report)
                reported = report
              end,
            }),
          },
        })
        assert.are.equal(1.5, db.profile.scale)
        assert.are.equal(60, db.char.level)
        assert.are.equal("aceDB", reported.kind)
        assert.are.same(aceTable(), Env.Global("MyAddonDB_Backup").data)
        assert.are.equal(1, Env.Global("MyAddonDB").version)
        assert.is_false(hasEntry(reported, "version", "unknownTopLevelKey"))
      end
    )

    it("leaves the saved table and the backup untouched when the migration fails", function()
      Env.SavedVariable("MyAddonDB", aceTable())
      local ok = pcall(SettingsKit.Open, SettingsKit, "MyAddonDB", schema, {
        version = 1,
        migrations = {
          [1] = BridgeKit:AceDBMigration({
            schema = schema,
            aceDefaults = {},
            backup = "MyAddonDB_Backup",
            onReport = function()
              error("addon bug")
            end,
          }),
        },
      })
      assert.is_false(ok)
      assert.are.same(aceTable(), Env.Global("MyAddonDB"))
      assert.is_nil(Env.Global("MyAddonDB_Backup"))

      Env.SavedVariable("MyAddonDB_Backup", { old = true })
      local failed, failure = pcall(SettingsKit.Open, SettingsKit, "MyAddonDB", schema, {
        version = 1,
        migrations = {
          [1] = BridgeKit:AceDBMigration({ schema = schema, backup = "MyAddonDB_Backup" }),
        },
      })
      assert.is_false(failed)
      assert.is_truthy(
        tostring(failure):find('backup global "MyAddonDB_Backup" already holds data', 1, true)
      )
    end)
  end)

  describe("plan errors", function()
    local function failureOf(fn)
      local ok, failure = pcall(fn)
      assert.is_false(ok)
      return tostring(failure)
    end

    it("refuse a plan the importer cannot follow, at the caller", function()
      local cases = {
        { {}, "plan.schema is required" },
        { { schema = schema, color = 1 }, "plan has no field named color" },
        {
          { schema = { party = schema.profile } },
          "plan.schema has a scope SettingsKit does not know: party",
        },
        {
          { schema = { profile = 5 } },
          "plan.schema.profile must be a SchemaKit table node or sealed schema",
        },
        { { schema = { profile = S.number() } }, "plan.schema.profile must be a SchemaKit.table" },
        { { schema = schema, renameProfile = 5 }, "plan.renameProfile must be a function" },
        {
          { schema = schema, scopes = { char = { into = "global", field = "byRace" } } },
          "plan.scopes names a scope",
        },
        {
          { schema = schema, scopes = { race = { into = "profile", field = "x" } } },
          'into = "global"',
        },
        {
          { schema = schema, scopes = { race = { into = "global", field = "version" } } },
          "is not a declared map field",
        },
        {
          { schema = schema, namespaces = { Bars = { field = "nothing" } } },
          "is not a declared record or map field",
        },
      }
      for _, case in ipairs(cases) do
        local failure = failureOf(function()
          BridgeKit:PreviewAceDB({}, case[1])
        end)
        assert.is_truthy(failure:find(case[2], 1, true), case[2] .. " in " .. failure)
      end
      assert.is_truthy(failureOf(function()
        BridgeKit:AceDBMigration({ schema = schema })
      end):find("plan.backup is required", 1, true))
      assert.is_truthy(failureOf(function()
        BridgeKit:PreviewAceDB("NoSuchGlobal", { schema = schema })
      end):find('source names the global "NoSuchGlobal"', 1, true))
      assert.is_truthy(failureOf(function()
        BridgeKit:ImportAceDB({}, "", { schema = schema })
      end):find("targetName must be the name of a global", 1, true))
    end)

    it("needs SchemaKit", function()
      local Plain = Env.NewPackage()
      local ok, failure = pcall(Plain.PreviewAceDB, Plain, {}, { schema = {} })
      assert.is_false(ok)
      assert.is_truthy(tostring(failure):find("requires SchemaKit API 1", 1, true))
    end)

    it("formats an import report with its own actions", function()
      local report = BridgeKit:PreviewAceDB(
        { profiles = { Default = { scale = 1.5 } } },
        { schema = schema, aceDefaults = {} }
      )
      local lines = BridgeKit:FormatReport(report)
      -- With no AceDB defaults, the seven fields SettingsKit defaults read
      -- differently from now on.
      assert.are.equal("1 imported, 7 changed", lines[#lines])
    end)
  end)

  describe("edges", function()
    it("renders keys that are no identifiers safely in report paths", function()
      local odd = 'a|b"c\\d\1'
      local report = BridgeKit:PreviewAceDB({
        global = { bars = { [true] = print, [odd] = print, [2.5] = print } },
      }, { schema = schema, aceDefaults = {} })
      assert.is_true(hasEntry(report, "global.bars[true]", "notStorable"))
      assert.is_true(hasEntry(report, 'global.bars["a||b\\"c\\\\d\\001"]', "notStorable"))
      assert.is_true(hasEntry(report, "global.bars[2.5]", "notStorable"))
    end)

    it("drops secret keys and values wherever they are", function()
      local secretKey, secretValue = {}, {}
      Env.MarkSecret(secretKey, secretValue)
      local report = BridgeKit:PreviewAceDB({
        profiles = {
          Default = { scale = secretValue, auras = { [secretKey] = {} }, [secretKey] = 1 },
        },
      }, { schema = schema, aceDefaults = {} })
      assert.is_true(hasEntry(report, "profiles.Default.scale", "secretValue"))
      assert.is_true(hasEntry(report, "profiles.Default.auras", "secretValue"))
      assert.is_true(hasEntry(report, "profiles.Default", "secretValue"))
    end)

    it("reports sections and entries that are not tables", function()
      local report = BridgeKit:PreviewAceDB({
        profiles = { Default = 5 },
        char = { [CHARACTER] = "x" },
        realm = 7,
      }, { schema = schema, aceDefaults = {} })
      assert.is_true(hasEntry(report, "profiles.Default", "notStorable"))
      assert.is_true(hasEntry(report, 'char["' .. CHARACTER .. '"]', "notStorable"))
      assert.is_true(hasEntry(report, "realm", "notStorable"))
      local noProfiles = BridgeKit:PreviewAceDB(
        { profiles = { Default = {} } },
        { schema = { global = schema.global } }
      )
      assert.is_true(hasEntry(noProfiles, "profiles", "undeclaredScope"))
    end)

    it("blanks and renames through the plan", function()
      local report = BridgeKit:PreviewAceDB(
        { profiles = { A = {} }, char = { [CHARACTER] = {} } },
        {
          schema = schema,
          aceDefaults = {},
          renameProfile = function()
            return "   "
          end,
          renameCharacter = function()
            return "Other - Realm"
          end,
        }
      )
      assert.is_true(hasEntry(report, "profiles.A", "profileNameBlank"))
      assert.is_true(hasEntry(report, 'char["' .. CHARACTER .. '"]', "renamedCharacter"))
    end)

    it("reports name and ruleset keys on a ruleset client", function()
      -- selene: allow(global_usage)
      rawset(_G, "GetBuildInfo", function()
        return "1.60.1", "70790", "Nov 3 2026", 16001
      end)
      local report = BridgeKit:PreviewAceDB(aceTable(), { schema = schema, aceDefaults = {} })
      assert.is_true(hasEntry(report, "char", "characterKeyMismatch"))
      assert.is_true(hasEntry(report, "realm", "realmKeyMismatch"))
    end)

    it("uses a record's own default and a map's default entries as SettingsKit's", function()
      local withDefaults = {
        profile = S.table({
          fields = {
            frame = S.optional(S.table({ fields = { x = S.optional(S.number()) } }), { x = 3 }),
            slots = S.optional(
              S.map({ keys = S.string(), values = S.optional(S.number(), 0), max = 4 }),
              { main = 2 }
            ),
          },
        }),
      }
      local report = BridgeKit:PreviewAceDB({ profiles = { Default = {} } }, {
        schema = withDefaults,
        aceDefaults = { profile = { frame = { x = 3 }, slots = { main = 2, off = 1 } } },
      })
      assert.are.same({}, notedAt(report, "profiles.Default.frame.x"))
      assert.are.same({}, notedAt(report, "profiles.Default.slots.main"))
      assert.are.same(
        { "materialised (defaultDiffers)" },
        notedAt(report, "profiles.Default.slots.off")
      )
    end)

    it("compares table defaults deeply", function()
      local arrays = {
        profile = S.table({
          fields = { list = S.optional(S.array({ of = S.number() }), { 1, 2 }) },
        }),
      }
      local same = BridgeKit:PreviewAceDB({ profiles = { Default = {} } }, {
        schema = arrays,
        aceDefaults = { profile = { list = { 1, 2 } } },
      })
      assert.are.equal(0, same.counts.materialised)
      local longer = BridgeKit:PreviewAceDB({ profiles = { Default = {} } }, {
        schema = arrays,
        aceDefaults = { profile = { list = { 1, 2, 3 } } },
      })
      assert.are.equal(1, longer.counts.materialised)
      local shorter = BridgeKit:PreviewAceDB({ profiles = { Default = {} } }, {
        schema = arrays,
        aceDefaults = { profile = { list = { 1 } } },
      })
      assert.are.equal(1, shorter.counts.materialised)
    end)

    it("merges a namespace into a global map that a mapped scope also fills", function()
      -- The plan's mappings, as a SettingsKit before revision 15 takes them.
      rawset(SettingsKit, "REVISION", 14)
      local plan = {
        schema = schema,
        aceDefaults = {},
        scopes = { race = { into = "global", field = "byRace" } },
        namespaces = { Races = { field = "byRace" } },
      }
      BridgeKit:ImportAceDB({
        race = { Human = { a = 1 } },
        namespaces = { Races = { global = { Orc = { b = 2 } }, realm = { Silvermoon = {} } } },
      }, "MyAddonSettings", plan)
      assert.are.same(
        { Human = { a = 1 }, Orc = { b = 2 } },
        Env.Global("MyAddonSettings").global.byRace
      )
      local report = BridgeKit:PreviewAceDB({
        namespaces = { Races = { realm = { Silvermoon = { x = 1 } } } },
      }, plan)
      assert.is_true(hasEntry(report, "namespaces.Races.realm", "undeclaredScope"))
    end)

    it(
      "keeps a table the backup reaches twice shared, and refuses a backup past the limit",
      function()
        local shared = { 1 }
        local source = { profiles = { A = { tags = shared }, B = { tags = shared } } }
        BridgeKit:ImportAceDB(
          source,
          "MyAddonSettings",
          { schema = schema, aceDefaults = {}, backup = "MyAddonDB_Backup" }
        )
        local data = Env.Global("MyAddonDB_Backup").data
        assert.are.equal(data.profiles.A.tags, data.profiles.B.tags)

        Env.SavedVariable("MyAddonSettings", nil)
        Env.SavedVariable("MyAddonDB_Backup", nil)
        local big = { global = { version = 1 }, mystery = {} }
        for index = 1, 50 do
          big.mystery[index] = index
        end
        BridgeKit:SetLimits({ maxImportEntries = 20 })
        local imported, reason = BridgeKit:ImportAceDB(big, "MyAddonSettings", {
          schema = schema,
          aceDefaults = {},
          backup = "MyAddonDB_Backup",
        })
        assert.is_nil(imported)
        assert.are.equal("maxImportEntries", reason)
        assert.is_nil(Env.Global("MyAddonDB_Backup"))
      end
    )

    it("fails a migration past maxImportEntries without touching the saved table", function()
      Env.SavedVariable("MyAddonDB", aceTable())
      BridgeKit:SetLimits({ maxImportEntries = 3 })
      local ok, failure = pcall(SettingsKit.Open, SettingsKit, "MyAddonDB", schema, {
        version = 1,
        migrations = {
          [1] = BridgeKit:AceDBMigration({ schema = schema, backup = "MyAddonDB_Backup" }),
        },
      })
      assert.is_false(ok)
      assert.is_truthy(tostring(failure):find("more than maxImportEntries", 1, true))
      assert.are.same(aceTable(), Env.Global("MyAddonDB"))
    end)

    it("refuses every malformed plan field and source", function()
      local secret = {}
      Env.MarkSecret(secret)
      local cases = {
        { "x", "plan must be a table" },
        { { schema = schema, aceDefaults = secret }, "plan must not hold a secret key or value" },
        { { schema = schema, aceDefaults = 5 }, "plan.aceDefaults must be a table" },
        { { schema = schema, namespaces = { Bars = 5 } }, "plan.namespaces entries must be" },
        {
          { schema = schema, namespaces = { Bars = { field = "bars", defaults = 5 } } },
          ".defaults must be a table",
        },
        { { schema = schema, version = 0 }, "plan has no field named version" },
      }
      for _, case in ipairs(cases) do
        local ok, failure = pcall(BridgeKit.PreviewAceDB, BridgeKit, {}, case[1])
        assert.is_false(ok)
        assert.is_truthy(
          tostring(failure):find(case[2], 1, true),
          case[2] .. " in " .. tostring(failure)
        )
      end
      local importCases = {
        { { schema = schema, version = 0 }, "plan.version must be a positive integer" },
        { { schema = schema, backup = "" }, "plan.backup must be the name of a global" },
        { { schema = schema, replaceBackup = "yes" }, "plan.replaceBackup must be a boolean" },
      }
      for _, case in ipairs(importCases) do
        local ok, failure = pcall(BridgeKit.ImportAceDB, BridgeKit, {}, "MyAddonSettings", case[1])
        assert.is_false(ok)
        assert.is_truthy(tostring(failure):find(case[2], 1, true), case[2])
      end
      local ok, failure = pcall(BridgeKit.PreviewAceDB, BridgeKit, secret, { schema = schema })
      assert.is_false(ok)
      assert.is_truthy(tostring(failure):find("source must not be a secret value", 1, true))
      ok, failure = pcall(BridgeKit.PreviewAceDB, BridgeKit, 5, { schema = schema })
      assert.is_false(ok)
      assert.is_truthy(
        tostring(failure):find("source must be a table or the name of a global", 1, true)
      )
    end)

    it("lets an error a rename function raises propagate unchanged", function()
      local ok, failure = pcall(BridgeKit.PreviewAceDB, BridgeKit, { profiles = { A = {} } }, {
        schema = schema,
        renameProfile = function()
          error("addon bug")
        end,
      })
      assert.is_false(ok)
      assert.is_truthy(tostring(failure):find("addon bug", 1, true))
    end)
  end)

  describe("defaults, collisions and merges", function()
    it("merge an AceDB default into an open record, keys it lacks included", function()
      BridgeKit:ImportAceDB({ global = { bars = { a = 1 } } }, "MyAddonSettings", {
        schema = schema,
        aceDefaults = { global = { bars = { b = 2 } } },
      })
      assert.are.same({ a = 1, b = 2 }, Env.Global("MyAddonSettings").global.bars)
    end)

    it("report an AceDB default a closed record cannot hold", function()
      local report = BridgeKit:PreviewAceDB({ profiles = { Default = {} } }, {
        schema = schema,
        aceDefaults = { profile = { unknown = 5 } },
      })
      assert.is_true(hasEntry(report, "profile.unknown", "defaultDiffers"))
    end)

    it("merge `**` into an explicit default at every depth", function()
      BridgeKit:ImportAceDB({ global = {} }, "MyAddonSettings", {
        schema = schema,
        aceDefaults = { global = { ["**"] = { x = { y = 1 } }, bars = { x = { z = 2 } } } },
      })
      assert.are.same({ x = { y = 1, z = 2 } }, Env.Global("MyAddonSettings").global.bars)
    end)

    it("read a map's own default entries against AceDB's wildcard", function()
      local mapSchema = {
        global = S.table({
          fields = {
            counts = S.optional(
              S.map({ keys = S.string(), values = S.number(), max = 2 }),
              { a = 1 }
            ),
          },
        }),
      }
      BridgeKit:ImportAceDB({ global = { counts = {} } }, "MyAddonSettings", {
        schema = mapSchema,
        aceDefaults = { global = { counts = { ["*"] = 5 } } },
      })
      assert.are.same({ a = 5 }, Env.Global("MyAddonSettings").global.counts)
    end)

    it("report explicit AceDB defaults a full map cannot take", function()
      local report = BridgeKit:PreviewAceDB(
        { profiles = { Default = { auras = { [1] = {}, [2] = {}, [3] = {} } } } },
        { schema = schema, aceDefaults = { profile = { auras = { [4] = { shown = false } } } } }
      )
      assert.is_true(hasEntry(report, "profiles.Default.auras", "mapFull"))
    end)

    it("keep a map entry that holds nothing but defaults", function()
      BridgeKit:ImportAceDB(
        { profiles = { Default = { auras = { [7] = {} } } } },
        "MyAddonSettings",
        { schema = schema, aceDefaults = {} }
      )
      assert.are.same({ [7] = {} }, Env.Global("MyAddonSettings").profiles.Default.auras)
    end)

    it("report a SettingsKit default AceDB lacked, once per field", function()
      local report = BridgeKit:PreviewAceDB(
        { profiles = { Default = {}, Raid = {} } },
        { schema = schema, aceDefaults = {} }
      )
      assert.are.same({ "changed (defaultDiffers)" }, notedAt(report, "profile.scale"))
    end)

    it("keep the entry that keeps its name when renames collide", function()
      local report = BridgeKit:ImportAceDB(
        {
          profiles = { A = { scale = 2 }, Default = { scale = 1.5 } },
          char = { ["Old - Silvermoon"] = { level = 5 }, [CHARACTER] = { level = 60 } },
        },
        "MyAddonSettings",
        {
          schema = schema,
          aceDefaults = {},
          renameProfile = function(name)
            return name == "A" and "Default" or name
          end,
          renameCharacter = function(key)
            return key == "Old - Silvermoon" and CHARACTER or key
          end,
        }
      )
      local target = Env.Global("MyAddonSettings")
      assert.are.same({ Default = { scale = 1.5 } }, target.profiles)
      assert.are.same({ [CHARACTER] = { level = 60 } }, target.char)
      assert.is_true(hasEntry(report, "profiles.A", "keyCollision"))
      assert.is_true(hasEntry(report, 'char["Old - Silvermoon"]', "keyCollision"))
    end)

    it("drop secret keys and profile choices without raising", function()
      Env.MarkSecret("hidden")
      local report = BridgeKit:ImportAceDB({
        profileKeys = { [CHARACTER] = "hidden" },
        profiles = { Default = {} },
        global = { bars = { hidden = 1, shown = 2 } },
      }, "MyAddonSettings", { schema = schema, aceDefaults = {} })
      local target = Env.Global("MyAddonSettings")
      assert.are.same({ shown = 2 }, target.global.bars)
      assert.are.same({}, target.profileKeys)
      assert.is_true(hasEntry(report, "global.bars", "secretValue"))
      assert.is_true(hasEntry(report, 'profileKeys["' .. CHARACTER .. '"]', "secretValue"))
    end)

    it("raise a schema refusal at the caller", function()
      local ok, failure = pcall(function()
        BridgeKit:PreviewAceDB({}, { schema = { party = schema.profile } })
      end)
      assert.is_false(ok)
      assert.is_truthy(tostring(failure):find("AceDB_spec.lua:", 1, true), tostring(failure))
    end)

    it("start each migration step from a clean walk", function()
      local reports = {}
      local step = BridgeKit:AceDBMigration({
        schema = schema,
        aceDefaults = {},
        backup = "MyAddonDB_Backup",
        replaceBackup = true,
        onReport = function(report)
          reports[#reports + 1] = report
        end,
      })
      step({ profiles = { Default = {} } })
      step({ profiles = { Default = {} } })
      assert.are.same(reports[1].counts, reports[2].counts)
      assert.is_true(hasEntry(reports[2], "profile.scale", "defaultDiffers"))
    end)

    it("keep what a section holds when a namespace lands on it, up to the map's max", function()
      -- The plan's mappings, as a SettingsKit before revision 15 takes them.
      rawset(SettingsKit, "REVISION", 14)
      local mergeSchema = {
        profile = S.table({
          fields = { bars = S.optional(S.table({ fields = {}, open = true })) },
        }),
        global = S.table({
          fields = {
            seen = S.optional(S.map({ keys = S.string(), values = S.number(), max = 1 })),
          },
        }),
      }
      local report = BridgeKit:ImportAceDB(
        {
          profiles = { Default = { bars = { count = 1 } } },
          race = { a = 1 },
          namespaces = {
            Bars = { profiles = { Default = { count = 4 } } },
            Seen = { global = { b = 2 } },
          },
        },
        "MyAddonSettings",
        {
          schema = mergeSchema,
          aceDefaults = {},
          scopes = { race = { into = "global", field = "seen" } },
          namespaces = { Bars = { field = "bars" }, Seen = { field = "seen" } },
        }
      )
      local target = Env.Global("MyAddonSettings")
      assert.are.same({ count = 1 }, target.profiles.Default.bars)
      assert.are.same({ a = 1 }, target.global.seen)
      assert.is_true(hasEntry(report, "profiles.Default.bars.count", "keyCollision"))
      assert.is_true(hasEntry(report, "global.seen", "mapFull"))
    end)

    it("apply AceDB's wildcards to entries a saved table already holds", function()
      BridgeKit:ImportAceDB(
        {
          global = {
            bars = { group = { one = {} }, deep = { two = { inner = {} } }, opts = { a = 1 } },
          },
        },
        "MyAddonSettings",
        {
          schema = schema,
          aceDefaults = {
            global = {
              bars = {
                group = { ["*"] = { on = true } },
                deep = { ["**"] = { on = true } },
                opts = { b = 2 },
              },
            },
          },
        }
      )
      assert.are.same({
        group = { one = { on = true } },
        -- `**` reaches the entries at its own level, not what they nest.
        deep = { two = { on = true, inner = {} } },
        opts = { a = 1, b = 2 },
      }, Env.Global("MyAddonSettings").global.bars)
    end)

    it("sort boolean keys and back up tables used as keys", function()
      local tableKey = {}
      local report = BridgeKit:ImportAceDB(
        { global = { bars = { [true] = print, [false] = print, [tableKey] = 1 } } },
        "MyAddonSettings",
        { schema = schema, aceDefaults = {}, backup = "MyAddonDB_Backup" }
      )
      assert.is_true(hasEntry(report, "global.bars[false]", "notStorable"))
      assert.is_true(hasEntry(report, "global.bars[true]", "notStorable"))
      local copiedKey = next(Env.Global("MyAddonDB_Backup").data.global.bars, nil)
      while type(copiedKey) ~= "table" do
        copiedKey = next(Env.Global("MyAddonDB_Backup").data.global.bars, copiedKey)
      end
      assert.are_not.equal(tableKey, copiedKey)
    end)
  end)
end)
