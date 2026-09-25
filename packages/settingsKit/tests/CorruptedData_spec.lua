local TestEnv = require("SettingsKitTestEnv")

-- A saved variable is a file the player can edit and older or broken code may
-- have written. These specs store a scalar where the schema declares a record
-- or a keyed section, and check that the views stay usable.

describe("SettingsKit corrupted saved data", function()
  local SettingsKit, S
  before_each(function()
    local _
    SettingsKit, _, _, _, S = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  local function schema()
    local Aura = S.table({
      fields = {
        shown = S.optional(S.boolean(), true),
        color = S.optional(S.array({ of = S.number(), max = 4 }), { 1, 1, 1 }),
      },
    })
    return {
      profile = S.table({
        fields = {
          frame = S.optional(S.table({ fields = { x = S.optional(S.number(), 0) } }), {}),
          extra = S.optional(S.table({ fields = { y = S.optional(S.number(), 7) } })),
          auras = S.optional(
            S.map({ keys = S.number(), values = S.optional(Aura, {}), max = 8 }),
            {}
          ),
          groups = S.optional(
            S.map({ keys = S.string(), values = S.optional(S.number()), max = 8 })
          ),
        },
      }),
    }
  end

  it("reads a record stored as a scalar as its default view", function()
    TestEnv.SavedVariable("MyAddonDB", { profiles = { Default = { frame = 5, extra = "x" } } })
    local db = SettingsKit:Open("MyAddonDB", schema())

    assert.are.equal("SettingsKit.View", getmetatable(db.profile.frame))
    assert.are.equal(0, db.profile.frame.x)
    -- A record without a default reads as absent.
    assert.is_nil(db.profile.extra)
    assert.are.equal(5, TestEnv.GetGlobal("MyAddonDB").profiles.Default.frame)
  end)

  it("replaces the scalar on the next write through the view", function()
    TestEnv.SavedVariable("MyAddonDB", { profiles = { Default = { frame = 5 } } })
    local db = SettingsKit:Open("MyAddonDB", schema())
    local changes = {}
    db:OnChange("profile", function(_, _, key, value, path)
      changes[#changes + 1] = { key, value, path }
    end)

    db.profile.frame.x = 12
    assert.are.same({ x = 12 }, TestEnv.GetGlobal("MyAddonDB").profiles.Default.frame)
    assert.are.equal(12, db.profile.frame.x)
    assert.are.same({ { "x", 12, "frame" } }, changes)
  end)

  it("reads a keyed-section entry stored as a scalar as the wildcard default", function()
    TestEnv.SavedVariable("MyAddonDB", {
      profiles = { Default = { auras = { [118] = "broken", [7] = { shown = false } } } },
    })
    local db = SettingsKit:Open("MyAddonDB", schema())

    assert.is_true(db.profile.auras[118].shown)
    assert.is_false(db.profile.auras[7].shown)
    -- A plain-table default read inside the broken entry is not stored over it.
    assert.are.same({ 1, 1, 1 }, db.profile.auras[118].color)
    assert.are.equal("broken", TestEnv.GetGlobal("MyAddonDB").profiles.Default.auras[118])

    db.profile.auras[118].shown = false
    assert.are.same({ shown = false }, TestEnv.GetGlobal("MyAddonDB").profiles.Default.auras[118])
  end)

  it("reads a keyed section stored as a scalar as its default and iterates it", function()
    TestEnv.SavedVariable("MyAddonDB", { profiles = { Default = { auras = true } } })
    local db = SettingsKit:Open("MyAddonDB", schema())
    assert.is_true(db.profile.auras[3].shown)
    local keys = 0
    for _ in db:Pairs(db.profile.auras) do
      keys = keys + 1
    end
    assert.are.equal(0, keys)
    db.profile.auras[3] = { shown = false }
    assert.are.same(
      { [3] = { shown = false } },
      TestEnv.GetGlobal("MyAddonDB").profiles.Default.auras
    )
  end)

  it("keeps a scalar keyed-section value that the schema declares as a scalar", function()
    TestEnv.SavedVariable("MyAddonDB", { profiles = { Default = { groups = { tanks = 2 } } } })
    local db = SettingsKit:Open("MyAddonDB", schema())
    assert.are.equal(2, db.profile.groups.tanks)
  end)
end)
