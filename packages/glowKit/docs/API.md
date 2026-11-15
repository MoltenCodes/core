# GlowKit API

GlowKit API generation **1** draws pixel and pulse glows on pooled overlay frames laid over a target, several per frame under keys, bounded.

Implementation revision: **1**.

## Loading

Runtime files must be loaded in dependency order:

```text
Registry.lua
PoolKit.lua
GlowKit.lua
```

Portable WoW code resolves the package through Registry:

```lua
local GlowKit = MoltenCodes.Registries[2]:Get("glowKit", 1)
```

GlowKit does not rely on `require()` at runtime.

### Host facilities

| Facility | Used by | Without it |
|---|---|---|
| `CreateFrame` | `Start` (the first overlays) | `Start` raises at the caller: `GlowKit:Start needs the client's CreateFrame, which this host does not have`. |
| `issecretvalue` | every check, every size read | Nothing is treated as secret. |

## Public surface

| Member | Purpose |
|---|---|
| `Start(frame, options?)` | Start a glow on `frame` under `options.key`; a glow already under that key on that frame is stopped and replaced. Returns the glow. |
| `Stop(frame, key?)` | Stop the glow under `key` (default `"default"`): `true`, or `false` when there was none. |
| `StopAll(frame)` | Stop every glow on `frame`; return how many. |
| `IsGlowing(frame, key?)` | Whether a glow is under `key` on `frame`; without `key`, whether any is. |
| `SetLimits(limits)` / `GetLimits()` | Change or read `maxGlows`; `GetLimits` returns a fresh table. |
| `MAX_GLOWS`, `GLOWS_CEILING` | `64`, `512`. |
| `API`, `REVISION` | `1`, `1`. |

A glow:

| Method | Purpose |
|---|---|
| `Stop()` | Stop it: `true`, or `false` when it was already stopped. |
| `IsActive()` | Whether it is still on its frame. |

## `GlowKit:Start(frame, options?)`

`frame` is any frame (a table with `GetWidth` and `CreateTexture`). Options:

| Option | Meaning |
|---|---|
| `kind` | `"pixel"` (the default) or `"pulse"`. |
| `key` | The glow's name on its frame, a non-empty string; default `"default"`. |
| `color` | `{ r, g, b, a? }`, each from 0 to 1; default `{ 0.95, 0.95, 0.32, 1 }`. |
| `lines` | `pixel`: lines running round the edge, an integer from 1 to 32; default `8`. |
| `thickness` | Pixels, above 0 and at most 10; default `2`. |
| `frequency` | Rounds (pixel) or breaths (pulse) per second, above 0 and at most 10; default `0.25`. |

The overlay is a child of `frame`, covering it (`SetAllPoints`), five frame levels above it. At most `maxGlows` glows are active at once; restarting a key does not count twice: `GlowKit:Start holds at most 64 glows at once; stop one, or raise maxGlows`.

## The effects

**Pixel.** The edge is walked clockwise from the top left: the top left to right, the right side down, the bottom right to left, the left side up. Each of the `lines` textures starts an equal share of the way round (`(phase + (i - 1) / lines)` of the perimeter) and is half a share long, cut where its side ends. Each frame, the phase advances by `elapsed × frequency`, so the lines go round once every `1 / frequency` seconds. The frame's size is read every frame, so a resized frame is followed; a frame without size shows nothing.

**Pulse.** Four textures of `thickness` line the overlay's edges. Each frame, the phase advances as above and the overlay's alpha is `0.3 + 0.7 × (0.5 + 0.5 × sin(2π × phase))`.

Textures are made the first time a glow needs them and kept on the overlay; a glow with fewer lines hides the rest.

## Stopping and reuse

A stopped glow's overlay goes back to the pool: hidden, its update cleared, unanchored, unparented, every texture hidden. The next glow reuses it. The overlay runs nothing while the target frame is hidden, because the client does not update a hidden frame's children.

## Secret values

Every frame, option, key, colour component, limit and receiver is checked with `issecretvalue` first and refused at the caller. A size, frame level or elapsed time the client answers as a secret counts as 0.

## Limits

| Limit | Default | How to open | `UNBOUNDED` allowed? | Ceiling and reason |
|---|---|---|---|---|
| `maxGlows`, glows active at once | `64` | `GlowKit:SetLimits({ maxGlows = n })` | no | `512`: each holds an overlay frame the session keeps |

Lowering `maxGlows` keeps every glow and refuses the next. The limit is shared by every addon in the session.

## Error behaviour

Argument errors raise at the caller's line: `GlowKit:Start options.lines must be an integer from 1 to 32`; methods called on anything but a glow raise `GlowKit.Glow:Stop must be called on a GlowKit glow; use glow:Stop(...)`. What the client calls (the overlays' updates) never raises.

## Performance

| Path | Cost |
|---|---|
| A visible pixel glow | One `OnUpdate`: two size reads and `lines` texture placements per frame. |
| A visible pulse glow | One `OnUpdate`: one alpha per frame. |
| A glow on a hidden frame | Nothing. |
| `Start`, `Stop` | One pool operation; the first use of a line count makes its textures. |

## Embedded copies and upgrades

Several addons may embed GlowKit; Registry selects the newest compatible revision and every copy shares one facade and one state: the glows, the overlays, the pool and the limit. The pool's factory and reset and every overlay's update call through a dispatch table in the shared state that every loading revision rewrites, so a glow an older copy started runs the newest copy's code.
