# codecKit records

Moved from `docs/ROADMAP.md` (Package D planned Kits — the nine points).

## codecKit

**codecKit** — facade `CodecKit`

1. Package `codecKit`, facade `CodecKit`, API generation 1.
2. Purpose: turn Lua values into transport-safe strings and back in three
   composable stages behind one self-describing header byte: serialise
   (strings, numbers including floats that do not survive `tostring`,
   booleans, nil, acyclic tables), compress (a DEFLATE-class codec written
   in pure Lua, yielding in blocks when run under a scheduler), and
   channel-encode (escape for the addon channel, or printable 7-bit for
   chat and export strings). Decoding never raises on malformed input.
   Non-goals: functions, userdata, metatables, shared-reference
   preservation (cycles are detected and refused), encryption,
   cross-language formats.
3. Dependencies: registry API 2; poolKit API 1 (leased fragment buffers);
   schedulerKit API 1 optional through `Registry:Find` (asynchronous
   variants).
4. Surface: `CodecKit:Encode(value, options)` → `true, string` or `false,
   reason` with `options.compress` (`"none" | "deflate"`), `options.channel`
   (`"addon" | "print"`); `CodecKit:Decode(string, options)` → `true, value`
   or `false, reason` (the header says which stages to reverse; an unknown
   header version is refused with a clear reason); the stages alone:
   `Serialize` / `Deserialize`, `Compress` / `Decompress`, `EncodeForAddon`
   / `EncodeForPrint` and their inverses; `CodecKit:EncodeAsync(value,
   options, scope, callback)` and `DecodeAsync` running in blocks on a
   schedulerKit scope under the frame budget; `CodecKit:SetLimits{ maxDepth,
   maxValues, maxStringLength, maxOutputBytes, maxListValues }` /
   `GetLimits()`, all bounded by default and documented as shared by every
   consumer, with `UNBOUNDED` accepted for `maxValues` and `maxStringLength`
   (still bounded by `maxOutputBytes`);
   `CodecKit.FORMAT_VERSION`.
5. Ownership: stateless apart from limits; buffers are leased from a poolKit
   table pool per call and returned, so calls are re-entrant.
6. Performance: one `table.concat` per encode; single-pass decode; every
   limit named in the refusal; compression cost documented per kilobyte
   and yielding in the asynchronous form so a large export never freezes a
   frame.
7. Tests: round-trip of every type and edge (control bytes, the escape
   byte, empty and long strings, integers past 2^53, `math.huge`, NaN,
   subnormal numbers), nested and mixed tables, nil in the middle of an argument
   list, cycle refusal, every limit, malformed input of every shape never
   raising, a fuzz pass over random bytes, compression round-trips against
   known vectors, asynchronous encode under a budget with the scheduler
   stub, allocation guard, upgrade, manifest, error levels.
8. Docs: README, API.md specifying the wire format byte by byte with the
   header and extension rules, the type matrix and the security note that
   decoded data is untrusted; INTERNALS.md (compressor design); CHANGELOG.
9. Status: implemented (package D, 0.1.0); deviations recorded in
   `packages/codecKit/docs/API.md`.

Moved from `docs/ROADMAP.md` (Package M — the user-interface phase (last, by the owner's decision)).

## codecKit native DEFLATE

**codecKit native DEFLATE** — a change inside facade `CodecKit`

1. Package `codecKit`, facade `CodecKit`, API generation 1 (no change to
   the surface), version 0.2.0, implementation revision 7, wire format
   version 1 (unchanged). Minor version because what a client with
   `C_EncodingUtil` writes changes (different, equally valid DEFLATE
   bytes), even though no member is added.
2. Purpose: run the compression stage, and only that stage, through the
   client's `C_EncodingUtil.CompressString` and `DecompressString` with
   `Enum.CompressionMethod.Deflate` where the client has them, because that
   is the one stage whose format the client implements exactly: raw DEFLATE
   (RFC 1951), which the Retail client suite already proved interoperates
   with CodecKit in both directions. Frames keep version 1 and the same
   flags; every frame any revision wrote still decodes, and a frame written
   through the native compressor decodes in revisions 1 to 6, whose inflater
   reads any conforming raw DEFLATE stream. Non-goals, each because the
   bytes would change: the serialiser (`SerializeCBOR`/`DeserializeCBOR` and
   the JSON pair write other formats and cannot carry CodecKit's exact
   doubles, `-0`, `nil` list entries, the argument-list type or the refusal
   vocabulary), the print channel (CodecKit's base 85 over its own
   85-character alphabet is not `EncodeBase64` in either RFC 4648 variant),
   the addon channel (no native counterpart; it is one `gsub`), and the hex
   functions (CodecKit has no hex stage). Also not a goal: byte-identical
   compressed output across clients, which `docs/API.md` already disclaims
   ("Encoded bytes are not a content hash").
3. Dependencies: unchanged, registry API 2 and poolKit API 1, schedulerKit
   API 1 optional. Host facility, optional: `C_EncodingUtil.CompressString`
   and `C_EncodingUtil.DecompressString`, documented identically on `live`
   since 11.1.5 (60428), `classic` since 5.5.0 (61767) and `classic_era`
   since 1.15.8 (63829), so on every promised client (12.1.5, 5.5.4,
   1.15.9); and `Enum.CompressionMethod.Deflate` (0) and
   `Enum.CompressionLevel` (`Default` 0, `OptimizeForSpeed` 1,
   `OptimizeForSize` 2), with the documented values used when `Enum` lacks
   them. Both functions are looked up with `rawget(_G, "C_EncodingUtil")` at
   every call, as `issecretvalue` is, each guarded with
   `type(...) == "function"` for the flavour gate. Without them, or on the
   host, every call takes the Lua path exactly as revision 6 does.
4. Surface: none added. Which path ran is internal; the package test
   environment's stand-in counts native calls, which is how the specs tell.
   The level option keeps its 1 to 9 range and maps onto the client's
   three: 1 to 3 to `OptimizeForSpeed`, 4 to 6 to `Default`, 7 to 9 to
   `OptimizeForSize`. What stays on the Lua path, and why:
   - compressing an input under 64 bytes (the existing literal or stored
     block, which allocates nothing and is what addon messages mostly are);
   - inflating an input larger than `maxOutputBytes / 64` bytes (16 KiB at
     the default limit): DEFLATE expands at most about 1032 to 1, and the
     native inflater only stops at its own 100 MiB cap
     (`Constants.EncodingLimits.EncodingDecompressSizeLimit` = 104857600),
     after which CodecKit can only measure the result. Below that bound the
     worst native output is no larger than the 16 bytes per output byte the
     Lua inflater already claims for an honest frame at the limit, so "a
     DEFLATE bomb costs at most this much" keeps its meaning. A consumer that
     raises `maxOutputBytes` raises the bound with it.
   - any native failure. `DecompressString` raises on invalid data and both
     functions may return nothing (`MayReturnNothing`), so each native call
     runs under `pcall`; a raise, no result or a non-string result reruns the
     stage on the Lua path, which returns the documented reason
     (`"malformedDeflate"`, `"truncated"`, `"trailingData"`,
     `"maxOutputBytes"`). Decoders still never raise, and every refusal
     keeps the reason revision 6 returns.
   - a native result is still measured against `maxOutputBytes` on both
     stages, as the Lua path's is.
   `EncodeAsync` and `DecodeAsync` use the native stage in one call when it
   applies (it cannot yield, and host C zlib measured 20 to 150 times
   cheaper than the Lua stage it replaces; see 6), and keep the sliced Lua
   path above an internal `ASYNC_NATIVE_MAXIMUM_BYTES` of 256 KiB of stage
   input, to be confirmed by the client measurement in 7.
   Gate before the inflate half ships: the client suite must show what
   `DecompressString` does with bytes after the final block. If it refuses
   them, native inflation is adopted as above; if it accepts them, a frame
   the Lua path refuses with `"trailingData"` would decode, so only native
   compression ships and inflation stays Lua until the owner decides.
5. Ownership: nothing new is held. No state field is added; the host
   functions are read per call and never cached in `_state`, so a revision 6
   copy upgraded in place and a revision 7 copy share the same state table,
   limits, `UNBOUNDED` and pool. A string the client returns belongs to the
   caller like any stage output.
6. Performance and memory. Measured on the host (Apple M5 Pro, Lua 5.1.5,
   load average about 30 to 40 during the runs, so read the ratios, not the
   absolute times), CodecKit revision 6, per KiB of input: compress level 6
   0.57 ms (prose, 10 and 50 KiB) and 0.48 ms (random); level 1 0.30 to
   0.44 ms; level 9 0.57 to 0.64 ms; inflate 0.13 to 0.18 ms (prose) and
   0.035 ms (stored blocks); print encode 0.09 ms, decode 0.12 ms; addon
   escape 0.010 ms, unescape 0.016 ms. The same inputs through host C zlib
   raw DEFLATE (window bits −15): compress level 6 0.013 to 0.032 ms, level
   9 0.015 to 0.054 ms, inflate 0.001 to 0.002 ms; that is 18 to 43 times
   cheaper to compress prose at level 6 and 110 to 150 times cheaper to
   inflate it, with output within 0.3% of CodecKit's size at levels 6
   and 9 (4508 against 4508 bytes, 18261 against 18237). Inferred, not
   measured: the client's functions perform like host zlib; Blizzard does
   not say which DEFLATE implementation they use, and the Retail client
   suite logs `CompressString` and `DecompressString` timings beside
   CodecKit's on a 50 KB roster, but that log was not kept in
   `tests/client/results.json`. Published: WeakAuras issue 5835 calls the
   native functions "substantially faster than LibDeflate+LibSerialize";
   no adopter published numbers. Memory: the Lua compressor's working arrays
   (a few tens of bytes per input byte and 35 to 40 KiB of code tables per
   32 KiB block) and the Lua inflater's output array (about 16 bytes per
   output byte) are not allocated on the native path; the native path
   allocates its result string, and `pcall` is given the host function
   and its arguments directly, so no closure is made per call. What does not
   change: serialising (the `codec` host benchmark, 0.82 ms to encode and
   0.65 ms to decode the large payload) and the print channel, which
   together are the whole cost of an uncompressed frame.
7. Tests, in the package's specs with a stand-in in
   `tests/support/CodecKitTestEnv.lua`: a `C_EncodingUtil` whose
   `CompressString` and `DecompressString` are a second, independent raw
   DEFLATE (CodecKit's own Lua stages loaded as a separate copy, with stored
   blocks forced for compression so its bytes differ) and count calls;
   modes that raise, return nothing, return a non-string, accept trailing
   bytes and refuse them. Specs: with the stand-in, `Compress`, `Encode`
   with `compress = "deflate"` and both asynchronous variants call it at and
   above 64 bytes and not below; its output decodes on the Lua path (stand-in
   removed) and Lua output decodes through it; every golden compressed frame
   of `FastPath_spec.lua` decodes through it; without it every golden frame
   is written byte for byte as revision 6 wrote it; each failure mode falls
   back and returns revision 6's reason; the inflate bound (an input of
   `maxOutputBytes / 64` bytes goes native, one byte more does not, and a
   raised `maxOutputBytes` moves it); `maxOutputBytes` on native results;
   the level mapping; the async size threshold; a secret string is refused
   before the stand-in is called; `Enum` missing uses the documented values;
   `C_EncodingUtil` present without the two functions takes the Lua path;
   the allocation specs unchanged without the stand-in and for inputs under
   64 bytes with it; an in-place upgrade from revision 6 keeping state and
   pool. Client suite (`tests/client/MoltenCodesTest_CodecKit`, never run by
   tooling): the existing interop tests stay; added, with the facade test
   logging which path runs: an `Encode`/`Decode` round trip of the 50 KB
   roster on the native path that a revision 6 copy loaded beside it
   decodes, and the reverse; `DecompressString` on a valid stream followed
   by trailing bytes, logged and asserted against the gate in 4; a stream
   that inflates past `maxOutputBytes`; the time of a 256 KiB and a 1 MiB
   native compress at `OptimizeForSize` and inflate, to confirm the async
   threshold; and the side-by-side timings of the existing log, written to
   EXPECTED.md this time. Classic Era and Mists of Pandaria Classic runs
   are required before the native path is called proven there.
8. Docs: API.md (the compression section: which encoder runs where, the
   level mapping, the inflate bound, the trailing-data finding, and the Cost
   section with the native rows once measured on the client; the optional
   facilities table gains `C_EncodingUtil`), INTERNALS.md (the native path,
   its fallback and the bound), README (the "Standard compression" line and
   the host facilities in Embedding), CHANGELOG, tests/README,
   EXPECTED.md for the client suite; `docs/EMBEDDING.md` host-requirements
   row for codecKit (applied by the maintainer).
9. Status: implemented 2026-11-15 under core decision 16, 0.2.0, revision
   7, 146 specs. Recorded deviation: native compression only. A frame has
   no declared length, checksum or end marker of its own, so CodecKit
   cannot tell whether the client's inflater accepted a stream its own
   inflater refuses (bytes after the final block); inflating stays in Lua
   on every client, with no native inflate code. A later revision may
   inflate natively, behind the 16 KiB bound of point 4, once the client
   suite's `codecKit.native` trailing-bytes test has shown what
   `DecompressString` does (docs/INTERNALS.md, "Native compressor"). The
   client suite (`tests/client/MoltenCodesTest_CodecKit`, now 36 tests) is
   not run yet.
   Reviewed 2026-11-15 under core decision 17: 0.2.1, revision 8 (a secret
   native result or `Enum` value falls back to Lua or to the documented
   number).

Moved from `docs/ROADMAP.md` (Package O — memory, performance and ease of use (decisions 18 and 19)).

## codecKit key descriptions, lazy tables and cheaper scans

**codecKit key descriptions, lazy tables and cheaper scans** — a fix and an internal change to facade `CodecKit`

1. Package `codecKit`, facade `CodecKit`, API generation 1 (unchanged),
   version 0.2.2, implementation revision 9 (from 0.2.1, revision 8).
   Patch: a defect fix and internal changes, no public surface added.
2. Purpose: fix the last live `tostring(key)` refusals, cut the memory held
   by tables a session may never use, and bring encode and decode down to
   AceSerializer-3.0's cost, following the architecture plan (item 3), the
   memory diagnosis (fix 2) and the runtime performance diagnosis of
   2026-11-15 (codecKit).
   - Defect: `validateOptionKeys` (`CodecKit.lua:3530`) and
     `validateLimitUpdate` (`:3672`) build their refusal with
     `tostring(key)`. A table key with `__tostring` therefore runs the
     caller's code inside CodecKit. Both take a `describeKey` that names a
     string as itself, a number or boolean through `tostring`, a secret as
     `<secret>` and anything else by type (`<table>`), the convention of
     ApiKit, CacheKit, CompatKit and EventKit. A secret key is refused
     first ("must not have a secret key"), before `known[key]` would raise
     inside CodecKit, as BridgeKit's `SetLimits` does.
   - Lazy tables: the DEFLATE tables (`:1523-1859`: length and distance
     bases and extras, the fixed codes and decoders) are built on the
     first Lua compression or decompression, never when the client's
     native path serves it. The print tables `PRINT_CODES` and
     `PRINT_DIGITS` (`:3033`) are built on the first print-safe encode or
     decode. `BYTE_TEXT` and `ADDON_BYTE_TEXT` (`:739-746`) are built on
     the first encode. After the first call the hot paths allocate nothing,
     as today.
   - A bounded clean-string cache: up to 256 strings of at most 32 bytes
     that the addon-channel escape scan found clean, filled once and never
     wiped. The secret check in `writeValue` (`:1069`) still runs before
     the lookup.
   - Plain finds: the escape and forbidden-byte scans over a whole frame
     (`:3000` in `decodeForAddon`, `:3360` in the frame reader) and over a
     string the cache does not hold (`:1101`) use one plain
     `string.find(text, byte, start, true)` per byte (four for the
     forbidden set, five with the escape byte) instead of a character
     class, which Lua 5.1 tries at every start position. This one was not
     in the diagnosis: it was measured for this record (item 6).
   - Options in one pass: `readEncodeOptions` checks unknown keys,
     `compress`, `channel` and `level` inline, in the same order and with
     the same messages and levels, reading the probe once. That probe is
     passed to `openWork`, which no longer reads it again. A handoff to a
     raising helper is never a tail call, so errors stay at the caller's
     line. The prototype's second copy of this reader for clients without
     a probe is not taken: one reader is easier to keep right.
   - The secret-probe rule: `readSecretProbe` (`:325`, read on every call
     today) answers the probe resolved at load, and looks it up again only
     when it was absent at load.
3. Dependencies: unchanged (registry API 2, poolKit API 1, schedulerKit
   API 1 for the asynchronous calls).
4. Surface: unchanged methods, reasons and limits. Messages change only
   for a non-string key: `options.<table> is not a recognised option` and
   `limits.<table> is not a recognised limit`, not the address `tostring`
   printed. A secret key is refused at the caller's line.
5. Ownership: the lazily built tables and the cache are file-local and
   built by each revision on first use. They hold constant data derived
   from code, so a copy in `_state` would need validation for nothing, and
   an upgraded revision builds its own once. Nothing is saved. The cache
   holds up to about 14 KB of caller strings for the session. The main
   chunk holds 180 of 200 locals; the lazy tables become fields of one
   table each.
6. Performance and memory, host bench `codec` workload (compression off,
   addon channel), MoltenCodes ÷ AceSerializer-3.0 in the same run, rerun
   2026-11-15. "Prototype" is the diagnosis prototype (cache, one-pass
   options); "this record" adds the plain finds:

   | Case | Before | Prototype | This record (expected) |
   |---|---:|---:|---:|
   | encode small | 1.59× | 1.28× | 1.28× |
   | encode medium | 1.53× | 1.25× | 1.25× |
   | encode large | 1.22× | 1.05× | 1.10× (noise) |
   | decode small | 1.26× | 1.28× | 1.08× |
   | decode medium | 1.15× | 1.12× | 0.95× |
   | decode large | 0.87× | 0.87× | 0.76× |

   The scan alone, clean text, best of 7: 32 B 237 → 96 ns, 200 B
   1,383 → 113 ns, 2,000 B 14,269 → 296 ns, 20,000 B 134,965 → 1,565 ns.
   Resident memory: −86.8 KB until used (memory diagnosis, exact drop:
   DEFLATE 59.0 KB, byte text 18.5 KB, print 9.3 KB), up to +14 KB for the
   cache. Decode reaches the target "below AceSerializer" on medium and
   large, and small comes within 8%. Encode does not: the remaining fixed
   cost per call is the facade check, the work record and the counting pass
   the wire format needs (the count comes before the entries). Two more
   items will be tried and kept only if they measure faster: a flat
   `Encode` for the synchronous uncompressed case, and an inline common
   path in `appendNumber`.
7. Tests, failing first for the defect:
   - a table key with a `__tostring` that counts its calls, given to
     `Encode` options and to `SetLimits`: refused, the message names
     `<table>`, the metamethod never ran; a function key likewise; a
     secret key refused at the caller's line;
   - lazy tables: absent after load, built by the first Lua compression,
     decompression or print-safe call, not built when the native path
     serves the call; round trips unchanged;
   - output byte for byte equal to revision 8 on the bench payloads and on
     strings holding each forbidden and escape byte at the first, middle
     and last position;
   - frames with a forbidden byte or a bad escape after the header refused
     with the same reasons;
   - the cache: as BridgeKit's, the cap respected, a secret refused before
     the lookup;
   - option errors in the same order, messages and levels (the ErrorLevels
     specs);
   - the probe rule: present at load, installed after load;
   - in-place upgrade from revision 8, with an asynchronous job running.
   Client suite (`tests/client/MoltenCodesTest_CodecKit/`, never run here):
   a `SetLimits` with a table key carrying `__tostring` is refused without
   running it.
8. Docs: `docs/API.md` (key descriptions in the refusals, cost notes),
   `INTERNALS.md` (lazy tables, the cache, plain finds, one-pass options),
   `CHANGELOG.md` 0.2.2, `README.md` performance and memory notes,
   `tests/README.md`, the client suite's `EXPECTED.md`.
9. Status: implemented 2026-11-15 under core decisions 18 and 19, 0.2.2,
   revision 9, 16 specs (165). A flat `Encode` and an inline number path were
   not tried: the profile puts the remaining cost per value.

Moved from `docs/ROADMAP.md` (Package O — memory, performance and ease of use (decisions 18 and 19)).

## codecKit (package O): compression as a part

**codecKit (package O): compression as a part** — a change to facade `CodecKit`

1. Package `codecKit`, facade `CodecKit`, API generation 1 (additive),
   version 0.3.0 (from 0.2.2), implementation revision 10 (from 9). Part
   `Compression`, revision 1.
2. Purpose: the DEFLATE compressor, inflater, Huffman code builders, table
   builders and the native compressor are 40 KB of CodecKit's 96 KB of live
   prototypes and 56.7 KB resident, carried by every addon that serialises.
   Usage: AceSerializer is referenced by 6 of 16 corpus addons (Details,
   Grid2, Plater, Rarity, Skada, WeakAuras), all for values, and CommKit's
   documented send recipe uses `Encode` with the addon channel; Ace3 has no
   compression, and nothing in this repository calls `Compress` or
   `compress = true` besides CodecKit itself. The print channel stays in the
   core: 5.0 KB of prototypes with its tables already built on first use, and
   it is what an export string needs even uncompressed. The asynchronous
   variants stay: their yield checks live in the serialiser's loops.
   Non-goals: format changes; a native inflater.
3. Dependencies: core unchanged (registry API 2, poolKit API 1,
   schedulerKit API 1 optional). Part: none beyond its core.
4. Surface:
   - New: `CodecKit:HasPart(name)`.
   - With the part: `Compress`, `Decompress`, `compress`/`level` options and
     compressed frames exactly as today, byte for byte.
   - Without it: `Compress`, `Decompress`, and `Encode`, `EncodeMany` or
     `EncodeAsync` with `compress = true`, raise at the caller with the file
     to embed (a setup mistake, deterministic). Decoding a compressed frame
     is data from a peer, so it never raises: `Decode`, `DecodeMany` return
     `nil, "compressionUnavailable"`, `DecodeAsync` calls back with
     `false, "compressionUnavailable"`, a new reason within the non-raising
     contract. A peer can therefore never make an addon raise by sending a
     compressed frame.
5. Ownership: unchanged. The lazily built DEFLATE tables move into the part
   and stay file-local to it, built on first use as since revision 9.
6. Performance and memory: CodecKit 148.5 KB → 91.8 KB measured for the core
   (about 93 KB expected), part 56.7 KB, plus 59.0 KB of tables after the
   first Lua compression or decompression. Against AceSerializer (11.5 KB):
   12.9× → 8.0×. Encode and decode of uncompressed frames unchanged (one
   flag test that already exists); the `codec` bench within noise. Main
   chunk 190 → about 182 locals.
7. Tests: Bootstrap and Manifest for the part; every compression spec and
   the byte-for-byte round trips with the part; without it: each raising
   entry at the caller's line, `compressionUnavailable` from the three
   decode paths, uncompressed frames unaffected; in-place upgrade from
   revision 9 with an asynchronous compression running (part loaded: it
   finishes; not loaded: it completes with `false,
   "compressionUnavailable"` and one report); revision 9 after a core-only
   revision 10 yields. Client suite: native compression through the part.
8. Docs: README, `docs/API.md` (Parts, `HasPart`, the new reason under
   "The non-raising contract" and "Compression"), `INTERNALS.md`,
   `CHANGELOG.md` 0.3.0, `tests/README.md`, client suite `EXPECTED.md`.
9. Status: implemented 2026-11-15, 0.3.0, revision 10, 184 specs. Core about
   95 KB (148.5 KB before), Compression part 59.2 KB plus about 59 KB of
   tables on the first Lua compression. A compression an older revision had
   already started completes on its own code; encoders name the option in the
   missing-part error.

