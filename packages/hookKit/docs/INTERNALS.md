# HookKit Internals

This document describes implementation invariants for maintainers. It is not an additional public API.

## Package state

`HookKit._state` is shared by every embedded copy:

| Field | Meaning |
|---|---|
| `schema` | The state layout version, `1`. |
| `dispatch` | `isolatedCall`, `replacementCall` and `closeAddonScopesAtLogout`; every closure HookKit installs, and the logout watcher's trampoline, call through it. |
| `runtimeRevision` | The revision that last committed its functions. |
| `scopeMetatable` | The metatable every scope shares; its `__index` is `HookKit.Scope`. |
| `addonScopes` | Addon name to that addon's canonical scope. At most one per addon name. |
| `secureStatus` | Weak-keyed: hooked object to `{ [method] = boolean }`, whether the target was secure the first time HookKit checked it. For a method that is not a raw field, `findHolder` walks at most `MAX_INDEX_DEPTH` (8) `__index` tables to the table holding it, and that table is what `issecurevariable` is asked about. |
| `secureScripts` | Weak-keyed: frame to `{ [script] = count }` of active `SecureHookScript` records across every scope. A script pre-hook or replacement is refused while the count is positive; release decrements it and deletes empty tables. |
| `logoutWatch` | `{ scope, connection, trampoline }`: HookKit's own EventKit scope, its one `PLAYER_LOGOUT` `Once` connection and the trampoline handed to it, each `false` until the first `ForAddon` in case (c) of "At logout" creates it. Added by revision 2; an upgrade over revision 1 adds it. |
| `unbounded` | The `HookKit.UNBOUNDED` sentinel, created once so every revision publishes the same table and a scope's `_maxHooks` keeps meaning "unbounded" after an upgrade. The current-state predicate requires the facade field to be this table. |

The scope prototype is published as `HookKit.Scope`, like EventKit's and TimerKit's.

## Scope layout

A scope is one table with a fixed set of private fields, all created by `newScope`:

| Field | Meaning |
|---|---|
| `_schema` | The scope layout version, `2` (revision 2 added the two logout fields). |
| `_addonName` | The owning addon name, or `false` for a manual scope. |
| `_closed` | Whether `Close` (or `CloseAddonScopes`) ran. |
| `_maxHooks` | The scope's limit: a positive integer (default `MAX_HOOKS`, 256) or the `unbounded` sentinel. Set at creation and never rewritten; a later `ForAddon` naming a different value is refused. |
| `_sequence` | The creation counter records are stamped with. |
| `_records` | Weak-keyed: hooked object (or `_G`) to `{ [method or script] = record }`. |
| `_logoutCloser` | Who closes the scope at logout: `false` for a manual scope, else `"lifecycleKit"`, `"onShutdown"`, `"playerLogout"` or `"none"` (the cases of "At logout" in `API.md`). Only `"none"` and `"playerLogout"` are decided again. |
| `_shutdownSubscription` | The LifecycleKit `OnShutdown` subscription of case (b), or `false`. `Close` disconnects it. |

There is no stored hook count. `countRecords` walks `_records`, which holds at most `_maxHooks` entries, so a record that disappears with its garbage-collected object stops counting at once instead of holding a slot for ever. `hasRoom` returns `true` without counting when `_maxHooks` is the `unbounded` sentinel, so an unbounded scope never pays a walk per install.

Reads never create anything: `findRecord` returns `nil` after at most two raw reads. Only `storeRecord` creates the per-object method table, and `removeRecord` deletes it when its last record goes. This is the fix for the auto-vivifying registry pattern older hook libraries use.

## Record layout

One record per hook, created by `newRecord` with every field present:

| Field | Meaning |
|---|---|
| `_schema` | The record layout version, `1`. |
| `_kind` | `"secure"`, `"secureScript"`, `"hook"`, `"rawHook"`, `"hookScript"` or `"rawHookScript"`. |
| `_handler` | The consumer's handler. |
| `_original` | The wrapped or replaced function; `false` for a secure hook and for a script that had no handler. |
| `_hadRaw` | Whether the field was a raw field of the object before the hook; decides between writing the original back and deleting the field. |
| `_installed` | The closure HookKit installed. |
| `_active` | The one flag the closure reads. Cleared by `Unhook` and never set again: a re-hook makes a new record and closure. |
| `_sequence` | Creation order within the scope; `Hooks()` and the release order use it. |

A record never references its object, so the weak key can be collected. It does reference the closure, which references the record; both go when the object does (or, for a secure hook, never, because the host keeps the closure). Lua 5.1 weak tables are not ephemeron tables: a handler that captures the hooked object keeps it, and its entry, alive through the record.

## Installed closures

Three shapes, each created once per hook:

```text
post-hook:     if record._active then dispatch.isolatedCall(record, ...) end
pre-hook:      if record._active then dispatch.isolatedCall(record, ...) end
               return record._original(...)            (when there is one)
replacement:   if record._active then return dispatch.replacementCall(record, ...) end
               return record._original(...)            (when there is one)
```

`isolatedCall` is `pcall(record._handler, ...)` plus a report on failure; `replacementCall` is `record._handler(original, ...)` with `false` mapped to `nil`. Neither builds a table, so a hooked call allocates nothing. The closures use plain field reads because a record has no metatable.

The original is passed first to a replacement handler because Lua 5.1 cannot append a value after `...` without packing the arguments into a table.

## Order of work in an install

1. Validate the receiver, that the scope is open, the object or frame, the name, the handler, and that the target is not already hooked in this scope; for field hooks, that the target is a function; for script hooks, that the frame may be touched and has the frame methods the semantic calls.
2. Read the option table.
3. Refuse: the secure target (`wasSecure`, which fills the memo on first use) or the protected-frame rules.
4. Check the capacity against the scope's `_maxHooks` (`nil, "full"`).
5. Build the record and closure, perform the host write (`hooksecurefunc`, `rawset`, `HookScript` or `SetScript`), and only then store the record. A host call that raises leaves nothing recorded.

Every public method calls its installer and returns the results through locals rather than as a tail call: a Lua 5.1 tail call replaces the public method's frame, and `error` levels counted from the installer would then land on the tail-call marker instead of the caller's line.

## Release

`releaseRecord` removes the record and clears `_active` first, so the scope is consistent even when the host write that follows raises. It then restores only when the installed function is still HookKit's (`rawget` for fields, `GetScript` for scripts), and never calls `SetScript` while `secureScripts` counts a HookKit post-hook on that script (it was installed after the pre-hook, and `SetScript` may drop it), on a protected frame during combat lockdown (a conservative rule) or on a frame that has become forbidden or inaccessible. `releaseAll` collects the records into three parallel arrays sorted by `_sequence` with an insertion sort (at most the scope's `_maxHooks` records, so quadratic only in a scope opened far beyond the default), releases them newest first under `pcall`, and re-raises the first failure with level `0` so the host's error object is unchanged.

## Upgrades

The bootstrap follows the Registry pattern. A copy that inherits state validates the shared fields and reuses `scopeMetatable`, `addonScopes`, `secureStatus` and `dispatch`, then rewrites the prototype methods and the dispatch functions. Closures installed by an older copy capture the shared `dispatch` table, not a function, so they run the newest behaviour. A revision that changes the record or scope layout must migrate by `_schema`, lazily or by walking `addonScopes`; manual scopes are reachable only through their owners, so a lazy migration on first use is the one that covers them.

Revision 2 does this for scope layout 2: it walks `addonScopes` and gives every layout-1 scope `_logoutCloser = "none"` and `_shutdownSubscription = false`, and adds `logoutWatch` to the state. A manual layout-1 scope is left as built: the logout code reads both fields with `rawget` and treats a missing one as "nothing to do". After committing, an upgrading copy arranges the logout close of every open addon scope, in addon-name order.
