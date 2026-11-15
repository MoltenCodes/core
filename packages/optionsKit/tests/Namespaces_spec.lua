local TestEnv = require("OptionsKitTestEnv")

-- Revision 14: binds into SettingsKit namespaces (`ns:<name>.<scope>...`)
-- and into the four scopes SettingsKit revision 15 adds. SettingsKit's
-- namespaces are specced here against a stand-in with revision 15's
-- documented surface: `GetNamespace(name, { missingOk = true })` answers the
-- child database or `nil`, and reading `GetNamespace` on a database whose
-- Namespaces part is not loaded raises at the reading line.

---Count the fields of a table.
---@param value table
---@return integer
local function countFields(value)
  local count = 0
  for _ in next, value do
    count = count + 1
  end
  return count
end

describe("OptionsKit binds into namespaces and the new scopes", function()
  local OptionsKit
  local db
  local children

  before_each(function()
    local Registry
    OptionsKit, Registry = TestEnv.NewPackage()
    TestEnv.InstallSettingsKitStub(Registry)
    db, children = TestEnv.NewDatabaseWithNamespaces({ profile = { scale = 1 } }, {
      Bars = { profile = { size = 4, layout = { rows = 2 } } },
    })
  end)
  after_each(TestEnv.Reset)

  ---Define a tree with one option bound at `bind`.
  ---@param bind string
  ---@param database table?
  ---@return table tree
  local function defineBound(bind, database)
    return OptionsKit:Define("Addon", {
      type = "group",
      args = { size = { type = "range", name = "Size", min = 0, max = 10, bind = bind } },
    }, { db = database or db })
  end

  it("reads, writes, validates and resets through the namespace's database", function()
    local tree = defineBound("ns:Bars.profile.size")
    assert.are.equal(4, tree:Get("size"))
    assert.is_true(tree:Set("size", 6))
    assert.are.equal(6, rawget(children.Bars.profile, "size"))
    assert.is_nil(rawget(db.profile, "size"))
    assert.is_true(tree:Validate("size", 7))
    assert.are.equal(4, tree:Reset("size"))
    local node = tree:DescribeOption("size")
    assert.are.equal("ns:Bars.profile.size", node.bind)
    assert.are.equal(4, node.value)
  end)

  it("sees a profile switch at once: the scope table is read per call", function()
    local tree = defineBound("ns:Bars.profile.layout.rows")
    assert.are.equal(2, tree:Get("size"))
    children.Bars.profile = setmetatable({ layout = { rows = 5 } }, {})
    assert.are.equal(5, tree:Get("size"))
  end)

  it("disables a namespaced option while the namespace's database is read-only", function()
    local tree = defineBound("ns:Bars.profile.size")
    assert.is_false(tree:IsDisabled("size"))
    function children.Bars:IsReadOnly()
      return true
    end
    assert.is_true(tree:IsDisabled("size"))
  end)

  it("keeps the record at 8 fields and the key array's length", function()
    local tree = defineBound("ns:Bars.profile.layout.rows")
    local record = rawget(rawget(tree, "_records"), "size")
    -- Kind, path, parent, name, hints (the range's bounds), schema, scope
    -- and keys: no field for the namespace.
    assert.are.equal(8, countFields(record))
    local keys = rawget(record, "_bindKeys")
    assert.are.equal(2, #keys)
    assert.are.same({ "layout", "rows" }, { keys[1], keys[2] })
    assert.are.equal(children.Bars, keys[0].db)
  end)

  it("refuses an unregistered namespace and a database without namespaces", function()
    TestEnv.expectErrorContaining(
      'tree.args.size.bind namespace "Gone" is not registered in options.db',
      function()
        defineBound("ns:Gone.profile.size")
      end
    )
    local plain = TestEnv.NewDatabase()
    TestEnv.expectErrorContaining(
      'bind "ns:Bars.profile.size" needs options.db with namespaces (SettingsKit revision 15 or later)',
      function()
        defineBound("ns:Bars.profile.size", plain)
      end
    )
    -- SettingsKit revision 15 without its Namespaces part raises when the
    -- member is read; that raise never escapes from inside OptionsKit.
    local partless = setmetatable(TestEnv.NewDatabase(), {
      __index = function(_, key)
        if key == "GetNamespace" then
          error(
            "SettingsKit.Database:GetNamespace is in SettingsKit's Namespaces part, which is not loaded",
            2
          )
        end
        return nil
      end,
    })
    TestEnv.expectErrorContaining("needs options.db with namespaces", function()
      defineBound("ns:Bars.profile.size", partless)
    end)
    TestEnv.expectErrorContaining(
      'bind scope "realm" is not an available scope of namespace "Bars" of options.db',
      function()
        children.Bars.realm = nil
        defineBound("ns:Bars.realm.size")
      end
    )
    TestEnv.expectErrorContaining("must be dot-separated identifiers", function()
      defineBound("ns:Bad Name.profile.size")
    end)
  end)

  it("binds the four new scopes when the database provides them", function()
    for _, scope in ipairs({ "race", "factionrealm", "factionrealmregion", "locale" }) do
      local database = TestEnv.NewDatabase()
      rawset(database, scope, setmetatable({}, { __index = { size = 3 } }))
      local tree = defineBound(scope .. ".size", database)
      assert.are.equal(3, tree:Get("size"))
      OptionsKit:Undefine("Addon")
      TestEnv.expectErrorContaining(
        'bind scope "' .. scope .. '" is not an available scope of options.db',
        function()
          defineBound(scope .. ".size", TestEnv.NewDatabase())
        end
      )
    end
  end)
end)
