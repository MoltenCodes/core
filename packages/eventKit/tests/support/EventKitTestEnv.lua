--- Package-specific test environment for the EventKit suite.
---
--- The World of Warcraft stubs, the `package.loaded` bookkeeping and the error
--- capture live in the shared `FrameworkTestEnv` fixture at `tests/support/`.
--- What stays here is this package's own module load order, and a second
--- environment for the specs that need SchedulerKit.
---
--- SchedulerKit is an optional partner of EventKit: `Coalesce` and `Derive`
--- find it through `Registry:Find` when they are called. The manifest schema
--- has no field for an optional dependency, so the test runner, which builds
--- `LUA_PATH` from the manifest dependency closure, does not put SchedulerKit
--- (or the LifecycleKit and TimerKit it needs) on the path. This file adds
--- their source directories, located relative to this file rather than to the
--- working directory.
local FrameworkTestEnv = require("FrameworkTestEnv")

---Append the `src` directory of each named sibling package to `package.path`.
---@param packageNames string[]
local function addSiblingSources(packageNames)
    local source = debug.getinfo(1, "S").source
    local packagesDirectory = source:match("^@(.*)[/\\]eventKit[/\\]tests[/\\]support[/\\][^/\\]+$")
    if packagesDirectory == nil then
        packagesDirectory = "packages"
    end

    for index = 1, #packageNames do
        local entry = packagesDirectory .. "/" .. packageNames[index] .. "/src/?.lua"
        if not package.path:find(entry, 1, true) then
            package.path = package.path .. ";" .. entry
        end
    end
end

addSiblingSources({ "lifecycleKit", "timerKit", "schedulerKit" })

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
