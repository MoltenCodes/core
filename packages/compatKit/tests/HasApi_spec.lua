local Env = require("CompatKitTestEnv")

describe("CompatKit hasApi and covers", function()
    after_each(Env.Reset)

    ---Run one shim that records what `hasApi` answers for `names`.
    ---@param CompatKit table
    ---@param names string[]
    ---@return table<string, boolean> answers
    local function probeApis(CompatKit, names)
        local answers = {}
        CompatKit:Shim("probe", 1, function(context)
            for _, name in ipairs(names) do
                answers[name] = context.hasApi(name)
            end
        end)
        CompatKit:Apply()
        return answers
    end

    ---The record of the shim `name`.
    ---@param CompatKit table
    ---@param name string
    ---@return table
    local function recordOf(CompatKit, name)
        for _, row in ipairs(CompatKit:GetShims()) do
            if row.name == name then
                return row
            end
        end
        error("no shim named " .. name, 2)
    end

    it("answers false for everything without ApiKit, even for a present global", function()
        local CompatKit = Env.NewPackageFor("mainline")
        local answers = probeApis(CompatKit, { "C_AddOns.GetAddOnMetadata", "C_Timer.NewTicker" })
        assert.is_false(answers["C_AddOns.GetAddOnMetadata"])
        assert.is_false(answers["C_Timer.NewTicker"])
    end)

    it("answers false with ApiKit loaded but no flavour file installed", function()
        local CompatKit = Env.NewPackageFor("mainline")
        Env.LoadApiKit()
        local answers = probeApis(CompatKit, { "C_AddOns.GetAddOnMetadata" })
        assert.is_false(answers["C_AddOns.GetAddOnMetadata"])
    end)

    it("answers from the installed Retail surface with ApiKit and its flavour file", function()
        local CompatKit = Env.NewPackageFor("mainline")
        local ApiKit = Env.LoadApiKit("flavours.Retail")
        assert.are.equal("retail", ApiKit:GetFlavor())
        local answers = probeApis(CompatKit, {
            "C_AddOns.GetAddOnMetadata", -- documented and present on the host
            "C_Timer.NewTicker", -- documented and present on the host
            "C_AddOns.IsAddOnLoaded", -- documented and present on the host
            "C_TooltipInfo.GetUnit", -- documented, but the host lacks the namespace
            "C_AddOns.NoSuchFunction", -- not documented
            "GetMouseFoci", -- documented global the host lacks
            "print", -- present on the host, not a documented client API
        })
        assert.is_true(answers["C_AddOns.GetAddOnMetadata"])
        assert.is_true(answers["C_Timer.NewTicker"])
        assert.is_true(answers["C_AddOns.IsAddOnLoaded"])
        assert.is_false(answers["C_TooltipInfo.GetUnit"])
        assert.is_false(answers["C_AddOns.NoSuchFunction"])
        assert.is_false(answers["GetMouseFoci"])
        assert.is_false(answers["print"])
    end)

    it("answers false on a client whose flavour the Retail file does not install", function()
        local CompatKit = Env.NewPackageFor("classic")
        Env.LoadApiKit("flavours.Retail")
        local answers = probeApis(CompatKit, { "C_Timer.NewTicker" })
        assert.is_false(answers["C_Timer.NewTicker"])
    end)

    it("answers from the installed Classic Era surface on a Classic client", function()
        local CompatKit = Env.NewPackageFor("classic")
        local ApiKit = Env.LoadApiKit("flavours.ClassicEra")
        assert.are.equal("classic-era", ApiKit:GetFlavor())
        local answers = probeApis(CompatKit, {
            "C_Timer.NewTicker", -- documented on Classic Era and present on the host
            "C_AddOns.GetAddOnMetadata", -- documented, but the classic profile has no C_AddOns
            "GetAddOnMetadata", -- present on the host as a legacy global, not documented
        })
        assert.is_true(answers["C_Timer.NewTicker"])
        assert.is_false(answers["C_AddOns.GetAddOnMetadata"])
        assert.is_false(answers["GetAddOnMetadata"])
    end)

    it("never reads a later path segment as a global of its own", function()
        local CompatKit = Env.NewPackageFor("mainline")
        Env.LoadApiKit("flavours.Retail")
        -- A bound function published under a bare global name must not make
        -- `C_Bogus.NewTicker` look documented.
        -- selene: allow(global_usage)
        rawset(_G, "NewTicker", rawget(_G, "C_Timer").NewTicker)
        local answers = probeApis(CompatKit, { "C_Bogus.NewTicker", "C_Timer.NewTicker" })
        -- selene: allow(global_usage)
        rawset(_G, "NewTicker", nil)
        assert.is_false(answers["C_Bogus.NewTicker"])
        assert.is_true(answers["C_Timer.NewTicker"])
    end)

    it("records the covers ApiKit lacks when ApiKit is loaded", function()
        local CompatKit = Env.NewPackageFor("mainline")
        Env.LoadApiKit("flavours.Retail")
        CompatKit:Shim("tooltips", 1, function() end, {
            covers = { "C_TooltipInfo.GetUnit", "C_AddOns.GetAddOnMetadata", "C_Timer.NewTicker" },
        })
        CompatKit:Apply()
        local record = recordOf(CompatKit, "tooltips")
        assert.are.same({ "C_TooltipInfo.GetUnit" }, record.missing)
        assert.are.same(
            { "C_TooltipInfo.GetUnit", "C_AddOns.GetAddOnMetadata", "C_Timer.NewTicker" },
            record.covers
        )
    end)

    it("records an empty missing list when every cover is installed", function()
        local CompatKit = Env.NewPackageFor("mainline")
        Env.LoadApiKit("flavours.Retail")
        CompatKit:Shim("timers", 1, function() end, { covers = { "C_Timer.NewTicker" } })
        CompatKit:Apply()
        assert.are.same({}, recordOf(CompatKit, "timers").missing)
    end)

    it("resets missing when a newer version is recorded after the shim ran", function()
        local CompatKit = Env.NewPackageFor("mainline")
        Env.LoadApiKit("flavours.Retail")
        CompatKit:Shim("tooltips", 1, function() end, { covers = { "C_TooltipInfo.GetUnit" } })
        CompatKit:Apply()
        assert.are.same({ "C_TooltipInfo.GetUnit" }, recordOf(CompatKit, "tooltips").missing)
        assert.are.same(
            { true, "recorded" },
            { CompatKit:Shim("tooltips", 2, function() end, { covers = { "C_Timer.NewTicker" } }) }
        )
        local record = recordOf(CompatKit, "tooltips")
        assert.is_false(record.missing)
        assert.are.same({ "C_Timer.NewTicker" }, record.covers)
        assert.are.equal(1, record.applied)
    end)

    it("leaves missing false without ApiKit, and for a shim without covers", function()
        local CompatKit = Env.NewPackageFor("mainline")
        CompatKit:Shim("tooltips", 1, function() end, { covers = { "C_TooltipInfo.GetUnit" } })
        CompatKit:Shim("plain", 1, function() end)
        CompatKit:Apply()
        assert.is_false(recordOf(CompatKit, "tooltips").missing)
        assert.is_false(recordOf(CompatKit, "plain").missing)
    end)

    it("does not verify covers of a skipped or filtered shim", function()
        local CompatKit = Env.NewPackageFor("mainline")
        Env.LoadApiKit("flavours.Retail")
        Env.LoadClientKit()
        CompatKit:Shim("skipped", 1, function() end, { covers = { "C_Timer.NewTicker" } })
        CompatKit:SkipShim("skipped")
        CompatKit:Shim("filtered", 1, function() end, {
            covers = { "C_Timer.NewTicker" },
            flavours = { "classic" },
        })
        CompatKit:Apply()
        assert.is_false(recordOf(CompatKit, "skipped").missing)
        assert.is_false(recordOf(CompatKit, "filtered").missing)
    end)

    it("sees a flavour file that loads between two Apply calls", function()
        local CompatKit = Env.NewPackageFor("mainline")
        Env.LoadApiKit()
        local first = probeApis(CompatKit, { "C_Timer.NewTicker" })
        assert.is_false(first["C_Timer.NewTicker"])
        require("flavours.Retail")
        local answer
        CompatKit:Shim("second-probe", 1, function(context)
            answer = context.hasApi("C_Timer.NewTicker")
        end)
        CompatKit:Apply()
        assert.is_true(answer)
    end)
end)
