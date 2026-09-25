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

  it("never re-applies the writes of a step that raised: scale 1 becomes 2, not 4", function()
    TestEnv.SavedVariable("MyAddonDB", { version = 1, profiles = { Default = { scale = 1 } } })
    local fail = true
    local migrations = {
      [2] = function(raw)
        raw.profiles.Default.scale = raw.profiles.Default.scale * 2
        if fail then
          error("interrupted", 0)
        end
      end,
    }

    TestEnv.expectErrorContaining(
      "SettingsKit:Open migration 2 of MyAddonDB failed: interrupted",
      function()
        SettingsKit:Open("MyAddonDB", schema(), { version = 2, migrations = migrations })
      end
    )
    local raw = TestEnv.GetGlobal("MyAddonDB")
    assert.are.same({ version = 1, profiles = { Default = { scale = 1 } } }, raw)

    fail = false
    local db = SettingsKit:Open("MyAddonDB", schema(), { version = 2, migrations = migrations })
    assert.are.equal(2, db.profile.scale)
    assert.are.equal(2, raw.version)
  end)

  -- Each step appends its number to `trail` and adds its number to `total`,
  -- then raises when it is the step chosen to fail.
  local STEPS = 3

  ---The saved table after steps 1 to `last` ran once each.
  ---@param last integer
  ---@return table
  local function expectedAfter(last)
    local trail = {}
    local total = 0
    for step = 1, last do
      trail[#trail + 1] = step
      total = total + step
    end
    return { version = last, trail = trail, total = total }
  end

  for failing = 1, STEPS do
    it(
      "keeps steps before a failing step "
        .. failing
        .. " committed, leaves the saved table as it was, and applies every step once on retry",
      function()
        TestEnv.SavedVariable("MyAddonDB", { version = 0, trail = {}, total = 0 })
        local raw = TestEnv.GetGlobal("MyAddonDB")
        local runs = { 0, 0, 0 }
        local armed = true
        local migrations = {}
        for step = 1, STEPS do
          migrations[step] = function(copy)
            runs[step] = runs[step] + 1
            copy.trail[#copy.trail + 1] = step
            copy.total = copy.total + step
            if armed and step == failing then
              error("step " .. step .. " failed after writing", 0)
            end
          end
        end

        TestEnv.expectErrorContaining(
          "SettingsKit:Open migration "
            .. failing
            .. " of MyAddonDB failed: step "
            .. failing
            .. " failed after writing",
          function()
            SettingsKit:Open("MyAddonDB", schema(), { version = STEPS, migrations = migrations })
          end
        )
        assert.are.equal(raw, TestEnv.GetGlobal("MyAddonDB"))
        assert.are.same(expectedAfter(failing - 1), raw)

        armed = false
        SettingsKit:Open("MyAddonDB", schema(), { version = STEPS, migrations = migrations })
        assert.are.equal(raw, TestEnv.GetGlobal("MyAddonDB"))
        local expected = expectedAfter(STEPS)
        assert.are.same(expected.trail, raw.trail)
        assert.are.equal(expected.total, raw.total)
        assert.are.equal(STEPS, raw.version)
        for step = 1, STEPS do
          local expectedRuns = 1
          if step == failing then
            expectedRuns = 2
          end
          assert.are.equal(expectedRuns, runs[step])
        end
      end
    )
  end

  it("hands each step a copy and keeps the identity of the saved-variable table", function()
    local legacy = { scale = 0.5 }
    TestEnv.SavedVariable("MyAddonDB", { version = 0, legacy = legacy })
    local raw = TestEnv.GetGlobal("MyAddonDB")
    local received = nil
    SettingsKit:Open("MyAddonDB", schema(), {
      version = 1,
      migrations = {
        [1] = function(copy)
          received = copy
          assert.are_not.equal(raw, copy)
          assert.are_not.equal(legacy, copy.legacy)
          assert.are.same(legacy, copy.legacy)
          copy.profiles = { Default = { scale = copy.legacy.scale } }
          copy.legacy = nil
        end,
      },
    })

    assert.are.equal(raw, TestEnv.GetGlobal("MyAddonDB"))
    assert.is_nil(raw.legacy)
    assert.are.equal(0.5, raw.profiles.Default.scale)
    assert.are.same({ scale = 0.5 }, legacy)

    -- A reference kept past the step reaches a table that is no longer saved.
    received.late = true
    assert.is_nil(raw.late)
  end)

  it("preserves shared references and cycles, including cycles through the root", function()
    local shared = { value = 1 }
    local loop = {}
    loop.self = loop
    local saved = { version = 0, first = shared, second = shared, loop = loop }
    saved.root = saved
    TestEnv.SavedVariable("MyAddonDB", saved)

    SettingsKit:Open("MyAddonDB", schema(), {
      version = 1,
      migrations = {
        [1] = function(copy)
          assert.are.equal(copy.first, copy.second)
          assert.are_not.equal(shared, copy.first)
          assert.are.equal(copy.loop, copy.loop.self)
          assert.are_not.equal(loop, copy.loop)
          assert.are.equal(copy, copy.root)
          copy.first.value = 2
          copy.loop.back = copy
        end,
      },
    })

    local raw = TestEnv.GetGlobal("MyAddonDB")
    assert.are.equal(saved, raw)
    assert.are.equal(raw.first, raw.second)
    assert.are.equal(2, raw.second.value)
    assert.are.equal(raw.loop, raw.loop.self)
    assert.are.equal(raw, raw.root)
    assert.are.equal(raw, raw.loop.back)
    -- The tables the client restored were never written to.
    assert.are.equal(1, shared.value)
    assert.is_nil(loop.back)
  end)

  it("copies without invoking metamethods and keys every value as it was keyed", function()
    local function trap()
      error("a metamethod ran", 0)
    end
    local guarded = setmetatable({ kept = true }, { __index = trap, __newindex = trap })
    TestEnv.SavedVariable("MyAddonDB", {
      version = 0,
      guarded = guarded,
      [1] = "one",
      [2.5] = "two and a half",
      [true] = "yes",
      nested = { deeper = { deepest = { "a", "b" } } },
    })

    local seen = nil
    SettingsKit:Open("MyAddonDB", schema(), {
      version = 1,
      migrations = {
        [1] = function(copy)
          seen = copy
        end,
      },
    })

    assert.is_nil(getmetatable(seen.guarded))
    assert.are.equal(true, rawget(seen.guarded, "kept"))
    local raw = TestEnv.GetGlobal("MyAddonDB")
    assert.are.equal("one", raw[1])
    assert.are.equal("two and a half", raw[2.5])
    assert.are.equal("yes", raw[true])
    assert.are.same({ "a", "b" }, raw.nested.deeper.deepest)
  end)

  it("carries a secret stored in the saved table over as it is", function()
    TestEnv.InstallSecretProbe()
    local secret = TestEnv.NewSecret()
    TestEnv.SavedVariable("MyAddonDB", { version = 0, label = secret })
    local copied = nil
    SettingsKit:Open("MyAddonDB", schema(), {
      version = 1,
      migrations = {
        [1] = function(copy)
          copied = copy.label
        end,
      },
    })
    assert.are.equal(secret, copied)
    assert.are.equal(secret, TestEnv.GetGlobal("MyAddonDB").label)
  end)

  it("migrates 10000 profiles with nested tables in one step", function()
    local profiles = {}
    for index = 1, 10000 do
      profiles["Character " .. index] = {
        scale = 1,
        frame = { x = index, y = -index },
        auras = { [index] = { shown = true, color = { 1, 0.5, 0 } } },
      }
    end
    TestEnv.SavedVariable("MyAddonDB", { version = 1, profiles = profiles })

    SettingsKit:Open("MyAddonDB", schema(), {
      version = 2,
      migrations = {
        [2] = function(copy)
          for _, profile in pairs(copy.profiles) do
            profile.scale = profile.frame.x % 2 + 1
          end
        end,
      },
    })

    local raw = TestEnv.GetGlobal("MyAddonDB")
    assert.are.equal(2, raw.version)
    assert.are.equal(2, raw.profiles["Character 1"].scale)
    assert.are.equal(1, raw.profiles["Character 10000"].scale)
    assert.are.same({ 1, 0.5, 0 }, raw.profiles["Character 7"].auras[7].color)
  end)

  it("advances an older table to options.version when no migrations are given", function()
    TestEnv.SavedVariable("MyAddonDB", { version = 1, profiles = { Default = { scale = 2 } } })
    local db = SettingsKit:Open("MyAddonDB", schema(), { version = 3 })
    assert.are.equal(3, TestEnv.GetGlobal("MyAddonDB").version)
    assert.are.equal(2, db.profile.scale)
  end)

  it("refuses a layout section that is not a table before writing anything", function()
    TestEnv.SavedVariable("MyAddonDB", { version = 2, global = 5 })
    TestEnv.expectErrorContaining("SettingsKit:Open MyAddonDB.global must be a table", function()
      SettingsKit:Open("MyAddonDB", schema(), { version = 2 })
    end)
    assert.are.same({ version = 2, global = 5 }, TestEnv.GetGlobal("MyAddonDB"))

    -- Pending versions without a step: the version is not stamped either.
    TestEnv.SavedVariable("OtherDB", { version = 0, data = 1, char = "x" })
    TestEnv.expectErrorContaining("SettingsKit:Open OtherDB.char must be a table", function()
      SettingsKit:Open("OtherDB", schema(), { version = 2 })
    end)
    assert.are.same({ version = 0, data = 1, char = "x" }, TestEnv.GetGlobal("OtherDB"))
  end)

  it(
    "refuses the last step's result when a layout section is not a table, and retries it",
    function()
      -- A pre-SettingsKit release stored its own `global` flag at the top.
      TestEnv.SavedVariable("MyAddonDB", { version = 0, global = true, scale = 1.5 })
      local raw = TestEnv.GetGlobal("MyAddonDB")
      local moveFlag = false
      local migrations = {
        [1] = function(copy)
          copy.profiles = { Default = { scale = copy.scale } }
          copy.scale = nil
        end,
        [2] = function(copy)
          if moveFlag then
            copy.legacyGlobal = copy.global
            copy.global = nil
          end
        end,
      }

      TestEnv.expectErrorContaining(
        "SettingsKit:Open migration 2 of MyAddonDB failed: MyAddonDB.global must be a table",
        function()
          SettingsKit:Open("MyAddonDB", schema(), { version = 2, migrations = migrations })
        end
      )
      -- Step 1 stays committed; step 2's result was not.
      assert.are.same({ version = 1, global = true, profiles = { Default = { scale = 1.5 } } }, raw)

      moveFlag = true
      local db = SettingsKit:Open("MyAddonDB", schema(), { version = 2, migrations = migrations })
      assert.are.equal(1.5, db.profile.scale)
      assert.are.equal(true, raw.legacyGlobal)
      assert.are.equal(2, raw.version)
    end
  )

  it("lets a step pass through a layout a later step restructures", function()
    TestEnv.SavedVariable("MyAddonDB", { version = 0, global = 5 })
    SettingsKit:Open("MyAddonDB", schema(), {
      version = 3,
      migrations = {
        [1] = function(copy)
          copy.char = "temporary"
        end,
        [2] = function(copy)
          copy.legacy = { copy.global, copy.char }
          copy.global = nil
          copy.char = nil
        end,
      },
    })
    local raw = TestEnv.GetGlobal("MyAddonDB")
    assert.are.same({ 5, "temporary" }, raw.legacy)
    assert.are.equal(3, raw.version)
    assert.are.same({}, raw.global)
  end)

  it("refuses a stored version that is not an integer", function()
    TestEnv.SavedVariable("MyAddonDB", { version = "one" })
    TestEnv.expectErrorContaining("MyAddonDB.version must be a non-negative integer", function()
      SettingsKit:Open("MyAddonDB", schema(), { version = 2 })
    end)
  end)
end)
