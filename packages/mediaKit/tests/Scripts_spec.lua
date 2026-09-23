local TestEnv = require("MediaKitTestEnv")

---Register one pack font per script group on `MediaKit`.
---@param MediaKit table
local function registerPackFonts(MediaKit)
    assert.is_true(
        MediaKit:Register("font", "Pack Latin", "Fonts\\PackLatin.ttf", { scripts = { "latin" } })
    )
    assert.is_true(MediaKit:Register("font", "Pack Wide", "Fonts\\PackWide.ttf", {
        scripts = { "latin", "cyrillic", "greek" },
    }))
    assert.is_true(MediaKit:Register("font", "Pack Hanzi", "Fonts\\PackHanzi.ttf", {
        scripts = { "cjkSimplified", "cjkTraditional" },
    }))
    assert.is_true(
        MediaKit:Register(
            "font",
            "Pack Hangul",
            "Fonts\\PackHangul.ttf",
            { scripts = { "korean" } }
        )
    )
    assert.is_true(MediaKit:Register("font", "Pack Everything", "Fonts\\PackEverything.ttf"))
end

describe("MediaKit font scripts", function()
    after_each(TestEnv.Reset)

    it("offers a Western client its Latin fonts only", function()
        local MediaKit = TestEnv.NewPackage("enUS")
        registerPackFonts(MediaKit)
        assert.are.same({
            "Arial Narrow",
            "Friz Quadrata TT",
            "Morpheus",
            "Pack Everything",
            "Pack Latin",
            "Pack Wide",
            "Skurri",
        }, MediaKit:List("font"))
        assert.is_nil(MediaKit:Fetch("font", "Pack Hanzi"))
        assert.is_false(MediaKit:Has("font", "Pack Hangul"))
        assert.are.equal("Fonts\\PackLatin.ttf", MediaKit:Fetch("font", "Pack Latin"))
    end)

    it("offers a zhCN client its Simplified Chinese fonts only", function()
        local MediaKit = TestEnv.NewPackage("zhCN")
        registerPackFonts(MediaKit)
        assert.are.same({ "Pack Everything", "Pack Hanzi" }, MediaKit:List("font"))
        assert.is_nil(MediaKit:Fetch("font", "Friz Quadrata TT"))
        assert.is_nil(MediaKit:Fetch("font", "Pack Latin"))
        assert.are.equal("Fonts\\PackHanzi.ttf", MediaKit:Fetch("font", "Pack Hanzi"))
    end)

    it("offers a ruRU client its Cyrillic fonts, built-ins included", function()
        local MediaKit = TestEnv.NewPackage("ruRU")
        registerPackFonts(MediaKit)
        assert.are.same({
            "Arial Narrow",
            "Friz Quadrata TT",
            "Morpheus",
            "Pack Everything",
            "Pack Wide",
            "Skurri",
        }, MediaKit:List("font"))
        assert.is_nil(MediaKit:Fetch("font", "Pack Latin"))
    end)

    it("maps the other client locales to their scripts", function()
        local expectations = {
            deDE = "Pack Latin",
            frFR = "Pack Latin",
            esMX = "Pack Latin",
            ptBR = "Pack Latin",
            itIT = "Pack Latin",
            enGB = "Pack Latin",
            zhTW = "Pack Hanzi",
            koKR = "Pack Hangul",
        }
        for locale, fontName in pairs(expectations) do
            local MediaKit = TestEnv.NewPackage(locale)
            registerPackFonts(MediaKit)
            assert.is_true(MediaKit:Has("font", fontName), locale .. " should see " .. fontName)
        end
    end)

    it("treats a client without GetLocale, or with an unknown locale, as Latin", function()
        local MediaKit = TestEnv.NewPackage("xxYY")
        registerPackFonts(MediaKit)
        assert.is_true(MediaKit:Has("font", "Pack Latin"))
        TestEnv.SetClientLocale(nil)
        assert.is_true(MediaKit:Has("font", "Pack Latin"))
        assert.is_false(MediaKit:Has("font", "Pack Hanzi"))
    end)

    it("ignores scripts with anyScript, in Fetch, Has and List", function()
        local MediaKit = TestEnv.NewPackage("zhCN")
        registerPackFonts(MediaKit)
        assert.are.equal(
            "Fonts\\PackLatin.ttf",
            MediaKit:Fetch("font", "Pack Latin", { anyScript = true })
        )
        assert.is_true(MediaKit:Has("font", "Pack Hangul", { anyScript = true }))
        assert.are.equal(9, #MediaKit:List("font", { anyScript = true }))
        assert.are.equal(2, #MediaKit:List("font"))
    end)

    it("never filters other media types by script", function()
        local MediaKit = TestEnv.NewPackage("koKR")
        MediaKit:Register("statusbar", "Pack Bar", "Interface\\Pack\\Bar")
        assert.are.same({ "Blizzard", "Pack Bar", "Solid" }, MediaKit:List("statusbar"))
    end)

    it("refilters the cached font list when the client's script changes", function()
        local MediaKit = TestEnv.NewPackage("enUS")
        registerPackFonts(MediaKit)
        local western = MediaKit:List("font")
        assert.are.equal(western, MediaKit:List("font"))
        TestEnv.SetClientLocale("koKR")
        assert.are.same({ "Pack Everything", "Pack Hangul" }, MediaKit:List("font"))
    end)

    it("lets a font declare scripts no client writes today", function()
        local MediaKit = TestEnv.NewPackage("enUS")
        assert.is_true(
            MediaKit:Register("font", "Kana", "Fonts\\Kana.ttf", { scripts = { "japanese" } })
        )
        assert.is_false(MediaKit:Has("font", "Kana"))
        assert.is_true(MediaKit:Has("font", "Kana", { anyScript = true }))
    end)
end)
