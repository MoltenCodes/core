# CodecKit API

CodecKit API generation **1** turns Lua values into transport-safe strings and back in three composable stages — serialise, compress, channel-encode — behind a two-byte, self-describing header. Decoding never raises on malformed input.

Implementation revision: **1**. Wire format version: **1** (`CodecKit.FORMAT_VERSION`).

## Loading

Runtime files must be loaded in dependency order:

```text
Registry.lua
PoolKit.lua
CodecKit.lua
```

CodecKit depends on Registry API 2 and PoolKit API 1. Portable WoW code resolves the package through Registry:

```lua
local CodecKit = MoltenCodes.Registry:Get("codecKit", 1)
```

CodecKit does not rely on `require()` at runtime. Loading it without Registry raises `MoltenCodes CodecKit requires Registry API 2 to be loaded first`; without PoolKit, `MoltenCodes CodecKit requires PoolKit API 1 to be loaded first`.

### Optional facilities

| Facility | Used by | Without it |
|---|---|---|
| SchedulerKit API 1 | `EncodeAsync`, `DecodeAsync` | Both raise at the caller: `CodecKit:EncodeAsync requires SchedulerKit API 1, which is not loaded (absent)`. Everything else works. |
| `issecretvalue` | refusing secret values | Nothing is treated as secret. |

SchedulerKit is found with `Registry:Find("schedulerKit", 1)` when an asynchronous method is called, so it may load in any order. `issecretvalue` is looked up at every call, as SchemaKit does.

## Public surface

| Member | Returns | Purpose |
|---|---|---|
| `Encode(value[, options])` | `true, text` or `false, reason` | Serialise one value, then compress and channel-encode as `options` says. |
| `Decode(text[, options])` | `true, value` or `false, reason` | Reverse whatever stages the header names. Never raises on malformed text. |
| `EncodeMany(options, ...)` | `true, text` or `false, reason` | Encode an argument list of at most `maxListValues` values (4096 by default); `nil`s, trailing ones included, survive. `options` is always the first argument and may be `nil`. |
| `DecodeMany(text[, options])` | `true, ...` or `false, reason` | Decode a list into as many values as were encoded; a single-value frame gives one value. Never raises on malformed text. |
| `Serialize(value)` | `true, bytes` or `false, reason` | Stage 1 alone, without a header. |
| `Deserialize(bytes)` | `true, value` or `false, reason` | Its inverse. |
| `Compress(bytes[, options])` | `true, bytes` or `false, reason` | Stage 2 alone: raw DEFLATE. `options.level` from 1 to 9. |
| `Decompress(bytes)` | `true, bytes` or `false, reason` | Its inverse; also inflates raw DEFLATE from other encoders. |
| `EncodeForAddon(bytes)` / `DecodeForAddon(text)` | `true, string` or `false, reason` | Stage 3 for the addon channel. |
| `EncodeForPrint(bytes)` / `DecodeForPrint(text)` | `true, string` or `false, reason` | Stage 3 for chat and export strings. |
| `EncodeAsync(value, options, scope, callback)` | the SchedulerKit job | `Encode` in slices on a SchedulerKit scope; `callback(ok, textOrReason)`. |
| `DecodeAsync(text, options, scope, callback)` | the SchedulerKit job | `Decode` in slices; `callback(ok, valueOrReason)`. |
| `SetLimits(limits)` | nothing | Change any subset of the shared limits. |
| `GetLimits()` | a fresh table | The five limits; `UNBOUNDED` where one was lifted. |
| `UNBOUNDED` | a table | The sentinel `SetLimits` accepts for `maxValues` and `maxStringLength` (see [Limits](#limits)). |
| `FORMAT_VERSION` | `1` | The frame version this copy writes and reads. |
| `PRINT_ALPHABET` | a string | The 85 print characters, digit 0 first. |
| `API`, `REVISION` | integers | API generation and implementation revision. |

### Options

| Option | Accepted by | Values | Default |
|---|---|---|---|
| `compress` | `Encode`, `EncodeMany`, `EncodeAsync` | `"none"`, `"deflate"` | `"none"` |
| `channel` | the same | `"none"`, `"addon"`, `"print"` | `"none"` |
| `level` | the same, and `Compress` | integer 1 (fastest) to 9 (smallest) | 6 |
| `channel` | `Decode`, `DecodeMany`, `DecodeAsync` | `"none"`, `"addon"`, `"print"` | not checked |

A decoder does not need options: the header says which stages to reverse. `options.channel` on a decoder is an assertion — a frame encoded for any other channel is refused with `"channelMismatch"`, so a handler for addon messages can refuse a pasted export string. An unknown option key, or a value outside its set, raises at the caller.

## The non-raising contract

Every method returns `false, reason` for a value it cannot encode and for any string it cannot decode, whatever the string contains: truncated, corrupted, random, hostile or made by a future version. Nothing a string can contain makes a decoder raise, run unbounded, or allocate beyond the limits.

What does raise, at the caller's line, is a programming error: a method called with `.` instead of `:`, a non-string where a string is required, an unknown option, a limit out of range, a secret value (see [Secret values](#secret-values)), and the asynchronous methods without SchedulerKit or with something other than an open SchedulerKit scope.

The reasons form a fixed vocabulary:

| Reason | Where | Meaning |
|---|---|---|
| `"cycle"` | encode | A table contains itself, directly or through any chain of tables (keys included). |
| `"unsupportedType"` | encode | A function, userdata or thread, as a value or a key. |
| `"maxDepth"` | both | Tables nest deeper than `maxDepth`. |
| `"maxValues"` | both | More than `maxValues` values, keys and list entries included, or an argument list of more than `maxListValues` entries. |
| `"maxStringLength"` | both | One string, value or key, is longer than `maxStringLength`. |
| `"maxOutputBytes"` | both | A stage's output (or a decoding stage's input) is larger than `maxOutputBytes`. |
| `"truncated"` | decode | The input ends inside a header, a value or a DEFLATE stream. |
| `"trailingData"` | decode | Bytes follow a complete value or a final DEFLATE block. |
| `"unsupportedVersion"` | decode | The version byte (the first byte, or the first decoded byte of a print frame) is not 1, or the first byte is neither `0x01`, a print character nor whitespace. |
| `"malformedHeader"` | decode | Reserved flag bits set, the serialised bit clear, both channel bits set, or the channel bit contradicting how the frame arrived. |
| `"channelMismatch"` | decode | `options.channel` differs from the frame's channel. |
| `"forbiddenByte"` | decode | Addon-channel text holds a byte the channel cannot carry. |
| `"malformedEscape"` | decode | The escape byte is not followed by one of its five codes. |
| `"malformedPrint"` | decode | A character outside the alphabet, a single dangling character, or a group above 2^32 − 1. |
| `"malformedDeflate"` | decode | An invalid block type, stored length, code table, symbol or distance. |
| `"unknownType"` | decode | An unassigned type byte (including a list anywhere but at the top). |
| `"malformedNumber"` | decode | A varint longer than eight bytes, above 2^53 or overlong, or a negative integer of magnitude 0. |
| `"invalidKey"` | decode | A table key that is `nil` or NaN. |
| `"duplicateKey"` | decode | The same key twice in one table. |
| `"nilValue"` | decode | `nil` as an array element or a map value. |
| `"multipleValues"` | decode | `Decode` or `Deserialize` given an argument list; use `DecodeMany`. |
| `"secret"` | `EncodeAsync` callback only | The value was changed after the call and now holds a secret. |

## Wire format

Everything below is normative. **The writer is canonical**: it produces exactly the encodings described here, and an implementation that writes anything else is not version 1. **The reader is lenient**: it accepts any *well-formed* frame, including encodings this writer never produces, and refuses everything else with a reason. See [Well-formed input](#well-formed-input).

### Frames

A frame is `version`, `flags`, then the body.

| Byte | Content |
|---|---|
| 1 | `0x01`, the version. |
| 2 | The stage flags. |
| 3 … | The body: the output of the last stage the flags name. |

The flags byte:

| Bit | Value | Meaning |
|---|---|---|
| 0 | `0x01` | Serialised. Always set in version 1, which also keeps the byte odd and non-zero. |
| 1 | `0x02` | The serialised bytes were compressed with raw DEFLATE. |
| 2 | `0x04` | The body is escaped for the addon channel. |
| 3 | `0x08` | The frame is encoded for the print channel. |
| 4–7 | | Reserved; must be zero. |

Bits 2 and 3 are exclusive. The valid version 1 flags are therefore `0x01`, `0x03`, `0x05`, `0x07`, `0x09` and `0x0B`.

The stages run in a fixed order: serialise, then compress when bit 1 is set, then the channel encoding. How the channel treats the header:

- **none**: `01 flags body`.
- **addon**: `01 flags escape(body)`. The header is written unescaped; `0x01`, `0x05` and `0x07` are never among the escaped bytes.
- **print**: `print(01 flags body)`. The whole frame, header included, is print-encoded, so every character is printable. A version 1 print frame always begins with `!`, the digit 0, because the first group starts with the byte `0x01`.

A decoder reads the first byte: `0x01` means a binary or addon frame, whose flags must not have bit 3; a print character or whitespace means a print frame, which is decoded first and must then carry version `0x01` and bit 3; anything else is `"unsupportedVersion"`.

### Extension rules

- An incompatible change of any stage is a new version byte. A binary version byte must stay outside the print alphabet and the six whitespace bytes (tab, line feed, vertical tab, form feed, carriage return, space), and must be a byte the addon channel carries unescaped, because the header is never escaped: `0x02`–`0x08` and `0x0E`–`0x1F` qualify. A print frame carries its version in its first decoded byte.
- A compatible addition within version 1 uses a reserved flag bit or an unassigned type byte. Version 1 decoders refuse both (`"malformedHeader"`, `"unknownType"`), so an addition is only compatible with decoders that know it, and a sender that needs older receivers must not use it.
- Type bytes `0x0C` to `0xFF` and `0x00` are unassigned.

### Serialised values

Every value is one type byte followed by its payload:

| Type byte | Value | Payload |
|---|---|---|
| `0x01` | `nil` | none |
| `0x02` | `false` | none |
| `0x03` | `true` | none |
| `0x04` | a non-negative integer up to 2^53 | varint |
| `0x05` | a negative integer down to −2^53 | varint of the magnitude, never 0 |
| `0x06` | any other number | eight bytes, IEEE-754 binary64, big-endian |
| `0x07` | a string | varint length, then the raw bytes |
| `0x08` | a table with only an array part | varint `n`, then `n` values |
| `0x09` | a table with only a map part | varint `m`, then `m` key, value pairs |
| `0x0A` | a table with both | varint `n`, `n` values, varint `m`, `m` key, value pairs |
| `0x0B` | an argument list (top level only) | varint `n` (at most `maxListValues`), then `n` values, which may be `nil` |

**Varint.** Seven bits per byte, least significant group first; the high bit is set on every byte but the last. At most eight bytes, at most 2^53, and never overlong (a last byte of zero after the first byte is refused). `300` is `AC 02`.

**Numbers.** An integral number from −2^53 to 2^53 other than −0 is written as `0x04`/`0x05` and a varint. Everything else — fractions, integers beyond 2^53, both infinities, NaN, −0 and subnormal numbers — is the exact binary64 bit pattern, computed with `math.frexp`, so it round-trips bit for bit (NaN is written as the quiet NaN `7F F8 00 00 00 00 00 00` whatever its payload). Examples: `1.5` is `06 3F F8 00 00 00 00 00 00`; `-0` is `06 80 00 00 00 00 00 00 00`; `2^-1074` is `06 00 00 00 00 00 00 00 01`. The writer uses one spelling for each value and for infinity; the reader also accepts the others (see below).

**Strings** are raw bytes: every byte value, including the escape byte and `|`, is carried as is, because escaping belongs to the channel stage.

**Tables.** The array part is `1..n` where `n` is the first index below `#t` whose successor is `nil` (so holes end it, whatever `#` reports); every other key is in the map part. The layout byte says which parts are present; the empty table is `08 00`. `{ 1, x = 2 }` is `0A 01 04 01 01 07 01 78 04 02`. Map pairs follow `next` order, so two equal tables may serialise to different bytes; they always decode to equal tables. Raw contents are read (`rawget`, `next`): metatables are neither consulted nor preserved.

### Well-formed input

A reader accepts a frame when it is **well-formed**:

- the header is `0x01` and a valid flags byte, and the body decodes through every stage the flags name;
- every stage's input and output stays within the limits;
- every type byte is assigned (`0x0B` only at the top), every varint is at most eight bytes, at most 2^53 and not overlong, and a negative integer's magnitude is not 0;
- every count fits in the bytes that remain, an argument list holds at most `maxListValues` entries, and nothing follows the top-level value;
- an array element or map value is never `nil`; a key is never `nil` or NaN and never repeats within one table.

Nothing else is checked. In particular the reader accepts, and decodes to the value it describes, input the writer never produces: an integral number written as a `0x06` double, a NaN with any payload, a map part holding the keys `1..n`, a mixed layout with an empty array or map part, and DEFLATE streams made by any encoder with any block choice. Re-encoding such a value gives the canonical bytes, which may differ from the input.

**Encoded bytes are not a content hash.** Map pairs follow `next` order, so two equal tables can encode differently, and the reader accepts several spellings of one value. To compare or hash values (commKit's `SyncSet`, say), hash a canonical walk of the value — keys sorted by type and value — not the output of `Encode`.

### Type matrix

| Lua value | Written as | Decodes to |
|---|---|---|
| `nil` | `0x01` | `nil` (a top-level value or a list entry only) |
| `true`, `false` | `0x03`, `0x02` | the same |
| integer within ±2^53, not −0 | `0x04`/`0x05` + varint | the same number |
| any other number | `0x06` + binary64 | the identical double (NaN stays NaN) |
| string | `0x07` + length + bytes | an equal string |
| table | `0x08`/`0x09`/`0x0A` | a new table with equal contents and no metatable; a table reached twice becomes two tables |
| function, userdata, thread | refused: `"unsupportedType"` | — |
| a cycle | refused: `"cycle"` | — |
| a secret value | raises at the caller | — |

### Compression

Raw DEFLATE (RFC 1951): no zlib or gzip wrapper, no checksum. The encoder writes stored, fixed-Huffman and dynamic-Huffman blocks, choosing per block whichever is smallest; the decoder inflates all three from any conforming encoder. `level` trades time for size: levels 1 to 3 take matches greedily, 4 to 9 defer each match by one byte when the next is longer, and the chain length ranges from 4 candidates at level 1 to 256 at levels 7 and 9. Inputs under 64 bytes are written as one literal or stored block without matching. [`INTERNALS.md`](INTERNALS.md#compressor) has the table, and [Cost](#cost) the time per KiB at each level.

### Addon channel

The addon channel cannot carry these five bytes; each becomes the escape byte `0xFF` followed by an ASCII digit. Every other byte passes unchanged.

| Byte | Written as |
|---|---|
| `0x00` (NUL) | `FF 30` (`"0"`) |
| `0x0A` (line feed) | `FF 31` (`"1"`) |
| `0x0D` (carriage return) | `FF 32` (`"2"`) |
| `0x7C` (`\|`) | `FF 33` (`"3"`) |
| `0xFF` (the escape byte) | `FF 34` (`"4"`) |

An escaped string contains no NUL, line break or pipe. The decoder refuses a raw one of those (`"forbiddenByte"`) and an escape byte followed by anything but `0`–`4`, or ending the text (`"malformedEscape"`). The worst case doubles the size; uniformly random bytes grow by about 2% (five of the 256 byte values).

### Print channel

The alphabet is the 85 printable ASCII characters left after removing nine, in ascending code order; digit 0 is `!` and digit 84 is `~`:

```text
!#$&()*+,-.0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[]^_abcdefghijklmnopqrstuvwxyz~
```

Removed, and why:

| Character | Reason |
|---|---|
| `"` `'` and the backtick | Quotes break copying into Lua sources, macros and forum posts. |
| `\` | The escape character of Lua strings and many editors. |
| `\|` | Introduces the client's UI escape sequences (`\|c`, `\|H`, `\|T`). |
| `{` `}` | Chat replaces raid-target names in braces with icons. |
| `%` | Chat and macro substitutions (`%t`), and format patterns. |
| `/` | A chat line starting with it is a slash command. |

Every four bytes, read as a big-endian 32-bit number, become five base-85 digits, most significant first. A final group of `k` bytes (1 to 3) is padded with zero bytes and only its first `k + 1` digits are written. The output is always `5 * floor(n / 4)` characters plus `k + 1` for a final partial group: 25% larger than the input. `00 00 00 00` is `!!!!!`.

The decoder ignores whitespace anywhere (space, tab, line feed, vertical tab, form feed and carriage return, which is also what may precede a print frame), so a string wrapped or indented by a chat window, an edit box or a forum still decodes. It pads a final group of `k + 1` digits with digit 84 and keeps `k` bytes. It refuses a character outside the alphabet, a final group of one character, and a group whose value exceeds 2^32 − 1 (`"malformedPrint"`).

## Limits

Every limit is package-wide: it is set with `CodecKit:SetLimits{ ... }` and read with `CodecKit:GetLimits()`.

| Limit | Default | Bounds | How to open | `UNBOUNDED` allowed? | Ceiling and reason |
|---|---|---|---|---|---|
| `maxDepth` | 16 | Table nesting; a top-level table is depth 1. | `SetLimits{ maxDepth = n }` | no | 128: the reader and writer recurse twice per level on the Lua call stack. A bare Lua 5.1.5 interpreter overflows near 9995 levels; 128 leaves the rest to the consumer's own call depth. |
| `maxValues` | 65536 | Values in one payload: keys, values and list entries. | `SetLimits{ maxValues = n }` | yes | 16777216 as an integer; lifted, `maxOutputBytes` still bounds it. |
| `maxStringLength` | 65536 | One string, value or key. | `SetLimits{ maxStringLength = n }` | yes | 2^30 as an integer; lifted, `maxOutputBytes` still bounds it. |
| `maxOutputBytes` | 1048576 | The output of every stage: the serialised bytes, the compressed bytes, the escaped or printed text, and the final frame. Decoding refuses an input stage larger than it and stops inflating when the output would pass it, so a DEFLATE bomb costs at most this much. | `SetLimits{ maxOutputBytes = n }` | no | 2^26 (64 MiB): inflating keeps one array slot per output byte, so this is the memory one hostile frame may claim. |
| `maxListValues` | 4096 | Entries in an `EncodeMany`/`DecodeMany` argument list, on both sides. Past it the reason is `"maxValues"`. | `SetLimits{ maxListValues = n }` | no | 7900: `DecodeMany` returns the entries through `unpack`, which Lua 5.1.5 refuses past 7997 results (the 8000-slot C stack limit less its three arguments, measured); the margin covers hosts built with a smaller stack. `EncodeMany` refuses the same count so everything it writes reads back. |

```lua
CodecKit:SetLimits({ maxDepth = 8, maxOutputBytes = 65536 })
CodecKit:SetLimits({ maxValues = CodecKit.UNBOUNDED })
local limits = CodecKit:GetLimits() -- a fresh table; limits.maxValues == CodecKit.UNBOUNDED
```

**Why lifting `maxValues` and `maxStringLength` is safe.** Every value takes at least one byte and every string is part of the bytes, and every decoding stage refuses input larger than `maxOutputBytes` (print text before its whitespace is stripped) and stops inflating at it. A lifted count or length is therefore still bounded by `maxOutputBytes` on both sides, which is why that limit, and the stack-bound `maxDepth` and `maxListValues`, cannot be lifted. With `maxValues` lifted, the secret scan `EncodeAsync` runs at the call stops after `maxOutputBytes + maxDepth + 2` values, the most the encoder can reach before `"maxOutputBytes"` refuses, so a value that references one table many times cannot make the scan run for long.

`SetLimits` accepts any subset and raises at the caller on an unknown name, on a value that is not an integer from 1 to the ceiling (or `CodecKit.UNBOUNDED` where the table allows it), and on `CodecKit.UNBOUNDED` where it does not, naming the reason (`CodecKit:SetLimits limits.maxDepth cannot be CodecKit.UNBOUNDED because the reader and writer recurse on the Lua call stack; use an integer from 1 to 128`). It validates every field before changing any. `CodecKit.UNBOUNDED` is one table kept in the package state, so every embedded copy and every revision publishes the same sentinel. **The limits are shared by every consumer in the session**, like SchedulerKit's frame budget: every embedded copy and every addon uses one set. A library should rely on the defaults; an addon that raises a limit raises it for everybody. Each call copies the limits when it starts, so a change during an asynchronous job does not affect that job.

## Asynchronous variants

```lua
local scope = SchedulerKit:CreateScope()
local job = CodecKit:EncodeAsync(profile, { compress = "deflate", channel = "print" }, scope, function(ok, text)
    if ok then
        ShowExportWindow(text)
    else
        print("Export failed: " .. text)
    end
end)
```

`EncodeAsync` and `DecodeAsync` validate every argument at the call and then schedule one job on `scope`, which must be an open SchedulerKit scope. The job runs the same stages as `Encode`/`Decode` and asks `context:ShouldYield()` every 256 values, every 2048 input positions of the compressor, every 4096 inflated symbols and every 2048 print groups, yielding when the frame budget is spent. It calls `callback(ok, result)` once, from the job, with exactly what the synchronous method would have returned. The escape pass of the addon channel is one `string.gsub` and does not yield.

The callback is never called when the job is cancelled, by `job:Cancel()`, `scope:CancelAll()` or `scope:Close()`. A callback error fails the job the way SchedulerKit reports any job error. Asynchronous calls do not lease from the pool: a cancelled job is never resumed, and a leased table it held would stay leased for the session.

## Secret values

Retail clients hand addon code **secret values** in restricted contexts; see [`EMBEDDING.md` → Secret values](../../../docs/EMBEDDING.md#secret-values-retail-12x). CodecKit asks `issecretvalue` about every value before anything else touches it, and a secret anywhere in the value — at the top, in a table value, in a key, deep in a nested table — raises at the caller: `CodecKit:Encode value must not contain a secret value`. `EncodeAsync` scans the value for secrets at the call, visiting values in the encoder's order and stopping where the encoder would refuse with `"maxDepth"` or `"maxValues"`, so its refusal is at the caller too. A decoding or stage method refuses a secret string argument the same way.

## Security: decoded data is untrusted

A decoded value is whatever the sender chose to encode. The limits keep decoding bounded, and the result contains only strings, numbers, booleans and plain tables, but nothing else about its shape is checked. **Validate every decoded value with SchemaKit before using it**, and treat a failure like any other malformed message:

```lua
local Message = SchemaKit:Seal(SchemaKit.table({
    fields = {
        kind = SchemaKit.enum({ "hello", "sync" }),
        version = SchemaKit.number({ integer = true, min = 1 }),
    },
}))

local ok, value = CodecKit:Decode(text, { channel = "addon" })
if not ok or not Message:Check(value) then
    return -- drop it
end
```

See [`schemaKit/docs/API.md`](../../schemaKit/docs/API.md). Never run a decoded string as code or as a macro, and never use a decoded value as a frame name, a global name or a format string.

## Cost

Measured with Lua 5.1.5 on a desktop. For a 10 KiB English Markdown sample:

| Level | Output | Ratio | Compress | Inflate |
|---|---|---|---|---|
| 1 | 4320 bytes | 2.37x | 3.1 ms | 1.4 ms |
| 6 | 4005 bytes | 2.56x | 4.4 ms | 1.2 ms |
| 9 | 4006 bytes | 2.56x | 4.1 ms | 1.2 ms |

Compression time depends on the input as much as on the level. Per KiB of input, for ordinary prose and for the worst case measured (random text over two symbols, where every hash chain is full of short matches):

| Level | Prose | Worst case |
|---|---|---|
| 1 | 0.11 ms | 0.19 ms |
| 4 | 0.15 ms | 0.28 ms |
| 6 (default) | 0.30 ms | 0.91 ms |
| 7 | 0.49 ms | 1.52 ms |
| 8 | 0.58 ms | 1.96 ms |
| 9 | 0.71 ms | 2.46 ms |

Inflating costs about 0.12 ms per KiB of output at any level, and print-encoding about 0.08 ms per KiB. **Synchronous callers should stay at level 6 or below**; for large exports at level 7 to 9, or any compression that might pass a few dozen KiB, use `EncodeAsync`, which spreads the work over frames. The default level is 6.

- **Serialising** allocates the output string and nothing else: its fragment arrays and work record are leased from a PoolKit table pool and returned on every path. Encoding the same small value again allocates nothing.
- **Decoding a serialised body** allocates the tables it returns and the strings in them; `DecodeMany` also allocates one array for the entries of a list.
- **Compressing** an input under 64 bytes writes one literal or stored block and allocates nothing beyond its output (0.001 KiB per call measured for 32 bytes). From 64 bytes the matcher allocates working arrays proportional to the input (a few tens of bytes per input byte: the byte array, the hash chains and the tokens) plus about 35 to 40 KiB of code tables **per block** (a block covers at most 32 KiB of input); all of it is garbage after the call. **Inflating** allocates an output array of about 16 bytes per output byte.
- One `table.concat` per stage output, per 1024 fragments.

## Deviations from the planned contract

The nine-point plan in `docs/ROADMAP.md` is followed except where recorded here:

- **The header is two bytes, version and flags**, not one. One byte cannot hold a version that can change independently of the stage flags; the second byte is also what makes the flags extensible.
- **The print alphabet has 85 characters**, not 92: removing quotes, backslash, pipe and whitespace from printable ASCII leaves 90, and braces, percent and slash are removed too for the chat reasons above. Base 85 maps four bytes to five characters exactly in double arithmetic, at a fixed 25% overhead.
- **`channel = "none"`**, the default, is accepted beside `"addon"` and `"print"`, and **`options.level`** selects the compression level. Decoder options hold only the `channel` assertion.
- **A secret value raises at the caller** instead of returning a reason, as the taint rules in `EMBEDDING.md` require; `"secret"` reaches only an asynchronous callback whose value changed after the call.
- **`Decode` raises for a non-string argument.** The non-raising contract covers every string, not programming errors.
- **Metatables are ignored**, not refused: raw contents are serialised.
- **One `table.concat` per stage output** rather than per encode, and compression allocates its working arrays per call; only fragment arrays and work records are leased. The asynchronous variants lease nothing, because a cancelled job never returns what it holds.
- **`Compress` and every decoding stage refuse input larger than `maxOutputBytes`** (print text is measured before whitespace is stripped), so the limit bounds each stage's input as well as its output.
- **Levels 8 and 9 cap their hash chains at 192 and 256 candidates** instead of zlib's 1024 and 4096, which keeps level 9 within about three times level 6 in pure Lua (2.7 times measured on the worst case above, down from 27 times).
- **Inputs under 64 bytes skip matching** and are written as one fixed-Huffman literal block or one stored block.
- **Additions:** `EncodeMany` and `DecodeMany` for argument lists (at most `maxListValues` entries, 4096 by default and at most 7900, because `DecodeMany` returns them through `unpack`, which Lua 5.1 bounds), `CodecKit.UNBOUNDED` for `maxValues` and `maxStringLength`, `PRINT_ALPHABET`, and the `"channelMismatch"` assertion.

## Upgrades

The package state (`_state`) holds the shared limits, the `UNBOUNDED` sentinel and the table pool, and all three are kept across an in-place upgrade: a newer compatible revision replaces the facade's functions, inherits the limits a consumer set, and keeps leasing from the same pool. The wire format belongs to the format version, not to the revision, so frames written by any revision of API generation 1 decode in every other.
