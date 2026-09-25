local TestEnv = require("SettingsKitTestEnv")

-- Revision 7 caches the saved table behind each view and resolves it again
-- after every SettingsKit mutation that can change it (the database's
-- generation). These cases hold a view (and the views below it) across each
-- mutation path and check that it never answers from a table the mutation
-- replaced, emptied or removed, and that a write through it never lands in
-- such a table.

---@param S table SchemaKit
---@return table schema
local function schemaFor(S)
  return {
    global = S.table({ fields = { installs = S.optional(S.number(), 0) } }),
    profile = S.table({
      fields = {
        scale = S.optional(S.number({ min = 0.5, max = 2 }), 1),
        list = S.optional(S.array({ of = S.number() }), { 1, 2 }),
        frame = S.optional(
          S.table({
            fields = {
              x = S.optional(S.number(), 0),
              inner = S.optional(S.table({ fields = { y = S.optional(S.number(), 0) } }), {}),
            },
          }),
          {}
        ),
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
  }
end

describe("SettingsKit view caches", function()
  local SettingsKit, S
  before_each(function()
    local _
    SettingsKit, _, _, _, S = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  ---@return table db
  local function open()
    return SettingsKit:Open("MyAddonDB", schemaFor(S))
  end

  ---@return table raw
  local function saved()
    return TestEnv.GetGlobal("MyAddonDB")
  end

  describe("direct edits of the saved variable", function()
    it("shows a replaced table only after Resync", function()
      local db = open()
      local frame = db.profile.frame
      frame.x = 1
      assert.are.equal(1, frame.x)

      saved().profiles.Default.frame = { x = 7 }
      assert.are.equal(1, frame.x)
      db:Resync()
      assert.are.equal(7, frame.x)
      frame.x = 8
      assert.are.same({ x = 8 }, saved().profiles.Default.frame)
    end)

    it("shows a table added or removed directly only after Resync", function()
      local db = open()
      local frame = db.profile.frame
      assert.are.equal(0, frame.x)
      saved().profiles.Default.frame = { x = 3 }
      db:Resync()
      assert.are.equal(3, frame.x)

      saved().profiles.Default.frame = nil
      db:Resync()
      assert.are.equal(0, frame.x)
    end)

    it("shows a scalar edited inside a table a view already reads at once", function()
      local db = open()
      db.profile.scale = 1.5
      saved().profiles.Default.scale = 2
      assert.are.equal(2, db.profile.scale)
    end)

    it("resyncs a read-only database without writing to it", function()
      TestEnv.SavedVariable("MyAddonDB", { version = 9, profiles = { Default = { scale = 2 } } })
      local db = SettingsKit:Open("MyAddonDB", schemaFor(S), { version = 2 })
      assert.is_true(db:IsReadOnly())
      assert.are.equal(2, db.profile.scale)
      assert.are.equal(0, db.profile.frame.x)

      saved().profiles.Default = { scale = 1.5, frame = { x = 4 } }
      db:Resync()
      assert.are.equal(1.5, db.profile.scale)
      assert.are.equal(4, db.profile.frame.x)
      assert.are.same(
        { version = 9, profiles = { Default = { scale = 1.5, frame = { x = 4 } } } },
        saved()
      )
      TestEnv.expectErrorContaining("is read-only", function()
        db.profile.scale = 1
      end)
    end)

    it("reads a saved table carrying a metatable without invoking it", function()
      local trap = function()
        error("metamethod invoked", 0)
      end
      TestEnv.SavedVariable("MyAddonDB", {
        profiles = { Default = setmetatable({ scale = 1.5 }, { __index = trap }) },
      })
      local db = open()
      local profile = db.profile
      for _ = 1, 3 do
        assert.are.equal(1.5, profile.scale)
        assert.is_nil(profile.undeclared)
        assert.are.equal(0, profile.frame.x)
      end
      local getter = db:Getter("profile", "undeclared")
      assert.is_nil(getter())
      profile.scale = 2
      assert.are.equal(2, profile.scale)
      assert.are.equal(2, rawget(saved().profiles.Default, "scale"))
    end)

    it("rejects Resync on anything but a database", function()
      local db = open()
      TestEnv.expectErrorContaining("must be called on a SettingsKit database", function()
        db.Resync({})
      end)
    end)
  end)

  describe("every SettingsKit mutation", function()
    it("follows a table written over the one a view read", function()
      local db = open()
      local frame, inner = db.profile.frame, db.profile.frame.inner
      frame.x = 1
      inner.y = 2
      assert.are.equal(1, frame.x)
      assert.are.equal(2, inner.y)

      db.profile.frame = { x = 3, inner = { y = 4 } }
      assert.are.equal(3, frame.x)
      assert.are.equal(4, inner.y)
      inner.y = 5
      assert.are.equal(5, saved().profiles.Default.frame.inner.y)
    end)

    it("follows a table reset to its default by writing nil", function()
      local db = open()
      local frame = db.profile.frame
      frame.x = 1
      db.profile.frame = nil
      assert.are.equal(0, frame.x)
      frame.x = 6
      assert.are.same({ x = 6 }, saved().profiles.Default.frame)
    end)

    it("follows keyed-section entries created, replaced and removed", function()
      local db = open()
      local aura = db.profile.auras[5]
      assert.is_true(aura.shown)
      aura.shown = false
      assert.is_false(aura.shown)
      assert.are.same({ [5] = { shown = false } }, saved().profiles.Default.auras)

      db.profile.auras[5] = { shown = true }
      assert.is_true(aura.shown)
      aura.shown = false
      assert.are.same({ [5] = { shown = false } }, saved().profiles.Default.auras)

      db.profile.auras[5] = nil
      assert.is_true(aura.shown)
      aura.shown = false
      assert.is_false(saved().profiles.Default.auras[5].shown)
    end)

    it("follows a corrupted scalar replaced by the next write", function()
      TestEnv.SavedVariable("MyAddonDB", { profiles = { Default = { frame = 5 } } })
      local db = open()
      local frame = db.profile.frame
      assert.are.equal(0, frame.x)
      frame.x = 2
      assert.are.equal(2, frame.x)
      assert.are.same({ x = 2 }, saved().profiles.Default.frame)
    end)

    it("follows the tables a first read of a plain-table default creates", function()
      local db = open()
      local frame = db.profile.frame
      assert.are.equal(0, frame.x)
      assert.are.same({ 1, 2 }, db.profile.list)
      assert.is_nil(saved().profiles.Default.frame)
      frame.x = 3
      assert.are.same({ 1, 2 }, saved().profiles.Default.list)
      assert.are.same({ x = 3 }, saved().profiles.Default.frame)
    end)

    it("follows SetProfile: each profile's views keep their own tables", function()
      local db = open()
      local defaultProfile, defaultFrame = db.profile, db.profile.frame
      defaultFrame.x = 1
      db:SetProfile("Other")
      local otherFrame = db.profile.frame
      assert.are.equal(0, otherFrame.x)
      otherFrame.x = 2
      assert.are.equal(1, defaultFrame.x)
      assert.are.equal(1, defaultProfile.frame.x)
      db:SetProfile("Default")
      assert.are.equal(1, db.profile.frame.x)
      assert.are.equal(2, otherFrame.x)
      assert.are.same({ x = 2 }, saved().profiles.Other.frame)
    end)

    it("follows CopyProfile", function()
      local db = open()
      db:SetProfile("Source")
      db.profile.frame.x = 9
      db.profile.auras[3].shown = false
      db:SetProfile("Default")
      local frame, aura = db.profile.frame, db.profile.auras[3]
      frame.x = 1
      assert.is_true(aura.shown)

      db:CopyProfile("Source")
      assert.are.equal(9, frame.x)
      assert.is_false(aura.shown)
      frame.x = 4
      assert.are.equal(4, saved().profiles.Default.frame.x)
      assert.are.equal(9, saved().profiles.Source.frame.x)
    end)

    it("follows ResetProfile", function()
      local db = open()
      local frame = db.profile.frame
      frame.x = 1
      db.profile.scale = 2
      assert.are.equal(1, frame.x)
      db:ResetProfile()
      assert.are.equal(0, frame.x)
      assert.are.equal(1, db.profile.scale)
      frame.x = 5
      assert.are.same({ frame = { x = 5 } }, saved().profiles.Default)
    end)

    it("detaches the views of a deleted profile, nested ones included", function()
      local db = open()
      db:SetProfile("Doomed")
      local doomed, doomedFrame = db.profile, db.profile.frame
      doomedFrame.x = 3
      db.profile.scale = 2
      db:SetProfile("Default")
      assert.are.equal(3, doomedFrame.x)

      db:DeleteProfile("Doomed")
      assert.are.equal(1, doomed.scale)
      assert.are.equal(0, doomedFrame.x)
      TestEnv.expectErrorContaining("deleted or reset away", function()
        doomedFrame.x = 1
      end)
      assert.is_nil(saved().profiles.Doomed)
    end)

    it("follows ResetDatabase in every scope", function()
      local db = open()
      local global, profile, frame = db.global, db.profile, db.profile.frame
      global.installs = 4
      frame.x = 2
      assert.are.equal(4, global.installs)

      db:ResetDatabase()
      assert.are.equal(0, global.installs)
      assert.are.equal(0, frame.x)
      assert.are.equal(1, profile.scale)
      global.installs = 1
      assert.are.same({ installs = 1 }, saved().global)
      db.profile.frame.x = 7
      assert.are.same({ frame = { x = 7 } }, saved().profiles.Default)
    end)

    it("follows Compact: a write after it lands in the saved variable", function()
      local db = open()
      local frame, inner = db.profile.frame, db.profile.frame.inner
      frame.x = 0
      inner.y = 0
      assert.are.equal(0, inner.y)

      db:Compact()
      assert.is_nil(saved().profiles.Default.frame)
      inner.y = 3
      assert.are.same({ inner = { y = 3 } }, saved().profiles.Default.frame)
      assert.are.equal(3, inner.y)
    end)

    it("follows the logout compaction", function()
      local db = open()
      local frame = db.profile.frame
      frame.x = 0
      assert.are.equal(0, frame.x)
      TestEnv.Logout()
      assert.is_nil(saved().profiles.Default.frame)
      frame.x = 2
      assert.are.same({ x = 2 }, saved().profiles.Default.frame)
    end)

    it("reads and writes what a migration committed before its views existed", function()
      TestEnv.SavedVariable("MyAddonDB", { version = 1, profiles = { Default = { legacy = 3 } } })
      local db = SettingsKit:Open("MyAddonDB", schemaFor(S), {
        version = 2,
        migrations = {
          [2] = function(raw)
            raw.profiles.Default.frame = { x = raw.profiles.Default.legacy }
            raw.profiles.Default.legacy = nil
          end,
        },
      })
      local frame = db.profile.frame
      assert.are.equal(3, frame.x)
      frame.x = 4
      assert.are.same({ frame = { x = 4 } }, saved().profiles.Default)
    end)
  end)

  describe("in-place upgrade from revision 6", function()
    it("gives revision 6 databases and nodes a cache and keeps detached roots detached", function()
      TestEnv.Reset()
      TestEnv.InstallWowApi()
      require("Registry")
      require("SignalKit")
      require("EventKit")
      local SchemaKit = require("SchemaKit")
      local previous = TestEnv.LoadRevision(6)
      TestEnv.SetPlayer()
      local state = rawget(previous, "_state")
      local db = previous:Open("MyAddonDB", schemaFor(SchemaKit))
      db:SetProfile("Doomed")
      local doomedFrame = db.profile.frame
      db:SetProfile("Default")
      db:DeleteProfile("Doomed")
      local profile, frame, aura = db.profile, db.profile.frame, db.profile.auras[5]
      frame.x = 2

      -- Every node and the database as revision 6 left them: `kind`,
      -- `depth` and a root's `dead`, no cache, and database layout 3.
      for _, node in pairs(state.views) do
        node.kind = node.kinds ~= nil and "record" or "map"
        if node.parent ~= false then
          node.depth = #node.pathKeys + 1
        else
          node.dead = node.generation == false
        end
        node.cache, node.generation = nil, nil
        node.layout = 2
      end
      rawset(db, "_generation", nil)
      rawset(db, "_layout", 3)

      local upgraded = TestEnv.ReloadPackage()
      assert.are.equal(previous, upgraded)
      assert.is_true(upgraded.REVISION > 6)
      assert.are.equal(db, upgraded:Open("MyAddonDB"))
      assert.are.equal(4, rawget(db, "_layout"))
      assert.are.equal("number", type(rawget(db, "_generation")))
      for _, node in pairs(state.views) do
        assert.are.equal(3, node.layout)
        assert.is_nil(node.kind)
        assert.is_nil(node.depth)
        assert.is_nil(node.dead)
      end

      assert.are.equal(2, frame.x)
      assert.is_true(aura.shown)
      assert.are.equal(0, doomedFrame.x)
      TestEnv.expectErrorContaining("deleted or reset away", function()
        doomedFrame.x = 1
      end)
      profile.frame = { x = 5 }
      assert.are.equal(5, frame.x)
      aura.shown = false
      assert.is_false(saved().profiles.Default.auras[5].shown)
      local getter = db:Getter("profile", "scale")
      assert.are.equal(1, getter())
      profile.scale = 2
      assert.are.equal(2, getter())
      saved().profiles.Default.frame = { x = 8 }
      db:Resync()
      assert.are.equal(8, frame.x)
    end)
  end)
end)
