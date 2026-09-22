--- Package-specific test environment for the SignalKit suite.
---
--- The World of Warcraft stubs, the `package.loaded` bookkeeping and the error
--- capture live in the shared `FrameworkTestEnv` fixture at `tests/support/`.
--- What stays here is this package's own module load order.
local FrameworkTestEnv = require("FrameworkTestEnv")

local SignalKitTestEnv = FrameworkTestEnv.New({
    modules = { "Registry", "SignalKit" },
    -- SignalKit is pure Lua: it never touches a World of Warcraft API.
    wowApi = false,
    legacyRegistryState = true,
})

return SignalKitTestEnv
