# Changelog

## 0.1.0 — 2026-11-15

The first revision, delivery step N1 of `docs/BRIDGE_KIT_DESIGN.md`: the
AceSerializer-3.0 wire format. API generation 1, implementation revision 1.

- `BridgeKit:AceSerialize(...)` writes the text Ace3's AceSerializer-3.0
  (`MINOR` 5, Ace3 `5e2e0d3b`) writes for the same values, and refuses with a
  reason where Ace3 would raise or write undefined bytes: `unsupportedType`,
  `cycle`, `nan`, and the limits.
- `BridgeKit:AceDeserialize(text)` reads what Ace3 reads, within the limits,
  and never raises on malformed text: `notAceSerializer`, `missingTerminator`,
  `invalidNumber`, `invalidFloat`, `invalidEscape`, `unknownControl`,
  `tableFormat`, `invalidKey` and the limits. A `^F` number is scaled with
  `ldexp`, so a subnormal number Ace3's own reader reads as `0` reads back
  exactly.
- `SetLimits` and `GetLimits` for `maxDepth`, `maxValues`, `maxStringLength`,
  `maxTextBytes` and `maxListValues`; `UNBOUNDED`; `ACE_WIRE_VERSION`; the
  read-only `ACE_BASELINE`.
- 139 specs, 90 of them generated from output recorded from Ace3 by
  `python3 -m tooling.fixtures.ace_serializer`
  (`tests/fixtures/AceSerializerFixtures.lua`).
