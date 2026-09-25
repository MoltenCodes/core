local TestEnv = require("SettingsKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src

-- The reason every read-only refusal ends with, for a table stored at version
-- 9 and opened with `options.version = 2`.
local REASON = "the saved table has version 9, newer than options.version 2; "
  .. "pass options.allowNewerData = true to SettingsKit:Open to write it"

---Assert `call` failed with `message` reported at the line inside `call`
---that called into SettingsKit: the line after `function()`.
---@param message string
---@param call fun()
local function assertCaseAtCaller(message, call)
  local expectedLine = debug.getinfo(call, "S").linedefined + 1
  local ok, value = pcall(call)
  assert.is_false(ok)
  assert.are.equal(SOURCE .. ":" .. tostring(expectedLine) .. ": " .. message, value)
end

---Deep-copy plain data, so a snapshot of the saved table can be compared with
---it after every refused write.
---@param value any
---@return any
local function snapshot(value)
  if type(value) ~= "table" then
    return value
  end
  local copy = {}
  for key, item in pairs(value) do
    copy[key] = snapshot(item)
  end
  return copy
end

describe("SettingsKit newer stored data", function()
  local SettingsKit, S
  before_each(function()
    local _
    SettingsKit, _, _, _, S = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  local function schema()
    local Aura = S.table({ fields = { shown = S.optional(S.boolean(), true) } })
    local Scoped = S.table({ fields = { note = S.optional(S.string()) } })
    return {
      global = S.table({ fields = { seen = S.optional(S.number(), 0) } }),
      char = Scoped,
      realm = Scoped,
      class = Scoped,
      faction = Scoped,
      profile = S.table({
        fields = {
          scale = S.optional(S.number(), 1),
          color = S.optional(S.array({ of = S.number(), max = 4 }), { 1, 1, 1 }),
          frame = S.optional(S.table({ fields = { x = S.optional(S.number(), 0) } }), {}),
          auras = S.optional(
            S.map({ keys = S.number(), values = S.optional(Aura, {}), max = 8 }),
            {}
          ),
        },
      }),
    }
  end

  ---Store the table a newer version of the addon saved: version 9, with a
  ---value in every section a write could reach, and nothing SettingsKit's
  ---layout would add.
  ---@return table raw
  local function saveNewerData()
    TestEnv.SavedVariable("MyAddonDB", {
      version = 9,
      global = { seen = 3 },
      profiles = {
        Default = { scale = 2, frame = { x = 5 }, auras = { [118] = { shown = false } } },
        Alt = { scale = 0.5 },
      },
      profileKeys = { ["Tester - Silvermoon"] = "Default" },
      char = { ["Tester - Silvermoon"] = { note = "newer" } },
      newerSection = { introducedIn = 9 },
    })
    return TestEnv.GetGlobal("MyAddonDB")
  end

  it("opens newer data read-only by default, reads it, and leaves it exactly as it was", function()
    local raw = saveNewerData()
    local before = snapshot(raw)
    local db = SettingsKit:Open("MyAddonDB", schema(), { version = 2 })

    assert.is_true(db:IsReadOnly())
    assert.are.equal(2, db.profile.scale)
    assert.are.equal(5, db.profile.frame.x)
    assert.is_false(db.profile.auras[118].shown)
    assert.is_true(db.profile.auras[7].shown)
    assert.are.equal(3, db.global.seen)
    assert.are.equal("newer", db.char.note)
    assert.is_nil(db.realm.note)
    assert.are.same({ "Alt", "Default" }, db:GetProfiles())
    assert.are.equal("Default", db:GetProfile())
    -- A plain-table default is handed out as a copy and not stored.
    assert.are.same({ 1, 1, 1 }, db.profile.color)
    local keys = 0
    for _ in db:Pairs(db.profile) do
      keys = keys + 1
    end
    assert.are.equal(4, keys)

    assert.are.same(before, raw)
  end)

  it("refuses every view write at the writing line, without storing or signalling", function()
    local raw = saveNewerData()
    local before = snapshot(raw)
    local db = SettingsKit:Open("MyAddonDB", schema(), { version = 2 })
    local signals = 0
    for _, scope in ipairs({ "global", "char", "realm", "class", "faction", "profile" }) do
      db:OnChange(scope, function()
        signals = signals + 1
      end)
    end

    local prefix = "SettingsKit (MyAddonDB) "
    local cases = {
      {
        prefix .. "global is read-only: " .. REASON,
        function()
          db.global.seen = 4
        end,
      },
      {
        prefix .. "char is read-only: " .. REASON,
        function()
          db.char.note = "older"
        end,
      },
      {
        prefix .. "realm is read-only: " .. REASON,
        function()
          db.realm.note = "older"
        end,
      },
      {
        prefix .. "class is read-only: " .. REASON,
        function()
          db.class.note = "older"
        end,
      },
      {
        prefix .. "faction is read-only: " .. REASON,
        function()
          db.faction.note = "older"
        end,
      },
      {
        prefix .. "profile is read-only: " .. REASON,
        function()
          db.profile.scale = 1.5
        end,
      },
      {
        prefix .. "profile is read-only: " .. REASON,
        function()
          db.profile.scale = nil
        end,
      },
      {
        prefix .. "profile.frame is read-only: " .. REASON,
        function()
          db.profile.frame.x = 1
        end,
      },
      {
        prefix .. "profile.auras is read-only: " .. REASON,
        function()
          db.profile.auras[7] = { shown = false }
        end,
      },
      {
        prefix .. "profile.auras[118] is read-only: " .. REASON,
        function()
          db.profile.auras[118].shown = true
        end,
      },
    }
    for index = 1, #cases do
      assertCaseAtCaller(cases[index][1], cases[index][2])
    end

    assert.are.equal(0, signals)
    assert.are.same(before, raw)
  end)

  it("refuses every changing method at the caller's line and changes nothing", function()
    local raw = saveNewerData()
    local before = snapshot(raw)
    local db = SettingsKit:Open("MyAddonDB", schema(), { version = 2 })
    local signals = 0
    local function count()
      signals = signals + 1
    end
    db:OnProfileChanged(count)
    db:OnProfileCopied(count)
    db:OnProfileReset(count)
    db:OnProfileDeleted(count)

    local function refusal(methodName)
      return "SettingsKit.Database:"
        .. methodName
        .. " cannot change MyAddonDB, which is read-only: "
        .. REASON
    end
    local cases = {
      {
        refusal("SetProfile"),
        function()
          db:SetProfile("Alt")
        end,
      },
      {
        refusal("SetProfile"),
        function()
          db:SetProfile("Default")
        end,
      },
      {
        refusal("SetProfile"),
        function()
          db:SetProfile("Brand new")
        end,
      },
      {
        refusal("CopyProfile"),
        function()
          db:CopyProfile("Alt")
        end,
      },
      {
        refusal("ResetProfile"),
        function()
          db:ResetProfile()
        end,
      },
      {
        refusal("DeleteProfile"),
        function()
          db:DeleteProfile("Alt")
        end,
      },
      {
        refusal("ResetDatabase"),
        function()
          db:ResetDatabase()
        end,
      },
      {
        refusal("Compact"),
        function()
          db:Compact()
        end,
      },
    }
    for index = 1, #cases do
      assertCaseAtCaller(cases[index][1], cases[index][2])
    end

    assert.are.equal(0, signals)
    assert.are.equal("Default", db:GetProfile())
    assert.are.same(before, raw)
  end)

  it("answers Validate with the refusal a write would raise", function()
    saveNewerData()
    local db = SettingsKit:Open("MyAddonDB", schema(), { version = 2 })
    local ok, message = db:Validate("profile", "frame.x", 1)
    assert.is_false(ok)
    assert.are.equal("SettingsKit (MyAddonDB) profile.frame is read-only: " .. REASON, message)
  end)

  it("skips the logout compaction of a read-only database", function()
    local raw = saveNewerData()
    raw.profiles.Default.scale = 1 -- equal to its default: compaction would remove it
    local before = snapshot(raw)
    SettingsKit:Open("MyAddonDB", schema(), { version = 2 })
    TestEnv.Logout()
    assert.are.same(before, raw)
  end)

  it("creates no layout section, profile or profile choice in a read-only database", function()
    TestEnv.SavedVariable("MyAddonDB", { version = 9, profiles = { Kept = { scale = 2 } } })
    local db = SettingsKit:Open("MyAddonDB", schema(), { version = 2, defaultProfile = "char" })
    assert.are.same(
      { version = 9, profiles = { Kept = { scale = 2 } } },
      TestEnv.GetGlobal("MyAddonDB")
    )
    assert.are.equal("Tester - Silvermoon", db:GetProfile())
    assert.are.equal(1, db.profile.scale)
    assert.is_true(db.profile.auras[3].shown)
    assert.are.same({ "Kept", "Tester - Silvermoon" }, db:GetProfiles())
  end)

  it("still refuses a layout section that is not a table", function()
    TestEnv.SavedVariable("MyAddonDB", { version = 9, global = 5 })
    TestEnv.expectErrorContaining("SettingsKit:Open MyAddonDB.global must be a table", function()
      SettingsKit:Open("MyAddonDB", schema(), { version = 2 })
    end)
  end)

  it("opens newer data writable with allowNewerData and never lowers the version", function()
    local raw = saveNewerData()
    local ran = 0
    local db = SettingsKit:Open("MyAddonDB", schema(), {
      version = 2,
      allowNewerData = true,
      migrations = {
        [2] = function()
          ran = ran + 1
        end,
      },
    })

    assert.is_false(db:IsReadOnly())
    assert.are.equal(0, ran)
    db.profile.scale = 1.5
    db.global.seen = 4
    assert.is_true(db:SetProfile("Alt"))
    db:CopyProfile("Default")
    assert.are.equal(1.5, db.profile.scale)
    db:ResetProfile()
    db:DeleteProfile("Default")
    db:Compact()
    TestEnv.Logout()
    assert.are.equal(4, raw.global.seen)
    assert.are.equal(9, raw.version)
    assert.are.same({ introducedIn = 9 }, raw.newerSection)

    db:ResetDatabase()
    assert.are.equal(9, raw.version)
    assert.is_nil(raw.newerSection)
  end)

  it("answers IsReadOnly with false for current and older data", function()
    local fresh = SettingsKit:Open("FreshDB", schema(), { version = 2 })
    assert.is_false(fresh:IsReadOnly())
    TestEnv.SavedVariable("OlderDB", { version = 1, global = { seen = 1 } })
    local older = SettingsKit:Open("OlderDB", schema(), { version = 2 })
    assert.is_false(older:IsReadOnly())
    local unversioned = SettingsKit:Open("PlainDB", schema())
    assert.is_false(unversioned:IsReadOnly())
    unversioned.global.seen = 2
  end)

  it("keeps the mode of the first Open when the name is opened again", function()
    saveNewerData()
    local db = SettingsKit:Open("MyAddonDB", schema(), { version = 2 })
    local again = SettingsKit:Open("MyAddonDB")
    assert.are.equal(db, again)
    assert.is_true(again:IsReadOnly())
  end)

  it("refuses IsReadOnly on anything but a database, at the caller", function()
    local db = SettingsKit:Open("MyAddonDB", schema())
    assertCaseAtCaller(
      "SettingsKit.Database:IsReadOnly must be called on a SettingsKit database",
      function()
        db.IsReadOnly({})
      end
    )
  end)

  it("validates options.allowNewerData at the caller", function()
    TestEnv.InstallSecretProbe()
    local secret = TestEnv.NewSecret()
    local cases = {
      {
        "SettingsKit:Open options.allowNewerData must be a boolean",
        function()
          SettingsKit:Open("MyAddonDB", schema(), { version = 2, allowNewerData = "yes" })
        end,
      },
      {
        "SettingsKit:Open options.allowNewerData must be a boolean",
        function()
          SettingsKit:Open("MyAddonDB", schema(), { version = 2, allowNewerData = 1 })
        end,
      },
      {
        "SettingsKit:Open options.allowNewerData must not be a secret value",
        function()
          SettingsKit:Open("MyAddonDB", schema(), { version = 2, allowNewerData = secret })
        end,
      },
      {
        "SettingsKit:Open options.allowNewerData requires options.version",
        function()
          SettingsKit:Open("MyAddonDB", schema(), { allowNewerData = true })
        end,
      },
      {
        'SettingsKit:Open options contains unknown field "allowNewer"',
        function()
          SettingsKit:Open("MyAddonDB", schema(), { version = 2, allowNewer = true })
        end,
      },
    }
    for index = 1, #cases do
      assertCaseAtCaller(cases[index][1], cases[index][2])
    end
    assert.is_nil(TestEnv.GetGlobal("MyAddonDB"))

    local db = SettingsKit:Open("MyAddonDB", schema(), { version = 2, allowNewerData = false })
    assert.is_false(db:IsReadOnly())
  end)
end)
