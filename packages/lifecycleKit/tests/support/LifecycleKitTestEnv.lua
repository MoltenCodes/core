--- Package-specific test environment for the LifecycleKit suite.
---
--- The World of Warcraft stubs, the `package.loaded` bookkeeping and the error
--- capture live in the shared `FrameworkTestEnv` fixture at `tests/support/`.
--- What stays here is this package's own module load order.
local FrameworkTestEnv = require("FrameworkTestEnv")

local LifecycleKitTestEnv = FrameworkTestEnv.New({
    modules = { "Registry", "SignalKit", "EventKit", "LifecycleKit" },
})

return LifecycleKitTestEnv
