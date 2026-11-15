# Expected result: `/mct run bridgeKit`

Installed with
`python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --package bridgeKit`
on Retail, and nothing else from the MoltenCodes framework enabled in the
client. The two tests that compare with real Ace3 need the pinned Ace3 in the
client as well, which the benchmark installer puts there as the
load-on-demand addon `MoltenCodesBench_Ace3`:

```bash
python3 -m tooling.bench.client_install --wow-dir "/Applications/World of Warcraft"
```

Without it, those two tests are skipped with the reason (see
[Without Ace3](#without-ace3)). No result has been recorded in the client yet;
the lines below are what the code and the host specs predict.

**What this test sends.** Every message is a `WHISPER` addon message
addressed to the character you are playing, as `Name-Realm`; the server hands
it straight back to you. Nothing is sent to anyone else, and addon messages
never appear in the chat frame. A run sends at most 19 addon messages, over a
few seconds.

Run it standing idle, out of combat, solo, outside any instance. A normal run
finishes within about ten seconds.

## At login

```text
MoltenCodes Test: test suites loaded for bridgeKit. Type /mct run bridgeKit to run them; /mct help lists every command.
```

## After `/mct run bridgeKit`

With `MoltenCodesBench_Ace3` installed, exactly these lines, in this order:

```text
MoltenCodes Test: running bridgeKit: 6 suites. Results follow when every test has finished.
MoltenCodes Test: PASS bridgeKit.facade: Registry:Get('bridgeKit', 1) is the BridgeKit facade with API 1 and every documented method
MoltenCodes Test: PASS bridgeKit.facade: the installed BridgeKit carries the revision of the committed manifest
MoltenCodes Test: PASS bridgeKit.serializer: AceSerialize and AceDeserialize round-trip every byte 00-FF in a string, the edges of the double range and a nested table on the client's Lua
MoltenCodes Test: PASS bridgeKit.serializer: with Ace3 loaded, AceSerializer-3.0 writes the same bytes as BridgeKit for scalars and one-entry tables, and each reads the other's text to equal values
MoltenCodes Test: PASS bridgeKit.aceComm: a channel whispers texts at every framing boundary to the player's own character through CommKit and reassembles each whole and byte-identical
MoltenCodes Test: PASS bridgeKit.aceComm: a text holding every byte 01-FF (| LF CR and 80-FF included) is sent without a refusal and reassembled at most once; what the client carries back is logged, not judged
MoltenCodes Test: PASS bridgeKit.aceComm: with Ace3 loaded, AceComm-3.0 receives what a BridgeKit channel sends, and a BridgeKit channel receives what AceComm-3.0 sends, multipart and escaped
MoltenCodes Test: SKIP bridgeKit.aceDB: an AceDB saved variable written by a first session imports after /reload in both modes, with its backup in WTF and every field read as before -- not run: it needs an AceDB saved variable from an earlier session; packages/bridgeKit/tests/AceDB_spec.lua covers the import through SettingsKit itself on the host
MoltenCodes Test: PASS bridgeKit.aceConfig: an AceConfig table converted by DefineAceConfig is rendered by WidgetKit, and a write through the tree reaches the Ace handler with the Ace info shape
MoltenCodes Test: PASS bridgeKit.secrets: AceSerialize refuses a secret value and OpenAceComm a secret prefix, each at this file's line
MoltenCodes Test: bridgeKit: 9 passed, 0 failed, 1 skipped, 0 timed out (10 tests)
MoltenCodes Test: results saved in MoltenCodesTestResults; /reload or log out to write them to disk.
```

The `aceDB` skip is expected on every client: the import across `/reload`
needs an AceDB saved variable written by an earlier session, which a single
run cannot produce. The host specs import through SettingsKit itself and read
every field back before and after compaction.

### Without Ace3

The two `with Ace3 loaded` tests print `SKIP` instead, with the reason
`MoltenCodesBench_Ace3 is not installed (...); install it with python3 -m
tooling.bench.client_install to compare with real Ace3`, and the totals line
reads `7 passed, 0 failed, 3 skipped, 0 timed out (10 tests)`.

### Per flavour

Classic Era and Mists of Pandaria Classic have no secret values: the
`secrets` test is skipped there with the harness's reason, and the totals
gain one skip. Those clients have not been run (no game time; see
`tests/client/README.md`).

## What each test proves

| Test | Proves in the real client |
|---|---|
| `Registry:Get('bridgeKit', 1) ...` | The loaded facade is API 1 with every method docs/API.md lists and `ACE_WIRE_VERSION` 1; the log gives `ACE_BASELINE.commit`. |
| `the installed BridgeKit carries the revision ...` | Registry selected the committed manifest's revision. |
| `AceSerialize and AceDeserialize round-trip ...` | The client's `tostring`, `string.format("%.0f")` and `frexp` write numbers the reader reads back exactly: 0, -0.5, 2^53 + 2, 1/3, the smallest subnormal, the largest double and both infinities; a string of every byte and a nested table with a number key round-trip. |
| `with Ace3 loaded, AceSerializer-3.0 writes the same bytes ...` | For strings with every escaped byte, integers, fractions, a subnormal and both booleans, alone and in a one-entry table, `AceSerializer:Serialize` and `BridgeKit:AceSerialize` produce identical text; each library reads the other's text of a record back to an equal value. A difference logs the first differing byte. |
| `a channel whispers texts at every framing boundary ...` | Through the real CommKit raw messages and the server: 10 bytes (one message), 254 bytes starting with `01` (escaped by `04`), 255 bytes starting with `01` and 256 bytes (two parts), 509 bytes (three parts, a one-byte last part) each come back whole, byte-identical and in order; no stream stays open. Nine addon messages. |
| `a text holding every byte 01-FF ...` | Design 13.2, item 2: whether addon messages carry `\|`, LF, CR and 80-FF unchanged. The send must be accepted and at most one message reassembled; the log says whether the text came back unchanged, changed (with the first difference) or not at all. Two addon messages. CommKit's suite already proves 01-FF but 0A, 0D and 7C cross unchanged. |
| `with Ace3 loaded, AceComm-3.0 receives ...` | A BridgeKit channel's escaped short text and 594-byte multipart text arrive whole in an AceComm-3.0 `RegisterComm` callback, and the same two texts sent with `SendCommMessage` arrive whole in a BridgeKit channel. Eight addon messages. |
| `an AceConfig table converted by DefineAceConfig ...` | The converted tree defines in OptionsKit and renders with `WidgetKit:RenderOptions`; `tree:Set("scale", 1.5)` calls the Ace handler's `Set` with an `info` whose `appName`, `option` and last path entry are Ace's. |
| `AceSerialize refuses a secret value ...` | A `secretwrap` value is refused at this file's line by `AceSerialize` and by `OpenAceComm` as the prefix. |

## What a run leaves behind

Every CommKit scope, channel, widget and OptionsKit definition a test creates
is released by its suite's After hook. What stays in the session until
`/reload`: the prefixes `MCTBridgeComm`, `MCTBridgeToAce` and
`MCTBridgeFromAce` registered with the client (it cannot unregister a prefix;
later runs reuse them), BridgeKit's counters, and, when it was loaded, Ace3's
libraries from `MoltenCodesBench_Ace3`. Nothing is written to a saved variable
besides the harness's own results.

## What counts as unexpected

- Any `FAIL` or `TIMEOUT` line, or a `SKIP` other than those above.
- `with Ace3 loaded, AceSerializer-3.0 writes the same bytes ...` failing: the
  log names the value and the first differing byte; BridgeKit's recorded
  fixtures disagree with the client's Ace3.
- `a channel whispers texts at every framing boundary ...` failing: the log
  names the text and the first differing byte, or how many came back.
- A Lua error window naming `MoltenCodes`, `MoltenCodesTest` or
  `MoltenCodesTest_BridgeKit`, or a whisper window or "player not found"
  message.

## What to send back

The chat lines, and after `/reload` the file
`WTF/Account/<ACCOUNT>/SavedVariables/MoltenCodesTest.lua` from the flavour
folder: it holds each test's logs, among them what the client carried in the
every-byte test.
