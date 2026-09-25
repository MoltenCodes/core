local TestEnv = require("OptionsKitTestEnv")

-- `ProfileOptions` drives a real SettingsKit database: SettingsKit is an
-- optional dependency, so the runner puts its source on `LUA_PATH` for this
-- suite (see docs/TESTING.md, "Which package sources a suite can require").

local SAVED_VARIABLE = "OptionsKitProfileDB"
local SOURCE = debug.getinfo(1, "S").short_src

-- The profile name SettingsKit builds for the identity installed below.
local CHARACTER_PROFILE = "Tester - Silvermoon"

-- Every localisation key `docs/API.md` documents, sorted.
local DOCUMENTED_KEYS = {
  "copy.confirm",
  "copy.desc",
  "copy.name",
  "copySource.desc",
  "copySource.name",
  "current.desc",
  "current.name",
  "delete.confirm",
  "delete.desc",
  "delete.name",
  "deleteTarget.desc",
  "deleteTarget.name",
  "group.desc",
  "group.name",
  "intro",
  "new.blank",
  "new.desc",
  "new.long",
  "new.name",
  "new.usage",
  "reset.confirm",
  "reset.desc",
  "reset.name",
}

---Write a host global: the client API lives only in the global table.
---@param name string
---@param value any
local function setGlobal(name, value)
  -- selene: allow(global_usage)
  rawset(_G, name, value)
end

---Install the two identity functions the per-character profile name needs.
local function installIdentity()
  setGlobal("UnitName", function(unit)
    if unit == "player" then
      return "Tester", nil
    end
    return nil
  end)
  setGlobal("GetRealmName", function()
    return "Silvermoon"
  end)
end

---Load the chain with SettingsKit and open a database whose profile holds
---`scale` in 0.5..2 (default 1).
---@return table OptionsKit
---@return table db
---@return table SettingsKit
local function openDatabase()
  local OptionsKit = TestEnv.NewPackage()
  installIdentity()
  local SettingsKit = require("SettingsKit")
  local S = require("SchemaKit")
  local db = SettingsKit:Open(SAVED_VARIABLE, {
    profile = S.table({
      fields = { scale = S.optional(S.number({ min = 0.5, max = 2 }), 1) },
    }),
  })
  return OptionsKit, db, SettingsKit
end

---Define a tree holding the profile group under `profiles`.
---@param OptionsKit table
---@param db table
---@param options table?
---@return table tree
---@return table group
local function defineProfiles(OptionsKit, db, options)
  local group = OptionsKit:ProfileOptions(db, options)
  local tree = OptionsKit:Define("Addon", { type = "group", args = { profiles = group } })
  return tree, group
end

---Connect a recorder to `tree:OnChange`.
---@param tree table
---@return table changes `{ { path, value }, ... }`
local function recordChanges(tree)
  local changes = {}
  tree:OnChange(function(_, path, value)
    changes[#changes + 1] = { path, value }
  end)
  return changes
end

---The node of `tree:Describe()` at `profiles.<key>`.
---@param tree table
---@param key string
---@return table node
local function describeChild(tree, key)
  local group = tree:Describe().children[1]
  for index = 1, #group.children do
    if group.children[index].key == key then
      return group.children[index]
    end
  end
  error("no child " .. key, 2)
end

---Run `action` and assert it failed with `message` reported at the line after
---`mark()` in this file.
---@param message string
---@param action fun(mark: fun())
local function assertReportedAtCaller(message, action)
  local expectedLine = nil
  local function mark()
    expectedLine = debug.getinfo(2, "l").currentline + 1
  end
  local ok, value = pcall(action, mark)
  assert.is_false(ok)
  assert.are.equal(SOURCE .. ":" .. tostring(expectedLine) .. ": " .. message, value)
end

describe("OptionsKit ProfileOptions", function()
  after_each(function()
    package.loaded["SettingsKit"] = nil
    setGlobal(SAVED_VARIABLE, nil)
    setGlobal("UnitName", nil)
    setGlobal("GetRealmName", nil)
    setGlobal("issecretvalue", nil)
    TestEnv.Reset()
  end)

  it("builds a group of the expected shape from existing kinds", function()
    local OptionsKit, db = openDatabase()
    local tree = defineProfiles(OptionsKit, db)

    local group = tree:Describe().children[1]
    assert.are.equal("group", group.kind)
    assert.are.equal("profiles", group.key)
    assert.are.equal("Profiles", group.name)
    assert.are.equal(100, group.order)
    assert.are.equal('This character uses the profile "Default".', group.desc)

    local shape = {}
    for index = 1, #group.children do
      local child = group.children[index]
      shape[index] = { child.key, child.kind }
    end
    assert.are.same({
      { "intro", "description" },
      { "current", "select" },
      { "new", "input" },
      { "copySource", "select" },
      { "copy", "execute" },
      { "reset", "execute" },
      { "deleteTarget", "select" },
      { "delete", "execute" },
    }, shape)

    assert.are.equal("medium", group.children[1].fontSize)
    assert.are.equal("<profile name>", group.children[3].usage)
    assert.are.equal(
      "Replace the current profile's settings with a copy of the chosen profile?",
      group.children[5].confirm
    )
    assert.are.equal("Reset the current profile to its defaults?", group.children[6].confirm)
    assert.are.equal(
      "Delete the chosen profile? Its settings cannot be recovered.",
      group.children[8].confirm
    )
    assert.are.equal(9, tree:Walk(function() end))
  end)

  it("offers every profile and the character profile, and switches on Set", function()
    local OptionsKit, db = openDatabase()
    db:SetProfile("Alt")
    db:SetProfile("Default")
    local tree = defineProfiles(OptionsKit, db)
    local changes = recordChanges(tree)

    assert.are.equal("Default", tree:Get("profiles.current"))
    local current = describeChild(tree, "current")
    assert.are.equal("Default", current.value)
    assert.are.same({
      Default = "Default",
      Alt = "Alt",
      [CHARACTER_PROFILE] = CHARACTER_PROFILE,
    }, current.values)

    -- The character profile does not exist yet: the switch creates it.
    assert.is_true(tree:Set("profiles.current", CHARACTER_PROFILE))
    assert.are.equal(CHARACTER_PROFILE, db:GetProfile())
    assert.are.same({ "Alt", "Default", CHARACTER_PROFILE }, db:GetProfiles())
    -- Set fires once: the link's own listener stays quiet for it.
    assert.are.same({ { "profiles.current", CHARACTER_PROFILE } }, changes)

    local ok = pcall(tree.Set, tree, "profiles.current", "Nowhere")
    assert.is_false(ok)
    assert.are.equal(CHARACTER_PROFILE, db:GetProfile())
  end)

  it("leaves the character choice out when the client does not know the player", function()
    local OptionsKit, db = openDatabase()
    setGlobal("GetRealmName", nil)
    local tree = defineProfiles(OptionsKit, db)
    assert.are.same({ Default = "Default" }, describeChild(tree, "current").values)
  end)

  it("creates a profile from the new-profile input after checking the name", function()
    local OptionsKit, db = openDatabase()
    local tree = defineProfiles(OptionsKit, db)
    local changes = recordChanges(tree)

    assert.are.equal("", tree:Get("profiles.new"))
    assert.are.same(
      { false, "a profile name needs a character other than whitespace" },
      { tree:Validate("profiles.new", "   ") }
    )
    assert.are.same(
      { false, "a profile name has at most 64 bytes" },
      { tree:Validate("profiles.new", string.rep("a", 65)) }
    )
    assert.are.same(
      { false, "a profile name needs a character other than whitespace" },
      { tree:Set("profiles.new", " ") }
    )
    assert.are.same({ "Default" }, db:GetProfiles())

    assert.is_true(tree:Set("profiles.new", "Raid"))
    assert.are.equal("Raid", db:GetProfile())
    assert.are.same({ "Default", "Raid" }, db:GetProfiles())
    assert.are.equal("", tree:Get("profiles.new"))

    -- The name of an existing profile switches to it.
    assert.is_true(tree:Set("profiles.new", "Default"))
    assert.are.equal("Default", db:GetProfile())
    -- The current profile changed too, so the link fires `current` before
    -- Set fires `new`.
    assert.are.same({
      { "profiles.current", "Raid" },
      { "profiles.new", "Raid" },
      { "profiles.current", "Default" },
      { "profiles.new", "Default" },
    }, changes)
  end)

  it("offers the database's own default profile, never a constant one", function()
    local OptionsKit = TestEnv.NewPackage()
    installIdentity()
    local SettingsKit = require("SettingsKit")
    local S = require("SchemaKit")
    local db = SettingsKit:Open(SAVED_VARIABLE, {
      profile = S.table({ fields = { scale = S.optional(S.number(), 1) } }),
    }, { defaultProfile = "Standard" })
    local tree = defineProfiles(OptionsKit, db)

    assert.are.equal("Standard", tree:Get("profiles.current"))
    assert.are.same(
      { Standard = "Standard", [CHARACTER_PROFILE] = CHARACTER_PROFILE },
      describeChild(tree, "current").values
    )
    assert.is_false(pcall(tree.Set, tree, "profiles.current", "Default"))
    assert.are.same({ "Standard" }, db:GetProfiles())
  end)

  it("copies the chosen profile into the current one", function()
    local OptionsKit, db = openDatabase()
    db.profile.scale = 1.5
    db:SetProfile("Raid")
    local tree = defineProfiles(OptionsKit, db)

    assert.are.same({ Default = "Default" }, describeChild(tree, "copySource").values)
    assert.is_nil(tree:Get("profiles.copySource"))
    assert.is_true(tree:IsDisabled("profiles.copy"))
    assertReportedAtCaller(
      'OptionsKit.Tree:Execute profiles.copy needs "profiles.copySource" to be set first',
      function(mark)
        mark()
        tree:Execute("profiles.copy")
      end
    )

    assert.is_true(tree:Set("profiles.copySource", "Default"))
    assert.are.equal("Default", tree:Get("profiles.copySource"))
    assert.is_false(tree:IsDisabled("profiles.copy"))
    -- The current profile is never a source.
    assert.is_false(pcall(tree.Set, tree, "profiles.copySource", "Raid"))

    local changes = recordChanges(tree)
    assert.are.equal(1, db.profile.scale)
    tree:Execute("profiles.copy")
    assert.are.equal(1.5, db.profile.scale)
    assert.are.equal("Raid", db:GetProfile())
    assert.are.same({ { "profiles.current", "Raid" } }, changes)
  end)

  it("resets the current profile", function()
    local OptionsKit, db = openDatabase()
    local tree = defineProfiles(OptionsKit, db)
    db.profile.scale = 1.5
    local changes = recordChanges(tree)

    tree:Execute("profiles.reset")
    assert.are.equal(1, db.profile.scale)
    assert.are.same({ { "profiles.current", "Default" } }, changes)
  end)

  it("deletes the chosen profile", function()
    local OptionsKit, db = openDatabase()
    db:SetProfile("Old")
    db:SetProfile("Default")
    local tree = defineProfiles(OptionsKit, db)

    assert.are.same({ Old = "Old" }, describeChild(tree, "deleteTarget").values)
    assert.is_true(tree:IsDisabled("profiles.delete"))
    assertReportedAtCaller(
      'OptionsKit.Tree:Execute profiles.delete needs "profiles.deleteTarget" to be set first',
      function(mark)
        mark()
        tree:Execute("profiles.delete")
      end
    )

    assert.is_true(tree:Set("profiles.deleteTarget", "Old"))
    assert.is_false(tree:IsDisabled("profiles.delete"))
    local changes = recordChanges(tree)
    tree:Execute("profiles.delete")
    assert.are.same({ "Default" }, db:GetProfiles())
    assert.is_nil(tree:Get("profiles.deleteTarget"))
    assert.is_true(tree:IsDisabled("profiles.delete"))
    assert.are.same({ { "profiles.current", "Default" } }, changes)
  end)

  it("keeps a delete target a listener chooses while the deletion is announced", function()
    local OptionsKit, db = openDatabase()
    db:SetProfile("Old")
    db:SetProfile("Next")
    db:SetProfile("Default")
    local tree = defineProfiles(OptionsKit, db)
    tree:Set("profiles.deleteTarget", "Old")
    -- The deletion is announced as a change of `current`.
    tree:OnChange(function(changed, path)
      if path == "profiles.current" then
        changed:Set("profiles.deleteTarget", "Next")
      end
    end)

    tree:Execute("profiles.delete")
    assert.are.same({ "Default", "Next" }, db:GetProfiles())
    assert.are.equal("Next", tree:Get("profiles.deleteTarget"))
    assert.is_false(tree:IsDisabled("profiles.delete"))
  end)

  it("fires once per Set when a SettingsKit listener switches again inside a switch", function()
    local OptionsKit, db = openDatabase()
    db:SetProfile("First")
    db:SetProfile("Second")
    db:SetProfile("Default")
    local tree
    local switchedAgain = false
    -- Connected before Define, so it runs before the group's own listener.
    db:OnProfileChanged(function(_, name)
      if name == "First" and not switchedAgain then
        switchedAgain = true
        tree:Set("profiles.current", "Second")
      end
    end)
    tree = defineProfiles(OptionsKit, db)
    local changes = recordChanges(tree)

    assert.is_true(tree:Set("profiles.current", "First"))
    assert.are.equal("Second", db:GetProfile())
    -- The inner Set fires for itself; the outer switch stays suppressed
    -- after the inner one returns, so only the outer Set follows.
    assert.are.same({
      { "profiles.current", "Second" },
      { "profiles.current", "First" },
    }, changes)
  end)

  it("disables copy and delete when the chosen profile stops qualifying", function()
    local OptionsKit, db = openDatabase()
    db:SetProfile("Old")
    db:SetProfile("Default")
    local tree = defineProfiles(OptionsKit, db)
    tree:Set("profiles.copySource", "Old")
    tree:Set("profiles.deleteTarget", "Old")
    assert.is_false(tree:IsDisabled("profiles.copy"))
    assert.is_false(tree:IsDisabled("profiles.delete"))

    -- The chosen profile became the current one.
    db:SetProfile("Old")
    assert.is_true(tree:IsDisabled("profiles.copy"))
    assert.is_true(tree:IsDisabled("profiles.delete"))
    assert.is_false(pcall(tree.Execute, tree, "profiles.copy"))
    assert.is_false(pcall(tree.Execute, tree, "profiles.delete"))

    -- The chosen profile was deleted elsewhere.
    db:SetProfile("Default")
    assert.is_false(tree:IsDisabled("profiles.copy"))
    db:DeleteProfile("Old")
    assert.is_true(tree:IsDisabled("profiles.copy"))
    assert.is_true(tree:IsDisabled("profiles.delete"))
  end)

  it("forgets a chosen profile that was deleted elsewhere or became current", function()
    local OptionsKit, db = openDatabase()
    db:SetProfile("Old")
    db:SetProfile("Default")
    local tree = defineProfiles(OptionsKit, db)
    tree:Set("profiles.copySource", "Old")
    tree:Set("profiles.deleteTarget", "Old")
    assert.are.equal("Old", tree:Get("profiles.copySource"))
    assert.are.equal("Old", tree:Get("profiles.deleteTarget"))

    db:SetProfile("Old")
    assert.is_nil(tree:Get("profiles.copySource"))
    assert.is_nil(tree:Get("profiles.deleteTarget"))
    db:SetProfile("Default")
    assert.are.equal("Old", tree:Get("profiles.copySource"))

    db:DeleteProfile("Old")
    assert.is_nil(tree:Get("profiles.copySource"))
    assert.is_nil(tree:Get("profiles.deleteTarget"))
    assert.is_nil(describeChild(tree, "copySource").value)
  end)

  it(
    "fires OnChange twice for ResetDatabase from another profile, once from the default",
    function()
      local OptionsKit, db = openDatabase()
      local tree = defineProfiles(OptionsKit, db)
      db:SetProfile("Other")
      local changes = recordChanges(tree)

      -- Reset fires OnProfileReset, then OnProfileChanged for the switch back.
      db:ResetDatabase()
      assert.are.same({
        { "profiles.current", "Default" },
        { "profiles.current", "Default" },
      }, changes)

      -- Already on the default profile: only OnProfileReset fires.
      db:ResetDatabase()
      assert.are.equal(3, #changes)
      assert.are.same(
        { Default = "Default", [CHARACTER_PROFILE] = CHARACTER_PROFILE },
        describeChild(tree, "current").values
      )
    end
  )

  it("fires OnChange on every profile signal of the database, until Undefine", function()
    local OptionsKit, db = openDatabase()
    local tree, group = defineProfiles(OptionsKit, db)
    local changes = recordChanges(tree)

    db:SetProfile("Other")
    db:ResetProfile()
    db:SetProfile("Default")
    db:CopyProfile("Other")
    db:DeleteProfile("Other")
    assert.are.same({
      { "profiles.current", "Other" },
      { "profiles.current", "Other" },
      { "profiles.current", "Default" },
      { "profiles.current", "Default" },
      { "profiles.current", "Default" },
    }, changes)

    local link = rawget(OptionsKit, "_state").profileGroups[group]
    assert.are.equal(tree, link.tree)
    assert.are.equal(4, #link.connections)
    local connection = link.connections[1]
    assert.is_true(connection:IsConnected())

    assert.is_true(OptionsKit:Undefine("Addon"))
    assert.is_false(connection:IsConnected())
    assert.is_false(link.tree)
    assert.is_false(link.connections)
    db:SetProfile("Later")
    assert.are.equal(5, #changes)
  end)

  it("describes the current profile live and translates through localize", function()
    local OptionsKit, db = openDatabase()
    local seen = {}
    local function localize(key, default)
      seen[key] = default
      if key == "group.desc" then
        return "Profil: %s"
      end
      if key == "new.usage" then
        return 42 -- not a string: the default stays
      end
      return "[" .. key .. "]"
    end
    local tree = defineProfiles(OptionsKit, db, { localize = localize })

    local group = tree:Describe().children[1]
    assert.are.equal("[group.name]", group.name)
    assert.are.equal('Profil: "Default"', group.desc)
    assert.are.equal("[intro]", group.children[1].name)
    assert.are.equal("[current.name]", group.children[2].name)
    assert.are.equal("[current.desc]", group.children[2].desc)
    assert.are.equal("<profile name>", group.children[3].usage)
    assert.are.equal("[copy.confirm]", group.children[5].confirm)
    assert.are.same({ false, "[new.blank]" }, { tree:Validate("profiles.new", " ") })
    assert.are.same({ false, "[new.long]" }, { tree:Validate("profiles.new", string.rep("a", 65)) })

    db:SetProfile("Alt")
    assert.are.equal('Profil: "Alt"', tree:Describe().children[1].desc)

    local keys = {}
    for key, default in pairs(seen) do
      keys[#keys + 1] = key
      assert.are.equal("string", type(default))
    end
    table.sort(keys)
    assert.are.same(DOCUMENTED_KEYS, keys)
  end)

  it("fills the current profile's name into every live description", function()
    local OptionsKit, db = openDatabase()
    db:SetProfile("Alt")
    local tree = defineProfiles(OptionsKit, db)
    assert.are.equal(
      'The profile this character uses, now "Alt". Choosing a name that has no profile yet creates an empty one.',
      describeChild(tree, "current").desc
    )
    assert.are.equal(
      'The profile whose settings replace those of "Alt" when you copy.',
      describeChild(tree, "copySource").desc
    )
    assert.are.equal(
      'Replace every setting of "Alt" with a copy of the profile chosen above.',
      describeChild(tree, "copy").desc
    )
    assert.are.equal(
      'Return every setting of "Alt" to its default.',
      describeChild(tree, "reset").desc
    )
    assert.are.equal(
      'A profile other than "Alt", to delete.',
      describeChild(tree, "deleteTarget").desc
    )
  end)

  it("applies the name, order and description overrides", function()
    local OptionsKit, db = openDatabase()
    local tree = defineProfiles(OptionsKit, db, {
      name = "Perfiles",
      order = 5,
      description = "Pick a profile.",
    })
    local group = tree:Describe().children[1]
    assert.are.equal("Perfiles", group.name)
    assert.are.equal(5, group.order)
    assert.are.equal("Pick a profile.", group.children[1].name)
  end)

  it("works as the root of a tree", function()
    local OptionsKit, db = openDatabase()
    local tree = OptionsKit:Define("Addon", OptionsKit:ProfileOptions(db))
    local changes = recordChanges(tree)

    assert.are.equal("Default", tree:Get("current"))
    assert.is_true(tree:Set("current", CHARACTER_PROFILE))
    db:SetProfile("Default")
    assert.are.same({ { "current", CHARACTER_PROFILE }, { "current", "Default" } }, changes)
    assertReportedAtCaller(
      'OptionsKit.Tree:Execute copy needs "copySource" to be set first',
      function(mark)
        mark()
        tree:Execute("copy")
      end
    )
  end)

  it("propagates a SettingsKit listener's error from Set and keeps working", function()
    local OptionsKit, db = openDatabase()
    local tree = defineProfiles(OptionsKit, db)
    local broken = db:OnProfileChanged(function()
      error("listener broke", 0)
    end)

    local ok, message = pcall(tree.Set, tree, "profiles.new", "Alt")
    assert.is_false(ok)
    assert.are.equal("listener broke", message)
    assert.are.equal("Alt", db:GetProfile())

    -- The link listens again: a later switch elsewhere reaches the tree.
    broken:Disconnect()
    local changes = recordChanges(tree)
    db:SetProfile("Default")
    assert.are.same({ { "profiles.current", "Default" } }, changes)
  end)

  it("refuses a group already defined in a tree, or twice in one, until Undefine", function()
    local OptionsKit, db = openDatabase()
    local group = OptionsKit:ProfileOptions(db)
    OptionsKit:Define("A", { type = "group", args = { profiles = group } })

    assertReportedAtCaller(
      'OptionsKit:Define tree.args.profiles is a profile group already defined in the tree of "A"; Undefine it first',
      function(mark)
        mark()
        OptionsKit:Define("B", { type = "group", args = { profiles = group } })
      end
    )
    assert.is_nil(OptionsKit:Get("B"))

    assert.is_true(OptionsKit:Undefine("A"))
    local other = OptionsKit:ProfileOptions(db)
    local ok, message = pcall(
      OptionsKit.Define,
      OptionsKit,
      "B",
      { type = "group", args = { first = other, second = other } }
    )
    assert.is_false(ok)
    assert.is_truthy(
      tostring(message):find("is a profile group that already appears in this tree", 1, true)
    )
    assert.is_nil(OptionsKit:Get("B"))

    -- A refused Define attached nothing: the group is still free.
    local tree = OptionsKit:Define("B", { type = "group", args = { profiles = group } })
    assert.are.equal("Default", tree:Get("profiles.current"))
  end)

  it("holds two profile groups over two databases in one tree", function()
    local OptionsKit, db = openDatabase()
    local SettingsKit = require("SettingsKit")
    local S = require("SchemaKit")
    setGlobal("OptionsKitOtherDB", nil)
    local other = SettingsKit:Open("OptionsKitOtherDB", {
      profile = S.table({ fields = { scale = S.optional(S.number(), 1) } }),
    })
    local tree = OptionsKit:Define("Addon", {
      type = "group",
      args = {
        first = OptionsKit:ProfileOptions(db),
        second = OptionsKit:ProfileOptions(other),
      },
    })
    local changes = recordChanges(tree)

    other:SetProfile("Alt")
    assert.are.same({ { "second.current", "Alt" } }, changes)
    assert.is_true(tree:Set("first.current", CHARACTER_PROFILE))
    assert.are.equal(CHARACTER_PROFILE, db:GetProfile())
    assert.are.equal("Alt", other:GetProfile())
    assert.are.equal(2, #changes)
    assert.is_true(OptionsKit:Undefine("Addon"))
    setGlobal("OptionsKitOtherDB", nil)
  end)

  it("leaves every group free when a database refuses to connect at Define", function()
    local OptionsKit, db = openDatabase()
    -- A table with the profile methods whose connect raises: it passes the
    -- structural check and fails only when the link attaches.
    local broken = {}
    for _, name in ipairs({
      "GetProfile",
      "SetProfile",
      "GetProfiles",
      "CopyProfile",
      "ResetProfile",
      "DeleteProfile",
    }) do
      broken[name] = function() end
    end
    local made = 0
    broken.OnProfileChanged = function()
      made = made + 1
      return {
        Disconnect = function()
          made = made - 1
        end,
      }
    end
    broken.OnProfileCopied = broken.OnProfileChanged
    broken.OnProfileReset = function()
      error("no signals here", 0)
    end
    broken.OnProfileDeleted = broken.OnProfileChanged

    local good = OptionsKit:ProfileOptions(db)
    local bad = OptionsKit:ProfileOptions(broken)
    local ok, message = pcall(OptionsKit.Define, OptionsKit, "Addon", {
      type = "group",
      args = { good = good, bad = bad },
    })
    assert.is_false(ok)
    assert.are.equal("no signals here", message)
    assert.are.equal(0, made)
    assert.is_nil(OptionsKit:Get("Addon"))

    local links = rawget(OptionsKit, "_state").profileGroups
    assert.is_false(links[good].tree)
    assert.is_false(links[good].connections)
    assert.is_false(links[bad].tree)
    assert.is_false(links[bad].connections)

    -- Both groups can still be defined; the good one works.
    local tree = OptionsKit:Define("Addon", { type = "group", args = { profiles = good } })
    assert.are.equal("Default", tree:Get("profiles.current"))
  end)

  it("refuses malformed options at the caller", function()
    local OptionsKit, db = openDatabase()
    assertReportedAtCaller("OptionsKit:ProfileOptions options must be a table", function(mark)
      mark()
      OptionsKit:ProfileOptions(db, 1)
    end)
    assertReportedAtCaller(
      'OptionsKit:ProfileOptions options contains unknown field "colour"',
      function(mark)
        mark()
        OptionsKit:ProfileOptions(db, { colour = 1, name = "X" })
      end
    )
    assertReportedAtCaller("OptionsKit:ProfileOptions options.name must be a string", function(mark)
      mark()
      OptionsKit:ProfileOptions(db, { name = 1 })
    end)
    assertReportedAtCaller(
      "OptionsKit:ProfileOptions options.order must be a number",
      function(mark)
        mark()
        OptionsKit:ProfileOptions(db, { order = "first" })
      end
    )
    assertReportedAtCaller(
      "OptionsKit:ProfileOptions options.description must be a string",
      function(mark)
        mark()
        OptionsKit:ProfileOptions(db, { description = true })
      end
    )
    assertReportedAtCaller(
      "OptionsKit:ProfileOptions options.localize must be a function",
      function(mark)
        mark()
        OptionsKit:ProfileOptions(db, { localize = {} })
      end
    )
  end)

  it("refuses a secret option at the caller before testing it", function()
    local OptionsKit, db = openDatabase()
    local secret = "Raid profiles"
    setGlobal("issecretvalue", function(value)
      return rawequal(value, secret)
    end)
    for _, field in ipairs({ "name", "description" }) do
      assertReportedAtCaller(
        "OptionsKit:ProfileOptions options." .. field .. " must not be a secret value",
        function(mark)
          mark()
          OptionsKit:ProfileOptions(db, { [field] = secret })
        end
      )
    end
    setGlobal("issecretvalue", nil)
  end)

  it("refuses anything but a SettingsKit database at the caller", function()
    local OptionsKit = openDatabase()
    assertReportedAtCaller(
      "OptionsKit:ProfileOptions db must be a SettingsKit database",
      function(mark)
        mark()
        OptionsKit:ProfileOptions(nil)
      end
    )
    assertReportedAtCaller(
      "OptionsKit:ProfileOptions db must be a SettingsKit database",
      function(mark)
        mark()
        OptionsKit:ProfileOptions({})
      end
    )
    assertReportedAtCaller(
      "OptionsKit:ProfileOptions db must be a SettingsKit database",
      function(mark)
        mark()
        OptionsKit:ProfileOptions({
          GetProfile = function() end,
          SetProfile = function() end,
        })
      end
    )
  end)

  ---Load the chain with SettingsKit and open a database over data a newer
  ---version saved (stored version 9, opened with version 2).
  ---@param allowNewerData boolean?
  ---@return table OptionsKit
  ---@return table db
  local function openNewerDatabase(allowNewerData)
    local OptionsKit = TestEnv.NewPackage()
    installIdentity()
    local SettingsKit = require("SettingsKit")
    local S = require("SchemaKit")
    setGlobal(SAVED_VARIABLE, {
      version = 9,
      profiles = { Default = { scale = 2 }, Alt = { scale = 0.5 } },
    })
    local db = SettingsKit:Open(SAVED_VARIABLE, {
      profile = S.table({
        fields = { scale = S.optional(S.number({ min = 0.5, max = 2 }), 1) },
      }),
    }, { version = 2, allowNewerData = allowNewerData })
    return OptionsKit, db
  end

  local CHANGING_KEYS =
    { "current", "new", "copySource", "copy", "reset", "deleteTarget", "delete" }

  it("disables every option that changes a read-only database and still reads it", function()
    local OptionsKit, db = openNewerDatabase()
    assert.is_true(db:IsReadOnly())
    local tree, group = defineProfiles(OptionsKit, db)
    group.args.copySource.set(nil, "Alt")
    group.args.deleteTarget.set(nil, "Alt")

    for index = 1, #CHANGING_KEYS do
      local key = CHANGING_KEYS[index]
      assert.is_true(tree:IsDisabled("profiles." .. key), key)
      assert.is_true(describeChild(tree, key).disabled, key)
    end
    assert.is_false(tree:IsDisabled("profiles.intro"))
    assert.are.equal("Default", tree:Get("profiles.current"))
    assert.are.same({ Alt = "Alt" }, describeChild(tree, "copySource").values)

    -- `disabled` is for renderers: a Set still reaches SettingsKit, which refuses it.
    TestEnv.expectErrorContaining(
      "SettingsKit.Database:SetProfile cannot change " .. SAVED_VARIABLE .. ", which is read-only",
      function()
        tree:Set("profiles.current", "Alt")
      end
    )
    assert.are.equal("Default", db:GetProfile())
  end)

  it("keeps the options enabled for newer data opened with allowNewerData", function()
    local OptionsKit, db = openNewerDatabase(true)
    assert.is_false(db:IsReadOnly())
    local tree, group = defineProfiles(OptionsKit, db)
    group.args.copySource.set(nil, "Alt")
    group.args.deleteTarget.set(nil, "Alt")

    for index = 1, #CHANGING_KEYS do
      assert.is_false(tree:IsDisabled("profiles." .. CHANGING_KEYS[index]), CHANGING_KEYS[index])
    end
    assert.is_true(tree:Set("profiles.current", "Alt"))
    assert.are.equal("Alt", db:GetProfile())
  end)

  it("counts a database without IsReadOnly, or with a secret answer, as writable", function()
    local OptionsKit, db = openDatabase()
    -- Stand-ins over the real database: an older SettingsKit without the
    -- method, and one whose answer the host reports as secret. The group's
    -- predicates are asked directly; the stand-ins cannot connect signals.
    local legacy = setmetatable({ IsReadOnly = false }, { __index = db })
    assert.is_false(OptionsKit:ProfileOptions(legacy).args.reset.disabled())

    local answer = {}
    local secretive = setmetatable({
      IsReadOnly = function()
        return answer
      end,
    }, { __index = db })
    setGlobal("issecretvalue", function(value)
      return rawequal(value, answer)
    end)
    assert.is_false(OptionsKit:ProfileOptions(secretive).args.reset.disabled())
  end)

  it("refuses to build without SettingsKit, at the caller", function()
    local OptionsKit = TestEnv.NewPackage()
    assertReportedAtCaller(
      "OptionsKit:ProfileOptions needs SettingsKit API 1 to be loaded",
      function(mark)
        mark()
        OptionsKit:ProfileOptions({})
      end
    )
  end)
end)
