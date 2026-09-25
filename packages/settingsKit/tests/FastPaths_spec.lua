local TestEnv = require("SettingsKitTestEnv")

-- Revision 6 answers reads from what it worked out when a view was built, and
-- accepts most scalar writes without asking SchemaKit (`checkWrite` in the
-- source explains when). These specs pin that the fast paths give exactly the
-- answers the full paths give: the same verdict and message as SchemaKit for
-- every kind of scalar rule, the same refusals for everything a fast path
-- must not skip, and the same sharing and signalling behaviour now that
-- plans, seals and signals are built once or on demand.

---Every value the differential specs write: each type, the numeric edges
---SchemaKit treats specially, and strings for every string rule.
---@return any[] values, integer count
local function candidateValues()
  local values = {
    true,
    false,
    0,
    -0,
    1,
    2,
    3,
    -2,
    -3,
    10,
    11,
    0.5,
    1.5,
    1e15,
    2 ^ 53,
    math.huge,
    -math.huge,
    0 / 0,
    "",
    "a",
    "ab",
    "abcde",
    "abcdef",
    "A1",
    "a1",
    "A12",
    "TOP",
    "BOTTOM",
    "top",
    "2",
  }
  return values, #values
end

---Describe a value for an assertion message.
---@param value any
---@return string
local function show(value)
  if type(value) == "string" then
    return string.format("%q", value)
  end
  return tostring(value)
end

describe("SettingsKit write fast path", function()
  local SettingsKit, S, SchemaKit

  before_each(function()
    local _
    SettingsKit, _, _, _, S = TestEnv.NewPackage()
    SchemaKit = S
  end)
  after_each(TestEnv.Reset)

  ---The scalar fields the differential specs cover: every rule SchemaKit
  ---describes for a string, a number, a boolean and an enum, and the kinds the
  ---fast path leaves to SchemaKit.
  ---@return table<string, table> fields
  local function scalarFields()
    return {
      count = S.optional(S.number({ integer = true, min = -2, max = 10 })),
      ratio = S.optional(S.number({ min = 0, max = 1 })),
      amount = S.optional(S.number()),
      whole = S.optional(S.number({ integer = true })),
      label = S.optional(S.string({ min = 2, max = 5 })),
      code = S.optional(S.string({ pattern = "^%u%d$" })),
      point = S.optional(S.string({ oneOf = { "TOP", "BOTTOM" } })),
      text = S.optional(S.string()),
      flag = S.optional(S.boolean()),
      mode = S.optional(S.enum({ "a", 2, true })),
      odd = S.optional(S.custom(function(value)
        return type(value) == "number" and value % 2 == 1
      end, "an odd number")),
      either = S.optional(S.oneOf({ S.number({ min = 0 }), S.string({ max = 1 }) })),
      anything = S.optional(S.any()),
    }
  end

  ---Open a database whose profile holds the scalar fields at the top, inside
  ---a nested record and inside the entries of a keyed section.
  ---@return table db, table sealed the profile schema, sealed by the spec
  local function openDatabase()
    local profile = S.table({
      fields = (function()
        local fields = scalarFields()
        fields.frame = S.optional(S.table({ fields = scalarFields() }), {})
        fields.auras = S.optional(
          S.map({
            keys = S.number({ integer = true, min = 1 }),
            values = S.optional(S.table({ fields = scalarFields() }), {}),
            max = 4,
          }),
          {}
        )
        return fields
      end)(),
    })
    local db = SettingsKit:Open("MyAddonDB", { profile = profile })
    return db, SchemaKit:Seal(profile)
  end

  ---What SchemaKit says of writing `value` at `path` of the profile: the
  ---verdict of a full check of a table holding only that path.
  ---@param sealed table
  ---@param path any[]
  ---@param value any
  ---@return boolean
  local function schemaAccepts(sealed, path, value)
    local probe = {}
    local container = probe
    for index = 1, #path - 1 do
      local child = {}
      container[path[index]] = child
      container = child
    end
    container[path[#path]] = value
    return (sealed:Check(probe))
  end

  ---Write `value` through `view[key]` and return whether it was accepted and
  ---the message of a refusal, without its position.
  ---@param view table
  ---@param key any
  ---@param value any
  ---@return boolean ok, string|nil message
  local function tryWrite(view, key, value)
    local ok, failure = pcall(function()
      view[key] = value
    end)
    if ok then
      return true, nil
    end
    return false, (tostring(failure):gsub("^[^:]+:%d+: ", ""))
  end

  it("accepts and refuses every scalar write exactly as SchemaKit does", function()
    local db, sealed = openDatabase()
    local views = {
      { view = db.profile, path = {} },
      { view = db.profile.frame, path = { "frame" } },
      { view = db.profile.auras[3], path = { "auras", 3 } },
    }
    local values, count = candidateValues()
    for _, target in ipairs(views) do
      for name in pairs(scalarFields()) do
        -- Each field is written twice with every value, so the second
        -- round runs once the view has passed a full check (`verified`).
        for _ = 1, 2 do
          for index = 1, count do
            local value = values[index]
            local path = { unpack(target.path) }
            path[#path + 1] = name
            local expected = schemaAccepts(sealed, path, value)
            local validated, validateMessage = db:Validate("profile", path, value)
            local written, writeMessage = tryWrite(target.view, name, value)
            local label = table.concat(target.path, ".") .. "." .. name .. " = " .. show(value)
            assert.are.equal(expected, validated, "Validate of " .. label)
            assert.are.equal(expected, written, "write of " .. label)
            assert.are.equal(validateMessage, writeMessage, "message of " .. label)
          end
        end
      end
    end
  end)

  it("keeps SchemaKit's message for a refusal after the view was verified", function()
    local db = openDatabase()
    local frame = db.profile.frame
    frame.count = 3
    local ok, message = tryWrite(frame, "count", 1.5)
    assert.is_false(ok)
    assert.are.equal(
      "SettingsKit (MyAddonDB) profile.frame.count: expected integer, found fractional number",
      message
    )
    assert.are.equal(3, frame.count)
  end)

  it("follows SchemaKit's maxDepth lowered after a nested write was accepted", function()
    local db = openDatabase()
    local frame = db.profile.frame
    frame.count = 1

    S:SetLimits({ maxDepth = 1 })
    local ok, message = tryWrite(frame, "count", 2)
    assert.is_false(ok)
    assert.is_truthy(message:find("nested tables", 1, true))
    assert.is_false((db:Validate("profile", { "frame", "count" }, 2)))
    assert.are.equal(1, frame.count)
    -- A top-level write is one table deep and passes any maxDepth.
    db.profile.count = 4
    assert.are.equal(4, db.profile.count)

    S:SetLimits({ maxDepth = 16 })
    frame.count = 2
    assert.are.equal(2, frame.count)
  end)

  it("refuses every write through an entry whose key the key schema refuses", function()
    local db = openDatabase()
    local entry = db.profile.auras.bogus
    for _ = 1, 2 do
      local ok, message = tryWrite(entry, "flag", true)
      assert.is_false(ok)
      assert.are.equal(
        "SettingsKit (MyAddonDB) profile.auras.bogus: expected key integer, found string",
        message
      )
    end
    assert.is_nil(TestEnv.GetGlobal("MyAddonDB").profiles.Default.auras)
  end)

  it("refuses a write that would add an entry to a full section, however often", function()
    local db = openDatabase()
    local auras = db.profile.auras
    for key = 1, 4 do
      auras[key].flag = true
    end
    local fifth = auras[5]
    for _ = 1, 2 do
      local ok, message = tryWrite(fifth, "flag", true)
      assert.is_false(ok)
      assert.are.equal("SettingsKit (MyAddonDB) profile.auras: expected at most 4 entries", message)
    end
    -- Existing entries still take writes on the fast path.
    auras[2].flag = false
    assert.is_false(auras[2].flag)
  end)

  it("refuses writes through a view detached after it was verified", function()
    local db = openDatabase()
    db:SetProfile("Old")
    local frame = db.profile.frame
    frame.count = 1
    db:SetProfile("Default")
    db:DeleteProfile("Old")

    for _ = 1, 2 do
      local ok, message = tryWrite(frame, "count", 2)
      assert.is_false(ok)
      assert.are.equal(
        "SettingsKit (MyAddonDB) profile.frame belongs to a profile that was deleted or reset away",
        message
      )
    end
    assert.is_nil(frame.count)
    assert.is_nil(TestEnv.GetGlobal("MyAddonDB").profiles.Old)
  end)

  it("refuses a secret value and a secret key after the view was verified", function()
    local db = openDatabase()
    local frame = db.profile.frame
    frame.text = "ok"
    TestEnv.InstallSecretProbe()
    local secret = TestEnv.NewSecret()

    local ok, message = tryWrite(frame, "text", secret)
    assert.is_false(ok)
    assert.are.equal(
      "SettingsKit (MyAddonDB) profile.frame.text refused a secret value: saved variables never hold secret values",
      message
    )
    ok, message = tryWrite(frame, secret, "x")
    assert.is_false(ok)
    assert.are.equal(
      "SettingsKit (MyAddonDB) profile.frame refused a secret key: saved variables never hold secret values",
      message
    )
    assert.are.equal("ok", frame.text)
  end)

  it("refuses an undeclared field of a closed record and accepts a reset to nil", function()
    local db = openDatabase()
    local frame = db.profile.frame
    frame.count = 1
    local ok, message = tryWrite(frame, "typo", 1)
    assert.is_false(ok)
    assert.are.equal(
      "SettingsKit (MyAddonDB) profile.frame.typo: expected only declared fields, found undeclared field",
      message
    )
    frame.count = nil
    assert.is_nil(frame.count)
    frame.typo = nil
  end)

  it("writes a table value through the full check", function()
    local db = SettingsKit:Open("MyAddonDB", {
      profile = S.table({
        fields = {
          tags = S.optional(S.array({ of = S.string(), max = 2 })),
        },
      }),
    })
    db.profile.tags = { "a" }
    local ok, message = tryWrite(db.profile, "tags", { "a", "b", "c" })
    assert.is_false(ok)
    assert.are.equal(
      "SettingsKit (MyAddonDB) profile.tags: expected array of at most 2 elements, found table with more than 2 entries",
      message
    )
    assert.are.same({ "a" }, TestEnv.GetGlobal("MyAddonDB").profiles.Default.tags)
  end)
end)

describe("SettingsKit read kinds", function()
  local SettingsKit, S

  before_each(function()
    local _
    SettingsKit, _, _, _, S = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("reads the defaults a record's own default gives, over its field defaults", function()
    local db = SettingsKit:Open("MyAddonDB", {
      profile = S.table({
        fields = {
          frame = S.optional(
            S.table({
              fields = {
                x = S.optional(S.number(), 0),
                size = S.optional(S.table({ fields = { w = S.optional(S.number(), 1) } })),
                color = S.optional(S.array({ of = S.number() })),
              },
            }),
            { x = 5, size = { w = 7 }, color = { 1, 0, 0 } }
          ),
        },
      }),
    })
    local frame = db.profile.frame
    assert.are.equal(5, frame.x)
    -- `size` has no default of its own; the record's default gives it one.
    assert.are.equal("SettingsKit.View", getmetatable(frame.size))
    assert.are.equal(7, frame.size.w)
    assert.are.same({ 1, 0, 0 }, frame.color)
    assert.are.same(
      { frame = { color = { 1, 0, 0 } } },
      TestEnv.GetGlobal("MyAddonDB").profiles.Default
    )
  end)

  it("reads a saved value of every kind over its default, and nil for an undeclared key", function()
    TestEnv.SavedVariable("MyAddonDB", {
      profiles = {
        Default = {
          scale = 2,
          frame = { x = 3 },
          auras = { [7] = { shown = false } },
          legacy = "kept",
        },
      },
    })
    local db = SettingsKit:Open("MyAddonDB", {
      profile = S.table({
        fields = {
          scale = S.optional(S.number(), 1),
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
        },
        open = true,
      }),
    })
    local profile = db.profile
    assert.are.equal(2, profile.scale)
    assert.are.equal(3, profile.frame.x)
    assert.is_false(profile.auras[7].shown)
    assert.is_true(profile.auras[8].shown)
    assert.are.equal("kept", profile.legacy)
    assert.is_nil(profile.missing)
  end)

  it("reads a keyed section's scalar and table values and defaults", function()
    local db = SettingsKit:Open("MyAddonDB", {
      profile = S.table({
        fields = {
          counts = S.optional(
            S.map({ keys = S.string(), values = S.optional(S.number(), 0), max = 8 }),
            {
              fire = 3,
            }
          ),
          lists = S.optional(
            S.map({
              keys = S.string(),
              values = S.optional(S.array({ of = S.number() }), { 1 }),
              max = 8,
            }),
            {}
          ),
          plain = S.optional(
            S.map({ keys = S.string(), values = S.optional(S.number()), max = 8 })
          ),
        },
      }),
    })
    local profile = db.profile
    assert.are.equal(3, profile.counts.fire)
    assert.are.equal(0, profile.counts.frost)
    profile.counts.frost = 2
    assert.are.equal(2, profile.counts.frost)
    local copy = profile.lists.any
    assert.are.same({ 1 }, copy)
    copy[1] = 9
    assert.are.same({ 1 }, profile.lists.any)
    assert.is_nil(profile.plain)
  end)

  it("gives two databases opened with one schema the same answers, kept apart", function()
    local schema = {
      profile = S.table({
        fields = {
          scale = S.optional(S.number({ max = 2 }), 1),
          frame = S.optional(S.table({ fields = { x = S.optional(S.number(), 0) } }), {}),
        },
      }),
    }
    local first = SettingsKit:Open("FirstDB", schema)
    local second = SettingsKit:Open("SecondDB", schema)
    local changes = {}
    first:OnChange("profile", function(_, _, key)
      changes[#changes + 1] = "first " .. key
    end)
    second:OnChange("profile", function(_, _, key)
      changes[#changes + 1] = "second " .. key
    end)

    first.profile.scale = 2
    second.profile.frame.x = 4
    assert.are.equal(2, first.profile.scale)
    assert.are.equal(1, second.profile.scale)
    assert.are.equal(0, first.profile.frame.x)
    assert.are.equal(4, second.profile.frame.x)
    assert.are.same({ "first scale", "second x" }, changes)
    TestEnv.expectErrorContaining(
      "SettingsKit (SecondDB) profile.scale: expected number <= 2",
      function()
        second.profile.scale = 3
      end
    )
  end)

  it("builds views to the maxDepth in force when each database is opened", function()
    local schema = {
      profile = S.table({
        fields = {
          outer = S.optional(
            S.table({
              fields = {
                inner = S.optional(S.table({ fields = { x = S.optional(S.number(), 1) } }), {}),
              },
            }),
            {}
          ),
        },
      }),
    }
    local deep = SettingsKit:Open("DeepDB", schema)
    S:SetLimits({ maxDepth = 2 })
    local shallow = SettingsKit:Open("ShallowDB", schema)
    S:SetLimits({ maxDepth = 16 })

    assert.are.equal("SettingsKit.View", getmetatable(deep.profile.outer.inner))
    assert.are.equal(1, deep.profile.outer.inner.x)
    -- Below the depth in force at its Open, a record reads as a plain value:
    -- its default, which is not filled below that depth either.
    assert.are.equal(nil, getmetatable(shallow.profile.outer.inner))
    assert.are.same({}, shallow.profile.outer.inner)
  end)
end)

describe("SettingsKit signals created on demand", function()
  local SettingsKit, S

  before_each(function()
    local _
    SettingsKit, _, _, _, S = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  local function schemaFor()
    return { profile = S.table({ fields = { scale = S.optional(S.number(), 1) } }) }
  end

  it("delivers to a change listener connected after earlier writes", function()
    local db = SettingsKit:Open("MyAddonDB", schemaFor())
    db.profile.scale = 2
    local seen = {}
    db:OnChange("profile", function(_, scope, key, value, path)
      seen[#seen + 1] = { scope, key, value, path }
    end)
    db.profile.scale = 3
    assert.are.same({ { "profile", "scale", 3, "" } }, seen)
  end)

  it("delivers to profile listeners connected after earlier profile changes", function()
    local db = SettingsKit:Open("MyAddonDB", schemaFor())
    db:SetProfile("One")
    db:SetProfile("Default")
    local seen = {}
    db:OnProfileChanged(function(_, name, previous)
      seen[#seen + 1] = "changed " .. name .. " from " .. previous
    end)
    db:OnProfileCopied(function(_, from, name)
      seen[#seen + 1] = "copied " .. from .. " to " .. name
    end)
    db:OnProfileReset(function(_, name)
      seen[#seen + 1] = "reset " .. name
    end)
    db:OnProfileDeleted(function(_, name)
      seen[#seen + 1] = "deleted " .. name
    end)

    db:CopyProfile("One")
    db:ResetProfile()
    db:DeleteProfile("One")
    db:SetProfile("Two")
    assert.are.same({
      "copied One to Default",
      "reset Default",
      "deleted One",
      "changed Two from Default",
    }, seen)
  end)

  it("stops delivering after a connection is disconnected", function()
    local db = SettingsKit:Open("MyAddonDB", schemaFor())
    local calls = 0
    local connection = db:OnChange("profile", function()
      calls = calls + 1
    end)
    db.profile.scale = 2
    connection:Disconnect()
    db.profile.scale = 3
    assert.are.equal(1, calls)
  end)
end)

describe("SettingsKit shared logout compaction", function()
  local SettingsKit, S

  before_each(function()
    local _
    SettingsKit, _, _, _, S = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  local function schemaFor()
    return {
      profile = S.table({
        fields = {
          scale = S.optional(S.number(), 1),
          name = S.optional(S.string(), "none"),
        },
      }),
    }
  end

  it("compacts every database at logout, each on its own", function()
    local first = SettingsKit:Open("FirstDB", schemaFor())
    local second = SettingsKit:Open("SecondDB", schemaFor())
    local third = SettingsKit:Open("ThirdDB", schemaFor())
    first.profile.scale = 1
    second.profile.name = "boom"
    second.profile.scale = 1
    third.profile.scale = 1
    third.profile.name = "kept"
    TestEnv.TakeReportedErrors()

    -- The probe raises for one value only, so only SecondDB's compaction
    -- fails; the others are still compacted, and the failure is reported
    -- once.
    TestEnv.SetGlobal("issecretvalue", function(value)
      if value == "boom" then
        error("probe failed", 0)
      end
      return false
    end)
    TestEnv.Logout()

    local reported = TestEnv.TakeReportedErrors()
    assert.are.equal(1, #reported)
    assert.are.equal("probe failed", reported[1].value)
    assert.are.same({}, TestEnv.GetGlobal("FirstDB").profiles.Default)
    assert.are.same({ name = "kept" }, TestEnv.GetGlobal("ThirdDB").profiles.Default)
  end)

  it("compacts a database opened after an earlier logout listener was connected", function()
    SettingsKit:Open("FirstDB", schemaFor())
    local later = SettingsKit:Open("LaterDB", schemaFor())
    later.profile.scale = 1
    TestEnv.Logout()
    assert.are.same({}, TestEnv.GetGlobal("LaterDB").profiles.Default)
  end)

  it("skips a read-only database and compacts the rest", function()
    TestEnv.SavedVariable("NewerDB", { version = 9, profiles = { Default = { scale = 1 } } })
    local newer = SettingsKit:Open("NewerDB", schemaFor(), { version = 2 })
    local current = SettingsKit:Open("CurrentDB", schemaFor())
    current.profile.scale = 1
    assert.is_true(newer:IsReadOnly())
    TestEnv.Logout()
    assert.are.same({ scale = 1 }, TestEnv.GetGlobal("NewerDB").profiles.Default)
    assert.are.same({}, TestEnv.GetGlobal("CurrentDB").profiles.Default)
  end)
end)
