--- Serialisation: CodecKit against AceSerializer-3.0, compression off.
---
--- Both sides turn the same logical values into text an addon message can
--- carry and back: `CodecKit:Encode(value, { channel = "addon" })` and
--- `CodecKit:Decode(text)` against `AceSerializer:Serialize(value)` and
--- `AceSerializer:Deserialize(text)`. Each produces channel-safe text by its
--- own rules (CodecKit escapes the bytes the addon channel cannot carry;
--- AceSerializer escapes control characters, space, `^`, `~` and DEL), so the
--- comparison is of the whole value-to-transport step each library offers.
---
--- Compression is not compared: Ace3 has no compressor, and comparing
--- CodecKit's DEFLATE stage would need a second, separately named library on
--- the Ace side (LibDeflate), which this benchmark does not fetch.

local Codec = {}

--- The payloads, built fresh by the same code on both sides.
local PAYLOADS = {
  small = function()
    return {
      id = 42,
      name = "Tester-Silvermoon",
      ready = true,
      health = 0.75,
      flags = { true, false, true },
      note = "line one\nline two",
    }
  end,
  medium = function()
    local records = {}
    for index = 1, 50 do
      records[index] = {
        spell = 100000 + index,
        rank = index,
        name = "Spell " .. index,
        cooldown = 1.5 * index,
        ready = index % 2 == 0,
      }
    end
    return records
  end,
  large = function()
    local numbers, names, records = {}, {}, {}
    for index = 1, 500 do
      numbers[index] = index % 3 == 0 and index * 1.25 or index
    end
    for index = 1, 200 do
      names["key" .. index] = "value " .. index
    end
    for index = 1, 100 do
      records[index] =
        { id = index, position = { x = index * 0.5, y = -index }, tags = { "a", "b", "c" } }
    end
    return { numbers = numbers, names = names, records = records }
  end,
}

--- How each payload is changed before every encode, so that every encode
--- produces a new string. Encoding one unchanged value would produce the same
--- string each time, which Lua interns, and the allocation column would then
--- leave out the output itself.
local VARY = {
  small = function(value, index)
    value.id = index
  end,
  medium = function(value, index)
    value[1].rank = index
  end,
  large = function(value, index)
    value.numbers[1] = index
  end,
}

--- Payload names in report order, with operations per timed batch.
local SIZES = { { "small", 20000 }, { "medium", 1000 }, { "large", 100 } }

---Whether two values are equal, tables compared by content.
---@param left any
---@param right any
---@return boolean
local function deepEqual(left, right)
  if type(left) ~= "table" or type(right) ~= "table" then
    return left == right
  end
  for key, value in pairs(left) do
    if not deepEqual(value, right[key]) then
      return false
    end
  end
  for key in pairs(right) do
    if left[key] == nil then
      return false
    end
  end
  return true
end

---@param host table
---@return table adapter, table[] libraries
local function kitAdapter(host)
  local loaded = host.RequireAll({ "Registry", "PoolKit", "CodecKit" })
  local CodecKit = loaded[3]
  local options = { channel = "addon" }
  local adapter = {}

  function adapter.encode(value)
    local ok, text = CodecKit:Encode(value, options)
    if not ok then
      error("CodecKit:Encode refused a benchmark payload: " .. tostring(text), 0)
    end
    return text
  end

  function adapter.decode(text)
    return CodecKit:Decode(text)
  end

  return adapter,
    {
      { name = "CodecKit", revision = CodecKit.REVISION },
      { name = "PoolKit", revision = loaded[2].REVISION },
    }
end

---@param host table
---@param directory string the Ace3 checkout
---@return table adapter, table[] libraries
local function aceAdapter(host, directory)
  host.LoadFiles(directory, { "LibStub/LibStub.lua", "AceSerializer-3.0/AceSerializer-3.0.lua" })
  local LibStub = host.Global("LibStub")
  local AceSerializer, minor = LibStub:GetLibrary("AceSerializer-3.0")
  local adapter = {}

  function adapter.encode(value)
    return AceSerializer:Serialize(value)
  end

  function adapter.decode(text)
    return AceSerializer:Deserialize(text)
  end

  return adapter, { { name = "AceSerializer-3.0", minor = minor } }
end

---@param adapter table
---@return Bench.Case[]
local function cases(adapter)
  local list = {}
  for _, entry in ipairs(SIZES) do
    local size, iterations = entry[1], entry[2]
    list[#list + 1] = {
      name = "encode-" .. size,
      iterations = iterations,
      operation = "serialise the " .. size .. " payload for the addon channel",
      prepare = function()
        local value = PAYLOADS[size]()
        local text = adapter.encode(value)
        local vary = VARY[size]
        local serial = 0
        return {
          run = function(count)
            for _ = 1, count do
              serial = serial + 1
              vary(value, serial)
              adapter.encode(value)
            end
          end,
          metrics = function()
            return { outputBytes = #text }
          end,
        }
      end,
    }
    list[#list + 1] = {
      name = "decode-" .. size,
      iterations = iterations,
      operation = "deserialise the " .. size .. " payload",
      prepare = function()
        local text = adapter.encode(PAYLOADS[size]())
        return {
          run = function(count)
            for _ = 1, count do
              adapter.decode(text)
            end
          end,
          metrics = function()
            return { inputBytes = #text }
          end,
        }
      end,
    }
  end
  return list
end

---Build the workload for one side.
---@param side string `"moltencodes"` or `"ace3"`
---@param host table
---@param settings table
---@return table suite `{ cases, checks, libraries }`
function Codec.Build(side, host, settings)
  local adapter, libraries
  if side == "moltencodes" then
    adapter, libraries = kitAdapter(host)
  else
    adapter, libraries = aceAdapter(host, settings.ace3)
  end

  local function checks()
    local results = {}
    for _, entry in ipairs(SIZES) do
      local size = entry[1]
      local text = adapter.encode(PAYLOADS[size]())
      local ok, decoded = adapter.decode(text)
      results[#results + 1] = {
        name = "round-trip-" .. size,
        passed = ok == true and deepEqual(decoded, PAYLOADS[size]()),
        detail = "decode succeeded: " .. tostring(ok),
        promised = true,
      }
      local unsafe = text:find("[%z\r\n]")
      results[#results + 1] = {
        name = "channel-safe-" .. size,
        passed = unsafe == nil,
        detail = unsafe == nil and "no NUL, CR or LF in the output"
          or ("forbidden byte at " .. unsafe),
        promised = true,
      }
    end

    local text = adapter.encode(PAYLOADS.medium())
    local raised, ok = false, nil
    local called = pcall(function()
      ok = adapter.decode(text:sub(1, #text - 7))
    end)
    raised = not called
    results[#results + 1] = {
      name = "truncated-input-refused",
      passed = not raised and ok == false,
      detail = raised and "decoding truncated text raised" or ("decode returned " .. tostring(ok)),
      promised = true,
    }
    return results
  end

  return { libraries = libraries, cases = cases(adapter), checks = checks }
end

return Codec
