-- MoltenCodes CodecKit part Compression
--
-- The compression stage of CodecKit: raw DEFLATE (RFC 1951), written by the
-- client's `C_EncodingUtil.CompressString` where it exists and the input is
-- 64 bytes or more, otherwise by CodecKit's own Lua compressor (LZ77 over hash
-- chains, then per block the cheapest of stored, fixed Huffman and dynamic
-- Huffman), and always inflated by CodecKit's own Lua inflater.
--
-- CodecKit's core serialises and channel-encodes; this part adds
-- `Compress`, `Decompress`, `compress = "deflate"` on the encoders and the
-- inflation of compressed frames. Without it those raise at the caller with
-- the file to embed, and a compressed frame decodes to
-- `false, "compressionUnavailable"` (docs/API.md, "Parts"). The split is
-- ADR 0001 (docs/decisions/0001-kit-core-and-parts.md).
--
-- The part needs CodecKit's core loaded first. It fills the core's two
-- compression entries (`_state.compression`) and reads the core's sinks,
-- reasons and pause through `_state.helpers` at the start of every call, so an
-- upgraded core's helpers serve a part loaded before it.
--
-- Contents
-- --------
--   Constants ............. identity and the part interface it needs
--   Dependencies .......... CodecKit's core, its state and its helpers
--   DEFLATE tables ........ RFC 1951 length, distance and fixed-code tables
--   Huffman codes ......... length-limited code construction and decoders
--   Compressor ............ LZ77 matching, block choice and bit output
--   Decompressor .......... stored, fixed and dynamic block inflation
--   Native compressor ..... C_EncodingUtil.CompressString, with its fallbacks
--   Compression stage ..... the two entries the core calls
--   Commit ................ the core's entries and the part's revision

-- Constants ------------------------------------------------------------------

local PART_NAME = "Compression"
local PART_REVISION = 1
local REQUIRED_REGISTRY_API = 2
local CORE_PACKAGE, CORE_API = "codecKit", 1
-- The `_state.helpers` entries and `_state.compression` layout this part
-- reads; the core publishes the interface it offers as `_state.partInterface`.
local REQUIRED_PART_INTERFACE = 1

-- Dependencies ---------------------------------------------------------------

local byte = string.byte
local char = string.char
local sub = string.sub
local floor = math.floor
local type = type
local rawget = rawget

-- The shared MoltenCodes namespace is the one documented global handoff point between independently embedded copies.
-- selene: allow(global_usage)
local namespace = rawget(_G, "MoltenCodes")
local generations = type(namespace) == "table" and rawget(namespace, "Registries") or nil
local Registry = type(generations) == "table" and rawget(generations, REQUIRED_REGISTRY_API) or nil
local CodecKit = nil
if type(Registry) == "table" and type(rawget(Registry, "Get")) == "function" then
  CodecKit = Registry:Get(CORE_PACKAGE, CORE_API)
end
local state = type(CodecKit) == "table" and rawget(CodecKit, "_state") or nil
local partInterface = type(state) == "table" and rawget(state, "partInterface") or nil
if
  type(state) ~= "table"
  or type(partInterface) ~= "number"
  or partInterface < REQUIRED_PART_INTERFACE
  or type(rawget(state, "parts")) ~= "table"
  or type(rawget(state, "helpers")) ~= "table"
  or type(rawget(state, "compression")) ~= "table"
then
  error("MoltenCodes CodecKit part Compression requires CodecKit API 1 to be loaded first", 2)
end

local parts = rawget(state, "parts")
local installed = rawget(parts, PART_NAME)
if
  type(installed) == "table"
  and type(rawget(installed, "revision")) == "number"
  and rawget(installed, "revision") >= PART_REVISION
then
  -- An equal or newer revision of this part already serves every copy.
  return CodecKit
end

local helpers = rawget(state, "helpers")
local compression = rawget(state, "compression")

-- The core's helpers this part calls, bound from `helpers` at the start of
-- every stage call (`bindHelpers`), never copied once at load: a core
-- upgraded after this part loaded then serves it. Inside one call they are
-- plain upvalues, so the per-byte paths pay no table read.
local REASON, SINK_BATCH_SIZE
local leaseTable, returnTable, pause
local openSink, closeSink, appendFragment, putByte, putString, finishSink

---Read the core's helpers into this file's upvalues.
local function bindHelpers()
  REASON = helpers.reasons
  SINK_BATCH_SIZE = helpers.sinkBatchSize
  leaseTable = helpers.leaseTable
  returnTable = helpers.returnTable
  pause = helpers.pause
  openSink = helpers.openSink
  closeSink = helpers.closeSink
  appendFragment = helpers.appendFragment
  putByte = helpers.putByte
  putString = helpers.putString
  finishSink = helpers.finishSink
end

-- The DEFLATE implementation below is one `do` scope that exports only these
-- two entry points. Its tables and helpers would otherwise count against the
-- 200 locals Lua 5.1 allows the main chunk.
local compressInto, inflateInto

do
  -- DEFLATE tables -------------------------------------------------------------
  --
  -- Everything in this section is RFC 1951 data, built once when the file loads.
  -- Symbol-indexed tables are zero-based, as the RFC numbers its symbols.

  local WINDOW_SIZE = 32768
  local MIN_MATCH = 3
  local MAX_MATCH = 258
  local END_OF_BLOCK = 256
  local LITERAL_SYMBOLS = 286
  local DISTANCE_SYMBOLS = 30
  local CODE_LENGTH_SYMBOLS = 19
  local MAX_CODE_BITS = 15
  local MAX_CODE_LENGTH_BITS = 7

  -- How often an asynchronous call asks `context:ShouldYield()`: every this
  -- many input positions of the compressor and decoded symbols of the
  -- inflater.
  local PAUSE_POSITIONS = 2048
  local PAUSE_SYMBOLS = 4096

  -- A length-3 match further back than this costs more bits than three
  -- literals usually do; zlib makes the same call.
  local TOO_FAR = 4096

  -- A block ends after this many tokens or this many input bytes, whichever
  -- comes first. The byte bound keeps a stored block under the format's 65535.
  local BLOCK_MAX_TOKENS = 16384
  local BLOCK_MAX_BYTES = 32768

  local sort = table.sort

  -- The symbol and fixed-code tables below are built on the first Lua
  -- compression or decompression (`buildTables`), not at load: they hold
  -- about 59 KB, and a session that never compresses, or whose client
  -- compresses natively, never needs them. Each table keeps its identity, so
  -- the functions below capture it once; only its contents arrive later.

  -- Powers of two, looked up rather than computed in the bit loops. The
  -- largest exponent read is 16, the widest field (a stored block's length).
  local POW2 = {}
  -- Length symbols 257..285 as indexes 0..28: base length and extra bits.
  local LENGTH_BASE = {}
  local LENGTH_EXTRA = {}
  -- Distance symbols 0..29: base distance and extra bits.
  local DISTANCE_BASE = {}
  local DISTANCE_EXTRA = {}
  -- Match length 3..258 to its length index 0..28. Filled in ascending order so
  -- 258 ends on its own symbol (285) rather than on 284's range.
  local LENGTH_INDEX = {}
  -- Distance to symbol: direct for 1..256; above that every symbol boundary is
  -- a multiple of 128 plus one, so `(distance - 1) / 128` indexes a small table.
  local DISTANCE_SMALL = {}
  local DISTANCE_LARGE = {}
  -- The fixed Huffman code lengths (RFC 1951 3.2.6).
  local FIXED_LITERAL_LENGTHS = {}
  local FIXED_DISTANCE_LENGTHS = {}

  ---Fill the symbol tables above. Called once, by `buildTables`.
  local function fillSymbolTables()
    for exponent = 0, 16 do
      POW2[exponent] = 2 ^ exponent
    end
    do
          -- stylua: ignore start
          local lengthBases = {
              3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
              35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
          }
          local lengthExtras = {
              0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
              3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
          }
          local distanceBases = {
              1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
              257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
          }
          local distanceExtras = {
              0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
              7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
          }
      -- stylua: ignore end
      for index = 1, #lengthBases do
        LENGTH_BASE[index - 1] = lengthBases[index]
        LENGTH_EXTRA[index - 1] = lengthExtras[index]
      end
      for index = 1, #distanceBases do
        DISTANCE_BASE[index - 1] = distanceBases[index]
        DISTANCE_EXTRA[index - 1] = distanceExtras[index]
      end
    end

    for index = 0, 28 do
      local base = LENGTH_BASE[index]
      for length = base, math.min(base + POW2[LENGTH_EXTRA[index]] - 1, MAX_MATCH) do
        LENGTH_INDEX[length] = index
      end
    end

    for symbol = 0, DISTANCE_SYMBOLS - 1 do
      local first = DISTANCE_BASE[symbol]
      local last = first + POW2[DISTANCE_EXTRA[symbol]] - 1
      for distance = first, math.min(last, 256) do
        DISTANCE_SMALL[distance] = symbol
      end
      if last > 256 then
        for group = floor((math.max(first, 257) - 1) / 128), floor((last - 1) / 128) do
          DISTANCE_LARGE[group] = symbol
        end
      end
    end

    for symbol = 0, 287 do
      local length = 8
      if symbol >= 144 and symbol <= 255 then
        length = 9
      elseif symbol >= 256 and symbol <= 279 then
        length = 7
      end
      FIXED_LITERAL_LENGTHS[symbol] = length
    end
    for symbol = 0, 31 do
      FIXED_DISTANCE_LENGTHS[symbol] = 5
    end
  end

  ---@param distance integer 1 to 32768
  ---@return integer symbol 0 to 29
  local function distanceSymbol(distance)
    if distance <= 256 then
      return DISTANCE_SMALL[distance]
    end
    return DISTANCE_LARGE[floor((distance - 1) / 128)]
  end

  -- The order the code-length code lengths are sent in (RFC 1951 3.2.7).
  local CODE_LENGTH_ORDER = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }

  -- Compression levels: how far to follow a hash chain (`chain`), when a match
  -- is long enough to stop looking (`nice`), when to quarter the chain because
  -- the previous match was already good (`good`), and whether to defer a match
  -- by one byte to look for a longer one (`lazy`, with `lazyLimit` the match
  -- length above which no deferred search runs). Greedy levels insert the
  -- positions inside a match into the hash only up to `lazyLimit` bytes.
  --
  -- Levels 8 and 9 cap the chain at 192 and 256 candidates, where zlib uses
  -- 1024 and 4096: on low-entropy input (two random symbols, say) every
  -- chain is full of short matches, and the longer chains made level 9
  -- twenty-seven times slower than level 6 in pure Lua for well under 5%
  -- smaller output. The caps keep level 9 within about three times level 6.
  local LEVELS = {
    { lazy = false, good = 4, lazyLimit = 4, nice = 8, chain = 4 },
    { lazy = false, good = 4, lazyLimit = 5, nice = 16, chain = 8 },
    { lazy = false, good = 4, lazyLimit = 6, nice = 32, chain = 32 },
    { lazy = true, good = 4, lazyLimit = 4, nice = 16, chain = 16 },
    { lazy = true, good = 8, lazyLimit = 16, nice = 32, chain = 32 },
    { lazy = true, good = 8, lazyLimit = 16, nice = 128, chain = 128 },
    { lazy = true, good = 8, lazyLimit = 32, nice = 128, chain = 256 },
    { lazy = true, good = 32, lazyLimit = 128, nice = 258, chain = 192 },
    { lazy = true, good = 32, lazyLimit = 258, nice = 258, chain = 256 },
  }

  -- Huffman codes --------------------------------------------------------------

  ---Reverse the low `length` bits of `code`. DEFLATE packs Huffman codes most
  ---significant bit first into a stream read least significant bit first.
  ---@param code integer
  ---@param length integer
  ---@return integer
  local function reverseBits(code, length)
    local reversed = 0
    for _ = 1, length do
      local bit = code % 2
      reversed = reversed * 2 + bit
      code = (code - bit) / 2
    end
    return reversed
  end

  ---The first canonical code of every length (RFC 1951 3.2.2).
  ---@param lengths table<integer, integer> zero-based code lengths
  ---@param symbolCount integer
  ---@return table<integer, integer> nextCode
  local function firstCodes(lengths, symbolCount)
    local lengthCount = {}
    for bits = 0, MAX_CODE_BITS do
      lengthCount[bits] = 0
    end
    for symbol = 0, symbolCount - 1 do
      local length = lengths[symbol]
      lengthCount[length] = lengthCount[length] + 1
    end
    lengthCount[0] = 0
    local nextCode = {}
    local code = 0
    for bits = 1, MAX_CODE_BITS do
      code = (code + lengthCount[bits - 1]) * 2
      nextCode[bits] = code
    end
    return nextCode
  end

  ---Assign canonical codes, stored bit-reversed so they can be written as is.
  ---@param lengths table<integer, integer>
  ---@param symbolCount integer
  ---@return table<integer, integer> codes
  local function canonicalCodes(lengths, symbolCount)
    local nextCode = firstCodes(lengths, symbolCount)
    local codes = {}
    for symbol = 0, symbolCount - 1 do
      local length = lengths[symbol]
      if length > 0 then
        local code = nextCode[length]
        nextCode[length] = code + 1
        codes[symbol] = reverseBits(code, length)
      else
        codes[symbol] = 0
      end
    end
    return codes
  end

  ---Build length-limited Huffman code lengths for `frequencies`.
  ---
  ---Symbols are sorted by frequency (packed with the symbol into one number so
  ---the default comparator sorts them), a Huffman tree is built with the
  ---two-queue method, and the resulting length counts are folded under
  ---`maxBits` and repaired until the Kraft sum is exactly one. The shortest
  ---lengths then go to the most frequent symbols. Fewer than two used symbols
  ---are padded with unused ones so the code is always complete.
  ---@param frequencies table<integer, integer> zero-based
  ---@param symbolCount integer
  ---@param maxBits integer
  ---@return table<integer, integer> lengths zero-based
  local function huffmanLengths(frequencies, symbolCount, maxBits)
    local lengths = {}
    local sorted = {}
    local used = 0
    for symbol = 0, symbolCount - 1 do
      lengths[symbol] = 0
      local frequency = frequencies[symbol]
      if frequency > 0 then
        used = used + 1
        sorted[used] = frequency * 512 + symbol
      end
    end
    local padding = 0
    while used < 2 do
      -- Weight 0 sorts a padding symbol first; its length costs nothing.
      if frequencies[padding] == 0 then
        used = used + 1
        sorted[used] = padding
      end
      padding = padding + 1
    end
    sort(sorted)

    local weight, parent = {}, {}
    for index = 1, used do
      weight[index] = floor(sorted[index] / 512)
    end
    local nextLeaf, nextNode = 1, used + 1
    local lastNode = used
    for node = used + 1, 2 * used - 1 do
      local first, second
      if nextLeaf <= used and (nextNode > lastNode or weight[nextLeaf] <= weight[nextNode]) then
        first, nextLeaf = nextLeaf, nextLeaf + 1
      else
        first, nextNode = nextNode, nextNode + 1
      end
      if nextLeaf <= used and (nextNode > lastNode or weight[nextLeaf] <= weight[nextNode]) then
        second, nextLeaf = nextLeaf, nextLeaf + 1
      else
        second, nextNode = nextNode, nextNode + 1
      end
      weight[node] = weight[first] + weight[second]
      parent[first] = node
      parent[second] = node
      lastNode = node
    end

    local root = 2 * used - 1
    local depth = { [root] = 0 }
    local lengthCount = {}
    for bits = 1, maxBits do
      lengthCount[bits] = 0
    end
    for node = root - 1, 1, -1 do
      depth[node] = depth[parent[node]] + 1
    end
    for leaf = 1, used do
      local bits = depth[leaf]
      if bits > maxBits then
        bits = maxBits
      end
      lengthCount[bits] = lengthCount[bits] + 1
    end

    local total = 0
    for bits = 1, maxBits do
      total = total + lengthCount[bits] * POW2[maxBits - bits]
    end
    local full = POW2[maxBits]
    while total > full do
      -- Remove one leaf at the deepest length and split a shallower leaf
      -- into two one level deeper: the Kraft sum drops by one unit.
      lengthCount[maxBits] = lengthCount[maxBits] - 1
      for bits = maxBits - 1, 1, -1 do
        if lengthCount[bits] > 0 then
          lengthCount[bits] = lengthCount[bits] - 1
          lengthCount[bits + 1] = lengthCount[bits + 1] + 2
          break
        end
      end
      total = total - 1
    end

    local leaf = used
    for bits = 1, maxBits do
      for _ = 1, lengthCount[bits] do
        lengths[sorted[leaf] % 512] = bits
        leaf = leaf - 1
      end
    end
    return lengths
  end

  ---Build a decoder for canonical code `lengths`, or refuse them.
  ---
  ---The decoder maps `2^length + reversedCode` to the symbol, so a lookup for a
  ---given length matches exactly the codes of that length. An over-subscribed
  ---set is refused; an incomplete one only when it is not the single one-bit
  ---code RFC 1951 allows for a block with one distance.
  ---@param lengths table<integer, integer> zero-based
  ---@param symbolCount integer
  ---@return table|false|nil decoder `false` when no symbol has a code, `nil` when invalid
  local function buildDecoder(lengths, symbolCount)
    local lengthCount = {}
    for bits = 1, MAX_CODE_BITS do
      lengthCount[bits] = 0
    end
    local used, minLength, maxLength = 0, MAX_CODE_BITS + 1, 0
    for symbol = 0, symbolCount - 1 do
      local length = lengths[symbol]
      if length > 0 then
        used = used + 1
        lengthCount[length] = lengthCount[length] + 1
        if length < minLength then
          minLength = length
        end
        if length > maxLength then
          maxLength = length
        end
      end
    end
    if used == 0 then
      return false
    end
    local left = 1
    for bits = 1, MAX_CODE_BITS do
      left = left * 2 - lengthCount[bits]
      if left < 0 then
        return nil
      end
    end
    if left > 0 and not (used == 1 and maxLength == 1) then
      return nil
    end

    local nextCode = firstCodes(lengths, symbolCount)
    local lookup = {}
    for symbol = 0, symbolCount - 1 do
      local length = lengths[symbol]
      if length > 0 then
        local code = nextCode[length]
        nextCode[length] = code + 1
        lookup[POW2[length] + reverseBits(code, length)] = symbol
      end
    end
    return { lookup = lookup, minLength = minLength, maxLength = maxLength }
  end

  -- The fixed codes and decoders, built with the tables above.
  local FIXED_LITERAL_CODES, FIXED_DISTANCE_CODES
  local FIXED_LITERAL_DECODER, FIXED_DISTANCE_DECODER
  local tablesBuilt = false

  ---Build every table the Lua compressor and inflater read, once per load of
  ---this file. Both entry points call it first; after that they allocate
  ---nothing for tables.
  local function buildTables()
    fillSymbolTables()
    FIXED_LITERAL_CODES = canonicalCodes(FIXED_LITERAL_LENGTHS, 288)
    FIXED_DISTANCE_CODES = canonicalCodes(FIXED_DISTANCE_LENGTHS, DISTANCE_SYMBOLS)
    FIXED_LITERAL_DECODER = buildDecoder(FIXED_LITERAL_LENGTHS, 288) --[[@as table]]
    FIXED_DISTANCE_DECODER = buildDecoder(FIXED_DISTANCE_LENGTHS, 32) --[[@as table]]
    tablesBuilt = true
  end

  -- Compressor -----------------------------------------------------------------
  --
  -- One compressor record per call holds the input as an array of byte values,
  -- the hash chains, the tokens of the current block and the bit writer. It is
  -- a plain table, not leased: its arrays are proportional to the input, and a
  -- pool retaining them would keep that memory for the session.

  ---Write `bits` low bits of `value` to the output, least significant first.
  ---@param compressor table
  ---@param value integer
  ---@param bits integer
  local function writeBits(compressor, value, bits)
    local count = compressor.bitCount
    local buffer = compressor.bitBuffer + value * POW2[count]
    count = count + bits
    local sink = compressor.sink
    while count >= 8 do
      local low = buffer % 256
      putByte(sink, low)
      buffer = (buffer - low) / 256
      count = count - 8
    end
    compressor.bitBuffer = buffer
    compressor.bitCount = count
  end

  ---Pad the current byte with zero bits.
  ---@param compressor table
  local function alignToByte(compressor)
    if compressor.bitCount > 0 then
      writeBits(compressor, 0, 8 - compressor.bitCount)
    end
  end

  ---Start a new block: no tokens, zeroed frequencies, one end-of-block symbol.
  ---@param compressor table
  local function resetBlock(compressor)
    compressor.tokenCount = 0
    compressor.extraBits = 0
    compressor.blockStart = compressor.covered + 1
    local literalFrequencies = compressor.literalFrequencies
    for symbol = 0, LITERAL_SYMBOLS - 1 do
      literalFrequencies[symbol] = 0
    end
    literalFrequencies[END_OF_BLOCK] = 1
    local distanceFrequencies = compressor.distanceFrequencies
    for symbol = 0, DISTANCE_SYMBOLS - 1 do
      distanceFrequencies[symbol] = 0
    end
  end

  ---Run-length encode the literal and distance code lengths with the
  ---code-length alphabet, and size the resulting dynamic block header.
  ---@param literalLengths table<integer, integer>
  ---@param distanceLengths table<integer, integer>
  ---@return table header
  local function dynamicHeader(literalLengths, distanceLengths)
    local literalCount = LITERAL_SYMBOLS
    while literalCount > 257 and literalLengths[literalCount - 1] == 0 do
      literalCount = literalCount - 1
    end
    local distanceCount = DISTANCE_SYMBOLS
    while distanceCount > 1 and distanceLengths[distanceCount - 1] == 0 do
      distanceCount = distanceCount - 1
    end

    local sequence = {}
    for symbol = 0, literalCount - 1 do
      sequence[symbol + 1] = literalLengths[symbol]
    end
    for symbol = 0, distanceCount - 1 do
      sequence[literalCount + symbol + 1] = distanceLengths[symbol]
    end

    local symbols, extras, count = {}, {}, 0
    local frequencies = {}
    for symbol = 0, CODE_LENGTH_SYMBOLS - 1 do
      frequencies[symbol] = 0
    end
    local function emit(symbol, extra)
      count = count + 1
      symbols[count] = symbol
      extras[count] = extra
      frequencies[symbol] = frequencies[symbol] + 1
    end

    local index, total = 1, #sequence
    while index <= total do
      local length = sequence[index]
      local run = 1
      while index + run <= total and sequence[index + run] == length do
        run = run + 1
      end
      index = index + run
      if length == 0 then
        while run >= 11 do
          local take = math.min(run, 138)
          emit(18, take - 11)
          run = run - take
        end
        if run >= 3 then
          emit(17, run - 3)
          run = 0
        end
      else
        emit(length, 0)
        run = run - 1
        while run >= 3 do
          local take = math.min(run, 6)
          emit(16, take - 3)
          run = run - take
        end
      end
      for _ = 1, run do
        emit(length, 0)
      end
    end

    local codeLengths = huffmanLengths(frequencies, CODE_LENGTH_SYMBOLS, MAX_CODE_LENGTH_BITS)
    local orderCount = CODE_LENGTH_SYMBOLS
    while orderCount > 4 and codeLengths[CODE_LENGTH_ORDER[orderCount]] == 0 do
      orderCount = orderCount - 1
    end

    local bits = 5 + 5 + 4 + 3 * orderCount
    for position = 1, count do
      local symbol = symbols[position]
      bits = bits + codeLengths[symbol]
      if symbol == 16 then
        bits = bits + 2
      elseif symbol == 17 then
        bits = bits + 3
      elseif symbol == 18 then
        bits = bits + 7
      end
    end

    return {
      literalCount = literalCount,
      distanceCount = distanceCount,
      orderCount = orderCount,
      codeLengths = codeLengths,
      symbols = symbols,
      extras = extras,
      symbolCount = count,
      bits = bits,
    }
  end

  ---Write a dynamic block's header after its three block-header bits.
  ---@param compressor table
  ---@param header table
  local function writeDynamicHeader(compressor, header)
    writeBits(compressor, header.literalCount - 257, 5)
    writeBits(compressor, header.distanceCount - 1, 5)
    writeBits(compressor, header.orderCount - 4, 4)
    local codeLengths = header.codeLengths
    for index = 1, header.orderCount do
      writeBits(compressor, codeLengths[CODE_LENGTH_ORDER[index]], 3)
    end
    local codes = canonicalCodes(codeLengths, CODE_LENGTH_SYMBOLS)
    local symbols, extras = header.symbols, header.extras
    for index = 1, header.symbolCount do
      local symbol = symbols[index]
      writeBits(compressor, codes[symbol], codeLengths[symbol])
      if symbol == 16 then
        writeBits(compressor, extras[index], 2)
      elseif symbol == 17 then
        writeBits(compressor, extras[index], 3)
      elseif symbol == 18 then
        writeBits(compressor, extras[index], 7)
      end
    end
  end

  ---Write the current block's tokens and its end-of-block symbol.
  ---@param compressor table
  ---@param literalCodes table<integer, integer>
  ---@param literalLengths table<integer, integer>
  ---@param distanceCodes table<integer, integer>
  ---@param distanceLengths table<integer, integer>
  local function writeTokens(
    compressor,
    literalCodes,
    literalLengths,
    distanceCodes,
    distanceLengths
  )
    local tokenValue, tokenDistance = compressor.tokenValue, compressor.tokenDistance
    for token = 1, compressor.tokenCount do
      local value = tokenValue[token]
      local distance = tokenDistance[token]
      if distance == 0 then
        writeBits(compressor, literalCodes[value], literalLengths[value])
      else
        local index = LENGTH_INDEX[value]
        local symbol = 257 + index
        writeBits(compressor, literalCodes[symbol], literalLengths[symbol])
        local extra = LENGTH_EXTRA[index]
        if extra > 0 then
          writeBits(compressor, value - LENGTH_BASE[index], extra)
        end
        local distanceIndex = distanceSymbol(distance)
        writeBits(compressor, distanceCodes[distanceIndex], distanceLengths[distanceIndex])
        extra = DISTANCE_EXTRA[distanceIndex]
        if extra > 0 then
          writeBits(compressor, distance - DISTANCE_BASE[distanceIndex], extra)
        end
      end
    end
    writeBits(compressor, literalCodes[END_OF_BLOCK], literalLengths[END_OF_BLOCK])
  end

  ---Emit the current block as whichever of stored, fixed and dynamic Huffman
  ---costs the fewest bits, then start the next block.
  ---@param compressor table
  ---@param final boolean
  local function flushBlock(compressor, final)
    local finalBit = final and 1 or 0
    local literalFrequencies = compressor.literalFrequencies
    local distanceFrequencies = compressor.distanceFrequencies

    local literalLengths = huffmanLengths(literalFrequencies, LITERAL_SYMBOLS, MAX_CODE_BITS)
    local distanceLengths = huffmanLengths(distanceFrequencies, DISTANCE_SYMBOLS, MAX_CODE_BITS)
    local header = dynamicHeader(literalLengths, distanceLengths)

    local fixedBits = 3 + compressor.extraBits
    local dynamicBits = 3 + header.bits + compressor.extraBits
    for symbol = 0, LITERAL_SYMBOLS - 1 do
      local frequency = literalFrequencies[symbol]
      if frequency > 0 then
        fixedBits = fixedBits + frequency * FIXED_LITERAL_LENGTHS[symbol]
        dynamicBits = dynamicBits + frequency * literalLengths[symbol]
      end
    end
    for symbol = 0, DISTANCE_SYMBOLS - 1 do
      local frequency = distanceFrequencies[symbol]
      if frequency > 0 then
        fixedBits = fixedBits + frequency * 5
        dynamicBits = dynamicBits + frequency * distanceLengths[symbol]
      end
    end
    local rawLength = compressor.covered - compressor.blockStart + 1
    local padding = (8 - (compressor.bitCount + 3) % 8) % 8
    local storedBits = 3 + padding + 32 + 8 * rawLength

    if storedBits < fixedBits and storedBits < dynamicBits then
      writeBits(compressor, finalBit, 3)
      alignToByte(compressor)
      writeBits(compressor, rawLength, 16)
      writeBits(compressor, 65535 - rawLength, 16)
      if rawLength > 0 then
        putString(compressor.sink, sub(compressor.input, compressor.blockStart, compressor.covered))
      end
    elseif dynamicBits < fixedBits then
      writeBits(compressor, finalBit + 4, 3)
      writeDynamicHeader(compressor, header)
      writeTokens(
        compressor,
        canonicalCodes(literalLengths, LITERAL_SYMBOLS),
        literalLengths,
        canonicalCodes(distanceLengths, DISTANCE_SYMBOLS),
        distanceLengths
      )
    else
      writeBits(compressor, finalBit + 2, 3)
      writeTokens(
        compressor,
        FIXED_LITERAL_CODES,
        FIXED_LITERAL_LENGTHS,
        FIXED_DISTANCE_CODES,
        FIXED_DISTANCE_LENGTHS
      )
    end
    resetBlock(compressor)
  end

  ---End the block when it holds enough tokens or covers enough input.
  ---@param compressor table
  local function checkBlockFull(compressor)
    if
      compressor.tokenCount >= BLOCK_MAX_TOKENS
      or compressor.covered - compressor.blockStart + 1 >= BLOCK_MAX_BYTES
    then
      flushBlock(compressor, false)
    end
  end

  ---@param compressor table
  ---@param value integer the literal byte
  local function emitLiteral(compressor, value)
    local token = compressor.tokenCount + 1
    compressor.tokenValue[token] = value
    compressor.tokenDistance[token] = 0
    compressor.tokenCount = token
    local literalFrequencies = compressor.literalFrequencies
    literalFrequencies[value] = literalFrequencies[value] + 1
    compressor.covered = compressor.covered + 1
    checkBlockFull(compressor)
  end

  ---@param compressor table
  ---@param length integer 3 to 258
  ---@param distance integer 1 to 32768
  local function emitMatch(compressor, length, distance)
    local token = compressor.tokenCount + 1
    compressor.tokenValue[token] = length
    compressor.tokenDistance[token] = distance
    compressor.tokenCount = token
    local index = LENGTH_INDEX[length]
    local literalFrequencies = compressor.literalFrequencies
    literalFrequencies[257 + index] = literalFrequencies[257 + index] + 1
    local distanceIndex = distanceSymbol(distance)
    local distanceFrequencies = compressor.distanceFrequencies
    distanceFrequencies[distanceIndex] = distanceFrequencies[distanceIndex] + 1
    compressor.extraBits = compressor.extraBits
      + LENGTH_EXTRA[index]
      + DISTANCE_EXTRA[distanceIndex]
    compressor.covered = compressor.covered + length
    checkBlockFull(compressor)
  end

  ---Record `position` in the hash chain of the three bytes starting there. The
  ---key is the three bytes themselves, so every chain entry is a true
  ---three-byte match and no candidate needs re-checking.
  ---@param compressor table
  ---@param position integer
  local function insertPosition(compressor, position)
    if position + 2 > compressor.length then
      return
    end
    local data = compressor.data
    local key = (data[position] * 256 + data[position + 1]) * 256 + data[position + 2]
    local head = compressor.head
    compressor.previous[position % WINDOW_SIZE] = head[key]
    head[key] = position
  end

  ---Find the longest match for `position` that is longer than `minimum`,
  ---following at most the level's chain length back through the window.
  ---@param compressor table
  ---@param position integer
  ---@param minimum integer
  ---@return integer length 0 when nothing longer was found
  ---@return integer distance
  local function findMatch(compressor, position, minimum)
    local data = compressor.data
    local maxLength = compressor.length - position + 1
    if maxLength > MAX_MATCH then
      maxLength = MAX_MATCH
    end
    if maxLength < MIN_MATCH or minimum >= maxLength then
      return 0, 0
    end
    local key = (data[position] * 256 + data[position + 1]) * 256 + data[position + 2]
    local candidate = compressor.head[key]
    local previous = compressor.previous
    local limit = position - WINDOW_SIZE
    local chain = compressor.chain
    if minimum >= compressor.good then
      chain = floor(chain / 4)
    end
    local nice = compressor.nice
    local best, bestDistance = minimum, 0

    while candidate ~= nil and candidate >= limit and chain > 0 do
      if data[candidate + best] == data[position + best] then
        local length = MIN_MATCH
        while length < maxLength and data[candidate + length] == data[position + length] do
          length = length + 1
        end
        if length > best then
          best = length
          bestDistance = position - candidate
          if length >= nice or length >= maxLength then
            break
          end
        end
      end
      local earlier = previous[candidate % WINDOW_SIZE]
      if earlier == nil or earlier >= candidate then
        break
      end
      candidate = earlier
      chain = chain - 1
    end

    if bestDistance == 0 then
      return 0, 0
    end
    return best, bestDistance
  end

  ---Tokenise greedily: take every match found (levels 1 to 3).
  ---@param compressor table
  local function tokenizeGreedy(compressor)
    local data, length = compressor.data, compressor.length
    local work = compressor.work
    local position = 1
    local nextPause = PAUSE_POSITIONS
    while position <= length do
      if work.context and position >= nextPause then
        pause(work)
        nextPause = position + PAUSE_POSITIONS
      end
      local matchLength, distance = findMatch(compressor, position, MIN_MATCH - 1)
      insertPosition(compressor, position)
      if matchLength == MIN_MATCH and distance > TOO_FAR then
        matchLength = 0
      end
      if matchLength >= MIN_MATCH then
        emitMatch(compressor, matchLength, distance)
        local last = position + matchLength - 1
        if matchLength <= compressor.lazyLimit then
          for inside = position + 1, last do
            insertPosition(compressor, inside)
          end
        end
        position = last + 1
      else
        emitLiteral(compressor, data[position])
        position = position + 1
      end
    end
  end

  ---Tokenise with lazy matching (levels 4 to 9): a match is held back one byte
  ---and dropped for a literal when the next position starts a longer one.
  ---@param compressor table
  local function tokenizeLazy(compressor)
    local data, length = compressor.data, compressor.length
    local work = compressor.work
    local lazyLimit = compressor.lazyLimit
    local position = 1
    local nextPause = PAUSE_POSITIONS
    local previousLength, previousDistance = 0, 0
    local pending = false
    while position <= length do
      if work.context and position >= nextPause then
        pause(work)
        nextPause = position + PAUSE_POSITIONS
      end
      local matchLength, distance = 0, 0
      if previousLength < lazyLimit then
        matchLength, distance =
          findMatch(compressor, position, math.max(previousLength, MIN_MATCH - 1))
        if matchLength == MIN_MATCH and distance > TOO_FAR then
          matchLength = 0
        end
      end
      insertPosition(compressor, position)

      if previousLength >= MIN_MATCH and matchLength <= previousLength then
        -- The held match, which starts at the previous position, wins.
        emitMatch(compressor, previousLength, previousDistance)
        local last = position + previousLength - 2
        for inside = position + 1, last do
          insertPosition(compressor, inside)
        end
        position = last + 1
        pending = false
        previousLength, previousDistance = 0, 0
      else
        if pending then
          emitLiteral(compressor, data[position - 1])
        end
        pending = true
        previousLength, previousDistance = matchLength, distance
        position = position + 1
      end
    end
    if pending then
      emitLiteral(compressor, data[position - 1])
    end
  end

  -- Below this many input bytes the compressor skips matching and writes
  -- one fixed-Huffman block of literals (or a stored block, when smaller).
  -- Short addon messages rarely repeat anything, and the full path would
  -- allocate several kilobytes of hash, token and code tables per call.
  local TINY_INPUT_BYTES = 64

  ---Compress a short input as one literal-only fixed block, or one stored
  ---block when that is smaller, without the matcher's working tables.
  ---@param work table
  ---@param sink table
  ---@param input string
  ---@param length integer
  local function compressTiny(work, sink, input, length)
    local fixedBits = 3 + FIXED_LITERAL_LENGTHS[END_OF_BLOCK]
    for index = 1, length do
      fixedBits = fixedBits + FIXED_LITERAL_LENGTHS[byte(input, index)]
    end
    local storedBits = 3 + 5 + 32 + 8 * length

    local writer = leaseTable(work.pooled)
    writer.sink = sink
    writer.bitBuffer = 0
    writer.bitCount = 0
    if storedBits < fixedBits then
      writeBits(writer, 1, 3)
      alignToByte(writer)
      writeBits(writer, length, 16)
      writeBits(writer, 65535 - length, 16)
      putString(sink, input)
    else
      writeBits(writer, 3, 3)
      for index = 1, length do
        local value = byte(input, index)
        writeBits(writer, FIXED_LITERAL_CODES[value], FIXED_LITERAL_LENGTHS[value])
      end
      writeBits(writer, FIXED_LITERAL_CODES[END_OF_BLOCK], FIXED_LITERAL_LENGTHS[END_OF_BLOCK])
      alignToByte(writer)
    end
    returnTable(work.pooled, writer)
  end

  ---Compress `input` as raw DEFLATE into `sink`.
  ---@param work table
  ---@param sink table
  ---@param input string
  ---@param level integer 1 to 9
  function compressInto(work, sink, input, level)
    if not tablesBuilt then
      buildTables()
    end
    local settings = LEVELS[level]
    local length = #input
    if length < TINY_INPUT_BYTES then
      compressTiny(work, sink, input, length)
      return
    end
    local data = {}
    for index = 1, length, 8 do
      local a, b, c, d, e, f, g, h = byte(input, index, index + 7)
      data[index], data[index + 1], data[index + 2], data[index + 3] = a, b, c, d
      data[index + 4], data[index + 5], data[index + 6], data[index + 7] = e, f, g, h
    end

    local compressor = {
      work = work,
      sink = sink,
      input = input,
      data = data,
      length = length,
      head = {},
      previous = {},
      chain = settings.chain,
      good = settings.good,
      nice = settings.nice,
      lazyLimit = settings.lazyLimit,
      tokenValue = {},
      tokenDistance = {},
      tokenCount = 0,
      literalFrequencies = {},
      distanceFrequencies = {},
      extraBits = 0,
      covered = 0,
      blockStart = 1,
      bitBuffer = 0,
      bitCount = 0,
    }
    resetBlock(compressor)
    if settings.lazy then
      tokenizeLazy(compressor)
    else
      tokenizeGreedy(compressor)
    end
    flushBlock(compressor, true)
    alignToByte(compressor)
  end

  -- Decompressor ---------------------------------------------------------------
  --
  -- A reader record holds the input, the next byte position and a bit buffer
  -- that is refilled one byte at a time. Every read is bounds-checked, so a
  -- malformed stream ends in a reason, never in a Lua error.

  ---Make at least `wanted` bits available; `false` when the input ends first
  ---(whatever could be read stays in the buffer).
  ---@param reader table
  ---@param wanted integer
  ---@return boolean
  local function fillBits(reader, wanted)
    local count = reader.bitCount
    if count >= wanted then
      return true
    end
    local input, position, buffer = reader.input, reader.position, reader.bitBuffer
    local available = true
    while count < wanted do
      local value = byte(input, position)
      if value == nil then
        available = false
        break
      end
      buffer = buffer + value * POW2[count]
      count = count + 8
      position = position + 1
    end
    reader.position, reader.bitBuffer, reader.bitCount = position, buffer, count
    return available
  end

  ---Read `count` bits as an integer, least significant first; `nil` when the
  ---input ends.
  ---@param reader table
  ---@param count integer
  ---@return integer|nil
  local function readBits(reader, count)
    if count == 0 then
      return 0
    end
    if not fillBits(reader, count) then
      return nil
    end
    local scale = POW2[count]
    local buffer = reader.bitBuffer
    local value = buffer % scale
    reader.bitBuffer = (buffer - value) / scale
    reader.bitCount = reader.bitCount - count
    return value
  end

  ---Decode one Huffman symbol.
  ---@param reader table
  ---@param decoder table
  ---@return integer|nil symbol
  ---@return string|nil reason
  local function readSymbol(reader, decoder)
    local maxLength = decoder.maxLength
    fillBits(reader, maxLength)
    local buffer, available = reader.bitBuffer, reader.bitCount
    local lookup = decoder.lookup
    local longest = maxLength
    if available < longest then
      longest = available
    end
    for length = decoder.minLength, longest do
      local scale = POW2[length]
      local low = buffer % scale
      local symbol = lookup[scale + low]
      if symbol ~= nil then
        reader.bitBuffer = (buffer - low) / scale
        reader.bitCount = available - length
        return symbol
      end
    end
    if available < maxLength then
      return nil, REASON.truncated
    end
    return nil, REASON.malformedDeflate
  end

  ---Read a dynamic block's code tables (RFC 1951 3.2.7).
  ---@param reader table
  ---@return table|nil literalDecoder `nil` when the tables are refused
  ---@return table|false|nil distanceDecoder `false` when the block has no distance codes
  ---@return string|nil reason
  local function readDynamicTables(reader)
    local literalCount = readBits(reader, 5)
    local distanceCount = readBits(reader, 5)
    local orderCount = readBits(reader, 4)
    if literalCount == nil or distanceCount == nil or orderCount == nil then
      return nil, nil, REASON.truncated
    end
    literalCount = literalCount + 257
    distanceCount = distanceCount + 1
    orderCount = orderCount + 4
    if literalCount > LITERAL_SYMBOLS or distanceCount > DISTANCE_SYMBOLS then
      return nil, nil, REASON.malformedDeflate
    end

    local codeLengths = {}
    for symbol = 0, CODE_LENGTH_SYMBOLS - 1 do
      codeLengths[symbol] = 0
    end
    for index = 1, orderCount do
      local length = readBits(reader, 3)
      if length == nil then
        return nil, nil, REASON.truncated
      end
      codeLengths[CODE_LENGTH_ORDER[index]] = length
    end
    local codeLengthDecoder = buildDecoder(codeLengths, CODE_LENGTH_SYMBOLS)
    if not codeLengthDecoder then
      return nil, nil, REASON.malformedDeflate
    end

    local lengths = {}
    local total = literalCount + distanceCount
    local index = 0
    while index < total do
      local symbol, reason = readSymbol(reader, codeLengthDecoder)
      if symbol == nil then
        return nil, nil, reason
      end
      if symbol < 16 then
        lengths[index] = symbol
        index = index + 1
      else
        local repeated, extra
        if symbol == 16 then
          if index == 0 then
            return nil, nil, REASON.malformedDeflate
          end
          repeated = lengths[index - 1]
          extra = readBits(reader, 2)
          extra = extra and extra + 3
        elseif symbol == 17 then
          repeated = 0
          extra = readBits(reader, 3)
          extra = extra and extra + 3
        else
          repeated = 0
          extra = readBits(reader, 7)
          extra = extra and extra + 11
        end
        if extra == nil then
          return nil, nil, REASON.truncated
        end
        if index + extra > total then
          return nil, nil, REASON.malformedDeflate
        end
        for _ = 1, extra do
          lengths[index] = repeated
          index = index + 1
        end
      end
    end

    if lengths[END_OF_BLOCK] == 0 then
      return nil, nil, REASON.malformedDeflate
    end
    local distanceLengths = {}
    for symbol = 0, distanceCount - 1 do
      distanceLengths[symbol] = lengths[literalCount + symbol]
    end
    local literalDecoder = buildDecoder(lengths, literalCount)
    local distanceDecoder = buildDecoder(distanceLengths, distanceCount)
    if not literalDecoder or distanceDecoder == nil then
      return nil, nil, REASON.malformedDeflate
    end
    return literalDecoder, distanceDecoder
  end

  ---Inflate one Huffman-coded block into `output`.
  ---@param work table
  ---@param reader table
  ---@param output integer[]
  ---@param outputLength integer
  ---@param literalDecoder table
  ---@param distanceDecoder table|false|nil
  ---@return integer|nil outputLength
  ---@return string|nil reason
  local function inflateCodes(work, reader, output, outputLength, literalDecoder, distanceDecoder)
    local limit = work.maxOutputBytes
    local context = work.context
    local untilPause = PAUSE_SYMBOLS
    while true do
      if context then
        untilPause = untilPause - 1
        if untilPause == 0 then
          pause(work)
          untilPause = PAUSE_SYMBOLS
        end
      end
      local symbol, reason = readSymbol(reader, literalDecoder)
      if symbol == nil then
        return nil, reason
      end
      if symbol < END_OF_BLOCK then
        if outputLength >= limit then
          return nil, REASON.maxOutputBytes
        end
        outputLength = outputLength + 1
        output[outputLength] = symbol
      elseif symbol == END_OF_BLOCK then
        return outputLength
      else
        local index = symbol - 257
        if index > 28 or not distanceDecoder then
          return nil, REASON.malformedDeflate
        end
        local extra = readBits(reader, LENGTH_EXTRA[index])
        if extra == nil then
          return nil, REASON.truncated
        end
        local length = LENGTH_BASE[index] + extra
        local distanceIndex
        distanceIndex, reason = readSymbol(reader, distanceDecoder)
        if distanceIndex == nil then
          return nil, reason
        end
        if distanceIndex >= DISTANCE_SYMBOLS then
          return nil, REASON.malformedDeflate
        end
        extra = readBits(reader, DISTANCE_EXTRA[distanceIndex])
        if extra == nil then
          return nil, REASON.truncated
        end
        local distance = DISTANCE_BASE[distanceIndex] + extra
        if distance > outputLength then
          return nil, REASON.malformedDeflate
        end
        if outputLength + length > limit then
          return nil, REASON.maxOutputBytes
        end
        local from = outputLength - distance
        for offset = 1, length do
          output[outputLength + offset] = output[from + offset]
        end
        outputLength = outputLength + length
      end
    end
  end

  ---Copy one stored block into `output`.
  ---@param work table
  ---@param reader table
  ---@param output integer[]
  ---@param outputLength integer
  ---@return integer|nil outputLength
  ---@return string|nil reason
  local function inflateStored(work, reader, output, outputLength)
    local drop = reader.bitCount % 8
    if drop > 0 then
      readBits(reader, drop)
    end
    local length = readBits(reader, 16)
    local complement = readBits(reader, 16)
    if length == nil or complement == nil then
      return nil, REASON.truncated
    end
    if length + complement ~= 65535 then
      return nil, REASON.malformedDeflate
    end
    -- Give back the whole bytes the bit buffer read ahead: they are the first
    -- bytes of the stored data.
    local position = reader.position - reader.bitCount / 8
    reader.bitBuffer, reader.bitCount = 0, 0
    if position + length - 1 > reader.inputLength then
      return nil, REASON.truncated
    end
    if outputLength + length > work.maxOutputBytes then
      return nil, REASON.maxOutputBytes
    end
    local input = reader.input
    for offset = 0, length - 1 do
      output[outputLength + 1 + offset] = byte(input, position + offset)
    end
    reader.position = position + length
    return outputLength + length
  end

  ---Inflate a raw DEFLATE stream into `sink`.
  ---@param work table
  ---@param sink table
  ---@param input string
  ---@return boolean ok
  ---@return string|nil reason
  function inflateInto(work, sink, input)
    if not tablesBuilt then
      buildTables()
    end
    local reader = {
      input = input,
      inputLength = #input,
      position = 1,
      bitBuffer = 0,
      bitCount = 0,
    }
    local output = {}
    local outputLength = 0
    local final = false
    while not final do
      local header = readBits(reader, 3)
      if header == nil then
        return false, REASON.truncated
      end
      final = header % 2 == 1
      local blockType = (header - header % 2) / 2
      local newLength, reason
      if blockType == 0 then
        newLength, reason = inflateStored(work, reader, output, outputLength)
      elseif blockType == 1 then
        newLength, reason = inflateCodes(
          work,
          reader,
          output,
          outputLength,
          FIXED_LITERAL_DECODER,
          FIXED_DISTANCE_DECODER
        )
      elseif blockType == 2 then
        local literalDecoder, distanceDecoder, tableReason = readDynamicTables(reader)
        if literalDecoder == nil then
          return false, tableReason
        end
        newLength, reason =
          inflateCodes(work, reader, output, outputLength, literalDecoder, distanceDecoder)
      else
        return false, REASON.malformedDeflate
      end
      if newLength == nil then
        return false, reason
      end
      outputLength = newLength
    end

    local unread = floor(reader.bitCount / 8)
    if reader.position - 1 - unread < reader.inputLength then
      return false, REASON.trailingData
    end

    for first = 1, outputLength, SINK_BATCH_SIZE do
      local last = first + SINK_BATCH_SIZE - 1
      if last > outputLength then
        last = outputLength
      end
      appendFragment(sink, char(unpack(output, first, last)))
    end
    return true
  end
end

-- Native compressor ----------------------------------------------------------
--
-- Where the client has `C_EncodingUtil.CompressString`, the compression stage
-- runs there with `Enum.CompressionMethod.Deflate`: raw DEFLATE (RFC 1951),
-- the format the Lua compressor writes, made by native code tens of times
-- faster. The frame is unchanged, version 1 with the deflate flag, and the
-- inflater of every revision reads any conforming raw DEFLATE stream, so a
-- peer on an older revision decodes it. The bytes differ from the Lua
-- compressor's; docs/API.md already says encoded bytes are not a content
-- hash.
--
-- Inflation stays in Lua. A frame carries no declared size, checksum or end
-- marker of its own, so nothing could tell whether the native inflater
-- accepted a stream (bytes after the final block, say) that the Lua inflater
-- refuses with a documented reason. docs/INTERNALS.md records the client
-- check a later revision needs first.

local compressNatively

do
  -- Below this many bytes the Lua compressor writes one literal or stored
  -- block without allocating anything but its output, which is what addon
  -- messages mostly are; a native call would not be cheaper there.
  local NATIVE_MINIMUM_BYTES = 64

  -- An asynchronous call takes the native compressor up to this much input.
  -- One native call cannot yield, so a larger input stays on the Lua
  -- compressor, which yields between slices of the frame budget.
  local ASYNC_NATIVE_MAXIMUM_BYTES = 262144

  -- The value `EncodingUtilDocumentation.lua` gives
  -- `Enum.CompressionMethod.Deflate` on every flavour, used when the client's
  -- `Enum` does not answer. The level numbers are in `readClientLevel`.
  local DOCUMENTED_DEFLATE_METHOD = 0

  ---Read `Enum.<enumName>.<fieldName>` from the client, or `documented` when
  ---the client has no such number. A value the secret probe reports is never
  ---handed on: like every value the client answers, it is asked about before
  ---anything uses it.
  ---@param isSecret function|false the call's `issecretvalue`, if any
  ---@param enumName string
  ---@param fieldName string
  ---@param documented integer
  ---@return integer
  local function readEnumValue(isSecret, enumName, fieldName, documented)
    -- Enum is a World of Warcraft client table reachable only through the global table.
    -- selene: allow(global_usage)
    local enums = rawget(_G, "Enum")
    local enum = type(enums) == "table" and rawget(enums, enumName) or nil
    local value = type(enum) == "table" and rawget(enum, fieldName) or nil
    if type(value) == "number" and not (isSecret and isSecret(value)) then
      return value
    end
    return documented
  end

  ---The client's `Enum.CompressionLevel` value for CodecKit's `level`: 1 to 3
  ---favour speed, as the greedy Lua levels do, 4 to 6 are the client's
  ---default, and 7 to 9 favour size. Each field is named literally, with the
  ---number `EncodingUtilDocumentation.lua` documents for it.
  ---@param isSecret function|false the call's `issecretvalue`, if any
  ---@param level integer 1 to 9
  ---@return integer
  local function readClientLevel(isSecret, level)
    if level <= 3 then
      return readEnumValue(isSecret, "CompressionLevel", "OptimizeForSpeed", 1)
    end
    if level <= 6 then
      return readEnumValue(isSecret, "CompressionLevel", "Default", 0)
    end
    return readEnumValue(isSecret, "CompressionLevel", "OptimizeForSize", 2)
  end

  ---Return the client's `C_EncodingUtil.CompressString`, or `nil`. Read at
  ---every call, as `issecretvalue` is, so nothing is cached in the package
  ---state an upgrade hands over.
  ---@return function|nil
  local function readCompressString()
    -- C_EncodingUtil is a World of Warcraft client API reachable only through the global table.
    -- selene: allow(global_usage)
    local encodingUtil = rawget(_G, "C_EncodingUtil")
    if type(encodingUtil) ~= "table" then
      return nil
    end
    local compressString = rawget(encodingUtil, "CompressString")
    if type(compressString) ~= "function" then
      return nil
    end
    return compressString
  end

  ---Compress `bytes` with the client's compressor, or answer `nil` when the
  ---Lua compressor must run instead: a short input, an asynchronous call over
  ---`ASYNC_NATIVE_MAXIMUM_BYTES`, a client without the function, or a native
  ---call that raised, returned nothing, returned something other than a
  ---non-empty string, returned a secret, or returned more than
  ---`maxOutputBytes`. In every such case the Lua compressor decides, so a
  ---refusal is exactly the one the Lua path gives.
  ---@param work table
  ---@param bytes string
  ---@param level integer 1 to 9
  ---@return string|nil compressed
  function compressNatively(work, bytes, level)
    local length = #bytes
    if length < NATIVE_MINIMUM_BYTES then
      return nil
    end
    if work.context and length > ASYNC_NATIVE_MAXIMUM_BYTES then
      return nil
    end
    local compressString = readCompressString()
    if type(compressString) ~= "function" then
      return nil
    end
    local isSecret = work.isSecret
    local method =
      readEnumValue(isSecret, "CompressionMethod", "Deflate", DOCUMENTED_DEFLATE_METHOD)
    local nativeLevel = readClientLevel(isSecret, level)
    -- The function and its arguments go to pcall directly, so no closure is
    -- made per call. The client documents that it may return nothing.
    local ok, result = pcall(compressString, bytes, method, nativeLevel)
    if not ok or type(result) ~= "string" then
      return nil
    end
    -- The answer is asked about before `#` or the frame touches it: a secret
    -- body would make the whole frame a secret no peer could send.
    if isSecret and isSecret(result) then
      return nil
    end
    local resultLength = #result
    if resultLength == 0 or resultLength > work.maxOutputBytes then
      return nil
    end
    return result
  end
end

-- Compression stage ----------------------------------------------------------

---Compress `bytes` into a string, bounded by `maxOutputBytes` on both sides:
---natively where the client can, otherwise with the Lua compressor.
---@param work table
---@param bytes string
---@param level integer
---@return boolean ok
---@return string bytesOrReason
local function compressBytes(work, bytes, level)
  if #bytes > work.maxOutputBytes then
    return false, REASON.maxOutputBytes
  end
  local native = compressNatively(work, bytes, level)
  if type(native) == "string" then
    return true, native
  end
  local sink = openSink(work.pooled)
  compressInto(work, sink, bytes, level)
  local result = finishSink(sink)
  if #result > work.maxOutputBytes then
    return false, REASON.maxOutputBytes
  end
  return true, result
end

---Inflate `bytes` into a string, bounded by `maxOutputBytes`.
---@param work table
---@param bytes string
---@return boolean ok
---@return string bytesOrReason
local function decompressBytes(work, bytes)
  if #bytes > work.maxOutputBytes then
    return false, REASON.maxOutputBytes
  end
  local sink = openSink(work.pooled)
  local ok, reason = inflateInto(work, sink, bytes)
  if not ok then
    closeSink(sink)
    return false, reason --[[@as string]]
  end
  return true, finishSink(sink)
end

-- Commit ---------------------------------------------------------------------

---The core's `compress` entry: bind the helpers, then compress.
---@param work table
---@param bytes string
---@param level integer
---@return boolean ok
---@return string bytesOrReason
local function compressStage(work, bytes, level)
  bindHelpers()
  local ok, result = compressBytes(work, bytes, level)
  return ok, result
end

---The core's `decompress` entry: bind the helpers, then inflate.
---@param work table
---@param bytes string
---@return boolean ok
---@return string bytesOrReason
local function decompressStage(work, bytes)
  bindHelpers()
  local ok, result = decompressBytes(work, bytes)
  return ok, result
end

rawset(compression, "compress", compressStage)
rawset(compression, "decompress", decompressStage)
rawset(parts, PART_NAME, { revision = PART_REVISION })

return CodecKit
