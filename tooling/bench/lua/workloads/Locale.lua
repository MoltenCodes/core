--- Translations: LocaleKit against AceLocale-3.0.
---
--- LocaleKit keeps AceLocale's design (one read table per addon, default
--- strings with the client locale's on top, `L[key] = true` storing the key as
--- its own text, a missing key stored as itself on its first read), so most
--- rows compare the same work directly:
---
---   register          `NewLocale(addon, "enUS", { isDefault = true })`,
---                     100 writes and `GetLocale(addon)` against
---                     `NewLocale(addon, "enUS", true)`, 100 writes and
---                     `GetLocale(addon)`
---   unneeded locale   `NewLocale(addon, "frFR")` on an `enUS` client: `nil`
---   lookup            `L[key]` of a defined key: one table read on both
---   first miss        the first read of a key no file defined, in each
---                     library's silent mode, so that no error report is timed
---
--- Where the two differ in behaviour, the difference is a check rather than a
--- ratio: AceLocale shares one "table being filled" between every addon, keeps
--- every missing key it is asked for, and stores any value; LocaleKit hands out
--- one proxy per call, records at most 1024 missing keys per addon by default
--- and refuses a value that is not a string or `true`. For the `first-miss`
--- row LocaleKit's bound is opened (`maxMissingKeys = LocaleKit.UNBOUNDED`), so
--- both sides store every key they are asked for; LocaleKit also adds the key
--- to its `MissingKeys` record, which AceLocale does not keep.
---
--- `format` (LocaleKit's indexed `%2$s` specifiers) has no AceLocale
--- counterpart and is reported for LocaleKit alone.

local Bench = require("Bench")

local Locale = {}

--- Strings each registered addon defines, half as `true` and half as text.
local STRINGS = 100

--- Addons registered per `register` batch.
local REGISTER_ITERATIONS = 500

--- Lookups per timed batch.
local LOOKUP_ITERATIONS = 5000000

--- Unneeded `NewLocale` calls per timed batch.
local UNNEEDED_ITERATIONS = 200000

--- First reads of missing keys per timed batch.
local MISS_ITERATIONS = 20000

--- Formats per timed batch.
local FORMAT_ITERATIONS = 50000

--- Addons registered for the retained-memory measurement.
local RETAINED_PROBE = 50

--- Distinct missing keys read by the bound check.
local MISSING_PROBE = 2000

--- The keys every addon defines, the same strings on both sides.
local KEYS = {}
for index = 1, STRINGS do
  KEYS[index] = "Message number " .. index
end

---Fill a write proxy with the `STRINGS` keys.
---@param writer table
local function fill(writer)
  for index = 1, STRINGS do
    local key = KEYS[index]
    if index % 2 == 0 then
      writer[key] = true
    else
      writer[key] = "Translated text " .. index
    end
  end
end

---@param host table
---@return table adapter, table[] libraries
local function kitAdapter(host)
  local loaded = host.RequireAll({ "Registry", "LocaleKit" })
  local LocaleKit = loaded[2]
  local adapter = { side = "moltencodes" }
  local defaultOptions = { isDefault = true }

  ---The missing-key mode is fixed by `getLocale` on this side, so a mode
  ---passed here, as the Ace3 adapter needs it, is ignored.
  function adapter.newLocale(addonName, locale, isDefault)
    return LocaleKit:NewLocale(addonName, locale, isDefault and defaultOptions or nil)
  end

  function adapter.getLocale(addonName, mode, unbounded)
    if mode == nil and not unbounded then
      return LocaleKit:GetLocale(addonName)
    end
    return LocaleKit:GetLocale(addonName, {
      missing = mode,
      maxMissingKeys = unbounded and LocaleKit.UNBOUNDED or nil,
    })
  end

  function adapter.missingKeys(addonName)
    return LocaleKit:MissingKeys(addonName)
  end

  function adapter.format(template, ...)
    return LocaleKit:Format(template, ...)
  end

  return adapter, { { name = "LocaleKit", revision = LocaleKit.REVISION } }
end

---@param host table
---@param directory string the Ace3 checkout
---@return table adapter, table[] libraries
local function aceAdapter(host, directory)
  host.LoadFiles(directory, { "LibStub/LibStub.lua", "AceLocale-3.0/AceLocale-3.0.lua" })
  local AceLocale, minor = host.Global("LibStub"):GetLibrary("AceLocale-3.0")
  local adapter = { side = "ace3" }

  ---AceLocale fixes the missing-key mode at the first `NewLocale`.
  function adapter.newLocale(addonName, locale, isDefault, mode)
    return AceLocale:NewLocale(addonName, locale, isDefault, mode == "silent")
  end

  ---AceLocale has no bound to open; `mode` was fixed by `newLocale`.
  function adapter.getLocale(addonName)
    return AceLocale:GetLocale(addonName)
  end

  return adapter, { { name = "AceLocale-3.0", minor = minor } }
end

---@param adapter table
---@return Bench.Case[]
local function cases(adapter)
  local list = {
    {
      name = "register",
      iterations = REGISTER_ITERATIONS,
      operation = "register a default locale with 100 strings and get its read table",
      prepare = function()
        local names, nextIndex = nil, 1

        ---Register `count` fresh addons starting at `nextIndex`.
        local function registerFresh(count)
          for index = nextIndex, nextIndex + count - 1 do
            local name = "BenchAddon" .. index
            fill(adapter.newLocale(name, "enUS", true))
            adapter.getLocale(name)
          end
          nextIndex = nextIndex + count
        end

        return {
          beforeBatch = function(iterations)
            names = {}
            for index = 1, iterations do
              names[index] = "BenchAddon" .. (nextIndex + index - 1)
            end
            nextIndex = nextIndex + iterations
          end,
          run = function(iterations)
            local newLocale, getLocale = adapter.newLocale, adapter.getLocale
            for index = 1, iterations do
              local name = names[index]
              fill(newLocale(name, "enUS", true))
              getLocale(name)
            end
          end,
          -- What one registered addon of 100 strings keeps alive.
          metrics = function()
            names = nil
            local baseline = Bench.RetainedBytes()
            registerFresh(RETAINED_PROBE)
            return { retainedBytesPerAddon = (Bench.RetainedBytes() - baseline) / RETAINED_PROBE }
          end,
        }
      end,
    },
    {
      name = "unneeded-locale",
      iterations = UNNEEDED_ITERATIONS,
      operation = "ask for a locale the client does not need (frFR on enUS): nil",
      prepare = function()
        fill(adapter.newLocale("BenchUnneeded", "enUS", true))
        return {
          run = function(iterations)
            local newLocale = adapter.newLocale
            for _ = 1, iterations do
              newLocale("BenchUnneeded", "frFR")
            end
          end,
        }
      end,
    },
    {
      name = "lookup",
      iterations = LOOKUP_ITERATIONS,
      operation = "read a defined key from the read table (100 defined)",
      prepare = function()
        fill(adapter.newLocale("BenchLookup", "enUS", true))
        local strings = adapter.getLocale("BenchLookup")
        return {
          run = function(iterations)
            local slot = 0
            for _ = 1, iterations do
              slot = slot + 1
              if slot > STRINGS then
                slot = 1
              end
              local _ = strings[KEYS[slot]]
            end
          end,
        }
      end,
    },
    {
      name = "first-miss",
      iterations = MISS_ITERATIONS,
      operation = "first read of a key no file defined, silent mode (stored as itself)",
      note = "LocaleKit's missing-key bound is opened for this row, so both sides store every key",
      prepare = function()
        fill(adapter.newLocale("BenchMissing", "enUS", true, "silent"))
        local strings = adapter.getLocale("BenchMissing", "silent", true)
        local keys, nextIndex = nil, 1
        local returnedKey, asked = 0, 0
        return {
          beforeBatch = function(iterations)
            keys = {}
            for index = 1, iterations do
              keys[index] = "Missing key " .. (nextIndex + index - 1)
            end
            nextIndex = nextIndex + iterations
          end,
          run = function(iterations)
            for index = 1, iterations do
              local key = keys[index]
              if strings[key] == key then
                returnedKey = returnedKey + 1
              end
            end
            asked = asked + iterations
          end,
          metrics = function()
            return { returnedKeyPerMiss = returnedKey / asked }
          end,
        }
      end,
    },
  }

  if adapter.format ~= nil then
    list[#list + 1] = {
      name = "format",
      iterations = FORMAT_ITERATIONS,
      operation = 'LocaleKit:Format("%2$s has %1$d items", count, name)',
      note = "LocaleKit only: AceLocale has no formatter",
      prepare = function()
        local count = 0
        return {
          run = function(iterations)
            local format = adapter.format
            for _ = 1, iterations do
              count = count + 1
              format("%2$s has %1$d items", count, "Alice")
            end
          end,
        }
      end,
    }
  end
  return list
end

---@param adapter table
---@param host table
---@return table[] checks
local function checks(adapter, host)
  local results = {}
  local isKit = adapter.side == "moltencodes"

  adapter.newLocale("CheckOrder", "enUS", false).Greeting = "Hello there"
  adapter.newLocale("CheckOrder", "enUS", true).Greeting = true
  adapter.newLocale("CheckOrder", "enUS", true).Farewell = true
  local ordered = adapter.getLocale("CheckOrder")
  results[#results + 1] = {
    name = "default-keeps-translation",
    passed = ordered.Greeting == "Hello there" and ordered.Farewell == "Farewell",
    detail = "Greeting: " .. tostring(ordered.Greeting) .. ", Farewell: " .. tostring(
      ordered.Farewell
    ),
    promised = true,
  }

  host.TakeReportedErrors()
  fill(adapter.newLocale("CheckReport", "enUS", true, "report"))
  local reported = adapter.getLocale("CheckReport", "report")
  local firstRead, secondRead = reported["Never defined"], reported["Never defined"]
  local reports = #host.TakeReportedErrors()
  results[#results + 1] = {
    name = "missing-reported-once",
    passed = firstRead == "Never defined" and secondRead == "Never defined" and reports == 1,
    detail = "reads returned the key: "
      .. tostring(firstRead == "Never defined")
      .. ", reports: "
      .. reports,
    promised = true,
  }

  local listed = adapter.missingKeys and adapter.missingKeys("CheckReport") or {}
  results[#results + 1] = {
    name = "missing-keys-listed",
    passed = listed[1] == "Never defined",
    detail = "keys read but never defined, as listed: " .. #listed,
    promised = isKit,
  }

  local first = adapter.newLocale("CheckFirst", "enUS", true)
  local second = adapter.newLocale("CheckSecond", "enUS", true)
  first.Shared = "first addon's text"
  second.Other = true
  local firstStrings = adapter.getLocale("CheckFirst")
  local secondStrings = adapter.getLocale("CheckSecond")
  local landedInFirst = rawget(firstStrings, "Shared") == "first addon's text"
  local landedInSecond = rawget(secondStrings, "Shared") ~= nil
  results[#results + 1] = {
    name = "interleaved-registration",
    passed = landedInFirst and not landedInSecond,
    detail = "a write to the first addon's proxy after the second NewLocale landed in the "
      .. (landedInFirst and "first" or (landedInSecond and "second" or "no"))
      .. " addon",
    promised = isKit,
  }

  fill(adapter.newLocale("CheckBound", "enUS", true, "silent"))
  local bounded = adapter.getLocale("CheckBound", "silent")
  for index = 1, MISSING_PROBE do
    local _ = bounded["Runtime name " .. index]
  end
  local stored = 0
  for index = 1, MISSING_PROBE do
    if rawget(bounded, "Runtime name " .. index) ~= nil then
      stored = stored + 1
    end
  end
  results[#results + 1] = {
    name = "missing-keys-bounded",
    passed = stored < MISSING_PROBE,
    detail = "distinct missing keys read: "
      .. MISSING_PROBE
      .. ", kept in the read table: "
      .. stored,
    promised = isKit,
  }

  local writer = adapter.newLocale("CheckValue", "enUS", true)
  local accepted = pcall(function()
    writer.Count = 5
  end)
  results[#results + 1] = {
    name = "non-text-translation-refused",
    passed = not accepted,
    detail = "L.Count = 5 was " .. (accepted and "stored" or "refused"),
    promised = isKit,
  }
  return results
end

---Build the workload for one side.
---@param side string `"moltencodes"` or `"ace3"`
---@param host table
---@param settings table
---@return table suite `{ cases, checks, libraries }`
function Locale.Build(side, host, settings)
  local adapter, libraries
  if side == "moltencodes" then
    adapter, libraries = kitAdapter(host)
  else
    adapter, libraries = aceAdapter(host, settings.ace3)
  end
  return {
    libraries = libraries,
    cases = cases(adapter),
    checks = function()
      return checks(adapter, host)
    end,
  }
end

return Locale
