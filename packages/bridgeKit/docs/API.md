# BridgeKit API

BridgeKit is the MoltenCodes package that moves an addon from Ace3 to the Kits
without breaking what its players already have. Its canonical design is
[`docs/BRIDGE_KIT_DESIGN.md`](../../../docs/BRIDGE_KIT_DESIGN.md); this
document is the contract of what the current revision ships.

**Revision 1 ships the AceSerializer-3.0 wire format** (design step N1). The
AceConfig adapter, the AceDB importer and the AceComm channel follow in later
revisions (design section 15); until then their methods do not exist.

Everything here reproduces Ace3 at commit
`5e2e0d3b3fd125ef1518744c6a9dd21f68f6e773`, AceSerializer-3.0 `MINOR` 5. The
implementation is written from the format description in the design, never
from Ace3's source, and is checked against output recorded from Ace3 itself
(see [Testing](#testing)).

## Loading

BridgeKit needs Registry API 2 and nothing else: an addon that only reads and
writes AceSerializer text embeds two files.

```xml
<Script file="Libs\MoltenCodes\registry\Registry.lua" />
<Script file="Libs\MoltenCodes\bridgeKit\BridgeKit.lua" />
```

```lua
local BridgeKit = MoltenCodes.Registries[2]:Get("bridgeKit", 1)
```

## Public surface

| Member | Returns | Purpose |
|---|---|---|
| `AceSerialize(...)` | `true, text` or `false, reason` | AceSerializer-3.0 text for a list of values. |
| `AceDeserialize(text)` | `true, ...` or `false, reason` | The values of AceSerializer-3.0 text. Never raises on malformed text. |
| `SetLimits(limits)` | nothing | Change any subset of the [limits](#limits). |
| `GetLimits()` | a fresh table | The limits. |
| `UNBOUNDED` | table | Sentinel for the limits that accept it. |
| `ACE_WIRE_VERSION` | `1` | The newest AceComm wire version this revision speaks (design section 8.5); no channel ships yet. |
| `ACE_BASELINE` | read-only table | `{ commit = "5e2e0d3b…", AceComm = 14, AceSerializer = 5, AceDB = 37, AceConfigRegistry = 22 }`: what BridgeKit reproduces. A write raises. |
| `API`, `REVISION` | integers | API generation `1`, implementation revision. |

Every method is called with a colon on the facade. A dot call, a wrong type or
a secret argument raises **at the caller's line**, named after the method:
`BridgeKit:AceDeserialize text must be a string`. Everything that depends on
the data is a return value.

## `BridgeKit:AceSerialize(...)`

```lua
local ok, text = BridgeKit:AceSerialize("profile", { scale = 1.25, shown = true })
-- ok == true, text == "^1^Sprofile^T^Sscale^N1.25^Sshown^B^t^^" (pair order follows next)
```

Writes what Ace's `Serialize` writes for the same values on the same client:
the start code `^1`, one token per value, the end code `^^`. Strings escape
their control bytes, space, caret, tilde and DEL; numbers use `tostring` when
it reads back as the same number, otherwise a mantissa and an exponent;
tables write their pairs in `next` order, as Ace walks them with `pairs`, so
two equal tables with more than one entry may be written in different orders
by either implementation. The number spelling follows the client's
`tostring`, as Ace's does.

Returns `true, text`, or `false` and one of these reasons, where Ace would
raise or write undefined bytes:

| Reason | When | Ace3 |
|---|---|---|
| `"unsupportedType"` | a function, userdata or coroutine | raises (`AceSerializer-3.0.lua:106`) |
| `"cycle"` | a table that contains itself, directly or further down | overflows the stack |
| `"nan"` | NaN, as a value or inside a table | writes bytes that depend on the client (`29`, `65`, `152`) |
| `"maxDepth"` | tables nest deeper than `maxDepth` | no bound |
| `"maxValues"` | more than `maxValues` values, keys included | no bound |
| `"maxStringLength"` | a string longer than `maxStringLength` bytes, counted before escaping | no bound |
| `"maxTextBytes"` | the text would pass `maxTextBytes` | no bound |

A table referenced twice (not a cycle) is written twice, as Ace writes it, and
reads back as two tables. **A secret value anywhere**, a table key included,
raises at the caller: `BridgeKit:AceSerialize value must not contain a secret
value`.

## `BridgeKit:AceDeserialize(text)`

```lua
local ok, kind, settings = BridgeKit:AceDeserialize(text)
if not ok then
  -- kind is the reason
end
```

Reads every text Ace's `Deserialize` reads, within the limits, and returns
`true` and the values, their count kept (`nil`s included), or `false` and a
reason. It never raises on any string; it raises at the caller only for a
`text` that is not a string or is secret. As Ace's reader does, it:

- removes every control byte and space from the text before reading it;
- reads tokens as a caret, one code character, and the data up to the next
  caret, starting at the first caret (bytes before it are ignored);
- ignores the data after `^1`, `^B`, `^b`, `^Z`, `^T`, `^t` and `^^`, and
  everything after the end code;
- accepts the infinity spellings `1.#INF`, `inf`, `-1.#INF` and `-inf`, and
  every number `tonumber` reads, hexadecimal included;
- lets a repeated table key overwrite the earlier one;
- reads `nan` as NaN.

| Reason | When | Ace3's message |
|---|---|---|
| `"notAceSerializer"` | the first token is not `^1` | "Supplied data is not AceSerializer data (rev 1)" (`253`) |
| `"missingTerminator"` | the text ends before the end code `^^` | "Supplied data misses AceSerializer terminator ('^^')" (`179`) |
| `"invalidNumber"` | a `^N` token `tonumber` cannot read | "Invalid serialized number" (`194`) |
| `"invalidFloat"` | a `^F` token not followed by `^f`, or either part not a number | "Invalid serialized floating-point number" (`199`, `204`) |
| `"invalidEscape"` | `~~`, or a tilde before a character below `@` | `string.char` fails inside Ace's reader |
| `"unknownControl"` | an unknown code, or `^t`, `^f` or `^1` where a value is expected | "Invalid AceSerializer control code" (`232`) |
| `"tableFormat"` | a table key or value that reads as `nil`, or the end code inside a table | "Invalid AceSerializer table format (no table end marker)" (`222`, `227`) |
| `"invalidKey"` | a NaN table key | Lua's "table index is NaN" |
| `"maxDepth"` | tables nest deeper than `maxDepth` | no bound |
| `"maxValues"` | more than `maxValues` values, keys included | no bound |
| `"maxStringLength"` | a string longer than `maxStringLength` bytes once unescaped | no bound |
| `"maxTextBytes"` | `text` is longer than `maxTextBytes` bytes | no bound |
| `"maxListValues"` | more than `maxListValues` top-level values | no bound |

### Deviations from Ace3

- **NaN key, invalid escape:** Ace raises inside its own `pcall` and returns
  `false` with Lua's message; BridgeKit returns the named reason.
- **`^F` numbers are scaled with `ldexp`.** Ace computes
  `mantissa * 2^exponent`, which reads some subnormal numbers its own writer
  produces as `0`, because `2^exponent` alone underflows. BridgeKit reads them
  back exactly; for every other integer exponent the two give the same
  number. A non-integer exponent, which no writer produces, is computed as Ace
  computes it.
- **The limits** below, which Ace does not have.

## Limits

The limits are shared by every embedded copy and every consumer in the
session, kept across an in-place upgrade, set with `SetLimits` and read with
`GetLimits`. Each call reads them when it starts.

| Limit | Default | `UNBOUNDED`? | Ceiling and reason |
|---|---|---|---|
| `maxDepth` | 16 | no: the reader and writer recurse on the Lua call stack | 128 |
| `maxValues` | 65536 | yes: `maxTextBytes` still bounds it | 2^24 |
| `maxStringLength` | 65536 | yes: `maxTextBytes` still bounds it | 2^30 |
| `maxTextBytes` | 1048576 | no: a peer chooses the size of the text a reader is given | 2^26 |
| `maxListValues` | 4096 | no: `AceDeserialize` returns its values through `unpack` | 7900 |

A top-level table is depth 1. `SetLimits` raises at the caller, before
changing anything, on a table that is not one, an unknown name, a secret key
or value, a value that is not an integer from 1 to the ceiling, or `UNBOUNDED`
where the table says no, naming why:
`BridgeKit:SetLimits limits.maxDepth cannot be BridgeKit.UNBOUNDED because the
reader and writer recurse on the Lua call stack; use an integer from 1 to 128`.

The design's other limits (reports, imports and AceComm streams) arrive with
the parts that use them.

## Secret values

`issecretvalue` is read at every call. A secret argument, a secret value or
key inside the values given to `AceSerialize`, a secret `text`, and a secret
`SetLimits` key or value raise at the caller; error messages never format a
value BridgeKit did not create.

## Cost

`AceSerialize` builds the text from one table of pieces and allocates one
work record per call; `AceDeserialize` first copies the text without its
control bytes and spaces, then cuts one string per token. Both are linear in
the text and recurse once per table level.

## Upgrades

The package state (`_state`) holds the limits, the `UNBOUNDED` sentinel and
the read-only baseline, so every embedded copy and every revision publishes the
same two tables. A newer compatible revision loaded over an older one keeps
that state and replaces the methods; an older copy loaded later steps aside.
A limit a later revision adds starts at its default over an inherited state.

## Testing

`tests/fixtures/AceSerializerFixtures.lua` is output recorded from Ace3 at the
pinned commit by `python3 -m tooling.fixtures.ace_serializer`, over this
project's own inputs: what `Serialize` wrote for each value and what
`Deserialize` answered for each text, malformed ones included. The specs
require BridgeKit to write the same bytes for every recorded value and to read
the same values, or the reason matching Ace's error, for every recorded text.
No Ace3 source or test is in the repository (design section 3.2).
