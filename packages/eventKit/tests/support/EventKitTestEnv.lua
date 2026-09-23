--- Package-specific test environment for the EventKit suite.
---
--- The World of Warcraft stubs, the `package.loaded` bookkeeping and the error
--- capture live in the shared `FrameworkTestEnv` fixture at `tests/support/`.
--- What stays here is this package's own module load order, and a second
--- environment for the specs that need SchedulerKit.
---
--- SchedulerKit is an optional partner of EventKit: `Coalesce` and `Derive`
--- find it through `Registry:Find` when they are called. The manifest declares
--- it under `optionalDependencies`, so the test runner puts SchedulerKit and
--- the LifecycleKit and TimerKit it needs on `LUA_PATH` for this suite while
--- the release load order ignores them.
local FrameworkTestEnv = require("FrameworkTestEnv")

local EventKitTestEnv = FrameworkTestEnv.New({
    modules = { "Registry", "SignalKit", "EventKit" },
})

---An environment that also loads SchedulerKit and its dependencies, for the
---coalescing specs. LifecycleKit needs EventKit, so the chain is in
---dependency order; use `NewEventKit` to get the two packages the specs use.
local Scheduled = FrameworkTestEnv.New({
    modules = {
        "Registry",
        "SignalKit",
        "EventKit",
        "LifecycleKit",
        "TimerKit",
        "SchedulerKit",
    },
})

---Load the full chain and return EventKit and SchedulerKit.
---@return table EventKit
---@return table SchedulerKit
function Scheduled.NewEventKit()
    local SchedulerKit, _, _, EventKit = Scheduled.NewPackage()
    return EventKit, SchedulerKit
end

EventKitTestEnv.Scheduled = Scheduled

return EventKitTestEnv
