local TestEnv = require("EditModeKitTestEnv")

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

describe("EditModeKit arguments and secrets", function()
  local EditModeKit, frame
  before_each(function()
    EditModeKit = TestEnv.NewPackage()
    frame = TestEnv.FrameAt(300, 300)
  end)
  after_each(TestEnv.Reset)

  it("points every argument error at the caller", function()
    checkCases({
      {
        function()
          EditModeKit:Register({}, {})
        end,
        "EditModeKit:Register frame must be a frame",
      },
      {
        function()
          EditModeKit:Register(frame, "positions")
        end,
        "EditModeKit:Register storage must be a table or a function returning one",
      },
      {
        function()
          EditModeKit:Register(frame, {}, "Bars")
        end,
        "EditModeKit:Register options must be a table or nil",
      },
      {
        function()
          EditModeKit:Register(frame, {}, { name = "Bars" })
        end,
        "EditModeKit:Register options holds an unknown field; it accepts label",
      },
      {
        function()
          EditModeKit:Register(frame, {}, { label = "" })
        end,
        "EditModeKit:Register options.label must be a non-empty string",
      },
      {
        function()
          EditModeKit.Register(nil, frame, {})
        end,
        "EditModeKit:Register must be called on the EditModeKit facade; use EditModeKit:Register(...)",
      },
      {
        function()
          EditModeKit.IsEditing({})
        end,
        "EditModeKit:IsEditing must be called on the EditModeKit facade; use EditModeKit:IsEditing(...)",
      },
      {
        function()
          EditModeKit.GetLayoutName(nil)
        end,
        "EditModeKit:GetLayoutName must be called on the EditModeKit facade; use EditModeKit:GetLayoutName(...)",
      },
      {
        function()
          EditModeKit:SetLimits({ maxRegistrations = 257 })
        end,
        "EditModeKit:SetLimits limits.maxRegistrations must be an integer from 1 to 256",
      },
      {
        function()
          EditModeKit:SetLimits({ registrations = 1 })
        end,
        "EditModeKit:SetLimits limits holds an unknown field; it accepts maxRegistrations",
      },
      {
        function()
          EditModeKit:SetLimits(1)
        end,
        "EditModeKit:SetLimits limits must be a table",
      },
    })
    local registration = EditModeKit:Register(frame, {})
    checkCases({
      {
        function()
          EditModeKit:Register(frame, {})
        end,
        "EditModeKit:Register frame is already registered; unregister it first",
      },
      {
        function()
          registration.Unregister({})
        end,
        "EditModeKit.Registration:Unregister must be called on an EditModeKit registration; use registration:Unregister(...)",
      },
      {
        function()
          registration.Refresh(nil)
        end,
        "EditModeKit.Registration:Refresh must be called on an EditModeKit registration; use registration:Refresh(...)",
      },
      {
        function()
          registration.GetFrame(frame)
        end,
        "EditModeKit.Registration:GetFrame must be called on an EditModeKit registration; use registration:GetFrame(...)",
      },
    })
  end)

  it("refuses secret frames, storage, options, limits and receivers", function()
    TestEnv.InstallSecretProbe()
    local secret = TestEnv.NewSecret()
    for _, case in ipairs({
      {
        "EditModeKit:Register frame must be a frame",
        function()
          EditModeKit:Register(secret, {})
        end,
      },
      {
        "EditModeKit:Register storage must be",
        function()
          EditModeKit:Register(frame, secret)
        end,
      },
      {
        "EditModeKit:Register options must be a table or nil",
        function()
          EditModeKit:Register(frame, {}, secret)
        end,
      },
      {
        "options holds an unknown field",
        function()
          EditModeKit:Register(frame, {}, { [secret] = 1 })
        end,
      },
      {
        "options.label must be a non-empty string",
        function()
          EditModeKit:Register(frame, {}, { label = secret })
        end,
      },
      {
        "EditModeKit:SetLimits limits must be a table",
        function()
          EditModeKit:SetLimits(secret)
        end,
      },
      {
        "limits holds an unknown field",
        function()
          EditModeKit:SetLimits({ [secret] = 1 })
        end,
      },
      {
        "EditModeKit:SetLimits limits.maxRegistrations must not be a secret value",
        function()
          EditModeKit:SetLimits({ maxRegistrations = secret })
        end,
      },
      {
        "must be called on an EditModeKit registration",
        function()
          EditModeKit:Register(frame, {}).Refresh(secret)
        end,
      },
    }) do
      TestEnv.expectErrorContaining(case[1], case[2])
    end
  end)

  it("ignores secret names, layouts, positions, scales and combat answers", function()
    TestEnv.InstallSecretProbe()
    local secret = TestEnv.NewSecret()
    frame.GetName = function()
      return secret
    end
    frame.GetFrameLevel = function()
      return secret
    end
    local storage = { Modern = { x = secret, y = 1 } }
    local registration = EditModeKit:Register(frame, storage)
    local overlay = rawget(registration, "_record").overlay
    assert.are.equal("Frame", overlay.text:GetText())
    assert.are.equal(20, overlay:GetFrameLevel())
    assert.are.same({ "CENTER", TestEnv.GetGlobal("UIParent"), "BOTTOMLEFT", 300, 300 }, {
      frame:GetPoint(1),
    })

    TestEnv.GetGlobal("EditModeManagerFrame").GetActiveLayoutInfo = function()
      return { layoutName = secret }
    end
    assert.are.equal("default", EditModeKit:GetLayoutName())

    frame.IsProtected = function()
      return secret
    end
    storage.default = { x = 5, y = 5 }
    registration:Refresh()
    assert.are.same({ "CENTER", TestEnv.GetGlobal("UIParent"), "CENTER", 5, 5 }, {
      frame:GetPoint(1),
    })

    frame.GetEffectiveScale = function()
      return secret
    end
    storage.default = { x = 9, y = 9 }
    registration:Refresh()
    TestEnv.Run(overlay, "OnDragStart")
    TestEnv.Run(overlay, "OnDragStop")
    assert.are.same({ x = 9, y = 9 }, storage.default)
    assert.are.same({ "CENTER", TestEnv.GetGlobal("UIParent"), "CENTER", 5, 5 }, {
      frame:GetPoint(1),
    })
  end)

  it("names the layout default when the manager raises or answers nothing", function()
    TestEnv.GetGlobal("EditModeManagerFrame").GetActiveLayoutInfo = function()
      error("no layouts yet")
    end
    assert.are.equal("default", EditModeKit:GetLayoutName())
    TestEnv.GetGlobal("EditModeManagerFrame").GetActiveLayoutInfo = function()
      return { layoutName = "" }
    end
    assert.are.equal("default", EditModeKit:GetLayoutName())
  end)

  it("reports a storage table that refuses the write", function()
    TestEnv.InstallHostErrorHandler()
    local storage = setmetatable({}, {
      __newindex = function()
        error("read-only", 0)
      end,
    })
    local registration = EditModeKit:Register(frame, storage)
    local overlay = rawget(registration, "_record").overlay
    TestEnv.Run(overlay, "OnDragStart")
    TestEnv.Run(overlay, "OnDragStop")
    assert.are.same({ "read-only" }, TestEnv.TakeReportedValues())
  end)

  it("ignores a drag stop without a drag start, and a drag on a given-back overlay", function()
    local storage = {}
    local registration = EditModeKit:Register(frame, storage)
    local overlay = rawget(registration, "_record").overlay
    TestEnv.Run(overlay, "OnDragStop")
    assert.are.same({}, storage)
    registration:Unregister()
    TestEnv.Run(overlay, "OnDragStart")
    assert.is_nil(frame.moving)
  end)

  it("refuses to register without the client's CreateFrame, UIParent or EventRegistry", function()
    for _, name in ipairs({ "CreateFrame", "UIParent", "EventRegistry" }) do
      local saved = TestEnv.GetGlobal(name)
      TestEnv.SetGlobal(name, nil)
      TestEnv.expectErrorContaining(
        "needs the client's CreateFrame, UIParent and EventRegistry",
        function()
          EditModeKit:Register(frame, {})
        end
      )
      TestEnv.SetGlobal(name, saved)
    end
  end)
end)
