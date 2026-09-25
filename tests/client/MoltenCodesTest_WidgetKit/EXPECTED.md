# Expected result: `/mct run widgetKit`

Installed with
`python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --package widgetKit`
and nothing else from the MoltenCodes framework enabled in the client. Run it
out of combat, with no options window of another addon and no colour picker
open.

## At login

One line from the harness:

```text
MoltenCodes Test: test suites loaded for widgetKit. Type /mct run widgetKit to run them; /mct help lists every command.
```

## After `/mct run widgetKit`

Within about five seconds, exactly these lines, in this order (`PASS` is green
in the client). The allocation tests run full garbage collections, so the
client may stutter for a moment; the List test waits for one rendered frame:

```text
MoltenCodes Test: running widgetKit: 10 suites. Results follow when every test has finished.
MoltenCodes Test: PASS widgetKit.facade: Registry:Get('widgetKit', 1) is the WidgetKit facade with API 1, its sixteen methods, the four Anchor functions, the defaults 256/256/16 and UNBOUNDED, and the twelve base types at their documented versions (3, ScrollFrame and Spacer 1)
MoltenCodes Test: PASS widgetKit.facade: the installed WidgetKit carries the revision of the committed manifest
MoltenCodes Test: PASS widgetKit.facade: the client has CreateFrame and UIParent, and OptionsKit, MediaKit and SchedulerKit are registered; ColorPickerFrame, the secret functions, ACCEPT, NOT_BOUND and UIParent's rect and scale are logged
MoltenCodes Test: PASS widgetKit.types: text getters answer "" once cleared, as docs/API.md says, on the client's font strings, buttons and edit boxes: Label, Heading, Button, EditBox and Dropdown texts, Frame and Group titles and a CheckBox label, after a fresh Create and after SetText(nil)
MoltenCodes Test: PASS widgetKit.types: Frame: a 700x500 movable, resizable window with an empty title; SetTitle, SetMovable and SetResizable reach the frame; its close button, title-bar drag stop and sizer fire OnClose, OnMoved and OnResize; release and reuse give the same frame back at its defaults
MoltenCodes Test: PASS widgetKit.types: Group: 300x16 with no title, a List layout and room for 256 children; a title moves the content 18 pixels down and a layout grows the group to its content plus insets; release and reuse give the same frame back at its defaults
MoltenCodes Test: PASS widgetKit.types: ScrollFrame: 300x200 with nothing to scroll; a 500-pixel child gives a 280-pixel scroll child, a 300-pixel range and a shown scrollbar; SetScroll clamps; the client's mouse-wheel script scrolls 40 pixels; release and reuse reset the scroll
MoltenCodes Test: PASS widgetKit.types: Label: 200 wide and empty in GameFontHighlightSmall; its height follows the client's measure of its text and grows when the text wraps; SetColor, SetJustifyH, SetFontObject and SetDisabled reach the font string; release and reuse give an empty label
MoltenCodes Test: PASS widgetKit.types: Button: 200x24, empty and enabled; SetText fires nothing while a real Click fires OnClick with the mouse button; a disabled button ignores clicks; key capture listens after a click, takes F, cancels on ESCAPE and unbinds on a right click; release and reuse clear the text
MoltenCodes Test: PASS widgetKit.types: CheckBox: 200x24, unchecked with an empty label; SetValue shows the value on the real check button and fires nothing; a real Click cycles unchecked, checked and, with three states, the third, firing OnValueChanged; a disabled box ignores clicks; release and reuse uncheck it
MoltenCodes Test: PASS widgetKit.types: Slider: 0 to 100 in steps of 1 at 0; SetSliderValues and SetValue snap, clamp and show the value without firing; the client's slider and the value box's Enter script fire OnValueChanged once per change; percent mode shows 35%; release and reuse restore 0 to 100
MoltenCodes Test: PASS widgetKit.types: EditBox: 200x44, single-line and empty; SetText and the client's own SetText fire nothing; the Enter and Escape scripts fire OnEnterPressed and OnEscapePressed; multi-line mode keeps the text and its accept button fires; SetFocus bookkeeping follows the widget; release and reuse empty it
MoltenCodes Test: PASS widgetKit.types: Dropdown: 200x44 and empty; SetList sorts by label then key, SetValue shows the label and fires nothing; PickIndex and a real click on a list row fire OnValueChanged; the list opens on UIParent at FULLSCREEN_DIALOG with the catcher and closes; release and reuse empty it
MoltenCodes Test: PASS widgetKit.types: ColorPicker: white and opaque; SetColor fires nothing; OpenPicker opens the client's ColorPickerFrame with the colour, its swatch and cancel callbacks fire OnValueChanged, a disabled picker opens nothing, and a release disarms the callbacks of the previous use
MoltenCodes Test: PASS widgetKit.types: Heading: 200x18, full width and empty with its two lines meeting in the middle; SetText centres the text between the lines, measured by the client; SetDisabled greys it; release and reuse give an empty full-width heading
MoltenCodes Test: PASS widgetKit.types: Spacer: 10x8; SetWidth, SetHeight, SetFullWidth and SetRelativeWidth reach the frame and the size requests, a full width clears a relative one and back; release and reuse give a 10x8 spacer with no requests
MoltenCodes Test: PASS widgetKit.layout: List stacks shown children from the content's top on real frames: explicit heights, a full-width child across the content, a half-width child, a hidden child left unanchored, a wrapped Label measured by the client and a nested Group whose growth moves the parent in the same pass
MoltenCodes Test: PASS widgetKit.layout: Fill anchors the first shown child to the content's corners, skipping a hidden one, and a nested ScrollFrame then sizes its scroll child to the 280-pixel viewport with a 300-pixel range
MoltenCodes Test: PASS widgetKit.layout: Flow places children left to right on real frames and wraps before one that would pass the edge, gives a full-width child a row of its own and a full-height child the height left, and keeps ten tenths of a 107-pixel row on one row
MoltenCodes Test: PASS widgetKit.anchors: Anchor.Normalize turns the SetPoint argument forms into anchors on a real frame: nil as the parent, UIParent as its global name, an unnamed parent as the frame itself, missing offsets as 0 and the frame's scale
MoltenCodes Test: PASS widgetKit.anchors: Anchor.Read of a real frame names UIParent by its global name; Anchor.Apply of that anchor puts another frame on the same rect with the anchor's scale; an unknown relative name leaves the frame alone
MoltenCodes Test: PASS widgetKit.anchors: a window's position binding captures the nearest point of UIParent from the client's rects (TOPLEFT, BOTTOMRIGHT, CENTER, TOP), saves a plain table after Flush, and a second binding restores that anchor onto another frame
MoltenCodes Test: PASS widgetKit.media: CreateMediaPicker lists MediaKit's font and statusbar names in MediaKit's order, PickIndex fires each name, and RenderOptions with options.media draws a select over MediaKit's fonts that writes the picked name
MoltenCodes Test: PASS widgetKit.renderer: RenderOptions draws one widget per visible option into a hidden container, in order, hidden ones skipped, each showing the value Get returns
MoltenCodes Test: PASS widgetKit.renderer: user input through the rendered widgets reaches tree:Set, a Validate refusal is shown in a Label right below the edit box and cleared by the next accepted write, tree:Set from code refreshes the widget in place, and a real click on the execute Button runs func
MoltenCodes Test: PASS widgetKit.renderer: Release gives every rendered widget back and empties the container; releasing a container releases a rendering drawn into it first
MoltenCodes Test: PASS widgetKit.allocation: Create and Release of each of the twelve base types again allocate nothing and hand back the same widget, 500 cycles each
MoltenCodes Test: PASS widgetKit.allocation: PerformLayout of a List of ten children again and Fire of a set callback allocate nothing, 500 calls each
MoltenCodes Test: PASS widgetKit.errors: Create called with a dot, a second Release, Release of a plain table and a method of a released widget are refused at the calling line; an unknown type answers nil and unknownType
MoltenCodes Test: PASS widgetKit.errors: bad arguments to widget methods are refused at the calling line with docs/API.md's wording: SetSliderValues with minimum over maximum, SetText with a table, SetRelativeWidth(0), an unregistered layout and a beforeWidget that is no child
MoltenCodes Test: PASS widgetKit.errors: a Dropdown list past maxDropdownEntries and SetLimits with an unknown name or UNBOUNDED for maxCreatedCeiling are refused at the calling line, and the limits and the list stay as they were
MoltenCodes Test: PASS widgetKit.errors: a callback that raises is reported through the client's error handler once per call, from a real Click and from Fire, naming WidgetKitSuite.lua at its line, and Fire returns false without raising
MoltenCodes Test: PASS widgetKit.secrets: text setters refuse a secretwrap string at the calling line; with allowSecret a Label shows it one line high on a font string of its own, and the next use of the same Label shows a plain empty text and measures plain texts again, wrapped ones included
MoltenCodes Test: PASS widgetKit.secrets: a secretwrap boolean handed to SetDisabled, SetFullWidth, SetIsPercent, SetKeyCapture, SetTriState, SetMultiLine, SetHasAlpha, SetResizable or options.allowSecret is refused at the calling line
MoltenCodes Test: PASS widgetKit.secrets: secret values WidgetKit would compare or use as a key are refused at the calling line (CheckBox and Dropdown values, a SetList order key and label, a user-data key, sizes, an index, a letter count, a justification, a type name), while a secret user-data value is kept
MoltenCodes Test: PASS widgetKit.secrets: Anchor.Normalize and Anchor.Apply refuse a secret offset at the calling line, and a binding's Restore of a saved anchor with a secret offset reports it through the error handler and leaves the frame where it was
MoltenCodes Test: PASS widgetKit.secrets: a layout function that returns secret sizes is ignored like any non-number, so the group keeps its insets; the client's answer to SetWidth with a secret from addon code is logged
MoltenCodes Test: PASS widgetKit.secrets: RenderOptions shows a secret input value as '<secret value>' and disables it, disables a toggle whose value is secret, and refuses a secret options.allowSecret at the calling line
MoltenCodes Test: PASS widgetKit.secrets: EditBox:SetText refuses a secret at the calling line even with allowSecret, as the client's edit box refuses one from addon code (logged), and RenderOptions with allowSecret shows a secret input value as '<secret value>', disabled
MoltenCodes Test: PASS widgetKit.taint: the client reported no ADDON_ACTION_BLOCKED or ADDON_ACTION_FORBIDDEN for a MoltenCodes addon since this addon loaded; every report and the security of the client globals WidgetKit reads are logged
MoltenCodes Test: widgetKit: 40 passed, 0 failed, 0 skipped, 0 timed out (40 tests)
MoltenCodes Test: results saved in MoltenCodesTestResults; /reload or log out to write them to disk.
```

Running it again in the same session prints the same lines.

## Visible side effects

None. Every widget is created with alpha 0 on a stage frame that sits 4000
pixels left of and above the screen's top-left corner, is not mouse-enabled and
is hidden again after every test. Two things are shown on `UIParent` for the
length of one synchronous step, which the client never draws in the middle of:

- the `Dropdown` test opens a dropdown list (a `FULLSCREEN_DIALOG` frame on
  `UIParent`, anchored below the off-screen dropdown) and WidgetKit's
  invisible full-screen click catcher, then closes both in the same step;
- the `ColorPicker` test opens the client's `ColorPickerFrame` through
  `ColorPicker:OpenPicker` and hides it in the same step. It is skipped, with
  the reason, when the colour picker is already open.

No key press, click or mouse movement of the player is needed, and none is
taken: the one test that turns on key capture turns it off in the same step.
No sound plays, no chat line other than the harness's appears, no client
setting changes and nothing is sent.

## What stays for the session

Every widget, position binding, rendering and options tree a test creates is
released or undefined by its suite's After hook, pass or fail, and every frame
the tests set to alpha 0 or unclamped gets its alpha and clamping back once it
is in its pool again. What stays:

- the frames WidgetKit's pools built for the base types (the client never
  frees a frame; they wait in their pools for the next `Create`), the
  session's dropdown catcher and the sixteen list rows of the dropdown the test
  opened;
- four plain frames of this addon's own, created once and reused by later runs:
  the stage, two 10 by 10 probes for the anchor tests (alpha 0, no texture,
  hidden after each test) and a hidden listener registered for
  `ADDON_ACTION_BLOCKED` and `ADDON_ACTION_FORBIDDEN`, which only records what
  the client reports;
- the fields `ColorPickerFrame:SetupColorPickerAndShow` stored on the client's
  colour picker (the callbacks of the test's `ColorPicker`, disarmed by its
  release), exactly as after any use of a WidgetKit `ColorPicker`.

WidgetKit's package-wide limits are not changed: every `SetLimits` call is a
refusal the tests check. No widget type or layout is registered, nothing is
written to a global or a saved variable other than the harness's own results.

### On a client without secret values

The seven `widgetKit.secrets` tests need the client's `issecretvalue` and
`secretwrap`. Retail 12.1 has both. A client without them prints these seven
lines instead, and the totals line reads
`33 passed, 0 failed, 7 skipped, 0 timed out (40 tests)`:

```text
MoltenCodes Test: SKIP widgetKit.secrets: text setters refuse a secretwrap string at the calling line; with allowSecret a Label shows it one line high on a font string of its own, and the next use of the same Label shows a plain empty text and measures plain texts again, wrapped ones included -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP widgetKit.secrets: a secretwrap boolean handed to SetDisabled, SetFullWidth, SetIsPercent, SetKeyCapture, SetTriState, SetMultiLine, SetHasAlpha, SetResizable or options.allowSecret is refused at the calling line -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP widgetKit.secrets: secret values WidgetKit would compare or use as a key are refused at the calling line (CheckBox and Dropdown values, a SetList order key and label, a user-data key, sizes, an index, a letter count, a justification, a type name), while a secret user-data value is kept -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP widgetKit.secrets: Anchor.Normalize and Anchor.Apply refuse a secret offset at the calling line, and a binding's Restore of a saved anchor with a secret offset reports it through the error handler and leaves the frame where it was -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP widgetKit.secrets: a layout function that returns secret sizes is ignored like any non-number, so the group keeps its insets; the client's answer to SetWidth with a secret from addon code is logged -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP widgetKit.secrets: RenderOptions shows a secret input value as '<secret value>' and disables it, disables a toggle whose value is secret, and refuses a secret options.allowSecret at the calling line -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP widgetKit.secrets: EditBox:SetText refuses a secret at the calling line even with allowSecret, as the client's edit box refuses one from addon code (logged), and RenderOptions with allowSecret shows a secret input value as '<secret value>', disabled -- the client has no issecretvalue and secretwrap; the secret path was not exercised
```

On Retail 12.1 any `SKIP` is unexpected, except the `ColorPicker` test when
the colour picker was open: `SKIP widgetKit.types: ColorPicker: ... -- the
client's ColorPickerFrame is open; it was not touched`. Close it and run again.

## What each test proves

| Test | Proves in the real client |
|---|---|
| `Registry:Get('widgetKit', 1) is the WidgetKit facade ...` | The facade the client loaded is API 1 with its sixteen methods, the four `Anchor` functions and nine points, the defaults and `UNBOUNDED`, the three built-in layouts and the twelve base types at the versions docs/API.md gives (3; `ScrollFrame` and `Spacer` 1). The log gives the session's limits and pool statistics before the run. |
| `the installed WidgetKit carries the revision ...` | Registry's selected revision and the facade's `REVISION` are both the committed manifest's. The log gives `REVISION`. |
| `the client has CreateFrame and UIParent, ...` | What WidgetKit builds on exists, and its optional Kits are registered. The log records `ColorPickerFrame` and its methods, the secret functions, the `ACCEPT` and `NOT_BOUND` strings, and `UIParent`'s rect and effective scale. |
| `text getters answer "" once cleared ...` | docs/API.md's "Text getters return what the widget shows (`""` once cleared)" against the client's font strings, buttons and edit boxes. Every answer is logged before any is checked; the other type tests read a `nil` answer as `""`, so only this test fails if a getter answers `nil`. The run of 2026-09-25 (revision 5) failed here: the client's font strings and buttons answer `nil` for an empty text, and revision 6 turns that into `""`. |
| `Frame: a 700x500 movable, resizable window ...` | The window's defaults on its real frame (size, `DIALOG` strata although it sits on the `MEDIUM` stage, movable, resizable, sizer shown; the log gives both strata and whether the window's strata is fixed), the three setters, and the three user callbacks: the drag-stop and mouse-up scripts WidgetKit set on its own title bar and sizer, called as the client calls them, and a real `Click` on the close button, which hides the window. Release and reuse (below) give the same frame back at its defaults. |
| `Group: 300x16 with no title, ...` | The content frame's real anchor moves from 8 to 26 pixels down with a title; `PerformLayout` grows the group to its content plus insets on the client (34 empty with a title, 74 around a 40-pixel child); `SetMaxChildren` answers `"full"`; a release releases the child and resets the title, children and bound. |
| `ScrollFrame: 300x200 with nothing to scroll; ...` | The scroll child is given the viewport's width as the client computes it from two anchors (280), the range is the content height minus the viewport height (300), the scrollbar shows, `SetScroll` clamps on the client's own scroll frame, and the mouse-wheel script scrolls 40 pixels a notch. The log gives the viewport and scroll child rectangles and the client's own scroll range. |
| `Label: 200 wide and empty ...` | The label's height is the client's `GetStringHeight` of its text, and a long text wraps into at least two lines at 200 pixels; colour, justification, font and the disabled grey reach the font string. The log gives the client's string widths and heights in `GameFontHighlightSmall` and `GameFontHighlightLarge`. |
| `Button: 200x24, empty and enabled; ...` | Programmatic `SetText` fires nothing; a real `Click` fires `OnClick` with the mouse button; a disabled button's `Click` fires nothing (the client ignores it); key capture starts on a click, ignores a modifier alone, fires `OnKeyCaptured` for `F` (with any modifier the player held, which the log shows), `OnKeyCaptureCancelled` for `ESCAPE` and `OnKeyCaptured("")` for a right click, and turning it off leaves the keyboard disabled. |
| `CheckBox: 200x24, unchecked ...` | `SetValue` shows the value on the real check button without a callback; real clicks cycle the value and fire `OnValueChanged` (true, false, then true and the third state with `SetTriState(true)`, whose marker shows); a disabled box ignores a click. |
| `Slider: 0 to 100 in steps of 1 at 0; ...` | `SetValue(0.337)` snaps to 0.35 on a 0.05 step and the client's slider shows it; clamping; the value box text (`0.35`, `35%`); moving the client's slider fires `OnValueChanged` once (a second identical move fires nothing), and the value box's Enter script reads `80%` back as 0.8; disabling disables both frames. |
| `EditBox: 200x44, single-line and empty; ...` | Text set from code, through the widget or on the client's edit box, fires no `OnTextChanged`; the Enter and Escape scripts fire their callbacks with the text; multi-line mode keeps the text, is 96 pixels high with three lines, and its accept button's real `Click` fires `OnEnterPressed`; `SetMaxLetters` reaches the edit box; `WidgetKit:SetFocus`, `GetFocus`, `Hide` and `ClearFocus` keep the documented bookkeeping without the keyboard ever being taken. |
| `Dropdown: 200x44 and empty; ...` | Sorting by label, then key with numbers first; `SetValue` shows the label on the button without a callback; `PickIndex` fires the key; the list is a `FULLSCREEN_DIALOG` frame on `UIParent`, `Open` shows it and the catcher, builds sixteen rows showing the labels, a real `Click` on a row fires its key and closes the list, and `Close` hides the catcher; an `order` skips keys without a label; a disabled dropdown neither picks nor opens. |
| `ColorPicker: white and opaque; ...` | `SetColor` fires nothing; a disabled picker's `OpenPicker` answers `false` and fires nothing; `OpenPicker` opens the client's `ColorPickerFrame`, whose `GetColorRGB` gives back the widget's colour (logged); the swatch callback fires `OnValueChanged` with the client picker's colour and the widget's alpha, the cancel callback with the colour from before; after a release, the same two callbacks reach nothing. The log gives how many callbacks the client made while setting the picker up and after it was hidden, and what `issecurevariable` says of the picker's three callback fields. |
| `Heading: 200x18, full width and empty ...` | The two lines meet in the middle without text and flank the text, 6 pixels away, with it, on the client's anchors; the log gives the client's width of `General`. |
| `Spacer: 10x8; ...` | Sizes reach the frame; full width and relative width replace each other; release and reuse clear the requests. |
| each type test, at its end | The release contract on the real frame: `OnRelease` fires once while `IsReleasing()` is true, the widget is no longer active, the frame is hidden, re-parented to `UIParent` and has no anchors, and `Fire` answers `false`; the next `Create` of the type hands back the same widget on the same frame, shown, with no user data, no size requests and no callbacks. |
| `List stacks shown children ...` | On a content frame 300 pixels wide: `GetPoint` gives the documented offsets (0, -20, -50, -60, then below the label), the full-width child spans the content with a second anchor, the half-width child is 150 wide, the hidden child has no anchor, the label wraps into at least two lines at full width (its font string is given the 300-pixel width; revision 5 left it unwrapped at 956 pixels because the client had not resolved its two anchors yet), the nested titled group is 74 high and the container grows to fit. Adding a child to the nested group grows it to 99 and the container follows in the same call. The rectangles the client computes match within one interface unit, again after a rendered frame. The log gives the rectangles, the label's measures and the largest rect deviation. |
| `Fill anchors the first shown child ...` | The first shown child gets `TOPLEFT` and `BOTTOMRIGHT` anchors on the content (300 by 200 on the client), and the nested `ScrollFrame` is laid out in the same pass: a 280-pixel scroll child and a 300-pixel range. A full-height group keeps its height. |
| `Flow places children left to right ...` | On 300 pixels: 120 + 120 fit, the third 120 wraps to y 30, a half-width child joins it at x 120 as 150 wide, a full-width child takes the row at y 40, and a full-height child gets the 148 pixels left below y 52. On a 107-pixel row, ten tenths sit at x = 10.7 × i on one row, the 0.001-pixel tolerance at work; the log gives the tenth's x offset. Offsets are checked with `GetPoint`, rectangles within one interface unit. |
| `Anchor.Normalize turns the SetPoint argument forms ...` | Six argument forms on a real frame of scale 0.8: an omitted or `nil` relative frame becomes the parent (the stage, unnamed, so the frame itself), `UIParent` becomes `"UIParent"`, a name stays a name, offsets default to 0 and `scale` is the client's `GetScale`. |
| `Anchor.Read of a real frame names UIParent ...` | `Read` of a real anchor, `Apply` of it to another frame (same rect on the client), `Apply` with a scale (the client's `GetScale` is 0.5), and `false, "unknownRelative"` leaving the frame's anchor as it was; `Read` of a frame without anchors is `nil`. |
| `a window's position binding captures the nearest point ...` | `Capture` from the window's drag-stop script elects `TOPLEFT` with offsets -3000, 3000 in `UIParent`'s units (the log gives the effective scale), fires the binding's `OnMoved` and the window's `OnMoved`, saves nothing until `Flush` (SchedulerKit's debounce), then a plain table naming `"UIParent"`; `BOTTOMRIGHT`, `CENTER` and `TOP` are elected from the client's rectangles of an invisible 10 by 10 probe; `Release` flushes, and a second binding restores the saved anchor onto another frame. |
| `CreateMediaPicker lists MediaKit's font and statusbar names ...` | Both pickers list exactly `MediaKit:List`'s names, in that order (up to 32 checked by `PickIndex`); `RenderOptions` with `options.media` fills a `select` from MediaKit's fonts, and picking the first writes it through the tree. The log gives the counts and the first and last names. |
| `RenderOptions draws one widget per visible option ...` | The widget type of every kind, full width, in `Describe` order, the hidden option skipped, the inline group nested, and every value read with `Get`. The container stays hidden throughout. |
| `user input through the rendered widgets reaches tree:Set, ...` | `PickIndex`, real clicks on the check box, the multiselect's second box and the execute button, and the client's slider write through `Validate` and `Set`; the edit box's Enter script with `bad` shows `no bad names` in a `Label` right below it, keeps the stored value, and the next accepted text removes the message; `tree:Set` from code refreshes the slider and the dropdown in place. |
| `Release gives every rendered widget back ...` | `Release` answers `true` then `false`, the container is empty, the 13 rendered widgets are no longer active (`GetStatistics`), and releasing the container releases a second rendering first. |
| `Create and Release of each of the twelve base types again ...` | docs/API.md's "`Create` / `Release` of a warm widget: no allocation", on the client's collector, per type: after a full collection in its own step and one unmeasured cycle, 500 cycles move `collectgarbage("count")` by at most 1 KB, and every cycle hands back the same widget. The log gives each delta. |
| `PerformLayout of a List of ten children again and Fire ...` | The same for a layout pass over unchanged children and for `Fire`. |
| `Create called with a dot, ...` | Receiver and release refusals at this file's calling line with docs/API.md's wording, and `nil, "unknownType"`. |
| `bad arguments to widget methods ...` | Six argument refusals at the calling line, including a container added to itself. |
| `a Dropdown list past maxDropdownEntries ...` | A list one entry over the session's limit is refused at the calling line and the dropdown keeps its one entry; the two `SetLimits` refusals leave the limits as they were. |
| `a callback that raises is reported ...` | A raising `OnClick` is reported through the client's error handler (swapped with `seterrorhandler` for the call and put back at once), once for the real click and once for `Fire`, with this file and the raising line in the message; `Fire` answers `false`. |
| `text setters refuse a secretwrap string ...` | A genuine secret text is refused at the calling line by `Label:SetText` and `Button:SetText`; with `allowSecret` the client's font string takes it and the label is 12 pixels high (the log says whether `GetText` answers a secret), a `Heading` takes one too, and the label shows it on a font string other than the one it shows plain texts on. The next use of the same label is back on that plain font string: it shows a plain `""`, measures a plain text as a plain number, its height is that string height, and a long text wraps into at least two lines (the log gives the three secret answers, the secret font string's included, and the two heights). The run of 2026-09-25 (revision 5) failed here, and the next two secrets tests with it: the reused label measured its text as a secret and handed it to `SetHeight`, which the client refuses from addon code. The second run that day (11:09, revision 6) failed here alone: `ClearText` on release made the text plain but not the measurements (`GetText() secret false, GetStringHeight() secret true`), so the reused label would have been one line high for any text; revision 7 never shows a plain text on a font string that showed a secret. |
| `a secretwrap boolean handed to ...` | Ten refusals of a secret boolean at the calling line, each with docs/API.md's message, before any boolean test could raise inside WidgetKit. |
| `secret values WidgetKit would compare or use as a key ...` | Twelve refusals at the calling line; the dropdown and the check box keep their state; a secret user-data value is stored and handed back still secret; a secret `maxDropdownEntries` is refused at the calling line with `WidgetKit:SetLimits limits.maxDropdownEntries must not be a secret value` and the limits are unchanged. |
| `Anchor.Normalize and Anchor.Apply refuse a secret offset ...` | Both refusals at the calling line; a `BindPosition` whose saved anchor holds a secret offset reports one error through the client's handler (the log shows it) and leaves the frame on its anchor. |
| `a layout function that returns secret sizes ...` | A custom layout returning secret width and height is ignored: `PerformLayout` answers `true` and the group is 16 high. The log records whether the client accepts `SetWidth` with a secret from addon code, on a probe frame of this addon, and whether `GetWidth` then answers a secret. |
| `RenderOptions shows a secret input value as '<secret value>' ...` | An `input` option whose `get` returns a secret shows the placeholder and is disabled; a `toggle` whose `get` returns a secret boolean is disabled and unchecked; a secret `options.allowSecret` is refused at the calling line. |
| `EditBox:SetText refuses a secret at the calling line even with allowSecret, ...` | `EditBox:SetText(secret, { allowSecret = true })` is refused at the calling line and the box stays empty; the client's own edit box is then handed the secret directly and its answer is logged (on 2026-09-25 it refused: `Secret values are only allowed during untainted execution for this argument`); `RenderOptions` with `allowSecret` renders the secret `input` as `<secret value>`, disabled, without raising. |
| `the client reported no ADDON_ACTION_BLOCKED ...` | Everything the client reported as blocked or forbidden since this addon loaded is logged with the addon and function it named, and none names a `MoltenCodes` addon. The log also gives `issecurevariable` for `UIParent`, `ColorPickerFrame`, `CreateFrame` and `GameFontNormal`. |

## What counts as unexpected

- Any `FAIL` or `TIMEOUT` line, a `SKIP` line on Retail 12.1 (other than the
  open colour picker), or a totals line other than
  `40 passed, 0 failed, 0 skipped, 0 timed out (40 tests)`.
- No login line, or `Expected.lua is missing`: the harness or the installer
  did not run as intended.
- Anything appearing on screen: a window, a list, the colour picker, a flicker
  of either, or a click of yours not reaching the game. Say what and when.
- A Lua error window or a BugSack entry naming `MoltenCodes`,
  `MoltenCodesTest` or `MoltenCodesTest_WidgetKit`. Every error the suite
  provokes is caught by the test itself. A taint message from the client
  ("Interface action failed because of an AddOn", an
  `ADDON_ACTION_BLOCKED` line in the taint log) is also unexpected; the taint
  test lists what the client reported.
- `text getters answer "" once cleared` failing: the log shows which getter
  answered `nil`; docs/API.md's promise or the widget must change.
- A layout test failing on a width, height or offset: the log gives the rectangles
  the client computed. A 0 width or height read right after `SetPoint` would
  mean the client resolves anchors lazily, which the layouts rely on not
  happening.
- The `ScrollFrame` test failing on `scroll clamped to the range`: the log
  gives the client's own scroll range, which may lag behind the scroll child's
  new height.
- The `ColorPicker` test failing on the callback count: the log gives how many
  callbacks the client's picker made itself.
- The allocation tests failing: their log gives the deltas per type. Say which
  other addons are enabled.
- The first secrets test failing on the reused label: its log says whether
  `GetText` or `GetStringHeight` still answered a secret, which would mean
  `ClearText` does not remove the secret aspect on this client.
- The last secrets test logging `accepted` for the client's own
  `EditBox:SetText(secret)`: the client changed, and `EditBox:SetText` could
  take a secret again; send its log.

## What to send back

1. The chat lines above as they appeared (a screenshot, or a copy of the chat
   log), including any line that differs.
2. After `/reload` or a logout, the file
   `/Applications/World of Warcraft/_retail_/WTF/Account/<ACCOUNT>/SavedVariables/MoltenCodesTest.lua`.
   It holds the full report, each test's logs (the client's string widths and
   heights, the rectangles of every layout, the effective scale, the captured
   offsets, the MediaKit counts, the memory deltas, the colour picker
   callbacks, the secret and taint facts, the client's own error messages with
   their paths) and the client facts. Lua shortens a long file path from the
   left, so a logged message may start with `...`; the tests compare only the
   `WidgetKitSuite.lua:<line>` part.
3. The text of any Lua error, with `/console scriptErrors 1` turned on, and
   the taint log if the client wrote one (`/console taintLog 1` before the run
   writes `Logs/taint.log`).
4. The list of other enabled addons, when a test failed.
