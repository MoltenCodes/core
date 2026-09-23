--- Package-specific test environment for the SchedulerKit suite.
---
--- The World of Warcraft stubs, the `package.loaded` bookkeeping and the error
--- capture live in the shared `FrameworkTestEnv` fixture at `tests/support/`.
--- What stays here is this package's own module load order.
---
--- SchedulerKit requires Registry and TimerKit and nothing else, so the chain
--- is the three files an addon embeds to use SchedulerKit alone. Closing addon
--- scopes at logout is LifecycleKit's call into
--- `SchedulerKit:CloseAddonScopes`, covered by LifecycleKit's suite.
local FrameworkTestEnv = require("FrameworkTestEnv")

local SchedulerKitTestEnv = FrameworkTestEnv.New({
    modules = {
        "Registry",
        "TimerKit",
        "SchedulerKit",
    },
})

return SchedulerKitTestEnv
