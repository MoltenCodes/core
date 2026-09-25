local TestEnv = require("CodecKitTestEnv")

-- Revision 5 serialises straight into the frame, escapes for the addon
-- channel while it writes, reuses one work record between calls and reads a
-- frame's body in place (docs/INTERNALS.md, "Work records and buffers" and
-- "Writer"). None of that may change a byte on the wire or a reason a call
-- returns: the wire format is a contract. These specs pin it three ways:
-- against the frames revision 4 wrote, against an independent reference
-- writer, and against the staged decoders the frame decoder short-cuts.

local NAN = math.huge - math.huge
local ZERO = 0

---Every byte value once, in order.
---@return string
local function allBytes()
  local bytes = {}
  for value = 0, 255 do
    bytes[value + 1] = string.char(value)
  end
  return table.concat(bytes)
end

---A table nested `depth` levels deep around one string.
---@param depth integer
---@return table
local function nested(depth)
  local value = { "leaf" }
  for _ = 2, depth do
    value = { value }
  end
  return value
end

---One table reached three times, which is not a cycle.
---@return table
local function shared()
  local inner = { 1, "two" }
  return { inner, inner, { inner } }
end

---5000 numbers, every seventh a fraction: more fragments than one fold.
---@return number[]
local function numbers()
  local list = {}
  for index = 1, 5000 do
    list[index] = index % 7 == 0 and index * 0.5 or index
  end
  return list
end

---300 strings that hold every byte the addon channel escapes.
---@return string[]
local function escapedRows()
  local list = {}
  for index = 1, 300 do
    list[index] = "row " .. index .. "|\n\r\0\255 end"
  end
  return list
end

local PAYLOADS = {
  {
    "nil",
    function()
      return nil
    end,
  },
  {
    "true",
    function()
      return true
    end,
  },
  {
    "false",
    function()
      return false
    end,
  },
  {
    "zero",
    function()
      return ZERO
    end,
  },
  {
    "negative zero",
    function()
      return -ZERO
    end,
  },
  {
    "127",
    function()
      return 127
    end,
  },
  {
    "128",
    function()
      return 128
    end,
  },
  {
    "300",
    function()
      return 300
    end,
  },
  {
    "2^53",
    function()
      return 2 ^ 53
    end,
  },
  {
    "-2^53",
    function()
      return -(2 ^ 53)
    end,
  },
  {
    "2^53 + 2",
    function()
      return 2 ^ 53 + 2
    end,
  },
  {
    "-1",
    function()
      return -1
    end,
  },
  {
    "1.5",
    function()
      return 1.5
    end,
  },
  {
    "-1.5",
    function()
      return -1.5
    end,
  },
  {
    "0.1",
    function()
      return 0.1
    end,
  },
  {
    "1e300",
    function()
      return 1e300
    end,
  },
  {
    "smallest subnormal",
    function()
      return 2 ^ -1074
    end,
  },
  {
    "smallest normal",
    function()
      return 2 ^ -1022
    end,
  },
  {
    "infinity",
    function()
      return math.huge
    end,
  },
  {
    "negative infinity",
    function()
      return -math.huge
    end,
  },
  {
    "NaN",
    function()
      return NAN
    end,
  },
  {
    "negated NaN",
    function()
      return -NAN
    end,
  },
  {
    "empty string",
    function()
      return ""
    end,
  },
  {
    "one byte",
    function()
      return "a"
    end,
  },
  { "every byte", allBytes },
  {
    "200 bytes",
    function()
      return string.rep("x", 200)
    end,
  },
  {
    "escapes only",
    function()
      return "|\n\r\0\255"
    end,
  },
  {
    "empty table",
    function()
      return {}
    end,
  },
  {
    "array",
    function()
      return { 1, 2, 3 }
    end,
  },
  {
    "nested arrays",
    function()
      return { "a", { "b", { "c" } } }
    end,
  },
  {
    "one-key map",
    function()
      return { x = 1 }
    end,
  },
  {
    "mixed",
    function()
      -- A mixed table is the point of this payload.
      -- selene: allow(mixed_table)
      return { 1, x = 2 }
    end,
  },
  {
    "hole",
    function()
      return { [1] = true, [3] = true }
    end,
  },
  {
    "huge key",
    function()
      return { [2 ^ 60] = -0.25 }
    end,
  },
  { "shared table", shared },
  {
    "depth 16",
    function()
      return nested(16)
    end,
  },
  { "5000 numbers", numbers },
  { "300 escaped rows", escapedRows },
}

local OPTIONS = {
  { "none", nil },
  { "addon", { channel = "addon" } },
  { "print", { channel = "print" } },
  { "deflate", { compress = "deflate" } },
  { "deflate addon", { compress = "deflate", channel = "addon" } },
  { "deflate print 1", { compress = "deflate", channel = "print", level = 1 } },
}

---Every payload under every option set, then two argument lists.
---@return table[] cases `{ name, value, options }` or `{ name, many, options }`
local function goldenCases()
  local cases = {}
  for _, payload in ipairs(PAYLOADS) do
    for _, option in ipairs(OPTIONS) do
      cases[#cases + 1] = {
        name = payload[1] .. " / " .. option[1],
        value = payload[2],
        options = option[2],
      }
    end
  end
  cases[#cases + 1] = {
    name = "list / addon",
    -- An argument list packed the way `table.pack` would, with its count.
    -- selene: allow(mixed_table)
    many = { n = 4, 1, nil, "x|y", nil },
    options = { channel = "addon" },
  }
  -- selene: allow(mixed_table)
  local list = { n = 3, true, { 2 }, nil }
  cases[#cases + 1] = { name = "list / none", many = list, options = nil }
  return cases
end

-- The frames revision 4 (CodecKit 0.1.4) wrote for `goldenCases()`, recorded
-- on 2026-09-25 by running that revision's source over the cases above. A
-- frame of up to 40 bytes is kept in hexadecimal, a longer one by its length
-- and Adler-32.
local GOLDEN = {
  ["nil / none"] = "010101",
  ["nil / addon"] = "010501",
  ["nil / print"] = "21413c69",
  ["nil / deflate"] = "0103630400",
  ["nil / deflate addon"] = "01076304ff30",
  ["nil / deflate print 1"] = "21415246432121",
  ["true / none"] = "010103",
  ["true / addon"] = "010503",
  ["true / print"] = "21413c6f",
  ["true / deflate"] = "0103630600",
  ["true / deflate addon"] = "01076306ff30",
  ["true / deflate print 1"] = "21415246452121",
  ["false / none"] = "010102",
  ["false / addon"] = "010502",
  ["false / print"] = "21413c6c",
  ["false / deflate"] = "0103630200",
  ["false / deflate addon"] = "01076302ff30",
  ["false / deflate print 1"] = "21415246412121",
  ["zero / none"] = "01010400",
  ["zero / addon"] = "010504ff30",
  ["zero / print"] = "21413c7233",
  ["zero / deflate"] = "010363610000",
  ["zero / deflate addon"] = "01076361ff30ff30",
  ["zero / deflate print 1"] = "214152474b212121",
  ["negative zero / none"] = "0101068000000000000000",
  ["negative zero / addon"] = "01050680ff30ff30ff30ff30ff30ff30ff30",
  ["negative zero / print"] = "21413c7962212121212121212121",
  ["negative zero / deflate"] = "0103636b606060606060600000",
  ["negative zero / deflate addon"] = "0107636b60606060606060ff30ff30",
  ["negative zero / deflate print 1"] = "2141524755437973455143797344462121",
  ["127 / none"] = "0101047f",
  ["127 / addon"] = "0105047f",
  ["127 / print"] = "21413c735e",
  ["127 / deflate"] = "010363a90700",
  ["127 / deflate addon"] = "010763a907ff30",
  ["127 / deflate print 1"] = "214152483e243a38",
  ["128 / none"] = "0101048001",
  ["128 / addon"] = "0105048001",
  ["128 / print"] = "21413c735f2140",
  ["128 / deflate"] = "01036369600400",
  ["128 / deflate addon"] = "010763696004ff30",
  ["128 / deflate print 1"] = "21415247534370264c",
  ["300 / none"] = "010104ac02",
  ["300 / addon"] = "010504ac02",
  ["300 / print"] = "21413c7435215b",
  ["300 / deflate"] = "01036359c30400",
  ["300 / deflate addon"] = "01076359c304ff30",
  ["300 / deflate print 1"] = "2141524743655f5878",
  ["2^53 / none"] = "0101048080808080808010",
  ["2^53 / addon"] = "0105048080808080808010",
  ["2^53 / print"] = "21413c735f4e3e5234244e3e4e35",
  ["2^53 / deflate"] = "01036369686868686868100000",
  ["2^53 / deflate addon"] = "0107636968686868686810ff30ff30",
  ["2^53 / deflate print 1"] = "214152475346543f2a7346543b775b2121",
  ["-2^53 / none"] = "0101058080808080808010",
  ["-2^53 / addon"] = "0105058080808080808010",
  ["-2^53 / print"] = "21413c76614e3e5234244e3e4e35",
  ["-2^53 / deflate"] = "0103636d686868686868100000",
  ["-2^53 / deflate addon"] = "0107636d68686868686810ff30ff30",
  ["-2^53 / deflate print 1"] = "214152475746543f2a7346543b775b2121",
  ["2^53 + 2 / none"] = "0101064340000000000001",
  ["2^53 + 2 / addon"] = "0105064340ff30ff30ff30ff30ff3001",
  ["2^53 + 2 / print"] = "21413c787a395547696721212126",
  ["2^53 + 2 / deflate"] = "01036373766060606060600400",
  ["2^53 + 2 / deflate addon"] = "010763737660606060606004ff30",
  ["2^53 + 2 / deflate print 1"] = "214152475e4b26746369437973444a2121",
  ["-1 / none"] = "01010501",
  ["-1 / addon"] = "01050501",
  ["-1 / print"] = "21413c7535",
  ["-1 / deflate"] = "010363650400",
  ["-1 / deflate addon"] = "0107636504ff30",
  ["-1 / deflate print 1"] = "214152474f233d3c",
  ["1.5 / none"] = "0101063ff8000000000000",
  ["1.5 / addon"] = "0105063ff8ff30ff30ff30ff30ff30ff30",
  ["1.5 / print"] = "21413c787676632b3d7521212121",
  ["1.5 / deflate"] = "010363b3ffc1c0c0c0c0c00000",
  ["1.5 / deflate addon"] = "010763b3ff34c1c0c0c0c0c0ff30ff30",
  ["1.5 / deflate print 1"] = "214152484879357e506a64776a65692121",
  ["-1.5 / none"] = "010106bff8000000000000",
  ["-1.5 / addon"] = "010506bff8ff30ff30ff30ff30ff30ff30",
  ["-1.5 / print"] = "21413c7a4a76632b3d7521212121",
  ["-1.5 / deflate"] = "010363dbff8381818181810100",
  ["-1.5 / deflate addon"] = "010763dbff3483818181818101ff30",
  ["-1.5 / deflate print 1"] = "2141524872792e4272564e597844552121",
  ["0.1 / none"] = "0101063fb999999999999a",
  ["0.1 / addon"] = "0105063fb999999999999a",
  ["0.1 / print"] = "21413c7876625d4571565644344f",
  ["0.1 / deflate"] = "010363b3df3973e6cc9933670100",
  ["0.1 / deflate addon"] = "010763b3df3973e6cc99336701ff30",
  ["0.1 / deflate print 1"] = "21415248486e663969436867473c23214040",
  ["1e300 / none"] = "0101067e37e43c8800759c",
  ["1e300 / addon"] = "0105067e37e43c88ff30759c",
  ["1e300 / print"] = "21413c795f3678732c5b2131536b",
  ["1e300 / deflate"] = "010363ab337f62d3c1503a0700",
  ["1e300 / deflate addon"] = "010763ab337f62d3c1503a07ff30",
  ["1e300 / deflate print 1"] = "214152484035536f726565302d337a2121",
  ["smallest subnormal / none"] = "0101060000000000000001",
  ["smallest subnormal / addon"] = "010506ff30ff30ff30ff30ff30ff30ff3001",
  ["smallest subnormal / print"] = "21413c7835212121212121212126",
  ["smallest subnormal / deflate"] = "01036363606060606060600400",
  ["smallest subnormal / deflate addon"] = "010763636060606060606004ff30",
  ["smallest subnormal / deflate print 1"] = "214152474d4379734551437973444a2121",
  ["smallest normal / none"] = "0101060010000000000000",
  ["smallest normal / addon"] = "010506ff3010ff30ff30ff30ff30ff30ff30",
  ["smallest normal / print"] = "21413c783529312c623521212121",
  ["smallest normal / deflate"] = "01036363106060606060600000",
  ["smallest normal / deflate addon"] = "0107636310606060606060ff30ff30",
  ["smallest normal / deflate print 1"] = "214152474d293b45735643797344462121",
  ["infinity / none"] = "0101067ff0000000000000",
  ["infinity / addon"] = "0105067ff0ff30ff30ff30ff30ff30ff30",
  ["infinity / print"] = "21413c79617430524a6d21212121",
  ["infinity / deflate"] = "010363abffc0c0c0c0c0c00000",
  ["infinity / deflate addon"] = "010763abff34c0c0c0c0c0c0ff30ff30",
  ["infinity / deflate print 1"] = "21415248407935724a6964776a65692121",
  ["negative infinity / none"] = "010106fff0000000000000",
  ["negative infinity / addon"] = "010506ff34f0ff30ff30ff30ff30ff30ff30",
  ["negative infinity / print"] = "21413c7e357430524a6d21212121",
  ["negative infinity / deflate"] = "010363fbff8181818181810100",
  ["negative infinity / deflate addon"] = "010763fbff3481818181818101ff30",
  ["negative infinity / deflate print 1"] = "214152493b792e3066544e597844552121",
  ["NaN / none"] = "0101067ff8000000000000",
  ["NaN / addon"] = "0105067ff8ff30ff30ff30ff30ff30ff30",
  ["NaN / print"] = "21413c796176632b3d7521212121",
  ["NaN / deflate"] = "010363abffc1c0c0c0c0c00000",
  ["NaN / deflate addon"] = "010763abff34c1c0c0c0c0c0ff30ff30",
  ["NaN / deflate print 1"] = "214152484079357e506a64776a65692121",
  ["negated NaN / none"] = "0101067ff8000000000000",
  ["negated NaN / addon"] = "0105067ff8ff30ff30ff30ff30ff30ff30",
  ["negated NaN / print"] = "21413c796176632b3d7521212121",
  ["negated NaN / deflate"] = "010363abffc1c0c0c0c0c00000",
  ["negated NaN / deflate addon"] = "010763abff34c1c0c0c0c0c0ff30ff30",
  ["negated NaN / deflate print 1"] = "214152484079357e506a64776a65692121",
  ["empty string / none"] = "01010700",
  ["empty string / addon"] = "010507ff30",
  ["empty string / print"] = "21413c7e36",
  ["empty string / deflate"] = "010363670000",
  ["empty string / deflate addon"] = "01076367ff30ff30",
  ["empty string / deflate print 1"] = "2141524751212121",
  ["one byte / none"] = "0101070161",
  ["one byte / addon"] = "0105070161",
  ["one byte / print"] = "21413c7e374433",
  ["one byte / deflate"] = "010363674c0400",
  ["one byte / deflate addon"] = "010763674c04ff30",
  ["one byte / deflate print 1"] = "21415247513d495e41",
  ["every byte / none"] = { length = 261, adler32 = 975863820 },
  ["every byte / addon"] = { length = 266, adler32 = 2867823731 },
  ["every byte / print"] = { length = 327, adler32 = 2869323043 },
  ["every byte / deflate"] = { length = 266, adler32 = 1148224013 },
  ["every byte / deflate addon"] = { length = 271, adler32 = 3209594484 },
  ["every byte / deflate print 1"] = { length = 333, adler32 = 159409759 },
  ["200 bytes / none"] = { length = 205, adler32 = 1989631635 },
  ["200 bytes / addon"] = { length = 205, adler32 = 2043109015 },
  ["200 bytes / print"] = { length = 257, adler32 = 3828305369 },
  ["200 bytes / deflate"] = "0103633fc158314c0000",
  ["200 bytes / deflate addon"] = "0107633fc158314cff30ff30",
  ["200 bytes / deflate print 1"] = "21415247286530784969212121",
  ["escapes only / none"] = "010107057c0a0d00ff",
  ["escapes only / addon"] = "01050705ff33ff31ff32ff30ff34",
  ["escapes only / print"] = "21413c7e3b4c70593f657878",
  ["escapes only / deflate"] = "01036367ade1e265f80f00",
  ["escapes only / deflate addon"] = "01076367ade1e265f80fff30",
  ["escapes only / deflate print 1"] = "21415247515d723c3c5276646143",
  ["empty table / none"] = "01010800",
  ["empty table / addon"] = "010508ff30",
  ["empty table / print"] = "21413d2437",
  ["empty table / deflate"] = "0103e3600000",
  ["empty table / deflate addon"] = "0107e360ff30ff30",
  ["empty table / deflate print 1"] = "2141567677212121",
  ["array / none"] = "01010803040104020403",
  ["array / addon"] = "01050803040104020403",
  ["array / print"] = "21413d243a233d455b30233d57",
  ["array / deflate"] = "0103e3606661646162610600",
  ["array / deflate addon"] = "0107e36066616461626106ff30",
  ["array / deflate print 1"] = "2141567677457375385e4459584c44",
  ["nested arrays / none"] = "0101080207016108020701620801070163",
  ["nested arrays / addon"] = "0105080207016108020701620801070163",
  ["nested arrays / print"] = "21413d2439243a453a41215d45673c24555e3336446c",
  ["nested arrays / deflate"] = "0103e36062674ce46062674ce26064674c0600",
  ["nested arrays / deflate addon"] = "0107e36062674ce46062674ce26064674c06ff30",
  ["nested arrays / deflate print 1"] = "2141567677445a3c4677437a2d68466f67433f343d49714d",
  ["one-key map / none"] = "010109010701780401",
  ["one-key map / addon"] = "010509010701780401",
  ["one-key map / print"] = "21413d2939243a4629542140",
  ["one-key map / deflate"] = "0103e3646467ac60610400",
  ["one-key map / deflate addon"] = "0107e3646467ac606104ff30",
  ["one-key map / deflate print 1"] = "214156767e453b777e5344344355",
  ["mixed / none"] = "01010a010401010701780402",
  ["mixed / addon"] = "0105ff31010401010701780402",
  ["mixed / print"] = "21413d2c3a233d455232214d2e654f",
  ["mixed / deflate"] = "0103e3626461646467ac60610200",
  ["mixed / deflate addon"] = "0107e3626461646467ac606102ff30",
  ["mixed / deflate print 1"] = "2141567679453b3d235f4640394f50215b5b",
  ["hole / none"] = "01010a010301040303",
  ["hole / addon"] = "0105ff31010301040303",
  ["hole / print"] = "21413d2c3a21792952302178",
  ["hole / deflate"] = "0103e36264666461660600",
  ["hole / deflate addon"] = "0107e362646664616606ff30",
  ["hole / deflate print 1"] = "2141567679453b6c4462456a3339",
  ["huge key / none"] = "010109010643b000000000000006bfd0000000000000",
  ["huge key / addon"] = "010509010643b0ff30ff30ff30ff30ff30ff3006bfd0ff30ff30ff30ff30ff30ff30",
  ["huge key / print"] = "21413d29392423305876212121212121216437682121212121212121",
  ["huge key / deflate"] = "0103e3646473dec0c0c0c0c0c0c0b6ff0203030303030300",
  ["huge key / deflate addon"] = "0107e3646473dec0c0c0c0c0c0c0b6ff3402030303030303ff30",
  ["huge key / deflate print 1"] = "214156767e453d3a5a4764776a682664776a485e215b78523021793c5b2d",
  ["shared table / none"] = "0101080308020401070374776f08020401070374776f080108020401070374776f",
  ["shared table / addon"] = "0105080308020401070374776f08020401070374776f080108020401070374776f",
  ["shared table / print"] = { length = 42, adler32 = 3865971540 },
  ["shared table / deflate"] = "0103e360e660626164672e29cfe760626164672e29cfe760e460626164672e29cf0700",
  ["shared table / deflate addon"] = "0107e360e660626164672e29cfe760626164672e29cfe760e460626164672e29cf07ff30",
  ["shared table / deflate print 1"] = { length = 44, adler32 = 871173559 },
  ["depth 16 / none"] = "0101080108010801080108010801080108010801080108010801080108010801080107046c656166",
  ["depth 16 / addon"] = "0105080108010801080108010801080108010801080108010801080108010801080107046c656166",
  ["depth 16 / print"] = { length = 50, adler32 = 900861084 },
  ["depth 16 / deflate"] = { length = 42, adler32 = 53941949 },
  ["depth 16 / deflate addon"] = { length = 43, adler32 = 483006448 },
  ["depth 16 / deflate print 1"] = { length = 53, adler32 = 2684686257 },
  ["5000 numbers / none"] = { length = 17020, adler32 = 2982721768 },
  ["5000 numbers / addon"] = { length = 19108, adler32 = 244462075 },
  ["5000 numbers / print"] = { length = 21275, adler32 = 4254701744 },
  ["5000 numbers / deflate"] = { length = 11119, adler32 = 3332466988 },
  ["5000 numbers / deflate addon"] = { length = 11381, adler32 = 2511272569 },
  ["5000 numbers / deflate print 1"] = { length = 13912, adler32 = 2438718158 },
  ["300 escaped rows / none"] = { length = 5297, adler32 = 762830195 },
  ["300 escaped rows / addon"] = { length = 6797, adler32 = 867041749 },
  ["300 escaped rows / print"] = { length = 6622, adler32 = 3096838322 },
  ["300 escaped rows / deflate"] = { length = 642, adler32 = 128973235 },
  ["300 escaped rows / deflate addon"] = { length = 648, adler32 = 2083847415 },
  ["300 escaped rows / deflate print 1"] = { length = 997, adler32 = 1589000115 },
  ["list / addon"] = "01050b04040101070378ff337901",
  ["list / none"] = "01010b03030801040201",
}

---Adler-32 of `text`, enough to tell two long frames apart.
---@param text string
---@return integer
local function adler32(text)
  local low, high = 1, 0
  for index = 1, #text do
    low = (low + text:byte(index)) % 65521
    high = (high + low) % 65521
  end
  return high * 65536 + low
end

---Encode one golden case with the package under test.
---@param CodecKit table
---@param case table
---@return boolean ok
---@return string textOrReason
local function encodeCase(CodecKit, case)
  if case.many then
    return CodecKit:EncodeMany(case.options, unpack(case.many, 1, case.many.n))
  end
  return CodecKit:Encode(case.value(), case.options)
end

-- Reference writer --------------------------------------------------------
--
-- The serialiser docs/API.md specifies, written the plain way: bytes are
-- collected as numbers and joined once. It shares no code with CodecKit.

local referenceValue

---@param bytes integer[]
---@param value integer
local function referenceVarint(bytes, value)
  while value >= 128 do
    bytes[#bytes + 1] = value % 128 + 128
    value = math.floor(value / 128)
  end
  bytes[#bytes + 1] = value
end

---@param bytes integer[]
---@param value number
local function referenceNumber(bytes, value)
  local integral = value == value and value % 1 == 0 and math.abs(value) <= 2 ^ 53
  if integral and not (value == 0 and 1 / value < 0) then
    bytes[#bytes + 1] = value < 0 and 5 or 4
    referenceVarint(bytes, math.abs(value))
    return
  end
  bytes[#bytes + 1] = 6
  if value ~= value then
    for _, byte in ipairs({ 127, 248, 0, 0, 0, 0, 0, 0 }) do
      bytes[#bytes + 1] = byte
    end
    return
  end
  local sign = (value < 0 or 1 / value < 0) and 128 or 0
  value = math.abs(value)
  local exponent, fraction = 0, 0
  if value == math.huge then
    exponent = 2047
  elseif value ~= 0 then
    local mantissa, power = math.frexp(value)
    exponent = power + 1022
    if exponent >= 1 then
      fraction = (mantissa * 2 - 1) * 2 ^ 52
    else
      exponent = 0
      fraction = math.ldexp(value, 1074)
    end
  end
  local digits = {}
  for index = 6, 1, -1 do
    digits[index] = fraction % 256
    fraction = math.floor(fraction / 256)
  end
  bytes[#bytes + 1] = sign + math.floor(exponent / 16)
  bytes[#bytes + 1] = (exponent % 16) * 16 + fraction
  for index = 1, 6 do
    bytes[#bytes + 1] = digits[index]
  end
end

---@param bytes integer[]
---@param value table
local function referenceTable(bytes, value)
  local arrayLength = 0
  while arrayLength < #value and rawget(value, arrayLength + 1) ~= nil do
    arrayLength = arrayLength + 1
  end
  local mapKeys = {}
  for key in next, value do
    local inArray = type(key) == "number" and key % 1 == 0 and key >= 1 and key <= arrayLength
    if not inArray then
      mapKeys[#mapKeys + 1] = key
    end
  end
  if #mapKeys == 0 then
    bytes[#bytes + 1] = 8
    referenceVarint(bytes, arrayLength)
  elseif arrayLength == 0 then
    bytes[#bytes + 1] = 9
    referenceVarint(bytes, #mapKeys)
  else
    bytes[#bytes + 1] = 10
    referenceVarint(bytes, arrayLength)
  end
  for index = 1, arrayLength do
    referenceValue(bytes, rawget(value, index))
  end
  if #mapKeys > 0 and arrayLength > 0 then
    referenceVarint(bytes, #mapKeys)
  end
  for _, key in ipairs(mapKeys) do
    referenceValue(bytes, key)
    referenceValue(bytes, rawget(value, key))
  end
end

---@param bytes integer[]
---@param value any
function referenceValue(bytes, value)
  local kind = type(value)
  if kind == "nil" then
    bytes[#bytes + 1] = 1
  elseif kind == "boolean" then
    bytes[#bytes + 1] = value and 3 or 2
  elseif kind == "number" then
    referenceNumber(bytes, value)
  elseif kind == "string" then
    bytes[#bytes + 1] = 7
    referenceVarint(bytes, #value)
    for index = 1, #value do
      bytes[#bytes + 1] = value:byte(index)
    end
  else
    referenceTable(bytes, value)
  end
end

---The serialised bytes of `value` by the reference writer.
---@param value any
---@return string
local function referenceSerialize(value)
  local bytes = {}
  referenceValue(bytes, value)
  local parts = {}
  for index = 1, #bytes do
    parts[index] = string.char(bytes[index])
  end
  return table.concat(parts)
end

local ADDON_ESCAPES = {
  ["\0"] = "\255" .. "0",
  ["\n"] = "\255" .. "1",
  ["\r"] = "\255" .. "2",
  ["|"] = "\255" .. "3",
  ["\255"] = "\255" .. "4",
}

---A random value of every kind the writer has a path for, nested a few levels.
---@param random fun(limit: integer): integer
---@param depth integer
---@return any
local function randomValue(random, depth)
  local specials = { 0, -ZERO, 127, 128, 16384, 2 ^ 53, -(2 ^ 53), 2 ^ 60, 0.1, -1.5 }
  local kind = random(depth > 3 and 6 or 9)
  if kind == 0 then
    return specials[random(#specials) + 1]
  elseif kind == 1 then
    return TestEnv.RandomBytes(random, random(4) == 0 and random(300) or random(12))
  elseif kind == 2 then
    return random(2) == 0
  elseif kind == 3 then
    return random(100000) - 50000
  elseif kind == 4 then
    return (random(1000000) - 500000) / 1000
  elseif kind == 5 then
    return random(2) == 0 and NAN or math.huge
  end
  local value = {}
  local length = random(6)
  for index = 1, length do
    value[index] = randomValue(random, depth + 1)
  end
  if random(2) == 0 then
    value[length + 2] = randomValue(random, depth + 1)
  end
  for _ = 1, random(4) do
    value[TestEnv.RandomBytes(random, random(6))] = randomValue(random, depth + 1)
  end
  return value
end

describe("CodecKit fast paths", function()
  local CodecKit
  before_each(function()
    CodecKit = TestEnv.NewPackage()
  end)
  after_each(TestEnv.Reset)

  it("writes byte for byte the frames revision 4 wrote", function()
    local cases = goldenCases()
    for _, case in ipairs(cases) do
      local expected = GOLDEN[case.name]
      assert.is_not_nil(expected, "no golden frame for " .. case.name)
      local ok, text = encodeCase(CodecKit, case)
      assert.is_true(ok, case.name .. ": " .. tostring(text))
      if type(expected) == "string" then
        assert.are.equal(expected, TestEnv.Hex(text), case.name)
      else
        assert.are.equal(expected.length, #text, case.name)
        assert.are.equal(expected.adler32, adler32(text), case.name)
      end
    end
  end)

  it("decodes every recorded revision 4 frame to its payload", function()
    for _, case in ipairs(goldenCases()) do
      local expected = GOLDEN[case.name]
      local text
      if type(expected) == "string" then
        text = TestEnv.Unhex(expected)
      else
        text = select(2, encodeCase(CodecKit, case))
      end
      if case.many then
        local decoded = { CodecKit:DecodeMany(text) }
        assert.is_true(decoded[1], case.name)
        for index = 1, case.many.n do
          assert.is_true(TestEnv.Same(case.many[index], decoded[index + 1]), case.name)
        end
      else
        local ok, value = CodecKit:Decode(text)
        assert.is_true(ok, case.name .. ": " .. tostring(value))
        assert.is_true(TestEnv.Same(case.value(), value), case.name)
      end
    end
  end)

  it("matches a reference writer on random values, on every uncompressed channel", function()
    local random = TestEnv.NewRandom(20260925)
    for round = 1, 400 do
      local value = randomValue(random, 0)
      local bytes = referenceSerialize(value)
      local label = "round " .. round

      local ok, serialized = CodecKit:Serialize(value)
      assert.is_true(ok, label)
      assert.are.equal(TestEnv.Hex(bytes), TestEnv.Hex(serialized), label)

      local _, plain = CodecKit:Encode(value)
      assert.are.equal(TestEnv.Hex("\1\1" .. bytes), TestEnv.Hex(plain), label)
      local _, addon = CodecKit:Encode(value, { channel = "addon" })
      local escaped = bytes:gsub("[%z\n\r|\255]", ADDON_ESCAPES)
      assert.are.equal(TestEnv.Hex("\1\5" .. escaped), TestEnv.Hex(addon), label)
      local _, printed = CodecKit:Encode(value, { channel = "print" })
      -- Print text is printable ASCII, safe to show in a failure message.
      assert.are.equal(select(2, CodecKit:EncodeForPrint("\1\9" .. bytes)), printed, label)

      local decoded, back = CodecKit:Decode(addon)
      assert.is_true(decoded, label)
      assert.is_true(TestEnv.Same(value, back), label)
    end
  end)

  it("folds a payload of many thousand fragments without changing a byte", function()
    local value = {}
    for index = 1, 3000 do
      value[index] = { index, "|" .. index, index * 0.25, index % 2 == 0 }
    end
    local bytes = referenceSerialize(value)
    local _, addon = CodecKit:Encode(value, { channel = "addon" })
    local escaped = bytes:gsub("[%z\n\r|\255]", ADDON_ESCAPES)
    assert.are.equal(TestEnv.Hex("\1\5" .. escaped), TestEnv.Hex(addon))
    local ok, back = CodecKit:Decode(addon, { channel = "addon" })
    assert.is_true(ok)
    assert.is_true(TestEnv.Same(value, back))
  end)

  it("decodes a frame in place exactly as the staged decoders do", function()
    ---What `Decode` must answer for a binary or addon frame, by the stages
    ---it short-cuts: check the header, unescape, deserialise.
    local function staged(text)
      local version, flags = text:byte(1, 2)
      if version ~= 1 or (flags ~= 1 and flags ~= 5) then
        return nil
      end
      local body = text:sub(3)
      if flags == 5 then
        local ok, unescaped = CodecKit:DecodeForAddon(body)
        if not ok then
          return false, unescaped
        end
        body = unescaped
      end
      return CodecKit:Deserialize(body)
    end

    local function check(text)
      local expectedOk, expected = staged(text)
      if expectedOk == nil then
        return
      end
      local ok, value = CodecKit:Decode(text)
      assert.are.equal(expectedOk, ok, TestEnv.Hex(text))
      if ok then
        assert.is_true(TestEnv.Same(expected, value), TestEnv.Hex(text))
      else
        assert.are.equal(expected, value, TestEnv.Hex(text))
      end
    end

    local payloads = {
      { name = "Tester", note = "a|b\nc", scale = 0.75, flags = { true, false } },
      { 1, 2, { "x\255y" }, 300 },
      "plain text without escapes",
    }
    for _, payload in ipairs(payloads) do
      for _, options in ipairs({ { channel = "none" }, { channel = "addon" } }) do
        local _, text = CodecKit:Encode(payload, options)
        for length = 0, #text do
          check(text:sub(1, length))
        end
        for position = 1, #text do
          for _, replacement in ipairs({ 0, 1, 5, 7, 10, 124, 128, 255 }) do
            check(text:sub(1, position - 1) .. string.char(replacement) .. text:sub(position + 1))
          end
        end
      end
    end
  end)

  it("keeps no reference to the strings it encoded once a call returns", function()
    -- Ten distinct 60000-byte strings: if the reused buffer kept them, the
    -- heap would stay about 600 KB larger after they are dropped.
    local function encodeAndDrop()
      local value = {}
      for index = 1, 10 do
        value[index] = index .. string.rep("x", 59990) .. "|"
      end
      assert.is_true((CodecKit:Encode(value, { channel = "addon" })))
      assert.is_true((CodecKit:Encode(value)))
      value[11] = print
      assert.is_false((CodecKit:Encode(value, { channel = "addon" })))
    end
    collectgarbage()
    collectgarbage()
    local before = collectgarbage("count")
    encodeAndDrop()
    collectgarbage()
    collectgarbage()
    local retained = collectgarbage("count") - before
    assert.is_true(retained < 100, "retained " .. retained .. " KiB after the call")
  end)

  it("serves a call nested inside another through the secret probe", function()
    local inner
    -- The fixture stands in for the client's `issecretvalue`, a global.
    -- selene: allow(global_usage)
    rawset(_G, "issecretvalue", function(value)
      if value == "nest" and inner == nil then
        inner = { CodecKit:Encode({ 1, "inner|value" }, { channel = "addon" }) }
      end
      return false
    end)
    local ok, text = CodecKit:Encode({ "outer", "nest", 2 }, { channel = "addon" })
    assert.is_true(ok)
    assert.is_true(inner[1])
    assert.is_true(TestEnv.Same({ 1, "inner|value" }, select(2, CodecKit:Decode(inner[2]))))
    assert.is_true(TestEnv.Same({ "outer", "nest", 2 }, select(2, CodecKit:Decode(text))))
  end)

  it("recovers when a probe raises in the middle of a call", function()
    -- selene: allow(global_usage)
    rawset(_G, "issecretvalue", function(value)
      if value == "boom" then
        error("probe failed", 0)
      end
      return false
    end)
    local called, message = pcall(CodecKit.Encode, CodecKit, { "a", "boom" })
    assert.is_false(called)
    assert.are.equal("probe failed", message)
    -- selene: allow(global_usage)
    rawset(_G, "issecretvalue", nil)

    -- A mixed table exercises both parts of the writer.
    -- selene: allow(mixed_table)
    local value = { "after", { 1, 2 }, x = "|" }
    local options = { channel = "addon" }
    local ok, text = CodecKit:Encode(value, options)
    assert.is_true(ok)
    assert.is_true(TestEnv.Same(value, select(2, CodecKit:Decode(text))))
    -- The failed call never gave its work record back; the next call built
    -- a fresh one. Allocation_spec.lua shows encoding is allocation-free
    -- again after such a failure.
  end)

  it("folds a stage output of more than 1024 fragments into chunks", function()
    -- A print sink holds 1024 bytes per fragment, so a stage output past
    -- 1 MiB folds its fragments into chunks before joining them.
    CodecKit:SetLimits({ maxOutputBytes = 2 ^ 21 })
    local random = TestEnv.NewRandom(4242)
    local bytes = TestEnv.RandomBytes(random, 1000003)
    local ok, printed = CodecKit:EncodeForPrint(bytes)
    assert.is_true(ok)
    assert.are.equal(5 * 250000 + 4, #printed)
    local decoded, back = CodecKit:DecodeForPrint(printed)
    assert.is_true(decoded)
    assert.is_true(back == bytes)
  end)

  it("refuses malformed argument lists in place", function()
    local cases = {
      { "\1\1\11", "truncated" },
      { "\1\1\11\2\3", "truncated" },
      { "\1\1\11\1\12", "unknownType" },
      { "\1\1\11\1\3\3", "trailingData" },
      { "\1\1\11\255\255\3", "maxValues" },
    }
    for _, case in ipairs(cases) do
      assert.are.same({ false, case[2] }, { CodecKit:DecodeMany(case[1]) }, TestEnv.Hex(case[1]))
    end
    assert.are.same({ true, true, nil }, { CodecKit:DecodeMany("\1\1\11\2\3\1") })
  end)

  it("applies the stage limits to a body it reads in place", function()
    CodecKit:SetLimits({ maxOutputBytes = 10 })
    local body = "\7\9" .. string.rep("a", 9)
    assert.are.same({ false, "maxOutputBytes" }, { CodecKit:Decode("\1\5" .. body) })
    assert.are.same({ false, "maxOutputBytes" }, { CodecKit:Decode("\1\1" .. body) })
    assert.are.same({ false, "maxOutputBytes" }, { CodecKit:Encode(string.rep("a", 9)) })
    assert.are.same(
      { false, "unsupportedType" },
      { CodecKit:Encode({ print }, { compress = "deflate" }) }
    )
    assert.are.same({ false, "maxOutputBytes" }, {
      CodecKit:Encode(string.rep("a", 7), { compress = "deflate", channel = "addon" }),
    })
  end)

  it("refuses a cycle only when a table is open on the path", function()
    local inner = { "inner" }
    -- The same table as elements, as a key and as a value.
    -- selene: allow(mixed_table)
    local repeated = { inner, { inner, { inner } }, [inner] = inner }
    assert.is_true((CodecKit:Encode(repeated)))

    local looped = { 1, { 2, { 3 } } }
    looped[2][2][2] = looped
    assert.are.same({ false, "cycle" }, { CodecKit:Encode(looped) })

    local keyed = {}
    keyed[{ keyed }] = true
    assert.are.same({ false, "cycle" }, { CodecKit:Encode(keyed) })

    local deep = nested(12)
    local innermost = deep
    for _ = 1, 11 do
      innermost = innermost[1]
    end
    innermost[2] = deep[1][1]
    assert.are.same({ false, "cycle" }, { CodecKit:Encode(deep) })
    assert.is_true((CodecKit:Encode(nested(12))))
  end)

  it("refuses exactly one level past maxDepth on both sides", function()
    CodecKit:SetLimits({ maxDepth = 5 })
    assert.is_true((CodecKit:Encode(nested(5), { channel = "addon" })))
    assert.are.same({ false, "maxDepth" }, { CodecKit:Encode(nested(6), { channel = "addon" }) })

    CodecKit:SetLimits({ maxDepth = 6 })
    local _, deeper = CodecKit:Encode(nested(6), { channel = "addon" })
    CodecKit:SetLimits({ maxDepth = 5 })
    assert.are.same({ false, "maxDepth" }, { CodecKit:Decode(deeper) })
    local ok = CodecKit:Decode(select(2, CodecKit:Encode(nested(5), { channel = "addon" })))
    assert.is_true(ok)
  end)
end)
