local TestEnv = require("SettingsKitTestEnv")

describe("SettingsKit defaults", function()
  local SettingsKit, S
  before_each(function()
    local _
    SettingsKit, _, _, _, S = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  local function openProfile(fields)
    return SettingsKit:Open("MyAddonDB", { profile = S.table({ fields = fields }) })
  end

  it("reads scalar defaults without writing them back", function()
    local db = openProfile({
      scale = S.optional(S.number({ min = 0.5, max = 2 }), 1),
      anchor = S.optional(S.string(), "CENTER"),
      label = S.optional(S.string()),
    })

    assert.are.equal(1, db.profile.scale)
    assert.are.equal("CENTER", db.profile.anchor)
    assert.is_nil(db.profile.label)
    assert.are.same({}, TestEnv.GetGlobal("MyAddonDB").profiles.Default)
  end)

  it("reads nested record defaults through child views without writing them back", function()
    local db = openProfile({
      frame = S.optional(
        S.table({
          fields = {
            x = S.optional(S.number(), 10),
            y = S.optional(S.number(), 20),
            size = S.optional(S.table({ fields = { width = S.optional(S.number(), 100) } }), {}),
          },
        }),
        {}
      ),
    })

    assert.are.equal(10, db.profile.frame.x)
    assert.are.equal(20, db.profile.frame.y)
    assert.are.equal(100, db.profile.frame.size.width)
    assert.are.equal(db.profile.frame, db.profile.frame)
    assert.are.same({}, TestEnv.GetGlobal("MyAddonDB").profiles.Default)

    db.profile.frame.x = 5
    assert.are.equal(5, db.profile.frame.x)
    assert.are.equal(20, db.profile.frame.y)
    assert.are.same({ frame = { x = 5 } }, TestEnv.GetGlobal("MyAddonDB").profiles.Default)
  end)

  it("fills defaults declared inside a table default", function()
    local db = openProfile({
      frame = S.optional(
        S.table({
          fields = { x = S.optional(S.number(), 1), y = S.optional(S.number(), 2) },
        }),
        {
          x = 7,
        }
      ),
    })

    assert.are.equal(7, db.profile.frame.x)
    assert.are.equal(2, db.profile.frame.y)
  end)

  it("uses a record's own field defaults when the record has no default but is saved", function()
    TestEnv.SavedVariable("MyAddonDB", { profiles = { Default = { frame = {} } } })
    local db = openProfile({
      frame = S.optional(S.table({ fields = { x = S.optional(S.number(), 3) } })),
    })

    assert.are.equal(3, db.profile.frame.x)
  end)

  it("reads nil for a record without a default that was never saved", function()
    local db = openProfile({
      frame = S.optional(S.table({ fields = { x = S.optional(S.number(), 3) } })),
    })

    assert.is_nil(db.profile.frame)
  end)

  it("serves wildcard defaults for keys of a keyed section without writing them", function()
    local Aura = S.table({
      fields = {
        shown = S.optional(S.boolean(), true),
        color = S.optional(
          S.array({ of = S.number({ min = 0, max = 1 }), min = 3, max = 4 }),
          { 1, 1, 1 }
        ),
      },
    })
    local db = openProfile({
      auras = S.optional(
        S.map({
          keys = S.number({ integer = true }),
          values = S.optional(Aura, {}),
          max = 8,
        }),
        {}
      ),
    })

    assert.is_true(db.profile.auras[12345].shown)
    assert.is_true(db.profile.auras[777].shown)
    assert.are.equal(db.profile.auras[12345], db.profile.auras[12345])
    assert.are.same({}, TestEnv.GetGlobal("MyAddonDB").profiles.Default)

    db.profile.auras[12345].shown = false
    assert.is_false(db.profile.auras[12345].shown)
    assert.is_true(db.profile.auras[777].shown)
    assert.are.same(
      { auras = { [12345] = { shown = false } } },
      TestEnv.GetGlobal("MyAddonDB").profiles.Default
    )
  end)

  it("reads nil for a nil key of a keyed section, after asking the secret probe", function()
    local db = openProfile({
      flags = S.optional(
        S.map({ keys = S.string(), values = S.optional(S.boolean(), true), max = 8 }),
        {}
      ),
    })
    -- The key is compared and used as a key after the nil test, both of
    -- which raise on a secret in the client, so the probe asks first.
    local asked = 0
    TestEnv.SetGlobal("issecretvalue", function()
      asked = asked + 1
      return false
    end)
    local flags = db.profile.flags
    asked = 0
    assert.is_nil(flags[nil])
    assert.are.equal(1, asked)
    assert.is_true(flags.anything)
  end)

  it("serves scalar wildcard defaults", function()
    local db = openProfile({
      counts = S.optional(
        S.map({
          keys = S.string(),
          values = S.optional(S.number({ integer = true }), 0),
          max = 8,
        }),
        {}
      ),
    })

    assert.are.equal(0, db.profile.counts.anything)
    db.profile.counts.fireball = 3
    assert.are.equal(3, db.profile.counts.fireball)
    assert.are.same({ counts = { fireball = 3 } }, TestEnv.GetGlobal("MyAddonDB").profiles.Default)
  end)

  it("prefers a keyed section's own default entries over its wildcard", function()
    local db = openProfile({
      counts = S.optional(
        S.map({ keys = S.string(), values = S.optional(S.number(), 0), max = 8 }),
        { preset = 5 }
      ),
    })

    assert.are.equal(5, db.profile.counts.preset)
    assert.are.equal(0, db.profile.counts.other)
  end)

  it("reads nil for a missing key of a keyed section without a wildcard", function()
    local db = openProfile({
      names = S.optional(S.map({ keys = S.string(), values = S.string(), max = 8 }), {}),
    })

    assert.is_nil(db.profile.names.missing)
  end)

  it(
    "stores a copy of an array default on first read, so editing it cannot change the default",
    function()
      local db = openProfile({
        color = S.optional(S.array({ of = S.number(), max = 4 }), { 1, 1, 1 }),
      })

      local color = db.profile.color
      assert.are.same({ 1, 1, 1 }, color)
      color[1] = 0
      assert.are.same({ 0, 1, 1 }, TestEnv.GetGlobal("MyAddonDB").profiles.Default.color)

      db.profile.color = nil
      assert.are.same({ 1, 1, 1 }, db.profile.color)
    end
  )

  it("reads undeclared fields as stored, and writes them only to an open record", function()
    TestEnv.SavedVariable("MyAddonDB", { profiles = { Default = { extra = "kept" } } })
    local db = openProfile({})
    assert.are.equal("kept", db.profile.extra)
    assert.has_error(function()
      db.profile.extra = "changed"
    end)

    local open = SettingsKit:Open("OtherDB", {
      profile = S.table({ fields = {}, open = true }),
    })
    open.profile.anything = 1
    assert.are.equal(1, open.profile.anything)
    assert.are.equal(1, TestEnv.GetGlobal("OtherDB").profiles.Default.anything)
  end)

  -- A keyed section declared without a default of its own: its saved
  -- entries still read the wildcard default and their record field defaults.
  local function auraSection()
    return S.optional(S.map({
      keys = S.number({ integer = true }),
      max = 8,
      values = S.optional(
        S.table({
          fields = {
            shown = S.optional(S.boolean(), true),
            sound = S.optional(S.string()),
            glow = S.optional(S.table({ fields = { alpha = S.optional(S.number(), 0.5) } })),
          },
        }),
        { shown = true }
      ),
    }))
  end

  it("reads the wildcard default through a saved entry of a section without a default", function()
    TestEnv.SavedVariable("MyAddonDB", {
      profiles = { Default = { auras = { [5] = { sound = "ping", glow = {} } } } },
    })
    local db = openProfile({ auras = auraSection() })

    local entry = db.profile.auras[5]
    assert.are.equal(true, entry.shown)
    assert.are.equal("ping", entry.sound)
    assert.are.equal(0.5, entry.glow.alpha)

    local seen = {}
    for key, value in db:Pairs(entry) do
      seen[key] = value
    end
    assert.are.equal(true, seen.shown)
    assert.are.equal("ping", seen.sound)
  end)

  it("reads a saved entry the same way before and after Compact removes its defaults", function()
    TestEnv.SavedVariable("MyAddonDB", {
      profiles = { Default = { auras = { [5] = { shown = true, sound = "ping" } } } },
    })
    local db = openProfile({ auras = auraSection() })

    assert.are.equal(1, db:Compact())
    assert.are.same(
      { auras = { [5] = { sound = "ping" } } },
      TestEnv.GetGlobal("MyAddonDB").profiles.Default
    )
    assert.are.equal(true, db.profile.auras[5].shown)
  end)

  it("shows nothing to pairs, because a view is an empty proxy", function()
    local db = openProfile({ scale = S.optional(S.number(), 1) })
    db.profile.scale = 2
    assert.is_nil(next(db.profile))
    assert.are.equal("SettingsKit.View", getmetatable(db.profile))
  end)
end)
