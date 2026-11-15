local TestEnv = require("OptionsKitTestEnv")

-- Revision 15, Dynamic part: builder trees, `NotifyChange`, `Replace`,
-- `Remove` and the structure signal.

local function getter()
  return true
end

local function setter() end

---A toggle with a getter and a setter.
---@param name string
---@return table
local function toggle(name)
  return { type = "toggle", name = name, get = getter, set = setter }
end

---The paths `Walk` visits, in order.
---@param tree table
---@return string[]
local function walked(tree)
  local paths = {}
  tree:Walk(function(path)
    paths[#paths + 1] = path
  end)
  return paths
end

describe("OptionsKit dynamic trees", function()
  local OptionsKit
  local reports

  before_each(function()
    OptionsKit = TestEnv.NewPackage()
    reports = {}
    -- selene: allow(global_usage)
    rawset(_G, "geterrorhandler", function()
      return function(message)
        reports[#reports + 1] = message
      end
    end)
  end)
  after_each(function()
    -- selene: allow(global_usage)
    rawset(_G, "geterrorhandler", nil)
    TestEnv.Reset()
  end)

  it("builds a tree from a builder and rebuilds it after NotifyChange", function()
    local count = 1
    local calls = 0
    local tree = OptionsKit:Define("Addon", function(addonName)
      calls = calls + 1
      assert.are.equal("Addon", addonName)
      local args = {}
      for index = 1, count do
        args["option" .. index] = toggle("Option " .. index)
      end
      return { type = "group", args = args }
    end)
    assert.are.equal(1, calls)
    assert.are.same({ "option1" }, walked(tree))
    count = 3
    tree:NotifyChange()
    tree:NotifyChange()
    -- Nothing runs until a method reads the structure, then once.
    assert.are.equal(1, calls)
    assert.are.same({ "option1", "option2", "option3" }, walked(tree))
    assert.are.equal(2, calls)
    assert.is_true(tree:Get("option3"))
    assert.are.equal(2, calls)
    assert.are.equal(tree, OptionsKit:Get("Addon"))
  end)

  it("re-reads the table passed to Define while the addon holds it", function()
    local spec = { type = "group", args = { first = toggle("First") } }
    local tree = OptionsKit:Define("Addon", spec)
    spec.args.second = toggle("Second")
    assert.are.same({ "first" }, walked(tree))
    tree:NotifyChange()
    assert.are.same({ "first", "second" }, walked(tree))
  end)

  it("refuses NotifyChange when there is no source to read again", function()
    local tree = OptionsKit:Define("Addon", { type = "group", args = { first = toggle("First") } })
    collectgarbage()
    collectgarbage()
    TestEnv.expectErrorContaining(
      "OptionsKit.Tree:NotifyChange has no source to read again: keep the table passed to Define, or define the tree with a builder",
      function()
        tree:NotifyChange()
      end
    )
  end)

  it("keeps listeners, the info of surviving paths and its handle across a rebuild", function()
    local infos = {}
    local spec
    spec = {
      type = "group",
      args = {
        kept = {
          type = "toggle",
          name = "Kept",
          get = function(info)
            infos[#infos + 1] = info
            return true
          end,
          set = setter,
        },
      },
    }
    local tree = OptionsKit:Define("Addon", spec)
    local changes = 0
    tree:OnChange(function()
      changes = changes + 1
    end)
    tree:Get("kept")
    spec.args.added = toggle("Added")
    tree:NotifyChange()
    tree:Get("kept")
    assert.are.equal(infos[1], infos[2])
    tree:Set("added", false)
    assert.are.equal(1, changes)
  end)

  it(
    "fires the structure signal once per clean-to-dirty change, and for Replace and Remove",
    function()
      local spec = { type = "group", args = { first = toggle("First") } }
      local tree = OptionsKit:Define("Addon", spec)
      local fired = {}
      tree:OnStructureChanged(function(changed, path)
        assert.are.equal(tree, changed)
        fired[#fired + 1] = path
      end)
      tree:NotifyChange()
      tree:NotifyChange()
      assert.are.same({ "" }, fired)
      tree:Walk(function() end)
      tree:NotifyChange()
      assert.are.same({ "", "" }, fired)
      tree:Replace("second", toggle("Second"))
      assert.is_true(tree:Remove("second"))
      assert.are.same({ "", "", "second", "second" }, fired)
      -- A listener that describes inside the signal triggers the rebuild.
      tree:OnStructureChanged(function()
        tree:Describe()
      end)
      spec.args.third = toggle("Third")
      tree:NotifyChange()
      assert.are.equal("toggle", tree:DescribeOption("third").kind)
      OptionsKit:Undefine("Addon")
    end
  )

  it("keeps the structure and reports when a rebuild is refused", function()
    local mode = "ok"
    local tree = OptionsKit:Define("Addon", function()
      if mode == "raise" then
        error("builder broke")
      elseif mode == "nothing" then
        return nil
      elseif mode == "bad" then
        return {
          type = "group",
          args = {
            range = { type = "range", name = "r", min = 2, max = 1, get = getter, set = setter },
          },
        }
      end
      return { type = "group", args = { first = toggle("First") } }
    end)
    for _, case in ipairs({ "raise", "nothing", "bad" }) do
      mode = case
      tree:NotifyChange()
      assert.is_true(tree:Get("first"))
    end
    assert.are.equal(3, #reports)
    assert.is_truthy(reports[1]:find("OptionsKit (Addon) NotifyChange: ", 1, true))
    assert.is_truthy(reports[1]:find("builder broke", 1, true))
    assert.is_truthy(reports[2]:find("the tree function returned no table", 1, true))
    assert.are.equal(
      "OptionsKit (Addon) NotifyChange: OptionsKit.Tree:NotifyChange tree.args.range.min must not be greater than max",
      reports[3]
    )
    -- Without an error handler the structure is kept all the same.
    -- selene: allow(global_usage)
    rawset(_G, "geterrorhandler", nil)
    mode = "raise"
    tree:NotifyChange()
    assert.is_true(tree:Get("first"))
  end)

  it("reports a table dropped between NotifyChange and the rebuild", function()
    local spec = { type = "group", args = { first = toggle("First") } }
    local tree = OptionsKit:Define("Addon", spec)
    tree:NotifyChange()
    spec = nil
    collectgarbage()
    collectgarbage()
    assert.is_true(tree:Get("first"))
    assert.are.equal(
      "OptionsKit (Addon) NotifyChange: the table passed to Define is no longer held by the addon",
      reports[1]
    )
    assert.is_nil(spec)
  end)

  it("ends a rebuild whose builder undefines the tree", function()
    local rounds = 0
    local tree = OptionsKit:Define("Addon", function()
      rounds = rounds + 1
      if rounds == 2 then
        OptionsKit:Undefine("Addon")
      end
      return { type = "group", args = { first = toggle("First") } }
    end)
    tree:NotifyChange()
    TestEnv.expectErrorContaining("cannot be called on an undefined tree", function()
      tree:Walk(function() end)
    end)
    assert.are.equal(2, rounds)
  end)

  it("applies the limits of the original Define to a rebuild", function()
    local count = 2
    local tree = OptionsKit:Define("Addon", function()
      local args = {}
      for index = 1, count do
        args["option" .. index] = toggle("Option")
      end
      return { type = "group", args = args }
    end, { maxOptions = 2 })
    count = 3
    tree:NotifyChange()
    assert.are.equal(2, tree:Walk(function() end))
    assert.is_truthy(reports[1]:find("has more than 2 options", 1, true))
  end)

  it("lets a builder read the tree and ask for another rebuild", function()
    local tree
    local rounds = 0
    tree = OptionsKit:Define("Addon", function()
      rounds = rounds + 1
      if rounds == 2 then
        assert.is_true(tree:Get("first"))
        tree:NotifyChange()
      end
      return { type = "group", args = { first = toggle("First") } }
    end)
    tree:NotifyChange()
    tree:Walk(function() end)
    assert.are.equal(2, rounds)
    -- The builder's own NotifyChange left the tree dirty: one more round.
    tree:Walk(function() end)
    assert.are.equal(3, rounds)
  end)

  it("raises the builder's error at Define, and a non-table result", function()
    TestEnv.expectErrorContaining("builder broke", function()
      OptionsKit:Define("Addon", function()
        error("builder broke")
      end)
    end)
    TestEnv.expectErrorContaining(
      "OptionsKit:Define tree function must return the root group table",
      function()
        OptionsKit:Define("Other", function()
          return 1
        end)
      end
    )
  end)

  it("replaces and adds one subtree, checking only it", function()
    local tree = OptionsKit:Define("Addon", {
      type = "group",
      args = {
        group = {
          type = "group",
          name = "Group",
          get = getter,
          set = setter,
          args = { a = { type = "toggle", name = "a" }, c = { type = "toggle", name = "c" } },
        },
      },
    })
    tree:Replace("group.b", { type = "toggle", name = "b" })
    assert.are.same({ "group", "group.a", "group.b", "group.c" }, walked(tree))
    -- The new option inherits the group's accessors.
    assert.is_true(tree:Get("group.b"))
    tree:Replace("group", { type = "group", name = "New", args = { z = toggle("z") } })
    assert.are.same({ "group", "group.z" }, walked(tree))
    TestEnv.expectErrorContaining('unknown path "group.a"', function()
      tree:Get("group.a")
    end)
    TestEnv.expectErrorContaining(
      "OptionsKit.Tree:Replace option.args.r.min must not be greater than max",
      function()
        tree:Replace("group", {
          type = "group",
          name = "Bad",
          args = {
            r = { type = "range", name = "r", min = 2, max = 1, get = getter, set = setter },
          },
        })
      end
    )
    assert.are.same({ "group", "group.z" }, walked(tree))
    TestEnv.expectErrorContaining(
      'OptionsKit.Tree:Replace path "nowhere.x" needs a group at "nowhere"',
      function()
        tree:Replace("nowhere.x", toggle("x"))
      end
    )
    TestEnv.expectErrorContaining(
      "OptionsKit.Tree:Replace path must be a non-empty string",
      function()
        tree:Replace("", toggle("x"))
      end
    )
  end)

  it("checks a Replace against the tree's limits", function()
    local tree = OptionsKit:Define("Addon", {
      type = "group",
      args = { a = toggle("a"), b = toggle("b") },
    }, { maxOptions = 2, maxDepth = 1 })
    tree:Replace("a", toggle("again"))
    TestEnv.expectErrorContaining("has more than 2 options", function()
      tree:Replace("c", toggle("c"))
    end)
    TestEnv.expectErrorContaining("is deeper than 1 levels", function()
      tree:Replace("a", { type = "group", name = "g", args = { deep = toggle("deep") } })
    end)
  end)

  it("removes one subtree", function()
    local tree = OptionsKit:Define("Addon", {
      type = "group",
      args = { a = toggle("a"), box = { type = "group", name = "Box", args = { b = toggle("b") } } },
    })
    assert.is_true(tree:Remove("box"))
    assert.are.same({ "a" }, walked(tree))
    assert.is_false(tree:Remove("box"))
    TestEnv.expectErrorContaining(
      'OptionsKit.Tree:Remove path "a..b" must be dot-separated identifiers',
      function()
        tree:Remove("a..b")
      end
    )
  end)

  it("keeps, adds and detaches profile groups across rebuilds, Replace and Remove", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    require("Registry")
    require("SignalKit")
    require("SchemaKit")
    OptionsKit = require("OptionsKit")
    require("OptionsKit-Profiles")
    require("OptionsKit-Dynamic")
    local SettingsKit = require("SettingsKit")
    local S = require("SchemaKit")
    local db = SettingsKit:Open("DynamicProfilesDB", {
      profile = S.table({ fields = { scale = S.optional(S.number(), 1) } }),
    })
    local group = OptionsKit:ProfileOptions(db)
    local withGroup = true
    local tree = OptionsKit:Define("Addon", function()
      local args =
        { scale = { type = "range", name = "Scale", min = 0, max = 2, get = getter, set = setter } }
      if withGroup then
        args.profiles = group
      end
      return { type = "group", args = args }
    end)
    local link = rawget(rawget(tree, "_profileLinks"), 1)
    local connections = link.connections
    tree:NotifyChange()
    tree:Walk(function() end)
    -- Still attached, with the same connections.
    assert.are.equal(connections, link.connections)
    withGroup = false
    tree:NotifyChange()
    tree:Walk(function() end)
    assert.is_false(link.tree)
    tree:Replace("moved", group)
    assert.are.equal(tree, link.tree)
    assert.are.equal("moved", link.path)
    assert.is_true(tree:Remove("moved"))
    assert.is_false(link.tree)
    OptionsKit:Undefine("Addon")
  end)

  it("lists the trees, sorted, in a fresh array", function()
    OptionsKit:Define("Zeta", { type = "group", args = {} })
    OptionsKit:Define("Alpha", { type = "group", args = {} })
    local names = OptionsKit:GetTrees()
    assert.are.same({ "Alpha", "Zeta" }, names)
    names[1] = nil
    assert.are.same({ "Alpha", "Zeta" }, OptionsKit:GetTrees())
  end)

  it("refuses the new methods on an undefined tree and on other receivers", function()
    local tree = OptionsKit:Define("Addon", function()
      return { type = "group", args = {} }
    end)
    OptionsKit:Undefine("Addon")
    TestEnv.expectErrorContaining(
      "OptionsKit.Tree:NotifyChange cannot be called on an undefined tree",
      function()
        tree:NotifyChange()
      end
    )
    TestEnv.expectErrorContaining(
      "OptionsKit.Tree:NotifyChange must be called on an OptionsKit tree",
      function()
        OptionsKit.Tree.NotifyChange({})
      end
    )
    TestEnv.expectErrorContaining(
      "OptionsKit.Tree:Replace cannot be called on an undefined tree",
      function()
        tree:Replace("a", toggle("a"))
      end
    )
  end)
end)
