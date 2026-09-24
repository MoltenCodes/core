local TestEnv = require("MediaKitTestEnv")

describe("MediaKit built-in media", function()
  after_each(TestEnv.Reset)

  it("registers the client's own media at load", function()
    local MediaKit = TestEnv.NewPackage("enUS")
    local expected = {
      background = {
        ["Blizzard Dialog Background"] = [[Interface\DialogFrame\UI-DialogBox-Background]],
        ["Blizzard Tooltip"] = [[Interface\Tooltips\UI-Tooltip-Background]],
        Solid = [[Interface\Buttons\WHITE8X8]],
      },
      border = {
        ["Blizzard Dialog"] = [[Interface\DialogFrame\UI-DialogBox-Border]],
        ["Blizzard Tooltip"] = [[Interface\Tooltips\UI-Tooltip-Border]],
        None = [[Interface\None]],
      },
      font = {
        ["Arial Narrow"] = [[Fonts\ARIALN.TTF]],
        ["Friz Quadrata TT"] = [[Fonts\FRIZQT__.TTF]],
        Morpheus = [[Fonts\MORPHEUS.TTF]],
        Skurri = [[Fonts\SKURRI.TTF]],
      },
      icon = { ["Question Mark"] = [[Interface\Icons\INV_Misc_QuestionMark]] },
      sound = { None = [[Interface\Quiet.ogg]] },
      statusbar = {
        Blizzard = [[Interface\TargetingFrame\UI-StatusBar]],
        Solid = [[Interface\Buttons\WHITE8X8]],
      },
      texture = { Solid = [[Interface\Buttons\WHITE8X8]] },
    }
    for mediaType, entries in pairs(expected) do
      for name, data in pairs(entries) do
        assert.are.equal(data, MediaKit:Fetch(mediaType, name), mediaType .. " " .. name)
      end
    end
  end)

  it("uses the Cyrillic font files on a ruRU client", function()
    local MediaKit = TestEnv.NewPackage("ruRU")
    assert.are.equal([[Fonts\FRIZQT___CYR.TTF]], MediaKit:Fetch("font", "Friz Quadrata TT"))
    assert.are.equal([[Fonts\MORPHEUS_CYR.TTF]], MediaKit:Fetch("font", "Morpheus"))
    assert.are.equal([[Fonts\SKURRI_CYR.TTF]], MediaKit:Fetch("font", "Skurri"))
    assert.are.equal([[Fonts\ARIALN.TTF]], MediaKit:Fetch("font", "Arial Narrow"))
  end)

  it("keeps the Western font files out of a CJK client's list", function()
    local MediaKit = TestEnv.NewPackage("zhTW")
    assert.are.same({}, MediaKit:List("font"))
    assert.are.equal(
      [[Fonts\FRIZQT__.TTF]],
      MediaKit:Fetch("font", "Friz Quadrata TT", { anyScript = true })
    )
  end)
end)
