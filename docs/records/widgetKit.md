# widgetKit records

Moved from `docs/ROADMAP.md` (Package E planned Kit — the nine points).

## widgetKit

**widgetKit** — facade `WidgetKit`

1. Package `widgetKit`, facade `WidgetKit`, API generation 1. A core
   package; widget sets beyond the base set become their own packages later
   so that independent publication holds.
2. Purpose: a versioned registry of pooled, acquire-and-release widget types
   with a small base contract, named callbacks, registered layout functions,
   a normalised anchor value type with position persistence, and an
   options renderer that consumes `optionsKit`'s `Describe`. Non-goals: a
   theming system, animation, wrapping every client template, replacing
   plain frames where they are simpler.
3. Dependencies: registry API 2, poolKit API 1 (pools for objects that
   cannot be freed, with generation stamps), signalKit API 1 (callbacks);
   optionsKit API 1, settingsKit API 1, schedulerKit API 1 and mediaKit
   API 1 optional through `Registry:Find` (the renderer, position
   persistence with a debounced save, media pickers).
4. Surface: `WidgetKit:RegisterType(name, constructor, version)`,
   `GetTypeVersion(name)`, `Create(name)` → widget, `Release(widget)`,
   `RegisterLayout(name, layoutFunction)` / `GetLayout(name)`,
   `SetFocus(widget)` / `ClearFocus()`, `GetStatistics()`; widget base:
   `OnAcquire` / `OnRelease` hooks, `SetCallback(name, callback)` /
   `Fire(name, ...)`, `SetUserData` / `GetUserData`, size, anchor and
   visibility pass-through methods, `IsReleasing()`; container base: `AddChild`,
   `AddChildren`, `ReleaseChildren`, `SetLayout`, `PauseLayout`,
   `ResumeLayout`, `PerformLayout`, the upward `LayoutFinished` size report;
   layouts in generation 1: `List`, `Fill`, `Flow`; base widgets in
   generation 1: `Frame` (window with title and close), `Group`,
   `ScrollFrame`, `Label`, `Button`, `CheckBox`, `Slider`, `EditBox`,
   `Dropdown`, `ColorPicker`, `Heading`, `Spacer`; anchors:
   `WidgetKit.Anchor.FromRect(rect, parentRect)` (pure, elects the nearest
   point), `Normalize(frame, ...)`, `Apply(frame, anchor)`, `Read(frame)`,
   `WidgetKit:BindPosition(frame, storageTable, options)` → binding with
   `OnMoved(callback)` and `Release()`; renderer:
   `WidgetKit:RenderOptions(optionsTree, container)` → a released-together
   set of widgets driving `Get` / `Set` / `Execute`, honouring `disabled`,
   `hidden`, `order` and `validate` refusals shown inline.
5. Ownership: one bounded pool per widget type; a widget built by an older
   registered version is discarded rather than reused; `Release` fires
   `OnRelease`, releases children first, clears user data, callbacks and
   anchors, hides and re-parents, then returns to the pool; the number of
   frames ever created per type is capped with a named refusal;
   `IsReleasing` is ancestor-aware.
6. Performance: bounded pools with `Trim` reachable through PoolKit; LIFO
   acquire; layout is an explicit operation, never a reaction to
   `OnSizeChanged`; layout scratch tables from a pool; a documented cap on
   children per container (256); callback errors isolated and reported;
   position saves debounced through SchedulerKit when present.
7. Tests: type versioning incl. a lower version ignored, acquire and
   release round-trip, pooled reuse, stale-generation discard after a type
   upgrade, double release refused, foreign widget refused, container add
   and release incl. nested order, `IsReleasing` through an ancestor chain,
   each layout against the frame fixture with recorded anchor calls (the
   shared fixture gains sizes and anchors), layout recursion refusal, frame
   cap, anchor election table cases, position binding save and restore,
   renderer against a real optionsKit tree for every option kind,
   allocation guard on acquire and release cycles, upgrade, manifest, error
   levels.
8. Docs: README, API.md with the widget author contract stated as
   requirements, the release contract, the layout contract, the versioning
   rule, the frame cap, the anchor model and a worked custom widget and
   layout; INTERNALS.md for the layout algorithms and the renderer;
   CHANGELOG; EMBEDDING.md host row and a UI section.
9. Status: implemented (package E, 0.1.0); deviations recorded in
   `packages/widgetKit/docs/API.md`.

Moved from `docs/ROADMAP.md` (Package M — the user-interface phase (last, by the owner's decision)).

## widgetKit virtualised lists

**widgetKit virtualised lists** — an addition to facade `WidgetKit`

1. Package `widgetKit`, facade `WidgetKit`, API generation 1 (additive),
   version 0.4.0, implementation revision 12. One new base widget type,
   `ScrollList`, at version 1; every other base type keeps its version.
2. Purpose: a list that stays cheap however long it is. Only the rows the
   list shows exist as frames; scrolling points them at other elements.
   Built on Blizzard's ScrollBox framework (`Blizzard_SharedXML/Shared/Scroll`
   and `DataProvider.lua`): a `WowScrollBoxList` frame, a `MinimalScrollBar`,
   `CreateScrollBoxListLinearView`, `ScrollUtil.InitScrollBoxListWithScrollBar`
   and `CreateDataProvider`. Retail, Mists of Pandaria Classic and Classic Era
   ship these with the same code (branches `live` 12.1.5, `classic` 5.5.4 and
   `classic_era` 1.15.9, read 2026-11-15; the only differences are Retail's
   narration hooks and a return value in the tree view, neither used here).
   What WidgetKit adds over calling the framework directly: a pooled widget
   that lays out and releases like every other one, checked arguments, a
   bounded element count, standard rows built once per row frame, a row
   formatter that raises reported and never breaking Blizzard's update, and
   single selection kept by WidgetKit. Recorded deviation: selection does not
   use `ScrollUtil.AddSelectionBehavior`, because every select there walks the
   whole data provider and allocates (`DeselectByPredicate`), and it reads an
   element's own `selected` field as selected. Non-goals: grid, tree and
   horizontal views; drag and drop; multi-selection; variable row heights
   (`SetElementExtentCalculator` recomputes every element's extent on each
   data change); custom row frames (a pooled list's rows go to the next
   consumer of the widget, so rows built by one addon would carry their
   children into another's list; such a list uses Blizzard's ScrollBox
   directly); sorting (sort the array before handing it over); secret texts
   in rows.
3. Dependencies: unchanged (registry API 2, poolKit API 1, signalKit API 1).
   Host requirement: `CreateFrame` with the templates `WowScrollBoxList`
   (a `Frame`) and `MinimalScrollBar` (an `EventFrame`), and the globals
   `CreateScrollBoxListLinearView`, `ScrollUtil` and `CreateDataProvider`.
   Without them `Create("ScrollList")` raises at the caller before any frame
   is made; the other widgets are unaffected.
4. Surface: `WidgetKit:Create("ScrollList")` → list.
   `list:SetRowHeight(pixels)` (a number of at least 8; default 20);
   `list:SetFormatter(callback|nil)`, `callback(element, index)` → text,
   icon? (default: `element.text` and `element.icon`);
   `list:SetElements(elements, retainScroll?)`, an array of tables, copied,
   at most `maxListElements`, every element checked before anything changes;
   `list:Insert(element, index?)`, `list:Remove(element)` → `true` or `false`,
   `list:Clear()`; `list:GetNumElements()`, `list:GetElement(index)`;
   `list:Refresh()` (draw the shown rows again after elements changed in
   place); `list:ScrollToElement(element, alignment?)` → `true` or `false`,
   with `alignment` `"begin"`, `"center"` (default), `"end"` or `"nearest"`;
   `list:SetValue(element|nil)`, `list:GetValue()`. Callbacks: a left click
   selects the row's element and fires `OnValueChanged(element)` when it
   changed; every click fires `OnClick(element, mouseButton)`. `SetDisabled`
   ignores clicks and greys the rows. `WidgetKit:SetLimits{ maxListElements }`
   joins the package limits.
5. Ownership: the widget's frame, its `WowScrollBoxList`, its
   `MinimalScrollBar` and its view are made once by the constructor and kept
   for the widget's life. Row frames are made by the view's own frame pool
   (`CreateFrameFactory`, keyed by the frame type `Button`), parented to the
   scroll target and reused by the next use of the widget; each row's parts
   (text, icon, highlight and selected textures) are made the first time the
   view hands WidgetKit that frame and kept in a table of the widget, never
   on the frame. Row click scripts call through the dispatch table, so an
   upgraded revision takes them over. On release the view is flushed (every
   row back to its pool, the data provider removed), row texts are cleared,
   and the formatter, the value and every element reference are dropped.
6. Performance and memory: frames per list are the rows its height shows,
   plus one, made once and pooled by the view; with the 8-pixel minimum a
   1080-pixel list holds at most 136. Row frames are the view's, not
   WidgetKit's, so they do not count against the frame cap. An element costs
   one array slot. Every data change costs one pass over the elements in
   Blizzard's code (`RecalculateExtent` walks the provider even with a fixed
   row height), so `Insert` and `Remove` are O(n) and many changes belong in
   one `SetElements`. `SetElements` allocates one data provider; scrolling
   allocates in Blizzard's view (a few tables per range change and accessor
   closures per acquired row), nothing in WidgetKit. Selection is one field.
   `maxListElements` defaults to 16384 and opens to `UNBOUNDED`: elements are
   the consumer's tables, never frames.
7. Tests: a package-local stand-in for the ScrollBox framework in
   `tests/support/WidgetKitTestEnv.lua` (templates, view, data provider and
   scroll bar recording what WidgetKit calls, and acquiring rows for a
   visible range); acquire and release with rows back in the view's pool and
   no element kept; standard rows built once per frame and reused across
   uses; the formatter (default, custom, raising, a non-string or secret
   text reported and shown empty); `SetElements` checks and limits
   (`UNBOUNDED` included), selection kept when the selected element is in
   the new list; `Insert`, `Remove`, `Clear`, `Refresh`; `ScrollToElement`
   and each alignment; clicks, selection, both callbacks and a callback that
   releases the list; `SetDisabled`; the refusal without the framework;
   secret arguments refused; error levels; an upgrade from revision 11 that
   keeps live widgets and adds the new limit; manifest. The existing client
   suite (`tests/client/MoltenCodesTest_WidgetKit`) gains a Retail case: a
   10000-element list shown, scrolled, a row clicked, a scroll to an
   element, the list released with the view's frame count unchanged on the
   next use, and the same in combat.
8. Docs: README, API.md (the `ScrollList` section, the limit row, the
   performance rows, the selection deviation), INTERNALS.md (rows in the
   view's pool, the row-parts table), CHANGELOG, tests/README, the client
   suite's EXPECTED.md; EMBEDDING's host-requirements row and package M's
   checklist (the maintainer).
9. Status: implemented 2026-11-15 under core decision 16, 0.4.0, revision
   12, 30 specs in `ScrollList_spec.lua`; the client cases
   (`widgetKit.scrollList` and the combat suite `widgetKit.scrollListCombat`
   in `tests/client/MoltenCodesTest_WidgetKit`) are written and have not been
   run in a client. Deviations: the base constructors moved into one table
   (the main chunk's 200-local limit); duplicate elements are refused,
   because Blizzard's view tells rows apart by their element; the formatter
   may return a number as the text; `ScrollToElement` finds the index and
   scrolls by it; a released `ScrollList` is not allocation-free in the
   client, since Blizzard's `Flush` allocates one table.
   Review fix 2026-11-15 (decision 17): widgetKit 0.4.1, revision 13,
   `ScrollList` version 2 (the formatter is asked again with the new index
   after `Insert` before the end and after `Remove`).

Moved from `docs/ROADMAP.md` (Package O — memory, performance and ease of use (decisions 18 and 19)).

## widgetKit (package O): a core and parts, pools on first use, no upgrade residue, and widget cycles at AceGUI's cost

**widgetKit (package O): a core and parts, pools on first use, no upgrade residue, and widget cycles at AceGUI's cost** — a change to facade `WidgetKit`

1. Package `widgetKit`, facade `WidgetKit`, API generation 1 (additive),
   version 0.5.0 (from 0.4.1), implementation revision 14 (from 13). The
   package becomes a core file `src/WidgetKit.lua` plus eleven part files
   `src/parts/WidgetKit-<Part>.lua`, each at part revision 1 (ADR 0001).

2. Purpose: an addon pays only for the widgets it uses, and the widget
   cycles cost no more than AceGUI-3.0's.

   Measured today (host Lua 5.1.5, debug information kept, shared fake
   client): WidgetKit holds 355.1 KB resident, and an addon that embeds it
   also loads PoolKit (78.9 KB) and SignalKit (80.8 KB), whatever it draws.
   Of the 355.1 KB, the widget types are 73.5 KB in their six largest
   sections alone, the renderer 37.5 KB, thirteen empty PoolKit pools built
   at load 34.6 KB (2.7 KB each), and an older copy upgraded in place leaves
   14.1 KB of its code reachable. The main chunk holds 189 of Lua 5.1's 200
   locals. On the bench, the `Button` cycle costs 1.41× AceGUI's and the
   `Slider` cycle 1.62× (456 against 269 VM instructions and 56 against 39
   calls per `Button` cycle; 882 against 601 and 113 against 75 per
   `Slider` cycle).

   The changes:

   - **Core and parts (ADR 0001).** The core keeps what every widget needs:
     constants, the shared prototypes, Registry bootstrap, host helpers,
     argument checks, widget records, the widget base, the container base,
     the `List`, `Fill` and `Flow` layouts, the type registry with pooling,
     focus, statistics, limits, the shared widget helpers (text checks,
     `showText`, label colours) and the part machinery. Everything else
     moves into parts:

     | Part | Holds | Needs |
     |---|---|---|
     | `Containers` | `Frame`, `Group`, `ScrollFrame` | the core |
     | `Text` | `Label`, `Heading`, `Spacer` | the core |
     | `Button` | `Button`, key capture included | the core |
     | `CheckBox` | `CheckBox` | the core |
     | `Slider` | `Slider` | the core |
     | `EditBox` | `EditBox`, single and multi-line | the core |
     | `Dropdown` | `Dropdown`, its list catcher, `CreateMediaPicker` | the core; MediaKit API 1 optional |
     | `ColorPicker` | `ColorPicker` | the core |
     | `ScrollList` | `ScrollList` | the core |
     | `Position` | `WidgetKit.Anchor`, `BindPosition`, the binding methods | the core; SignalKit API 1; SchedulerKit API 1 optional |
     | `Renderer` | `RenderOptions`, the rendering methods, `childGroups` pages | parts `Containers`, `Text`, `Button`, `CheckBox`, `Slider`, `EditBox`, `Dropdown`, `ColorPicker`; OptionsKit, SchedulerKit, MediaKit API 1 optional |

     Controls get a part each, as AceGUI gives each widget a file, so a
     window with a button does not carry a slider. The three small display
     types share `Text` and the three containers share `Containers`,
     because a part has a fixed cost (its record, its bind function and
     its stubs, at most 1 KB) that one tiny type would not repay. An addon
     that embeds every part behaves as today.

   - **The core needs only Registry.** PoolKit and SignalKit leave the
     core's dependencies: SignalKit carries only a binding's `OnMoved`
     listeners and moves to the `Position` part; PoolKit is replaced as
     below.

   - **Pooling inside the core, pools on first use.** Each type keeps its
     own free list (an array of idle widgets), its cap, its created,
     borrowed and discarded counts, and its version as the generation, in
     its type record. The array is created by the first `Create` of the
     type, never at load or at registration. This removes the second layer
     of pool bookkeeping (WidgetKit's records plus PoolKit's maps, 105 VM
     instructions and 8 calls per cycle measured in PoolKit alone) and the
     34.6 KB of empty pools. Behaviour is PoolKit's as WidgetKit used it:
     the cap counts every frame a type ever built, every released widget is
     kept, a raised version retires idle widgets of older versions at once
     and borrowed ones when they come back, the cap grows by what an
     upgrade retires within `maxCreatedCeiling`, a constructor that raises
     or breaks the author contract is raised at the caller of `Create`. The
     constructor runs under `pcall` only when a widget is built; taking an
     idle widget calls nothing protected. Layout scratch tables become one
     retained table per layout depth (at most `MAX_LAYOUT_DEPTH`, 32) in
     the core's state, replacing the PoolKit table pool.

   - **No upgrade residue.** Two causes, both measured (a revision 11 copy
     upgraded by revision 13 keeps 174 of its functions reachable): pool
     callbacks created by the older file, and base types whose version did
     not change keeping the older file's constructor, through which the
     older copy's helpers stay alive. Fixes: the free lists need no
     per-type callbacks at all; a built-in type registered by WidgetKit's
     own part at an equal version replaces the constructor (only the public
     `RegisterType` keeps answering `false, "current"`), so the older
     constructor is unreferenced; and parts reach core helpers through a
     bind step (below) instead of capturing an older core's functions.
     Widgets an older revision built and pooled keep that revision's type
     methods for their life, as the versioning rule has always said; an
     addon builds its widgets after loading, so a session upgraded during
     load has none.

   - **Part machinery.** The core's state gains `parts`: part name to
     `{ revision, bind, members }`. A part file resolves its core through
     `Registry:Get("widgetKit", 1)` at file scope and raises
     `MoltenCodes WidgetKit part <Part> requires WidgetKit API 1 to be loaded
     first` without it; it returns at once when an equal or newer revision
     of itself is installed. Otherwise it registers its types through the
     core's internal registration, installs its members, and records itself.
     Core helpers reach a part through `bind(helpers)`, which assigns the
     part's local upvalues from `state.helpers`; the core calls every
     installed part's `bind` again when a newer core revision loads, so
     every part runs the newest helpers with no per-call lookup and no
     older helper kept alive. `state.helpers` is additive inside API 1: a
     helper's arguments and meaning never change; a change is a new name.
     A part may rely on a core at least as new as the one it shipped with,
     because an addon's own core file loads before its parts.

   - **Members of parts that are not loaded.** The facade and the shared
     prototypes stay complete, so every revision's surface check (Registry
     calls an older copy's check on a newer facade) passes whichever parts
     are loaded. For each member a part provides, the core installs, in
     order of preference: the loaded part's function; a function an older
     single-file revision installed (an upgrade from revision 13 or older
     with the part absent keeps that copy's renderer, bindings, anchors and
     media pickers working); a stub that raises at the caller's line
     `WidgetKit:RenderOptions is in WidgetKit's Renderer part, which is not
     loaded: add widgetKit\parts\WidgetKit-Renderer.lua to embeds.xml (or
     rebuild it with python3 -m tooling.package.embeds)`. `Create` of a base
     type whose part is absent raises the same form
     (`WidgetKit:Create Slider is in WidgetKit's Slider part, ...`) instead
     of answering `nil, "unknownType"`; names WidgetKit does not ship still
     answer `nil, "unknownType"`. `GetTypeVersion` answers `nil` for an
     absent type, so code can ask without raising. `Frame:BindPosition`
     raises the `Position` form when that part is absent; the `Containers`
     part does not require `Position`.

   - **Renderer extension points, for the AceConfigDialog work that follows
     on this split.** The `Renderer` part keeps, in its part state, four
     registries a later part fills without editing the renderer:
     `kinds` (option kind to the widget type, configure, apply and write
     functions; a custom-control part such as `dialogControl` picks another
     type per option), `decorators` (an ordered list called after a node's
     widget is built and at every refresh; tooltips for `desc`, `width`,
     inline descriptions and images attach here), `pageStyles`
     (`childGroups` value to the page builder; a widget-set part registers
     real tab, tree and select containers and the renderer prefers them)
     and `confirm` (the provider asked before a confirmed write or execute;
     the inline question is the default, a DialogKit part replaces it). Each
     entry carries its part's revision and the highest wins. The dialog
     layer (`OpenOptions` and its family) is a later part that adds facade
     members, with core stubs added in that revision. Constructor changes
     the later work needs (`OnEnter`/`OnLeave`, images, value limits,
     radio, multiselect) are revisions of the type parts that raise those
     types' versions, not new parts.

   - **Cycles at or below AceGUI's.** On top of the pooling change:
     - *The probe rule.* `issecretvalue` is read once at load; when it was
       absent at load, each check reads `rawget(_G, "issecretvalue")` and
       accepts it only as a function, so a probe installed later is
       honoured. Today `Create`, `isSecret`, `validateNumber` and the text
       checks read `_G` on every call (5 `rawget` per `Button` cycle, 9 per
       `Slider` cycle).
     - *Setters without repeated `type()` calls.* Today 16 `type` calls per
       `Button` cycle and 27 per `Slider` cycle. A checked value is typed
       once: the probe first, then one `type` test, then plain comparisons
       (`validateNumber`, `checkText`, `readDisabled`, the slider's `step`).
       Under ADR 0002 the checks that guard only a table index of a caller's
       value go: `type(widget) == "table" and records[widget]` becomes
       `records[widget]` (`Release`, `IsWidget`, `SetFocus`, `activeRecord`),
       `Create` and `GetTypeVersion` index `types[name]` before testing the
       name for their error message, and user-data keys are not probed
       before `userData[key]`. `docs/API.md` "Secret values" lists each,
       with the client's message (`attempted to index a table that cannot be
       indexed with secret keys`) as what a secret key now meets.
     - *Built-in hooks unprotected.* The `OnAcquire` and `OnRelease` hooks
       of WidgetKit's own types are called directly (the type record
       carries `trusted = true`, set only by the internal registration);
       custom types keep both `pcall`s and their documented behaviour. With
       the free list this takes the built-in cycle from three `pcall`s to
       none; a consumer's `OnRelease` callback stays protected.
     - *Slider text rewritten only on change.* The low and high labels are
       written only when `SetSliderValues` changes the range; the value
       text is formatted only when the value or the percent mode changed
       (the widget keeps the value and the text it formatted), and the box
       is written with that text at every store, because the user may have
       typed into it. Today four `string.format("%.10g")` calls per cycle.
     Non-goals: `x == nil` in place of `type(x) == "nil"` on values that
     may be secret (whether a secret compares with `nil` is not verified in
     the client; the guards that stay are the ones before such a
     comparison); removing the consumer callback's `pcall`; any change to
     what a widget draws.

   Non-goals of the whole record: new widgets, new option fields or any
   AceConfigDialog feature (the renderer round that follows builds on the
   extension points above); a second API generation; assembling parts into
   one file; changing PoolKit or SignalKit.

3. Dependencies:
   - Core: Registry API 2, required. Nothing else. PoolKit and SignalKit
     leave `dependencies`; SettingsKit stays an optional dependency in name
     only (a documented storage shape for `BindPosition`), moved to the
     `Position` part's `optionalDependencies`. OptionsKit, SchedulerKit and
     MediaKit move to the parts that use them.
   - Parts, as the table in point 2; manifest `parts` entries carry them
     (`Position`: `dependencies` signalKit API 1, `optionalDependencies`
     schedulerKit and settingsKit; `Dropdown`: `optionalDependencies`
     mediaKit; `Renderer`: `optionalDependencies` optionsKit,
     schedulerKit, mediaKit, and `parts` as listed).
   - Host requirements unchanged; the flavour gate keeps guarding every
     client call, now per file.
   - Dependents: PanelKit renders through `RenderOptions` and creates
     `Label` and `ScrollFrame`. Its manifest contract becomes
     `"widgetKit": { "api": 1, "parts": ["Renderer"] }` (the renderer's
     parts include `Containers` and `Text`), and its load check asks
     `WidgetKit:GetPartRevision("Renderer")` rather than the type of
     `RenderOptions`, which the stub always satisfies. The exact text goes
     to PanelKit's owner; until it lands PanelKit keeps loading because the
     stub is a function, and fails at its first render with the stub's
     message, which names the part.
   - Load order (generated by `tooling.package.embeds`): Registry, the core,
     then the selected parts, `Renderer` after its sibling parts, `Position`
     after SignalKit.

4. Surface:
   - Unchanged: every API 1 member, argument error and level, every
     `docs/API.md` behaviour, the base type versions (`Frame` 4, `Group` 3,
     `ScrollFrame` 1, `Label` 3, `Button` 3, `CheckBox` 4, `Slider` 4,
     `EditBox` 4, `Dropdown` 4, `ColorPicker` 4, `Heading` 3, `Spacer` 1,
     `ScrollList` 2; no constructor changes what it builds), and
     `GetStatistics` per type (`maxCreated`, `created`, `active`,
     `available`, `discarded`; a type registered but never created reports
     zeros and its cap).
   - Added: `WidgetKit:GetPartRevision(partName)` → the installed part's
     revision, or `nil`. `partName` must be a non-empty string; a name
     WidgetKit does not ship answers `nil`.
   - Changed, only where a part is missing (impossible before this
     revision): the stubs' errors and `Create`'s error for a base type
     whose part is absent, as in point 2. Loading the core without PoolKit
     or SignalKit no longer raises; loading the `Position` part without
     SignalKit raises `MoltenCodes WidgetKit part Position requires
     SignalKit API 1 to be loaded first`.
   - Changed by ADR 0002: a secret used as a widget receiver, a type or
     layout name, or a user-data key meets the client's own refusal instead
     of WidgetKit's message. Every other secret check stays.
   - `WidgetKit.Anchor.POINTS` is `nil` until `Position` loads (the four
     anchor functions are stubs).
   - Files: `src/WidgetKit.lua` and `src/parts/WidgetKit-Containers.lua`,
     `-Text`, `-Button`, `-CheckBox`, `-Slider`, `-EditBox`, `-Dropdown`,
     `-ColorPicker`, `-ScrollList`, `-Position`, `-Renderer`, each with the
     file header and Contents list, `PART_REVISION = 1`, LuaCATS types and
     doc comments. Main-chunk locals: the core at most 120, each part at
     most 60 (the `lua_limits` ratchet entry for `WidgetKit.lua`, 189
     today, goes down).

5. Ownership:
   - The core's state keeps everything shared: types (with their free
     lists), records, layouts, prototypes, metatables, limits, focus,
     scratch tables, `helpers`, `parts` and `dispatch`. A part keeps its own
     data under `state.parts.<Part>` (the renderer's extension registries,
     the dropdown catcher, the list's dispatch entries) and never a copy of
     core state.
   - Frame scripts and long-lived callbacks call through `dispatch`
     (already true for the dropdown catcher, binding saves and list rows),
     so the newest revision of the part that wrote the entry serves widgets
     an older one built.
   - Upgrade from revision 13 or older, in place: the state is kept; for
     each type that has a PoolKit pool, the idle widgets are taken out of it
     (`Acquire` while `GetAvailableCount() > 0`, which never builds), put on
     the new free list, and the created, discarded and cap counts copied;
     the pool is then dropped and collected with its maps; borrowed widgets
     return to the free list when released. `state.scratch` (the PoolKit
     table pool) is dropped. Older revisions' members for absent parts are
     kept, as in point 2. Upgrade of a part: the higher part revision
     replaces members, constructors at equal versions and its extension
     entries. Upgrade of the core with parts loaded: the new core re-binds
     each part.
   - Known limit, documented in `docs/API.md` "Embedded copies and
     upgrades": when a core of revision 14 or later loads first and a
     single-file copy of revision 13 or older loads after it, the older
     copy yields (Registry selects the newer) and registers nothing; that
     addon's widgets whose parts no addon loaded raise the not-loaded error
     naming the part. Only a newer embedding of the older addon fixes it,
     as for any Kit whose newer revision a session selects. The opposite
     order (older first) keeps working.

6. Performance and memory. Today's figures measured 2026-11-15; the
   targets are estimates (each section's resident prototypes times 1.39,
   WidgetKit's measured ratio of resident bytes to prototype bytes without
   the pools) that phase 2 measures with the same scripts and reports
   against this table.

   | Resident (debug info kept) | Today | Target | AceGUI-3.0 counterpart |
   |---|---:|---:|---|
   | Core | 355.1 KB (everything) | at most 95 KB | AceGUI-3.0.lua 44.0 KB |
   | `Containers` | | at most 26 KB | Frame 18.0 + InlineGroup 4.8 + SimpleGroup 2.7 + ScrollFrame 11.3 = 36.8 KB |
   | `Text` | | at most 15 KB | Label 8.2 + Heading 3.8 = 12.0 KB |
   | `Button` | | at most 9 KB | Button 4.7 + Keybinding 13.1 = 17.8 KB |
   | `CheckBox` | | at most 8 KB | CheckBox 13.0 KB |
   | `Slider` | | at most 15 KB | Slider 15.4 KB |
   | `EditBox` | | at most 16 KB | EditBox 14.5 + MultiLineEditBox 20.1 = 34.6 KB |
   | `Dropdown` | | at most 24 KB | DropDown 36.4 + DropDown-Items 19.6 = 56.0 KB |
   | `ColorPicker` | | at most 13 KB | ColorPicker 11.2 KB |
   | `ScrollList` | | at most 29 KB | none |
   | `Position` | | at most 30 KB | none in Ace3 |
   | `Renderer` | | at most 53 KB | AceConfigDialog-3.0 91.6 KB (with AceConfigRegistry 25.7 KB) |
   | Core and every part | 355.1 KB | at most 335 KB | AceGUI-3.0.xml as shipped (core and 22 widget files) 347.5 KB |
   | Empty pools at load | 34.6 KB | 0 | none |
   | Upgrade residue | 14.1 KB | 0 (no widget built before the upgrade) | 0.2 KB |
   | Main-chunk locals | 189 | core at most 120, parts at most 60 | |

   What an addon holds, with the Kits it must embed (Registry 31.3 KB,
   PoolKit 78.9 KB, SignalKit 80.8 KB today):

   | Addon | Today | Target | Ace3 |
   |---|---:|---:|---:|
   | Core only (custom types) | 546.1 KB | at most 127 KB | LibStub + AceGUI core 46.6 KB; as shipped 350.1 KB |
   | A window: `Containers`, `Text`, `Button`, `CheckBox`, `EditBox` | 546.1 KB | at most 201 KB | the same five files by hand 109.8 KB; AceGUI-3.0.xml as shipped 350.1 KB |
   | Options rendering: `Renderer` and its parts | 546.1 KB | at most 306 KB (OptionsKit apart) | AceGUI as shipped + AceConfigDialog + AceConfigRegistry + CallbackHandler + LibStub 477.6 KB |

   Where the target stays above Ace3: the core is about twice AceGUI's
   core (validation, limits, secret checks and records that buy the
   documented guarantees), and Registry is twelve times LibStub. Against
   AceGUI as addons embed it (AceGUI-3.0.xml loads every widget file), every
   addon in the table holds less; against an AceGUI trimmed by hand to the
   same files, the window addon holds about 1.8× as much. Closing that is
   the shared-helper and shorter-prose work, not this record.

   Compile: an addon that embeds the window set compiles about a third of
   today's source (WidgetKit allocates 910 KB transient while loading
   today), and each further addon embedding it pays the same smaller
   amount.

   Widget cycles against AceGUI-3.0, same run (bench `widgets`, fake
   client, indicative):

   | Case | Today | Target |
   |---|---:|---:|
   | `cycle-label` | 0.79× | at most 0.75× |
   | `cycle-button` | 1.41× | at most 1.00× |
   | `cycle-checkbox` | 0.67× | at most 0.65× |
   | `cycle-slider` | 1.62× | at most 1.00× |
   | `cycle-editbox` | 1.02× | at most 0.95× |
   | Bytes per cycle | 0 | 0 |

   Basis: in the `Button` cycle the PoolKit layer is 105 of 456 VM
   instructions and 8 of 56 calls, the probe 5 `rawget` and 5 `type`
   calls, the three `pcall`s about 35 ns each beyond their bodies; the
   earlier prototype of the probe rule and the slider text alone reached
   1.32× on both. Phase 2 reports instruction and call counts per cycle
   beside the ratios, and names the remaining cost of any case that stays
   above its target.

7. Tests (Busted, `packages/widgetKit/tests/`; every existing spec keeps
   passing with the core and every part loaded; coverage floor kept, every
   part loaded by a spec of its own):
   - `Parts_spec.lua`: each part loaded alone after the core (types
     registered, members installed, `GetPartRevision`), a part before its
     core (the ADR message), `Position` without SignalKit, `Renderer`
     without one of its parts, every stub's message and level at the
     caller's line, `Create` of each absent base type naming its part,
     `GetTypeVersion` answering `nil`, `Frame:BindPosition` without
     `Position`, a part loaded twice (same revision returns), a higher part
     revision replacing members, constructors and extension entries, and a
     newer core re-binding loaded parts (a synthetic revision 15 copy).
   - `Pooling_spec.lua`: no free list before the first `Create`; cap,
     reuse, `exhausted`, version raise retiring idle and borrowed widgets,
     the cap grown within the ceiling, `GetStatistics` before and after first
     use, a raising and a contract-breaking constructor, the borrowed
     counts, layout scratch tables reused per depth with nothing allocated.
   - `Bootstrap_spec.lua` additions: upgrade from a revision 13 copy with
     every part (pooled widgets moved off PoolKit and reused, live widgets
     released into the free list, renderings and bindings kept, counts
     kept), upgrade from a revision 13 copy with the core only (its
     renderer, bindings, anchors and media pickers still serving), the
     revision 13 copy loading after a revision 14 core (yields; surface
     check passes; the not-loaded error for an absent part), and the
     residue: no function of the older file reachable after an upgrade with
     every part loaded (a reachability walk over `_G` and the registry, as
     the residue measurement does).
   - `Manifest_spec.lua`: runtime `REVISION`, every `PART_REVISION` and the
     manifest agree; the core's dependencies are Registry alone.
   - `RendererExtensions_spec.lua`: a test part registering a decorator, a
     kind override and a page style, each used by the renderer and replaced
     by a higher revision; the inline confirm as the default provider.
   - `FastPaths_spec.lua` additions: the probe resolved at load and a probe
     installed after load honoured; ADR 0002 receivers and keys (a secret
     reaches the index, modelled by the fixture's client rules); built-in
     hooks called without `pcall` and custom ones protected as before; the
     slider's labels written only on a range change and its text formatted
     only on a value change, the box written each time.
   - `Allocation_spec.lua` additions: zero bytes per warm cycle of the five
     bench types after the pooling change.
   - `ErrorLevels_spec.lua`: every stub and part-loading error at the
     caller's line.
   - The test environment loads the core and every part by default
     (`WidgetKitTestEnv`), with loaders for core-only and chosen parts.
   - Client suite `tests/client/MoltenCodesTest_WidgetKit` (never run):
     `GetPartRevision` for each part in the full bundle; a secret receiver
     and a secret user-data key meet the client's refusal (ADR 0002,
     consequence 3); the five bench widgets acquired, filled and released
     on real frames; `EXPECTED.md` updated.
   - Gates: stylua, `tooling.test.run widgetKit`, `tooling.test.coverage
     widgetKit`, lua-language-server on `src` and on the client suite,
     `tooling.lint`, `flavour_api --package widgetKit`, `tooling.spell`,
     `lua_limits` (ratchet lowered), `validate_repository` for the package.

8. Docs: `README.md` (what each part holds, the embeds command for the
   common selections, the AceGUI migration table mapping each
   `AceGUIWidget-*.lua` and `AceConfigDialog-3.0` to the part to embed),
   `docs/API.md` (Loading with parts, the parts table, `GetPartRevision`,
   the not-loaded errors, "Secret values" under ADR 0002, "Embedded copies
   and upgrades" for revision 14 and the known limit, the Deviations entry
   "One runtime file" replaced by the parts), `docs/INTERNALS.md` (free
   lists and generations, the part machinery, `bind`, stubs and inherited
   members, the renderer's extension points and their contract),
   `CHANGELOG.md` (0.5.0, revision 14), `tests/README.md`,
   `package.manifest.json` (`parts`, dependencies). Outside the package,
   with exact text in the phase 2 report: the `docs/EMBEDDING.md` footprint
   and parts blocks (generated), `docs/MIGRATING_FROM_ACE3.md` (AceGUI and
   AceConfigDialog rows naming parts), the ROADMAP placement of this
   record, the `packages/README.md` row, the coverage floor if parts change
   it, spell words, PanelKit's manifest contract and load check (its
   owner), and `tooling/bench` (`workloads.py` package list and the
   `Widgets.lua` adapter loading the parts; the client window workload).

9. Status: implemented 2026-11-15, 0.5.0, revision 14, 320 specs; panelKit
   0.1.2, revision 2 (contract on the Renderer part, GetPartRevision check).
   Core 112.9 KB (whole file 358.3 KB before; target 95), every part loaded
   383.5 KB (target 335; AceGUI-3.0.xml as shipped 357.3 KB); a typical window
   addon with the Kits it needs 555.6 to 233.7 KB, an options-rendering addon
   352.8 KB against Ace3's 486.7 KB; the core alone is 2.5x AceGUI's core and
   the window addon 2.1x AceGUI trimmed by hand to the same files. Upgrade
   residue 0. Widget cycles against AceGUI: Label 0.54x, Button 0.88x,
   CheckBox 0.44x, Slider 0.97x, EditBox 0.72x, 0 bytes per cycle. The main
   chunk is down to 118 locals.

**SettingsKit namespaces, the four AceDB scopes and the remaining AceDB callbacks** (two records)

Basis: the decision 18 Ace3 gap diagnosis (namespaces, scopes and callbacks;
usage counted in sixteen open-source Ace3 addons), ADRs 0001 and 0003, and
AceDB-3.0's behaviour, read for behaviour only (nothing copied). Measurements:
host Lua 5.1.5 on a loaded machine, so ratios, not absolute times, are the
evidence. "Measured" means run; "estimate" means priced from measurements.

**Client facts used**

Read 2026-11-15 from Gethe/wow-ui-source, branches `live` `297d7aa` (12.1.5,
70783), `classic` `e5d9b3a` (5.5.4, 70631), `classic_era` `4192ac6` (1.15.9,
70576), the commits `packages/apiKit/metadata/*/provenance.json` was captured
from.

| Function | `live` | `classic` (Mists) | `classic_era` | Notes |
|---|---|---|---|---|
| `UnitRace(unit)` → `localizedRaceName, englishRaceName, raceID` | documented, `UnitDocumentation.lua:2836`, `SecretWhenUnitIdentityRestricted = true`, `MayReturnNothing = true` | not documented; called by Blizzard's own UI: `Blizzard_CharacterFrame/Cata/PaperDollFrame.lua:3896` (`local race, fileName = UnitRace(unit)`) | not documented; called by Blizzard's own UI: `Blizzard_CharacterFrame/Vanilla/PaperDollFrame.lua:91` | AceDB keys `race` by the second result |
| `UnitFactionGroup(unit)` → `factionGroupTag, localized` | `UnitDocumentation.lua:1179`, no secret flag | `:689` | `:689` | already used by SettingsKit |
| `GetRealmName()` | in `metadata/retail/namespaces.json` | in `classic-mop` | in `classic-era` | already used |
| `GetCurrentRegion()` → `region` (number) | `LocaleDocumentation.lua:40` | `:38` | `:38` | |
| `GetCurrentRegionName()` → `regionName` (string) | `ExpansionDocumentation.lua:46` | absent from `ExpansionDocumentation.lua` | absent | AceDB calls it unguarded on every client (`AceDB-3.0.lua:285`), which suggests the classic clients have it undocumented; **not verified**, so SettingsKit guards it and falls back as AceDB does |
| `GetLocale()` → `localeName` | `LocaleDocumentation.lua:49` | `:47` | `:47` | |

The flavour gate was run on a scratch copy of the repository with the four
reads added through SettingsKit's existing `callHost` helper (which returns
nothing unless the global is a function): `python3 -m
tooling.validation.flavour_api --package settingsKit` passes, with `UnitRace`
and `GetCurrentRegionName` reported as **guarded** on `classic-mop` and
`classic-era`. An allow-list entry for them would therefore be stale, and the
gate fails stale entries. See the report for the shared-file text this leads
to (a `host_names.json` entry instead).

AceDB-3.0's rules, read at `ac3d122`:

- Scope keys (`AceDB-3.0.lua:255-291`), read once when the library loads:
  `race` = second result of `UnitRace("player")`; `factionrealm` =
  `UnitFactionGroup("player") .. " - " .. GetRealmName()`;
  `factionrealmregion` = that `.. " - " ..` region, where the region is
  `({ "US", "KR", "EU", "TW", "CN" })[GetCurrentRegion()]`, else
  `GetCurrentRegionName()` unless it is `""`, else `"TR"`;
  `locale` = `GetLocale():lower()`.
- Callbacks: `OnNewProfile(db, key)` when a profile section is first created
  (`:215`, lazily, on the first `db.profile` access after `New`, `SetProfile`
  or `ResetDB`); `OnProfileShutdown(db)` at the start of `SetProfile`, before
  anything changes (`:502`); `OnDatabaseShutdown(db)` at `PLAYER_LOGOUT`, for
  every database, before defaults are stripped (`:397`); `OnDatabaseReset(db)`
  in `ResetDB`, followed by `OnProfileChanged` (`:731-733`).
- Namespaces (`:743-786`, `initdb` `:296-384`, logout `:391-440`): a child
  database over `sv.namespaces[name]` in AceDB's own layout minus
  `profileKeys`; it shares the parent's profile key; `SetProfile`,
  `CopyProfile`, `ResetProfile` and `DeleteProfile` cascade to every
  registered child (each child fires its own callbacks) and, for copy, reset
  and delete, to the raw `profiles` of namespaces nobody registered this
  session; `ResetDB` rebuilds every child; children expose only
  `RegisterDefaults` and `ResetProfile` of the profile methods; at logout
  empty sections and empty profiles inside namespaces, then empty namespaces,
  are removed. `RegisterNamespace` raises for a name already registered;
  `GetNamespace(name, silent)` raises for a missing one unless `silent`.

Corpus facts that shaped the design (`ace3-gaps/corpus`):

- Namespaces: 8/16 addons, 63 registrations, 145 `GetNamespace` calls.
  `Bartender4/Options/PresetsForever.lua:40` and 25 more sites write presets
  through `db:GetNamespace("ActionBars").profile`, so a child's views must
  take validated writes like a database's.
- Callbacks registered **on a namespace**: `oRA3/modules/Cooldowns/Cooldowns.lua:1118`
  (`self.db` is the namespace from `:1042`) listens to `OnProfileShutdown`.
  So children carry their own profile signals; the parent's alone is not
  enough (the gap report's "fire the parent's signals once" is refined below).
- `OnNewProfile`: `Bartender4/Bartender4.lua:49` and `:112-118` rely on it
  firing for the **first** profile of a new character, created right after
  `New`. SettingsKit's `Open` creates that profile before any listener can
  connect, hence `db:IsNewProfile()` below.
- `BigWigs/Core/Core.lua:609` registers one namespace per boss module it
  loads, which is why the namespace bound defaults well above the gap
  report's 64.

Baseline measured for this record (one run, `bench-before.json`, against
AceDB-3.0 in the same run; MoltenCodes `ad2626a`, SettingsKit revision 14):

| Case | SettingsKit ns/op | AceDB ns/op | Ratio | SettingsKit B/op | AceDB B/op |
|---|---:|---:|---|---:|---:|
| open-empty | 6,624 | 2,190 | 3.03x | 3,691 | 3,299 |
| open-populated | 9,580 | 4,195 | 2.28x | 4,704 | 3,792 |
| switch-profile | 590 | 3,040 | 0.19x | 0 | 496 |
| read-default | 14.6 | 3.9 | 3.76x | 0 | 0 |
| read-saved | 10.4 | 3.5 | 2.95x | 0 | 0 |
| read-nested | 13.2 | 6.8 | 1.95x | 0 | 0 |
| read-entry-default | 21.0 | 10.9 | 1.93x | 0 | 0 |
| read-getter | 25.5 | 15.4 | 1.65x | 0 | 0 |
| write-scalar | 319 | 8.5 | different work | 0 | 0 |
| write-nested | 557 | 5.2 | different work | 0 | 0 |
| retained per open database | 4,400 B | 3,872 B | 1.14x | | |

Namespace costs measured outside the bench (scripts above, same host):

| Measurement | Value |
|---|---|
| AceDB `RegisterNamespace` with a small profile default, then one `child.profile` read | 2,696 ns, 3,297 B allocated, 3,294 B held per namespace |
| AceDB `SetProfile` between two existing profiles, no namespaces / 10 namespaces | 444 ns, 0 B / 10,524 ns, 2,044 B allocated |
| SettingsKit `Open` with a small profile-only schema, then one read (upper bound of a child's registration: it also creates the global, nine layout sections, runs the migration check and joins the logout list) | 6,900 ns, 4,764 B allocated, 4,472 B held |
| SettingsKit `SetProfile` between two existing profiles, one database | 780 ns, 0 B |
| Held by compiled chunks (`compile_held.lua`) | SettingsKit.lua 186.1 KB (5,390 lines); AceDB-3.0 36.4 KB; CallbackHandler-1.0 10.8 KB |

