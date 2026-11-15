local TestEnv = require("DialogKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src

---Run every `{ action, message }` case and check the failure is reported at
---the line after the function's `function()` line, where its statement sits.
---@param cases { [1]: fun(), [2]: string }[]
local function checkCases(cases)
  for _, case in ipairs(cases) do
    local action = case[1]
    local line = debug.getinfo(action, "S").linedefined + 1
    local ok, value = pcall(action)
    assert.is_false(ok)
    assert.are.equal(SOURCE .. ":" .. line .. ": " .. case[2], value)
  end
end

describe("DialogKit arguments and secrets", function()
  local DialogKit
  before_each(function()
    DialogKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("points every argument error at the caller", function()
    checkCases({
      {
        function()
          DialogKit:Show("Sure?")
        end,
        "DialogKit:Show options must be a table",
      },
      {
        function()
          DialogKit:Show({ text = "x", button1 = "OK" })
        end,
        "DialogKit:Show options holds an unknown field; see docs/API.md for the fields it accepts",
      },
      {
        function()
          DialogKit:Show({})
        end,
        "DialogKit:Show options.text must be a non-empty string or a number",
      },
      {
        function()
          DialogKit:Show({ text = "x", accept = "" })
        end,
        "DialogKit:Show options.accept must be a non-empty string or a number",
      },
      {
        function()
          DialogKit:Show({ text = "x", cancel = true })
        end,
        "DialogKit:Show options.cancel must be a non-empty string or a number",
      },
      {
        function()
          DialogKit:Show({ text = "x", onAccept = "Reset" })
        end,
        "DialogKit:Show options.onAccept must be a function or nil",
      },
      {
        function()
          DialogKit:Show({ text = "x", input = 1 })
        end,
        "DialogKit:Show options.input must be a boolean",
      },
      {
        function()
          DialogKit:Show({ text = "x", inputText = 3 })
        end,
        "DialogKit:Show options.inputText must be a string",
      },
      {
        function()
          DialogKit:Show({ text = "x", maxLetters = 0 })
        end,
        "DialogKit:Show options.maxLetters must be a positive integer",
      },
      {
        function()
          DialogKit:Show({ text = "x", timeout = -1 })
        end,
        "DialogKit:Show options.timeout must be a number above 0",
      },
      {
        function()
          DialogKit:Show({ text = "x", key = "" })
        end,
        "DialogKit:Show options.key must be a non-empty string",
      },
      {
        function()
          DialogKit:Show({ text = "x", allowSecret = "yes" })
        end,
        "DialogKit:Show options.allowSecret must be a boolean",
      },
      {
        function()
          DialogKit.Show(nil, { text = "x" })
        end,
        "DialogKit:Show must be called on the DialogKit facade; use DialogKit:Show(...)",
      },
      {
        function()
          DialogKit:SetLimits({ maxQueued = 0 })
        end,
        "DialogKit:SetLimits limits.maxQueued must be a positive integer or DialogKit.UNBOUNDED",
      },
      {
        function()
          DialogKit:SetLimits({ queued = 1 })
        end,
        "DialogKit:SetLimits limits holds an unknown field; it accepts maxQueued",
      },
      {
        function()
          DialogKit.GetLimits({})
        end,
        "DialogKit:GetLimits must be called on the DialogKit facade; use DialogKit:GetLimits(...)",
      },
    })
    local dialog = DialogKit:Show({ text = "x" })
    checkCases({
      {
        function()
          dialog.Hide({})
        end,
        "DialogKit.Dialog:Hide must be called on a DialogKit dialog; use dialog:Hide(...)",
      },
      {
        function()
          dialog.GetInput(nil)
        end,
        "DialogKit.Dialog:GetInput must be called on a DialogKit dialog; use dialog:GetInput(...)",
      },
    })
  end)

  it("refuses a secret text unless allowSecret, and secret options", function()
    TestEnv.InstallSecretProbe()
    local secret = TestEnv.NewSecret()
    TestEnv.expectErrorContaining(
      "DialogKit:Show options.text must not be a secret value; pass allowSecret = true to draw one",
      function()
        DialogKit:Show({ text = secret })
      end
    )
    DialogKit:Show({ text = secret, allowSecret = true })
    assert.are.equal(secret, TestEnv.GetGlobal(DialogKit.FRAME_NAME).text:GetText())
    for _, case in ipairs({
      { "options must be a table", secret },
      { "options holds an unknown field", { text = "x", [secret] = 1 } },
      { "options.accept must not be a secret value", { text = "x", accept = secret } },
      { "options.timeout must be a number above 0", { text = "x", timeout = secret } },
      { "options.key must be a non-empty string", { text = "x", key = secret } },
    }) do
      TestEnv.expectErrorContaining("DialogKit:Show " .. case[1], function()
        DialogKit:Show(case[2])
      end)
    end
    TestEnv.expectErrorContaining(
      "DialogKit:SetLimits limits.maxQueued must not be a secret value",
      function()
        DialogKit:SetLimits({ maxQueued = secret })
      end
    )
  end)

  it(
    "refuses a secret button text without offering allowSecret, which never applies to it",
    function()
      TestEnv.InstallSecretProbe()
      local secret = TestEnv.NewSecret()
      for _, field in ipairs({ "accept", "cancel" }) do
        local ok, failure = pcall(DialogKit.Show, DialogKit, {
          text = "x",
          allowSecret = true,
          [field] = secret,
        })
        assert.is_false(ok)
        assert.is_truthy(
          tostring(failure):find(
            "DialogKit:Show options." .. field .. " must not be a secret value",
            1,
            true
          )
        )
        assert.is_nil(tostring(failure):find("allowSecret", 1, true))
      end
    end
  )

  it("refuses a secret cancel at the caller's line, before comparing it", function()
    TestEnv.InstallSecretProbe()
    for _, secret in ipairs({ TestEnv.NewSecret(), TestEnv.MarkSecret(7) }) do
      local line = debug.getinfo(1, "l").currentline + 2
      local ok, failure = pcall(function()
        DialogKit:Show({ text = "x", cancel = secret })
      end)
      assert.is_false(ok)
      assert.is_truthy(
        tostring(failure):find("DialogKit:Show options.cancel must not be a secret value", 1, true)
      )
      assert.is_nil(tostring(failure):find("allowSecret", 1, true))
      assert.is_truthy(tostring(failure):find("Arguments_spec.lua:" .. line, 1, true))
    end
  end)

  it(
    "hands a secret number text to the font string unconverted, and refuses it without allowSecret",
    function()
      TestEnv.InstallSecretProbe()
      local secretNumber = TestEnv.MarkSecret(1234)
      TestEnv.expectErrorContaining(
        "DialogKit:Show options.text must not be a secret value; pass allowSecret = true to draw one",
        function()
          DialogKit:Show({ text = secretNumber })
        end
      )
      DialogKit:Show({ text = secretNumber, allowSecret = true })
      -- The client accepts a secret in `SetText`; `tostring` would convert it.
      assert.are.equal(secretNumber, TestEnv.GetGlobal(DialogKit.FRAME_NAME).text:GetText())
    end
  )

  it("draws a secret text that raises when converted or concatenated", function()
    TestEnv.InstallSecretProbe()
    local secret = TestEnv.NewSecret()
    assert.has_error(function()
      return tostring(secret)
    end)
    local dialog = DialogKit:Show({ text = secret, allowSecret = true })
    assert.is_true(dialog:IsShown())
    assert.are.equal(secret, TestEnv.GetGlobal(DialogKit.FRAME_NAME).text:GetText())
  end)

  it("refuses to show without CreateFrame or UIParent", function()
    TestEnv.SetGlobal("UIParent", nil)
    TestEnv.expectErrorContaining("needs the client's CreateFrame and UIParent", function()
      DialogKit:Show({ text = "x" })
    end)
  end)

  it(
    "never times out without GetTime, refuses limits that are not a table, and sizes a secret text height as one line",
    function()
      TestEnv.InstallSecretProbe()
      local secret = TestEnv.NewSecret()
      TestEnv.SetGlobal("GetTime", nil)
      local cancelled = false
      DialogKit:Show({
        text = "x",
        timeout = 1,
        onCancel = function()
          cancelled = true
        end,
      })
      local frame = TestEnv.GetGlobal(DialogKit.FRAME_NAME)
      frame:GetScript("OnUpdate")(frame, 5)
      assert.is_false(cancelled)
      DialogKit:HideAll()
      frame.text.GetStringHeight = function()
        return secret
      end
      DialogKit:Show({ text = "y", cancel = false })
      assert.are.equal(16 + 12 + 10 + 22 + 16, frame:GetHeight())
      TestEnv.expectErrorContaining("DialogKit:SetLimits limits must be a table", function()
        DialogKit:SetLimits(1)
      end)
    end
  )

  it("works without UISpecialFrames, closing only through its own buttons", function()
    TestEnv.SetGlobal("UISpecialFrames", nil)
    local dialog = DialogKit:Show({ text = "x" })
    assert.is_true(dialog:IsShown())
  end)
end)
