# Getting help

## Where to ask

| You want to | Go to |
|---|---|
| Learn how to embed or depend on the framework | [`docs/EMBEDDING.md`](docs/EMBEDDING.md), then the Kit's README and `docs/API.md` |
| Find any other document | [`docs/README.md`](docs/README.md), the documentation index |
| Ask how to do something, or talk an idea through | [GitHub Discussions](https://github.com/MoltenCodes/core/discussions), when enabled; until then, open an issue with the **Feature request** or **Documentation** form |
| Report a bug | [An issue](https://github.com/MoltenCodes/core/issues/new/choose) with the **Bug report** form |
| Propose a new Kit | [An issue](https://github.com/MoltenCodes/core/issues/new/choose) with the **Kit proposal** form |
| Report a vulnerability | Privately, as [`SECURITY.md`](SECURITY.md) describes; never in public |

The embedding guide ends with the exact error message each load-order mistake
produces and what it means; check it before reporting a load error.

## What to include

A question or report is answered much faster when it says:

- which Kit, with `version` and `revision` from its `package.manifest.json` (or
  from `manifest.json` in the bundle you installed);
- the client flavour and `## Interface` number
  (`/dump (select(4, GetBuildInfo()))`);
- whether the Kit is embedded in your addon or installed as the standalone
  `MoltenCodes` addon, and which other addons are enabled;
- the output of `/dump MoltenCodes` after the problem happens;
- the smallest code that shows the problem, and the full error text from
  BugSack or the client's error frame.

## What this project does not support

- Private support by email, except for security reports.
- Old releases: upgrade to the latest release of the Kit first. See
  [`SECURITY.md`](SECURITY.md#supported-versions).
- Problems in the game client or in other addons that are not caused by a Kit.

This is a project maintained in spare time. Everyone taking part follows the
[Code of Conduct](CODE_OF_CONDUCT.md).
