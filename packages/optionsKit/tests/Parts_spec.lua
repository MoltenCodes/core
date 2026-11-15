local TestEnv = require("OptionsKitTestEnv")

-- Revision 15 splits OptionsKit into a core and two parts (ADR 0001): the
-- Profiles part (`ProfileOptions`) and the Dynamic part (`NotifyChange`,
-- `Replace`, `Remove`, builder trees). These specs load the core alone, the
-- parts in other orders, and the upgrade from a single-file revision.

local PART_MESSAGE_TAIL = " to embeds.xml (or rebuild it with python3 -m tooling.package.embeds)"

local function getter()
  return true
end

local function setter() end

describe("OptionsKit parts", function()
  after_each(function()
    -- selene: allow(global_usage)
    rawset(_G, "geterrorhandler", nil)
    TestEnv.Reset()
  end)

  it("keeps the surface complete with the core alone, each part member naming its file", function()
    local OptionsKit = TestEnv.NewCorePackage()
    assert.is_false(OptionsKit:IsPartLoaded("Profiles"))
    assert.is_false(OptionsKit:IsPartLoaded("Dynamic"))
    TestEnv.expectErrorContaining(
      "OptionsKit:ProfileOptions is in OptionsKit's Profiles part, which is not loaded: add optionsKit\\parts\\OptionsKit-Profiles.lua"
        .. PART_MESSAGE_TAIL,
      function()
        OptionsKit:ProfileOptions({})
      end
    )
    local tree = OptionsKit:Define("Addon", { type = "group", args = {} })
    for _, member in ipairs({ "NotifyChange", "Replace", "Remove" }) do
      TestEnv.expectErrorContaining(
        "OptionsKit.Tree:"
          .. member
          .. " is in OptionsKit's Dynamic part, which is not loaded: add optionsKit\\parts\\OptionsKit-Dynamic.lua"
          .. PART_MESSAGE_TAIL,
        function()
          tree[member](tree, "a")
        end
      )
    end
    TestEnv.expectErrorContaining(
      "OptionsKit:Define tree is a function, which needs OptionsKit's Dynamic part: add optionsKit\\parts\\OptionsKit-Dynamic.lua",
      function()
        OptionsKit:Define("Built", function()
          return { type = "group", args = {} }
        end)
      end
    )
    -- The structure signal is the core's: a static tree just never fires it.
    assert.is_table(tree:OnStructureChanged(function() end))
    TestEnv.expectErrorContaining("OptionsKit:IsPartLoaded partName must be a string", function()
      OptionsKit:IsPartLoaded(1)
    end)
  end)

  it(
    "installs a part's members when it loads after the core, and keeps them across a core upgrade",
    function()
      local OptionsKit = TestEnv.NewCorePackage()
      require("OptionsKit-Dynamic")
      assert.is_true(OptionsKit:IsPartLoaded("Dynamic"))
      local notify = OptionsKit.Tree.NotifyChange
      local upgraded = TestEnv.LoadRevision(16)
      assert.are.equal(OptionsKit, upgraded)
      assert.are.equal(notify, OptionsKit.Tree.NotifyChange)
      local tree = OptionsKit:Define("Addon", function()
        return { type = "group", args = {} }
      end)
      tree:NotifyChange()
      assert.are.equal(0, tree:Walk(function() end))
    end
  )

  it("lets an equal or older part revision yield to the installed one", function()
    local OptionsKit = TestEnv.NewCorePackage()
    require("OptionsKit-Profiles")
    local record = rawget(rawget(OptionsKit, "_state"), "parts").Profiles
    package.loaded["OptionsKit-Profiles"] = nil
    assert.are.equal(OptionsKit, require("OptionsKit-Profiles"))
    assert.are.equal(record, rawget(rawget(OptionsKit, "_state"), "parts").Profiles)
  end)

  it("refuses to load a part without its core", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    require("Registry")
    TestEnv.expectErrorContaining(
      "MoltenCodes OptionsKit part Dynamic requires OptionsKit API 1 to be loaded first",
      function()
        require("OptionsKit-Dynamic")
      end
    )
    package.loaded["OptionsKit-Dynamic"] = nil
    TestEnv.expectErrorContaining(
      "MoltenCodes OptionsKit part Profiles requires OptionsKit API 1 to be loaded first",
      function()
        require("OptionsKit-Profiles")
      end
    )
    package.loaded["OptionsKit-Profiles"] = nil
  end)

  it("keeps the ProfileOptions of a single-file revision when no addon loads the part", function()
    TestEnv.Reset()
    TestEnv.InstallWowApi()
    require("Registry")
    require("SignalKit")
    require("SchemaKit")
    local OptionsKit = TestEnv.LoadRevision(13)
    local state = rawget(OptionsKit, "_state")
    -- A single-file copy has no part records: its ProfileOptions is its own.
    local own = OptionsKit.ProfileOptions
    rawset(state, "parts", nil)
    rawset(state, "helpers", nil)
    local upgraded = require("OptionsKit")
    assert.are.equal(OptionsKit, upgraded)
    assert.are.equal(own, upgraded.ProfileOptions)
    assert.is_false(upgraded:IsPartLoaded("Profiles"))
  end)

  it(
    "upgrades a revision 13 tree in place: layout 3, its limits, no source to read again",
    function()
      TestEnv.Reset()
      TestEnv.InstallWowApi()
      require("Registry")
      require("SignalKit")
      require("SchemaKit")
      local OptionsKit = TestEnv.LoadRevision(13)
      local spec = {
        type = "group",
        args = { a = { type = "toggle", name = "a", get = getter, set = setter } },
      }
      local tree = OptionsKit:Define("Addon", spec)
      local state = rawget(OptionsKit, "_state")
      -- What a revision 13 tree lacks.
      rawset(tree, "_schema", 2)
      rawset(tree, "_maxOptions", nil)
      rawset(tree, "_maxDepth", nil)
      rawset(tree, "_maxDynamicEntries", nil)
      rawset(rawget(state, "treeSources"), tree, nil)
      local upgraded = require("OptionsKit")
      require("OptionsKit-Dynamic")
      assert.are.equal(3, rawget(tree, "_schema"))
      assert.are.equal(upgraded.MAX_OPTIONS, rawget(tree, "_maxOptions"))
      assert.are.equal(upgraded.MAX_DEPTH, rawget(tree, "_maxDepth"))
      assert.are.equal(1024, rawget(tree, "_maxDynamicEntries"))
      TestEnv.expectErrorContaining(
        "OptionsKit.Tree:NotifyChange has no source to read again",
        function()
          tree:NotifyChange()
        end
      )
      tree:Replace("b", { type = "toggle", name = "b", get = getter, set = setter })
      assert.is_true(tree:Get("b"))
      assert.is_true(tree:Get("a"))
      assert.is_nil(tree:GetConfirmation("a"))
      assert.is_false(tree:IsHidden("a", "dialog"))
    end
  )
end)

describe("OptionsKit parts allocation #allocation", function()
  after_each(TestEnv.Reset)

  it("allocates nothing on Get, Set, IsHidden and a dirty NotifyChange", function()
    local OptionsKit = TestEnv.NewPackage()
    local spec = {
      type = "group",
      args = {
        flag = { type = "toggle", name = "Flag", get = getter, set = setter, cmdHidden = false },
      },
    }
    local tree = OptionsKit:Define("Addon", spec)
    tree:Get("flag")
    tree:IsHidden("flag", "cmd")
    local kilobytes = TestEnv.AllocatedKilobytes(function()
      for _ = 1, 2000 do
        tree:Get("flag")
        tree:Set("flag", true)
        tree:IsHidden("flag")
        tree:IsHidden("flag", "dialog")
        tree:IsHidden("flag", "cmd")
      end
    end)
    assert.is_true(kilobytes < 1)
    tree:NotifyChange()
    local dirty = TestEnv.AllocatedKilobytes(function()
      for _ = 1, 2000 do
        tree:NotifyChange()
      end
    end)
    assert.is_true(dirty < 1)
  end)
end)
