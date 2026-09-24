local TestEnv = require("WidgetKitHostTestEnv")

describe("WidgetKit position binding with SchedulerKit and SettingsKit", function()
  local WidgetKit, modules
  before_each(function()
    WidgetKit, modules = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("debounces saves through SchedulerKit", function()
    local window = WidgetKit:Create("Frame")
    local storage = {}
    local binding = window:BindPosition(storage, { delay = 0.5 })

    TestEnv.MoveFrame(window.frame, 20, 560)
    binding:Capture()
    TestEnv.MoveFrame(window.frame, 30, 560)
    binding:Capture()
    assert.is_nil(storage.anchor)

    TestEnv.AdvanceMs(500)
    TestEnv.FireLatestTimer()
    assert.are.equal(30, storage.anchor.x)
    assert.are.equal("TOPLEFT", storage.anchor.point)
  end)

  it("flushes a pending save on demand and on release", function()
    local window = WidgetKit:Create("Frame")
    local storage = {}
    local binding = window:BindPosition(storage)
    TestEnv.MoveFrame(window.frame, 1200, 20)
    binding:Capture()
    assert.is_nil(storage.anchor)
    assert.is_true(binding:Flush())
    assert.are.equal("BOTTOMRIGHT", storage.anchor.point)

    TestEnv.MoveFrame(window.frame, 610, 290)
    binding:Capture()
    binding:Release()
    assert.are.equal("CENTER", storage.anchor.point)
  end)

  it("saves into and restores from a SettingsKit scope view", function()
    local S = modules.SchemaKit
    local SettingsKit = modules.SettingsKit
    local db = SettingsKit:Open(TestEnv.SavedVariable("WidgetKitSpecDB"), {
      global = S.table({
        fields = {
          window = S.optional(S.table({
            fields = {
              point = S.optional(S.string()),
              relativeTo = S.optional(S.string()),
              relativePoint = S.optional(S.string()),
              x = S.optional(S.number()),
              y = S.optional(S.number()),
              scale = S.optional(S.number()),
            },
          })),
        },
      }),
    })

    local window = WidgetKit:Create("Frame")
    local binding = window:BindPosition(db.global, { key = "window" })
    TestEnv.MoveFrame(window.frame, 20, 20)
    binding:Capture()
    binding:Flush()
    assert.are.equal("BOTTOMLEFT", db.global.window.point)
    assert.are.equal("UIParent", db.global.window.relativeTo)
    assert.are.equal(20, db.global.window.x)

    local other = WidgetKit:Create("Frame")
    other:BindPosition(db.global, { key = "window" })
    local point, _, _, x, y = other.frame:GetPoint(1)
    assert.are.same({ "BOTTOMLEFT", 20, 20 }, { point, x, y })
  end)
end)
