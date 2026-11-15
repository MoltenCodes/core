-- Host spec of the real-client harness's session passes (tests/client/MoltenCodesTest).
--
-- Run by tooling/tests/test_client_harness.py with the TestKit test
-- environment on the path. The harness file is loaded as the client loads it,
-- with its folder name and private table, over the framework Kits; package
-- test suites are registered through its public API, and `/mct` lines are
-- typed through the slash command it installs.

local TestKitTestEnv = require("TestKitTestEnv")

local HARNESS_FILE = os.getenv("MOLTENCODES_HARNESS_FILE")
local ADDON_NAME = "MoltenCodesTest"
local TEST_ADDON = "MoltenCodesTest_FixtureKit"

---Read a global the fake client owns.
---@param name string
---@return any
local function host(name)
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

---Write a global the fake client owns.
---@param name string
---@param value any
local function setHost(name, value)
  -- selene: allow(global_usage)
  rawset(_G, name, value)
end

---Load the module chain and the harness, register the fixture suites, then log in.
---@return string[] chat the lines the harness printed, filled as it prints
---@return table harness
local function newSession()
  TestKitTestEnv.NewPackage()
  local chat = {}
  setHost("DEFAULT_CHAT_FRAME", {
    AddMessage = function(_, text)
      chat[#chat + 1] = (text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
    end,
  })
  setHost("SlashCmdList", {})
  setHost("MoltenCodesTestResults", {})
  local chunk = assert(loadfile(HARNESS_FILE))
  chunk(ADDON_NAME, {})
  local harness = host("MoltenCodesTest")

  local plain = harness:Suite("fixtureKit", "plain", TEST_ADDON)
  plain:Test("passes", function(ctx)
    ctx:Expect(1):ToBe(1)
  end)
  local interactive = harness:Suite(
    "fixtureKit",
    "clicks",
    TEST_ADDON,
    { interactive = "right-click the fixture frame" }
  )
  interactive:Test("needs the player", function(ctx)
    ctx:Expect(true):ToBe(true)
  end)
  local other = harness:Suite("otherKit", "plain", TEST_ADDON)
  other:Test("fails", function(ctx)
    ctx:Expect(1):ToBe(2)
  end)

  TestKitTestEnv.LoadAddon(ADDON_NAME)
  TestKitTestEnv.LoadAddon(TEST_ADDON)
  TestKitTestEnv.Login()
  TestKitTestEnv.RenderFrames(3)
  return chat, harness
end

---Type one `/mct` line.
---@param line string
local function typeLine(line)
  host("SlashCmdList").MOLTENCODESTEST(line)
end

---Whether a chat line containing `text` was printed.
---@param chat string[]
---@param text string
---@return boolean
local function printed(chat, text)
  for _, line in ipairs(chat) do
    if line:find(text, 1, true) then
      return true
    end
  end
  return false
end

---Render frames until `text` is printed.
---@param chat string[]
---@param text string
local function waitFor(chat, text)
  local reached = TestKitTestEnv.FramesUntil(function()
    return printed(chat, text)
  end, 400)
  assert.is_true(reached, "never printed: " .. text .. "\n" .. table.concat(chat, "\n"))
end

describe("MoltenCodesTest session passes", function()
  after_each(function()
    for _, name in ipairs({ "MoltenCodesTest", "MoltenCodesTestResults", "SlashCmdList" }) do
      setHost(name, nil)
    end
    setHost("DEFAULT_CHAT_FRAME", nil)
    setHost("SLASH_MOLTENCODESTEST1", nil)
    TestKitTestEnv.Reset()
  end)

  it("refuses an interactive option that is not an instruction line", function()
    local _, harness = newSession()
    assert.has_error(function()
      harness:Suite("fixtureKit", "bad", TEST_ADDON, { interactive = true })
    end)
    assert.has_error(function()
      harness:Suite("fixtureKit", "both", TEST_ADDON, { interactive = "x", combat = true })
    end)
  end)

  it("run all leaves the interactive suites out and ends with the pass totals", function()
    local chat = newSession()
    typeLine("run all")
    waitFor(chat, "session pass done")

    assert.is_true(printed(chat, "running fixtureKit, otherKit (unattended pass): 2 suites"))
    assert.is_true(
      printed(
        chat,
        "session pass done: 2 packages, 1 passed, 1 failed, 0 skipped, 0 timed out; 1 interactive suites wait for /mct run guided and 0 combat suites for /mct run combat; /reload to save."
      )
    )
    local saved = host("MoltenCodesTestResults")
    assert.are.equal("unattended", saved["fixtureKit:unattended"].mode)
    assert.are.equal(1, saved["fixtureKit:unattended"].report.totals.tests)
    assert.is_nil(saved["fixtureKit"])
  end)

  it("run guided shows each package's instruction and waits for next", function()
    local chat = newSession()
    typeLine("run guided")
    assert.is_true(printed(chat, "guided 1 of 1: fixtureKit. Get ready, then type /mct next"))
    assert.is_true(printed(chat, "  fixtureKit.clicks: right-click the fixture frame"))
    TestKitTestEnv.RenderFrames(10)
    assert.is_nil(host("MoltenCodesTestResults")["fixtureKit:guided"])

    typeLine("next")
    waitFor(chat, "guided pass done: 1 packages")
    local entry = host("MoltenCodesTestResults")["fixtureKit:guided"]
    assert.are.equal("guided", entry.mode)
    assert.are.equal(1, entry.report.totals.passed)
  end)

  it("skip leaves a package out and next without a waiting package says so", function()
    local chat = newSession()
    typeLine("next")
    assert.is_true(printed(chat, "no guided package is waiting"))
    typeLine("run guided")
    typeLine("skip")
    assert.is_true(printed(chat, "left out fixtureKit; its interactive suites stay not run."))
    assert.is_true(printed(chat, "guided pass done: 1 packages"))
    assert.is_nil(host("MoltenCodesTestResults")["fixtureKit:guided"])
  end)

  it("a plain run still runs every suite under the package's own key", function()
    local chat = newSession()
    typeLine("run fixtureKit")
    waitFor(chat, "fixtureKit: 2 passed")
    assert.are.equal("default", host("MoltenCodesTestResults")["fixtureKit"].mode)
  end)
end)
