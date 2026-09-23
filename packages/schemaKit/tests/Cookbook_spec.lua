local TestEnv = require("SchemaKitTestEnv")

-- The three schemas of the cookbook in docs/API.md, run as written, so the
-- documented examples cannot drift from the implementation.
describe("SchemaKit cookbook", function()
    local S
    before_each(function()
        S = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    it("fills a settings schema with defaults and wildcard entries", function()
        local Aura = S.table({
            fields = {
                shown = S.optional(S.boolean(), true),
                color = S.optional(
                    S.array({ of = S.number({ min = 0, max = 1 }), min = 3, max = 4 }),
                    { 1, 1, 1 }
                ),
                sound = S.optional(S.string({ max = 64 })),
            },
        })
        local Settings = S:Seal(S.table({
            fields = {
                version = S.optional(S.number({ integer = true, min = 1 }), 1),
                scale = S.optional(S.number({ min = 0.5, max = 2 }), 1),
                anchor = S.optional(S.string({ oneOf = { "TOP", "CENTER", "BOTTOM" } }), "CENTER"),
                auras = S.optional(
                    S.map({
                        keys = S.number({ integer = true }),
                        values = S.optional(Aura, {}),
                        max = 256,
                    }),
                    {}
                ),
            },
        }))

        local ok, settings = Settings:Apply({ scale = 1.5, auras = { [133] = { shown = false } } })
        assert.is_true(ok)
        assert.are.same({
            version = 1,
            scale = 1.5,
            anchor = "CENTER",
            auras = { [133] = { shown = false, color = { 1, 1, 1 } } },
        }, settings)

        local bad, failure = Settings:Apply({ scale = 3 })
        assert.is_false(bad)
        assert.are.same({ "scale", "max" }, { failure.path, failure.rule })

        local okDefaults, defaults = Settings:Apply({})
        assert.is_true(okDefaults)
        assert.are.same({ version = 1, scale = 1, anchor = "CENTER", auras = {} }, defaults)
        assert.are.same({}, Settings:Describe().fields.auras.values.default)
    end)

    it("drives an options screen from Describe", function()
        local Options = S:Seal(S.table({
            fields = {
                fontSize = S.optional(S.number({ integer = true, min = 8, max = 32 }), 12),
                outline = S.optional(S.enum({ "NONE", "OUTLINE", "THICKOUTLINE" }), "NONE"),
                label = S.optional(S.string({ max = 24, pattern = "^[%w ]*$" }), ""),
            },
        }))
        local description = Options:Describe()
        assert.are.same({ "fontSize", "label", "outline" }, description.fieldNames)
        local fontSize = description.fields.fontSize
        assert.are.same({ "number", 8, 32, true, 12 }, {
            fontSize.kind,
            fontSize.min,
            fontSize.max,
            fontSize.integer,
            fontSize.default,
        })
        assert.are.same({ "NONE", "OUTLINE", "THICKOUTLINE" }, description.fields.outline.values)

        local FontSize = S:Seal(S.number({ integer = true, min = 8, max = 32 }))
        local ok, failure = FontSize:Check(tonumber("40"))
        assert.is_false(ok)
        assert.are.equal("integer <= 32", failure.expected)
    end)

    it("checks a received message payload", function()
        local Payload = S:Seal(S.table({
            fields = {
                kind = S.enum({ "hello", "cooldowns" }),
                version = S.number({ integer = true, min = 1, max = 1000 }),
                sender = S.string({ min = 2, max = 64 }),
                cooldowns = S.optional(S.map({
                    keys = S.number({ integer = true, min = 1 }),
                    values = S.number({ min = 0, max = 86400 }),
                    max = 64,
                })),
            },
        }))

        assert.is_true(Payload:Check({
            kind = "cooldowns",
            version = 3,
            sender = "Jaina",
            cooldowns = { [642] = 30 },
        }))
        local ok, failure =
            Payload:Check({ kind = "hello", version = 3, sender = "Jaina", injected = "x" })
        assert.is_false(ok)
        assert.are.same({ "injected", "unknown" }, { failure.path, failure.rule })
    end)
end)
