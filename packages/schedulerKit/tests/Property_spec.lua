local TestEnv = require("SchedulerKitTestEnv")

describe("SchedulerKit state properties", function()
  after_each(TestEnv.Reset)

  it("keeps scope and package active counts synchronized across mixed operations", function()
    local SchedulerKit = TestEnv.NewPackage()
    SchedulerKit:SetMaxResumesPerFrame(20)
    local scope = SchedulerKit:CreateScope()
    local jobs = {}
    local seed = 173

    local function random(limit)
      seed = (seed * 48271) % 2147483647
      -- The low bits of an LCG cycle quickly, so results come from the high bits.
      return (math.floor(seed / 65536) % limit) + 1
    end

    for _ = 1, 5000 do
      local operation = random(5)
      if operation <= 2 then
        local job
        if operation == 1 then
          job = scope:Schedule(function(context)
            if random(4) == 1 then
              context:Yield()
            end
          end, { priority = random(4) })
        else
          job = scope:After(random(5) - 1, function() end, { priority = random(4) })
        end
        jobs[#jobs + 1] = job
      elseif operation == 3 and #jobs > 0 then
        pcall(function()
          jobs[random(#jobs)]:Cancel()
        end)
      elseif operation == 4 then
        TestEnv.Tick()
      elseif #TestEnv.NativeTimers() > 0 then
        TestEnv.FireNative(random(#TestEnv.NativeTimers()))
      end

      local active = 0
      for index = 1, #jobs do
        if jobs[index]:IsPending() then
          active = active + 1
        end
      end
      assert.are.equal(active, scope:GetActiveCount())
      assert.are.equal(active, SchedulerKit:GetActiveCount())
    end
  end)
end)
