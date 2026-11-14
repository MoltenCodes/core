# BridgeKit Tests

| Spec | Covers |
|---|---|
| `Fixtures_spec.lua` | Every case recorded from Ace3 in `fixtures/AceSerializerFixtures.lua`: the bytes `AceSerialize` writes for each recorded value, and for each recorded text the values `AceDeserialize` reads or the reason that stands for Ace3's error message; the fixtures' provenance against `ACE_BASELINE`. |
| `Serializer_spec.lua` | Round trips of every byte, of value counts with `nil`s, of numbers at the edges of the double range and of 500 random doubles, of nested tables with every key type; a table referenced twice; every writer refusal; every reader limit, the most values `unpack` returns; every proper prefix of a valid text refused without raising; hostile text; a subnormal number Ace3's reader loses; huge and tiny exponents; secret values and keys, secret and non-string text and dot calls raised at the caller's line. |
| `Limits_spec.lua` | Defaults, fresh tables, partial updates, validation of every entry before any change, ranges, unknown names, `UNBOUNDED` accepted and refused with its reason, secret keys and values, errors at the caller's line. |
| `Bootstrap_spec.lua` | Registration, one copy for two embedded copies, an older copy stepping aside, an in-place upgrade keeping the limits, the sentinel and the baseline, the read-only baseline, a missing Registry. |
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
