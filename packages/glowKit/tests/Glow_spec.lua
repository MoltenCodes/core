local TestEnv = require("GlowKitTestEnv")

describe("GlowKit glows", function()
  local GlowKit, button
  before_each(function()
    GlowKit = TestEnv.NewPackage()
    button = TestEnv.FrameAt(100, 100)
    button:SetSize(40, 20)
  end)
  after_each(TestEnv.Reset)

  local function overlayOf(glow)
    return rawget(glow, "_record").overlay
  end

  it("lays an overlay over the frame, above it, and draws eight pixel lines by default", function()
    button:SetFrameLevel(3)
    local glow = GlowKit:Start(button)
    local overlay = overlayOf(glow)
    assert.are.equal(button, overlay:GetParent())
    assert.are.equal(8, overlay:GetFrameLevel())
    assert.is_true(overlay:IsShown())
    assert.is_function(overlay:GetScript("OnUpdate"))
    assert.are.equal(8, #overlay.lines)
    local first = overlay.lines[1]
    -- Perimeter 120, eight lines of 7.5 pixels, the first at the top left.
    assert.are.same({ "TOPLEFT", overlay, "TOPLEFT", 0, 0 }, { first:GetPoint(1) })
    assert.are.same({ 7.5, 2 }, { first:GetWidth(), first:GetHeight() })
    assert.are.same(
      { 0.95, 0.95, 0.32, 1 },
      { first.colorRed, first.colorGreen, first.colorBlue, first.colorAlpha }
    )
    assert.is_true(GlowKit:IsGlowing(button))
    assert.is_true(glow:IsActive())
    assert.are.equal("GlowKit.Glow", getmetatable(glow))
  end)

  it("moves the lines round the edge with time, side by side", function()
    local glow = GlowKit:Start(button, { lines = 1, frequency = 1 })
    local overlay = overlayOf(glow)
    local line = overlay.lines[1]
    -- Perimeter 120: a quarter of a second moves the line 30 pixels round.
    TestEnv.Run(overlay, "OnUpdate", 0.25)
    assert.are.same({ "TOPLEFT", overlay, "TOPLEFT", 30, 0 }, { line:GetPoint(1) })
    assert.are.equal(10, line:GetWidth())
    TestEnv.Run(overlay, "OnUpdate", 0.125)
    assert.are.same({ "TOPRIGHT", overlay, "TOPRIGHT", 0, -5 }, { line:GetPoint(1) })
    assert.are.same({ 2, 15 }, { line:GetWidth(), line:GetHeight() })
    TestEnv.Run(overlay, "OnUpdate", 0.25)
    assert.are.same({ "BOTTOMRIGHT", overlay, "BOTTOMRIGHT", -15, 0 }, { line:GetPoint(1) })
    TestEnv.Run(overlay, "OnUpdate", 0.25)
    assert.are.equal("BOTTOMLEFT", (line:GetPoint(1)))
  end)

  it("follows a frame resized while it glows, and draws nothing on a frame without size", function()
    local glow = GlowKit:Start(button, { lines = 2 })
    local overlay = overlayOf(glow)
    button:SetSize(100, 100)
    TestEnv.Run(overlay, "OnUpdate", 0)
    assert.are.equal(100, overlay.lines[1]:GetWidth())
    button:SetSize(0, 0)
    TestEnv.Run(overlay, "OnUpdate", 0)
    assert.is_false(overlay.lines[1]:IsShown())
  end)

  it("draws a pulsing border whose opacity breathes", function()
    local glow =
      GlowKit:Start(button, { kind = "pulse", color = { 1, 0, 0 }, thickness = 3, frequency = 1 })
    local overlay = overlayOf(glow)
    assert.are.equal(4, #overlay.edges)
    assert.are.equal(3, overlay.edges[1]:GetHeight())
    assert.are.equal(3, overlay.edges[3]:GetWidth())
    assert.are.same({ 1, 0, 0, 1 }, {
      overlay.edges[1].colorRed,
      overlay.edges[1].colorGreen,
      overlay.edges[1].colorBlue,
      overlay.edges[1].colorAlpha,
    })
    TestEnv.Run(overlay, "OnUpdate", 0.25)
    assert.are.equal(1, overlay:GetAlpha())
    TestEnv.Run(overlay, "OnUpdate", 0.5)
    assert.is_true(math.abs(overlay:GetAlpha() - 0.3) < 1e-9)
  end)

  it("keeps glows under different keys side by side and restarts one under the same key", function()
    local first = GlowKit:Start(button, { key = "ready" })
    local second = GlowKit:Start(button, { key = "proc", kind = "pulse" })
    assert.is_true(GlowKit:IsGlowing(button, "ready"))
    assert.is_true(GlowKit:IsGlowing(button, "proc"))
    assert.is_false(GlowKit:IsGlowing(button, "other"))
    local replaced = GlowKit:Start(button, { key = "ready", lines = 3 })
    assert.is_false(first:IsActive())
    assert.is_true(replaced:IsActive())
    assert.are.equal(3, rawget(replaced, "_record").lines)
    assert.are.equal(2, GlowKit._state.activeCount)
    assert.is_true(second:Stop())
    assert.is_false(second:Stop())
  end)

  it("stops by key, all at once, and gives the overlays back cleared for reuse", function()
    GlowKit:Start(button, { key = "a", lines = 4 })
    GlowKit:Start(button, { key = "b" })
    assert.is_true(GlowKit:Stop(button, "a"))
    assert.is_false(GlowKit:Stop(button, "a"))
    assert.is_false(GlowKit:Stop(button))
    assert.are.equal(1, GlowKit:StopAll(button))
    assert.are.equal(0, GlowKit:StopAll(button))
    assert.is_false(GlowKit:IsGlowing(button))
    local pool = GlowKit._state.pool
    assert.are.equal(0, pool:GetActiveCount())
    local again = GlowKit:Start(button, { lines = 2 })
    local overlay = overlayOf(again)
    assert.are.equal(2, pool:GetCreatedCount())
    for index = 3, #overlay.lines do
      assert.is_false(overlay.lines[index]:IsShown())
    end
  end)

  it("ignores the update of an overlay it gave back, and a secret elapsed time", function()
    TestEnv.InstallSecretProbe()
    local glow = GlowKit:Start(button, { lines = 1, frequency = 1 })
    local overlay = overlayOf(glow)
    TestEnv.Run(overlay, "OnUpdate", TestEnv.NewSecret())
    assert.are.same({ "TOPLEFT", overlay, "TOPLEFT", 0, 0 }, { overlay.lines[1]:GetPoint(1) })
    glow:Stop()
    GlowKit._state.scripts.OnUpdate(overlay, 1)
    assert.is_false(overlay:IsShown())
  end)

  it("holds at most maxGlows glows, a restart not counted twice", function()
    assert.are.same({ maxGlows = 64 }, GlowKit:GetLimits())
    GlowKit:SetLimits({ maxGlows = 1 })
    GlowKit:Start(button)
    GlowKit:Start(button)
    TestEnv.expectErrorContaining(
      "GlowKit:Start holds at most 1 glows at once; stop one, or raise maxGlows",
      function()
        GlowKit:Start(button, { key = "second" })
      end
    )
    GlowKit:SetLimits({ maxGlows = 512 })
    GlowKit:Start(button, { key = "second" })
  end)
end)
