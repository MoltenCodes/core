# Changelog

## 0.1.0 — 2026-09-23

- Added CodecKit API generation 1, implementation revision 1, wire format version 1 (`CodecKit.FORMAT_VERSION`).
- Added the frame: a version byte and a stage-flags byte (serialised, deflate, addon, print; four reserved bits), then the body. `Encode(value, options)` and `Decode(text, options)` compose the stages; the decoder reads the stages from the header and refuses an unknown version with `"unsupportedVersion"`.
- Added the serialiser: one type byte per value, varint integers up to 2^53, exact IEEE-754 binary64 for every other number (infinities, NaN, −0 and subnormal numbers included) computed with `math.frexp`, length-prefixed raw strings, array, map and mixed table layouts, and an argument-list type for `EncodeMany`/`DecodeMany`. Cycles are refused with `"cycle"`; functions, userdata and threads with `"unsupportedType"`.
- Added raw DEFLATE (RFC 1951) in pure Lua: LZ77 over exact three-byte hash chains with greedy (levels 1–3) or lazy (levels 4–9) matching, and per block the cheapest of stored, fixed and dynamic Huffman with length-limited codes; an inflater for all three block types. Output interoperates with zlib in both directions.
- Added the addon channel (five bytes escaped behind `0xFF`) and the print channel (base 85 over an 85-character alphabet without quotes, backslash, pipe, braces, percent and slash; whitespace ignored on decode). `PRINT_ALPHABET` publishes the alphabet.
- Added the stage methods `Serialize`, `Deserialize`, `Compress`, `Decompress`, `EncodeForAddon`, `DecodeForAddon`, `EncodeForPrint` and `DecodeForPrint`.
- Decoding never raises on malformed input: every failure is `false` and a reason from a fixed vocabulary of 22 (21 returned by the synchronous methods, plus `"secret"`, which only reaches an `EncodeAsync` callback), and a `channel` decode option refuses frames made for another channel.
- Added `SetLimits` and `GetLimits` over `maxDepth` (16), `maxValues` (65536), `maxStringLength` (65536) and `maxOutputBytes` (1 MiB), shared by every consumer, each with a ceiling; `maxOutputBytes` also bounds inflation.
- Added `EncodeAsync` and `DecodeAsync`, running as a SchedulerKit job on a caller-owned scope and yielding when `context:ShouldYield()` says so. SchedulerKit API 1 is an optional dependency found with `Registry:Find`.
- Fragment arrays and work records are leased from a PoolKit table pool and returned on every path; PoolKit API 1 is a required dependency.
- Secret values anywhere in a value, and secret string arguments, are refused at the caller when the client has `issecretvalue`.
- The writer is canonical and the reader lenient: `docs/API.md` defines the well-formed input a reader accepts, including encodings the writer never produces, and warns that encoded bytes are not a content hash.
- Levels 8 and 9 cap their hash chains at 192 and 256 candidates, keeping level 9 within about three times level 6 on low-entropy input (2.7 times measured, down from 27); `docs/API.md` lists the time per KiB at each level and steers synchronous callers to level 6 or below.
- Inputs under 64 bytes skip matching and are written as one fixed-Huffman literal block or one stored block, so compressing a short message allocates nothing.
- The array-part scan and key loops test input values with `type(...)` rather than comparing them with `nil`, so a secret element is first touched by the secret probe.
- `DecodeForPrint` bounds its raw input, whitespace included, by `maxOutputBytes` before stripping it; vertical tab and form feed may precede a print frame, as every other character `%s` strips may.
- The `maxOutputBytes` ceiling is 64 MiB, since inflating keeps 16 bytes per output byte.
- 95 specs, including known DEFLATE vectors, a zlib-made dynamic stream, a 2000-string fuzz pass, every-prefix refusal, allocation guards, asynchronous encode and decode under a budget, an in-place upgrade to revision 2 and pinned error levels.
