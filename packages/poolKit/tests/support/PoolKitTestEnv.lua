--- Package-specific test environment for the PoolKit suite.
---
--- The World of Warcraft stubs, the `package.loaded` bookkeeping and the error
--- capture live in the shared `FrameworkTestEnv` fixture at `tests/support/`.
--- What stays here is this package's own module load order.
local FrameworkTestEnv = require("FrameworkTestEnv")

local PoolKitTestEnv = FrameworkTestEnv.New({
    modules = { "Registry", "PoolKit" },
    -- PoolKit is pure Lua and stays silent without a host error sink, so its
    -- specs install `geterrorhandler` explicitly through
    -- `InstallHostErrorHandler` rather than having it installed for them.
    wowApi = false,
})

--- Diagnostics PoolKit handed to the host error handler, in order.
---@return any[]
function PoolKitTestEnv.ReportedWarnings()
    return PoolKitTestEnv.ReportedErrors()
end

return PoolKitTestEnv
