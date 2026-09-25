local TestEnv = require("WidgetKitTestEnv")

local PARENT = { left = 0, bottom = 0, width = 1000, height = 600 }

---A 100 x 100 rect with its bottom-left corner at (`left`, `bottom`).
local function square(left, bottom)
  return { left = left, bottom = bottom, width = 100, height = 100 }
end

describe("WidgetKit anchors", function()
  local WidgetKit
  local Anchor
  before_each(function()
    WidgetKit = TestEnv.NewPackage()
    Anchor = WidgetKit.Anchor
  end)
  after_each(TestEnv.Reset)

  it("elects the nearest of the nine points", function()
    local cases = {
      { rect = square(10, 490), point = "TOPLEFT", x = 10, y = -10 },
      { rect = square(450, 490), point = "TOP", x = 0, y = -10 },
      { rect = square(890, 490), point = "TOPRIGHT", x = -10, y = -10 },
      { rect = square(10, 250), point = "LEFT", x = 10, y = 0 },
      { rect = square(450, 250), point = "CENTER", x = 0, y = 0 },
      { rect = square(890, 250), point = "RIGHT", x = -10, y = 0 },
      { rect = square(10, 10), point = "BOTTOMLEFT", x = 10, y = 10 },
      { rect = square(450, 10), point = "BOTTOM", x = 0, y = 10 },
      { rect = square(890, 10), point = "BOTTOMRIGHT", x = -10, y = 10 },
      -- Off-centre but nearer the centre than any edge.
      { rect = square(380, 300), point = "CENTER", x = -70, y = 50 },
    }
    for _, case in ipairs(cases) do
      local anchor = Anchor.FromRect(case.rect, PARENT)
      assert.are.same({
        point = case.point,
        relativePoint = case.point,
        x = case.x,
        y = case.y,
      }, anchor)
    end
  end)

  it("breaks ties deterministically in POINTS order", function()
    assert.are.same({
      "CENTER",
      "TOP",
      "BOTTOM",
      "LEFT",
      "RIGHT",
      "TOPLEFT",
      "TOPRIGHT",
      "BOTTOMLEFT",
      "BOTTOMRIGHT",
    }, Anchor.POINTS)
    -- A rect the size of its parent is equally near to every point.
    assert.are.equal("CENTER", Anchor.FromRect(PARENT, PARENT).point)
    -- A point a quarter across is as near LEFT as CENTER: CENTER wins.
    local quarter = { left = 250, bottom = 300, width = 0, height = 0 }
    assert.are.equal("CENTER", Anchor.FromRect(quarter, PARENT).point)
    -- Equally near TOP and TOPLEFT: TOP wins.
    local between = { left = 250, bottom = 600, width = 0, height = 0 }
    assert.are.equal("TOP", Anchor.FromRect(between, PARENT).point)
  end)

  it("fills a given anchor table in place #allocation", function()
    local into = { relativeTo = "Stale", scale = 3 }
    local anchor = Anchor.FromRect(square(10, 10), PARENT, into)
    assert.are.equal(into, anchor)
    assert.is_nil(anchor.relativeTo)
    assert.is_nil(anchor.scale)
    local allocated = TestEnv.AllocatedKilobytes(function()
      for _ = 1, 200 do
        Anchor.FromRect(PARENT, PARENT, into)
      end
    end)
    assert.is_true(allocated < 1, "FromRect into a table allocated " .. allocated .. " KB")
  end)

  it("normalises every SetPoint argument form", function()
    local createFrame = TestEnv.GetGlobal("CreateFrame")
    local uiParent = TestEnv.GetGlobal("UIParent")
    local named = createFrame("Frame", "WidgetKitSpecAnchorTarget", uiParent)
    local unnamed = createFrame("Frame", nil, uiParent)
    local frame = createFrame("Frame", nil, uiParent)
    frame:SetScale(0.8)

    local function normalise(...)
      local anchor = Anchor.Normalize(frame, ...)
      return {
        anchor.point,
        anchor.relativeTo,
        anchor.relativePoint,
        anchor.x,
        anchor.y,
        anchor.scale,
      }
    end

    assert.are.same({ "TOP", "UIParent", "TOP", 0, 0, 0.8 }, normalise("TOP"))
    assert.are.same({ "LEFT", "UIParent", "LEFT", 5, 6, 0.8 }, normalise("LEFT", 5, 6))
    assert.are.same(
      { "LEFT", "WidgetKitSpecAnchorTarget", "LEFT", 0, 0, 0.8 },
      normalise("LEFT", named)
    )
    assert.are.same(
      { "LEFT", "WidgetKitSpecAnchorTarget", "RIGHT", 0, 0, 0.8 },
      normalise("LEFT", named, "RIGHT")
    )
    assert.are.same(
      { "LEFT", "WidgetKitSpecAnchorTarget", "LEFT", 3, 4, 0.8 },
      normalise("LEFT", named, 3, 4)
    )
    assert.are.same(
      { "TOPLEFT", "WidgetKitSpecAnchorTarget", "BOTTOMLEFT", 1, 2, 0.8 },
      normalise("TOPLEFT", "WidgetKitSpecAnchorTarget", "BOTTOMLEFT", 1, 2)
    )
    assert.are.same(
      { "TOPLEFT", "UIParent", "BOTTOMLEFT", 3, 4, 0.8 },
      normalise("TOPLEFT", nil, "BOTTOMLEFT", 3, 4)
    )
    -- An unnamed relative frame cannot be saved by name, so it is kept.
    assert.are.equal(unnamed, Anchor.Normalize(frame, "TOP", unnamed).relativeTo)

    TestEnv.expectErrorContaining("point must be one of the nine anchor points", function()
      Anchor.Normalize(frame, "MIDDLE")
    end)
    TestEnv.expectErrorContaining("relativePoint must be one of", function()
      Anchor.Normalize(frame, "TOP", named, "SIDE")
    end)
  end)

  it("round-trips Normalize, Apply and Read", function()
    local createFrame = TestEnv.GetGlobal("CreateFrame")
    local uiParent = TestEnv.GetGlobal("UIParent")
    local target = createFrame("Frame", "WidgetKitSpecAnchorTarget", uiParent)
    local frame = createFrame("Frame", nil, uiParent)
    local anchor = {
      point = "BOTTOMRIGHT",
      relativeTo = "WidgetKitSpecAnchorTarget",
      relativePoint = "TOPLEFT",
      x = -4,
      y = 7,
      scale = 1.25,
    }
    assert.is_true(Anchor.Apply(frame, anchor))
    assert.are.equal(1.25, frame:GetScale())
    local point, relativeTo, relativePoint, x, y = frame:GetPoint(1)
    assert.are.same({ "BOTTOMRIGHT", target, "TOPLEFT", -4, 7 }, {
      point,
      relativeTo,
      relativePoint,
      x,
      y,
    })
    assert.are.same(anchor, Anchor.Read(frame))

    local bare = createFrame("Frame", nil, uiParent)
    assert.is_nil(Anchor.Read(bare))
  end)

  it("refuses to apply an anchor naming no frame and leaves the frame alone", function()
    local frame = TestEnv.GetGlobal("CreateFrame")("Frame", nil, TestEnv.GetGlobal("UIParent"))
    frame:SetPoint("CENTER")
    local applied, reason = Anchor.Apply(frame, { point = "TOP", relativeTo = "NoSuchFrame" })
    assert.is_false(applied)
    assert.are.equal("unknownRelative", reason)
    assert.are.equal("CENTER", (frame:GetPoint(1)))

    TestEnv.expectErrorContaining("anchor.x must be a number", function()
      Anchor.Apply(frame, { point = "TOP", x = "left" })
    end)
    TestEnv.expectErrorContaining(
      "rect must be a table with left, bottom, width and height",
      function()
        Anchor.FromRect({ left = 1 }, PARENT)
      end
    )
  end)

  it("refuses an anchor to the frame itself before changing anything", function()
    local frame = TestEnv.GetGlobal("CreateFrame")(
      "Frame",
      "WidgetKitSpecAnchorSelf",
      TestEnv.GetGlobal("UIParent")
    )
    frame:SetPoint("CENTER")
    local clears = frame.clearAllPointsCount or 0
    for _, relativeTo in ipairs({ "WidgetKitSpecAnchorSelf", frame }) do
      local applied, reason =
        Anchor.Apply(frame, { point = "TOP", relativeTo = relativeTo, scale = 3 })
      assert.is_false(applied)
      assert.are.equal("refused", reason)
    end
    assert.are.equal(clears, frame.clearAllPointsCount or 0)
    assert.are.equal(1, frame:GetNumPoints())
    assert.are.equal("CENTER", (frame:GetPoint(1)))
    assert.are.equal(1, frame:GetScale())
  end)

  it("puts the points and scale back when the client refuses an anchor cycle", function()
    local createFrame = TestEnv.GetGlobal("CreateFrame")
    local uiParent = TestEnv.GetGlobal("UIParent")
    local frame = createFrame("Frame", nil, uiParent)
    frame:SetPoint("TOPLEFT", uiParent, "TOPLEFT", 10, -10)
    frame:SetPoint("BOTTOMRIGHT", uiParent, "BOTTOMRIGHT", -10, 10)
    local follower = createFrame("Frame", "WidgetKitSpecAnchorFollower", uiParent)
    follower:SetPoint("TOP", frame, "BOTTOM", 0, 0)

    local applied, reason = Anchor.Apply(frame, {
      point = "TOP",
      relativeTo = "WidgetKitSpecAnchorFollower",
      scale = 2,
    })
    assert.is_false(applied)
    assert.are.equal("refused", reason)
    assert.are.equal(1, frame:GetScale())
    assert.are.equal(2, frame:GetNumPoints())
    local point, relativeTo, relativePoint, x, y = frame:GetPoint(1)
    assert.are.same({ "TOPLEFT", uiParent, "TOPLEFT", 10, -10 }, {
      point,
      relativeTo,
      relativePoint,
      x,
      y,
    })
    point, relativeTo, relativePoint, x, y = frame:GetPoint(2)
    assert.are.same({ "BOTTOMRIGHT", uiParent, "BOTTOMRIGHT", -10, 10 }, {
      point,
      relativeTo,
      relativePoint,
      x,
      y,
    })
  end)

  it("keeps no table for a refused anchor #allocation", function()
    local createFrame = TestEnv.GetGlobal("CreateFrame")
    local uiParent = TestEnv.GetGlobal("UIParent")
    local frame = createFrame("Frame", nil, uiParent)
    frame:SetPoint("CENTER")
    local follower = createFrame("Frame", "WidgetKitSpecAnchorLoop", uiParent)
    follower:SetPoint("TOP", frame, "BOTTOM", 0, 0)
    local anchor = { point = "TOP", relativeTo = "WidgetKitSpecAnchorLoop" }
    Anchor.Apply(frame, anchor)
    local kilobytes = TestEnv.AllocatedKilobytes(function()
      for _ = 1, 200 do
        Anchor.Apply(frame, anchor)
      end
    end)
    assert.is_true(kilobytes < 1, "allocated " .. kilobytes .. " KiB")
  end)

  it("leaves a frame the current code may not touch alone", function()
    local frame = TestEnv.GetGlobal("CreateFrame")("Frame", nil, TestEnv.GetGlobal("UIParent"))
    frame:SetPoint("CENTER")
    function frame.CanBeAccessedInContext()
      return false
    end
    local applied, reason = Anchor.Apply(frame, { point = "TOP", scale = 2 })
    assert.is_false(applied)
    assert.are.equal("forbidden", reason)
    assert.are.equal("CENTER", (frame:GetPoint(1)))
    assert.are.equal(1, frame:GetScale())
  end)

  it("refuses malformed anchors, relative frames and into tables at the caller", function()
    local uiParent = TestEnv.GetGlobal("UIParent")
    local frame = TestEnv.GetGlobal("CreateFrame")("Frame", nil, uiParent)
    frame:SetPoint("CENTER")
    TestEnv.expectErrorContaining(
      "WidgetKit.Anchor.Apply anchor must be an anchor table",
      function()
        Anchor.Apply(frame, "TOP")
      end
    )
    TestEnv.expectErrorContaining(
      "WidgetKit.Anchor.Apply anchor.relativeTo must be a frame, a frame name or nil",
      function()
        Anchor.Apply(frame, { point = "TOP", relativeTo = 5 })
      end
    )
    TestEnv.expectErrorContaining("WidgetKit.Anchor.Apply anchor.scale must be above 0", function()
      Anchor.Apply(frame, { point = "TOP", scale = 0 })
    end)
    -- Every refusal left the frame where it was.
    assert.are.equal("CENTER", (frame:GetPoint(1)))
    assert.are.equal(1, frame:GetScale())

    TestEnv.expectErrorContaining("WidgetKit.Anchor.Normalize frame must be a frame", function()
      Anchor.Normalize({}, "TOP")
    end)
    TestEnv.expectErrorContaining(
      "WidgetKit.Anchor.Normalize relativeTo must be a frame, a frame name or nil",
      function()
        Anchor.Normalize(frame, "TOP", true)
      end
    )
    TestEnv.expectErrorContaining(
      "WidgetKit.Anchor.FromRect into must be a table or nil",
      function()
        Anchor.FromRect(square(0, 0), PARENT, "anchor")
      end
    )
  end)

  it("refuses a secret relative frame before it is compared", function()
    TestEnv.InstallSecretProbe()
    local secret = TestEnv.NewSecret()
    local frame = TestEnv.GetGlobal("CreateFrame")("Frame", nil, TestEnv.GetGlobal("UIParent"))
    frame:SetPoint("CENTER")
    TestEnv.expectErrorContaining(
      "WidgetKit.Anchor.Apply anchor.relativeTo must not be a secret value",
      function()
        Anchor.Apply(frame, { point = "TOP", relativeTo = secret })
      end
    )
    assert.are.equal("CENTER", (frame:GetPoint(1)))
  end)
end)
