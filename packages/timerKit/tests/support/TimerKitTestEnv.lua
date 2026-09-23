--- Package-specific test environment for the TimerKit suite.
---
--- The World of Warcraft stubs, the `package.loaded` bookkeeping and the error
--- capture live in the shared `FrameworkTestEnv` fixture at `tests/support/`.
--- What stays here is this package's own module load order.
---
--- TimerKit requires Registry and nothing else, so the chain is two modules:
--- the two files an addon embeds to use TimerKit alone. Closing addon scopes at
--- logout is LifecycleKit's call into `TimerKit:CloseAddonScopes`, and that
--- integration is covered by LifecycleKit's suite, where both Kits load.
local FrameworkTestEnv = require("FrameworkTestEnv")

local TimerKitTestEnv = FrameworkTestEnv.New({
    modules = { "Registry", "TimerKit" },
})

--- TimerKit's specs name the native-timer failure hooks without the `Timer`
--- infix the shared fixture uses, because in this suite there is nothing else
--- a failed creation or cancellation could refer to.
TimerKitTestEnv.FailNextCreate = TimerKitTestEnv.FailNextTimerCreate
TimerKitTestEnv.FailNextCancel = TimerKitTestEnv.FailNextTimerCancel

return TimerKitTestEnv
