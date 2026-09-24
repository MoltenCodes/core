local TestEnv = require("SchemaKitTestEnv")

describe("SchemaKit and secret values", function()
    local S, secret, probeCalls
    before_each(function()
        S = TestEnv.NewPackage()
        secret = TestEnv.NewSecret()
        -- Installed after SchemaKit loaded: the probe is looked up per check.
        probeCalls = TestEnv.InstallSecretProbe({ [secret] = true })
    end)
    after_each(TestEnv.Reset)

    it("refuses a secret with rule secret for every kind, before touching it", function()
        local customCalls = 0
        local nodes = {
            S.string({ min = 1, pattern = "a", oneOf = { "a" } }),
            S.number({ min = 0, integer = true }),
            S.boolean(),
            S.enum({ "a" }),
            S.table({ fields = {} }),
            S.array({ of = S.any() }),
            S.map({ keys = S.any(), values = S.any(), max = 1 }),
            S.optional(S.number()),
            S.oneOf({ S.string(), S.number() }),
            S.any(),
            S.custom(function()
                customCalls = customCalls + 1
                return true
            end, "anything"),
        }
        for index = 1, #nodes do
            local ok, failure = S:Seal(nodes[index]):Check(secret)
            assert.is_false(ok)
            assert.are.equal("secret", failure.rule)
            assert.are.equal("secret value", failure.found)
            assert.are.equal("", failure.path)
        end
        assert.are.equal(0, customCalls)
        assert.is_true(probeCalls() >= #nodes)
    end)

    it("refuses a secret nested in a field, an element and a map value", function()
        local schema = S:Seal(S.table({
            fields = {
                name = S.optional(S.string()),
                list = S.optional(S.array({ of = S.any() })),
                byName = S.optional(S.map({ keys = S.string(), values = S.any(), max = 4 })),
            },
        }))

        local _, field = schema:Check({ name = secret })
        assert.are.same({ "name", "secret" }, { field.path, field.rule })
        local _, element = schema:Check({ list = { 1, secret } })
        assert.are.same({ "list[2]", "secret" }, { element.path, element.rule })
        local _, entry = schema:Check({ byName = { player = secret } })
        assert.are.same({ "byName.player", "secret" }, { entry.path, entry.rule })
    end)

    it("never formats a secret into an Assert message", function()
        local schema = S:Seal(S.table({ fields = { name = S.string() } }))
        local ok, message = pcall(schema.Assert, schema, { name = secret }, "unit")
        assert.is_false(ok)
        assert.is_not_nil(message:find("unit.name: expected string, found secret value", 1, true))
    end)

    it("refuses a secret through Apply without copying into it", function()
        local schema = S:Seal(S.table({ fields = { box = S.table({ fields = {} }) } }))
        local ok, failure = schema:Apply({ box = secret })
        assert.is_false(ok)
        assert.are.equal("secret", failure.rule)
    end)

    it("refuses a secret limit value at the caller before comparing it", function()
        -- A number stands in for a secret number: without the probe asked
        -- first, it would pass as a valid limit.
        TestEnv.InstallSecretProbe({ [48] = true })
        local source = debug.getinfo(1, "S").short_src
        local cases = {
            {
                limits = { defaultArrayMax = 48 },
                message = "SchemaKit:SetLimits limits.defaultArrayMax must be a positive integer or SchemaKit.UNBOUNDED",
            },
            {
                limits = { maxDepth = 48 },
                message = "SchemaKit:SetLimits limits.maxDepth must be an integer from 1 to 64",
            },
        }
        for index = 1, #cases do
            local line
            local ok, value = pcall(function()
                line = debug.getinfo(1, "l").currentline + 1
                S:SetLimits(cases[index].limits)
            end)
            assert.is_false(ok)
            assert.are.equal(source .. ":" .. line .. ": " .. cases[index].message, value)
        end
        assert.are.equal(16, S:GetLimits().maxDepth)
        assert.are.equal(1024, S:GetLimits().defaultArrayMax)
    end)

    it("still accepts a plain limit and UNBOUNDED while the probe exists", function()
        S:SetLimits({ maxDepth = 20, defaultArrayMax = S.UNBOUNDED })
        assert.are.equal(20, S:GetLimits().maxDepth)
        assert.are.equal(S.UNBOUNDED, S:GetLimits().defaultArrayMax)
    end)

    it("accepts ordinary values while the probe exists", function()
        local schema = S:Seal(S.table({ fields = { name = S.string() } }))
        assert.is_true(schema:Check({ name = "Thrall" }))
    end)

    it("checks normally once the probe is removed", function()
        TestEnv.Reset()
        S = TestEnv.NewPackage()
        -- The spec checks that the fixture removed the host global it installed.
        -- selene: allow(global_usage)
        assert.is_nil(rawget(_G, "issecretvalue"))
        assert.is_true(S:Seal(S.any()):Check({}))
    end)
end)
