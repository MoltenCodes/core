local TestEnv = require("EventKitTestEnv")

local MANIFEST_PATH = "packages/eventKit/package.manifest.json"

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

describe("EventKit package metadata", function()
    after_each(TestEnv.Reset)
    it("matches runtime API and revision to the package manifest", function()
        local EventKit = TestEnv.NewPackage()
        local manifest = readManifest()
        assert.are.equal(readIntegerField(manifest, "api"), EventKit.API)
        assert.are.equal(readIntegerField(manifest, "revision"), EventKit.REVISION)
    end)
end)
