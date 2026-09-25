# CodecKit Internals

This document describes implementation invariants for maintainers. It is not an additional public API; the wire format is specified in [`API.md`](API.md).

## Package state

`CodecKit._state` is shared by every embedded copy:

| Field | Meaning |
|---|---|
| `schema` | The state layout version, `1`. |
| `runtimeRevision` | The revision that last committed its functions. |
| `limits` | The five shared limits, each an integer or, for `maxValues` and `maxStringLength`, the `unbounded` sentinel. `SetLimits` writes here; every call copies them into its work record as numbers, `math.huge` for a lifted limit, so no stage tests for the sentinel. |
| `unbounded` | The table published as `CodecKit.UNBOUNDED`, shared by every revision. |
| `pool` | The PoolKit table pool (`maxRetained` 16) the compression and print stages of a synchronous call lease their sinks from. |

Nothing else is package state: CodecKit keeps no registrations and no per-consumer objects. The idle work record (below) belongs to each loaded copy of the file, not to the shared state.

## Work records and buffers

Every call opens one **work record**: the copied limits, the secret probe (or `false`), the value counter, the text length the reader checks against, the SchedulerKit context of an asynchronous call (or `false`), `pooled`, and two tables that belong to the record: the serialiser's **writer** and the **open-table stack** (`visited`) its cycle check uses.

A synchronous call takes the file's one idle work record, built once when the file loads, and gives it back when it returns; none of the three tables is leased. A PoolKit `Acquire` and `Release` pair costs about as much as serialising a small value, and serialising and reading back run for every addon message. A call that finds no idle record builds a fresh one. That happens only for a call nested inside another (no user code runs inside a synchronous call, so only a host probe such as `issecretvalue` could nest one) or after a call that raised before it gave its record back; whichever record is given back while none is idle becomes the idle one, so the package returns to allocation-free calls by itself. The record keeps nothing of a call: the writer drops its string values and chunks on every path, and `closeWork` empties the open-table stack, which a refused value leaves filled.

The **writer** collects the serialised bytes:

| Field | Meaning |
|---|---|
| `[1..count]` | Fragments: one-byte strings from a table built at load, string values, and the frame header. |
| `byteText` | The byte table in use: plain, or with the addon channel's five escapes applied. |
| `escapeStrings` | Whether string values are escaped for the addon channel as they are written. |
| `size` | Serialised bytes so far, before escaping, for the `maxOutputBytes` check after every value. |
| `textSlots`, `textCount` | The slots holding string values, which are the only fragments that can reference the caller's data; the writer clears just those. |
| `chunks`, `chunkCount` | Joined buffers: once a value ends with 4096 fragments or more, the buffer becomes one chunk string and starts again, so the reused buffer stays at about 4096 slots (64 KiB) however large the payload. |

An uncompressed `Encode` writes the frame header as the first fragment and, for the addon channel, escapes while it writes: every byte through the escaped byte table, and a string value through one `gsub` when `find` shows it holds an escaped byte. Escaping maps single bytes, so escaping fragment by fragment gives exactly the bytes escaping the joined body would. The frame is then the one string `table.concat` builds, measured once against `maxOutputBytes` (it is two bytes longer than the escaped body the stage limit covers). Compressed and print frames serialise without a header or escapes and run the later stages as before.

A **sink** collects the output of the compression and print stages:

| Field | Meaning |
|---|---|
| `[1..count]` | String fragments. |
| `batch`, `batchCount` | Pending bytes as numbers; at 1024 they become one fragment through `string.char(unpack(...))`. |
| `chunks`, `chunkCount` | Leased on demand: at 1024 fragments the fragments are concatenated into one chunk, so no leased array grows past 1024 entries. |
| `total` | Bytes in fragments, for the `maxOutputBytes` checks. |

A sink is leased from the shared PoolKit pool (`maxRetained` 16) with its batch and possibly its chunk array, as is the bit writer for a short compression input; `finishSink` and `closeSink` return a sink's tables and `compressTiny` its writer, on every return path. The pool's shallow reset clears them on release, so nothing a call wrote survives into the next. Because nothing is shared between calls but the idle record and the pool, and a nested call never shares the record, calls are re-entrant.

An asynchronous call sets `pooled = false` and uses plain tables throughout, a work record of its own included: SchedulerKit never resumes a cancelled job, and a table leased by an abandoned coroutine would stay in the pool's active set.

## Serialiser

`writeValue` and `readValue` recurse once per table level (two Lua frames per level with `writeTable` and `readTable`), so the Lua stack depth is bounded by `maxDepth` (ceiling 128; a bare Lua 5.1.5 interpreter overflows near 9995 levels). The writer asks the secret probe before `type` dispatch, counts every value against `maxValues`, and checks the serialised size after every value. Short strings, integers from 1 to 127, booleans and `nil` are appended inline, without a call per byte.

A table is a cycle when it is already open on the path from the top. The open tables are the stack `visited[1..depth - 1]`: `writeTable` stores its table at its depth on the way down and clears the slot on the way up, and compares a new table with the open ones using `rawequal`, so no `__eq` metamethod runs. A table reached twice through different paths is therefore written twice (and bounded by `maxValues`), while a table reached from itself is a cycle. Revision 4 kept a set keyed by table instead; every distinct table left a dead key in it, and Lua rehashed the set as they accumulated.

Table contents are read raw. An element of the array part is known to be present and so is every key `next` yields, so indexing them returns the raw value without reaching a metatable; only the probe for the array part's end, which may meet an absent index, uses `rawget`. One `next` pass counts every key (the map part is that count less the array part), a second writes the map part, so no key list is allocated.

The array part is found by `arrayPartLength`, which walks `rawget(t, i)` from 1 while below `#t` and so ends it at the first hole whatever border `#` picked; it tests elements with `type`, never `~= nil`, so a secret element is first touched by the secret probe.

An argument list holds at most `maxListValues` entries on both sides (4096 by default, ceiling 7900), because `DecodeMany` returns them with `unpack`, which Lua 5.1.5 refuses past 7997 results (measured: the 8000-slot C stack limit less the three arguments of `unpack`).

`EncodeAsync` asks about secrets before it schedules the job. `containsSecret` visits values in the writer's order (array part, then map keys and values), counts them as `writeValue` does and stops where the writer would refuse with `maxValues` or `maxDepth`, so any secret the job could reach is found at the call. It also stops after `maxOutputBytes + maxDepth + 2` values: every value started has written at least one byte, and at most `maxDepth + 1` are started but not yet measured, so the writer must have refused with `maxOutputBytes` by then. Only a lifted `maxValues` makes that bound the one that applies.

The reader bounds-checks every byte it reads with `string.byte`, which returns `nil` past the end, and refuses an array or map count larger than the bytes left before looping over it. A length, count or integer below 128 is one varint byte and is read inline; `readVarint` takes every other case, the end of the text included. Refusals return up the recursion as `nil, reason`; there is no `pcall`, which is what lets the asynchronous form yield from inside the recursion.

The reader works on absolute positions in the text it is given, so a frame's body is read where it lies: `decodeFrame` hands the whole frame over with the body starting at byte 3. An addon frame is unescaped only when `find` shows an escape or forbidden byte after the header; otherwise the addon stage would return its input unchanged, and only its input limit is checked. When there is something to unescape, the addon stage runs over the whole frame from byte 3, since the header bytes are neither forbidden nor the escape byte, and refuses exactly as before. A compressed body is still copied out once for the inflater.

## Compressor

The DEFLATE implementation is one `do` scope that exports `compressInto` and `inflateInto`, so its tables and helpers do not count against the 200 locals Lua 5.1 allows the main chunk.

**Short input.** Below 64 bytes the matcher is skipped: the input is written as one fixed-Huffman block of literals, or one stored block when that is smaller, through a leased bit writer, so a short addon message allocates nothing.

**Input.** The input is loaded into an array of byte values, eight per `string.byte` call.

**Hash chains.** The key of a position is its three bytes as one 24-bit number, so a chain holds only true three-byte matches and a candidate never needs its first bytes re-checked. `head[key]` is the latest position with that key and `previous[position % 32768]` the one before it. A chain is followed while the candidate is inside the 32 KiB window, the chain budget lasts, and each step moves strictly backwards (a ring slot overwritten by a newer position ends the chain).

**Levels.** Parameters follow zlib's well-known configuration table, except that levels 8 and 9 cap the chain at 192 and 256 (zlib: 1024 and 4096) so level 9 stays within about three times level 6 on low-entropy input:

| Level | Strategy | `chain` | `nice` | `good` | `lazyLimit` |
|---|---|---|---|---|---|
| 1 | greedy | 4 | 8 | 4 | 4 |
| 2 | greedy | 8 | 16 | 4 | 5 |
| 3 | greedy | 32 | 32 | 4 | 6 |
| 4 | lazy | 16 | 16 | 4 | 4 |
| 5 | lazy | 32 | 32 | 8 | 16 |
| 6 | lazy | 128 | 128 | 8 | 16 |
| 7 | lazy | 256 | 128 | 8 | 32 |
| 8 | lazy | 192 | 258 | 32 | 128 |
| 9 | lazy | 256 | 258 | 32 | 258 |

`chain` is how many candidates a search visits, quartered when the match to beat is already `good`; a search stops at a match of `nice` bytes. Greedy levels take every match and insert the positions inside it only up to `lazyLimit` bytes. Lazy levels hold each match back by one position and emit a literal instead when the next position starts a longer match; no deferred search runs once the held match reaches `lazyLimit`. A three-byte match more than 4096 bytes back is dropped for literals in both.

**Blocks.** Tokens (a literal byte, or a length and distance) accumulate with their symbol frequencies until a block holds 16384 tokens or covers 32768 input bytes. Then the block's size is computed three ways — stored (header, padding, the length and its complement, raw bytes), fixed Huffman, and dynamic Huffman including its header — and the smallest is written. A stored block copies the input substring it covers, which is why the byte bound keeps it below the format's 65535.

**Huffman codes.** Used symbols are sorted by frequency (frequency and symbol packed into one number, so the default comparator sorts without a closure), a tree is built with the two-queue method, and its depth counts are folded under 15 bits (7 for the code-length code) and repaired until the Kraft sum is exactly one. The shortest lengths go to the most frequent symbols. A code with fewer than two used symbols is padded with unused ones so it is always complete. Canonical codes are assigned as RFC 1951 3.2.2 describes and stored bit-reversed, because Huffman codes are packed most significant bit first into a stream read least significant bit first.

**Dynamic header.** The literal and distance lengths are run-length coded as one sequence with the code-length alphabet (16: repeat the previous length 3–6 times; 17: 3–10 zeros; 18: 11–138 zeros), trailing unused lengths trimmed to the format's minimum counts.

**Bits.** The bit writer keeps a number and a bit count and emits whole bytes into the sink's batch; all arithmetic stays far below 2^53.

## Decompressor

The reader record holds the input, the next byte position and a bit buffer filled one byte at a time. A **decoder** maps `2^length + reversedCode` to the symbol, so a lookup for a given length matches exactly the codes of that length; decoding peeks up to the longest code length and tries each length from the shortest. Building one is linear in the number of symbols, so table construction never grows with the table size; a hostile stream of tiny dynamic blocks still costs more per input byte than ordinary data — about ten times — but that cost is linear in the input and bounded by `maxOutputBytes` on the input side.

A code set is refused when over-subscribed, and when incomplete unless it is the single one-bit code RFC 1951 allows; a distance code with no lengths is accepted until a block uses a distance. A literal code without end-of-block is refused. A stored block first discards the bits to the byte boundary, then gives back the whole bytes the bit buffer read ahead, because they are the first bytes of its data.

Output accumulates as byte values in one array, needed anyway for back-references; `maxOutputBytes` is checked before each literal and each copy. After the final block, any whole byte left unread is `"trailingData"`.

## Print channel

A group of four bytes is at most 2^32 − 1 and five base-85 digits at most 85^5 − 1, both exact in doubles, so the arithmetic is plain division and remainder. The alphabet is computed at load from printable ASCII minus the excluded characters, and the load fails loudly if it does not come to 85.

## Upgrades

A newer revision keeps `_state` (limits, the `UNBOUNDED` sentinel and pool) and rewrites the facade's functions and constants. Sinks exist only during a call, and the idle work record is file-local: each revision builds its own and holds nothing in it between calls, so no object carries state from the revision that built it. No revision so far has changed the state layout: revisions 2 to 5 inherit the state revision 1 built unchanged, and so will a later revision that keeps schema 1.
