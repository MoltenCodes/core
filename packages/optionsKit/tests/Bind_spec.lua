local TestEnv = require("OptionsKitTestEnv")

describe("OptionsKit bind to a SettingsKit database", function()
  local OptionsKit
  local db
  local tree
  local changes

  ---Define the bound tree over `db`.
  local function defineBound()
    return OptionsKit:Define("Addon", {
      type = "group",
      args = {
        scale = {
          type = "range",
          name = "Scale",
          min = 0.5,
          max = 2,
          bind = "profile.scale",
        },
        anchor = {
          type = "select",
          name = "Anchor",
          values = { TOP = "Top", CENTER = "Center" },
          bind = "profile.frame.anchor",
          validate = function(_, value)
            return value ~= "TOP", "TOP is taken"
          end,
        },
        verbose = { type = "toggle", name = "Verbose", bind = "global.verbose" },
      },
    }, { db = db })
  end

  before_each(function()
    local Registry
    OptionsKit, Registry = TestEnv.NewPackage()
    TestEnv.InstallSettingsKitStub(Registry)
    db = TestEnv.NewDatabase({
      profile = { scale = 1, frame = { anchor = "CENTER" } },
      global = { verbose = false },
    })
    tree = defineBound()
    changes = {}
    tree:OnChange(function(_, path, value)
      changes[#changes + 1] = { path, value }
    end)
  end)
  after_each(TestEnv.Reset)

  it("counts a database without IsReadOnly, or with a secret answer, as writable", function()
    -- The stand-in has no `IsReadOnly`, as an older SettingsKit has none.
    assert.is_false(tree:IsDisabled("scale"))
    assert.is_false(tree:Describe().children[1].disabled)

    local answer = {}
    db.IsReadOnly = function()
      return answer
    end
    -- selene: allow(global_usage)
    rawset(_G, "issecretvalue", function(value)
      return rawequal(value, answer)
    end)
    assert.is_false(tree:IsDisabled("scale"))
    -- selene: allow(global_usage)
    rawset(_G, "issecretvalue", nil)

    db.IsReadOnly = function()
      return true
    end
    assert.is_true(tree:IsDisabled("scale"))
    assert.is_true(tree:IsDisabled("verbose"))
  end)

  it("reads defaults through the database", function()
    assert.are.equal(1, tree:Get("scale"))
    assert.are.equal("CENTER", tree:Get("anchor"))
    assert.is_false(tree:Get("verbose"))
  end)

  it("writes validated values into the scope table", function()
    assert.is_true(tree:Set("scale", 1.5))
    assert.are.equal(1.5, rawget(db.profile, "scale"))
    assert.is_true(tree:Set("verbose", true))
    assert.is_true(rawget(db.global, "verbose"))
    assert.are.same({ { "scale", 1.5 }, { "verbose", true } }, changes)
  end)

  it("walks nested bind paths", function()
    assert.is_true(tree:Set("anchor", "CENTER"))
    assert.are.equal("CENTER", rawget(db.profile.frame, "anchor"))
    assert.are.same({ false, "TOP is taken" }, { tree:Set("anchor", "TOP") })
    TestEnv.expectErrorContaining("OptionsKit.Tree:Set anchor: expected one of", function()
      tree:Set("anchor", "LEFT")
    end)
  end)

  it("resolves the scope table on every call, so a profile switch is seen", function()
    tree:Set("scale", 1.5)
    db.profile = setmetatable({ frame = {} }, { __index = { scale = 0.75 } })
    assert.are.equal(0.75, tree:Get("scale"))
    tree:Set("scale", 2)
    assert.are.equal(2, rawget(db.profile, "scale"))
  end)

  it("resets a bound option to its default and fires OnChange with it", function()
    tree:Set("scale", 1.5)
    assert.are.equal(1, tree:Reset("scale"))
    assert.is_nil(rawget(db.profile, "scale"))
    assert.are.equal(1, tree:Get("scale"))
    assert.are.same({ "scale", 1 }, changes[#changes])
  end)

  it("reads nil and writes a nested table when an intermediate record is missing", function()
    db.profile = setmetatable({}, { __index = {} })
    assert.is_nil(tree:Get("anchor"))
    -- Clearing a value whose record does not exist changes nothing.
    assert.is_nil(tree:Reset("anchor"))
    assert.is_nil(rawget(db.profile, "frame"))
    assert.is_true(tree:Set("anchor", "CENTER"))
    assert.are.same({ anchor = "CENTER" }, rawget(db.profile, "frame"))
    assert.are.equal("CENTER", tree:Get("anchor"))
  end)

  it("raises when a scope is no longer available", function()
    db.profile = nil
    TestEnv.expectErrorContaining(
      'OptionsKit.Tree:Get bind scope "profile" is not an available scope of the database',
      function()
        tree:Get("scale")
      end
    )
  end)

  it("raises when a bind path no longer leads to a table", function()
    db.profile = { frame = "flat" }
    TestEnv.expectErrorContaining(
      'OptionsKit.Tree:Get bind path "profile.frame.anchor" does not lead to a table',
      function()
        tree:Get("anchor")
      end
    )
    TestEnv.expectErrorContaining(
      'OptionsKit.Tree:Set bind path "profile.frame.anchor" does not lead to a table',
      function()
        tree:Set("anchor", "CENTER")
      end
    )
  end)

  it("refuses to reset an option with get and set", function()
    OptionsKit:Undefine("Addon")
    local value = true
    tree = OptionsKit:Define("Addon", {
      type = "group",
      args = {
        own = {
          type = "toggle",
          name = "Own",
          get = function()
            return value
          end,
          set = function(_, newValue)
            value = newValue
          end,
        },
      },
    })
    TestEnv.expectErrorContaining(
      'OptionsKit.Tree:Reset path "own" is not bound to a database and has no default',
      function()
        tree:Reset("own")
      end
    )
  end)

  it("mixes bound options and options with get and set in one tree", function()
    OptionsKit:Undefine("Addon")
    local own = "x"
    tree = OptionsKit:Define("Addon", {
      type = "group",
      args = {
        bound = { type = "range", name = "B", min = 0, max = 5, bind = "profile.scale" },
        own = {
          type = "input",
          name = "O",
          get = function()
            return own
          end,
          set = function(_, value)
            own = value
          end,
        },
      },
    }, { db = db })
    tree:Set("bound", 3)
    tree:Set("own", "y")
    assert.are.equal(3, rawget(db.profile, "scale"))
    assert.are.equal("y", own)
  end)

  it("refuses malformed bind paths and a database without the scope", function()
    OptionsKit:Undefine("Addon")
    local function assertBindRefused(bind, expected, database)
      TestEnv.expectErrorContaining(expected, function()
        OptionsKit:Define("Bad", {
          type = "group",
          args = { option = { type = "toggle", name = "t", bind = bind } },
        }, { db = database or db })
      end)
    end
    assertBindRefused(1, "tree.args.option.bind must be a string")
    assertBindRefused("profile", 'bind "profile" must name a value inside the scope')
    assertBindRefused(
      "session.value",
      "must start with global, char, realm, class, faction or profile"
    )
    assertBindRefused("profile..value", "must be dot-separated identifiers")
    assertBindRefused("profile.2x", "must be dot-separated identifiers")
    local partial = TestEnv.NewDatabase()
    partial.realm = nil
    assertBindRefused(
      "realm.value",
      'bind scope "realm" is not an available scope of options.db',
      partial
    )
  end)

  it("refuses an options.db that is not a database", function()
    OptionsKit:Undefine("Addon")
    TestEnv.expectErrorContaining(
      "OptionsKit:Define options.db must be a SettingsKit database",
      function()
        OptionsKit:Define("Bad", { type = "group", args = {} }, { db = { profile = {} } })
      end
    )
  end)
end)
