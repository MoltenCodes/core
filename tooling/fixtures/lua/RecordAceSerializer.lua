-- Record AceSerializer-3.0 fixtures for bridgeKit.
--
-- Run by `python3 -m tooling.fixtures.ace_serializer`, never by hand and never
-- in the game client:
--
--   lua RecordAceSerializer.lua <ace3 directory> <commit> <date>
--
-- The script loads LibStub and AceSerializer-3.0 from a checkout of Ace3 at the
-- pinned commit, which lives outside the repository (docs/BRIDGE_KIT_DESIGN.md,
-- section 3.2). It calls the library on the project's own inputs, listed
-- below, and prints a Lua module of the results to standard output. Nothing of
-- Ace3 is copied: the module holds only what the library returned for those
-- inputs, with the inputs that produced it.
--
-- Encoding cases are written as Lua source, evaluated here into the values
-- passed to `Serialize`, and kept as source in the module so a spec can build
-- the same values. Decoding cases are AceSerializer texts written by hand,
-- including malformed ones; the module records what `Deserialize` answered.

local aceDirectory, commit, recordedOn = ...
if aceDirectory == nil or commit == nil or recordedOn == nil then
  io.stderr:write("usage: lua RecordAceSerializer.lua <ace3 directory> <commit> <date>\n")
  os.exit(2)
end

-- LibStub and AceSerializer are plain files; loading them needs no client.
dofile(aceDirectory .. "/LibStub/LibStub.lua")
dofile(aceDirectory .. "/AceSerializer-3.0/AceSerializer-3.0.lua")
-- selene: allow(global_usage)
local LibStub = rawget(_G, "LibStub")
local AceSerializer, minor = LibStub:GetLibrary("AceSerializer-3.0")

--- Values passed to `Serialize`, as Lua source. Each is evaluated with
--- `loadstring("return " .. source)`, so a case may pass several values.
local ENCODE_CASES = {
  { label = "no values", source = "" },
  { label = "empty string", source = [["" ]] },
  { label = "plain string", source = [["hello"]] },
  { label = "string with a space", source = [["a b"]] },
  { label = "caret and tilde", source = [["^~"]] },
  {
    label = "control bytes, record separator, space, caret, tilde, DEL",
    source = "string.char(0, 1, 9, 10, 13, 30, 31, 32, 94, 126, 127)",
  },
  { label = "high bytes and pipe", source = "string.char(124, 128, 200, 255)" },
  {
    label = "every byte value",
    source = "(function() local t = {} for b = 0, 255 do t[#t + 1] = string.char(b) end return table.concat(t) end)()",
  },
  { label = "integer", source = "42" },
  { label = "negative integer", source = "-7" },
  { label = "zero", source = "0" },
  { label = "negative zero", source = "-0.0" },
  { label = "short fraction", source = "3.5" },
  { label = "one third", source = "1 / 3" },
  { label = "two to the 53", source = "2 ^ 53" },
  { label = "two to the 53 plus two", source = "2 ^ 53 + 2" },
  { label = "large exponent", source = "1e300" },
  { label = "smallest subnormal", source = "5e-324" },
  { label = "smallest normal", source = "2.2250738585072014e-308" },
  { label = "positive infinity", source = "math.huge" },
  { label = "negative infinity", source = "-math.huge" },
  { label = "true", source = "true" },
  { label = "false", source = "false" },
  { label = "nil", source = "nil" },
  { label = "several values with nil", source = [[1, nil, "three"]] },
  { label = "empty table", source = "{}" },
  { label = "one-entry array", source = "{ 1 }" },
  { label = "one-entry map", source = "{ a = 1 }" },
  { label = "boolean key", source = [[{ [true] = "x" }]] },
  { label = "nested single entries", source = "{ a = { b = { c = 1 } } }" },
  { label = "table holding an empty table", source = "{ {} }" },
  { label = "fractional key", source = [[{ [0.5] = "half" }]] },
}

--- AceSerializer texts passed to `Deserialize`, written by hand.
local DECODE_CASES = {
  { label = "empty", text = "" },
  { label = "start and end only", text = "^1^^" },
  { label = "data after the start code", text = "^1junk^S1^^" },
  { label = "garbage before the start code", text = "junk^1^Sx^^" },
  { label = "wrong revision", text = "^2^Sx^^" },
  { label = "no start code", text = "^Sx^^" },
  { label = "no terminator", text = "^1^Sx" },
  { label = "data after the end code", text = "^1^Sx^^trailing" },
  { label = "values after the end code", text = "^1^Sx^^^Sy^^" },
  { label = "string", text = "^1^Shello^^" },
  { label = "empty string", text = "^1^S^^" },
  { label = "every escape", text = "^1^S~@~A~I~J~M~z~_~`~}~|~{^^" },
  { label = "unknown escape letter", text = "^1^S~a~0^^" },
  { label = "tilde before the next caret", text = "^1^Sa~^^" },
  { label = "spaces and control bytes removed", text = "^1 ^S a\tb\r\n c ^^" },
  { label = "high bytes and pipe", text = "^1^S\124\128\200\255^^" },
  { label = "integer", text = "^1^N42^^" },
  { label = "hexadecimal number", text = "^1^N0x10^^" },
  { label = "exponent number", text = "^1^N1e3^^" },
  { label = "invalid number", text = "^1^Nabc^^" },
  { label = "empty number", text = "^1^N^^" },
  { label = "infinity, Windows spelling", text = "^1^N1.#INF^^" },
  { label = "negative infinity, Windows spelling", text = "^1^N-1.#INF^^" },
  { label = "infinity, C spelling", text = "^1^Ninf^^" },
  { label = "negative infinity, C spelling", text = "^1^N-inf^^" },
  { label = "float one", text = "^1^F4503599627370496^f-52^^" },
  { label = "float without exponent", text = "^1^F1^^" },
  { label = "float with a bad mantissa", text = "^1^Fx^f1^^" },
  { label = "float with a bad exponent", text = "^1^F1^fx^^" },
  { label = "float followed by another token", text = "^1^F1^S2^^" },
  { label = "stray exponent", text = "^1^f1^^" },
  { label = "true with data", text = "^1^Bjunk^^" },
  { label = "false", text = "^1^b^^" },
  { label = "nil with data", text = "^1^Zx^^" },
  { label = "several values", text = "^1^N1^Z^Sthree^^" },
  { label = "empty table", text = "^1^T^t^^" },
  { label = "table", text = "^1^T^Sa^N1^N1^Sx^t^^" },
  { label = "nested tables", text = "^1^T^Sa^T^Sb^T^t^t^t^^" },
  { label = "table with data on its codes", text = "^1^Tjunk^Sa^N1^tjunk^^" },
  { label = "repeated key", text = "^1^T^Sa^N1^Sa^N2^t^^" },
  { label = "nil value", text = "^1^T^Sa^Z^t^^" },
  { label = "nil key", text = "^1^T^Z^Sa^t^^" },
  { label = "key without a value", text = "^1^T^Sa^t^^" },
  { label = "table without its end", text = "^1^T^Sa^N1^^" },
  { label = "table end outside a table", text = "^1^t^^" },
  { label = "unknown control", text = "^1^X^^" },
  { label = "caret at the very end", text = "^1^" },
  { label = "escape of a letter", text = "^1^S~a^^" },
  { label = "escape below the byte range", text = "^1^S~0^^" },
  { label = "escaped tilde written as two tildes", text = "^1^S~~^^" },
  { label = "DEL removed from the input", text = "^1^Sa\127b^^" },
  { label = "NaN value", text = "^1^Nnan^^" },
  { label = "NaN key", text = "^1^T^Nnan^N1^t^^" },
  { label = "end code inside a table value", text = "^1^T^Sa^^" },
  { label = "table end where a value is expected at the top", text = "^1^N1^t^^" },
  { label = "float at the very end", text = "^1^F1" },
  { label = "table cut off after a value", text = "^1^T^Sa^N1" },
  { label = "start code where a value is expected", text = "^1^1^^" },
}

--- Every byte that can follow a tilde in a string token once the reader has
--- removed control bytes and spaces: everything from `!` to 255 but the caret,
--- which ends the token. Each is decoded as `^1^S~<byte>^^`.
local ESCAPE_BYTES = {}
for byte = 33, 255 do
  if byte ~= 94 and byte ~= 127 then
    ESCAPE_BYTES[#ESCAPE_BYTES + 1] = byte
  end
end

-- Writing the module -----------------------------------------------------------

local lines = {}

---An error message without the `file:line: ` position Lua puts in front of
---it, which names the checkout on this machine and is not part of the result.
---@param message string
---@return string
local function withoutPosition(message)
  return (message:gsub("^[^\n]-:%d+: ", ""))
end

---@param text string
local function emit(text)
  lines[#lines + 1] = text
end

---A Lua literal for a recorded number, exact for every double.
---@param value number
---@return string
local function numberLiteral(value)
  if value ~= value then
    return "0 / 0"
  end
  if value == math.huge then
    return "math.huge"
  end
  if value == -math.huge then
    return "-math.huge"
  end
  if value == 0 and 1 / value < 0 then
    return "-0.0"
  end
  return string.format("%.17g", value)
end

local literal

---A Lua literal for a recorded table, its keys in a stable order.
---@param value table
---@return string
local function tableLiteral(value)
  local keys = {}
  for key in pairs(value) do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(left, right)
    local leftType, rightType = type(left), type(right)
    if leftType ~= rightType then
      return leftType < rightType
    end
    if leftType == "boolean" then
      return (left and 1 or 0) < (right and 1 or 0)
    end
    return left < right
  end)
  local entries = {}
  for index = 1, #keys do
    local key = keys[index]
    entries[index] = "[" .. literal(key) .. "] = " .. literal(value[key])
  end
  return "{ " .. table.concat(entries, ", ") .. " }"
end

---A Lua literal for any recorded value.
---@param value any
---@return string
function literal(value)
  local valueType = type(value)
  if valueType == "nil" then
    return "nil"
  elseif valueType == "boolean" then
    return tostring(value)
  elseif valueType == "number" then
    return numberLiteral(value)
  elseif valueType == "string" then
    -- Every byte outside printable ASCII is written as a decimal escape, so
    -- the module is plain ASCII whatever the values hold.
    return '"'
      .. value:gsub('[%c"\\\128-\255]', function(byte)
        return string.format("\\%03d", string.byte(byte))
      end)
      .. '"'
  elseif valueType == "table" then
    return tableLiteral(value)
  end
  error("cannot record a " .. valueType, 2)
end

---Pack every value with its count, nils included.
---@return table
local function pack(...)
  return { n = select("#", ...), ... }
end

---The recorded values as `{ n = <count>, <literal>, ... }`.
---@param values table
---@param first integer
---@return string
local function valuesLiteral(values, first)
  local parts = { "n = " .. (values.n - first + 1) }
  for index = first, values.n do
    parts[#parts + 1] = "[" .. (index - first + 1) .. "] = " .. literal(values[index])
  end
  return "{ " .. table.concat(parts, ", ") .. " }"
end

emit("-- AceSerializer-3.0 fixtures for bridgeKit. GENERATED FILE: do not edit.")
emit("-- Regenerate with `python3 -m tooling.fixtures.ace_serializer`.")
emit("--")
emit("-- Output of Ace3's AceSerializer-3.0 run over this project's own inputs:")
emit("-- each encoding case names the Lua source of the values it passed, each")
emit("-- decoding case the text it passed. No Ace3 source is reproduced here")
emit("-- (docs/BRIDGE_KIT_DESIGN.md, section 3.2).")
emit("return {")
emit("  provenance = {")
emit("    repository = " .. literal("WoWUIDev/Ace3") .. ",")
emit("    commit = " .. literal(commit) .. ",")
emit("    library = " .. literal("AceSerializer-3.0") .. ",")
emit("    minor = " .. literal(minor) .. ",")
emit("    recordedOn = " .. literal(recordedOn) .. ",")
emit("    client = " .. literal(_VERSION .. " (host, not the game client)") .. ",")
emit("  },")

emit("  encode = {")
for _, case in ipairs(ENCODE_CASES) do
  local values = pack(assert(loadstring("return " .. case.source, case.label))())
  local ok, result = pcall(AceSerializer.Serialize, AceSerializer, unpack(values, 1, values.n))
  emit("    {")
  emit("      label = " .. literal(case.label) .. ",")
  emit("      source = " .. literal(case.source) .. ",")
  emit("      ok = " .. tostring(ok) .. ",")
  if ok then
    emit("      text = " .. literal(result) .. ",")
  else
    emit("      message = " .. literal(withoutPosition(tostring(result))) .. ",")
  end
  emit("    },")
end
emit("  },")

emit("  decode = {")
for _, case in ipairs(DECODE_CASES) do
  local results = pack(AceSerializer:Deserialize(case.text))
  emit("    {")
  emit("      label = " .. literal(case.label) .. ",")
  emit("      text = " .. literal(case.text) .. ",")
  emit("      ok = " .. tostring(results[1]) .. ",")
  if results[1] then
    emit("      values = " .. valuesLiteral(results, 2) .. ",")
  else
    emit("      message = " .. literal(withoutPosition(tostring(results[2]))) .. ",")
  end
  emit("    },")
end
emit("  },")

-- One row per byte after a tilde: `{ byte, ok, value or message }`.
emit("  escapes = {")
for _, byte in ipairs(ESCAPE_BYTES) do
  local ok, value = AceSerializer:Deserialize("^1^S~" .. string.char(byte) .. "^^")
  local result = ok and literal(value) or literal(withoutPosition(tostring(value)))
  emit("    { " .. byte .. ", " .. tostring(ok) .. ", " .. result .. " },")
end
emit("  },")
emit("}")

io.write(table.concat(lines, "\n"), "\n")
