# ModuleKit Tests

The ModuleKit suite covers:

- addon/container identity, shared bootstrap state, and embedded revision behavior;
- `automatic` and `strict` dependency policies;
- hard, optional, and ordering-only graph semantics;
- deterministic topological ordering and cycle diagnostics;
- late-module ordering safety and targeted-operation isolation;
- dependency-injection scopes, deterministic aliases, provider cycles, and requester validation;
- hook failures, blocked dependents, retries, and non-terminal dependency-invariant preservation;
- terminal best-effort shutdown cleanup;
- late-created modules and definition-table catch-up;
- strict definition-schema validation;
- manifest/runtime metadata consistency;
- in-place upgrade safety: a deliberately disabled module stays disabled, and no module hook runs during migration;
- re-entrant module creation from a hook, which is deferred to the end of the running whole-container pass;
- the Lua 5.1 rule that a hook cannot yield across the `pcall` boundary;
- deterministic activation order on a larger layered graph fixture;
- module scopes: lazy creation, release on disable, `DisableAll`, shutdown and a failed `OnEnable`, absent Kits, and the enable window (TimerKit and SchedulerKit are recording fakes registered through Registry, because neither is a dependency; EventKit is covered both by a fake and by the real `EventKit:CreateScope()`);
- intent versus fact: recovery after a dependency enables, explicit disable winning over recovery, and both fields surviving an in-place upgrade.
