local TestEnv = require("RegistryTestEnv")

describe("Registry:Find", function()
    local Registry

    before_each(function()
        Registry = TestEnv.NewRegistry()
    end)

    after_each(TestEnv.Reset)

    it("reports an absent package without raising", function()
        local implementation, reason = Registry:Find("missingKit", 1)

        assert.is_nil(implementation)
        assert.are.equal("absent", reason)
    end)

    it("returns the same table and revision Get returns", function()
        local registered = Registry:Register("demoKit", 1, 3)

        local implementation, revision = Registry:Find("demoKit", 1)

        assert.are.equal(registered, implementation)
        assert.are.equal(3, revision)
        assert.are.equal(registered, (Registry:Get("demoKit", 1)))
    end)

    it("tells a different API generation apart from an absent package", function()
        Registry:Register("demoKit", 1, 1)

        local implementation, reason = Registry:Find("demoKit", 2)

        assert.is_nil(implementation)
        assert.are.equal("generation_mismatch", reason)
    end)

    it("reports a package whose upgrade retired it without finishing", function()
        local older = Registry:Register("demoKit", 1, 1)
        older.API = 1
        older.REVISION = 1

        assert.has_error(function()
            Registry:Bootstrap({
                package = "demoKit",
                api = 1,
                revision = 2,
                label = "MoltenCodes DemoKit",
                validatePublicSurface = function()
                    return true
                end,
                migrations = {
                    [2] = function()
                        error("layout cannot be converted")
                    end,
                },
            })
        end)

        local implementation, reason = Registry:Find("demoKit", 1)
        assert.is_nil(implementation)
        assert.are.equal("retired", reason)
    end)

    it("allocates nothing, hit or miss, and neither does Get #allocation", function()
        Registry:Register("demoKit", 1, 3)
        Registry:Find("demoKit", 1)
        Registry:Find("missingKit", 1)
        Registry:Get("demoKit", 1)

        collectgarbage()
        collectgarbage("stop")
        local before = collectgarbage("count")
        for _ = 1, 200 do
            Registry:Find("demoKit", 1)
            Registry:Find("demoKit", 2)
            Registry:Find("missingKit", 1)
            Registry:Get("demoKit", 1)
        end
        local after = collectgarbage("count")
        collectgarbage("restart")

        assert.are.equal(before, after)
    end)

    it("raises at the caller for malformed arguments", function()
        local source = debug.getinfo(1, "S").short_src
        local line
        local ok, message = pcall(function()
            line = debug.getinfo(1, "l").currentline + 1
            Registry:Find("", 1)
        end)

        assert.is_false(ok)
        assert.are.equal(
            source .. ":" .. line .. ": Registry:Find packageName must be a non-empty string",
            message
        )
        assert.has_error(function()
            Registry:Find("demoKit", 0)
        end)
    end)
end)

describe("Registry:Packages", function()
    local Registry

    before_each(function()
        Registry = TestEnv.NewRegistry()
    end)

    after_each(TestEnv.Reset)

    it("lists every registration sorted by package, then API", function()
        Registry:Register("zetaKit", 1, 4)
        Registry:Register("alphaKit", 2, 1)
        Registry:Register("alphaKit", 1, 9)

        assert.are.same({
            { package = "alphaKit", api = 1, revision = 9, status = "active" },
            { package = "alphaKit", api = 2, revision = 1, status = "active" },
            { package = "zetaKit", api = 1, revision = 4, status = "active" },
        }, Registry:Packages())
    end)

    it("returns a fresh snapshot that cannot mutate Registry state", function()
        Registry:Register("demoKit", 1, 2)

        local first = Registry:Packages()
        first[1].revision = 99
        first[2] = "junk"
        local second = Registry:Packages()

        assert.are_not.equal(first, second)
        assert.are.equal(1, #second)
        assert.are.equal(2, second[1].revision)
        assert.are.equal(2, select(2, Registry:Get("demoKit", 1)))
    end)

    it("returns an empty array when nothing is registered", function()
        assert.are.same({}, Registry:Packages())
    end)
end)
