local TestEnv = require("CommandKitTestEnv")

-- An epic item link as the client inserts it on shift-click: a colour code
-- around a hyperlink whose text contains spaces.
local ITEM_LINK =
    "|cffa335ee|Hitem:19019::::::::60:::::|h[Thunderfury, Blessed Blade of the Windseeker]|h|r"

describe("CommandKit parsing", function()
    local CommandKit
    before_each(function()
        CommandKit = TestEnv.NewPackage()
    end)
    after_each(TestEnv.Reset)

    it("splits on runs of whitespace", function()
        assert.are.same({ "one", "two", "three" }, CommandKit:Parse("  one \t two\n\nthree  "))
        assert.are.same({}, CommandKit:Parse(""))
        assert.are.same({}, CommandKit:Parse("   "))
    end)

    it("keeps double- and single-quoted text as one token", function()
        assert.are.same(
            { "set", "label", "two words", "it's here" },
            CommandKit:Parse([[set label "two words" "it's here"]])
        )
        assert.are.same({ "a b", "c" }, CommandKit:Parse("'a b' c"))
        assert.are.same({ "", "x" }, CommandKit:Parse([["" x]]))
    end)

    it("unescapes an escaped quote inside quotes", function()
        assert.are.same({ 'say "hi"', "done" }, CommandKit:Parse([["say \"hi\"" done]]))
        assert.are.same({ "it's" }, CommandKit:Parse([['it\'s']]))
        -- Any other backslash is kept: WoW paths use them.
        assert.are.same({ [[Interface\Icons\X]] }, CommandKit:Parse([["Interface\Icons\X"]]))
    end)

    it("keeps a hyperlink with spaces as one token", function()
        local link = "|Hitem:19019|h[Thunderfury, Blessed Blade]|h"
        assert.are.same({ "link", link, "3" }, CommandKit:Parse("link " .. link .. " 3"))
    end)

    it("keeps an item link as the only argument", function()
        assert.are.same({ ITEM_LINK }, CommandKit:Parse(ITEM_LINK))
        assert.are.same({ "give", ITEM_LINK, "2" }, CommandKit:Parse("give " .. ITEM_LINK .. " 2"))
    end)

    it("keeps colour-wrapped text as one token", function()
        local coloured = "|cffff0000Red Text|r"
        assert.are.same({ coloured, "after" }, CommandKit:Parse(coloured .. " after"))
        -- A colour code without |r is ordinary text.
        assert.are.same({ "|cffff0000Red", "Text" }, CommandKit:Parse("|cffff0000Red Text"))
    end)

    it("keeps a texture and an escaped pipe inside their token", function()
        assert.are.same(
            { "|TInterface\\Icons\\My Icon:16|t", "a||b" },
            CommandKit:Parse("|TInterface\\Icons\\My Icon:16|t a||b")
        )
    end)

    it("keeps a hyperlink whose text contains a quote inside a quoted token", function()
        local link = '|Hitem:1|h["Quoted" Name]|h'
        assert.are.same({ "x " .. link }, CommandKit:Parse('"x ' .. link .. '"'))
    end)

    it("refuses an unterminated quote", function()
        local array, reason = CommandKit:Parse([[set "two words]])
        assert.is_nil(array)
        assert.are.equal("unterminated quote", reason)
        assert.are.same({ nil, "unterminated quote" }, { CommandKit:Parse('x "open') })
    end)

    it("reads a single quote without a closing quote before a boundary as an apostrophe", function()
        assert.are.same(
            { "'twas", "the", "night's", "end" },
            CommandKit:Parse("'twas the night's end")
        )
        assert.are.same({ "'open" }, CommandKit:Parse("'open"))
        assert.are.same({ "don't", "stop" }, CommandKit:Parse("don't stop"))
        assert.are.same({ "a b" }, CommandKit:Parse("'a b'"))
    end)

    it("joins adjacent quoted and bare segments into one token", function()
        assert.are.same({ "foobar", "x" }, CommandKit:Parse('"foo"bar x'))
        assert.are.same({ "its" }, CommandKit:Parse("'it''s'"))
        assert.are.same({ "two wordsand 'more'" }, CommandKit:Parse([["two words"'and '"'more'"]]))
        -- A quote inside a bare run stays literal.
        assert.are.same({ 'say"hi"' }, CommandKit:Parse('say"hi"'))
    end)

    it("unescapes a backslash escaped with a backslash", function()
        assert.are.same({ [[C:\]], "next" }, CommandKit:Parse([["C:\\" next]]))
        assert.are.same({ [[a\b]] }, CommandKit:Parse([['a\\b']]))
    end)

    it("does not let an unclosed colour swallow text up to another colour's |r", function()
        assert.are.same(
            { "|cffff0000red", "and", "|cff00ff00green text|r" },
            CommandKit:Parse("|cffff0000red and |cff00ff00green text|r")
        )
    end)

    it("reads a pipe that starts no escape sequence as one ordinary byte", function()
        assert.are.same({ "a|", "b" }, CommandKit:Parse("a| b"))
        assert.are.same({ "a|", "b" }, CommandKit:Parse('"a|" b'))
        assert.are.same({ "x|", "y" }, CommandKit:Parse("'x|' y"))
        assert.are.same({ "|" }, CommandKit:Parse("|"))
    end)

    it("refuses an unterminated hyperlink", function()
        assert.are.same({ nil, "unterminated link" }, { CommandKit:Parse("|Hitem:1 no marker") })
        assert.are.same({ nil, "unterminated link" }, { CommandKit:Parse("|Hitem:1|h[Half open") })
        assert.are.same(
            { nil, "unterminated link" },
            { CommandKit:Parse('"|Hitem:1|h[inside quotes"') }
        )
    end)

    it("fills an array with ParseInto and clears the slots after the count", function()
        local array = { "stale", "stale", "stale", "stale" }
        assert.are.equal(2, CommandKit:ParseInto("a b", array))
        assert.are.same({ "a", "b" }, array)
        assert.are.equal(0, CommandKit:ParseInto("", array))
        assert.are.same({}, array)
    end)

    it("empties the array when ParseInto refuses", function()
        local array = { "stale" }
        local count, reason = CommandKit:ParseInto('ok "open', array)
        assert.is_nil(count)
        assert.are.equal("unterminated quote", reason)
        assert.are.same({}, array)
    end)

    it("returns a new array from every Parse call", function()
        local first = CommandKit:Parse("a")
        local second = CommandKit:Parse("a")
        assert.are_not.equal(first, second)
        assert.are.same(first, second)
    end)

    it("refuses what is not a string", function()
        TestEnv.expectErrorContaining("CommandKit:Parse text must be a string", function()
            CommandKit:Parse(nil)
        end)
        TestEnv.expectErrorContaining("CommandKit:ParseInto array must be a table", function()
            CommandKit:ParseInto("a", nil)
        end)
    end)
end)
