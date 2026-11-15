local TestEnv = require("OptionsKitTestEnv")

-- Revision 11: `ProfileOptions` carries one select per spec index over
-- SettingsKit's spec profiles (SettingsKit revision 11), the LibDualSpec-1.0
-- `EnhanceOptions` counterpart. The suite drives a real SettingsKit database:
-- SettingsKit is an optional dependency, so the runner puts its source on
-- `LUA_PATH`.

local SAVED_VARIABLE = "OptionsKitSpecProfileDB"

-- The globals this suite installs and removes. `WOW_PROJECT_ID` belongs to the
-- shared fixture, which clears it.
local INSTALLED_GLOBALS = {
  "UnitName",
  "GetRealmName",
  "UnitClass",
  "C_SpecializationInfo",
  "GetNumTalentGroups",
  "GetSpecializationInfoForClassID",
  "issecretvalue",
}

---Write a host global: the client API lives only in the global table.
---@param name string
---@param value any
local function setGlobal(name, value)
  -- selene: allow(global_usage)
  rawset(_G, name, value)
end

---Install a client whose player is a class with ID 8 and answers from
---`client`, which a spec changes afterwards. `projectId` 1 keys by
---specialization, anything else by talent group.
---@param client table `{ projectId, specialization, classCount, talentGroup, talentGroups, names }`
---@return table client
local function installClient(client)
  setGlobal("UnitName", function()
    return "Tester"
  end)
  setGlobal("GetRealmName", function()
    return "Silvermoon"
  end)
  setGlobal("UnitClass", function()
    return "Mage", "MAGE", 8
  end)
  setGlobal("WOW_PROJECT_ID", client.projectId)
  setGlobal("C_SpecializationInfo", {
    GetSpecialization = function()
      return client.specialization
    end,
    GetNumSpecializationsForClassID = function()
      return client.classCount
    end,
    GetActiveSpecGroup = function()
      return client.talentGroup
    end,
  })
  setGlobal("GetNumTalentGroups", function()
    return client.talentGroups
  end)
  if client.names ~= false then
    setGlobal("GetSpecializationInfoForClassID", function(classID, index)
      local names = client.names or { "Arcane", "Fire", "Frost" }
      if classID == 8 then
        return 60 + index, names[index]
      end
      return nil
    end)
  end
  return client
end

---Load the chain, install `client` (after the fixture's own reset, which
---clears `WOW_PROJECT_ID`), and open a database with SettingsKit.
---@param client table see `installClient`
---@param options table? `SettingsKit:Open` options
---@return table OptionsKit, table db, table SettingsKit
local function openDatabase(client, options)
  local OptionsKit = TestEnv.NewPackage()
  installClient(client)
  local SettingsKit = require("SettingsKit")
  local S = require("SchemaKit")
  local db = SettingsKit:Open(SAVED_VARIABLE, {
    profile = S.table({ fields = { scale = S.optional(S.number(), 1) } }),
  }, options)
  return OptionsKit, db, SettingsKit
end

---Define a tree holding the profile group under `profiles`.
local function defineProfiles(OptionsKit, db, options)
  local group = OptionsKit:ProfileOptions(db, options)
  return OptionsKit:Define("Addon", { type = "group", args = { profiles = group } }), group
end

---The node of `tree:Describe()` at `profiles.<key>`, or `nil`.
local function describeChild(tree, key)
  local group = tree:Describe().children[1]
  for index = 1, #group.children do
    if group.children[index].key == key then
      return group.children[index]
    end
  end
  return nil
end

---Which of `specs`, `spec1` ... `spec8` are shown.
local function shownSpecOptions(tree)
  local shown = {}
  if not tree:IsHidden("profiles.specs") then
    shown[#shown + 1] = "specs"
  end
  for index = 1, 8 do
    if not tree:IsHidden("profiles.spec" .. index) then
      shown[#shown + 1] = "spec" .. index
    end
  end
  return shown
end

describe("OptionsKit ProfileOptions spec profiles", function()
  after_each(function()
    package.loaded["SettingsKit"] = nil
    setGlobal(SAVED_VARIABLE, nil)
    for index = 1, #INSTALLED_GLOBALS do
      setGlobal(INSTALLED_GLOBALS[index], nil)
    end
    TestEnv.Reset()
  end)

  it("shows one select per specialization, named after it", function()
    local OptionsKit, db = openDatabase({ projectId = 1, specialization = 1, classCount = 3 })
    local tree = defineProfiles(OptionsKit, db)

    assert.are.same({ "specs", "spec1", "spec2", "spec3" }, shownSpecOptions(tree))
    local spec2 = describeChild(tree, "spec2")
    assert.are.equal("select", spec2.kind)
    assert.are.equal("Profile for Fire", spec2.name)
    assert.are.equal("The profile this character switches to in Fire.", spec2.desc)
    assert.are.equal(11, spec2.order)
    assert.are.equal("", tree:Get("profiles.spec2"))
  end)

  it("shows the selects only while the character has more than one index", function()
    local client = { projectId = 2, talentGroup = 1, talentGroups = 1 }
    local OptionsKit, db = openDatabase(client)
    local tree = defineProfiles(OptionsKit, db)
    assert.are.same({}, shownSpecOptions(tree))

    client.talentGroups = 2
    assert.are.same({ "specs", "spec1", "spec2" }, shownSpecOptions(tree))
    assert.are.equal("Profile for talent group 2", describeChild(tree, "spec2").name)
  end)

  it("hides the selects while SettingsKit knows no count", function()
    local OptionsKit, db = openDatabase({ projectId = 1, specialization = 1, classCount = 3 })
    local tree = defineProfiles(OptionsKit, db)
    setGlobal("C_SpecializationInfo", nil)
    assert.are.same({}, shownSpecOptions(tree))
  end)

  it("assigns, reads and clears through SettingsKit", function()
    local OptionsKit, db = openDatabase({ projectId = 1, specialization = 1, classCount = 3 })
    local tree = defineProfiles(OptionsKit, db)
    db:SetProfile("Damage")
    db:SetProfile("Default")

    tree:Set("profiles.spec2", "Damage")
    assert.are.equal("Damage", db:GetSpecProfile(2))
    assert.are.equal("Damage", tree:Get("profiles.spec2"))
    assert.are.equal("Default", db:GetProfile())

    tree:Set("profiles.spec2", "")
    assert.is_nil(db:GetSpecProfile(2))
    assert.are.equal("", tree:Get("profiles.spec2"))
  end)

  it("offers every profile, the assigned one and None", function()
    local OptionsKit, db = openDatabase({ projectId = 1, specialization = 1, classCount = 3 })
    db:SetSpecProfile(3, "Never")
    local tree = defineProfiles(OptionsKit, db)
    assert.are.same({
      [""] = "None",
      Default = "Default",
      Never = "Never",
      ["Tester - Silvermoon"] = "Tester - Silvermoon",
    }, describeChild(tree, "spec3").values)
    assert.are.equal("Never", tree:Get("profiles.spec3"))
  end)

  it("switches at once for the current index and tells the tree", function()
    local OptionsKit, db = openDatabase({ projectId = 1, specialization = 2, classCount = 3 })
    db:SetProfile("Raid")
    db:SetProfile("Default")
    local tree = defineProfiles(OptionsKit, db)
    local changes = {}
    tree:OnChange(function(_, path, value)
      changes[#changes + 1] = path .. "=" .. tostring(value)
    end)
    tree:Set("profiles.spec2", "Raid")
    assert.are.equal("Raid", db:GetProfile())
    assert.are.same({ "profiles.current=Raid", "profiles.spec2=Raid" }, changes)
  end)

  it("disables the selects on a read-only database", function()
    setGlobal(SAVED_VARIABLE, { version = 9 })
    local OptionsKit, db = openDatabase(
      { projectId = 1, specialization = 1, classCount = 3 },
      { version = 1 }
    )
    local tree = defineProfiles(OptionsKit, db)
    assert.is_true(db:IsReadOnly())
    assert.is_true(tree:IsDisabled("profiles.spec1"))
  end)

  it("labels a specialization the client does not name by its index", function()
    local OptionsKit, db =
      openDatabase({ projectId = 1, specialization = 1, classCount = 3, names = false })
    local seen = {}
    local tree = defineProfiles(OptionsKit, db, {
      localize = function(key, default)
        seen[key] = true
        return default
      end,
    })
    assert.are.equal("Profile for specialization 2", describeChild(tree, "spec2").name)
    assert.is_true(seen["spec.specialization"])
  end)

  it("labels by index when the client answers no name, a secret or no class", function()
    local secret = {}
    local OptionsKit, db = openDatabase({
      projectId = 1,
      specialization = 1,
      classCount = 3,
      names = { "", secret },
    })
    setGlobal("issecretvalue", function(value)
      return rawequal(value, secret)
    end)
    local tree = defineProfiles(OptionsKit, db)
    assert.are.equal("Profile for specialization 1", describeChild(tree, "spec1").name)
    assert.are.equal("Profile for specialization 2", describeChild(tree, "spec2").name)
    assert.are.equal("Profile for specialization 4", describeChild(tree, "spec4").name)

    OptionsKit:Undefine("Addon")
    setGlobal("UnitClass", function()
      return "Mage", "MAGE", secret
    end)
    local other = OptionsKit:ProfileOptions(db, { name = "Other" })
    assert.are.equal("Profile for specialization 1", other.args.spec1.name)
    setGlobal("UnitClass", nil)
    local third = OptionsKit:ProfileOptions(db, { name = "Third" })
    assert.are.equal("Profile for specialization 1", third.args.spec1.name)
  end)

  it("treats a secret count as unknown", function()
    local secret = {}
    local OptionsKit, db, SettingsKit =
      openDatabase({ projectId = 1, specialization = 1, classCount = 3 })
    setGlobal("issecretvalue", function(value)
      return rawequal(value, secret)
    end)
    local tree = defineProfiles(OptionsKit, db)
    rawset(SettingsKit, "GetSpecIndex", function()
      return nil, secret, "specialization"
    end)
    assert.are.same({}, shownSpecOptions(tree))
  end)

  it("leaves the selects out for a SettingsKit without spec profiles", function()
    local OptionsKit, db = openDatabase({ projectId = 1, specialization = 1, classCount = 3 })
    rawset(db, "SetSpecProfile", false)
    local group = OptionsKit:ProfileOptions(db)
    assert.is_nil(group.args.specs)
    assert.is_nil(group.args.spec1)
    assert.is_not_nil(group.args.current)
  end)

  it("adds the selects once SettingsKit gains spec profiles after the group was cached", function()
    local OptionsKit, db, SettingsKit = openDatabase({
      projectId = 1,
      specialization = 1,
      classCount = 3,
    })
    -- SettingsKit revision 10, before an in-place upgrade to revision 11:
    -- neither the facade nor the database offers spec profiles.
    local getSpecIndex = rawget(SettingsKit, "GetSpecIndex")
    rawset(SettingsKit, "GetSpecIndex", nil)
    local first = OptionsKit:ProfileOptions(db)
    assert.is_nil(first.args.spec1)
    rawset(SettingsKit, "GetSpecIndex", getSpecIndex)

    local second = OptionsKit:ProfileOptions(db)
    assert.are_not.equal(first, second)
    assert.is_table(second.args.spec1)
    assert.are.equal(second, OptionsKit:ProfileOptions(db))
  end)

  it("replaces a cached group an older revision built", function()
    local OptionsKit, db = openDatabase({ projectId = 1, specialization = 1, classCount = 3 })
    local first = OptionsKit:ProfileOptions(db)
    assert.are.equal(first, OptionsKit:ProfileOptions(db))

    -- What revision 10 cached: a link without `specProfiles`, its group
    -- without the selects.
    local state = rawget(OptionsKit, "_state")
    local link = state.profileLinksByDatabase[db]
    link.specProfiles = nil
    for index = 1, 8 do
      first.args["spec" .. index] = nil
    end
    first.args.specs = nil

    local second = OptionsKit:ProfileOptions(db)
    assert.are_not.equal(first, second)
    assert.is_table(second.args.spec1)
    assert.are.equal(second, OptionsKit:ProfileOptions(db))
    -- The older group keeps working where it is held.
    first.args.current.set(nil, "Alt")
    assert.are.equal("Alt", db:GetProfile())
  end)

  it("keeps the selects working across an in-place upgrade", function()
    local client = { projectId = 1, specialization = 1, classCount = 3 }
    local OptionsKit, db = openDatabase(client)
    local tree = defineProfiles(OptionsKit, db)
    db:SetProfile("Damage")
    db:SetProfile("Default")
    local upgraded = TestEnv.LoadRevision(OptionsKit.REVISION + 1)
    assert.are.equal(OptionsKit, upgraded)
    tree:Set("profiles.spec2", "Damage")
    client.specialization = 2
    db:ApplySpecProfile()
    assert.are.equal("Damage", db:GetProfile())
  end)
end)
