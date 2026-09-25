# CommandKit Internals

This document describes implementation invariants for maintainers. It is not an additional public API.

## Package state

`CommandKit._state` is shared by every embedded copy:

| Field | Meaning |
|---|---|
| `schema` | The state layout version, `1`. |
| `dispatch` | `slash`, `tabPressed` and `closeAddonScopesAtLogout`; every closure CommandKit leaves in the client's tables, and the logout watcher's trampoline, call through it. |
| `runtimeRevision` | The revision that last committed its functions. |
| `scopeMetatable`, `contextMetatable` | The metatables every scope and context shares; their `__index` is `CommandKit.Scope` and `CommandKit.Context`. |
| `addonScopes` | Addon name to that addon's canonical scope. Only `ForAddon` adds to it. |
| `activeByName` | Lower-case slash name to the top-level record that currently owns it. At most one owner per name, across every scope. |
| `keyByName` | Lower-case slash name to the slash-table key it was first registered under. Never shrinks during a session. |
| `ownedKeys` | Slash-table key to the lower-case name it serves, for every key CommandKit ever wrote. The taken check skips these keys (also when `hash_ChatTypeInfoList` names one), and the dispatcher reads its name here. |
| `slashHandlers` | Slash-table key to the permanent dispatcher closure written under it. One closure per key for the session. The taken check does not count a `hash_SlashCmdList` entry holding one of these closures. |
| `frames`, `frameDepth` | The dispatch frames, one per nesting level up to `MAX_NESTING` (4), and how many are in use. |
| `completion` | `installed`, `previous` (the function the replacement forwards to, or `false`), `handler` (the replacement closure, or `false` before the first install) and `enabledScopes`. |
| `unbounded` | The `CommandKit.UNBOUNDED` sentinel, created once so every revision publishes the same table; the state predicate checks the facade field against it. |
| `logoutWatch` | `{ scope, connection, trampoline }`: CommandKit's own EventKit scope, its one `PLAYER_LOGOUT` `Once` connection and the trampoline handed to it, each `false` until the first `ForAddon` in case (c) of "At logout" creates it. Added by revision 2; an upgrade over revision 1 adds it. |
| `limits` | The package-wide limits `SetLimits` writes: `maxCaptured` (an integer or the sentinel), `maxCompletions` and `maxEmotes` (integers under their ceilings). Read where they apply, so a change takes effect at the next capture, completion or registration. |

`keyByName`, `ownedKeys` and `slashHandlers` grow with the number of distinct slash names registered in the session, which is bounded by what addons register; each entry is a few strings and one closure.

## Scope layout

| Field | Meaning |
|---|---|
| `_schema` | The scope layout version, `2` (revision 2 added the two logout fields). |
| `_addonName` | The owning addon name, or `false` for a manual scope. |
| `_closed` | Whether `Close` (or `CloseAddonScopes`) ran. |
| `_logoutCloser` | Who closes the scope at logout: `false` for a manual scope, else `"lifecycleKit"`, `"onShutdown"`, `"playerLogout"` or `"none"` (the cases of "At logout" in `API.md`). Only `"none"` and `"playerLogout"` are decided again. |
| `_shutdownSubscription` | The LifecycleKit `OnShutdown` subscription of case (b), or `false`. `Close` disconnects it. |
| `_count` | The number of registered top-level commands. |
| `_commands` | Lower-case name to top-level record. |
| `_sink` | The sink, or `false` for `DEFAULT_CHAT_FRAME`. |
| `_completion` | Whether this scope counts in `completion.enabledScopes`. |
| `_maxCommands`, `_maxSubcommands`, `_maxPositions`, `_maxSlashAliases` | The scope's limits, resolved from its options at creation: an integer, or `math.huge` for `CommandKit.UNBOUNDED`, so every comparison on the registration path stays numeric. |

## Record layout

`Register` compiles a spec into one record per command and sub-command, with every field present from the start; nothing writes a record after `Register` returns, except `_scope`, set once on every record of the tree before the command becomes active.

| Field | Meaning |
|---|---|
| `_schema` | The record layout version, `1`. |
| `_path` | The full lower-case path, `"/cmd sub"`. |
| `_handler`, `_complete` | The spec's functions, or `false`. |
| `_mode` | `"none"`, `"positions"` or `"array"`. |
| `_schemas`, `_coercions`, `_positionCount` | Sealed schemas and their token conversions (`"number"`, `"boolean"`, `"string"`); for `"array"` one of each for the element. |
| `_defaulted` | Per position, whether the schema is an `optional` with a default; a missing argument there is filled with `schema:Apply(nil)`. Empty for `"none"` and `"array"`. |
| `_usage`, `_description` | The usage tail and the description (`false` when absent). |
| `_subcommands`, `_subcommandNames` | Lower-case name to child record, and the names sorted. |
| `_usageLines` | The lines `Usage()` writes, built once. |
| `_scope` | The owning scope, on every record of the tree. |

A record never changes owner: unregistering drops it, and a later registration compiles a new one.

## Slash dispatchers

The closure under a key is created once per key and never replaced:

```text
function(text, editBox) dispatch.slash(key, text, editBox) end
```

`dispatch.slash` reads `ownedKeys[key]` for the name and `activeByName[name]` for the record. No record: the call returns at once, which is what "inert" means. Because the lookup is by name and a name keeps its key, whichever function the client cached for `/name` reaches the current owner.

## Dispatch frames

A frame is `{ tokens = {}, arguments = {}, argumentMark = 0, context = <context> }`. `acquireFrame` hands out `frames[frameDepth + 1]`, creating it on first use, and `releaseFrame` retires the context (`_live = false`) and decrements the depth. Dispatch runs `runCommand` inside `pcall` so the frame is always released, whatever a sink or a handler does. A handler that runs another command gets the next frame, so the outer command's tokens, arguments and context are untouched when it continues.

`tokenize` clears `tokens` after the count; `runCommand` copies the argument tokens to `arguments` and clears every slot up to `argumentMark`, the highest slot the previous dispatch at that depth wrote, so an array schema always sees keys exactly `1..n` and no filled default survives into the next command. Clearing only up to the first `nil` would not do: a default can sit above a missing position. Conversions, and a default filled for a missing position, write in place; a default is a fresh copy from `Apply` on every dispatch, which allocates when the default is a table. Otherwise nothing in the path allocates when the text has been seen before: token strings are interned, `string.lower` of a known sub-command name returns the existing string (and `walkSubcommands` stops at a record without sub-commands before lower-casing the next token, which is an argument, often an item link whose lower-case copy would be a new string), number conversion and `Check` of a valid value allocate nothing, and `pcall(handler, context, unpack(arguments, 1, n))` creates no closure.

## Parser state machine

`tokenize(text, array)` is one loop over byte positions with no state outside the call. Bytes are compared as numbers (`string.byte`), and the terminators of an escape sequence are found with plain `string.find`, so nothing but the token strings is allocated.

```text
BETWEEN     whitespace: advance; anything else: start a token in SEGMENT

SEGMENT     (a quote may open here: token start, or right after a closing quote)
  "         find the closing " → QUOTED segment, then SEGMENT again
            none: "unterminated quote" (or "unterminated link" from inside)
  '         find the closing ' → if it is followed by whitespace, the end or
            a quote: QUOTED segment, then SEGMENT again; otherwise BARE
            (the ' is an apostrophe)
  other     BARE
  whitespace or end: emit the joined segments, back to BETWEEN

QUOTED      scanning for the closing quote
  \ + quote or \ + \   skip two bytes, remember an escape
  |H                    skip the link (missing |h: "unterminated link")
  ||                    skip two bytes
  other |               skip the pipe alone
  other                 advance

BARE        up to whitespace or the end; quotes are ordinary bytes here
  |                     ESCAPE
  other                 advance

ESCAPE
  ||      skip two bytes
  |H      find "|h", then the next "|h"; skip past it (missing: "unterminated link")
  |c      find "|r"; skip past it when it comes before the next "|c",
          otherwise skip the pipe alone
  |T      find "|t"; skip past it (missing: skip the pipe alone)
  other   skip the pipe alone: the next byte is read normally, so
          whitespace or a quote right after a stray pipe still ends the run
```

- Adjacent segments join (`"a"b` is `ab`); a token of one segment is one `string.sub`, so joining allocates only when segments really are joined.
- Inside quotes only `||` and hyperlinks are skipped as units: a link's text may contain a quote, while colour codes, textures and a stray pipe cannot hide the closing quote.
- Escapes are removed with one `gsub` only when the segment had one.
- A single quote that does not close before a boundary is read as an apostrophe, so `'twas` and `don't` never fail; only an unclosed double quote is refused.
- On a refusal every slot of the array is cleared, so a caller never sees half a parse.

## Completion

The replacement is created once and kept in `completion.handler`:

```text
function(editBox, ...) return dispatch.tabPressed(editBox, ...) end
```

`tabPressed` tries completion only while `enabledScopes > 0`, inside `pcall`; an error is reported and the call falls through to `completion.previous`. `installTabHandler` writes the global only when it is not already the replacement, remembering the current function as `previous`; `uninstallTabHandler` writes `previous` back only when the replacement is still the installed global. When another addon has replaced the global since, `installed` stays `true` and the replacement keeps forwarding, so a later `EnableCompletion` does not install a second copy into the chain.

`tryComplete` borrows a dispatch frame to tokenise the words before the one being completed, walks the sub-commands with them, and opens the frame's context on the reached record for the `complete` call.

## Upgrades

Revision 1 creates the state above; a later revision validates it with `validateStateBase` and rewrites `dispatch`, the prototypes and `runtimeRevision`. Dispatchers and the tab replacement installed by an older copy call through `dispatch`, so they run the newer code at once; scopes and contexts reach the newer methods through the shared metatables. A revision that changes a layout checks the `_schema` of each scope, record and context it inherits.

Revision 2 does this for scope layout 2: it walks `addonScopes`, gives every layout-1 scope `_logoutCloser = "none"` and `_shutdownSubscription = false`, adds `logoutWatch` to the state, and after committing arranges the logout close of every open addon scope in addon-name order. A manual layout-1 scope is left as built; the logout code reads both fields with `rawget` and treats a missing one as "nothing to do". The logout functions are fields of one `LogoutClose` table and the logout constants one `LOGOUT` table, because the main chunk is close to Lua 5.1's limit of 200 locals.

Revision 3 changes no layout and inherits revision 2's state unchanged. Its fixes reach every existing command through `dispatch` and the shared prototypes, except the sub-command handlers `BindOptions` compiled into a bound command's records, which stay those of the revision that bound it.

Revision 4 changes no layout either and inherits revision 3's state unchanged; its nil checks on outside values reach existing commands the same way.

Revision 6 changes no layout and inherits revision 5's state unchanged. Its taken check also asks the client's `hash_*` lookup tables and `IsSecureCmd`, and tells CommandKit's own entries there apart by `ownedKeys` and by the closures in `slashHandlers`, so a name an older copy registered is still CommandKit's after the upgrade.
