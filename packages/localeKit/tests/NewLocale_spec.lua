local TestEnv = require("LocaleKitTestEnv")

describe("LocaleKit:NewLocale", function()
    local LocaleKit
    before_each(function()
        LocaleKit = TestEnv.NewPackage("deDE")
    end)
    after_each(TestEnv.Reset)

    it("returns a proxy for the client locale and nil for any other", function()
        assert.is_table(LocaleKit:NewLocale("MyAddon", "deDE"))
        assert.is_nil(LocaleKit:NewLocale("MyAddon", "frFR"))
        assert.is_nil(LocaleKit:NewLocale("MyAddon", "enUS"))
    end)

    it("always returns a proxy for the default locale", function()
        assert.is_table(LocaleKit:NewLocale("MyAddon", "enUS", { isDefault = true }))
        assert.is_nil(LocaleKit:NewLocale("Other", "enUS", { isDefault = false }))
    end)

    it("registers nothing for a locale the client does not need", function()
        assert.is_nil(LocaleKit:NewLocale("MyAddon", "frFR"))
        TestEnv.expectErrorContaining("found no locale registered for MyAddon", function()
            LocaleKit:GetLocale("MyAddon")
        end)
    end)

    it("returns a fresh proxy on every call", function()
        local first = LocaleKit:NewLocale("MyAddon", "deDE")
        local second = LocaleKit:NewLocale("MyAddon", "deDE")
        assert.are_not.equal(first, second)
        first.One = "Eins"
        second.Two = "Zwei"
        local L = LocaleKit:GetLocale("MyAddon")
        assert.are.equal("Eins", L.One)
        assert.are.equal("Zwei", L.Two)
    end)

    it("stores the key itself for true", function()
        local L = LocaleKit:NewLocale("MyAddon", "enUS", { isDefault = true })
        L["Hello"] = true
        assert.are.equal("Hello", LocaleKit:GetLocale("MyAddon").Hello)
    end)

    it("never lets the default overwrite a translation that loaded first", function()
        local translated = LocaleKit:NewLocale("MyAddon", "deDE")
        translated["Hello"] = "Hallo"
        local default = LocaleKit:NewLocale("MyAddon", "enUS", { isDefault = true })
        default["Hello"] = true
        default["Goodbye"] = true
        local L = LocaleKit:GetLocale("MyAddon")
        assert.are.equal("Hallo", L.Hello)
        assert.are.equal("Goodbye", L.Goodbye)
    end)

    it("lets a translation overwrite a default that loaded first", function()
        local default = LocaleKit:NewLocale("MyAddon", "enUS", { isDefault = true })
        default["Hello"] = true
        local translated = LocaleKit:NewLocale("MyAddon", "deDE")
        translated["Hello"] = "Hallo"
        assert.are.equal("Hallo", LocaleKit:GetLocale("MyAddon").Hello)
    end)

    it("lets two default files share keys without clobbering the first", function()
        local first = LocaleKit:NewLocale("MyAddon", "enUS", { isDefault = true })
        first["Shared"] = "first"
        local second = LocaleKit:NewLocale("MyAddon", "enUS", { isDefault = true })
        second["Shared"] = "second"
        assert.are.equal("first", LocaleKit:GetLocale("MyAddon").Shared)
    end)

    it("uses the default proxy when the default locale is the client locale", function()
        TestEnv.SetClientLocale("enUS")
        local default = LocaleKit:NewLocale("Other", "enUS", { isDefault = true })
        default["Key"] = "first"
        local again = LocaleKit:NewLocale("Other", "enUS", { isDefault = true })
        again["Key"] = "second"
        assert.are.equal("first", LocaleKit:GetLocale("Other").Key)
    end)

    it("reads written values through a proxy and nil otherwise, never raising", function()
        local L = LocaleKit:NewLocale("MyAddon", "deDE")
        L["Hello"] = "Hallo"
        assert.are.equal("Hallo", L["Hello"])
        assert.is_nil(L["Unknown"])
        assert.is_nil(L[1])
        assert.is_nil(rawget(L, "Hello"))

        local default = LocaleKit:NewLocale("MyAddon", "enUS", { isDefault = true })
        assert.are.equal("Hallo", default["Hello"])
    end)

    it("keeps two addons apart when their NewLocale calls interleave", function()
        local firstDefault = LocaleKit:NewLocale("First", "enUS", { isDefault = true })
        local secondDefault = LocaleKit:NewLocale("Second", "enUS", { isDefault = true })
        local firstGerman = LocaleKit:NewLocale("First", "deDE")
        firstDefault["Title"] = "First title"
        secondDefault["Title"] = "Second title"
        local secondGerman = LocaleKit:NewLocale("Second", "deDE")
        firstGerman["Title"] = "Erster Titel"
        secondDefault["Only"] = true
        secondGerman["Other"] = "Anderes"

        local first = LocaleKit:GetLocale("First", { missing = "raw" })
        local second = LocaleKit:GetLocale("Second", { missing = "raw" })
        assert.are.equal("Erster Titel", first.Title)
        assert.is_nil(first.Only)
        assert.is_nil(first.Other)
        assert.are.equal("Second title", second.Title)
        assert.are.equal("Only", second.Only)
        assert.are.equal("Anderes", second.Other)
    end)

    it("refuses a second default locale for the same addon", function()
        LocaleKit:NewLocale("MyAddon", "enUS", { isDefault = true })
        TestEnv.expectErrorContaining("MyAddon already has default locale enUS", function()
            LocaleKit:NewLocale("MyAddon", "frFR", { isDefault = true })
        end)
    end)

    it("refuses keys and values a translation file cannot mean", function()
        local L = LocaleKit:NewLocale("MyAddon", "deDE")
        TestEnv.expectErrorContaining("translation key must be a non-empty string", function()
            L[1] = "one"
        end)
        TestEnv.expectErrorContaining("translation key must be a non-empty string", function()
            L[""] = "empty"
        end)
        TestEnv.expectErrorContaining('translation "Key" must be a string or true', function()
            L["Key"] = false
        end)
        TestEnv.expectErrorContaining('translation "Key" must be a string or true', function()
            L["Key"] = nil
        end)
    end)

    it("refuses bad arguments", function()
        TestEnv.expectErrorContaining("addonName must be a non-empty string", function()
            LocaleKit:NewLocale("", "deDE")
        end)
        TestEnv.expectErrorContaining(
            'locale must be a client locale code such as "deDE"',
            function()
                LocaleKit:NewLocale("MyAddon", "dede")
            end
        )
        TestEnv.expectErrorContaining('options contains unknown field "default"', function()
            LocaleKit:NewLocale("MyAddon", "deDE", { default = true })
        end)
        TestEnv.expectErrorContaining("isDefault must be a boolean", function()
            LocaleKit:NewLocale("MyAddon", "deDE", { isDefault = 1 })
        end)
        TestEnv.expectErrorContaining("options must be a table", function()
            LocaleKit:NewLocale("MyAddon", "deDE", true)
        end)
    end)
end)
