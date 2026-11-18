-- The Arguments part (ADR 0001): a core without SchemaKit, the refusal that
-- names the part, the part's own load checks, the Options part's dependency
-- on it, and the in-place upgrade from revision 11, the last core that
-- compiled arguments itself (its file is kept verbatim as a fixture).
local TestEnv = require("CommandKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src
local PART_REFUSAL = "needs CommandKit's Arguments part, which is not loaded: "
  .. "add commandKit\\parts\\CommandKit-Arguments.lua to your embeds.xml"

local function noop() end

---Run `action` and assert it failed with `message` reported at the line after
---the one that called `mark()`, which must be the call into CommandKit.
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

---Load a fixture file and run it, as an addon embedding that older copy does.
---@param name string
---@return any
local function runFixture(name)
  local text, path = TestEnv.ReadFixture(name)
  return assert(loadstring(text, "@" .. path))()
end

describe("CommandKit core without the Arguments part", function()
  local CommandKit
  before_each(function()
    CommandKit = TestEnv.NewPackageAlone()
  end)
  after_each(TestEnv.Reset)

  it("registers and runs plain commands and sub-commands with Registry alone", function()
    local seen = {}
    local scope = CommandKit:CreateScope()
    assert.is_true(scope:Register("tool", {
      description = "A tool.",
      subcommands = {
        say = {
          usage = "<word>",
          handler = function(context, word)
            seen[#seen + 1] = word
            context:Print("said", word)
          end,
        },
      },
    }))
    TestEnv.RunSlash('/tool say "two words"')
    TestEnv.RunSlash("/tool")
    assert.are.same({ "two words" }, seen)
    local lines = TestEnv.ChatLines()
    assert.are.equal("said two words", lines[1])
    assert.are.equal("Usage: /tool <say>", lines[2])
  end)

  it("refuses arguments at the caller and names the file to embed", function()
    local scope = CommandKit:CreateScope()
    assertReportedAtCaller(
      "CommandKit.Scope:Register spec.arguments " .. PART_REFUSAL,
      function(mark)
        mark()
        scope:Register("sum", { handler = noop, arguments = {} })
      end
    )
    assertReportedAtCaller(
      "CommandKit.Scope:Register spec.subcommands.add.arguments " .. PART_REFUSAL,
      function(mark)
        mark()
        scope:Register("calc", { subcommands = { add = { handler = noop, arguments = {} } } })
      end
    )
    assert.is_false(scope:IsRegistered("sum"))
    assert.is_false(scope:IsRegistered("calc"))
  end)
end)

describe("CommandKit Arguments part loading", function()
  after_each(TestEnv.Reset)

  it("requires SchemaKit", function()
    TestEnv.NewPackageAlone()
    local ok, message = pcall(require, "CommandKit-Arguments")
    assert.is_false(ok)
    assert.is_not_nil(
      tostring(message):find(
        "MoltenCodes CommandKit part Arguments requires SchemaKit API 1 to be loaded first",
        1,
        true
      )
    )
  end)

  it("requires a core of revision 12 or later", function()
    TestEnv.NewRevision11Package()
    local ok, message = pcall(require, "CommandKit-Arguments")
    assert.is_false(ok)
    assert.is_not_nil(tostring(message):find("requires CommandKit revision 12 or later", 1, true))
  end)

  it("is what the Options part needs first", function()
    TestEnv.NewPackageWithoutParts()
    local ok, message = pcall(require, "CommandKit-Options")
    assert.is_false(ok)
    assert.is_not_nil(
      tostring(message):find(
        "MoltenCodes CommandKit part Options requires CommandKit's Arguments part to be loaded first",
        1,
        true
      )
    )
  end)

  it("publishes what the Options part reads", function()
    local CommandKit, _, _, SchemaKit = TestEnv.NewPackage()
    local helpers = rawget(rawget(CommandKit, "_state"), "helpers")
    assert.are.equal(SchemaKit, helpers.SchemaKit)
    assert.is_true(helpers.BOOLEAN_WORDS.on)
    assert.are.equal("a|b", helpers.joinValues({ "a", "b" }, "|"))
  end)

  it("serves an Options part of revision 1, which reads the same helpers", function()
    local CommandKit, _, _, _, OptionsKit = TestEnv.NewPackageWithoutParts()
    require("CommandKit-Arguments")
    runFixture("CommandKit-Options-revision1.lua")
    local value = 3
    local tree = OptionsKit:Define("MyAddon", {
      type = "group",
      args = {
        size = {
          type = "range",
          name = "Size",
          min = 1,
          max = 9,
          get = function()
            return value
          end,
          set = function(_, newValue)
            value = newValue
          end,
        },
      },
    })
    local scope = CommandKit:ForAddon("MyAddon")
    local sink = CommandKit:CaptureSink()
    scope:SetSink(sink)
    assert.is_true(scope:BindOptions(tree, "cfg"))
    TestEnv.RunSlash("/cfg set size 7")
    TestEnv.RunSlash("/cfg get size")
    assert.are.equal(7, value)
    -- `set` prints the new value and `get` prints it again.
    assert.are.same({ "size = 7", "size = 7" }, sink:Messages())
  end)
end)

describe("CommandKit Arguments part across core revisions", function()
  after_each(TestEnv.Reset)

  ---Register `/<name>` with one number argument and return what it received.
  ---@param scope table
  ---@param name string
  ---@return number[] received
  local function registerScale(scope, name)
    local received = {}
    assert.is_true(scope:Register(name, {
      arguments = { require("SchemaKit").number({ min = 0.5, max = 2 }) },
      handler = function(_, number)
        received[#received + 1] = number
      end,
    }))
    return received
  end

  it("keeps serving when a newer core loads after it", function()
    local CommandKit = TestEnv.NewPackage()
    local scope = CommandKit:CreateScope()
    local before = registerScale(scope, "scale")

    local upgraded = TestEnv.LoadRevision(CommandKit.REVISION + 1)

    assert.are.equal(CommandKit, upgraded)
    local after = registerScale(scope, "zoom")
    TestEnv.RunSlash("/scale 1.5")
    TestEnv.RunSlash("/zoom 2")
    assert.are.same({ 1.5 }, before)
    assert.are.same({ 2 }, after)
  end)

  it("serves a newer core that loaded before it", function()
    local CommandKit = TestEnv.NewPackageWithoutParts()
    TestEnv.LoadRevision(CommandKit.REVISION + 1)
    require("CommandKit-Arguments")

    local received = registerScale(CommandKit:CreateScope(), "scale")
    TestEnv.RunSlash("/scale 0.5")
    assert.are.same({ 0.5 }, received)
  end)
end)

describe("CommandKit in-place upgrade from revision 11", function()
  after_each(TestEnv.Reset)

  ---Revision 11 with a command whose argument is a number, then the current
  ---core over it, without the Arguments part.
  local function upgradeWithoutPart()
    local previous, SchemaKit = TestEnv.NewRevision11Package()
    local received = {}
    local scope = previous:ForAddon("OldAddon")
    assert.is_true(scope:Register("old", {
      arguments = { SchemaKit.number() },
      handler = function(_, number)
        received[#received + 1] = number
      end,
    }))
    local current = require("CommandKit")
    return previous, current, scope, SchemaKit, received
  end

  it("keeps a revision-11 command with arguments running without the part", function()
    local previous, current, _, _, received = upgradeWithoutPart()
    assert.are.equal(previous, current)
    assert.are.equal(12, current.REVISION)
    TestEnv.RunSlash("/old 42")
    TestEnv.RunSlash("/old nope")
    assert.are.same({ 42 }, received)
    assert.is_not_nil(table.concat(TestEnv.ChatLines(), "\n"):find("/old: argument 1", 1, true))
  end)

  it("hands a Register with arguments to revision 11 while the part is absent", function()
    local _, current, scope, SchemaKit = upgradeWithoutPart()
    local doubled = {}
    assert.is_true(scope:Register("twice", {
      arguments = { SchemaKit.number() },
      handler = function(_, number)
        doubled[#doubled + 1] = number * 2
      end,
    }))
    TestEnv.RunSlash("/twice 4")
    assert.are.same({ 8 }, doubled)
    -- A plain command is the new core's own.
    local plain = {}
    assert.is_true(current:CreateScope():Register("plain", {
      handler = function(_, word)
        plain[#plain + 1] = word
      end,
    }))
    TestEnv.RunSlash("/plain word")
    assert.are.same({ "word" }, plain)
  end)

  it("drops the hand-over once the part loads and serves the older records", function()
    local CommandKit, _, _, _, received = upgradeWithoutPart()
    local state = rawget(CommandKit, "_state")
    assert.is_table(state.legacyArguments)
    require("CommandKit-Arguments")
    assert.is_nil(state.legacyArguments)
    TestEnv.RunSlash("/old 5")
    assert.are.same({ 5 }, received)
  end)

  it("keeps no hand-over when the part was loaded before the upgrade finished", function()
    TestEnv.NewRevision11Package()
    local current = require("CommandKit")
    require("CommandKit-Arguments")
    local state = rawget(current, "_state")
    assert.is_nil(state.legacyArguments)
    assert.is_function(rawget(state.parts, "Arguments").check)
  end)
end)
