local TestEnv = require("TimerKitTestEnv")

---Return the bytes `build` allocates per call, averaged over `count` kept
---results, with the collector stopped.
---@param count integer
---@param build fun(): any
---@return number bytes
local function bytesPer(count, build)
  local kept = {}
  for index = 1, count do
    kept[index] = false
  end
  build()
  local kilobytes = TestEnv.AllocatedKilobytes(function()
    for index = 1, count do
      kept[index] = build()
    end
  end)
  return kilobytes * 1024 / count
end

describe("TimerKit timer records", function()
  after_each(TestEnv.Reset)

  it("stores one-shot and repeating timers in the same small array record #allocation", function()
    local TimerKit = TestEnv.NewPackage()
    local scope = TimerKit:CreateScope()
    local function callback() end
    local oneShot = { delay = 1, callback = callback }
    local repeating = { delay = 1, callback = callback, repeating = true }

    local oneShotBytes = bytesPer(200, function()
      return scope:New(oneShot)
    end)
    local repeatingBytes = bytesPer(200, function()
      return scope:New(repeating)
    end)

    -- Nine array slots: 200 bytes on 64-bit Lua 5.1, against 384 (one-shot)
    -- and 704 (repeating) for eight named fields.
    assert.is_true(oneShotBytes <= 224, "one-shot record " .. oneShotBytes .. " B")
    assert.is_true(repeatingBytes <= 224, "repeating record " .. repeatingBytes .. " B")
    assert.is_true(TestEnv.HasRecordLayout(TimerKit, scope:New(oneShot)))
  end)

  it("attaches user data without growing the record #allocation", function()
    local TimerKit = TestEnv.NewPackage()
    local ticker = TimerKit:Every(1, function() end)
    local timer = TimerKit:New({ delay = 1, callback = function() end })
    local payload = {}

    local kilobytes = TestEnv.AllocatedKilobytes(function()
      ticker:SetUserData(payload)
      timer:SetUserData(payload)
    end)

    assert.are.equal(0, kilobytes)
    assert.are.equal(payload, ticker:GetUserData())
  end)
end)
