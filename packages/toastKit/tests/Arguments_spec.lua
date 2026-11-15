local TestEnv = require("ToastKitTestEnv")

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

describe("ToastKit arguments and secrets", function()
  local ToastKit
  before_each(function()
    ToastKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("points every argument error at the caller", function()
    checkCases({
      {
        function()
          ToastKit:Show("Saved")
        end,
        "ToastKit:Show options must be a table",
      },
      {
        function()
          ToastKit:Show({ title = "x", sound = 1 })
        end,
        "ToastKit:Show options holds an unknown field; it accepts title, text, icon, duration, onClick, data, key and allowSecret",
      },
      {
        function()
          ToastKit:Show({})
        end,
        "ToastKit:Show options.title must be a non-empty string or a number",
      },
      {
        function()
          ToastKit:Show({ title = "x", text = "" })
        end,
        "ToastKit:Show options.text must be a non-empty string or a number",
      },
      {
        function()
          ToastKit:Show({ title = "x", icon = {} })
        end,
        "ToastKit:Show options.icon must be a texture path, a FileDataID or nil",
      },
      {
        function()
          ToastKit:Show({ title = "x", duration = 0 })
        end,
        "ToastKit:Show options.duration must be a number above 0",
      },
      {
        function()
          ToastKit:Show({ title = "x", onClick = "open" })
        end,
        "ToastKit:Show options.onClick must be a function or nil",
      },
      {
        function()
          ToastKit:Show({ title = "x", key = 1 })
        end,
        "ToastKit:Show options.key must be a non-empty string",
      },
      {
        function()
          ToastKit:Show({ title = "x", allowSecret = 1 })
        end,
        "ToastKit:Show options.allowSecret must be a boolean",
      },
      {
        function()
          ToastKit:SetAnchor("MIDDLE", 0, 0)
        end,
        'ToastKit:SetAnchor point must be an anchor point such as "TOP" or "BOTTOMRIGHT"',
      },
      {
        function()
          ToastKit:SetAnchor("TOP", 0 / 0, 0)
        end,
        "ToastKit:SetAnchor x must be a finite number",
      },
      {
        function()
          ToastKit:SetAnchor("TOP", 0, 0, "LEFT")
        end,
        'ToastKit:SetAnchor direction must be "UP", "DOWN" or nil',
      },
      {
        function()
          ToastKit:SetLimits({ maxVisible = 21 })
        end,
        "ToastKit:SetLimits limits.maxVisible must be an integer from 1 to 20",
      },
      {
        function()
          ToastKit:SetLimits({ maxQueued = 0 })
        end,
        "ToastKit:SetLimits limits.maxQueued must be a positive integer or ToastKit.UNBOUNDED",
      },
      {
        function()
          ToastKit:SetLimits({ visible = 1 })
        end,
        "ToastKit:SetLimits limits holds an unknown field; it accepts maxVisible and maxQueued",
      },
      {
        function()
          ToastKit:SetLimits(1)
        end,
        "ToastKit:SetLimits limits must be a table",
      },
      {
        function()
          ToastKit.DismissAll({})
        end,
        "ToastKit:DismissAll must be called on the ToastKit facade; use ToastKit:DismissAll(...)",
      },
    })
    local toast = ToastKit:Show({ title = "x" })
    checkCases({
      {
        function()
          toast.Dismiss({})
        end,
        "ToastKit.Toast:Dismiss must be called on a ToastKit toast; use toast:Dismiss(...)",
      },
    })
  end)

  it("refuses a secret title unless allowSecret, and secret options", function()
    TestEnv.InstallSecretProbe()
    local secret = TestEnv.NewSecret()
    TestEnv.expectErrorContaining(
      "ToastKit:Show options.title must not be a secret value; pass allowSecret = true to draw one",
      function()
        ToastKit:Show({ title = secret })
      end
    )
    local toast = ToastKit:Show({ title = secret, text = secret, allowSecret = true })
    assert.are.equal(secret, rawget(toast, "_record").frame.title:GetText())
    for _, case in ipairs({
      { "ToastKit:Show options must be a table", secret },
      { "ToastKit:Show options.icon must be", { title = "x", icon = secret } },
      { "ToastKit:Show options.duration must be", { title = "x", duration = secret } },
      { "ToastKit:Show options holds an unknown field", { title = "x", [secret] = 1 } },
    }) do
      TestEnv.expectErrorContaining(case[1], function()
        ToastKit:Show(case[2])
      end)
    end
    TestEnv.expectErrorContaining("ToastKit:SetAnchor x must be a finite number", function()
      ToastKit:SetAnchor("TOP", secret, 0)
    end)
    TestEnv.expectErrorContaining(
      "ToastKit:SetLimits limits.maxQueued must not be a secret value",
      function()
        ToastKit:SetLimits({ maxQueued = secret })
      end
    )
    local frame = rawget(toast, "_record").frame
    TestEnv.SetMouseOver(frame, secret)
    frame:GetScript("OnUpdate")(frame, secret)
    assert.is_true(toast:IsShown())
  end)

  it("refuses to show without CreateFrame or UIParent", function()
    TestEnv.SetGlobal("UIParent", nil)
    TestEnv.expectErrorContaining("needs the client's CreateFrame and UIParent", function()
      ToastKit:Show({ title = "x" })
    end)
    ToastKit:SetAnchor("TOP", 0, 0)
  end)
end)
