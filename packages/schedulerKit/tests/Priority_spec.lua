local TestEnv = require("SchedulerKitTestEnv")

describe("SchedulerKit priorities", function()
  after_each(TestEnv.Reset)

  it("is FIFO within a priority lane", function()
    local SchedulerKit = TestEnv.NewPackage()
    local order = {}
    for index = 1, 5 do
      SchedulerKit:Schedule(function()
        order[#order + 1] = index
      end, { priority = SchedulerKit.Priority.NORMAL })
    end

    TestEnv.Tick()
    assert.are.same({ 1, 2, 3, 4, 5 }, order)
  end)

  it("gives high priority more service while preserving lower-priority progress", function()
    local SchedulerKit = TestEnv.NewPackage()
    SchedulerKit:SetMaxResumesPerFrame(7)
    local order = {}

    for index = 1, 8 do
      SchedulerKit:Schedule(function()
        order[#order + 1] = "H" .. index
      end, { priority = SchedulerKit.Priority.HIGH })
    end
    for index = 1, 3 do
      SchedulerKit:Schedule(function()
        order[#order + 1] = "N" .. index
      end, { priority = SchedulerKit.Priority.NORMAL })
    end
    SchedulerKit:Schedule(function()
      order[#order + 1] = "L"
    end, {
      priority = SchedulerKit.Priority.LOW,
    })

    TestEnv.Tick()
    assert.are.same({ "H1", "H2", "H3", "H4", "N1", "N2", "L" }, order)
    TestEnv.Tick()
    assert.are.same(
      { "H1", "H2", "H3", "H4", "N1", "N2", "L", "H5", "H6", "H7", "H8", "N3" },
      order
    )
  end)

  it("runs IDLE work only once no contending lane is ready", function()
    local SchedulerKit = TestEnv.NewPackage()
    SchedulerKit:SetMaxResumesPerFrame(4)
    local order = {}

    SchedulerKit:Schedule(function()
      order[#order + 1] = "I"
    end, { priority = SchedulerKit.Priority.IDLE })
    for index = 1, 3 do
      SchedulerKit:Schedule(function()
        order[#order + 1] = "N" .. index
      end, { priority = SchedulerKit.Priority.NORMAL })
    end

    TestEnv.Tick()
    assert.are.same({ "N1", "N2", "N3", "I" }, order)
  end)

  it("promotes IDLE work once the starvation guard trips", function()
    local SchedulerKit = TestEnv.NewPackage()
    SchedulerKit:SetMaxResumesPerFrame(400)
    local order = {}

    SchedulerKit:Schedule(function()
      order[#order + 1] = "I"
    end, { priority = SchedulerKit.Priority.IDLE })

    -- More contending work than the guard tolerates, so IDLE must be served
    -- before the HIGH lane drains.
    for _ = 1, 300 do
      SchedulerKit:Schedule(function()
        order[#order + 1] = "H"
      end, { priority = SchedulerKit.Priority.HIGH })
    end

    TestEnv.Tick()

    local idleIndex
    for index = 1, #order do
      if order[index] == "I" then
        idleIndex = index
        break
      end
    end
    assert.are.equal(257, idleIndex)
  end)

  it("does not let guard credit accumulate while no IDLE work waits", function()
    local SchedulerKit = TestEnv.NewPackage()
    SchedulerKit:SetMaxResumesPerFrame(400)
    local order = {}

    for _ = 1, 300 do
      SchedulerKit:Schedule(function()
        order[#order + 1] = "H"
      end, { priority = SchedulerKit.Priority.HIGH })
    end
    TestEnv.Tick()
    assert.are.equal(300, #order)

    -- The guard was never charged, so a newly arrived IDLE job still waits
    -- behind contending work instead of being promoted immediately.
    SchedulerKit:Schedule(function()
      order[#order + 1] = "I"
    end, { priority = SchedulerKit.Priority.IDLE })
    for _ = 1, 3 do
      SchedulerKit:Schedule(function()
        order[#order + 1] = "H"
      end, { priority = SchedulerKit.Priority.HIGH })
    end

    TestEnv.Tick()
    assert.are.same({ "H", "H", "H", "I" }, {
      order[301],
      order[302],
      order[303],
      order[304],
    })
  end)

  it("stops charging the guard once the last IDLE job has been served", function()
    local SchedulerKit = TestEnv.NewPackage()
    SchedulerKit:SetMaxResumesPerFrame(1000)
    local order = {}
    local secondScheduledAt = nil
    SchedulerKit:Schedule(function(context)
      while true do
        order[#order + 1] = "H"
        -- Long after the first IDLE job ran, a second one arrives.
        if #order == 400 then
          secondScheduledAt = #order
          SchedulerKit:Schedule(function()
            order[#order + 1] = "second I"
          end, { priority = SchedulerKit.Priority.IDLE })
        end
        context:Yield()
      end
    end, { priority = SchedulerKit.Priority.HIGH })
    SchedulerKit:Schedule(function()
      order[#order + 1] = "I"
    end, { priority = SchedulerKit.Priority.IDLE })

    TestEnv.Tick()

    -- The first IDLE job is promoted by the guard. The IDLE lane is empty
    -- from then until the second job arrives, so that stretch earns the
    -- second job no credit: it waits a full guard period of 256 resumes.
    assert.are.equal("I", order[257])
    assert.are.equal(400, secondScheduledAt)
    assert.are.equal("H", order[400 + 256])
    assert.are.equal("second I", order[400 + 257])
  end)

  it("keeps the fairness cursor across frames", function()
    local SchedulerKit = TestEnv.NewPackage()
    SchedulerKit:SetMaxResumesPerFrame(1)
    local order = {}
    for _ = 1, 8 do
      SchedulerKit:Schedule(function()
        order[#order + 1] = "H"
      end, {
        priority = SchedulerKit.Priority.HIGH,
      })
    end
    SchedulerKit:Schedule(function()
      order[#order + 1] = "N"
    end, {
      priority = SchedulerKit.Priority.NORMAL,
    })

    for _ = 1, 5 do
      TestEnv.Tick()
    end
    assert.are.same({ "H", "H", "H", "H", "N" }, order)
  end)
end)
