local TestEnv = require("BrokerKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src

---Return the line number of the statement that called this helper.
---@return integer line
local function currentLine()
  return debug.getinfo(2, "l").currentline
end

---Assert that `action` fails with `message` reported at `expectedLine` of this
---spec file. A wrong `error` level shows up either as a different line number
---or as a message with no `file:line` prefix at all.
---@param expectedLine integer
---@param message string
---@param ok boolean
---@param value any
local function assertReportedAt(expectedLine, message, ok, value)
  assert.is_false(ok)
  assert.are.equal(SOURCE .. ":" .. expectedLine .. ": " .. message, value)
end

---Run every `{ action, message }` case and check the failure points at the
---line after the function's `function()` line, where its statement sits.
---@param cases { [1]: fun(), [2]: string }[]
local function checkCases(cases)
  for _, case in ipairs(cases) do
    local action = case[1]
    local line = debug.getinfo(action, "S").linedefined + 1
    local ok, value = pcall(action)
    assertReportedAt(line, case[2], ok, value)
  end
end

describe("BrokerKit error levels", function()
  local BrokerKit
  local object
  before_each(function()
    BrokerKit = TestEnv.NewPackage()
    object = BrokerKit:New("Mine", { text = "Ready" })
  end)
  after_each(TestEnv.Reset)

  it("points New argument errors at the caller", function()
    checkCases({
      {
        function()
          BrokerKit:New("")
        end,
        "BrokerKit:New name must be a non-empty string",
      },
      {
        function()
          BrokerKit:New("Mine")
        end,
        'BrokerKit:New name "Mine" is already taken',
      },
      {
        function()
          BrokerKit:New("Other", 1)
        end,
        "BrokerKit:New definition must be a table",
      },
      {
        function()
          BrokerKit:New("Other", { text = 1 })
        end,
        'BrokerKit:New attribute "text" must be a string',
      },
      {
        function()
          BrokerKit:New("Other", { name = "x" })
        end,
        'BrokerKit:New attribute "name" is reserved',
      },
      {
        function()
          BrokerKit:New("Other", { [1] = "x" })
        end,
        "BrokerKit:New attribute name must be a non-empty string",
      },
      {
        function()
          BrokerKit.New("Other")
        end,
        "BrokerKit:New must be called on the BrokerKit facade; use BrokerKit:New(...)",
      },
    })
  end)

  it("points New limit refusals at the caller", function()
    BrokerKit:SetLimits({ maxObjects = 1, maxAttributes = 1 })
    checkCases({
      {
        function()
          BrokerKit:New("Other", { text = "x" })
        end,
        "BrokerKit:New refuses more than 1 attributes on an object",
      },
      {
        function()
          BrokerKit:New("Other", { type = "launcher" })
        end,
        "BrokerKit:New refuses more than 1 objects",
      },
    })
  end)

  it("points field writes and Set at the caller", function()
    checkCases({
      {
        function()
          object.text = 1
        end,
        'BrokerKit.Object:Set attribute "text" must be a string',
      },
      {
        function()
          object.name = "x"
        end,
        'BrokerKit.Object:Set attribute "name" is reserved',
      },
      {
        function()
          object[1] = "x"
        end,
        "BrokerKit.Object:Set attribute name must be a non-empty string",
      },
      {
        function()
          object:Set("text", 1)
        end,
        'BrokerKit.Object:Set attribute "text" must be a string',
      },
      {
        function()
          object:Set(1, "x")
        end,
        "BrokerKit.Object:Set attribute name must be a non-empty string",
      },
      {
        function()
          object.Set(nil, "text", "x")
        end,
        "BrokerKit.Object:Set must be called on a broker object; use object:Set(...)",
      },
    })
  end)

  it("points the attribute limit at the writing line, both ways", function()
    BrokerKit:SetLimits({ maxAttributes = 2 })
    checkCases({
      {
        function()
          object.extra = 1
        end,
        'BrokerKit.Object:Set refuses more than 2 attributes on object "Mine"',
      },
      {
        function()
          object:Set("extra", 1)
        end,
        'BrokerKit.Object:Set refuses more than 2 attributes on object "Mine"',
      },
    })
  end)

  it("points foreign writes at the caller", function()
    TestEnv.InstallLibDataBroker({ objects = { Theirs = { type = "data source" } } })
    BrokerKit:AdoptFromLibDataBroker()
    local theirs = BrokerKit:Get("Theirs")
    local message =
      'BrokerKit.Object:Set object "Theirs" is foreign (adopted from LibDataBroker) and read-only'
    checkCases({
      {
        function()
          theirs.text = "x"
        end,
        message,
      },
      {
        function()
          theirs:Set("text", "x")
        end,
        message,
      },
    })
  end)

  it("points Get, OnChange, facade lookups and IsForeign at the caller", function()
    checkCases({
      {
        function()
          object:Get("")
        end,
        "BrokerKit.Object:Get attribute name must be a non-empty string",
      },
      {
        function()
          object.Get({}, "text")
        end,
        "BrokerKit.Object:Get must be called on a broker object; use object:Get(...)",
      },
      {
        function()
          object:OnChange("text")
        end,
        "BrokerKit.Object:OnChange callback must be a function",
      },
      {
        function()
          object:OnChange("Set", function() end)
        end,
        'BrokerKit.Object:OnChange attribute "Set" is reserved',
      },
      {
        function()
          BrokerKit:Get(nil)
        end,
        "BrokerKit:Get name must be a non-empty string",
      },
      {
        function()
          BrokerKit:OnObjectAdded("x")
        end,
        "BrokerKit:OnObjectAdded callback must be a function",
      },
      {
        function()
          BrokerKit:IsForeign("x")
        end,
        "BrokerKit:IsForeign object must be a broker object",
      },
      {
        function()
          BrokerKit.Objects()
        end,
        "BrokerKit:Objects must be called on the BrokerKit facade; use BrokerKit:Objects(...)",
      },
      {
        function()
          BrokerKit.ExposeToLibDataBroker()
        end,
        "BrokerKit:ExposeToLibDataBroker must be called on the BrokerKit facade; use BrokerKit:ExposeToLibDataBroker(...)",
      },
      {
        function()
          BrokerKit.AdoptFromLibDataBroker()
        end,
        "BrokerKit:AdoptFromLibDataBroker must be called on the BrokerKit facade; use BrokerKit:AdoptFromLibDataBroker(...)",
      },
    })
  end)

  it("points secret-value refusals at the caller", function()
    TestEnv.InstallSecretProbe("Secret")
    local line
    local ok, value = pcall(function()
      line = currentLine() + 1
      object.text = "Secret"
    end)
    assertReportedAt(
      line,
      'BrokerKit.Object:Set attribute "text" must not be a secret value',
      ok,
      value
    )
  end)
end)
