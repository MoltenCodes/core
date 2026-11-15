# 0004. AddonKit, the single entry point

- Status: Accepted
- Date: 2026-11-15

## Context

A newcomer writing a first addon met the Registry, one lookup per Kit, a
ModuleKit container, LifecycleKit and a "Main" module before writing
`OnEnable`. Ace3's equivalent is one call that returns an addon object. The
lookups exist for a real guarantee (an addon never receives a contract it
does not understand), but that guarantee does not need the author to type
each lookup by hand, and a lookup that answers `nil` for a missing Kit gives
neither a useful error nor editor completion.

## Decision

1. A new optional Kit, `addonKit` (facade `AddonKit`), holds the single entry
   point, `MoltenCodes:For(...)`, and the addon object built on ModuleKit.
2. It resolves the Kits an addon uses lazily and raises at the caller's line,
   with the fix, when one is not embedded.
3. It is optional: every other Kit keeps working without it, and an addon
   may still resolve Kits through the Registry directly.
4. Conveniences beyond the entry point (databases from plain defaults,
   options panels and launchers in one call) are AddonKit parts
   (ADR 0001), so an addon that does not use them does not load them.

## Consequences

- The getting-started path and the examples start from `MoltenCodes:For`.
- AddonKit depends only on the Registry; the Kits it offers are optional
  dependencies, found when the addon embeds them.
- The ModuleKit and LifecycleKit contracts do not change; AddonKit is a layer
  over them.
