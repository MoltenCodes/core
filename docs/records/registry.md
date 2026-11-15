# registry records

Moved from `docs/ROADMAP.md` (Package O — memory, performance and ease of use (decisions 18 and 19)).

## registry cheaper lookups

**registry cheaper lookups** — an internal change to facade `Registry`

1. Package `registry`, facade `Registry`, API generation 2 (unchanged),
   version 0.6.11, implementation revision 16 (from 0.6.10, revision 15).
   Patch. The file stays within its 1000-line budget.
2. Purpose: bring `Get`, `Find` and `Register` lookups closer to LibStub's,
   following the runtime performance diagnosis of 2026-11-15 (registry).
   - The secret-probe rule: `issecretvalue` resolved once at load, looked
     up per call only when it was absent at load, in `isSecret`
     (`Registry.lua:74`) and `lookUp` (`:250`).
   - Owner decision needed: plain indexing on the hit path. `lookUp` reads
     the package bucket, the entry and its two fields with `rawget` and
     checks each with `type`. Indexing them plainly is where the gain is
     (item 6), but `docs/API.md` ("Lookup cost") promises that a hit "reads
     the state with raw access". Plain indexing keeps every shape check
     (the corruption checks stay, and `Corruption_spec` and `FastPath_spec`
     pass). It drops that promise, though: a metatable that foreign code
     puts on the shared state could then answer a missing bucket or field.
     No form of plain indexing keeps the promise for less: a `getmetatable`
     test on the three tables costs what the `rawget`s cost. Unless the
     owner drops the sentence, the hit keeps raw reads and takes only the
     probe rule.
   - Decision 19b: none applies. The secret checks in Registry guard
     arguments before they are compared or used as keys, so the error is
     raised at the caller's line; the client's own refusal would raise
     inside Registry. The sealed facade's `__newindex` (`:712`) asks about
     the key it describes. Whether the client refuses a secret key on
     assignment before `__newindex` runs has not been measured, so that
     check stays.
3. Dependencies: none (Registry is the root).
4. Surface: unchanged. With plain indexing, the "Lookup cost" paragraph
   loses "reads the state with raw access" on the hit. The bootstrap and
   facade checks keep raw access in either case.
5. Ownership: unchanged. The load-time probe is file-local to each
   embedded copy. An in-place upgrade from revision 15 keeps every entry.
6. Performance and memory, host bench `libraryRegistry` workload,
   MoltenCodes ÷ LibStub in the same run (two runs on 2026-11-15, the
   unmodified file against each variant):

   | Case | Before | Probe rule only | Probe rule and plain indexing |
   |---|---:|---:|---:|
   | lookup | 3.54× | 3.35-3.38× | 2.53-2.60× |
   | silent-miss | 5.00-5.05× | 4.84-4.97× | 4.02-4.09× |
   | stale-copy | 1.77-1.83× | 1.74× | 1.44-1.45× |
   | upgrade | 1.18-1.20× | 1.20× | 0.96-1.01× |
   | new-library | 1.91-2.12× | 1.93-2.08× | 1.56-1.81× |

   The target "Ace3/LibStub level" is not reached by either form: a hit
   still runs the probe and the shape check, and a miss runs the name
   pattern. No memory change. Registry lookups happen mostly at load. The
   hot-path cost is the call-time lookups other Kits make, which those
   Kits should resolve once.
7. Tests: the probe rule (present at load, installed after load); a hit
   with a malformed entry still raises the corruption error at the caller;
   a secret name or API still refused before use as a key. With plain
   indexing: the rewritten "Lookup cost" claim, and a spec that a bucket
   carrying a foreign metatable is refused, not read through. In-place
   upgrade from revision 15. Line budget: the file stays at or under 1000
   lines. Client suite (`tests/client/MoltenCodesTest_Registry/`, never run
   here): unchanged.
8. Docs: `docs/API.md` ("Lookup cost"), `CHANGELOG.md` 0.6.11,
   `tests/README.md`.
9. Status: implemented 2026-11-15 under core decisions 18 and 19, 0.6.11,
   revision 16, plain indexing on the owner's decision (Registry's state
   carries no metatable; the docs/API.md "Lookup cost" sentence replaced), 2
   specs (143), 999 lines.

