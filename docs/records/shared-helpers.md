# Shared helper records

Records for binding the helpers Kits copy to their single source in
`tooling/shared/lua/` (see `docs/TOOLING.md`), written before the code.

## Shared helper blocks in 27 Kits

Binding the hand-written copies to `tooling/shared/lua/`: a change to 25 facades, with one record per package below.

Scope: clientKit, localeKit, hookKit, cacheKit, profileKit, readinessKit,
interopKit, mediaKit, brokerKit, logKit, compatKit, bridgeKit, apiKit,
panelKit, menuKit, launcherKit, tooltipKit, barKit, dialogKit, toastKit,
bindingKit, glowKit, editModeKit, rangeKit, unitFrameKit, addonKit, testKit.
`python3 -m tooling.shared.sync --list` names 78 hand-written copies in them
(measured 2026-11-16): `isSecret` 24, `validateFacade` 21, `reportError` 17,
`describeKey` 8, `limits` 8. All 78 are "compare"; none is "identical".
clientKit and localeKit have no listed copy. The record of the mechanism is
`docs/records/tooling.md`, "Shared helper blocks and their gate".

### Common facts every record below refers to

### The changes, once

- **C1 `isSecret`: the probe rule.** The shared block reads `issecretvalue`
  once at load and keeps it when it is a function; only when it was absent at
  load does each check read the global again. The answer is `probe(value) ==
  true`. Three earlier forms meet it:
  - *Per-call* (`local probe = readGlobal("issecretvalue")` on every check;
    18 Kits, plus interopKit through its `globals` alias): on a host that had
    the probe at load, a probe **replaced** after load is no longer honoured;
    the one from load keeps answering. Every client flavour defines
    `issecretvalue` before any addon runs (the header of
    `tooling/shared/lua/isSecret.lua`), so no client sees a difference; a test host that swaps the global
    after loading the Kit does. One function call and one global-table read
    fewer per check: 78 ns → 28 ns per check on host Lua 5.1.5 (5 000 000
    checks, a probe present at load).
  - *Load-only* (cacheKit, readinessKit): gains the late read, so a probe
    installed after load on a host that had none is honoured. No client sees
    a difference.
  - *Already on the rule* (hookKit, bridgeKit through `readSecretProbe`):
    hookKit's is equivalent for every input. bridgeKit's never asked the probe
    about `nil` (`type(value) ~= "nil"` guard); the block does, and the real
    `issecretvalue(nil)` answers `false`, so only a stub that calls `nil`
    secret can tell.
  - readinessKit's also answered `probe(value) and true or false`, so a stub
    answering a truthy non-boolean counted as secret; the block counts only
    `true`. `issecretvalue` answers a boolean.
  - A Kit whose copy is named `isSecretValue` (bridgeKit, cacheKit,
    readinessKit) renames its call sites to `isSecret`.
- **C2 `reportError`: a raising error handler falls back to `print`.** The
  shared block calls the handler through `pcall` and prints the failure when
  the handler is missing or raises. The 17 unprotected copies called it
  directly, so an error-display addon whose handler raises turned one reported
  failure into a second, raised into whoever called the Kit: the hooked
  function's caller (hookKit's `isolatedCall`, whose own comment says a
  handler failure must not break the host's call), a frame script, a
  `pcall`-isolated consumer callback (barKit `onFinished`, menuKit menu
  builders, readinessKit staged calls, testKit `OnFinished`). This is a drift
  bug the block fixes; each Kit gets a failing-first spec. compatKit's and
  logKit's copies already had the shared form: no change.
- **C3 `validateFacade`: the shared form.** 17 copies (addonKit, barKit,
  bindingKit, bridgeKit, brokerKit, compatKit, editModeKit, glowKit,
  launcherKit, logKit, menuKit, panelKit, profileKit, rangeKit, toastKit,
  tooltipKit, unitFrameKit) raise the same text at the same level; the block
  only builds the `; use <label>(...)` hint in a local first. Equivalent for
  every input. hookKit's `rawequal(receiver, HookKit)` is equivalent as well
  (see the hookKit record). Changing ones: dialogKit (drops its `isSecret`
  call), mediaKit (gains the `type` test), cacheKit and testKit (gain the
  `type` test and the hint, a visible text change).
- **C4 `describeKey`: `<secret>` for a secret key.** The 4 copies in cacheKit,
  compatKit, profileKit, readinessKit and the 2 in logKit, mediaKit named
  every key by type and would have put a secret string key into the message.
  In every one of these Kits the key either comes from `next` over a caller's
  table (a secret cannot be stored as a key; storing one raises) or is
  refused as secret before `describeKey` runs, so the `<secret>` branch is
  unreachable on a client: no user-visible change. apiKit's copy already
  answered `<secret>`; it now asks through `isSecret` (C1). testKit's
  `describeKey` is a different function (a path segment, `.name` or `[1]`)
  and is renamed, not converted.
- **C5 `limits`: not converted in this change (decision D1).**

### Resident cost (host Lua 5.1.5, 64-bit, debug info kept)

Each helper loaded alone with everything it shares held by the baseline and
every constant interned beforehand, so the figure is what the helper itself
keeps resident (closure, prototype, line info, upvalue boxes); runs vary by
about 15 bytes.

| Helper | Hand-written | Shared block | Change |
|---|---|---|---|
| `isSecret`, per-call form | 448 B | 537 B | about +90 B |
| `isSecret`, load-only form | 382 B | 537 B | about +155 B |
| `reportError`, unprotected form | 545 B | 544 B | 0 |
| `validateFacade`, one-concatenation form | 477 B | 547 B | about +70 B (the `hint` local) |
| `describeKey`, type-named form | 466 B | 604 B | about +140 B (the `isSecret` call) |
| `readGlobal` removed where it has no other caller | 285 B | — | −285 B |
| `limits`, brokerKit (2 limits, no ceilings) | 3 435 B | 4 723 B | +1 288 B |
| `limits`, cacheKit (1 limit) | 4 313 B | 6 342 B | +2 029 B |
| `limits`, bridgeKit (13 limits), describeKey included | 4 349 B | 6 924 B | +2 575 B |

A typical user-interface Kit (C1 + C2 + C3) grows by about 160 bytes and
saves about 50 ns on every secret check it makes; addonKit shrinks (its
`readGlobal` has no other caller). No converted Kit gains a main-chunk local;
hookKit and readinessKit lose one (the load-time probe local), addonKit one
(`readGlobal`). The `lua_limits` ratchet only moves down.

### Decisions this record asks for

- **D1 (`limits`): opt the 8 `validateLimitUpdate` copies out for now
  (recommended).** Revision 1 of `tooling/shared/lua/limits.lua` does not fit
  these Kits without cost or visible change:
  1. *Memory.* The block is 1.3 KB to 2.6 KB more resident than each Kit's own
     loop (table above): it builds `rulesByName`, `names` and the `accepted`
     string at load and keeps four closures, against one function per Kit, and
     requires a `describeKey` block that brokerKit and bridgeKit do not carry.
     A leaner variant measured in the same harness (a linear scan of
     `LIMIT_RULES` on the cold `SetLimits` path, no precomputed tables) still
     costs +1.8 KB on bridgeKit. Against the memory-first rule this is a
     regression with no runtime gain.
  2. *Ceilings.* The block refuses a value above `rule.ceiling`, a required
     field. brokerKit (`maxObjects`, `maxAttributes`), compatKit (`maxShims`,
     `maxProviders`, `maxProviderKinds`), logKit (`maxSinks`,
     `maxMessageLength`, `maxLoggers`), mediaKit (`maxConsumers`), profileKit
     (`maxSections`) and testKit (six limits) accept any finite positive
     integer or `UNBOUNDED` today. Converting means choosing ceilings, a new
     refusal for callers.
  3. *Messages.* Every Kit's refusals change text: the unknown-key message
     gains `; it accepts <names>`, a secret value is reported as secret where
     cacheKit and profileKit folded it into the range message, a range
     refusal loses `or <Facade>.UNBOUNDED`, and bridgeKit's `has no limit
     named <key>` and `cannot be BridgeKit.UNBOUNDED because <reason>; use
     <range>` take the shared wording. A minor version each.
  4. *Locals.* bridgeKit (175 main-chunk locals) gains three
     (`describeKey`, `applyLimitUpdate`, `copyLimits`); cacheKit (166) two.

  So `tooling/shared/pins.json` gains `optOuts` for `limits` in bridgeKit,
  brokerKit, cacheKit, compatKit, logKit, mediaKit, profileKit and testKit,
  reason: "The shared limits block measured 1.3 to 2.6 KB more resident than
  this Kit's own loop and changes its refusals; kept until a leaner revision
  of the block." The alternative, converting now, is a minor version per Kit
  with the ceilings chosen per limit; a leaner `limits` revision 2 (optional
  ceiling, the `or <Facade>.UNBOUNDED` hint kept, the accepted names built
  only when raising) is the tooling's change, not these Kits'.
- **D2 (testKit `isSecret`): opt out.** See the testKit record.
- **D3 (hookKit `validateFacade`): drop the existing opt-out and convert.**
  See the hookKit record.
- **D4 (profileKit `describeKey`): opt out with its `limits`.** See the
  profileKit record.
- **D5 (localeKit `report`): leave it.** It is a `reportError` copy under
  another name (unprotected, C2's drift), so `--list` does not see it.
  Converting it is outside the listed copies; it is noted here so the choice
  is explicit.

### Versions

A revision bump wherever any converted copy behaves differently on some host
(C1 to C4), so an older embedded copy is replaced in place and the faster
check reaches every addon (an equal revision never replaces the loaded copy).
Patch version where no refusal text changes; minor where one does (cacheKit,
testKit). Only profileKit is equivalent for every input: patch version, no
revision bump. Every revision bump gets an in-place upgrade spec from the
current revision, with a byte copy of the current file as the fixture.

### Specs and test environments

The probe rule changes when a test probe takes effect: a spec that installs
`issecretvalue` after the Kit loaded is honoured only when no probe existed
at load. Package test environments that install a probe before load and
replace it later move to one probe whose answers the test controls (the
`NewSecret` set pattern most of them already use). Which specs do so is
found by running each Kit's specs after its conversion.

---

**addonKit: shared `isSecret`, `reportError`, `validateFacade`** — a change to facade `AddonKit`

1. Package `addonKit`, facade `AddonKit`, API 1, 0.2.0 → 0.2.1, implementation
   revision 2 → 3. Core `src/AddonKit.lua` only; parts unchanged.
2. Copies: `isSecret` (line 467, per-call), `reportError` (475, unprotected),
   `validateFacade` (1065, shared form). C1, C2, C3.
3. Dependencies unchanged.
4. For users: a raising host error handler no longer raises out of the
   failure report at line 1160; the failure is printed. A probe replaced after
   load is not honoured (C1). No refusal text changes.
5. pins.json: none.
6. Memory and locals: `readGlobal` (304) loses its last caller and is
   removed: −1 main-chunk local (77 → 76), about −285 B; the blocks add about
   +160 B. Net about −125 B.
7. Specs: raising error handler → printed, caller unaffected (failing
   first); probe from load kept after the global is replaced; upgrade from
   revision 2. KitConformance opt-in (`tests/Conformance_spec.lua`).
8. Docs: CHANGELOG `## 0.2.1`, `docs/API.md` Error behaviour (the handler
   fallback) and the skeleton fixes the validator asks for (`## Cost` →
   `## Performance`, a `## Secret values` section), tests/README.
9. Status: recorded 2026-11-16; code follows.

**apiKit: shared `isSecret`, `describeKey`** — a change to facade `ApiKit`

1. Package `apiKit`, facade `ApiKit`, API 1, 0.2.3 → 0.2.4, revision 6 → 7.
2. Copies: `describeKey` (282, already `<secret>`, its own per-call probe
   read) and `isSecret` (417, per-call). The `isSecret` block moves above
   `describeKey`, which the block requires earlier in the file. C1.
3. Dependencies unchanged.
4. For users: no text change; `describeKey` output is the same. C1's probe
   rule applies to both.
5. pins.json: none.
6. Locals 42 unchanged; `readGlobal` keeps three callers. About +90 B
   (`isSecret`); `describeKey` now calls `isSecret` instead of reading the
   global, about equal.
7. Specs: the probe rule; `SUPPORTED_FLAVORS` write with a secret key still
   names `<secret>`; upgrade from revision 6. KitConformance opt-in.
8. Docs: CHANGELOG `## 0.2.4`; API.md skeleton (`## Errors` → `## Error
   behaviour`, `## Embedded identity and upgrades` → `## Embedded copies and
   upgrades`, `## Loading` and `## Performance` sections, the section order).
9. Status: recorded 2026-11-16; code follows.

**barKit, bindingKit, editModeKit, launcherKit, menuKit, panelKit, rangeKit, toastKit, tooltipKit, unitFrameKit: shared `isSecret`, `reportError`, `validateFacade`** — one record per facade, identical in shape

Each of these ten Kits carries the same three copies with the same bodies
(per-call `isSecret`, unprotected `reportError`, shared-form
`validateFacade`), so the nine points are the same but for the numbers:

| Package | Lines (isSecret / reportError / validateFacade) | reportError callers | Version | Revision | Main locals |
|---|---|---|---|---|---|
| barKit | 313 / 321 / 354 | 1 (`onFinished` under `pcall`) | 0.1.1 → 0.1.2 | 2 → 3 | 88, unchanged |
| bindingKit | 288 / 296 / 339 | 1 | 0.1.1 → 0.1.2 | 2 → 3 | 70, unchanged |
| editModeKit | 296 / 304 / 365 | 3 | 0.1.1 → 0.1.2 | 2 → 3 | 67, unchanged |
| launcherKit | 372 / 380 / 413 | 4 | 0.1.1 → 0.1.2 | 2 → 3 | 91, unchanged |
| menuKit | 346 / 355 / 402 | 5 (menu builders, callbacks) | 0.1.1 → 0.1.2 | 2 → 3 | 64, unchanged |
| panelKit | 346 / 355 / 394 | 4 | 0.1.2 → 0.1.3 | 2 → 3 | 64, unchanged |
| rangeKit | 358 / 387 / 474 | 1 | 0.1.1 → 0.1.2 | 2 → 3 | 81, unchanged |
| toastKit | 339 / 347 / 370 | 1 | 0.1.1 → 0.1.2 | 1 → 2 | 77, unchanged |
| tooltipKit | 372 / 380 / 413 | 1 | 0.1.1 → 0.1.2 | 2 → 3 | 101, unchanged |
| unitFrameKit | 418 / 426 / 486 | 3 | 0.1.1 → 0.1.2 | 2 → 3 | 97, unchanged |

1. Package and facade as named, API 1, version and revision as tabled.
2. C1, C2, C3.
3. Dependencies unchanged.
4. For users: a raising host error handler no longer raises into the frame
   script or callback path that reported a consumer's failure; the failure is
   printed. Secret checks follow the probe rule. No refusal text changes.
5. pins.json: none.
6. Each keeps `readGlobal` (other callers remain). About +160 B resident per
   Kit; about −50 ns per secret check (tooltipKit has 30 call sites,
   unitFrameKit 24).
7. Specs per Kit: raising handler → printed, caller unaffected (failing
   first); probe from load kept after the global is replaced; upgrade from
   the current revision. KitConformance opt-in (`limits`, `receivers`,
   `arguments`, `upgrade`).
8. Docs: CHANGELOG patch heading, API.md Error behaviour (the handler
   fallback), tests/README.
9. Status: recorded 2026-11-16; code follows.

**bridgeKit: shared `isSecret`, `validateFacade`; `limits` opted out** — a change to facade `BridgeKit`

1. Package `bridgeKit`, facade `BridgeKit`, API 1, 0.6.0 → 0.6.1, revision
   8 → 9.
2. Copies: `validateFacade` (570, shared form, C3), `limits` (582, D1), and
   `isSecretValue` (1460), which reads `readSecretProbe()` (already the probe
   rule) and never asks about `nil`. Converted to the `isSecret` block; 19
   call sites renamed. `loadedSecretProbe` and `readSecretProbe` stay: ten
   other sites read the probe once and test many values with it (a
   serializer walk, option tables), which a per-value `isSecret` call would
   slow.
3. Dependencies unchanged.
4. For users: none on a client (`issecretvalue(nil)` is `false`). Limits
   refusals unchanged (D1).
5. pins.json: `optOuts` `limits` (D1; also the three locals bridgeKit's 175
   cannot spare comfortably).
6. Locals 175 unchanged (rename). Resident about +160 B: the `isSecret`
   block keeps its own load-time probe upvalue beside `loadedSecretProbe`,
   and `validateFacade` its hint local.
7. Specs: a nil argument with the test probe still takes the nil path; the
   probe from load kept after the global is replaced; upgrade from revision
   8. KitConformance opt-in.
8. Docs: CHANGELOG `## 0.6.1`; API.md skeleton (`## Cost` → `## Performance`,
   `## Upgrades` → `## Embedded copies and upgrades`, `## Error behaviour`,
   order).
9. Status: recorded 2026-11-16; code follows.

**brokerKit: shared `isSecret`, `validateFacade`; `limits` opted out** — a change to facade `BrokerKit`

1. Package `brokerKit`, facade `BrokerKit`, API 1, 0.1.6 → 0.1.7, revision
   3 → 4.
2. Copies: `isSecret` (480, per-call, C1), `validateFacade` (497, C3),
   `limits` (614, D1). `describeLimitKey` and `SECRET_PLACEHOLDER` stay with
   the hand-written limits loop.
3. Dependencies unchanged.
4. For users: the probe rule only.
5. pins.json: `optOuts` `limits` (D1: +1.3 KB measured, no ceilings on
   `maxObjects` and `maxAttributes`).
6. Locals 104 unchanged; `readGlobal` keeps a caller. About +160 B.
7. Specs: probe rule; upgrade from revision 3. KitConformance opt-in.
8. Docs: CHANGELOG `## 0.1.7`, tests/README.
9. Status: recorded 2026-11-16; code follows.

**cacheKit: shared `isSecret`, `validateFacade`, `describeKey`; `limits` opted out** — a change to facade `CacheKit`

1. Package `cacheKit`, facade `CacheKit`, API 1, 0.2.9 → 0.3.0 (refusal
   text), revision 7 → 8.
2. Copies: `isSecretValue` (320, load-only: gains the late read, C1; renamed
   at 6 call sites), `validateFacade` (595: gains the `type` test and the
   hint, C3), `describeKey` (664, C4; its callers are the unknown-limit
   refusal and the snapshot's duplicate-key refusal, whose key is refused as
   secret first at 1587), `limits` (704, D1). `nativeIsSecretValue` stays for
   the snapshot fill (1586), a hot path that hoists the probe.
3. Dependencies unchanged.
4. For users: `CacheKit:SetLimits` and `GetLimits` called with a dot raise
   `<label> must be called on the CacheKit facade; use <label>(...)` (the
   hint is new). A probe installed after load on a host without one at load
   is honoured.
5. pins.json: `optOuts` `limits` (D1: +2.0 KB measured, two more locals at
   166).
6. Locals 166 unchanged. About +155 B (`isSecret`), +70 B, +140 B.
7. Specs: the facade message with the hint (failing first); a probe
   installed after load is honoured by the argument checks (failing first);
   upgrade from revision 7. KitConformance opt-in.
8. Docs: CHANGELOG `## 0.3.0`; API.md Error behaviour (the message) and the
   section order the validator asks for.
9. Status: recorded 2026-11-16; code follows.

**compatKit: shared `isSecret`, `reportError`, `validateFacade`, `describeKey`; `limits` opted out** — a change to facade `CompatKit`

1. Package `compatKit`, facade `CompatKit`, API 1, 0.1.7 → 0.1.8, revision
   4 → 5.
2. Copies: `isSecret` (520, per-call, C1), `reportError` (533, already the
   shared form: equivalent), `validateFacade` (612, C3), `describeKey` (1475;
   its one caller refuses a secret key first: equivalent), `limits` (1490,
   D1).
3. Dependencies unchanged.
4. For users: the probe rule only.
5. pins.json: `optOuts` `limits` (D1: no ceilings on its three limits).
6. Locals 113 unchanged. About +300 B.
7. Specs: probe rule; upgrade from revision 4. KitConformance opt-in.
8. Docs: CHANGELOG `## 0.1.8`; API.md skeleton (`## Errors`, `## Cost`
   renames).
9. Status: recorded 2026-11-16; code follows.

**dialogKit: shared `isSecret`, `reportError`, `validateFacade`** — a change to facade `DialogKit`

1. Package `dialogKit`, facade `DialogKit`, API 1, 0.1.1 → 0.1.2, revision
   2 → 3.
2. Copies: `isSecret` (317, per-call, C1), `reportError` (325, C2),
   `validateFacade` (358): it asked `isSecret(receiver)` before the `type`
   test; the block drops the call (a secret is never a table), so every
   facade method call makes one probe call fewer.
3. Dependencies unchanged.
4. For users: C2's fallback; the probe rule. No refusal text changes.
5. pins.json: none.
6. Locals 71 unchanged. About +160 B; about −80 ns per facade method call.
7. Specs: raising handler (failing first); probe rule; a dot call with a
   secret receiver still raises the facade message; upgrade from revision 2.
   KitConformance opt-in.
8. Docs: CHANGELOG `## 0.1.2`, API.md Error behaviour.
9. Status: recorded 2026-11-16; code follows.

**glowKit: shared `isSecret`, `validateFacade`** — a change to facade `GlowKit`

1. Package `glowKit`, facade `GlowKit`, API 1, 0.1.1 → 0.1.2, revision 1 →
   2.
2. Copies: `isSecret` (283, per-call, C1), `validateFacade` (309, C3). No
   `reportError` copy.
3. Dependencies unchanged.
4. For users: the probe rule only.
5. pins.json: none.
6. Locals 78 unchanged; `readGlobal` keeps two callers. About +160 B.
7. Specs: probe rule; upgrade from revision 1. KitConformance opt-in (its
   header already uses glowKit as the example).
8. Docs: CHANGELOG `## 0.1.2`, tests/README.
9. Status: recorded 2026-11-16; code follows.

**hookKit: shared `reportError`, `isSecret`, `validateFacade`; the opt-out goes** — a change to facade `HookKit`

1. Package `hookKit`, facade `HookKit`, API 1, 0.4.0 → 0.4.1, revision 8 →
   9.
2. Copies: `reportError` (452, unprotected, C2), `isSecret` (500: the probe
   rule through `nativeIsSecretValue` and `readHostFunction`, equivalent for
   every input), and `validateFacade` (1995), which `pins.json` opts out
   because it compares with `rawequal`. That opt-out has no remaining reason:
   Lua 5.1 calls `__eq` for `receiver ~= HookKit` only when both operands'
   metatables carry the same `__eq` (`get_compTM` in `lvm.c`), and the
   facade's only metatable is Registry's seal, which has none
   (`packages/registry/src/Registry.lua`, `applySeal`). Checked on host Lua
   5.1.5: a receiver with an `__eq` metamethod compared with a sealed facade
   does not run it. The shared form also tests `type` first, so a secret is
   never compared. Equivalent for every input.
3. Dependencies unchanged.
4. For users: a raising host error handler no longer raises out of a
   post-hook or pre-hook call into the hooked function's caller (C2): the
   comment on `isolatedCall` already promises the host's call is not broken.
5. pins.json: remove the `hookKit` `validateFacade` entry.
6. Locals 119 → 118 (`nativeIsSecretValue` goes; `readHostFunction` stays for
   the other host functions). About +70 B (`validateFacade`'s hint local;
   `isSecret` and `reportError` are the same size either way).
7. Specs: a raising handler during a hooked call: the call completes and the
   failure is printed (failing first); a dot call on the facade with a
   receiver carrying `__eq` still raises; upgrade from revision 8, including
   a closure revision 8 installed reporting through the new `reportError`.
   KitConformance opt-in.
8. Docs: CHANGELOG `## 0.4.1`; API.md Error behaviour, and the skeleton the
   validator asks for (`## Cost`, `## Upgrades` renames, `## Secret values`,
   `## Error behaviour`, the taint-model section placed after `## Loading`).
9. Status: recorded 2026-11-16; code follows.

**interopKit: shared `isSecret`** — a change to facade `InteropKit`

1. Package `interopKit`, facade `InteropKit`, API 1, 0.1.3 → 0.1.4,
   revision 3 → 4.
2. Copy: `isSecret` (229, per-call through the `globals` alias, C1). The
   inline probe read at 558 is not a listed copy and stays.
3. Dependencies unchanged.
4. For users: the probe rule only.
5. pins.json: none.
6. Locals 48 unchanged. About +90 B.
7. Specs: probe rule (its `InstallSecretProbe` installs after load: the test
   environment installs before load or keeps one probe); upgrade from
   revision 3. KitConformance opt-in.
8. Docs: CHANGELOG `## 0.1.4`; API.md skeleton (renames, `## Loading`,
   `## Performance`, order).
9. Status: recorded 2026-11-16; code follows.

**logKit: shared `isSecret`, `reportError`, `validateFacade`, `describeKey`; `limits` opted out** — a change to facade `LogKit`

1. Package `logKit`, facade `LogKit`, API 1, 0.2.2 → 0.2.3, revision 5 → 6.
2. Copies: `isSecret` (313, per-call, C1), `reportError` (324, shared form:
   equivalent), `validateFacade` (645, C3), `describeKey` (1224; its caller
   refuses a secret key first: equivalent), `limits` (1240, D1: no ceilings on
   three limits, the SignalKit cross-check).
3. Dependencies unchanged.
4. For users: the probe rule only.
5. pins.json: `optOuts` `limits`.
6. Locals 138 unchanged. About +300 B.
7. Specs: probe rule; upgrade from revision 5. KitConformance opt-in.
8. Docs: CHANGELOG `## 0.2.3`; API.md skeleton (`## Errors`, `## Cost`
   renames, `## Secret values`).
9. Status: recorded 2026-11-16; code follows.

**mediaKit: shared `isSecret`, `describeKey`, `validateFacade`; `limits` opted out** — a change to facade `MediaKit`

1. Package `mediaKit`, facade `MediaKit`, API 1, 0.1.6 → 0.1.7, revision 5 →
   6.
2. Copies: `isSecret` (544, per-call, C1), `describeKey` (657; its caller
   refuses a secret key first: equivalent), `validateFacade` (1285: compared
   `receiver ~= MediaKit` without the `type` test; gains it), `limits` (1317,
   D1: `maxConsumers` has no ceiling).
3. Dependencies unchanged.
4. For users: a dot call whose receiver is a secret raises the facade
   message at the caller instead of whatever comparing a secret raises inside
   MediaKit. The probe rule. No text changes.
5. pins.json: `optOuts` `limits`.
6. Locals 119 unchanged. About +300 B.
7. Specs: probe rule; upgrade from revision 5. The secret-receiver case
   cannot fail first on the host (the test environment's secrets are tables,
   which compare without raising); it is asserted to raise the facade message.
   KitConformance opt-in.
8. Docs: CHANGELOG `## 0.1.7`, tests/README.
9. Status: recorded 2026-11-16; code follows.

**readinessKit: shared `isSecret`, `reportError`, `describeKey`** — a change to facade `ReadinessKit`

1. Package `readinessKit`, facade `ReadinessKit`, API 1, 0.1.8 → 0.1.9,
   revision 5 → 6.
2. Copies: `isSecretValue` (220, load-only and `and true or false`: gains
   the late read and the strict boolean, C1; 4 call sites renamed),
   `reportError` (239, unprotected, C2: five callers report probe, staged
   call and timer-cancel failures), `describeKey` (456; option-table keys from
   `next`: equivalent).
3. Dependencies unchanged.
4. For users: a raising host error handler no longer raises out of a gate's
   probe or a queued callback; the failure is printed.
5. pins.json: none.
6. Locals 107 → 106 (`nativeIsSecretValue` goes). About +300 B.
7. Specs: raising handler (failing first); a probe installed after load is
   honoured (failing first); a probe answering a truthy non-boolean is not
   secret (failing first); upgrade from revision 5. KitConformance opt-in
   (no `SetLimits`: the `limits` group stays pending).
8. Docs: CHANGELOG `## 0.1.9`; API.md `## Secret values` section.
9. Status: recorded 2026-11-16; code follows.

**testKit: shared `reportError`, `validateFacade`; `isSecret` and `limits` opted out; `describeKey` renamed** — a change to facade `TestKit`

1. Package `testKit`, facade `TestKit`, API 1, 0.1.9 → 0.2.0 (refusal text),
   revision 5 → 6.
2. Copies:
   - `isSecret` (323): reads `issecretvalue` through `readHostFunction` on
     every call **by design**: the file documents that the host probes are
     read late so a test can replace one with `ctx:Replace`. The shared
     block keeps the probe from load, which would ignore such a replacement
     on any client. **Opt out (D2).**
   - `reportError` (344, unprotected, C2: the `OnFinished` callbacks).
   - `validateFacade` (683, `value ~= TestKit` without hint): gains the
     `type` test and the hint.
   - `describeKey` (920) formats a path segment for `ToEqual` messages
     (`.name`, `["two words"]`, `[1]`); it is not the shared helper. Renamed
     `describePathSegment`, which takes it off the list without an opt-out.
   - `limits` (2299): requires the `isSecret` block, which D2 keeps out, and
     six limits without ceilings. **Opt out (D1).**
3. Dependencies unchanged.
4. For users: a dot call on the methods that use `validateFacade` raises
   `<label> must be called on the TestKit facade; use <label>(...)`. A raising
   error handler during `OnFinished` reporting no longer raises out of the
   run.
5. pins.json: `optOuts` `isSecret`, reason "TestKit reads the host probes at
   call time so a test can replace `issecretvalue` with `ctx:Replace`; the
   shared probe is kept from load.", and `limits` (D1 and the missing
   `isSecret` block).
6. Locals 173 unchanged. About +70 B.
7. Specs: the facade message with the hint (failing first); raising handler
   (failing first); `ToEqual` path messages unchanged after the rename;
   upgrade from revision 5. KitConformance opt-in.
8. Docs: CHANGELOG `## 0.2.0`; API.md `## Secret values` section.
9. Status: recorded 2026-11-16; code follows.

**profileKit: shared `validateFacade`; `describeKey` and `limits` opted out** — a change to facade `ProfileKit`, equivalent for every input

1. Package `profileKit`, facade `ProfileKit`, API 1, 0.1.6 → 0.1.7,
   **revision 4 unchanged**: the only converted copy is equivalent for every
   input, so an older embedded copy of revision 4 stays correct.
2. Copies: `validateFacade` (333, C3, converted); `describeKey` (349) and
   `limits` (364) opted out.
   - `describeKey` requires an `isSecret` block, which profileKit does not
     carry: it binds `nativeIsSecretValue` once so the disabled `Measure`
     pays one call and no global lookup (its file says so). Adding the block
     beside it costs a main-chunk local and about 540 B for a branch no key
     can reach (its only caller is the limits loop over `next`).
   - `limits`: D1 (no ceiling on `maxSections`; a secret value folded into
     the range message today).
3. Dependencies unchanged.
4. For users: nothing.
5. pins.json: `optOuts` `describeKey` and `limits`, reason "ProfileKit's
   probe is bound at load for the disabled Measure; the shared describeKey
   needs an isSecret block, and the shared limits block measured larger than
   this Kit's loop."
6. Locals 62 unchanged. About +70 B.
7. Specs: none new beyond KitConformance opt-in (the dot-call refusals are
   already specified and unchanged).
8. Docs: CHANGELOG `## 0.1.7` ("Documentation and tooling only:
   implementation revision 4 is unchanged" in the house wording); API.md
   skeleton (`## Errors`, `## Cost`, `## Upgrades` renames, order).
9. Status: recorded 2026-11-16; code follows.

**clientKit, localeKit, and the conformance and API.md work across all 27** — no helper change in clientKit or localeKit

1. Packages `clientKit` (0.3.2, revision 8) and `localeKit` (0.1.7,
   revision 5): no listed copy, no version or revision change from this
   record.
2. Why nothing converts:
   - clientKit is the secret probe's provider: `readSecretProbe` reads its
     own `host.isSecretValue` binding first; `describeValue` quotes strings
     with `%q` and names `nil`; the deprecation reporter `deliver` runs both
     `geterrorhandler()` and the handler under `pcall` and drops a failure
     (a warning must never break the call it warns about). None is a shared
     helper's contract.
   - localeKit's probe is `loadedSecretProbe` plus `readSecretProbe` (the
     probe rule, hoisted by its callers); its `report` is an unprotected
     `reportError` under another name (D5).
3. Dependencies: none.
4. For users: nothing.
5. pins.json: nothing.
6. Memory: nothing.
7. Tests: KitConformance (`tests/support/KitConformance.lua`) opt-in for all
   27 packages, each a `tests/Conformance_spec.lua` over its test
   environment; groups whose field a Kit cannot fill stay pending with the
   field named (no `SetLimits` in apiKit, hookKit, interopKit, localeKit,
   readinessKit; no secret-checked argument where ADR 0002 asks none). The
   `limits` group asserts a ceiling per limit (docs/TESTING.md, "The
   conformance suite"), so a limit without one (brokerKit, compatKit,
   logKit, mediaKit `maxConsumers`, profileKit, testKit) is described
   without that case or the group stays pending, whichever the field
   allows; D1's ceiling question decides it for good. A
   failure the suite finds in a Kit not otherwise changed here is a separate
   fix with its own revision.
8. Docs: the `docs/API.md` skeleton (`docs/CONTRIBUTING.md`, "The
   docs/API.md skeleton") for every package of the set the validator warns
   about today: addonKit, apiKit, bridgeKit, cacheKit, clientKit, compatKit,
   hookKit, interopKit, localeKit, logKit, profileKit, readinessKit, testKit
   (41 warnings, measured with `tooling.validation.validate_repository`
   2026-11-16). For clientKit and localeKit this is documentation only: a
   patch version each, revision unchanged.
9. Status: recorded 2026-11-16; code follows.

---

Resulting migration list for these 27 packages: 67 copies become blocks, 10
leave the list by `optOuts` (8 `limits`, testKit `isSecret`, profileKit
`describeKey`), 1 by the rename (testKit `describeKey`); 0 remain. One
existing opt-out goes (hookKit `validateFacade`).
