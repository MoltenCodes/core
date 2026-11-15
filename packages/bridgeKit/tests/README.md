# BridgeKit Tests

| Spec | Covers |
|---|---|
| `Fixtures_spec.lua` | Every case recorded from Ace3 in `fixtures/AceSerializerFixtures.lua`: the bytes `AceSerialize` writes for each recorded value, for each recorded text the values `AceDeserialize` reads or the reason that stands for Ace3's error message, and a tilde before every byte that can follow one, accepted and decoded or refused as Ace3 does; the fixtures' provenance against `ACE_BASELINE`. |
| `Serializer_spec.lua` | Round trips of every byte, of value counts with `nil`s, of numbers at the edges of the double range and of 500 random doubles, of nested tables with every key type; a table referenced twice; every writer refusal; every reader limit, the most values `unpack` returns; every proper prefix of a valid text refused without raising; hostile text; a subnormal number Ace3's reader loses; overflow and NaN as in Ace3's arithmetic, a NaN key reached that way; huge and tiny exponents; secret values and keys, secret and non-string text and dot calls raised at the caller's line. |
| `AceConfig_spec.lua` | The AceConfig adapter: every kind and field with its report entry and reason, `name`, `order` and `sorting` evaluated once, live `desc`, the interface flags of each `uiType`, inheritance of accessors and handlers (a handler switch, `get = false`), method names looked up at call time and Ace's message when one is gone, the Ace `info` fields and its reuse, `color` and `multiselect` shapes both ways, `validate` answers (`true`, a string, `false`, a secret), deterministic renaming and `paths`, `bind`, `replace`, `strict`, `maxOptions`, `maxDepth` and a cyclic table, every option and argument error, a secret field named by its path, errors of addon callbacks propagated, report truncation and `FormatReport`; and `DefineAceConfig` with OptionsKit loaded (driven through `Get`, `Set`, `Validate`, `Execute`, `Describe`), OptionsKit's refusal at the caller's line, and OptionsKit absent. |
| `Limits_spec.lua` | Defaults, fresh tables, partial updates, validation of every entry before any change, ranges, unknown names, `UNBOUNDED` accepted and refused with its reason, secret keys and values, errors at the caller's line. |
| `Bootstrap_spec.lua` | Registration, one copy for two embedded copies, an older copy stepping aside, an in-place upgrade keeping the limits, the sentinel and the baseline, a newer revision's baseline published through the same table, a corrupted inherited state refused, the read-only baseline, a missing Registry. |
| `Manifest_spec.lua` | Manifest and runtime API and revision agree; Registry is the only dependency. |

`support/BridgeKitTestEnv.lua` loads Registry and BridgeKit into the shared
fake client, loads the recorded fixtures, marks values secret and loads the
source again as another revision.

## The recorded fixtures

`fixtures/AceSerializerFixtures.lua` is generated: run
`python3 -m tooling.fixtures.ace_serializer` to record it again from Ace3 at
the pinned commit, and `--check` to compare a fresh recording with the
committed one. The inputs are listed in
`tooling/fixtures/lua/RecordAceSerializer.lua`. The module holds Ace3's
output for them and no Ace3 source (`docs/BRIDGE_KIT_DESIGN.md`, section 3.2).
