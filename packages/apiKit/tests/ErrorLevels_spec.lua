local TestEnv = require("ApiKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src

---Return the line number of the statement that called this helper.
---@return integer line
local function currentLine()
    return debug.getinfo(2, "l").currentline
end

---Assert that `action` failed with `message` reported at `expectedLine` of this
---spec file. A wrong `error` level shows up either as a different line number
---or as a message with no `file:line` prefix at all.
---@param expectedLine integer
---@param message string
---@param ok boolean
---@param value any
local function assertReportedAt(expectedLine, message, ok, value)
    assert.is_false(ok)
    assert.are.equal(SOURCE .. ":" .. expectedLine .. ": " .. message, value)
end

describe("ApiKit error levels", function()
    after_each(TestEnv.Reset)

    it("points an unknown flavour at the caller", function()
        local ApiKit = TestEnv.NewPackageFor("retail")
        local line
        local ok, value = pcall(function()
            line = currentLine() + 1
            ApiKit:RegisterFlavor("wrath", function() end)
        end)
        assertReportedAt(
            line,
            "ApiKit:RegisterFlavor flavor must be one of retail, classic-era, classic-mop, ptr, beta",
            ok,
            value
        )
    end)

    it("points a bad installer at the caller", function()
        local ApiKit = TestEnv.NewPackageFor("retail")
        local line
        local ok, value = pcall(function()
            line = currentLine() + 1
            ApiKit:RegisterFlavor("retail", "nope")
        end)
        assertReportedAt(line, "ApiKit:RegisterFlavor install must be a function", ok, value)
    end)

    it("points a bad info table at the caller", function()
        local ApiKit = TestEnv.NewPackageFor("retail")
        local line
        local ok, value = pcall(function()
            line = currentLine() + 1
            ApiKit:RegisterFlavor("retail", function() end, { build = "69933" })
        end)
        assertReportedAt(
            line,
            "ApiKit:RegisterFlavor info.build must be an integer when given",
            ok,
            value
        )
    end)

    it("points a bad GetMetadataBuild flavour at the caller", function()
        local ApiKit = TestEnv.NewPackageFor("retail")
        local line
        local ok, value = pcall(function()
            line = currentLine() + 1
            ApiKit:GetMetadataBuild(42)
        end)
        assertReportedAt(
            line,
            "ApiKit:GetMetadataBuild flavor must be one of retail, classic-era, classic-mop, ptr, beta",
            ok,
            value
        )
    end)

    it("points a non-table info at the caller", function()
        local ApiKit = TestEnv.NewPackageFor("retail")
        local line
        local ok, value = pcall(function()
            line = currentLine() + 1
            ApiKit:RegisterFlavor("retail", function() end, "info")
        end)
        assertReportedAt(line, "ApiKit:RegisterFlavor info must be a table when given", ok, value)
    end)

    it("points a bad info version at the caller", function()
        local ApiKit = TestEnv.NewPackageFor("retail")
        local line
        local ok, value = pcall(function()
            line = currentLine() + 1
            ApiKit:RegisterFlavor("retail", function() end, { version = 12 })
        end)
        assertReportedAt(
            line,
            "ApiKit:RegisterFlavor info.version must be a string when given",
            ok,
            value
        )
    end)

    it("points every wrong receiver at the caller", function()
        local ApiKit = TestEnv.NewPackageFor("retail")
        local cases = {
            {
                "GetGlobalStatus",
                function()
                    ApiKit.GetGlobalStatus({})
                end,
            },
            {
                "RegisterFlavor",
                function()
                    ApiKit.RegisterFlavor({}, "retail", function() end)
                end,
            },
            {
                "GetMetadataBuild",
                function()
                    ApiKit.GetMetadataBuild({}, "retail")
                end,
            },
        }
        for _, case in ipairs(cases) do
            local ok, value = pcall(case[2])
            assert.is_false(ok)
            assert.matches(
                SOURCE .. ":%d+: ApiKit:" .. case[1] .. " must be called on the ApiKit facade",
                value
            )
        end
    end)

    it("points a wrong receiver at the caller", function()
        local ApiKit = TestEnv.NewPackageFor("retail")
        local line
        local ok, value = pcall(function()
            line = currentLine() + 1
            ApiKit.GetFlavor({})
        end)
        assertReportedAt(line, "ApiKit:GetFlavor must be called on the ApiKit facade", ok, value)
    end)
end)
