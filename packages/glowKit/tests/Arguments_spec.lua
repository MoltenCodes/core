local TestEnv = require("GlowKitTestEnv")

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

describe("GlowKit arguments and secrets", function()
  local GlowKit, button
  before_each(function()
    GlowKit = TestEnv.NewPackage()
    button = TestEnv.FrameAt(0, 0)
  end)
  after_each(TestEnv.Reset)

  it("points every argument error at the caller", function()
    checkCases({
      {
        function()
          GlowKit:Start({})
        end,
        "GlowKit:Start frame must be a frame",
      },
      {
        function()
          GlowKit:Start(button, "pixel")
        end,
        "GlowKit:Start options must be a table or nil",
      },
      {
        function()
          GlowKit:Start(button, { colour = {} })
        end,
        "GlowKit:Start options holds an unknown field; it accepts kind, key, color, lines, thickness and frequency",
      },
      {
        function()
          GlowKit:Start(button, { kind = "autocast" })
        end,
        'GlowKit:Start options.kind must be "pixel" or "pulse"',
      },
      {
        function()
          GlowKit:Start(button, { key = "" })
        end,
        "GlowKit:Start options.key must be a non-empty string or nil",
      },
      {
        function()
          GlowKit:Start(button, { color = { 1, 2, 0 } })
        end,
        "GlowKit:Start options.color must be { r, g, b, a? }, each from 0 to 1",
      },
      {
        function()
          GlowKit:Start(button, { color = 1 })
        end,
        "GlowKit:Start options.color must be { r, g, b, a? }",
      },
      {
        function()
          GlowKit:Start(button, { lines = 33 })
        end,
        "GlowKit:Start options.lines must be an integer from 1 to 32",
      },
      {
        function()
          GlowKit:Start(button, { thickness = 0 })
        end,
        "GlowKit:Start options.thickness must be a number above 0 and at most 10",
      },
      {
        function()
          GlowKit:Start(button, { frequency = 11 })
        end,
        "GlowKit:Start options.frequency must be a number above 0 and at most 10",
      },
      {
        function()
          GlowKit:Stop(button, 1)
        end,
        "GlowKit:Stop key must be a non-empty string or nil",
      },
      {
        function()
          GlowKit:IsGlowing("button")
        end,
        "GlowKit:IsGlowing frame must be a frame",
      },
      {
        function()
          GlowKit:StopAll(nil)
        end,
        "GlowKit:StopAll frame must be a frame",
      },
      {
        function()
          GlowKit.Start(nil, button)
        end,
        "GlowKit:Start must be called on the GlowKit facade; use GlowKit:Start(...)",
      },
      {
        function()
          GlowKit:SetLimits({ maxGlows = 0 })
        end,
        "GlowKit:SetLimits limits.maxGlows must be an integer from 1 to 512",
      },
      {
        function()
          GlowKit:SetLimits({ glows = 1 })
        end,
        "GlowKit:SetLimits limits holds an unknown field; it accepts maxGlows",
      },
      {
        function()
          GlowKit:SetLimits(1)
        end,
        "GlowKit:SetLimits limits must be a table",
      },
    })
    local glow = GlowKit:Start(button)
    checkCases({
      {
        function()
          glow.Stop({})
        end,
        "GlowKit.Glow:Stop must be called on a GlowKit glow; use glow:Stop(...)",
      },
      {
        function()
          glow.IsActive(nil)
        end,
        "GlowKit.Glow:IsActive must be called on a GlowKit glow; use glow:IsActive(...)",
      },
    })
  end)

  it("refuses secret frames, options, colours, limits and receivers", function()
    TestEnv.InstallSecretProbe()
    local secret = TestEnv.NewSecret()
    for _, case in ipairs({
      {
        "GlowKit:Start frame must be a frame",
        function()
          GlowKit:Start(secret)
        end,
      },
      {
        "GlowKit:Start options must be a table or nil",
        function()
          GlowKit:Start(button, secret)
        end,
      },
      {
        "options.color must be",
        function()
          GlowKit:Start(button, { color = { secret, 0, 0 } })
        end,
      },
      {
        "options.thickness must be",
        function()
          GlowKit:Start(button, { thickness = secret })
        end,
      },
      {
        "options holds an unknown field",
        function()
          GlowKit:Start(button, { [secret] = 1 })
        end,
      },
      {
        "GlowKit:SetLimits limits.maxGlows must not be a secret value",
        function()
          GlowKit:SetLimits({ maxGlows = secret })
        end,
      },
      {
        "must be called on a GlowKit glow",
        function()
          GlowKit.Start(GlowKit, button).Stop(secret)
        end,
      },
    }) do
      TestEnv.expectErrorContaining(case[1], case[2])
    end
  end)

  it("treats a secret size or level as 0", function()
    TestEnv.InstallSecretProbe()
    local secret = TestEnv.NewSecret()
    button.GetFrameLevel = function()
      return secret
    end
    button.GetWidth = function()
      return secret
    end
    local glow = GlowKit:Start(button, { lines = 1 })
    local overlay = rawget(glow, "_record").overlay
    assert.are.equal(5, overlay:GetFrameLevel())
  end)

  it("refuses to start without CreateFrame", function()
    TestEnv.SetGlobal("CreateFrame", nil)
    TestEnv.expectErrorContaining("needs the client's CreateFrame", function()
      GlowKit:Start(button)
    end)
  end)
end)
