local RegistryTestEnv = {}

RegistryTestEnv.STATE_KEY = "__MOLTENCODES_REGISTRY_STATE_V2"
RegistryTestEnv.LEGACY_STATE_KEY = "__MOLTENCODES_REGISTRY_STATE_V1"
RegistryTestEnv.NAMESPACE_KEY = "MoltenCodes"

function RegistryTestEnv.Reset()
    package.loaded["Registry"] = nil
    rawset(_G, RegistryTestEnv.STATE_KEY, nil)
    rawset(_G, RegistryTestEnv.LEGACY_STATE_KEY, nil)
    rawset(_G, RegistryTestEnv.NAMESPACE_KEY, nil)
end

function RegistryTestEnv.Reload()
    package.loaded["Registry"] = nil
    return require("Registry")
end

function RegistryTestEnv.NewRegistry()
    RegistryTestEnv.Reset()
    return require("Registry")
end

function RegistryTestEnv.GetState()
    return rawget(_G, RegistryTestEnv.STATE_KEY)
end

function RegistryTestEnv.GetNamespace()
    return rawget(_G, RegistryTestEnv.NAMESPACE_KEY)
end

return RegistryTestEnv
