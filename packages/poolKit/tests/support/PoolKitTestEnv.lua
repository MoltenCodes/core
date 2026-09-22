local PoolKitTestEnv = {}

PoolKitTestEnv.REGISTRY_STATE_KEY = "__MOLTENCODES_REGISTRY_STATE_V2"
PoolKitTestEnv.NAMESPACE_KEY = "MoltenCodes"

local reportedWarnings = {}

function PoolKitTestEnv.Reset()
    package.loaded["PoolKit"] = nil
    package.loaded["Registry"] = nil
    rawset(_G, PoolKitTestEnv.REGISTRY_STATE_KEY, nil)
    rawset(_G, PoolKitTestEnv.NAMESPACE_KEY, nil)
    rawset(_G, "geterrorhandler", nil)
    reportedWarnings = {}
end

---Install the World of Warcraft error sink PoolKit reports diagnostics through.
---PoolKit is pure Lua and stays silent without it, so specs opt in explicitly.
function PoolKitTestEnv.InstallHostErrorHandler()
    rawset(_G, "geterrorhandler", function()
        return function(value)
            reportedWarnings[#reportedWarnings + 1] = value
        end
    end)
end

---@return table reported Diagnostics handed to the host error handler, in order.
function PoolKitTestEnv.ReportedWarnings()
    return reportedWarnings
end

function PoolKitTestEnv.NewPackage()
    PoolKitTestEnv.Reset()
    local Registry = require("Registry")
    local PoolKit = require("PoolKit")
    return PoolKit, Registry
end

function PoolKitTestEnv.ReloadPackage()
    package.loaded["PoolKit"] = nil
    return require("PoolKit")
end

return PoolKitTestEnv
