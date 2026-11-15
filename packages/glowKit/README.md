# GlowKit

GlowKit draws glows that pull the eye to a frame: an action button that is ready, an aura about to run out, a unit frame that needs attention. It is what LibCustomGlow-1.0 gives WeakAuras and action-bar addons, with two effects drawn from plain textures on an overlay frame of its own: `pixel`, short lines running round the frame's edge, and `pulse`, a border whose opacity breathes.

```lua
local GlowKit = MoltenCodes.Registries[2]:Get("glowKit", 1)

-- Lines running round the button.
GlowKit:Start(button, { color = { 1, 0.8, 0.2 }, lines = 10, frequency = 0.5 })

-- A second glow on the same button, under its own key.
GlowKit:Start(button, { key = "proc", kind = "pulse", color = { 0.3, 0.7, 1 } })

GlowKit:Stop(button, "proc")
GlowKit:StopAll(button)
```

What each piece promises:

- **Frames of its own.** Each glow is an overlay laid over your frame, above it, from a PoolKit pool that keeps every released overlay. Blizzard's spell-activation overlay (`ActionButton_ShowOverlayGlow`) is never touched.
- **Nothing while hidden.** The overlay is a child of your frame, so its one `OnUpdate` stops when your frame hides and resumes when it shows. A resized frame is followed at the next frame.
- **Keyed.** Several glows sit on one frame under different keys; starting a key that already glows restarts it with the new options.
- **Bounded.** At most 64 glows at once, up to 512 with `GlowKit:SetLimits({ maxGlows = n })`; each holds an overlay frame the session keeps, so there is no unbounded setting.

Non-goals: Blizzard's own overlay, particle or model effects.

### Moving from LibCustomGlow-1.0

| LibCustomGlow-1.0 | GlowKit |
|---|---|
| `LCG.PixelGlow_Start(frame, color, N, frequency, length, th, xOffset, yOffset, border, key)` | `GlowKit:Start(frame, { kind = "pixel", color = color, lines = N, frequency = frequency, thickness = th, key = key })` |
| `LCG.PixelGlow_Stop(frame, key)` | `GlowKit:Stop(frame, key)` |
| `LCG.ButtonGlow_Start(frame, color, frequency)` | `GlowKit:Start(frame, { kind = "pulse", color = color, frequency = frequency })` |
| `LCG.AutoCastGlow_Start(...)`, `LCG.ProcGlow_Start(...)` | No equivalent: use `pixel` or `pulse`. |

See [`docs/API.md`](docs/API.md) for the complete contract.

## Embedding

[`../../docs/EMBEDDING.md`](../../docs/EMBEDDING.md) is the addon author's guide:
directory layout, supported Interface numbers, taint, `/reload` semantics and
troubleshooting. This package's load order inside a consuming addon is:

```toc
Libs\MoltenCodes\registry\Registry.lua
Libs\MoltenCodes\poolKit\PoolKit.lua
Libs\MoltenCodes\glowKit\GlowKit.lua
```

Minimum footprint: embed 3 files: `registry/Registry.lua`, `poolKit/PoolKit.lua`, `glowKit/GlowKit.lua`.

Direct runtime dependencies: Registry API 2, PoolKit API 1.
Every file above is required; omitting one makes this package raise at
load.

GlowKit makes its overlays when a glow starts, never at load.
