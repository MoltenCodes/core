# Expected result: `/mct run brokerKit`

Installed with
`python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --package brokerKit`
for Retail, with `--flavour-dir _classic_era_` added for Classic Era or
`--flavour-dir _classic_` for Mists of Pandaria Classic, and nothing else
enabled in the client: no other addon, and in particular no addon that loads
LibStub (Titan Panel, Bazooka, ChocolateBar, any Ace3 addon). Run it out of
combat. The lines below are Retail's; "Per flavour" says what differs on the
two Classic clients.

## At login

One line from the harness:

```text
MoltenCodes Test: test suites loaded for brokerKit. Type /mct run brokerKit to run them; /mct help lists every command.
```

## After `/mct run brokerKit`

Within a few seconds, exactly these lines, in this order (`PASS` is green in
the client). The three allocation tests each run a full garbage collection
first, so the client may stutter for a moment:

```text
MoltenCodes Test: running brokerKit: 9 suites. Results follow when every test has finished.
MoltenCodes Test: PASS brokerKit.facade: Registry:Get('brokerKit', 1) is the BrokerKit facade with API 1, its ten methods, MAX_OBJECTS 256, MAX_ATTRIBUTES 32 and UNBOUNDED
MoltenCodes Test: PASS brokerKit.facade: the installed BrokerKit carries the revision of the committed manifest
MoltenCodes Test: PASS brokerKit.facade: the client's LibStub and LibDataBroker-1.1 are logged, GameTooltip has the methods a display calls, and the session has room for this run's objects under maxObjects
MoltenCodes Test: PASS brokerKit.objects: New hands back an object whose attributes read as plain fields: text, a FileDataID icon, value, OnClick, a custom table, type 'data source' by default and the read-only name
MoltenCodes Test: PASS brokerKit.objects: a launcher keeps its type, and the object is an empty proxy: rawget and next see nothing, getmetatable answers 'BrokerKit.Object' and setmetatable is refused
MoltenCodes Test: PASS brokerKit.objects: a plain field write and Set store the same way: text, value, label, a custom table, and nil clearing any attribute but type
MoltenCodes Test: PASS brokerKit.signals: a per-attribute listener gets (object, 'text', value, previous) after the value is stored and before the any-attribute listener, for a field write and Set alike
MoltenCodes Test: PASS brokerKit.signals: writing the value an attribute holds fires nothing, a new attribute arrives with previous nil and a cleared one with value nil, and a disconnected listener hears nothing
MoltenCodes Test: PASS brokerKit.signals: OnObjectAdded fires once per New with the new object, which BrokerKit:Get already finds
MoltenCodes Test: PASS brokerKit.signals: a listener error propagates to the line that wrote, after the value was stored
MoltenCodes Test: PASS brokerKit.enumeration: Objects lists this test's names sorted with < in the client's byte order ('Bar 10' before 'Bar 2', upper case before lower case), in a fresh array every call
MoltenCodes Test: PASS brokerKit.enumeration: Iterate walks the order of Objects, hands out each name's object, skips an object created during the walk yet visits every name present at its start, and the next walk has it
MoltenCodes Test: PASS brokerKit.display: OnTooltipShow called as a display calls it fills the client's GameTooltip: two lines read back through NumLines and GameTooltipTextLeft1 and 2, hidden again in the same step
MoltenCodes Test: PASS brokerKit.display: OnClick is stored and never called by BrokerKit; a display's call with UIParent and a mouse button reaches it, and a replaced OnClick fires OnChange and is the one called next
MoltenCodes Test: PASS brokerKit.libDataBroker: without LibStub, ExposeToLibDataBroker and AdoptFromLibDataBroker return false, 'absent', and so they do with a LibStub that holds no LibDataBroker-1.1
MoltenCodes Test: PASS brokerKit.libDataBroker: ExposeToLibDataBroker registers objects into the stand-in LibDataBroker-1.1 with their attributes, follows later objects and each field write with one data-object write, and a second call returns false, 'already'
MoltenCodes Test: PASS brokerKit.libDataBroker: AdoptFromLibDataBroker wraps the stand-in's data objects as foreign objects holding copies of their attributes, follows objects created later, even one nobody wrote to yet, and a second call returns false, 'already'
MoltenCodes Test: PASS brokerKit.libDataBroker: a foreign object is read-only: a field write and Set are refused at the calling line naming it foreign, New of its name is refused, and a write into its data object reaches BrokerKit and fires OnChange once
MoltenCodes Test: PASS brokerKit.libDataBroker: with both directions on nothing echoes: a new object is not adopted back and fires OnObjectAdded once, its write is one data-object write and one OnChange, and another addon's write into its data object is ignored
MoltenCodes Test: PASS brokerKit.libDataBroker: a display reading the stand-in calls our OnClick with UIParent through the data object, and a foreign OnTooltipShow read through BrokerKit fills GameTooltip, hidden again in the same step
MoltenCodes Test: PASS brokerKit.allocation: reading attributes as plain fields, object.name, object:Get and BrokerKit:Get allocate nothing over 5000 rounds
MoltenCodes Test: PASS brokerKit.allocation: field writes and Set of a new value with a per-attribute and an any-attribute listener connected, and writes of the value already held, allocate nothing over 5000 rounds
MoltenCodes Test: PASS brokerKit.allocation: 500 full Iterate walks over every object of the session allocate nothing while no object is added
MoltenCodes Test: PASS brokerKit.errors: a field write of the wrong type, clearing type, writing name and Set of a table icon are refused at the writing line in BrokerKitSuite.lua
MoltenCodes Test: PASS brokerKit.errors: New refuses a taken name, a definition that is not a table, a reserved or mistyped attribute and a call with a dot at the calling line, and a refused definition leaves no object behind
MoltenCodes Test: PASS brokerKit.errors: an object method called with a dot, a listener that is not a function, Get of 'name' and IsForeign of UIParent are refused at the calling line
MoltenCodes Test: PASS brokerKit.errors: SetLimits with an unknown limit, or with maxObjects 0 beside a valid maxAttributes, is refused at the calling line and the limits stay as they were
MoltenCodes Test: PASS brokerKit.secrets: the client's handling of a secret key on a broker object is logged: reading and writing object[secret] both raise, and the object is unchanged
MoltenCodes Test: PASS brokerKit.secrets: a secret text is refused at the calling line by a field write, by Set and in a New definition; the object keeps its text, no listener runs and no object is created
MoltenCodes Test: PASS brokerKit.secrets: a secret custom attribute is stored without comparison: read back secret by field and Get, every write of it fires, listeners get it still secret, and clearing it fires with the secret as previous
MoltenCodes Test: PASS brokerKit.secrets: secret names are refused before any comparison at the calling line: New and Get of a secret name, Set, Get and OnChange of a secret attribute name, a secret receiver and a secret SetLimits value; the limits stay as they were
MoltenCodes Test: PASS brokerKit.secrets: a secret custom attribute of an exposed object is never written into the stand-in LibDataBroker-1.1, and a secret another addon writes into a foreign data object reaches BrokerKit still secret
MoltenCodes Test: brokerKit: 32 passed, 0 failed, 0 skipped, 0 timed out (32 tests)
MoltenCodes Test: results saved in MoltenCodesTestResults; /reload or log out to write them to disk.
```

Running it again in the same session prints the same lines, up to six full
runs per session (see *What stays for the session*). The logs of a later run
differ in one place: the bridge calls answer `false, already` instead of
`true`, because the first run already connected BrokerKit to the stand-in
library; each such log line says whether the call was the session's first.

## Visible side effects

None. Nothing is drawn, no sound plays, no frame is created, no chat line other
than the harness's appears, and no client setting (CVar) changes.

Two tests fill the client's `GameTooltip` the way a LibDataBroker display does,
and neither shows it: each calls `GameTooltip:SetOwner(UIParent, "ANCHOR_NONE")`
(an owner and no position), calls the object's `OnTooltipShow` with
`GameTooltip`, reads the lines back through `GameTooltip:NumLines()` and the
`GameTooltipTextLeft<n>` FontStrings, and calls `GameTooltip:Hide()`, all in one
synchronous step of the test, so no frame is ever rendered with the tooltip
filled; `Show` is never called. The one thing a player could notice: a tooltip
that was open for something under the mouse at that moment closes, as it does
whenever an addon uses `GameTooltip`.

## What stays for the session

**The objects.** BrokerKit has no removal (docs/API.md, "BrokerKit:New"), so
every object a test creates stays until `/reload`. Each has a name no other run
uses, `MoltenCodesTest_BrokerKit <serial> <label>`, the serial counting up from
001 for the session. A full run creates **39 objects** (6 of them adopted from
the stand-in LibDataBroker), all counted against BrokerKit's shared
`maxObjects` of 256, so **six full runs** fit in one session. Before a seventh,
the third facade test fails with
`only <n> more objects fit under maxObjects 256 and a run creates 39; /reload to start over, because objects live for the session`,
and later tests fail at `BrokerKit:New refuses more than 256 objects`: `/reload`
and run again. BrokerKit's limits are never changed; the `SetLimits` calls are
refusals the tests check.

**The LibDataBroker stand-in.** When the client has no `LibStub`, each bridge
test installs the LibStub of `LibDataBrokerStandIn.lua` as the global `LibStub`,
holding a LibDataBroker-1.1 stand-in written for this addon from the library's
documented contract (no third-party code is shipped), and the After hook of its
suite removes the global again, pass or fail. BrokerKit's bridge is one-way:
once it exposed into or adopted from a library, it keeps that library for the
session. After the first bridge test BrokerKit therefore keeps the stand-in
library (one per session), and every object created later in the session, by
any addon, is also written into it. Nobody else can reach it, and `/reload` ends
it. The global `LibStub` never stays.

**Connections.** Every `OnChange` and `OnObjectAdded` connection and every
callback a test registers on the stand-in is disconnected by the After hook of
its suite. Nothing is written to a global or a saved variable other than the
harness's own results.

### With another addon that loads LibStub

The bridge tests never replace a real `LibStub`: exposing is one-way for the
session and would put the test objects into the player's own display addons.
The third facade test then logs the real LibStub, the minor version of its
LibDataBroker-1.1 and its number of data objects, and these seven lines replace
their `PASS` lines:

```text
MoltenCodes Test: SKIP brokerKit.libDataBroker: without LibStub, ExposeToLibDataBroker and AdoptFromLibDataBroker return false, 'absent', and so they do with a LibStub that holds no LibDataBroker-1.1 -- another addon loaded a real LibStub; exposing is one-way for the session and would put test objects into the player's display addons, so the bridge was not exercised (disable every other addon to run it)
MoltenCodes Test: SKIP brokerKit.libDataBroker: ExposeToLibDataBroker registers objects into the stand-in LibDataBroker-1.1 with their attributes, follows later objects and each field write with one data-object write, and a second call returns false, 'already' -- another addon loaded a real LibStub; exposing is one-way for the session and would put test objects into the player's display addons, so the bridge was not exercised (disable every other addon to run it)
MoltenCodes Test: SKIP brokerKit.libDataBroker: AdoptFromLibDataBroker wraps the stand-in's data objects as foreign objects holding copies of their attributes, follows objects created later, even one nobody wrote to yet, and a second call returns false, 'already' -- another addon loaded a real LibStub; exposing is one-way for the session and would put test objects into the player's display addons, so the bridge was not exercised (disable every other addon to run it)
MoltenCodes Test: SKIP brokerKit.libDataBroker: a foreign object is read-only: a field write and Set are refused at the calling line naming it foreign, New of its name is refused, and a write into its data object reaches BrokerKit and fires OnChange once -- another addon loaded a real LibStub; exposing is one-way for the session and would put test objects into the player's display addons, so the bridge was not exercised (disable every other addon to run it)
MoltenCodes Test: SKIP brokerKit.libDataBroker: with both directions on nothing echoes: a new object is not adopted back and fires OnObjectAdded once, its write is one data-object write and one OnChange, and another addon's write into its data object is ignored -- another addon loaded a real LibStub; exposing is one-way for the session and would put test objects into the player's display addons, so the bridge was not exercised (disable every other addon to run it)
MoltenCodes Test: SKIP brokerKit.libDataBroker: a display reading the stand-in calls our OnClick with UIParent through the data object, and a foreign OnTooltipShow read through BrokerKit fills GameTooltip, hidden again in the same step -- another addon loaded a real LibStub; exposing is one-way for the session and would put test objects into the player's display addons, so the bridge was not exercised (disable every other addon to run it)
MoltenCodes Test: SKIP brokerKit.secrets: a secret custom attribute of an exposed object is never written into the stand-in LibDataBroker-1.1, and a secret another addon writes into a foreign data object reaches BrokerKit still secret -- another addon loaded a real LibStub; exposing is one-way for the session and would put test objects into the player's display addons, so the bridge was not exercised (disable every other addon to run it)
```

The totals line then reads `25 passed, 0 failed, 7 skipped, 0 timed out (32 tests)`.
Disable every other addon and `/reload` to run the bridge.

### On a client without secret values

The five `brokerKit.secrets` tests need the client's `issecretvalue` and
`secretwrap`. `secretwrap` is the one documented way to obtain a genuine secret
out of combat without side effects: the client's own API documentation
(`FrameScriptDocumentation`, mirrored in
`packages/apiKit/metadata/retail/namespaces.json`) lists it with no
restriction, and it only converts the values handed to it. Retail 12.1 has
both. A client without them prints these five lines instead:

```text
MoltenCodes Test: SKIP brokerKit.secrets: the client's handling of a secret key on a broker object is logged: reading and writing object[secret] both raise, and the object is unchanged -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP brokerKit.secrets: a secret text is refused at the calling line by a field write, by Set and in a New definition; the object keeps its text, no listener runs and no object is created -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP brokerKit.secrets: a secret custom attribute is stored without comparison: read back secret by field and Get, every write of it fires, listeners get it still secret, and clearing it fires with the secret as previous -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP brokerKit.secrets: secret names are refused before any comparison at the calling line: New and Get of a secret name, Set, Get and OnChange of a secret attribute name, a secret receiver and a secret SetLimits value; the limits stay as they were -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP brokerKit.secrets: a secret custom attribute of an exposed object is never written into the stand-in LibDataBroker-1.1, and a secret another addon writes into a foreign data object reaches BrokerKit still secret -- the client has no issecretvalue and secretwrap; the secret path was not exercised
```

The totals line then reads `27 passed, 0 failed, 5 skipped, 0 timed out (32 tests)`.
On Retail 12.1 with only the MoltenCodes addons enabled, any `SKIP` is
unexpected.

## Per flavour

Nothing this suite or BrokerKit uses differs between the three clients.
BrokerKit itself needs nothing from the client but `issecretvalue`, which the
client documentation of Retail, Classic Era and Mists Classic lists
(`packages/apiKit/metadata/<flavour>/namespaces.json`, with `secretwrap`), and
the global `LibStub`, which is never the client's own. The suite also uses
`UIParent`, `GameTooltip` with `SetOwner`, `AddLine`, `NumLines`, `IsShown`,
`Hide` and `GetName`, and the `GameTooltipTextLeft<n>` FontStrings: the
client's own interface code, which the documentation does not list and every
flavour has. The FileDataID `134400` (the question-mark icon) is only stored
as an attribute and compared, never loaded. No test waits for an event and
none needs combat.

| Client | Totals line with no LibStub | Tests that `SKIP` |
|---|---|---|
| Retail 12.1 | `MoltenCodes Test: brokerKit: 32 passed, 0 failed, 0 skipped, 0 timed out (32 tests)` | none |
| Classic Era 1.15 | the same as Retail when `Harness:CanMakeSecrets()` is `true`; otherwise `27 passed, 0 failed, 5 skipped, 0 timed out (32 tests)` | none, or the five `brokerKit.secrets` lines below when the client makes no secrets |
| Mists of Pandaria Classic 5.5 | the same as Retail when `Harness:CanMakeSecrets()` is `true`; otherwise `27 passed, 0 failed, 5 skipped, 0 timed out (32 tests)` | none, or the five `brokerKit.secrets` lines below when the client makes no secrets |

With another addon's LibStub the totals line is
`MoltenCodes Test: brokerKit: 25 passed, 0 failed, 7 skipped, 0 timed out (32 tests)`
on all three, with the seven `SKIP` lines of that section.

**Secret values on the Classic clients.** Both Classic clients publish
`issecretvalue` and `secretwrap`, but whether `secretwrap` hands back a value
that `issecretvalue` reports as secret there cannot be read from the
documentation. The suite asks the harness once, at load:
`Harness:CanMakeSecrets()` wraps one value with `secretwrap` and asks
`issecretvalue` about it. When it answers `true`, the five `brokerKit.secrets`
tests run and the run is the same as Retail's. When it answers `false`, they
are registered as skipped and print these lines instead:

```text
MoltenCodes Test: SKIP brokerKit.secrets: the client's handling of a secret key on a broker object is logged: reading and writing object[secret] both raise, and the object is unchanged -- the client makes no secret values (issecretvalue does not report what secretwrap returns as secret)
MoltenCodes Test: SKIP brokerKit.secrets: a secret text is refused at the calling line by a field write, by Set and in a New definition; the object keeps its text, no listener runs and no object is created -- the client makes no secret values (issecretvalue does not report what secretwrap returns as secret)
MoltenCodes Test: SKIP brokerKit.secrets: a secret custom attribute is stored without comparison: read back secret by field and Get, every write of it fires, listeners get it still secret, and clearing it fires with the secret as previous -- the client makes no secret values (issecretvalue does not report what secretwrap returns as secret)
MoltenCodes Test: SKIP brokerKit.secrets: secret names are refused before any comparison at the calling line: New and Get of a secret name, Set, Get and OnChange of a secret attribute name, a secret receiver and a secret SetLimits value; the limits stay as they were -- the client makes no secret values (issecretvalue does not report what secretwrap returns as secret)
MoltenCodes Test: SKIP brokerKit.secrets: a secret custom attribute of an exposed object is never written into the stand-in LibDataBroker-1.1, and a secret another addon writes into a foreign data object reaches BrokerKit still secret -- the client makes no secret values (issecretvalue does not report what secretwrap returns as secret)
```

and the totals line reads
`MoltenCodes Test: brokerKit: 27 passed, 0 failed, 5 skipped, 0 timed out (32 tests)`
(no LibStub) or
`MoltenCodes Test: brokerKit: 21 passed, 0 failed, 11 skipped, 0 timed out (32 tests)`
(another addon's LibStub, whose six `libDataBroker` `SKIP` lines then stand beside these five).
These skips say the client makes no secrets, so BrokerKit has nothing to refuse
there: it treats a value as secret only when `issecretvalue` says so. On
Retail 12.1 these lines are unexpected.

## What each test proves

| Test | Proves in the real client |
|---|---|
| `Registry:Get('brokerKit', 1) is the BrokerKit facade ...` | The facade the client loaded is API 1 with all ten methods, `MAX_OBJECTS` 256, `MAX_ATTRIBUTES` 32 and the `UNBOUNDED` sentinel. The log gives the session's two limits. |
| `the installed BrokerKit carries the revision ...` | Registry's selected revision and the facade's `REVISION` are both the committed manifest's, not an older or newer embedded copy. |
| `the client's LibStub and LibDataBroker-1.1 are logged, ...` | The log says whether a real `LibStub` is loaded and, when it is, LibDataBroker-1.1's minor version and its number of data objects (only read, never used). `GameTooltip` has `SetOwner`, `AddLine`, `NumLines`, `IsShown`, `Hide` and `GetName`. The log gives the objects already in the session and the room left; fewer than 39 fails the test with the `/reload` advice. |
| `New hands back an object whose attributes read as plain fields ...` | `New` copies the definition (a later change to it changes nothing, and nothing is written into it), reads `text`, the FileDataID `icon` 134400, `value`, `suffix`, `OnClick` and a custom table back as plain fields and through `Get`, defaults `type` to `"data source"`, and `BrokerKit:Get` finds the same object. |
| `a launcher keeps its type, and the object is an empty proxy ...` | The LibDataBroker proxy idiom on the client's Lua: `rawget` and `next` see nothing, `getmetatable` answers `"BrokerKit.Object"`, and `setmetatable` raises (the message is logged). |
| `a plain field write and Set store the same way ...` | `object.text = ...` and `object:Set(...)` share one write path; writing `nil` clears `text`, `label` and a custom attribute; `type` can change to `"launcher"`; the proxy stays empty. |
| `a per-attribute listener gets (object, 'text', value, previous) ...` | Listeners run after the value is stored (`object.text` already reads the new value), the per-attribute list before the any-attribute list, with the object itself and the previous value, for both write forms. |
| `writing the value an attribute holds fires nothing, ...` | A same-value write (field or `Set`) and `nil` over nothing fire nothing; a new attribute arrives with `previous` nil and a cleared one with `value` nil; `Disconnect` stops delivery. |
| `OnObjectAdded fires once per New ...` | One delivery per object, after `Get` already finds it. |
| `a listener error propagates to the line that wrote, ...` | A raising listener's error reaches the writer (the text is logged) and the value was stored first. |
| `Objects lists this test's names sorted with < ...` | The client's string comparison gives the documented byte order: `Bar 10`, `Bar 2`, `Beta`, `Zulu`, `alpha`. Two calls hand out two different arrays with equal contents, and changing one does not change the next. The log gives the session's object count. |
| `Iterate walks the order of Objects, ...` | A walk visits exactly the names `Objects` listed at its start, in that order, each with the object `Get` returns; an object created during the walk is not visited, and the next walk has it. |
| `OnTooltipShow called as a display calls it fills the client's GameTooltip ...` | The callback receives the client's `GameTooltip` itself; after `AddLine` twice, `NumLines()` is 2 and `GameTooltipTextLeft1` and `2` read the two lines; after `Hide`, `IsShown()` is false. The log gives the lines, `IsShown()` before `Hide` (expected `false`: nothing called `Show`) and `NumLines()` after `Hide`. |
| `OnClick is stored and never called by BrokerKit; ...` | Creating and writing an object never calls `OnClick`; a display's call with `UIParent` and `"LeftButton"` reaches the handler; replacing `OnClick` fires `OnChange("OnClick")` with the new and the old function, and the next call with `"RightButton"` reaches the new one. |
| `without LibStub, ExposeToLibDataBroker and AdoptFromLibDataBroker return false, 'absent', ...` | On the real client with no LibStub both bridge calls return `false, "absent"`, and still do with the stand-in LibStub that holds no LibDataBroker-1.1. |
| `ExposeToLibDataBroker registers objects into the stand-in ...` | An object created before the call becomes a data object with its `type`, `text`, `icon` and custom attribute; one created after appears at once and a display registered on the library is told once; a field write is exactly one data-object write, one `LibDataBroker_AttributeChanged` for that name and one `OnChange`; a same-value write is none; a second call answers `false, "already"`. The first call of the session answers `true` (logged). |
| `AdoptFromLibDataBroker wraps the stand-in's data objects ...` | Data objects another addon created before and after the call become foreign objects (`IsForeign` true) holding copies of their attributes, `OnObjectAdded` fires once for each; a data object created without attributes (the real library's `pairs` raises for it) is adopted empty and fills on its first write; a second call answers `false, "already"`. |
| `a foreign object is read-only: ...` | A write into the foreign data object reaches BrokerKit and fires `OnChange` once with the previous value, and nothing is written back (one data-object write in all); a field write and `Set` on the foreign object raise at this file's calling line naming it foreign; `New` of its name raises `... is already taken by a foreign LibDataBroker object`. |
| `with both directions on nothing echoes: ...` | Exposing and adopting at once: a new object is not adopted back (`OnObjectAdded` once, `IsForeign` false), its write is one data-object write and one `OnChange`, and another addon writing into our data object changes nothing on our side. |
| `a display reading the stand-in calls our OnClick ...` | What a LibDataBroker display does: it reads our `OnClick` from the data object and calls it with `UIParent`, and a foreign `OnTooltipShow`, read through BrokerKit, fills `GameTooltip` with its line, hidden again in the same step. |
| `reading attributes as plain fields, object.name, object:Get and BrokerKit:Get ...` | docs/API.md's "No function call, no allocation" for reads, on the client's collector: after a full collection in its own step and one warm-up round, 5000 rounds of five reads move `collectgarbage("count")` by at most 1 KB. |
| `field writes and Set of a new value with a per-attribute and an any-attribute listener connected, ...` | The same for writes: four changing writes (two field writes, two `Set`s) with both listener lists connected and two unchanged writes per round, 5000 rounds; the listeners ran exactly as often as documented. The log says whether the object was also mirrored into the stand-in (a later run: yes). |
| `500 full Iterate walks over every object of the session ...` | "`Iterate` unchanged ... No allocation" over every object of the session; the log gives the object count. |
| `a field write of the wrong type, clearing type, writing name and Set of a table icon ...` | Each refusal of a field write names this file at the writing line, with docs/API.md's wording, and the object is unchanged. |
| `New refuses a taken name, a definition that is not a table, ...` | Each `New` refusal, and a call with a dot, at the calling line; a refused definition creates no object. |
| `an object method called with a dot, a listener that is not a function, ...` | The receiver check of object methods, both listener checks, `Get("name")` and `IsForeign(UIParent)`, each at the calling line. |
| `SetLimits with an unknown limit, or with maxObjects 0 ...` | Both refusals at the calling line; the whole table is checked before anything changes, so the valid `maxAttributes = 64` beside the bad `maxObjects` is not applied. |
| `the client's handling of a secret key on a broker object is logged: ...` | `object[secret]` read and write both raise on the client; the log gives both messages (the client's own `cannot be indexed with secret keys`, or BrokerKit's `attribute name must not be a secret value` if the client let `__newindex` run). |
| `a secret text is refused at the calling line ...` | A `secretwrap` string for the known attribute `text` is refused by a field write, `Set` and a `New` definition with `... attribute "text" must not be a secret value`, BrokerKit's own message, so it was found before any comparison; no listener ran and no object was created. |
| `a secret custom attribute is stored without comparison: ...` | A secret number stored as a custom attribute reads back still secret (type `number`) by field and `Get`; each of three writes of the same secret fires, because a secret is never compared; the listener receives it still secret; clearing it fires with the secret as `previous`. |
| `secret names are refused before any comparison ...` | Secret object names (`New`, `Get`), secret attribute names (`Set`, `Get`, `OnChange`), a secret receiver and a secret `SetLimits` value, each at the calling line; the limits are unchanged. |
| `a secret custom attribute of an exposed object is never written into the stand-in ...` | The secret is stored on our object and never reaches the data object (no write, no secret received); a secret another addon writes into a foreign data object reaches BrokerKit's `OnChange` still secret and is stored. |

## What counts as unexpected

- Any `FAIL` or `TIMEOUT` line, a `SKIP` line when only the MoltenCodes addons
  are enabled, or a totals line other than
  `32 passed, 0 failed, 0 skipped, 0 timed out (32 tests)`, on any of the three
  clients, apart from the secrets skips "Per flavour" describes for the
  Classic clients.
- No login line, or `Expected.lua is missing`: the harness or the installer did
  not run as intended.
- A Lua error window or a BugSack entry naming `MoltenCodes`,
  `MoltenCodesTest` or `MoltenCodesTest_BrokerKit`. Every error the suite
  provokes is caught by the test itself.
- The tooltip becoming visible at any moment of the run, or the log line
  `shown before Hide: true`: something called `Show`.
- An allocation test failing: its log gives the measured delta. Say which other
  addons are enabled.
- `the installed BrokerKit carries the revision ...` failing: another enabled
  addon embeds a different BrokerKit copy.
- The third facade test failing with `only <n> more objects fit` on the first
  run after a login or `/reload`: another addon created objects in BrokerKit.
- A `brokerKit.secrets` test failing with "secretwrap raised" or "secretwrap
  returned a value issecretvalue does not report as secret": the client's
  secret functions behave differently from their documentation.

## What to send back

1. The chat lines above as they appeared (a screenshot, or a copy of the chat
   log), including any line that differs.
2. After `/reload` or a logout, the file
   `/Applications/World of Warcraft/<flavour folder>/WTF/Account/<ACCOUNT>/SavedVariables/MoltenCodesTest.lua`,
   where the folder is `_retail_`, `_classic_era_` or `_classic_`.
   It holds the full report, each test's logs (the LibStub facts, the object
   count and room, the bridge answers and whether each was the session's first,
   the tooltip lines, the memory deltas, the client's own error messages with
   their paths) and the client facts. Lua shortens a long file path from the
   left, so a logged message may start with `...`; the tests compare only the
   `BrokerKitSuite.lua:<line>` part.
3. The text of any Lua error, with `/console scriptErrors 1` turned on.
4. The list of other enabled addons, when a test failed or was skipped.
