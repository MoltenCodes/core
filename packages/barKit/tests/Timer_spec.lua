local TestEnv = require("BarKitTestEnv")

describe("BarKit timers", function()
  local BarKit, bar, frame
  before_each(function()
    BarKit = TestEnv.NewPackage()
    TestEnv.InstallHostErrorHandler()
    bar = BarKit:Acquire()
    frame = bar:GetFrame()
  end)
  after_each(TestEnv.Reset)

  it("drains over its duration and writes the time left", function()
    bar:Start(90)
    assert.is_true(bar:IsRunning())
    assert.are.same({ 0, 90 }, { frame:GetMinMaxValues() })
    assert.are.equal(90, frame:GetValue())
    assert.are.equal("1:30", frame.valueText:GetText())
    TestEnv.Advance(frame, 30.5)
    assert.are.equal(59.5, frame:GetValue())
    assert.are.equal("59", frame.valueText:GetText())
    TestEnv.Advance(frame, 50.6)
    assert.are.equal("8.9", frame.valueText:GetText())
    assert.are.equal(8.9, math.floor(bar:GetRemaining() * 10 + 0.5) / 10)
  end)

  it("writes hours, minutes and tenths", function()
    bar:Start(3725)
    assert.are.equal("1:02:05", frame.valueText:GetText())
    bar:Start(9.99)
    assert.are.equal("9.9", frame.valueText:GetText())
  end)

  it("fills instead of draining with fill", function()
    bar:Start(10, { fill = true })
    assert.are.equal(0, frame:GetValue())
    TestEnv.Advance(frame, 4)
    assert.are.equal(4, frame:GetValue())
  end)

  it("calls onFinished once at zero and stops ticking", function()
    local calls = {}
    bar:Start(5, {
      onFinished = function(finished)
        calls[#calls + 1] = finished
      end,
    })
    TestEnv.Advance(frame, 6)
    assert.are.same({ bar }, calls)
    assert.is_false(bar:IsRunning())
    assert.is_nil(frame:GetScript("OnUpdate"))
    assert.are.equal("0.0", frame.valueText:GetText())
    assert.is_nil(bar:GetRemaining())
  end)

  it("reports an onFinished that raises", function()
    bar:Start(1, {
      onFinished = function()
        error("finished failed", 0)
      end,
    })
    TestEnv.Advance(frame, 2)
    local reported = TestEnv.TakeReportedValues()
    assert.are.same({ "finished failed" }, reported)
  end)

  it("releases itself at the end with releaseOnFinish, after onFinished", function()
    local seenRunning = nil
    bar:Start(1, {
      releaseOnFinish = true,
      onFinished = function(finished)
        seenRunning = pcall(finished.IsRunning, finished)
      end,
    })
    TestEnv.Advance(frame, 2)
    assert.is_true(seenRunning)
    assert.are.equal(0, BarKit._state.acquiredCount)
    assert.is_false(frame:IsShown())
  end)

  it("pauses and resumes from where it was", function()
    bar:Start(20)
    TestEnv.Advance(frame, 5)
    assert.is_true(bar:Pause())
    assert.is_false(bar:Pause())
    assert.is_true(bar:IsPaused())
    assert.is_nil(frame:GetScript("OnUpdate"))
    TestEnv.SetTime(1000)
    assert.are.equal(15, bar:GetRemaining())
    assert.is_true(bar:Resume())
    assert.is_false(bar:Resume())
    TestEnv.Advance(frame, 5)
    assert.are.equal(10, bar:GetRemaining())
  end)

  it("stops without the callback, and a new Start replaces a running timer", function()
    local calls = 0
    local function count()
      calls = calls + 1
    end
    bar:Start(5, { onFinished = count })
    bar:Start(8, { onFinished = count })
    assert.are.equal(8, bar:GetRemaining())
    assert.is_true(bar:Stop())
    assert.is_false(bar:Stop())
    TestEnv.Advance(frame, 10)
    assert.are.equal(0, calls)
    bar:Start(3, { onFinished = count })
    bar:SetValue(1)
    assert.is_false(bar:IsRunning())
    bar:Start(3, { onFinished = count })
    bar:SetMinMax(0, 2)
    assert.is_false(bar:IsRunning())
  end)

  it("keeps a text set by hand until the next tick changes the time", function()
    bar:Start(30)
    bar:SetValueText("custom")
    assert.are.equal("custom", frame.valueText:GetText())
    TestEnv.Advance(frame, 0.01)
    assert.are.equal("29", frame.valueText:GetText())
  end)
end)
