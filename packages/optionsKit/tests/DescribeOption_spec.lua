local TestEnv = require("OptionsKitTestEnv")

---A tree with a group of a range, a select over a table and a toggle, and a
---top-level select over a values function. Every getter, `desc` function and
---values function counts its calls in `calls`, by option key.
---@param store table
---@param calls table<string, integer>
---@return table spec
local function countingTree(store, calls)
  local function count(key)
    calls[key] = (calls[key] or 0) + 1
  end
  return {
    type = "group",
    name = "Counting",
    args = {
      display = {
        type = "group",
        name = "Display",
        desc = function()
          count("displayDesc")
          return "Display settings"
        end,
        args = {
          scale = {
            type = "range",
            name = "Scale",
            min = 0.5,
            max = 2,
            step = 0.05,
            desc = function()
              count("scaleDesc")
              return "Frame scale"
            end,
            get = function()
              count("scale")
              return store.scale
            end,
            set = function(_, value)
              store.scale = value
            end,
          },
          anchor = {
            type = "select",
            name = "Anchor",
            values = { TOP = "Top", BOTTOM = "Bottom" },
            sorting = { "TOP", "BOTTOM" },
            get = function()
              count("anchor")
              return store.anchor
            end,
            set = function(_, value)
              store.anchor = value
            end,
          },
          locked = {
            type = "toggle",
            name = "Locked",
            disabled = true,
            get = function()
              count("locked")
              return store.locked
            end,
            set = function(_, value)
              store.locked = value
            end,
          },
        },
      },
      channel = {
        type = "select",
        name = "Channel",
        hidden = true,
        values = function()
          count("channelValues")
          return { SAY = "Say", GUILD = "Guild" }
        end,
        get = function()
          count("channel")
          return store.channel
        end,
        set = function(_, value)
          store.channel = value
        end,
      },
    },
  }
end

---The node of `description` at `path`, found by walking the children.
---@param description table
---@param path string
---@return table|nil
local function findNode(description, path)
  if description.path == path then
    return description
  end
  for _, child in ipairs(description.children or {}) do
    local found = findNode(child, path)
    if found ~= nil then
      return found
    end
  end
  return nil
end

describe("OptionsKit tree DescribeOption", function()
  local OptionsKit
  local store
  local calls
  local tree

  before_each(function()
    OptionsKit = TestEnv.NewPackage()
    store = { scale = 1.25, anchor = "TOP", locked = false, channel = "SAY" }
    calls = {}
    tree = OptionsKit:Define("Addon", countingTree(store, calls))
  end)
  after_each(TestEnv.Reset)

  it("describes one option exactly as Describe describes it", function()
    local whole = tree:Describe()
    for _, path in ipairs({ "display", "display.scale", "display.anchor", "display.locked" }) do
      assert.are.same(findNode(whole, path), tree:DescribeOption(path))
    end
    assert.are.same(findNode(whole, "channel"), tree:DescribeOption("channel"))
  end)

  it("describes the root, with the addon name, for the empty path", function()
    assert.are.same(tree:Describe(), tree:DescribeOption(""))
    assert.are.equal("Addon", tree:DescribeOption("").addonName)
  end)

  it("runs only the callbacks of the option described", function()
    local node = tree:DescribeOption("display.scale")
    assert.are.equal(1.25, node.value)
    assert.are.equal("Frame scale", node.desc)
    assert.are.same({ scale = 1, scaleDesc = 1 }, calls)
  end)

  it("describes a group with everything below it and nothing beside it", function()
    local node = tree:DescribeOption("display")
    assert.are.equal(3, #node.children)
    assert.are.same({ displayDesc = 1, scale = 1, scaleDesc = 1, anchor = 1, locked = 1 }, calls)
  end)

  it("reports effective flags and fresh copies, as Describe does", function()
    local locked = tree:DescribeOption("display.locked")
    assert.is_true(locked.disabled)
    local channel = tree:DescribeOption("channel")
    assert.is_true(channel.hidden)
    assert.are.same({ SAY = "Say", GUILD = "Guild" }, channel.values)
    local anchor = tree:DescribeOption("display.anchor")
    anchor.values.TOP = "Changed"
    anchor.sorting[1] = "BOTTOM"
    local again = tree:DescribeOption("display.anchor")
    assert.are.equal("Top", again.values.TOP)
    assert.are.same({ "TOP", "BOTTOM" }, again.sorting)
  end)

  it("answers nil for a path the tree does not have", function()
    assert.is_nil(tree:DescribeOption("display.nosuch"))
    assert.is_nil(tree:DescribeOption("nosuch"))
    assert.are.same({}, calls)
  end)

  it("refuses a path that is not a string or is secret, at the caller", function()
    TestEnv.expectErrorContaining("OptionsKit.Tree:DescribeOption path must be a string", function()
      tree:DescribeOption(5)
    end)
    -- A table stands in for a secret: only the probe tells a secret apart.
    local secret = {}
    -- `issecretvalue` is the client's global probe.
    -- selene: allow(global_usage)
    rawset(_G, "issecretvalue", function(value)
      return rawequal(value, secret)
    end)
    local ok, message = pcall(tree.DescribeOption, tree, secret)
    -- selene: allow(global_usage)
    rawset(_G, "issecretvalue", nil)
    assert.is_false(ok)
    assert.is_truthy(
      tostring(message):find(
        "OptionsKit.Tree:DescribeOption path must not be a secret value",
        1,
        true
      )
    )
  end)

  it("names DescribeOption when a desc or values function answers wrongly", function()
    OptionsKit:Undefine("Addon")
    tree = OptionsKit:Define("Addon", {
      type = "group",
      args = {
        mode = {
          type = "select",
          name = "Mode",
          values = function()
            return "not a table"
          end,
          get = function() end,
          set = function() end,
        },
        note = {
          type = "description",
          name = "Note",
          desc = function()
            return 5
          end,
        },
      },
    })
    TestEnv.expectErrorContaining(
      'OptionsKit.Tree:DescribeOption values function of "mode" returned no table',
      function()
        tree:DescribeOption("mode")
      end
    )
    TestEnv.expectErrorContaining(
      'OptionsKit.Tree:DescribeOption desc function of "note" returned no string',
      function()
        tree:DescribeOption("note")
      end
    )
  end)

  it("is refused on an undefined tree", function()
    OptionsKit:Undefine("Addon")
    TestEnv.expectErrorContaining(
      "OptionsKit.Tree:DescribeOption cannot be called on an undefined tree",
      function()
        tree:DescribeOption("display")
      end
    )
  end)
end)

describe("OptionsKit Define sharing", function()
  local OptionsKit

  before_each(function()
    OptionsKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  ---The internal record at `path`: these specs pin what `Define` shares.
  ---@param tree table
  ---@param path string
  ---@return table
  local function recordAt(tree, path)
    return rawget(rawget(tree, "_records"), path)
  end

  local function noop() end

  ---A value option of `kind` with `fields` added.
  local function option(kind, fields)
    local spec = { type = kind, name = kind, get = noop, set = noop }
    for key, value in pairs(fields or {}) do
      spec[key] = value
    end
    return spec
  end

  it("shares one schema between options with the same kind and inputs", function()
    local values = { a = "A", b = "B" }
    local tree = OptionsKit:Define("Addon", {
      type = "group",
      args = {
        first = option("range", { min = 0, max = 10 }),
        second = option("range", { min = 0, max = 10 }),
        other = option("range", { min = 0, max = 5 }),
        onA = option("toggle"),
        onB = option("toggle"),
        maybe = option("toggle", { tristate = true }),
        pickA = option("select", { values = values }),
        pickB = option("select", { values = { b = "Bee", a = "Ay" } }),
        manyA = option("multiselect", { values = values }),
        textA = option("input", { pattern = "^%d+$" }),
        textB = option("input", { pattern = "^%d+$" }),
        plain = option("input"),
        key = option("keybinding"),
        tint = option("color"),
        tintAlpha = option("color", { hasAlpha = true }),
      },
    })
    local function schema(path)
      return rawget(recordAt(tree, path), "_schema")
    end
    assert.are.equal(schema("first"), schema("second"))
    assert.are_not.equal(schema("first"), schema("other"))
    assert.are.equal(schema("onA"), schema("onB"))
    assert.are_not.equal(schema("onA"), schema("maybe"))
    -- The keys decide, not the labels or the table.
    assert.are.equal(schema("pickA"), schema("pickB"))
    assert.are_not.equal(schema("pickA"), schema("manyA"))
    assert.are.equal(schema("textA"), schema("textB"))
    assert.are.equal(schema("plain"), schema("key"))
    assert.are_not.equal(schema("tint"), schema("tintAlpha"))

    -- A second tree reuses the schemas of the first.
    local again = OptionsKit:Define("Again", {
      type = "group",
      args = { scale = option("range", { min = 0, max = 10 }) },
    })
    assert.are.equal(schema("first"), rawget(recordAt(again, "scale"), "_schema"))
  end)

  it("keeps each shared schema's own checks", function()
    local tree = OptionsKit:Define("Addon", {
      type = "group",
      args = {
        small = option("range", { min = 0, max = 1 }),
        large = option("range", { min = 0, max = 100 }),
        pick = option("select", { values = { a = "A" } }),
        many = option("multiselect", { values = { a = "A", b = "B" } }),
        tintAlpha = option("color", { hasAlpha = true }),
      },
    })
    assert.is_false((tree:Validate("small", 5)))
    assert.is_true((tree:Validate("large", 5)))
    assert.is_false((tree:Validate("pick", "b")))
    assert.is_true((tree:Validate("many", { a = true, b = false })))
    assert.is_false((tree:Validate("many", { c = true })))
    assert.is_false((tree:Validate("tintAlpha", { r = 1, g = 1, b = 1 })))
  end)

  it("gives a select over a values function a schema of its own", function()
    local tree = OptionsKit:Define("Addon", {
      type = "group",
      args = {
        first = option("select", {
          values = function()
            return { a = "A" }
          end,
        }),
        second = option("select", {
          values = function()
            return { b = "B" }
          end,
        }),
      },
    })
    assert.are_not.equal(
      rawget(recordAt(tree, "first"), "_schema"),
      rawget(recordAt(tree, "second"), "_schema")
    )
    assert.is_true((tree:Validate("first", "a")))
    assert.is_false((tree:Validate("first", "b")))
    assert.is_true((tree:Validate("second", "b")))
  end)

  it("hands a values function the option's info when it checks a key", function()
    local seen
    local tree = OptionsKit:Define("Addon", {
      type = "group",
      args = {
        group = {
          type = "group",
          name = "Group",
          args = {
            mode = option("select", {
              values = function(info)
                seen = info
                return { a = "A" }
              end,
            }),
          },
        },
      },
    })
    assert.is_true((tree:Validate("group.mode", "a")))
    assert.are.equal("group.mode", seen.path)
    assert.are.equal("select", seen.kind)
    assert.are.equal(tree, seen.tree)
    assert.are.same({ "group", "mode" }, { seen[1], seen[2] })
  end)

  it("shares one copy of a values table between the options that name it", function()
    local values = { a = "A", b = "B" }
    local tree = OptionsKit:Define("Addon", {
      type = "group",
      args = {
        first = option("select", { values = values }),
        second = option("multiselect", { values = values }),
      },
    })
    local copy = rawget(recordAt(tree, "first"), "_values")
    assert.are_not.equal(values, copy)
    assert.are.equal(copy, rawget(recordAt(tree, "second"), "_values"))
    values.c = "C"
    assert.is_nil(tree:Describe().children[1].values.c)
    assert.is_false((tree:Validate("first", "c")))
  end)

  it("builds an option's info on first use and hands out the same table after", function()
    local infos = {}
    local tree = OptionsKit:Define("Addon", {
      type = "group",
      args = {
        group = {
          type = "group",
          name = "Group",
          args = {
            scale = option("range", {
              min = 0,
              max = 1,
              get = function(info)
                infos[#infos + 1] = info
                return 0.5
              end,
            }),
          },
        },
      },
    })
    local record = recordAt(tree, "group.scale")
    assert.is_nil(rawget(record, "_info"))
    tree:Get("group.scale")
    tree:Get("group.scale")
    assert.are.equal(infos[1], infos[2])
    assert.are.equal(infos[1], rawget(record, "_info"))
    local info = infos[1]
    assert.are.same({ "group", "scale" }, { info[1], info[2] })
    assert.is_nil(info[3])
    assert.are.equal("group.scale", info.path)
    assert.are.equal("range", info.kind)
    assert.are.equal(tree, info.tree)
  end)

  it("names the option in a Set refusal, as before, without a prebuilt label", function()
    local tree = OptionsKit:Define("Addon", {
      type = "group",
      args = { scale = option("range", { min = 0, max = 1 }) },
    })
    assert.is_nil(rawget(recordAt(tree, "scale"), "_setArgument"))
    TestEnv.expectErrorContaining(
      "OptionsKit.Tree:Set scale: expected number <= 1, found larger number",
      function()
        tree:Set("scale", 5)
      end
    )
  end)

  it("keeps a value record to the 16 hash slots its constructor sizes #allocation", function()
    local spec = {
      type = "group",
      args = {
        scale = option("range", { min = 0, max = 1 }),
        pick = option("select", { values = { a = "A" } }),
      },
    }
    OptionsKit:Define("Warm", spec)
    local names = {}
    for index = 1, 100 do
      names[index] = "Addon" .. index
    end
    local allocated = TestEnv.AllocatedKilobytes(function()
      for index = 1, 100 do
        OptionsKit:Define(names[index], spec)
      end
    end)
    -- Per tree: the tree, three records, the index, the walk, the children,
    -- the signal and the values copy, about 5 KiB. Revision 6 allocated
    -- 11.6 KiB here: records grown to 32 slots, an info table per option
    -- and a schema per value option.
    assert.is_true(allocated / 100 < 7, "one Define allocated " .. allocated / 100 .. " KiB")
  end)
end)
