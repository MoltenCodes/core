local TestEnv = require("CommandKitTestEnv")

-- `BindOptions(tree, name, { syntax = "path" })`: AceConfigCmd-3.0's
-- `/cmd group option value` (docs/API.md, "The path syntax"), `onEmpty`,
-- `GetBoundTree`, and completion of the path words.

describe("CommandKit path syntax", function()
  local CommandKit, OptionsKit, tree, scope, sink, values, executed, opened

  before_each(function()
    CommandKit, _, _, _, OptionsKit = TestEnv.NewPackage()
    values = {
      enabled = true,
      scale = 1,
      anchor = "CENTER",
      barWidth = 100,
      label = "Main",
      hiddenFlag = false,
      locked = false,
    }
    executed = {}
    opened = 0
    local function getter(info)
      return values[info[#info]]
    end
    local function setter(info, value)
      values[info[#info]] = value
    end
    tree = OptionsKit:Define("MyAddon", {
      type = "group",
      args = {
        enabled = { type = "toggle", name = "Enabled", order = 1, get = getter, set = setter },
        frame = {
          type = "group",
          name = "Frame",
          order = 2,
          args = {
            scale = {
              type = "range",
              name = "Scale",
              min = 0.5,
              max = 2,
              order = 1,
              get = getter,
              set = setter,
            },
            anchor = {
              type = "select",
              name = "Anchor",
              order = 2,
              values = { TOP = "Top", CENTER = "Centre" },
              sorting = { "TOP", "CENTER" },
              get = getter,
              set = setter,
            },
            barWidth = {
              type = "range",
              name = "Bar width",
              min = 10,
              max = 500,
              order = 3,
              get = getter,
              set = setter,
            },
          },
        },
        label = { type = "input", name = "Label", order = 3, get = getter, set = setter },
        locked = {
          type = "toggle",
          name = "Locked",
          order = 4,
          disabled = true,
          get = getter,
          set = setter,
        },
        hiddenFlag = {
          type = "toggle",
          name = "Hidden",
          order = 5,
          hidden = true,
          get = getter,
          set = setter,
        },
        wipe = {
          type = "execute",
          name = "Wipe",
          order = 6,
          confirm = "Really wipe everything?",
          func = function()
            executed[#executed + 1] = "wipe"
          end,
        },
        list = { type = "toggle", name = "List mode", order = 7, get = getter, set = setter },
      },
    })
    scope = CommandKit:ForAddon("MyAddon")
    sink = CommandKit:CaptureSink()
    scope:SetSink(sink)
    assert.is_true(scope:BindOptions(tree, "cfg", {
      syntax = "path",
      onEmpty = function()
        opened = opened + 1
      end,
    }))
  end)

  after_each(TestEnv.Reset)

  local function run(line)
    sink:Clear()
    TestEnv.RunSlash(line)
    return sink:Messages()
  end

  it("sets and reads options by group and key, without case", function()
    assert.are.same({ "frame.scale = 1.5" }, run("/cfg frame scale 1.5"))
    assert.are.same({ "frame.scale = 1.5" }, run("/cfg FRAME Scale"))
    assert.are.same({ "frame.anchor = TOP (Top)" }, run("/cfg frame anchor top"))
    assert.are.same({ "label = two words" }, run("/cfg label two words"))
    assert.are.same({ "frame.barWidth = 250" }, run("/cfg frame BARWIDTH 250"))
    assert.are.same({ "frame.scale = 0.75" }, run("/cfg frame.scale 0.75"))
  end)

  it("flips a toggle without a value and sets it with one", function()
    assert.are.same({ "enabled = off" }, run("/cfg enabled"))
    assert.are.same({ "enabled = on" }, run("/cfg enabled"))
    assert.are.same({ "enabled = off" }, run("/cfg enabled off"))
  end)

  it("lists a group, runs onEmpty for an empty line and lists the root without it", function()
    local listed = run("/cfg frame")
    assert.are.equal("frame.scale = 1 - Scale", listed[1])
    assert.are.equal(3, #listed)
    run("/cfg")
    assert.are.equal(1, opened)

    local plain = CommandKit:CreateScope()
    plain:SetSink(sink)
    plain:BindOptions(tree, "plaincfg", { syntax = "path" })
    local root = run("/plaincfg")
    assert.are.equal("enabled = on - Enabled", root[1])
    assert.are.equal("frame - Frame (group)", root[2])
  end)

  it("runs a button and asks first when it wants confirmation", function()
    assert.are.same({
      "Really wipe everything?",
      "Type /cfg wipe confirm to run it.",
    }, run("/cfg wipe"))
    assert.are.same({}, executed)
    run("/cfg wipe confirm")
    assert.are.same({ "wipe" }, executed)
  end)

  it("refuses unknown, hidden and disabled options with a message", function()
    assert.are.same({ '/cfg: unknown option "nope"' }, { run("/cfg nope")[1] })
    assert.are.same({ '/cfg: unknown option "nope" in "frame"' }, run("/cfg frame nope"))
    assert.are.same({ '/cfg: unknown option "hiddenFlag"' }, run("/cfg hiddenflag on"))
    assert.are.same({ '/cfg: "locked" is disabled' }, run("/cfg locked on"))
  end)

  it("builds its path index once per binding and drops it when the tree changes shape", function()
    -- Own fields on the tree handle shadow the prototype's methods, so the
    -- walks are counted and the structure listener is caught.
    local walks = 0
    local walk = OptionsKit.Tree.Walk
    local listeners = {}
    rawset(tree, "Walk", function(self, visitor)
      walks = walks + 1
      return walk(self, visitor)
    end)
    rawset(tree, "OnStructureChanged", function(_, listener)
      listeners[#listeners + 1] = listener
      return {}
    end)
    local counted = CommandKit:CreateScope()
    counted:SetSink(sink)
    counted:BindOptions(tree, "countcfg", { syntax = "path" })

    run("/countcfg frame scale 1.25")
    run("/countcfg enabled off")
    assert.are.equal(1, walks)
    assert.are.equal(1, #listeners)
    listeners[1]()
    assert.are.same({ "frame.scale = 1.25" }, run("/countcfg frame scale"))
    assert.are.equal(2, walks)
    assert.are.equal(1, #listeners)
  end)

  it("keeps the verbs, which take a root option named like a verb", function()
    assert.are.same({ "frame.scale = 2" }, run("/cfg set frame.scale 2"))
    assert.are.same({ "list = on" }, run("/cfg set list on"))
    assert.are.same({ "frame.scale = 2" }, run("/cfg get frame.scale"))
  end)

  it("remembers the bound tree until the command goes", function()
    assert.are.equal(tree, scope:GetBoundTree("CFG"))
    assert.is_nil(scope:GetBoundTree("other"))
    scope:Unregister("cfg")
    assert.is_nil(scope:GetBoundTree("cfg"))
  end)

  it("completes group keys, option keys and values", function()
    scope:EnableCompletion()
    local function press(text)
      local editBox = TestEnv.NewEditBox(text)
      TestEnv.PressTab(editBox)
      return editBox.text
    end

    assert.are.equal("/cfg frame ", press("/cfg fr"))
    assert.are.equal("/cfg frame scale ", press("/cfg frame sc"))
    assert.are.equal("/cfg frame barWidth ", press("/cfg frame ba"))
    assert.are.equal("/cfg frame anchor TOP ", press("/cfg frame anchor T"))
    assert.are.equal("/cfg enabled off ", press("/cfg enabled of"))
    assert.are.equal("/cfg nope x", press("/cfg nope x"))
  end)

  it("checks its options at the caller", function()
    TestEnv.expectErrorContaining('options.syntax must be "verbs" or "path"', function()
      scope:BindOptions(tree, "bad", { syntax = "slash" })
    end)
    TestEnv.expectErrorContaining("options.onEmpty must be a function", function()
      scope:BindOptions(tree, "bad", { onEmpty = "open" })
    end)
  end)
end)

describe("CommandKit verbs with onEmpty", function()
  after_each(TestEnv.Reset)

  it("runs onEmpty for an empty line and refuses an unknown verb", function()
    local CommandKit, _, _, _, OptionsKit = TestEnv.NewPackage()
    local tree = OptionsKit:Define("MyAddon", {
      type = "group",
      args = {
        size = {
          type = "range",
          name = "Size",
          min = 1,
          max = 9,
          get = function()
            return 3
          end,
          set = function() end,
        },
      },
    })
    local scope = CommandKit:CreateScope()
    local sink = CommandKit:CaptureSink()
    scope:SetSink(sink)
    local opened = 0
    scope:BindOptions(tree, "verbcfg", {
      onEmpty = function()
        opened = opened + 1
      end,
    })

    TestEnv.RunSlash("/verbcfg")
    TestEnv.RunSlash("/verbcfg size")
    TestEnv.RunSlash("/verbcfg get size")

    assert.are.equal(1, opened)
    assert.are.equal('/verbcfg: unknown sub-command "size"', sink:Messages()[1])
    assert.are.equal("size = 3", sink:Messages()[#sink:Messages()])
  end)
end)
