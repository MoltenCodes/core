# CodecKit

CodecKit turns Lua values into strings that survive the addon channel, a chat window or a copy-paste box, and back. It works in three stages behind a two-byte header that says which stages ran: **serialise** (exact for every number, string, boolean, `nil` and acyclic table), **compress** (raw DEFLATE in pure Lua), and **channel-encode** (escaped for the addon channel, or printable for export strings). Decoding never raises on malformed input.

```lua
local CodecKit = MoltenCodes.Registry:Get("codecKit", 1)

-- An addon message: small, binary-safe for SendAddonMessage.
local ok, message = CodecKit:Encode({ kind = "sync", version = 3 }, { channel = "addon" })

-- A profile export string: compressed and printable.
local ok, exportString = CodecKit:Encode(profile, { compress = "deflate", channel = "print" })
-- Starts with "!"; no quotes, pipes, braces or slashes; wrapping is ignored on import.

-- Importing: the header says which stages to reverse.
local ok, value = CodecKit:Decode(pastedText, { channel = "print" })
if not ok then
    print("Import failed: " .. value) -- a reason such as "malformedPrint" or "truncated"
elseif not ProfileSchema:Check(value) then
    print("Import failed: not a profile")
end
```

What each piece promises:

- **Exact values.** Integers up to 2^53 are written as varint integers; every other number — fractions, larger integers, both infinities, NaN, −0, subnormal numbers — is its IEEE-754 bit pattern, so nothing is lost to `tostring`. Strings carry every byte. Tables keep array, map and mixed parts; cycles are refused with `"cycle"`, functions and userdata with `"unsupportedType"`.
- **Never raises on input.** `Decode`, `Deserialize`, `Decompress` and the channel decoders return `false, reason` for any string, from a fixed vocabulary, and stay within the limits whatever the string holds.
- **Bounded by default.** `maxDepth` 16, `maxValues` 65536, `maxStringLength` 65536, `maxOutputBytes` 1 MiB and `maxListValues` 4096, shared by every consumer, changed with `SetLimits`; `CodecKit.UNBOUNDED` lifts `maxValues` and `maxStringLength`, which `maxOutputBytes` still bounds. The output limit also caps what inflating a hostile stream can produce.
- **Standard compression.** `Compress` writes raw DEFLATE that any inflater reads, and `Decompress` reads any raw DEFLATE stream; levels 1 to 9.
- **Every stage on its own.** `Serialize`/`Deserialize`, `Compress`/`Decompress`, `EncodeForAddon`/`DecodeForAddon`, `EncodeForPrint`/`DecodeForPrint`; `EncodeMany`/`DecodeMany` for argument lists of up to `maxListValues` values (4096 by default), `nil`s included.
- **Never freezes a frame.** `EncodeAsync` and `DecodeAsync` run on a SchedulerKit scope and yield when the frame budget is spent.
- **Re-entrant and cheap.** Buffers are leased from a PoolKit table pool and returned on every path; encoding a small value again allocates nothing.
- **Secrets refused.** A secret value anywhere in the value raises at your line.

Decoded data is untrusted: validate it with SchemaKit before using it. See [`docs/API.md`](docs/API.md) for the wire format byte by byte, the escape table, the print alphabet and the limits, and [`docs/INTERNALS.md`](docs/INTERNALS.md) for the compressor.

## Embedding

[`../../docs/EMBEDDING.md`](../../docs/EMBEDDING.md) is the addon author's guide:
directory layout, supported Interface numbers, taint, `/reload` semantics and
troubleshooting. This package's load order inside a consuming addon is:

```toc
Libs\MoltenCodes\registry\Registry.lua
Libs\MoltenCodes\poolKit\PoolKit.lua
Libs\MoltenCodes\codecKit\CodecKit.lua
```

Direct runtime dependencies: Registry API 2 and PoolKit API 1.
Every file above is required; omitting one makes this package raise at
load.

Optional: SchedulerKit API 1, used only by `EncodeAsync` and `DecodeAsync`.
CodecKit looks it up with `Registry:Find` when one of them is called, so it may
load in any order; without it those two methods raise at the caller and
everything else works. The one host facility CodecKit reads, `issecretvalue`,
is looked up at every call; on a client without it nothing is treated as
secret.
