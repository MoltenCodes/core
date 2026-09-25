--- Widgets on the fake client: WidgetKit against AceGUI-3.0. Indicative only.
---
--- Both toolkits keep a pool of widgets per type and build a widget's frames
--- once, so steady-state use is acquire, fill, lay out and release. That is
--- what is measured: a pooled widget of each common type acquired, given a
--- typical text or value and released, and a titled group filled with labels,
--- laid out as a list and released with its children.
---
--- **Host-only and indicative.** The frames are the repository's fake client
--- (`tests/support/FrameworkTestEnv.lua`): a `SetPoint` or `SetText` on them is
--- a Lua table write, where the client's is a native call that can cost far
--- more, and nothing is ever drawn. The numbers compare the two libraries'
--- own Lua work around the frames, never what a player would see; the frame
--- cost belongs to the in-client runner (`docs/BENCHMARKS.md`).
---
--- The types compared are the ones both libraries have with the same role:
--- `Label`, `Button`, `CheckBox`, `Slider` and `EditBox`, and WidgetKit's
--- `Group` (an inline group with a title) against AceGUI's `InlineGroup`.
--- `Heading` is left out: AceGUI's at this commit calls the Retail 12
--- `issecretvalue` global on every `SetText`, and the host installs none on
--- purpose (a Lua stand-in would then also run on every WidgetKit text
--- setter, pricing a native check the host cannot price). AceGUI's `Frame`,
--- `ScrollFrame` and `SimpleGroup` load, but a window or a scroll area adds
--- nothing a group does not already show on these frames.
---
--- One stub cost is uneven, and is measured apart so a reader can subtract
--- it: the fake client refuses an anchor cycle, as the client does, by
--- walking the new anchor's chain in Lua. AceGUI's `List` anchors each child
--- to the one above, so its chain grows with every child and a pass over n
--- children walks about n²/2 anchors; WidgetKit's anchors each child to the
--- content. The `host-stub-list-anchors-50` rows are that stub work alone in
--- each library's style (one of AceGUI's label anchors per child is not in
--- it, so it understates the share); the client does the same check
--- natively. The group rows therefore carry both numbers but no ratio.
---
--- Before loading either side, the workload creates `UIParent`, the parent
--- both toolkits give a released frame (AceGUI captures it at load).

local Widgets = {}

--- Acquire-and-release cycles per timed batch.
local CYCLE_ITERATIONS = 20000

--- Groups filled and released per timed batch, by the labels each holds.
local GROUP_ITERATIONS = { [10] = 500, [50] = 100 }

--- Layout passes over one group of 50 labels per timed batch.
local RELAYOUT_ITERATIONS = 200

--- The caveat on every case that lays a group out.
--- Not given a ratio: on AceGUI's side most of the time is the stub's Lua
--- anchor-cycle check walking the chained anchors, which the client does
--- natively, so a ratio would measure the stub rather than the library.
local GROUP_NOTE = "not compared: AceGUI chains each child's anchor to the one above and the"
  .. " fake client checks anchor cycles by walking that chain in Lua, which dominates AceGUI's"
  .. " time (see host-stub-list-anchors-50); fake-client frames, indicative only"

--- The width groups are given, as a dialog column would.
local GROUP_WIDTH = 300

--- Widgets acquired without release in the `pool-bounded` check: more than
--- WidgetKit's default cap of 256 frames per type.
local UNRELEASED_PROBE = 300

--- The widget types both toolkits have, by the name each uses.
local TYPES = {
  label = { kit = "Label", ace = "Label", file = "AceGUIWidget-Label" },
  button = { kit = "Button", ace = "Button", file = "AceGUIWidget-Button" },
  checkbox = { kit = "CheckBox", ace = "CheckBox", file = "AceGUIWidget-CheckBox" },
  slider = { kit = "Slider", ace = "Slider", file = "AceGUIWidget-Slider" },
  editbox = { kit = "EditBox", ace = "EditBox", file = "AceGUIWidget-EditBox" },
  group = { kit = "Group", ace = "InlineGroup", file = "AceGUIContainer-InlineGroup" },
}

--- The order the cycle cases are listed in.
local CYCLED = { "label", "button", "checkbox", "slider", "editbox" }

--- What each cycle case writes into the widget, the same calls on both sides:
--- the typical content an options dialog gives a widget of that type.
local FILL = {
  label = function(widget)
    widget:SetText("Scale of the frame")
  end,
  button = function(widget)
    widget:SetText("Reset")
  end,
  checkbox = function(widget)
    widget:SetLabel("Show in combat")
    widget:SetValue(true)
  end,
  slider = function(widget)
    widget:SetLabel("Scale")
    widget:SetSliderValues(0, 100, 1)
    widget:SetValue(50)
  end,
  editbox = function(widget)
    widget:SetLabel("Name")
    widget:SetText("Tester")
  end,
}

---Create `UIParent`, as the client has it, before either toolkit loads.
---@param host table
local function installScreen(host)
  local uiParent = host.Global("CreateFrame")("Frame", "UIParent")
  uiParent:SetSize(1920, 1080)
end

---@param host table
---@return table adapter, table[] libraries
local function kitAdapter(host)
  local loaded = host.RequireAll({ "Registry", "PoolKit", "SignalKit", "WidgetKit" })
  local WidgetKit = loaded[4]
  local adapter = {}

  function adapter.create(kind)
    return WidgetKit:Create(TYPES[kind].kit)
  end

  function adapter.release(widget)
    WidgetKit:Release(widget)
  end

  function adapter.layout(group)
    group:PerformLayout()
  end

  function adapter.labelText(label)
    return label:GetText()
  end

  function adapter.children(group)
    return group:GetChildren()
  end

  ---The anchors WidgetKit's `List` sets on a full-width child, alone: two
  ---points on the content at the running offset, then the height read.
  function adapter.stubListAnchor(frames, index, content)
    local frame = frames[index]
    local offset = (index - 1) * 12
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -offset)
    frame:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -offset)
    return frame:GetHeight()
  end

  return adapter,
    {
      { name = "WidgetKit", revision = WidgetKit.REVISION },
      { name = "PoolKit", revision = loaded[2].REVISION },
      { name = "SignalKit", revision = loaded[3].REVISION },
    }
end

---@param host table
---@param directory string the Ace3 checkout
---@return table adapter, table[] libraries
local function aceAdapter(host, directory)
  local files = { "LibStub/LibStub.lua", "AceGUI-3.0/AceGUI-3.0.lua" }
  for _, description in pairs(TYPES) do
    files[#files + 1] = "AceGUI-3.0/widgets/" .. description.file .. ".lua"
  end
  host.LoadFiles(directory, files)
  local AceGUI, minor = host.Global("LibStub"):GetLibrary("AceGUI-3.0")
  local adapter = {}

  function adapter.create(kind)
    return AceGUI:Create(TYPES[kind].ace)
  end

  function adapter.release(widget)
    AceGUI:Release(widget)
  end

  function adapter.layout(group)
    group:DoLayout()
  end

  function adapter.labelText(label)
    return label.label:GetText()
  end

  function adapter.children(group)
    return group.children
  end

  ---The anchors AceGUI's `List` sets on a full-width child, alone: the top
  ---left to the frame above (the content for the first), the right edge to
  ---the content, then the height read.
  function adapter.stubListAnchor(frames, index, content)
    local frame = frames[index]
    frame:ClearAllPoints()
    if index == 1 then
      frame:SetPoint("TOPLEFT", content)
    else
      frame:SetPoint("TOPLEFT", frames[index - 1], "BOTTOMLEFT")
    end
    frame:SetPoint("RIGHT", content)
    return frame:GetHeight()
  end

  return adapter, { { name = "AceGUI-3.0", minor = minor } }
end

---Frames the fake client has created so far.
---@param host table
---@return integer
local function frameCount(host)
  return #host.environment.Frames()
end

---Fill a titled group with `count` full-width labels, layout paused, then lay
---it out once: the order an options dialog builds a page in.
---@param adapter table
---@param count integer
---@return table group
local function buildGroup(adapter, count)
  local group = adapter.create("group")
  group:SetWidth(GROUP_WIDTH)
  group:SetTitle("General")
  group:PauseLayout()
  for _ = 1, count do
    local label = adapter.create("label")
    label:SetText("An option described in one line")
    label:SetFullWidth(true)
    group:AddChild(label)
  end
  group:ResumeLayout()
  adapter.layout(group)
  return group
end

---One cycle case per widget type.
---@param adapter table
---@param host table
---@param kind string
---@return Bench.Case
local function cycleCase(adapter, host, kind)
  local fill = FILL[kind]
  return {
    name = "cycle-" .. kind,
    iterations = CYCLE_ITERATIONS,
    operation = "acquire a pooled "
      .. TYPES[kind].kit
      .. ", give it a text or value, release it (fake frames)",
    note = "indicative: fake-client frames, no native frame cost",
    prepare = function()
      local before = frameCount(host)
      adapter.release(adapter.create(kind))
      local framesPerWidget = frameCount(host) - before
      local afterPrepare = frameCount(host)
      return {
        run = function(iterations)
          local create, release = adapter.create, adapter.release
          for _ = 1, iterations do
            local widget = create(kind)
            fill(widget)
            release(widget)
          end
        end,
        metrics = function()
          return {
            framesPerWidget = framesPerWidget,
            framesCreatedWhileMeasuring = frameCount(host) - afterPrepare,
          }
        end,
      }
    end,
  }
end

---A case that fills and releases a group of `count` labels.
---@param adapter table
---@param host table
---@param count integer
---@return Bench.Case
local function groupCase(adapter, host, count)
  return {
    name = "group-" .. count,
    iterations = GROUP_ITERATIONS[count],
    operation = "acquire a titled group, add "
      .. count
      .. " labels, lay it out once, release it with its children (fake frames)",
    equivalent = false,
    note = GROUP_NOTE,
    prepare = function()
      adapter.release(buildGroup(adapter, count))
      local afterPrepare = frameCount(host)
      return {
        run = function(iterations)
          for _ = 1, iterations do
            adapter.release(buildGroup(adapter, count))
          end
        end,
        metrics = function()
          return {
            framesCreatedWhileMeasuring = frameCount(host) - afterPrepare,
          }
        end,
      }
    end,
  }
end

---@param adapter table
---@param host table
---@return Bench.Case[]
local function cases(adapter, host)
  local list = {}
  for index = 1, #CYCLED do
    list[#list + 1] = cycleCase(adapter, host, CYCLED[index])
  end
  list[#list + 1] = groupCase(adapter, host, 10)
  list[#list + 1] = groupCase(adapter, host, 50)
  list[#list + 1] = {
    name = "relayout-50",
    iterations = RELAYOUT_ITERATIONS,
    operation = "lay out a titled group of 50 labels again (fake frames)",
    equivalent = false,
    note = GROUP_NOTE,
    prepare = function()
      local group = buildGroup(adapter, 50)
      return {
        run = function(iterations)
          local layout = adapter.layout
          for _ = 1, iterations do
            layout(group)
          end
        end,
      }
    end,
  }
  list[#list + 1] = {
    name = "host-stub-list-anchors-50",
    iterations = RELAYOUT_ITERATIONS,
    operation = "the fake client alone: anchor 50 frames as this library's List layout does,"
      .. " read their heights",
    equivalent = false,
    note = "host stub cost, not a library cost: each anchor to the frame above (AceGUI) or"
      .. " to the content (WidgetKit); the stub checks anchor cycles by walking the chain in Lua",
    prepare = function()
      local createFrame = host.Global("CreateFrame")
      local content = createFrame("Frame", nil, host.Global("UIParent"))
      content:SetPoint("TOPLEFT", host.Global("UIParent"), "TOPLEFT", 0, 0)
      content:SetWidth(GROUP_WIDTH)
      local frames = {}
      for index = 1, 50 do
        frames[index] = createFrame("Frame", nil, content)
        frames[index]:SetHeight(12)
      end
      return {
        run = function(iterations)
          local anchor = adapter.stubListAnchor
          for _ = 1, iterations do
            for index = 1, 50 do
              anchor(frames, index, content)
            end
          end
        end,
      }
    end,
  }
  return list
end

---The correctness checks, the same on both sides.
---@param adapter table
---@param host table
---@return table[]
local function checks(adapter, host)
  local results = {}

  local first = adapter.create("label")
  adapter.release(first)
  local before = frameCount(host)
  local second = adapter.create("label")
  results[#results + 1] = {
    name = "pool-reuses-widget",
    passed = second == first and frameCount(host) == before,
    detail = "same widget after release: "
      .. tostring(second == first)
      .. ", frames created: "
      .. (frameCount(host) - before),
    promised = true,
  }

  local called = 0
  second:SetCallback("OnClick", function()
    called = called + 1
  end)
  second:SetUserData("key", "value")
  second:SetText("A text that must not survive")
  adapter.release(second)
  local reused = adapter.create("label")
  reused:Fire("OnClick")
  local text = adapter.labelText(reused)
  local textCleared = text == nil or text == ""
  results[#results + 1] = {
    name = "released-widget-clean",
    passed = reused == second and called == 0 and reused:GetUserData("key") == nil and textCleared,
    detail = "callback ran: "
      .. called
      .. ", user data: "
      .. tostring(reused:GetUserData("key"))
      .. ", text cleared: "
      .. tostring(textCleared),
    promised = true,
  }
  adapter.release(reused)

  local doubled = adapter.create("button")
  adapter.release(doubled)
  local refused = not pcall(adapter.release, doubled)
  results[#results + 1] = {
    name = "double-release-refused",
    passed = refused,
    detail = "releasing a released widget raised: " .. tostring(refused),
    promised = true,
  }

  local group = adapter.create("group")
  group:SetWidth(GROUP_WIDTH)
  group:SetPoint("TOPLEFT", host.Global("UIParent"), "TOPLEFT", 0, 0)
  group:PauseLayout()
  local released = {}
  for index = 1, 5 do
    local label = adapter.create("label")
    label:SetText("Line " .. index)
    label:SetFullWidth(true)
    label:SetCallback("OnRelease", function()
      released[#released + 1] = index
    end)
    group:AddChild(label)
  end
  group:ResumeLayout()
  adapter.layout(group)
  local stacked = true
  local children = adapter.children(group)
  for index = 2, #children do
    local above, below = children[index - 1].frame, children[index].frame
    local top, bottom = below:GetTop(), above:GetBottom()
    if top == nil or bottom == nil or top > bottom + 0.001 then
      stacked = false
    end
  end
  results[#results + 1] = {
    name = "list-layout-in-order",
    passed = stacked and #children == 5,
    detail = "5 labels stacked top to bottom in the order added: " .. tostring(stacked),
    promised = true,
  }
  adapter.release(group)
  local lastFirst = table.concat(released, " ") == "5 4 3 2 1"
  results[#results + 1] = {
    name = "children-released-last-first",
    passed = lastFirst,
    detail = "release order of 5 children: " .. table.concat(released, " "),
    promised = adapter.promisesReleaseOrder == true,
  }

  local held, acquired = {}, 0
  for index = 1, UNRELEASED_PROBE do
    local ok, widget = pcall(adapter.create, "button")
    if ok and widget ~= nil then
      acquired = acquired + 1
      held[index] = widget
    end
  end
  local bounded = acquired < UNRELEASED_PROBE
  results[#results + 1] = {
    name = "pool-bounded",
    passed = bounded,
    detail = "buttons acquired of " .. UNRELEASED_PROBE .. " asked, none released: " .. acquired,
    promised = adapter.promisesBound == true,
  }
  for index = 1, UNRELEASED_PROBE do
    if held[index] ~= nil then
      adapter.release(held[index])
    end
  end

  return results
end

---Build the workload for one side.
---@param side string `"moltencodes"` or `"ace3"`
---@param host table
---@param settings table
---@return table suite `{ cases, checks, libraries }`
function Widgets.Build(side, host, settings)
  installScreen(host)
  local adapter, libraries
  if side == "moltencodes" then
    adapter, libraries = kitAdapter(host)
    -- WidgetKit documents both: children released last first, and at most
    -- 256 frames per type (`packages/widgetKit/docs/API.md`).
    adapter.promisesReleaseOrder = true
    adapter.promisesBound = true
  else
    adapter, libraries = aceAdapter(host, settings.ace3)
  end

  return {
    libraries = libraries,
    cases = cases(adapter, host),
    checks = function()
      return checks(adapter, host)
    end,
  }
end

return Widgets
