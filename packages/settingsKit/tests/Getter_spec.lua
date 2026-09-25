local TestEnv = require("SettingsKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src

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

---@param S table SchemaKit
---@return table schema
local function schemaFor(S)
  return {
    global = S.table({ fields = { installs = S.optional(S.number(), 0) } }),
    char = S.table({ fields = { seen = S.optional(S.boolean(), false) } }),
    profile = S.table({
      fields = {
        scale = S.optional(S.number({ min = 0.5, max = 2 }), 1),
        locked = S.optional(S.boolean(), false),
        name = S.optional(S.string()),
        list = S.optional(S.array({ of = S.number() }), { 1, 2 }),
        frame = S.optional(S.table({ fields = { x = S.optional(S.number(), 0) } }), {}),
        auras = S.optional(
          S.map({
            keys = S.number(),
            values = S.optional(
              S.table({ fields = { shown = S.optional(S.boolean(), true) } }),
              {}
            ),
            max = 8,
          }),
          {}
        ),
        counts = S.optional(
          S.map({ keys = S.string(), values = S.optional(S.number(), 5), max = 8 }),
          {}
        ),
      },
    }),
  }
end

describe("SettingsKit getters", function()
  local SettingsKit, S, db
  before_each(function()
    local _
    SettingsKit, _, _, _, S = TestEnv.NewPackage()
    db = SettingsKit:Open("MyAddonDB", schemaFor(S))
  end)
  after_each(TestEnv.Reset)

  ---@return table raw
  local function saved()
    return TestEnv.GetGlobal("MyAddonDB")
  end

  it("answers exactly what reading the view answers, for every kind of field", function()
    local profile = db.profile
    profile.name = "saved"
    profile.auras[3].shown = false
    profile.counts.kept = 9
    local cases = {
      { profile, "scale" },
      { profile, "locked" },
      { profile, "name" },
      { profile, "undeclared" },
      { profile, "frame" },
      { profile, "auras" },
      { profile.frame, "x" },
      { profile.auras, 3 },
      { profile.auras, 4 },
      { profile.auras[4], "shown" },
      { profile.auras[3], "shown" },
      { profile.counts, "kept" },
      { profile.counts, "missing" },
      { db.global, "installs" },
      { db.char, "seen" },
    }
    for _, case in ipairs(cases) do
      local view, key = case[1], case[2]
      local getter = db:Getter(view, key)
      assert.are.equal(view[key], getter(), tostring(key))
      assert.are.equal(getter(), getter(), tostring(key))
    end
    -- A plain-table default: the first read stores a copy, later reads
    -- answer that stored table, through the view or the getter.
    local list = db:Getter("profile", "list")
    local first = list()
    assert.are.same({ 1, 2 }, first)
    assert.are.equal(first, profile.list)
    assert.are.equal(first, list())
  end)

  it("follows writes, resets to the default and structural changes", function()
    local scale = db:Getter("profile", "scale")
    local x = db:Getter(db.profile.frame, "x")
    local shown = db:Getter(db.profile.auras[7], "shown")
    assert.are.equal(1, scale())
    assert.are.equal(0, x())
    assert.is_true(shown())

    db.profile.scale = 1.5
    db.profile.frame.x = 3
    db.profile.auras[7].shown = false
    assert.are.equal(1.5, scale())
    assert.are.equal(3, x())
    assert.is_false(shown())

    db.profile.frame = { x = 4 }
    db.profile.auras[7] = { shown = true }
    assert.are.equal(4, x())
    assert.is_true(shown())

    db.profile.scale = nil
    db.profile.frame = nil
    db.profile.auras = nil
    assert.are.equal(1, scale())
    assert.are.equal(0, x())
    assert.is_true(shown())

    db.profile.frame.x = 0
    db:Compact()
    db.profile.frame.x = 6
    assert.are.equal(6, x())
    assert.are.same({ x = 6 }, saved().profiles.Default.frame)
  end)

  it(
    "follows the current profile from a scope name, and stays on its profile from a view",
    function()
      local current = db:Getter("profile", "scale")
      local pinned = db:Getter(db.profile, "scale")
      db.profile.scale = 1.5
      db:SetProfile("Other")
      assert.are.equal(1, current())
      assert.are.equal(1.5, pinned())
      db.profile.scale = 2
      assert.are.equal(2, current())
      assert.are.equal(1.5, pinned())
      db:SetProfile("Default")
      assert.are.equal(1.5, current())

      db:CopyProfile("Other")
      assert.are.equal(2, current())
      assert.are.equal(2, pinned())
      db:ResetProfile()
      assert.are.equal(1, current())
      assert.are.equal(1, pinned())
    end
  )

  it(
    "reads defaults through a detached view and follows ResetDatabase from a scope name",
    function()
      db:SetProfile("Doomed")
      db.profile.scale = 2
      local doomed = db:Getter(db.profile, "scale")
      local doomedX = db:Getter(db.profile.frame, "x")
      db.profile.frame.x = 3
      db:SetProfile("Default")
      assert.are.equal(2, doomed())
      assert.are.equal(3, doomedX())
      db:DeleteProfile("Doomed")
      assert.are.equal(1, doomed())
      assert.are.equal(0, doomedX())

      db.profile.scale = 1.5
      db.global.installs = 3
      local current, pinned = db:Getter("profile", "scale"), db:Getter(db.profile, "scale")
      local installs = db:Getter("global", "installs")
      db:ResetDatabase()
      assert.are.equal(1, current())
      assert.are.equal(1, pinned())
      assert.are.equal(0, installs())
      db.profile.scale = 2
      db.global.installs = 1
      assert.are.equal(2, current())
      assert.are.equal(1, pinned())
      assert.are.equal(1, installs())
    end
  )

  it("shows a direct edit of the saved variable after Resync", function()
    local x = db:Getter(db.profile.frame, "x")
    db.profile.frame.x = 1
    assert.are.equal(1, x())
    saved().profiles.Default.frame = { x = 9 }
    assert.are.equal(1, x())
    db:Resync()
    assert.are.equal(9, x())
  end)

  it("reads a read-only database", function()
    TestEnv.Reset()
    local _
    SettingsKit, _, _, _, S = TestEnv.NewPackage()
    TestEnv.SavedVariable("MyAddonDB", { version = 9, profiles = { Default = { scale = 2 } } })
    db = SettingsKit:Open("MyAddonDB", schemaFor(S), { version = 2 })
    assert.is_true(db:IsReadOnly())
    assert.are.equal(2, db:Getter("profile", "scale")())
    assert.are.equal(0, db:Getter(db.profile.frame, "x")())
    assert.are.same({ 1, 2 }, db:Getter("profile", "list")())
    assert.is_nil(saved().profiles.Default.list)
  end)

  it("probes the key when the getter is made, not on the calls that read the cache", function()
    local probed = 0
    TestEnv.SetGlobal("issecretvalue", function()
      probed = probed + 1
      return false
    end)
    local scale = db:Getter("profile", "scale")
    assert.is_true(probed > 0)
    -- The first call after a mutation reads through the view once.
    assert.are.equal(1, scale())
    local warmed = probed
    for _ = 1, 10 do
      assert.are.equal(1, scale())
    end
    assert.are.equal(warmed, probed)
  end)

  it("refuses a secret key, a nil or NaN key and a bad source at the caller's line", function()
    TestEnv.InstallSecretProbe()
    local secret = TestEnv.NewSecret()
    local other = SettingsKit:Open("OtherDB", schemaFor(S))
    assertCaseAtCaller("SettingsKit.Database:Getter key must not be a secret value", function()
      db:Getter("profile", secret)
    end)
    assertCaseAtCaller("SettingsKit.Database:Getter key must not be nil or NaN", function()
      db:Getter("profile", nil)
    end)
    assertCaseAtCaller("SettingsKit.Database:Getter key must not be nil or NaN", function()
      db:Getter(db.profile.auras, 0 / 0)
    end)
    assertCaseAtCaller("SettingsKit.Database:Getter scope must not be a secret value", function()
      db:Getter(secret, "scale")
    end)
    assertCaseAtCaller(
      "SettingsKit.Database:Getter scope must name a declared, available scope",
      function()
        db:Getter("realm", "scale")
      end
    )
    assertCaseAtCaller(
      "SettingsKit.Database:Getter source must be a scope name or a view of this database",
      function()
        db:Getter(other.profile, "scale")
      end
    )
    assertCaseAtCaller(
      "SettingsKit.Database:Getter source must be a scope name or a view of this database",
      function()
        db:Getter({}, "scale")
      end
    )
    assertCaseAtCaller(
      "SettingsKit.Database:Getter must be called on a SettingsKit database",
      function()
        db.Getter({}, "profile", "scale")
      end
    )
  end)

  it("returns a secret saved value as it is stored, as the view does", function()
    -- The fast path tests the saved value with `~= nil` (the documented
    -- exception to the nil rule). A secret here raises on any operation a
    -- client secret raises on, so the getter must only compare it with nil
    -- and return it.
    TestEnv.InstallSecretProbe()
    local secret = TestEnv.NewSecret()
    local function refuse()
      error("a secret value was operated on", 2)
    end
    setmetatable(secret, {
      __eq = refuse,
      __lt = refuse,
      __le = refuse,
      __index = refuse,
      __newindex = refuse,
      __call = refuse,
      __concat = refuse,
      __len = refuse,
      __unm = refuse,
      __add = refuse,
    })
    local profile = saved().profiles.Default
    profile.undeclared = secret
    profile.scale = secret
    db:Resync()
    local getters = {
      db:Getter("profile", "undeclared"),
      db:Getter(db.profile, "undeclared"),
      db:Getter("profile", "scale"),
      db:Getter(db.profile, "scale"),
    }
    for index, getter in ipairs(getters) do
      -- Twice: the first call may take the dispatched path, the second
      -- reads the cached table on the fast path.
      assert.is_true(rawequal(secret, getter()), "getter " .. index)
      assert.is_true(rawequal(secret, getter()), "getter " .. index)
    end
    assert.is_true(rawequal(secret, db.profile.undeclared))
    assert.is_true(rawequal(secret, db.profile.scale))
    -- A secret removed again gives the default back on the fast path.
    profile.scale = nil
    assert.are.equal(1, getters[3]())
    assert.are.equal(1, getters[4]())
  end)

  it("keeps getters made by revision 7 working after the upgrade to this revision", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    require("Registry")
    require("SignalKit")
    require("EventKit")
    local SchemaKit = require("SchemaKit")
    local previous = TestEnv.LoadRevision(7)
    TestEnv.SetPlayer()
    assert.are.equal(7, previous.REVISION)
    local old = previous:Open("MyAddonDB", schemaFor(SchemaKit))
    local scale = old:Getter("profile", "scale")
    local x = old:Getter(old.profile.frame, "x")
    old.profile.scale = 1.5
    assert.are.equal(1.5, scale())

    local upgraded = TestEnv.ReloadPackage()
    assert.are.equal(previous, upgraded)
    assert.is_true(upgraded.REVISION > 7)
    assert.are.equal(upgraded.REVISION, rawget(upgraded, "_state").runtimeRevision)
    assert.are.equal(old, upgraded:Open("MyAddonDB"))
    assert.are.equal(1.5, scale())
    old.profile.frame = { x = 3 }
    assert.are.equal(3, x())
    local fresh = old:Getter("profile", "scale")
    assert.are.equal(1.5, fresh())
    old:SetProfile("Other")
    assert.are.equal(1, scale())
    assert.are.equal(1, fresh())
  end)

  it("keeps working across an in-place upgrade", function()
    local scale = db:Getter("profile", "scale")
    local x = db:Getter(db.profile.frame, "x")
    db.profile.scale = 1.5
    assert.are.equal(1.5, scale())

    local upgraded = TestEnv.LoadRevision(SettingsKit.REVISION + 1)
    assert.are.equal(SettingsKit, upgraded)
    assert.are.equal(1.5, scale())
    db.profile.frame = { x = 2 }
    assert.are.equal(2, x())
    db:SetProfile("Other")
    assert.are.equal(1, scale())
  end)
end)
