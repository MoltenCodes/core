# brokerKit records

Moved from `docs/ROADMAP.md` (Package J — brokerKit).

## brokerKit

**brokerKit** — facade `BrokerKit`

1. Package `brokerKit`, facade `BrokerKit`, API generation 1.
2. Purpose: data objects for display addons, compatible with the
   LibDataBroker-1.1 contract every display addon already consumes (Titan,
   Bazooka, ChocolateBar): typed data objects with `text`, `label`, `icon`,
   `value`, `suffix` and the callbacks `OnClick`, `OnEnter`, `OnLeave`,
   `OnTooltipShow`; attribute-change notification per object and per
   attribute through SignalKit; enumeration; and a bridge that publishes
   MoltenCodes objects into a foreign LibDataBroker when one is loaded and
   adopts foreign objects read-only, so an addon written against BrokerKit is
   seen by every display addon and sees theirs. Non-goals: rendering a
   display, the minimap launcher (UI phase), persisting anything.
3. Dependencies: registry API 2, signalKit API 1; interopKit API 1 optional
   through `Registry:Find` (finding LibStub's LibDataBroker).
4. Surface: `BrokerKit:New(name, definition)` → object; `BrokerKit:Get(name)`;
   `BrokerKit:Objects()` sorted; `object:Set(attribute, value)` /
   `object:Get(attribute)`; `object:OnChange(attribute?, callback)`;
   `BrokerKit:OnObjectAdded(callback)`; `BrokerKit:ExposeToLibDataBroker()` /
   `AdoptFromLibDataBroker()`; `SetLimits{ maxObjects, maxAttributes }`.
5. Ownership: objects live for the session (a display addon keeps
   references); attributes are plain fields for LibDataBroker readers and
   change through `Set` for notification; foreign objects are read-only.
6. Performance: `Set` is one comparison and one signal fire when the value
   changed; reads are field reads; no allocation per update.
7. Tests: attribute change signals, per-attribute subscriptions, callbacks
   invoked with the object, enumeration order, the bridge both ways with a
   fake LibDataBroker, limits, upgrade, manifest, error levels.
8. Docs: README, API.md (the LibDataBroker mapping field by field), CHANGELOG;
   EMBEDDING footprint and host-requirements rows.
9. Status: implemented 2026-09-24, 0.1.0, revision 1, 126 specs.

