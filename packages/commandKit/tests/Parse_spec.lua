local TestEnv = require("CommandKitTestEnv")

-- Lines and what revision 6's byte-by-byte parser answered for them: tokens,
-- or `nil` and the reason. Revision 7 jumps between the bytes that matter with
-- `string.find` and must answer the same; the lines cover quoted segments,
-- escapes, apostrophes, adjacent segments, colour codes, links and textures,
-- every kind of whitespace and both refusals. A further 200,000 generated
-- lines agreed when the change was made.
local AGREED_WITH_REVISION_6 = {
  { 'say "hello world" end', { { "say", "hello world", "end" } } },
  { "it's fine", { { "it's", "fine" } } },
  { "'single quoted' x", { { "single quoted", "x" } } },
  { '"a\\"b" c', { { 'a"b', "c" } } },
  { '"a\\\\" b', { { "a\\", "b" } } },
  { '"x"y"z"', { { 'xy"z"' } } },
  { "'a''b'", { { "ab" } } },
  {
    "cast |cffa335ee|Hitem:19019::::::::70:::::|h[Thunderfury, Blessed Blade]|h|r now",
    {
      { "cast", "|cffa335ee|Hitem:19019::::::::70:::::|h[Thunderfury, Blessed Blade]|h|r", "now" },
    },
  },
  { '"|Hitem:1|h[a "b"]|h" tail', { { '|Hitem:1|h[a "b"]|h', "tail" } } },
  { "|TInterface\\Icons\\X:0|t icon", { { "|TInterface\\Icons\\X:0|t", "icon" } } },
  { "|cff00ff00green text|r |cffff0000red", { { "|cff00ff00green text|r", "|cffff0000red" } } },
  { "a\tb\nc\rd", { { "a", "b", "c", "d" } } },
  { "  leading and trailing  ", { { "leading", "and", "trailing" } } },
  { "", { {} } },
  { "||pipe", { { "||pipe" } } },
  { "x|", { { "x|" } } },
  { '"unterminated', { nil, "unterminated quote" } },
  { "|Hitem:1|h[unfinished", { nil, "unterminated link" } },
  { "'apostrophe's end'", { { "'apostrophe's", "end'" } } },
  { "'open", { { "'open" } } },
  { "|cffffffff|cff000000x|r y|r", { { "|cffffffff|cff000000x|r", "y|r" } } },
  { "\"a\"'b' c", { { "ab", "c" } } },
  { " |\\", { { "|\\" } } },
  { "item:1']\t[|", { { "item:1']", "[|" } } },
  { '|t\r|h|hx|x a" \\|c', { { "|t", "|h|hx|x", 'a"', "\\|c" } } },
  { "b|T\"\\1.5]   ['b|", { { 'b|T"\\1.5]', "['b|" } } },
  { '  item:1|" 1.5|ra|c|t|c"', { { 'item:1|"', '1.5|ra|c|t|c"' } } },
  { "'|H '\r]aitem:1  ffa335ee  ]\t|r", { nil, "unterminated link" } },
  { 'item:1|t1.5\r"x|T||[|c]|r|ffa335ee', { nil, "unterminated quote" } },
  { "|c\r|c|H'", { nil, "unterminated link" } },
}

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
    assert.are.same({ "'twas", "the", "night's", "end" }, CommandKit:Parse("'twas the night's end"))
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

  it("answers every line as the byte-by-byte parser of revision 6 did", function()
    for _, case in ipairs(AGREED_WITH_REVISION_6) do
      local text, expected = case[1], case[2]
      local tokens, reason = CommandKit:Parse(text)
      assert.are.same(expected, { tokens, reason }, string.format("%q", text))
      local into = { "stale", "slots", "left", "over", "from", "an", "earlier", "call", "x", "y" }
      local count, intoReason = CommandKit:ParseInto(text, into)
      if expected[1] == nil then
        assert.are.same({ nil, expected[2] }, { count, intoReason })
        assert.are.same({}, into)
      else
        assert.are.equal(#expected[1], count)
        assert.are.same(expected[1], into)
      end
    end
  end)
end)
