local TestEnv = require("CodecKitTestEnv")

describe("CodecKit manifest metadata", function()
    after_each(TestEnv.Reset)

    local function readManifest()
        local file = assert(io.open("packages/codecKit/package.manifest.json", "r"))
        local text = file:read("*a")
        file:close()
        return text
    end

    it("matches runtime API and revision", function()
        local CodecKit = TestEnv.NewPackage()
        local text = readManifest()
        local api = tonumber(text:match('"api"%s*:%s*(%d+)'))
        local revision = tonumber(text:match('"revision"%s*:%s*(%d+)'))

        assert.are.equal(CodecKit.API, api)
        assert.are.equal(CodecKit.REVISION, revision)
    end)

    it("declares Registry API 2 and PoolKit API 1, and SchedulerKit API 1 as optional", function()
        local text = readManifest()
        local dependencies = text:match('"dependencies"%s*:%s*(%b{})')
        assert.is_not_nil(dependencies:find('"registry"%s*:%s*{%s*"api"%s*:%s*2%s*}'))
        assert.is_not_nil(dependencies:find('"poolKit"%s*:%s*{%s*"api"%s*:%s*1%s*}'))
        local _, names = dependencies:gsub('"%w+"%s*:%s*{', "")
        assert.are.equal(2, names)

        local optional = text:match('"optionalDependencies"%s*:%s*(%b{})')
        assert.is_not_nil(optional:find('"schedulerKit"%s*:%s*{%s*"api"%s*:%s*1%s*}'))
        -- Every Manifest_spec reads the first "api" in the file, so the
        -- optional dependencies must come after the top-level field.
        assert.is_true(text:find('"optionalDependencies"', 1, true) > text:find('"api"', 1, true))
    end)
end)
