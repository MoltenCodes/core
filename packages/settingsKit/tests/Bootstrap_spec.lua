local TestEnv = require("SettingsKitTestEnv")

describe("SettingsKit bootstrap", function()
  after_each(TestEnv.Reset)

  local function schemaFor(S)
    return { profile = S.table({ fields = { scale = S.optional(S.number({ max = 2 }), 1) } }) }
  end

  it("returns the same facade on duplicate embedded load and keeps databases", function()
    local SettingsKit, _, _, _, S = TestEnv.NewPackage()
    local db = SettingsKit:Open("MyAddonDB", schemaFor(S))

    local reloaded = TestEnv.ReloadPackage()
    assert.are.equal(SettingsKit, reloaded)
    assert.are.equal(db, reloaded:Open("MyAddonDB"))
  end)

  it("publishes through Registry", function()
    local SettingsKit, Registry = TestEnv.NewPackage()
    local registered, revision = Registry:Get("settingsKit", 1)
    assert.are.equal(SettingsKit, registered)
    assert.are.equal(SettingsKit.REVISION, revision)
    assert.are.equal(64, SettingsKit.MAX_PROFILE_NAME_LENGTH)
  end)

  it("does not reinterpret private state owned by a newer compatible revision", function()
    local SettingsKit, Registry = TestEnv.NewPackage()
    local shippedRevision = SettingsKit.REVISION
    local upgraded, previous = Registry:Register("settingsKit", 1, 99)
    assert.are.equal(SettingsKit, upgraded)
    assert.are.equal(shippedRevision, previous)

    rawset(SettingsKit, "REVISION", 99)
    rawset(SettingsKit, "_state", { schema = 999 })
    package.loaded["SettingsKit"] = nil

    local reloaded = require("SettingsKit")
    assert.are.equal(SettingsKit, reloaded)
    assert.are.equal(99, reloaded.REVISION)
  end)

  it("upgrades in place and keeps databases, views, listeners and the logout compaction", function()
    local SettingsKit, _, _, _, S = TestEnv.NewPackage()
    local prototype = SettingsKit.Database
    local db = SettingsKit:Open("MyAddonDB", schemaFor(S))
    local profile = db.profile
    local changes = 0
    db:OnChange("profile", function()
      changes = changes + 1
    end)
    local switched = 0
    db:OnProfileChanged(function()
      switched = switched + 1
    end)

    local nextRevision = SettingsKit.REVISION + 1
    local upgraded = TestEnv.LoadRevision(nextRevision)
    assert.are.equal(SettingsKit, upgraded)
    assert.are.equal(nextRevision, upgraded.REVISION)
    assert.are.equal(prototype, upgraded.Database)
    assert.are.equal(db, upgraded:Open("MyAddonDB"))
    assert.are.equal(profile, db.profile)

    assert.are.equal(1, profile.scale)
    profile.scale = 1
    assert.are.equal(1, changes)
    TestEnv.expectErrorContaining("expected number <= 2", function()
      profile.scale = 3
    end)
    db:SetProfile("Other")
    assert.are.equal(1, switched)

    db:SetProfile("Default")
    TestEnv.Logout()
    assert.are.same({}, TestEnv.GetGlobal("MyAddonDB").profiles.Default)
  end)

  it("repairs the defaults revision 1 gave entry views of a section without a default", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    require("Registry")
    require("SignalKit")
    require("EventKit")
    local S = require("SchemaKit")
    local previous = TestEnv.LoadRevision(1)
    TestEnv.SetPlayer()
    assert.are.equal(1, previous.REVISION)

    TestEnv.SavedVariable("MyAddonDB", {
      profiles = { Default = { auras = { [5] = { glow = {} } } } },
    })
    local db = previous:Open("MyAddonDB", {
      profile = S.table({
        fields = {
          auras = S.optional(S.map({
            keys = S.number(),
            max = 8,
            values = S.optional(
              S.table({
                fields = {
                  shown = S.optional(S.boolean(), true),
                  glow = S.optional(S.table({ fields = { alpha = S.optional(S.number(), 0.5) } })),
                },
              }),
              { shown = true }
            ),
          })),
        },
      }),
    })
    local entry = db.profile.auras[5]
    local glow = entry.glow

    -- Leave the two nodes as revision 1 built them: `false` handed down
    -- from the section, which was declared without a default. Revision 6
    -- decides each field's read from the defaults when a view is built, so
    -- those read kinds are emptied too: every field then reads `nil`, as
    -- revision 1 read it.
    local views = rawget(previous, "_state").views
    for _, view in ipairs({ entry, glow }) do
      local node = rawget(views, view)
      node.defaults = false
      node.kinds = {}
    end
    assert.is_nil(entry.shown)
    assert.is_nil(glow.alpha)

    local upgraded = TestEnv.ReloadPackage()
    assert.are.equal(previous, upgraded)
    assert.is_true(upgraded.REVISION > 1)
    assert.are.equal(entry, db.profile.auras[5])
    assert.are.equal(true, entry.shown)
    assert.are.equal(0.5, glow.alpha)
  end)

  it("upgrades revision 2 in place and applies the secret refusals at once", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    require("Registry")
    require("SignalKit")
    require("EventKit")
    local S = require("SchemaKit")
    local previous = TestEnv.LoadRevision(2)
    TestEnv.SetPlayer()
    assert.are.equal(2, previous.REVISION)
    local state = rawget(previous, "_state")
    local prototype = previous.Database
    local unbounded = previous.UNBOUNDED
    previous:SetLimits({ pathKeyLimit = 48 })
    local db = previous:Open("MyAddonDB", schemaFor(S))
    local profile = db.profile
    local changes = 0
    db:OnChange("profile", function()
      changes = changes + 1
    end)

    local upgraded = TestEnv.ReloadPackage()
    assert.are.equal(previous, upgraded)
    assert.is_true(upgraded.REVISION > 2)
    assert.are.equal(state, rawget(upgraded, "_state"))
    assert.are.equal(upgraded.REVISION, state.runtimeRevision)
    assert.are.equal(prototype, upgraded.Database)
    assert.are.equal(unbounded, upgraded.UNBOUNDED)
    assert.are.equal(48, upgraded:GetLimits().pathKeyLimit)
    assert.are.equal(db, upgraded:Open("MyAddonDB"))
    assert.are.equal(profile, db.profile)
    profile.scale = 2
    assert.are.equal(1, changes)
    assert.are.equal(2, profile.scale)

    TestEnv.InstallSecretProbe()
    TestEnv.expectErrorContaining(
      "SettingsKit:SetLimits limits.pathKeyLimit must not be a secret value",
      function()
        upgraded:SetLimits({ pathKeyLimit = TestEnv.NewSecret() })
      end
    )
  end)

  it("upgrades revision 3 in place and refuses secret scope names and keys at once", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    require("Registry")
    require("SignalKit")
    require("EventKit")
    local S = require("SchemaKit")
    local previous = TestEnv.LoadRevision(3)
    TestEnv.SetPlayer()
    assert.are.equal(3, previous.REVISION)
    local state = rawget(previous, "_state")
    local db = previous:Open("MyAddonDB", schemaFor(S))
    local profile = db.profile
    local changes = 0
    db:OnChange("profile", function()
      changes = changes + 1
    end)
    -- Revision 3 indexed the prototype with any key; its `__index` stays
    -- on the shared metatable until the newer copy replaces it.
    local metatable = getmetatable(db)
    local function legacyIndex() end
    rawset(metatable, "__index", legacyIndex)

    local upgraded = TestEnv.ReloadPackage()
    assert.are.equal(previous, upgraded)
    assert.is_true(upgraded.REVISION > 3)
    assert.are.equal(state, rawget(upgraded, "_state"))
    assert.are.equal(db, upgraded:Open("MyAddonDB"))
    assert.are.equal(profile, db.profile)
    assert.are_not.equal(legacyIndex, rawget(metatable, "__index"))
    profile.scale = 2
    assert.are.equal(1, changes)

    TestEnv.InstallSecretProbe()
    local secret = TestEnv.NewSecret()
    TestEnv.expectErrorContaining(
      "SettingsKit.Database:OnChange scope must not be a secret value",
      function()
        db:OnChange(secret, function() end)
      end
    )
    TestEnv.expectErrorContaining(
      "SettingsKit databases cannot be read with a secret key",
      function()
        return db[secret]
      end
    )
  end)

  it("upgrades revision 4 in place: its databases stay writable and gain IsReadOnly", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    require("Registry")
    require("SignalKit")
    require("EventKit")
    local S = require("SchemaKit")
    local previous = TestEnv.LoadRevision(4)
    TestEnv.SetPlayer()
    local state = rawget(previous, "_state")
    TestEnv.SavedVariable("NewerDB", { version = 9, profiles = { Default = { scale = 2 } } })
    local current = previous:Open("CurrentDB", schemaFor(S), { version = 2 })
    local newer = previous:Open("NewerDB", schemaFor(S), { version = 2 })
    local profile = newer.profile

    -- Leave both databases, and the prototype, as revision 4 built them:
    -- layout 1, without the read-only fields, and no `IsReadOnly` method.
    for _, db in ipairs({ current, newer }) do
      rawset(db, "_layout", 1)
      rawset(db, "_readOnly", nil)
      rawset(db, "_newerVersion", nil)
    end
    rawset(previous.Database, "IsReadOnly", nil)

    local upgraded = TestEnv.ReloadPackage()
    assert.are.equal(previous, upgraded)
    assert.is_true(upgraded.REVISION > 4)
    assert.are.equal(state, rawget(upgraded, "_state"))
    assert.are.equal(newer, upgraded:Open("NewerDB"))
    assert.are.equal(profile, newer.profile)
    for _, db in ipairs({ current, newer }) do
      assert.are.equal(4, rawget(db, "_layout"))
      assert.is_false(db:IsReadOnly())
    end
    assert.is_false(rawget(current, "_newerVersion"))
    assert.are.equal(9, rawget(newer, "_newerVersion"))

    -- Opened writable under revision 4, the database stays writable, and
    -- ResetDatabase keeps the newer stored version.
    profile.scale = 1.5
    assert.are.equal(1.5, TestEnv.GetGlobal("NewerDB").profiles.Default.scale)
    newer:ResetDatabase()
    assert.are.equal(9, TestEnv.GetGlobal("NewerDB").version)
    current:ResetDatabase()
    assert.are.equal(2, TestEnv.GetGlobal("CurrentDB").version)

    -- A database opened after the upgrade follows the new contract.
    TestEnv.SavedVariable("LaterDB", { version = 9 })
    assert.is_true(upgraded:Open("LaterDB", schemaFor(S), { version = 2 }):IsReadOnly())
  end)

  it("upgrades revision 5 in place: its views, plans, signals and logout keep working", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    require("Registry")
    local SignalKit = require("SignalKit")
    local S = require("SchemaKit")
    -- Loaded without EventKit, so the copy connects no logout listener; the
    -- one revision 5 connected per database is added by hand below.
    local previous = TestEnv.LoadRevision(5)
    TestEnv.SetPlayer()
    local state = rawget(previous, "_state")
    local views = state.views
    local db = previous:Open("MyAddonDB", {
      profile = S.table({
        fields = {
          scale = S.optional(S.number({ max = 2 }), 1),
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
      }),
    })
    local profile, frame, aura = db.profile, db.profile.frame, db.profile.auras[5]
    local EventKit = require("EventKit")
    EventKit:Connect("PLAYER_LOGOUT", function()
      rawget(state.dispatch, "compactOnLogout")(db)
    end)

    ---Put a plan back in the shape revision 5 compiled: no layout, read kinds,
    ---fast checks or default kind.
    local function toPlanLayout1(plan)
      plan.layout, plan.ownKinds, plan.fastChecks, plan.defaultKind = nil, nil, nil, nil
      for _, field in pairs(plan.fields or {}) do
        toPlanLayout1(field)
      end
      if plan.values then
        toPlanLayout1(plan.values)
      end
    end
    toPlanLayout1(rawget(db, "_scopes").profile.plan)

    -- Every node as revision 5 built it: layout 1 with `db`, `scope`,
    -- `displayPath`, `sectionName`, `probeSet` and `entries` on every node,
    -- and none of what revision 6 added. The display path is left wrong on
    -- purpose: revision 6 must derive it, never read it.
    for _, node in pairs(views) do
      local root = node.root
      -- Revision 5 named the kind of view; revision 7 derives it from `kinds`.
      node.kind = node.kinds ~= nil and "record" or "map"
      node.layout = 1
      node.db, node.scope = root.db, root.scope
      node.displayPath = "legacy"
      node.sectionName = root.scope.sectionName
      node.dead = node.generation == false
      node.generation, node.cache = nil, nil
      node.sectionKey = node.sectionKey or false
      node.probeSet, node.probeKey = false, false
      if node.kind == "map" then
        node.entries, node.children = node.children, false
      else
        node.entries = false
      end
      node.depth, node.pathKeys, node.kinds = nil, nil, nil
      node.ownEntries, node.valuesProxied, node.verified = nil, nil, nil
    end
    -- An interrupted write left a key in the frame's probe.
    local frameNode = rawget(views, frame)
    frameNode.probe.stale = 1
    frameNode.probeSet, frameNode.probeKey = true, "stale"
    -- The database, its scopes and the package state as revision 5 left them.
    rawset(db, "_layout", 2)
    rawset(db, "_unavailable", {
      char = "SettingsKit (MyAddonDB) db.char is not declared; pass schema.char to SettingsKit:Open",
    })
    rawget(db, "_scopes").profile.signal = SignalKit:New()
    rawset(db, "_signals", {
      profileChanged = SignalKit:New(),
      profileCopied = SignalKit:New(),
      profileReset = SignalKit:New(),
      profileDeleted = SignalKit:New(),
    })
    state.logoutDatabases, state.logoutConnected = nil, nil
    local changes, switched = {}, 0
    rawget(db, "_scopes").profile.signal:Connect(function(_, _, key, value, path)
      changes[#changes + 1] = { key, value, path }
    end)
    rawget(db, "_signals").profileChanged:Connect(function()
      switched = switched + 1
    end)

    local upgraded = TestEnv.ReloadPackage()
    assert.are.equal(previous, upgraded)
    assert.is_true(upgraded.REVISION > 5)
    assert.are.equal(state, rawget(upgraded, "_state"))
    assert.are.equal(db, upgraded:Open("MyAddonDB"))
    assert.are.equal(4, rawget(db, "_layout"))
    assert.is_nil(rawget(db, "_unavailable"))
    assert.are.equal(profile, db.profile)
    assert.are.equal(frame, profile.frame)
    assert.are.equal(aura, profile.auras[5])
    for _, node in pairs(views) do
      assert.are.equal(3, node.layout)
      assert.is_nil(node.displayPath)
      assert.is_nil(node.probeSet)
      assert.is_nil(node.entries)
    end

    -- Reads, on the paths revision 6 answers from its read kinds.
    assert.are.equal(1, profile.scale)
    assert.are.equal(0, frame.x)
    assert.is_true(aura.shown)
    assert.is_true(profile.auras[6].shown)

    -- Writes, through the full check and then the fast path, with the
    -- listener connected before the upgrade.
    for _, value in ipairs({ 1.5, 2 }) do
      profile.scale = value
      frame.x = value
    end
    aura.shown = false
    assert.are.same({ x = 2 }, TestEnv.GetGlobal("MyAddonDB").profiles.Default.frame)
    assert.is_nil(frameNode.probe.stale)
    assert.are.same({
      { "scale", 1.5, "" },
      { "x", 1.5, "frame" },
      { "scale", 2, "" },
      { "x", 2, "frame" },
      { "shown", false, "auras[5]" },
    }, changes)
    TestEnv.expectErrorContaining(
      "SettingsKit (MyAddonDB) profile.frame.x: expected number, found string",
      function()
        frame.x = "far"
      end
    )
    assert.are.same({ true, nil }, { db:Validate("profile", { "frame", "x" }, 3) })
    TestEnv.expectErrorContaining(
      "SettingsKit (MyAddonDB) db.char is not declared; pass schema.char to SettingsKit:Open",
      function()
        return db.char
      end
    )
    db:SetProfile("Other")
    db:SetProfile("Default")
    assert.are.equal(2, switched)

    -- A database opened after the upgrade joins the one shared listener; the
    -- older one keeps its own. Each is compacted once: the raising probe
    -- reports one failure per compaction.
    local later = upgraded:Open("LaterDB", {
      profile = S.table({ fields = { scale = S.optional(S.number(), 1) } }),
    })
    later.profile.scale = 1
    TestEnv.TakeReportedErrors()
    TestEnv.SetGlobal("issecretvalue", function()
      error("probe failed", 0)
    end)
    TestEnv.Logout()
    assert.are.equal(2, #TestEnv.TakeReportedErrors())
  end)

  it("loads without EventKit", function()
    local SettingsKit, Registry = TestEnv.NewPackageWithoutEventKit()
    assert.are.equal(SettingsKit, Registry:Get("settingsKit", 1))
    assert.are.equal("absent", select(2, Registry:Find("eventKit", 1)))
  end)

  it("requires Registry", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    local ok, value = pcall(require, "SettingsKit")
    assert.is_false(ok)
    assert.is_true(tostring(value):find("Registry API 2", 1, true) ~= nil)
  end)

  it("requires SchemaKit", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    require("Registry")
    require("SignalKit")
    local ok, value = pcall(TestEnv.requireAfterFailedLoad, "SettingsKit")
    assert.is_false(ok)
    assert.is_true(tostring(value):find("requires SchemaKit API 1", 1, true) ~= nil)
  end)

  it("requires SignalKit", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    require("Registry")
    require("SchemaKit")
    local ok, value = pcall(TestEnv.requireAfterFailedLoad, "SettingsKit")
    assert.is_false(ok)
    assert.is_true(tostring(value):find("requires SignalKit API 1", 1, true) ~= nil)
  end)

  it("refuses an incomplete facade left by an earlier failed load", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    local Registry = require("Registry")
    require("SignalKit")
    require("SchemaKit")
    Registry:Register("settingsKit", 1, 1)

    local ok, value = pcall(TestEnv.requireAfterFailedLoad, "SettingsKit")
    assert.is_false(ok)
    assert.is_true(tostring(value):find("MoltenCodes SettingsKit", 1, true) ~= nil)
  end)
end)
