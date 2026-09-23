local TestEnv = require("MediaKitTestEnv")

describe("MediaKit and LibSharedMedia", function()
    local MediaKit
    before_each(function()
        MediaKit = TestEnv.NewPackage("enUS")
    end)
    after_each(TestEnv.Reset)

    describe("without LibStub or LibSharedMedia", function()
        it("reports absent from both directions", function()
            assert.are.same({ false, "absent" }, { MediaKit:AdoptLibSharedMedia() })
            assert.are.same({ false, "absent" }, { MediaKit:MirrorToLibSharedMedia() })
        end)

        it("reports absent when LibStub holds no LibSharedMedia", function()
            TestEnv.InstallLibStub()
            assert.are.same({ false, "absent" }, { MediaKit:AdoptLibSharedMedia() })
            assert.are.same({ false, "absent" }, { MediaKit:MirrorToLibSharedMedia() })
        end)

        it("keeps working as a plain registry afterwards", function()
            MediaKit:AdoptLibSharedMedia()
            assert.is_true(MediaKit:Register("statusbar", "Pack Bar", "Interface\\Pack\\Bar"))
            assert.are.equal("Interface\\Pack\\Bar", MediaKit:Fetch("statusbar", "Pack Bar"))
        end)
    end)

    describe("adopting", function()
        it("adopts every entry of the five shared types read-only", function()
            TestEnv.InstallLibSharedMedia({
                media = {
                    statusbar = { ["Pack Bar"] = "Interface\\Pack\\Bar" },
                    sound = { ["Pack Sound"] = 569593 },
                    font = { ["Pack Font"] = "Fonts\\Pack.ttf" },
                    border = { ["Pack Border"] = "Interface\\Pack\\Border" },
                    background = { ["Pack Background"] = "Interface\\Pack\\Background" },
                },
            })
            local found, added = MediaKit:AdoptLibSharedMedia()
            assert.is_true(found)
            assert.are.equal(5, added)
            assert.are.equal("Interface\\Pack\\Bar", MediaKit:Fetch("statusbar", "Pack Bar"))
            assert.are.equal(569593, MediaKit:Fetch("sound", "Pack Sound"))
            assert.are.same({ "Blizzard", "Pack Bar", "Solid" }, MediaKit:List("statusbar"))
            -- LibSharedMedia already filtered fonts by locale, so an adopted
            -- font is offered to this client.
            assert.are.equal("Fonts\\Pack.ttf", MediaKit:Fetch("font", "Pack Font"))
        end)

        it("fires OnRegistered for adopted entries in sorted order", function()
            TestEnv.InstallLibSharedMedia({
                media = { statusbar = { Zeta = "z", Alpha = "a", Mid = "m" } },
            })
            local names = {}
            MediaKit:OnRegistered("statusbar", function(_, name)
                names[#names + 1] = name
            end)
            MediaKit:AdoptLibSharedMedia()
            assert.are.same({ "Alpha", "Mid", "Zeta" }, names)
        end)

        it(
            "refuses to re-register an adopted name with other data, and accepts the same data",
            function()
                TestEnv.InstallLibSharedMedia({
                    media = { statusbar = { ["Pack Bar"] = "Interface\\Pack\\Bar" } },
                })
                MediaKit:AdoptLibSharedMedia()
                assert.are.same(
                    { nil, "taken" },
                    { MediaKit:Register("statusbar", "Pack Bar", "Interface\\Mine\\Bar") }
                )
                assert.is_true(MediaKit:Register("statusbar", "Pack Bar", "Interface\\Pack\\Bar"))
                assert.are.equal("Interface\\Pack\\Bar", MediaKit:Fetch("statusbar", "Pack Bar"))
            end
        )

        it("keeps its own entry when LibSharedMedia holds the same name with other data", function()
            MediaKit:Register("statusbar", "Clash", "Interface\\Mine\\Clash")
            TestEnv.InstallLibSharedMedia({
                media = { statusbar = { Clash = "Interface\\Pack\\Clash" } },
            })
            local _, added = MediaKit:AdoptLibSharedMedia()
            assert.are.equal(0, added)
            assert.are.equal("Interface\\Mine\\Clash", MediaKit:Fetch("statusbar", "Clash"))
        end)

        it("skips invalid LibSharedMedia entries", function()
            TestEnv.InstallLibSharedMedia({
                media = {
                    statusbar = { [""] = "x", Empty = "", Zero = 0, Good = "Interface\\Pack\\Good" },
                },
            })
            local _, added = MediaKit:AdoptLibSharedMedia()
            assert.are.equal(1, added)
            assert.are.same({ "Blizzard", "Good", "Solid" }, MediaKit:List("statusbar"))
        end)

        it("follows packs registered later through the callback", function()
            local library = TestEnv.InstallLibSharedMedia()
            MediaKit:AdoptLibSharedMedia()
            local list = MediaKit:List("sound")

            library:Register("sound", "Later Sound", 567458)
            assert.are.equal(567458, MediaKit:Fetch("sound", "Later Sound"))
            assert.are_not.equal(list, MediaKit:List("sound"))
            assert.are.same({ "Later Sound", "None" }, MediaKit:List("sound"))

            -- A media type MediaKit does not share is ignored.
            library:Register("music", "Tune", "Interface\\Pack\\Tune.mp3")
            TestEnv.expectErrorContaining("type must be one of", function()
                MediaKit:Fetch("music", "Tune")
            end)
        end)

        it("is idempotent and subscribes once", function()
            local library = TestEnv.InstallLibSharedMedia({
                media = { border = { Frame = "Interface\\Pack\\Frame" } },
            })
            assert.are.same({ true, 1 }, { MediaKit:AdoptLibSharedMedia() })
            assert.are.same({ true, 0 }, { MediaKit:AdoptLibSharedMedia() })
            assert.are.equal(1, library.CallbackCount())
        end)

        it("adopts once per call from a LibSharedMedia without CallbackHandler", function()
            local library = TestEnv.InstallLibSharedMedia({ withoutCallbacks = true })
            MediaKit:AdoptLibSharedMedia()
            library:Register("border", "Later Border", "Interface\\Pack\\Later")
            assert.is_nil(MediaKit:Fetch("border", "Later Border"))
            assert.are.same({ true, 1 }, { MediaKit:AdoptLibSharedMedia() })
            assert.are.equal("Interface\\Pack\\Later", MediaKit:Fetch("border", "Later Border"))
        end)
    end)

    describe("mirroring", function()
        it("registers our entries into LibSharedMedia, skipping names it has", function()
            local library = TestEnv.InstallLibSharedMedia({
                media = { statusbar = { Blizzard = [[Interface\TargetingFrame\UI-StatusBar]] } },
            })
            MediaKit:Register("statusbar", "Pack Bar", "Interface\\Pack\\Bar")
            MediaKit:Register("sound", "Pack Sound", 569593)
            MediaKit:Register("icon", "Pack Icon", 134400)

            local found, mirrored = MediaKit:MirrorToLibSharedMedia()
            assert.is_true(found)
            assert.are.equal("Interface\\Pack\\Bar", library:Fetch("statusbar", "Pack Bar"))
            assert.are.equal(569593, library:Fetch("sound", "Pack Sound"))
            -- Built-ins LibSharedMedia lacked are mirrored too; ones it has are not.
            assert.are.equal([[Interface\Buttons\WHITE8X8]], library:Fetch("statusbar", "Solid"))
            assert.are.equal(library.registerCalls, mirrored)
            -- Icons and textures have no LibSharedMedia type.
            assert.is_nil(library:HashTable("icon"))
        end)

        it("mirrors later registrations and stays idempotent", function()
            local library = TestEnv.InstallLibSharedMedia()
            MediaKit:MirrorToLibSharedMedia()
            local calls = library.registerCalls
            assert.are.same({ true, 0 }, { MediaKit:MirrorToLibSharedMedia() })
            assert.are.equal(calls, library.registerCalls)

            MediaKit:Register("background", "Later Background", "Interface\\Pack\\Later")
            assert.are.equal(
                "Interface\\Pack\\Later",
                library:Fetch("background", "Later Background")
            )
        end)

        it("hands LibSharedMedia a langmask built from the font's scripts", function()
            local library = TestEnv.InstallLibSharedMedia()
            MediaKit:Register("font", "Latin", "Fonts\\Latin.ttf", { scripts = { "latin" } })
            MediaKit:Register(
                "font",
                "Wide",
                "Fonts\\Wide.ttf",
                { scripts = { "latin", "cyrillic", "greek" } }
            )
            MediaKit:Register("font", "Every", "Fonts\\Every.ttf", {
                scripts = { "latin", "cyrillic", "cjkSimplified", "cjkTraditional", "korean" },
            })
            MediaKit:Register("font", "Undeclared", "Fonts\\Undeclared.ttf")
            MediaKit:Register("font", "Kana", "Fonts\\Kana.ttf", { scripts = { "japanese" } })
            MediaKit:MirrorToLibSharedMedia()
            assert.are.equal(128, library.langmasks.font.Latin)
            assert.are.equal(130, library.langmasks.font.Wide)
            assert.are.equal(143, library.langmasks.font.Every)
            -- A font that declared no scripts is Latin only, so western only.
            assert.are.equal(128, library.langmasks.font.Undeclared)
            assert.are.equal(0, library.langmasks.font.Kana)
            assert.are.equal(128, library.langmasks.font["Friz Quadrata TT"])
            assert.is_nil(library.langmasks.statusbar.Blizzard)
        end)
    end)

    describe("both directions", function()
        it("does not mirror an adopted entry back", function()
            local library =
                TestEnv.InstallLibSharedMedia({ media = { statusbar = { ["Pack Bar"] = "p" } } })
            MediaKit:AdoptLibSharedMedia()
            MediaKit:MirrorToLibSharedMedia()
            local calls = library.registerCalls

            -- A pack registering later is adopted and not written back.
            library:Register("statusbar", "Later Bar", "l")
            assert.are.equal(calls + 1, library.registerCalls)
            assert.are.equal("l", MediaKit:Fetch("statusbar", "Later Bar"))
        end)

        it("does not take a mirrored entry back as a duplicate", function()
            local library = TestEnv.InstallLibSharedMedia()
            MediaKit:AdoptLibSharedMedia()
            MediaKit:MirrorToLibSharedMedia()

            local fired = 0
            MediaKit:OnRegistered("statusbar", function()
                fired = fired + 1
            end)
            local calls = library.registerCalls
            assert.is_true(MediaKit:Register("statusbar", "Mine", "Interface\\Mine\\Bar"))
            assert.are.equal(calls + 1, library.registerCalls)
            assert.are.equal(1, fired)
            assert.are.equal("Interface\\Mine\\Bar", library:Fetch("statusbar", "Mine"))

            local count = 0
            for _, name in ipairs(MediaKit:List("statusbar")) do
                if name == "Mine" then
                    count = count + 1
                end
            end
            assert.are.equal(1, count)
        end)

        it("does not loop on a restricted font LibSharedMedia echoes back", function()
            local library = TestEnv.InstallLibSharedMedia()
            MediaKit:AdoptLibSharedMedia()
            MediaKit:MirrorToLibSharedMedia()
            assert.is_true(
                MediaKit:Register("font", "Latin", "Fonts\\Latin.ttf", { scripts = { "latin" } })
            )
            assert.are.equal("Fonts\\Latin.ttf", library:Fetch("font", "Latin"))
            assert.is_true(
                MediaKit:Register("font", "Latin", "Fonts\\Latin.ttf", { scripts = { "latin" } })
            )
        end)
    end)
end)
