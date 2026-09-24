# Expected result: `/mct run cacheKit`

Installed with
`python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --package cacheKit`
and nothing else from the MoltenCodes framework enabled in the client. Run it
out of combat.

## At login

One line from the harness:

```text
MoltenCodes Test: test suites loaded for cacheKit. Type /mct run cacheKit to run them; /mct help lists every command.
```

## After `/mct run cacheKit`

Within about three seconds, exactly these lines, in this order (`PASS` is
green in the client). The age-limit tests wait on the client's clock for
0.2 to 0.5 seconds each, and the six allocation tests each run a full garbage
collection first, which can make the client stutter for a moment:

```text
MoltenCodes Test: running cacheKit: 9 suites. Results follow when every test has finished.
MoltenCodes Test: PASS cacheKit.facade: Registry:Get('cacheKit', 1) is the CacheKit facade with API 1, its six constructors, SetLimits, GetLimits and UNBOUNDED
MoltenCodes Test: PASS cacheKit.facade: the installed CacheKit carries the revision of the committed manifest
MoltenCodes Test: PASS cacheKit.facade: the client has GetTimePreciseSec, so age limits are live, and EventKit API 1 is loaded for ClearOn
MoltenCodes Test: PASS cacheKit.ttl: a NewTtl entry with a 0.3-second limit is present halfway and gone once GetTimePreciseSec passes 0.3 seconds after Set
MoltenCodes Test: PASS cacheKit.ttl: setting the key again restarts its age: set again at 0.2 seconds, it is still present 0.3 seconds after the first Set
MoltenCodes Test: PASS cacheKit.ttl: a 0.2-second negative entry answers nil and 'negative' as a hit, then expires on the real clock while an ordinary entry of its 60-second cache stays
MoltenCodes Test: PASS cacheKit.memoize: Memoize over C_Item.GetItemInfoInstant reads the Hearthstone (6948) once and answers the second call with the same table
MoltenCodes Test: PASS cacheKit.memoize: cacheable keeps item 0, which C_Item.GetItemInfoInstant answers with nothing, out of the cache, so the client is asked on every call
MoltenCodes Test: PASS cacheKit.memoize: Memoize with a 0.3-second limit over C_Spell.GetSpellInfo hands back Auto Attack's (6603) info table until the limit passes, then asks the client again
MoltenCodes Test: PASS cacheKit.clearOn: ClearOn('CVAR_UPDATE') empties the cache inside C_CVar.SetCVar of chatBubbles, every time, and leaves a cache without ClearOn alone
MoltenCodes Test: PASS cacheKit.clearOn: a cache closed after ClearOn stays closed and empty through a later chatBubbles change that still clears an open cache on the same event
MoltenCodes Test: PASS cacheKit.clearOn: ClearOn with an event name the client does not know is refused at the calling line with EventKit's reason, and a retry is refused the same way
MoltenCodes Test: PASS cacheKit.lazy: a Lazy tree resolves each path once, and Invalidate forgets the path's descendants and its ancestors' values but not a sibling
MoltenCodes Test: PASS cacheKit.lazy: a Lazy tree over C_Item.GetItemInfoInstant expands ('item', 6948, 'icon') on first read and keeps item 0's nil answer out of the tree
MoltenCodes Test: PASS cacheKit.lazy: a Lazy tree of maxEntries 2 forgets the least recently read path when a third expands, counting one eviction
MoltenCodes Test: PASS cacheKit.queue: on a full queue of capacity 2, dropOldest stores and returns the oldest, dropNewest returns the value pushed, and reject returns false
MoltenCodes Test: PASS cacheKit.queue: Push and Pop keep first-in first-out order across the ring's wrap-around, and Iterate walks oldest to newest from position 1
MoltenCodes Test: PASS cacheKit.allocation: Get hits, a Get miss, Peek and Set of a stored key on a full NewLru cache allocate nothing over 5000 cycles
MoltenCodes Test: PASS cacheKit.allocation: a NewTtl Get hit, a negative-entry Get and PutNegative and Set over stored keys allocate nothing over 5000 cycles
MoltenCodes Test: PASS cacheKit.allocation: a memoised hit on a C_Item.GetItemInfoInstant memo with cacheable allocates nothing over 5000 calls
MoltenCodes Test: PASS cacheKit.allocation: a Lazy tree Get hit on a three-part path allocates nothing over 5000 reads
MoltenCodes Test: PASS cacheKit.allocation: Push onto a full dropOldest queue and Pop allocate nothing over 5000 cycles
MoltenCodes Test: PASS cacheKit.allocation: 500 full Iterate walks over a queue of 64 values allocate nothing
MoltenCodes Test: PASS cacheKit.errors: NewLru without maxEntries names CacheKitSuite.lua at the calling line
MoltenCodes Test: PASS cacheKit.errors: NewTtl with ttlSeconds 0 names CacheKitSuite.lua at the calling line
MoltenCodes Test: PASS cacheKit.errors: a nil key, a closed cache's Set and a cache method called with UIParent are each refused at the calling line
MoltenCodes Test: PASS cacheKit.errors: PutNegative on a NewLru cache is refused at the calling line because nothing would expire it
MoltenCodes Test: PASS cacheKit.errors: a memoised function called with a table key names CacheKitSuite.lua at the calling line and never runs
MoltenCodes Test: PASS cacheKit.errors: NewQueue with an unknown overflow policy or a capacity above maxQueueCapacity is refused at the calling line
MoltenCodes Test: PASS cacheKit.errors: a Lazy path part that is a table, a nil queue value and Get on a closed tree are each refused at the calling line
MoltenCodes Test: PASS cacheKit.secrets: the client's handling of secrets is logged: rawequal, ==, type, table keys, and CacheKit's read paths
MoltenCodes Test: PASS cacheKit.secrets: a secret value stored with Set comes back from Get and Peek still secret and untouched
MoltenCodes Test: PASS cacheKit.secrets: a memoised function that returns a secret hands it back still secret on the second call without running again
MoltenCodes Test: PASS cacheKit.secrets: a secret value pushed on a queue comes back from Iterate and Pop still secret
MoltenCodes Test: PASS cacheKit.secrets: a secret maxEntries is refused by NewLru, NewTtl, Memoize and Lazy at the calling line
MoltenCodes Test: PASS cacheKit.secrets: a secret NewQueue capacity and a secret SetLimits maxQueueCapacity are refused at the calling line and the limits stay as they were
MoltenCodes Test: PASS cacheKit.secrets: a snapshot read that fills a secret value fails Refresh at the fill line in CacheKitSuite.lua and keeps nothing
MoltenCodes Test: PASS cacheKit.secrets: a secret key reaching Get raises the client's own error, as docs/API.md says, and the cache is unchanged
MoltenCodes Test: cacheKit: 38 passed, 0 failed, 0 skipped, 0 timed out (38 tests)
MoltenCodes Test: results saved in MoltenCodesTestResults; /reload or log out to write them to disk.
```

Running it again in the same session prints the same lines.

## Visible side effects

The **chat bubbles** option (`chatBubbles` CVar, Interface options) changes
four times during a run and ends where it was: the first ClearOn test flips it
twice, the second flips it once and the After hook puts it back. Each change is
a real `C_CVar.SetCVar`, so the client raises `CVAR_UPDATE` and another addon
that listens to it sees four updates. Nothing is drawn, no sound plays, no chat
line other than the harness's appears, and no request goes to the server: the
item and spell reads (`C_Item.GetItemInfoInstant` for the Hearthstone and for
item 0, `C_Spell.GetSpellInfo` for Auto Attack) answer from the client's own
data.

## What stays for the session

Every cache, snapshot and lazy tree a test creates is closed by its suite's
After hook, pass or fail, which also closes the private EventKit scope of each
cache that cleared on `CVAR_UPDATE`; only then is `chatBubbles` put back, so the
restore clears nothing. Queues have no `Close`; the test drops them with
whatever they held. EventKit keeps the Frame it registered `CVAR_UPDATE` on,
unregistered, for reuse, because the client never frees a Frame. CacheKit's
package-wide limits are not changed (the one `SetLimits` call is a refusal the
test checks). Nothing is written to a global or a saved variable other than
the harness's own results.

### On a client without secret values

The eight `cacheKit.secrets` tests need the client's `issecretvalue` and
`secretwrap`. `secretwrap` is the one documented way to obtain a genuine secret
out of combat without side effects: the client's own API documentation
(`FrameScriptDocumentation`, mirrored in
`packages/apiKit/metadata/retail/namespaces.json`) lists it with no
restriction, and it only converts the values handed to it. Retail 12.1 has
both. A client without them prints these eight lines instead, and the totals
line reads `30 passed, 0 failed, 8 skipped, 0 timed out (38 tests)`:

```text
MoltenCodes Test: SKIP cacheKit.secrets: the client's handling of secrets is logged: rawequal, ==, type, table keys, and CacheKit's read paths -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP cacheKit.secrets: a secret value stored with Set comes back from Get and Peek still secret and untouched -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP cacheKit.secrets: a memoised function that returns a secret hands it back still secret on the second call without running again -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP cacheKit.secrets: a secret value pushed on a queue comes back from Iterate and Pop still secret -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP cacheKit.secrets: a secret maxEntries is refused by NewLru, NewTtl, Memoize and Lazy at the calling line -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP cacheKit.secrets: a secret NewQueue capacity and a secret SetLimits maxQueueCapacity are refused at the calling line and the limits stay as they were -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP cacheKit.secrets: a snapshot read that fills a secret value fails Refresh at the fill line in CacheKitSuite.lua and keeps nothing -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP cacheKit.secrets: a secret key reaching Get raises the client's own error, as docs/API.md says, and the cache is unchanged -- the client has no issecretvalue and secretwrap; the secret path was not exercised
```

### A client without the item or spell functions

The four tests that read `C_Item.GetItemInfoInstant`, and the one that reads
`C_Spell.GetSpellInfo`, end as skipped naming the missing function (`the
client has no C_Item.GetItemInfoInstant`). Retail 12.1 has both, so a `SKIP`
there is unexpected.

## What each test proves

| Test | Proves in the real client |
|---|---|
| `Registry:Get('cacheKit', 1) is the CacheKit facade ...` | The facade the client loaded is API 1 with `NewLru`, `NewTtl`, `Memoize`, `NewSnapshot`, `Lazy`, `NewQueue`, `SetLimits`, `GetLimits` and the `UNBOUNDED` sentinel; the log gives the session's `maxQueueCapacity`. |
| `the installed CacheKit carries the revision ...` | Registry's selected revision and the facade's `REVISION` are both the committed manifest's, not an older or newer embedded copy. |
| `the client has GetTimePreciseSec ... EventKit API 1 is loaded` | The two optional facilities docs/API.md names are present, so age limits are live (without the clock nothing expires) and `ClearOn` can connect. |
| `a NewTtl entry with a 0.3-second limit is present halfway and gone ...` | On the client's own clock the entry reads back at about 0.15 s and is gone once the clock passes 0.3 s after `Set`; `Peek` reports it absent but leaves it stored, `Get` removes it and counts a miss. The log gives both measured instants. |
| `setting the key again restarts its age ...` | A second `Set` at about 0.2 s restarts the age: at 0.3 s after the first `Set` the value is still there, and it goes 0.3 s after the second. |
| `a 0.2-second negative entry answers nil and 'negative' as a hit ...` | `PutNegative` answers `nil, "negative"` through `Get` (a hit) and `Peek`, expires by its own 0.2-second limit on the real clock, and leaves an ordinary entry of the 60-second cache alone. |
| `Memoize over C_Item.GetItemInfoInstant reads the Hearthstone ...` | A memo over a real client read runs the read once; the second call returns the same table, equal to a fresh read. The log gives the icon and class the client answered. |
| `cacheable keeps item 0 ... out of the cache ...` | An answer the client has no data for reaches `cacheable` (with the key) and is returned unremembered, so the client is asked again; the same memo then remembers a real item. |
| `Memoize with a 0.3-second limit over C_Spell.GetSpellInfo ...` | A memo's `ttlSeconds` expires on the real clock: the same info table is handed back before the limit and a new one from the client after it. |
| `ClearOn('CVAR_UPDATE') empties the cache inside C_CVar.SetCVar ...` | The clear happens synchronously inside the client's `SetCVar`, on every change, keeps the statistics, and a second `ClearOn` for the event returns `false`; a cache without `ClearOn` keeps its entries. |
| `a cache closed after ClearOn stays closed and empty ...` | `Close` releases the subscription: a later change still clears an open cache on the same event, while the closed one stays closed and empty and a second `Close` returns `false`. |
| `ClearOn with an event name the client does not know ...` | The refusal is raised at this file's calling line as `CacheKit.Cache:ClearOn could not connect MOLTENCODES_TEST_NO_SUCH_EVENT: ...` with EventKit's reason (on Retail 12.1, `... is not an event this client knows`), twice in a row, and the cache still connects a real event afterwards. |
| `a Lazy tree resolves each path once, and Invalidate ...` | Resolution once per path, hit and miss counts, and `Invalidate` removing the path with its descendants and its ancestors' values but not a sibling, as docs/API.md's example says. |
| `a Lazy tree over C_Item.GetItemInfoInstant ...` | A resolver that reads the client expands a path once and keeps a `nil` answer out of the tree. |
| `a Lazy tree of maxEntries 2 forgets the least recently read path ...` | The bound evicts the least recently read expanded node and counts one eviction. |
| `on a full queue of capacity 2, dropOldest ...` | Each overflow policy returns what docs/API.md's table says. |
| `Push and Pop keep first-in first-out order ...` | Order across the ring's wrap-around, `false` as an ordinary value, `Iterate` positions from 1, `Pop` of an empty queue and `Clear`. |
| `Get hits, a Get miss, Peek and Set of a stored key ...` | After a full collection in a step of its own, 5000 cycles move `collectgarbage("count")` by at most 1 KB. |
| `a NewTtl Get hit, a negative-entry Get and PutNegative and Set ...` | The same for the age-limited hit path, a negative hit and rewriting stored keys, which reads the real clock on every write. |
| `a memoised hit on a C_Item.GetItemInfoInstant memo ...` | The same for 5000 memoised hits with a `cacheable` predicate. |
| `a Lazy tree Get hit on a three-part path ...` | The same for 5000 lazy hits. |
| `Push onto a full dropOldest queue and Pop ...` | The same for 5000 cycles of two pushes and a pop on a full ring. |
| `500 full Iterate walks over a queue of 64 values ...` | The same for 32000 iteration steps. |
| `NewLru without maxEntries ...`, `NewTtl with ttlSeconds 0 ...` | Constructor errors name this file at the calling line, as the client names it. |
| `a nil key, a closed cache's Set and a cache method called with UIParent ...` | Key, closed-cache and receiver errors at the calling line; the receiver check refuses a real Frame table. |
| `PutNegative on a NewLru cache ...` | The refusal on a cache without an age limit, at the calling line. |
| `a memoised function called with a table key ...` | The key refusal of a memoised function reaches the caller of the memoised function, and `fn` never runs. |
| `NewQueue with an unknown overflow policy or a capacity above maxQueueCapacity ...` | Both refusals at the calling line; the capacity message names the session's limit. |
| `a Lazy path part that is a table, a nil queue value and Get on a closed tree ...` | Path, queue value and closed-tree errors at the calling line. |
| `the client's handling of secrets is logged ...` | A diagnostic: the log records what the client does with a secret made by `secretwrap(42)`. On Retail 12.1.0 b69933 (2026-09-24) it read: `type(secret)` is `number`; `rawequal(secret, secret)` raises `attempt to compare a secret number value (execution tainted by '<addon>')`; `rawequal(secret, {})`, `rawequal({}, secret)`, `secret == nil` and `type(secret) == 'nil'` return `false` without raising; reading `plainTable[secret]` raises `attempted to index a table that cannot be indexed with secret keys`; `select('#', secret)` works; and CacheKit's `Set`, `Get`, `Peek`, queue `Push` and `Pop`, and both memoised calls hand the value back still secret. The test itself only checks that the value is still secret afterwards; send the log whenever a line differs. |
| `a secret value stored with Set comes back from Get and Peek ...` | A genuine secret value is stored and handed back by `Get` and `Peek` still secret and of its own type. Identity cannot be checked, because `rawequal` of a secret with itself raises; the negative-entry check compares the value with CacheKit's own marker table, which the client allows for a secret of another type. |
| `a memoised function that returns a secret ...` | A secret result is remembered and handed back untouched without running `fn` again. |
| `a secret value pushed on a queue ...` | A queue never compares its values: `Iterate` and `Pop` hand the secret back still secret and of its own type. |
| `a secret maxEntries is refused ...` | All four constructors refuse a secret `maxEntries` at the calling line, before comparing it with anything. |
| `a secret NewQueue capacity and a secret SetLimits maxQueueCapacity ...` | Both refusals at the calling line, with the messages any other invalid value gets, and `GetLimits` unchanged. |
| `a snapshot read that fills a secret value ...` | `fill` asks the client's `issecretvalue`, refuses at the reader's `fill` line in this file, and `Refresh` re-raises that position unchanged and keeps nothing from the failed read. |
| `a secret key reaching Get raises the client's own error ...` | What docs/API.md says of cache keys: CacheKit does not probe a key, and the client itself refuses a secret used as a table key, even to read (measured on Retail 12.1.0 b69933: `attempted to index a table that cannot be indexed with secret keys`). The log holds the client's message. The Busted fixture cannot show this: its stand-in secret is a plain table. |

## What counts as unexpected

- Any `FAIL` or `TIMEOUT` line, a `SKIP` line on Retail 12.1, or a totals
  line other than `38 passed, 0 failed, 0 skipped, 0 timed out (38 tests)`.
- No login line, or `Expected.lua is missing`: the harness or the installer
  did not run as intended.
- A Lua error window or a BugSack entry naming `MoltenCodes`,
  `MoltenCodesTest` or `MoltenCodesTest_CacheKit`. Every error the suite
  provokes is caught by the test itself.
- The chat bubbles option left changed after the run.
- An age-limit test failing with "the client stalled; run again": a frame took
  longer than the whole age limit, so the "still present" reading could not be
  taken in time. Run again; if it repeats, say what the client was doing.
- A ClearOn test failing on the entry count right after `SetCVar`: the client
  raised `CVAR_UPDATE` later than inside `SetCVar`, which the EventKit client
  run showed it does not.
- An allocation test failing: its log gives the measured delta. Say which
  other addons are enabled.
- `the installed CacheKit carries the revision ...` failing: another enabled
  addon embeds a different CacheKit copy.
- `a secret key reaching Get raises the client's own error ...` failing on
  `expected boolean true to be boolean false`: the client accepted a secret as
  a table key for a read, and docs/API.md's *Secret values* section needs
  correcting. Send the log line.
- A `cacheKit.secrets` test failing with "secretwrap raised" or "secretwrap
  returned a value issecretvalue does not report as secret": the client's
  secret functions behave differently from their documentation.

## What to send back

1. The chat lines above as they appeared (a screenshot, or a copy of the chat
   log), including any line that differs.
2. After `/reload` or a logout, the file
   `/Applications/World of Warcraft/_retail_/WTF/Account/<ACCOUNT>/SavedVariables/MoltenCodesTest.lua`.
   It holds the full report, each test's logs (the measured instants of every
   age-limit test in milliseconds, the item and spell data the client
   answered, the entry count right after `SetCVar`, the client's own error
   messages with their paths, the six measured memory deltas) and the client
   facts. Lua shortens a long file path from the left, so a logged message may
   start with `...`; the tests compare only the `CacheKitSuite.lua:<line>`
   part.
3. The text of any Lua error, with `/console scriptErrors 1` turned on.
4. The list of other enabled addons, when a test failed.
