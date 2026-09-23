local TestEnv = require("CommKitTestEnv")

describe("CommKit manifest metadata", function()
    after_each(TestEnv.Reset)

    ---@return string
    local function readManifest()
        local file = assert(io.open("packages/commKit/package.manifest.json", "r"))
        local text = file:read("*a")
        file:close()
        return text
    end

    it("matches runtime API and revision", function()
        local CommKit = TestEnv.NewPackage()
        local text = readManifest()
        local api = tonumber(text:match('"api"%s*:%s*(%d+)'))
        local revision = tonumber(text:match('"revision"%s*:%s*(%d+)'))
        assert.are.equal(CommKit.API, api)
        assert.are.equal(CommKit.REVISION, revision)
    end)

    it("declares the six required and three optional dependencies", function()
        local text = readManifest()
        local required = text:match('"dependencies"%s*:%s*(%b{})')
        local optional = text:match('"optionalDependencies"%s*:%s*(%b{})')
        for _, name in ipairs({
            "registry",
            "signalKit",
            "eventKit",
            "lifecycleKit",
            "schedulerKit",
            "poolKit",
        }) do
            assert.is_truthy(required:find('"' .. name .. '"', 1, true), name)
        end
        for _, name in ipairs({ "codecKit", "hookKit", "schemaKit" }) do
            assert.is_truthy(optional:find('"' .. name .. '"', 1, true), name)
            assert.is_nil(required:find('"' .. name .. '"', 1, true), name)
        end
        assert.is_true(text:find('"optionalDependencies"', 1, true) > text:find('"api"', 1, true))
    end)
end)
