# Changelog

## 0.1.0 — 2026-09-23

- Added MediaKit API generation 1, implementation revision 1.
- Added `MediaKit:Register(type, name, data, options)` over seven fixed media types (`background`, `border`, `font`, `icon`, `sound`, `statusbar`, `texture`), with data a non-empty path or a FileDataID. A name holding different data returns `nil, "taken"`; the same name with the same data (and, for a font, the same scripts) returns `true` and changes nothing; past `MediaKit.MAX_ENTRIES_PER_TYPE` (1024) entries of a type it returns `nil, "full"`.
- Fonts declare the scripts they render through `options.scripts` (`latin`, `cyrillic`, `greek`, `cjkSimplified`, `cjkTraditional`, `korean`, `japanese`; every script by default), and the client's script comes from `GetLocale`, read at call time.
- Added `MediaKit:Fetch(type, name, options)` and `MediaKit:Has(type, name, options)`: one table read, no allocation; a font that does not render the client's script is `nil` unless `options.anyScript`.
- Added `MediaKit:List(type, options)`: a cached array of names sorted with `<`, shared and read-only, rebuilt as a new array only after a registration of that type (or, for fonts, when the client's script changed); fonts filtered to the client's script unless `options.anyScript`.
- Added `MediaKit:OnRegistered(type, callback)`: a SignalKit connection fired with `(type, name, data)` for each new entry of that type, from any origin.
- Added `MediaKit:Defaults(consumerName)`: one defaults object per consumer with `Set(type, name)` and `Get(type)`, falling back to the client's built-in media, registered at load (the client's own fonts, with the Cyrillic files on a `ruRU` client, and its dialog, tooltip, status bar, sound, texture and icon files). At most 1024 consumers.
- Added `MediaKit:AdoptLibSharedMedia()`: reads LibSharedMedia-3.0's five media types into read-only entries in sorted order and follows `LibSharedMedia_Registered` through its CallbackHandler; `true, added` or `false, "absent"`; idempotent, subscribing once.
- Added `MediaKit:MirrorToLibSharedMedia()`: registers MediaKit's entries of the five shared types into LibSharedMedia (with a `langmask` built from a font's scripts), skipping names it holds and entries adopted from it, and mirrors later registrations; `true, mirrored` or `false, "absent"`; idempotent. Neither direction echoes: an adopted entry is never mirrored back, and a mirrored entry arriving through the callback is recognised as already present.
- LibStub is read with `rawget(_G, "LibStub")` at call time; MediaKit does not depend on the LibStub bridge package.
- A secret type, name or data (through `issecretvalue`, looked up at call time) is refused at the caller; secret LibSharedMedia entries are skipped.
- Package state, cached lists, signals, defaults objects and the LibSharedMedia callback survive an in-place upgrade; the callback dispatches through package state, so a newer revision replaces its behaviour without subscribing again.
- 89 specs, including sorted-listing determinism across insertion orders, script filtering on `enUS`, `ruRU`, `zhCN` and every other client locale, adoption and mirroring against a LibStub and LibSharedMedia stub in both directions without echo, allocation guards on `Fetch`, `Has`, `List` and `Get`, an in-place upgrade spec and error levels pinned for every argument failure.
