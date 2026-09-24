local TestEnv = require("WidgetKitHostTestEnv")

describe("WidgetKit execute confirmation with SchedulerKit", function()
  after_each(TestEnv.Reset)

  it("disarms an armed confirmation after five seconds", function()
    local WidgetKit, modules = TestEnv.NewPackage()
    local runs = 0
    local tree = modules.OptionsKit:Define("ConfirmHostSpec", {
      type = "group",
      args = {
        reset = {
          type = "execute",
          name = "Reset",
          confirm = "Really?",
          func = function()
            runs = runs + 1
          end,
        },
      },
    })
    local rendering = WidgetKit:RenderOptions(tree, WidgetKit:Create("Frame"))
    local button = rendering:GetWidget("reset")
    button.frame:Click()
    assert.are.equal("Really?", rendering:GetMessage("reset"))
    local timer = TestEnv.NativeTimers()[#TestEnv.NativeTimers()]
    assert.are.equal(5, timer.seconds)

    TestEnv.AdvanceMs(5000)
    TestEnv.FireLatestTimer()
    TestEnv.Tick()
    assert.is_nil(rendering:GetMessage("reset"))

    -- Disarmed: the next click asks again rather than running.
    button.frame:Click()
    assert.are.equal(0, runs)
    button.frame:Click()
    assert.are.equal(1, runs)
  end)
end)
