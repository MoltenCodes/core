# ReadinessKit

ReadinessKit gives World of Warcraft addons named gates for host data that arrives after load and is `nil` or wrong until then: spell and item information, the spellbook, talents, the guild roster. You describe the fact you need as a probe, and wait for the gate instead of guessing with a timer.

```lua
local ReadinessKit = MoltenCodes.Registries[2]:Get("readinessKit", 1)

-- One gate per name for the whole session; the first definition wins.
local spellbook = ReadinessKit:Gate("MyAddon.spellbook", function()
  return C_SpellBook.GetNumSpellBookSkillLines() > 0
end, { timeoutSeconds = 60 })

-- Probe again as soon as the host says something changed.
spellbook:ReprobeOn("SPELLS_CHANGED")

spellbook:Await(function(ready, reason)
  if ready then
    BuildRangeCheckers()
  else
    print("spellbook never arrived:", reason) -- "timeout" or "closed"
  end
end)

-- Several facts at once.
ReadinessKit:WhenAll({ spellbook, itemCache }, function(ready, reason)
  -- ...
end)

-- The data went away (a respec, say): back to waiting.
spellbook:Invalidate()
```

What each piece promises:

- **A gate probes once when it is defined.** When the probe answers, the gate is ready and no timer exists. Otherwise it polls the probe every `intervalSeconds` (0.5 by default) on one TimerKit repeating timer, and stops the moment the probe answers.
- **Timeouts.** After `timeoutSeconds` (30 by default, `false` for none) of polling, every waiter is called once with `false, "timeout"` and polling stops until `Probe()`, `Invalidate()` or a re-probe event starts a new round.
- **Negative caching.** `Probe()` re-runs the probe now, unless its last "not yet" is younger than `intervalSeconds`; a burst of callers costs one probe.
- **Bounded waiting.** `Await` runs the callback at once when the gate already has an outcome, and otherwise queues it, in order, up to `maxWaiters` (64 by default, `ReadinessKit.UNBOUNDED` for no limit). Beyond that it returns `nil, "full"`. Every handle has `Cancel()`.
- **Failures stay visible without flooding.** A probe that raises counts as "not ready" and polling continues; the first failure of each polling round is reported to the host error handler and every failure is counted in `gate:GetProbeErrorCount()`. A queued callback that raises is reported the same way and the rest of the batch still runs.
- **`gate:ReprobeOn(eventName)`** re-runs the probe whenever a host event fires. It uses EventKit, which ReadinessKit finds through `Registry:Find` when you call it. `Close()` releases the subscriptions.
- **Readiness is sticky.** Once ready, a gate stays ready until you call `Invalidate()`; it never probes a ready gate.

See [`docs/API.md`](docs/API.md) for the complete contract and [`docs/INTERNALS.md`](docs/INTERNALS.md) for the gate layout and the waiter arrays.

## When to use a LifecycleKit phase instead

LifecycleKit's phases (`loaded`, `ready`, `shutdown`) are one-shot and terminal: they happen once per addon and never undo. Use them for "my addon has loaded" and "the player is in the world". Use a ReadinessKit gate for a fact about host data that can be late, can fail to arrive, and can stop being true again.

## Embedding

[`../../docs/EMBEDDING.md`](../../docs/EMBEDDING.md) is the addon author's guide:
directory layout, supported Interface numbers, taint, `/reload` semantics and
troubleshooting. This package's load order inside a consuming addon is:

```toc
Libs\MoltenCodes\registry\Registry.lua
Libs\MoltenCodes\timerKit\TimerKit.lua
Libs\MoltenCodes\readinessKit\ReadinessKit.lua
```

Minimum footprint: Embed 3 files: Registry, TimerKit, ReadinessKit.

Direct runtime dependencies: Registry API 2, TimerKit API 1.
Every file above is required; omitting one makes this package raise at
load.

Optional: EventKit API 1, used only by `gate:ReprobeOn`. To re-probe on host
events, embed SignalKit and EventKit as well, after Registry and before
ReadinessKit (Registry, SignalKit, EventKit, TimerKit, ReadinessKit: five
files). ReadinessKit lists EventKit only under `optionalDependencies` and looks
it up with `Registry:Find` when `ReprobeOn` is called, so without EventKit, or
with an incompatible or retired one, only re-probing is unavailable.
