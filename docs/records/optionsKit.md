# optionsKit records

Moved from `docs/ROADMAP.md` (Package C planned Kits — the nine points).

## optionsKit

**optionsKit** — facade `OptionsKit`

1. Package `optionsKit`, facade `OptionsKit`, API generation 1.
2. Purpose: a typed, validated, introspectable options tree with no
   renderer: what an addon exposes as configurable, how each option is
   read and written, and what a UI or a command line needs to present it.
   Non-goals: widgets, a dialog, slash parsing (commandKit binds to it).
3. Dependencies: registry API 2, schemaKit API 1 (value validation),
   signalKit API 1 (change signals); settingsKit API 1 optional through
   `Registry:Find` (binding an option to a database path).
4. Surface: `OptionsKit:Define(addonName, tree)` where the tree is nested
   groups of typed options: `group`, `toggle`, `range { min, max, step }`,
   `select { values }`, `multiselect { values }`, `input { pattern,
   multiline }`, `color { alpha }`, `keybinding`, `execute { func }`,
   `header`, `description`; each with `name`, `desc`, `order`, `get`/`set`
   or `bind = "profile.path.to.value"` (settingsKit), `disabled`/`hidden`
   as booleans or predicates, `validate`; `options:Get(path)`,
   `options:Set(path, value)` (validated through the option's schema at the
   caller's line, then the setter, then a change signal), `options:Walk(fn)`
   in order, `options:Describe()` (plain table for renderers, allocating),
   `options:OnChange(callback)`, `options:Reset(path)` to the bound default;
   `OptionsKit:Get(addonName)`.
5. Ownership: one tree per addon name in package state; the tree is sealed
   at `Define`; upgrades keep trees.
6. Performance: `Get` and `Set` are path lookups on a pre-indexed map (no
   string splitting per call after Define); `Walk` allocates nothing;
   `Describe` allocates by design.
7. Tests: every option type validated, bind to settingsKit and to
   getters, order, disabled/hidden predicates, change signal, Reset,
   unknown path errors at the caller, Describe shape, Walk order, upgrade,
   manifest, error levels.
8. Docs: README, API.md with a complete options tree example, CHANGELOG;
   a note on how a renderer (widgetKit, package E) consumes Describe.
9. Status: implemented (package C3, 0.1.0); deviations recorded in
   `packages/optionsKit/docs/API.md`.

Moved from `docs/ROADMAP.md` (Package O — memory, performance and ease of use (decisions 18 and 19)).

## optionsKit smaller records, labels on failure, cheaper ProfileOptions

**optionsKit smaller records, labels on failure, cheaper `ProfileOptions`** — an internal change to facade `OptionsKit`

1. Package `optionsKit`, facade `OptionsKit`, API generation 1 (no surface
   change), version 0.6.2 (from 0.6.1), implementation revision 13 (from
   12), record layout bump.
2. Purpose: less memory per option and less work per `ProfileOptions` call.
   a. **Records of at most 8 hash fields** for the common option (name,
      description, get and set, or bind): `_depth` and `_path` derived from
      the parent chain when needed (`Walk`, info, error messages; `Walk`
      carries them down instead of recomputing), `_bind` rebuilt from scope
      and keys on the failure path, `_bindCount` replaced by `#_bindKeys`,
      `_order` and `_hints` stored only when not the default (read as
      `DEFAULT_ORDER` and `NO_HINTS`), the constructor listing at most 8
      fields so Lua sizes an 8-slot hash.
   b. **Labels built only on failure**: `buildOption` and its checks receive
      the parent label and the key and build `label .. ".args." .. key` (and
      `.validate`, `.values`, …) only in the branch that raises. Messages and
      levels unchanged. `Tree:Set` checks with `Check` and builds its
      `Assert` label only on failure.
   c. **`ProfileOptions`**: SettingsKit found through the Registry once and
      kept (a found implementation is stable per package and API; a miss is
      looked up again), and `validateProfileDatabase` skipped when the
      database is already the cache key. With SettingsKit's `databaseIndex`
      no longer probing (settingsKit record, 2b), each remaining `db[method]`
      probe is a plain method lookup.
   Non-goals: lazy records built on first use (memory.md fix 7 main form: an
   author mutating the tree between `Define` and first use would see the
   change), positional records.
3. Dependencies: unchanged (registry API 2, schemaKit API 1, signalKit API 1,
   settingsKit API 1 optional).
4. Surface: none. `Describe`, `Walk`, info tables and every message unchanged.
5. Ownership: records stay immutable after `Define`. In-place upgrade from
   revision 12: records of trees defined before keep their fields; the
   accessors read both layouts (a stored `_path`/`_depth`/`_bindCount` is
   used when present), so no record migration is needed.
6. Performance and memory: about −320 B per option (721 to 401 B per record,
   estimate from measured table sizing); −9% of `Define`'s allocation for the
   `args` label alone (measured), more with the other labels (estimate);
   define-50 time stays below AceConfigRegistry's (0.88x today).
   profile-options-build 6.2x to 4.6x (430 to 290 instructions, measured,
   prototype G) and toward 60 to 100 instructions with the cache-hit skip and
   the kept lookup (estimate); cmd-set-range, toggle, select, refused 10 to
   20% faster with CommandKit's kept lookup (measured, prototype H).
7. Tests: record sizes (8 hash slots for get/set and bind options with a
   description), every Define message unchanged and at the caller's line
   (existing ErrorLevels specs), no label built on success (allocation
   spec), `Walk` and info paths and depths, a bind error naming the bind
   path, `ProfileOptions` on a cache hit asking no `db[method]` and no
   Registry lookup, SettingsKit registered after the first call, the upgrade
   from revision 12 with a tree defined before it.
8. Docs: `docs/INTERNALS.md` (record fields, the derived ones),
   CHANGELOG, `tests/README.md`, README performance note. API.md unchanged
   except its *Performance* notes.
9. Status: implemented 2026-11-15 under core decision 18, 0.6.2, revision 13,
   208 specs. Recorded deviations: `desc`, `order`, `disabled` and `hidden`
   live in the hints table, collected in the unknown-field walk, so a value
   option keeps 8 fields with an order too; SettingsKit is still found on
   every `ProfileOptions` call, because a call must refuse when SettingsKit is
   gone from the Registry, and only the method probes of a database that
   already has a group are skipped. Measured on host Lua 5.1: 589 B held per
   option with a name, description, getter and setter (revision 12: 806 B), a
   20-option tree 18.7 KB (20.8 KB); against Ace3 in the same runs, define-50
   0.92x to 0.78x, profile-options-build 6.4x to 2.0x, cmd-refused 1.34x to
   1.18x.

Moved from `docs/ROADMAP.md` (Package O — memory, performance and ease of use (decisions 18 and 19)).

## optionsKit option fields, model side

**optionsKit option fields, model side** — a change to facade `OptionsKit`

1. Package `optionsKit`, facade `OptionsKit`, API generation 1 (additive),
   version 0.7.0 (from 0.6.2), implementation revision 14 (from 13). Record
   layout unchanged; new keys only inside `_hints`.

2. Purpose: accept, check and describe every field an AceConfig-3.0 option
   may carry that has an interface to honour it, so an Ace3 table ports
   without losing presentation and a renderer (WidgetKit, PanelKit,
   CommandKit) has the model it needs. Measured use in the Ace3 corpus:
   `desc` 15/16 (already accepted), `width` 12/16, `confirm` 9/16 (3/16 on
   value options), `arg` 9/16, function `name` 9/16, `bigStep`/`softMin`/
   `softMax` 8/16 and 6/16 (already accepted and described; nothing changes
   for them), `handler` 6/16, method-name `set`/`get` 4/16 and 3/16, `image`
   4/16, `plugins` 2/16, per-interface flags 0 to 2/16. Method names follow
   ADR 0003. Rendering is not in this record: it is WidgetKit's and
   CommandKit's later work, on top of this model.

   a. **Fields accepted**, each checked at `Define` with its own message at
      the caller's line, as today (`OptionsKit:Define tree.args.x.width must
      be "normal", "half", "double", "full", a positive number or a
      function`):

      | Field | Kinds | Accepted values |
      |---|---|---|
      | `name` | all | string, or `fun(info): string` (resolved at `Describe`) |
      | `order` | all | number, function or method name returning a number (resolved at `Describe`) |
      | `descStyle` | all | `"inline"` or `"tooltip"` |
      | `width` | all but `group` | `"normal"`, `"half"`, `"double"`, `"full"`, a positive number, or a function returning one of those |
      | `relWidth` | all but `group` | number, `0 < relWidth <= 1` |
      | `confirm` | all (a group's is inherited) | boolean, the question as a string, or `fun(info, value): string\|boolean` |
      | `confirmText` | all | string |
      | `arg` | all | any non-secret value, kept by reference |
      | `handler` | all (inherited) | table |
      | `get`, `set` | value kinds, and `group` (inherited) | function, method name, or `false` (stops inheritance) |
      | `validate` | value kinds, and `group` (inherited) | function, method name, or `false` |
      | `func` | `execute`, and `group` (inherited) | function, method name, or `false` |
      | `disabled`, `hidden` | all | as today, plus a method name |
      | `guiHidden`, `dialogHidden`, `cmdHidden` | all | boolean, function or method name |
      | `guiInline`, `dialogInline`, `cmdInline` | `group` | boolean |
      | `plugins` | `group` | `{ [pluginName] = { [key] = option } }` |
      | `icon` | all | texture path, file ID, or a function returning one |
      | `iconCoords` | all | array of 4 or 8 numbers, function or method name |
      | `image` | `description`, `execute`, `toggle` | texture path, file ID, or a function returning one, optionally with a width and a height |
      | `imageCoords` | `description`, `execute`, `toggle` | as `iconCoords` |
      | `imageWidth`, `imageHeight` | `description`, `execute` | positive number |
      | `tooltipHyperlink` | all | string, or a function returning one |
      | `dialogControl`, `control` | all but `group` | non-empty string (a widget type name) |
      | `itemControl` | `select` | non-empty string |
      | `style` | `select` | `"dropdown"` or `"radio"` |
      | `tristate` | `multiselect` (as on `toggle`) | boolean |
      | `multiline` | `input` | boolean or a positive integer (a line count) |
      | `fontSize` | `description` | as today, or a function returning one of the three |
      | `values`, `sorting` | `select`, `multiselect` | as today, plus a method name; `sorting` also a function |

      `hasAlpha` stays a boolean: it shapes the schema, which is fixed at
      `Define`. `dropdownHidden`, `dropdownInline` and `dropdownControl`
      stay refused: Ace3 itself has no dropdown interface that reads them.

   b. **Method names (ADR 0003).** A string in a field that accepts a
      function names a method of the handler in force, except where a string
      is the value itself: `name`, `desc`, `usage`, `width`, `image`, `icon`,
      `fontSize`, `tooltipHyperlink` (Ace3's literal fields) and `confirm`,
      whose string has been the question since revision 1 (API 1 cannot
      change it; a confirm method is written as a function). The handler in
      force is the option's own `handler`, else the nearest ancestor's. At
      `Define` the method must exist on that handler, or the field is
      refused at the caller's line (`OptionsKit:Define tree.args.x.get names
      method "GetX", which the handler in force does not have`; without a
      handler: `... is a method name, but no handler is in force`). The name
      becomes one small closure over the handler and the name, built at
      `Define` and shared by every option of that `Define` with the same
      handler and name; it looks the method up on every call (late binding)
      and calls the method `name` on `handler` with `(handler, info, ...)`. A method removed after
      `Define` raises `OptionsKit (MyAddon) general.scale: handler method
      "GetX" is missing` when called. Because the closure is stored where
      the function would be (`_get`, `_set`, `_validate`, `_func`, `_values`,
      a hint), `Get`, `Set` and the predicates keep exactly today's function
      path: no type test is added to any hot path.

   c. **Inheritance, resolved at `Define`.** `get`, `set`, `validate` and
      `func` declared on a group apply to every option below it that does not
      declare its own (an own `bind` counts as its own accessor); the nearest
      declaration wins and `false` stops it, as in AceConfigDialog. The
      reference is copied into the option's record when it is built, so
      nothing is resolved per call. The group keeps its own declarations
      (`_get` and `_set` in the record slots a group leaves unused,
      `validate`, `func` and `handler` in its hints, never described) so
      record 2's `Replace` can resolve them for a new subtree. `handler` is
      resolved the same way. `confirm` is inherited too, but resolved when it
      is asked (`Describe`, `GetConfirmation`), so a group's `confirm` adds
      nothing to its children's records. `disabled` and `hidden` keep their
      documented rule (every ancestor applies).

   d. **Functions resolved at `Describe`.** `name`, `order`, `width`,
      `fontSize`, `image`, `imageCoords`, `icon`, `iconCoords`,
      `tooltipHyperlink` and `sorting` functions (and method closures) are
      called by `Describe`/`DescribeOption` with the option's `info`, before
      any sort, and their result is checked as `desc`'s is today (a wrong
      type raises at the caller of `Describe`: `OptionsKit.Tree:Describe
      width function of "frame.scale" returned no string or number`). An
      `image` function may return the image, a width and a height (Ace3's
      shape); the last two become `imageWidth`/`imageHeight`. Tables
      (`imageCoords`, `iconCoords`, a resolved `sorting`) are copied into the
      node. `Walk` keeps the order fixed at `Define`, where a function `name`
      sorts by key and a function `order` as `100`; `Describe` re-sorts a
      group's described children by (order, name, key) on the resolved plain
      values when any child has a function `name` or `order`, so no consumer
      code runs inside `table.sort`.

   e. **Per interface.** `tree:IsHidden(path, interface?)`,
      `tree:Describe(interface?)` and `tree:DescribeOption(path, interface?)`
      take `"dialog"` (WidgetKit, PanelKit; honours `guiHidden` and
      `dialogHidden`, and `guiInline`/`dialogInline` over `inline`) or `"cmd"`
      (CommandKit; `cmdHidden`, and `cmdInline`). In a description `hidden`
      and `inline` are the effective values for that interface; the
      per-interface fields themselves never appear in a node. Without an
      interface every answer is exactly today's.

   f. **Confirmation.** `tree:GetConfirmation(path, value?)` → the question
      to ask before `Set(path, value)` or `Execute(path)`, or `nil`: the
      option's `confirm`, else the nearest ancestor's; `true` gives
      `confirmText`, else the resolved `name`, then `" - "` and the resolved
      `desc` when there is one (AceConfigDialog's text); a string is the
      question; a function is called with `(info, value)` and its string is
      the question, `true` gives the text above, anything else (a secret
      that is not a string included) means no question. In `Describe`,
      `confirm` is the effective value, `true` for a function. `Set` and
      `Execute` still never ask.

   g. **`info`.** `info.arg` (the option's own `arg`) and `info.handler` (the
      handler in force) are set when the option's `info` is built on first
      use; an option without them gets neither key. Ace3's `info.option`,
      `info.options`, `info.appName` and `info.uiType` are not provided
      (OptionsKit keeps no copy of the source table and does not know which
      interface called); BridgeKit's wrappers keep providing them for
      converted tables.

   h. **`plugins`** are merged into the group's `args` at `Define`; plugin
      names do not appear in paths. A key that two of them define, or that
      also appears in `args`, is refused at the caller (`OptionsKit:Define
      tree.args.x.plugins.Masque.skin collides with args.skin`), unlike
      Ace3, where a plugin silently wins. BridgeKit keeps Ace3's rule for
      converted tables.

   i. **`OptionsKit:GetFields(kind)`** → a fresh table: every field name the
      kind accepts, mapped to a fresh set of its accepted forms (`string`,
      `number`, `boolean`, `table`, `function`, `method`, `any`). It allocates
      by design and is meant for converters, called once per conversion.
      Unknown or non-string `kind` raises at the caller.

   j. **Binding into SettingsKit namespaces and the new scopes.** SettingsKit
      revision 15 adds AceDB-layout namespaces (its Namespaces part:
      `db:RegisterNamespace`, `db:GetNamespace`, each child a full database)
      and the scopes `race`, `factionrealm`, `factionrealmregion` and
      `locale`. OptionsKit follows in two ways:
      - `bind` accepts the four scopes. Availability is checked as for
        every scope today (`rawget(db, scope)` must be a table), so a
        database that does not declare one, or a SettingsKit before
        revision 15, refuses the bind at the caller with today's message.
      - `bind = "ns:<name>.<scope>.<key>[...]"` reaches namespace `<name>`
        of `options.db` (`ns:Bars.profile.scale`). `<name>` is an
        identifier, like every other segment. At `Define` the namespace is
        asked once with `db:GetNamespace(name)` (the method must exist and
        answer a table with `OnChange` and `Validate`, the shape
        `options.db` is held to), and the scope is checked on the child.
        The child database is kept in the bind keys array under key `0`,
        outside its array part, so `#keys` is unchanged and the record
        keeps its 8 slots. `Get`, `Set`, `Validate`, `Reset`, the read-only
        rule and `Describe` then use the child exactly as they use
        `options.db`; `rawget(child, scope)` is read per call, so a profile
        switch the parent cascades is seen at once. Refusals at the caller:
        `... bind "ns:Bars.profile.x" needs options.db with namespaces
        (SettingsKit revision 15 or later)`, `... namespace "Bars" is not
        registered in options.db`. A namespace registered after `Define` is
        reached by defining again (or, with record 2's part, `NotifyChange`).
      - A child database passed directly as `options.db` already works: it
        is a full database.
      Describe reports `bind` as written. Nothing changes for binds without
      `ns:`.

   Non-goals: rendering any field (WidgetKit, CommandKit); `hasAlpha` as a
   function; the `dropdown*` fields; Ace3's string `confirm` as a method
   name; `info.uiType`; a published `FIELDS` table (correction 3);
   `validate` on `execute`.

3. Dependencies: unchanged (registry API 2, schemaKit API 1, signalKit API
   1, settingsKit API 1 optional). No client function is added. `ns:` binds
   and the four new scopes need SettingsKit revision 15 at runtime (found
   through the database's own methods, not a version test); this record's
   2j lands after SettingsKit's revision 15 record, and its surface
   (`GetNamespace` answering a child database or `nil`) is taken from that
   record as announced and checked again against its code before
   implementation.

4. Surface:
   - Facade: `GetFields(kind)`.
   - Tree: `GetConfirmation(path, value?)`; `IsHidden(path, interface?)`,
     `Describe(interface?)`, `DescribeOption(path, interface?)` gain the
     optional argument (`OptionsKit.Tree:IsHidden interface must be "dialog"
     or "cmd"`, also for a secret).
   - `Define` accepts the fields of 2a; every existing message and level is
     unchanged.
   - Description nodes gain the fields of 2a as described in 2d and 2e;
     `arg`, `handler` and the per-interface flags never appear; functions
     never appear.
   - Errors added: the field checks of 2a, the method checks of 2b, the
     plugin collision of 2h, the result checks of 2d, the missing method at
     call time.

5. Ownership and memory rules:
   - Every new field is kept in the record's `_hints` table, which an option
     that sets no hint does not have (revision 13). An option that uses none
     of the new fields gets a record with exactly today's fields: 8 hash
     slots for a value option with get and set or bind, `_hints` absent
     without hints. The fields that must not reach a description (`arg`,
     `handler`, a group's `validate` and `func`) are listed once in a
     file-level set `Describe` skips.
   - An option that inherits a `validate` pays what an option with its own
     pays today (the ninth field); inherited `get`, `set` and `func` reuse
     slots every such record already has.
   - Method closures are made at `Define` only for fields written as method
     names and shared per handler and name within one `Define`.
   - Acceptance tables are shared, not merged per kind: one table for the
     fields every kind accepts, one per kind for the kind's own, and one
     field-to-forms table that the generic checker and `GetFields` read. The
     existing per-kind hint sets read the shared common set instead of
     copying it, so the resident tables grow by the new entries only (about
     2 KB).
   - Records stay immutable after `Define` (except `_info`). In-place upgrade
     from revision 13: no tree or record migration. Old records have no new
     hint keys and no function `_name`, which every new reader treats as
     today's case; trees defined before the upgrade answer `GetConfirmation`,
     `IsHidden(path, interface)` and `Describe(interface)` from what they
     have. Old method-free trees keep their records as they are.
   - New helpers go inside `do` blocks; OptionsKit's main chunk stays at or
     below 172 locals (169 today).

6. Performance and memory (host Lua, bench `options` workload, against
   AceConfigRegistry-3.0 in the same run; expected unless marked measured):

   | Case | Today | Expected |
   |---|---|---|
   | retained per option, toggle name/get/set | 477 B (measured) | 477 B: no change |
   | the same with `desc` | 614 B (measured) | 614 B |
   | range name/desc/min/max/bind | 843 B (measured) | 843 B |
   | an option with `width = "full"` and no other hint | 477 B | about +120 B (its hints table), only for that option |
   | `define-50`, `define-200` | bench ratio of the run | within 3% (the field loop does the same number of lookups for an option without new fields) |
   | `tree-get`, `tree-set` | bench ratio of the run | unchanged (no instruction added on the function path) |
   | `Describe` of the bench tree | bench of the run | within 3%; the new work runs only for hint keys that are present |
   | method-name `get` vs function `get` | — | one closure call and one table read more |
   | OptionsKit resident after load | 128.5 KB (measured) | +17 to +25 KB, budget 25 KB, measured before release |
   | against AceConfigRegistry + AceDBOptions (43.7 KB) | 2.9x | about 3.4x |

   The resident growth is code every addon that embeds OptionsKit loads.
   A part for the Ace3-style conveniences (handler, method names, plugins,
   per-interface flags, `GetFields`) was weighed: about 250 lines, 10 KB,
   against the core hooks and part scaffolding it would need (about 4 KB)
   and a Define that refuses an accepted field until a part is embedded.
   The net 6 KB does not pay for that, so these stay in the core. The larger
   lever is outside this record (see the report).

7. Tests (each fix or addition failing first where it changes behaviour):
   - every field of 2a: accepted with each accepted form, refused with each
     wrong form, secret refused before any comparison, message and level at
     the caller (ErrorLevels), unknown on a kind that does not take it;
   - records: 8 fields and no `_hints` for options without hints (the
     existing `Records_spec` cases), no new keys for options without new
     fields, retained bytes per option for the three shapes above unchanged
     (an allocation spec over 500 options);
   - method names: resolved through own and inherited handlers, refused when
     the method is missing at `Define` or no handler is in force, late
     binding (a replaced method is called), a missing method at call time,
     closure shared per handler and name, every field that accepts one
     (`get`, `set`, `validate`, `func`, `disabled`, `hidden`, the three
     per-interface flags, `values`, `sorting`, `order`, `iconCoords`,
     `imageCoords`), literal-string fields never treated as names, `confirm`
     string stays the question;
   - inheritance: nearest wins, `false` stops it, own `bind` beats inherited
     accessors, a value option with no accessor after inheritance refused as
     today, `validate` inherited, `func` inherited, `confirm` inherited and
     overridden by `false`;
   - `Describe`: resolved `name`, `order`, `width`, `fontSize`, `image`
     (with width and height returns), coordinates copied, `sorting`
     function checked, re-sort with function names and orders while `Walk`
     keeps the `Define` order, wrong result types raise at the caller of
     `Describe`/`DescribeOption`, no function and no `arg`/`handler` in any
     node;
   - per interface: `IsHidden` and `Describe` with `"dialog"` and `"cmd"`,
     ancestors' per-interface flags, inline overrides, invalid interface;
   - `GetConfirmation` for every form, inherited, `confirmText`, the
     name-and-desc default, a secret answer;
   - `info.arg` and `info.handler`, and their absence;
   - `plugins` merge and both collision refusals;
   - `GetFields` for every kind, fresh tables, unknown kind;
   - binds: each new scope accepted when the database declares it and
     refused when not; `ns:` binds through a namespace stand-in (Get, Set,
     Validate, Reset, read-only, Describe, a profile switch seen), the record
     still 8 fields, `#keys` unchanged, refusals without `GetNamespace` and
     for an unregistered namespace, and against the real SettingsKit 15 when
     its Namespaces part is present (`SettingsKitIntegration_spec`);
   - allocation: `Get`, `Set`, `IsHidden(path)` and `IsHidden(path,
     interface)` allocate nothing (`Allocation_spec`);
   - in-place upgrade from revision 13 with a tree defined before it.
   Client suite (`tests/client/MoltenCodesTest_OptionsKit/`, never run here):
   a tree using every new field defines and describes; `GetConfirmation`
   answers.

8. Docs: `docs/API.md` (the field tables, *Fields every option accepts*,
   method names, inheritance, `info`, `Describe` fields, per-interface
   answers, `GetConfirmation`, `GetFields`, *Deviations*: the "Not carried
   over" item shrinks to `hasAlpha` functions, `dropdown*` and the string
   `confirm`; the revision line, which still says 12), `docs/INTERNALS.md`
   (hint keys, method closures, inherited declarations on groups, the
   acceptance tables), README (the migration table rows for these fields),
   CHANGELOG 0.7.0, `tests/README.md`, the client suite's `EXPECTED.md`.
   `docs/MIGRATING_FROM_ACE3.md` rows (method names, inheritance, `width`,
   `arg`, function `name`, confirm on values, per-interface flags) are
   shared: their text is supplied with the code.

9. Status: implemented 2026-11-15 together with the next record as optionsKit
   0.8.0, revision 15 (revision 14 never released alone), 270 specs.
   `ProfileOptions` moved in the same release into the Profiles part
   (`parts/OptionsKit-Profiles.lua`), API and errors unchanged. Per-option
   memory is unchanged (477 B a toggle, 614 B with `desc`, 843 B a bound
   range); the core holds 155.6 KB against 130.1 KB before (budget overrun:
   the new fields cost about 60 KB against the 29 KB estimated), the Profiles
   part 35.4 KB, the Dynamic part 16.8 KB. `OptionsKit:IsPartLoaded(name)` was
   added, since the core installs stubs for part members.

Moved from `docs/ROADMAP.md` (Package O — memory, performance and ease of use (decisions 18 and 19)).

## optionsKit dynamic trees

**optionsKit dynamic trees** — a change to facade `OptionsKit`, with a new part `Dynamic`

1. Package `optionsKit`, facade `OptionsKit`, API generation 1 (additive),
   version 0.8.0 (from 0.7.0), implementation revision 15 (from 14). New
   part `Dynamic` (`src/parts/OptionsKit-Dynamic.lua`, `PART_REVISION = 1`,
   manifest `parts.Dynamic` with no dependencies beyond the core). Tree
   layout 3 (from 2): the dirty state and the kept limits below.

2. Purpose: let an options tree change shape after `Define`, as AceConfig
   addons do: 14 of 16 corpus addons assign `args` at runtime (379 sites;
   2,353 more in ElvUI), 7/16 register a function as their options table,
   8/16 call `NotifyChange`. Today `Define` copies the tree and the only
   route is `Undefine` and `Define` again, which loses the handle and every
   listener.

   a. **Builder trees.** `OptionsKit:Define(addonName, builder, options?)`
      accepts `fun(addonName): table` in place of the tree. The builder is
      called at `Define` and again on every rebuild. It needs the part: a
      function without it raises at the caller (`OptionsKit:Define tree is a
      function, which needs OptionsKit's Dynamic part: add
      optionsKit\parts\OptionsKit-Dynamic.lua`).
   b. **`tree:NotifyChange()`** marks the tree dirty and returns; it never
      checks anything itself, so calling it from an event handler costs a
      field write. Calls before the next rebuild coalesce into that one
      rebuild. The rebuild runs at the first tree method that reads the
      structure (`Get`, `Set`, `Validate`, `Reset`, `Execute`, `IsDisabled`,
      `IsHidden`, `Walk`, `Describe`, `DescribeOption`, `GetConfirmation`,
      `Replace`, `Remove`). It calls the builder, or re-reads the table
      passed to `Define`, checks the result in full as `Define` does, with
      the tree's own limits and database, and swaps the structure in: same
      handle, same `OnChange` and structure listeners, the `info` table of
      every path that survives with the same kind, profile groups kept
      attached when they survive, attached when new, detached when gone.
      The dirty mark lives in the field every method already tests
      (`_defined` is `true`, or a dirty sentinel), so a clean tree pays
      nothing on any call.
   c. **A table passed to `Define`** is kept by a weak reference (one
      weak-valued map in the package state), so a tree whose table the
      addon dropped keeps nothing alive. `NotifyChange` on such a tree, or
      on a tree defined before revision 15, raises at the caller
      (`OptionsKit.Tree:NotifyChange has no source to read again: keep the
      table passed to Define, or define the tree with a builder`).
   d. **`tree:Replace(path, option)`** checks one option (and its subtree)
      in the position `path` names and puts it there, creating it when the
      parent group exists and the key is new; **`tree:Remove(path)`** removes
      one and returns `true`, or `false` when the path does not exist. Both
      check only the subtree, against the tree's limits (the count is the
      tree's minus the old subtree plus the new), resolve inherited
      declarations from the ancestors' records (record 1, 2c), re-sort the
      parent's children, update the path index and rebuild the walk array.
      The root cannot be replaced or removed. A refused `Replace` changes
      nothing. A later `NotifyChange` rebuilds from the source, which wins
      over earlier `Replace` and `Remove` calls (documented).
   e. **`tree:OnStructureChanged(callback)`** → a SignalKit connection;
      `callback(tree, path)` runs when the structure has changed or will
      change: at once after `Replace`/`Remove` (`path` the option's), and
      at `NotifyChange` when the tree goes from clean to dirty (`path`
      `""`, before the rebuild, which the listener's own read triggers).
      The signal is created on first connect; `Undefine` disconnects it.
   f. **Errors after `NotifyChange`.** A builder that raises, returns no
      table, or a result the checks refuse does not raise in the method that
      triggered the rebuild: the previous structure is kept, the tree is
      clean again, and the error is reported once through `geterrorhandler()`
      as `OptionsKit (MyAddon) NotifyChange: <message>`, with the check's
      own label (`OptionsKit.Tree:NotifyChange tree.args.x.min must not be
      greater than max`) or the builder's own message and position. The
      triggering method then runs on the kept structure.
   g. **`OptionsKit:GetTrees()`** → a fresh sorted array of the addon names
      that have a tree (diagnostics; installed by the part).

   **What renderers must do** (the contract for WidgetKit's `RenderOptions`,
   PanelKit and CommandKit, implemented in their own later records on top of
   WidgetKit's split):
   1. Test `type(tree.OnStructureChanged) == "function"`; without it the
      tree is static (no part loaded) and nothing below applies.
   2. Connect once per rendering or binding; disconnect when it is released.
   3. In the listener, only schedule: rebuild at most once per frame
      (SchedulerKit's next frame when registered, otherwise on the next
      show). Never call `Describe` inside the listener: a burst of
      `NotifyChange` calls from one event would then rebuild once per call.
   4. On the scheduled rebuild, describe `path` again (`DescribeOption`,
      or `Describe` for `""`) and rebuild that part of the screen; a
      `DescribeOption` answer of `nil` means the option is gone. Keep the
      selected page or tab by path and fall back to the first child when
      the path no longer exists.
   5. Do not hold paths across a structure change without describing again:
      `Get`/`Set` on a removed path raise as for any unknown path.
   6. CommandKit: the path list `BindOptions` gathers with `Walk` (and its
      completion candidates) is rebuilt on the signal; `DescribeOption` per
      command already follows the structure.
   7. PanelKit: a page that is shown refreshes as in 4; a hidden page needs
      nothing (it looks the tree up when shown).

   Non-goals: re-reading a table nobody holds; per-key change detection
   (Replace/Remove are the fine-grained path); undo; capturing the
   `NotifyChange` call site; scheduling inside OptionsKit (the renderers own
   their frame timing, and OptionsKit takes no SchedulerKit dependency).

3. Dependencies: unchanged for the core. The part needs only the core
   (signalKit through the core). Client: `geterrorhandler` (see the
   evidence above), read at the time of a report and guarded with
   `type(...) == "function"`; without it the report is dropped and the
   structure is still kept.

4. Surface:
   - Core: `Define` accepts a builder when the part is loaded; the dirty
     check inside the existing tree validation; `Undefine` disconnects the
     structure signal; the tree keeps its `maxOptions`, `maxDepth` and
     `maxDynamicEntries` (three numbers per tree) and, for a builder, the
     builder.
   - Part: `Tree:NotifyChange()`, `Tree:Replace(path, option)`,
     `Tree:Remove(path)`, `Tree:OnStructureChanged(callback)`,
     `OptionsKit:GetTrees()`. Argument errors at the caller's line
     (`OptionsKit.Tree:Replace path must be a non-empty string`,
     `OptionsKit.Tree:Replace option.args.y.max must be a number`, ...).
   - No method changes meaning for a static tree.

5. Ownership:
   - The part keeps its state in `OptionsKit._state.parts.Dynamic` with its
     revision; the highest revision installs its methods on the shared
     `OptionsKit.Tree` prototype and `GetTrees` on the facade (OptionsKit's
     facade is not sealed); an equal or older copy returns at once, as
     AddonKit's parts do. The core calls the part through
     `state.parts.Dynamic.rebuild(tree)` only when a tree is dirty, which
     only the part can make it.
   - The core publishes the helpers the part needs in `_state.helpers`
     (the build context, `buildOption`, `flatten`, profile link attach and
     detach, labels), read at call time so an upgraded core serves a part
     loaded before it.
   - The weak source map is core state: every table-defined tree is
     registered at `Define`, so a part loaded later by another addon can
     still rebuild it. Builder references and limits live on the tree.
   - In-place upgrade from revision 14: trees get layout 3 on load (limits
     taken from the `_maxOptions` fields revisions 8 and earlier wrote,
     else the defaults); they have no source, so `NotifyChange` raises the
     message of 2c and `Replace`/`Remove` work.
   - New core code goes in `do` blocks; the core's main chunk stays at or
     below 172 locals.

6. Performance and memory:

   | Case | Today | Expected |
   |---|---|---|
   | any tree method on a clean tree | — | unchanged: the dirty test is the existing `_defined` test |
   | `NotifyChange` | — | one field write; one signal fire per clean-to-dirty change when listened to |
   | rebuild | — | the cost of `define-N` for the tree (bench ratio of the run against AceConfigRegistry's first check) plus `info` transfer, once per burst |
   | `Replace` of one option in a 200-option tree | — | building that option, sorting its siblings and one pass over the walk array (O(n) array writes, no strings built) |
   | per option | 477 / 614 / 843 B | unchanged |
   | per tree | — | +3 numbers, +1 weak map entry, + the builder when used; the signal only when connected |
   | core resident | after record 1 | +2 to +4 KB (hooks, helpers table, source map) |
   | part `Dynamic` resident, loaded only by addons that embed it | — | about 15 to 18 KB |
   | typical addon with a static tree (core only) against AceConfigRegistry + AceDBOptions | — | about 3.5x (record 1 plus the hooks); the part adds nothing to it |

   Why a part: dynamic trees are one separable feature set (five methods
   and a rebuild path) that a static tree never runs, and a native tree
   covers most runtime variation with `hidden`/`disabled` predicates,
   values functions and, after record 1, function names. Ace3 ports reach
   it through BridgeKit (record 3), and `tooling.package.embeds` adds the
   part line to `embeds.xml`. If the owner prefers the feature in the core
   because 14/16 Ace3 addons mutate trees, the code is the same minus the
   part scaffolding (about 60 lines) and every addon pays the 15 to 18 KB.

7. Tests:
   - builder: called at `Define`, its error propagates there, a non-table
     result raises at the caller; a function without the part raises with
     the part's name;
   - `NotifyChange`: no work at the call; many calls, one rebuild; rebuild at
     each structure-reading method; added, removed and changed options;
     `info` of surviving paths kept (same table), not for a changed kind;
     `OnChange` listeners kept; profile groups kept, added and removed with
     their connections; limits of the original `Define` applied;
   - a table source edited in place then `NotifyChange`; a dropped table
     (collected) and a tree from before the upgrade raise 2c's message;
   - failure: builder raises, returns a non-table, result refused: previous
     structure kept, one report through a stubbed `geterrorhandler` with the
     `NotifyChange` label, tree clean, triggering method answers from the
     kept structure; without `geterrorhandler`;
   - re-entry: a builder calling tree methods (old structure), a builder
     calling `NotifyChange` (dirty again after the swap), a listener calling
     `Describe` inside the signal;
   - `Replace` and `Remove`: new key, replaced subtree, group with children,
     inherited declarations, sort position, walk order, path index, limits
     (count and depth), refusal leaves the tree unchanged, root refused,
     unknown path `false`, malformed path raises, profile group inside a
     replaced subtree;
   - `OnStructureChanged`: lazy signal, paths, fired once per clean-to-dirty,
     `Undefine` disconnects;
   - `GetTrees` sorted and fresh;
   - part protocol: core without the part, part loaded twice (equal and
     older revision), part loaded before a core upgrade, missing core error
     message; ErrorLevels for every new method; allocation: a clean tree's
     `Get`/`Set` allocate nothing, `NotifyChange` on a dirty tree allocates
     nothing;
   - in-place upgrade from revision 14 with trees defined before it.
   Client suite (never run here): a builder tree rebuilt after
   `NotifyChange` from a `PLAYER_LOGIN` handler; the error report reaching
   the client's error handler.

8. Docs: `docs/API.md` (Define's builder, *Dynamic trees* with the renderer
   contract above, the part in *Loading*, `GetTrees`, errors, upgrades),
   `docs/INTERNALS.md` (tree layout 3, the dirty sentinel, the source map,
   rebuild and swap, the helpers table, the part state), README (embedding
   the part; the migration rows for `NotifyChange`, function tables and
   `IterateOptionsTables`), CHANGELOG 0.8.0, `tests/README.md`, manifest
   `parts`, the client suite. Shared docs (EMBEDDING footprint table,
   MIGRATING_FROM_ACE3 rows, ROADMAP checkbox, coverage floor for the part
   file) are supplied as text with the code.

9. Status: implemented 2026-11-15 in optionsKit 0.8.0, revision 15.
   `OnStructureChanged` and `GetTrees` live in the core, so a renderer only
   connects `OnStructureChanged`, which a static tree never fires.

**optionsKit minimal core: AceConfig presentation, handlers and SettingsKit binds become parts; profile links join the Profiles part; the shared secret probe** — a change to facade `OptionsKit`

Measured 2026-11-16 on host Lua 5.1.5 (64-bit) with the shared fake client,
debug information kept as the client keeps it, the string table pre-grown;
each file loaded after its dependencies in one process, resident bytes after
a full collection. KB is 1000 bytes. Ace3 is the pinned bench copy
(`5e2e0d3b`), loaded after LibStub and CallbackHandler.

1. Package `optionsKit`, facade `OptionsKit`, API generation 1, version
   0.9.0 (from 0.8.0), implementation revision 16 (from 15), tree layout 3
   (unchanged), record layout unchanged. Three new parts (ADR 0001), each
   `PART_REVISION = 1`: `Presentation`
   (`src/parts/OptionsKit-Presentation.lua`), `Handlers`
   (`src/parts/OptionsKit-Handlers.lua`) and `Bind`
   (`src/parts/OptionsKit-Bind.lua`). `Profiles` goes to part revision 2;
   `Dynamic` stays at 1.

2. Purpose: a core that holds what every tree needs, with the conveniences
   only some addons use in parts. The previous record kept AceConfig's
   fields, method names, plugins and per-interface flags in the core; its
   point 9 measured the cost at about 60 KB against 29 KB estimated. This
   record re-weighs that.

   **What the core holds today** (155,796 B resident; 97,560 B of live
   prototypes in 126 top-level functions, 39,596 B of it debug information;
   25,760 B of data tables; constant strings 15,039 B, of which 6,137 B
   error and description prose; error-raising instruction runs 7,664 B):

   | Section | Prototypes | Share |
   |---|---:|---:|
   | Definition checks | 25,632 B | 26% |
   | Building | 14,800 B | 15% |
   | Describe (with the revision 14 resolution) | 13,808 B | 14% |
   | Package public API | 11,200 B | 11% |
   | Tree methods | 10,616 B | 11% |
   | Bound values | 6,760 B | 7% |
   | Schemas | 6,152 B | 6% |
   | Argument checks, profile groups, record fields, info tables, dependencies | 8,592 B | 9% |

   Biggest functions: `buildValueFields` 5,288 B, `buildOption` 3,752,
   `describeRecord` 3,720, `buildChildren` 2,824, `buildSchema` 2,680,
   `define` 2,320, `checkKnownFields` 2,064, `readDefineOptions` 1,720,
   `getFields` 1,616, `parseBind` 1,496. Biggest data: `Fields` 11,139 B
   (the accepted-field tables, the forms string, the method and interface
   lists), `Hints` 3,328 B (the field checks and roles), `SharedSchemas`
   1,088 B, `BIND_SCOPES` 704 B.

   **Classified by who needs it** (prototype bytes summed per function,
   priced resident = prototypes × 1.333, this core's measured ratio of
   resident-minus-data to prototypes, plus the data tables each takes):

   | Group | Prototypes | Who needs it | Decision |
   |---|---:|---|---|
   | Define of a static tree, the revision 13 field set, schemas, `Get`/`Set`/`Validate`/`Reset`/`Execute`, `IsDisabled`/`IsHidden`, `Walk`, `Describe`/`DescribeOption`, `OnChange`, `OnStructureChanged`, `GetTrees`, `IsPartLoaded`, the `Define` limits | about 62,000 B (67,096 B of whole functions less the inline code that moves) | every tree | core |
   | Presentation fields and their checks (`width`, `relWidth`, `descStyle`, `icon`, `iconCoords`, `image*`, `tooltipHyperlink`, `dialogControl`, `control`, `itemControl`, `style`) | 7,264 B | renderer hints, some addons | `Presentation` |
   | Describe-time resolution (function `name`, `order`, `fontSize`, hint functions, the re-sort, `sorting` functions, `compareDynamicRecords`) | 6,856 B | trees with function presentation fields | `Presentation` |
   | Per-interface flags (`guiHidden`, `dialogHidden`, `cmdHidden`, `guiInline`, `dialogInline`, `cmdInline`: `hiddenFlagOf`, `Resolve.inline`) | 1,168 B | 0 to 2 of 16 corpus addons | `Presentation` |
   | Handler and method names (ADR 0003 form), accessors inherited from groups, `plugins` | 4,408 B + about 1,900 B inline | Ace3 ports | `Handlers` |
   | `bind` into a SettingsKit database, `ns:` namespace binds, bound reads, writes and checks | 7,264 B + about 1,500 B inline | addons with SettingsKit | `Bind` |
   | Profile links (`collectProfileLink`, `attachProfileLink`, `detachProfileLink`, `disconnectAll`, `attachLinks`) | 3,504 B | trees holding `ProfileOptions` | `Profiles` |
   | `confirm`, `confirmText`, `GetConfirmation` | 2,224 B | renderers ask every tree; `confirm` is accepted since revision 1 | core |
   | `GetFields` | 1,616 B | BridgeKit, once per conversion | core, reporting what is loaded |
   | `checkInterface` (the interface argument of `IsHidden`, `Describe`, `DescribeOption`) | 464 B | every renderer that passes one | core |
   | `findSettingsKit`, `isDatabaseReadOnly`, `handlerInForce` | 1,272 B | helpers the Profiles and Dynamic parts call | core |

   Cold code that stays resident: none named as upgrade code; the
   revision-15 `legacyMembers` handling runs in the main chunk and is freed.
   Validation by name is 17,200 B of prototypes (17.6%), error builders
   5,520 B, the secret probe 392 B. Limits are `Define` options only
   (`readCapacityOption`, `readMaxDepthOption`, 1,544 B); OptionsKit has no
   `SetLimits`.

   **Ace3 counterpart, measured the same way:** AceConfigRegistry-3.0
   27,243 B resident (8,080 B of prototypes, the rest its validation type
   tables), AceDBOptions-3.0 17,007 B; together 44,250 B. The smallest
   OptionsKit set (Registry 32,306 + SignalKit 90,379 + SchemaKit 82,746 +
   core 155,796 = 361,227 B) stands against LibStub + CallbackHandler +
   AceConfigRegistry (40,288 B), 9.0×. Revision 13, the core before the
   AceConfig fields, measured 129,788 B with the profile code (25.3 KB of
   prototypes) still inside it: about 97 KB without.

   **The changes.**

   a. **`Presentation` part.** Moves the presentation field checks
      (`Hints.fieldChecks` entries, `isTexture`, `checkTexture`,
      `isCoordinates`, `checkCoordinates`, `checkControlName`,
      `checkBoolean`, `checkPositive`, `checkString`), the "Describe-time
      resolution (revision 14)" section (`Resolve.*`, `RESOLVERS`), the
      function forms of `name`, `order` and `fontSize`, `sorting` functions,
      `compareDynamicRecords`, the per-interface flags and their fields in
      `Fields` (`control`, `interfaces`, `widths`, `descStyles`,
      `selectStyles`, the part's share of `notDescribed` and of the forms
      string). The core keeps one generic hint loop in `describeRecord`
      (plain hints copied as today) and calls the part's resolver only for a
      function or table hint, which only the part can have accepted.
   b. **`Handlers` part.** Moves `handler`, method names in every field of
      `Fields.method`, accessors (`get`, `set`, `validate`, `func`) declared
      on groups and inherited, and `plugins`: `methodCaller`,
      `Hints.callback`, `Hints.accessor`, `Hints.resolve`,
      `checkMethodPredicate`'s method form, `checkAccessor`, the plugin loop
      of `buildChildren`, `Fields.method` and `Fields.accessor`.
      `Hints.handlerInForce` stays in the core (392 B): `infoOf` reports
      `info.handler` and the Dynamic part's revision 1 calls it through the
      helpers.
   c. **`Bind` part.** Moves `bind` and `ns:` binds: `parseBind`,
      `readMember`, `findNamespace`, `bindTextOf`, `bindDatabaseOf`,
      `assignField`, `withoutPosition`, `walkBound`, `validateBound`,
      `writeBound`, the bound branches of `buildValueFields`, `readValue`,
      `writeValue`, `snapshotValue` and `describeRecord`, `BIND_SCOPES`,
      `NAMESPACE_PREFIX`. `options.db` stays a `Define` option of the core
      (Profiles needs it too). `findSettingsKit` and `isDatabaseReadOnly`
      stay as core helpers. **This one needs the owner's yes:** the README's
      first example binds every option, so the native SettingsKit path gains
      one embedded file; an addon with `get`/`set` (every Ace3 port) saves
      about 13 KB.
   d. **Profile links into `Profiles`.** The "Profile groups" section and
      `collectProfileLink` move to the Profiles part, which already makes the
      groups. The core calls a build hook only when the Profiles part is
      loaded; `profileGroups` stays in state.
   e. **Hooks, not copies.** The core publishes extension points in its
      state, rewritten by every core revision and re-filled by each loaded
      part's `bind(helpers)` (today's pattern): field roles and checks
      (`Hints.roles`), a per-kind field set the parts add to, a build hook
      (accessors, plugins, bind, profile links), a describe hook (resolved
      hints, function names and orders, interface flags), and
      `helpers.compareRecords` (the plain comparator, or the part's
      comparator once Presentation is loaded). Hot paths gain nothing: a
      method caller is still stored where a function would be, so `Get`,
      `Set` and the predicates keep today's function path, and an option
      without part fields never reaches a hook.
   f. **Shared secret probe.** The hand-written `isSecret` (line 560)
      becomes the `isSecret` shared block. The answers are the same: a probe
      present at load is kept, a probe absent at load is read again per
      call, which covers "a probe that appears after load is used at once".

   Considered and kept in the core, with the numbers: `confirm` and
   `GetConfirmation` (renderers call it on every tree, and `confirm` has been
   a core field since revision 1); `GetFields` (BridgeKit asks it what to
   carry; in a part, a converter without the part would carry nothing);
   `Describe` (every tree that is shown is described); the interface
   argument (464 B, so a renderer may always pass it). Rejected: dropping
   SchemaKit (it is the documented validated `Set`, and SettingsKit needs it
   anyway); replacing SignalKit with a listener list (EventKit, LifecycleKit
   and SettingsKit load it in every typical set, so it saves nothing there);
   shortening error prose (6.1 KB in the core, part of it moves with the
   parts; messages are matched by the specs and documented); the
   `loadstring` trick (memory diagnosis: rejected for every Kit).
   Non-goals: per-option memory (the records do not change), the lazy
   records of the memory diagnosis (fix 7).

3. Dependencies: core Registry API 2, SchemaKit API 1, SignalKit API 1 as
   today; `settingsKit` stays an optional dependency of the core (for
   `options.db` and the Profiles helpers). Manifest parts:

   ```json
   "Presentation": {
     "description": "AceConfig's presentation fields: widths, icons, images, controls, styles, function names and orders, sorting functions and the per-interface hidden and inline flags.",
     "revision": 1,
     "dependencies": {},
     "optionalDependencies": {}
   },
   "Handlers": {
     "description": "AceConfig's ways of wiring a tree: a handler and method names, accessors declared on groups and inherited, and plugins.",
     "revision": 1,
     "dependencies": {},
     "optionalDependencies": {}
   },
   "Bind": {
     "description": "bind = \"profile.path\" and ns: binds: options read and written through a SettingsKit database passed as options.db.",
     "revision": 1,
     "dependencies": {},
     "optionalDependencies": { "settingsKit": { "api": 1 } }
   }
   ```

   `Profiles` revision 2 keeps its dependencies. None of the new parts needs
   another part; an Ace3 port embeds Presentation and Handlers together.

4. Surface: no new method and no removed one. `OptionsKit:IsPartLoaded`
   accepts the three new names. `OptionsKit:GetFields(kind)` reports the
   fields the loaded parts accept: without Presentation it no longer lists
   `width` and the rest, and without Handlers no form lists `"method"`.
   What changes for users:
   - A tree that uses a field of an absent part is refused at `Define`, at
     the caller's line, with the file to add, in the form the Dynamic part
     already uses: `OptionsKit:Define tree.args.general.args.scale.width
     needs OptionsKit's Presentation part: add
     optionsKit\parts\OptionsKit-Presentation.lua to embeds.xml (or rebuild
     it with python3 -m tooling.package.embeds)`. The same for a method
     name, `handler`, a group's accessor or `plugins` (Handlers) and `bind`
     (Bind). The core keeps one string of the part fields' names, read only
     on the failure path, to name the part.
   - A function `name`, `order` or `fontSize` and a `sorting` function are
     Presentation fields; a string name, a number order and a sorting array
     stay in the core.
   - `IsHidden(path, interface)`, `Describe(interface)` and
     `DescribeOption(path, interface)` accept `"dialog"` and `"cmd"` with or
     without Presentation; without it no tree can carry interface flags, so
     the answer is the plain `hidden` and `inline`, which is correct.
   - Embedding: README minimum footprint unchanged (4 files); an Ace3 port
     adds two lines, a SettingsKit tree one (if c is accepted).
   - Messages, levels and every other behaviour unchanged.

5. Ownership and in-place upgrade from revision 15. Trees keep their records
   and layout. Revision 15 was the last core with these features inside, so
   an addon embedding revision 15 alone may share a session with one that
   embeds revision 16 without the parts; the revision-16 core keeps that
   addon working, as revision 15 kept `ProfileOptions` of older single-file
   revisions (`legacyMembers`):
   - Before its commit, the revision-16 core copies revision 15's `Define`
     and every method of the shared `Tree` prototype into
     `state.legacyMembers` (main chunk, only when `previousRevision == 15`).
   - Routing happens only on the branch that needs an absent part, never on
     the common path. A bound record (`_bindScope`) already takes its own
     branch in `Get`, `Set`, `Validate`, `Reset` and `Describe`; with Bind
     absent that branch calls revision 15's captured method for the whole
     call. A function or table hint, or an interface flag, reaches the
     describe hook only through its own branch; with Presentation absent,
     `Describe`, `DescribeOption` and `IsHidden` call revision 15's
     functions for that tree. Method callers, inherited accessors and
     plugins are resolved into the records at `Define`, so trees using them
     need no routing at all. Unbound options without part fields pay
     nothing, and `Get`/`Set` stay allocation-free.
   - A `Define` the core would refuse only because a part is absent is
     handed to the captured revision-15 `Define`; with nothing captured it
     raises as in point 4.
   - Once every part is loaded, the revision-15 entries of
     `state.legacyMembers` are dropped, so a
     session that later gains the parts runs revision 16 throughout and the
     revision-15 closures are collected.
   The parts keep their state in `_state.parts.<Part>` with their revision;
   the highest part revision wins and upgrades in place. A part loaded with
   a core older than revision 16 raises `MoltenCodes OptionsKit part
   Presentation requires OptionsKit revision 16 or later to be loaded first`
   (a core's own load order puts it first, so only a hand-edited file list
   meets this).

6. Performance and memory. Priced from the measured prototypes and data
   tables (point 2); measured again in phase 2.

   | Change | Core today | Expected effect on the core | Part file (resident) |
   |---|---:|---:|---:|
   | a. Presentation | 155,796 B | −29.5 KB | about 31 KB |
   | b. Handlers | | −9.4 KB | about 11 KB |
   | c. Bind | | −13.0 KB | about 14.5 KB |
   | d. profile links to Profiles | | −4.7 KB | Profiles 36.1 → about 41 KB |
   | e. hooks, part field names, upgrade routing | | +3.5 KB | |
   | f. shared `isSecret` | | +0.1 KB | |
   | **core** | **155.8 KB** | **about 103 KB (−34%)**; about 116 KB without c | |

   | Embedded | Today | Expected | Ace3 it replaces | Ratio |
   |---|---:|---:|---|---:|
   | core alone | 155.8 KB | about 103 KB | AceConfigRegistry 27.2 KB | 3.8× (today 5.7×) |
   | smallest set (Registry, SignalKit, SchemaKit, core) | 361.2 KB | about 308 KB | LibStub, CallbackHandler, AceConfigRegistry 40.3 KB | 7.7× (today 9.0×) |
   | Ace3 port: core + Presentation + Handlers | 155.8 KB | about 145 KB | AceConfigRegistry 27.2 KB | 5.3× |
   | everything: core + all five parts | 209.1 KB (core and two parts) | about 218 KB | AceConfigRegistry + AceDBOptions 44.3 KB | 4.9× (today 4.7×) |

   What stays above AceConfigRegistry is the validated, path-indexed
   snapshot (`Define` checks every field at the caller's line and builds a
   record and a SchemaKit schema per option; AceConfigRegistry keeps the
   author's table and validates lazily), `Describe`, the change signals and
   the limits: documented guarantees, about 60 KB of prototypes. Transient
   allocation while loading the core falls with its size (405,093 B today).
   Hot paths: `Get`, `Set`, `IsHidden(path)` and `IsHidden(path, interface)`
   keep allocating nothing; bench cases (`options` workload) expected
   unchanged within noise, measured against Ace3 in one run in phase 2.
   Per option: unchanged (477 B a toggle, 843 B a bound range).

7. Tests: the core alone refuses every Presentation, Handlers and Bind
   field at the caller with the file to add (one case per field family);
   each part's fields accepted with the part, existing field specs moved to
   load the part they need; `GetFields` with and without each part;
   `IsHidden`/`Describe` with an interface and no Presentation part; the
   profile links through Profiles revision 2, and a Profiles revision 1
   part with the revision-16 core (helpers kept); Dynamic revision 1 with
   the new core (its helpers `compareRecords`, `handlerInForce`,
   `attachLinks`, `detachProfileLink` still published); a part loaded with a
   revision-15 core raising; in-place upgrade from revision 15 (a byte copy
   of today's file as fixture) with a tree using `width`, a function `name`,
   a method name, `plugins` and `bind` defined before the upgrade: every
   method answers as before with no part loaded, and again after the parts
   load; a `Define` with part fields after the upgrade handed to revision 15;
   the shared `isSecret` block (`tooling.shared.sync --check`); allocation
   specs unchanged; opt into `KitConformance` (manifest, receivers,
   arguments, upgrade; `limits` pending: OptionsKit has no `SetLimits`).
   Client suite: a tree with presentation fields and binds defines and
   describes with the parts embedded.

8. Docs: README (the parts table with measured sizes, the migration table
   rows that now name a part, the footprint line), `docs/API.md` (*Loading*:
   five parts and which fields each brings; the field tables gain a "Part"
   column; *Deviations*; *Embedded copies and upgrades*: the revision-15
   routing; the section skeleton of `docs/CONTRIBUTING.md`),
   `docs/INTERNALS.md` (hooks, the part field index, legacy routing),
   CHANGELOG 0.9.0, `tests/README.md`, `src/.luarc.json` covering the new
   parts, the client suite's `EXPECTED.md`. Shared files (text with the
   code): the embedding guide's parts table (generated), the
   `MIGRATING_FROM_ACE3.md` rows for `width`, function `name`, method names,
   `handler`, inherited accessors, `plugins` and per-interface flags (each
   names its part), and BridgeKit's owner told that converting an Ace3
   table needs Presentation and Handlers loaded or the fields are not
   carried (its manifest may name the parts in its `optionsKit` contract).

9. Status: implemented 2026-11-18, 0.9.0, revision 16, 297 specs (one
   pending). Measured on host Lua 5.1.5 (64-bit, debug information kept,
   resident bytes after a full collection, each file after its
   dependencies): core 158,714 B → 134,087 B (−15.5%); Presentation
   30,068 B, Handlers 8,171 B, Bind 10,922 B; Profiles 36,445 B → 41,164 B
   (part revision 2); Dynamic 17,412 B. The core stays above the 103 KB
   estimated: what remains is the "every tree" group of point 2 (about
   62 KB of prototypes plus the data tables), and the revision 15 routing
   costs about 7 KB (`Legacy.specNeedsAbsentPart`, the routed branches, the
   `Bound` defaults); the scan of revision 15 trees runs as main-chunk code
   and is freed. Choices the record left open, taken conservatively: the
   core keeps `detachProfileLink` (small) so `Undefine` frees a link any
   revision attached with or without Profiles revision 2; a Profiles
   revision 1 part (or a single-file `ProfileOptions`) with a revision 16
   core builds groups that define and work but are not linked to the tree
   (documented limit); routing of `Describe`, `DescribeOption` and
   `IsHidden(path, interface)` applies to trees marked at the upgrade (or
   defined through revision 15) as using a part; `Bound.database` and
   `Bound.text` stay core (the record moved `bindDatabaseOf`/`bindTextOf`;
   `IsDisabled` and `Describe` need them for any bound record); a method-name
   `order` needs Handlers and Presentation; `GetTrees` is exempt from
   KitConformance's receiver group (it reads no receiver) and `limits`
   stays pending (no `SetLimits`); the conformance spec loads its chain
   tolerantly in `NewPackageWithout`, since KitConformance loads the rest of
   a multi-Kit chain unprotected; the Rules part is checked with
   `SchemaKit:HasPart` before a pattern or values function, raising at the
   `Define` caller. A routed `Define` reports its own refusals at a line
   inside OptionsKit (no tail call is possible without losing the line).
   Outside this package (reported, not changed): WidgetKit, BridgeKit,
   CommandKit and AddonKit test environments and fixtures must load the
   parts their trees use (Bind; BridgeKit Presentation and Handlers) and
   SchemaKit's Rules part; the client suite `EXPECTED.md` and `.toc`.
