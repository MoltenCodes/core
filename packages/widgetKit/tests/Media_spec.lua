local TestEnv = require("WidgetKitHostTestEnv")

describe("WidgetKit media pickers with MediaKit", function()
  local WidgetKit, modules
  before_each(function()
    WidgetKit, modules = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("lists MediaKit's names for a type, in MediaKit's order", function()
    local MediaKit = modules.MediaKit
    MediaKit:Register("statusbar", "Spec Smooth", [[Interface\AddOns\Spec\Smooth.tga]])
    local picker = WidgetKit:CreateMediaPicker("statusbar")
    local names = MediaKit:List("statusbar")
    assert.are.equal(#names, picker:GetNumEntries())
    for index = 1, #names do
      assert.are.equal(names[index], picker._keys[index])
      assert.are.equal(names[index], picker._labels[index])
    end
    picker:SetValue("Spec Smooth")
    assert.are.equal("Spec Smooth", picker.button:GetText())
  end)

  it("refuses a MediaKit list longer than a Dropdown holds without borrowing one", function()
    local MediaKit = modules.MediaKit
    for index = 1, 4 do
      MediaKit:Register("statusbar", "Spec Bar " .. index, "Interface\\Spec\\Bar" .. index)
    end
    WidgetKit:SetLimits({ maxDropdownEntries = 4 })
    local before = WidgetKit:GetStatistics().byType.Dropdown.active
    TestEnv.expectErrorContaining(
      "WidgetKit:CreateMediaPicker MediaKit lists more statusbar names than a Dropdown holds"
        .. " (4; WidgetKit:SetLimits maxDropdownEntries)",
      function()
        WidgetKit:CreateMediaPicker("statusbar")
      end
    )
    assert.are.equal(before, WidgetKit:GetStatistics().byType.Dropdown.active)

    WidgetKit:SetLimits({ maxDropdownEntries = WidgetKit.UNBOUNDED })
    local picker = WidgetKit:CreateMediaPicker("statusbar")
    assert.are.equal(#MediaKit:List("statusbar"), picker:GetNumEntries())
  end)

  it("refuses a type MediaKit does not know at the caller", function()
    TestEnv.expectErrorContaining("mediaType must be a MediaKit media type", function()
      WidgetKit:CreateMediaPicker("statusBar")
    end)
  end)

  it("draws a select option as a media picker and writes to a SettingsKit binding", function()
    local S = modules.SchemaKit
    local MediaKit = modules.MediaKit
    MediaKit:Register("font", "Spec Sans", [[Interface\AddOns\Spec\Sans.ttf]])
    local db = modules.SettingsKit:Open(TestEnv.SavedVariable("WidgetKitMediaSpecDB"), {
      profile = S.table({ fields = { font = S.optional(S.string(), "Spec Sans") } }),
    })
    local tree = modules.OptionsKit:Define("MediaSpec", {
      type = "group",
      args = {
        font = {
          type = "select",
          name = "Font",
          values = function()
            local values = {}
            for _, name in ipairs(MediaKit:List("font")) do
              values[name] = name
            end
            return values
          end,
          bind = "profile.font",
        },
      },
    }, { db = db })

    local window = WidgetKit:Create("Frame")
    local rendering = WidgetKit:RenderOptions(tree, window, { media = { font = "font" } })
    local picker = rendering:GetWidget("font")
    assert.are.equal(#MediaKit:List("font"), picker:GetNumEntries())
    assert.are.equal("Spec Sans", picker:GetValue())

    local fonts = MediaKit:List("font")
    local target = fonts[1] == "Spec Sans" and 2 or 1
    picker:PickIndex(target)
    assert.are.equal(fonts[target], db.profile.font)
  end)
end)

describe("WidgetKit media pickers without MediaKit", function()
  local WidgetKitTestEnv = require("WidgetKitTestEnv")
  after_each(WidgetKitTestEnv.Reset)

  it("raises at the caller", function()
    local WidgetKit = WidgetKitTestEnv.NewPackage()
    WidgetKitTestEnv.expectErrorContaining(
      "WidgetKit:CreateMediaPicker requires MediaKit API 1",
      function()
        WidgetKit:CreateMediaPicker("font")
      end
    )
  end)

  it("falls back to the option's own values in the renderer", function()
    local WidgetKit, _, _, _, _, OptionsKit = WidgetKitTestEnv.NewPackage()
    local stored = "a"
    local tree = OptionsKit:Define("NoMediaSpec", {
      type = "group",
      args = {
        font = {
          type = "select",
          name = "Font",
          values = { a = "A", b = "B" },
          get = function()
            return stored
          end,
          set = function(_, value)
            stored = value
          end,
        },
      },
    })
    local rendering =
      WidgetKit:RenderOptions(tree, WidgetKit:Create("Frame"), { media = { font = "font" } })
    assert.are.equal(2, rendering:GetWidget("font"):GetNumEntries())
  end)
end)
