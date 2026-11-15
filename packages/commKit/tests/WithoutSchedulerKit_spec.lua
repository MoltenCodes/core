--- Every spec file that drives the send queue, run a second time with
--- SchedulerKit absent: from revision 11 the driver then runs on TimerKit
--- timers, and every documented guarantee of the queue, the bucket, the run
--- cap, backoff, held callbacks and idleness must hold the same way.
local TestEnv = require("CommKitTestEnv")

-- The directory this file lives in, so the other spec files are found
-- wherever the runner starts.
local here = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"

local DRIVER_SPECS = {
  "Allocation_spec.lua",
  "Budget_spec.lua",
  "ChatThrottle_spec.lua",
  "Chunking_spec.lua",
  "FastPaths_spec.lua",
  "HookLookup_spec.lua",
  "Lifecycle_spec.lua",
  "Limits_spec.lua",
  "LogoutClose_spec.lua",
  "Queue_spec.lua",
  "RawMessages_spec.lua",
  "Reassembly_spec.lua",
  "Robustness_spec.lua",
  "SendAtOnce_spec.lua",
  "Statistics_spec.lua",
  "SyncSet_spec.lua",
}

describe("CommKit without SchedulerKit", function()
  setup(function()
    TestEnv.withoutSchedulerKit = true
  end)
  teardown(function()
    TestEnv.withoutSchedulerKit = false
  end)

  -- Busted gives a spec file its own environment holding `describe`, `it`
  -- and the rest; each nested file runs in this file's environment.
  local environment = getfenv(1)
  for index = 1, #DRIVER_SPECS do
    local chunk = assert(loadfile(here .. DRIVER_SPECS[index]))
    setfenv(chunk, environment)
    chunk()
  end
end)
