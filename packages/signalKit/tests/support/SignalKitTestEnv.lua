local SignalKitTestEnv = {}

SignalKitTestEnv.REGISTRY_STATE_KEY = "__MOLTENCODES_REGISTRY_STATE_V2"
SignalKitTestEnv.LEGACY_REGISTRY_STATE_KEY = "__MOLTENCODES_REGISTRY_STATE_V1"
SignalKitTestEnv.NAMESPACE_KEY = "MoltenCodes"

function SignalKitTestEnv.Reset()
    package.loaded["SignalKit"] = nil
    package.loaded["Registry"] = nil
    rawset(_G, SignalKitTestEnv.REGISTRY_STATE_KEY, nil)
    rawset(_G, SignalKitTestEnv.LEGACY_REGISTRY_STATE_KEY, nil)
    rawset(_G, SignalKitTestEnv.NAMESPACE_KEY, nil)
end

function SignalKitTestEnv.NewPackage()
    SignalKitTestEnv.Reset()
    local Registry = require("Registry")
    local SignalKit = require("SignalKit")
    return SignalKit, Registry
end

function SignalKitTestEnv.ReloadPackage()
    package.loaded["SignalKit"] = nil
    return require("SignalKit")
end

return SignalKitTestEnv
