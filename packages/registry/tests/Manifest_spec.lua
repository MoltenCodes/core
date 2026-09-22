local TestEnv = require("RegistryTestEnv")

local MANIFEST_PATH = "packages/registry/package.manifest.json"

local function readManifest()
    local file = io.open(MANIFEST_PATH, "r")
    assert.is_not_nil(file)
    local content = file:read("*a")
    file:close()
    return content
end

local function readIntegerField(content, field)
    local value = string.match(content, '"' .. field .. '"%s*:%s*(%d+)')
    assert.is_not_nil(value)
    return tonumber(value)
end

describe("Registry package metadata", function()
    after_each(TestEnv.Reset)

    it("matches runtime API and revision to the package manifest", function()
        local Registry = TestEnv.NewRegistry()
        local manifest = readManifest()

        assert.are.equal(readIntegerField(manifest, "api"), Registry.API)
        assert.are.equal(readIntegerField(manifest, "revision"), Registry.REVISION)
    end)
end)
