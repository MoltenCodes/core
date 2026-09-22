# Design Constitution

This document defines the architectural principles of the framework.

## 1. Modularity

Every independently useful capability should be isolated into a package with a clear public contract.

Packages must avoid unnecessary coupling.

## 2. Explicit contracts

Public APIs must be intentional, documented, and stable within their declared API generation.

Internal implementation details are not public contracts.

## 3. Independent publication

Every package under `packages/` must be independently versionable and publishable.

A package must not require the entire framework to be distributed.

## 4. Minimal runtime cost

Abstractions must justify their runtime cost.

Initialization, allocations, dispatch, and indirection should remain deliberate.

Reusable retention structures such as pools and caches must be bounded by default. Unbounded retention may exist only as an explicit, documented opt-in owned by the caller.

## 5. Determinism

Equivalent inputs and registration sets must produce equivalent observable results regardless of load order unless a contract explicitly states otherwise.

## 6. Compatibility

World of Warcraft runtime constraints are first-class requirements.

The framework must not assume facilities unavailable to supported WoW clients.

## 7. Documentation

Stable public behavior must be documented in English.

Names, errors, examples, and contracts should favor clarity over cleverness.

## 8. Testability

Core behavior should be testable outside the WoW client whenever practical.

WoW-specific boundaries should remain narrow.

## 9. No hidden global state

Global state must be minimized and, where unavoidable for embedded-library interoperability, explicitly documented.

## 10. Sustainable evolution

Breaking changes require an explicit API-generation decision.

Refactoring private implementation must not require consumer changes.

## 11. Package naming

Public framework capability packages use the `Kit` suffix. Package IDs are lowerCamelCase and runtime Lua facades are PascalCase. `registry` / `Registry` is the explicit infrastructure exception. Naming must remain consistent across directories, manifests, Registry keys, dependencies, module filenames, tests, and documentation.
