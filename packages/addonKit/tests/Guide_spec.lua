-- The getting-started guide's code, run so it cannot rot. Each step of the
-- guide is a complete addon folder under `fixtures/FirstAddon/`, and the
-- guide's last section is the ten-task addon of `fixtures/TenTasks/`
-- (TenTasks_spec.lua runs it). Every step is loaded and logged in on the fake
-- client here.
--
-- The guide marks each code block it shows from a fixture with a comment on
-- the line before the block, `<!-- fixture: FirstAddon/step1/Core.lua -->`;
-- the last spec compares every marked block with its fixture file, leaving
-- out the fixture's `--# selene:` line (the fixtures are linted as test code,
-- where the client's globals are undefined). It is pending until the guide
-- is in the repository as docs/GETTING_STARTED.md.
local TestEnv = require("AddonKitTestEnv")

local FIXTURES = "packages/addonKit/tests/fixtures"
local GUIDE = "docs/GETTING_STARTED.md"
local ADDON_NAME = "FirstAddon"

---Load one step's folder, log in and enter the world; return what it printed.
---@param step string
---@return string[] printed
---@return table settings the Settings stand-in
local function runStep(step)
  local _, settings = TestEnv.InstallClient()
  local printed = {}
  local originalPrint = print
  -- selene: allow(global_usage)
  rawset(_G, "print", function(text)
    printed[#printed + 1] = text
  end)
  local ok, failure = pcall(function()
    TestEnv.LoadAddonFolder(FIXTURES .. "/FirstAddon/" .. step, ADDON_NAME)
    TestEnv.LogIn(ADDON_NAME)
    TestEnv.Emit("PLAYER_ENTERING_WORLD", true, false)
  end)
  -- selene: allow(global_usage)
  rawset(_G, "print", originalPrint)
  assert(ok, failure)
  local errors = TestEnv.ReportedErrors()
  assert.are.equal(0, #errors, tostring(errors[1]))
  return printed, settings
end

describe("AddonKit getting-started guide", function()
  after_each(TestEnv.Reset)

  it("step 1: an addon that greets on login", function()
    local printed = runStep("step1")
    assert.are.same({ "Hello from FirstAddon" }, printed)
  end)

  it("step 2: a database from plain defaults", function()
    local printed = runStep("step2")
    assert.are.same({ "Hello from FirstAddon, login 1" }, printed)
    local addon = TestEnv.Namespace():For(ADDON_NAME):GetAddon()
    assert.are.equal(1, addon.db.profile.scale)
    assert.has_error(function()
      addon.db.profile.scale = 3
    end)
  end)

  it("step 3: an options panel opened by /firstaddon", function()
    local printed, settings = runStep("step3")
    assert.are.equal(1, #printed)
    assert.are.equal("First Addon", settings.addOns[1].name)
    assert.is_true(TestEnv.RunSlash("/firstaddon"))
    assert.are.equal(1, #settings.opened)
  end)

  it("step 4: a minimap button that opens the panel", function()
    local _, settings = runStep("step4")
    local MC = TestEnv.Namespace():For(ADDON_NAME)
    assert.is_table(MC.LauncherKit:Get(ADDON_NAME))
    MC.BrokerKit:Get(ADDON_NAME).OnClick()
    assert.are.equal(1, #settings.opened)
  end)

  it("shows exactly the fixture code in every marked block of the guide", function()
    local file = io.open(GUIDE, "r")
    if file == nil then
      pending(GUIDE .. " is not in the repository yet")
      return
    end
    local text = file:read("*a")
    file:close()
    local blocks = 0
    for fixture, block in string.gmatch(text, "<!%-%- fixture: (%S+) %-%->%s*\n```%a*\n(.-)\n```") do
      blocks = blocks + 1
      local expected =
        string.gsub(TestEnv.ReadFile(FIXTURES .. "/" .. fixture), "^%-%-# selene:[^\n]*\n", "")
      assert.are.equal((string.gsub(expected, "\n$", "")), block, fixture)
    end
    assert.is_true(blocks > 0, "the guide marks no block with its fixture")
    local _, markers = string.gsub(text, "<!%-%- fixture:", "")
    assert.are.equal(markers, blocks, "a fixture marker is not followed by its code block")
  end)
end)
