local TestEnv = require("OptionsKitTestEnv")

describe("OptionsKit tree Get, Set, Validate and Execute", function()
  local OptionsKit
  local store
  local calls
  local tree

  before_each(function()
    OptionsKit = TestEnv.NewPackage()
    store = { scale = 1, name = "one" }
    calls = {}
    tree = OptionsKit:Define("Addon", {
      type = "group",
      args = {
        frame = {
          type = "group",
          name = "Frame",
          args = {
            scale = {
              type = "range",
              name = "Scale",
              min = 0.5,
              max = 2,
              get = function(info)
                calls[#calls + 1] = { "get", info }
                return store.scale
              end,
              set = function(info, value)
                calls[#calls + 1] = { "set", info, value }
                store.scale = value
              end,
              validate = function(info, value)
                calls[#calls + 1] = { "validate", info, value }
                if value == 1.5 then
                  return false, "1.5 is reserved"
                end
                return true
              end,
            },
            name = {
              type = "input",
              name = "Name",
              hidden = true,
              disabled = function()
                return true
              end,
              get = function()
                return store.name
              end,
              set = function(_, value)
                store.name = value
              end,
              validate = function()
                return false
              end,
            },
            reset = {
              type = "execute",
              name = "Reset",
              func = function(info)
                calls[#calls + 1] = { "func", info }
              end,
            },
          },
        },
      },
    })
    tree:OnChange(function(_, path, value)
      calls[#calls + 1] = { "changed", path, value }
    end)
  end)
  after_each(TestEnv.Reset)

  it("reads through the getter with the option's info", function()
    assert.are.equal(1, tree:Get("frame.scale"))
    local info = calls[1][2]
    assert.are.equal("frame", info[1])
    assert.are.equal("scale", info[2])
    assert.are.equal(2, #info)
    assert.are.equal("frame.scale", info.path)
    assert.are.equal("range", info.kind)
    assert.are.equal(tree, info.tree)
  end)

  it("hands every call for one option the same info table", function()
    tree:Get("frame.scale")
    tree:Set("frame.scale", 2)
    local first = calls[1][2]
    for index = 2, #calls - 1 do
      assert.are.equal(first, calls[index][2])
    end
  end)

  it("checks the schema, then validate, then sets, then fires OnChange", function()
    assert.are.same({ true }, { tree:Set("frame.scale", 2) })
    assert.are.equal(2, store.scale)
    assert.are.equal("validate", calls[1][1])
    assert.are.equal("set", calls[2][1])
    assert.are.equal(2, calls[2][3])
    assert.are.same({ "changed", "frame.scale", 2 }, calls[3])
    assert.are.equal(3, #calls)
  end)

  it("stops before validate when the schema refuses", function()
    TestEnv.expectErrorContaining(
      "OptionsKit.Tree:Set frame.scale: expected number <= 2",
      function()
        tree:Set("frame.scale", 3)
      end
    )
    assert.are.equal(0, #calls)
    assert.are.equal(1, store.scale)
  end)

  it("returns false and validate's message when validate refuses, writing nothing", function()
    assert.are.same({ false, "1.5 is reserved" }, { tree:Set("frame.scale", 1.5) })
    assert.are.equal(1, store.scale)
    assert.are.equal(1, #calls)
    assert.are.same({ false, "1.5 is reserved" }, { tree:Validate("frame.scale", 1.5) })
  end)

  it("supplies a message when validate refuses without one", function()
    assert.are.same({ false, "refused by validate" }, { tree:Set("frame.name", "two") })
    assert.are.equal("one", store.name)
  end)

  it("Validate checks without writing or firing", function()
    assert.are.same({ true }, { tree:Validate("frame.scale", 2) })
    local valid, message = tree:Validate("frame.scale", "big")
    assert.is_false(valid)
    assert.are.equal("expected number, found string", message)
    assert.are.equal(1, store.scale)
    for index = 1, #calls do
      assert.are_not.equal("changed", calls[index][1])
    end
  end)

  it("writes hidden and disabled options: hiding is a renderer's concern", function()
    assert.is_true(tree:IsHidden("frame.name"))
    assert.is_true(tree:IsDisabled("frame.name"))
    assert.are.equal("one", tree:Get("frame.name"))
    -- The validate of this option refuses everything, so replace it with
    -- a tree whose hidden, disabled option has no validate.
    OptionsKit:Undefine("Addon")
    tree = OptionsKit:Define("Addon", {
      type = "group",
      args = {
        name = {
          type = "input",
          name = "Name",
          hidden = true,
          disabled = true,
          get = function()
            return store.name
          end,
          set = function(_, value)
            store.name = value
          end,
        },
      },
    })
    assert.is_true(tree:Set("name", "two"))
    assert.are.equal("two", store.name)
  end)

  it("runs an execute option's func with its info", function()
    tree:Execute("frame.reset")
    assert.are.equal("func", calls[1][1])
    assert.are.equal("frame.reset", calls[1][2].path)
    TestEnv.expectErrorContaining(
      'OptionsKit.Tree:Execute path "frame.scale" is not an execute option',
      function()
        tree:Execute("frame.scale")
      end
    )
  end)

  it("refuses unknown and malformed paths", function()
    TestEnv.expectErrorContaining('OptionsKit.Tree:Get unknown path "frame.missing"', function()
      tree:Get("frame.missing")
    end)
    TestEnv.expectErrorContaining('OptionsKit.Tree:Set unknown path "scale"', function()
      tree:Set("scale", 1)
    end)
    TestEnv.expectErrorContaining('OptionsKit.Tree:Get unknown path ""', function()
      tree:Get("")
    end)
    TestEnv.expectErrorContaining("OptionsKit.Tree:Get path must be a string", function()
      tree:Get({ "frame", "scale" })
    end)
  end)

  it("does not check what a getter returns", function()
    store.scale = "not a number"
    assert.are.equal("not a number", tree:Get("frame.scale"))
  end)
end)
