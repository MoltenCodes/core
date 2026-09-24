local TestEnv = require("SettingsKitTestEnv")

-- Each workload repeats its operation many times, so a single allocation per
-- call would show up as tens of kilobytes. The threshold leaves room for the
-- few bytes the measurement itself can cost.
local ITERATIONS = 2000
local THRESHOLD_KILOBYTES = 1

describe("SettingsKit allocation #allocation", function()
    local db
    before_each(function()
        local SettingsKit, _, _, _, S = TestEnv.NewPackage()
        db = SettingsKit:Open("MyAddonDB", {
            profile = S.table({
                fields = {
                    scale = S.optional(S.number({ min = 0.5, max = 2 }), 1),
                    frame = S.optional(S.table({ fields = { x = S.optional(S.number(), 0) } }), {}),
                    auras = S.optional(
                        S.map({
                            keys = S.number(),
                            values = S.optional(
                                S.table({ fields = { shown = S.optional(S.boolean(), true) } }),
                                {}
                            ),
                            max = 8,
                        }),
                        {}
                    ),
                },
            }),
        })
    end)
    after_each(TestEnv.Reset)

    it("allocates nothing for a default read, top-level or nested", function()
        local profile = db.profile
        local aura = profile.auras[7]
        local sum = 0

        local allocated = TestEnv.AllocatedKilobytes(function()
            for _ = 1, ITERATIONS do
                sum = sum + profile.scale + profile.frame.x
                if aura.shown then
                    sum = sum + 1
                end
            end
        end)
        assert.is_true(
            allocated < THRESHOLD_KILOBYTES,
            "default read allocated " .. allocated .. " KiB"
        )
        assert.are.equal(ITERATIONS * 2, sum)
    end)

    it("allocates nothing for a validated write of an existing key", function()
        local profile = db.profile
        local frame = profile.frame
        profile.scale = 1
        frame.x = 1
        local listened = 0
        db:OnChange("profile", function()
            listened = listened + 1
        end)

        local allocated = TestEnv.AllocatedKilobytes(function()
            for index = 1, ITERATIONS do
                profile.scale = 1 + (index % 2) / 2
                frame.x = index
            end
        end)
        assert.is_true(
            allocated < THRESHOLD_KILOBYTES,
            "validated write allocated " .. allocated .. " KiB"
        )
        assert.are.equal(ITERATIONS * 2, listened)
        assert.are.equal(ITERATIONS, frame.x)
    end)
end)
