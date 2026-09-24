local TestEnv = require("LocaleKitTestEnv")

describe("LocaleKit:Format", function()
  local LocaleKit
  before_each(function()
    LocaleKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("formats sequential %s, %d and %.2f like string.format", function()
    assert.are.equal(
      "Alice has 3 items worth 1.50 gold",
      LocaleKit:Format("%s has %d items worth %.2f gold", "Alice", 3, 1.5)
    )
  end)

  it("passes flags and width through", function()
    assert.are.equal("[  7|7  |007|+1.0]", LocaleKit:Format("[%3d|%-3d|%03d|%+.1f]", 7, 7, 7, 1))
  end)

  it("reorders indexed arguments", function()
    assert.are.equal(
      "3 Gegenstände hat Alice",
      LocaleKit:Format("%2$d Gegenstände hat %1$s", "Alice", 3)
    )
  end)

  it("repeats an indexed argument", function()
    assert.are.equal("Bob, Bob, Bob!", LocaleKit:Format("%1$s, %1$s, %1$s!", "Bob"))
  end)

  it("applies precision to an indexed argument", function()
    assert.are.equal("2.50 / 1", LocaleKit:Format("%2$.2f / %1$d", 1, 2.5))
  end)

  it("takes unindexed arguments in order, independently of indexed ones", function()
    assert.are.equal("a b a", LocaleKit:Format("%s %2$s %1$s", "a", "b"))
  end)

  it("turns %% into a percent sign", function()
    assert.are.equal("50% of 10", LocaleKit:Format("%d%% of %d", 50, 10))
  end)

  it("formats a number with %s", function()
    assert.are.equal("12", LocaleKit:Format("%s", 12))
  end)

  it("returns a template without specifiers unchanged", function()
    assert.are.equal("plain", LocaleKit:Format("plain"))
    assert.are.equal("plain", LocaleKit:Format("plain", "ignored"))
  end)

  it("raises for an index beyond the arguments", function()
    TestEnv.expectErrorContaining(
      "LocaleKit:Format template needs argument 3 but 2 were given",
      function()
        LocaleKit:Format("%3$s", "a", "b")
      end
    )
    TestEnv.expectErrorContaining(
      "LocaleKit:Format template needs argument 2 but 1 were given",
      function()
        LocaleKit:Format("%s %s", "a")
      end
    )
  end)

  it("raises for index zero", function()
    TestEnv.expectErrorContaining("argument indexes start at 1", function()
      LocaleKit:Format("%0$s", "a")
    end)
  end)

  it("raises for an unsupported or truncated specifier", function()
    TestEnv.expectErrorContaining('unsupported specifier "%x"', function()
      LocaleKit:Format("%x", 1)
    end)
    TestEnv.expectErrorContaining('unsupported specifier "%"', function()
      LocaleKit:Format("100%", 1)
    end)
  end)

  it("raises for an argument of the wrong type", function()
    TestEnv.expectErrorContaining("argument 1 must be a number, got string", function()
      LocaleKit:Format("%d", "3")
    end)
    TestEnv.expectErrorContaining("argument 2 must be a string or a number, got nil", function()
      LocaleKit:Format("%s %s", "a", nil)
    end)
    TestEnv.expectErrorContaining("argument 1 must be a string or a number, got table", function()
      LocaleKit:Format("%1$s", {})
    end)
  end)

  it("retains no argument after a call, whether it succeeded or raised", function()
    local tracker = setmetatable({}, { __mode = "k" })
    ---Format one fresh table argument in a scope of its own, so the only
    ---reference left afterwards would be one LocaleKit kept.
    ---@param template string
    local function formatFreshTable(template)
      local argument = {}
      tracker[argument] = true
      pcall(LocaleKit.Format, LocaleKit, template, argument)
    end
    formatFreshTable("%s")
    formatFreshTable("%d")
    collectgarbage()
    collectgarbage()
    assert.is_nil(next(tracker))
  end)

  it("is usable again after a failure", function()
    pcall(LocaleKit.Format, LocaleKit, "%s %s", "a")
    assert.are.equal("x", LocaleKit:Format("%s", "x"))
  end)

  it("refuses a template that is not a string", function()
    TestEnv.expectErrorContaining("LocaleKit:Format template must be a string", function()
      LocaleKit:Format(nil)
    end)
  end)

  it("reports a width or precision string.format refuses, and clears the arguments", function()
    TestEnv.expectErrorContaining(
      'LocaleKit:Format template has an invalid specifier "%100s"',
      function()
        LocaleKit:Format("%100s", "x")
      end
    )
    TestEnv.expectErrorContaining(
      'LocaleKit:Format template has an invalid specifier "%1$.100f"',
      function()
        LocaleKit:Format("%1$.100f", 1)
      end
    )
  end)

  it("reports repeated flags, and clears the arguments", function()
    TestEnv.expectErrorContaining(
      'LocaleKit:Format template has an invalid specifier "%------5s"',
      function()
        LocaleKit:Format("%------5s", "x")
      end
    )
  end)

  it("retains no argument after string.format refuses a specifier", function()
    local tracker = setmetatable({}, { __mode = "k" })
    ---Stage an unused table argument behind a refused specifier.
    ---@param template string
    local function formatWithUnusedTable(template)
      local unused = {}
      tracker[unused] = true
      local ok = pcall(LocaleKit.Format, LocaleKit, template, "x", unused)
      assert.is_false(ok)
    end
    formatWithUnusedTable("%100s")
    formatWithUnusedTable("%------5s")
    collectgarbage()
    collectgarbage()
    assert.is_nil(next(tracker))
    assert.are.equal("ok", LocaleKit:Format("%s", "ok"))
  end)
end)
