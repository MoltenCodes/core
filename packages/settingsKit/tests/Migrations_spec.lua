local TestEnv = require("SettingsKitTestEnv")

describe("SettingsKit migrations", function()
  local SettingsKit, S
  before_each(function()
    local _
    SettingsKit, _, _, _, S = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  local function schema()
    return { profile = S.table({ fields = { scale = S.optional(S.number(), 1) } }) }
  end

  it("stamps a new saved table with the version and runs nothing", function()
    local runs = 0
    SettingsKit:Open("MyAddonDB", schema(), {
      version = 3,
      migrations = {
        [1] = function()
          runs = runs + 1
        end,
      },
    })
    assert.are.equal(0, runs)
    assert.are.equal(3, TestEnv.GetGlobal("MyAddonDB").version)
  end)

  it("migrates an older table once, in ascending order, and not again on the next open", function()
    local order = {}
    local migrations = {
      [3] = function(raw)
        order[#order + 1] = 3
        raw.profiles.Default.scale = raw.profiles.Default.scale * 2
      end,
      [2] = function(raw)
        order[#order + 1] = 2
        raw.profiles = { Default = { scale = raw.legacyScale } }
        raw.legacyScale = nil
      end,
    }
    TestEnv.SavedVariable("MyAddonDB", { version = 1, legacyScale = 0.75 })

    local db = SettingsKit:Open("MyAddonDB", schema(), { version = 3, migrations = migrations })
    assert.are.same({ 2, 3 }, order)
    assert.are.equal(1.5, db.profile.scale)
    local raw = TestEnv.GetGlobal("MyAddonDB")
    assert.are.equal(3, raw.version)

    -- The next session loads the same saved table.
    local reloaded = { TestEnv.NewPackage() }
    SettingsKit, S = reloaded[1], reloaded[5]
    TestEnv.SavedVariable("MyAddonDB", raw)
    local reopened =
      SettingsKit:Open("MyAddonDB", schema(), { version = 3, migrations = migrations })
    assert.are.same({ 2, 3 }, order)
    assert.are.equal(1.5, reopened.profile.scale)
  end)

  it("treats a non-empty table without a version as version 0", function()
    local ran = {}
    TestEnv.SavedVariable("MyAddonDB", { someOldField = true })
    SettingsKit:Open("MyAddonDB", schema(), {
      version = 1,
      migrations = {
        [1] = function(raw)
          ran[#ran + 1] = raw.someOldField
          raw.someOldField = nil
        end,
      },
    })
    assert.are.same({ true }, ran)
    assert.are.equal(1, TestEnv.GetGlobal("MyAddonDB").version)
  end)

  it("stops at a failing step, keeps the steps before it, and retries it next time", function()
    TestEnv.SavedVariable("MyAddonDB", { version = 0, data = true })
    local runs = { 0, 0 }
    local fail = true
    local migrations = {
      [1] = function()
        runs[1] = runs[1] + 1
      end,
      [2] = function()
        runs[2] = runs[2] + 1
        if fail then
          error("bad data", 0)
        end
      end,
    }

    TestEnv.expectErrorContaining(
      "SettingsKit:Open migration 2 of MyAddonDB failed: bad data",
      function()
        SettingsKit:Open("MyAddonDB", schema(), { version = 2, migrations = migrations })
      end
    )
    assert.are.equal(1, TestEnv.GetGlobal("MyAddonDB").version)

    fail = false
    SettingsKit:Open("MyAddonDB", schema(), { version = 2, migrations = migrations })
    assert.are.same({ 1, 2 }, runs)
    assert.are.equal(2, TestEnv.GetGlobal("MyAddonDB").version)
  end)

  it("leaves a newer stored version alone", function()
    TestEnv.SavedVariable("MyAddonDB", { version = 9 })
    SettingsKit:Open("MyAddonDB", schema(), { version = 2 })
    assert.are.equal(9, TestEnv.GetGlobal("MyAddonDB").version)
  end)

  it("refuses a stored version that is not an integer", function()
    TestEnv.SavedVariable("MyAddonDB", { version = "one" })
    TestEnv.expectErrorContaining("MyAddonDB.version must be a non-negative integer", function()
      SettingsKit:Open("MyAddonDB", schema(), { version = 2 })
    end)
  end)
end)
