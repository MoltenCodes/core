# Changelog

## 0.1.4 — 2026-09-25

- The serialiser writes every NaN as the canonical quiet NaN `06 7F F8 00 00 00 00 00 00`, as `docs/API.md` promises. Revision 3 derived the sign bit with an ordered comparison before it recognised NaN, and on Retail 12.1.0 b69933 (measured 2026-09-25 by the real-client suite) that comparison answered "negative" for `0 / 0`, so the client wrote `06 FF F8 ...`. NaN is now recognised first with `value ~= value` and written without looking at its sign or payload. The value reaching the writer has already been refused if it is a secret. Decoding is unchanged, and a sign-bit NaN written by revision 3 still decodes to NaN.
- Implementation revision 4. The state layout is unchanged: `Bootstrap_spec.lua` loads a revision 3 copy and upgrades it in place, keeping the state table, the limits and the pool, and the upgraded copy writes the canonical NaN.
- `CodecKitTestEnv.LoadPatched` loads the source with one piece of text replaced; `Serialize_spec.lua` uses it to model the client's sign test, which stock Lua cannot reproduce.
- 110 specs.

## 0.1.3 — 2026-09-24

- Secret values: the source comments on `arrayPartLength`, the facade check and the secret refusal of option and limit values no longer claim that comparing a secret with anything, `nil` included, raises, or that a raw identity test is safe whatever the other side. They state what was measured on Retail 12.1.0 b69933 (2026-09-24): a secret compared with a value of its own type raises (`==`, `~=`, `<`, `<=` and `rawequal` alike) and a secret used as a table key raises, while a comparison with `nil` or with a value of another type answers without raising. The `type(value) == "nil"` rule stays, as the repository's uniform rule that never compares anything. Comments and documentation only: `luac -s -l` gives the same instruction listing before and after, so the implementation revision is unchanged.

## 0.1.2 — 2026-09-24

- Every absent value that comes from outside CodecKit is tested with `type`, never with `== nil`: the `options` argument of every method, option and limit keys, `SetLimits` values, the Registry alias read from the `MoltenCodes` namespace and the SchedulerKit facade `Registry:Find` returns. The receiver check tests `type` before comparing with the facade. A secret receiver or `options` argument is now refused at the caller with the ordinary message (`CodecKit:Encode must be called on the CodecKit facade; use CodecKit:Encode(...)`, `CodecKit:Encode options must be a table or nil`) instead of raising inside CodecKit on the comparison. Every value accepted before is still accepted.
- Implementation revision 3. The state layout is unchanged: `Bootstrap_spec.lua` loads a revision 2 copy and upgrades it in place, keeping the state table, the limits and the pool.
- `docs/API.md` states revision 3 and the refusal of a secret receiver or `options` argument.
- 107 specs.

## 0.1.1 — 2026-09-24

- A secret option value (`compress`, `channel`, `level`) or `SetLimits` value is now refused at the caller before anything compares it: `CodecKit:Encode options.level must not be a secret value`, `CodecKit:SetLimits limits.maxDepth must not be a secret value`. Revision 1 compared these values with `nil`, a set or the `UNBOUNDED` sentinel first, which raises a host error at a line inside CodecKit when the value is a secret. Absent options are now tested with `type`, never with `== nil`.
- Implementation revision 2. The state layout is unchanged: a revision 2 copy inherits the limits, the `UNBOUNDED` sentinel and the pool a revision 1 copy built. `Bootstrap_spec.lua` loads a revision 1 copy and upgrades it in place, and the next-revision upgrade spec now loads the revision after the current one.
- `docs/API.md` states revision 2 and the refusal of secret option and limit values; `docs/INTERNALS.md` describes the upgrade in current form.
- 105 specs.

## 0.1.0 — 2026-09-23

First release: CodecKit API generation 1, implementation revision 1, wire format version 1 (`CodecKit.FORMAT_VERSION`). Requires Registry API 2 and PoolKit API 1; SchedulerKit API 1 is optional and found with `Registry:Find` by the asynchronous methods.

- **Frames.** A version byte and a stage-flags byte (serialised, deflate, addon, print; four reserved bits), then the body. `Encode(value, options)` and `Decode(text, options)` compose the stages; the decoder reads the stages from the header, refuses an unknown version with `"unsupportedVersion"`, and a `channel` decode option refuses a frame made for another channel with `"channelMismatch"`.
- **Serialiser.** One type byte per value: varint integers up to 2^53, the exact IEEE-754 binary64 bit pattern for every other number (infinities, NaN, −0 and subnormal numbers included), length-prefixed raw strings, array, map and mixed table layouts, and an argument-list type for `EncodeMany`/`DecodeMany` (at most `maxListValues` entries on both sides). Cycles are refused with `"cycle"`; functions, userdata and threads with `"unsupportedType"`; metatables are ignored.
- **Compression.** Raw DEFLATE (RFC 1951) in pure Lua, interoperating with zlib in both directions: LZ77 over exact three-byte hash chains with greedy (levels 1–3) or lazy (levels 4–9) matching, then per block the cheapest of stored, fixed and dynamic Huffman with length-limited codes. Levels 8 and 9 cap their hash chains at 192 and 256 candidates, keeping level 9 within about three times level 6 on low-entropy input. Inputs under 64 bytes skip matching and become one literal or stored block without allocating. The inflater reads all three block types from any encoder.
- **Channels.** The addon channel escapes five bytes behind `0xFF`; the print channel is base 85 over an 85-character alphabet without quotes, backslash, pipe, braces, percent and slash, published as `PRINT_ALPHABET`, and ignores whitespace on decode, before the frame included.
- **Stage methods.** `Serialize`, `Deserialize`, `Compress`, `Decompress`, `EncodeForAddon`, `DecodeForAddon`, `EncodeForPrint` and `DecodeForPrint`.
- **Decoding never raises on malformed input.** Every failure is `false` and a reason from a fixed vocabulary of 22 (21 returned by the synchronous methods, plus `"secret"`, which only reaches an `EncodeAsync` callback). `docs/API.md` defines the well-formed input a lenient reader accepts, and warns that encoded bytes are not a content hash.
- **Limits.** `SetLimits` and `GetLimits` over `maxDepth` (16, ceiling 128), `maxValues` (65536), `maxStringLength` (65536), `maxOutputBytes` (1 MiB, ceiling 64 MiB) and `maxListValues` (4096, ceiling 7900: `unpack` refuses past 7997 results on Lua 5.1.5, measured), shared by every consumer. `maxOutputBytes` bounds each stage's input and output, inflation included; print input is measured before its whitespace is stripped.
- **`CodecKit.UNBOUNDED`**, one sentinel table kept in the package state so every revision shares it. `SetLimits` accepts it for `maxValues` and `maxStringLength`, which `maxOutputBytes` still bounds, and `GetLimits` returns it; `maxDepth`, `maxOutputBytes` and `maxListValues` refuse it at the caller with the reason. With `maxValues` lifted, the call-time secret scan of `EncodeAsync` stops after `maxOutputBytes + maxDepth + 2` values. API.md's *Limits* table names every limit's default, how to open it and its ceiling. The suite has 103 specs.
- **Asynchronous variants.** `EncodeAsync` and `DecodeAsync` run as one SchedulerKit job on a caller-owned scope and yield when `context:ShouldYield()` says so; a cancelled job never calls back.
- **Allocation.** Work records and fragment arrays are leased from a PoolKit table pool and returned on every path, so calls are re-entrant and encoding a small value again allocates nothing. The asynchronous variants lease nothing.
- **Secret values.** A secret anywhere in a value, and a secret string argument, raise at the caller when the client has `issecretvalue`. Elements are tested with `type` before the probe sees them, and `EncodeAsync` scans the value at the call as far as the encoder would reach.
- **Error levels.** Every programming error (receiver, argument, option, limit, secret, missing SchedulerKit, invalid scope) is reported at the caller's line.
