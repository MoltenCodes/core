# Changelog

## 0.2.0 — 2026-09-22

- `ConnectUnit`/`OnceUnit` now reject more than two distinct unit tokens instead of letting the client silently drop the extras. `Frame:RegisterUnitEvent` has two filter slots; a third token used to be sorted away by the host while EventKit's group key still claimed it, so the caller got a filter they never asked for. Fan-in was considered and rejected: it needs an extra Frame per pair and makes delivery order for one logical subscription unspecified, because EventKit does not define ordering between Frames.
- Listeners are now isolated from each other at EventKit's dispatch boundary. EventKit is one shared instance per WoW session, and an erroring handler used to abort delivery to every listener behind it, including listeners belonging to unrelated addons. Errors are now reported through the host error handler and delivery continues. Isolation uses `securecallfunction` when the client provides it, otherwise `xpcall` with `geterrorhandler()` driven by a reusable upvalue trampoline, so nothing is allocated per event.
- Unit groups are released when their last channel goes. The Frame's `OnEvent` handler is detached and the Frame returns to a free list that new unit sets re-purpose, so creating and releasing a hundred distinct unit sets creates one Frame instead of a hundred. The number of unit-filter Frames EventKit will ever create is capped at 64, which also bounds the free list.
- Host-environment failures (`CreateFrame` missing, a missing Frame method, the Frame cap) now raise at level 0 with an `EventKit:` prefix. They were raised two to four frames below the public API, so their stack level named a line inside EventKit. Argument errors continue to point at the calling line, and a spec now verifies that.
- The per-event `rawget(EventKit, "_DispatchRegular")` plus type check is gone: the dispatchers are validated once at load and kept in shared state. `_DispatchRegular`/`_DispatchUnit` remain on the facade so Frames created by revision 1 keep working after an in-place upgrade.
- `releaseChannel` treats any non-positive listener count as empty rather than testing `count ~= 0`, so a bookkeeping slip cannot pin a registration for the rest of the session.
- Documented the combat-log event's empty payload, the taint consequences of a shared bus, and the reserved underscore-prefixed facade fields.
- Made the test stub enforce the host's two unit-filter slots, documented cross-Frame delivery order as unspecified, and added specs for two tenants where the first throws, disconnect-during-dispatch from another connection, Frame retention, the revision-1 upgrade path, and per-event allocation.
- Annotated the public surface with LuaCATS types.

## 0.1.1 — 2026-09-22

- No runtime behaviour change. Revision 1 still describes the shipped implementation.
- Made the test-support `CreateFrame` stub raise a plain error when asked for a frame type it does not model. It previously called a luassert matcher, which is unavailable inside a `require`d support module and reported a confusing indexing failure instead of the real misuse.
- Annotated every deliberate `_G` access with the reason it crosses into the global table, so Selene reports the package clean without the `global_usage` lint being disabled repository-wide.
- Reformatted the package with StyLua 2.5.2. Whitespace, wrapping and quote style only; the compiled Lua is unchanged.

## 0.1.0

- Renamed the package identity and Lua facade from `events` / `Events` to `eventKit` / `EventKit` as part of the framework-wide Kit naming convention.

- Added lazy regular WoW event subscriptions.
- Added unit-filtered event subscriptions.
- Added one-shot subscriptions.
- Added explicit, idempotent connection lifecycle.
- Added shared-frame grouping and automatic unregistration.
- Added Registry-backed embedded-copy reconciliation.
