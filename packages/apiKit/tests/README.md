# ApiKit Tests

The ApiKit suite covers the handwritten facade; the generated flavour files are
covered by the sampled generated-output specs that arrive with each flavour's
capture.

- flavour detection for every supported client, an unsupported client and a
  client without a project id; probes that are absent; the beta client that
  denies being a test build; detection read once at load;
- the `wow` global: published when free, left alone when taken, never
  reclaimed, status kept across a reload;
- `RegisterFlavor`: immediate installation for the running flavour with the
  flavour's `api` table and the host, other flavours dropped, first copy wins,
  metadata build recorded, installer errors propagate, state kept across a
  reload, argument validation;
- `error` levels: every argument and receiver failure reports the caller's own
  line;
- duplicate embedded loading, Registry publication, refusal of state owned by
  a newer revision, corrupted state, the read-only flavour list;
- the facade's flavour table against `tooling/api/flavours.json`;
- manifest/runtime API and revision consistency.

Spec files:

| File | Covers |
|---|---|
| `Bootstrap_spec.lua` | duplicate loading, Registry publication, newer revisions, namespace tables, `SUPPORTED_FLAVORS`, corrupted state |
| `Flavor_spec.lua` | detection for every client, missing probes, beta without test build, non-numeric project id, read once |
| `GlobalPublication_spec.lua` | the `wow` global in both states and across reloads |
| `RegisterFlavor_spec.lua` | installation, dropping, first copy wins, metadata build, installer errors, reloads, arguments |
| `ErrorLevels_spec.lua` | every argument and receiver failure at the caller's line |
| `FlavourTable_spec.lua` | the facade's table against the tooling's flavour table |
| `Manifest_spec.lua` | runtime API and revision against `package.manifest.json` |

Not yet covered: an in-place upgrade from an older revision (none exists), so
the facade's own inherited-state validation is exercised only by a same-revision
copy with incomplete state, which Registry refuses first.

`tests/support/ApiKitTestEnv.lua` builds the two-module chain (Registry, ApiKit)
on the shared fixture and installs the client identity a spec asks for
(`SetClient`, `NewPackageFor`).
