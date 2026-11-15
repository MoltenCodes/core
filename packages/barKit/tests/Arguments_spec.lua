local TestEnv = require("BarKitTestEnv")

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

describe("BarKit arguments, limits and secrets", function()
  local BarKit, bar
  before_each(function()
    BarKit = TestEnv.NewPackage()
    bar = BarKit:Acquire()
  end)
  after_each(TestEnv.Reset)

  it("points every argument error at the caller", function()
    checkCases({
      {
        function()
          BarKit:Acquire("wide")
        end,
        "BarKit:Acquire options must be a table or nil",
      },
      {
        function()
          BarKit:Acquire({ colour = 1 })
        end,
        "BarKit:Acquire options holds an unknown field; it accepts width, height, texture and parent",
      },
      {
        function()
          BarKit:Acquire({ width = 0 })
        end,
        "BarKit:Acquire options.width must be a number above 0",
      },
      {
        function()
          BarKit:Acquire({ texture = {} })
        end,
        "BarKit:Acquire options.texture must be a texture path, a FileDataID or nil",
      },
      {
        function()
          BarKit:Acquire({ parent = "UIParent" })
        end,
        "BarKit:Acquire options.parent must be a frame or nil",
      },
      {
        function()
          bar:SetLabel({})
        end,
        "BarKit.Bar:SetLabel text must be a string, a number or nil",
      },
      {
        function()
          bar:SetValueText("x", { allowSecret = 1 })
        end,
        "BarKit.Bar:SetValueText options.allowSecret must be a boolean",
      },
      {
        function()
          bar:SetValueText("x", { secret = true })
        end,
        "BarKit.Bar:SetValueText options holds an unknown field; it accepts allowSecret",
      },
      {
        function()
          bar:SetIcon(true)
        end,
        "BarKit.Bar:SetIcon texture must be a texture path, a FileDataID or nil",
      },
      {
        function()
          bar:SetColor(1, 2, 0)
        end,
        "BarKit.Bar:SetColor g must be a number from 0 to 1",
      },
      {
        function()
          bar:SetBackgroundColor(0, 0, 0, 5)
        end,
        "BarKit.Bar:SetBackgroundColor a must be a number from 0 to 1",
      },
      {
        function()
          bar:SetMinMax(10, 1)
        end,
        "BarKit.Bar:SetMinMax minimum must not be greater than maximum",
      },
      {
        function()
          bar:SetValue("full")
        end,
        "BarKit.Bar:SetValue value must be a number",
      },
      {
        function()
          bar:Start(0)
        end,
        "BarKit.Bar:Start duration must be a number above 0",
      },
      {
        function()
          bar:Start(5, { onFinished = "done" })
        end,
        "BarKit.Bar:Start options.onFinished must be a function or nil",
      },
      {
        function()
          bar:Start(5, { fill = "yes" })
        end,
        "BarKit.Bar:Start options.fill must be a boolean",
      },
      {
        function()
          bar.GetFrame({})
        end,
        "BarKit.Bar:GetFrame must be called on an acquired BarKit bar; use bar:GetFrame(...)",
      },
      {
        function()
          BarKit.Acquire(nil)
        end,
        "BarKit:Acquire must be called on the BarKit facade; use BarKit:Acquire(...)",
      },
      {
        function()
          BarKit:Release({})
        end,
        "BarKit:Release bar must be an acquired BarKit bar",
      },
      {
        function()
          BarKit:SetLimits({ maxBars = 513 })
        end,
        "BarKit:SetLimits limits.maxBars must be an integer from 1 to 512",
      },
      {
        function()
          BarKit:SetLimits({ bars = 1 })
        end,
        "BarKit:SetLimits limits holds an unknown field; it accepts maxBars",
      },
    })
  end)

  it("reports the limit, refuses the bar past it and frees a slot on Release", function()
    assert.are.same({ 64, 512 }, { BarKit.MAX_BARS, BarKit.BARS_CEILING })
    assert.are.same({ maxBars = 64 }, BarKit:GetLimits())
    BarKit:SetLimits({ maxBars = 2 })
    BarKit:Acquire()
    checkCases({
      {
        function()
          BarKit:Acquire()
        end,
        "BarKit:Acquire holds at most 2 bars at once; release one, or raise maxBars",
      },
    })
    BarKit:Release(bar)
    BarKit:Acquire()
    BarKit:SetLimits({ maxBars = 1 })
    assert.are.equal(1, BarKit:GetLimits().maxBars)
  end)

  it("refuses secret options, numbers, colours, limits and receivers", function()
    TestEnv.InstallSecretProbe()
    local secret = TestEnv.NewSecret()
    for _, case in ipairs({
      {
        "BarKit:Acquire options must be a table or nil",
        function()
          BarKit:Acquire(secret)
        end,
      },
      {
        "BarKit:Acquire options.width must not be a secret value",
        function()
          BarKit:Acquire({ width = secret })
        end,
      },
      {
        "BarKit.Bar:SetColor r must not be a secret value",
        function()
          bar:SetColor(secret, 0, 0)
        end,
      },
      {
        "BarKit.Bar:Start duration must not be a secret value",
        function()
          bar:Start(secret)
        end,
      },
      {
        "BarKit.Bar:SetIcon texture must not be a secret value",
        function()
          bar:SetIcon(secret)
        end,
      },
      {
        "BarKit:SetLimits limits.maxBars must not be a secret value",
        function()
          BarKit:SetLimits({ maxBars = secret })
        end,
      },
      {
        "must be called on an acquired BarKit bar",
        function()
          bar.Stop(secret)
        end,
      },
    }) do
      TestEnv.expectErrorContaining(case[1], case[2])
    end
  end)

  it("refuses to acquire without CreateFrame or UIParent", function()
    TestEnv.SetGlobal("UIParent", nil)
    TestEnv.expectErrorContaining("needs the client's CreateFrame and UIParent", function()
      BarKit:Acquire()
    end)
  end)
end)
