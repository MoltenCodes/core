local TestEnv = require("WidgetKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src

---Run `action` and assert it failed with `message` reported at the line of this
---spec file marked by `mark()`, which records the line after it.
---@param message string
---@param action fun(mark: fun())
local function assertReportedAtCaller(message, action)
  local expectedLine = nil
  local function mark()
    expectedLine = debug.getinfo(2, "l").currentline + 1
  end
  local ok, value = pcall(action, mark)
  assert.is_false(ok)
  assert.are.equal(SOURCE .. ":" .. tostring(expectedLine) .. ": " .. message, value)
end

---`count` elements `{ text = "row <index>" }`.
---@param count integer
---@return table[]
local function elementsOf(count)
  local elements = {}
  for index = 1, count do
    elements[index] = { text = "row " .. index }
  end
  return elements
end

---The rows on display, in data order: `{ row, element, text }`.
---@param list table
---@return table[]
local function shownRows(list)
  local rows = {}
  for _, row in ipairs(list.view.frames) do
    local parts = list._rowParts[row]
    rows[#rows + 1] = {
      row = row,
      element = row:GetElementData(),
      index = row:GetOrderIndex(),
      text = parts.text:GetText(),
      parts = parts,
    }
  end
  table.sort(rows, function(first, second)
    return first.index < second.index
  end)
  return rows
end

---The shown row whose element is `element`, or `nil`.
---@param list table
---@param element table
---@return table?
local function rowOf(list, element)
  for _, row in ipairs(list.view.frames) do
    if row:GetElementData() == element then
      return row
    end
  end
  return nil
end

describe("WidgetKit ScrollList", function()
  local WidgetKit

  ---A list 300 x 200 on the screen: 11 rows of 20 pixels on display.
  ---@return table list
  local function newList()
    local list = WidgetKit:Create("ScrollList") ---@cast list -nil
    list:SetPoint("TOPLEFT", TestEnv.GetGlobal("UIParent"), "TOPLEFT", 0, 0)
    return list
  end

  before_each(function()
    WidgetKit = TestEnv.NewPackage()
    TestEnv.InstallScrollBox()
    TestEnv.InstallSecretProbe()
    TestEnv.InstallHostErrorHandler()
  end)
  after_each(TestEnv.Reset)

  describe("construction", function()
    it("is a base type at version 2 built on the ScrollBox framework", function()
      assert.are.equal(2, WidgetKit:GetTypeVersion("ScrollList"))
      local list = newList()
      assert.are.equal("ScrollList", list:GetType())
      assert.are.equal("WowScrollBoxList", list.scrollBox.template)
      assert.are.equal(list.frame, list.scrollBox:GetParent())
      assert.are.equal("MinimalScrollBar", list.scrollBar.template)
      assert.are.equal("EventFrame", list.scrollBar.frameType)
      assert.is_true(list.scrollBar.hideIfUnscrollable)
      assert.are.equal(list.view, list.scrollBox.view)
      assert.are.equal(list.scrollBar, list.scrollBox.scrollBar)
      assert.are.equal("Button", list.view.frameType)
      assert.are.equal(20, list.view.extent)
      assert.are.equal(300, list:GetWidth())
      assert.are.equal(200, list:GetHeight())
      -- An empty list has no data provider and no row.
      assert.is_nil(list.scrollBox:GetDataProvider())
      assert.are.equal(0, list:GetNumElements())
      assert.are.equal(0, list.view.created)
    end)

    it("refuses at the caller's line on a host without the framework, making no frame", function()
      TestEnv.ScrollBox.Remove(TestEnv.SetGlobal)
      local frames = #TestEnv.Frames()
      assertReportedAtCaller(
        "WidgetKit:Create ScrollList needs the client's ScrollBox framework (Blizzard_SharedXML),"
          .. " which this host does not have",
        function(mark)
          mark()
          WidgetKit:Create("ScrollList")
        end
      )
      assert.are.equal(frames, #TestEnv.Frames())
      assert.are.equal(0, WidgetKit:GetStatistics().byType.ScrollList.created)
      -- The other widgets are unaffected.
      assert.is_true(WidgetKit:IsWidget(WidgetKit:Create("Label")))
    end)

    it("refuses a member of the framework missing as well", function()
      TestEnv.SetGlobal("ScrollUtil", {})
      assert.has_error(function()
        WidgetKit:Create("ScrollList")
      end)
    end)
  end)

  describe("rows", function()
    it("makes frames only for the rows on display, whatever the length", function()
      local list = newList()
      local elements = elementsOf(10000)
      list:SetElements(elements)
      assert.are.equal(10000, list:GetNumElements())
      assert.are.equal(elements[42], list:GetElement(42))
      assert.is_nil(list:GetElement(10001))
      assert.are.equal(11, list.view.created)
      local rows = shownRows(list)
      assert.are.equal(11, #rows)
      assert.are.equal("row 1", rows[1].text)
      assert.are.equal("row 11", rows[11].text)
      assert.are.equal(20, rows[1].row:GetHeight())
    end)

    it("reuses its rows when scrolled and builds each row's parts once", function()
      local list = newList()
      list:SetElements(elementsOf(1000))
      local partsBefore = {}
      for row, parts in pairs(list._rowParts) do
        partsBefore[row] = parts
      end
      TestEnv.ScrollBox.ScrollTo(list.scrollBox, 500)
      TestEnv.ScrollBox.ScrollTo(list.scrollBox, 990)
      assert.are.equal(11, list.view.created)
      local rows = shownRows(list)
      assert.are.equal("row 990", rows[1].text)
      assert.are.equal("row 1000", rows[11].text)
      for row, parts in pairs(list._rowParts) do
        assert.are.equal(partsBefore[row], parts)
        local fontStrings = 0
        for _, region in ipairs(row.regions) do
          if region:GetObjectType() == "FontString" then
            fontStrings = fontStrings + 1
          end
        end
        assert.are.equal(1, fontStrings)
      end
    end)

    it("draws element.text and element.icon by default", function()
      local list = newList()
      local withIcon = { text = "with icon", icon = 134400 }
      local plain = { text = "plain" }
      list:SetElements({ withIcon, plain })
      local iconRow = list._rowParts[rowOf(list, withIcon)]
      assert.are.equal("with icon", iconRow.text:GetText())
      assert.are.equal(134400, iconRow.icon:GetTexture())
      assert.is_true(iconRow.icon:IsShown())
      assert.are.equal(18, iconRow.icon:GetWidth())
      local _, _, _, inset = iconRow.text:GetPoint(1)
      assert.are.equal(4 + 18 + 4, inset)
      local plainRow = list._rowParts[rowOf(list, plain)]
      assert.is_false(plainRow.icon:IsShown())
      local _, _, _, plainInset = plainRow.text:GetPoint(1)
      assert.are.equal(4, plainInset)
    end)

    it("asks a formatter with the element and its index", function()
      local list = newList()
      local calls = {}
      list:SetFormatter(function(element, index)
        calls[#calls + 1] = index
        return element.name .. "#" .. index, "Interface\\Icons\\Spell"
      end)
      list:SetElements({ { name = "a" }, { name = "b" } })
      local rows = shownRows(list)
      assert.are.equal("a#1", rows[1].text)
      assert.are.equal("b#2", rows[2].text)
      assert.are.equal("Interface\\Icons\\Spell", rows[1].parts.icon:GetTexture())
      assert.are.same({ 1, 2 }, calls)
      -- Numbers are texts too.
      list:SetFormatter(function(_, index)
        return index * 10
      end)
      assert.are.equal(10, shownRows(list)[1].text)
    end)

    -- Regression (revision 13): Blizzard's view keeps the row of an element
    -- that stays on display when the data provider changes and only moves
    -- its order index, without running the initializer, so a formatter that
    -- shows the index kept the old one after an Insert or a Remove before it.
    it("asks the formatter again with the new index after Insert and Remove", function()
      local list = newList()
      list:SetFormatter(function(element, index)
        return element.name .. "#" .. index
      end)
      local first, second, third = { name = "a" }, { name = "b" }, { name = "c" }
      list:SetElements({ first, second, third })
      list:Insert({ name = "z" }, 1)
      local texts = {}
      for _, row in ipairs(shownRows(list)) do
        texts[#texts + 1] = row.text
      end
      assert.are.same({ "z#1", "a#2", "b#3", "c#4" }, texts)
      list:Remove(first)
      texts = {}
      for _, row in ipairs(shownRows(list)) do
        texts[#texts + 1] = row.text
      end
      assert.are.same({ "z#1", "b#2", "c#3" }, texts)
      -- Appending moves no index: the rows on display are not drawn again.
      local reinitializations = list.scrollBox.reinitializations
      list:Insert({ name = "d" })
      assert.are.equal(reinitializations, list.scrollBox.reinitializations)
      -- The default formatter shows no index: nothing is drawn again either.
      list:SetFormatter(nil)
      reinitializations = list.scrollBox.reinitializations
      list:Insert({ text = "y" }, 1)
      list:Remove(second)
      assert.are.equal(reinitializations, list.scrollBox.reinitializations)
    end)

    it("reports a raising formatter and wrong results, showing an empty row", function()
      local list = newList()
      list:SetElements({ { text = "kept" } })
      list:SetFormatter(function()
        error("formatter broke", 0)
      end)
      local rows = shownRows(list)
      assert.is_nil(rows[1].text)
      assert.are.same({ "formatter broke" }, TestEnv.ReportedErrors())

      TestEnv.TakeReportedErrors()
      list:SetFormatter(function()
        return true, {}
      end)
      assert.is_nil(shownRows(list)[1].text)
      assert.is_false(shownRows(list)[1].parts.icon:IsShown())
      assert.are.same({
        "WidgetKit ScrollList formatter text must be a string or nil; it was a boolean",
        "WidgetKit ScrollList formatter icon must be a string, a number or nil; it was a table",
      }, TestEnv.ReportedErrors())

      TestEnv.TakeReportedErrors()
      local secret = TestEnv.NewSecret()
      list:SetFormatter(function()
        return secret, secret
      end)
      assert.is_nil(shownRows(list)[1].text)
      assert.are.same({
        "WidgetKit ScrollList formatter text must not be a secret value",
        "WidgetKit ScrollList formatter icon must not be a secret value",
      }, TestEnv.ReportedErrors())

      TestEnv.TakeReportedErrors()
      list:SetFormatter(nil)
      assert.are.equal("kept", shownRows(list)[1].text)
      assert.are.same({}, TestEnv.ReportedErrors())
    end)

    it("refuses a formatter that is not a function", function()
      local list = newList()
      assert.has_error(function()
        list:SetFormatter("text")
      end, nil)
      TestEnv.expectErrorContaining(
        "WidgetKit ScrollList:SetFormatter callback must be a function or nil",
        function()
          list:SetFormatter({})
        end
      )
      TestEnv.expectErrorContaining(
        "WidgetKit ScrollList:SetFormatter callback must not be a secret value",
        function()
          list:SetFormatter(TestEnv.NewSecret())
        end
      )
    end)

    it("changes the row height and acquires the rows on display again", function()
      local list = newList()
      list:SetRowHeight(40)
      assert.are.equal(40, list.view.extent)
      list:SetElements(elementsOf(100))
      -- 200 / 40 + 1 rows.
      assert.are.equal(6, #shownRows(list))
      assert.are.equal(40, shownRows(list)[1].row:GetHeight())
      list:SetRowHeight(25)
      assert.are.equal(1, list.scrollBox.rebuilds)
      assert.are.equal(25, shownRows(list)[1].row:GetHeight())
      -- The same height changes nothing.
      list:SetRowHeight(25)
      assert.are.equal(1, list.scrollBox.rebuilds)
      for _, invalid in ipairs({ 7.9, 0, -20, math.huge }) do
        TestEnv.expectErrorContaining(
          "WidgetKit ScrollList:SetRowHeight pixels must be a finite number of at least 8",
          function()
            list:SetRowHeight(invalid)
          end
        )
      end
      TestEnv.expectErrorContaining(
        "WidgetKit ScrollList:SetRowHeight pixels must be a number",
        function()
          list:SetRowHeight("20")
        end
      )
    end)
  end)

  describe("elements", function()
    it("copies the array and checks every element before changing anything", function()
      local list = newList()
      local elements = elementsOf(3)
      list:SetElements(elements)
      elements[4] = { text = "later" }
      assert.are.equal(3, list:GetNumElements())

      local before = list.scrollBox:GetDataProvider()
      local duplicate = { text = "twice" }
      local secret = TestEnv.NewSecret()
      local refusals = {
        { { {}, "x" }, "elements[2] must be a table" },
        { { {}, secret }, "elements[2] must not be a secret value" },
        { { duplicate, duplicate }, "elements[2] appears twice" },
      }
      for _, refusal in ipairs(refusals) do
        TestEnv.expectErrorContaining("WidgetKit ScrollList:SetElements " .. refusal[2], function()
          list:SetElements(refusal[1])
        end)
      end
      TestEnv.expectErrorContaining(
        "WidgetKit ScrollList:SetElements elements must be an array of tables",
        function()
          list:SetElements("rows")
        end
      )
      TestEnv.expectErrorContaining(
        "WidgetKit ScrollList:SetElements elements must not be a secret value",
        function()
          list:SetElements(secret)
        end
      )
      TestEnv.expectErrorContaining(
        "WidgetKit ScrollList:SetElements retainScroll must be a boolean",
        function()
          list:SetElements({}, "yes")
        end
      )
      assert.are.equal(before, list.scrollBox:GetDataProvider())
      assert.are.equal(3, list:GetNumElements())
    end)

    it("holds at most maxListElements, which opens to UNBOUNDED", function()
      assert.are.equal(16384, WidgetKit:GetLimits().maxListElements)
      local list = newList()
      WidgetKit:SetLimits({ maxListElements = 3 })
      list:SetElements(elementsOf(3))
      TestEnv.expectErrorContaining(
        "WidgetKit ScrollList:SetElements holds at most 3 elements (WidgetKit:SetLimits maxListElements)",
        function()
          list:SetElements(elementsOf(4))
        end
      )
      TestEnv.expectErrorContaining(
        "WidgetKit ScrollList:Insert holds at most 3 elements (WidgetKit:SetLimits maxListElements)",
        function()
          list:Insert({})
        end
      )
      assert.are.equal(3, list:GetNumElements())
      WidgetKit:SetLimits({ maxListElements = WidgetKit.UNBOUNDED })
      list:SetElements(elementsOf(20000))
      assert.are.equal(20000, list:GetNumElements())
      assert.are.equal(11, list.view.created)
      for _, invalid in ipairs({ 0, 1.5, "8", {} }) do
        TestEnv.expectErrorContaining(
          "WidgetKit:SetLimits limits.maxListElements must be a positive integer or WidgetKit.UNBOUNDED",
          function()
            WidgetKit:SetLimits({ maxListElements = invalid })
          end
        )
      end
      TestEnv.expectErrorContaining(
        "WidgetKit:SetLimits limits.maxListElements must not be a secret value",
        function()
          WidgetKit:SetLimits({ maxListElements = TestEnv.NewSecret() })
        end
      )
      WidgetKit:SetLimits({ maxCreatedCeiling = 8192, maxListElements = 5 })
      assert.are.equal(5, WidgetKit:GetLimits().maxListElements)
      assert.are.equal(8192, WidgetKit:GetLimits().maxCreatedCeiling)
    end)

    it(
      "keeps the selection when its element is in the new list, and the scroll on request",
      function()
        local list = newList()
        local elements = elementsOf(100)
        list:SetElements(elements)
        list:SetValue(elements[50])
        TestEnv.ScrollBox.ScrollTo(list.scrollBox, 45)

        local reordered = { elements[50] }
        for index = 1, 99 do
          reordered[index + 1] = index < 50 and elements[index] or elements[index + 1]
        end
        list:SetElements(reordered, true)
        assert.are.equal(elements[50], list:GetValue())
        assert.are.equal(45, list.scrollBox.firstIndex)
        list:SetElements(elementsOf(100), true)
        assert.is_nil(list:GetValue())
        assert.are.equal(45, list.scrollBox.firstIndex)
        list:SetElements(elementsOf(100))
        assert.are.equal(1, list.scrollBox.firstIndex)
      end
    )

    it("inserts, removes and clears through one data provider", function()
      local list = newList()
      local first, second, third = { text = "first" }, { text = "second" }, { text = "third" }
      list:Insert(first)
      local provider = list.scrollBox:GetDataProvider()
      assert.is_not_nil(provider)
      list:Insert(third)
      list:Insert(second, 2)
      assert.are.equal(provider, list.scrollBox:GetDataProvider())
      assert.are.same({ "first", "second", "third" }, {
        shownRows(list)[1].text,
        shownRows(list)[2].text,
        shownRows(list)[3].text,
      })
      TestEnv.expectErrorContaining(
        "WidgetKit ScrollList:Insert element is already in the list",
        function()
          list:Insert(second)
        end
      )
      TestEnv.expectErrorContaining(
        "WidgetKit ScrollList:Insert index must be at most the element count plus one",
        function()
          list:Insert({}, 5)
        end
      )
      TestEnv.expectErrorContaining(
        "WidgetKit ScrollList:Insert index must be a positive integer",
        function()
          list:Insert({}, 0)
        end
      )
      TestEnv.expectErrorContaining(
        "WidgetKit ScrollList:Insert element must be a table",
        function()
          list:Insert("row")
        end
      )

      list:SetValue(second)
      assert.is_true(list:Remove(second))
      assert.is_nil(list:GetValue())
      assert.is_false(list:Remove(second))
      assert.are.equal(2, list:GetNumElements())
      TestEnv.expectErrorContaining(
        "WidgetKit ScrollList:Remove element must not be a secret value",
        function()
          list:Remove(TestEnv.NewSecret())
        end
      )

      list:SetValue(first)
      list:Clear()
      assert.are.equal(0, list:GetNumElements())
      assert.is_nil(list:GetValue())
      assert.are.equal(0, #list.view.frames)
    end)

    it("answers an empty list without making a data provider", function()
      local list = newList()
      assert.is_false(list:Remove({}))
      list:Clear()
      list:Refresh()
      assert.is_false(list:ScrollToElement({}))
      assert.is_nil(list:GetElement(1))
      assert.is_nil(list.scrollBox:GetDataProvider())
      TestEnv.expectErrorContaining(
        "WidgetKit ScrollList:GetElement index must be a positive integer",
        function()
          list:GetElement(0)
        end
      )
    end)

    it("draws the rows on display again on Refresh", function()
      local list = newList()
      local element = { text = "before" }
      list:SetElements({ element })
      element.text = "after"
      assert.are.equal("before", shownRows(list)[1].text)
      list:Refresh()
      assert.are.equal("after", shownRows(list)[1].text)
      assert.are.equal(1, list.scrollBox.reinitializations)
    end)

    it("scrolls to an element by index with each alignment", function()
      local list = newList()
      local elements = elementsOf(500)
      list:SetElements(elements)
      assert.is_true(list:ScrollToElement(elements[300]))
      local call = list.scrollBox.scrollCalls[1]
      assert.are.same({ index = 300, alignment = 0.5, offset = 0, noInterpolation = true }, call)
      local expected = { begin = 0, center = 0.5, ["end"] = 1, nearest = -1 }
      for name, value in pairs(expected) do
        assert.is_true(list:ScrollToElement(elements[10], name))
        local last = list.scrollBox.scrollCalls[#list.scrollBox.scrollCalls]
        assert.are.equal(value, last.alignment)
      end
      list:ScrollToElement(elements[300], "begin")
      assert.are.equal("row 300", shownRows(list)[1].text)
      assert.is_false(list:ScrollToElement({}))
      TestEnv.expectErrorContaining(
        'WidgetKit ScrollList:ScrollToElement alignment must be "begin", "center", "end" or "nearest"',
        function()
          list:ScrollToElement(elements[1], "top")
        end
      )
      TestEnv.expectErrorContaining(
        "WidgetKit ScrollList:ScrollToElement alignment must not be a secret value",
        function()
          list:ScrollToElement(elements[1], TestEnv.NewSecret())
        end
      )
    end)
  end)

  describe("selection and clicks", function()
    it("selects on a left click and fires OnValueChanged, then OnClick", function()
      local list = newList()
      local elements = elementsOf(20)
      list:SetElements(elements)
      local fired = {}
      list:SetCallback("OnValueChanged", function(_, name, element)
        fired[#fired + 1] = { name, element }
      end)
      list:SetCallback("OnClick", function(_, name, element, mouseButton)
        fired[#fired + 1] = { name, element, mouseButton }
      end)

      rowOf(list, elements[3]):Click("LeftButton")
      assert.are.equal(elements[3], list:GetValue())
      assert.are.same({
        { "OnValueChanged", elements[3] },
        { "OnClick", elements[3], "LeftButton" },
      }, fired)
      assert.is_true(list._rowParts[rowOf(list, elements[3])].selected:IsShown())
      assert.is_false(list._rowParts[rowOf(list, elements[4])].selected:IsShown())

      fired = {}
      rowOf(list, elements[3]):Click("LeftButton")
      rowOf(list, elements[5]):Click("RightButton")
      assert.are.same({
        { "OnClick", elements[3], "LeftButton" },
        { "OnClick", elements[5], "RightButton" },
      }, fired)
      assert.are.equal(elements[3], list:GetValue())
    end)

    it("shows the selection on rows acquired later and after SetValue", function()
      local list = newList()
      local elements = elementsOf(100)
      list:SetElements(elements)
      list:SetValue(elements[60])
      TestEnv.ScrollBox.ScrollTo(list.scrollBox, 55)
      assert.is_true(list._rowParts[rowOf(list, elements[60])].selected:IsShown())
      list:SetValue(nil)
      assert.is_false(list._rowParts[rowOf(list, elements[60])].selected:IsShown())
      TestEnv.expectErrorContaining(
        "WidgetKit ScrollList:SetValue element must be a table or nil",
        function()
          list:SetValue("row")
        end
      )
      TestEnv.expectErrorContaining(
        "WidgetKit ScrollList:SetValue element must not be a secret value",
        function()
          list:SetValue(TestEnv.NewSecret())
        end
      )
    end)

    it("stops after OnValueChanged when that callback releases the list", function()
      local list = newList()
      local elements = elementsOf(5)
      list:SetElements(elements)
      local clicked = false
      list:SetCallback("OnValueChanged", function(widget)
        widget:Release()
      end)
      list:SetCallback("OnClick", function()
        clicked = true
      end)
      local row = rowOf(list, elements[2]) ---@cast row -nil
      local click = row.scripts.OnClick
      click(row, "LeftButton")
      assert.is_false(WidgetKit:IsWidget(list))
      assert.is_false(clicked)
      -- A click on a row of a released list does nothing.
      click(row, "LeftButton")
    end)

    it("ignores clicks and greys the rows while disabled", function()
      local list = newList()
      local elements = elementsOf(5)
      list:SetElements(elements)
      local clicks = 0
      list:SetCallback("OnClick", function()
        clicks = clicks + 1
      end)
      list:SetDisabled(true)
      rowOf(list, elements[1]):Click("LeftButton")
      assert.are.equal(0, clicks)
      assert.is_nil(list:GetValue())
      local red = list._rowParts[rowOf(list, elements[1])].text:GetTextColor()
      assert.are.equal(0.5, red)
      list:SetElements(elementsOf(3))
      assert.are.equal(0.5, (shownRows(list)[1].parts.text:GetTextColor()))
      list:SetDisabled(false)
      assert.are.equal(1, (shownRows(list)[1].parts.text:GetTextColor()))
      shownRows(list)[1].row:Click("LeftButton")
      assert.are.equal(1, clicks)
      TestEnv.expectErrorContaining(
        "WidgetKit ScrollList:SetDisabled disabled must be a boolean",
        function()
          list:SetDisabled("yes")
        end
      )
    end)
  end)

  describe("release and reuse", function()
    it("gives every row back to the view and keeps no element", function()
      local list = newList()
      local elements = elementsOf(50)
      list:SetElements(elements)
      list:SetValue(elements[2])
      list:SetFormatter(function(element)
        return element.text
      end)
      list:SetRowHeight(30)
      WidgetKit:Release(list)
      assert.are.equal(1, list.scrollBox.flushes)
      assert.is_nil(list.scrollBox:GetDataProvider())
      assert.are.equal(0, #list.view.frames)
      assert.is_nil(list._provider)
      assert.is_nil(list._value)
      assert.is_nil(list._formatter)
      for row, parts in pairs(list._rowParts) do
        assert.is_false(row:IsShown())
        assert.is_nil(row.GetElementData)
        assert.is_nil(parts.text:GetText())
        assert.is_false(parts.selected:IsShown())
      end

      local again = WidgetKit:Create("ScrollList") ---@cast again -nil
      assert.are.equal(list, again)
      assert.are.equal(20, again.view.extent)
      assert.is_nil(again:GetValue())
      assert.are.equal(0, again:GetNumElements())
      again:SetPoint("TOPLEFT", TestEnv.GetGlobal("UIParent"), "TOPLEFT", 0, 0)
      again:SetElements(elementsOf(50))
      -- 200 / 30 + 1 = 7 rows were made at 30 pixels; 11 at 20 reuse them.
      assert.are.equal(11, again.view.created)
      assert.are.equal("row 1", shownRows(again)[1].text)
      WidgetKit:Release(again)
      local third = WidgetKit:Create("ScrollList") ---@cast third -nil
      third:SetPoint("TOPLEFT", TestEnv.GetGlobal("UIParent"), "TOPLEFT", 0, 0)
      third:SetElements(elementsOf(50))
      assert.are.equal(11, third.view.created)
    end)

    it("refuses every method of a released list", function()
      local list = newList()
      WidgetKit:Release(list)
      local calls = {
        SetElements = { {} },
        Insert = { {} },
        Remove = { {} },
        Clear = {},
        GetNumElements = {},
        GetElement = { 1 },
        Refresh = {},
        ScrollToElement = { {} },
        SetValue = { {} },
        GetValue = {},
        SetRowHeight = { 20 },
        SetFormatter = {},
        SetDisabled = { true },
      }
      for name, arguments in pairs(calls) do
        TestEnv.expectErrorContaining(
          "WidgetKit ScrollList:" .. name .. " cannot be called on a released widget",
          function()
            list[name](list, unpack(arguments))
          end
        )
        TestEnv.expectErrorContaining(
          "WidgetKit ScrollList:" .. name .. " must be called on a WidgetKit widget",
          function()
            list[name]({}, unpack(arguments))
          end
        )
      end
    end)

    it("lays out in a container like any widget", function()
      local group = WidgetKit:Create("Group") ---@cast group -nil
      local list = WidgetKit:Create("ScrollList") ---@cast list -nil
      list:SetFullWidth(true)
      group:AddChild(list)
      assert.are.equal(group, list:GetParentContainer())
      WidgetKit:Release(group)
      assert.is_false(WidgetKit:IsWidget(list))
    end)
  end)

  describe("error levels", function()
    it("reports argument errors at the caller's line", function()
      local list = newList()
      assertReportedAtCaller(
        "WidgetKit ScrollList:SetElements elements[1] must be a table",
        function(mark)
          mark()
          list:SetElements({ 1 })
        end
      )
      assertReportedAtCaller(
        "WidgetKit ScrollList:SetElements elements must not be a secret value",
        function(mark)
          mark()
          list:SetElements(TestEnv.NewSecret())
        end
      )
      assertReportedAtCaller("WidgetKit ScrollList:Insert element must be a table", function(mark)
        mark()
        list:Insert(1)
      end)
      assertReportedAtCaller(
        "WidgetKit ScrollList:Insert element must not be a secret value",
        function(mark)
          mark()
          list:Insert(TestEnv.NewSecret())
        end
      )
      assertReportedAtCaller(
        "WidgetKit ScrollList:Insert index must be a positive integer",
        function(mark)
          mark()
          list:Insert({}, -1)
        end
      )
      assertReportedAtCaller(
        "WidgetKit ScrollList:GetElement index must be a positive integer",
        function(mark)
          mark()
          list:GetElement(1.5)
        end
      )
      assertReportedAtCaller(
        "WidgetKit ScrollList:SetRowHeight pixels must be a number",
        function(mark)
          mark()
          list:SetRowHeight(nil)
        end
      )
      assertReportedAtCaller(
        "WidgetKit ScrollList:SetRowHeight pixels must be a finite number of at least 8",
        function(mark)
          mark()
          list:SetRowHeight(4)
        end
      )
      assertReportedAtCaller(
        "WidgetKit ScrollList:SetValue element must be a table or nil",
        function(mark)
          mark()
          list:SetValue(1)
        end
      )
      assertReportedAtCaller(
        "WidgetKit ScrollList:SetFormatter callback must be a function or nil",
        function(mark)
          mark()
          list:SetFormatter(1)
        end
      )
      assertReportedAtCaller(
        "WidgetKit ScrollList:ScrollToElement element must be a table",
        function(mark)
          mark()
          list:ScrollToElement(nil)
        end
      )
      assertReportedAtCaller("WidgetKit ScrollList:Remove element must be a table", function(mark)
        mark()
        list:Remove(nil)
      end)
      assertReportedAtCaller(
        "WidgetKit ScrollList:SetDisabled disabled must be a boolean",
        function(mark)
          mark()
          list:SetDisabled(1)
        end
      )
      WidgetKit:Release(list)
      assertReportedAtCaller(
        "WidgetKit ScrollList:GetValue cannot be called on a released widget",
        function(mark)
          mark()
          list:GetValue()
        end
      )
    end)

    it("reports a data provider missing at call time at the caller's line", function()
      local list = newList()
      TestEnv.SetGlobal("CreateDataProvider", nil)
      assertReportedAtCaller(
        "WidgetKit ScrollList:SetElements needs the client's ScrollBox framework (Blizzard_SharedXML),"
          .. " which this host does not have",
        function(mark)
          mark()
          list:SetElements({})
        end
      )
      assertReportedAtCaller(
        "WidgetKit ScrollList:Insert needs the client's ScrollBox framework (Blizzard_SharedXML),"
          .. " which this host does not have",
        function(mark)
          mark()
          list:Insert({})
        end
      )
    end)
  end)

  describe("upgrades", function()
    -- The text revision 12 added to the source (the `ScrollList` version
    -- line and the limit); without it the file models revision 11, which had
    -- no `ScrollList` and no `maxListElements`.
    local REVISION_12_ONLY = {
      ["  ScrollList = 2,\n"] = "",
      ['if rawget(rawget(state, "limits"), "maxListElements") == nil then\n' .. '  rawset(rawget(state, "limits"), "maxListElements", 16384)\n' .. "end\n"] = "",
    }

    it("upgrades a revision 11 copy in place, adding the type and the limit", function()
      TestEnv.Reset()
      TestEnv.InstallWowApi()
      TestEnv.InstallClientRules()
      TestEnv.InstallScreen()
      for _, name in ipairs({ "Registry", "SignalKit", "PoolKit", "SchemaKit", "OptionsKit" }) do
        require(name)
      end
      local old = TestEnv.LoadRevision(11, REVISION_12_ONLY)
      assert.are.equal(11, old.REVISION)
      assert.is_nil(old:GetTypeVersion("ScrollList"))
      assert.is_nil(old:GetLimits().maxListElements)
      old:SetLimits({ maxDropdownEntries = old.UNBOUNDED })
      local label = old:Create("Label") ---@cast label -nil
      label:SetText("kept")
      local state = old._state

      local upgraded = require("WidgetKit")
      assert.are.equal(old, upgraded)
      assert.are.equal(state, upgraded._state)
      assert.are.equal(WidgetKit.REVISION, upgraded.REVISION)
      assert.are.equal(2, upgraded:GetTypeVersion("ScrollList"))
      assert.are.same({
        maxCreatedCeiling = 4096,
        maxDropdownEntries = upgraded.UNBOUNDED,
        maxListElements = 16384,
      }, upgraded:GetLimits())
      assert.is_true(upgraded:IsWidget(label))
      assert.are.equal("kept", label:GetText())

      TestEnv.InstallScrollBox()
      local list = upgraded:Create("ScrollList") ---@cast list -nil
      list:SetPoint("TOPLEFT", TestEnv.GetGlobal("UIParent"), "TOPLEFT", 0, 0)
      list:SetElements(elementsOf(30))
      assert.are.equal(11, list.view.created)
    end)

    it("upgrades a revision 12 copy, retiring its lists for the redraw of version 2", function()
      TestEnv.Reset()
      TestEnv.InstallWowApi()
      TestEnv.InstallClientRules()
      TestEnv.InstallScreen()
      TestEnv.InstallScrollBox()
      for _, name in ipairs({ "Registry", "SignalKit", "PoolKit", "SchemaKit", "OptionsKit" }) do
        require(name)
      end
      -- Revision 12: `ScrollList` at version 1, whose `Insert` and `Remove`
      -- never asked the formatter again.
      local old = TestEnv.LoadRevision(12, {
        ["  ScrollList = 2,\n"] = "  ScrollList = 1,\n",
        ["    if widget._formatter ~= nil then\n      widget.scrollBox:ReinitializeFrames()"] = "    if false then\n      widget.scrollBox:ReinitializeFrames()",
      })
      assert.are.equal(12, old.REVISION)
      assert.are.equal(1, old:GetTypeVersion("ScrollList"))
      local borrowed = old:Create("ScrollList") ---@cast borrowed -nil
      local pooled = old:Create("ScrollList") ---@cast pooled -nil
      old:Release(pooled)
      borrowed:SetElements(elementsOf(3))
      local state = old._state

      local upgraded = require("WidgetKit")
      assert.are.equal(old, upgraded)
      assert.are.equal(state, upgraded._state)
      assert.are.equal(13, upgraded.REVISION)
      assert.are.equal(2, upgraded:GetTypeVersion("ScrollList"))
      -- The borrowed list keeps working until it is released, then retires.
      assert.is_true(upgraded:IsWidget(borrowed))
      assert.are.equal(3, borrowed:GetNumElements())
      upgraded:Release(borrowed)
      local fresh = upgraded:Create("ScrollList") ---@cast fresh -nil
      assert.are_not.equal(pooled, fresh)
      assert.are_not.equal(borrowed, fresh)
      fresh:SetPoint("TOPLEFT", TestEnv.GetGlobal("UIParent"), "TOPLEFT", 0, 0)
      fresh:SetFormatter(function(element, index)
        return element.text .. "#" .. index
      end)
      local first = { text = "a" }
      fresh:SetElements({ first })
      fresh:Insert({ text = "z" }, 1)
      assert.are.equal("a#2", fresh._rowParts[rowOf(fresh, first)].text:GetText())
    end)

    it("hands a live list's rows to a newer revision through dispatch", function()
      local list = newList()
      local elements = elementsOf(40)
      list:SetElements(elements)
      local row = rowOf(list, elements[1]) ---@cast row -nil

      local upgraded = TestEnv.LoadRevision(WidgetKit.REVISION + 1, {
        ['reportError("WidgetKit ScrollList formatter text must not be a secret value")'] = 'reportError("newer revision")',
      })
      assert.are.equal(WidgetKit, upgraded)
      assert.is_true(upgraded:IsWidget(list))
      assert.are.equal(2, upgraded:GetTypeVersion("ScrollList"))
      -- The newer copy's row drawing runs for a list the older one built.
      local secret = TestEnv.NewSecret()
      list:SetFormatter(function()
        return secret
      end)
      -- One report per row on display.
      local reported = TestEnv.ReportedErrors()
      assert.are.equal(11, #reported)
      assert.are.equal("newer revision", reported[1])
      list:SetFormatter(nil)
      local changed = nil
      list:SetCallback("OnValueChanged", function(_, _, element)
        changed = element
      end)
      row:Click("LeftButton")
      assert.are.equal(elements[1], changed)
      upgraded:Release(list)
      assert.are.equal(list, upgraded:Create("ScrollList"))
    end)
  end)

  describe("allocation #allocation", function()
    it("acquires and releases a warm list without allocating", function()
      local list = WidgetKit:Create("ScrollList") ---@cast list -nil
      WidgetKit:Release(list)
      local kilobytes = TestEnv.AllocatedKilobytes(function()
        for _ = 1, 50 do
          local warm = WidgetKit:Create("ScrollList") ---@cast warm -nil
          WidgetKit:Release(warm)
        end
      end)
      assert.is_true(kilobytes < 1, "warm cycles allocated " .. kilobytes .. " KB")
    end)

    it("draws rows on scroll without allocating in WidgetKit", function()
      local list = newList()
      list:SetElements(elementsOf(200))
      local rows = shownRows(list)
      local initialize = list.view.initializer
      local kilobytes = TestEnv.AllocatedKilobytes(function()
        for _ = 1, 50 do
          for index = 1, #rows do
            initialize(rows[index].row, rows[index].element)
          end
        end
      end)
      assert.is_true(kilobytes < 1, "row drawing allocated " .. kilobytes .. " KB")
    end)
  end)
end)
