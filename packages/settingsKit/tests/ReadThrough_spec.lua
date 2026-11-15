local TestEnv = require("SettingsKitTestEnv")

-- Revision 14: views read through chained tables, are built on first use, and
-- every mutation rebinds what it changed. See docs/INTERNALS.md,
-- "Read-through chains".

---@param S table SchemaKit
---@return table schema
local function schemaFor(S)
  return {
    global = S.table({ fields = { installs = S.optional(S.number(), 0) } }),
    profile = S.table({
      fields = {
        scale = S.optional(S.number({ min = 0.5, max = 2 }), 1),
        name = S.optional(S.string()),
        list = S.optional(S.array({ of = S.number() }), { 1, 2 }),
        frame = S.optional(S.table({ fields = { x = S.optional(S.number(), 0) } }), {}),
        extra = S.optional(S.table({ fields = { y = S.optional(S.number(), 7) } })),
        auras = S.optional(
          S.map({
            keys = S.number(),
            values = S.optional(
              S.table({
                fields = {
                  shown = S.optional(S.boolean(), true),
                  color = S.optional(S.array({ of = S.number() }), { 1, 1, 1 }),
                },
              }),
              {}
            ),
            max = 8,
          }),
          {}
        ),
        counts = S.optional(
          S.map({ keys = S.string(), values = S.optional(S.number(), 3), max = 8 }),
          { fixed = 9 }
        ),
      },
    }),
  }
end

---How many SettingsKit functions `action` calls.
---@param action fun()
---@return integer
local function settingsKitCalls(action)
  local count = 0
  -- The coverage run hooks lines; its hook is put back afterwards.
  local previousHook, previousMask, previousCount = debug.gethook()
  debug.sethook(function()
    local info = debug.getinfo(2, "S")
    if info and info.what == "Lua" and info.short_src:find("SettingsKit.lua", 1, true) then
      count = count + 1
    end
  end, "c")
  action()
  if previousHook then
    debug.sethook(previousHook, previousMask, previousCount)
  else
    debug.sethook(nil, "")
  end
  return count
end

describe("SettingsKit read-through views", function()
  local SettingsKit, S, db
  before_each(function()
    local _
    SettingsKit, _, _, _, S = TestEnv.NewPackage()
    db = SettingsKit:Open("MyAddonDB", schemaFor(S))
  end)
  after_each(TestEnv.Reset)

  local function saved()
    return TestEnv.GetGlobal("MyAddonDB")
  end

  it("answers defaults, saved values, nested fields and entries without a Lua call", function()
    local profile = db.profile
    profile.frame.x = 4
    local frame = profile.frame
    local aura = profile.auras[3]
    -- `list` has a plain-table default: until its first read stores the
    -- copy, the profile view reads through the function path (see the next
    -- spec), so it is read first here.
    local _ = profile.list
    _ = profile.scale + frame.x
    _ = aura.shown
    local scale, x, shown
    assert.are.equal(
      0,
      settingsKitCalls(function()
        scale = profile.scale
        x = profile.frame.x
        shown = profile.auras[3].shown
      end)
    )
    assert.are.same({ 1, 4, true }, { scale, x, shown })
  end)

  it("reads through the function path while a plain-table default is not stored", function()
    local profile = db.profile
    local calls = settingsKitCalls(function()
      local _ = profile.scale
    end)
    assert.is_true(calls > 0)
    assert.are.same({ 1, 2 }, profile.list)
    calls = settingsKitCalls(function()
      local _ = profile.scale
    end)
    assert.are.equal(0, calls)
  end)

  it("reads through a keyed section of plain values to its own entries and wildcard", function()
    local counts = db.profile.counts
    assert.are.equal(9, counts.fixed)
    assert.are.equal(3, counts.anything)
    assert.is_nil(counts[0 / 0])
    counts.anything = 5
    assert.are.equal(5, counts.anything)
    counts.anything = nil
    assert.are.equal(3, counts.anything)
  end)

  it("gives an open database's saved tables its defaults, which rawget does not see", function()
    db.profile.name = "Kept"
    local profileTable = saved().profiles.Default
    assert.are.equal(1, profileTable.scale)
    assert.is_nil(rawget(profileTable, "scale"))
    assert.are.equal("Kept", profileTable.name)
    local metatable = getmetatable(profileTable)
    assert.is_true(rawget(metatable, "__settingsKitSaved"))
    -- A plain-table default is never handed out by a raw read.
    assert.is_nil(profileTable.list)
  end)

  it("hands out a plain-table default as a stored copy, then reads it through the chain", function()
    local profile = db.profile
    local list = profile.list
    assert.are.same({ 1, 2 }, list)
    assert.are.equal(list, rawget(saved().profiles.Default, "list"))
    assert.are.equal(list, profile.list)
    profile.list = nil
    assert.is_nil(rawget(saved().profiles.Default, "list"))
    assert.are.same({ 1, 2 }, profile.list)
  end)

  it("hands out a fresh copy for an unsaved entry and stores nothing", function()
    local aura = db.profile.auras[5]
    assert.is_true(aura.shown)
    assert.are.same({ 1, 1, 1 }, aura.color)
    assert.are_not.equal(aura.color, aura.color)
    assert.is_nil(rawget(saved().profiles.Default, "auras"))
  end)

  it("reads an optional record field as nil until something is saved there", function()
    local profile = db.profile
    assert.is_nil(profile.extra)
    profile.extra = { y = 1 }
    assert.are.equal(1, profile.extra.y)
    profile.extra = nil
    assert.is_nil(profile.extra)
  end)

  it("reads a scalar stored where an optional record is declared as absent", function()
    TestEnv.Reset()
    SettingsKit, _, _, _, S = TestEnv.NewPackage()
    TestEnv.SavedVariable("MyAddonDB", { profiles = { Default = { extra = 5, frame = 6 } } })
    db = SettingsKit:Open("MyAddonDB", schemaFor(S))
    assert.is_nil(db.profile.extra)
    assert.are.equal(0, db.profile.frame.x)
  end)

  it("reads through the function path a saved table with a foreign metatable", function()
    TestEnv.Reset()
    SettingsKit, _, _, _, S = TestEnv.NewPackage()
    local foreign = setmetatable({ scale = 2 }, { __index = { name = "foreign" } })
    TestEnv.SavedVariable("MyAddonDB", { profiles = { Default = foreign } })
    db = SettingsKit:Open("MyAddonDB", schemaFor(S))
    assert.are.equal(2, db.profile.scale)
    assert.is_nil(db.profile.name)
    assert.are.equal(0, db.profile.frame.x)
  end)

  it("reads defaults through a detached view and refuses its writes", function()
    db:SetProfile("Doomed")
    local doomed = db.profile
    doomed.scale = 2
    db:SetProfile("Default")
    db:DeleteProfile("Doomed")
    assert.are.equal(1, doomed.scale)
    TestEnv.expectErrorContaining("deleted or reset away", function()
      doomed.scale = 1.5
    end)
  end)

  it("reads a read-only database's copies without storing them", function()
    TestEnv.Reset()
    SettingsKit, _, _, _, S = TestEnv.NewPackage()
    TestEnv.SavedVariable("MyAddonDB", { version = 9, profiles = { Default = { scale = 2 } } })
    db = SettingsKit:Open("MyAddonDB", schemaFor(S), { version = 2 })
    assert.is_true(db:IsReadOnly())
    assert.are.equal(2, db.profile.scale)
    assert.are.same({ 1, 2 }, db.profile.list)
    assert.is_nil(rawget(saved().profiles.Default, "list"))
    assert.is_nil(saved().profiles.Default.list)
  end)
end)

describe("SettingsKit chains after mutations", function()
  local SettingsKit, S, db
  before_each(function()
    local _
    SettingsKit, _, _, _, S = TestEnv.NewPackage()
    db = SettingsKit:Open("MyAddonDB", schemaFor(S))
  end)
  after_each(TestEnv.Reset)

  local function saved()
    return TestEnv.GetGlobal("MyAddonDB")
  end

  it("follows a table write, a nil write and the tables a nested write creates", function()
    local profile = db.profile
    local frame = profile.frame
    assert.are.equal(0, frame.x)
    frame.x = 3
    assert.are.equal(3, frame.x)
    profile.frame = { x = 8 }
    assert.are.equal(8, frame.x)
    profile.frame = nil
    assert.are.equal(0, frame.x)
    profile.auras[2].shown = false
    assert.is_false(profile.auras[2].shown)
    profile.auras[2] = { shown = true }
    assert.is_true(profile.auras[2].shown)
  end)

  it("follows SetProfile to a new profile and back to a root built before", function()
    local first = db.profile
    first.scale = 2
    db:SetProfile("Other")
    assert.are.equal(1, db.profile.scale)
    db.profile.scale = 1.5
    db:SetProfile("Default")
    assert.are.equal(first, db.profile)
    assert.are.equal(2, db.profile.scale)
  end)

  it("follows CopyProfile, ResetProfile and ResetDatabase", function()
    local profile = db.profile
    local frame = profile.frame
    frame.x = 5
    db:SetProfile("Other")
    local other = db.profile
    local otherFrame = other.frame
    db:CopyProfile("Default")
    assert.are.equal(5, otherFrame.x)
    db:ResetProfile()
    assert.are.equal(0, otherFrame.x)
    otherFrame.x = 6
    db.global.installs = 2
    db:ResetDatabase()
    assert.are.equal(0, db.global.installs)
    assert.are.equal(0, db.profile.frame.x)
    assert.are.equal(0, otherFrame.x)
  end)

  it("follows Compact, also when it raises halfway, and Resync after a direct edit", function()
    local profile = db.profile
    profile.frame = { x = 0 }
    profile.scale = 1
    assert.is_true(db:Compact() >= 1)
    assert.are.equal(0, profile.frame.x)
    assert.is_nil(rawget(saved().profiles.Default, "frame"))

    saved().profiles.Default.frame = { x = 11 }
    db:Resync()
    assert.are.equal(11, profile.frame.x)

    -- A probe that raises partway through the comparison of a value with its
    -- default: Compact raises, and the chains are still rebound.
    profile.frame.x = 0
    TestEnv.SetGlobal("issecretvalue", function()
      error("probe failed")
    end)
    assert.has_error(function()
      db:Compact()
    end)
    TestEnv.SetGlobal("issecretvalue", nil)
    assert.are.equal(
      rawget(rawget(saved().profiles.Default, "frame") or {}, "x") or 0,
      profile.frame.x
    )
  end)
end)

describe("SettingsKit views built on first use", function()
  after_each(TestEnv.Reset)

  it(
    "builds no node at Open, the root at its first read and each record field at its own",
    function()
      local SettingsKit, _, _, _, S = TestEnv.NewPackage()
      local views = rawget(SettingsKit, "_state").views
      local db = SettingsKit:Open("MyAddonDB", schemaFor(S))
      local profile = db.profile
      assert.are.equal("table", type(rawget(db, "profile")))
      assert.are.equal("SettingsKit.View", getmetatable(profile))
      assert.is_nil(rawget(views, profile))
      local _ = profile.scale
      assert.is_not_nil(rawget(views, profile))
      local frame = profile.frame
      assert.is_nil(rawget(views, frame))
      assert.are.equal(0, frame.x)
      assert.is_not_nil(rawget(views, frame))
      assert.are.equal(frame, profile.frame)
    end
  )

  it("serves Getter, Validate, Pairs, OnChange and Compact before any read", function()
    local SettingsKit, _, _, _, S = TestEnv.NewPackage()
    local db = SettingsKit:Open("MyAddonDB", schemaFor(S))
    assert.are.equal(0, db:Getter("global", "installs")())
    assert.are.equal(0, db:Getter(db.profile.frame, "x")())
    assert.is_true((db:Validate("profile", "frame.x", 3)))
    local keys = {}
    for key in db:Pairs(db.global) do
      keys[#keys + 1] = key
    end
    assert.are.same({ "installs" }, keys)
    assert.are.equal(0, db:Compact())
    local first = SettingsKit:Open("OtherDB", schemaFor(S))
    first.profile.frame.x = 2
    assert.are.equal(2, first.profile.frame.x)
  end)

  it("writes through a view never read before, at the writer's line", function()
    local SettingsKit, _, _, _, S = TestEnv.NewPackage()
    local db = SettingsKit:Open("MyAddonDB", schemaFor(S))
    local frame = db.profile.frame
    TestEnv.expectErrorContaining(
      "SettingsKit (MyAddonDB) profile.frame.x: expected number, found string",
      function()
        frame.x = "no"
      end
    )
    frame.x = 1
    assert.are.equal(1, frame.x)
  end)

  it("detaches a profile root that was never read", function()
    local SettingsKit, _, _, _, S = TestEnv.NewPackage()
    local db = SettingsKit:Open("MyAddonDB", schemaFor(S))
    db:SetProfile("Doomed")
    local doomed = db.profile
    db:SetProfile("Default")
    db:DeleteProfile("Doomed")
    assert.are.equal(1, doomed.scale)
    TestEnv.expectErrorContaining("deleted or reset away", function()
      doomed.scale = 2
    end)
  end)
end)

describe("SettingsKit fused writes and the depth limit", function()
  after_each(TestEnv.Reset)

  it("refuses on the fused path with the full path's message and level", function()
    local SettingsKit, _, _, _, S = TestEnv.NewPackage()
    local db = SettingsKit:Open("MyAddonDB", schemaFor(S))
    local frame = db.profile.frame
    frame.x = 1
    frame.x = 2
    TestEnv.expectErrorContaining(
      "SettingsKit (MyAddonDB) profile.frame.x: expected number, found boolean",
      function()
        frame.x = true
      end
    )
    db.profile.scale = 1.5
    TestEnv.expectErrorContaining(
      "SettingsKit (MyAddonDB) profile.scale: expected number <= 2, found larger number",
      function()
        db.profile.scale = 3
      end
    )
  end)

  it("follows SchemaKit's maxDepth through GetLimit, and without it", function()
    local SettingsKit, _, _, _, SchemaKit = TestEnv.NewPackage()
    local deep = SchemaKit.table({
      fields = {
        a = SchemaKit.optional(
          SchemaKit.table({
            fields = { b = SchemaKit.optional(SchemaKit.number(), 0) },
          }),
          {}
        ),
      },
    })
    local db = SettingsKit:Open("MyAddonDB", { profile = deep })
    local a = db.profile.a
    a.b = 1
    a.b = 2
    SchemaKit:SetLimits({ maxDepth = 1 })
    assert.has_error(function()
      a.b = 3
    end)
    SchemaKit:SetLimits({ maxDepth = 16 })
    a.b = 4
    assert.are.equal(4, a.b)

    -- A SchemaKit revision without GetLimit: the depth probes answer.
    local getLimit = rawget(SchemaKit, "GetLimit")
    rawset(SchemaKit, "GetLimit", nil)
    local other = SettingsKit:Open("OtherDB", { profile = deep })
    local otherA = other.profile.a
    otherA.b = 1
    otherA.b = 2
    SchemaKit:SetLimits({ maxDepth = 1 })
    assert.has_error(function()
      otherA.b = 3
    end)
    SchemaKit:SetLimits({ maxDepth = 16 })
    rawset(SchemaKit, "GetLimit", getLimit)
  end)
end)

describe("SettingsKit character key", function()
  after_each(TestEnv.Reset)

  it("keys the character by UnitNameUnmodified and answers GetCharacterKey", function()
    local SettingsKit, _, _, _, S = TestEnv.NewPackage()
    TestEnv.SetPlayer({ name = "Seeded", unmodified = "Tester" })
    assert.are.equal("Tester - Silvermoon", SettingsKit:GetCharacterKey())
    local db = SettingsKit:Open("MyAddonDB", {
      char = S.table({ fields = { seen = S.optional(S.boolean(), false) } }),
    })
    db.char.seen = true
    assert.is_true(rawget(TestEnv.GetGlobal("MyAddonDB").char["Tester - Silvermoon"], "seen"))
  end)

  it("falls back to UnitName when UnitNameUnmodified is absent, secret or empty", function()
    local SettingsKit = TestEnv.NewPackage()
    assert.are.equal("Tester - Silvermoon", SettingsKit:GetCharacterKey())
    TestEnv.SetPlayer({ unmodified = "" })
    assert.are.equal("Tester - Silvermoon", SettingsKit:GetCharacterKey())
    TestEnv.SetPlayer({ unmodified = 5 })
    assert.are.equal("Tester - Silvermoon", SettingsKit:GetCharacterKey())
    local secret = TestEnv.NewSecret()
    TestEnv.InstallSecretProbe()
    TestEnv.SetPlayer({ unmodified = secret })
    assert.are.equal("Tester - Silvermoon", SettingsKit:GetCharacterKey())
    TestEnv.SetPlayer({ name = false })
    assert.is_nil(SettingsKit:GetCharacterKey())
  end)

  it("refuses GetCharacterKey called with a dot", function()
    local SettingsKit = TestEnv.NewPackage()
    TestEnv.expectErrorContaining(
      "SettingsKit:GetCharacterKey must be called on the SettingsKit facade",
      function()
        SettingsKit.GetCharacterKey()
      end
    )
  end)
end)

describe("SettingsKit upgrade from revision 13", function()
  after_each(TestEnv.Reset)

  it("gives every live view of revision 13 its chain and keeps reads and writes", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    require("Registry")
    require("SignalKit")
    require("EventKit")
    local S = require("SchemaKit")
    local previous = TestEnv.LoadRevision(13)
    TestEnv.SetPlayer()
    local state = rawget(previous, "_state")
    local db = previous:Open("MyAddonDB", schemaFor(S))
    local profile, frame, aura = db.profile, db.profile.frame, db.profile.auras[4]
    frame.x = 2
    local _ = aura.shown
    _ = profile.list

    -- Revision 13's layout: every view built, all sharing the view
    -- metatable, entry caches on a plain weak metatable, and none of the
    -- chain tables.
    local VIEW_METATABLE = state.viewMetatable
    for proxy, node in pairs(state.views) do
      local metatable = state.chains[node]
      rawset(metatable, "__metatable", nil)
      setmetatable(proxy, VIEW_METATABLE)
      if node.kinds == nil then
        setmetatable(node.children, { __mode = "v" })
      end
    end
    for _, field in ipairs({
      "chains",
      "pendingRoots",
      "pendingChildren",
      "entryOwners",
      "planShapes",
      "pendingMetatable",
      "entryCacheMetatable",
    }) do
      state[field] = nil
    end

    local upgraded = TestEnv.ReloadPackage()
    assert.are.equal(previous, upgraded)
    assert.are.equal(14, upgraded.REVISION)
    assert.are.equal(db, upgraded:Open("MyAddonDB"))
    for proxy, node in pairs(state.views) do
      assert.are.equal("SettingsKit.View", getmetatable(proxy))
      assert.is_not_nil(state.chains[node])
    end
    assert.are.equal(2, frame.x)
    assert.is_true(aura.shown)
    assert.are.equal(
      0,
      settingsKitCalls(function()
        local _ = profile.scale
      end)
    )
    frame.x = 3
    assert.are.equal(3, profile.frame.x)
    aura.shown = false
    assert.is_false(profile.auras[4].shown)
    db:SetProfile("Other")
    assert.are.equal(0, db.profile.frame.x)
    assert.is_not_nil(rawget(state.views, db.profile))
  end)
end)
