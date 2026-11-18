# commandKit records

Moved from `docs/ROADMAP.md` (Package C planned Kits — the nine points).

## commandKit

**commandKit** — facade `CommandKit`

1. Package `commandKit`, facade `CommandKit`, API generation 1.
2. Purpose: slash commands done once: registration that follows the module
   that owns it, an argument parser that understands quotes and WoW
   hyperlinks so a shift-clicked item does not break a command, sub-commands
   with usage and help generated from their declarations, output sinks
   (chat frame, a custom frame, a capture for tests), tab completion, and a
   binding that drives an optionsKit tree from the command line. Non-goals:
   a console UI, macros, anything that sends chat to other players.
3. Dependencies: registry API 2, schemaKit API 1 (argument schemas);
   optionsKit API 1 optional through `Registry:Find` (binding), localeKit
   API 1 optional (localised help), clientKit API 1 optional (`IsSecret`).
4. Surface: `CommandKit:CreateScope()` / `ForAddon(addonName)` → scope
   with `Register(name, spec)` where `spec` has `handler(context, ...)`, an
   optional `arguments` schema (a `SchemaKit.array` or per-position list),
   `usage`, `description`, `subcommands = { name = spec }`, `complete(text)`
   for custom completion; the slash global `SLASH_<KEY>1` and
   `SlashCmdList[<KEY>]` are written through `rawset` with a key derived
   from the addon and command names, refused when the slash name is already
   taken by another owner (`nil, "taken"`); `Unregister(name)`, `Close()`
   removes every command of the scope (the slash global is left pointing at
   an inert function because the client's table cannot be cleaned;
   documented); `CommandKit:Parse(text)` → arguments array honouring
   `"quoted strings"` and `|H...|h[...]|h` hyperlinks as single tokens,
   allocating one array per call (documented) plus `CommandKit:ParseInto(text,
   array)` for the allocation-free form; `context:Print(...)`,
   `context:Printf(format, ...)`, `context:Usage()`, `context:Fail(reason)`
   to the scope's sink; `scope:SetSink(sink)` where a sink is
   `{ AddMessage = fn }`; `CommandKit:CaptureSink()` for tests;
   `scope:BindOptions(optionsTree, commandName)` generating `get`, `set`,
   `reset`, `list` sub-commands over an optionsKit tree with values parsed
   through the option's schema; tab completion through `ChatEdit` hooks when
   `ChatEdit_CustomTabPressed` exists (optional, documented).
5. Ownership: commands belong to a scope; moduleKit's `module.scope` gains
   `Commands` lazily; lifecycleKit closes the addon's command scopes at
   shutdown through `CloseAddonScopes` (two-step, as for EventKit).
6. Performance: dispatch is one table lookup on the slash key and one on
   the sub-command; parsing allocates only in the `Parse` form; bounded
   commands per scope (`maxCommands` 64) and sub-command depth 3.
7. Tests: registration writes the two globals, taken slash refused, parse
   with quotes, hyperlinks, mixed and malformed input, sub-command dispatch
   and usage, schema-validated arguments refused with a message, sink
   capture, BindOptions get/set/reset/list against a real optionsKit tree,
   completion with a stubbed ChatEdit, Close leaves an inert global,
   upgrade, manifest, error levels.
8. Docs: README, API.md with a full slash-command example, CHANGELOG;
   EMBEDDING.md host row (`SlashCmdList`, `SLASH_*`, `DEFAULT_CHAT_FRAME`,
   `ChatEdit_CustomTabPressed`).
9. Status: implemented (package C3, 0.1.0); deviations recorded in
   `packages/commandKit/docs/API.md`.

Moved from `docs/ROADMAP.md` (Package O — memory, performance and ease of use (decisions 18 and 19)).

## commandKit secret question without a per-call Registry lookup

**commandKit secret question without a per-call Registry lookup** — an internal change to facade `CommandKit`

1. Package `commandKit`, facade `CommandKit`, API generation 1 (no surface
   change), version 0.2.10 (from 0.2.9), implementation revision 10 (from 9).
2. Purpose: `isSecret` (`CommandKit.lua:658`) looks ClientKit up through the
   Registry on every call (70 to 100 instructions each, twice per Register,
   also on every options-binding write). It now looks it up on the first
   secret question and keeps the answer, a miss included, in state. A
   ClientKit registered after that first question is not consulted; on the
   client that changes no answer, because ClientKit's `IsSecret` asks the
   same `issecretvalue` (`ClientKit.lua:873`). Alias liveness is kept, by
   the owner's decision: every Register still reads every foreign
   `SLASH_<key><n>` and chat-type alias live (prototype E's alias index is
   not taken).
   Non-goals: the alias index, reading only the next alias slot, any change
   to dispatch or parsing.
3. Dependencies: unchanged; clientKit API 1 stays optional.
4. Surface: none.
5. Ownership: the kept lookup lives in `state`, so an upgraded revision
   starts from it; a ClientKit implementation table is stable per package
   and API across its own upgrades (Registry: "one stable implementation
   table per (package, API) pair"). Upgrade from revision 9: the field is
   created empty and filled on first use.
6. Performance and memory: register-unregister about 3 011 to about 2 840
   instructions (the `isSecret` lookups, 124 to 170 instructions, measured
   share of prototype E), so about 28x instead of 30x (estimate); the scan
   (2 130 instructions, 71%) stays, which is the price of the kept liveness.
   Options command line 10 to 20% faster (measured, prototype H). No new
   allocation.
7. Tests: ClientKit asked when registered before the first question
   (`SecretValues_spec.lua:74` stays), one Registry lookup for many
   questions, a miss kept, the upgrade from revision 9;
   `TakenCheck_spec.lua:123` ("reads every alias live") unchanged.
8. Docs: `docs/INTERNALS.md` (the kept lookup and why a miss may be kept),
   CHANGELOG, `tests/README.md`.
9. Status: implemented 2026-11-15 under core decision 18, 0.2.10, revision 10,
   176 specs. register-unregister 29.9x to 28.3x of AceConsole-3.0; the live
   alias scan stays, by the owner's decision, and `docs/API.md` says why.

Moved from `docs/ROADMAP.md` (Package O — memory, performance and ease of use (decisions 18 and 19)).

## commandKit (package O): parts for options binding and completion; the command list, a prefix, dispatch, the AceConfigCmd path syntax and general tab completion

**commandKit (package O): parts for options binding and completion; the command list, a prefix, dispatch, the AceConfigCmd path syntax and general tab completion** — a change to facade `CommandKit`

1. Package `commandKit`, facade `CommandKit`, API generation 1, version
   0.3.0 (from 0.2.10), implementation revision 11 (from 10). Two parts
   (ADR 0001): `CommandKit-Options` (`src/parts/CommandKit-Options.lua`,
   part revision 1) and `CommandKit-Completion`
   (`src/parts/CommandKit-Completion.lua`, part revision 1).
2. Purpose: the CommandKit items of the Ace3 feature-gap diagnosis (section
   "AceBucket, AceConsole, AceConfigCmd, AceTab", work package 10), placed
   so an addon that only registers commands stops paying for options binding
   and completion.
   - **The split, along existing sections.** The "Options binding" section
     (20.0 KB of prototypes, 19 main-chunk locals) moves to the `Options`
     part and the "Completion" section (7.1 KB, 8 locals) to the
     `Completion` part, measured with the section walk on revision 10. The
     new options features join the first, AceTab's counterpart the second.
     The core keeps `BindOptions`, `EnableCompletion` and
     `DisableCompletion` (and the new part methods) on the scope prototype as
     forwarders: each calls its part through `_state.parts.<Part>` with an
     explicit error level, and raises at the caller's line when the part is
     not loaded: `CommandKit.Scope:BindOptions needs CommandKit's Options
     part, which is not loaded: add commandKit\parts\CommandKit-Options.lua
     to your embeds.xml`. A forwarder in the core, rather than a method the
     part writes onto the prototype, survives any load order of core and
     part revisions. The core shares what the parts need (tokenizer,
     sub-command walk, frames, contexts, output, secret probe, host
     readers, the error reporter, limits, `activeByName`) through
     `_state.helpers`, read at call time, so an upgraded core's helpers
     serve parts loaded before it (AddonKit's pattern). Freeing 27 locals
     takes the main chunk from 198 to about 175, below the gate's fail line,
     so its `lua_limits.json` entry is removed.
   - **This changes embedding.** An addon that calls `BindOptions` or
     `EnableCompletion` must embed the part; a hand-written file list that
     names only `CommandKit.lua` gets the error above at the call, with the
     file to add. A single-Kit release ships both parts, and
     `tooling.package.embeds` adds them when selected. This is the
     consequence ADR 0001 states for every split.
   - **The command list** (AceConsole `IterateChatCommands`, 0/16).
     `scope:GetCommands()`: a new sorted array of the scope's active
     top-level slash names; `CommandKit:GetCommands()`: every active name
     CommandKit serves in the session (AceConsole's iterator is global too).
     Diagnostics; both allocate.
   - **A prefix and printing outside a handler** (AceConsole `Print`).
     `scope:SetPrefix(text)` (or `nil`) returns the previous prefix;
     `scope:GetPrefix()`. With a prefix, every line the scope writes (handler
     output, usage, refusals, option listings, completion lists) starts with
     `text`; colour codes are the author's choice (Ace's form is
     `"|cff33ff99Name|r: "`). Default none, so today's output is unchanged.
     `scope:Print(...)` and `scope:Printf(template, ...)` write to the
     scope's sink outside any handler, with the same argument rules as
     `context:Print`/`Printf` (`Printf` through LocaleKit when present).
   - **Dispatch from code** (AceConfigCmd `HandleCommand`, 2/16).
     `scope:Dispatch(name, text)` runs the scope's command `name` with
     `text` exactly as the client's slash handler would (same dispatcher,
     same frames, same failure reporting): `true` when it ran, `false` when
     the scope has no such command. A secret `text` or `name`, and a closed
     scope, raise at the caller. It works for bound and ordinary commands.
   - **AceConfigCmd's syntax** (every `BindOptions` user who knows Ace).
     `BindOptions(tree, name, { syntax = "path" })`, in the Options part.
     `/cmd group option value`: each word selects a child of the current
     group by key, without case and with `_` matching a space in the key
     (AceConfigCmd's rule), until a non-group is reached; the rest of the
     line is the value. Then: a group with nothing after it is listed (as
     `list path`); a `toggle` without a value flips (as `set path toggle`);
     an `execute` runs (with the `confirm` word rule of `exec`); any other
     value option prints `path = value` without a value and is set with one
     (as `set path value...`, same parsing and refusals). An empty line lists
     the root, or runs `options.onEmpty(context)` when given (Ace addons open
     their options window there). The five verbs stay available: they are
     the command's sub-commands, so `/cmd set a.b 1` keeps working and a root
     option keyed `get`, `set`, `reset`, `list` or `exec` is reached through
     the verbs (`/cmd set list on`). Resolution uses one `tree:Walk` per typed
     line with a visitor kept per binding (OptionsKit's walk allocates
     nothing) and then the one `DescribeOption` today's verbs make, so a
     typed line describes one option, never a group subtree. A group that a
     future OptionsKit marks inline for the command line is still a path
     step until OptionsKit reports that flag in its walk (ace3-gaps WP 1/2).
     `syntax = "verbs"` is the default, today's behaviour.
   - **The bound tree** (AceConfigCmd `GetChatCommandOptions`, 0/16).
     `scope:GetBoundTree(name)` returns the tree a command was bound to, or
     `nil`. Kept in a per-scope map created on the first bind and cleared by
     `Unregister` and `Close`.
   - **General tab completion** (AceTab-3.0, 1/16, Prat-3.0's five uses).
     The migration guide marks AceTab "not planned" without a technical
     reason; the hook it needs is the one CommandKit already installs.
     Verified in Blizzard's UI source (`Gethe/wow-ui-source`,
     `Interface/AddOns/Blizzard_ChatFrameBase/Shared/ChatFrameEditBox.lua`,
     `live` `297d7aa` line 444, `classic` `e5d9b3a` line 442, `classic_era`
     `4192ac6` line 442): `ChatEdit_CustomTabPressed(editBox)` is an empty
     global "left intentionally global ... to enable secure tab completion
     hooks in addons", and `ChatFrameEditBoxMixin:OnTabPressed` calls it
     through `securecall` only after `AutoCompleteEditBox_OnTabPressed`
     declined, skipping `SecureTabPressed` when it returns true. In the
     Completion part:
     `scope:RegisterCompletion(name, pattern, provider)` → `true`, or
     `nil, "full"` at `maxCompletionProviders`, or `nil, "taken"` when the
     scope already has `name`. `pattern` is a Lua pattern tested with
     `string.find` against the text before the word being completed
     (AceTab's "prematch"); `""` matches anywhere. `provider(partial,
     before, editBox)` returns an array of candidates, or `nil`. On Tab, when
     the cursor is at the end: the scope commands' own completion runs first
     (today's behaviour); otherwise every provider whose pattern matches is
     asked, in registration order, and their candidates are merged through
     today's filter (start of word without case, secrets skipped,
     `maxCompletions`), insertion, common prefix and listing. A provider that
     raises is reported through the host error handler and the others still
     run. `scope:UnregisterCompletion(name)` → `true`/`false`;
     `scope:IsCompletionRegistered(name)`; `Close` releases every provider of
     the scope. The tab chain is installed while any scope has completion
     enabled or a provider registered, and uninstalled as today when neither
     remains. Only chat edit boxes are covered (the client calls the hook
     from them alone); other edit boxes are not, because completing there
     needs the frame's own `OnTabPressed`, which a `HookScript` cannot stop,
     so the guide's row becomes "chat edit boxes: `RegisterCompletion`;
     other edit boxes: not planned (the client offers no hook there)".
     The client's own name auto-complete (`AutoCompleteEditBox_OnTabPressed`)
     runs before the hook and wins while its list is shown.
   Non-goals: honouring `cmdHidden`/`cmdInline`/`confirm` beyond today
   (WP 2); dynamic trees (WP 3); `Reopen` for CommandKit scopes (a separate
   small record would let ModuleKit keep `scope.Commands`); the live taken
   scan (kept by the owner's decision); a raising `GetBoundTree`.
3. Dependencies: core unchanged (registry API 2, schemaKit API 1; optional
   localeKit, clientKit, eventKit, lifecycleKit). `optionsKit` API 1 moves
   from the core's `optionalDependencies` to the Options part's
   `dependencies` (the part cannot work without it, and the embeds
   generator then brings it along). The Completion part has none beyond its
   core. Manifest:

   ```json
   "parts": {
     "Options": {
       "description": "Drive an OptionsKit tree from a slash command: the get, set, reset, list and exec verbs and AceConfigCmd's path syntax.",
       "revision": 1,
       "dependencies": { "optionsKit": { "api": 1 } }
     },
     "Completion": {
       "description": "Tab completion in chat edit boxes: the scopes' own commands and AceTab-style completion providers.",
       "revision": 1
     }
   }
   ```
4. Surface (additive apart from the split): core `CommandKit:GetCommands()`,
   `scope:GetCommands()`, `scope:SetPrefix(text)`, `scope:GetPrefix()`,
   `scope:Print(...)`, `scope:Printf(template, ...)`,
   `scope:Dispatch(name, text)`; forwarders `BindOptions`, `GetBoundTree`
   (Options), `EnableCompletion`, `DisableCompletion`,
   `RegisterCompletion`, `UnregisterCompletion`, `IsCompletionRegistered`
   (Completion); `BindOptions` option fields `syntax` (`"verbs"` or
   `"path"`) and `onEmpty` (function); package limit
   `maxCompletionProviders` (default 32, ceiling 256, `UNBOUNDED` refused:
   every Tab press walks the list). Scope fields, all absent until written:
   `_prefix`, `_bound`, `_completionProviders` (a count); the provider list
   lives in the shared `completion` state table, which keeps its revision-10
   field names so the part adopts it.
5. Ownership: providers and bound-tree entries belong to their scope and go
   with `Unregister`/`Close`; the tab chain belongs to the package as today.
   The parts keep their state inside the core's (`_state.parts.<Part>`, with
   `revision`); the highest part revision wins and upgrades in place.
   Upgrade from revision 10: the state gains `parts` and `helpers`; scopes,
   records and dispatchers are kept. A revision-10 `dispatch.tabPressed`
   keeps serving completion until a Completion part loads and replaces it,
   so an addon that enabled completion under revision 10 keeps it working
   across a core-only upgrade.
6. Performance and memory. Host bench, one run on 2026-11-15 (Lua 5.1.5,
   3 rounds), ratios against Ace3 from the same run:

   | Case | Before | Expected after |
   |---|---:|---:|
   | slashCommands register-unregister | 30.41× | unchanged (the taken scan) |
   | slashCommands dispatch-words | 2.14× | unchanged (one `rawget` for the prefix per written line only) |
   | slashCommands dispatch-subcommand | 2.97× | unchanged |
   | options cmd-set-range / toggle / select | 1.69× / 1.96× / 1.47× | unchanged in verb syntax |
   | new: the same typed line as AceConfigCmd (`/cmd g1 scale 1.25`) in path syntax | n/a | at most 2.0× (one allocation-free walk plus today's describe) |

   The new case needs a line in the `options` workload (text in
   the report). Completion runs only on a Tab press.
   Held memory (load-and-execute footprint, debug information kept):
   CommandKit 141,088 B today; AceConsole-3.0 10,483 B, AceConfigCmd-3.0
   32,779 B, AceTab-3.0 20,398 B (63,660 B together). Expected after:

   | Embedded | Expected | Ace3 it replaces | Ratio |
   |---|---:|---|---:|
   | core only (register, dispatch, print) | about 116 KB (−31 KB moved, +6 KB new) | AceConsole 10.5 KB | about 11× (today 13.5×) |
   | core + Options | about 147 KB | AceConsole + AceConfigCmd 43.3 KB | about 3.4× |
   | core + both parts | about 164 KB | all three, 63.7 KB | about 2.6× (today 2.2× without path syntax or providers) |

   The core-only figure is the one most addons pay; what stays above
   AceConsole is the parser, the schema arguments, sub-commands and the
   taken check, outside this record. Per object: a scope with a prefix
   +1 field; a provider entry about 100 B; a bound tree one map entry.
7. Tests: the split (core alone: every forwarder raises at the caller with
   the file to embed; the part loaded before and after another core
   revision; a part revision upgrade in place; the part loaded without its
   core raising the ADR 0001 message), the upgrade from revision 10 with
   completion enabled and a bound command (both keep working with and
   without the parts), all existing BindOptions and Completion specs moved
   to load the parts; `GetCommands` (both, sorted, fresh); prefix on every
   kind of line, `nil` clearing, argument errors; `scope:Print`/`Printf`
   outside a handler; `Dispatch` (ran, unknown name, closed scope, secret
   text, a raising handler reported not raised); path syntax for every kind
   (group listing, toggle flip and set, tristate, range, select by key and
   label, multiselect, color, input, execute with and without confirm),
   case and `_` matching, unknown word, verbs still reachable, a root option
   named like a verb, empty line with and without `onEmpty`, hidden and
   disabled options, `syntax` refusals; `GetBoundTree`; providers: pattern
   match and miss, merge order, filter and limit, one candidate, common
   prefix, listing with prefix, a raising provider, `"taken"`, `"full"`,
   unregister, release on `Close`, chain installed by a provider alone and
   uninstalled after the last, cursor not at end, secret text; limits
   `maxCompletionProviders`; lua_limits below the fail line.
8. Docs: API.md (*Loading*: the two parts; surface; a *Prefix and printing*
   section; *Dispatch from code*; `BindOptions` path syntax and `onEmpty`;
   *Tab completion*: providers and the client hook with the source
   reference; *Limits*; *Error behaviour*; *Embedded copies and upgrades*),
   INTERNALS.md (helpers, forwarders, part state, the walk visitor), README
   (migration table rows `IterateChatCommands`, `Print`, `HandleCommand`,
   `GetChatCommandOptions`, AceConfigCmd syntax, `RegisterTabCompletion`),
   CHANGELOG 0.3.0, tests/README, `src/.luarc.json` covering the parts, the
   client suite (a provider completing in a real chat edit box; path syntax
   `/cmd group option value`). For the shared files: the AceTab row of the
   migration guide, the embedding guide's parts table (generated), the bench
   workload line.
9. Status: implemented 2026-11-15, 0.3.0, revision 11, 209 specs; core 117.5
   KB (140.5 KB before), Options part 40.1 KB (AceConfigCmd 32.8 KB),
   Completion part 19.3 KB (AceTab 20.4 KB). The core writes each part's
   functions, or a stub naming the file, onto the scope prototype; the path
   syntax keeps a per-binding index of the tree's paths, dropped when the tree
   changes shape (cmd-set-range-path 1.83x AceConfigCmd). It also adds
   `scope:Reopen()` for manual scopes (an addon scope is refused), so
   ModuleKit keeps a module's `scope.Commands` across enables. The main chunk
   is down to 169 locals.

**commandKit minimal core: schema-checked arguments become a part, so the core no longer needs SchemaKit; the shared helper blocks** — a change to facade `CommandKit`

Measured 2026-11-16 on host Lua 5.1.5 (64-bit) with the shared fake client,
debug information kept as the client keeps it, the string table pre-grown;
each file loaded after its dependencies in one process, resident bytes after
a full collection. KB is 1000 bytes. Ace3 is the pinned bench copy
(`5e2e0d3b`), loaded after LibStub and CallbackHandler.

1. Package `commandKit`, facade `CommandKit`, API generation 1, version
   0.4.0 (from 0.3.0), implementation revision 12 (from 11), record layout
   unchanged. New part `Arguments` (`src/parts/CommandKit-Arguments.lua`,
   `PART_REVISION = 1`). `Options` goes to part revision 2; `Completion`
   stays at 1.

2. Purpose: a core that holds what every slash command needs (register a
   name, run a handler with the typed words, print, close), with SchemaKit
   argument checking in a part, so an addon whose commands take plain words
   embeds neither the part nor SchemaKit.

   **What the core holds today** (116,896 B resident; 75,872 B of live
   prototypes in 110 top-level functions, 29,596 B of it debug information;
   15,040 B of data tables; constant strings 12,823 B, of which 3,285 B
   prose; error-raising instruction runs 2,520 B; transient while loading
   314,282 B):

   | Section | Prototypes | Share | Who needs it |
   |---|---:|---:|---|
   | "Logout close" header: `LogoutClose.*` 5,336 B and the revision 11 scope extras 7,192 B (no header of their own) | 12,528 B | 17% | addon scopes; extras: `Print`/`Printf`/prefix every user, `GetCommands`, `Dispatch`, `Reopen`, part stubs some |
   | Slash registration (5,568 B of it the taken check) | 10,792 B | 14% | every user (the taken check is kept by the owner's decision) |
   | Package public API (limits 2,512 B, scope options 2,792 B) | 9,728 B | 13% | every user |
   | Argument schemas | 7,264 B | 10% | commands that declare `arguments` |
   | Dispatch (`checkArguments` 1,608 B of it) | 7,112 B | 9% | every user; `checkArguments` only with `arguments` |
   | Command records (sub-commands, usage lines) | 6,776 B | 9% | every user with sub-commands or usage |
   | Parser (hyperlink-aware tokenizer) | 5,104 B | 7% | every user |
   | Context methods | 4,392 B | 6% | every user |
   | Scope methods | 3,960 B | 5% | every user |
   | Argument checks | 3,624 B | 5% | every user |
   | Output (`CaptureSink` 1,472 B of it) | 2,456 B | 3% | every user; `CaptureSink` tests |
   | Host access (`isSecret` with the ClientKit lookup 792 B) | 2,136 B | 3% | every user |

   Biggest functions: `compileSpec` 2,832 B, `registerCommand` 2,464,
   `compileArguments` 2,280, `compileSubcommands` 2,096, `runCommand`
   1,648, `usageWord` 1,616, `checkArguments` 1,608, `newCaptureSink`
   1,472, `Taken.anyAliasNames` 1,400, `validateLimitUpdate` 1,376. SchemaKit
   is used only by "Argument schemas", `checkArguments` and the Options part
   (through `helpers.SchemaKit`). Cold code that stays resident:
   `LogoutClose.arrangeInherited` (696 B), called once from the main chunk
   after an upgrade but kept alive as a field of `LogoutClose`. Validation by
   name 13,208 B (17.4%), error builders 2,440 B, secret checks 1,104 B,
   limits 1,136 B.

   **Ace3 counterpart, measured the same way:** AceConsole-3.0 10,759 B
   resident (6,640 B of prototypes). With AceConfigCmd (32,983 B) and AceTab
   (20,844 B) 64,586 B. The smallest CommandKit set today (Registry 32,306 +
   SchemaKit 82,746 + core 116,896 = 231,948 B) stands against LibStub +
   AceConsole (13,382 B), 17.3×.

   **The changes.**

   a. **`Arguments` part.** Moves "Argument schemas" (`isSchema`,
      `sealSchema`, `allOfType`, `coercionOf`, `coerce`, `joinValues`,
      `usageWord`, `compileArguments`, `describeFailure`,
      `SCHEMA_METATABLE_NAMES`, `NO_ARGUMENTS`, `BOOLEAN_WORDS`) and
      `checkArguments`, and the SchemaKit lookup. The core's `compileSpec`
      hands a spec's `arguments` to the part (`_state.parts.Arguments`, read
      at call time) and keeps `_mode = "none"` without it; `runCommand`
      already returns early for `"none"`, so dispatch gains no test. The
      part publishes `BOOLEAN_WORDS`, `joinValues` and `SchemaKit` into the
      helpers for the Options part. The scope option `maxPositions` stays a
      core option (read and stored at `CreateScope`/`ForAddon`, used by the
      part).
   b. **The core loads without SchemaKit.** `REQUIRED_SCHEMAKIT_API` and the
      load-time refusal leave the core; the part raises at load
      `MoltenCodes CommandKit part Arguments requires SchemaKit API 1 to be
      loaded first`.
   c. **Options part revision 2** declares the Arguments part (its verbs are
      registered with argument schemas) and reads `SchemaKit` from the
      helpers the Arguments part fills. A revision-1 Options part keeps
      working with the revision-12 core when the Arguments part is loaded,
      since it reads the same helper names.
   d. **Cold upgrade code out of the resident set.**
      `LogoutClose.arrangeInherited` becomes a main-chunk-only function, so
      it is freed after load.
   e. **Shared helper blocks** for every copy `tooling.shared.sync --list`
      names: `reportError` (line 689), `validateFacade` (781), `describeKey`
      (2889), `limits` (3075: `validateLimitUpdate`, `setLimits`'s loop and
      `getLimits`'s table become `validateLimitUpdate`, `applyLimitUpdate`
      and `copyLimits` over a `LIMIT_RULES` table), and `isSecret` (718),
      which `describeKey` and `limits` require earlier in the file. The
      `pins.json` opt-out for CommandKit's `isSecret` is removed: the
      ClientKit route answers what the shared probe answers (ClientKit's
      `IsSecret` asks the client's `issecretvalue`, `ClientKit.lua` lines
      740-749 and 886-891), so `state.clientKitLookup` and the optional
      `clientKit` dependency go. Measured cost of each block against the
      copy it replaces (prototype bytes, debug kept): `isSecret` 464 B
      against 792 (−328), `reportError` 496 against 424 (+72, and a raising
      error handler now falls back to `print` instead of propagating),
      `validateFacade` 448 against 392 (+56, same message), `describeKey`
      504 against 424 (+80), `limits` 3,296 B against 2,512 (+784). Net
      about +0.7 KB resident: the blocks buy one source per helper, not
      memory.
      Limit messages that change: `limits.maxCaptured` gets a ceiling of
      2147483647 (the shared rule needs one; every value accepted today
      stays accepted), so its refusal reads `CommandKit:SetLimits
      limits.maxCaptured must be an integer from 1 to 2147483647`; an
      unknown key's refusal gains `; it accepts maxCaptured, maxCompletions,
      maxEmotes, maxCompletionProviders`; a limits table with a metatable is
      no longer refused (the block reads it with `next` and `rawget`).
      Specs `Bootstrap_spec` (lines 186, 279), `Limits_spec` (148, 290, 298,
      305, 335) and `docs/API.md` line 549 follow.
   f. **A header for the scope extras** ("Scope extras", between "Logout
      close" and "Scope methods"), so the file's sections say what they
      hold.

   Considered and kept in the core, with the numbers: sub-commands and usage
   generation (about 4,800 B; most multi-verb commands use them, and a part
   costs about 1.5 KB of its own); `CaptureSink` (1,728 B with its facade
   method, about 2.5 KB resident; a part would save about 1 KB net);
   `Print`, `Printf` and the prefix (AceConsole's most used calls); the
   taken check (owner's decision, 5,568 B); logout close (5,336 B; every
   addon scope relies on it; it belongs to the cross-Kit "logout close"
   family a future shared block could serve). Rejected: shorter error prose
   (3.3 KB in the core, matched by specs).

3. Dependencies: core Registry API 2 only; optional `localeKit`,
   `eventKit`, `lifecycleKit` (`clientKit` removed, point 2e). Manifest:

   ```json
   "dependencies": { "registry": { "api": 2 } },
   "parts": {
     "Arguments": {
       "description": "Schema-checked command arguments: SchemaKit schemas per position or one array, coercion of the typed words, generated usage and refusals.",
       "revision": 1,
       "dependencies": { "schemaKit": { "api": 1 } }
     },
     "Options": {
       "description": "Drive an OptionsKit tree from a slash command: the get, set, reset, list and exec verbs and AceConfigCmd's path syntax.",
       "revision": 2,
       "dependencies": { "optionsKit": { "api": 1 } },
       "parts": ["Arguments"]
     },
     "Completion": { "description": "(unchanged)", "revision": 1 }
   }
   ```

4. Surface: unchanged. What changes for users:
   - A spec (or sub-command spec) with `arguments` registered without the
     part raises at the caller's line: `CommandKit.Scope:Register
     spec.arguments needs CommandKit's Arguments part, which is not loaded:
     add commandKit\parts\CommandKit-Arguments.lua to your embeds.xml` (the
     path in the label as today, e.g. `spec.subcommands.a.arguments`).
   - Embedding: the minimum footprint becomes 2 files
     (`registry/Registry.lua`, `commandKit/CommandKit.lua`); an addon with
     argument schemas adds SchemaKit and the part (the embeds generator does
     it); `BindOptions` brings the Arguments part through the Options part's
     dependency.
   - The limit messages of point 2e. Everything else unchanged.

5. Ownership and in-place upgrade from revision 11. Records, scopes, frames
   and the slash dispatchers are kept; the state loses `clientKitLookup`.
   Revision 11 was the last core with arguments inside, so a revision-11
   addon may share a session with a revision-12 core and no Arguments part:
   - Before its commit the revision-12 core keeps revision 11's
     `helpers.registerCommand` and `dispatch.slash` in
     `state.legacyArguments` (main chunk, only when `previousRevision ==
     11`).
   - A record compiled by revision 11 with `_mode` other than `"none"` keeps
     its schemas; while the Arguments part is not loaded, `slashDispatch`
     hands such a record's line to revision 11's `dispatch.slash`, on the
     branch that already tests `_mode` (no cost for `"none"` records).
   - A `Register` the core would refuse only because the part is absent is
     handed to the kept `registerCommand`; with nothing kept it raises as in
     point 4. This also keeps a revision-1 Options part working.
   - When the Arguments part loads, it adopts revision-11 records as they
     are (same fields) and `state.legacyArguments` is dropped.
   The part keeps its state in `_state.parts.Arguments` with its revision;
   the highest part revision wins and upgrades in place. A part loaded
   without its core raises the ADR 0001 message.

6. Performance and memory. Priced from the measured prototypes (resident =
   prototypes × 1.342, this core's measured ratio of resident-minus-data to
   prototypes, plus the data tables each takes); measured again in phase 2.

   | Change | Expected effect on the core | Part file (resident) |
   |---|---:|---:|
   | a, b. Arguments part, no SchemaKit in the core | −12.8 KB (8,872 B of prototypes, 912 B of tables), +0.4 KB for the hand-over and the stub | about 14.5 KB |
   | d. `arrangeInherited` freed after load | −0.9 KB | |
   | e. shared helper blocks, `clientKitLookup` gone | +0.7 KB | |
   | **core** | **116.9 KB → about 104 KB (−11%)** | |

   | Embedded | Today | Expected | Ace3 it replaces | Ratio |
   |---|---:|---:|---|---:|
   | core alone | 116.9 KB | about 104 KB | AceConsole 10.8 KB | 9.7× (today 10.9×) |
   | smallest set (Registry + core) | 231.9 KB (with SchemaKit) | about 137 KB | LibStub + AceConsole 13.4 KB | 10.2× (today 17.3×) |
   | Registry + SchemaKit + core + Arguments | 231.9 KB | about 234 KB | LibStub + AceConsole 13.4 KB | 17.4× |
   | core + all three parts | 176.3 KB (+ SchemaKit, OptionsKit) | about 178 KB | AceConsole + AceConfigCmd + AceTab 64.6 KB | 2.8× (today 2.7×) |

   The gain for most addons is SchemaKit: 82.7 KB not loaded when nothing
   else in the addon needs it (SettingsKit and OptionsKit do). What stays
   above AceConsole is the documented behaviour: the hyperlink-aware
   tokenizer, the taken check, sub-commands and usage, nested dispatch
   frames, logout close for addon scopes, scope limits, refusals at the
   caller's line and secret refusals. Hot paths: dispatch unchanged (the
   `"none"` branch exists today); bench cases `slashCommands` and `options`
   expected unchanged within noise, measured against Ace3 in one run in
   phase 2. Per object: unchanged.

7. Tests: core alone loads with Registry only (no SchemaKit) and serves
   `Register`, dispatch, sub-commands, usage, `Print`; `arguments` without
   the part raises at the caller with the file to add (top level and in a
   sub-command); every existing argument spec loads the part; the part
   without SchemaKit raises at load; the part loaded before and after
   another core revision; Options revision 2 with and without its Arguments
   dependency, Options revision 1 with the revision-12 core; in-place
   upgrade from revision 11 (a byte copy of today's file as fixture) with a
   command with arguments registered before: it dispatches with and
   without the part, and a `Register` with arguments after the upgrade is
   handed to revision 11 when the part is absent; `arrangeInherited` not
   resident after load; the shared blocks (`tooling.shared.sync --check`,
   `pins.json` entry removed) and the changed limit messages; allocation
   specs unchanged; opt into `KitConformance` (manifest, limits with
   `maxCaptured` default 256 ceiling 2147483647 unbounded allowed,
   `maxCompletions` 32/256, `maxEmotes` 1024/16384,
   `maxCompletionProviders` 32/256, receivers, arguments, upgrade). Client
   suite: a command with argument schemas with the part embedded.

8. Docs: README (minimum footprint, the parts table with measured sizes,
   the migration table row for argument schemas), `docs/API.md` (*Loading*:
   three parts; *Arguments* names the part; *Limits*: `maxCaptured`'s
   ceiling; *Error behaviour*: the changed messages; *Embedded copies and
   upgrades*: the revision-11 hand-over; the section skeleton of
   `docs/CONTRIBUTING.md`), `docs/INTERNALS.md` (the hand-over, the helpers
   the Arguments part fills), CHANGELOG 0.4.0, `tests/README.md`,
   `src/.luarc.json` covering the part, the client suite's `EXPECTED.md`.
   Shared files (text with the code): the embedding guide's parts table and
   dependency rows (generated; `commandKit` no longer needs `schemaKit`),
   `tooling/shared/pins.json` (the CommandKit `isSecret` opt-out removed).

9. Status: implemented 2026-11-18, 0.4.0, revision 12, 242 specs (Arguments
   part revision 1, Options part revision 2, Completion part revision 1).
   Integration (2026-11-18): the Arguments part's manifest dependency names
   SchemaKit's `["Apply"]` part (its default filling calls `schema:Apply`), as
   the schemaKit record reports; the test environment loads `SchemaKit-Apply`.

   Measured 2026-11-18 on host Lua 5.1.5 (64-bit), debug information kept,
   each file loaded after its dependencies in one process on the shared fake
   client, resident bytes after a full collection (the load-and-execute
   harness of the earlier memory work, without the pre-grown string table, so
   its baseline reads 120,746 B where point 2 reads 116,896 B):

   | | Revision 11 | Revision 12 |
   |---|---:|---:|
   | core | 120,746 B | 113,230 B (−7,516 B, −6.2%) |
   | Arguments part | — | 12,085 B |
   | Options part | 40,196 B | 40,160 B |
   | Completion part | 19,263 B | 19,287 B |
   | smallest set (Registry + core; revision 11 with SchemaKit) | 236,550 B | 145,557 B (−38%) |
   | Registry + SchemaKit + core + Arguments | 236,550 B | 240,161 B (+1.5%) |

   The core's prototypes went from 75,872 B to 68,960 B. The core gained less
   than point 6 expected (about −12.8 KB, to about 104 KB). By prototype:
   the moved functions −8,216 B and `arrangeInherited` −696 B as priced, but
   the hand-over branches that stay resident (`registerCommand`,
   `runCommand`, `slashDispatch`) +776 B, and the shared `limits` block
   +1,384 B against everything it replaces (`setLimits` and `getLimits`
   lose their loops), where point 2e priced +784 B; and the resident bytes
   per prototype byte of the moved code came out near 1.09, not 1.342. To keep the hand-over small, `declaresArguments` lives in
   `state.legacyArguments` (built only by an upgrade over revision 11) rather
   than as a file-level function (−776 B resident).

   Host bench (`python3 -m tooling.bench.run --workload slashCommands
   --workload options`, revision 11 and revision 12 in separate runs on one
   machine), ratios against Ace3: `dispatch-subcommand` 2.86× → 2.87×,
   `dispatch-words` 2.15× → 2.05×, `register-unregister` 29.97× → 29.29×,
   `cmd-set-range` 1.76× → 1.71×, `cmd-refused` 1.24× → 1.19×: within noise.
   The dispatch path reads the part's `check` with plain indexing only for a
   record whose `_mode` is not `"none"`.

   Choices where the record left one open, and deviations:
   - The Arguments part refuses to load over a core older than revision 12
     (`... requires CommandKit revision 12 or later to be loaded first`): an
     older core compiles arguments itself and never asks a part.
   - Point 2e did not list one more `SetLimits` message the shared block
     changes: a secret value is refused as `... must not be a secret value`
     instead of with the type message. Documented in `docs/API.md` and the
     CHANGELOG.
   - `Conformance_spec.lua` runs on an environment of its own (Registry and
     the core; SchemaKit loaded for the committed revision 11 in the upgrade
     case) and lists no secret arguments: every facade argument is tested for
     its type before anything compares it, and the suite's secret value is a
     table (ADR 0002). Secret strings stay covered by `SecretValues_spec.lua`.
   - `tooling/bench/lua/workloads/SlashCommands.lua` and `Options.lua` load
     the Arguments part (both declare argument schemas).
   - Other owners' code that must follow (not changed here):
     `examples/embeds.xml`, `examples/.luarc.json`, `examples/README.md` and
     the embedding guide's quote of `embeds.xml` (the core before SchemaKit,
     then the Arguments part); LifecycleKit's test environment, which loads
     SchemaKit for CommandKit and must drop it from its module chain.
