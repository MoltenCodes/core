# Expected result: `/mct run codecKit`

Installed with
`python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --package codecKit`
and nothing else from the MoltenCodes framework enabled in the client. Run it
out of combat.

## At login

One line from the harness:

```text
MoltenCodes Test: test suites loaded for codecKit. Type /mct run codecKit to run them; /mct help lists every command.
```

## After `/mct run codecKit`

Within about ten seconds, exactly these lines, in this order (`PASS` is green
in the client). The performance and interoperability tests compress a 50 KB
table several times, the fuzz tests decode 3500 strings six ways each, and the
three allocation tests each run full garbage collections first, so the client
may stutter for a moment; the `EncodeAsync`/`DecodeAsync` test spreads its
work over rendered frames and takes about a second:

```text
MoltenCodes Test: running codecKit: 9 suites. Results follow when every test has finished.
MoltenCodes Test: PASS codecKit.facade: Registry:Get('codecKit', 1) is the CodecKit facade with API 1, its sixteen methods, FORMAT_VERSION 1, the 85-character PRINT_ALPHABET and UNBOUNDED
MoltenCodes Test: PASS codecKit.facade: the installed CodecKit carries the revision of the committed manifest
MoltenCodes Test: PASS codecKit.facade: the client's Lua has string.byte, string.char, math.floor, math.frexp, math.ldexp and unpack, all CodecKit computes with; bit, C_EncodingUtil, SendAddonMessage, issecretvalue and SchedulerKit logged
MoltenCodes Test: PASS codecKit.values: Serialize writes the bytes docs/API.md spells out for 300, 1.5, -0, 2^-1074, NaN, {} and { 1, x = 2 } on the client's math.frexp and string.char
MoltenCodes Test: PASS codecKit.values: every kind of number round-trips bit for bit through Serialize and Deserialize on the client: integers to 2^53, fractions, 2^53 + 2, both infinities, NaN, -0 and subnormals
MoltenCodes Test: PASS codecKit.values: a string of every byte value 0 to 255, alone and in a table, round-trips through all six stage combinations with the documented header
MoltenCodes Test: PASS codecKit.values: EncodeMany and DecodeMany carry an argument list with nils in the middle and at the end through the addon channel, as select('#') and unpack count them
MoltenCodes Test: PASS codecKit.channels: addon-channel text of every byte value and of 300 random payloads from math.random, plain and deflated, holds no NUL, line feed, carriage return or raw pipe and escapes 0xFF, so C_ChatInfo.SendAddonMessage's byte rules hold (nothing sent)
MoltenCodes Test: PASS codecKit.channels: a deflated print export string of the sample value uses only PRINT_ALPHABET, starts with '!', and decodes again after chat-style wrapping at 60 characters with indentation
MoltenCodes Test: PASS codecKit.channels: a decoder told options.channel refuses a frame of another channel with channelMismatch, so an addon-message handler refuses a pasted export string
MoltenCodes Test: PASS codecKit.interop: C_EncodingUtil.DecompressString with Enum.CompressionMethod.Deflate inflates CodecKit:Compress output at levels 1, 6 and 9 for prose, random binary, a 32-byte message and the serialised 50 KB roster
MoltenCodes Test: PASS codecKit.interop: CodecKit:Decompress inflates C_EncodingUtil.CompressString raw Deflate output at the client's Default, OptimizeForSpeed and OptimizeForSize levels for the same four inputs
MoltenCodes Test: PASS codecKit.interop: on the 50 KB roster CodecKit and C_EncodingUtil are logged side by side (Serialize vs SerializeCBOR, Compress vs CompressString, EncodeForPrint vs EncodeBase64, and back), and CodecKit's print text is exactly 25% larger than its input
MoltenCodes Test: PASS codecKit.performance: a 288-member guild roster serialises to 48-56 KB, and Serialize, Compress, EncodeForPrint, EncodeForAddon, the whole export Encode and its Decode are each timed on the client and give back an equal table
MoltenCodes Test: PASS codecKit.performance: EncodeAsync of the 50 KB roster on a SchedulerKit scope spreads over at least two rendered frames and hands its callback exactly the synchronous export string, and DecodeAsync gives back an equal table
MoltenCodes Test: PASS codecKit.malformed: 1000 random byte strings of 0 to 64 bytes from the client's math.random make none of the six decoders raise, and every refusal is a documented reason
MoltenCodes Test: PASS codecKit.malformed: 1000 random bodies behind a version byte and every flags value from 0x00 to 0x0F make none of the six decoders raise, and every refusal is a documented reason
MoltenCodes Test: PASS codecKit.malformed: 1000 random mutations of valid frames (bytes replaced, cut short, a byte inserted, bytes appended) in every stage combination make none of the six decoders raise
MoltenCodes Test: PASS codecKit.malformed: 500 random strings of print characters behind '!', with stray whitespace, make none of the six decoders raise
MoltenCodes Test: PASS codecKit.allocation: Encode of a small table again allocates nothing on the none, addon and print channels, 2000 calls each
MoltenCodes Test: PASS codecKit.allocation: Decode of the addon frames of true, 42, -1.5 and 'name' again allocates nothing over 2000 rounds
MoltenCodes Test: PASS codecKit.allocation: Compress of a 32-byte message again, and Encode of the small table deflated for the addon channel, allocate nothing over 2000 calls each
MoltenCodes Test: PASS codecKit.errors: Encode called with a dot names CodecKitSuite.lua at the calling line
MoltenCodes Test: PASS codecKit.errors: an unknown option key, a channel outside its set, level 10 and Compress options that are not a table are refused at the calling line
MoltenCodes Test: PASS codecKit.errors: Decode of a number and DecodeForAddon of a table are refused at the calling line, because the non-raising contract covers strings only
MoltenCodes Test: PASS codecKit.errors: SetLimits with UNBOUNDED for maxDepth is refused at the calling line with its reason, and the limits stay as they were
MoltenCodes Test: PASS codecKit.errors: EncodeAsync with a table that is not a scope, and with a closed SchedulerKit scope, is refused at the calling line and never calls back
MoltenCodes Test: PASS codecKit.secrets: Encode refuses a secretwrap value at the top, in an array, as a map value and three tables deep, each at the calling line, and leaves no pooled table leased
MoltenCodes Test: PASS codecKit.secrets: EncodeMany and Serialize refuse a secret argument at the calling line
MoltenCodes Test: PASS codecKit.secrets: EncodeAsync refuses a secret deep in the value at the calling line, schedules no job and never calls back
MoltenCodes Test: PASS codecKit.secrets: a secret string handed to Decode, DecodeMany, Deserialize, Decompress, DecodeForAddon and DecodeForPrint is refused at the calling line before anything reads it
MoltenCodes Test: PASS codecKit.secrets: a secret options.level, a secret options.channel and a secret SetLimits maxDepth are refused at the calling line and the limits stay as they were
MoltenCodes Test: codecKit: 32 passed, 0 failed, 0 skipped, 0 timed out (32 tests)
MoltenCodes Test: results saved in MoltenCodesTestResults; /reload or log out to write them to disk.
```

Running it again in the same session prints the same lines.

## Visible side effects

None. Nothing is drawn, no sound plays, no chat line other than the
harness's appears, no client setting (CVar) changes, and nothing is sent:
`C_ChatInfo.SendAddonMessage` is only looked up, and the addon-channel test
checks the encoded text against the byte rules instead of sending it. The
`C_EncodingUtil` calls work on strings in memory. The only thing a player can
notice is a short stutter while the large payloads are compressed and while
the allocation tests collect garbage.

## What stays for the session

Every SchedulerKit scope a test creates (the asynchronous test and the
EncodeAsync refusals) is closed by its suite's After hook, pass or fail, which
cancels any job still queued on it. CodecKit's package-wide limits are not
changed: the two `SetLimits` calls are refusals the tests check, and the
fuzz and secret tests check the limits and the pool afterwards. CodecKit's
table pool keeps up to 16 idle tables, as after any use. Nothing is written
to a global or a saved variable other than the harness's own results.

### On a client without secret values

The five `codecKit.secrets` tests need the client's `issecretvalue` and
`secretwrap`. `secretwrap` is the one documented way to obtain a genuine secret
out of combat without side effects: the client's own API documentation
(`FrameScriptDocumentation`, mirrored in
`packages/apiKit/metadata/retail/namespaces.json`) lists it with no
restriction, and it only converts the values handed to it. Retail 12.1 has
both. A client without them prints these five lines instead:

```text
MoltenCodes Test: SKIP codecKit.secrets: Encode refuses a secretwrap value at the top, in an array, as a map value and three tables deep, each at the calling line, and leaves no pooled table leased -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP codecKit.secrets: EncodeMany and Serialize refuse a secret argument at the calling line -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP codecKit.secrets: EncodeAsync refuses a secret deep in the value at the calling line, schedules no job and never calls back -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP codecKit.secrets: a secret string handed to Decode, DecodeMany, Deserialize, Decompress, DecodeForAddon and DecodeForPrint is refused at the calling line before anything reads it -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP codecKit.secrets: a secret options.level, a secret options.channel and a secret SetLimits maxDepth are refused at the calling line and the limits stay as they were -- the client has no issecretvalue and secretwrap; the secret path was not exercised
```

### On a client without `C_EncodingUtil`

The three `codecKit.interop` tests need `C_EncodingUtil.CompressString` and
`C_EncodingUtil.DecompressString`, which Retail 12.1 documents
(`packages/apiKit/metadata/retail/namespaces.json`). A client without them
prints these three lines instead:

```text
MoltenCodes Test: SKIP codecKit.interop: C_EncodingUtil.DecompressString with Enum.CompressionMethod.Deflate inflates CodecKit:Compress output at levels 1, 6 and 9 for prose, random binary, a 32-byte message and the serialised 50 KB roster -- the client has no C_EncodingUtil.CompressString and DecompressString; interoperability was not exercised
MoltenCodes Test: SKIP codecKit.interop: CodecKit:Decompress inflates C_EncodingUtil.CompressString raw Deflate output at the client's Default, OptimizeForSpeed and OptimizeForSize levels for the same four inputs -- the client has no C_EncodingUtil.CompressString and DecompressString; interoperability was not exercised
MoltenCodes Test: SKIP codecKit.interop: on the 50 KB roster CodecKit and C_EncodingUtil are logged side by side (Serialize vs SerializeCBOR, Compress vs CompressString, EncodeForPrint vs EncodeBase64, and back), and CodecKit's print text is exactly 25% larger than its input -- the client has no C_EncodingUtil.CompressString and DecompressString; interoperability was not exercised
```

With both missing, the totals line reads
`24 passed, 0 failed, 8 skipped, 0 timed out (32 tests)`; with only one
missing, `27 passed, 0 failed, 5 skipped` or `29 passed, 0 failed, 3 skipped`.
On Retail 12.1 any `SKIP` is unexpected.

## What each test proves

| Test | Proves in the real client |
|---|---|
| `Registry:Get('codecKit', 1) is the CodecKit facade ...` | The facade the client loaded is API 1 with all sixteen methods, `FORMAT_VERSION` 1, the 85-character `PRINT_ALPHABET` from `!` to `~` and the `UNBOUNDED` sentinel. The log gives the session's five limits. |
| `the installed CodecKit carries the revision ...` | Registry's selected revision and the facade's `REVISION` are both the committed manifest's, not an older or newer embedded copy. |
| `the client's Lua has string.byte, string.char, math.floor, ...` | Everything CodecKit computes with exists in the client's Lua. CodecKit uses no `bit` library at all (its shifts and masks are `math.floor`, `%` and multiplication; doubles go through `math.frexp` and its inverse), so the log only records whether `bit` and `bit32` exist and which functions they have. The log also lists which `C_EncodingUtil` functions exist, the value of `Enum.CompressionMethod.Deflate` (and whether it came from `Enum` or from the documented value 0), whether `C_ChatInfo.SendAddonMessage` exists (never called), the secret functions and SchedulerKit's revision. |
| `Serialize writes the bytes docs/API.md spells out ...` | The client's `math.frexp`, its inverse and `string.char` produce exactly the documented wire bytes: `300` is `04 AC 02`, `1.5` is `06 3F F8 00 ...`, `-0` is `06 80 00 ...`, `2^-1074` is `06 00 ... 01`, NaN is the quiet NaN `06 7F F8 00 ...`, `{}` is `08 00` and `{ 1, x = 2 }` is `0A 01 04 01 01 07 01 78 04 02`. The log has each in hexadecimal. |
| `every kind of number round-trips bit for bit ...` | 23 numbers (varint boundaries, ±2^53, 2^53 + 2, fractions, π, ±1e±300, both infinities, the smallest and largest subnormal numbers, the smallest normal, −0) decode to the same number, −0 keeps its sign (`1 / x` is `-inf`), NaN stays NaN, and re-serialising gives the same bytes. |
| `a string of every byte value 0 to 255 ...` | The client's strings carry NUL and every high byte through all six stage combinations; each frame has header `01` and flags `01`, `03`, `05`, `07`, or starts with `!` on the print channel; a table holding the string as a value and as a key comes back equal. The log gives every frame size. |
| `EncodeMany and DecodeMany carry an argument list with nils ...` | `select('#')` and `unpack` in the client keep the list at five values, `nil`s in the middle and at the end included. |
| `addon-channel text of every byte value and of 300 random payloads ...` | Every addon text CodecKit writes, from `EncodeForAddon` of all 256 byte values (exactly 261 bytes: five escapes) and from `Encode` of 300 payloads from the client's `math.random`, plain and deflated, has no raw NUL, line feed, carriage return or `\|`, and every `0xFF` is followed by `0` to `4`: the byte rules docs/API.md states for `C_ChatInfo.SendAddonMessage`, checked without sending. Each decodes back exactly. The log gives the longest text and how many pass the client's 255-byte message limit, which CodecKit leaves to CommKit's chunking. |
| `a deflated print export string of the sample value ...` | An export string uses only the alphabet, starts with `!`, and still decodes after it is wrapped at 60 characters with CR LF line breaks and indentation, as a chat window or forum would. |
| `a decoder told options.channel refuses a frame of another channel ...` | The `channelMismatch` assertion in both directions, and the right channel still decodes. |
| `C_EncodingUtil.DecompressString with Enum.CompressionMethod.Deflate inflates ...` | docs/API.md's claim that `Compress` "writes raw DEFLATE that any inflater reads", against the client's own inflater: prose, 4 KB of random bytes (stored blocks), a 32-byte message (the short-input path) and the serialised roster, each at levels 1, 6 and 9, inflate to the exact input. The log gives each size. |
| `CodecKit:Decompress inflates C_EncodingUtil.CompressString raw Deflate output ...` | The converse claim, "`Decompress` reads any raw DEFLATE stream", against the client's own encoder at its three `Enum.CompressionLevel` values. The log gives the client's size and first four bytes: a zlib wrapper would show as `78 ..`, which would mean `Enum.CompressionMethod.Deflate` is not raw DEFLATE. |
| `on the 50 KB roster CodecKit and C_EncodingUtil are logged side by side ...` | Only CodecKit is asserted (`Deserialize` gives back an equal table; the print text is exactly `5 * floor(n / 4)` plus `k + 1` characters). The log is the comparison CodecKit documents no compatibility for: sizes and milliseconds of `Serialize` and `Deserialize` against `C_EncodingUtil`'s own serialiser and its reader, `Compress` level 6 against `CompressString` Default, both inflaters, `EncodeForPrint` (base 85, +25%) against `EncodeBase64` (+33%) and both decoders. |
| `a 288-member guild roster serialises to 48-56 KB ...` | The realistic payload's cost on the client's CPU clock (`debugprofilestop`): `Serialize`, `Compress` (with ms per KiB, to compare with docs/API.md's desktop "Cost" table), `EncodeForPrint`, `EncodeForAddon`, the whole export `Encode` and its `Decode`, and an uncompressed addon-channel round trip, each in a step of its own. Both round trips give back an equal table and no pooled table stays leased. |
| `EncodeAsync of the 50 KB roster on a SchedulerKit scope ...` | "Never freezes a frame" on the real frame loop: the job is still pending after at least one rendered frame at SchedulerKit's 2 ms budget, its callback runs once with exactly the synchronous export string, and `DecodeAsync` gives back an equal table. The log gives the frames, game time and CPU time. |
| `1000 random byte strings ...`, `1000 random bodies behind a version byte ...`, `1000 random mutations of valid frames ...`, `500 random strings of print characters ...` | The non-raising contract on 3500 strings made by the client's `math.random`, each fed to all six decoders: nothing raises, every answer is `true` with a value or `false` with a reason from the documented vocabulary, and afterwards no pooled table is leased and the limits are unchanged. The log counts each reason; a failure logs the offending string in hexadecimal. |
| `Encode of a small table again allocates nothing ...` | docs/API.md's "Encoding the same small value again allocates nothing", on the client's collector, for each of the three channels: after a full collection in its own step and two warm-up calls, 2000 calls move `collectgarbage("count")` by at most 1 KB. |
| `Decode of the addon frames of true, 42, -1.5 and 'name' again ...` | The same for scalar decodes, which return no table. |
| `Compress of a 32-byte message again, and Encode of the small table deflated ...` | The same for the short-input compressor ("a short addon message allocates nothing", docs/INTERNALS.md), alone and inside a deflated addon-channel `Encode`. |
| `Encode called with a dot names CodecKitSuite.lua ...` | The receiver check raises at this file's calling line, as the client names it. |
| `an unknown option key, a channel outside its set, level 10 ...` | Each option refusal at the calling line with docs/API.md's wording. |
| `Decode of a number and DecodeForAddon of a table ...` | The non-raising contract covers strings only: a non-string raises at the calling line. |
| `SetLimits with UNBOUNDED for maxDepth ...` | The refusal names the reason and the range at the calling line, and nothing changes. |
| `EncodeAsync with a table that is not a scope, and with a closed SchedulerKit scope ...` | Both scope refusals at the calling line, and no callback. |
| `Encode refuses a secretwrap value at the top, in an array, ...` | A genuine secret anywhere in the value is refused at the calling line with `CodecKit:Encode value must not contain a secret value`, CodecKit's own message, so CodecKit found it before the client's comparison error could; no pooled table stays leased and the limits are unchanged. The log records whether the client lets a table hold a secret key at all (the CacheKit client run measured that reading `t[secret]` raises `cannot be indexed with secret keys` on Retail 12.1.0 b69933, so a refusal is expected), which is the only way docs/API.md's "in a key" case could arise. |
| `EncodeMany and Serialize refuse a secret argument ...` | The same refusal on the two other encoders. |
| `EncodeAsync refuses a secret deep in the value ...` | The call-time scan finds a secret two tables deep, raises at the caller, and the scope holds no job afterwards. |
| `a secret string handed to Decode, DecodeMany, ...` | All six decoders refuse a secret string at the calling line (`... text must not be a secret value`, `... bytes must not be a secret value`) instead of reading it. |
| `a secret options.level, a secret options.channel and a secret SetLimits maxDepth ...` | Secret settings are refused before anything compares them, and the limits stay as they were. |

## What counts as unexpected

- Any `FAIL` or `TIMEOUT` line, a `SKIP` line on Retail 12.1, or a totals
  line other than `32 passed, 0 failed, 0 skipped, 0 timed out (32 tests)`.
- No login line, or `Expected.lua is missing`: the harness or the installer
  did not run as intended.
- A Lua error window or a BugSack entry naming `MoltenCodes`,
  `MoltenCodesTest` or `MoltenCodesTest_CodecKit`. Every error the suite
  provokes is caught by the test itself. An error report from SchedulerKit
  about a slice over the runaway threshold means one synchronous step took
  longer than 500 ms; send its text.
- An interoperability test failing: the log says whether the client's
  inflater refused CodecKit's stream, or CodecKit refused the client's (with
  CodecKit's reason and the client's first bytes). Either contradicts
  docs/API.md's "Standard compression" and must be reported, not retried.
- A fuzz test failing: the log holds the method and the offending string in
  hexadecimal. That is a defect in CodecKit's non-raising contract.
- An allocation test failing: its log gives the measured deltas. Say which
  other addons are enabled.
- The asynchronous test failing on `pendingAfterFrames >= 1` (a line naming
  `expected boolean false to be boolean true` right after the `EncodeAsync`
  log line): the whole job finished inside one frame, so the budget did not
  spread it; send the log.
- `the installed CodecKit carries the revision ...` failing: another enabled
  addon embeds a different CodecKit copy.
- A `codecKit.secrets` test failing with "secretwrap raised" or "secretwrap
  returned a value issecretvalue does not report as secret": the client's
  secret functions behave differently from their documentation.

## What to send back

1. The chat lines above as they appeared (a screenshot, or a copy of the chat
   log), including any line that differs.
2. After `/reload` or a logout, the file
   `/Applications/World of Warcraft/_retail_/WTF/Account/<ACCOUNT>/SavedVariables/MoltenCodesTest.lua`.
   It holds the full report, each test's logs (whether `bit` exists, the
   `C_EncodingUtil` functions, every timing in milliseconds, the side-by-side
   sizes, the reason counts of the fuzz tests, the memory deltas, the client's
   own error messages with their paths) and the client facts. Lua shortens a
   long file path from the left, so a logged message may start with `...`; the
   tests compare only the `CodecKitSuite.lua:<line>` part.
3. The text of any Lua error, with `/console scriptErrors 1` turned on.
4. The list of other enabled addons, when a test failed.
