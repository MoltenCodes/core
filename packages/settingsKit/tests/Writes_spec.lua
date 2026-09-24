local TestEnv = require("SettingsKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src

---Run `action` and return the error it raised, asserting it was reported at
---the line after the one that called `mark()`.
---@param action fun(mark: fun())
---@return string message without the position prefix
local function raisedAtWriter(action)
  local expectedLine = nil
  local function mark()
    expectedLine = debug.getinfo(2, "l").currentline + 1
  end
  local ok, value = pcall(action, mark)
  assert.is_false(ok)
  local prefix = SOURCE .. ":" .. tostring(expectedLine) .. ": "
  assert.are.equal(prefix, tostring(value):sub(1, #prefix))
  return tostring(value):sub(#prefix + 1)
end

describe("SettingsKit validated writes", function()
  local SettingsKit, S, db
  before_each(function()
    local _
    SettingsKit, _, _, _, S = TestEnv.NewPackage()
    db = SettingsKit:Open("MyAddonDB", {
      global = S.table({ fields = { seen = S.optional(S.number({ integer = true }), 0) } }),
      profile = S.table({
        fields = {
          scale = S.optional(S.number({ min = 0.5, max = 2 }), 1),
          name = S.optional(S.string({ max = 8 })),
          frame = S.optional(
            S.table({
              fields = {
                x = S.optional(S.number(), 0),
                point = S.optional(S.enum({ "TOP", "CENTER" }), "TOP"),
              },
            }),
            {}
          ),
          auras = S.optional(
            S.map({
              keys = S.number({ integer = true, min = 1 }),
              values = S.optional(
                S.table({ fields = { shown = S.optional(S.boolean(), true) } }),
                {}
              ),
              max = 2,
            }),
            {}
          ),
          tags = S.optional(S.array({ of = S.string(), max = 3 })),
        },
      }),
    })
  end)
  after_each(TestEnv.Reset)

  local function saved()
    return TestEnv.GetGlobal("MyAddonDB")
  end

  it("stores a valid write in the saved table", function()
    db.profile.scale = 1.5
    db.global.seen = 3
    db.profile.tags = { "a", "b" }

    assert.are.equal(1.5, db.profile.scale)
    assert.are.equal(1.5, saved().profiles.Default.scale)
    assert.are.equal(3, saved().global.seen)
    assert.are.same({ "a", "b" }, db.profile.tags)
  end)

  it(
    "refuses a write that violates the schema at the writer's line with SchemaKit's failure text",
    function()
      local message = raisedAtWriter(function(mark)
        mark()
        db.profile.scale = 5
      end)
      assert.are.equal(
        "SettingsKit (MyAddonDB) profile.scale: expected number <= 2, found larger number",
        message
      )
      assert.is_nil(saved().profiles.Default.scale)

      message = raisedAtWriter(function(mark)
        mark()
        db.profile.name = 42
      end)
      assert.are.equal(
        "SettingsKit (MyAddonDB) profile.name: expected string, found number",
        message
      )
    end
  )

  it("refuses an undeclared field of a closed record", function()
    local message = raisedAtWriter(function(mark)
      mark()
      db.profile.typo = 1
    end)
    assert.is_truthy(message:find("SettingsKit (MyAddonDB) profile.typo: ", 1, true))
    assert.is_nil(saved().profiles.Default.typo)
  end)

  it("validates nested writes against the nested field's schema", function()
    db.profile.frame.point = "CENTER"
    assert.are.equal("CENTER", saved().profiles.Default.frame.point)

    local message = raisedAtWriter(function(mark)
      mark()
      db.profile.frame.point = "LEFT"
    end)
    assert.is_truthy(
      message:find("SettingsKit (MyAddonDB) profile.frame.point: expected ", 1, true)
    )
    assert.are.equal("CENTER", db.profile.frame.point)
  end)

  it("validates a whole table assigned to a record field", function()
    db.profile.frame = { x = 3 }
    assert.are.equal(3, db.profile.frame.x)
    assert.are.equal("TOP", db.profile.frame.point)

    local message = raisedAtWriter(function(mark)
      mark()
      db.profile.frame = { x = "wide" }
    end)
    assert.are.equal(
      "SettingsKit (MyAddonDB) profile.frame.x: expected number, found string",
      message
    )
  end)

  it("validates keyed-section keys, values and entries", function()
    db.profile.auras[1].shown = false
    assert.is_false(saved().profiles.Default.auras[1].shown)

    local message = raisedAtWriter(function(mark)
      mark()
      db.profile.auras[0] = {}
    end)
    assert.is_truthy(
      message:find("SettingsKit (MyAddonDB) profile.auras[0]: expected key ", 1, true)
    )

    message = raisedAtWriter(function(mark)
      mark()
      db.profile.auras[2].shown = "yes"
    end)
    assert.are.equal(
      "SettingsKit (MyAddonDB) profile.auras[2].shown: expected boolean, found string",
      message
    )
  end)

  it("refuses to grow a keyed section past its bound", function()
    db.profile.auras[1] = {}
    db.profile.auras[2].shown = false

    local message = raisedAtWriter(function(mark)
      mark()
      db.profile.auras[3] = {}
    end)
    assert.are.equal("SettingsKit (MyAddonDB) profile.auras: expected at most 2 entries", message)
    message = raisedAtWriter(function(mark)
      mark()
      db.profile.auras[3].shown = false
    end)
    assert.are.equal("SettingsKit (MyAddonDB) profile.auras: expected at most 2 entries", message)

    -- Replacing an existing entry does not grow the section.
    db.profile.auras[2] = { shown = true }
    assert.is_nil(saved().profiles.Default.auras[3])
  end)

  it("resets a field to its default when nil is written", function()
    db.profile.scale = 2
    db.profile.scale = nil
    assert.are.equal(1, db.profile.scale)
    assert.is_nil(saved().profiles.Default.scale)
  end)

  it("leaves a NaN key to Lua, which refuses it before any metamethod runs", function()
    local ok, message = pcall(function()
      db.profile.auras[0 / 0] = {}
    end)
    assert.is_false(ok)
    assert.is_truthy(tostring(message):find("NaN", 1, true))
    assert.is_nil(TestEnv.GetGlobal("MyAddonDB").profiles.Default.auras)
  end)

  it("fires OnChange with the database, scope, key, value and container path", function()
    local calls = {}
    local connection = db:OnChange("profile", function(...)
      calls[#calls + 1] = { ... }
    end)
    db:OnChange("global", function(_, scope, key, value, path)
      calls[#calls + 1] = { "global listener", scope, key, value, path }
    end)

    db.profile.scale = 1.25
    db.profile.frame.x = 7
    db.profile.auras[1].shown = false
    db.global.seen = 1
    db.profile.scale = nil

    assert.are.same({
      { db, "profile", "scale", 1.25, "" },
      { db, "profile", "x", 7, "frame" },
      { db, "profile", "shown", false, "auras[1]" },
      { "global listener", "global", "seen", 1, "" },
      { db, "profile", "scale", nil, "" },
    }, calls)

    assert.is_true(connection:Disconnect())
    db.profile.scale = 1
    assert.are.equal(5, #calls)
  end)

  it("does not fire OnChange for a refused write", function()
    local calls = 0
    db:OnChange("profile", function()
      calls = calls + 1
    end)
    pcall(function()
      db.profile.scale = 10
    end)
    assert.are.equal(0, calls)
  end)

  it("refuses writes to the database object itself", function()
    local message = raisedAtWriter(function(mark)
      mark()
      db.custom = 1
    end)
    assert.are.equal(
      "SettingsKit databases are read-only; write through db.<scope> instead",
      message
    )
  end)
end)

describe("SettingsKit and secret values", function()
  local db
  before_each(function()
    local SettingsKit, _, _, _, S = TestEnv.NewPackage()
    TestEnv.InstallSecretProbe()
    db = SettingsKit:Open("MyAddonDB", {
      profile = S.table({
        fields = {
          name = S.optional(S.any()),
          data = S.optional(S.table({ fields = {}, open = true })),
          byName = S.optional(S.map({ keys = S.any(), values = S.any(), max = 8 }), {}),
        },
      }),
    })
  end)
  after_each(TestEnv.Reset)

  it("refuses a secret value at the writer's line and stores nothing", function()
    local secret = TestEnv.NewSecret()
    local message = raisedAtWriter(function(mark)
      mark()
      db.profile.name = secret
    end)
    assert.are.equal(
      "SettingsKit (MyAddonDB) profile.name refused a secret value: saved variables never hold secret values",
      message
    )
    assert.is_nil(TestEnv.GetGlobal("MyAddonDB").profiles.Default.name)
  end)

  it("refuses a secret nested inside a table value, even where the schema does not look", function()
    local secret = TestEnv.NewSecret()
    local message = raisedAtWriter(function(mark)
      mark()
      db.profile.data = { deep = { deeper = secret } }
    end)
    assert.are.equal(
      "SettingsKit (MyAddonDB) profile.data refused a secret value: saved variables never hold secret values",
      message
    )
  end)

  it("reads, iterates and compacts a secret saved value as it is stored", function()
    local secret = TestEnv.NewSecret()
    local saved = TestEnv.GetGlobal("MyAddonDB")
    saved.profiles.Default.name = secret

    assert.is_true(rawequal(secret, db.profile.name))
    local seen = nil
    for key, value in db:Pairs(db.profile) do
      if key == "name" then
        seen = value
      end
    end
    assert.is_true(rawequal(secret, seen))
    db:Compact()
    assert.is_true(rawequal(secret, saved.profiles.Default.name))
  end)

  it("skips a secret stored profile choice when a profile is deleted", function()
    local secret = TestEnv.NewSecret()
    local saved = TestEnv.GetGlobal("MyAddonDB")
    db:SetProfile("Spare")
    db:SetProfile("Default")
    saved.profileKeys["Other - Realm"] = secret
    saved.profileKeys["Third - Realm"] = "Spare"

    db:DeleteProfile("Spare")
    assert.is_true(rawequal(secret, saved.profileKeys["Other - Realm"]))
    assert.is_nil(saved.profileKeys["Third - Realm"])
  end)

  it("refuses a secret key", function()
    local secret = TestEnv.NewSecret()
    local message = raisedAtWriter(function(mark)
      mark()
      db.profile.byName[secret] = 1
    end)
    assert.are.equal(
      "SettingsKit (MyAddonDB) profile.byName refused a secret key: saved variables never hold secret values",
      message
    )
  end)

  it("refuses to read a keyed section with a secret key", function()
    local secret = TestEnv.NewSecret()
    local message = raisedAtWriter(function(mark)
      mark()
      local _ = db.profile.byName[secret]
    end)
    assert.are.equal(
      "SettingsKit (MyAddonDB) profile.byName cannot be read with a secret key",
      message
    )
  end)

  it("refuses a secret scope name at the caller's line before it indexes a scope", function()
    local secret = TestEnv.NewSecret()
    local message = raisedAtWriter(function(mark)
      mark()
      db:OnChange(secret, function() end)
    end)
    assert.are.equal("SettingsKit.Database:OnChange scope must not be a secret value", message)

    message = raisedAtWriter(function(mark)
      mark()
      db:Validate(secret, "name", 1)
    end)
    assert.are.equal("SettingsKit.Database:Validate scope must not be a secret value", message)
  end)

  it("refuses to read the database with a secret key at the reading line", function()
    local secret = TestEnv.NewSecret()
    local message = raisedAtWriter(function(mark)
      mark()
      return db[secret]
    end)
    assert.are.equal("SettingsKit databases cannot be read with a secret key", message)
    -- Methods and scopes still read as before.
    assert.are.equal("function", type(db.OnChange))
    assert.are.equal("table", type(db.profile))
  end)
end)

describe("SettingsKit path rendering of unusual keys", function()
  local db
  before_each(function()
    local SettingsKit, _, _, _, S = TestEnv.NewPackage()
    db = SettingsKit:Open("MyAddonDB", {
      profile = S.table({
        fields = {
          notes = S.optional(
            S.map({
              keys = S.string(),
              values = S.optional(S.table({ fields = { text = S.optional(S.any()) } }), {}),
              max = 8,
            }),
            {}
          ),
        },
      }),
    })
  end)
  after_each(TestEnv.Reset)

  -- A key a hostile player could send: a texture escape and a control byte.
  local HOSTILE = "a|Tx|t\1b"
  -- The way SchemaKit renders the same key in its failure paths.
  local RENDERED = '["a||Tx||t\\001b"]'

  it("renders a key with escape codes and control bytes safely in a refusal", function()
    local message = raisedAtWriter(function(mark)
      mark()
      db.profile.notes[HOSTILE].text = setmetatable({}, {})
    end)
    assert.are.equal(
      "SettingsKit (MyAddonDB) profile.notes"
        .. RENDERED
        .. ".text refused a table with a metatable: saved variables cannot hold metatables",
      message
    )
  end)

  it("passes OnChange the same rendering in its path", function()
    local paths = {}
    db:OnChange("profile", function(_, _, _, _, path)
      paths[#paths + 1] = path
    end)
    db.profile.notes[HOSTILE].text = "x"
    db.profile.notes.plain_key.text = "y"
    db.profile.notes[string.rep("é", 20)].text = "z"
    assert.are.same({
      "notes" .. RENDERED,
      -- An identifier key keeps its plain dotted form.
      "notes.plain_key",
      -- A long key is cut at 32 bytes, never inside a UTF-8 sequence.
      'notes["' .. string.rep("é", 16) .. '..."]',
    }, paths)
  end)
end)
