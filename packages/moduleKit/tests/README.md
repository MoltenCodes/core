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
- manifest/runtime metadata consistency.
