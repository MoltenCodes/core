--- Package-specific test environment for the ModuleKit suite.
---
--- The World of Warcraft stubs, the `package.loaded` bookkeeping and the error
--- capture live in the shared `FrameworkTestEnv` fixture at `tests/support/`.
--- What stays here is this package's own module load order.
---
--- HookKit is an optional dependency: only `module.scope.Hooks` uses it, found
--- through `Registry:Find` at first read. The manifest declares it under
--- `optionalDependencies`, so the test runner puts it on `LUA_PATH`, and the
--- module chain loads it as an addon that embeds it would.
--- `NewPackageWithoutHookKit` loads the chain without it.
local FrameworkTestEnv = require("FrameworkTestEnv")

local ModuleKitTestEnv = FrameworkTestEnv.New({
    modules = { "Registry", "SignalKit", "EventKit", "LifecycleKit", "HookKit", "ModuleKit" },
})

---Load the module chain without HookKit, as an addon that embeds none does.
---@return table ModuleKit
function ModuleKitTestEnv.NewPackageWithoutHookKit()
    ModuleKitTestEnv.Reset()
    ModuleKitTestEnv.InstallWowApi()
    require("Registry")
    require("SignalKit")
    require("EventKit")
    require("LifecycleKit")
    return require("ModuleKit")
end

return ModuleKitTestEnv
