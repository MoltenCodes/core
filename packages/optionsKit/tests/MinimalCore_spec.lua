local TestEnv = require("OptionsKitTestEnv")

-- Revision 16 keeps in the core what every tree needs and moves AceConfig's
-- presentation fields, its handlers and method names, and SettingsKit binds
-- into the Presentation, Handlers and Bind parts; profile links join the
-- Profiles part (revision 2). These specs load the core alone, each part, a
-- Profiles revision 1 part, a part over a revision 15 core, and the in-place
-- upgrade from revision 15 with and without the parts.

local SOURCE = debug.getinfo(1, "S").short_src
local PART_MESSAGE_TAIL = " to embeds.xml (or rebuild it with python3 -m tooling.package.embeds)"
local SPEC_DIRECTORY = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"

---Return the line number of the statement that called this helper.
---@return integer line
local function currentLine()
  return debug.getinfo(2, "l").currentline
end

---The not-loaded message of a part's field.
---@param label string
---@param partName string
---@return string
local function needsPart(label, partName)
  return label
    .. " needs OptionsKit's "
    .. partName
    .. " part: add optionsKit\\parts\\OptionsKit-"
    .. partName
    .. ".lua"
    .. PART_MESSAGE_TAIL
end

local function getter()
  return true
end

local function setter() end

---A one-option tree around `option`, under key `option`.
---@param option table
---@return table spec
local function treeWith(option)
  return { type = "group", args = { option = option } }
end

-- The line of the call a `define` callback is about to make, which it sets
-- before making it.
local expectedLine = 0

---Run `define`, expecting `message` at the line it set in `expectedLine`.
---@param message string
---@param define fun()
local function expectRefusedAtCaller(message, define)
  local ok, failure = pcall(define)
  assert.is_false(ok)
  assert.are.equal(SOURCE .. ":" .. expectedLine .. ": " .. message, failure)
end

---Load the revision 1 Profiles part, the one revision 15 shipped.
---@return table OptionsKit
local function loadProfilesRevision1()
  local path = SPEC_DIRECTORY .. "fixtures/OptionsKit-Profiles-revision1.lua"
  return assert(loadfile(path))()
end

describe("OptionsKit minimal core", function()
  after_each(TestEnv.Reset)

  describe("the core alone", function()
    it("refuses each part's fields at the caller's line, naming the part's file", function()
      local OptionsKit = TestEnv.NewCorePackage()
      local cases = {
        {
          "OptionsKit:Define tree.args.option.width",
          "Presentation",
          { type = "toggle", name = "T", get = getter, set = setter, width = "half" },
        },
        {
          "OptionsKit:Define tree.args.option.dialogHidden",
          "Presentation",
          { type = "toggle", name = "T", get = getter, set = setter, dialogHidden = true },
        },
        {
          "OptionsKit:Define tree.args.option.image",
          "Presentation",
          { type = "execute", name = "E", func = setter, image = "Interface\\Icons\\Spell" },
        },
        {
          "OptionsKit:Define tree.args.option.handler",
          "Handlers",
          { type = "toggle", name = "T", get = getter, set = setter, handler = {} },
        },
        {
          "OptionsKit:Define tree.args.option.plugins",
          "Handlers",
          { type = "group", name = "G", args = {}, plugins = {} },
        },
        {
          "OptionsKit:Define tree.args.option.get",
          "Handlers",
          { type = "group", name = "G", args = {}, get = getter },
        },
        {
          "OptionsKit:Define tree.args.option.bind",
          "Bind",
          { type = "toggle", name = "T", bind = "profile.enabled" },
        },
      }
      for _, case in ipairs(cases) do
        expectRefusedAtCaller(needsPart(case[1], case[2]), function()
          expectedLine = currentLine() + 1
          OptionsKit:Define("Addon", treeWith(case[3]))
        end)
      end
    end)

    it("refuses a function name or order and a method name, naming the part", function()
      local OptionsKit = TestEnv.NewCorePackage()
      expectRefusedAtCaller(
        needsPart("OptionsKit:Define tree.args.option.name is a function, which", "Presentation"),
        function()
          expectedLine = currentLine() + 1
          OptionsKit:Define(
            "Addon",
            treeWith({ type = "toggle", name = getter, get = getter, set = setter })
          )
        end
      )
      expectRefusedAtCaller(
        needsPart("OptionsKit:Define tree.args.option.order is a function, which", "Presentation"),
        function()
          expectedLine = currentLine() + 1
          OptionsKit:Define(
            "Addon",
            treeWith({ type = "toggle", name = "T", order = getter, get = getter, set = setter })
          )
        end
      )
      expectRefusedAtCaller(
        needsPart(
          'OptionsKit:Define tree.args.option.get is a method name ("Get"), which',
          "Handlers"
        ),
        function()
          expectedLine = currentLine() + 1
          OptionsKit:Define(
            "Addon",
            treeWith({ type = "toggle", name = "T", get = "Get", set = setter })
          )
        end
      )
    end)

    it("answers IsHidden and Describe for an interface with the plain flags", function()
      local OptionsKit = TestEnv.NewCorePackage()
      local tree = OptionsKit:Define("Addon", {
        type = "group",
        args = {
          hiddenOne = { type = "toggle", name = "H", hidden = true, get = getter, set = setter },
          inner = { type = "group", name = "I", inline = true, args = {} },
        },
      })
      assert.is_true(tree:IsHidden("hiddenOne", "dialog"))
      assert.is_true(tree:IsHidden("hiddenOne", "cmd"))
      local described = tree:Describe("dialog")
      for _, child in ipairs(described.children) do
        if child.key == "inner" then
          assert.is_true(child.inline)
        else
          assert.is_true(child.hidden)
        end
      end
      assert.is_true(tree:DescribeOption("inner", "cmd").inline)
    end)

    it("reports in GetFields only the fields and forms of the loaded parts", function()
      local OptionsKit = TestEnv.NewCorePackage()
      local toggle = OptionsKit:GetFields("toggle")
      assert.is_nil(toggle.width)
      assert.is_nil(toggle.bind)
      assert.is_nil(toggle.handler)
      assert.is_nil(toggle.name["function"])
      assert.is_nil(toggle.get.method)
      assert.is_nil(OptionsKit:GetFields("group").plugins)

      TestEnv.LoadPart("Presentation")
      toggle = OptionsKit:GetFields("toggle")
      assert.is_true(toggle.width.string)
      assert.is_true(toggle.name["function"])
      assert.is_nil(toggle.get.method)

      TestEnv.LoadPart("Handlers")
      toggle = OptionsKit:GetFields("toggle")
      assert.is_true(toggle.get.method)
      assert.is_true(toggle.handler.table)
      assert.is_true(OptionsKit:GetFields("group").plugins.table)
      assert.is_nil(toggle.bind)

      TestEnv.LoadPart("Bind")
      assert.is_true(OptionsKit:GetFields("toggle").bind.string)
      for _, partName in ipairs({ "Presentation", "Handlers", "Bind" }) do
        assert.is_true(OptionsKit:IsPartLoaded(partName))
      end
    end)
  end)

  it("accepts each part's fields once the part is loaded", function()
    local OptionsKit, Registry = TestEnv.NewCorePackage()
    TestEnv.InstallSettingsKitStub(Registry)
    TestEnv.LoadPart("Presentation")
    TestEnv.LoadPart("Handlers")
    TestEnv.LoadPart("Bind")
    local handler = {
      Get = function()
        return true
      end,
      Set = function() end,
    }
    local db = TestEnv.NewDatabase({ profile = { enabled = true } })
    local tree = OptionsKit:Define("Addon", {
      type = "group",
      handler = handler,
      args = {
        wide = { type = "toggle", name = getter, width = "half", get = "Get", set = "Set" },
        bound = { type = "toggle", name = "B", bind = "profile.enabled" },
      },
    }, { db = db })
    assert.is_true(tree:Get("wide"))
    assert.is_true(tree:Get("bound"))
    assert.is_true((tree:Set("bound", false)))
    assert.is_false(db.profile.enabled)
  end)

  it("refuses a part loaded over a revision 15 core", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    require("Registry")
    require("SignalKit")
    require("SchemaKit")
    TestEnv.LoadRevision(15)
    for _, partName in ipairs({ "Presentation", "Handlers", "Bind" }) do
      local ok, failure = pcall(TestEnv.LoadPart, partName)
      assert.is_false(ok)
      assert.is_truthy(
        tostring(failure):find(
          "MoltenCodes OptionsKit part "
            .. partName
            .. " requires OptionsKit revision 16 or later to be loaded first",
          1,
          true
        )
      )
    end
  end)

  it("serves a Profiles revision 1 part's groups with the revision 16 core", function()
    local OptionsKit = TestEnv.NewCorePackage()
    loadProfilesRevision1()
    assert.are.equal(1, OptionsKit._state.parts.Profiles.revision)
    local SettingsKit = TestEnv.RequireSettingsKit()
    local S = require("SchemaKit")
    local db = SettingsKit:Open("MinimalCoreProfilesDB", {
      profile = S.table({ fields = { scale = S.optional(S.number(), 1) } }),
    })
    local group = OptionsKit:ProfileOptions(db)
    local tree = OptionsKit:Define("Addon", { type = "group", args = { profiles = group } })
    assert.are.equal(db:GetProfile(), tree:Get("profiles.current"))
    assert.is_true((tree:Set("profiles.current", db:GetProfile())))
    assert.is_true(OptionsKit:Undefine("Addon"))
  end)

  it("links profile groups through the Profiles part revision 2", function()
    local OptionsKit = TestEnv.NewPackage()
    assert.are.equal(2, OptionsKit._state.parts.Profiles.revision)
    local SettingsKit = TestEnv.RequireSettingsKit()
    local S = require("SchemaKit")
    local db = SettingsKit:Open("MinimalCoreLinksDB", {
      profile = S.table({ fields = { scale = S.optional(S.number(), 1) } }),
    })
    local group = OptionsKit:ProfileOptions(db)
    local tree = OptionsKit:Define("Addon", { type = "group", args = { profiles = group } })
    local changes = {}
    tree:OnChange(function(_, path, value)
      changes[#changes + 1] = path .. "=" .. tostring(value)
    end)
    db:SetProfile("Other")
    assert.are.same({ "profiles.current=Other" }, changes)
    OptionsKit:Undefine("Addon")
    db:SetProfile("Default")
    assert.are.equal(1, #changes)
  end)

  describe("an in-place upgrade from revision 15", function()
    local handler = {
      value = true,
      Get = function(self)
        return self.value
      end,
      Set = function(self, _, value)
        self.value = value
      end,
    }

    ---Define, with the revision 15 copy, a tree using a part of every kind.
    ---@param OptionsKit table
    ---@param db table
    ---@return table tree
    local function defineFullTree(OptionsKit, db)
      return OptionsKit:Define("Addon", {
        type = "group",
        handler = handler,
        args = {
          wide = { type = "toggle", name = "Wide", width = "double", get = getter, set = setter },
          named = {
            type = "toggle",
            name = function()
              return "Dynamic"
            end,
            get = getter,
            set = setter,
          },
          method = { type = "toggle", name = "Method", get = "Get", set = "Set" },
          bound = { type = "range", name = "Bound", min = 0, max = 2, bind = "profile.scale" },
          dialogOnly = {
            type = "toggle",
            name = "Dialog",
            dialogHidden = true,
            get = getter,
            set = setter,
          },
        },
        plugins = {
          extra = { plugged = { type = "toggle", name = "Plugged", get = getter, set = setter } },
        },
      }, { db = db })
    end

    ---Load the chain with the revision 15 fixture, define the full tree, then
    ---load this core over it without any part.
    ---@return table OptionsKit, table tree, table db, table before
    local function upgradeWithTree()
      TestEnv.Reset()
      TestEnv.InstallWowApi()
      local Registry = require("Registry")
      require("SignalKit")
      require("SchemaKit")
      require("SchemaKit-Rules")
      local previous = TestEnv.LoadRevision(15)
      TestEnv.InstallSettingsKitStub(Registry)
      local db = TestEnv.NewDatabase({ profile = { scale = 1 } })
      local tree = defineFullTree(previous, db)
      local before = tree:Describe("dialog")
      local current = require("OptionsKit")
      assert.are.equal(previous, current)
      assert.are.equal(16, current.REVISION)
      return current, tree, db, before
    end

    ---Every method answers as revision 15 did.
    ---@param tree table
    ---@param db table
    ---@param before table the revision 15 description
    local function assertAnswers(tree, db, before)
      assert.are.same(before, tree:Describe("dialog"))
      assert.are.same(before.children[1], tree:DescribeOption(before.children[1].path, "dialog"))
      assert.is_true(tree:IsHidden("dialogOnly", "dialog"))
      assert.is_false(tree:IsHidden("dialogOnly"))
      assert.are.equal(1, tree:Get("bound"))
      assert.is_true((tree:Validate("bound", 2)))
      assert.is_true((tree:Set("bound", 2)))
      assert.are.equal(2, db.profile.scale)
      assert.is_true(tree:Get("method"))
      assert.is_true((tree:Set("method", false)))
      assert.is_false(handler.value)
      handler.value = true
      assert.is_true(tree:Get("plugged"))
      db.profile.scale = 1
    end

    it("keeps every method of a tree using every part answering with no part loaded", function()
      local current, tree, db, before = upgradeWithTree()
      assert.is_not_nil(current._state.legacyMembers.revision15)
      assertAnswers(tree, db, before)
    end)

    it("hands a Define with part fields to revision 15 while a part is absent", function()
      local current = upgradeWithTree()
      local other = current:Define("Other", {
        type = "group",
        args = {
          half = { type = "toggle", name = "Half", width = "half", get = getter, set = setter },
        },
      })
      assert.are.equal("half", other:Describe().children[1].width)
      expectRefusedAtCaller(
        'OptionsKit:Define "Other" already has a tree; Undefine it first',
        function()
          expectedLine = currentLine() + 1
          current:Define("Other", { type = "group", args = {} })
        end
      )
    end)

    it(
      "hands to revision 15 a Define needing an absent part only below a plugin or in a function name",
      function()
        local current = upgradeWithTree()
        TestEnv.LoadPart("Handlers")
        local plugged = current:Define("Plugged", {
          type = "group",
          args = {},
          plugins = {
            extra = {
              half = { type = "toggle", name = "Half", width = "half", get = getter, set = setter },
            },
          },
        })
        assert.are.equal("half", plugged:Describe().children[1].width)
        local named = current:Define(
          "Named",
          treeWith({
            type = "toggle",
            name = function()
              return "Dynamic"
            end,
            get = getter,
            set = setter,
          })
        )
        assert.are.equal("Dynamic", named:Describe().children[1].name)
        local trees = current._state.legacyMembers.revision15.trees
        assert.is_true(trees[plugged])
        assert.is_true(trees[named])
      end
    )

    it(
      "keeps a revision 15 tree whose only part field is a presentation hint, and not a plain one",
      function()
        TestEnv.Reset()
        TestEnv.InstallWowApi()
        require("Registry")
        require("SignalKit")
        require("SchemaKit")
        require("SchemaKit-Rules")
        local previous = TestEnv.LoadRevision(15)
        local wide = previous:Define(
          "Wide",
          treeWith({
            type = "toggle",
            name = "Wide",
            width = "double",
            get = getter,
            set = setter,
          })
        )
        local plain = previous:Define(
          "Plain",
          treeWith({
            type = "toggle",
            name = "Plain",
            order = 2,
            get = getter,
            set = setter,
          })
        )
        local current = require("OptionsKit")
        local trees = current._state.legacyMembers.revision15.trees
        assert.is_true(trees[wide])
        assert.is_nil(trees[plain])
        assert.are.equal("double", wide:Describe().children[1].width)
        assert.are.equal(2, plain:Describe().children[1].order)
        assert.is_true(plain:Get("option"))
      end
    )

    it("answers the same once the parts load, and drops revision 15", function()
      local current, tree, db, before = upgradeWithTree()
      TestEnv.LoadPart("Presentation")
      TestEnv.LoadPart("Handlers")
      assert.is_not_nil(current._state.legacyMembers.revision15)
      TestEnv.LoadPart("Bind")
      assert.is_nil(current._state.legacyMembers.revision15)
      assertAnswers(tree, db, before)
    end)
  end)
end)
