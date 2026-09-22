local PoolKitTestEnv = {}

PoolKitTestEnv.REGISTRY_STATE_KEY = "__MOLTENCODES_REGISTRY_STATE_V2"
PoolKitTestEnv.NAMESPACE_KEY = "MoltenCodes"

function PoolKitTestEnv.Reset()
    package.loaded["PoolKit"] = nil
    package.loaded["Registry"] = nil
    rawset(_G, PoolKitTestEnv.REGISTRY_STATE_KEY, nil)
    rawset(_G, PoolKitTestEnv.NAMESPACE_KEY, nil)
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
