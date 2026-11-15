# 0003. Method-name callbacks, checked at registration

- Status: Accepted
- Date: 2026-11-15

## Context

Ace3 lets an addon register a callback by naming a method of the addon
object: `self:RegisterEvent("PLAYER_LOGIN", "OnLogin")`. The Kits accepted
only functions (closures), which kept the call path simple but made every
port from Ace3 rewrite each registration, and gave a newcomer a generic Lua
error, or none, when a method was misspelt.

## Decision

1. The runtime Kits that take callbacks (TimerKit, SignalKit, EventKit,
   LifecycleKit, ModuleKit, SchedulerKit and HookKit) accept a method name on
   a receiver as well as a function.
2. The method is checked when it is registered: it must exist on the
   receiver then. A missing method raises at the caller's line, naming the
   method and the receiver.
3. Functions stay accepted everywhere, unchanged.

## Consequences

- Ace3's registration form ports without a rewrite, and a misspelt method
  fails at once, where it was written, instead of when the event fires.
- Each Kit documents in its `docs/API.md` how a named method is called and
  what happens when the receiver changes the method after registration.
- This replaces the earlier rule that callbacks are closures only.
