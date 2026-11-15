# hookKit records

Moved from `docs/ROADMAP.md` (Package C planned Kits — the nine points).

## hookKit

**hookKit** — facade `HookKit`

1. Package `hookKit`, facade `HookKit`, API generation 1.
2. Purpose: reversible hooking with the three semantics named and the taint
   consequences spelled out: secure post-hook (default, wraps
   `hooksecurefunc` and `frame:HookScript`, made reversible by an active
   flag on a closure that stays installed), safe pre-hook (handler first,
   original always runs, returns untouched) and raw replacement (original
   handed to the handler). Non-goals: hooking secure functions insecurely
   without an explicit override, hooking protected scripts on protected
   frames.
3. Dependencies: registry API 2; clientKit API 1 optional through
   `Registry:Find` for `IsSecret` and capability flags.
4. Surface: `HookKit:CreateScope()` / `HookKit:ForAddon(addonName)` →
   scope with `SecureHook(object, method, handler)`, `SecureHookScript(frame,
   script, handler)`, `Hook(object, method, handler, options)`,
   `RawHook(object, method, handler, options)`, `HookScript(frame, script,
   handler, options)`, `Unhook(object, method)`, `UnhookAll()`, `IsHooked`,
   `Hooks()` (enumeration for diagnostics), `Close()`; `options.forceSecure`
   is the explicit override for a non-secure hook of a secure target and the
   target's secure status is remembered from before the first hook.
5. Ownership: hooks belong to a scope; moduleKit's `module.scope` gains
   `Hooks` lazily; restoration on unhook happens only when the installed
   function is still ours, otherwise the closure stays and turns inert.
6. Performance: one record per hook keyed by object and method in a
   weak-keyed table (no auto-vivifying registry); the installed closure
   reads one flag before dispatching; bounded hooks per scope
   (`maxHooks` 256).
7. Tests: each of the three semantics, unhook with and without a later
   foreign hook, secure target refusal and override, protected script
   refusal, scope Close, IsHooked and Hooks, secret argument passing through
   untouched, upgrade, manifest, error levels pinned.
8. Docs: README, API.md leading with the taint model, CHANGELOG;
   EMBEDDING.md host row and a taint-section cross-reference.
9. Status: implemented (package C2, 0.1.0); deviations recorded in
   `packages/hookKit/docs/API.md`.

Moved from `docs/ROADMAP.md` (Package O — memory, performance and ease of use (decisions 18 and 19)).

## hookKit (package O): counted hook bound, inline isolation, scope reopening and method-name handlers

**hookKit (package O): counted hook bound, inline isolation, scope reopening and method-name handlers** — a change to facade `HookKit`

1. Package `hookKit`, facade `HookKit`, API generation 1 (additive),
   version 0.4.0 (from 0.3.2), implementation revision 8 (from 7).
2. Purpose: the measured HookKit fixes of
   the decision 18 diagnosis (section hookKit;
   prototype the diagnosis prototype), `Scope:Reopen` for
   ModuleKit's kept `Hooks` scope, and decision 19c's method-name form.
   - **Counted upper bound instead of a walk.** `hasRoom` (`:1090`) today
     calls `countRecords` on every install, so installing n hooks is
     quadratic. Each scope keeps `_recordBound`, raised by one at every
     record added and lowered at `removeRecord` (`:819`, the only place a
     record is removed). A real count runs only when the bound reaches
     `maxHooks`; it also forgets records of collected objects and resets the
     bound. A scope an older revision built has no bound and is counted on
     first use.
   - **`pcall` inline in the hook closures.** Pre-hook and secure post-hook
     closures call `pcall(record._handler, ...)` and pass a failure to
     `dispatch.reportFailure`, instead of going through
     `dispatch.isolatedCall`, which stays published for closures older
     revisions installed.
   - **No `type()` before the private-metatable checks** (`:512`, `:967`).
   - Probe: HookKit already follows package O's rule (`isSecret`, `:486`).
   - **`Scope:Reopen()`.**
   - **Method-name handlers (decision 19c)**, the counterpart of AceHook's
     `self:Hook(obj, "Method", "Handler")` and its default handler name.
   Non-goals: AceHook's `hookSecure` flag, late binding, AceHook's
   `self.hooks` table (`scope:Original` is the counterpart).
3. Dependencies: unchanged, registry API 2.
4. Surface: in the handler position of `Hook`, `RawHook`, `SecureHook`,
   `HookScript`, `RawHookScript` and `SecureHookScript`, a receiver table
   followed by an optional handler name:
   - `Hook(object, method, receiver[, handlerName][, options])` and
     `Hook(globalName, receiver[, handlerName][, options])`; the script
     forms `HookScript(frame, script, receiver[, handlerName][, options])`.
     After the receiver, a string is the handler name and anything else is
     the options table. The default handler name is the hooked method's or
     script's name, as in AceHook (`AceHook-3.0.lua:119` at the bench's
     pinned commit, read for behaviour only).
   - The handler runs as `handler(receiver, ...)` with what the closure form
     receives: the call's arguments, and for `RawHook`/`RawHookScript` the
     original first (`handler(receiver, original, ...)`), which differs from
     AceHook (it passes `self` and keeps originals in `self.hooks`); the
     migration table says so.
   - Resolved and checked at the call, errors at the caller's line:
     `<method> handler must be a function, or a receiver table followed by
     an optional handler name` (containing today's `handler must be a
     function`), `<method> handlerName must be a non-empty string`,
     `<method> handlerName must not be a secret value`, `<method> receiver
     has no method "<name>"`.
   - **Early binding** (recorded deviation from AceHook, which looks the
     handler up per call).
   - `scope:Reopen()` → `true` when it reopened a closed manual scope,
     `false` when it was open; its limit is kept; closures left inert by the
     close stay inert (a new hook installs a new closure). An addon scope
     raises at the caller (`HookKit.Scope:Reopen cannot reopen an addon
     scope`).
5. Ownership: unchanged.
6. Performance and memory (host bench against AceHook-3.0, same run):

   | Case | Before | Expected after |
   |---|---:|---:|
   | call through a pre-hooked script / method | 1.89× / 1.81× | 1.47× / 1.39× |
   | call through a post-hooked method | 1.64× | 1.31× |
   | install with 200 hooks resident | 11,331 ns | 1,298 ns, flat in n |
   | install with 0 resident | 1,341 ns | 1,276 ns |

   One number field per scope for the bound, no per-hook bytes. Method
   form: a 136 B closure per hook and one extra Lua frame per hooked call
   (about 12.5 ns, measured in the diagnosis prototype).
7. Tests: installs up to `maxHooks` and the refusal past it with the bound;
   the bound after `Unhook`, `UnhookAll`, `Close`, and with records of
   collected objects (recount frees room); a revision 7 scope without a
   bound; inline isolation reports a handler error and still runs the
   original, results and `nil` counts unchanged; closures installed by
   revision 7 keep working after the in-place upgrade; receiver checks
   without `type`; method form on all six methods with and without a
   handler name and with options, refusals at the caller's line, the raw
   form's `original` argument, early binding; `Reopen`.
8. Docs: API.md (method form, raw-form argument order, `Reopen`, the install
   cost), INTERNALS.md (`_recordBound`, inline isolation), CHANGELOG, README
   (migration rows for `Hook(obj, "Method", "Handler")` and the default
   handler), tests/README.
9. Status: implemented 2026-11-15 under core decisions 18 and 19, 0.4.0,
   revision 8, 151 specs. Deviations: the handler is looked up on the receiver
   at every call (late binding); the counted bound lives in the weak-keyed
   state table `recordBounds`, not a `_recordBound` scope field, so the scope
   stays at eight fields.

