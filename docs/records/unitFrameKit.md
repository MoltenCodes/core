# unitFrameKit records

Moved from `docs/ROADMAP.md` (Package M — the user-interface phase (last, by the owner's decision)).

## unitFrameKit

**unitFrameKit** — facade `UnitFrameKit`

1. Package `unitFrameKit`, facade `UnitFrameKit`, API generation 1, version
   0.1.0, implementation revision 1.
2. Purpose: find the unit frame shown on screen for a unit token, what
   LibGetFrame-1.0 gives WeakAuras to anchor an aura or a glow to a party or
   raid member's frame. A scan walks the client's frames with
   `EnumerateFrames`, in slices, and keeps every visible `Button` whose
   `unit` attribute is set (with `unitsuffix` appended, as Blizzard's
   `SecureButton_GetUnit` does), under its name or, for an unnamed frame,
   its parent's name and parent key (`PartyFrame.MemberFrame1`). A query
   reads each kept frame's `unit` attribute again, compares it with
   `UnitIsUnit`, drops hidden frames, and ranks the matches: the caller's
   patterns first, then frames of other addons, then Blizzard's frames
   (`CompactRaidFrame%d`, `CompactRaidGroup%dMember%d`,
   `CompactPartyFrameMember%d`, `PartyFrame.MemberFrame%d`,
   `Boss%dTargetFrame`, then `PlayerFrame`, `TargetFrame`, `FocusFrame`).
   Frames are sorted into kinds (`raid`, `party`, `boss`, `player`,
   `target`, `targettarget`, `focus`); by default only `raid`, `party` and
   `boss` frames answer, and a solo kind answers when the token asked for
   is that kind's own token (`"target"` finds `TargetFrame`). Kinds of
   other addons come from a short pattern table, each entry checked in that
   addon's own published source and cited in `docs/API.md`; an entry that
   cannot be checked is left out, and such an addon's frames are still
   found, without a kind, ranked after the known ones. A nameplate is
   `C_NamePlate.GetNamePlateForUnit(unit)` and its `UnitFrame` child. Every
   name used exists on Retail, Mists of Pandaria Classic and Classic Era
   (Blizzard's `Blizzard_UnitFrame`, `Blizzard_CompactRaidFrames` and
   `Blizzard_NamePlates`, branches `live`, `classic` and `classic_era`,
   read 2026-11-15). Non-goals: names or GUIDs in place of unit tokens,
   per-addon workarounds (ElvUI's health bar, Cell's override hook),
   third-party nameplate addons, arena frames, frame creation or anchoring
   (the caller anchors), profiling.
3. Dependencies: registry API 2 only. It keeps one event frame of its own,
   so EventKit is not needed. Host requirement: `CreateFrame`,
   `EnumerateFrames`, `UnitIsUnit`, `UnitExists`; without `EnumerateFrames`
   nothing is kept and every query answers `nil`. `C_NamePlate` for
   `GetNamePlate` (`nil` without it). `issecretvalue` where the client has
   it: a secret `unit` attribute or a secret `UnitIsUnit` answer (Retail's
   `Attributes` aspect and restricted unit comparisons) makes that frame no
   match.
4. Surface: `UnitFrameKit:GetUnitFrame(unit, options?)` → frame or `nil`,
   with `kinds` (array of kinds in rank order), `priorities` (array of name
   patterns ranked before everything else), `ignore` (array of name
   patterns never answered); `UnitFrameKit:GetUnitFrames(unit, options?)`
   → a new array of every match in rank order; `UnitFrameKit:GetNamePlate(unit)`
   → frame or `nil`; `UnitFrameKit:Rescan()` (a scan starts on the next
   client frame); `UnitFrameKit:IsScanning()`;
   `UnitFrameKit:OnChange(callback)` → connection (`Disconnect()`,
   `IsConnected()`), called after a scan once per frame whose unit
   changed, with `(frame, unit, previousUnit)` (`previousUnit` `nil` for a
   frame new to the cache, `unit` `nil` for one gone from it), which is
   LibGetFrame's `FRAME_UNIT_ADDED`, `FRAME_UNIT_UPDATE` and
   `FRAME_UNIT_REMOVED` in one; `UnitFrameKit:GetKindPatterns(kind)` → a
   copy of the kind's patterns; `SetLimits{ maxFrames, scanFramesPerStep,
   maxListeners }` / `GetLimits()`. A unit that is secret or not a
   non-empty string, an unknown option or kind, a pattern list over 64
   entries, or a callback that is not a function raise at the caller.
5. Ownership: the Kit owns one event frame for the session. It scans on
   first use, on `PLAYER_ENTERING_WORLD`, `GROUP_ROSTER_UPDATE`,
   `PLAYER_REGEN_DISABLED`, `PLAYER_REGEN_ENABLED`,
   `INSTANCE_ENCOUNTER_ENGAGE_UNIT` and `UNIT_PET` of a group member, each
   coalesced into one scan one second later; a request during a scan
   queues exactly one more. The cache holds frames, which the client never
   frees, so it holds them strongly and replaces the whole cache at the end
   of each scan. A connection lives until `Disconnect`; a callback that
   raises is reported through `geterrorhandler` and the others still run.
   Scanning and queries only read frames, so both run in combat.
6. Performance and memory: the event frame's `OnUpdate` runs only while a
   scan is waiting or running. A scan visits at most `scanFramesPerStep`
   frames per client frame and keeps its place in `EnumerateFrames`, which
   is safe because frames are never deleted and the walk follows creation
   order; frames made during the scan come later in the walk and are seen.
   Per frame visited it calls `IsForbidden`, `GetObjectType` and, for a
   `Button`, `GetAttribute` and `IsVisible`, and allocates only for a kept
   frame (its name and kind). The cache and the scan's working table swap
   and are wiped, so a scan allocates no tables. A query reads at most
   `maxFrames` entries, one attribute and one `UnitIsUnit` each, and
   allocates nothing (`GetUnitFrames` allocates its result). Limits:
   `maxFrames` (frames kept) 512, ceiling 4096; `scanFramesPerStep` 400,
   ceiling 4000; `maxListeners` 64, ceiling 512; none `UNBOUNDED`. A scan
   that reaches `maxFrames` keeps the first ones and reports once through
   `geterrorhandler`. The cost of a full scan on a loaded Retail interface
   is measured in the benchmark harness before the first release and
   written into `docs/API.md`.
7. Tests: stand-ins for `EnumerateFrames`, frames with attributes,
   visibility and names, `UnitIsUnit`, `C_NamePlate` and the events; frames
   found by attribute and by `unitsuffix`, unnamed frames named through
   their parent key, forbidden, hidden and non-button frames skipped, aura
   buttons (`type` `"cancelaura"`) skipped, the scan sliced per client frame
   and resumed in place, frames created during a scan, rescans coalesced
   and queued, ranking by caller patterns, other addons and Blizzard's
   frames, kinds and the solo-token rule, `ignore`, `GetUnitFrames` order,
   `OnChange` with added, changed and removed frames and a callback that
   raises, nameplates, limits and ceilings, the `maxFrames` report, secret
   arguments, secret attributes and secret `UnitIsUnit` answers, a host
   without `EnumerateFrames`, upgrade, manifest, error levels. A client
   suite on Retail: in a party with Blizzard's frames, `GetUnitFrame("party1")`
   answers the shown party frame, and after `Rescan` with raid-style party
   frames answers the compact one.
8. Docs: README (with the migration from LibGetFrame-1.0), API.md (the
   ranking, the kinds and their cited patterns, the measured scan cost),
   CHANGELOG, tests/README; EMBEDDING rows; ARCHITECTURE's package list.
9. Status: implemented 2026-11-15 under core decision 16, 0.1.0, revision
   1, 65 specs; the client suite (`tests/client/MoltenCodesTest_UnitFrameKit`)
   is written and has not been run in a client. Third-party patterns shipped
   only where checked in the addon's own source: ElvUI, Cell, Grid2 and
   Shadowed Unit Frames (commits cited in `docs/API.md`); the rest of
   LibGetFrame's list is left out, and those frames are found without a
   kind. Deviations: a query allocates one string for a frame with a
   `unitsuffix` attribute; a scan reads up to three attributes per button
   (`unit`, `unitsuffix`, `type`, to skip secure aura buttons); a frame
   matching a caller's `priorities` answers whatever its kind, and `ignore`
   wins over `priorities`; a scan that raises is dropped and reported once;
   `IsScanning` is also true while a scan waits to start; the client suite
   accepts whichever Blizzard party style is shown rather than switching it.
   The full-scan cost is to be measured in the benchmark harness before the
   first release.
   Reviewed 2026-11-15 under core decision 17: 0.1.1, revision 2, 68 specs
   (Blizzard's `PetFrame` and `FocusFrameToT` rank as Blizzard's and answer
   only for their own token; frames `CanBeAccessedInContext` refuses are
   skipped).

