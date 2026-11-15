local Env = require("ClientKitTestEnv")

-- The file name the `debugstack` stand-in places every frame under, so a
-- report's site reads `Interface/AddOns/MyAddon/Deprecation_spec.lua:<line>`.
local SPEC_FILE = string.match(debug.getinfo(1, "S").short_src, "[^/\\]+$")

---Return the line number of the statement that called this helper.
---@return integer line
local function currentLine()
  return debug.getinfo(2, "l").currentline
end

---The site a report names for `line` of this spec, in the default form.
---@param line integer
---@param addon string?
---@return string
local function siteAt(line, addon)
  return "Interface/AddOns/" .. (addon or "MyAddon") .. "/" .. SPEC_FILE .. ":" .. line
end

---Measures the allocation a workload causes, in kilobytes, with the collector
---stopped so that a collection cycle cannot hide or invent growth.
local function allocatedKilobytes(workload)
  collectgarbage()
  collectgarbage("stop")
  local before = collectgarbage("count")
  workload()
  local after = collectgarbage("count")
  collectgarbage("restart")
  return after - before
end

---A stand-in for a Kit's deprecated method: it warns with the default level,
---so the report names whoever called it. It is called as a statement, never
---tail-called, so its caller's frame stays on the stack.
---@param reporter ClientKit.DeprecationReporter
---@return fun(addonName: string?)
local function deprecatedMethod(reporter)
  return function(addonName)
    reporter:Warn(nil, addonName)
  end
end

---The spec most tests declare.
local AFTER_SPEC = {
  name = "TimerKit:After",
  replacement = "TimerKit:Delay",
  removal = "TimerKit API 2",
}

---Load ClientKit on Retail with a `debugstack` stand-in and the host error
---handler captured.
---@param debugStack ClientKitTestEnv.DebugStackOptions|false|nil `false` for a host without `debugstack`
---@param hostOptions ClientKitTestEnv.HostOptions?
---@return table ClientKit
---@return table Registry
local function newClientKit(debugStack, hostOptions)
  hostOptions = hostOptions or {}
  if debugStack ~= false then
    hostOptions.debugStack = debugStack or {}
  end
  local ClientKit, Registry = Env.NewPackageFor("mainline", hostOptions)
  Env.InstallHostErrorHandler()
  return ClientKit, Registry
end

describe("ClientKit deprecations", function()
  after_each(function()
    Env.Reset()
  end)

  describe("reporting", function()
    it("reports once per call site through the host error handler", function()
      local ClientKit = newClientKit()
      local after = deprecatedMethod(ClientKit:Deprecate(AFTER_SPEC))

      local line
      for _ = 1, 3 do
        line = currentLine() + 1
        after()
      end

      assert.are.same({
        "MoltenCodes: TimerKit:After is deprecated; use TimerKit:Delay. Removal: TimerKit API 2. "
          .. "Called from MyAddon ("
          .. siteAt(line)
          .. ").",
      }, Env.ReportedErrors())
      assert.are.same({
        {
          name = "TimerKit:After",
          replacement = "TimerKit:Delay",
          removal = "TimerKit API 2",
          addon = "MyAddon",
          site = siteAt(line),
        },
      }, ClientKit:GetDeprecationReports())
    end)

    it("reports two call sites twice", function()
      local ClientKit = newClientKit()
      local after = deprecatedMethod(ClientKit:Deprecate(AFTER_SPEC))

      local firstLine = currentLine() + 1
      after()
      local secondLine = currentLine() + 1
      after()

      local reports = ClientKit:GetDeprecationReports()
      assert.are.equal(2, #reports)
      assert.are.equal(siteAt(firstLine), reports[1].site)
      assert.are.equal(siteAt(secondLine), reports[2].site)
      assert.are.equal(2, #Env.ReportedErrors())
    end)

    it("reports once per addon when the Kit names it, and stops asking debugstack", function()
      local ClientKit = newClientKit({ addon = "SomeoneElse" })
      local after = deprecatedMethod(ClientKit:Deprecate(AFTER_SPEC))

      local line = currentLine() + 1
      after("MyAddon")
      after("MyAddon")
      after("MyAddon")
      after("OtherAddon")

      local reports = ClientKit:GetDeprecationReports()
      assert.are.equal(2, #reports)
      -- The addon the Kit names wins over the folder of the frame.
      assert.are.equal("MyAddon", reports[1].addon)
      assert.are.equal(siteAt(line, "SomeoneElse"), reports[1].site)
      assert.are.equal("OtherAddon", reports[2].addon)
      -- One frame read per addon, none for the repeated calls.
      assert.are.equal(2, Env.DebugStackCalls())
    end)

    it("leaves out the replacement when the spec has none", function()
      local ClientKit = newClientKit()
      local reporter = ClientKit:Deprecate({ name = "EventKit API 1", removal = "2027" })
      local line = currentLine() + 1
      deprecatedMethod(reporter)()

      assert.are.same({
        "MoltenCodes: EventKit API 1 is deprecated. Removal: 2027. Called from MyAddon ("
          .. siteAt(line)
          .. ").",
      }, Env.ReportedErrors())
      assert.is_nil(ClientKit:GetDeprecationReports()[1].replacement)
    end)

    it("honours an explicit level for a Kit that warns from a helper", function()
      local ClientKit = newClientKit()
      local reporter = ClientKit:Deprecate(AFTER_SPEC)
      local function warnFromHelper()
        -- Level 1 is this helper, 2 the Kit's method, 3 the consumer.
        reporter:Warn(3)
      end
      local function kitMethod()
        warnFromHelper()
      end

      local line = currentLine() + 1
      kitMethod()

      assert.are.equal(siteAt(line), ClientKit:GetDeprecationReports()[1].site)
    end)

    it("hands out fresh report rows", function()
      local ClientKit = newClientKit()
      deprecatedMethod(ClientKit:Deprecate(AFTER_SPEC))()

      local rows = ClientKit:GetDeprecationReports()
      rows[1].addon = "Changed"
      rows[2] = { name = "Invented" }

      local again = ClientKit:GetDeprecationReports()
      assert.are.equal(1, #again)
      assert.are.equal("MyAddon", again[1].addon)
      assert.are_not.equal(rows[1], again[1])
    end)

    it("returns the same reporter for a name declared again, with the newer text", function()
      local ClientKit = newClientKit()
      local first = ClientKit:Deprecate(AFTER_SPEC)
      local second = ClientKit:Deprecate({ name = "TimerKit:After", removal = "TimerKit API 3" })

      assert.are.equal(first, second)
      assert.are.equal(1, ClientKit._state.deprecation.count)
      deprecatedMethod(second)()
      local report = ClientKit:GetDeprecationReports()[1]
      assert.are.equal("TimerKit API 3", report.removal)
      assert.is_nil(report.replacement)
    end)

    it("costs nothing until a Kit deprecates something", function()
      local ClientKit = newClientKit()
      local deprecation = ClientKit._state.deprecation
      assert.are.same({}, deprecation.reporters)
      assert.are.same({}, deprecation.reports)
      assert.are.equal(0, deprecation.count)
      assert.is_false(deprecation.inert)
      assert.are.equal(0, Env.DebugStackCalls())
    end)

    it("allocates nothing for a repeated warning of a known addon #allocation", function()
      local ClientKit = newClientKit()
      local after = deprecatedMethod(ClientKit:Deprecate(AFTER_SPEC))
      after("MyAddon")
      assert.are.equal(
        0,
        allocatedKilobytes(function()
          for _ = 1, 1000 do
            after("MyAddon")
          end
        end)
      )
    end)
  end)

  describe("call sites", function()
    for _, case in ipairs({
      { form = "bracket", label = "the bracketed form the Retail client writes" },
      { form = "string", label = 'the [string "@..."] form with backslashes' },
      { form = "plain", label = "a bare path with backslashes" },
    }) do
      it("names the addon and the location from " .. case.label, function()
        local ClientKit = newClientKit({ form = case.form, addon = "Other", more = true })
        local line = currentLine() + 1
        deprecatedMethod(ClientKit:Deprecate(AFTER_SPEC))()

        local report = ClientKit:GetDeprecationReports()[1]
        assert.are.equal("Other", report.addon)
        assert.are.equal(siteAt(line, "Other"), report.site)
      end)
    end

    it("names no addon for a frame outside Interface/AddOns and keeps its text", function()
      local ClientKit = newClientKit({
        answer = function()
          return '  [string "MyChunk"]:3: in main chunk\n...\n'
        end,
      })
      deprecatedMethod(ClientKit:Deprecate(AFTER_SPEC))()

      local report = ClientKit:GetDeprecationReports()[1]
      assert.are.equal("unknown", report.addon)
      assert.are.equal('[string "MyChunk"]:3: in main chunk', report.site)
    end)

    it("treats an empty or blank answer as no site", function()
      for _, answer in ipairs({ "", "  \n" }) do
        local ClientKit = newClientKit({
          answer = function()
            return answer
          end,
        })
        local after = deprecatedMethod(ClientKit:Deprecate(AFTER_SPEC))
        after()
        after()

        local reports = ClientKit:GetDeprecationReports()
        assert.are.equal(1, #reports)
        assert.are.equal("unknown", reports[1].addon)
        assert.is_nil(reports[1].site)
        Env.Reset()
      end
    end)

    it("reports once per deprecation on a host without debugstack", function()
      local ClientKit = newClientKit(false)
      local after = deprecatedMethod(ClientKit:Deprecate(AFTER_SPEC))
      after()
      after()
      after("MyAddon")
      after("MyAddon")

      assert.are.same({
        "MoltenCodes: TimerKit:After is deprecated; use TimerKit:Delay. Removal: TimerKit API 2. "
          .. "Called from unknown.",
        "MoltenCodes: TimerKit:After is deprecated; use TimerKit:Delay. Removal: TimerKit API 2. "
          .. "Called from MyAddon.",
      }, Env.ReportedErrors())
    end)

    it("ignores a secret frame line", function()
      local ClientKit = newClientKit({
        answer = function()
          return "SECRET_FRAME"
        end,
      }, { secretStrings = { "SECRET_FRAME" } })
      local after = deprecatedMethod(ClientKit:Deprecate(AFTER_SPEC))
      after()
      after()

      local reports = ClientKit:GetDeprecationReports()
      assert.are.equal(1, #reports)
      assert.is_nil(reports[1].site)
      assert.are.equal("unknown", reports[1].addon)
    end)
  end)

  describe("delivery", function()
    it("prints the report on a host without geterrorhandler", function()
      local ClientKit = Env.NewPackageFor("mainline", { debugStack = {} })
      -- selene: allow(global_usage)
      rawset(_G, "geterrorhandler", nil)
      local printed = {}
      -- selene: allow(global_usage)
      local originalPrint = rawget(_G, "print")
      -- selene: allow(global_usage)
      rawset(_G, "print", function(message)
        printed[#printed + 1] = message
      end)
      local ok, failure = pcall(deprecatedMethod(ClientKit:Deprecate(AFTER_SPEC)))
      -- selene: allow(global_usage)
      rawset(_G, "print", originalPrint)

      assert.is_true(ok, failure)
      assert.are.equal(1, #printed)
      assert.truthy(string.find(printed[1], "TimerKit:After is deprecated", 1, true))
    end)

    it("never raises when the error handler fails", function()
      local ClientKit = Env.NewPackageFor("mainline", { debugStack = {} })
      -- selene: allow(global_usage)
      rawset(_G, "geterrorhandler", function()
        return function()
          error("handler failed")
        end
      end)
      local after = deprecatedMethod(ClientKit:Deprecate(AFTER_SPEC))
      assert.has_no.errors(function()
        after()
      end)
      assert.are.equal(1, #ClientKit:GetDeprecationReports())
    end)
    it("survives a handler that warns again from inside the report", function()
      local ClientKit = Env.NewPackageFor("mainline", { debugStack = {} })
      local reporter = ClientKit:Deprecate(AFTER_SPEC)
      local other = ClientKit:Deprecate({ name = "TimerKit:Every", removal = "TimerKit API 2" })
      local delivered = 0
      -- The handler re-enters ClientKit for the same addon and for another
      -- reporter. The once-key and the row are written before the handler
      -- runs, so the first re-entry is answered as already reported and
      -- only the second reporter adds one report of its own.
      -- selene: allow(global_usage)
      rawset(_G, "geterrorhandler", function()
        return function()
          delivered = delivered + 1
          reporter:Warn(1, "MyAddon")
          other:Warn(1, "MyAddon")
        end
      end)

      reporter:Warn(1, "MyAddon")

      assert.are.equal(2, delivered)
      local reports = ClientKit:GetDeprecationReports()
      assert.are.equal(2, #reports)
      assert.are.equal("TimerKit:After", reports[1].name)
      assert.are.equal("TimerKit:Every", reports[2].name)
    end)
  end)

  describe("modes", function()
    it("starts in report mode", function()
      local ClientKit = newClientKit()
      assert.are.equal("report", ClientKit:GetDeprecationMode())
    end)

    it("records without reporting in silent mode", function()
      local ClientKit = newClientKit()
      ClientKit:SetDeprecationMode("silent")
      deprecatedMethod(ClientKit:Deprecate(AFTER_SPEC))()

      assert.are.equal("silent", ClientKit:GetDeprecationMode())
      assert.are.same({}, Env.ReportedErrors())
      assert.are.equal(1, #ClientKit:GetDeprecationReports())
    end)

    it("raises at the consumer's line on every call in raise mode and records nothing", function()
      local ClientKit = newClientKit()
      ClientKit:SetDeprecationMode("raise")
      local after = deprecatedMethod(ClientKit:Deprecate(AFTER_SPEC))
      local source = debug.getinfo(1, "S").short_src

      for _ = 1, 2 do
        local line
        local ok, message = pcall(function()
          line = currentLine() + 1
          after()
        end)
        assert.is_false(ok)
        assert.are.equal(
          source
            .. ":"
            .. line
            .. ": MoltenCodes: TimerKit:After is deprecated; use TimerKit:Delay. "
            .. "Removal: TimerKit API 2. Called from MyAddon ("
            .. siteAt(line)
            .. ").",
          message
        )
      end
      assert.are.same({}, ClientKit:GetDeprecationReports())
      assert.are.same({}, Env.ReportedErrors())
    end)

    it("raises with an explicit level and without a site on a host without debugstack", function()
      local ClientKit = newClientKit(false)
      ClientKit:SetDeprecationMode("raise")
      local reporter = ClientKit:Deprecate(AFTER_SPEC)
      local function kitMethod()
        reporter:Warn(2, "MyAddon")
      end
      local source = debug.getinfo(1, "S").short_src

      local line
      local ok, message = pcall(function()
        line = currentLine() + 1
        kitMethod()
      end)
      assert.is_false(ok)
      assert.are.equal(
        source
          .. ":"
          .. line
          .. ": MoltenCodes: TimerKit:After is deprecated; use TimerKit:Delay. "
          .. "Removal: TimerKit API 2. Called from MyAddon.",
        message
      )
    end)

    it("refuses an unknown or secret mode and keeps the current one", function()
      local ClientKit = newClientKit(nil, { secretStrings = { "raise" } })
      assert.has_error(function()
        ClientKit:SetDeprecationMode("loud")
      end, 'ClientKit:SetDeprecationMode mode must be "report", "silent" or "raise"')
      assert.has_error(function()
        ClientKit:SetDeprecationMode("raise")
      end, "ClientKit:SetDeprecationMode mode must not be a secret value")
      assert.are.equal("report", ClientKit:GetDeprecationMode())
    end)
  end)

  describe("limits", function()
    it("answers the defaults as a fresh table", function()
      local ClientKit = newClientKit()
      local limits = ClientKit:GetLimits()
      assert.are.same({ maxDeprecations = 128, maxReports = 256 }, limits)
      limits.maxReports = 1
      assert.are.equal(256, ClientKit:GetLimits().maxReports)
    end)

    it("changes any subset up to the ceilings", function()
      local ClientKit = newClientKit()
      ClientKit:SetLimits({ maxReports = 4096 })
      assert.are.same({ maxDeprecations = 128, maxReports = 4096 }, ClientKit:GetLimits())
      ClientKit:SetLimits({ maxDeprecations = 1024, maxReports = 1 })
      assert.are.same({ maxDeprecations = 1024, maxReports = 1 }, ClientKit:GetLimits())
    end)

    it("refuses a limit name the host reports secret without formatting it", function()
      local ClientKit = newClientKit(nil, { secretStrings = { "maxReports" } })
      assert.has_error(function()
        ClientKit:SetLimits({ maxReports = 8 })
      end, "ClientKit:SetLimits does not know limit <secret value>")
      assert.are.equal(256, ClientKit:GetLimits().maxReports)
    end)

    it("refuses a bad limit and changes nothing", function()
      local ClientKit = newClientKit()
      local refusals = {
        {
          { maxReports = 0 },
          "ClientKit:SetLimits limits.maxReports must be an integer from 1 to 4096",
        },
        {
          { maxReports = 4097 },
          "ClientKit:SetLimits limits.maxReports must be an integer from 1 to 4096",
        },
        {
          { maxReports = 1.5 },
          "ClientKit:SetLimits limits.maxReports must be an integer from 1 to 4096",
        },
        {
          { maxDeprecations = 2, maxReports = "8" },
          "ClientKit:SetLimits limits.maxReports must be an integer from 1 to 4096",
        },
        {
          { maxDeprecations = 1025 },
          "ClientKit:SetLimits limits.maxDeprecations must be an integer from 1 to 1024",
        },
        { { maxCalls = 1 }, 'ClientKit:SetLimits does not know limit "maxCalls"' },
        { { [1] = 1 }, "ClientKit:SetLimits does not know limit 1" },
        { "all", "ClientKit:SetLimits limits must be a table" },
        {
          { maxDeprecations = Env.NewSecretValue() },
          "ClientKit:SetLimits limits.maxDeprecations must not be a secret value",
        },
        { Env.NewSecretValue(), "ClientKit:SetLimits limits must not be a secret value" },
      }
      for _, refusal in ipairs(refusals) do
        assert.has_error(function()
          ClientKit:SetLimits(refusal[1])
        end, refusal[2])
      end
      assert.are.same({ maxDeprecations = 128, maxReports = 256 }, ClientKit:GetLimits())
    end)

    it("hands out one inert reporter past maxDeprecations and reports the limit once", function()
      local ClientKit = newClientKit()
      ClientKit:SetLimits({ maxDeprecations = 1 })
      local kept = ClientKit:Deprecate(AFTER_SPEC)
      local inert = ClientKit:Deprecate({ name = "TimerKit:Every", removal = "TimerKit API 2" })
      local alsoInert = ClientKit:Deprecate({ name = "TimerKit:Once", removal = "TimerKit API 2" })

      assert.are_not.equal(kept, inert)
      assert.are.equal(inert, alsoInert)
      -- A name declared before still gets its own reporter.
      assert.are.equal(kept, ClientKit:Deprecate(AFTER_SPEC))
      assert.are.same({
        'MoltenCodes ClientKit: maxDeprecations (1) reached; "TimerKit:Every" and later '
          .. "deprecations report nothing (raise it with ClientKit:SetLimits).",
      }, Env.ReportedErrors())

      deprecatedMethod(inert)()
      ClientKit:SetDeprecationMode("raise")
      assert.has_no.errors(function()
        deprecatedMethod(inert)()
      end)
      assert.are.same({}, ClientKit:GetDeprecationReports())
      assert.are.equal(1, ClientKit._state.deprecation.count)
    end)

    it("does not report the limit in silent mode", function()
      local ClientKit = newClientKit()
      ClientKit:SetDeprecationMode("silent")
      ClientKit:SetLimits({ maxDeprecations = 1 })
      ClientKit:Deprecate(AFTER_SPEC)
      ClientKit:Deprecate({ name = "TimerKit:Every", removal = "TimerKit API 2" })
      assert.are.same({}, Env.ReportedErrors())
    end)

    it("stops recording and reading call sites past maxReports", function()
      local ClientKit = newClientKit()
      ClientKit:SetLimits({ maxReports = 2 })
      local after = deprecatedMethod(ClientKit:Deprecate(AFTER_SPEC))
      after()
      after()
      local callsAtLimit = Env.DebugStackCalls()
      after()
      after("MyAddon")

      assert.are.equal(2, #ClientKit:GetDeprecationReports())
      assert.are.equal(2, #Env.ReportedErrors())
      assert.are.equal(callsAtLimit, Env.DebugStackCalls())
    end)
  end)

  describe("arguments", function()
    it("refuses a malformed spec", function()
      local ClientKit = newClientKit()
      local refusals = {
        { nil, "ClientKit:Deprecate spec must be a table" },
        { { removal = "2" }, "ClientKit:Deprecate spec.name must be a non-empty string" },
        {
          { name = "", removal = "2" },
          "ClientKit:Deprecate spec.name must be a non-empty string",
        },
        { { name = "A" }, "ClientKit:Deprecate spec.removal must be a non-empty string" },
        {
          { name = "A", removal = "2", replacement = "" },
          "ClientKit:Deprecate spec.replacement must be a non-empty string or nil",
        },
        {
          { name = "A", removal = "2", replacement = 3 },
          "ClientKit:Deprecate spec.replacement must be a non-empty string or nil",
        },
      }
      for _, refusal in ipairs(refusals) do
        assert.has_error(function()
          ClientKit:Deprecate(refusal[1])
        end, refusal[2])
      end
      assert.are.equal(0, ClientKit._state.deprecation.count)
    end)

    it("refuses secret spec fields before using them", function()
      local ClientKit = newClientKit()
      for _, field in ipairs({ "name", "removal", "replacement" }) do
        local spec = { name = "A", removal = "2", replacement = "B" }
        spec[field] = Env.NewSecretValue()
        assert.has_error(function()
          ClientKit:Deprecate(spec)
        end, "ClientKit:Deprecate spec." .. field .. " must not be a secret value")
      end
      assert.has_error(function()
        ClientKit:Deprecate(Env.NewSecretValue())
      end, "ClientKit:Deprecate spec must not be a secret value")
    end)

    it("refuses a bad level, addon name or receiver", function()
      local ClientKit = newClientKit()
      local reporter = ClientKit:Deprecate(AFTER_SPEC)
      local refusals = {
        { 0, nil, "ClientKit.DeprecationReporter:Warn level must be a positive integer or nil" },
        { 1.5, nil, "ClientKit.DeprecationReporter:Warn level must be a positive integer or nil" },
        {
          math.huge,
          nil,
          "ClientKit.DeprecationReporter:Warn level must be a positive integer or nil",
        },
        { "2", nil, "ClientKit.DeprecationReporter:Warn level must be a positive integer or nil" },
        {
          Env.NewSecretValue(),
          nil,
          "ClientKit.DeprecationReporter:Warn level must not be a secret value",
        },
        {
          nil,
          "",
          "ClientKit.DeprecationReporter:Warn addonName must be a non-empty string or nil",
        },
        {
          nil,
          7,
          "ClientKit.DeprecationReporter:Warn addonName must be a non-empty string or nil",
        },
        {
          nil,
          Env.NewSecretValue(),
          "ClientKit.DeprecationReporter:Warn addonName must not be a secret value",
        },
      }
      for _, refusal in ipairs(refusals) do
        assert.has_error(function()
          reporter:Warn(refusal[1], refusal[2])
        end, refusal[3])
      end
      for _, receiver in ipairs({ {}, "reporter", setmetatable({}, getmetatable(reporter)) }) do
        assert.has_error(function()
          reporter.Warn(receiver)
        end, "ClientKit.DeprecationReporter:Warn must be called on a reporter")
      end
      assert.are.same({}, ClientKit:GetDeprecationReports())
    end)
  end)

  describe("the optional-Kit pattern", function()
    ---A stand-in Kit's deprecated method, written as docs/API.md tells a Kit
    ---to write it: ClientKit is found through `Registry:Find` at the first
    ---deprecated call, and `false` remembers that it cannot report.
    ---@param Registry table
    ---@return fun()
    local function newKitMethod(Registry)
      local reporter
      return function()
        if reporter == nil then
          reporter = false
          local ClientKit = Registry:Find("clientKit", 1)
          if type(ClientKit) == "table" and type(rawget(ClientKit, "Deprecate")) == "function" then
            reporter = ClientKit:Deprecate(AFTER_SPEC)
          end
        end
        if reporter then
          reporter:Warn()
        end
        return "done"
      end
    end

    it("reports when ClientKit is loaded", function()
      local ClientKit, Registry = newClientKit()
      local kitMethod = newKitMethod(Registry)
      kitMethod()
      assert.are.equal(1, #ClientKit:GetDeprecationReports())
    end)

    it("reports nothing and fails nothing without ClientKit", function()
      local Registry = Env.NewHostFor("mainline", { debugStack = {} })
      Env.InstallHostErrorHandler()
      local kitMethod = newKitMethod(Registry)
      assert.are.equal("done", kitMethod())
      assert.are.equal("done", kitMethod())
      assert.are.same({}, Env.ReportedErrors())
    end)

    it("reports nothing and fails nothing with a revision 5 ClientKit", function()
      local Registry = Env.NewHostFor("mainline", { debugStack = {} })
      Env.InstallHostErrorHandler()
      local ClientKit = Env.LoadSourceAtRevision(5)
      -- Revision 5 published none of the deprecation methods.
      for _, methodName in ipairs({
        "Deprecate",
        "GetDeprecationReports",
        "SetDeprecationMode",
        "GetDeprecationMode",
        "SetLimits",
        "GetLimits",
      }) do
        rawset(ClientKit, methodName, nil)
      end
      local kitMethod = newKitMethod(Registry)
      assert.are.equal("done", kitMethod())
      assert.are.same({}, Env.ReportedErrors())
    end)
  end)
end)
