local TestEnv = require("RegistryTestEnv")

---Bootstrap `demoKit` API 1 at `revision` and commit its surface via `rawset`.
---@param Registry Registry
---@param revision integer
---@param sealFacade boolean|nil
---@return table|nil implementation
local function loadCopy(Registry, revision, sealFacade)
    local implementation = Registry:Bootstrap({
        package = "demoKit",
        api = 1,
        revision = revision,
        label = "MoltenCodes DemoKit",
        validatePublicSurface = function(candidate)
            return rawget(candidate, "API") == 1
        end,
        sealFacade = sealFacade,
    })
    if implementation ~= nil then
        rawset(implementation, "API", 1)
        rawset(implementation, "REVISION", revision)
        rawset(implementation, "Run", function()
            return revision
        end)
    end
    return implementation
end

describe("Registry sealed facades", function()
    after_each(TestEnv.Reset)

    it("refuses a new field written from outside the package, at the writer's line", function()
        local Registry = TestEnv.NewRegistry()
        local DemoKit = loadCopy(Registry, 1, true)

        local source = debug.getinfo(1, "S").short_src
        local line
        local ok, message = pcall(function()
            line = debug.getinfo(1, "l").currentline + 1
            DemoKit.Extra = true
        end)

        assert.is_false(ok)
        assert.are.equal(
            source
                .. ":"
                .. line
                .. ': MoltenCodes DemoKit facade is sealed; field "Extra" cannot be added from outside the package',
            message
        )
        assert.is_nil(rawget(DemoKit, "Extra"))
    end)

    it("still lets an upgrading revision mutate the facade through rawset", function()
        local Registry = TestEnv.NewRegistry()
        local DemoKit = loadCopy(Registry, 1, true)

        local upgraded = loadCopy(Registry, 2, true)

        assert.are.equal(DemoKit, upgraded)
        assert.are.equal(2, DemoKit.Run())
        assert.are.equal(2, DemoKit.REVISION)
        assert.has_error(function()
            DemoKit.Extra = true
        end)
    end)

    it("leaves pairs over the facade unchanged", function()
        local Registry = TestEnv.NewRegistry()
        local DemoKit = loadCopy(Registry, 1, true)

        local keys = {}
        for key in pairs(DemoKit) do
            keys[#keys + 1] = key
        end
        table.sort(keys)

        assert.are.same({ "API", "REVISION", "Run" }, keys)
    end)

    it("installs nothing when the option is absent", function()
        local Registry = TestEnv.NewRegistry()
        local DemoKit = loadCopy(Registry, 1)

        DemoKit.Extra = true

        assert.is_nil(getmetatable(DemoKit))
        assert.is_true(DemoKit.Extra)
    end)

    it("names the revision that sealed the facade most recently", function()
        local Registry = TestEnv.NewRegistry()
        local DemoKit = loadCopy(Registry, 1, true)
        Registry:Bootstrap({
            package = "demoKit",
            api = 1,
            revision = 2,
            label = "MoltenCodes DemoKit r2",
            validatePublicSurface = function()
                return true
            end,
            sealFacade = true,
        })

        TestEnv.expectErrorContaining("MoltenCodes DemoKit r2 facade is sealed", function()
            DemoKit.Extra = true
        end)
    end)

    it("is removed by a newer revision that does not ask for it", function()
        local Registry = TestEnv.NewRegistry()
        local DemoKit = loadCopy(Registry, 1, true)

        loadCopy(Registry, 2)

        assert.is_nil(getmetatable(DemoKit))
    end)

    it("refuses to replace a metatable Registry did not install", function()
        local Registry = TestEnv.NewRegistry()
        local DemoKit = loadCopy(Registry, 1)
        setmetatable(DemoKit, {})

        TestEnv.expectErrorContaining(
            "MoltenCodes DemoKit cannot seal a facade that already carries a metatable",
            function()
                loadCopy(Registry, 2, true)
            end
        )
    end)
end)
