local TestEnv = require("LocaleKitTestEnv")

local SOURCE = debug.getinfo(1, "S").short_src

---Return the line number of the statement that called this helper.
---@return integer line
local function currentLine()
  return debug.getinfo(2, "l").currentline
end

---Assert that `action` fails with `message` reported at `expectedLine` of this
---spec file. A wrong `error` level shows up either as a different line number
---or as a message with no `file:line` prefix at all.
---@param expectedLine integer
---@param message string
---@param ok boolean
---@param value any
local function assertReportedAt(expectedLine, message, ok, value)
  assert.is_false(ok)
  assert.are.equal(SOURCE .. ":" .. expectedLine .. ": " .. message, value)
end

describe("LocaleKit error levels", function()
  local LocaleKit
  before_each(function()
    LocaleKit = TestEnv.NewPackage("deDE")
  end)
  after_each(TestEnv.Reset)

  it("points NewLocale argument errors at the caller", function()
    local nameLine
    local nameOk, nameValue = pcall(function()
      nameLine = currentLine() + 1
      LocaleKit:NewLocale(nil, "deDE")
    end)
    assertReportedAt(
      nameLine,
      "LocaleKit:NewLocale addonName must be a non-empty string",
      nameOk,
      nameValue
    )

    local localeLine
    local localeOk, localeValue = pcall(function()
      localeLine = currentLine() + 1
      LocaleKit:NewLocale("MyAddon", "de")
    end)
    assertReportedAt(
      localeLine,
      'LocaleKit:NewLocale locale must be a client locale code such as "deDE"',
      localeOk,
      localeValue
    )

    local optionLine
    local optionOk, optionValue = pcall(function()
      optionLine = currentLine() + 1
      LocaleKit:NewLocale("MyAddon", "deDE", { zzz = true, aaa = true })
    end)
    assertReportedAt(
      optionLine,
      'LocaleKit:NewLocale options contains unknown field "aaa"',
      optionOk,
      optionValue
    )

    local flagLine
    local flagOk, flagValue = pcall(function()
      flagLine = currentLine() + 1
      LocaleKit:NewLocale("MyAddon", "deDE", { isDefault = "yes" })
    end)
    assertReportedAt(flagLine, "LocaleKit:NewLocale isDefault must be a boolean", flagOk, flagValue)

    LocaleKit:NewLocale("MyAddon", "enUS", { isDefault = true })
    local defaultLine
    local defaultOk, defaultValue = pcall(function()
      defaultLine = currentLine() + 1
      LocaleKit:NewLocale("MyAddon", "frFR", { isDefault = true })
    end)
    assertReportedAt(
      defaultLine,
      "LocaleKit:NewLocale MyAddon already has default locale enUS",
      defaultOk,
      defaultValue
    )
  end)

  it("points write-proxy errors at the assignment", function()
    local translated = LocaleKit:NewLocale("MyAddon", "deDE")
    local default = LocaleKit:NewLocale("MyAddon", "enUS", { isDefault = true })

    local keyLine
    local keyOk, keyValue = pcall(function()
      keyLine = currentLine() + 1
      translated[1] = "one"
    end)
    assertReportedAt(
      keyLine,
      "LocaleKit translation key must be a non-empty string",
      keyOk,
      keyValue
    )

    local valueLine
    local valueOk, valueValue = pcall(function()
      valueLine = currentLine() + 1
      default["Key"] = 42
    end)
    assertReportedAt(
      valueLine,
      'LocaleKit translation "Key" must be a string or true',
      valueOk,
      valueValue
    )
  end)

  it("points GetLocale errors at the caller", function()
    local unknownLine
    local unknownOk, unknownValue = pcall(function()
      unknownLine = currentLine() + 1
      LocaleKit:GetLocale("Nobody")
    end)
    assertReportedAt(
      unknownLine,
      "LocaleKit:GetLocale found no locale registered for Nobody; load its translation files first",
      unknownOk,
      unknownValue
    )

    LocaleKit:NewLocale("MyAddon", "deDE")
    local modeLine
    local modeOk, modeValue = pcall(function()
      modeLine = currentLine() + 1
      LocaleKit:GetLocale("MyAddon", { missing = "loud" })
    end)
    assertReportedAt(
      modeLine,
      'LocaleKit:GetLocale missing must be "report", "silent" or "raw"',
      modeOk,
      modeValue
    )

    LocaleKit:GetLocale("MyAddon", { missing = "raw" })
    local fixedLine
    local fixedOk, fixedValue = pcall(function()
      fixedLine = currentLine() + 1
      LocaleKit:GetLocale("MyAddon", { missing = "silent" })
    end)
    assertReportedAt(
      fixedLine,
      'LocaleKit:GetLocale MyAddon already uses missing mode "raw", not "silent"',
      fixedOk,
      fixedValue
    )

    local optionsLine
    local optionsOk, optionsValue = pcall(function()
      optionsLine = currentLine() + 1
      LocaleKit:GetLocale("MyAddon", "raw")
    end)
    assertReportedAt(
      optionsLine,
      "LocaleKit:GetLocale options must be a table",
      optionsOk,
      optionsValue
    )
  end)

  it("points MissingKeys and SetLocaleOverride errors at the caller", function()
    local missingLine
    local missingOk, missingValue = pcall(function()
      missingLine = currentLine() + 1
      LocaleKit:MissingKeys("")
    end)
    assertReportedAt(
      missingLine,
      "LocaleKit:MissingKeys addonName must be a non-empty string",
      missingOk,
      missingValue
    )

    local overrideLine
    local overrideOk, overrideValue = pcall(function()
      overrideLine = currentLine() + 1
      LocaleKit:SetLocaleOverride(1)
    end)
    assertReportedAt(
      overrideLine,
      'LocaleKit:SetLocaleOverride locale must be a client locale code such as "deDE"',
      overrideOk,
      overrideValue
    )
  end)

  it("points Format errors at the caller, including those found inside the template", function()
    local templateLine
    local templateOk, templateValue = pcall(function()
      templateLine = currentLine() + 1
      LocaleKit:Format(1)
    end)
    assertReportedAt(
      templateLine,
      "LocaleKit:Format template must be a string",
      templateOk,
      templateValue
    )

    local indexLine
    local indexOk, indexValue = pcall(function()
      indexLine = currentLine() + 1
      LocaleKit:Format("%1$s and %2$s", "only")
    end)
    assertReportedAt(
      indexLine,
      "LocaleKit:Format template needs argument 2 but 1 were given",
      indexOk,
      indexValue
    )

    local typeLine
    local typeOk, typeValue = pcall(function()
      typeLine = currentLine() + 1
      LocaleKit:Format("%d", true)
    end)
    assertReportedAt(
      typeLine,
      "LocaleKit:Format argument 1 must be a number, got boolean",
      typeOk,
      typeValue
    )

    local specifierLine
    local specifierOk, specifierValue = pcall(function()
      specifierLine = currentLine() + 1
      LocaleKit:Format("%q", "x")
    end)
    assertReportedAt(
      specifierLine,
      'LocaleKit:Format template has an unsupported specifier "%q"',
      specifierOk,
      specifierValue
    )
  end)
end)
