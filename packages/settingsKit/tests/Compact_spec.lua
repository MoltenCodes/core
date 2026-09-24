local TestEnv = require("SettingsKitTestEnv")

local function schemaFor(S)
  local Aura = S.table({
    fields = { shown = S.optional(S.boolean(), true), note = S.optional(S.string()) },
  })
  return {
    global = S.table({ fields = { seen = S.optional(S.number(), 0) } }),
    char = S.table({ fields = { gold = S.optional(S.number(), 0) } }),
    profile = S.table({
      fields = {
        scale = S.optional(S.number(), 1),
        color = S.optional(S.array({ of = S.number(), max = 4 }), { 1, 1, 1 }),
        frame = S.optional(S.table({ fields = { x = S.optional(S.number(), 0) } }), {}),
        extra = S.optional(S.table({ fields = { y = S.optional(S.number(), 0) } })),
        auras = S.optional(
          S.map({ keys = S.number(), values = S.optional(Aura, {}), max = 8 }),
          {}
        ),
      },
    }),
  }
end

describe("SettingsKit Compact", function()
  local SettingsKit, S
  before_each(function()
    local _
    SettingsKit, _, _, _, S = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("removes values equal to their defaults, deeply, and keeps the rest", function()
    local db = SettingsKit:Open("MyAddonDB", schemaFor(S))
    db.global.seen = 0
    db.char.gold = 0
    db.profile.scale = 1
    local _ = db.profile.color -- materialised by the read
    db.profile.frame.x = 0
    db.profile.extra = { y = 0 }
    db.profile.auras[1].shown = true
    db.profile.auras[2].shown = false
    db:SetProfile("Other")
    db.profile.scale = 2

    local removed = db:Compact()
    local raw = TestEnv.GetGlobal("MyAddonDB")
    assert.are.same({}, raw.global)
    assert.are.same({}, raw.char)
    assert.are.same({
      extra = {},
      auras = { [2] = { shown = false } },
    }, raw.profiles.Default)
    assert.are.same({ scale = 2 }, raw.profiles.Other)
    assert.are.equal(9, removed)

    db:SetProfile("Default")
    assert.are.equal(0, db.profile.extra.y)
    assert.is_true(db.profile.auras[1].shown)
    assert.is_false(db.profile.auras[2].shown)
  end)

  it("compacts every stored character, not only the current one", function()
    TestEnv.SavedVariable(
      "MyAddonDB",
      { char = { ["Alt - Realm"] = { gold = 0 }, ["Main - Realm"] = { gold = 5 } } }
    )
    local db = SettingsKit:Open("MyAddonDB", schemaFor(S))
    db:Compact()
    assert.are.same({ ["Main - Realm"] = { gold = 5 } }, TestEnv.GetGlobal("MyAddonDB").char)
  end)

  it("keeps an empty profile", function()
    local db = SettingsKit:Open("MyAddonDB", schemaFor(S))
    db:SetProfile("Empty")
    db:Compact()
    assert.are.same({}, TestEnv.GetGlobal("MyAddonDB").profiles.Empty)
  end)

  it("compacts on PLAYER_LOGOUT when EventKit is embedded", function()
    local db = SettingsKit:Open("MyAddonDB", schemaFor(S))
    db.profile.scale = 1
    db.profile.frame.x = 3

    TestEnv.Logout()
    assert.are.same({ frame = { x = 3 } }, TestEnv.GetGlobal("MyAddonDB").profiles.Default)
  end)

  it("reports a failing logout compaction instead of raising it into the dispatch", function()
    local db = SettingsKit:Open("MyAddonDB", schemaFor(S))
    db.profile.scale = 1
    TestEnv.TakeReportedErrors()

    -- A host probe that raises makes the comparison inside Compact fail.
    TestEnv.SetGlobal("issecretvalue", function()
      error("probe failed", 0)
    end)
    TestEnv.Logout()

    local reported = TestEnv.TakeReportedErrors()
    assert.are.equal(1, #reported)
    assert.are.equal("probe failed", reported[1].value)
  end)
end)

describe("SettingsKit without EventKit", function()
  after_each(TestEnv.Reset)

  it("opens, reads and writes, and leaves compaction to the addon", function()
    local SettingsKit, _, S = TestEnv.NewPackageWithoutEventKit()
    local db = SettingsKit:Open("MyAddonDB", schemaFor(S))
    db.profile.scale = 1
    assert.are.equal(1, db.profile.scale)

    TestEnv.Logout()
    assert.are.same({ scale = 1 }, TestEnv.GetGlobal("MyAddonDB").profiles.Default)
    assert.are.equal(1, db:Compact())
    assert.are.same({}, TestEnv.GetGlobal("MyAddonDB").profiles.Default)
  end)
end)
