local TestEnv = require("CommKitTestEnv")

-- Each workload repeats its operation many times, so a single table per call
-- would show up as tens of kilobytes. The threshold leaves room for the few
-- bytes the measurement itself can cost.
local ITERATIONS = 2000
local THRESHOLD_KILOBYTES = 1

describe("CommKit allocation #allocation", function()
  local CommKit
  before_each(function()
    CommKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  ---@param label string
  ---@param workload fun()
  local function assertAllocatesNothing(label, workload)
    workload()
    local allocated = TestEnv.AllocatedKilobytes(function()
      for _ = 1, ITERATIONS do
        workload()
      end
    end)
    assert.is_true(allocated < THRESHOLD_KILOBYTES, label .. " allocated " .. allocated .. " KiB")
  end

  it("allocates nothing to receive and deliver a single chunk", function()
    local received = 0
    CommKit:CreateScope():Register("CKTest", function()
      received = received + 1
    end)
    assertAllocatesNothing("single-chunk receive", function()
      TestEnv.Deliver("CKTest", "\001hello there", "PARTY", "Friend-Realm")
    end)
    assert.are.equal(ITERATIONS + 1, received)
  end)

  it("allocates nothing for a message on a prefix nobody registered", function()
    CommKit:CreateScope():Register("CKTest", function() end)
    assertAllocatesNothing("foreign prefix", function()
      TestEnv.Deliver("Other", "\001hello there", "PARTY", "Friend-Realm")
    end)
  end)

  it("receives two-chunk messages from ever new senders with nothing but strings", function()
    local received = 0
    CommKit:CreateScope():Register("CKTest", function()
      received = received + 1
    end)
    local count = 500
    local messages, keptAlive = {}, {}
    for index = 1, count + 1 do
      local sender = "Sender" .. index .. "-Realm"
      messages[index] = {
        sender = sender,
        first = "\002\129\128\130" .. TestEnv.Text(251),
        last = "\004\129\128\130" .. TestEnv.Text(49),
      }
      -- The reassembly key is interned while it is alive, so building it
      -- again during the measurement allocates nothing.
      keptAlive[index] = "CKTest\tPARTY\t" .. sender .. "\t1"
    end
    local function receive(message)
      TestEnv.Deliver("CKTest", message.first, "PARTY", message.sender)
      TestEnv.Deliver("CKTest", message.last, "PARTY", message.sender)
    end
    receive(messages[count + 1])
    local allocated = TestEnv.AllocatedKilobytes(function()
      for index = 1, count do
        receive(messages[index])
      end
    end)
    assert.are.equal(count + 1, received)
    -- Per message: the two payloads cut from their chunks (251 and 49 bytes)
    -- and the 300-byte message, each with a string header of 24 bytes on a
    -- 64-bit build and its terminator. The margin (64 bytes) is well below
    -- a table: a per-sender record, a stream record or a timer handle built
    -- per message would pass it.
    local strings = (251 + 25) + (49 + 25) + (300 + 25)
    local perMessage = allocated * 1024 / count
    assert.is_true(
      perMessage < strings + 64,
      "two-chunk receive allocated " .. perMessage .. " bytes per message"
    )
    assert.are.equal(#keptAlive, count + 1)
  end)

  it("allocates nothing for the handle and queue queries", function()
    local handle = CommKit:CreateScope():Send({
      prefix = "CKTest",
      text = "hello",
      distribution = "PARTY",
    })
    assertAllocatesNothing("queries", function()
      handle:GetState()
      handle:GetBytesSent()
      CommKit:GetQueueDepth()
      CommKit:GetQueueDepth(CommKit.Priority.BULK)
      CommKit:GetBudget()
    end)
  end)
end)
