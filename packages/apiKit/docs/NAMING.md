# ApiKit naming rules

Wrapper names are produced by rules, not chosen by hand. The rules live in
`tooling/api/naming.py`; the reviewed data they use (mixed-case words, aliases,
exceptions) is `tooling/api/naming.json`. This page states the rules an addon
author needs to predict a name from the Blizzard one.

## Rules

1. **Words.** A Blizzard name is split into words at PascalCase boundaries: a
   lowercase letter followed by an uppercase one starts a word (`AddOn` →
   `Add`, `On`), and a run of capitals followed by a lowercase letter ends
   before its last capital (`NPCName` → `NPC`, `Name`). Digits stay with the
   word they follow. An underscore separates words, and in an underscored name
   every all-capitals word is written as a name (`LFG_ROLEConstants` → `Lfg`,
   `Role`, `Constants`). A few mixed-case words the splitter cannot see
   (`PvP`, `PvE`, `BNet`, `CVar`, `WoW`) are listed in `naming.json` and taken
   whole.
2. **lowerCamelCase.** The first word is written in lowercase and the rest
   unchanged: `GetNPCName` → `getNPCName`, `UIWidgetManager` →
   `uiWidgetManager`, `PvPScoreInfo` → `pvpScoreInfo`.
3. **Namespaces.** A `C_` namespace drops the prefix: `C_AddOnProfiler` →
   `api.addOnProfiler`, `C_Timer` → `api.timer`. A namespace without the
   prefix (`string`, `table`) goes through the same rules, which leave those
   names as they are. Functions documented without a
   namespace (globals) are grouped by their documentation system:
   `UnitName` is in `api.unit`.
4. **Global functions** drop their system's words when their name starts with
   them and more words follow: `UnitName` in `Unit` → `api.unit.name`,
   `UnitIsPVP` → `api.unit.isPVP`; `GetTime` in `SystemTime` keeps its whole
   name → `api.systemTime.getTime`. Functions in a `C_` namespace never drop
   anything: `C_Timer.After` → `api.timer.after`.
5. **Events** are named from their documented PascalCase name and hold the
   event string: `api.events.addonLoaded == "ADDON_LOADED"`.
6. **Enumerations and constants** alias the client's tables:
   `api.enums.phaseReason == Enum.PhaseReason`,
   `api.constants.auctionConstants == Constants.AuctionConstants`.
7. **Aliases.** A short alias may point at a systematic namespace name;
   both reach the same table. Today: `api.profiler` is `api.addOnProfiler`.
   The systematic name is canonical; the alias is convenience.
8. **Collisions** (two Blizzard names mapping to one wrapper name, or a name
   that is a Lua keyword or one of `events`, `enums`, `constants`) fail
   generation. The fix is an entry in the exception tables of `naming.json`,
   never a silent suffix. The committed captures produce no collision.

## Finding a name

The generated reference (a release asset, or built locally with
`tooling.api.generate --reference-out`) lists every
namespace with its raw Blizzard name and every function with the expression
it binds to, so a raw name can be looked up and a wrapper name traced back.
The LuaCATS definitions under `types/<flavour>/` give the same in the editor.
