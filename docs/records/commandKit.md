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

