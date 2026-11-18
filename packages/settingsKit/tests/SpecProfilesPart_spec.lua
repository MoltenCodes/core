local TestEnv = require("SettingsKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src

---Return the line number of the statement that called this helper.
---@return integer line
local function currentLine()
  return debug.getinfo(2, "l").currentline
end

---Assert that a protected call failed with `message` at `expectedLine` of this
---spec file.
---@param expectedLine integer
---@param message string
---@param ok boolean
---@param value any
local function assertReportedAt(expectedLine, message, ok, value)
  assert.is_false(ok)
  assert.are.equal(SOURCE .. ":" .. expectedLine .. ": " .. message, value)
end

---The message a member of the SpecProfiles part raises without the part.
---@param label string
---@return string
local function missing(label)
  return label
    .. " is in SettingsKit's SpecProfiles part, which is not loaded: "
    .. "add settingsKit\\parts\\SettingsKit-SpecProfiles.lua"
end

-- Spec profiles are SettingsKit's SpecProfiles part (revision 16): the core
-- keeps the saved section consistent without it, and stubs its members.
describe("SettingsKit SpecProfiles part", function()
  local SettingsKit, S

  before_each(function()
    local loaded = { TestEnv.NewCore() }
    SettingsKit, S = loaded[1], loaded[5]
  end)

  after_each(TestEnv.Reset)

  local function schemaFor()
    return { profile = S.table({ fields = { scale = S.optional(S.number(), 1) } }) }
  end

  local function saved()
    return TestEnv.GetGlobal("MyAddonDB")
  end

  local function retail(specialization)
    return TestEnv.SetSpecialization({
      projectId = 1,
      specialization = specialization,
      classCount = 3,
    })
  end

  local function specEvent()
    TestEnv.Emit("PLAYER_SPECIALIZATION_CHANGED", "player")
  end

  it("raises the not-loaded message at the caller's line for every member", function()
    local db = SettingsKit:Open("MyAddonDB", schemaFor())
    local line
    local ok, failure = pcall(function()
      line = currentLine() + 1
      SettingsKit:GetSpecIndex()
    end)
    assertReportedAt(line, missing("SettingsKit:GetSpecIndex"), ok, failure)
    ok, failure = pcall(function()
      line = currentLine() + 1
      db:SetSpecProfile(1, "Healing")
    end)
    assertReportedAt(line, missing("SettingsKit.Database:SetSpecProfile"), ok, failure)
    ok, failure = pcall(function()
      line = currentLine() + 1
      db:GetSpecProfile(1)
    end)
    assertReportedAt(line, missing("SettingsKit.Database:GetSpecProfile"), ok, failure)
    ok, failure = pcall(function()
      line = currentLine() + 1
      db:ApplySpecProfile()
    end)
    assertReportedAt(line, missing("SettingsKit.Database:ApplySpecProfile"), ok, failure)
    ok, failure = pcall(function()
      line = currentLine() + 1
      SettingsKit.GetSpecIndex({})
    end)
    assertReportedAt(
      line,
      "SettingsKit:GetSpecIndex must be called on the SettingsKit facade",
      ok,
      (tostring(failure):gsub(";.*$", ""))
    )
  end)

  it("keeps the saved section right without the part", function()
    TestEnv.SavedVariable("MyAddonDB", {
      profileKeys = { ["Tester - Silvermoon"] = "Default" },
      profiles = { Default = {}, Healing = {}, Damage = {} },
      specProfiles = {
        ["Tester - Silvermoon"] = { "Healing", "Damage" },
        ["Other - Silvermoon"] = { "Healing" },
      },
    })
    local db = SettingsKit:Open("MyAddonDB", schemaFor())
    db:DeleteProfile("Healing")
    assert.are.same({ ["Tester - Silvermoon"] = { [2] = "Damage" } }, saved().specProfiles)
    db:ResetDatabase()
    assert.are.same({}, saved().specProfiles)
  end)

  it("applies assignments at Open only once the part is loaded", function()
    retail(2)
    TestEnv.SavedVariable("MyAddonDB", {
      profileKeys = { ["Tester - Silvermoon"] = "Default" },
      profiles = { Default = {}, Damage = {} },
      specProfiles = { ["Tester - Silvermoon"] = { [2] = "Damage" } },
    })
    local db = SettingsKit:Open("MyAddonDB", schemaFor())
    assert.are.equal("Default", db:GetProfile())
    assert.is_false(SettingsKit._state.specListenerConnected)

    TestEnv.LoadSpecProfiles()
    TestEnv.SavedVariable("OtherDB", {
      profileKeys = { ["Tester - Silvermoon"] = "Default" },
      profiles = { Default = {}, Damage = {} },
      specProfiles = { ["Tester - Silvermoon"] = { [2] = "Damage" } },
    })
    local other = SettingsKit:Open("OtherDB", schemaFor())
    assert.are.equal("Damage", other:GetProfile())
    assert.is_true(SettingsKit._state.specListenerConnected)
    assert.are.same({ 2, 3, "specialization" }, { SettingsKit:GetSpecIndex() })
  end)

  it("answers HasPart without raising, and refuses a name that is not a string", function()
    assert.is_false(SettingsKit:HasPart("SpecProfiles"))
    assert.is_false(SettingsKit:HasPart("Namespaces"))
    assert.is_false(SettingsKit:HasPart("Unknown"))
    TestEnv.LoadSpecProfiles()
    assert.is_true(SettingsKit:HasPart("SpecProfiles"))
    TestEnv.LoadNamespaces()
    assert.is_true(SettingsKit:HasPart("Namespaces"))

    local line
    local ok, failure = pcall(function()
      line = currentLine() + 1
      SettingsKit:HasPart(1)
    end)
    assertReportedAt(line, "SettingsKit:HasPart partName must be a string", ok, failure)
    TestEnv.InstallSecretProbe()
    local secret = TestEnv.NewSecret()
    ok, failure = pcall(function()
      line = currentLine() + 1
      SettingsKit:HasPart(secret)
    end)
    assertReportedAt(line, "SettingsKit:HasPart partName must not be a secret value", ok, failure)
  end)

  it("declares the part in the manifest at the file's revision", function()
    local manifest = assert(io.open("packages/settingsKit/package.manifest.json", "r"))
    local text = manifest:read("*a")
    manifest:close()
    local entry = text:match('"SpecProfiles"%s*:%s*(%b{})')
    assert.is_not_nil(entry)
    local part = assert(io.open("packages/settingsKit/src/parts/SettingsKit-SpecProfiles.lua", "r"))
    local source = part:read("*a")
    part:close()
    assert.are.equal(
      tonumber(entry:match('"revision"%s*:%s*(%d+)')),
      tonumber(source:match("local PART_REVISION = (%d+)"))
    )
    assert.is_not_nil(entry:find('"eventKit"', 1, true))
  end)

  it("refuses to load without the core", function()
    TestEnv.Reset()
    require("Registry")
    local ok, failure = pcall(TestEnv.LoadSpecProfiles)
    assert.is_false(ok)
    assert.is_truthy(
      tostring(failure):find(
        "MoltenCodes SettingsKit part SpecProfiles requires SettingsKit API 1 to be loaded first",
        1,
        true
      )
    )
  end)

  describe("an in-place upgrade from revision 15", function()
    ---Load the chain up to SettingsKit, then the revision 15 fixture.
    ---@return table previous
    local function loadRevision15()
      TestEnv.Reset()
      TestEnv.InstallWowApi()
      require("Registry")
      require("SignalKit")
      require("EventKit")
      S = require("SchemaKit")
      local previous = TestEnv.LoadRevision(15)
      TestEnv.SetPlayer()
      return previous
    end

    it("keeps revision 15's members and switching while the part is absent", function()
      local previous = loadRevision15()
      local client = retail(1)
      local db = previous:Open("MyAddonDB", schemaFor())
      db:SetSpecProfile(2, "Damage")
      local setSpecProfile = previous.Database.SetSpecProfile

      local current = TestEnv.ReloadPackage()
      assert.are.equal(previous, current)
      assert.are.equal(16, current.REVISION)
      assert.are.equal(setSpecProfile, current.Database.SetSpecProfile)
      assert.is_false(current:HasPart("SpecProfiles"))

      client.specialization = 2
      specEvent()
      assert.are.equal("Damage", db:GetProfile())
      assert.are.equal("Damage", db:GetSpecProfile(2))
      db:SetProfile("Manual")
      db:SetSpecProfile(1, "Healing")
      client.specialization = 1
      specEvent()
      assert.are.equal("Healing", db:GetProfile())
      -- The core's DeleteProfile forgets the assignment revision 15 wrote.
      db:SetProfile("Default")
      db:DeleteProfile("Healing")
      assert.is_nil(saved().specProfiles["Tester - Silvermoon"][1])
    end)

    it("hands over to the part once it loads", function()
      local previous = loadRevision15()
      local client = retail(1)
      local db = previous:Open("MyAddonDB", schemaFor())
      db:SetSpecProfile(2, "Damage")
      local oldSetSpecProfile = previous.Database.SetSpecProfile
      local current = TestEnv.ReloadPackage()

      TestEnv.LoadSpecProfiles()
      assert.are_not.equal(oldSetSpecProfile, current.Database.SetSpecProfile)
      assert.is_nil(current._state.legacySpecProfiles)
      assert.is_true(current:HasPart("SpecProfiles"))
      client.specialization = 2
      specEvent()
      assert.are.equal("Damage", db:GetProfile())
    end)

    it("cannot serve a revision 15 copy loaded after revision 16 without the part", function()
      -- The documented limit: the older copy yields to the loaded core, so
      -- its addon reaches the stubs until some addon embeds the part.
      local yielded = TestEnv.LoadRevision(15)
      assert.are.equal(SettingsKit, yielded)
      local ok, failure = pcall(yielded.GetSpecIndex, yielded)
      assert.is_false(ok)
      assert.is_truthy(tostring(failure):find(missing("SettingsKit:GetSpecIndex"), 1, true))
      TestEnv.LoadSpecProfiles()
      retail(1)
      assert.are.same({ 1, 3, "specialization" }, { yielded:GetSpecIndex() })
    end)
  end)
end)
