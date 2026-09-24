local TestEnv = require("CommandKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src

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

local function noop() end

---A spec with `count` sub-commands named `s1..s<count>`.
local function specWithSubcommands(count)
  local subcommands = {}
  for index = 1, count do
    subcommands["s" .. index] = { handler = noop }
  end
  return { subcommands = subcommands }
end

---A spec with `count` optional string positions and a handler recording how
---many arguments it received.
local function specWithPositions(SchemaKit, count, received)
  local arguments = {}
  for index = 1, count do
    arguments[index] = SchemaKit.optional(SchemaKit.string())
  end
  return {
    arguments = arguments,
    handler = function(_, ...)
      received.count = select("#", ...)
    end,
  }
end

---Another addon's slash command whose `alias`-th alias is `/late`.
local function installForeignAliases(alias)
  TestEnv.GetGlobal("SlashCmdList").OTHERADDON = noop
  for index = 1, alias - 1 do
    TestEnv.SetGlobal("SLASH_OTHERADDON" .. index, "/other" .. index)
  end
  TestEnv.SetGlobal("SLASH_OTHERADDON" .. alias, "/late")
end

describe("CommandKit limits", function()
  local CommandKit, SchemaKit
  before_each(function()
    local _
    CommandKit, _, _, SchemaKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  describe("scope options", function()
    it("enforce maxCommands: default, a smaller option and UNBOUNDED", function()
      local default = CommandKit:CreateScope()
      for index = 1, 64 do
        assert.is_true(default:Register("d" .. index, { handler = noop }))
      end
      assert.are.same({ nil, "full" }, { default:Register("dmore", { handler = noop }) })

      local small = CommandKit:CreateScope({ maxCommands = 2 })
      assert.is_true(small:Register("sa", { handler = noop }))
      assert.is_true(small:Register("sb", { handler = noop }))
      assert.are.same({ nil, "full" }, { small:Register("sc", { handler = noop }) })

      local open = CommandKit:CreateScope({ maxCommands = CommandKit.UNBOUNDED })
      for index = 1, 100 do
        assert.is_true(open:Register("u" .. index, { handler = noop }))
      end
      assert.are.equal(100, open:GetActiveCount())
    end)

    it("enforce maxSubcommands: default, a larger option and UNBOUNDED", function()
      assertReportedAtCaller(
        "CommandKit.Scope:Register spec.subcommands declares more than 64 sub-commands",
        function(mark)
          local scope = CommandKit:CreateScope()
          mark()
          scope:Register("many", specWithSubcommands(65))
        end
      )
      local larger = CommandKit:CreateScope({ maxSubcommands = 65 })
      assert.is_true(larger:Register("many", specWithSubcommands(65)))
      local open = CommandKit:CreateScope({ maxSubcommands = CommandKit.UNBOUNDED })
      assert.is_true(open:Register("lots", specWithSubcommands(200)))
      TestEnv.RunSlash("/lots s200")
    end)

    it("enforce maxPositions: default, a larger option and UNBOUNDED", function()
      local received = {}
      assertReportedAtCaller(
        "CommandKit.Scope:Register spec.arguments must be a list of at most 16 schemas",
        function(mark)
          local scope = CommandKit:CreateScope()
          mark()
          scope:Register("wide", specWithPositions(SchemaKit, 17, received))
        end
      )
      local larger = CommandKit:CreateScope({ maxPositions = 17 })
      assert.is_true(larger:Register("wide", specWithPositions(SchemaKit, 17, received)))
      local open = CommandKit:CreateScope({ maxPositions = CommandKit.UNBOUNDED })
      assert.is_true(open:Register("wider", specWithPositions(SchemaKit, 40, received)))
      TestEnv.RunSlash("/wider a b c")
      assert.are.equal(40, received.count)
    end)

    it("enforce maxSlashAliases: default, a larger option and UNBOUNDED", function()
      installForeignAliases(20)
      local default = CommandKit:CreateScope()
      assert.is_true(default:Register("late", { handler = noop }))
      default:Close()

      local larger = CommandKit:CreateScope({ maxSlashAliases = 20 })
      assert.are.same({ nil, "taken" }, { larger:Register("late", { handler = noop }) })
      local open = CommandKit:CreateScope({ maxSlashAliases = CommandKit.UNBOUNDED })
      assert.are.same({ nil, "taken" }, { open:Register("late", { handler = noop }) })
    end)

    it("refuse invalid values at the caller", function()
      local invalid = { 0, -1, 1.5, 0 / 0, math.huge, "8", {}, true }
      local fields = { "maxCommands", "maxSubcommands", "maxPositions", "maxSlashAliases" }
      for _, field in ipairs(fields) do
        for _, value in ipairs(invalid) do
          assertReportedAtCaller(
            "CommandKit:CreateScope options."
              .. field
              .. " must be a positive integer or CommandKit.UNBOUNDED",
            function(mark)
              mark()
              CommandKit:CreateScope({ [field] = value })
            end
          )
        end
      end
      assertReportedAtCaller(
        "CommandKit:ForAddon options.maxEntries is not a recognised option",
        function(mark)
          mark()
          CommandKit:ForAddon("MyAddon", { maxEntries = 4 })
        end
      )
      assertReportedAtCaller("CommandKit:CreateScope options must be a table", function(mark)
        mark()
        CommandKit:CreateScope(8)
      end)
    end)

    it("apply ForAddon options on creation and refuse a later conflicting one", function()
      local scope = CommandKit:ForAddon("MyAddon", { maxCommands = 1 })
      assert.are.equal(scope, CommandKit:ForAddon("MyAddon"))
      assert.are.equal(scope, CommandKit:ForAddon("MyAddon", { maxCommands = 1 }))
      assert.is_true(scope:Register("one", { handler = noop }))
      assert.are.same({ nil, "full" }, { scope:Register("two", { handler = noop }) })
      assertReportedAtCaller(
        "CommandKit:ForAddon options.maxCommands differs from the limit this addon's scope was created with",
        function(mark)
          mark()
          CommandKit:ForAddon("MyAddon", { maxCommands = CommandKit.UNBOUNDED })
        end
      )
    end)
  end)

  describe("SetLimits and GetLimits", function()
    it("report the defaults in a fresh table on every call", function()
      local first = CommandKit:GetLimits()
      assert.are.same({ maxCaptured = 256, maxCompletions = 32, maxEmotes = 1024 }, first)
      first.maxCaptured = 1
      assert.are_not.equal(first, CommandKit:GetLimits())
      assert.are.equal(256, CommandKit:GetLimits().maxCaptured)
    end)

    it("enforce maxCaptured: default, a set value and UNBOUNDED", function()
      local function capture(lines)
        local sink = CommandKit:CaptureSink()
        for index = 1, lines do
          sink:AddMessage("line " .. index)
        end
        return sink:Messages()
      end
      assert.are.equal(256, #capture(300))
      CommandKit:SetLimits({ maxCaptured = 3 })
      assert.are.same({ "line 3", "line 4", "line 5" }, capture(5))
      CommandKit:SetLimits({ maxCaptured = CommandKit.UNBOUNDED })
      assert.are.equal(300, #capture(300))
      assert.are.equal(CommandKit.UNBOUNDED, CommandKit:GetLimits().maxCaptured)
    end)

    it("enforce maxCompletions: default, a set value, the ceiling and no UNBOUNDED", function()
      local words = {}
      for index = 1, 40 do
        words[index] = string.char(64 + index) .. "x"
      end
      local scope = CommandKit:CreateScope()
      local sink = CommandKit:CaptureSink()
      scope:SetSink(sink)
      scope:Register("pick", {
        handler = noop,
        complete = function()
          return words
        end,
      })
      scope:EnableCompletion()
      local function offered()
        sink:Clear()
        assert.is_true(TestEnv.PressTab(TestEnv.NewEditBox("/pick ")))
        local line = sink:Messages()[1]
        local count = 0
        for _ in line:gmatch("%S+") do
          count = count + 1
        end
        return count
      end
      assert.are.equal(32, offered())
      CommandKit:SetLimits({ maxCompletions = 2 })
      assert.are.equal(2, offered())
      CommandKit:SetLimits({ maxCompletions = 256 })
      assert.are.equal(40, offered())
      assertReportedAtCaller(
        "CommandKit:SetLimits limits.maxCompletions cannot be CommandKit.UNBOUNDED: the candidates are printed to the shared chat frame as one line",
        function(mark)
          mark()
          CommandKit:SetLimits({ maxCompletions = CommandKit.UNBOUNDED })
        end
      )
      assertReportedAtCaller(
        "CommandKit:SetLimits limits.maxCompletions must be an integer from 1 to 256",
        function(mark)
          mark()
          CommandKit:SetLimits({ maxCompletions = 257 })
        end
      )
    end)

    it("enforce maxEmotes: default, a set value, the ceiling and no UNBOUNDED", function()
      local scope = CommandKit:CreateScope()
      assert.are.same({ nil, "emote" }, { scope:Register("wave", { handler = noop }) })
      CommandKit:SetLimits({ maxEmotes = 1 })
      assert.is_true(scope:Register("wave", { handler = noop }))
      assert.are.same({ nil, "emote" }, { scope:Register("dance", { handler = noop }) })
      CommandKit:SetLimits({ maxEmotes = 16384 })
      assertReportedAtCaller(
        "CommandKit:SetLimits limits.maxEmotes cannot be CommandKit.UNBOUNDED: emote indexes have gaps, so the scan needs an end",
        function(mark)
          mark()
          CommandKit:SetLimits({ maxEmotes = CommandKit.UNBOUNDED })
        end
      )
      assertReportedAtCaller(
        "CommandKit:SetLimits limits.maxEmotes must be an integer from 1 to 16384",
        function(mark)
          mark()
          CommandKit:SetLimits({ maxEmotes = 16385 })
        end
      )
    end)

    it("refuse invalid updates at the caller and change nothing", function()
      local before = CommandKit:GetLimits()
      for _, value in ipairs({ 0, -1, 1.5, 0 / 0, math.huge, "8", {} }) do
        assertReportedAtCaller(
          "CommandKit:SetLimits limits.maxCaptured must be a positive integer or CommandKit.UNBOUNDED",
          function(mark)
            mark()
            CommandKit:SetLimits({ maxCompletions = 4, maxCaptured = value })
          end
        )
      end
      assertReportedAtCaller(
        "CommandKit:SetLimits limits.maxBuses is not a recognised limit",
        function(mark)
          mark()
          CommandKit:SetLimits({ maxEmotes = 4, maxBuses = 4 })
        end
      )
      assertReportedAtCaller(
        "CommandKit:SetLimits limits.1 is not a recognised limit",
        function(mark)
          mark()
          CommandKit:SetLimits({ 4 })
        end
      )
      assertReportedAtCaller("CommandKit:SetLimits limits must be a table", function(mark)
        mark()
        CommandKit:SetLimits(nil)
      end)
      assertReportedAtCaller(
        "CommandKit:SetLimits must be called on the CommandKit facade; use CommandKit:SetLimits(...)",
        function(mark)
          mark()
          CommandKit.SetLimits({})
        end
      )
      assert.are.same(before, CommandKit:GetLimits())
    end)
  end)

  describe("across an upgrade", function()
    it("keep the sentinel, the set limits and the scope limits", function()
      local sentinel = CommandKit.UNBOUNDED
      assert.are.equal("table", type(sentinel))
      CommandKit:SetLimits({ maxCaptured = sentinel, maxEmotes = 7 })
      local scope = CommandKit:CreateScope({ maxCommands = sentinel })
      for index = 1, 70 do
        scope:Register("c" .. index, { handler = noop })
      end

      local upgraded = TestEnv.LoadRevision(CommandKit.REVISION + 1)
      assert.are.equal(CommandKit, upgraded)
      assert.are.equal(sentinel, upgraded.UNBOUNDED)
      assert.are.same(
        { maxCaptured = sentinel, maxCompletions = 32, maxEmotes = 7 },
        upgraded:GetLimits()
      )
      assert.is_true(scope:Register("after", { handler = noop }))
      assert.are.equal(71, scope:GetActiveCount())
    end)
  end)
end)
