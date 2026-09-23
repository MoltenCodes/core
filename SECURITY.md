# Security policy

MoltenCodes Kits run inside other people's addons, next to data that other
players control: addon messages, hyperlinks in chat and saved variables shared
between characters. A flaw there can reach every addon that embeds the Kit, so
security reports are handled privately first and published once a fix exists.

## Supported versions

| What | Supported |
|---|---|
| The latest release of each Kit (`<packageId>-v<version>` tag) | Yes |
| The latest bundle release, the addon `MoltenCodes` (`v<version>` tag) | Yes |
| The `main` branch, unreleased | Yes; fixed before the next release |
| Any earlier release of a Kit or of the bundle | No; upgrade to the latest |

Registry keeps the newest compatible copy of a Kit loaded in the session (see
[`docs/EMBEDDING.md`](docs/EMBEDDING.md)), so a fixed release protects a player
as soon as any one of their addons ships it. Releases and their notes are listed
in [`docs/RELEASES.md`](docs/RELEASES.md#release-history).

## Reporting a vulnerability

**Do not open a public issue, discussion or pull request for a vulnerability.**

1. Use GitHub's private vulnerability reporting: the **Report a vulnerability**
   button under the repository's
   [Security tab](https://github.com/MoltenCodes/core/security/advisories/new),
   when it is enabled.
2. Otherwise, email **kendinikertenkelebek@me.com** with `MoltenCodes security`
   in the subject.

Please include:

- the Kit or Kits, with `version` and `revision` from the manifest;
- the client flavour and `## Interface` number;
- what an attacker needs (another player in the same group or channel, a crafted
  hyperlink, a shared saved-variables file) and what they gain;
- the smallest reproduction you have: a message payload, a link, a Busted spec
  against the fake client in `tests/support/`, or in-client steps.

You do not need a working exploit; a credible description is enough to start.

## What counts

A vulnerability is anything in a Kit, as documented, that lets:

- an **addon message, saved variable or hyperlink from another player** crash,
  taint or hijack an addon that uses a Kit: an error raised on a path the Kit
  documents as never raising (for example codecKit decoding), taint that
  spreads into protected frames or Blizzard code, or input that makes a Kit call
  code or change state its owner did not ask for;
- a **secret value** leak: a Kit comparing, indexing, formatting or otherwise
  exposing a value the client marks as secret, or building an error message
  from one;
- a **hostile peer exhaust memory or CPU past the documented bounds**: a Kit
  retaining more than its documented limits allow (reassembly buffers, queues,
  caches, waiters), or spending unbounded time on a crafted input.

Issues in the repository's own supply chain (a workflow that could leak a
secret, a release artifact whose checksum does not match) are in scope as well.

## Out of scope

- The World of Warcraft client itself, its API and its taint system. Report
  those to Blizzard Entertainment.
- Third-party addons, including ones that embed a Kit, unless the flaw is in the
  Kit's code. Report those to their authors.
- Behaviour an addon author opts into through a documented escape hatch, such as
  raising a limit.
- Anything that needs the attacker to already run code in the victim's client.

## What happens next

| Step | Target |
|---|---|
| Acknowledge the report | within 7 days |
| Assess it and agree on severity with you | as soon as it is reproduced |
| Release a fix, or publish a statement explaining why there will be none | within 90 days of the report |

The maintainer keeps you informed along the way. If a fix needs longer, you are
told why and when to expect it.

## Disclosure

This project follows coordinated disclosure. Please keep the report private
until a fixed release is published or 90 days have passed, whichever comes
first. The fix is released as a new version and revision of each affected Kit,
with a changelog entry that describes the problem, and a GitHub security
advisory is published once players can upgrade. Reporters are credited in the
advisory and the changelog unless they ask not to be.
