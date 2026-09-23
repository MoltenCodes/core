local TestEnv = require("MediaKitTestEnv")

describe("MediaKit:Defaults", function()
    local MediaKit
    before_each(function()
        MediaKit = TestEnv.NewPackage("enUS")
    end)
    after_each(TestEnv.Reset)

    it("falls back to the documented built-in for every type", function()
        local defaults = MediaKit:Defaults("MyAddon")
        assert.are.equal("Blizzard Dialog Background", defaults:Get("background"))
        assert.are.equal("Blizzard Tooltip", defaults:Get("border"))
        assert.are.equal("Friz Quadrata TT", defaults:Get("font"))
        assert.are.equal("Question Mark", defaults:Get("icon"))
        assert.are.equal("None", defaults:Get("sound"))
        assert.are.equal("Blizzard", defaults:Get("statusbar"))
        assert.are.equal("Solid", defaults:Get("texture"))
        for _, mediaType in ipairs({
            "background",
            "border",
            "font",
            "icon",
            "sound",
            "statusbar",
            "texture",
        }) do
            assert.is_true(MediaKit:Has(mediaType, defaults:Get(mediaType)), mediaType)
        end
    end)

    it("returns the same object for a consumer and separate ones per consumer", function()
        local first = MediaKit:Defaults("First")
        assert.are.equal(first, MediaKit:Defaults("First"))
        local second = MediaKit:Defaults("Second")
        assert.are_not.equal(first, second)

        MediaKit:Register("statusbar", "Smooth", "Interface\\Pack\\Smooth")
        first:Set("statusbar", "Smooth")
        assert.are.equal("Smooth", first:Get("statusbar"))
        assert.are.equal("Blizzard", second:Get("statusbar"))
    end)

    it("keeps a choice registered later and answers the fallback until then", function()
        local defaults = MediaKit:Defaults("MyAddon")
        defaults:Set("statusbar", "From A Pack")
        assert.are.equal("Blizzard", defaults:Get("statusbar"))
        MediaKit:Register("statusbar", "From A Pack", "Interface\\Pack\\Bar")
        assert.are.equal("From A Pack", defaults:Get("statusbar"))
    end)

    it("answers the fallback for a font the client cannot render", function()
        MediaKit:Register("font", "Hanzi", "Fonts\\Hanzi.ttf", { scripts = { "cjkSimplified" } })
        local defaults = MediaKit:Defaults("MyAddon")
        defaults:Set("font", "Hanzi")
        assert.are.equal("Friz Quadrata TT", defaults:Get("font"))
    end)

    it("clears a choice with nil", function()
        MediaKit:Register("sound", "Ding", 554003)
        local defaults = MediaKit:Defaults("MyAddon")
        defaults:Set("sound", "Ding")
        assert.are.equal("Ding", defaults:Get("sound"))
        defaults:Set("sound", nil)
        assert.are.equal("None", defaults:Get("sound"))
    end)

    it("hides its metatable", function()
        assert.are.equal("MediaKit.Defaults", getmetatable(MediaKit:Defaults("MyAddon")))
    end)

    it("refuses bad arguments at the caller", function()
        local defaults = MediaKit:Defaults("MyAddon")
        TestEnv.expectErrorContaining(
            "MediaKit:Defaults consumerName must be a non-empty string",
            function()
                MediaKit:Defaults("")
            end
        )
        TestEnv.expectErrorContaining("MediaKit.Defaults:Set type must be one of", function()
            defaults:Set("bar", "Name")
        end)
        TestEnv.expectErrorContaining(
            "MediaKit.Defaults:Set name must be a non-empty string",
            function()
                defaults:Set("statusbar", 5)
            end
        )
        TestEnv.expectErrorContaining(
            "MediaKit.Defaults:Get must be called on a defaults object; use defaults:Get(...)",
            function()
                defaults.Get("statusbar")
            end
        )
    end)

    it("refuses more than 1024 consumers", function()
        for index = 1, 1024 do
            MediaKit:Defaults("Consumer " .. index)
        end
        assert.is_table(MediaKit:Defaults("Consumer 1"))
        TestEnv.expectErrorContaining(
            "MediaKit:Defaults refuses more than 1024 consumers",
            function()
                MediaKit:Defaults("Consumer 1025")
            end
        )
    end)
end)
